#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
EXTIME=${EXTIME:-30}
RUNS=${RUNS:-2}
LOG_ACTIVE_THREADS=${LOG_ACTIVE_THREADS:-false}
FIXED_VALUES=${FIXED_VALUES:-"8 16 24 32 48 64 96"}
OUT_DIR="$SCRIPT_DIR/logs/fixed/${MODEL_VERSION}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"
printf 'binary=%s\nthreads=%s\nwarehouses=%s\nactive_warehouses=%s\nhome_assignment=%s\nseed=%s\nreward_scale=%s\nupdate_period_us=%s\nclocks_per_us=%s\nidle_sleep_us=%s\nbalanced_home_prefix=%s\nextime=%s\nruns=%s\nfixed_values=%s\nlog_active_threads=%s\n' \
  "$BIN" "$THREADS" "$WAREHOUSES" "$ACTIVE_WAREHOUSES" "$HOME_ASSIGNMENT" \
  "$HOME_SEED" "$REWARD_SCALE" "$UPDATE_PERIOD_US" "$CLOCKS_PER_US" "$IDLE_SLEEP_US" "$BALANCED_HOME_PREFIX" \
  "$EXTIME" "$RUNS" "$FIXED_VALUES" "$LOG_ACTIVE_THREADS" > "$OUT_DIR/config.txt"
printf 'active_threads,run,tps,abort_rate,commits,actual_extime\n' > "$OUT_DIR/results.csv"
for fixed in $FIXED_VALUES; do
  for ((run=1;run<=RUNS;run++)); do
    log="$OUT_DIR/fixed_${fixed}_run_${run}.log"
    "$BIN" "${COMMON_ARGS[@]}" --extime="$EXTIME" \
      --metis_test_fixed_threads="$fixed" --metis_test_learn=false \
      --tam_log_active_threads="$LOG_ACTIVE_THREADS" > "$log"
    if [[ "$LOG_ACTIVE_THREADS" == true ]]; then
      save_active_log "$log" "$OUT_DIR/active_fixed_${fixed}_run_${run}.log"
    fi
    awk -v fixed="$fixed" -v run="$run" '
      $1 == "throughput[tps]:" { tps=$2 }
      $1 == "abort_rate:" { abort_rate=$2 }
      $1 == "commit_counts_:" { commits=$2 }
      $1 == "actual_extime:" { actual=$2 }
      END { if (tps == "" || abort_rate == "" || commits == "" || actual == "") exit 1;
        printf "%d,%d,%s,%s,%s,%s\n",fixed,run,tps,abort_rate,commits,actual }
    ' "$log" >> "$OUT_DIR/results.csv"
    printf 'fixed=%s run=%s ' "$fixed" "$run"
    awk '$1 == "throughput[tps]:" { print "TPS=" $2 }' "$log"
  done
done
echo "Results: $OUT_DIR/results.csv"
