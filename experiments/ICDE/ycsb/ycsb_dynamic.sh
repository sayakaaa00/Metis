#!/usr/bin/env bash
set -euo pipefail

# TAM の AdaTAM / Metis_paper を複数の skew・複数回リピートで比較し、
# 各試行のスループット差分と優位割合を CSV に記録するスクリプト。

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/ycsb_metis_paper"
NUMACTL_PREFIX=("numactl" "--membind=0")

# ==== 実験パラメータ（必要に応じて書き換え） ===============================

THREADS=96

# 3 フェーズの動的 skew パターン
# フェーズ1: 起動直後 ~ PHASE1_SEC 秒まで
# フェーズ2: PHASE1_SEC ~ (PHASE1_SEC+PHASE2_SEC) 秒まで
# フェーズ3: それ以降 (合計 EXTIME まで)
PHASE1_SKEW=0.7
PHASE2_SKEW=0.95
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
TAM_MAX_THREADS=96
Ada_TAM_UPDATE_US=1000
LinUCB_TAM_UPDATE_US=10000
TAM_LOG_ACTIVE_THREADS=true   # TAM の active_threads ログが不要なら false のまま

# LinUCB のハイパーパラメータ
LINUCB_ALPHA=0.7
LINUCB_LAMBDA=1.0

# この動的パターンを何回リピートするか
REPEATS=5

# 学習済み Metis_paper モデル
MODEL_VERSION=${MODEL_VERSION:-model_test}
MODEL_BASENAME=${MODEL_BASENAME:-linucb_all.txt}
OUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$OUT_ROOT/models/$MODEL_VERSION"
MODEL_PATH="$MODEL_DIR/$MODEL_BASENAME"

# 実行結果はモデル名ごとに log/96/dynamic 配下へ保存する
MODEL_NAME=${MODEL_NAME:-$MODEL_VERSION}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RUN_DIR="$OUT_ROOT/log/96/dynamic/$MODEL_NAME"
mkdir -p "$RUN_DIR"
RESULT_CSV="$RUN_DIR/tam_sweep_result_${TIMESTAMP}.csv"

# コマンドライン引数はそのままベンチバイナリに渡す（外側から上書きしたいとき用）
EXTRA_FLAGS=("$@")

# ==== 共通フラグ ============================================================

COMMON_FLAGS_BASE=(
  "--thread_num=${THREADS}"
  "--extime=${EXTIME}"
  "--ycsb_tuple_num=${YCSB_TUPLES}"
  "--ycsb_max_ope=${YCSB_MAX_OPE}"
  "--ycsb_rratio=${YCSB_RRATIO}"
  "--pin_threads=${PIN_THREADS}"
  "--tam_min_threads=${TAM_MIN_THREADS}"
  "--tam_max_threads=${TAM_MAX_THREADS}"
  #"--tam_update_period_us=${TAM_UPDATE_US}"
  "--tam_log_active_threads=${TAM_LOG_ACTIVE_THREADS}"
)

# ==== ヘルパ関数 ============================================================

run_one() {
  # 引数: 実行名、その後にベンチマーク固有フラグ
  local run_name=$1
  shift
  local log_file="$RUN_DIR/${run_name}_${TIMESTAMP}.log"
  local active_threads_log="$RUN_DIR/${run_name}_active_threads_${TIMESTAMP}.log"
  local out tam_log_path
  local status=0

  out=$("${NUMACTL_PREFIX[@]}" "${BIN}" "${COMMON_FLAGS[@]}" "$@" "${EXTRA_FLAGS[@]}" 2>&1) || status=$?
  printf '%s\n' "$out" > "$log_file"
  printf 'Saved benchmark log to %s\n' "$log_file" >&2

  tam_log_path=$(awk -F': ' '/TAM active_threads logs will be written to/ {print $2; exit}' "$log_file")
  if [[ -n "$tam_log_path" && -f "$tam_log_path" ]]; then
    cp -f "$tam_log_path" "$active_threads_log"
    printf 'Saved TAM active_threads log to %s\n' "$active_threads_log" >&2
  else
    printf 'WARN: TAM active_threads log was not found for %s\n' "$run_name" >&2
  fi

  if (( status != 0 )); then
    printf 'ERROR: benchmark failed with status %d: %s\n' "$status" "$log_file" >&2
    return "$status"
  fi

  local tps abort lat
  tps=$(awk '/throughput\[tps\]/{print $2}' "$log_file")
  abort=$(awk '/^abort_rate:/{print $2}' "$log_file")
  lat=$(awk '/^latency\[ns\]/{print $2}' "$log_file")

  if [[ -z "$tps" || -z "$abort" || -z "$lat" ]]; then
    echo "error: failed to parse metrics from benchmark output: $log_file" >&2
    exit 1
  fi

  echo "$tps,$abort,$lat"
}

# ==== メイン ================================================================

if [[ ! -x "${BIN}" ]]; then
  echo "error: benchmark binary not found: ${BIN}" >&2
  echo "       先に Release ビルドしてください (cmake --build build_release --target ycsb_metis_paper -j)" >&2
  exit 1
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
  echo "error: trained Metis_paper model not found: ${MODEL_PATH}" >&2
  echo "       MODEL_DIR または MODEL_PATH でモデルの場所を指定してください" >&2
  exit 1
fi

if [[ "$(head -n 1 "${MODEL_PATH}")" != "linucb_abs_model_v2" ]]; then
  echo "error: incompatible model format: ${MODEL_PATH}" >&2
  echo "       expected header: linucb_abs_model_v2" >&2
  exit 1
fi

echo "trained model: ${MODEL_PATH}"

# CSV ヘッダ
{
  echo "phase1_skew,phase2_skew,phase3_skew,trial,winner,winner_tps,loser,loser_tps,diff_tps,diff_pct,ada_tps,ada_abort,ada_latency,metis_paper_tps,metis_paper_abort,metis_paper_latency"
} > "${RESULT_CSV}"

echo
echo "===== dynamic skew pattern ====="
echo "  phase1: skew=${PHASE1_SKEW}, duration=${PHASE1_SEC}s"
echo "  phase2: skew=${PHASE2_SKEW}, duration=${PHASE2_SEC}s (start at ${PHASE1_SEC}s)"
echo "  phase3: skew=${PHASE3_SKEW}, duration=${PHASE3_SEC}s (start at $((PHASE1_SEC + PHASE2_SEC))s)"

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

for ((i=1; i<=REPEATS; i++)); do
    echo
    echo "--- trial ${i}/${REPEATS} (3-phase dynamic skew) AdaTAM ---"
    ada_metrics=$(run_one "adatam_trial_${i}" \
      --ada_tam_enable=true \
      --metis_paper_enable=false \
      --tam_update_period_us=${Ada_TAM_UPDATE_US} \
      --ada_tam_step=1.0)
    IFS=',' read -r ada_tps ada_abort ada_lat <<< "${ada_metrics}"

  echo "--- trial ${i}/${REPEATS} (3-phase dynamic skew) Metis_paper ---"
    lin_metrics=$(run_one "metis_paper_trial_${i}" \
      --ada_tam_enable=false \
      --metis_paper_enable=true \
      --tam_update_period_us=${LinUCB_TAM_UPDATE_US} \
      --linucb_alpha=${LINUCB_ALPHA} \
      --linucb_lambda=${LINUCB_LAMBDA} \
      --linucb_model_path=${MODEL_PATH} \
      --linucb_model_autosave=false)
    IFS=',' read -r lin_tps lin_abort lin_lat <<< "${lin_metrics}"

  # どちらが優っているか判定
  winner=""; loser=""; winner_tps=""; loser_tps=""
    if awk -v a="${lin_tps}" -v b="${ada_tps}" 'BEGIN{exit !(a>b)}'; then
      winner="Metis_paper"
      loser="AdaTAM"
      winner_tps="${lin_tps}"
      loser_tps="${ada_tps}"
    else
      winner="AdaTAM"
      loser="Metis_paper"
      winner_tps="${ada_tps}"
      loser_tps="${lin_tps}"
    fi

    diff_tps=$(awk -v w="${winner_tps}" -v l="${loser_tps}" 'BEGIN{printf "%.0f", w-l}')
    diff_pct=$(awk -v w="${winner_tps}" -v l="${loser_tps}" 'BEGIN{if (l==0) print "nan"; else printf "%.2f", (w-l)/l*100}')

    echo "trial=${i}: winner=${winner} diff_tps=${diff_tps} diff_pct=${diff_pct}%" \
      "(Ada=${ada_tps}, Metis_paper=${lin_tps})"

    echo "${PHASE1_SKEW},${PHASE2_SKEW},${PHASE3_SKEW},${i},${winner},${winner_tps},${loser},${loser_tps},${diff_tps},${diff_pct},${ada_tps},${ada_abort},${ada_lat},${lin_tps},${lin_abort},${lin_lat}" \
      >> "${RESULT_CSV}"
done

echo
echo "結果 CSV: ${RESULT_CSV}" 

# ==== 全体および skew ごとの集計（簡易） ==================================

echo
echo "===== 集計（全 skew 合計） ====="
awk -F',' 'NR>1{
  if ($5 == "Metis_paper") { lin_n++; lin_diff+=$9; lin_pct+=$10 }
  else if ($5 == "AdaTAM") { ada_n++; ada_diff+=$9; ada_pct+=$10 }
}
END{
  if (lin_n>0) {
    printf "Metis_paper wins: %d runs, avg diff = %.0f tps, avg advantage = %.2f%%\n", lin_n, lin_diff/lin_n, lin_pct/lin_n;
  } else {
    print "Metis_paper wins: 0 runs";
  }
  if (ada_n>0) {
    printf "AdaTAM   wins: %d runs, avg diff = %.0f tps, avg advantage = %.2f%%\n", ada_n, ada_diff/ada_n, ada_pct/ada_n;
  } else {
    print "AdaTAM   wins: 0 runs";
  }
}' "${RESULT_CSV}"

echo
