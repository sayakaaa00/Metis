#!/usr/bin/env bash
set -euo pipefail

TARGET_SKEW=${TARGET_SKEW:-0.7}
THREADS=${THREADS:-96}
BASE_MODEL_VERSION=${BASE_MODEL_VERSION:-model_v15}
LAMBDA_SET=(${LAMBDA_SET:-0.1 0.5 1.0 2.0 5.0})
OUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_DIR="$OUT_ROOT/log/96/$BASE_MODEL_VERSION"
SUMMARY_FILE="$SUMMARY_DIR/summary.tsv"
mkdir -p "$SUMMARY_DIR"

run_case() {
    local mode_name=$1
    local lambda=$2
    local disable_tps=$3
    local log_reward=$4
    local normalize_mode=$5
    local version="${BASE_MODEL_VERSION}_${mode_name}_lambda_${lambda}"

    echo "[CASE] version=${version}" >&2
    MODEL_VERSION="$version" \
    TARGET_SKEW="$TARGET_SKEW" \
    THREADS="$THREADS" \
    LINUCB_TAM_LAMBDA="$lambda" \
    DISABLE_TPS_THREAD_CONTEXT="$disable_tps" \
    USE_LOG_REWARD="$log_reward" \
    NORMALIZE_CONTEXT_REWARD="$normalize_mode" \
    "$OUT_ROOT/LinucbTAM_model_learning.sh"

    MODEL_VERSION="$version" \
    TARGET_SKEW="$TARGET_SKEW" \
    THREADS="$THREADS" \
    LINUCB_TAM_LAMBDA="$lambda" \
    DISABLE_TPS_THREAD_CONTEXT="$disable_tps" \
    USE_LOG_REWARD="$log_reward" \
    NORMALIZE_CONTEXT_REWARD="$normalize_mode" \
    "$OUT_ROOT/linucb_model_percheck.sh"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$version" "$lambda" "$disable_tps" "$log_reward" "$normalize_mode" "log/96/$version" \
        >> "$SUMMARY_FILE"
}

: > "$SUMMARY_FILE"
printf 'model_version\tlambda\tdisable_tps_thread_context\tlog_reward\tnormalize_context_reward\tlog_dir\n' >> "$SUMMARY_FILE"

for lambda in "${LAMBDA_SET[@]}"; do
    run_case tps_raw "$lambda" false false false
    run_case tps_log "$lambda" false true false
    run_case no_tps_raw "$lambda" true false false
    run_case no_tps_log "$lambda" true true false
    run_case normalize "$lambda" false false true
done

echo "[DONE] all cases finished. summary=$SUMMARY_FILE" >&2
