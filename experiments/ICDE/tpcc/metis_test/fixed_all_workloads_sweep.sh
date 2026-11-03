#!/usr/bin/env bash
# Sweep active worker counts with 96 physical workers and a 96-warehouse DB.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNS=${RUNS:-1}
EXTIME=${EXTIME:-15}
FIXED_VALUES=${FIXED_VALUES:-"8 16 24 32 48 64 96"}
MODEL_VERSION=${MODEL_VERSION:-physical96_fixed_sweep_v1}
for warehouses in 1 4 16 32 96; do
  echo "[fixed sweep] W=$warehouses"
  MODEL_VERSION="$MODEL_VERSION" ACTIVE_WAREHOUSES="$warehouses" \
    THREADS=96 WAREHOUSES=96 RUNS="$RUNS" EXTIME="$EXTIME" \
    FIXED_VALUES="$FIXED_VALUES" bash "$SCRIPT_DIR/fixed_sweep.sh"
done
python3 "$SCRIPT_DIR/plot_fixed_thread_sweep.py" \
  --logs-dir "$SCRIPT_DIR/logs/fixed" --model-version "$MODEL_VERSION" \
  --output-dir "$SCRIPT_DIR/figures/$MODEL_VERSION"
