#!/usr/bin/env bash
# Extra fixed-worker candidates around the two-run coarse sweep peaks.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_OUT=${BASE_OUT:-"$SCRIPT_DIR/logs/fixed/mimalloc_numa_uniform_refine_v1"}
RUNS=${RUNS:-2}
EXTIME=${EXTIME:-15}

for spec in '1:6 10 12' '4:12 20 28' '16:20 28 56 72' \
            '32:56 72 80' '96:80 88'; do
  w=${spec%%:*}
  values=${spec#*:}
  OUT="$BASE_OUT/w${w}" WAREHOUSE_VALUES="$w" N_VALUES="$values" \
    RUNS="$RUNS" EXTIME="$EXTIME" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
