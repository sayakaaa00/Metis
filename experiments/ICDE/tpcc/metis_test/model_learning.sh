#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
EXTIME=${EXTIME:-20}
RUNS=${RUNS:-3}
ALPHA=${ALPHA:-0.4}
MIN_PULLS=${MIN_PULLS:-1}
OUT_DIR="$SCRIPT_DIR/logs/train/$MODEL_VERSION"
if [[ -e "$MODEL_PATH" ]]; then
  echo "Refusing to overwrite model: $MODEL_PATH" >&2
  exit 1
fi
mkdir -p "$MODEL_DIR" "$OUT_DIR"
printf 'binary=%s\nthreads=%s\nwarehouses=%s\nactive_warehouses=%s\nhome_assignment=%s\nseed=%s\nreward_scale=%s\nreward_profile=%s\nupdate_period_us=%s\nclocks_per_us=%s\nidle_sleep_us=%s\nbalanced_home_prefix=%s\nempirical_reward=%s\ncoarse_actions=%s\ncross_workload=%s\nobserved_load=%s\nprobe_intervals=%s\nreprobe_period_us=%s\nobserved_min_coefficient=%s\nexploration_seed_base=%s\nalpha=%s\nmin_pulls=%s\nextime=%s\nruns=%s\nallocator_preload=%s\nitem_count=%s\npin_order=%s\n' \
  "$BIN" "$THREADS" "$WAREHOUSES" "$ACTIVE_WAREHOUSES" "$HOME_ASSIGNMENT" \
  "$HOME_SEED" "$REWARD_SCALE" "$REWARD_PROFILE" "$UPDATE_PERIOD_US" "$CLOCKS_PER_US" "$IDLE_SLEEP_US" "$BALANCED_HOME_PREFIX" "$EMPIRICAL_REWARD" "$COARSE_ACTIONS" "$CROSS_WORKLOAD" "$OBSERVED_LOAD" "$PROBE_INTERVALS" "$REPROBE_PERIOD_US" "$OBSERVED_MIN_COEFFICIENT" "$EXPLORATION_SEED" \
  "$ALPHA" "$MIN_PULLS" "$EXTIME" "$RUNS" \
  "${BENCHMARK_LD_PRELOAD:-}" "$TPCC_ITEM_COUNT" "$TPCC_PIN_ORDER" > "$OUT_DIR/config.txt"
launcher=()
if [[ -n "${BENCHMARK_LD_PRELOAD:-}" ]]; then
  launcher=(env "LD_PRELOAD=$BENCHMARK_LD_PRELOAD")
fi
for ((run=1;run<=RUNS;run++)); do
  log="$OUT_DIR/run_${run}.log"
  "${launcher[@]}" "$BIN" "${COMMON_ARGS[@]}" --extime="$EXTIME" \
    --metis_test_learn=true --linucb_alpha="$ALPHA" \
    --metis_test_min_pulls_per_action="$MIN_PULLS" \
    --metis_test_exploration_seed="$((EXPLORATION_SEED + run))" \
    --linucb_model_path="$MODEL_PATH" --linucb_model_autosave=true \
    --tam_log_active_threads=true > "$log"
  save_active_log "$log" "$OUT_DIR/active_${run}.log"
  expected_header=metis_test_model_v5
  if [[ "$REWARD_PROFILE" != legacy ]]; then
    expected_header=metis_test_model_v6
  fi
  if [[ "${SMT_FEATURE:-false}" == true ]]; then
    expected_header=metis_test_model_v7
  fi
  if [[ "$OBSERVED_LOAD" == true ]]; then
    expected_header=metis_test_observed_v1
  fi
  if [[ ! -s "$MODEL_PATH" ]] ||
     [[ "$(head -c ${#expected_header} "$MODEL_PATH")" != "$expected_header" ]]; then
    echo "Model was not saved after run $run: $MODEL_PATH" >&2
    exit 1
  fi
  show_metrics "$log"
done
echo "Model: $MODEL_PATH"
