#!/usr/bin/env bash
set -euo pipefail

EXTIME=${EXTIME:-10}
TUPLE_NUM=${TUPLE_NUM:-1000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
REPEATS=${REPEATS:-1}

SKEWS=(${SKEWS_OVERRIDE:-0.7 0.8 0.9 0.99})
THREAD_LIST=(${THREADS_OVERRIDE:-2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build"
BIN="$BUILD_DIR/silo/silo_with_TAM"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/optTAM_scan_results"
SUMMARY_FILE="$OUT_ROOT/summary_pinned_runs_tuple_1000.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_without_backoff first." >&2
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
      --cpu_use_os_load_aware=true \
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

printf '\nAll runs complete. Summary: %s\n' "$SUMMARY_FILE" >&2