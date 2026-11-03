#!/usr/bin/env bash
set -euo pipefail

# TAM の AdaTAM / LinUCBTAM を複数の skew・複数回リピートで比較し、
# 各試行のスループット差分と優位割合を CSV に記録するスクリプト。

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_TAM"
NUMACTL_PREFIX=("numactl" "--membind=0")

# ==== 実験パラメータ（必要に応じて書き換え） ===============================

THREADS=64

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
TAM_MAX_THREADS=64
Ada_TAM_UPDATE_US=1000
LinUCB_TAM_UPDATE_US=1000
TAM_LOG_ACTIVE_THREADS=true   # TAM の active_threads ログが不要なら false のまま

# LinUCB のハイパーパラメータ
LINUCB_ALPHA=0.5
LINUCB_LAMBDA=1.0

# この動的パターンを何回リピートするか
REPEATS=5

# 結果 CSV のパス（実行ごとに新規ファイルを作る）
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_DIR="$REPO_ROOT/experiments/paper_replication/AdaTAM_vs_LinUCBTAM_dynamic"
mkdir -p "${OUT_DIR}"
RESULT_CSV="${OUT_DIR}/tam_sweep_result_${TIMESTAMP}.csv"

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
  # 引数: その他フラグ（Ada / LinUCB の切り替えなど）
  local out
  out=$("${NUMACTL_PREFIX[@]}" "${BIN}" "${COMMON_FLAGS[@]}" "$@" "${EXTRA_FLAGS[@]}")

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

  echo "${tps},${abort},${lat}"
}

# ==== メイン ================================================================

if [[ ! -x "${BIN}" ]]; then
  echo "error: benchmark binary not found: ${BIN}" >&2
  echo "       先に Release ビルドしてください (cmake --build build_release --target silo_with_TAM -j)" >&2
  exit 1
fi

# CSV ヘッダ
{
  echo "phase1_skew,phase2_skew,phase3_skew,trial,winner,winner_tps,loser,loser_tps,diff_tps,diff_pct,ada_tps,ada_abort,ada_latency,linucb_tps,linucb_abort,linucb_latency"
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
    ada_metrics=$(run_one \
      --ada_tam_enable=true \
      --linucb_tam_enable=false \
      --tam_update_period_us=${Ada_TAM_UPDATE_US} \
      --ada_tam_step=1.0)
    IFS=',' read -r ada_tps ada_abort ada_lat <<< "${ada_metrics}"

  echo "--- trial ${i}/${REPEATS} (3-phase dynamic skew) LinUCBTAM ---"
    lin_metrics=$(run_one \
      --ada_tam_enable=false \
      --linucb_tam_enable=true \
      --tam_update_period_us=${LinUCB_TAM_UPDATE_US} \
      --linucb_alpha=${LINUCB_ALPHA} \
      --linucb_lambda=${LINUCB_LAMBDA})
    IFS=',' read -r lin_tps lin_abort lin_lat <<< "${lin_metrics}"

  # どちらが優っているか判定
  winner=""; loser=""; winner_tps=""; loser_tps=""
    if awk -v a="${lin_tps}" -v b="${ada_tps}" 'BEGIN{exit !(a>b)}'; then
      winner="LinUCBTAM"
      loser="AdaTAM"
      winner_tps="${lin_tps}"
      loser_tps="${ada_tps}"
    else
      winner="AdaTAM"
      loser="LinUCBTAM"
      winner_tps="${ada_tps}"
      loser_tps="${lin_tps}"
    fi

    diff_tps=$(awk -v w="${winner_tps}" -v l="${loser_tps}" 'BEGIN{printf "%.0f", w-l}')
    diff_pct=$(awk -v w="${winner_tps}" -v l="${loser_tps}" 'BEGIN{if (l==0) print "nan"; else printf "%.2f", (w-l)/l*100}')

    echo "trial=${i}: winner=${winner} diff_tps=${diff_tps} diff_pct=${diff_pct}%" \
      "(Ada=${ada_tps}, LinUCB=${lin_tps})"

    echo "${PHASE1_SKEW},${PHASE2_SKEW},${PHASE3_SKEW},${i},${winner},${winner_tps},${loser},${loser_tps},${diff_tps},${diff_pct},${ada_tps},${ada_abort},${ada_lat},${lin_tps},${lin_abort},${lin_lat}" \
      >> "${RESULT_CSV}"
done

echo
echo "結果 CSV: ${RESULT_CSV}" 

# ==== 全体および skew ごとの集計（簡易） ==================================

echo
echo "===== 集計（全 skew 合計） ====="
awk -F',' 'NR>1{
  if ($5 == "LinUCBTAM") { lin_n++; lin_diff+=$9; lin_pct+=$10 }
  else if ($5 == "AdaTAM") { ada_n++; ada_diff+=$9; ada_pct+=$10 }
}
END{
  if (lin_n>0) {
    printf "LinUCBTAM wins: %d runs, avg diff = %.0f tps, avg advantage = %.2f%%\n", lin_n, lin_diff/lin_n, lin_pct/lin_n;
  } else {
    print "LinUCBTAM wins: 0 runs";
  }
  if (ada_n>0) {
    printf "AdaTAM   wins: %d runs, avg diff = %.0f tps, avg advantage = %.2f%%\n", ada_n, ada_diff/ada_n, ada_pct/ada_n;
  } else {
    print "AdaTAM   wins: 0 runs";
  }
}' "${RESULT_CSV}"

echo
