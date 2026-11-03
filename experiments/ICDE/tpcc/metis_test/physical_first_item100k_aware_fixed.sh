#!/usr/bin/env bash
# Fixed TPC-C leave-one-W-out Metis-test versus four 96-worker protocols.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
EXP_NAME=${EXP_NAME:-physical_first_item100k_aware_loo_reward_v2}
OUT=${OUT:-"$SCRIPT_DIR/logs/eval/$EXP_NAME/fixed"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
METIS_BINARY=${METIS_BINARY:-"$ROOT/build_release/silo/tpcc_metis_test"}
RUNS=${RUNS:-2}
EXTIME=${EXTIME:-30}
STATES=(1 4 8 16 32 64 96)
METHODS=(metis_test silo_without_backoff silo_with_backoff cicada ermia)

[[ -r "$MIMALLOC_LIBRARY" ]] || { echo "Missing mimalloc library" >&2; exit 1; }
mkdir -p "$OUT/logs" "$OUT/traces"
config=$(cat <<EOF
experiment=$EXP_NAME
item_count=100000
database_warehouses=96
physical_workers=96
active_home_assignment=random_per_transaction
pin_order=physical_first
allocator_preload=$MIMALLOC_LIBRARY
allocator_sha256=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
metis_binary_sha256=$(sha256sum "$METIS_BINARY" | awk '{print $1}')
no_backoff_binary_sha256=$(sha256sum "$ROOT/build_release/silo/tpcc_silo_without_backoff" | awk '{print $1}')
backoff_binary_sha256=$(sha256sum "$ROOT/build_release/silo/tpcc_silo_with_backoff" | awk '{print $1}')
cicada_binary_sha256=$(sha256sum "$ROOT/build_release/cc/cicada/tpcc_cicada.exe" | awk '{print $1}')
ermia_binary_sha256=$(sha256sum "$ROOT/build_release/cc/ermia/tpcc_ermia.exe" | awk '{print $1}')
model=target_W_excluded_from_training
metis_coarse_actions=true
metis_reward_scale=400000
metis_reward_profile=physical_first_item100k
metis_update_period_us=200000
metis_idle_sleep_us=50
native_gc_inter_us=1000000000
states=${STATES[*]}
methods=${METHODS[*]}
runs=$RUNS
extime=$EXTIME
EOF
)
if [[ "$METIS_BINARY" != "$ROOT/build_release/silo/tpcc_metis_test" ]]; then
  config+=$(printf '\nmetis_binary=%s' "$METIS_BINARY")
fi
if [[ -f "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Settings changed for existing output: $OUT" >&2
  exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"
if [[ ! -f "$OUT/results.csv" ]]; then
  printf 'method,warehouse,run,tps,abort_rate,log,trace\n' > "$OUT/results.csv"
fi

for w in "${STATES[@]}"; do
  model="$SCRIPT_DIR/models/$EXP_NAME/target_$w/model.txt"
  [[ -s "$model" ]] || { echo "Missing held-out model: $model" >&2; exit 1; }
  for ((run=1;run<=RUNS;run++)); do
    if ((run % 2 == 1)); then
      order=("${METHODS[@]}")
    else
      order=()
      for ((i=${#METHODS[@]}-1;i>=0;i--)); do order+=("${METHODS[i]}"); done
    fi
    for method in "${order[@]}"; do
      if rg -q "^${method},${w},${run}," "$OUT/results.csv"; then continue; fi
      case "$method" in
        metis_test) binary="$METIS_BINARY" ;;
        silo_*) binary="$ROOT/build_release/silo/tpcc_$method" ;;
        cicada|ermia) binary="$ROOT/build_release/cc/$method/tpcc_$method.exe" ;;
      esac
      log="$OUT/logs/${method}_w${w}_run${run}.log"
      trace=""
      common=(--thread_num=96 --tpcc_num_wh=96 --tpcc_num_items=100000
        "--tpcc_active_warehouse_count=$w" --tpcc_active_warehouse_schedule=
        --tpcc_home_warehouse_assignment=random_per_transaction
        --tpcc_home_warehouse_seed=1 --tpcc_balanced_home_prefix=true
        --tpcc_perc_payment=43 --tpcc_perc_order_status=4
        --tpcc_perc_delivery=4 --tpcc_perc_stock_level=4
        --tpcc_hot_item_ratio=0 --tpcc_hot_transaction_mode=false
        --tpcc_interactive_ms=0 --tpcc_retry_same_type=true
        --tpcc_log_retry_conflicts=false
        "--extime=$EXTIME" --clocks_per_us=2900)
      case "$method" in
        metis_test)
          args=(--tpcc_pin_workers=true --tpcc_pin_order=physical_first
            --metis_test_enable=true --ada_tam_enable=false
            --metis_test_learn=false --metis_test_observed_load=false
            --metis_test_cross_workload=true --metis_test_coarse_actions=true
            --metis_test_empirical_reward=false
            --metis_test_random_per_transaction=true
            "--metis_test_active_warehouses=$w"
            --metis_test_balanced_home_prefix=true
            --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000
            --metis_test_reward_profile=physical_first_item100k
            --metis_test_reprobe_period_us=0
            --tam_min_threads=8 --tam_max_threads=96
            --tam_update_period_us=200000 --tam_log_period_us=200000
            --tam_log_active_threads=true --linucb_abs_ignore_initial_steps=1
            --linucb_alpha=0 --linucb_model_autosave=false
            "--linucb_model_path=$model")
          ;;
        silo_*)
          args=(--tpcc_pin_workers=true --tpcc_pin_order=physical_first
            --metis_test_enable=true --metis_test_fixed_threads=96
            --metis_test_learn=false --metis_test_idle_sleep_us=50
            --tam_update_period_us=200000)
          ;;
        cicada|ermia)
          args=(--tpcc_pin_order=physical_first --batch_th_num=0
            --gc_inter_us=1000000000 --gc_defer_record_reclamation=false)
          ;;
      esac
      echo "[fixed] W=$w method=$method run=$run" >&2
      if ! env "LD_PRELOAD=$MIMALLOC_LIBRARY" "$binary" \
          "${common[@]}" "${args[@]}" > "$log" 2>&1; then
        echo "Benchmark failed: $log" >&2
        exit 1
      fi
      if [[ "$method" == metis_test ]]; then
        active_path=$(awk -F': ' '/TAM active_threads logs will be written to:/ {
          gsub(/"/, "", $2); print $2; exit}' "$log")
        [[ -n "$active_path" ]] || { echo "Missing trace path: $log" >&2; exit 1; }
        if [[ "$active_path" != /* ]]; then active_path="$ROOT/$active_path"; fi
        trace="$OUT/traces/metis_test_w${w}_run${run}.log"
        cp "$active_path" "$trace"
        rg -q '\[Metis-test\].*bench_s=' "$trace" || {
          echo "Missing timestamped trace: $trace" >&2; exit 1;
        }
      fi
      tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
      abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
      [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "Missing summary: $log" >&2; exit 1;
      }
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$method" "$w" "$run" \
        "$tps" "$abort" "$log" "$trace" >> "$OUT/results.csv"
      echo "[result] W=$w method=$method run=$run TPS=$tps abort=$abort" >&2
    done
  done
done
echo "Results: $OUT/results.csv" >&2
