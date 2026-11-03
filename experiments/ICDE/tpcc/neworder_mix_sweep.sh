#!/usr/bin/env bash
set -euo pipefail

# New-Order share sweep with a fixed warehouse count. The remaining transaction
# mix follows TPC-C's Payment:Order-Status:Delivery:Stock-Level ratio 43:4:4:4.
# No custom tpcc_hot_* flags are passed; random warehouse per transaction is on.
WAREHOUSES=${WAREHOUSES:-96}
NEW_ORDER_PERCENTAGES=${NEW_ORDER_PERCENTAGES:-"45 55 65 75 85 90"}
THREADS=${THREADS:-"8 16 24 32 48 64 96"}
EXTIME=${EXTIME:-5}
REPEATS=${REPEATS:-2}
NUMACTL_ARGS=${NUMACTL_ARGS---interleave=all}
RETRY_SAME_TYPE=${RETRY_SAME_TYPE:-false}
RESUME=${RESUME:-false}
COMPRESS_LOGS=${COMPRESS_LOGS:-false}
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-$((EXTIME + 300))}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR_WAS_SET=${RESULT_DIR+x}
RESULT_DIR=${RESULT_DIR:-"$SCRIPT_DIR/results/neworder_mix_sweep_${TIMESTAMP}"}
RAW_DIR="$RESULT_DIR/logs"
RESULT_CSV="$RESULT_DIR/results.csv"
SUMMARY_CSV="$RESULT_DIR/summary.csv"
BEST_CSV="$RESULT_DIR/best_threads.csv"

read -r -a NEW_ORDER_VALUES <<< "$NEW_ORDER_PERCENTAGES"
read -r -a THREAD_VALUES <<< "$THREADS"
read -r -a NUMACTL_OPTIONS <<< "$NUMACTL_ARGS"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found or not executable: $BIN" >&2
  echo "Build with: cmake --build build_release --target tpcc_metis_paper -j" >&2
  exit 1
fi
if (( WAREHOUSES < 1 || EXTIME < 1 || REPEATS < 1 || RUN_TIMEOUT_SEC < 0 )); then
  echo "ERROR: WAREHOUSES, EXTIME, REPEATS must be positive; timeout non-negative" >&2
  exit 1
fi
if [[ "$RETRY_SAME_TYPE" != true && "$RETRY_SAME_TYPE" != false ]]; then
  echo "ERROR: RETRY_SAME_TYPE must be true or false" >&2
  exit 1
fi
if [[ "$RESUME" != true && "$RESUME" != false ]]; then
  echo "ERROR: RESUME must be true or false" >&2
  exit 1
fi
if [[ "$COMPRESS_LOGS" != true && "$COMPRESS_LOGS" != false ]]; then
  echo "ERROR: COMPRESS_LOGS must be true or false" >&2
  exit 1
fi
if [[ "$COMPRESS_LOGS" == true ]] && ! command -v gzip >/dev/null 2>&1; then
  echo "ERROR: gzip is required when COMPRESS_LOGS=true" >&2
  exit 1
fi
if (( ${#NEW_ORDER_VALUES[@]} == 0 || ${#THREAD_VALUES[@]} == 0 )); then
  echo "ERROR: NEW_ORDER_PERCENTAGES and THREADS must not be empty" >&2; exit 1
fi
if (( RUN_TIMEOUT_SEC > 0 )) && ! command -v timeout >/dev/null 2>&1; then
  echo "ERROR: timeout is required when RUN_TIMEOUT_SEC > 0" >&2; exit 1
fi
if ((${#NUMACTL_OPTIONS[@]} > 0)); then
  if ! command -v numactl >/dev/null 2>&1; then
    echo "ERROR: numactl is required when NUMACTL_ARGS is non-empty" >&2; exit 1
  fi
  NUMA_MODE="numactl ${NUMACTL_OPTIONS[*]}"
  BENCHMARK_CMD=(numactl "${NUMACTL_OPTIONS[@]}" "$BIN")
else
  NUMA_MODE="default OS NUMA policy (numactl not used)"
  BENCHMARK_CMD=("$BIN")
fi
for new_order in "${NEW_ORDER_VALUES[@]}"; do
  if [[ ! "$new_order" =~ ^[0-9]+$ ]] || (( new_order > 100 )); then
    echo "ERROR: invalid New-Order percentage: $new_order (expected 0..100)" >&2; exit 1
  fi
done
for threads in "${THREAD_VALUES[@]}"; do
  if [[ ! "$threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: invalid thread count: $threads" >&2; exit 1
  fi
done
if [[ "$RESUME" == true ]]; then
  if [[ -z "$RESULT_DIR_WAS_SET" ]]; then
    echo "ERROR: set RESULT_DIR to the existing result directory when RESUME=true" >&2
    exit 1
  fi
  if [[ ! -d "$RESULT_DIR" || ! -f "$RESULT_DIR/config.txt" || ! -f "$RESULT_DIR/results.csv" ]]; then
    echo "ERROR: result directory is missing config.txt or results.csv: $RESULT_DIR" >&2
    exit 1
  fi
  expected_config=(
    "binary=$BIN"
    "warehouses=$WAREHOUSES (fixed across runs)"
    "new_order_percentages=$NEW_ORDER_PERCENTAGES"
    "threads=$THREADS"
    "extime=$EXTIME"
    "repeats=$REPEATS"
    "tpcc_retry_same_type=$RETRY_SAME_TYPE"
    "numactl_args=$NUMACTL_ARGS"
  )
  for expected_line in "${expected_config[@]}"; do
    if ! grep -Fxq "$expected_line" "$RESULT_DIR/config.txt"; then
      echo "ERROR: resume configuration mismatch; expected '$expected_line' in $RESULT_DIR/config.txt" >&2
      exit 1
    fi
  done
  expected_header="new_order_percent,payment_percent,order_status_percent,delivery_percent,stock_level_percent,threads,run,tps,abort_rate,latency_ns,commits,aborts,log_file"
  if [[ "$(head -n 1 "$RESULT_DIR/results.csv")" != "$expected_header" ]]; then
    echo "ERROR: unexpected results.csv header in $RESULT_DIR/results.csv" >&2
    exit 1
  fi
else
  if [[ -e "$RESULT_DIR" ]]; then
    echo "ERROR: refusing to overwrite existing result directory: $RESULT_DIR" >&2
    exit 1
  fi
  mkdir -p "$RESULT_DIR"
fi

# Scale the non-New-Order mix from the standard 43:4:4:4 ratio. Largest-
# remainder rounding sums to 100; keep all four other types present when able.
allocate_transaction_mix() {
  local remaining=$((100 - $1)) weights=(43 4 4 4) alloc=() rem=()
  local assigned=0 left i best
  for ((i=0; i<4; i++)); do
    alloc[i]=$((remaining * weights[i] / 55))
    rem[i]=$((remaining * weights[i] % 55))
    assigned=$((assigned + alloc[i]))
  done
  left=$((remaining - assigned))
  while (( left > 0 )); do
    best=0
    for ((i=1; i<4; i++)); do
      if (( rem[i] > rem[best] )); then best=$i; fi
    done
    alloc[best]=$((alloc[best] + 1)); rem[best]=-1; left=$((left - 1))
  done
  if (( remaining >= 4 )); then
    for ((i=1; i<4; i++)); do
      if (( alloc[i] == 0 )); then
        if (( alloc[0] <= 1 )); then
          echo "ERROR: cannot retain every standard transaction type" >&2; exit 1
        fi
        alloc[i]=1
        alloc[0]=$((alloc[0] - 1))
      fi
    done
  fi
  PAYMENT_PERCENT=${alloc[0]}; ORDER_STATUS_PERCENT=${alloc[1]}
  DELIVERY_PERCENT=${alloc[2]}; STOCK_LEVEL_PERCENT=${alloc[3]}
  if (( PAYMENT_PERCENT + ORDER_STATUS_PERCENT + DELIVERY_PERCENT + STOCK_LEVEL_PERCENT + $1 != 100 )); then
    echo "ERROR: computed transaction mix does not sum to 100%" >&2; exit 1
  fi
}

total_runs=$((${#NEW_ORDER_VALUES[@]} * ${#THREAD_VALUES[@]} * REPEATS))
measurement_seconds=$((total_runs * EXTIME))
mkdir -p "$RAW_DIR"
if [[ "$RESUME" != true ]]; then
cat > "$RESULT_DIR/config.txt" <<EOF
binary=$BIN
warehouses=$WAREHOUSES (fixed across runs)
new_order_percentages=$NEW_ORDER_PERCENTAGES
threads=$THREADS
extime=$EXTIME
repeats=$REPEATS
non_new_order_ratio=payment:order_status:delivery:stock_level=43:4:4:4
percentage_rounding=largest_remainder; keep each non-New-Order type >=1% when possible
home_warehouse_assignment=random_per_transaction
hot_workload_flags=not passed (regular TPC-C item/supplier/district behavior)
remote_supplier_selection=standard TPC-C behavior
metis_paper_enable=false
ada_tam_enable=false
tpcc_retry_same_type=$RETRY_SAME_TYPE
compress_logs=$COMPRESS_LOGS
numactl_args=$NUMACTL_ARGS
numa_mode=$NUMA_MODE
run_timeout_sec=$RUN_TIMEOUT_SEC
total_runs=$total_runs
measurement_seconds_excluding_database_load=$measurement_seconds
started_at=$TIMESTAMP
EOF
echo "new_order_percent,payment_percent,order_status_percent,delivery_percent,stock_level_percent,threads,run,tps,abort_rate,latency_ns,commits,aborts,log_file" > "$RESULT_CSV"
fi
extract_scalar() {
  if [[ "$2" == *.gz ]]; then
    gzip -cd -- "$2" | awk -v key="$1" '$1 == key {print $2; exit}'
  else
    awk -v key="$1" '$1 == key {print $2; exit}' "$2"
  fi
}

echo "[CONFIG] warehouses=$WAREHOUSES; new-order percentages=$NEW_ORDER_PERCENTAGES" >&2
echo "[CONFIG] threads=$THREADS; repeats=$REPEATS; runs=$total_runs; NUMA=$NUMA_MODE" >&2
echo "[CONFIG] measurement time excluding DB loading: ${measurement_seconds}s" >&2
echo "[CONFIG] result directory: $RESULT_DIR" >&2
for new_order in "${NEW_ORDER_VALUES[@]}"; do
  allocate_transaction_mix "$new_order"
  for threads in "${THREAD_VALUES[@]}"; do
    for ((run=1; run<=REPEATS; run++)); do
      log_file="$RAW_DIR/neworder_${new_order}_threads_${threads}_run_${run}.log"
      if [[ "$COMPRESS_LOGS" == true ]]; then log_file+=".gz"; fi
      if [[ "$RESUME" == true ]] && awk -F, -v no="$new_order" -v th="$threads" -v rn="$run" \
        'NR>1 && $1==no && $6==th && $7==rn {found=1} END {exit(found ? 0 : 1)}' "$RESULT_CSV"; then
        echo "[SKIP] already recorded: NO=$new_order% threads=$threads run=$run/$REPEATS" >&2
        continue
      fi
      if [[ "$COMPRESS_LOGS" == true && -e "${log_file%.gz}" ]]; then
        mv -- "${log_file%.gz}" "${log_file%.gz}.incomplete.$(date +%Y%m%d_%H%M%S)"
      fi
      if [[ -e "$log_file" ]]; then
        mv -- "$log_file" "$log_file.incomplete.$(date +%Y%m%d_%H%M%S)"
      fi
      echo "[RUN] NO=$new_order% (P=$PAYMENT_PERCENT OS=$ORDER_STATUS_PERCENT D=$DELIVERY_PERCENT S=$STOCK_LEVEL_PERCENT) threads=$threads run=$run/$REPEATS" >&2
      command=("${BENCHMARK_CMD[@]}" "--thread_num=$threads" "--extime=$EXTIME" "--tpcc_num_wh=$WAREHOUSES"
        "--tpcc_perc_payment=$PAYMENT_PERCENT" "--tpcc_perc_order_status=$ORDER_STATUS_PERCENT"
        "--tpcc_perc_delivery=$DELIVERY_PERCENT" "--tpcc_perc_stock_level=$STOCK_LEVEL_PERCENT"
        "--tpcc_retry_same_type=$RETRY_SAME_TYPE"
        --tpcc_home_warehouse_assignment=random_per_transaction
        --ada_tam_enable=false --metis_paper_enable=false)
      status=0
      if (( RUN_TIMEOUT_SEC > 0 )); then
        if [[ "$COMPRESS_LOGS" == true ]]; then
          timeout --signal=TERM --kill-after=10s "${RUN_TIMEOUT_SEC}s" "${command[@]}" 2>&1 | gzip -c >"$log_file" || status=$?
        else
          timeout --signal=TERM --kill-after=10s "${RUN_TIMEOUT_SEC}s" "${command[@]}" >"$log_file" 2>&1 || status=$?
        fi
      else
        if [[ "$COMPRESS_LOGS" == true ]]; then
          "${command[@]}" 2>&1 | gzip -c >"$log_file" || status=$?
        else
          "${command[@]}" >"$log_file" 2>&1 || status=$?
        fi
      fi
      if (( status != 0 )); then
        echo "ERROR: benchmark failed with status $status: $log_file" >&2
        tail -n 50 "$log_file" >&2; exit "$status"
      fi
      tps=$(extract_scalar "throughput[tps]:" "$log_file")
      abort_rate=$(extract_scalar "abort_rate:" "$log_file")
      latency=$(extract_scalar "latency[ns]:" "$log_file")
      commits=$(extract_scalar "commit_counts_:" "$log_file")
      aborts=$(extract_scalar "abort_counts_:" "$log_file")
      for metric in tps abort_rate latency commits aborts; do
        if [[ -z "${!metric}" ]]; then
          echo "ERROR: could not parse $metric from $log_file" >&2
          tail -n 50 "$log_file" >&2; exit 1
        fi
      done
      echo "$new_order,$PAYMENT_PERCENT,$ORDER_STATUS_PERCENT,$DELIVERY_PERCENT,$STOCK_LEVEL_PERCENT,$threads,$run,$tps,$abort_rate,$latency,$commits,$aborts,$log_file" >> "$RESULT_CSV"
    done
  done
done

awk -F, 'BEGIN{OFS=",";print "new_order_percent,threads,runs,avg_tps,stddev_tps,avg_abort_rate,avg_latency_ns"}
NR>1{k=$1 SUBSEP $6;if(!(k in seen)){seen[k]=1;order[++n]=k}c[k]++;s[k]+=$8;ss[k]+=$8*$8;a[k]+=$9;l[k]+=$10}
END{for(i=1;i<=n;i++){k=order[i];split(k,f,SUBSEP);v=0;if(c[k]>1){v=(ss[k]-s[k]*s[k]/c[k])/(c[k]-1);if(v<0)v=0}printf "%s,%s,%d,%.2f,%.2f,%.6f,%.2f\n",f[1],f[2],c[k],s[k]/c[k],sqrt(v),a[k]/c[k],l[k]/c[k]}}' \
  "$RESULT_CSV" > "$SUMMARY_CSV"
awk -F, 'BEGIN{OFS=",";print "new_order_percent,best_threads,avg_tps,avg_abort_rate,avg_latency_ns"}
NR>1&&(!seen[$1]||$4>best[$1]){seen[$1]=1;best[$1]=$4;t[$1]=$2;a[$1]=$6;l[$1]=$7}
END{for(r in seen)printf "%s,%s,%.2f,%.6f,%.2f\n",r,t[r],best[r],a[r],l[r]}' \
  "$SUMMARY_CSV" > "$BEST_CSV"
echo "[DONE] raw results: $RESULT_CSV" >&2
echo "[DONE] summary: $SUMMARY_CSV" >&2
echo "[DONE] best threads: $BEST_CSV" >&2
