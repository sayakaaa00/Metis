#!/usr/bin/env bash
# Repeat the earlier 73-point fixed-worker sweep with all process memory
# bound to NUMA node 0 before the 96-warehouse DB is constructed.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_ROOT=${OUT_ROOT:-"$SCRIPT_DIR/logs/fixed/mimalloc_node0_uniform_v1"}
export NUMA_MEMORY_POLICY=bind_node0
export RUNS=${RUNS:-2}
export EXTIME=${EXTIME:-15}

OUT="$OUT_ROOT/base" bash "$SCRIPT_DIR/mimalloc_numa_uniform_sweep.sh"
BASE_OUT="$OUT_ROOT/refine1" bash "$SCRIPT_DIR/mimalloc_numa_uniform_refine.sh"
BASE_OUT="$OUT_ROOT/refine2" bash "$SCRIPT_DIR/mimalloc_numa_uniform_refine2.sh"
