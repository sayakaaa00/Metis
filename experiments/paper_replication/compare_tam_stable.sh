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
EXTIME=15

YCSB_TUPLES=10000
YCSB_MAX_OPE=10
YCSB_RRATIO=50

# sweep する Zipf skew のリスト
SKEWS=(0.7 0.8 0.9 0.99)

PIN_THREADS=true

TAM_MIN_THREADS=1
TAM_MAX_THREADS=64
Ada_TAM_UPDATE_US=1000
LinUCB_TAM_UPDATE_US=1000
TAM_LOG_ACTIVE_THREADS=true # TAM の active_threads ログが不要なら false のまま

# LinUCB のハイパーパラメータ
LINUCB_ALPHA=0.5
LINUCB_LAMBDA=1.0

# 各 skew ごとに何回リピートするか
REPEATS=3

# 結果 CSV のパス（実行ごとに新規ファイルを作る）
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_CSV="$REPO_ROOT/experiments/paper_replication/AdaTAM_vs_LinUCBTAM/tam_sweep_result_${TIMESTAMP}.csv"

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
  echo "skew,trial,winner,winner_tps,loser,loser_tps,diff_tps,diff_pct,ada_tps,ada_abort,ada_latency,linucb_tps,linucb_abort,linucb_latency"
} > "${RESULT_CSV}"

for skew in "${SKEWS[@]}"; do
  echo
  echo "===== skew=${skew} ====="

  # この skew 用の共通フラグを組み立て
  COMMON_FLAGS=("${COMMON_FLAGS_BASE[@]}" "--ycsb_zipf_skew=${skew}")

  for ((i=1; i<=REPEATS; i++)); do
    echo
    echo "--- trial ${i}/${REPEATS} (skew=${skew}) AdaTAM ---"
    ada_metrics=$(run_one \
      --ada_tam_enable=true \
      --linucb_tam_enable=false \
      --tam_update_period_us=${Ada_TAM_UPDATE_US} \
      --ada_tam_step=2.0)
    IFS=',' read -r ada_tps ada_abort ada_lat <<< "${ada_metrics}"

    echo "--- trial ${i}/${REPEATS} (skew=${skew}) LinUCBTAM ---"
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

    echo "skew=${skew} trial=${i}: winner=${winner} diff_tps=${diff_tps} diff_pct=${diff_pct}%" \
      "(Ada=${ada_tps}, LinUCB=${lin_tps})"

    echo "${skew},${i},${winner},${winner_tps},${loser},${loser_tps},${diff_tps},${diff_pct},${ada_tps},${ada_abort},${ada_lat},${lin_tps},${lin_abort},${lin_lat}" \
      >> "${RESULT_CSV}"
  done
done

echo
echo "結果 CSV: ${RESULT_CSV}" 

# ==== 全体および skew ごとの集計（簡易） ==================================

echo
echo "===== 集計（全 skew 合計） ====="
awk -F',' '
  # 先頭行がヘッダ("skew,...")ならスキップし，空行も無視する
  NR==1 && $1=="skew" { next }
  NF==0 { next }
  {
    if ($3 == "LinUCBTAM") { lin_n++; lin_diff+=$7; lin_pct+=$8 }
    else if ($3 == "AdaTAM") { ada_n++; ada_diff+=$7; ada_pct+=$8 }
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
  }
' "${RESULT_CSV}"

echo
echo "===== skew 別 平均 throughput ====="
echo "skew,ada_mean_tps,linucb_mean_tps,winner,winner_diff_tps,winner_diff_pct"
# 各 skew ごとに AdaTAM / LinUCBTAM の平均 throughput を計算し，勝者とその差分を表示
awk -F',' '
  # 先頭行がヘッダ("skew,...")ならスキップし，空行も無視する
  NR==1 && $1=="skew" { next }
  NF==0 { next }
  {
    # カラム:
    # 1:skew, 9:ada_tps, 12:linucb_tps
    ada_sum[$1] += $9;
    ada_cnt[$1] += 1;
    lin_sum[$1] += $12;
    lin_cnt[$1] += 1;
  }
  END{
    for (k in ada_sum) {
      ada_m = ada_sum[k] / ada_cnt[k];
      lin_m = lin_sum[k] / lin_cnt[k];

      if (ada_m > lin_m) {
        w = "AdaTAM";
        diff = ada_m - lin_m;
        base = lin_m;
      } else if (lin_m > ada_m) {
        w = "LinUCBTAM";
        diff = lin_m - ada_m;
        base = ada_m;
      } else {
        w = "tie";
        diff = 0.0;
        base = ada_m; # どちらも同じ
      }

      if (base == 0) {
        pct = "nan";
        printf "%s,%.0f,%.0f,%s,%.0f,%s\n", k, ada_m, lin_m, w, diff, pct;
      } else {
        pct = diff / base * 100.0;
        printf "%s,%.0f,%.0f,%s,%.0f,%.2f\n", k, ada_m, lin_m, w, diff, pct;
      }
    }
  }
' "${RESULT_CSV}" | sort -t',' -k1,1

echo
