#!/usr/bin/env bash
set -euo pipefail

EXTIME=${EXTIME:-30}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
REPEATS=${REPEATS:-5}

SKEWS=(${SKEWS_OVERRIDE:-0.7 0.8 0.9 0.99})
THREAD_LIST=(${THREADS_OVERRIDE:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
# TAM 実験と同じ実装 (silo_with_TAM) 上での静的最適 thread 数を測る
BIN="$BUILD_DIR/silo/silo_with_TAM"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/optTAM_scan_results"
SUMMARY_FILE="$OUT_ROOT/summary_pinned_tuple_10000_release.csv"
BEST_FILE="$OUT_ROOT/best_pinned_tuple_10000_release.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_TAM first (cmake --build build_release --target silo_with_TAM -j)." >&2
  exit 1
fi

echo "skew,thread,run,throughput_tps,abort_rate" > "$SUMMARY_FILE"

run_one() {
  local skew="$1"
  local thread="$2"
  local runid="$3"

  local label="skew_${skew}/thread_${thread}"
  local tmp_log
  tmp_log=$(mktemp)

  echo "[RUN] skew=${skew} thread=${thread} run=${runid}" >&2
  if numactl --membind=0 "$BIN" \
    --thread_num="$thread" \
    --extime="$EXTIME" \
    --ycsb_tuple_num="$TUPLE_NUM" \
    --ycsb_max_ope="$MAX_OPE" \
    --ycsb_rratio="$RRATIO" \
    --ycsb_zipf_skew="$skew" \
    --pin_threads=true \
    --ada_tam_enable=false \
    --linucb_tam_enable=false \
      | tee "$tmp_log" >/dev/stderr; then
    :
  else
    echo "WARNING: run failed for $label (run $runid). Skipping." >&2
    rm -f "$tmp_log"
    return 1
  fi

  local throughput abort_rate keep_log=0
  throughput=$(awk -F':[ \t]+' '/throughput\[tps\]/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")
  abort_rate=$(awk -F':[ \t]+' '/^abort_rate/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")

  if [[ -z "$throughput" ]]; then throughput="NA"; keep_log=1; fi
  if [[ -z "$abort_rate" ]]; then abort_rate="NA"; keep_log=1; fi

  if (( keep_log )); then
    echo "WARN: metrics missing for $label (log: $tmp_log)" >&2
  else
    rm -f "$tmp_log"
  fi

  printf '%s %s\n' "$throughput" "$abort_rate"
}

for skew in "${SKEWS[@]}"; do
  for thread in "${THREAD_LIST[@]}"; do
    for ((r=1; r<=REPEATS; r++)); do
        if output=$(run_one "$skew" "$thread" "$r"); then
            if read -r tps_val abort_val <<<"$output"; then
                echo "$skew,$thread,$r,$tps_val,$abort_val" >> "$SUMMARY_FILE"
            fi
        fi
    done
  done
done

# 各 skew ごとに、「throughput の平均値」が最も高い thread と、その平均 throughput / 平均 abort_rate を集計
awk 'BEGIN{FS=","; OFS=","}
     NR==1{next}            # ヘッダ行をスキップ
     $4=="NA"{next}        # throughput NA は無視
     {
       sk=$1; th=$2; tps=$4+0; ab=$5+0;

       key = sk "\t" th;
       cnt[key]    += 1;
       sum_tps[key] += tps;
       sum_ab[key]  += ab;
     }
     END{
       # (sk,thread) ごとの平均 throughput / abort_rate を計算し、
       # skew ごとに平均 throughput が最大の thread を選ぶ
       for (key in cnt) {
         split(key, a, "\t");
         sk = a[1]; th = a[2];

         avg_tps = sum_tps[key] / cnt[key];
         avg_ab  = sum_ab[key]  / cnt[key];

         if (!(sk in best_avg) || avg_tps > best_avg[sk]) {
           best_avg[sk]    = avg_tps;
           best_thread[sk] = th;
           best_abort[sk]  = avg_ab;
         }
       }

       print "skew","best_thread","throughput_tps","abort_rate";
       for (sk in best_avg) {
         print sk,best_thread[sk],best_avg[sk],best_abort[sk];
       }
     }' "$SUMMARY_FILE" | sort -t',' -k1,1 > "$BEST_FILE"

printf '\nAll runs complete. Summary: %s, Best-per-skew: %s\n' "$SUMMARY_FILE" "$BEST_FILE" >&2