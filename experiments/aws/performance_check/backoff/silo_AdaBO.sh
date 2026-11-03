#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-96}
EXTIME=${EXTIME:-10}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
UPDATE_PERIOD_US=${UPDATE_US_OVERRIDE:-10000}
STEP_US=${STEP_US_OVERRIDE:-3}
BACKOFF_LOG_ENABLE=${BACKOFF_LOG_ENABLE:-true}
BACKOFF_LOG_INTERVAL_US=${BACKOFF_LOG_INTERVAL_US:-10000}

SKEWS=(${SKEWS_OVERRIDE:-0.9})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_backoff"

OUT_ROOT="$REPO_ROOT/experiments/aws/performance_check/backoff/silo_AdaBO"
SUMMARY_FILE="$OUT_ROOT/log_0.9_10000.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_backoff first." >&2
  exit 1
fi

echo "skew,throughput_tps,abort_rate,backoff_log" > "$SUMMARY_FILE"

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
      --backoff_log_enable="$BACKOFF_LOG_ENABLE" \
      --backoff_log_interval_us="$BACKOFF_LOG_INTERVAL_US" \
      | tee "$tmp_log" >&2; then
    :
  else
    echo "WARNING: run failed for $label. Skipping." >&2
    rm -f "$tmp_log"
    return 1
  fi

  local throughput abort_rate backoff_log_src backoff_log_dst keep_log=0
  throughput=$(awk -F':[ \t]+' '/throughput\[tps\]/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")
  abort_rate=$(awk -F':[ \t]+' '/^abort_rate/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")
  backoff_log_src=$(awk -F': ' '/Backoff logs will be written to/ {print $2; exit}' "$tmp_log")

  if [[ -z "$throughput" ]]; then throughput="NA"; keep_log=1; fi
  if [[ -z "$abort_rate" ]]; then abort_rate="NA"; keep_log=1; fi

  backoff_log_dst="NA"
  if [[ -n "$backoff_log_src" ]]; then
    if [[ -f "$REPO_ROOT/$backoff_log_src" ]]; then
      backoff_log_dst="$OUT_ROOT/$(basename "$backoff_log_src")"
      mv "$REPO_ROOT/$backoff_log_src" "$backoff_log_dst"
      echo "Saved backoff log to $backoff_log_dst" >&2
    else
      echo "WARN: backoff log file not found at $REPO_ROOT/$backoff_log_src" >&2
      keep_log=1
    fi
  elif [[ "$BACKOFF_LOG_ENABLE" == "true" ]]; then
    echo "WARN: backoff log path not found for $label" >&2
    keep_log=1
  fi

  if (( keep_log )); then
    echo "WARN: metrics missing or log unresolved for $label (console log: $tmp_log)" >&2
  else
    rm -f "$tmp_log"
  fi

  printf '%s %s %s\n' "$throughput" "$abort_rate" "$backoff_log_dst"
}

for skew in "${SKEWS[@]}"; do
  if output=$(run_one "$skew"); then
    if read -r tps_val abort_val backoff_log_val <<<"$output"; then
      echo "$skew,$tps_val,$abort_val,$backoff_log_val" >> "$SUMMARY_FILE"
    fi
  fi
done

printf '\nAll runs complete. Summary: %s\n' "$SUMMARY_FILE" >&2
