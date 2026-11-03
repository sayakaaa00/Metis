#!/usr/bin/env bash
# Live active-home-warehouse TPC-C comparison under mimalloc.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
EXTIME=${EXTIME:-60}
RUNS=${RUNS:-2}
SCHEDULE=${SCHEDULE:-0:16,20:4,40:32}
TPCC_ITEM_COUNT=${TPCC_ITEM_COUNT:-100000}
METIS_REWARD_PROFILE=${METIS_REWARD_PROFILE:-legacy}
TPCC_PIN_ORDER=${TPCC_PIN_ORDER:-socket0_first}
HOME_ASSIGNMENT=${HOME_ASSIGNMENT:-randomized_worker_affined}
RANDOM_PER_TRANSACTION=false
if [[ "$HOME_ASSIGNMENT" == random_per_transaction ]]; then
  RANDOM_PER_TRANSACTION=true
fi
if [[ ! "$SCHEDULE" =~ ^0:([0-9]+)(,|$) ]]; then
  echo "SCHEDULE must start at 0 with an active warehouse count" >&2
  exit 1
fi
INITIAL_WAREHOUSES=${BASH_REMATCH[1]}
METIS_VARIANT=${METIS_VARIANT:-observed}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
case "$METIS_VARIANT" in
  observed)
    default_model="$SCRIPT_DIR/metis_test/models/dynamic_mimalloc_all_v1/all/model.txt"
    observed=true cross=false reprobe=6000000
    ;;
  warehouse_aware)
    default_model="$SCRIPT_DIR/metis_test/models/dynamic_mimalloc_aware_v1/warehouse_aware/model.txt"
    observed=false cross=true reprobe=0
    ;;
  *) echo "METIS_VARIANT must be observed or warehouse_aware" >&2; exit 1;;
esac
METIS_MODEL=${METIS_MODEL:-$default_model}
METIS_BINARY=${METIS_BINARY:-"$ROOT/build_release/silo/tpcc_metis_test"}
OUT=${OUT:-"$SCRIPT_DIR/metis_adatam_dynamic_16_4_32_${METIS_VARIANT}_v1"}
read -r -a METHODS <<< "${METHODS:-metis_test adatam silo_without_backoff silo_with_backoff}"

[[ -r "$MIMALLOC_LIBRARY" && -r "$METIS_MODEL" ]] || {
  echo "Missing mimalloc library or Metis-test model" >&2
  exit 1
}
mkdir -p "$OUT/logs" "$OUT/traces"
if [[ ! -f "$OUT/results.csv" ]]; then
  printf 'method,run,tps,abort_rate,trace,log\n' > "$OUT/results.csv"
fi
config=$(printf 'database_warehouses=96\nphysical_workers=96\nitem_count=%s\npin_order=%s\nhome_assignment=%s\nhome_seed=1\nbalanced_home_prefix=true\nschedule=%s\nextime=%s\nruns=%s\nmethods=%s\nallocator_preload=%s\nmetis_variant=%s\nmetis_model=%s\nmetis_reward_profile=%s\nmetis_observed_load=%s\nmetis_cross_workload=%s\nmetis_reprobe_period_us=%s\nupdate_period_us=200000\nlog_period_us=200000\nidle_sleep_us=50\ntam_min_threads=8\ntam_max_threads=96\nada_tam_step=4\n' \
  "$TPCC_ITEM_COUNT" "$TPCC_PIN_ORDER" "$HOME_ASSIGNMENT" \
  "$SCHEDULE" "$EXTIME" "$RUNS" "${METHODS[*]}" \
  "$MIMALLOC_LIBRARY" "$METIS_VARIANT" "$METIS_MODEL" "$METIS_REWARD_PROFILE" \
  "$observed" "$cross" "$reprobe")
if [[ "$METIS_BINARY" != "$ROOT/build_release/silo/tpcc_metis_test" ]]; then
  config+=$(printf '\nmetis_binary=%s\nmetis_binary_sha256=%s' \
    "$METIS_BINARY" "$(sha256sum "$METIS_BINARY" | awk '{print $1}')")
fi
if [[ -f "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Existing output has different benchmark settings: $OUT" >&2
  exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"

for ((run=1;run<=RUNS;run++)); do
  if ((run % 2 == 1)); then
    order=("${METHODS[@]}")
  else
    order=()
    for ((i=${#METHODS[@]}-1;i>=0;i--)); do order+=("${METHODS[i]}"); done
  fi
  for method in "${order[@]}"; do
    if rg -q "^${method},${run}," "$OUT/results.csv"; then continue; fi
    log="$OUT/logs/${method}_run${run}.log"
    trace="$OUT/traces/${method}_run${run}.log"
    common_args=(
      --thread_num=96 --tpcc_num_wh=96 "--tpcc_num_items=$TPCC_ITEM_COUNT"
      "--tpcc_active_warehouse_count=$INITIAL_WAREHOUSES"
      "--tpcc_active_warehouse_schedule=$SCHEDULE"
      "--tpcc_home_warehouse_assignment=$HOME_ASSIGNMENT"
      --tpcc_home_warehouse_seed=1 --tpcc_balanced_home_prefix=true
      --tpcc_pin_workers=true "--tpcc_pin_order=$TPCC_PIN_ORDER"
      --tpcc_log_retry_conflicts=false
      "--extime=$EXTIME" --clocks_per_us=2900
      --tam_min_threads=8 --tam_max_threads=96
      --tam_update_period_us=200000 --tam_log_period_us=200000
      --tam_log_active_threads=true
    )
    case "$method" in
      metis_test)
        binary="$METIS_BINARY"
        args=(--metis_test_enable=true --ada_tam_enable=false
              --metis_test_learn=false "--metis_test_observed_load=$observed"
              "--metis_test_cross_workload=$cross" --metis_test_coarse_actions=true
              "--metis_test_random_per_transaction=$RANDOM_PER_TRANSACTION"
              "--metis_test_active_warehouses=$INITIAL_WAREHOUSES"
              --metis_test_balanced_home_prefix=true
              --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000
              "--metis_test_reward_profile=$METIS_REWARD_PROFILE"
              --metis_test_probe_intervals=3
              "--metis_test_reprobe_period_us=$reprobe"
              --linucb_alpha=0 --linucb_model_autosave=false
              "--linucb_model_path=$METIS_MODEL")
        ;;
      adatam)
        binary="$ROOT/build_release/silo/tpcc_metis_test"
        args=(--ada_tam_enable=true --metis_test_enable=false
              --ada_tam_step=4 --tam_idle_sleep_us=50)
        ;;
      silo_without_backoff|silo_with_backoff)
        binary="$ROOT/build_release/silo/tpcc_$method"
        args=(--metis_test_enable=true --ada_tam_enable=false
              --metis_test_fixed_threads=96 --metis_test_learn=false
              --metis_test_balanced_home_prefix=true
              --metis_test_idle_sleep_us=50)
        ;;
      *) echo "Invalid method: $method" >&2; exit 1;;
    esac
    echo "[dynamic] run=$run method=$method schedule=$SCHEDULE" >&2
    if ! env "LD_PRELOAD=$MIMALLOC_LIBRARY" "$binary" \
        "${common_args[@]}" "${args[@]}" > "$log" 2>&1; then
      echo "Benchmark failed: $log" >&2
      exit 1
    fi
    active_path=$(awk -F': ' '/TAM active_threads logs will be written to:/ {
      print $2; exit
    }' "$log")
    active_path=${active_path#\"}
    active_path=${active_path%\"}
    if [[ "$active_path" != /* ]]; then active_path="$ROOT/$active_path"; fi
    [[ -s "$active_path" ]] || { echo "Missing active trace: $log" >&2; exit 1; }
    cp "$active_path" "$trace"
    rg -q '^\[TAM sample\] bench_s=' "$trace" || {
      echo "Missing time-stamped thread samples: $trace" >&2
      exit 1
    }
    tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
    abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
    [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
      echo "Missing result summary: $log" >&2
      exit 1
    }
    printf '%s,%s,%s,%s,%s,%s\n' \
      "$method" "$run" "$tps" "$abort" "$trace" "$log" \
      >> "$OUT/results.csv"
    echo "[result] run=$run method=$method tps=$tps" >&2
  done
done
