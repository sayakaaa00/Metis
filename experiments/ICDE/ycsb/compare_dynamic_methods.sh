#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
YCSB_DIR="$ROOT/experiments/ICDE/ycsb"
BUILD_DIR="$ROOT/build_release/silo"
MODEL="$YCSB_DIR/models/${MODEL_VERSION:-model_test}/${MODEL_BASENAME:-linucb_all.txt}"
REPEATS=${REPEATS:-2}
OUT_DIR=${OUT_DIR:-"$YCSB_DIR/dynamic_comparison_$(date +%Y%m%d_%H%M%S)"}
mkdir -p "$OUT_DIR"
printf 'method,trial,throughput_tps,abort_rate,benchmark_log,trace_log\n' > "$OUT_DIR/results.csv"

if [[ $(head -n 1 "$MODEL") != linucb_abs_model_v2 ]]; then
  echo "Incompatible Metis-paper model: $MODEL" >&2
  exit 1
fi

common=(
  --thread_num=96 --extime=60 --clocks_per_us=2900 --ycsb_tuple_num=10000
  --ycsb_max_ope=10 --ycsb_rratio=50 --pin_threads=true
  --ycsb_zipf_skew=0.7 --ycsb_skew_change_enable=true
  --ycsb_zipf_skew2=0.95 --ycsb_skew_change_time_sec=20
  --ycsb_skew_change_enable2=true --ycsb_zipf_skew3=0.8
  --ycsb_skew_change_time_sec2=40
  --benchmark_interval_tps_log_us=200000
  --tam_min_threads=1 --tam_max_threads=96
)

run_one() {
  local method=$1 trial=$2
  local log="$OUT_DIR/${method}_trial_${trial}.log"
  local trace="$OUT_DIR/${method}_trial_${trial}_trace.log"
  local flags=(--ada_tam_enable=false --metis_paper_enable=false)
  local bin="$BUILD_DIR/$method"
  case "$method" in
    metis_paper)
      bin="$BUILD_DIR/ycsb_metis_paper"
      flags=(--ada_tam_enable=false --metis_paper_enable=true
             --tam_update_period_us=10000 --tam_log_period_us=200000
             --tam_log_active_threads=true --linucb_alpha=0.7
             --linucb_lambda=1.0 --linucb_model_path="$MODEL"
             --linucb_model_autosave=false)
      ;;
    adatam)
      bin="$BUILD_DIR/ycsb_metis_paper"
      flags=(--ada_tam_enable=true --metis_paper_enable=false
             --tam_update_period_us=1000 --tam_log_period_us=200000
             --tam_log_active_threads=true --ada_tam_step=1.0)
      ;;
  esac
  echo "Running $method trial $trial/$REPEATS" >&2
  numactl --membind=0 "$bin" "${common[@]}" "${flags[@]}" > "$log" 2>&1
  local source_trace
  source_trace=$(sed -n 's/^TAM active_threads logs will be written to: //p' "$log" | head -1)
  if [[ -n "$source_trace" ]]; then
    source_trace=${source_trace#\"}
    source_trace=${source_trace%\"}
    cp "$ROOT/$source_trace" "$trace"
  else
    # Fixed-thread methods write TPS samples to the benchmark log.
    trace="$log"
  fi
  local tps abort
  tps=$(awk '/^throughput\[tps\]:/{print $2}' "$log")
  abort=$(awk '/^abort_rate:/{print $2}' "$log")
  if [[ -z "$tps" || -z "$abort" ]] || ! rg -q '\[TPS sample\]' "$trace"; then
    echo "Missing metrics or TPS samples in $log / $trace" >&2
    exit 1
  fi
  printf '%s,%s,%s,%s,%s,%s\n' "$method" "$trial" "$tps" "$abort" "$log" "$trace" >> "$OUT_DIR/results.csv"
  echo "Finished $method trial $trial: $tps TPS" >&2
}

cd "$ROOT"
for ((trial=1; trial<=REPEATS; trial++)); do
  if (( trial % 2 == 1 )); then
    methods=(silo_without_backoff silo_with_backoff metis_paper adatam)
  else
    methods=(adatam metis_paper silo_with_backoff silo_without_backoff)
  fi
  for method in "${methods[@]}"; do
    if rg -q "^${method},${trial}," "$OUT_DIR/results.csv"; then
      continue
    fi
    run_one "$method" "$trial"
  done
done

echo "$OUT_DIR"
