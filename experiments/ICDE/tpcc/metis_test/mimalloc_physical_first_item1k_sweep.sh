#!/usr/bin/env bash
# Fixed-worker sweeps with 1,000 Items, physical-first pinning, and uniform homes.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mode=${1:?Usage: $0 standard|neworder60_payment40|neworder40_payment60}
case "$mode" in
  standard)
    default_out="$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_item1k_standard_v1"
    warehouses=(1 4 16 32 96)
    export TPCC_PAYMENT_PERCENT=43 TPCC_ORDER_STATUS_PERCENT=4
    export TPCC_DELIVERY_PERCENT=4 TPCC_STOCK_LEVEL_PERCENT=4
    ;;
  neworder60_payment40)
    default_out="$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_item1k_no60_p40_v1"
    warehouses=(1 4 16 32 96)
    export TPCC_PAYMENT_PERCENT=40 TPCC_ORDER_STATUS_PERCENT=0
    export TPCC_DELIVERY_PERCENT=0 TPCC_STOCK_LEVEL_PERCENT=0
    ;;
  neworder40_payment60)
    default_out="$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_item1k_no40_p60_v1"
    warehouses=(1 4 16 32 96)
    export TPCC_PAYMENT_PERCENT=60 TPCC_ORDER_STATUS_PERCENT=0
    export TPCC_DELIVERY_PERCENT=0 TPCC_STOCK_LEVEL_PERCENT=0
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 1
    ;;
esac

OUT_ROOT=${OUT_ROOT:-$default_out}
export TPCC_ITEM_COUNT=1000 TPCC_PIN_ORDER=physical_first
export NUMA_MEMORY_POLICY=OS_default
export RUNS=${RUNS:-2} EXTIME=${EXTIME:-15}

for w in "${warehouses[@]}"; do
  case "$w" in
    1) candidates="1 2 4 6 8 10 12 16 24 32 48 64 96" ;;
    4) candidates="1 2 4 8 12 16 20 24 28 32 48 64 96" ;;
    16) candidates="1 2 4 8 16 20 24 28 32 36 40 44 48 52 56 60 64 68 72 76 80 88 96" ;;
    32) candidates="1 2 4 8 16 24 32 36 40 44 48 52 56 60 64 68 72 76 80 88 96" ;;
    96) candidates="1 2 4 8 16 24 32 48 64 80 88 92 96" ;;
  esac
  OUT="$OUT_ROOT/w${w}" WAREHOUSE_VALUES="$w" N_VALUES="$candidates" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
