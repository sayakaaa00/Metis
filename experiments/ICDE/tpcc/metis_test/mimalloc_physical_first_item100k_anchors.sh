#!/usr/bin/env bash
# Recheck historical best (W,N) pairs with the binary used for the new W sweep.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_ROOT=${OUT_ROOT:-"$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_uniform_v1/extra_w/anchors"}
export TPCC_ITEM_COUNT=100000 TPCC_PIN_ORDER=physical_first
export NUMA_MEMORY_POLICY=OS_default
export TPCC_PAYMENT_PERCENT=43 TPCC_ORDER_STATUS_PERCENT=4
export TPCC_DELIVERY_PERCENT=4 TPCC_STOCK_LEVEL_PERCENT=4
export RUNS=${RUNS:-2} EXTIME=${EXTIME:-15}

for spec in 1:8 4:24 16:48 32:48 96:80; do
  w=${spec%%:*}
  n=${spec#*:}
  OUT="$OUT_ROOT/w${w}" DB_WAREHOUSES=96 \
    WAREHOUSE_VALUES="$w" N_VALUES="$n" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
