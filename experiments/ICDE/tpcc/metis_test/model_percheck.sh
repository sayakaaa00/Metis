#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
EXTIME=${EXTIME:-30}
RUNS=${RUNS:-3}
ALPHA=${ALPHA:-0}
EVAL_TAG=${EVAL_TAG:-base}
OUT_DIR="$SCRIPT_DIR/logs/eval/${MODEL_VERSION}_${EVAL_TAG}"
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Missing trained model: $MODEL_PATH" >&2
  exit 1
fi
mkdir -p "$OUT_DIR"
printf 'binary=%s\nmodel=%s\nthreads=%s\nwarehouses=%s\nactive_warehouses=%s\nwarehouse_schedule=%s\nhome_assignment=%s\nseed=%s\nreward_scale=%s\nupdate_period_us=%s\nclocks_per_us=%s\nidle_sleep_us=%s\nbalanced_home_prefix=%s\nempirical_reward=%s\ncoarse_actions=%s\ncross_workload=%s\nobserved_load=%s\nprobe_intervals=%s\nreprobe_period_us=%s\nobserved_min_coefficient=%s\nalpha=%s\nextime=%s\nruns=%s\nlearn=false\nallocator_preload=%s\nitem_count=%s\npin_order=%s\n' \
  "$BIN" "$MODEL_PATH" "$THREADS" "$WAREHOUSES" "$ACTIVE_WAREHOUSES" \
  "$WAREHOUSE_SCHEDULE" "$HOME_ASSIGNMENT" "$HOME_SEED" "$REWARD_SCALE" "$UPDATE_PERIOD_US" \
  "$CLOCKS_PER_US" "$IDLE_SLEEP_US" "$BALANCED_HOME_PREFIX" "$EMPIRICAL_REWARD" "$COARSE_ACTIONS" "$CROSS_WORKLOAD" "$OBSERVED_LOAD" "$PROBE_INTERVALS" "$REPROBE_PERIOD_US" "$OBSERVED_MIN_COEFFICIENT" "$ALPHA" "$EXTIME" "$RUNS" "${BENCHMARK_LD_PRELOAD:-}" "$TPCC_ITEM_COUNT" "$TPCC_PIN_ORDER" > "$OUT_DIR/config.txt"
launcher=()
if [[ -n "${BENCHMARK_LD_PRELOAD:-}" ]]; then
  launcher=(env "LD_PRELOAD=$BENCHMARK_LD_PRELOAD")
fi
printf 'run,tps,abort_rate,commits,actual_extime\n' > "$OUT_DIR/summary.csv"
for ((run=1;run<=RUNS;run++)); do
  log="$OUT_DIR/run_${run}.log"
  "${launcher[@]}" "$BIN" "${COMMON_ARGS[@]}" --extime="$EXTIME" \
    --metis_test_learn=false --linucb_alpha="$ALPHA" \
    --linucb_model_path="$MODEL_PATH" --linucb_model_autosave=false \
    --tam_log_active_threads=true > "$log"
  save_active_log "$log" "$OUT_DIR/active_${run}.log"
  awk -v run="$run" '
    $1 == "throughput[tps]:" { tps=$2 }
    $1 == "abort_rate:" { abort_rate=$2 }
    $1 == "commit_counts_:" { commits=$2 }
    $1 == "actual_extime:" { actual=$2 }
    END { if (tps == "" || abort_rate == "" || commits == "" || actual == "") exit 1;
      printf "%d,%s,%s,%s,%s\n",run,tps,abort_rate,commits,actual }
  ' "$log" >> "$OUT_DIR/summary.csv"
  show_metrics "$log"
done
echo "Summary: $OUT_DIR/summary.csv"
