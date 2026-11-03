#!/usr/bin/env bash
set -euo pipefail

# Short, static-thread calibration for transaction-level TPC-C contention.
# METIS and TAM are deliberately disabled; only the hot New-Order ratio varies.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/tpcc_mix_config.sh"

WAREHOUSES=${WAREHOUSES:-96}
EXTIME=${EXTIME:-5}
REPEATS=${REPEATS:-1}
THREADS=${THREADS:-"16 32 48 64 96"}
RATIOS=${RATIOS:-"0.00 0.50 1.00"}
HOT_ITEM_COUNT=${HOT_ITEM_COUNT:-100}
HOT_WAREHOUSE_ID=${HOT_WAREHOUSE_ID:-1}
HOT_DISTRICT_COUNT=${HOT_DISTRICT_COUNT:-10}
HOT_TRANSACTION_KEEP_TPCC_ROUTING=${HOT_TRANSACTION_KEEP_TPCC_ROUTING:-false}
# An unset variable keeps the historical interleave default, while an
# explicitly empty value runs without numactl (the OS default NUMA policy).
NUMACTL_ARGS=${NUMACTL_ARGS---interleave=all}
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-$((EXTIME + 300))}
RESUME=${RESUME:-0}
COMPRESS_LOGS=${COMPRESS_LOGS:-true}

REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
if [[ "$RESUME" == "1" && -z "${RESULT_DIR:-}" ]]; then
  echo "ERROR: RESUME=1 requires RESULT_DIR to point at the existing result directory" >&2
  exit 1
fi
RESULT_DIR=${RESULT_DIR:-"$SCRIPT_DIR/results/hot_transaction_calibration_${TIMESTAMP}"}
RAW_DIR="$RESULT_DIR/logs"
RESULT_CSV="$RESULT_DIR/results.csv"
CONFIG_FILE="$RESULT_DIR/config.txt"

read -r -a THREAD_VALUES <<< "${THREADS//$'\n'/ }"
read -r -a RATIO_VALUES <<< "${RATIOS//$'\n'/ }"
read -r -a NUMACTL_OPTIONS <<< "$NUMACTL_ARGS"
declare -A seen_threads=()
for threads in "${THREAD_VALUES[@]}"; do
  if [[ ! "$threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: invalid thread count: $threads" >&2
    exit 1
  fi
  if [[ -n "${seen_threads[$threads]:-}" ]]; then
    echo "ERROR: duplicate thread count: $threads" >&2
    exit 1
  fi
  seen_threads[$threads]=1
done
if [[ "$COMPRESS_LOGS" != true && "$COMPRESS_LOGS" != false ]]; then
  echo "ERROR: COMPRESS_LOGS must be true or false" >&2
  exit 1
fi
if [[ "$HOT_TRANSACTION_KEEP_TPCC_ROUTING" != true && "$HOT_TRANSACTION_KEEP_TPCC_ROUTING" != false ]]; then
  echo "ERROR: HOT_TRANSACTION_KEEP_TPCC_ROUTING must be true or false" >&2
  exit 1
fi
if [[ "$COMPRESS_LOGS" == true ]] && ! command -v gzip >/dev/null 2>&1; then
  echo "ERROR: gzip is required when COMPRESS_LOGS=true" >&2
  exit 1
fi
if ((${#NUMACTL_OPTIONS[@]} > 0)); then
  if ! command -v numactl >/dev/null 2>&1; then
    echo "ERROR: numactl is required when NUMACTL_ARGS is non-empty" >&2
    exit 1
  fi
  NUMA_MODE="numactl ${NUMACTL_OPTIONS[*]}"
  BENCHMARK_CMD=(numactl "${NUMACTL_OPTIONS[@]}" "$BIN")
else
  NUMA_MODE="default OS NUMA policy (numactl not used)"
  BENCHMARK_CMD=("$BIN")
fi

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found: $BIN" >&2
  echo "Build it with: cmake --build build_release --target tpcc_metis_paper -j" >&2
  exit 1
fi
for command_name in timeout awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done
if (( WAREHOUSES < 1 || HOT_WAREHOUSE_ID < 1 || HOT_WAREHOUSE_ID > WAREHOUSES )); then
  echo "ERROR: invalid warehouse configuration" >&2
  exit 1
fi
if (( HOT_ITEM_COUNT < 15 || HOT_ITEM_COUNT > 100000 )); then
  echo "ERROR: HOT_ITEM_COUNT must be in [15, 100000]" >&2
  exit 1
fi
if (( HOT_DISTRICT_COUNT < 1 || HOT_DISTRICT_COUNT > 10 )); then
  echo "ERROR: HOT_DISTRICT_COUNT must be in [1, 10]" >&2
  exit 1
fi

expected_config=$(cat <<EOF
binary=$BIN
warehouses=$WAREHOUSES
extime=$EXTIME
repeats=$REPEATS
threads=$THREADS
hot_transaction_ratios=$RATIOS
hot_item_count=$HOT_ITEM_COUNT
hot_warehouse_id=$HOT_WAREHOUSE_ID
hot_district_count=$HOT_DISTRICT_COUNT
hot_transaction_keep_tpcc_routing=$HOT_TRANSACTION_KEEP_TPCC_ROUTING
numactl_args=$NUMACTL_ARGS
new_order_percent=$TPCC_PERC_NEW_ORDER
payment_percent=$TPCC_PERC_PAYMENT
order_status_percent=$TPCC_PERC_ORDER_STATUS
delivery_percent=$TPCC_PERC_DELIVERY
stock_level_percent=$TPCC_PERC_STOCK_LEVEL
home_warehouse_assignment=random_per_transaction
remote_supplier_selection=standard
metis=false
tam=false
EOF
)
if [[ "$RESUME" == "1" ]]; then
  if [[ ! -f "$CONFIG_FILE" || ! -f "$RESULT_CSV" ]]; then
    echo "ERROR: cannot resume; missing config.txt or results.csv in $RESULT_DIR" >&2
    exit 1
  fi
  if ! diff -u <(printf '%s\n' "$expected_config") <(grep -v '^compress_logs=' "$CONFIG_FILE"); then
    echo "ERROR: resume configuration does not match the existing result directory" >&2
    exit 1
  fi
  config_tmp="$CONFIG_FILE.tmp.$$"
  { grep -v '^compress_logs=' "$CONFIG_FILE"; printf 'compress_logs=%s\n' "$COMPRESS_LOGS"; } > "$config_tmp"
  mv -- "$config_tmp" "$CONFIG_FILE"
  echo "[RESUME] preserving existing results: $RESULT_CSV" >&2
else
  mkdir -p "$RAW_DIR"
  printf '%s\ncompress_logs=%s\n' "$expected_config" "$COMPRESS_LOGS" > "$CONFIG_FILE"
  echo "ratio,threads,run,tps,abort_rate,latency_ns,commits,aborts,observed_hot_tx_ratio,observed_remote_line_ratio,neworder_attempts,hot_neworder_attempts,lines,remote_lines,hot_district_hist,log_file" > "$RESULT_CSV"
fi
mkdir -p "$RAW_DIR"

extract_scalar() {
  local key=$1 logfile=$2
  if [[ "$logfile" == *.gz ]]; then
    gzip -cd -- "$logfile" | awk -v key="$key" '$1 == key && !found {value=$2; found=1} END {if (found) print value}'
  else
    awk -v key="$key" '$1 == key && !found {value=$2; found=1} END {if (found) print value}' "$logfile"
  fi
}
extract_stat() {
  local key=$1 logfile=$2
  local parser='/\[TPC-C hot-transaction stats\]/ && !found {
    for (i = 1; i <= NF; ++i) {
      split($i, pair, "=");
      if (pair[1] == key) { value=pair[2]; found=1; break }
    }
  } END {if (found) print value}'
  if [[ "$logfile" == *.gz ]]; then
    gzip -cd -- "$logfile" | awk -v key="$key" "$parser"
  else
    awk -v key="$key" "$parser" "$logfile"
  fi
}
show_log_tail() {
  if [[ "$1" == *.gz ]]; then
    gzip -cd -- "$1" | tail -n 50 >&2
  else
    tail -n 50 "$1" >&2
  fi
}
run_is_recorded() {
  awk -F, -v ratio="$1" -v threads="$2" -v run="$3" \
    'NR > 1 && $1 == ratio && $2 == threads && $3 == run { found=1; exit }
     END { exit !found }' "$RESULT_CSV"
}

total_runs=$((${#RATIO_VALUES[@]} * ${#THREAD_VALUES[@]} * REPEATS))
echo "[CONFIG] runs=$total_runs, measurement seconds=$((total_runs * EXTIME)) (excluding DB load)" >&2
echo "[CONFIG] result directory: $RESULT_DIR" >&2
echo "[CONFIG] NUMA mode: $NUMA_MODE" >&2

for ratio in "${RATIO_VALUES[@]}"; do
  ratio_tag=${ratio//./p}
  for threads in "${THREAD_VALUES[@]}"; do
    for ((run=1; run<=REPEATS; run++)); do
      if [[ "$RESUME" == "1" ]] && run_is_recorded "$ratio" "$threads" "$run"; then
        echo "[SKIP] hot_tx_ratio=$ratio threads=$threads run=$run/$REPEATS (already recorded)" >&2
        continue
      fi
      log_file="$RAW_DIR/ratio_${ratio_tag}_threads_${threads}_run_${run}.log"
      if [[ "$COMPRESS_LOGS" == true ]]; then log_file+=".gz"; fi
      echo "[RUN] hot_tx_ratio=$ratio threads=$threads run=$run/$REPEATS" >&2
      status=0
      if [[ "$COMPRESS_LOGS" == true ]]; then
        timeout --signal=TERM --kill-after=10s "${RUN_TIMEOUT_SEC}s" \
          "${BENCHMARK_CMD[@]}" \
          --thread_num="$threads" \
          --extime="$EXTIME" \
          --tpcc_num_wh="$WAREHOUSES" \
          --tpcc_perc_payment="$TPCC_PERC_PAYMENT" \
          --tpcc_perc_order_status="$TPCC_PERC_ORDER_STATUS" \
          --tpcc_perc_delivery="$TPCC_PERC_DELIVERY" \
          --tpcc_perc_stock_level="$TPCC_PERC_STOCK_LEVEL" \
          --tpcc_home_warehouse_assignment=random_per_transaction \
          --tpcc_hot_transaction_mode=true \
          --tpcc_hot_transaction_keep_tpcc_routing="$HOT_TRANSACTION_KEEP_TPCC_ROUTING" \
          --tpcc_hot_transaction_ratio="$ratio" \
          --tpcc_hot_warehouse_id="$HOT_WAREHOUSE_ID" \
          --tpcc_hot_district_count="$HOT_DISTRICT_COUNT" \
          --tpcc_hot_item_count="$HOT_ITEM_COUNT" \
          --tpcc_hot_item_ratio=0 \
          --tpcc_hot_transaction_stats=true \
          --tpcc_hot_item_stats=false \
          --tpcc_interactive_ms=0 \
          --tpcc_retry_same_type=true \
          --ada_tam_enable=false \
          --metis_paper_enable=false \
          2>&1 | gzip -c >"$log_file" || status=$?
      else
        timeout --signal=TERM --kill-after=10s "${RUN_TIMEOUT_SEC}s" \
          "${BENCHMARK_CMD[@]}" \
          --thread_num="$threads" \
          --extime="$EXTIME" \
          --tpcc_num_wh="$WAREHOUSES" \
          --tpcc_perc_payment="$TPCC_PERC_PAYMENT" \
          --tpcc_perc_order_status="$TPCC_PERC_ORDER_STATUS" \
          --tpcc_perc_delivery="$TPCC_PERC_DELIVERY" \
          --tpcc_perc_stock_level="$TPCC_PERC_STOCK_LEVEL" \
          --tpcc_home_warehouse_assignment=random_per_transaction \
          --tpcc_hot_transaction_mode=true \
          --tpcc_hot_transaction_keep_tpcc_routing="$HOT_TRANSACTION_KEEP_TPCC_ROUTING" \
          --tpcc_hot_transaction_ratio="$ratio" \
          --tpcc_hot_warehouse_id="$HOT_WAREHOUSE_ID" \
          --tpcc_hot_district_count="$HOT_DISTRICT_COUNT" \
          --tpcc_hot_item_count="$HOT_ITEM_COUNT" \
          --tpcc_hot_item_ratio=0 \
          --tpcc_hot_transaction_stats=true \
          --tpcc_hot_item_stats=false \
          --tpcc_interactive_ms=0 \
          --tpcc_retry_same_type=true \
          --ada_tam_enable=false \
          --metis_paper_enable=false \
          >"$log_file" 2>&1 || status=$?
      fi
      if (( status != 0 )); then
        echo "ERROR: benchmark failed with status $status: $log_file" >&2
        show_log_tail "$log_file"
        exit "$status"
      fi

      tps=$(extract_scalar "throughput[tps]:" "$log_file")
      abort_rate=$(extract_scalar "abort_rate:" "$log_file")
      latency=$(extract_scalar "latency[ns]:" "$log_file")
      commits=$(extract_scalar "commit_counts_:" "$log_file")
      aborts=$(extract_scalar "abort_counts_:" "$log_file")
      observed_hot=$(extract_stat "observed_hot_ratio" "$log_file")
      observed_remote=$(extract_stat "observed_remote_line_ratio" "$log_file")
      observed_district_count=$(extract_stat "hot_district_count" "$log_file")
      hot_district_hist=$(extract_stat "hot_district_hist" "$log_file")
      neworder_attempts=$(extract_stat "neworder_attempts" "$log_file")
      hot_attempts=$(extract_stat "hot_neworder_attempts" "$log_file")
      lines=$(extract_stat "lines" "$log_file")
      remote_lines=$(extract_stat "remote_lines" "$log_file")
      if [[ "$HOT_TRANSACTION_KEEP_TPCC_ROUTING" != true ]]; then
        if [[ "$observed_district_count" != "$HOT_DISTRICT_COUNT" ]] || \
           ! awk -F';' -v k="$HOT_DISTRICT_COUNT" '{
             for (i = 1; i <= NF; ++i) {
               split($i, pair, ":");
               if (pair[1] > k && pair[2] != 0) exit 1;
             }
           }' <<< "$hot_district_hist"; then
          echo "ERROR: hot district configuration was not honored: $log_file" >&2
          show_log_tail "$log_file"
          exit 1
        fi
      fi
      echo "$ratio,$threads,$run,$tps,$abort_rate,$latency,$commits,$aborts,$observed_hot,$observed_remote,$neworder_attempts,$hot_attempts,$lines,$remote_lines,$hot_district_hist,$log_file" >> "$RESULT_CSV"
    done
  done
done

echo "[DONE] results: $RESULT_CSV" >&2
