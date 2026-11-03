#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-96}
EXTIME=${EXTIME:-10}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
SKEW=${SKEW:-0.99}
RUNS_PER_BACKOFF=${RUNS_PER_BACKOFF:-3}
BACKOFF_VALUES_STR=${BACKOFF_VALUES_OVERRIDE:-0 10 50 100 500 1000}
read -r -a BACKOFF_VALUES <<< "$BACKOFF_VALUES_STR"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_backoff"

OUT_DIR="$REPO_ROOT/experiments/aws/performance_check/backoff/silo_BO_avg"
SUMMARY_FILE="$OUT_DIR/summary_skew_${SKEW}.csv"

mkdir -p "$OUT_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_backoff first." >&2
  exit 1
fi

echo "fixed_backoff_us,avg_throughput_tps,avg_abort_rate" > "$SUMMARY_FILE"

run_one() {
  local fixed_backoff_us="$1"
  local tmp_log
  tmp_log=$(mktemp)

  echo "[RUN] skew=${SKEW} fixed_backoff_us=${fixed_backoff_us}" >&2
  if "$BIN" \
      --thread_num="$THREADS" \
      --extime="$EXTIME" \
      --ycsb_tuple_num="$TUPLE_NUM" \
      --ycsb_max_ope="$MAX_OPE" \
      --ycsb_rratio="$RRATIO" \
      --ycsb_zipf_skew="$SKEW" \
      --backoff_fixed_enable=true \
      --backoff_fixed_us="$fixed_backoff_us" \
      --backoff_log_enable=false \
      | tee "$tmp_log" >&2; then
    :
  else
    echo "WARNING: run failed for fixed_backoff_us=${fixed_backoff_us}. Skipping." >&2
    rm -f "$tmp_log"
    return 1
  fi

  local throughput abort_rate
  throughput=$(awk -F':[ \t]+' '/throughput\[tps\]/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")
  abort_rate=$(awk -F':[ \t]+' '/^abort_rate/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")
  rm -f "$tmp_log"

  if [[ -z "$throughput" || -z "$abort_rate" ]]; then
    echo "WARNING: metrics missing for fixed_backoff_us=${fixed_backoff_us}." >&2
    return 1
  fi

  printf '%s %s\n' "$throughput" "$abort_rate"
}

average_lines() {
  awk '
    {
      throughput_sum += $1
      abort_sum += $2
      count += 1
    }
    END {
      if (count == 0) {
        exit 1
      }
      printf "%.6f %.6f\n", throughput_sum / count, abort_sum / count
    }
  ' "$1"
}

for backoff_us in "${BACKOFF_VALUES[@]}"; do
  result_file=$(mktemp)
  success_count=0

  for ((run_idx = 1; run_idx <= RUNS_PER_BACKOFF; run_idx++)); do
    echo "[TRY] fixed_backoff_us=${backoff_us} run=${run_idx}/${RUNS_PER_BACKOFF}" >&2
    if output=$(run_one "$backoff_us"); then
      echo "$output" >> "$result_file"
      success_count=$((success_count + 1))
    fi
  done

  if (( success_count == 0 )); then
    echo "WARNING: no successful runs for fixed_backoff_us=${backoff_us}. Writing NA." >&2
    echo "${backoff_us},NA,NA" >> "$SUMMARY_FILE"
    rm -f "$result_file"
    continue
  fi

  if avg_output=$(average_lines "$result_file"); then
    read -r avg_tps avg_abort <<<"$avg_output"
    echo "${backoff_us},${avg_tps},${avg_abort}" >> "$SUMMARY_FILE"
  else
    echo "WARNING: failed to compute averages for fixed_backoff_us=${backoff_us}. Writing NA." >&2
    echo "${backoff_us},NA,NA" >> "$SUMMARY_FILE"
  fi

  rm -f "$result_file"
done

printf '\nAll runs complete. Summary: %s\n' "$SUMMARY_FILE" >&2
