#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   run_silo_single_pinned.sh <skew> <thread> [runid]
#
# Environment variables (optional):
#   EXTIME      : benchmark time in seconds (default: 60)
#   TUPLE_NUM   : YCSB tuple_num (default: 1000000)
#   MAX_OPE     : YCSB max_ope (default: 10)
#   RRATIO      : YCSB rratio (default: 50)
#   OUT_CSV     : output CSV path
#                 (default: experiments/paper_replication/optTAM_scan_results/single_pinned_runs.csv)
#
# This script runs silo_with_TAM with CPU pinning enabled 
# "skew,thread,run,throughput_tps,abort_rate" to the CSV.

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <skew> <thread> [runid]" >&2
  exit 1
fi

skew="$1"
thread="$2"
runid="${3:-1}"

EXTIME=${EXTIME:-60}
TUPLE_NUM=${TUPLE_NUM:-1000000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
BIN="$BUILD_DIR/silo/silo_with_TAM"
OUT_ROOT="$REPO_ROOT/experiments/paper_replication/optTAM_scan_results"
OUT_CSV=${OUT_CSV:-"$OUT_ROOT/pinned_runs.csv"}

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_TAM first." >&2
  exit 1
fi

# Create CSV with header if it does not exist yet.
if [[ ! -f "$OUT_CSV" ]]; then
  echo "skew,thread,run,throughput_tps,abort_rate" > "$OUT_CSV"
fi

label="skew_${skew}/thread_${thread}/run_${runid}"
tmp_log=$(mktemp)

echo "[SINGLE RUN PINNED] skew=${skew} thread=${thread} run=${runid}" >&2
if numactl --membind=0 "$BIN" \
    --thread_num="$thread" \
    --extime="$EXTIME" \
    --ycsb_tuple_num="$TUPLE_NUM" \
    --ycsb_max_ope="$MAX_OPE" \
    --ycsb_rratio="$RRATIO" \
    --ycsb_zipf_skew="$skew" \
    --pin_threads=true \
    | tee "$tmp_log" >/dev/stderr; then
  :
else
  echo "WARNING: run failed for $label. Skipping." >&2
  echo "${skew},${thread},${runid},NA,NA" >> "$OUT_CSV"
  exit 1
fi

throughput=$(awk -F':[ \t]+' '/throughput\[tps\]/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")
abort_rate=$(awk -F':[ \t]+' '/^abort_rate/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$tmp_log")

if [[ -z "$throughput" ]]; then throughput="NA"; fi
if [[ -z "$abort_rate" ]]; then abort_rate="NA"; fi

printf '%s,%s,%s,%s,%s\n' "$skew" "$thread" "$runid" "$throughput" "$abort_rate" >> "$OUT_CSV"

rm -f "$tmp_log"

echo "Appended result to $OUT_CSV: skew=${skew}, thread=${thread}, run=${runid}, tps=${throughput}, abort_rate=${abort_rate}" >&2
