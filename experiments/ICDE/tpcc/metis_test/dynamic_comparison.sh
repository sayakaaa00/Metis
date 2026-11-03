#!/usr/bin/env bash
# Compare both frozen five-workload models on the same live warehouse schedule.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL_NAME=${MODEL_NAME:-dynamic_all_v1}
EXP_NAME=${EXP_NAME:-dynamic_switch_v2}
EXTIME=${EXTIME:-60}
WAREHOUSE_SCHEDULE=${WAREHOUSE_SCHEDULE:-0:16,10:1,20:96,30:4,40:32,50:16}
REPROBE_PERIOD_US=${REPROBE_PERIOD_US:-6000000}
COARSE_ACTIONS=${COARSE_ACTIONS:-true}
OUT="$SCRIPT_DIR/logs/dynamic/$EXP_NAME"
mkdir -p "$OUT/aware" "$OUT/observed"
printf 'model,run,overall_tps\n' > "$OUT/overall.csv"
printf 'schedule=%s\nextime=%s\nreprobe_period_us=%s\ncoarse_actions=%s\n' \
  "$WAREHOUSE_SCHEDULE" "$EXTIME" "$REPROBE_PERIOD_US" "$COARSE_ACTIONS" > "$OUT/config.txt"

# Reverse the order in the second pair to expose time-dependent host effects.
for spec in aware:1 observed:1 observed:2 aware:2; do
  model=${spec%%:*}
  run=${spec##*:}
  if [[ "$model" == aware ]]; then
    version="$MODEL_NAME/warehouse_aware"
    cross=true
    observed=false
    period=0
  else
    version="$MODEL_NAME/observed"
    cross=false
    observed=true
    period="$REPROBE_PERIOD_US"
  fi
  echo "[dynamic] $model run $run"
  MODEL_VERSION="$version" ACTIVE_WAREHOUSES=16 \
    WAREHOUSE_SCHEDULE="$WAREHOUSE_SCHEDULE" CROSS_WORKLOAD="$cross" \
    OBSERVED_LOAD="$observed" COARSE_ACTIONS="$COARSE_ACTIONS" EMPIRICAL_REWARD=false \
    REPROBE_PERIOD_US="$period" EVAL_TAG="dynamic_run$run" \
    RUNS=1 EXTIME="$EXTIME" bash "$SCRIPT_DIR/model_percheck.sh"
  source_dir="$SCRIPT_DIR/logs/eval/${version}_dynamic_run$run"
  cp "$source_dir/active_1.log" "$OUT/$model/active_$run.log"
  cp "$source_dir/run_1.log" "$OUT/$model/run_$run.log"
  if [[ "$run" == 1 ]]; then
    cp "$source_dir/summary.csv" "$OUT/$model/summary.csv"
  else
    tail -n +2 "$source_dir/summary.csv" | \
      awk -F, -v run="$run" 'BEGIN {OFS=","} {$1=run; print}' \
      >> "$OUT/$model/summary.csv"
  fi
  awk -F, -v model="$model" -v run="$run" 'NR==2 {print model "," run "," $2}' \
    "$source_dir/summary.csv" >> "$OUT/overall.csv"
done

python3 "$SCRIPT_DIR/plot_dynamic_comparison.py" \
  --dynamic-dir "$OUT" --output-dir "$SCRIPT_DIR/figures/$EXP_NAME" \
  --duration "$EXTIME" --runs=2 --model-name "$MODEL_NAME"
