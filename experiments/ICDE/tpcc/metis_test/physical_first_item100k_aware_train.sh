#!/usr/bin/env bash
# Train one warehouse-aware model per W, then prepare seven leave-one-W-out models.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
EXP_NAME=${EXP_NAME:-physical_first_item100k_aware_loo_reward_v2}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
TRAIN_RUNS=${TRAIN_RUNS:-2}
TRAIN_EXTIME=${TRAIN_EXTIME:-20}
STATES=(1 4 8 16 32 64 96)

[[ -r "$MIMALLOC_LIBRARY" ]] || { echo "Missing mimalloc library" >&2; exit 1; }
export TPCC_ITEM_COUNT=100000 TPCC_PIN_ORDER=physical_first
export TPCC_PIN_WORKERS=true HOME_ASSIGNMENT=random_per_transaction
export BALANCED_HOME_PREFIX=true CROSS_WORKLOAD=true COARSE_ACTIONS=true
export EMPIRICAL_REWARD=false OBSERVED_LOAD=false REPROBE_PERIOD_US=0
export REWARD_PROFILE=physical_first_item100k
export BENCHMARK_LD_PRELOAD="$MIMALLOC_LIBRARY"

for state in "${STATES[@]}"; do
  model="$SCRIPT_DIR/models/$EXP_NAME/state_$state/model.txt"
  if [[ ! -s "$model" ]]; then
    echo "[train] W=$state" >&2
    MODEL_VERSION="$EXP_NAME/state_$state" ACTIVE_WAREHOUSES="$state" \
      RUNS="$TRAIN_RUNS" EXTIME="$TRAIN_EXTIME" MIN_PULLS=4 ALPHA=0.4 \
      EXPLORATION_SEED="$((31 + state))" \
      bash "$SCRIPT_DIR/model_learning.sh"
  fi
done

for target in "${STATES[@]}"; do
  output="$SCRIPT_DIR/models/$EXP_NAME/target_$target/model.txt"
  if [[ ! -s "$output" ]]; then
    inputs=()
    for state in "${STATES[@]}"; do
      if ((state != target)); then
        inputs+=("$SCRIPT_DIR/models/$EXP_NAME/state_$state/model.txt")
      fi
    done
    python3 "$SCRIPT_DIR/merge_cross_workload_models.py" \
      --output "$output" "${inputs[@]}"
  fi
done

all="$SCRIPT_DIR/models/$EXP_NAME/all/model.txt"
if [[ ! -s "$all" ]]; then
  inputs=()
  for state in "${STATES[@]}"; do
    inputs+=("$SCRIPT_DIR/models/$EXP_NAME/state_$state/model.txt")
  done
  python3 "$SCRIPT_DIR/merge_cross_workload_models.py" \
    --output "$all" "${inputs[@]}"
fi
echo "Models: $SCRIPT_DIR/models/$EXP_NAME" >&2
