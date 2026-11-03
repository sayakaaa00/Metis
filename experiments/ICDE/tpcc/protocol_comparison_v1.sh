#!/usr/bin/env bash
# Compare TPC-C protocols with the same 96-warehouse DB and home schedule.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
OUT=${OUT:-"$SCRIPT_DIR/protocol_comparison_v1"}
FIXED_EXTIME=${FIXED_EXTIME:-15}
FIXED_RUNS=${FIXED_RUNS:-2}
DYNAMIC_EXTIME=${DYNAMIC_EXTIME:-60}
DYNAMIC_RUNS=${DYNAMIC_RUNS:-2}
SCHEDULE=${SCHEDULE:-0:16,10:1,20:96,30:4,40:32,50:16}
read -r -a METHODS <<< "${METHODS:-silo_without_backoff silo_with_backoff cicada ermia observed_metis}"
REVERSE_METHODS=()
for ((index=${#METHODS[@]}-1;index>=0;index--)); do
  REVERSE_METHODS+=("${METHODS[index]}")
done
STATES=(1 4 16 32 96)
mkdir -p "$OUT/logs/fixed" "$OUT/logs/dynamic"
if [[ ! -f "$OUT/fixed.csv" ]]; then
  printf 'method,warehouse,run,tps,abort_rate,log\n' > "$OUT/fixed.csv"
fi
if [[ ! -f "$OUT/dynamic.csv" ]]; then
  printf 'method,run,tps,abort_rate,log\n' > "$OUT/dynamic.csv"
fi
printf 'database_warehouses=96\nphysical_workers=96\nhome_assignment=randomized_worker_affined\nhome_seed=1\nbalanced_home_prefix=true\nclocks_per_us=2900\nfixed_extime=%s\nfixed_runs=%s\ndynamic_extime=%s\ndynamic_runs=%s\nschedule=%s\nallocator_preload=%s\nnative_gc_inter_us=%s\nnative_defer_record_gc=%s\nmethods=%s\nmetis_model=%s\n' \
  "$FIXED_EXTIME" "$FIXED_RUNS" "$DYNAMIC_EXTIME" "$DYNAMIC_RUNS" "$SCHEDULE" \
  "${BENCHMARK_LD_PRELOAD:-}" "${NATIVE_GC_INTER_US:-1000000000}" \
  "${NATIVE_DEFER_RECORD_GC:-false}" "${METHODS[*]}" \
  "${METIS_MODEL_PATH:-$SCRIPT_DIR/metis_test/models/dynamic_all_v1/observed/model.txt}" \
  > "$OUT/config.txt"

run_one() {
  local method=$1 warehouses=$2 duration=$3 schedule=$4 reprobe=$5 log=$6
  local binary
  local -a args=(
    --thread_num=96 --tpcc_num_wh=96
    "--tpcc_active_warehouse_count=$warehouses"
    "--tpcc_active_warehouse_schedule=$schedule"
    --tpcc_home_warehouse_assignment=randomized_worker_affined
    --tpcc_home_warehouse_seed=1
    --tpcc_log_retry_conflicts=false
    "--extime=$duration" --clocks_per_us=2900
  )
  case "$method" in
    silo_without_backoff|silo_with_backoff)
      binary="$ROOT/build_release/silo/tpcc_$method"
      args+=(--metis_test_enable=true --metis_test_fixed_threads=96
             --metis_test_balanced_home_prefix=true
             --metis_test_idle_sleep_us=50
             --metis_test_learn=false --tam_update_period_us=200000)
      ;;
    cicada|ermia)
      binary="$ROOT/build_release/cc/$method/tpcc_$method.exe"
      # Both native engines fail in their regular GC paths under this
      # high-contention TPC-C workload. Keep reclamation outside the run.
      args+=(--tpcc_balanced_home_prefix=true --batch_th_num=0
             "--gc_inter_us=${NATIVE_GC_INTER_US:-1000000000}"
             "--gc_defer_record_reclamation=${NATIVE_DEFER_RECORD_GC:-false}")
      ;;
    observed_metis)
      binary="$ROOT/build_release/silo/tpcc_metis_test"
      args+=(--metis_test_enable=true --metis_test_learn=false
             --metis_test_observed_load=true --metis_test_cross_workload=false
             --metis_test_coarse_actions=true
             --metis_test_balanced_home_prefix=true
             --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000
             --metis_test_probe_intervals=3
             "--metis_test_reprobe_period_us=$reprobe"
             --tam_min_threads=8 --tam_max_threads=96
             --tam_update_period_us=200000 --tam_log_period_us=200000
             --linucb_alpha=0 --linucb_model_autosave=false
             "--linucb_model_path=${METIS_MODEL_PATH:-$SCRIPT_DIR/metis_test/models/dynamic_all_v1/observed/model.txt}")
      ;;
    *) echo "Invalid method: $method" >&2; exit 1;;
  esac
  if [[ -n "$schedule" && "$method" != cicada && "$method" != ermia ]]; then
    args+=(--tam_log_active_threads=true)
  fi
  [[ -x "$binary" ]] || { echo "Missing binary: $binary" >&2; exit 1; }
  echo "[protocol] $method W=$warehouses duration=$duration schedule=$schedule" >&2
  local -a launcher=()
  if [[ -n "${BENCHMARK_LD_PRELOAD:-}" ]]; then
    launcher=(env "LD_PRELOAD=$BENCHMARK_LD_PRELOAD")
  fi
  if ! "${launcher[@]}" "$binary" "${args[@]}" > "$log" 2>&1; then
    echo "Benchmark failed: $method W=$warehouses log=$log" >&2
    return 1
  fi
  if [[ -n "$schedule" && "$method" != cicada && "$method" != ermia ]]; then
    local active_path
    active_path=$(awk -F': ' '/TAM active_threads logs will be written to:/ {
      print $2; exit
    }' "$log")
    [[ -n "$active_path" ]] || { echo "Missing active log path: $log" >&2; exit 1; }
    active_path=${active_path#\"}
    active_path=${active_path%\"}
    if [[ "$active_path" != /* ]]; then active_path="$ROOT/$active_path"; fi
    [[ -s "$active_path" ]] || { echo "Missing active log: $active_path" >&2; exit 1; }
    cat "$active_path" >> "$log"
  fi
  local metrics
  if ! metrics=$(awk '
    $1 == "throughput[tps]:" { tps=$2 }
    $1 == "abort_rate:" { abort=$2 }
    END {
      if (tps == "" || abort == "") exit 1;
      print tps "," abort
    }
  ' "$log"); then
    echo "Missing result summary: $log" >&2
    return 1
  fi
  if [[ ! "$metrics" =~ ^[0-9]+,[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid result summary: $log" >&2
    return 1
  fi
  echo "$metrics"
}

for warehouses in "${STATES[@]}"; do
  for ((run=1;run<=FIXED_RUNS;run++)); do
    if ((run % 2 == 1)); then
      order=("${METHODS[@]}")
    else
      order=("${REVERSE_METHODS[@]}")
    fi
    for method in "${order[@]}"; do
      if rg -q "^${method},${warehouses},${run}," "$OUT/fixed.csv"; then continue; fi
      log="$OUT/logs/fixed/${method}_w${warehouses}_run${run}.log"
      metrics=$(run_one "$method" "$warehouses" "$FIXED_EXTIME" "" 0 "$log") || exit 1
      metrics=${metrics##*$'\n'}
      printf '%s,%s,%s,%s,%s\n' "$method" "$warehouses" "$run" "$metrics" "$log" \
        >> "$OUT/fixed.csv"
      echo "[fixed result] $method W=$warehouses run=$run $metrics" >&2
    done
  done
done
for ((run=1;run<=DYNAMIC_RUNS;run++)); do
  if ((run % 2 == 1)); then
    order=("${METHODS[@]}")
  else
    order=("${REVERSE_METHODS[@]}")
  fi
  for method in "${order[@]}"; do
    if rg -q "^${method},${run}," "$OUT/dynamic.csv"; then continue; fi
    log="$OUT/logs/dynamic/${method}_run${run}.log"
    reprobe=0
    [[ "$method" == observed_metis ]] && reprobe=6000000
    metrics=$(run_one "$method" 16 "$DYNAMIC_EXTIME" "$SCHEDULE" "$reprobe" "$log") || exit 1
    metrics=${metrics##*$'\n'}
    printf '%s,%s,%s,%s\n' "$method" "$run" "$metrics" "$log" \
      >> "$OUT/dynamic.csv"
    echo "[dynamic result] $method run=$run $metrics" >&2
  done
done
python3 "$SCRIPT_DIR/plot_protocol_comparison.py" --experiment-dir "$OUT"
