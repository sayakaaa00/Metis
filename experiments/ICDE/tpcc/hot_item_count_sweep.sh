#!/usr/bin/env bash
set -euo pipefail

# Sweep the hot-item set size while keeping the hot New-Order transaction
# ratio fixed at 1.0. Each item count gets its own resumable calibration run.

WAREHOUSES=${WAREHOUSES:-16}
THREADS=${THREADS:-"8 16 24 32 40 48 56 64 72 80 88 96"}
# 15 is the minimum valid TPC-C New-Order item-set size; the other defaults
# include sizes used in prior experiments and span increasingly broad sets.
HOT_ITEM_COUNTS=${HOT_ITEM_COUNTS:-"15 100 1000 5000 10000 100000"}
EXTIME=${EXTIME:-5}
REPEATS=${REPEATS:-2}
# Hot transactions keep the normal TPC-C random home warehouse and district.
# These values are not used for routing in that mode; district_count is set to
# the full TPC-C range for clear configuration metadata.
HOT_WAREHOUSE_ID=${HOT_WAREHOUSE_ID:-1}
HOT_DISTRICT_COUNT=${HOT_DISTRICT_COUNT:-10}
# An unset variable keeps the historical interleave default; an explicitly
# empty value disables numactl and uses the OS default NUMA policy.
NUMACTL_ARGS=${NUMACTL_ARGS---interleave=all}
RESUME=${RESUME:-0}
COMPRESS_LOGS=${COMPRESS_LOGS:-true}

readonly HOT_TRANSACTION_RATIO=1.0

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/tpcc_mix_config.sh"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
CALIBRATION_SCRIPT="$SCRIPT_DIR/hot_transaction_calibration.sh"
BIN=${BIN:-"$REPO_ROOT/build_release/silo/tpcc_metis_paper"}
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

if [[ "$RESUME" == "1" && -z "${RESULT_DIR:-}" ]]; then
  echo "ERROR: RESUME=1 requires RESULT_DIR to point at an existing sweep directory" >&2
  exit 1
fi
RESULT_DIR=${RESULT_DIR:-"$SCRIPT_DIR/results/hot_item_count_sweep_${TIMESTAMP}"}
SWEEP_CONFIG="$RESULT_DIR/sweep_config.txt"

read -r -a ITEM_COUNT_VALUES <<< "${HOT_ITEM_COUNTS//$'\n'/ }"
if ((${#ITEM_COUNT_VALUES[@]} == 0)); then
  echo "ERROR: HOT_ITEM_COUNTS must contain at least one item count" >&2
  exit 1
fi

declare -A seen_item_counts=()
for item_count in "${ITEM_COUNT_VALUES[@]}"; do
  if [[ ! "$item_count" =~ ^[1-9][0-9]*$ ]] || ((item_count < 15 || item_count > 100000)); then
    echo "ERROR: each HOT_ITEM_COUNTS value must be in [15, 100000]: $item_count" >&2
    exit 1
  fi
  if [[ -n "${seen_item_counts[$item_count]:-}" ]]; then
    echo "ERROR: duplicate hot item count: $item_count" >&2
    exit 1
  fi
  seen_item_counts[$item_count]=1
done
if [[ "$COMPRESS_LOGS" != true && "$COMPRESS_LOGS" != false ]]; then
  echo "ERROR: COMPRESS_LOGS must be true or false" >&2
  exit 1
fi

expected_config=$(cat <<EOF
binary=$BIN
warehouses=$WAREHOUSES
extime=$EXTIME
repeats=$REPEATS
threads=$THREADS
hot_transaction_ratio=$HOT_TRANSACTION_RATIO
hot_item_counts=$HOT_ITEM_COUNTS
hot_warehouse_id=$HOT_WAREHOUSE_ID
hot_district_count=$HOT_DISTRICT_COUNT
hot_transaction_keep_tpcc_routing=true
numactl_args=$NUMACTL_ARGS
new_order_percent=$TPCC_PERC_NEW_ORDER
payment_percent=$TPCC_PERC_PAYMENT
order_status_percent=$TPCC_PERC_ORDER_STATUS
delivery_percent=$TPCC_PERC_DELIVERY
stock_level_percent=$TPCC_PERC_STOCK_LEVEL
home_warehouse_assignment=random_per_transaction
remote_supplier_selection=standard
metis=false
tam=false
compress_logs=$COMPRESS_LOGS
EOF
)

if [[ "$RESUME" == "1" ]]; then
  if [[ ! -f "$SWEEP_CONFIG" ]]; then
    echo "ERROR: cannot resume; missing $SWEEP_CONFIG" >&2
    exit 1
  fi
  if ! diff -u <(printf '%s\n' "$expected_config") "$SWEEP_CONFIG"; then
    echo "ERROR: resume configuration does not match the existing sweep" >&2
    exit 1
  fi
else
  if [[ -e "$RESULT_DIR" ]]; then
    echo "ERROR: result directory already exists: $RESULT_DIR" >&2
    echo "Use RESUME=1 and RESULT_DIR=... to continue it." >&2
    exit 1
  fi
  mkdir -p "$RESULT_DIR"
  printf '%s\n' "$expected_config" > "$SWEEP_CONFIG"
fi

printf '[CONFIG] fixed hot_transaction_ratio=%s; item counts=%s\n' \
  "$HOT_TRANSACTION_RATIO" "${ITEM_COUNT_VALUES[*]}" >&2
printf '[CONFIG] result directory: %s\n' "$RESULT_DIR" >&2

config_value() {
  local key=$1 file=$2
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found=1; exit }
    END { if (!found) exit 1 }' "$file"
}

assert_sub_config_matches_sweep() {
  local sub_config=$1 mapping sweep_key child_key sweep_value child_value
  local mappings=(
    "binary:binary"
    "warehouses:warehouses"
    "extime:extime"
    "repeats:repeats"
    "threads:threads"
    "hot_transaction_ratio:hot_transaction_ratios"
    "hot_warehouse_id:hot_warehouse_id"
    "hot_district_count:hot_district_count"
    "hot_transaction_keep_tpcc_routing:hot_transaction_keep_tpcc_routing"
    "numactl_args:numactl_args"
    "new_order_percent:new_order_percent"
    "payment_percent:payment_percent"
    "order_status_percent:order_status_percent"
    "delivery_percent:delivery_percent"
    "stock_level_percent:stock_level_percent"
    "home_warehouse_assignment:home_warehouse_assignment"
    "remote_supplier_selection:remote_supplier_selection"
    "metis:metis"
    "tam:tam"
    "compress_logs:compress_logs"
  )

  for mapping in "${mappings[@]}"; do
    sweep_key=${mapping%%:*}
    child_key=${mapping#*:}
    sweep_value=$(config_value "$sweep_key" "$SWEEP_CONFIG")
    child_value=$(config_value "$child_key" "$sub_config") || {
      echo "ERROR: $child_key missing from $sub_config" >&2
      return 1
    }
    if [[ "$sweep_value" != "$child_value" ]]; then
      echo "ERROR: configuration mismatch for $sweep_key/$child_key: '$sweep_value' != '$child_value'" >&2
      return 1
    fi
  done

  child_value=$(config_value hot_item_count "$sub_config") || {
    echo "ERROR: hot_item_count missing from $sub_config" >&2
    return 1
  }
  if [[ "$child_value" != "$item_count" ]]; then
    echo "ERROR: expected hot_item_count=$item_count, got $child_value in $sub_config" >&2
    return 1
  fi
}

for item_count in "${ITEM_COUNT_VALUES[@]}"; do
  item_result_dir="$RESULT_DIR/hot_item_count_${item_count}"
  sub_resume=0
  if [[ "$RESUME" == "1" && -f "$item_result_dir/config.txt" && -f "$item_result_dir/results.csv" ]]; then
    sub_resume=1
  elif [[ "$RESUME" == "1" && -e "$item_result_dir" ]]; then
    echo "ERROR: incomplete result directory cannot be resumed: $item_result_dir" >&2
    exit 1
  fi

  echo "[ITEM COUNT] $item_count" >&2
  env \
    BIN="$BIN" \
    WAREHOUSES="$WAREHOUSES" \
    THREADS="$THREADS" \
    RATIOS="$HOT_TRANSACTION_RATIO" \
    EXTIME="$EXTIME" \
    REPEATS="$REPEATS" \
    HOT_ITEM_COUNT="$item_count" \
    HOT_WAREHOUSE_ID="$HOT_WAREHOUSE_ID" \
    HOT_DISTRICT_COUNT="$HOT_DISTRICT_COUNT" \
    HOT_TRANSACTION_KEEP_TPCC_ROUTING=true \
    TPCC_PERC_PAYMENT="$TPCC_PERC_PAYMENT" \
    TPCC_PERC_ORDER_STATUS="$TPCC_PERC_ORDER_STATUS" \
    TPCC_PERC_DELIVERY="$TPCC_PERC_DELIVERY" \
    TPCC_PERC_STOCK_LEVEL="$TPCC_PERC_STOCK_LEVEL" \
    NUMACTL_ARGS="$NUMACTL_ARGS" \
    COMPRESS_LOGS="$COMPRESS_LOGS" \
    RESULT_DIR="$item_result_dir" \
    RESUME="$sub_resume" \
    bash "$CALIBRATION_SCRIPT"

  assert_sub_config_matches_sweep "$item_result_dir/config.txt"
done

echo "[DONE] sweep results: $RESULT_DIR" >&2
