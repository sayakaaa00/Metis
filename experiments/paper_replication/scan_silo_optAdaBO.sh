#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-64}
EXTIME=${EXTIME:-60}
TUPLE_NUM=${TUPLE_NUM:-1000000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
REPEATS=${REPEATS:-3}

SKEWS=(${SKEWS_OVERRIDE:-0.7 0.8 0.9 0.99})
UPDATE_PERIODS_US=(${UPDATE_US_OVERRIDE:-10 5000 50000})
STEPS_US=(${STEP_US_OVERRIDE:-0.5 1 5})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
BIN="$BUILD_DIR/silo/silo_with_backoff"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/adaBO_scan_results"
SUMMARY_FILE="$OUT_ROOT/summary.csv"
BEST_REPORT="$OUT_ROOT/best_by_skew.txt"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_backoff first." >&2
  exit 1
fi

echo "skew,backoff_update_period_us,backoff_step_us,run,throughput_tps,abort_rate" > "$SUMMARY_FILE"

run_one() {
  local skew="$1"
  local upd_us="$2"
  local step_us="$3"
  local runid="$4"

  local label="skew_${skew}/upd_${upd_us}us/step_${step_us}us"
  local tmp_log
  tmp_log=$(mktemp)

  echo "[RUN] skew=${skew} upd=${upd_us}us step=${step_us}us run=${runid}" >&2
  if "$BIN" \
      --thread_num="$THREADS" \
      --extime="$EXTIME" \
      --ycsb_tuple_num="$TUPLE_NUM" \
      --ycsb_max_ope="$MAX_OPE" \
      --ycsb_rratio="$RRATIO" \
      --ycsb_zipf_skew="$skew" \
      --backoff_update_period_us="$upd_us" \
      --backoff_step_us="$step_us" \
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
  for upd in "${UPDATE_PERIODS_US[@]}"; do
    for step in "${STEPS_US[@]}"; do
      for ((r=1; r<=REPEATS; r++)); do
        if output=$(run_one "$skew" "$upd" "$step" "$r"); then
          if read -r tps_val abort_val <<<"$output"; then
            echo "$skew,$upd,$step,$r,$tps_val,$abort_val" >> "$SUMMARY_FILE"
          fi
        fi
      done
    done
  done
done

printf '\nAll runs complete. Summary: %s\n' "$SUMMARY_FILE" >&2

awk -F',' '
NR==1 { next }
{
  skew=$1
  tps=$5+0
  if (!(skew in best) || tps > best[skew]) {
    best[skew]=tps
    rec[skew]=$0
  }
}
END {
  print "Best combos per skew (by throughput):"
  for (skew in best) {
    split(rec[skew], arr, ",")
    printf("  skew=%s update_us=%s step_us=%s run=%s throughput=%s abort_rate=%s\n",
           arr[1], arr[2], arr[3], arr[4], arr[5], arr[6])
  }
}
' "$SUMMARY_FILE" | tee "$BEST_REPORT"

echo "Best-per-skew report: $BEST_REPORT"
