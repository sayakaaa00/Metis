#!/usr/bin/env bash
set -euo pipefail

# Train one model for a held-out active-warehouse contention state.
WAREHOUSES=${WAREHOUSES:-96}
THREADS=${THREADS:-96}
EXTIME=${EXTIME:-20}
ACTIVE_WAREHOUSES=${ACTIVE_WAREHOUSES:-"1 4 16 32 96"}
TARGET_ACTIVE_WAREHOUSES=${TARGET_ACTIVE_WAREHOUSES:-16}
RUNS_PER_STATE=${RUNS_PER_STATE:-${RUNS_PER_RATIO:-3}}
UPDATE_PERIOD_US=${UPDATE_PERIOD_US:-10000}
TAM_MIN_THREADS=${TAM_MIN_THREADS:-1}
TAM_MAX_THREADS=${TAM_MAX_THREADS:-$THREADS}
LINUCB_ALPHA=${LINUCB_ALPHA:-1.0}
LINUCB_LAMBDA=${LINUCB_LAMBDA:-1.0}
HOME_WAREHOUSE_ASSIGNMENT=${HOME_WAREHOUSE_ASSIGNMENT:-randomized_worker_affined}
HOME_WAREHOUSE_SEED=${HOME_WAREHOUSE_SEED:-1}
MIN_PULLS_PER_ACTION=${MIN_PULLS_PER_ACTION:-10}
MODEL_VERSION=${MODEL_VERSION:-randomized_worker_affined_test_v1}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TARGET_TAG=$TARGET_ACTIVE_WAREHOUSES
MODEL_BASENAME=${MODEL_BASENAME:-"linucb_active_wh_${TARGET_TAG}.txt"}
MODEL_DIR="$SCRIPT_DIR/models/$MODEL_VERSION"
MODEL_PATH="$MODEL_DIR/$MODEL_BASENAME"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$SCRIPT_DIR/logs/train/$MODEL_VERSION/target_${TARGET_TAG}_$TIMESTAMP"

read -r -a ACTIVE_WAREHOUSE_VALUES <<< "$ACTIVE_WAREHOUSES"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: benchmark binary not found or not executable: $BIN" >&2
  echo "Build with: cmake --build build_release --target tpcc_metis_paper -j" >&2
  exit 1
fi
if (( WAREHOUSES < 1 || THREADS < 1 || RUNS_PER_STATE < 1 )); then
  echo "ERROR: WAREHOUSES, THREADS, RUNS_PER_STATE must be positive" >&2; exit 1
fi
if (( TARGET_ACTIVE_WAREHOUSES < 1 || TARGET_ACTIVE_WAREHOUSES > WAREHOUSES )); then
  echo "ERROR: TARGET_ACTIVE_WAREHOUSES must be within [1, WAREHOUSES]" >&2; exit 1
fi
if ((${#ACTIVE_WAREHOUSE_VALUES[@]} == 0)); then
  echo "ERROR: ACTIVE_WAREHOUSES must not be empty" >&2; exit 1
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
if [[ -e "$MODEL_PATH" ]]; then
  echo "ERROR: refusing to overwrite existing model: $MODEL_PATH" >&2
  echo "Choose a new MODEL_VERSION or MODEL_BASENAME." >&2; exit 1
fi
mkdir -p "$MODEL_DIR" "$LOG_DIR"
cat > "$LOG_DIR/config.txt" <<EOF
binary=$BIN
database_warehouses=$WAREHOUSES
total_threads=$THREADS
extime_seconds_per_run=$EXTIME
active_warehouse_states=$ACTIVE_WAREHOUSES
held_out_target_active_warehouses=$TARGET_ACTIVE_WAREHOUSES
runs_per_training_state=$RUNS_PER_STATE
home_warehouse_assignment=$HOME_WAREHOUSE_ASSIGNMENT
home_warehouse_seed=$HOME_WAREHOUSE_SEED
home_warehouses_per_thread_average=active_warehouses / total_threads
workers_per_home_warehouse_average=total_threads / active_warehouses
tpcc_mix=not passed (TPC-C defaults: New-Order 45, Payment 43, Order-Status 4, Delivery 4, Stock-Level 4)
tpcc_retry_same_type=not passed (default true)
tpcc_hot_*_flags=not passed (defaults disabled)
active_warehouse_count=varies by training state
metis_paper_enable=true
ada_tam=false (default)
numa_policy=not set (no numactl)
update_period_us=$UPDATE_PERIOD_US
tam_min_threads=$TAM_MIN_THREADS
tam_max_threads=$TAM_MAX_THREADS
linucb_alpha=$LINUCB_ALPHA
linucb_lambda=$LINUCB_LAMBDA
min_pulls_per_action=$MIN_PULLS_PER_ACTION
model_path=$MODEL_PATH
EOF

total_runs=0
for active_warehouses in "${ACTIVE_WAREHOUSE_VALUES[@]}"; do
  [[ "$active_warehouses" == "$TARGET_ACTIVE_WAREHOUSES" ]] || ((total_runs += RUNS_PER_STATE))
done
if (( total_runs == 0 )); then
  echo "ERROR: no training states remain after holding out $TARGET_ACTIVE_WAREHOUSES" >&2; exit 1
fi
echo "[CONFIG] target_active_warehouses=$TARGET_ACTIVE_WAREHOUSES training_runs=$total_runs model=$MODEL_PATH" >&2
echo "[CONFIG] approx. measurement time: $((total_runs * EXTIME)) sec, excluding DB loading" >&2

for active_warehouses in "${ACTIVE_WAREHOUSE_VALUES[@]}"; do
  if [[ "$active_warehouses" == "$TARGET_ACTIVE_WAREHOUSES" ]]; then
    echo "[SKIP] held-out active_warehouses=$active_warehouses" >&2
    continue
  fi
  for ((run_id=1; run_id<=RUNS_PER_STATE; run_id++)); do
    log_file="$LOG_DIR/active_warehouses_${active_warehouses}_run_${run_id}.log"
    echo "[RUN] train_active_warehouses=$active_warehouses run=$run_id/$RUNS_PER_STATE" >&2
    status=0
    "$BIN" \
      --thread_num="$THREADS" --extime="$EXTIME" --tpcc_num_wh="$WAREHOUSES" \
      --tpcc_active_warehouse_count="$active_warehouses" \
      --tpcc_home_warehouse_assignment="$HOME_WAREHOUSE_ASSIGNMENT" \
      --tpcc_home_warehouse_seed="$HOME_WAREHOUSE_SEED" \
      --metis_paper_enable=true \
      --tam_update_period_us="$UPDATE_PERIOD_US" \
      --tam_min_threads="$TAM_MIN_THREADS" --tam_max_threads="$TAM_MAX_THREADS" \
      --tam_log_active_threads=false --linucb_alpha="$LINUCB_ALPHA" \
      --linucb_lambda="$LINUCB_LAMBDA" \
      --linucb_tam_min_pulls_per_action="$MIN_PULLS_PER_ACTION" \
      --linucb_model_path="$MODEL_PATH" --linucb_model_autosave=true \
      --linucb_abs_ignore_initial_steps=1 >"$log_file" 2>&1 || status=$?
    if (( status != 0 )); then
      echo "ERROR: benchmark failed (status $status): $log_file" >&2
      tail -n 50 "$log_file" >&2; exit "$status"
    fi
    if [[ ! -f "$MODEL_PATH" ]] || [[ "$(head -n 1 "$MODEL_PATH")" != "linucb_abs_model_v2" ]]; then
      echo "ERROR: model missing or invalid after $log_file" >&2
      tail -n 50 "$log_file" >&2; exit 1
    fi
  done
done

echo "[DONE] model: $MODEL_PATH" >&2
echo "[DONE] training logs/config: $LOG_DIR" >&2
echo "[NEXT] MODEL_VERSION='$MODEL_VERSION' TARGET_ACTIVE_WAREHOUSES='$TARGET_ACTIVE_WAREHOUSES' bash '$SCRIPT_DIR/model_percheck.sh'" >&2
