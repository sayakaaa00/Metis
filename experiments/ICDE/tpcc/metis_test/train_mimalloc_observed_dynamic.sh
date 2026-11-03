#!/usr/bin/env bash
# Train the warehouse-blind observed policy on fixed TPC-C states, then merge.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL_NAME=${MODEL_NAME:-dynamic_mimalloc_all_v1}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-/tmp/metis-mimalloc-preload-build/libmimalloc.so}
TRAIN_RUNS=${TRAIN_RUNS:-2}
TRAIN_EXTIME=${TRAIN_EXTIME:-20}
[[ -r "$MIMALLOC_LIBRARY" ]] || {
  echo "Missing mimalloc override library: $MIMALLOC_LIBRARY" >&2
  exit 1
}

models=()
for warehouses in 1 4 16 32 96; do
  version="$MODEL_NAME/state_$warehouses"
  model="$SCRIPT_DIR/models/$version/model.txt"
  if [[ ! -s "$model" ]]; then
    MODEL_VERSION="$version" ACTIVE_WAREHOUSES="$warehouses" \
      OBSERVED_LOAD=true CROSS_WORKLOAD=false COARSE_ACTIONS=true \
      EMPIRICAL_REWARD=false REPROBE_PERIOD_US=0 \
      BENCHMARK_LD_PRELOAD="$MIMALLOC_LIBRARY" \
      RUNS="$TRAIN_RUNS" EXTIME="$TRAIN_EXTIME" MIN_PULLS=4 \
      EXPLORATION_SEED="$((131 + warehouses))" \
      bash "$SCRIPT_DIR/model_learning.sh"
  fi
  models+=("$model")
done

merged="$SCRIPT_DIR/models/$MODEL_NAME/all/model.txt"
if [[ ! -s "$merged" ]]; then
  python3 "$SCRIPT_DIR/merge_observed_models.py" \
    --output "$merged" "${models[@]}"
fi
echo "Merged model: $merged"
