#!/usr/bin/env bash
set -euo pipefail

# Static-thread TPC-C sweep controlled only by warehouse count.
# Hot-item/warehouse/district workload extensions are intentionally omitted.
WAREHOUSES=${WAREHOUSES:-"512 256 128 64 32 16"}
THREADS=${THREADS:-"8 12 16 20 24 28 32 36 40 44 48"}
EXTIME=${EXTIME:-5}
REPEATS=${REPEATS:-2}
NUMACTL_ARGS=${NUMACTL_ARGS:---interleave=all}
RUN_TIMEOUT_SEC=${RUN_TIMEOUT_SEC:-0}

# New-Order is the remaining % of the transaction mix.
readonly TPCC_PERC_PAYMENT=30
readonly TPCC_PERC_ORDER_STATUS=1
readonly TPCC_PERC_DELIVERY=1
readonly TPCC_PERC_STOCK_LEVEL=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_DIR=${RESULT_DIR:-"$SCRIPT_DIR/results/warehouse_contention_sweep_${TIMESTAMP}"}
RAW_DIR="$RESULT_DIR/logs"
RAW_CSV="$RESULT_DIR/runs.csv"
MEAN_CSV="$RESULT_DIR/means.csv"
BEST_CSV="$RESULT_DIR/best_threads.csv"

read -r -a WAREHOUSE_VALUES <<< "$WAREHOUSES"
read -r -a THREAD_VALUES <<< "$THREADS"
read -r -a NUMACTL_OPTIONS <<< "$NUMACTL_ARGS"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found: $BIN" >&2
  echo "Build it with: cmake --build build_release --target tpcc_metis_paper -j" >&2
  exit 1
fi
for command_name in numactl gzip awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done
if (( RUN_TIMEOUT_SEC > 0 )) && ! command -v timeout >/dev/null 2>&1; then
  echo "ERROR: RUN_TIMEOUT_SEC requires the timeout command" >&2
  exit 1
fi
if (( EXTIME < 1 || REPEATS < 1 || RUN_TIMEOUT_SEC < 0 )); then
  echo "ERROR: EXTIME and REPEATS must be positive; RUN_TIMEOUT_SEC must be non-negative" >&2
  exit 1
fi
if (( ${#WAREHOUSE_VALUES[@]} == 0 || ${#THREAD_VALUES[@]} == 0 )); then
  echo "ERROR: WAREHOUSES and THREADS must not be empty" >&2
  exit 1
fi
for warehouses in "${WAREHOUSE_VALUES[@]}"; do
  if [[ ! "$warehouses" =~ ^[0-9]+$ ]] || (( warehouses < 1 )); then
    echo "ERROR: invalid warehouse count: $warehouses" >&2
    exit 1
  fi
done
for threads in "${THREAD_VALUES[@]}"; do
  if [[ ! "$threads" =~ ^[0-9]+$ ]] || (( threads < 1 )); then
    echo "ERROR: invalid thread count: $threads" >&2
    exit 1
  fi
done

mkdir -p "$RAW_DIR"
cat > "$RESULT_DIR/config.txt" <<EOF
binary=$BIN
warehouses=$WAREHOUSES
threads=$THREADS
extime=$EXTIME
repeats=$REPEATS
new_order_percent=90
payment_percent=$TPCC_PERC_PAYMENT
order_status_percent=$TPCC_PERC_ORDER_STATUS
delivery_percent=$TPCC_PERC_DELIVERY
stock_level_percent=$TPCC_PERC_STOCK_LEVEL
home_warehouse_assignment=random_per_transaction
numactl_args=$NUMACTL_ARGS
metis=false
tam=false
hot_workload_flags=not_passed
retry_same_type=false
EOF
echo "warehouse,threads,run,tps,abort_rate,latency_ns,commits,aborts,log_file" > "$RAW_CSV"

extract_scalar() {
  awk -v key="$1" '$1 == key {print $2; exit}' "$2"
}

total_runs=$((${#WAREHOUSE_VALUES[@]} * ${#THREAD_VALUES[@]} * REPEATS))
echo "[CONFIG] runs=$total_runs, measurement seconds=$((total_runs * EXTIME)) (excluding DB load)" >&2
echo "[CONFIG] result directory: $RESULT_DIR" >&2

for warehouses in "${WAREHOUSE_VALUES[@]}"; do
  for threads in "${THREAD_VALUES[@]}"; do
    for ((run=1; run<=REPEATS; run++)); do
      raw_log="$RAW_DIR/warehouses_${warehouses}_threads_${threads}_run_${run}.log"
      echo "[RUN] warehouses=$warehouses threads=$threads run=$run/$REPEATS" >&2
      command=(numactl "${NUMACTL_OPTIONS[@]}" "$BIN"
        "--thread_num=$threads"
        "--extime=$EXTIME"
        "--tpcc_num_wh=$warehouses"
        "--tpcc_perc_payment=$TPCC_PERC_PAYMENT"
        "--tpcc_perc_order_status=$TPCC_PERC_ORDER_STATUS"
        "--tpcc_perc_delivery=$TPCC_PERC_DELIVERY"
        "--tpcc_perc_stock_level=$TPCC_PERC_STOCK_LEVEL"
        --tpcc_home_warehouse_assignment=random_per_transaction
        --tpcc_retry_same_type=false
        --ada_tam_enable=false
        --metis_paper_enable=false)

      status=0
      if (( RUN_TIMEOUT_SEC > 0 )); then
        timeout --signal=TERM --kill-after=30s "${RUN_TIMEOUT_SEC}s" \
          "${command[@]}" >"$raw_log" 2>&1 || status=$?
      else
        "${command[@]}" >"$raw_log" 2>&1 || status=$?
      fi
      if (( status != 0 )); then
        echo "ERROR: benchmark failed with status $status: $raw_log" >&2
        tail -n 50 "$raw_log" >&2
        exit "$status"
      fi

      tps=$(extract_scalar "throughput[tps]:" "$raw_log")
      abort_rate=$(extract_scalar "abort_rate:" "$raw_log")
      latency=$(extract_scalar "latency[ns]:" "$raw_log")
      commits=$(extract_scalar "commit_counts_:" "$raw_log")
      aborts=$(extract_scalar "abort_counts_:" "$raw_log")
      if [[ -z "$tps" || -z "$abort_rate" || -z "$latency" ]]; then
        echo "ERROR: could not parse benchmark metrics: $raw_log" >&2
        tail -n 50 "$raw_log" >&2
        exit 1
      fi

      gzip -f "$raw_log"
      log_file="$raw_log.gz"
      echo "$warehouses,$threads,$run,$tps,$abort_rate,$latency,$commits,$aborts,$log_file" >> "$RAW_CSV"
    done
  done
done

echo "warehouse,threads,runs,mean_tps,mean_abort_rate,mean_latency_ns,mean_commits,mean_aborts" > "$MEAN_CSV"
for warehouses in "${WAREHOUSE_VALUES[@]}"; do
  for threads in "${THREAD_VALUES[@]}"; do
    awk -F, -v w="$warehouses" -v t="$threads" '
      NR > 1 && $1 == w && $2 == t {
        n++;
        tps += $4;
        abort_rate += $5;
        latency += $6;
        commits += $7;
        aborts += $8;
      }
      END {
        if (n > 0) {
          printf "%s,%s,%d,%.2f,%.6f,%.2f,%.2f,%.2f\n",
                 w, t, n, tps / n, abort_rate / n, latency / n,
                 commits / n, aborts / n;
        }
      }
    ' "$RAW_CSV" >> "$MEAN_CSV"
  done
done

echo "warehouse,best_threads,mean_tps,mean_abort_rate,mean_latency_ns" > "$BEST_CSV"
for warehouses in "${WAREHOUSE_VALUES[@]}"; do
  awk -F, -v w="$warehouses" '
    NR > 1 && $1 == w {
      if (!found || $4 > best_tps) {
        found = 1;
        best_threads = $2;
        best_tps = $4;
        best_abort_rate = $5;
        best_latency = $6;
      }
    }
    END {
      if (found) {
        printf "%s,%s,%.2f,%.6f,%.2f\n", w, best_threads, best_tps,
               best_abort_rate, best_latency;
      }
    }
  ' "$MEAN_CSV" >> "$BEST_CSV"
done

echo "[DONE] raw runs: $RAW_CSV" >&2
echo "[DONE] per-thread means: $MEAN_CSV" >&2
echo "[DONE] best threads per warehouse: $BEST_CSV" >&2
