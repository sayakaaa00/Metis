#!/usr/bin/env bash
set -euo pipefail

# Fast screening pilot for whether a smaller hot-item set shifts the best
# worker count downward as hot-item ratio rises. This is a screening run, not
# a publication-quality benchmark: one repeat by default.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_ROOT=${RESULT_ROOT:-"$SCRIPT_DIR/results/quick_contention_pilot_${STAMP}"}
WAREHOUSES=${WAREHOUSES:-32}
EXTIME=${EXTIME:-3}
REPEATS=${REPEATS:-1}
RATIOS=${RATIOS:-"0.00 0.99"}
THREADS_OVERRIDE=${THREADS_OVERRIDE:-"4 8 12 16 24 32"}
HOT_ITEM_COUNTS=${HOT_ITEM_COUNTS:-"100 10 1"}
HOT_SUPPLY_WAREHOUSE_COUNT=${HOT_SUPPLY_WAREHOUSE_COUNT:-1}
NUMACTL_ARGS=${NUMACTL_ARGS:---interleave=all}

if [[ -e "$RESULT_ROOT" ]]; then
  echo "ERROR: result directory already exists: $RESULT_ROOT" >&2
  exit 1
fi
mkdir -p "$RESULT_ROOT"

read -r -a HOT_COUNT_VALUES <<< "$HOT_ITEM_COUNTS"
read -r -a RATIO_VALUES <<< "$RATIOS"
read -r -a THREAD_VALUES <<< "$THREADS_OVERRIDE"
total_runs=$((${#HOT_COUNT_VALUES[@]} * ${#RATIO_VALUES[@]} * ${#THREAD_VALUES[@]} * REPEATS))

echo "[PILOT] output=$RESULT_ROOT" >&2
echo "[PILOT] warehouses=$WAREHOUSES ex time=${EXTIME}s repeats=$REPEATS" >&2
echo "[PILOT] hot_item_counts=$HOT_ITEM_COUNTS ratios=$RATIOS threads=$THREADS_OVERRIDE" >&2
echo "[PILOT] measurement time excluding DB load: $((total_runs * EXTIME))s" >&2

for hot_count in "${HOT_COUNT_VALUES[@]}"; do
  RESULT_DIR="$RESULT_ROOT/hot_items_${hot_count}" \
    WAREHOUSES="$WAREHOUSES" \
    EXTIME="$EXTIME" \
    REPEATS="$REPEATS" \
    RATIOS="$RATIOS" \
    THREADS_OVERRIDE="$THREADS_OVERRIDE" \
    HOT_ITEM_COUNT="$hot_count" \
    HOT_SUPPLY_WAREHOUSE_COUNT="$HOT_SUPPLY_WAREHOUSE_COUNT" \
    NUMACTL_ARGS="$NUMACTL_ARGS" \
    bash "$SCRIPT_DIR/thread_sweep_neworder90.sh"
done

echo "[DONE] pilot result directory: $RESULT_ROOT" >&2
