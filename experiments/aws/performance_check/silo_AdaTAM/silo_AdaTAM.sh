#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-96}
EXTIME=${EXTIME:-10}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
UPDATE_PERIOD_US=${UPDATE_US_OVERRIDE:-10000}
ADA_TAM_STEP=${ADA_TAM_STEP_OVERRIDE:-4.0}

SKEWS=(${SKEWS_OVERRIDE:-0.8 0.85 0.9 0.95 0.99})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_TAM"

OUT_ROOT="$REPO_ROOT/experiments/aws/performance_check/silo_AdaTAM"
SUMMARY_FILE="$OUT_ROOT/summary_96.csv"
LOG_DIR="$OUT_ROOT/log/96/with_pin"


mkdir -p "$OUT_ROOT"
mkdir -p "$LOG_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_TAM first." >&2
  exit 1
fi

echo "skew,throughput_tps,abort_rate" > "$SUMMARY_FILE"

run_one() {
	local skew="$1"
	local label="skew_${skew}"
	local log_file="$LOG_DIR/linucb_tam_paper_skew_${skew}_$(date +%Y%m%d_%H%M%S).log"

	echo "[RUN] skew=${skew} log=${log_file}" >&2

	if numactl --membind=0 "$BIN" \
		--thread_num="$THREADS" \
		--extime="$EXTIME" \
		--ycsb_tuple_num="$TUPLE_NUM" \
		--ycsb_max_ope="$MAX_OPE" \
		--ycsb_rratio="$RRATIO" \
		--ycsb_zipf_skew="$skew" \
		--tam_update_period_us="$UPDATE_PERIOD_US" \
		--ada_tam_enable=true \
		--tam_log_active_threads=true \
		--tam_log_period_us="$UPDATE_PERIOD_US" \
		--ada_tam_step="$ADA_TAM_STEP" \
		--pin_threads=true \
		2>&1 | tee "$log_file"
	then
		:
	else
		echo "WARNING: run failed or timed out for $label. Keeping log: $log_file" >&2
		return 1
	fi

	tam_log_path=$(awk -F': ' '/TAM active_threads logs will be written to/ {print $2; exit}' "$log_file")
	if [[ -n "$tam_log_path" && -f "$tam_log_path" ]]; then
		log_base=$(basename "$tam_log_path")
		cp -f "$tam_log_path" "$LOG_DIR/$log_base"
		printf 'Saved TAM active_threads log to %s\n' "$LOG_DIR/$log_base" >&2
	else
		printf 'WARN: tam_active_threads log path not found in output\n' >&2
	fi

	local throughput abort_rate keep_log=0

	throughput=$(awk -F':[ \t]+' '/throughput\[tps\]/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$log_file")
	abort_rate=$(awk -F':[ \t]+' '/^abort_rate/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "$log_file")

	if [[ -z "$throughput" ]]; then throughput="NA"; keep_log=1; fi
	if [[ -z "$abort_rate" ]]; then abort_rate="NA"; keep_log=1; fi

	if (( keep_log )); then
		echo "WARN: metrics missing for $label (log: $log_file)" >&2
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
