#!/usr/bin/env bash
set -euo pipefail

# AdaTAM の性能を、3 フェーズの動的 skew 環境で複数回計測し、
# - 全体 throughput / abort_rate / latency
# - 最適スレッド数に到達するまでの時間
# - 最適スレッド数に張り付いていた時間
# - 各フェーズごとの平均 throughput と安定性（throughput の標準偏差）
# を CSV に記録するスクリプト。

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_TAM"
NUMACTL_PREFIX=("numactl" "--membind=0")

# 常にリポジトリルートをカレントディレクトリにして実行する。
# これにより、ycsb_silo.cc 内の相対パス
#   "experiments/paper_replication/logs"
# へ TAM ログが一貫して出力される。
cd "${REPO_ROOT}"

# ==== 実験パラメータ（必要に応じて書き換え） =============================== 

THREADS=64

# 3 フェーズの動的 skew パターン
# フェーズ1: 起動直後 ~ PHASE1_SEC 秒まで
# フェーズ2: PHASE1_SEC ~ (PHASE1_SEC+PHASE2_SEC) 秒まで
# フェーズ3: それ以降 (合計 EXTIME まで)
PHASE1_SKEW=0.7
PHASE2_SKEW=0.99
PHASE3_SKEW=0.8

PHASE1_SEC=20
PHASE2_SEC=20
PHASE3_SEC=20

# 自動的に extime を 3 フェーズ合計に設定
EXTIME=$((PHASE1_SEC + PHASE2_SEC + PHASE3_SEC))

YCSB_TUPLES=10000
YCSB_MAX_OPE=10
YCSB_RRATIO=50

PIN_THREADS=true

TAM_MIN_THREADS=1
TAM_MAX_THREADS=64
TAM_UPDATE_US=1000
TAM_LOG_ACTIVE_THREADS=true   # AdaTAM の挙動解析に TAM ログを使う

# この動的パターンを何回リピートするか
REPEATS=3

# 各 skew ごとの「最適スレッド数」をここで指定する
# （optTAM スキャンなどから得た静的最適スレッド数）
OPT_THREADS_0_7=32
OPT_THREADS_0_8=32
OPT_THREADS_0_9=27
OPT_THREADS_0_99=21

# 結果 CSV のパス（実行ごとに新規ファイルを作る）
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_DIR="$REPO_ROOT/experiments/paper_replication/AdaTAM_performance"
mkdir -p "${OUT_DIR}"
RESULT_CSV="${OUT_DIR}/adatam_perfo_${TIMESTAMP}.csv"

# コマンドライン引数はそのままベンチバイナリに渡す（外側から上書きしたいとき用）
EXTRA_FLAGS=("$@")

# ==== 共通フラグ ============================================================

get_opt_for_skew() {
  local skew="$1"
  case "${skew}" in
    0.7)  echo "${OPT_THREADS_0_7}" ;;
    0.8)  echo "${OPT_THREADS_0_8}" ;;
    0.9)  echo "${OPT_THREADS_0_9}" ;;
    0.99) echo "${OPT_THREADS_0_99}" ;;
    *)
      echo "0" >&2
      echo "0"
      ;;
  esac
}

PHASE1_OPT_THREADS=$(get_opt_for_skew "${PHASE1_SKEW}")
PHASE2_OPT_THREADS=$(get_opt_for_skew "${PHASE2_SKEW}")
PHASE3_OPT_THREADS=$(get_opt_for_skew "${PHASE3_SKEW}")

COMMON_FLAGS_BASE=(
  "--thread_num=${THREADS}"
  "--extime=${EXTIME}"
  "--ycsb_tuple_num=${YCSB_TUPLES}"
  "--ycsb_max_ope=${YCSB_MAX_OPE}"
  "--ycsb_rratio=${YCSB_RRATIO}"
  "--pin_threads=${PIN_THREADS}"
  "--tam_min_threads=${TAM_MIN_THREADS}"
  "--tam_max_threads=${TAM_MAX_THREADS}"
  "--tam_log_active_threads=${TAM_LOG_ACTIVE_THREADS}"
)

# このパターン用の共通フラグを組み立て
COMMON_FLAGS=(
  "${COMMON_FLAGS_BASE[@]}"
  "--ycsb_zipf_skew=${PHASE1_SKEW}"
  "--ycsb_skew_change_enable=true"
  "--ycsb_zipf_skew2=${PHASE2_SKEW}"
  "--ycsb_skew_change_time_sec=${PHASE1_SEC}"
  "--ycsb_skew_change_enable2=true"
  "--ycsb_zipf_skew3=${PHASE3_SKEW}"
  "--ycsb_skew_change_time_sec2=$((PHASE1_SEC + PHASE2_SEC))"
)

# ==== ヘルパ関数: TAM ログ解析 (AdaTAM 向け) ============================

analyze_tam_log() {
  local log_path=$1

  # 事前にログファイルの存在をチェックして、わかりやすいエラーを出す
  if [[ ! -f "${log_path}" ]]; then
    echo "error: TAM log file not found: ${log_path}" >&2
    return 1
  fi

  awk -v opt1="${PHASE1_OPT_THREADS}" \
      -v opt2="${PHASE2_OPT_THREADS}" \
      -v opt3="${PHASE3_OPT_THREADS}" \
      -v period_us="${TAM_UPDATE_US}" \
      -v p1="${PHASE1_SEC}" -v p2="${PHASE2_SEC}" '
  BEGIN {
    idx = 0;
    first_opt_time1 = -1.0;
    first_opt_time2 = -1.0;
    first_opt_time3 = -1.0;

    opt_samples1 = 0;
    opt_samples2 = 0;
    opt_samples3 = 0;

    c1 = c2 = c3 = 0;
    sum1 = sum2 = sum3 = 0.0;
    sq1 = sq2 = sq3 = 0.0;
  }

  /^\[AdaTAM\]/ {
    at = 0; tps = 0.0;
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^active_threads=/) {
        gsub(/^active_threads=/, "", $i);
        at = $i + 0;
      } else if ($i ~ /^tput=/) {
        gsub(/^tput=/, "", $i);
        tps = $i + 0.0;
      }
    }
    if (at <= 0) next;

    time_sec = (idx + 1) * period_us / 1000000.0;

    boundary1 = p1;
    boundary2 = p1 + p2;
    if (time_sec < boundary1) {
      phase = 1; cur_opt = opt1;
    } else if (time_sec < boundary2) {
      phase = 2; cur_opt = opt2;
    } else {
      phase = 3; cur_opt = opt3;
    }

    if (phase == 1) {
      if (at == opt1) {
        if (first_opt_time1 < 0.0) first_opt_time1 = time_sec;
        opt_samples1++;
      }
      c1++; sum1 += tps; sq1 += tps * tps;
    } else if (phase == 2) {
      if (at == opt2) {
        if (first_opt_time2 < 0.0) first_opt_time2 = time_sec;
        opt_samples2++;
      }
      c2++; sum2 += tps; sq2 += tps * tps;
    } else {
      if (at == opt3) {
        if (first_opt_time3 < 0.0) first_opt_time3 = time_sec;
        opt_samples3++;
      }
      c3++; sum3 += tps; sq3 += tps * tps;
    }

    idx++;
  }

  END {
    if (first_opt_time1 < 0.0) time_to_opt1 = -1.0; else time_to_opt1 = first_opt_time1;
    if (first_opt_time2 < 0.0) time_to_opt2 = -1.0; else time_to_opt2 = first_opt_time2 - p1;
    if (first_opt_time3 < 0.0) time_to_opt3 = -1.0; else time_to_opt3 = first_opt_time3 - (p1 + p2);

    time_at_opt1 = opt_samples1 * period_us / 1000000.0;
    time_at_opt2 = opt_samples2 * period_us / 1000000.0;
    time_at_opt3 = opt_samples3 * period_us / 1000000.0;

    if (c1 > 0) {
      mean1 = sum1 / c1;
      var1  = sq1 / c1 - mean1 * mean1;
      if (var1 < 0.0) var1 = 0.0;
      std1  = (var1 > 0.0) ? sqrt(var1) : 0.0;
    } else { mean1 = 0.0; std1 = 0.0; }

    if (c2 > 0) {
      mean2 = sum2 / c2;
      var2  = sq2 / c2 - mean2 * mean2;
      if (var2 < 0.0) var2 = 0.0;
      std2  = (var2 > 0.0) ? sqrt(var2) : 0.0;
    } else { mean2 = 0.0; std2 = 0.0; }

    if (c3 > 0) {
      mean3 = sum3 / c3;
      var3  = sq3 / c3 - mean3 * mean3;
      if (var3 < 0.0) var3 = 0.0;
      std3  = (var3 > 0.0) ? sqrt(var3) : 0.0;
    } else { mean3 = 0.0; std3 = 0.0; }

    printf "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n",
      time_to_opt1, time_at_opt1,
      time_to_opt2, time_at_opt2,
      time_to_opt3, time_at_opt3,
      mean1, std1,
      mean2, std2,
      mean3, std3;
  }
  ' "${log_path}"
}

# ==== ヘルパ関数: ベンチ 1 回実行 ==========================================

run_one() {
  local out
  out=$("${NUMACTL_PREFIX[@]}" "${BIN}" "${COMMON_FLAGS[@]}" \
        --ada_tam_enable=true \
        --linucb_tam_enable=false \
        --tam_update_period_us=${TAM_UPDATE_US} \
        "${EXTRA_FLAGS[@]}")

  # stdout から throughput / abort_rate / latency を抽出
  local tps abort lat
  tps=$(echo "${out}"    | awk '/throughput\[tps\]/{print $2}')
  abort=$(echo "${out}"  | awk '/^abort_rate:/{print $2}')
  lat=$(echo "${out}"    | awk '/^latency\[ns\]/{print $2}')

  if [[ -z "${tps}" || -z "${abort}" || -z "${lat}" ]]; then
    echo "error: failed to parse metrics from benchmark output" >&2
    echo "--- raw output ---" >&2
    echo "${out}" >&2
    exit 1
  fi

  # TAM ログファイルのパスを取得
  local log_path
  log_path=$(echo "${out}" | awk '/TAM active_threads logs will be written to:/{print $NF}' | tail -n1)
  if [[ -z "${log_path}" ]]; then
    echo "error: failed to find TAM active_threads log path in output" >&2
    echo "--- raw output ---" >&2
    echo "${out}" >&2
    exit 1
  fi

  # ベンチマーク側が出力したパスに本当にファイルが存在するかを確認
  if [[ ! -f "${log_path}" ]]; then
    echo "error: TAM log file does not exist at reported path: ${log_path}" >&2
    echo "       current working directory: $(pwd)" >&2
    exit 1
  fi

  # TAM ログから AdaTAM の詳細メトリクスを算出
  local tam_metrics
  tam_metrics=$(analyze_tam_log "${log_path}")

  if [[ -z "${tam_metrics}" ]]; then
    echo "error: analyze_tam_log returned empty metrics for log: ${log_path}" >&2
    exit 1
  fi

  # stdout 用と CSV 用に返す（カンマ区切り）
  echo "${tps},${abort},${lat},${tam_metrics}"
}

# ==== メイン ================================================================

if [[ ! -x "${BIN}" ]]; then
  echo "error: benchmark binary not found: ${BIN}" >&2
  echo "       先に Release ビルドしてください (cmake --build build_release --target silo_with_TAM -j)" >&2
  exit 1
fi

# CSV ヘッダ
{
  echo "phase1_skew,phase2_skew,phase3_skew,phase1_sec,phase2_sec,phase3_sec,trial,overall_tps,overall_abort,overall_latency,opt_threads_p1,opt_threads_p2,opt_threads_p3,phase1_time_to_opt_sec,phase1_time_at_opt_sec,phase2_time_to_opt_sec,phase2_time_at_opt_sec,phase3_time_to_opt_sec,phase3_time_at_opt_sec,phase1_mean_tps,phase1_tput_std,phase2_mean_tps,phase2_tput_std,phase3_mean_tps,phase3_tput_std"
} > "${RESULT_CSV}"

echo
echo "===== AdaTAM performance check (3-phase dynamic skew) ====="
echo "  phase1: skew=${PHASE1_SKEW}, duration=${PHASE1_SEC}s"
echo "  phase2: skew=${PHASE2_SKEW}, duration=${PHASE2_SEC}s (start at ${PHASE1_SEC}s)"
echo "  phase3: skew=${PHASE3_SKEW}, duration=${PHASE3_SEC}s (start at $((PHASE1_SEC + PHASE2_SEC))s)"
echo "  OPT_THREADS: phase1=${PHASE1_OPT_THREADS}, phase2=${PHASE2_OPT_THREADS}, phase3=${PHASE3_OPT_THREADS}"

for ((i=1; i<=REPEATS; i++)); do
  echo
  echo "--- trial ${i}/${REPEATS} (AdaTAM only) ---"
  metrics=$(run_one)
  IFS=',' read -r tps abort lat \
                  p1_time_to_opt p1_time_at_opt \
                  p2_time_to_opt p2_time_at_opt \
                  p3_time_to_opt p3_time_at_opt \
                  p1_mean p1_std p2_mean p2_std p3_mean p3_std <<< "${metrics}"

  echo "trial=${i}: tps=${tps} abort_rate=${abort} \"time_to_opt\" (s): p1=${p1_time_to_opt}, p2=${p2_time_to_opt}, p3=${p3_time_to_opt}"

  echo "${PHASE1_SKEW},${PHASE2_SKEW},${PHASE3_SKEW},${PHASE1_SEC},${PHASE2_SEC},${PHASE3_SEC},${i},${tps},${abort},${lat},${PHASE1_OPT_THREADS},${PHASE2_OPT_THREADS},${PHASE3_OPT_THREADS},${p1_time_to_opt},${p1_time_at_opt},${p2_time_to_opt},${p2_time_at_opt},${p3_time_to_opt},${p3_time_at_opt},${p1_mean},${p1_std},${p2_mean},${p2_std},${p3_mean},${p3_std}" \
    >> "${RESULT_CSV}"
done

echo
echo "結果 CSV: ${RESULT_CSV}"
