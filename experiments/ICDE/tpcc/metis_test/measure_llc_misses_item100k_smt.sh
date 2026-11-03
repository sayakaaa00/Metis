#!/usr/bin/env bash
# Measure LLC load misses for the current Item=100k, physical-first TPC-C setup.
# Requires a host/VM exposing a CPU PMU. perf attaches after DB loading.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
OUT=${OUT:-"$SCRIPT_DIR/logs/perf/llc_miss_item100k_smt_v1"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
METIS_BINARY=${METIS_BINARY:-"$ROOT/build_release/silo/tpcc_metis_test_smt"}
METIS_MODEL=${METIS_MODEL:-"$SCRIPT_DIR/models/physical_first_item100k_aware_smt_loo_v1/all/model.txt"}
PERF_EVENTS=${PERF_EVENTS:-LLC-load-misses,LLC-loads,instructions}
PERF_USE_SUDO=${PERF_USE_SUDO:-false}
SCOPE=${SCOPE:-all}                 # fixed, dynamic, or all
RUNS=${RUNS:-2}
FIXED_EXTIME=${FIXED_EXTIME:-30}
DYNAMIC_EXTIME=${DYNAMIC_EXTIME:-60}
PERF_INTERVAL_MS=${PERF_INTERVAL_MS:-1000}

case "$SCOPE" in fixed|dynamic|all) ;; *) echo "Invalid SCOPE: $SCOPE" >&2; exit 2;; esac
for path in "$MIMALLOC_LIBRARY" "$METIS_BINARY" "$METIS_MODEL"; do
  [[ -r "$path" ]] || { echo "Missing $path" >&2; exit 2; }
done
perf_cmd=(perf)
if [[ "$PERF_USE_SUDO" == true ]]; then perf_cmd=(sudo -n perf); fi
mkdir -p "$OUT"

# Fail before launching TPC-C if the VM does not expose the requested events.
if ! "${perf_cmd[@]}" stat -e "$PERF_EVENTS" -- sleep 0.02 \
    > "$OUT/perf_preflight.txt" 2>&1; then
  cat "$OUT/perf_preflight.txt" >&2
  echo "No usable CPU PMU for $PERF_EVENTS; no benchmark was started." >&2
  exit 2
fi

cat > "$OUT/config.txt" <<EOF
database_warehouses=96
physical_workers=96
item_count=100000
transaction_mix=new_order_45_payment_43_other_4_each
home_assignment=random_per_transaction
pin_order=physical_first
allocator=$MIMALLOC_LIBRARY
allocator_sha256=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
metis_binary=$METIS_BINARY
metis_binary_sha256=$(sha256sum "$METIS_BINARY" | awk '{print $1}')
metis_model=$METIS_MODEL
metis_model_sha256=$(sha256sum "$METIS_MODEL" | awk '{print $1}')
perf_events=$PERF_EVENTS
perf_interval_ms=$PERF_INTERVAL_MS
perf_use_sudo=$PERF_USE_SUDO
scope=$SCOPE
runs=$RUNS
fixed_extime=$FIXED_EXTIME
dynamic_extime=$DYNAMIC_EXTIME
EOF

printf 'mode,workload,threads,run,tps,perf_file,log_file\n' > "$OUT/results.csv"

# Every perf interval starts after the [end] load. marker. perf's first and
# last 1-second intervals may be partial; retain raw interval records.
measure() {
  local mode=$1 workload=$2 threads=$3 run=$4 binary=$5 extime=$6
  shift 6
  local prefix="$OUT/${mode}_${workload}_n${threads}_run${run}"
  local log="${prefix}.log" perf_file="${prefix}.perf.csv" pid
  local -a common=(
    --thread_num=96 --tpcc_num_wh=96 --tpcc_num_items=100000
    --tpcc_home_warehouse_assignment=random_per_transaction
    --tpcc_home_warehouse_seed=1 --tpcc_balanced_home_prefix=true
    --tpcc_pin_workers=true --tpcc_pin_order=physical_first
    --tpcc_perc_payment=43 --tpcc_perc_order_status=4
    --tpcc_perc_delivery=4 --tpcc_perc_stock_level=4
    --tpcc_hot_item_ratio=0 --tpcc_hot_transaction_mode=false
    --tpcc_interactive_ms=0 --tpcc_retry_same_type=true
    --tpcc_log_retry_conflicts=false --clocks_per_us=2900
    --tam_min_threads=8 --tam_max_threads=96
    --tam_log_period_us=200000 --tam_log_active_threads=true
    "--extime=$extime")
  echo "[llc] $mode $workload N=$threads run=$run" >&2
  env "LD_PRELOAD=$MIMALLOC_LIBRARY" "$binary" "${common[@]}" "$@" \
    > "$log" 2>&1 &
  pid=$!
  local ready=false
  for ((attempt=0;attempt<2400;attempt++)); do
    if rg -q '^\[end\] load\.' "$log"; then ready=true; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      echo "TPC-C exited before DB load completed: $log" >&2
      exit 1
    fi
    sleep 0.05
  done
  if [[ "$ready" != true ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" || true
    echo "Timed out waiting for DB load: $log" >&2
    exit 1
  fi
  if ! "${perf_cmd[@]}" stat -x, -I "$PERF_INTERVAL_MS" -e "$PERF_EVENTS" \
      -o "$perf_file" -p "$pid" -- sleep "$extime"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" || true
    echo "perf failed: $perf_file" >&2
    exit 1
  fi
  wait "$pid"
  if [[ "$PERF_USE_SUDO" == true ]]; then
    sudo -n chown "$(id -u):$(id -g)" "$perf_file"
  fi
  local tps
  tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
  [[ "$tps" =~ ^[0-9]+$ ]] || { echo "Missing TPS: $log" >&2; exit 1; }
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$mode" "$workload" "$threads" "$run" "$tps" "$perf_file" "$log" \
    >> "$OUT/results.csv"
}

if [[ "$SCOPE" == fixed || "$SCOPE" == all ]]; then
  # Include selected/near-optimal contrasts, especially W=32/64 at N=48.
  read -r -a fixed_specs <<< "${FIXED_SPECS:-1:8 4:16 4:24 8:48 16:48 32:48 32:64 64:48 64:96 96:80 96:96}"
  for ((run=1;run<=RUNS;run++)); do
    for spec in "${fixed_specs[@]}"; do
      [[ "$spec" =~ ^[0-9]+:[0-9]+$ ]] || { echo "Invalid FIXED_SPECS: $spec" >&2; exit 2; }
      w=${spec%%:*}; n=${spec##*:}
      measure fixed "w$w" "$n" "$run" "$METIS_BINARY" "$FIXED_EXTIME" \
        "--tpcc_active_warehouse_count=$w" \
        --tpcc_active_warehouse_schedule= \
        --metis_test_enable=true --ada_tam_enable=false \
        --metis_test_fixed_threads="$n" \
        --metis_test_learn=false --metis_test_idle_sleep_us=50 \
        --metis_test_reward_profile=physical_first_item100k \
        --tam_update_period_us=200000
    done
  done
fi

if [[ "$SCOPE" == dynamic || "$SCOPE" == all ]]; then
  for schedule in 16_32_4 16_96_4; do
    case "$schedule" in
      16_32_4) timeline=0:16,20:32,40:4 ;;
      16_96_4) timeline=0:16,20:96,40:4 ;;
    esac
    for ((run=1;run<=RUNS;run++)); do
      for method in metis_test silo_without_backoff silo_with_backoff; do
        case "$method" in
          metis_test)
            binary="$METIS_BINARY"
            args=(--metis_test_enable=true --ada_tam_enable=false
              --metis_test_learn=false --metis_test_observed_load=false
              --metis_test_cross_workload=true --metis_test_coarse_actions=true
              --metis_test_empirical_reward=false
              --metis_test_random_per_transaction=true
              --metis_test_active_warehouses=16
              --metis_test_balanced_home_prefix=true
              --metis_test_idle_sleep_us=50
              --metis_test_tps_scale=400000
              --metis_test_reward_profile=physical_first_item100k
              --metis_test_probe_intervals=3
              --metis_test_reprobe_period_us=0
              --tam_update_period_us=200000
              --linucb_alpha=0 --linucb_model_autosave=false
              "--linucb_model_path=$METIS_MODEL")
            threads=adaptive ;;
          *)
            binary="$ROOT/build_release/silo/tpcc_$method"
            args=(--metis_test_enable=true --ada_tam_enable=false
              --metis_test_fixed_threads=96 --metis_test_learn=false
              --metis_test_idle_sleep_us=50 --tam_update_period_us=200000)
            threads=96 ;;
        esac
        measure "$method" "$schedule" "$threads" "$run" "$binary" \
          "$DYNAMIC_EXTIME" --tpcc_active_warehouse_count=16 \
          "--tpcc_active_warehouse_schedule=$timeline" "${args[@]}"
      done
    done
  done
fi
echo "Raw perf intervals and TPS: $OUT" >&2
