#!/usr/bin/env bash
# Paired fixed-W Metis-test-SMT evaluation: physical-first pinning versus OS scheduling.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN=${BIN:-"$ROOT/build_release/silo/tpcc_metis_test_smt"}
MIMALLOC_LIBRARY=${MIMALLOC_LIBRARY:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
MODEL_DIR=${MODEL_DIR:-"$SCRIPT_DIR/models/physical_first_item100k_aware_smt_loo_v1"}
OUT=${OUT:-"$SCRIPT_DIR/logs/eval/smt_worker_pin_ab_item100k_v1"}
EXTIME=${EXTIME:-15}
STATES=${STATES:-"1 4 8 16 32 64 96"}
RUNS=${RUNS:-2}

[[ -x "$BIN" && -r "$MIMALLOC_LIBRARY" ]] || { echo "Missing binary or allocator" >&2; exit 1; }
mkdir -p "$OUT/logs" "$OUT/traces"
config=$(cat <<EOF
experiment=smt_worker_pin_ab_item100k_v1
binary=$BIN
binary_sha256=$(sha256sum "$BIN" | awk '{print $1}')
allocator=$MIMALLOC_LIBRARY
allocator_sha256=$(sha256sum "$MIMALLOC_LIBRARY" | awk '{print $1}')
model_dir=$MODEL_DIR
model_sha256=$(for w in $STATES; do sha256sum "$MODEL_DIR/target_$w/model.txt"; done)
warehouse_count=96
worker_count=96
item_count=100000
home_assignment=random_per_transaction
pin_order=physical_first
memory_policy=OS_default
states=$STATES
runs=$RUNS
extime=$EXTIME
EOF
)
if [[ -f "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Settings changed for existing output: $OUT" >&2
  exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"
lscpu > "$OUT/cpu_topology.txt"
numactl --hardware >> "$OUT/cpu_topology.txt"
if [[ ! -f "$OUT/results.csv" ]]; then
  printf 'warehouse,run,pin_workers,tps,abort_rate,log,trace\n' > "$OUT/results.csv"
fi

for w in $STATES; do
  model="$MODEL_DIR/target_$w/model.txt"
  [[ -s "$model" ]] || { echo "Missing model: $model" >&2; exit 1; }
  for ((run=1; run<=RUNS; run++)); do
    if ((run % 2 == 1)); then modes=(true false); else modes=(false true); fi
    for pin in "${modes[@]}"; do
      if rg -q "^${w},${run},${pin}," "$OUT/results.csv"; then continue; fi
      log="$OUT/logs/w${w}_run${run}_pin${pin}.log"
      echo "[pin A/B] $(date -u +%FT%TZ) W=$w run=$run pin=$pin" >&2
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
        "--tpcc_pin_workers=$pin" --tpcc_pin_order=physical_first \
        --metis_test_enable=true --ada_tam_enable=false \
        --metis_test_learn=false --metis_test_observed_load=false \
        --metis_test_cross_workload=true --metis_test_coarse_actions=true \
        --metis_test_empirical_reward=false \
        --metis_test_random_per_transaction=true \
        "--metis_test_active_warehouses=$w" \
        --metis_test_balanced_home_prefix=true \
        --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000 \
        --metis_test_reward_profile=physical_first_item100k \
        --metis_test_reprobe_period_us=0 \
        --tam_min_threads=8 --tam_max_threads=96 \
        --tam_update_period_us=200000 --tam_log_period_us=200000 \
        --tam_log_active_threads=true --linucb_abs_ignore_initial_steps=1 \
        --linucb_alpha=0 --linucb_model_autosave=false \
        "--linucb_model_path=$model" > "$log" 2>&1
      active_path=$(awk -F': ' '/TAM active_threads logs will be written to:/ {
        gsub(/"/, "", $2); print $2; exit}' "$log")
      [[ -n "$active_path" ]] || { echo "Missing trace path: $log" >&2; exit 1; }
      if [[ "$active_path" != /* ]]; then active_path="$ROOT/$active_path"; fi
      trace="$OUT/traces/w${w}_run${run}_pin${pin}.log"
      cp "$active_path" "$trace"
      tps=$(awk '$1 == "throughput[tps]:" {print $2}' "$log" | tail -1)
      abort=$(awk '$1 == "abort_rate:" {print $2}' "$log" | tail -1)
      [[ "$tps" =~ ^[0-9]+$ && "$abort" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "Missing summary: $log" >&2; exit 1;
      }
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$w" "$run" "$pin" "$tps" "$abort" "$log" "$trace" >> "$OUT/results.csv"
      echo "[result] W=$w run=$run pin=$pin TPS=$tps abort=$abort" >&2
    done
  done
done
