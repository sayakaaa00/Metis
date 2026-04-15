#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-64}
EXTIME=${EXTIME:-10}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
REPEATS=${REPEATS:-1}

SKEWS=(${SKEWS_OVERRIDE:-0.7 0.8 0.9 0.99})
UPDATE_PERIODS_US=(${UPDATE_US_OVERRIDE:-100 1000 5000 10000 50000 100000})
STEPS=(${STEP_OVERRIDE:-1 2 4})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_TAM"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/optAdaTAM_scan_results"
SUMMARY_FILE="$OUT_ROOT/summary_pinned_tuple_10000_release.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_without_backoff first." >&2
  exit 1
fi

echo "skew,update_periods_us,steps,throughput_tps,abort_rate" > "$SUMMARY_FILE"

run_one() {
  local skew="$1"
  local thread="$2"
  local upd_us="$3"
  local step="$4"
  local runid="$5"

  local label="skew_${skew}/upd_${upd_us}us/step_${step}"
  local tmp_log
  tmp_log=$(mktemp)

  echo "[RUN] skew=${skew} thread=${thread} upd=${upd_us}us step=${step} run=${runid}" >&2
  if numactl --membind=0 "$BIN" \
    --thread_num="$thread" \
      --extime="$EXTIME" \
      --ycsb_tuple_num="$TUPLE_NUM" \
      --ycsb_max_ope="$MAX_OPE" \
      --ycsb_rratio="$RRATIO" \
      --ycsb_zipf_skew="$skew" \
      --pin_threads=true \
      --ada_tam_enable=true \
      --tam_update_period_us="$upd_us" \
      --ada_tam_step="$step" \
      --tam_log_active_threads=false \
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
  for upd_us in "${UPDATE_PERIODS_US[@]}"; do
    for step_us in "${STEPS[@]}"; do
      for ((r=1; r<=REPEATS; r++)); do
        if output=$(run_one "$skew" "$THREADS" "$upd_us" "$step_us" "$r"); then
          if read -r tps_val abort_val <<<"$output"; then
            echo "$skew,$upd_us,$step_us,$tps_val,$abort_val" >> "$SUMMARY_FILE"
          fi
        fi
      done
    done
  done
done

printf '\nAll runs complete. Summary: %s\n' "$SUMMARY_FILE" >&2