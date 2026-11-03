#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export WAREHOUSES=96
export TERMINALS=192
export WARMUP_CONFIG="${SCRIPT_DIR}/tpcc-hot-contention-192t-warmup.xml"
export MEASURE_CONFIG="${SCRIPT_DIR}/tpcc-hot-contention-192t.xml"
export RESULT_ROOT="${RESULT_ROOT:-/home/ubuntu/metis-mysql-lab/results/hot-contention-192t-thread-sweep}"

# Reuse the loaded SF96 database. PREPARE=auto loads only when it is absent.
export RESET_EACH_POINT="${RESET_EACH_POINT:-0}"
export PREPARE="${PREPARE:-auto}"

# Counterbalance time/order effects: repeat 1 uses the listed order and repeat
# 2 reverses it. Pre-warm for one minute before recording either repeat.
export LIMITS="${LIMITS:-0 16 32 48 64 80 96 112 128 160 192}"
export REPEATS="${REPEATS:-2}"
export ORDER_MODE="${ORDER_MODE:-balanced}"
export PREWARM_RUNS="${PREWARM_RUNS:-2}"
export PREWARM_LIMIT="${PREWARM_LIMIT:-96}"

exec "${SCRIPT_DIR}/run_thread_concurrency_sweep.sh" "$@"
