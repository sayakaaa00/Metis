#!/usr/bin/env bash
# Fixed-worker TPC-C sweep. Each transaction samples one of all W homes
# uniformly, so W remains meaningful even when active workers N < W.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$ROOT/build_release/silo/tpcc_metis_test"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
OUT=${OUT:-"$SCRIPT_DIR/logs/fixed/mimalloc_numa_uniform_sweep_v1"}
WAREHOUSE_VALUES=${WAREHOUSE_VALUES:-"1 4 16 32 96"}
N_VALUES=${N_VALUES:-"1 2 4 8 16 24 32 48 64 96"}
RUNS=${RUNS:-2}
EXTIME=${EXTIME:-15}
NUMA_MEMORY_POLICY=${NUMA_MEMORY_POLICY:-OS_default}
TPCC_PIN_ORDER=${TPCC_PIN_ORDER:-socket0_first}
TPCC_ITEM_COUNT=${TPCC_ITEM_COUNT:-100000}
DB_WAREHOUSES=${DB_WAREHOUSES:-96}
TPCC_PAYMENT_PERCENT=${TPCC_PAYMENT_PERCENT:-43}
TPCC_ORDER_STATUS_PERCENT=${TPCC_ORDER_STATUS_PERCENT:-4}
TPCC_DELIVERY_PERCENT=${TPCC_DELIVERY_PERCENT:-4}
TPCC_STOCK_LEVEL_PERCENT=${TPCC_STOCK_LEVEL_PERCENT:-4}

[[ -x "$BIN" && -r "$MIMALLOC_LIBRARY" ]] || {
  echo "Missing benchmark binary or mimalloc override library" >&2
  exit 1
}
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$EXTIME" =~ ^[1-9][0-9]*$ ]] || {
  echo "RUNS and EXTIME must be positive integers" >&2
  exit 1
}
[[ "$TPCC_ITEM_COUNT" =~ ^[1-9][0-9]*$ && "$TPCC_ITEM_COUNT" -le 100000 ]] || {
  echo "TPCC_ITEM_COUNT must be in [1, 100000]" >&2
  exit 1
}
for percent in "$TPCC_PAYMENT_PERCENT" "$TPCC_ORDER_STATUS_PERCENT" \
               "$TPCC_DELIVERY_PERCENT" "$TPCC_STOCK_LEVEL_PERCENT"; do
  [[ "$percent" =~ ^(0|[1-9][0-9]*)$ && "$percent" -le 100 ]] || {
    echo "TPC-C transaction percentages must be integers in [0, 100]" >&2
    exit 1
  }
done
tpcc_new_order_percent=$((100 - TPCC_PAYMENT_PERCENT - TPCC_ORDER_STATUS_PERCENT - TPCC_DELIVERY_PERCENT - TPCC_STOCK_LEVEL_PERCENT))
((tpcc_new_order_percent >= 0)) || {
  echo "TPC-C transaction percentages exceed 100" >&2
  exit 1
}
case "$NUMA_MEMORY_POLICY" in
  OS_default) benchmark_prefix=(env) ;;
  bind_node0)
    command -v numactl >/dev/null || {
      echo "numactl is required for NUMA_MEMORY_POLICY=bind_node0" >&2
      exit 1
    }
    benchmark_prefix=(numactl --membind=0 env) ;;
  *) echo "Unsupported NUMA_MEMORY_POLICY: $NUMA_MEMORY_POLICY" >&2; exit 1 ;;
esac
case "$TPCC_PIN_ORDER" in
  socket0_first) worker_cpu_placement="chooseSocketAwareCpu(worker_id),socket0_first" ;;
  physical_first) worker_cpu_placement="choosePhysicalFirstCpu(worker_id),physical_first" ;;
  *) echo "Unsupported TPCC_PIN_ORDER: $TPCC_PIN_ORDER" >&2; exit 1 ;;
esac
read -r -a warehouses <<< "$WAREHOUSE_VALUES"
read -r -a candidates <<< "$N_VALUES"
for w in "${warehouses[@]}"; do
  [[ "$DB_WAREHOUSES" =~ ^[1-9][0-9]*$ && "$w" =~ ^[1-9][0-9]*$ &&
     "$w" -le "$DB_WAREHOUSES" ]] || {
    echo "Active W must be in [1, DB_WAREHOUSES]" >&2
    exit 1
  }
done
for n in "${candidates[@]}"; do
  [[ "$n" =~ ^[1-9][0-9]*$ && "$n" -le 96 ]] || exit 1
done

mkdir -p "$OUT/logs"
binary_hash=$(sha256sum "$BIN" | awk '{print $1}')
allocator_hash=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
config=$(cat <<EOF
binary=$BIN
binary_sha256=$binary_hash
allocator_preload=$MIMALLOC_LIBRARY
allocator_sha256=$allocator_hash
database_warehouses=$DB_WAREHOUSES
item_count=$TPCC_ITEM_COUNT
physical_workers=96
active_home_assignment=random_per_transaction
active_home_distribution=uniform_over_all_W
worker_cpu_placement=$worker_cpu_placement
numa_memory_policy=$NUMA_MEMORY_POLICY
warehouse_values=${warehouses[*]}
active_worker_values=${candidates[*]}
runs=$RUNS
extime=$EXTIME
tpcc_mix=new_order:$tpcc_new_order_percent,payment:$TPCC_PAYMENT_PERCENT,order_status:$TPCC_ORDER_STATUS_PERCENT,delivery:$TPCC_DELIVERY_PERCENT,stock_level:$TPCC_STOCK_LEVEL_PERCENT
idle_sleep_us=50
update_period_us=200000
EOF
)
if [[ -e "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Existing output has different settings: $OUT" >&2
  exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"
if [[ ! -e "$OUT/results.csv" ]]; then
  printf 'active_warehouses,active_threads,run,tps,abort_rate,log\n' > "$OUT/results.csv"
fi
lscpu -e=CPU,NODE,SOCKET,CORE > "$OUT/cpu_topology.txt"

for ((run=1; run<=RUNS; run++)); do
  if ((run % 2 == 1)); then
    w_order=("${warehouses[@]}")
    n_order=("${candidates[@]}")
  else
    w_order=()
    n_order=()
    for ((i=${#warehouses[@]}-1; i>=0; i--)); do w_order+=("${warehouses[i]}"); done
    for ((i=${#candidates[@]}-1; i>=0; i--)); do n_order+=("${candidates[i]}"); done
  fi
  for w in "${w_order[@]}"; do
    for n in "${n_order[@]}"; do
      if rg -q "^${w},${n},${run}," "$OUT/results.csv"; then continue; fi
      log="$OUT/logs/w${w}_n${n}_run${run}.log"
      echo "[sweep] $(date -u +%FT%TZ) W=$w N=$n run=$run" >&2
      "${benchmark_prefix[@]}" "LD_PRELOAD=$MIMALLOC_LIBRARY" "$BIN" \
        --thread_num=96 "--tpcc_num_wh=$DB_WAREHOUSES" "--tpcc_num_items=$TPCC_ITEM_COUNT" \
        "--tpcc_active_warehouse_count=$w" --tpcc_active_warehouse_schedule= \
        --tpcc_home_warehouse_assignment=random_per_transaction \
        --tpcc_balanced_home_prefix=true --tpcc_home_warehouse_seed=1 \
        "--tpcc_perc_payment=$TPCC_PAYMENT_PERCENT" \
        "--tpcc_perc_order_status=$TPCC_ORDER_STATUS_PERCENT" \
        "--tpcc_perc_delivery=$TPCC_DELIVERY_PERCENT" \
        "--tpcc_perc_stock_level=$TPCC_STOCK_LEVEL_PERCENT" \
        --tpcc_hot_item_ratio=0 --tpcc_hot_transaction_mode=false \
        --tpcc_interactive_ms=0 --tpcc_retry_same_type=true \
        --tpcc_log_retry_conflicts=false \
        "--extime=$EXTIME" --clocks_per_us=2900 \
        --tam_min_threads=1 --tam_max_threads=96 \
        --tam_update_period_us=200000 \
        --metis_test_enable=true --ada_tam_enable=false \
        --metis_test_learn=false --metis_test_observed_load=false \
        --metis_test_cross_workload=true --metis_test_coarse_actions=true \
        "--metis_test_active_warehouses=$w" \
        --metis_test_balanced_home_prefix=true \
        --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000 \
        "--metis_test_fixed_threads=$n" --linucb_alpha=0 \
        --tpcc_pin_workers=true "--tpcc_pin_order=$TPCC_PIN_ORDER" \
        > "$log" 2>&1
      tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
      abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
      [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "Missing result summary: $log" >&2
        exit 1
      }
      printf '%s,%s,%s,%s,%s,%s\n' "$w" "$n" "$run" "$tps" "$abort" "$log" \
        >> "$OUT/results.csv"
      echo "[result] W=$w N=$n run=$run TPS=$tps abort=$abort" >&2
    done
  done
done
echo "Results: $OUT/results.csv" >&2
