#!/usr/bin/env bash
# Extend the Item=100,000, standard-mix physical-first sweep to five more W.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_ROOT=${OUT_ROOT:-"$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_uniform_v1/extra_w"}
export TPCC_ITEM_COUNT=100000 TPCC_PIN_ORDER=physical_first
export NUMA_MEMORY_POLICY=OS_default
export TPCC_PAYMENT_PERCENT=43 TPCC_ORDER_STATUS_PERCENT=4
export TPCC_DELIVERY_PERCENT=4 TPCC_STOCK_LEVEL_PERCENT=4
export RUNS=${RUNS:-2} EXTIME=${EXTIME:-15}

for w in 8 14 24 64 128; do
  case "$w" in
    8) candidates="1 2 4 8 12 16 20 24 28 32 36 40 44 48 52 56 64 72 80 88 96" ;;
    14) candidates="1 2 4 8 16 20 24 28 32 36 40 44 48 52 56 64 72 80 88 96" ;;
    24) candidates="1 2 4 8 16 24 28 32 36 40 44 48 52 56 60 64 68 72 76 80 88 96" ;;
    64) candidates="1 2 4 8 16 24 32 40 44 48 52 56 60 64 68 72 76 80 88 92 96" ;;
    128) candidates="1 2 4 8 16 24 32 48 64 72 80 88 92 96" ;;
  esac
  db_warehouses=96
  if ((w == 128)); then db_warehouses=128; fi
  OUT="$OUT_ROOT/w${w}" DB_WAREHOUSES="$db_warehouses" \
    WAREHOUSE_VALUES="$w" N_VALUES="$candidates" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
