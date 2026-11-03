#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-96}
EXTIME=${EXTIME:-20}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
TARGET_SKEW=${TARGET_SKEW:-0.70}
UPDATE_PERIOD_US=${UPDATE_US_OVERRIDE:-10000}
TAM_MIN_THREADS=${TAM_MIN_THREADS:-1}
TAM_MAX_THREADS=${TAM_MAX_THREADS:-$THREADS}
LINUCB_TAM_ALPHA=${LINUCB_TAM_ALPHA:-1.0}
LINUCB_TAM_LAMBDA=${LINUCB_TAM_LAMBDA:-1.0}
MIN_PULLS_PER_ACTION=${MIN_PULLS_PER_ACTION:-10}
MODEL_VERSION=${MODEL_VERSION:-model_test}
MODEL_BASENAME=${MODEL_BASENAME:-linucb_${TARGET_SKEW}.txt}
#MODEL_BASENAME=${MODEL_BASENAME:-linucb_all.txt}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/ycsb_metis_paper"
OUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$OUT_ROOT/models/$MODEL_VERSION"
MODEL_PATH="$MODEL_DIR/$MODEL_BASENAME"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN not found or not executable." >&2
    exit 1
fi

mkdir -p "$MODEL_DIR"
rm -f "$MODEL_PATH"

SKEW_SET=(0.70 0.75 0.8 0.85 0.9 0.95)

for SKEW in "${SKEW_SET[@]}"; do
    if [[ "$SKEW" == "$TARGET_SKEW" ]]; then
        echo "[SKIP] target skew=${SKEW}" >&2
        continue
    fi

    for RUN_ID in 1 2 3; do
        echo "[RUN] model=${MODEL_VERSION} eval=${TARGET_SKEW} train=${SKEW} run=${RUN_ID} model_path=${MODEL_PATH}" >&2

        numactl --membind=0 "$BIN" \
            --thread_num="$THREADS" \
            --extime="$EXTIME" \
            --ycsb_tuple_num="$TUPLE_NUM" \
            --ycsb_max_ope="$MAX_OPE" \
            --ycsb_rratio="$RRATIO" \
            --ycsb_zipf_skew="$SKEW" \
            --tam_update_period_us="$UPDATE_PERIOD_US" \
            --tam_min_threads="$TAM_MIN_THREADS" \
            --tam_max_threads="$TAM_MAX_THREADS" \
            --metis_paper_enable=true \
            --pin_threads=true \
            --linucb_alpha="$LINUCB_TAM_ALPHA" \
            --linucb_lambda="$LINUCB_TAM_LAMBDA" \
            --linucb_tam_min_pulls_per_action="$MIN_PULLS_PER_ACTION" \
            --tam_log_active_threads=false \
            --linucb_model_path="$MODEL_PATH" \
            --linucb_model_autosave=true \
            --linucb_abs_ignore_initial_steps=1
    done
done

echo "[DONE] model saved to $MODEL_PATH" >&2
