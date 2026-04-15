#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-64}
EXTIME=${EXTIME:-30}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}


SKEWS=(${SKEWS_OVERRIDE:-0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 0.99})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/ermia/ycsb_ermia.exe"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/ermia"
SUMMARY_FILE="$OUT_ROOT/summary_tuple10000_build.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build ycsb_ermia.exe first (e.g. cmake --build build_release --target ycsb_ermia.exe)." >&2
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
    2>&1 | tee "$tmp_log" >&2; then
    :
  else
    echo "WARNING: run failed for $label. Skipping." >&2
    rm -f "$tmp_log"
    return 1
  fi

  local throughput abort_rate keep_log=0
  # Strictly extract only numeric values that follow the metric labels. This avoids
  # accidentally picking up other colon-separated config lines (e.g. "#FLAGS_clocks_per_us:").
  # Use sed to capture the first numeric token after the label.
  throughput=$(sed -nE 's/.*throughput\[tps\]:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' "$tmp_log" | head -n1 || true)
  abort_rate=$(sed -nE 's/.*abort_rate:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' "$tmp_log" | head -n1 || true)

  if [[ -z "$throughput" ]]; then
    throughput="NA"
    keep_log=1
  fi
  if [[ -z "$abort_rate" ]]; then
    abort_rate="NA"
    keep_log=1
  fi

  if (( keep_log )); then
    echo "WARN: metrics missing for $label (log: $tmp_log)" >&2
    # Print a small diagnostic snippet to stderr to help debugging parsing issues.
    echo "--- first 200 bytes of log ---" >&2
    head -c 200 "$tmp_log" >&2 || true
    echo "--- end snippet ---" >&2
    # keep the temp log for inspection
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