#!/usr/bin/env bash
# Train both 45-action policies on five fixed loads, then evaluate fixed and changing loads.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL_NAME=${MODEL_NAME:-dense_all_v1}
EXP_NAME=${EXP_NAME:-dynamic_dense_v1}
TRAIN_EXTIME=${TRAIN_EXTIME:-50}
TRAIN_RUNS=${TRAIN_RUNS:-2}
MIN_PULLS=${MIN_PULLS:-2}
FIXED_EXTIME=${FIXED_EXTIME:-15}
DYNAMIC_EXTIME=${DYNAMIC_EXTIME:-60}
STATES=(1 4 16 32 96)

for model in aware observed; do
  if [[ "$model" == aware ]]; then
    cross=true
    observed=false
    merged="$SCRIPT_DIR/models/$MODEL_NAME/warehouse_aware/model.txt"
    merger=merge_cross_workload_models.py
  else
    cross=false
    observed=true
    merged="$SCRIPT_DIR/models/$MODEL_NAME/observed/model.txt"
    merger=merge_observed_models.py
  fi
  parts=()
  for state in "${STATES[@]}"; do
    version="$MODEL_NAME/state_${state}_${model}"
    part="$SCRIPT_DIR/models/$version/model.txt"
    parts+=("$part")
    if [[ ! -s "$part" ]]; then
      echo "[train] $model W=$state, 45 actions"
      MODEL_VERSION="$version" ACTIVE_WAREHOUSES="$state" \
        CROSS_WORKLOAD="$cross" OBSERVED_LOAD="$observed" \
        COARSE_ACTIONS=false EMPIRICAL_REWARD=false REPROBE_PERIOD_US=0 \
        EXTIME="$TRAIN_EXTIME" RUNS="$TRAIN_RUNS" MIN_PULLS="$MIN_PULLS" \
        bash "$SCRIPT_DIR/model_learning.sh"
    fi
  done
  if [[ ! -s "$merged" ]]; then
    python3 "$SCRIPT_DIR/$merger" --output "$merged" "${parts[@]}"
  fi
done

MODEL_NAME="$MODEL_NAME" COARSE_ACTIONS=false EXTIME="$FIXED_EXTIME" \
  bash "$SCRIPT_DIR/matched_fixed_comparison.sh"
MODEL_NAME="$MODEL_NAME" EXP_NAME="$EXP_NAME" COARSE_ACTIONS=false \
  EXTIME="$DYNAMIC_EXTIME" bash "$SCRIPT_DIR/dynamic_comparison.sh"
python3 "$SCRIPT_DIR/plot_action_resolution.py" \
  --coarse "$SCRIPT_DIR/figures/dynamic_switch_v2" \
  --dense "$SCRIPT_DIR/figures/$EXP_NAME" \
  --output-dir "$SCRIPT_DIR/figures/$EXP_NAME"
