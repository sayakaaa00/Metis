#!/usr/bin/env bash
set -euo pipefail

THREADS=${THREADS:-96}
BASE_MODEL_VERSION=${BASE_MODEL_VERSION:-model_v17_beta}
LAMBDA_SET=(${LAMBDA_SET:-0.1 0.5 1.0})
BETA_SET=(${BETA_SET:-0.0 0.05 0.1 0.2})
REWARD_HISTORY_ALPHA=${REWARD_HISTORY_ALPHA:-0.3}
TARGET_SKEW_SET=(${TARGET_SKEW_SET:-0.7 0.8 0.9 0.99})
OUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_DIR="$OUT_ROOT/log/96/$BASE_MODEL_VERSION"
SUMMARY_FILE="$SUMMARY_DIR/summary.tsv"
mkdir -p "$SUMMARY_DIR"

run_case() {
    local target_skew=$1
    local lambda=$2
    local beta=$3
    local version="${BASE_MODEL_VERSION}_skew_${target_skew}_lambda_${lambda}_beta_${beta}"

    echo "[CASE] version=${version}" >&2
    MODEL_VERSION="$version" \
    TARGET_SKEW="$target_skew" \
    THREADS="$THREADS" \
    LINUCB_TAM_LAMBDA="$lambda" \
    DISABLE_TPS_THREAD_CONTEXT=false \
    USE_LOG_REWARD=true \
    NORMALIZE_CONTEXT_REWARD=false \
    REWARD_THREAD_BETA="$beta" \
    REWARD_HISTORY_ALPHA="$REWARD_HISTORY_ALPHA" \
    DISABLE_CONTEXT_HISTORY=true \
    EXCLUDE_TARGET_SKEW_FROM_TRAIN=false \
    "$OUT_ROOT/LinucbTAM_model_learning.sh"

    MODEL_VERSION="$version" \
    TARGET_SKEW="$target_skew" \
    THREADS="$THREADS" \
    LINUCB_TAM_LAMBDA="$lambda" \
    DISABLE_TPS_THREAD_CONTEXT=false \
    USE_LOG_REWARD=true \
    NORMALIZE_CONTEXT_REWARD=false \
    REWARD_THREAD_BETA="$beta" \
    REWARD_HISTORY_ALPHA="$REWARD_HISTORY_ALPHA" \
    DISABLE_CONTEXT_HISTORY=true \
    "$OUT_ROOT/linucb_model_percheck.sh"

    printf '%s\t%s\t%s\t%s\t%s\n' "$version" "$target_skew" "$lambda" "$beta" "log/96/$version" >> "$SUMMARY_FILE"
}

: > "$SUMMARY_FILE"
printf 'model_version\ttarget_skew\tlambda\tbeta\tlog_dir\n' >> "$SUMMARY_FILE"

for target_skew in "${TARGET_SKEW_SET[@]}"; do
  for lambda in "${LAMBDA_SET[@]}"; do
    for beta in "${BETA_SET[@]}"; do
      run_case "$target_skew" "$lambda" "$beta"
    done
  done
done

echo "[DONE] v17 beta sweep finished. summary=$SUMMARY_FILE" >&2
