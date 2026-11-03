#!/usr/bin/env bash
# Fixed-N Silo TPC-C pin-order A/B at W=16/32 and N=24/72.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$ROOT/build_release/silo/tpcc_silo_without_backoff"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
OUT=${OUT:-"$SCRIPT_DIR/logs/fixed/silo_pin_order_n24_n72_w16_w32_item100k_v1"}
EXTIME=${EXTIME:-15}
RUNS=${RUNS:-2}
PAIRS=(16:24 16:72 32:24 32:72)

[[ -x "$BIN" && -r "$MIMALLOC_LIBRARY" ]] || { echo "Missing binary or allocator" >&2; exit 1; }
mkdir -p "$OUT/logs"
config=$(cat <<EOF
experiment=silo_pin_order_n24_n72_w16_w32_item100k_v1
binary=$BIN
binary_sha256=$(sha256sum "$BIN" | awk '{print $1}')
allocator=$MIMALLOC_LIBRARY
allocator_sha256=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
database_warehouses=96
physical_workers=96
item_count=100000
home_assignment=random_per_transaction
home_distribution=uniform_over_active_W
pairs=${PAIRS[*]}
controller=none
backoff=false
idle_sleep_us=50
mix=new_order:45,payment:43,order_status:4,delivery:4,stock_level:4
memory_policy=OS_default
pin_orders=physical_first,socket0_first
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
  printf 'warehouse,active_threads,run,pin_order,tps,abort_rate,log\n' > "$OUT/results.csv"
fi

for pair in "${PAIRS[@]}"; do
  w=${pair%%:*}
  n=${pair#*:}
  for ((run=1; run<=RUNS; run++)); do
    if ((run % 2 == 1)); then
      orders=(physical_first socket0_first)
    else
      orders=(socket0_first physical_first)
    fi
    for order in "${orders[@]}"; do
      if rg -q "^${w},${n},${run},${order}," "$OUT/results.csv"; then continue; fi
      log="$OUT/logs/w${w}_n${n}_run${run}_${order}.log"
      echo "[pin order A/B] $(date -u +%FT%TZ) W=$w N=$n run=$run order=$order" >&2
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
        --ada_tam_enable=false --tpcc_pin_workers=true \
        "--tpcc_pin_order=$order" > "$log" 2>&1
      tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
      abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
      [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "Missing result summary: $log" >&2; exit 1
      }
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$w" "$n" "$run" "$order" \
        "$tps" "$abort" "$log" >> "$OUT/results.csv"
      echo "[result] W=$w N=$n run=$run order=$order TPS=$tps abort=$abort" >&2
    done
  done
done
