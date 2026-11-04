#!/usr/bin/env bash
# Fine fixed-N oracle for the 8 standard-mix TPC-C states used by Metis v2:
# W = 1/2/3/4/8/16/32/96. Dense 2-step N around each peak plus the coarse set
# {8,16,24,32,48,64,96}. 10 s x 2 runs (run 2 reverses the N order).
# Uses a frozen copy of the binary so rebuilding during the sweep is harmless.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BASE=${BASE:-"$SCRIPT_DIR/logs/fixed/standard_oracle_8states_20261103"}
FROZEN="$ROOT/build_release/silo/tpcc_metis_test.oracle_20261103"
[[ -x "$FROZEN" ]] || cp "$ROOT/build_release/silo/tpcc_metis_test" "$FROZEN"
export BIN="$FROZEN"
export TPCC_ITEM_COUNT=100000 TPCC_PIN_ORDER=physical_first
export NUMA_MEMORY_POLICY=OS_default DB_WAREHOUSES=96 EXTIME=10 RUNS=2
export TPCC_PAYMENT_PERCENT=43 TPCC_ORDER_STATUS_PERCENT=4
export TPCC_DELIVERY_PERCENT=4 TPCC_STOCK_LEVEL_PERCENT=4

declare -A GRID=(
  [1]="4 6 8 10 12 14 16 24 32 48 64 96"
  [2]="6 8 10 12 14 16 18 20 24 32 48 64 96"
  [3]="8 10 12 14 16 18 20 22 24 32 48 64 96"
  [4]="8 12 14 16 18 20 22 24 26 28 32 48 64 96"
  [8]="8 16 24 32 36 40 42 44 46 48 50 52 56 64 96"
  [16]="8 16 24 32 40 42 44 46 48 50 52 56 64 96"
  [32]="8 16 24 32 40 42 44 46 48 50 52 56 64 96"
  [96]="8 16 24 32 48 56 64 68 72 76 80 84 88 92 96"
)
for w in 1 2 3 4 8 16 32 96; do
  OUT="$BASE/w$w" WAREHOUSE_VALUES="$w" N_VALUES="${GRID[$w]}" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
echo "done: $BASE"
