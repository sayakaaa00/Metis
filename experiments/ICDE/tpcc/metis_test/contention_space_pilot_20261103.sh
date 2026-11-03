#!/usr/bin/env bash
# Pilot for a TPC-C state space whose best fixed N spreads across 8..96.
#  A: standard mix, Item=100k, DB=96, dense low active-W (1..12), 10 s x 2 runs.
#  B: New-Order 60% / Payment 40%, Item=100k, DB=96, W=1..96, 10 s x 1 run.
# Both reuse mimalloc_numa_uniform_sweep.sh (fixed N via metis_test_fixed_threads,
# physical-first pinning, parked workers sleep 50 us, mimalloc preloaded).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BASE=${BASE:-"$SCRIPT_DIR/logs/fixed/contention_space_pilot_20261103"}
export BIN="$ROOT/build_release/silo/tpcc_metis_test"
export TPCC_ITEM_COUNT=100000 TPCC_PIN_ORDER=physical_first
export NUMA_MEMORY_POLICY=OS_default DB_WAREHOUSES=96 EXTIME=10

# A: standard mix
export TPCC_PAYMENT_PERCENT=43 TPCC_ORDER_STATUS_PERCENT=4
export TPCC_DELIVERY_PERCENT=4 TPCC_STOCK_LEVEL_PERCENT=4
OUT="$BASE/standard_lowW" RUNS=2 \
  WAREHOUSE_VALUES="1 2 3 4 6 8 12" \
  N_VALUES="2 4 6 8 10 12 14 16 20 24 28 32 40 48 64 96" \
  bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"

# B: New-Order 60 / Payment 40
export TPCC_PAYMENT_PERCENT=40 TPCC_ORDER_STATUS_PERCENT=0
export TPCC_DELIVERY_PERCENT=0 TPCC_STOCK_LEVEL_PERCENT=0
OUT="$BASE/no60_p40" RUNS=1 \
  WAREHOUSE_VALUES="1 2 4 8 16 32 96" \
  N_VALUES="4 8 12 16 20 24 32 40 48 56 64 80 96" \
  bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
