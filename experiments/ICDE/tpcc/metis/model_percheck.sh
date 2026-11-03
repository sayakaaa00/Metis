#!/usr/bin/env bash
set -euo pipefail

# Evaluate the matching held-out model on one active-warehouse contention state.
WAREHOUSES=${WAREHOUSES:-96}
THREADS=${THREADS:-96}
EXTIME=${EXTIME:-30}
REPEATS=${REPEATS:-3}
ACTIVE_WAREHOUSES=${ACTIVE_WAREHOUSES:-"1 4 16 32 96"}
TARGET_ACTIVE_WAREHOUSES=${TARGET_ACTIVE_WAREHOUSES:-16}
UPDATE_PERIOD_US=${UPDATE_PERIOD_US:-10000}
TAM_LOG_PERIOD_US=${TAM_LOG_PERIOD_US:-10000}
TAM_MIN_THREADS=${TAM_MIN_THREADS:-1}
TAM_MAX_THREADS=${TAM_MAX_THREADS:-$THREADS}
LINUCB_ALPHA=${LINUCB_ALPHA:-1.0}
LINUCB_LAMBDA=${LINUCB_LAMBDA:-1.0}
HOME_WAREHOUSE_ASSIGNMENT=${HOME_WAREHOUSE_ASSIGNMENT:-randomized_worker_affined}
HOME_WAREHOUSE_SEED=${HOME_WAREHOUSE_SEED:-1}
MODEL_VERSION=${MODEL_VERSION:-randomized_worker_affined_test_v1}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TARGET_TAG=$TARGET_ACTIVE_WAREHOUSES
MODEL_BASENAME=${MODEL_BASENAME:-"linucb_active_wh_${TARGET_TAG}.txt"}
MODEL_PATH="$SCRIPT_DIR/models/$MODEL_VERSION/$MODEL_BASENAME"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$SCRIPT_DIR/logs/percheck/$MODEL_VERSION/target_${TARGET_TAG}_$TIMESTAMP"

read -r -a ACTIVE_WAREHOUSE_VALUES <<< "$ACTIVE_WAREHOUSES"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found or not executable: $BIN" >&2; exit 1
fi
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "ERROR: model not found: $MODEL_PATH" >&2
  echo "Train it first with model_learning.sh using this MODEL_VERSION and TARGET_ACTIVE_WAREHOUSES." >&2
  exit 1
fi
if [[ "$(head -n 1 "$MODEL_PATH")" != "linucb_abs_model_v2" ]]; then
  echo "ERROR: invalid or unsupported Metis model: $MODEL_PATH" >&2; exit 1
fi
if (( WAREHOUSES < 1 || THREADS < 1 || REPEATS < 1 )); then
  echo "ERROR: WAREHOUSES, THREADS, REPEATS must be positive" >&2; exit 1
fi
if (( TARGET_ACTIVE_WAREHOUSES < 1 || TARGET_ACTIVE_WAREHOUSES > WAREHOUSES )); then
  echo "ERROR: TARGET_ACTIVE_WAREHOUSES must be within [1, WAREHOUSES]" >&2; exit 1
fi
target_found=false
for active_warehouses in "${ACTIVE_WAREHOUSE_VALUES[@]}"; do
  if [[ ! "$active_warehouses" =~ ^[1-9][0-9]*$ ]] || (( active_warehouses > WAREHOUSES )); then
    echo "ERROR: active warehouse count must be an integer in [1, $WAREHOUSES]: $active_warehouses" >&2; exit 1
  fi
  if [[ "$active_warehouses" == "$TARGET_ACTIVE_WAREHOUSES" ]]; then
    target_found=true
  fi
done
if [[ "$target_found" != true ]]; then
  echo "ERROR: TARGET_ACTIVE_WAREHOUSES=$TARGET_ACTIVE_WAREHOUSES must appear in ACTIVE_WAREHOUSES='$ACTIVE_WAREHOUSES'" >&2; exit 1
fi
mkdir -p "$LOG_DIR"
cat > "$LOG_DIR/config.txt" <<EOF
binary=$BIN
model_path=$MODEL_PATH
database_warehouses=$WAREHOUSES
total_threads=$THREADS
extime_seconds_per_run=$EXTIME
repeats=$REPEATS
active_warehouse_states=$ACTIVE_WAREHOUSES
target_active_warehouses=$TARGET_ACTIVE_WAREHOUSES
home_warehouse_assignment=$HOME_WAREHOUSE_ASSIGNMENT
home_warehouse_seed=$HOME_WAREHOUSE_SEED
home_warehouses_per_thread_average=active_warehouses / total_threads
workers_per_home_warehouse_average=total_threads / active_warehouses
tpcc_mix=not passed (TPC-C defaults: New-Order 45, Payment 43, Order-Status 4, Delivery 4, Stock-Level 4)
tpcc_retry_same_type=not passed (default true)
tpcc_hot_*_flags=not passed (defaults disabled)
active_warehouse_count=$TARGET_ACTIVE_WAREHOUSES
metis_paper_enable=true
ada_tam=false (default)
numa_policy=not set (no numactl)
model_autosave=false
update_period_us=$UPDATE_PERIOD_US
tam_min_threads=$TAM_MIN_THREADS
tam_max_threads=$TAM_MAX_THREADS
linucb_alpha=$LINUCB_ALPHA
linucb_lambda=$LINUCB_LAMBDA
EOF

echo "[CONFIG] target_active_warehouses=$TARGET_ACTIVE_WAREHOUSES threads=$THREADS repeats=$REPEATS model=$MODEL_PATH" >&2
echo "[CONFIG] result logs: $LOG_DIR" >&2
run_metric_rows=""

extract_scalar() {
  awk -v key="$1" '$1 == key { value = $2 } END { if (value != "") print value }' "$2"
}

for ((run_id=1; run_id<=REPEATS; run_id++)); do
  log_file="$LOG_DIR/run_${run_id}.log"
  echo "[RUN] target_active_warehouses=$TARGET_ACTIVE_WAREHOUSES run=$run_id/$REPEATS" >&2
  "$BIN" \
    --thread_num="$THREADS" --extime="$EXTIME" --tpcc_num_wh="$WAREHOUSES" \
    --tpcc_active_warehouse_count="$TARGET_ACTIVE_WAREHOUSES" \
    --tpcc_home_warehouse_assignment="$HOME_WAREHOUSE_ASSIGNMENT" \
    --tpcc_home_warehouse_seed="$HOME_WAREHOUSE_SEED" \
    --metis_paper_enable=true \
    --tam_update_period_us="$UPDATE_PERIOD_US" \
    --tam_log_period_us="$TAM_LOG_PERIOD_US" \
    --tam_min_threads="$TAM_MIN_THREADS" --tam_max_threads="$TAM_MAX_THREADS" \
    --tam_log_active_threads=true --linucb_alpha="$LINUCB_ALPHA" \
    --linucb_lambda="$LINUCB_LAMBDA" \
    --linucb_model_path="$MODEL_PATH" --linucb_model_autosave=false \
    --linucb_abs_ignore_initial_steps=1 2>&1 | tee "$log_file" | sed '/insert order failed/d'

  active_log_path=$(awk -F': ' '/TAM active_threads logs will be written to:/ {
    path = $2
    sub(/^"/, "", path)
    sub(/"$/, "", path)
    print path
    exit
  }' "$log_file")
  if [[ -n "$active_log_path" && -f "$active_log_path" ]]; then
    cp "$active_log_path" "$LOG_DIR/active_threads_run_${run_id}.log"
    echo "[SAVED] active-thread log: $LOG_DIR/active_threads_run_${run_id}.log" >&2
  else
    echo "[WARN] no active-thread log path found in $log_file" >&2
  fi

  tps=$(extract_scalar "throughput[tps]:" "$log_file")
  abort_rate=$(extract_scalar "abort_rate:" "$log_file")
  latency_ns=$(extract_scalar "latency[ns]:" "$log_file")
  commits=$(extract_scalar "commit_counts_:" "$log_file")
  aborts=$(extract_scalar "abort_counts_:" "$log_file")
  if [[ -z "$tps" || -z "$abort_rate" || -z "$latency_ns" || -z "$commits" || -z "$aborts" ]]; then
    echo "ERROR: could not extract benchmark metrics from $log_file" >&2
    tail -n 50 "$log_file" >&2
    exit 1
  fi
  run_metric_rows+="$run_id,$tps,$abort_rate,$latency_ns,$commits,$aborts"$'\n'
done

summary_row=$(printf '%s' "$run_metric_rows" | awk -F, \
  -v target="$TARGET_ACTIVE_WAREHOUSES" \
  -v threads="$THREADS" \
  -v warehouses="$WAREHOUSES" \
  -v expected="$REPEATS" '
  NF == 6 {
    runs++
    tps += $2
    abort_rate += $3
    latency_ns += $4
    commits += $5
    aborts += $6
  }
  END {
    if (runs != expected) {
      printf "ERROR: expected %d run metrics, found %d\n", expected, runs > "/dev/stderr"
      exit 1
    }
    printf "%s,%s,%s,%d,%.2f,%.6f,%.2f,%.2f,%.2f\n", \
      target, threads, warehouses, runs, tps / runs, abort_rate / runs, \
      latency_ns / runs, commits / runs, aborts / runs
  }')
summary_csv="$LOG_DIR/summary.csv"
{
  echo "active_warehouses,total_threads,database_warehouses,runs,mean_tps,mean_abort_rate,mean_latency_ns,mean_commits,mean_aborts"
  printf '%s\n' "$summary_row"
} > "$summary_csv"

echo "[SAVED] summary: $summary_csv" >&2
echo "[DONE] performance logs/config: $LOG_DIR" >&2
