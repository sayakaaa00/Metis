#pragma once

#include <cstdint>

#include "gflags/gflags.h"

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_uint32(tpcc_num_wh, 1, "The number of warehouses");
DEFINE_uint32(tpcc_num_items, 100000,
              "Number of Item rows and Stock rows per warehouse");
DEFINE_uint32(tpcc_active_warehouse_count, 0,
              "Number of warehouses used as home warehouses; 0 uses tpcc_num_wh");
DEFINE_string(tpcc_active_warehouse_schedule, "",
              "In-run changes of the active warehouse count as "
              "seconds:count[,seconds:count...], starting at 0 (Silo only)");
DEFINE_string(tpcc_home_warehouse_assignment, "worker_affined",
              "Home warehouse of a transaction: worker_affined (fixed per "
              "worker) or random_per_transaction");
DEFINE_bool(tpcc_log_retry_conflicts, true,
            "Print expected TPC-C insert conflicts while retrying");
DEFINE_uint64(tpcc_perc_payment, 43, "The percentage of Payment transactions");
DEFINE_uint64(tpcc_perc_order_status, 4,
              "The percentage of Order-Status transactions");
DEFINE_uint64(tpcc_perc_delivery, 4, "The percentage of Delivery transactions");
DEFINE_uint64(tpcc_perc_stock_level, 4,
              "The percentage of Stock-Level transactions");
DEFINE_bool(tpcc_retry_same_type, true,
            "Keep the selected transaction type across abort retries");
DEFINE_uint32(tpcc_interactive_ms, 0,
              "Sleep milliseconds per SQL(-equivalent) unit");
#else
DECLARE_uint32(tpcc_num_wh);
DECLARE_uint32(tpcc_num_items);
DECLARE_uint32(tpcc_active_warehouse_count);
DECLARE_string(tpcc_active_warehouse_schedule);
DECLARE_string(tpcc_home_warehouse_assignment);
DECLARE_bool(tpcc_log_retry_conflicts);
DECLARE_uint64(tpcc_perc_payment);
DECLARE_uint64(tpcc_perc_order_status);
DECLARE_uint64(tpcc_perc_delivery);
DECLARE_uint64(tpcc_perc_stock_level);
DECLARE_bool(tpcc_retry_same_type);
DECLARE_uint64(tpcc_interactive_ms);
#endif

constexpr std::size_t DIST_PER_WARE{10};
constexpr std::size_t MAX_ITEMS{100000};
constexpr std::size_t CUST_PER_DIST{3000};
constexpr std::size_t LASTNAME_LEN{16};
