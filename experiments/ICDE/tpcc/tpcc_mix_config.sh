# Shared TPC-C transaction-mix settings for experiment and per-run metadata.
# New-Order is the remainder because the benchmark accepts percentages for
# the other four transaction types only.

TPCC_PERC_PAYMENT=${TPCC_PERC_PAYMENT:-7}
TPCC_PERC_ORDER_STATUS=${TPCC_PERC_ORDER_STATUS:-1}
TPCC_PERC_DELIVERY=${TPCC_PERC_DELIVERY:-1}
TPCC_PERC_STOCK_LEVEL=${TPCC_PERC_STOCK_LEVEL:-1}

for percentage_name in \
  TPCC_PERC_PAYMENT \
  TPCC_PERC_ORDER_STATUS \
  TPCC_PERC_DELIVERY \
  TPCC_PERC_STOCK_LEVEL; do
  percentage_value=${!percentage_name}
  if [[ ! "$percentage_value" =~ ^(0|[1-9][0-9]*)$ ]] || ((percentage_value > 100)); then
    echo "ERROR: $percentage_name must be an integer in [0, 100]: $percentage_value" >&2
    return 1
  fi
done

tpcc_non_new_order_total=$((
  TPCC_PERC_PAYMENT + TPCC_PERC_ORDER_STATUS +
  TPCC_PERC_DELIVERY + TPCC_PERC_STOCK_LEVEL
))
if ((tpcc_non_new_order_total > 100)); then
  echo "ERROR: non-New-Order transaction percentages exceed 100" >&2
  return 1
fi

TPCC_PERC_NEW_ORDER=$((100 - tpcc_non_new_order_total))
