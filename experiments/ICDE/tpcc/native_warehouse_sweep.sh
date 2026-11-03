#!/usr/bin/env bash
set -euo pipefail

# Native-default TPC-C sweep. The database always contains 96 warehouses;
# active warehouse count controls the logical terminal home-warehouse range.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

TOTAL_THREADS=${TOTAL_THREADS:?Set TOTAL_THREADS (positive integer list)}
ACTIVE_WAREHOUSES=${ACTIVE_WAREHOUSES:?Set ACTIVE_WAREHOUSES (positive integer list from 1 to 96)}
readonly WAREHOUSES=96
EXTIME=${EXTIME:-5}
REPEATS=${REPEATS:-2}
HOME_WAREHOUSE_ASSIGNMENT=${HOME_WAREHOUSE_ASSIGNMENT:-worker_affined}
HOME_WAREHOUSE_SEED=${HOME_WAREHOUSE_SEED:-1}
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_DIR=${RESULT_DIR:-"$SCRIPT_DIR/results/active_warehouse_sweep_${TIMESTAMP}"}
LOG_DIR="$RESULT_DIR/logs"
RESULTS_CSV="$RESULT_DIR/results.csv"
SUMMARY_CSV="$RESULT_DIR/summary.csv"
CONFIG_FILE="$RESULT_DIR/config.txt"
SKIPPED_CSV="$RESULT_DIR/skipped.csv"

read -r -a TOTAL_THREAD_VALUES <<< "${TOTAL_THREADS//$'\n'/ }"
read -r -a ACTIVE_WAREHOUSE_VALUES <<< "${ACTIVE_WAREHOUSES//$'\n'/ }"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found or not executable: $BIN" >&2
  echo "Build it with: cmake --build build_release --target tpcc_metis_paper -j" >&2
  exit 1
fi
if ! command -v gzip >/dev/null 2>&1; then
  echo "ERROR: gzip is required to compress benchmark logs" >&2
  exit 1
fi
if (( EXTIME < 1 || REPEATS < 1 || ${#TOTAL_THREAD_VALUES[@]} == 0 || ${#ACTIVE_WAREHOUSE_VALUES[@]} == 0 )); then
  echo "ERROR: EXTIME and REPEATS must be positive; thread lists must not be empty" >&2
  exit 1
fi
for total_threads in "${TOTAL_THREAD_VALUES[@]}"; do
  if [[ ! "$total_threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: invalid total thread count: $total_threads" >&2
    exit 1
  fi
done
for active_warehouses in "${ACTIVE_WAREHOUSE_VALUES[@]}"; do
  if [[ ! "$active_warehouses" =~ ^[1-9][0-9]*$ ]] || (( active_warehouses > WAREHOUSES )); then
    echo "ERROR: active warehouse count must be an integer in [1, $WAREHOUSES]: $active_warehouses" >&2
    exit 1
  fi
done
if [[ -e "$RESULT_DIR" ]]; then
  echo "ERROR: result directory already exists: $RESULT_DIR" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
cat > "$CONFIG_FILE" <<EOF
binary=$BIN
total_threads=$TOTAL_THREADS
database_warehouses=$WAREHOUSES (fixed)
active_warehouses=$ACTIVE_WAREHOUSES
home_warehouse_assignment=$HOME_WAREHOUSE_ASSIGNMENT
home_warehouse_seed=$HOME_WAREHOUSE_SEED
home_warehouses_per_thread_average=active_warehouses / total_threads
workers_per_home_warehouse_average=total_threads / active_warehouses
extime=$EXTIME
repeats=$REPEATS
tpcc_mix=not passed (TPC-C defaults: New-Order 45, Payment 43, Order-Status 4, Delivery 4, Stock-Level 4)
tpcc_retry_same_type=not passed (default true)
tpcc_hot_*_flags=not passed (defaults disabled)
metis=false (default)
ada_tam=false (default)
numa_policy=not set (no numactl)
EOF
echo "total_threads,active_warehouses,home_warehouses_per_thread_avg,workers_per_home_warehouse_avg,database_warehouses,run,tps,abort_rate,latency_ns,commits,aborts,log_file" > "$RESULTS_CSV"
echo "total_threads,active_warehouses,reason" > "$SKIPPED_CSV"

extract_scalar() {
  awk -v key="$1" '$1 == key && !found { print $2; found=1 }' "$2"
}

total_runs=$((${#TOTAL_THREAD_VALUES[@]} * ${#ACTIVE_WAREHOUSE_VALUES[@]} * REPEATS))
echo "[CONFIG] runs=$total_runs; measurement time=$((total_runs * EXTIME)) sec (excluding database loading)" >&2
echo "[CONFIG] result directory: $RESULT_DIR" >&2

for total_threads in "${TOTAL_THREAD_VALUES[@]}"; do
  for active_warehouses in "${ACTIVE_WAREHOUSE_VALUES[@]}"; do
    home_warehouses_per_thread_avg=$(awk -v a="$active_warehouses" -v t="$total_threads" 'BEGIN { printf "%.6f", a / t }')
    workers_per_home_warehouse_avg=$(awk -v t="$total_threads" -v a="$active_warehouses" 'BEGIN { printf "%.6f", t / a }')
    for ((run = 1; run <= REPEATS; run++)); do
      raw_log="$LOG_DIR/threads_${total_threads}_active_warehouses_${active_warehouses}_run_${run}.log"
      echo "[RUN] total_threads=$total_threads active_warehouses=$active_warehouses home_warehouses_per_thread_avg=$home_warehouses_per_thread_avg workers_per_home_warehouse_avg=$workers_per_home_warehouse_avg database_warehouses=$WAREHOUSES run=$run/$REPEATS" >&2

      # Database size stays at 96; active_warehouse_count affects only home
      # logical terminal home-warehouse routing. Other workload features stay
      # at defaults. When active warehouses exceed workers, each worker cycles
      # among its assigned homes only after a successful transaction.
      "$BIN" \
        "--thread_num=$total_threads" \
        "--extime=$EXTIME" \
        "--tpcc_num_wh=$WAREHOUSES" \
        "--tpcc_active_warehouse_count=$active_warehouses" \
        "--tpcc_home_warehouse_assignment=$HOME_WAREHOUSE_ASSIGNMENT" \
        "--tpcc_home_warehouse_seed=$HOME_WAREHOUSE_SEED" \
        >"$raw_log" 2>&1

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
      echo "$total_threads,$active_warehouses,$home_warehouses_per_thread_avg,$workers_per_home_warehouse_avg,$WAREHOUSES,$run,$tps,$abort_rate,$latency,$commits,$aborts,$raw_log.gz" >> "$RESULTS_CSV"
    done
  done
done

echo "total_threads,active_warehouses,home_warehouses_per_thread_avg,workers_per_home_warehouse_avg,database_warehouses,runs,mean_tps,mean_abort_rate,mean_latency_ns" > "$SUMMARY_CSV"
for total_threads in "${TOTAL_THREAD_VALUES[@]}"; do
  for active_warehouses in "${ACTIVE_WAREHOUSE_VALUES[@]}"; do
    home_warehouses_per_thread_avg=$(awk -v a="$active_warehouses" -v t="$total_threads" 'BEGIN { printf "%.6f", a / t }')
    workers_per_home_warehouse_avg=$(awk -v t="$total_threads" -v a="$active_warehouses" 'BEGIN { printf "%.6f", t / a }')
    awk -F, -v t="$total_threads" -v a="$active_warehouses" -v hp="$home_warehouses_per_thread_avg" -v wp="$workers_per_home_warehouse_avg" -v w="$WAREHOUSES" '
    NR > 1 && $1 == t && $2 == a && $3 == hp && $4 == wp && $5 == w { n++; tps += $7; abort_rate += $8; latency += $9 }
    END {
      if (n > 0) printf "%s,%s,%s,%s,%s,%d,%.2f,%.6f,%.2f\n", t, a, hp, wp, w, n,
                    tps / n, abort_rate / n, latency / n
    }
  ' "$RESULTS_CSV" >> "$SUMMARY_CSV"
  done
done

echo "[DONE] results: $RESULTS_CSV" >&2
echo "[DONE] summary: $SUMMARY_CSV" >&2
echo "[DONE] skipped combinations: none (see empty $SKIPPED_CSV)" >&2
