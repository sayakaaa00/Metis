#!/usr/bin/env bash
set -euo pipefail

# Find the best static worker count for each TPC-C hot-item ratio.
# Workload mix is fixed to:
#   New-Order 90%, Payment 7%, Order-Status 1%, Delivery 1%, Stock-Level 1%.
#
# The default thread candidates match Metis/LinUCB's actions (8..96, step 2).
# Use THREADS_OVERRIDE for a smaller smoke/coarse scan.

WAREHOUSES=${WAREHOUSES:-96}
EXTIME=${EXTIME:-5}
REPEATS=${REPEATS:-5}
HOT_ITEM_COUNT=${HOT_ITEM_COUNT:-100}
HOT_SUPPLY_WAREHOUSE_COUNT=${HOT_SUPPLY_WAREHOUSE_COUNT:-1}
RATIOS=${RATIOS:-"0.00 0.30 0.50 0.70 0.80 0.90 0.95 0.99"}
THREADS_OVERRIDE=${THREADS_OVERRIDE:-"8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64 66 68 70 72 74 76 78 80 82 84 86 88 90 92 94 96"}
NUMACTL_ARGS=${NUMACTL_ARGS:---interleave=all}
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-$((EXTIME + 300))}
RESUME=${RESUME:-false}

readonly TPCC_PERC_NEW_ORDER=90
readonly TPCC_PERC_PAYMENT=7
readonly TPCC_PERC_ORDER_STATUS=1
readonly TPCC_PERC_DELIVERY=1
readonly TPCC_PERC_STOCK_LEVEL=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_DIR=${RESULT_DIR:-"$SCRIPT_DIR/results/thread_sweep_neworder90_${TIMESTAMP}"}
RAW_DIR="$RESULT_DIR/logs"
RESULT_CSV="$RESULT_DIR/results.csv"
SUMMARY_CSV="$RESULT_DIR/summary.csv"
BEST_CSV="$RESULT_DIR/best_threads.csv"

read -r -a RATIO_VALUES <<< "$RATIOS"
read -r -a THREAD_VALUES <<< "$THREADS_OVERRIDE"
read -r -a NUMACTL_OPTIONS <<< "$NUMACTL_ARGS"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found: $BIN" >&2
  echo "Build it with: cmake --build build_release --target tpcc_metis_paper -j" >&2
  exit 1
fi
for command_name in numactl timeout awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done
if (( EXTIME < 1 || REPEATS < 1 || WAREHOUSES < 1 )); then
  echo "ERROR: EXTIME, REPEATS, and WAREHOUSES must be at least 1" >&2
  exit 1
fi
if (( HOT_ITEM_COUNT < 1 || HOT_ITEM_COUNT > 100000 )); then
  echo "ERROR: HOT_ITEM_COUNT must be in [1, 100000]" >&2
  exit 1
fi
if (( HOT_SUPPLY_WAREHOUSE_COUNT < 1 ||
      HOT_SUPPLY_WAREHOUSE_COUNT > WAREHOUSES )); then
  echo "ERROR: HOT_SUPPLY_WAREHOUSE_COUNT must be in [1, WAREHOUSES]" >&2
  exit 1
fi
if (( RUN_TIMEOUT_SEC <= EXTIME )); then
  echo "ERROR: RUN_TIMEOUT_SEC must be greater than EXTIME" >&2
  exit 1
fi
if (( ${#RATIO_VALUES[@]} == 0 || ${#THREAD_VALUES[@]} == 0 )); then
  echo "ERROR: RATIOS and THREADS_OVERRIDE must not be empty" >&2
  exit 1
fi

for ratio in "${RATIO_VALUES[@]}"; do
  if [[ ! "$ratio" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]]; then
    echo "ERROR: invalid hot-item ratio: $ratio" >&2
    exit 1
  fi
done
for threads in "${THREAD_VALUES[@]}"; do
  if [[ ! "$threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: invalid worker count: $threads" >&2
    exit 1
  fi
done

total_runs=$((${#RATIO_VALUES[@]} * ${#THREAD_VALUES[@]} * REPEATS))
measurement_seconds=$((total_runs * EXTIME))

mkdir -p "$RAW_DIR"

if [[ "$RESUME" == "true" && ! -f "$RESULT_CSV" ]]; then
  echo "ERROR: cannot resume; results CSV not found: $RESULT_CSV" >&2
  exit 1
fi
if [[ "$RESUME" != "true" || ! -f "$RESULT_DIR/config.txt" ]]; then
cat > "$RESULT_DIR/config.txt" <<EOF
binary=$BIN
warehouses=$WAREHOUSES
extime=$EXTIME
repeats=$REPEATS
hot_item_count=$HOT_ITEM_COUNT
hot_supply_warehouse_count=$HOT_SUPPLY_WAREHOUSE_COUNT
ratios=$RATIOS
thread_values=$THREADS_OVERRIDE
numactl_args=$NUMACTL_ARGS
run_timeout_sec=$RUN_TIMEOUT_SEC
tpcc_perc_new_order=$TPCC_PERC_NEW_ORDER
tpcc_perc_payment=$TPCC_PERC_PAYMENT
tpcc_perc_order_status=$TPCC_PERC_ORDER_STATUS
tpcc_perc_delivery=$TPCC_PERC_DELIVERY
tpcc_perc_stock_level=$TPCC_PERC_STOCK_LEVEL
tpcc_retry_same_type=true
ada_tam_enable=false
metis_paper_enable=false
total_runs=$total_runs
measurement_seconds_excluding_load=$measurement_seconds
started_at=$TIMESTAMP
EOF
fi

if [[ "$RESUME" != "true" || ! -f "$RESULT_CSV" ]]; then
  echo "timestamp,hot_item_ratio,threads,run,throughput_tps,abort_rate,latency_ns,commit_count,abort_count,neworder_commits,neworder_aborts,neworder_abort_rate,neworder_tps,maxrss_kb,log_file,neworder_commit_share,payment_commits,orderstatus_commits,delivery_commits,stocklevel_commits" > "$RESULT_CSV"
fi

extract_scalar() {
  local key=$1
  local log_file=$2
  awk -v key="$key" '$1 == key {print $2; exit}' "$log_file"
}

extract_tx_field() {
  local tx_type=$1
  local field=$2
  local log_file=$3
  awk -v tx_type="$tx_type" -v field="$field" '
    $0 == "  Transaction type: " tx_type { in_transaction=1; next }
    in_transaction && /^  Transaction type:/ { in_transaction=0 }
    in_transaction && field == "abort_rate" && $1 == "abort" && $2 == "rate:" {
      print $3;
      exit;
    }
    in_transaction && $1 == field { print $2; exit }
  ' "$log_file"
}

echo "[CONFIG] ratios=${#RATIO_VALUES[@]} thread_values=${#THREAD_VALUES[@]} repeats=$REPEATS total_runs=$total_runs" >&2
echo "[CONFIG] measurement time excluding DB load: ${measurement_seconds}s" >&2
echo "[CONFIG] result directory: $RESULT_DIR" >&2

for ratio in "${RATIO_VALUES[@]}"; do
  ratio_tag=${ratio//./p}
  for threads in "${THREAD_VALUES[@]}"; do
    for ((run=1; run<=REPEATS; run++)); do
      if [[ "$RESUME" == "true" ]] && awk -F',' -v ratio="$ratio" \
          -v threads="$threads" -v run="$run" \
          'NR > 1 && $2 == ratio && $3 == threads && $4 == run { found=1; exit } END { exit !found }' \
          "$RESULT_CSV"; then
        continue
      fi

      log_file=""
      if [[ "$RESUME" == "true" ]]; then
        shopt -s nullglob
        existing_logs=("$RAW_DIR/ratio_${ratio_tag}_threads_${threads}_run_${run}_"*.log)
        shopt -u nullglob
        for candidate_log in "${existing_logs[@]}"; do
          if [[ -n "$(extract_scalar "throughput[tps]:" "$candidate_log")" &&
                -n "$(extract_tx_field "NewOrder" "commits:" "$candidate_log")" ]]; then
            log_file=$candidate_log
            break
          fi
        done
      fi

      if [[ -z "$log_file" ]]; then
        run_timestamp=$(date +"%Y%m%d_%H%M%S")
        log_file="$RAW_DIR/ratio_${ratio_tag}_threads_${threads}_run_${run}_${run_timestamp}.log"
        echo "[RUN] ratio=$ratio threads=$threads run=$run/$REPEATS" >&2
        status=0
        timeout --signal=TERM --kill-after=10s "${RUN_TIMEOUT_SEC}s" \
          numactl "${NUMACTL_OPTIONS[@]}" "$BIN" \
            --thread_num="$threads" \
            --extime="$EXTIME" \
            --tpcc_num_wh="$WAREHOUSES" \
            --tpcc_perc_payment="$TPCC_PERC_PAYMENT" \
            --tpcc_perc_order_status="$TPCC_PERC_ORDER_STATUS" \
            --tpcc_perc_delivery="$TPCC_PERC_DELIVERY" \
            --tpcc_perc_stock_level="$TPCC_PERC_STOCK_LEVEL" \
            --tpcc_hot_item_count="$HOT_ITEM_COUNT" \
            --tpcc_hot_supply_warehouse_count="$HOT_SUPPLY_WAREHOUSE_COUNT" \
            --tpcc_hot_item_ratio="$ratio" \
            --tpcc_hot_item_stats=false \
            --tpcc_interactive_ms=0 \
            --tpcc_retry_same_type=true \
            --ada_tam_enable=false \
            --metis_paper_enable=false \
            >"$log_file" 2>&1 || status=$?
        if (( status != 0 )); then
          echo "ERROR: benchmark failed with status $status" >&2
          echo "       ratio=$ratio threads=$threads run=$run log=$log_file" >&2
          tail -n 40 "$log_file" >&2
          exit "$status"
        fi
      else
        echo "[RECOVER] ratio=$ratio threads=$threads run=$run from $log_file" >&2
        log_basename=${log_file##*/}
        run_timestamp=${log_basename%.log}
        run_timestamp=${run_timestamp##*_run_${run}_}
      fi

      throughput=$(extract_scalar "throughput[tps]:" "$log_file")
      abort_rate=$(extract_scalar "abort_rate:" "$log_file")
      latency=$(extract_scalar "latency[ns]:" "$log_file")
      commits=$(extract_scalar "commit_counts_:" "$log_file")
      aborts=$(extract_scalar "abort_counts_:" "$log_file")
      maxrss_kb=$(extract_scalar "maxrss:" "$log_file")
      neworder_commits=$(extract_tx_field "NewOrder" "commits:" "$log_file")
      neworder_aborts=$(extract_tx_field "NewOrder" "aborts:" "$log_file")
      neworder_abort_rate=$(extract_tx_field "NewOrder" "abort_rate" "$log_file")
      payment_commits=$(extract_tx_field "Payment" "commits:" "$log_file")
      orderstatus_commits=$(extract_tx_field "OrderStatus" "commits:" "$log_file")
      delivery_commits=$(extract_tx_field "Delivery" "commits:" "$log_file")
      stocklevel_commits=$(extract_tx_field "StockLevel" "commits:" "$log_file")

      for value_name in throughput abort_rate latency commits aborts maxrss_kb \
                        neworder_commits neworder_aborts neworder_abort_rate \
                        payment_commits orderstatus_commits delivery_commits \
                        stocklevel_commits; do
        if [[ -z "${!value_name}" ]]; then
          echo "ERROR: failed to parse $value_name from $log_file" >&2
          exit 1
        fi
      done

      neworder_tps=$(awk -v commits="$neworder_commits" -v seconds="$EXTIME" \
        'BEGIN { printf "%.6f", commits / seconds }')
      neworder_commit_share=$(awk -v neworder="$neworder_commits" \
        -v total="$commits" \
        'BEGIN { if (total == 0) print "0.000000"; else printf "%.6f", neworder / total }')

      echo "$run_timestamp,$ratio,$threads,$run,$throughput,$abort_rate,$latency,$commits,$aborts,$neworder_commits,$neworder_aborts,$neworder_abort_rate,$neworder_tps,$maxrss_kb,$log_file,$neworder_commit_share,$payment_commits,$orderstatus_commits,$delivery_commits,$stocklevel_commits" >> "$RESULT_CSV"
    done
  done
done

awk -F',' '
  BEGIN {
    OFS=",";
    print "hot_item_ratio,threads,runs,avg_throughput_tps,stddev_throughput_tps,min_throughput_tps,max_throughput_tps,avg_abort_rate,avg_latency_ns,avg_neworder_tps,stddev_neworder_tps,avg_neworder_abort_rate,avg_maxrss_kb,avg_neworder_commit_share";
  }
  NR > 1 {
    key=$2 SUBSEP $3;
    if (!(key in seen)) {
      seen[key]=1;
      order[++n]=key;
      min_tps[key]=$5;
      max_tps[key]=$5;
    }
    count[key]++;
    sum_tps[key]+=$5;
    sumsq_tps[key]+=$5*$5;
    if ($5 < min_tps[key]) min_tps[key]=$5;
    if ($5 > max_tps[key]) max_tps[key]=$5;
    sum_abort[key]+=$6;
    sum_latency[key]+=$7;
    sum_neworder_tps[key]+=$13;
    sumsq_neworder_tps[key]+=$13*$13;
    sum_neworder_abort[key]+=$12;
    sum_maxrss[key]+=$14;
    sum_neworder_share[key]+=$16;
  }
  END {
    for (i=1; i<=n; i++) {
      key=order[i];
      split(key, fields, SUBSEP);
      ratio=fields[1];
      threads=fields[2];
      runs=count[key];
      avg_tps=sum_tps[key]/runs;
      avg_neworder_tps=sum_neworder_tps[key]/runs;
      if (runs > 1) {
        var_tps=(sumsq_tps[key]-(sum_tps[key]*sum_tps[key]/runs))/(runs-1);
        var_neworder=(sumsq_neworder_tps[key]-(sum_neworder_tps[key]*sum_neworder_tps[key]/runs))/(runs-1);
        if (var_tps < 0) var_tps=0;
        if (var_neworder < 0) var_neworder=0;
        std_tps=sqrt(var_tps);
        std_neworder=sqrt(var_neworder);
      } else {
        std_tps=0;
        std_neworder=0;
      }
      printf "%s,%d,%d,%.3f,%.3f,%.3f,%.3f,%.6f,%.3f,%.3f,%.3f,%.6f,%.3f,%.6f\n",
             ratio, threads, runs, avg_tps, std_tps, min_tps[key], max_tps[key],
             sum_abort[key]/runs, sum_latency[key]/runs,
             avg_neworder_tps, std_neworder,
             sum_neworder_abort[key]/runs, sum_maxrss[key]/runs,
             sum_neworder_share[key]/runs;
    }
  }
' "$RESULT_CSV" > "$SUMMARY_CSV"

awk -F',' '
  BEGIN {
    OFS=",";
    print "hot_item_ratio,best_threads_by_throughput,avg_throughput_tps,stddev_throughput_tps,avg_abort_rate,best_threads_by_neworder_tps,avg_neworder_tps,stddev_neworder_tps,avg_neworder_abort_rate";
  }
  NR > 1 {
    ratio=$1;
    threads=$2+0;
    if (!(ratio in seen_ratio)) {
      seen_ratio[ratio]=1;
      ratio_order[++n]=ratio;
    }
    if (!(ratio in best_tps) || $4 > best_tps[ratio] ||
        ($4 == best_tps[ratio] && threads < best_tps_threads[ratio])) {
      best_tps[ratio]=$4;
      best_tps_threads[ratio]=threads;
      best_tps_std[ratio]=$5;
      best_tps_abort[ratio]=$8;
    }
    if (!(ratio in best_neworder) || $10 > best_neworder[ratio] ||
        ($10 == best_neworder[ratio] && threads < best_neworder_threads[ratio])) {
      best_neworder[ratio]=$10;
      best_neworder_threads[ratio]=threads;
      best_neworder_std[ratio]=$11;
      best_neworder_abort[ratio]=$12;
    }
  }
  END {
    for (i=1; i<=n; i++) {
      ratio=ratio_order[i];
      printf "%s,%d,%.3f,%.3f,%.6f,%d,%.3f,%.3f,%.6f\n",
             ratio,
             best_tps_threads[ratio], best_tps[ratio], best_tps_std[ratio],
             best_tps_abort[ratio],
             best_neworder_threads[ratio], best_neworder[ratio],
             best_neworder_std[ratio], best_neworder_abort[ratio];
    }
  }
' "$SUMMARY_CSV" > "$BEST_CSV"

echo "[DONE] raw logs: $RAW_DIR" >&2
echo "[DONE] per-run results: $RESULT_CSV" >&2
echo "[DONE] per-thread summary: $SUMMARY_CSV" >&2
echo "[DONE] best threads per ratio: $BEST_CSV" >&2
