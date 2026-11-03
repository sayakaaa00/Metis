#!/usr/bin/env bash
# Fixed-N Silo TPC-C: OS scheduling, socket0-first, then physical-first.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$ROOT/build_release/silo/tpcc_silo_without_backoff"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
OUT=${OUT:-"$SCRIPT_DIR/logs/fixed/silo_best_n_three_placements_item100k_v1"}
EXTIME=${EXTIME:-15}
RUNS=${RUNS:-2}
W_VALUES=${W_VALUES:-"1 4 8 16 32 64 96"}
declare -A BEST_N=([1]=8 [4]=24 [8]=48 [16]=48 [32]=48 [64]=48 [96]=80)

[[ -x "$BIN" && -r "$MIMALLOC_LIBRARY" ]] || {
  echo "Missing Silo binary or mimalloc library" >&2; exit 1;
}
[[ "$EXTIME" =~ ^[1-9][0-9]*$ && "$RUNS" =~ ^[1-9][0-9]*$ ]] || exit 1
read -r -a warehouses <<< "$W_VALUES"
for w in "${warehouses[@]}"; do [[ -n "${BEST_N[$w]:-}" ]] || exit 1; done
mkdir -p "$OUT/logs"
config=$(cat <<EOF
experiment=silo_best_n_three_placements_item100k_v1
binary=$BIN
binary_sha256=$(sha256sum "$BIN" | awk '{print $1}')
allocator=$MIMALLOC_LIBRARY
allocator_sha256=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
database_warehouses=96
physical_workers=96
item_count=100000
home_assignment=random_per_transaction
home_distribution=uniform_over_active_W
fixed_N_by_W=1:8,4:24,8:48,16:48,32:48,64:48,96:80
controller=none
backoff=false
idle_sleep_us=50
mix=new_order:45,payment:43,order_status:4,delivery:4,stock_level:4
memory_policy=OS_default
placement_order=os_scheduler,socket0_first,physical_first
warehouses=${warehouses[*]}
runs=$RUNS
extime=$EXTIME
EOF
)
if [[ -f "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Settings changed for existing output: $OUT" >&2; exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"
lscpu -e=CPU,NODE,SOCKET,CORE > "$OUT/cpu_topology.txt"
if [[ ! -f "$OUT/results.csv" ]]; then
  printf 'placement,warehouse,active_threads,run,tps,abort_rate,log\n' > "$OUT/results.csv"
fi

for placement in os_scheduler socket0_first physical_first; do
  for ((run=1; run<=RUNS; run++)); do
    if ((run % 2 == 1)); then
      w_order=("${warehouses[@]}")
    else
      w_order=()
      for ((i=${#warehouses[@]}-1; i>=0; i--)); do w_order+=("${warehouses[i]}"); done
    fi
    for w in "${w_order[@]}"; do
      n=${BEST_N[$w]}
      if rg -q "^${placement},${w},${n},${run}," "$OUT/results.csv"; then continue; fi
      case "$placement" in
        os_scheduler) pin=false; order=socket0_first ;;
        socket0_first) pin=true; order=socket0_first ;;
        physical_first) pin=true; order=physical_first ;;
      esac
      log="$OUT/logs/${placement}_w${w}_n${n}_run${run}.log"
      echo "[fixed N] $(date -u +%FT%TZ) placement=$placement W=$w N=$n run=$run" >&2
      env "LD_PRELOAD=$MIMALLOC_LIBRARY" "$BIN" \
        --thread_num=96 --tpcc_num_wh=96 --tpcc_num_items=100000 \
        "--tpcc_active_warehouse_count=$w" --tpcc_active_warehouse_schedule= \
        --tpcc_home_warehouse_assignment=random_per_transaction \
        --tpcc_home_warehouse_seed=1 --tpcc_balanced_home_prefix=true \
        --tpcc_perc_payment=43 --tpcc_perc_order_status=4 \
        --tpcc_perc_delivery=4 --tpcc_perc_stock_level=4 \
        --tpcc_hot_item_ratio=0 --tpcc_hot_transaction_mode=false \
        --tpcc_interactive_ms=0 --tpcc_retry_same_type=true \
        --tpcc_log_retry_conflicts=false \
        "--extime=$EXTIME" --clocks_per_us=2900 \
        "--tpcc_fixed_active_workers=$n" --tam_idle_sleep_us=50 \
        --metis_test_enable=false --metis_paper_enable=false \
        --ada_tam_enable=false "--tpcc_pin_workers=$pin" \
        "--tpcc_pin_order=$order" > "$log" 2>&1
      tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
      abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
      [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "Missing result summary: $log" >&2; exit 1
      }
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$placement" "$w" "$n" "$run" \
        "$tps" "$abort" "$log" >> "$OUT/results.csv"
      echo "[result] placement=$placement W=$w N=$n run=$run TPS=$tps abort=$abort" >&2
    done
  done
done
