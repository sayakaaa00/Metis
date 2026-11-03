#!/usr/bin/env bash
# Shared, fixed TPC-C workload for Metis-test training and measurement.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_test"}
THREADS=${THREADS:-96}
WAREHOUSES=${WAREHOUSES:-96}
TPCC_ITEM_COUNT=${TPCC_ITEM_COUNT:-100000}
TPCC_PIN_ORDER=${TPCC_PIN_ORDER:-socket0_first}
TPCC_PIN_WORKERS=${TPCC_PIN_WORKERS:-true}
ACTIVE_WAREHOUSES=${ACTIVE_WAREHOUSES:-16}
WAREHOUSE_SCHEDULE=${WAREHOUSE_SCHEDULE:-}
HOME_ASSIGNMENT=${HOME_ASSIGNMENT:-randomized_worker_affined}
HOME_SEED=${HOME_SEED:-1}
REWARD_SCALE=${REWARD_SCALE:-400000}
REWARD_PROFILE=${REWARD_PROFILE:-legacy}
UPDATE_PERIOD_US=${UPDATE_PERIOD_US:-200000}
CLOCKS_PER_US=${CLOCKS_PER_US:-2900}
IDLE_SLEEP_US=${IDLE_SLEEP_US:-50}
BALANCED_HOME_PREFIX=${BALANCED_HOME_PREFIX:-true}
EMPIRICAL_REWARD=${EMPIRICAL_REWARD:-false}
COARSE_ACTIONS=${COARSE_ACTIONS:-false}
CROSS_WORKLOAD=${CROSS_WORKLOAD:-false}
OBSERVED_LOAD=${OBSERVED_LOAD:-false}
PROBE_INTERVALS=${PROBE_INTERVALS:-3}
REPROBE_PERIOD_US=${REPROBE_PERIOD_US:-0}
OBSERVED_MIN_COEFFICIENT=${OBSERVED_MIN_COEFFICIENT:-2}
EXPLORATION_SEED=${EXPLORATION_SEED:-1}
MODEL_VERSION=${MODEL_VERSION:-fixed_wh16_v1}
MODEL_DIR="$SCRIPT_DIR/models/$MODEL_VERSION"
MODEL_PATH="$MODEL_DIR/model.txt"
if [[ ! -x "$BIN" ]]; then
  echo "Missing $BIN; build target tpcc_metis_test" >&2
  exit 1
fi
if [[ "$HOME_ASSIGNMENT" != randomized_worker_affined &&
      "$HOME_ASSIGNMENT" != worker_affined &&
      "$HOME_ASSIGNMENT" != random_per_transaction ]]; then
  echo "Invalid HOME_ASSIGNMENT: $HOME_ASSIGNMENT" >&2
  exit 1
fi
RANDOM_PER_TRANSACTION=false
if [[ "$HOME_ASSIGNMENT" == random_per_transaction ]]; then
  RANDOM_PER_TRANSACTION=true
fi
COMMON_ARGS=(
  --thread_num="$THREADS"
  --tpcc_num_wh="$WAREHOUSES"
  --tpcc_num_items="$TPCC_ITEM_COUNT"
  --tpcc_pin_workers="$TPCC_PIN_WORKERS"
  --tpcc_pin_order="$TPCC_PIN_ORDER"
  --tpcc_balanced_home_prefix="$BALANCED_HOME_PREFIX"
  --tpcc_log_retry_conflicts=false
  --tpcc_active_warehouse_count="$ACTIVE_WAREHOUSES"
  --tpcc_active_warehouse_schedule="$WAREHOUSE_SCHEDULE"
  --tpcc_home_warehouse_assignment="$HOME_ASSIGNMENT"
  --tpcc_home_warehouse_seed="$HOME_SEED"
  --metis_test_enable=true
  --metis_test_active_warehouses="$ACTIVE_WAREHOUSES"
  --metis_test_random_per_transaction="$RANDOM_PER_TRANSACTION"
  --metis_test_balanced_home_prefix="$BALANCED_HOME_PREFIX"
  --metis_test_empirical_reward="$EMPIRICAL_REWARD"
  --metis_test_coarse_actions="$COARSE_ACTIONS"
  --metis_test_cross_workload="$CROSS_WORKLOAD"
  --metis_test_observed_load="$OBSERVED_LOAD"
  --metis_test_probe_intervals="$PROBE_INTERVALS"
  --metis_test_reprobe_period_us="$REPROBE_PERIOD_US"
  --metis_test_observed_min_coefficient="$OBSERVED_MIN_COEFFICIENT"
  --metis_test_tps_scale="$REWARD_SCALE"
  --metis_test_reward_profile="$REWARD_PROFILE"
  --tam_min_threads=8
  --tam_max_threads="$THREADS"
  --tam_update_period_us="$UPDATE_PERIOD_US"
  --tam_log_period_us="$UPDATE_PERIOD_US"
  --clocks_per_us="$CLOCKS_PER_US"
  --metis_test_idle_sleep_us="$IDLE_SLEEP_US"
  --linucb_abs_ignore_initial_steps=1
)

save_active_log() {
  local benchmark_log=$1
  local destination=$2
  local active_path
  active_path=$(awk -F': ' '/TAM active_threads logs will be written to:/ {
    gsub(/"/, "", $2); print $2; exit
  }' "$benchmark_log")
  if [[ ! -s "$REPO_ROOT/$active_path" ]]; then
    echo "Missing active-thread log: $active_path" >&2
    exit 1
  fi
  cp "$REPO_ROOT/$active_path" "$destination"
}

show_metrics() {
  awk '/^(actual_extime:|commit_counts_:|abort_rate:|throughput\[tps\]:)/ {print}' "$1"
}
