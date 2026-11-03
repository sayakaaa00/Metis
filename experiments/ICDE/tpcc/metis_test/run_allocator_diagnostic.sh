#!/usr/bin/env bash
# Reproduce the frozen observed-model dynamic TPC-C allocator A/B.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
ALLOCATOR=${ALLOCATOR:-glibc}
RUNS=${RUNS:-2}
OUT=${OUT:-"$SCRIPT_DIR/logs/dynamic/allocator_diagnostic_${ALLOCATOR}"}
MIMALLOC_BUILD_DIR=${MIMALLOC_BUILD_DIR:-/tmp/metis-mimalloc-preload-build}
MODEL="$SCRIPT_DIR/models/dynamic_all_v1/observed/model.txt"
BINARY="$ROOT/build_release/silo/tpcc_metis_test"

[[ -x "$BINARY" && -r "$MODEL" ]] || {
  echo "Missing Metis-test binary or model" >&2
  exit 1
}
case "$ALLOCATOR" in
  glibc) ;;
  mimalloc)
    cmake -S "$ROOT/build_release/_deps/mimalloc-src" \
      -B "$MIMALLOC_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
      -DMI_BUILD_SHARED=ON -DMI_BUILD_STATIC=OFF \
      -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DMI_OVERRIDE=ON
    cmake --build "$MIMALLOC_BUILD_DIR" -j 8
    ;;
  *) echo "ALLOCATOR must be glibc or mimalloc" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
printf 'allocator=%s\nruns=%s\nschedule=0:16,10:1,20:96,30:4,40:32,50:16\nmodel=%s\n' \
  "$ALLOCATOR" "$RUNS" "$MODEL" > "$OUT/config.txt"

for ((run=1; run<=RUNS; ++run)); do
  preload=()
  if [[ "$ALLOCATOR" == mimalloc ]]; then
    preload=(env "LD_PRELOAD=$MIMALLOC_BUILD_DIR/libmimalloc.so")
  fi
  "${preload[@]}" timeout 145s "$BINARY" \
    --thread_num=96 --tpcc_num_wh=96 \
    --tpcc_active_warehouse_count=16 \
    --tpcc_active_warehouse_schedule=0:16,10:1,20:96,30:4,40:32,50:16 \
    --tpcc_home_warehouse_assignment=randomized_worker_affined \
    --tpcc_home_warehouse_seed=1 --tpcc_log_retry_conflicts=false \
    --extime=60 --clocks_per_us=2900 \
    --metis_test_enable=true --metis_test_learn=false \
    --metis_test_observed_load=true --metis_test_cross_workload=false \
    --metis_test_coarse_actions=true --metis_test_balanced_home_prefix=true \
    --metis_test_idle_sleep_us=50 --metis_test_tps_scale=400000 \
    --metis_test_probe_intervals=3 --metis_test_reprobe_period_us=6000000 \
    --tam_min_threads=8 --tam_max_threads=96 \
    --tam_update_period_us=200000 --tam_log_period_us=200000 \
    --tam_log_active_threads=true --tpcc_epoch_diagnostics=true \
    --linucb_alpha=0 --linucb_model_autosave=false \
    "--linucb_model_path=$MODEL" > "$OUT/run_${run}.log" 2>&1
  rg '^throughput\[tps\]:' "$OUT/run_${run}.log"
done
