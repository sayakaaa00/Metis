#!/usr/bin/env bash
# Additional candidates around the new N=48 peak for W=16 and W=32.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_OUT=${BASE_OUT:-"$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_uniform_v1/near48"}
export NUMA_MEMORY_POLICY=OS_default
export TPCC_PIN_ORDER=physical_first
export RUNS=${RUNS:-2}
export EXTIME=${EXTIME:-15}

for w in 16 32; do
  OUT="$BASE_OUT/w${w}" WAREHOUSE_VALUES="$w" N_VALUES="36 40 44 52 60" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
