#!/usr/bin/env bash
# Repeat all 73 candidate pairs from the earlier pinned fixed-load sweep.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_ROOT=${OUT_ROOT:-"$SCRIPT_DIR/logs/fixed/mimalloc_physical_first_uniform_v1"}
export NUMA_MEMORY_POLICY=OS_default
export TPCC_PIN_ORDER=physical_first
export RUNS=${RUNS:-2}
export EXTIME=${EXTIME:-15}

OUT="$OUT_ROOT/base" bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
BASE_OUT="$OUT_ROOT/refine1" bash "$SCRIPT_DIR/mimalloc_numa_uniform_refine.sh"
BASE_OUT="$OUT_ROOT/refine2" bash "$SCRIPT_DIR/mimalloc_numa_uniform_refine2.sh"
