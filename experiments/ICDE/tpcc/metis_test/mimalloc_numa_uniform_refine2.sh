#!/usr/bin/env bash
# Follow-up around N=72 and the upper edge N=96.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_OUT=${BASE_OUT:-"$SCRIPT_DIR/logs/fixed/mimalloc_numa_uniform_refine2_v1"}
RUNS=${RUNS:-2}
EXTIME=${EXTIME:-15}

for spec in '16:68 76 80 88' '32:68 76 88' '96:92'; do
  w=${spec%%:*}
  values=${spec#*:}
  OUT="$BASE_OUT/w${w}" WAREHOUSE_VALUES="$w" N_VALUES="$values" \
    RUNS="$RUNS" EXTIME="$EXTIME" \
    bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
done
