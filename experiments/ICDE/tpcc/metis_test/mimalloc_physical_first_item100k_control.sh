#!/usr/bin/env bash
# Same-binary 100k-Item control at one worker, the peak, and a high-thread candidate.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-"$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_item100k_control_v1"}
export OUT
export TPCC_PIN_ORDER=physical_first
export TPCC_ITEM_COUNT=100000
export NUMA_MEMORY_POLICY=OS_default
export RUNS=${RUNS:-2}
export EXTIME=${EXTIME:-15}

WAREHOUSE_VALUES="16 32" N_VALUES="1 48 72" \
  bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
