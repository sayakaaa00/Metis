#!/usr/bin/env bash
# Repeat the W=16/32 physical-first candidates with 10,000 Items.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_ROOT=${OUT_ROOT:-"$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_item10k_v1"}
export TPCC_PIN_ORDER=physical_first
export TPCC_ITEM_COUNT=10000
export NUMA_MEMORY_POLICY=OS_default
export RUNS=${RUNS:-2}
export EXTIME=${EXTIME:-15}

# These are exactly the candidates measured for each W in the 100,000-Item sweep.
OUT="$OUT_ROOT/w16" WAREHOUSE_VALUES=16 \
  N_VALUES="1 2 4 8 16 20 24 28 32 36 40 44 48 52 56 60 64 68 72 76 80 88 96" \
  bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
OUT="$OUT_ROOT/w32" WAREHOUSE_VALUES=32 \
  N_VALUES="1 2 4 8 16 24 32 36 40 44 48 52 56 60 64 68 72 76 80 88 96" \
  bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
