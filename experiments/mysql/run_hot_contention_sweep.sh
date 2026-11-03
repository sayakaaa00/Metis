#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export WAREHOUSES=96
export TERMINALS=96
export WARMUP_CONFIG="${SCRIPT_DIR}/tpcc-hot-contention-warmup.xml"
export MEASURE_CONFIG="${SCRIPT_DIR}/tpcc-hot-contention.xml"
export RESULT_ROOT="${RESULT_ROOT:-/home/ubuntu/metis-mysql-lab/results/hot-contention-thread-sweep}"
# SF96 loading is large. Load once, then reuse it across fixed-limit points.
export RESET_EACH_POINT=0
export PREPARE="${PREPARE:-auto}"
exec "${SCRIPT_DIR}/run_thread_concurrency_sweep.sh" "$@"
