#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-64}
EXTIME=${EXTIME:-10}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
UPDATE_PERIOD_US=${UPDATE_US_OVERRIDE:-5000}
STEP_US=${STEP_US_OVERRIDE:-0.5}

SKEWS=(${SKEWS_OVERRIDE:-0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 0.99})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
BIN="$BUILD_DIR/silo/silo_with_backoff"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/silo_adaBO"
SUMMARY_FILE="$OUT_ROOT/summary_tuple1000.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_backoff first." >&2
  exit 1
fi

echo "skew,throughput_tps,abort_rate" > "$SUMMARY_FILE"

run_one() {
  local skew="$1"

  local label="skew_${skew}"
  local tmp_log
  tmp_log=$(mktemp)

  echo "[RUN] skew=${skew}" >&2
  if "$BIN" \
      --thread_num="$THREADS" \
      --extime="$EXTIME" \
      --ycsb_tuple_num="$TUPLE_NUM" \
      --ycsb_max_ope="$MAX_OPE" \
      --ycsb_rratio="$RRATIO" \
      --ycsb_zipf_skew="$skew" \
      --backoff_update_period_us="$UPDATE_PERIOD_US" \
      --backoff_step_us="$STEP_US" \
      | tee "$tmp_log" >&2; then
    :
  else
    echo "WARNING: run failed for $label. Skipping." >&2
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
    if output=$(run_one "$skew"); then
        if read -r tps_val abort_val <<<"$output"; then
            echo "$skew,$tps_val,$abort_val" >> "$SUMMARY_FILE"
        fi
    fi
done

printf '\nAll runs complete. Summary: %s\n' "$SUMMARY_FILE" >&2
