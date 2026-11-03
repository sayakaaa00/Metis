#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-96}
EXTIME=${EXTIME:-30}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
TARGET_SKEW=${TARGET_SKEW:-0.70}
UPDATE_PERIOD_US=${UPDATE_US_OVERRIDE:-10000}
TAM_MIN_THREADS=${TAM_MIN_THREADS:-1}
TAM_MAX_THREADS=${TAM_MAX_THREADS:-$THREADS}
LINUCB_TAM_ALPHA=${LINUCB_TAM_ALPHA:-0.7}
LINUCB_TAM_LAMBDA=${LINUCB_TAM_LAMBDA:-1.0}
TAM_LOG_PERIOD_US=${TAM_LOG_PERIOD_US:-10000}
MODEL_VERSION=${MODEL_VERSION:-model_test}
MODEL_BASENAME=${MODEL_BASENAME:-linucb_${TARGET_SKEW}.txt}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/ycsb_metis_paper"
OUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$OUT_ROOT/models/$MODEL_VERSION"
MODEL_PATH="$MODEL_DIR/$MODEL_BASENAME"
LOG_DIR="$OUT_ROOT/log/96/fixed/$MODEL_VERSION"
LOG_FILE="$LOG_DIR/metis_paper_skew_${TARGET_SKEW}_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN not found or not executable. Build ycsb_metis_paper first." >&2
    exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "ERROR: model not found: $MODEL_PATH" >&2
    exit 1
fi

echo "[RUN] model=${MODEL_VERSION} skew=${TARGET_SKEW} threads=${THREADS} log=${LOG_FILE} model_path=${MODEL_PATH}" >&2

numactl --membind=0 "$BIN" \
    --thread_num="$THREADS" \
    --extime="$EXTIME" \
    --ycsb_tuple_num="$TUPLE_NUM" \
    --ycsb_max_ope="$MAX_OPE" \
    --ycsb_rratio="$RRATIO" \
    --ycsb_zipf_skew="$TARGET_SKEW" \
    --tam_update_period_us="$UPDATE_PERIOD_US" \
    --tam_min_threads="$TAM_MIN_THREADS" \
    --tam_max_threads="$TAM_MAX_THREADS" \
    --metis_paper_enable=true \
    --pin_threads=true \
    --linucb_alpha="$LINUCB_TAM_ALPHA" \
    --linucb_lambda="$LINUCB_TAM_LAMBDA" \
    --tam_log_active_threads=true \
    --tam_log_period_us="$TAM_LOG_PERIOD_US" \
    --linucb_model_path="$MODEL_PATH" \
    --linucb_model_autosave=false \
    --linucb_abs_ignore_initial_steps=1 \
    2>&1 | tee "$LOG_FILE"

metis_log_path=$(awk -F': ' '/Metis active_threads logs will be written to/ {print $2; exit}' "$LOG_FILE")
if [[ -n "$metis_log_path" && -f "$metis_log_path" ]]; then
    log_base=$(basename "$metis_log_path")
    cp -f "$metis_log_path" "$LOG_DIR/$log_base"
    printf 'Saved metis active_threads log to %s\n' "$LOG_DIR/$log_base" >&2
else
    printf 'WARN: metis_active_threads log path not found in output\n' >&2
fi
