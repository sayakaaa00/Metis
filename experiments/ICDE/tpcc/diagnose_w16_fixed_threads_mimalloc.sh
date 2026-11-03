#!/usr/bin/env bash
# Isolate the worker-count effect at fixed W=16 under the dynamic benchmark setup.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
OUT=${OUT:-"$SCRIPT_DIR/diagnose_w16_fixed_threads_mimalloc_v1"}
EXTIME=${EXTIME:-15}
RUNS=${RUNS:-2}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
BIN="$ROOT/build_release/silo/tpcc_metis_test"
read -r -a VALUES <<< "${FIXED_VALUES:-16 24 72}"

[[ -r "$MIMALLOC_LIBRARY" && -x "$BIN" ]] || {
  echo "Missing benchmark binary or mimalloc library" >&2
  exit 1
}
mkdir -p "$OUT/logs"
config=$(printf 'database_warehouses=96\nactive_warehouses=16\nphysical_workers=96\nhome_assignment=randomized_worker_affined\nhome_seed=1\nbalanced_home_prefix=true\nallocator_preload=%s\nextime=%s\nruns=%s\nfixed_values=%s\nupdate_period_us=200000\nlog_period_us=200000\nidle_sleep_us=50\n' \
  "$MIMALLOC_LIBRARY" "$EXTIME" "$RUNS" "${VALUES[*]}")
if [[ -f "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Existing output has different settings: $OUT" >&2
  exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"
if [[ ! -f "$OUT/results.csv" ]]; then
  printf 'active_threads,run,tps,abort_rate,log\n' > "$OUT/results.csv"
fi

for ((run=1;run<=RUNS;run++)); do
  if ((run % 2 == 1)); then
    order=("${VALUES[@]}")
  else
    order=()
    for ((i=${#VALUES[@]}-1;i>=0;i--)); do order+=("${VALUES[i]}"); done
  fi
  for n in "${order[@]}"; do
    if rg -q "^${n},${run}," "$OUT/results.csv"; then continue; fi
    log="$OUT/logs/w16_n${n}_run${run}.log"
    echo "[fixed W=16] run=$run active_threads=$n" >&2
    env "LD_PRELOAD=$MIMALLOC_LIBRARY" "$BIN" \
      --thread_num=96 --tpcc_num_wh=96 \
      --tpcc_active_warehouse_count=16 --tpcc_active_warehouse_schedule= \
      --tpcc_home_warehouse_assignment=randomized_worker_affined \
      --tpcc_home_warehouse_seed=1 --tpcc_balanced_home_prefix=true \
      --tpcc_log_retry_conflicts=false \
      "--extime=$EXTIME" --clocks_per_us=2900 \
      --tam_min_threads=8 --tam_max_threads=96 \
      --tam_update_period_us=200000 --tam_log_period_us=200000 \
      --tam_log_active_threads=true \
      --metis_test_enable=true --ada_tam_enable=false \
      --metis_test_learn=false --metis_test_observed_load=false \
      --metis_test_cross_workload=true --metis_test_coarse_actions=true \
      --metis_test_active_warehouses=16 \
      --metis_test_balanced_home_prefix=true \
      --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000 \
      "--metis_test_fixed_threads=$n" --linucb_alpha=0 \
      > "$log" 2>&1
    tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
    abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
    [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
      echo "Missing result summary: $log" >&2
      exit 1
    }
    printf '%s,%s,%s,%s,%s\n' "$n" "$run" "$tps" "$abort" "$log" \
      >> "$OUT/results.csv"
    echo "[result] run=$run active_threads=$n tps=$tps" >&2
  done
done
