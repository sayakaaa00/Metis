#!/usr/bin/env bash
# Fixed-active-worker YCSB sweep under the conditions shared with the TPC-C
# experiments: 96 software workers, the first N active (AdaTAM clamped to
# min=max=N), parked workers sleep 50 us, physical-first pinning, mimalloc
# preloaded, OS-default NUMA memory placement, TSC 2900 clocks/us.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN=${BIN:-"$ROOT/build_release/silo/ycsb_metis_paper"}
MIMALLOC=${MIMALLOC:-"$ROOT/build_release/mimalloc_override/libmimalloc.so"}
SKEWS=${SKEWS:-"0.7 0.8 0.85 0.9 0.95 0.99 0.999"}
THREADS=${THREADS:-"8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 56 64 72 80 88 96"}
EXTIME=${EXTIME:-10}
RUNS=${RUNS:-2}
PIN_ORDER=${PIN_ORDER:-physical_first}
OUT=${OUT:-"$ROOT/experiments/ICDE/ycsb/oracle_${PIN_ORDER}_$(date +%Y%m%d_%H%M%S)"}

mkdir -p "$OUT/logs"

config=$({
  echo "binary=$BIN"
  echo "binary_sha256=$(sha256sum "$BIN" | cut -d' ' -f1)"
  echo "allocator_preload=$MIMALLOC"
  echo "allocator_sha256=$(sha256sum "$MIMALLOC" | cut -d' ' -f1)"
  echo "git_head=$(git -C "$ROOT" rev-parse HEAD)"
  echo "skews=$SKEWS"
  echo "threads=$THREADS"
  echo "extime=$EXTIME runs=$RUNS pin_order=$PIN_ORDER"
  echo "physical_workers=96 idle_sleep_us=50 clocks_per_us=2900 numa=os_default"
  echo "ycsb_tuple_num=10000 ycsb_max_ope=10 ycsb_rratio=50 backoff=0"
  echo "run_order=run1 ascending skew/N, run2 descending"
})
# Resume support: an existing output directory is reused only when every
# setting (including binary and allocator hashes) is unchanged.
if [[ -e "$OUT/config.txt" && "$(cat "$OUT/config.txt")" != "$config" ]]; then
  echo "Existing output has different settings: $OUT" >&2
  exit 1
fi
printf '%s\n' "$config" > "$OUT/config.txt"
if [[ ! -e "$OUT/results.csv" ]]; then
  printf 'skew,threads,run,throughput_tps,abort_rate,actual_extime\n' > "$OUT/results.csv"
fi

read -r -a skew_list <<< "$SKEWS"
read -r -a thread_list <<< "$THREADS"

run_one() {
  local skew=$1 n=$2 run=$3
  local log="$OUT/logs/skew${skew}_n${n}_run${run}.log"
  env "LD_PRELOAD=$MIMALLOC" "$BIN" \
    --thread_num=96 --extime="$EXTIME" --clocks_per_us=2900 \
    --ycsb_tuple_num=10000 --ycsb_max_ope=10 --ycsb_rratio=50 \
    --ycsb_zipf_skew="$skew" --pin_threads=true \
    --ycsb_pin_order="$PIN_ORDER" \
    --ada_tam_enable=true --metis_paper_enable=false \
    --tam_min_threads="$n" --tam_max_threads="$n" \
    --tam_update_period_us=1000000 --tam_idle_sleep_us=50 \
    --tam_log_active_threads=false > "$log" 2>&1
  local tps abort ext
  tps=$(awk '/^throughput\[tps\]:/{print $2}' "$log")
  abort=$(awk '/^abort_rate:/{print $2}' "$log")
  ext=$(awk '/^actual_extime:/{print $2}' "$log")
  if [[ -z "$tps" || -z "$abort" ]]; then
    echo "Missing metrics in $log" >&2
    return 1
  fi
  printf '%s,%s,%s,%s,%s,%s\n' "$skew" "$n" "$run" "$tps" "$abort" "$ext" >> "$OUT/results.csv"
  gzip -f "$log"
  echo "skew=$skew N=$n run=$run tps=$tps abort=$abort" >&2
}

cd "$ROOT"
for ((run = 1; run <= RUNS; run++)); do
  pairs=()
  for s in "${skew_list[@]}"; do
    for n in "${thread_list[@]}"; do pairs+=("$s:$n"); done
  done
  if (( run % 2 == 0 )); then
    reversed=()
    for ((i = ${#pairs[@]} - 1; i >= 0; i--)); do reversed+=("${pairs[i]}"); done
    pairs=("${reversed[@]}")
  fi
  for p in "${pairs[@]}"; do
    if grep -q "^${p%%:*},${p##*:},${run}," "$OUT/results.csv"; then continue; fi
    run_one "${p%%:*}" "${p##*:}" "$run"
  done
done

echo "$OUT"
