#!/usr/bin/env bash
# Alternate the two observed-load action sets at fixed W=16.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXTIME=${EXTIME:-15}
for spec in coarse:1 dense:1 dense:2 coarse:2; do
  mode=${spec%%:*}
  run=${spec##*:}
  if [[ "$mode" == coarse ]]; then
    version=dynamic_all_v1/observed
    coarse=true
  else
    version=dense_all_v1/observed
    coarse=false
  fi
  echo "[paired W16] $mode run $run"
  MODEL_VERSION="$version" ACTIVE_WAREHOUSES=16 WAREHOUSE_SCHEDULE= \
    CROSS_WORKLOAD=false OBSERVED_LOAD=true COARSE_ACTIONS="$coarse" \
    REPROBE_PERIOD_US=0 EMPIRICAL_REWARD=false EXTIME="$EXTIME" RUNS=1 \
    EVAL_TAG="paired_w16_run$run" bash "$SCRIPT_DIR/model_percheck.sh"
done
OUT="$SCRIPT_DIR/figures/dynamic_dense_v1/paired_w16_metrics.csv"
mkdir -p "$(dirname "$OUT")"
printf 'mode,run,overall_tps\n' > "$OUT"
for mode in coarse dense; do
  if [[ "$mode" == coarse ]]; then
    version=dynamic_all_v1/observed
  else
    version=dense_all_v1/observed
  fi
  for run in 1 2; do
    summary="$SCRIPT_DIR/logs/eval/${version}_paired_w16_run$run/summary.csv"
    awk -F, -v mode="$mode" -v run="$run" 'NR==2 {print mode "," run "," $2}' \
      "$summary" >> "$OUT"
  done
done
echo "$OUT"
