#!/usr/bin/env bash
# Leave-one-out training using only measured 96-thread TPS and abort rate.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXP_NAME=${EXP_NAME:-observed_wh_loo_v2}
TRAIN_RUNS=${TRAIN_RUNS:-2}
TRAIN_EXTIME=${TRAIN_EXTIME:-20}
EVAL_RUNS=${EVAL_RUNS:-3}
EVAL_EXTIME=${EVAL_EXTIME:-30}
MIN_PULLS=${MIN_PULLS:-4}
COARSE_ACTIONS=${COARSE_ACTIONS:-true}
REPROBE_PERIOD_US=${REPROBE_PERIOD_US:-0}
STATES=(1 4 32 96 16)
TARGETS=(16 1 4 32 96)

for state in "${STATES[@]}"; do
  path="$SCRIPT_DIR/models/$EXP_NAME/state_$state/model.txt"
  if [[ ! -s "$path" ]]; then
    echo "[train observed] active warehouses=$state"
    MODEL_VERSION="$EXP_NAME/state_$state" ACTIVE_WAREHOUSES="$state" \
      OBSERVED_LOAD=true CROSS_WORKLOAD=false COARSE_ACTIONS="$COARSE_ACTIONS" \
      EMPIRICAL_REWARD=false REPROBE_PERIOD_US=0 \
      RUNS="$TRAIN_RUNS" EXTIME="$TRAIN_EXTIME" MIN_PULLS="$MIN_PULLS" \
      EXPLORATION_SEED="$((131 + state))" \
      bash "$SCRIPT_DIR/model_learning.sh"
  fi
done

for target in "${TARGETS[@]}"; do
  output="$SCRIPT_DIR/models/$EXP_NAME/target_$target/model.txt"
  if [[ ! -s "$output" ]]; then
    inputs=()
    for state in "${STATES[@]}"; do
      [[ "$state" == "$target" ]] || \
        inputs+=("$SCRIPT_DIR/models/$EXP_NAME/state_$state/model.txt")
    done
    python3 "$SCRIPT_DIR/merge_observed_models.py" \
      --output "$output" "${inputs[@]}"
  fi
  echo "[evaluate observed] held-out active warehouses=$target"
  MODEL_VERSION="$EXP_NAME/target_$target" ACTIVE_WAREHOUSES="$target" \
    OBSERVED_LOAD=true CROSS_WORKLOAD=false COARSE_ACTIONS="$COARSE_ACTIONS" \
    EMPIRICAL_REWARD=false REPROBE_PERIOD_US="$REPROBE_PERIOD_US" \
    EVAL_TAG=held_out RUNS="$EVAL_RUNS" EXTIME="$EVAL_EXTIME" \
    bash "$SCRIPT_DIR/model_percheck.sh"
  python3 "$SCRIPT_DIR/plot_active_threads.py" \
    "$SCRIPT_DIR/logs/eval/$EXP_NAME/target_${target}_held_out" \
    --output "$SCRIPT_DIR/figures/${EXP_NAME}_target_${target}.png" \
    --title "Observed-load Metis-test: held-out warehouses=$target"
done
