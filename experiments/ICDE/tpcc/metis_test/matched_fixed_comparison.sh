#!/usr/bin/env bash
# Fixed workloads using the exact five-state models evaluated dynamically.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL_NAME=${MODEL_NAME:-dynamic_all_v1}
EXTIME=${EXTIME:-15}
COARSE_ACTIONS=${COARSE_ACTIONS:-true}
EVAL_TAG_PREFIX=${EVAL_TAG_PREFIX:-matched_fixed}
STATES=(1 4 16 32 96)
for state in "${STATES[@]}"; do
  if ((state == 4 || state == 32)); then
    order=(observed aware)
  else
    order=(aware observed)
  fi
  for model in "${order[@]}"; do
    if [[ "$model" == aware ]]; then
      version="$MODEL_NAME/warehouse_aware"
      cross=true
      observed=false
    else
      version="$MODEL_NAME/observed"
      cross=false
      observed=true
    fi
    echo "[matched fixed] W=$state model=$model"
    MODEL_VERSION="$version" ACTIVE_WAREHOUSES="$state" \
      WAREHOUSE_SCHEDULE= CROSS_WORKLOAD="$cross" OBSERVED_LOAD="$observed" \
      COARSE_ACTIONS="$COARSE_ACTIONS" EMPIRICAL_REWARD=false REPROBE_PERIOD_US=0 \
      EVAL_TAG="${EVAL_TAG_PREFIX}_w$state" RUNS=1 EXTIME="$EXTIME" \
      bash "$SCRIPT_DIR/model_percheck.sh"
  done
done
