#!/usr/bin/env bash
# Fixed TPC-C: compare Metis-test with AdaTAM and retain time-stamped workers.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
OUT=${OUT:-"$SCRIPT_DIR/metis_adatam_mimalloc_fixed_v1"}
EXTIME=${EXTIME:-15}
RUNS=${RUNS:-2}
WAREHOUSES=${WAREHOUSES:-"1 4 16 32 96"}
read -r -a STATES <<< "$WAREHOUSES"
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-/tmp/metis-mimalloc-preload-build/libmimalloc.so}
METIS_MODEL=${METIS_MODEL:-"$SCRIPT_DIR/metis_test/models/dynamic_mimalloc_all_v1/all/model.txt"}

[[ -r "$MIMALLOC_LIBRARY" && -r "$METIS_MODEL" ]] || {
  echo "Missing mimalloc library or Metis-test model" >&2
  exit 1
}
mkdir -p "$OUT/logs" "$OUT/traces"
if [[ ! -f "$OUT/results.csv" ]]; then
  printf 'method,warehouse,run,tps,abort_rate,trace,log\n' > "$OUT/results.csv"
fi
printf 'database_warehouses=96\nphysical_workers=96\nhome_assignment=randomized_worker_affined\nhome_seed=1\nbalanced_home_prefix=true\nclocks_per_us=2900\nfixed_extime=%s\nruns=%s\nwarehouses=%s\nallocator_preload=%s\nmetis_model=%s\nupdate_period_us=200000\nidle_sleep_us=50\ntam_min_threads=8\ntam_max_threads=96\nada_tam_step=2\n' \
  "$EXTIME" "$RUNS" "$WAREHOUSES" "$MIMALLOC_LIBRARY" "$METIS_MODEL" > "$OUT/config.txt"

for warehouse in "${STATES[@]}"; do
  for ((run=1;run<=RUNS;run++)); do
    if ((run % 2 == 1)); then
      methods=(metis_test adatam)
    else
      methods=(adatam metis_test)
    fi
    for method in "${methods[@]}"; do
      if rg -q "^${method},${warehouse},${run}," "$OUT/results.csv"; then
        continue
      fi
      log="$OUT/logs/${method}_w${warehouse}_run${run}.log"
      trace="$OUT/traces/${method}_w${warehouse}_run${run}.log"
      common_args=(
        --thread_num=96 --tpcc_num_wh=96
        "--tpcc_active_warehouse_count=$warehouse"
        --tpcc_active_warehouse_schedule=
        --tpcc_home_warehouse_assignment=randomized_worker_affined
        --tpcc_home_warehouse_seed=1
        --tpcc_balanced_home_prefix=true
        --tpcc_log_retry_conflicts=false
        "--extime=$EXTIME" --clocks_per_us=2900
        --tam_min_threads=8 --tam_max_threads=96
        --tam_update_period_us=200000 --tam_log_period_us=200000
        --tam_log_active_threads=true
      )
      if [[ "$method" == metis_test ]]; then
        binary="$ROOT/build_release/silo/tpcc_metis_test"
        args=(--metis_test_enable=true --ada_tam_enable=false
              --metis_test_learn=false --metis_test_observed_load=true
              --metis_test_cross_workload=false --metis_test_coarse_actions=true
              --metis_test_balanced_home_prefix=true
              --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000
              --metis_test_probe_intervals=3
              --metis_test_reprobe_period_us=0
              --linucb_alpha=0 --linucb_model_autosave=false
              "--linucb_model_path=$METIS_MODEL")
      else
        binary="$ROOT/build_release/silo/tpcc_with_TAM"
        args=(--ada_tam_enable=true --metis_test_enable=false
              --ada_tam_step=2 --tam_idle_sleep_us=50)
      fi
      echo "[fixed] W=$warehouse run=$run method=$method" >&2
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
      printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$method" "$warehouse" "$run" "$tps" "$abort" "$trace" "$log" \
        >> "$OUT/results.csv"
      echo "[result] W=$warehouse run=$run method=$method tps=$tps" >&2
    done
  done
done
