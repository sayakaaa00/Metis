#!/usr/bin/env bash
# Compare socket0-first and physical-core-first pinning on the same binary.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$ROOT/build_release/silo/tpcc_metis_test"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
OUT=${OUT:-"$SCRIPT_DIR/logs/fixed/mimalloc_pinning_order_ab_v1"}
RUNS=${RUNS:-2}
EXTIME=${EXTIME:-15}
PAIRS=(4:24 4:48 4:64 4:72 16:24 16:48 16:64 16:72
       32:24 32:48 32:64 32:72)

[[ -x "$BIN" && -r "$MIMALLOC_LIBRARY" ]] || {
  echo "Missing benchmark binary or mimalloc override library" >&2
  exit 1
}
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$EXTIME" =~ ^[1-9][0-9]*$ ]] || {
  echo "RUNS and EXTIME must be positive integers" >&2
  exit 1
}
mkdir -p "$OUT/logs"
binary_hash=$(sha256sum "$BIN" | awk '{print $1}')
allocator_hash=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
config=$(cat <<EOF
binary=$BIN
binary_sha256=$binary_hash
allocator_preload=$MIMALLOC_LIBRARY
allocator_sha256=$allocator_hash
database_warehouses=96
physical_workers=96
active_home_assignment=random_per_transaction
active_home_distribution=uniform_over_all_W
numa_memory_policy=OS_default
worker_pin_orders=socket0_first physical_first
physical_first_order=socket0_physical,socket1_physical,socket0_smt,socket1_smt
pairs=${PAIRS[*]}
runs=$RUNS
extime=$EXTIME
tpcc_mix=new_order:45,payment:43,order_status:4,delivery:4,stock_level:4
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
  printf 'active_warehouses,active_threads,run,pin_order,tps,abort_rate,log\n' \
    > "$OUT/results.csv"
fi
lscpu -e=CPU,NODE,SOCKET,CORE > "$OUT/cpu_topology.txt"

for ((run=1; run<=RUNS; run++)); do
  if ((run % 2 == 1)); then
    pair_order=("${PAIRS[@]}")
    pin_order=(socket0_first physical_first)
  else
    pair_order=()
    for ((i=${#PAIRS[@]}-1; i>=0; i--)); do
      pair_order+=("${PAIRS[i]}")
    done
    pin_order=(physical_first socket0_first)
  fi
  for spec in "${pair_order[@]}"; do
    w=${spec%%:*}
    n=${spec#*:}
    for order in "${pin_order[@]}"; do
      if rg -q "^${w},${n},${run},${order}," "$OUT/results.csv"; then
        continue
      fi
      log="$OUT/logs/w${w}_n${n}_run${run}_${order}.log"
      echo "[pin-order] $(date -u +%FT%TZ) W=$w N=$n run=$run order=$order" >&2
      env "LD_PRELOAD=$MIMALLOC_LIBRARY" "$BIN" \
        --thread_num=96 --tpcc_num_wh=96 \
        "--tpcc_active_warehouse_count=$w" --tpcc_active_warehouse_schedule= \
        --tpcc_home_warehouse_assignment=random_per_transaction \
        --tpcc_balanced_home_prefix=true --tpcc_home_warehouse_seed=1 \
        --tpcc_perc_payment=43 --tpcc_perc_order_status=4 \
        --tpcc_perc_delivery=4 --tpcc_perc_stock_level=4 \
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
        --tpcc_pin_workers=true "--tpcc_pin_order=$order" \
        > "$log" 2>&1
      tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
      abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
      [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "Missing result summary: $log" >&2
        exit 1
      }
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$w" "$n" "$run" "$order" \
        "$tps" "$abort" "$log" >> "$OUT/results.csv"
      echo "[result] W=$w N=$n run=$run order=$order TPS=$tps abort=$abort" >&2
    done
  done
done
echo "Results: $OUT/results.csv" >&2
