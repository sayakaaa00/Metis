#pragma once

#include <atomic>
#include <cstdint>

#include "gflags/gflags.h"

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_uint32(tpcc_num_wh, 1, "The number of warehouses");
DEFINE_uint32(tpcc_active_warehouse_count, 0,
              "Number of warehouses selected as logical terminal home warehouses; 0 uses tpcc_num_wh");
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
DEFINE_uint32(tpcc_hot_item_count, 100,
              "Number of popular items in the flash-sale workload");
DEFINE_double(tpcc_hot_item_ratio, 0.0,
              "Probability that a New-Order line selects a popular item");
DEFINE_string(tpcc_home_warehouse_assignment, "worker_affined",
              "Home warehouse mode: worker_affined, random_per_transaction, or randomized_worker_affined");
DEFINE_uint64(tpcc_home_warehouse_seed, 1,
              "Seed for randomized_worker_affined home-warehouse assignment");
DEFINE_bool(tpcc_hot_transaction_mode, false,
            "Select hot New-Orders per transaction and preserve normal remote-line selection");
DEFINE_bool(tpcc_hot_transaction_keep_tpcc_routing, false,
            "Keep normal home-warehouse and district selection for hot New-Orders");
DEFINE_bool(tpcc_hot_transaction_stats, false,
            "Collect hot-transaction and remote-line counters");
DEFINE_double(tpcc_hot_transaction_ratio, 0.0,
              "Probability that a New-Order uses the hot warehouse and hot item set");
DEFINE_uint32(tpcc_hot_warehouse_id, 1,
              "Home warehouse used by hot New-Order transactions");
DEFINE_uint32(tpcc_hot_district_count, 10,
              "Number of districts used by hot New-Order transactions");
DEFINE_uint32(tpcc_hot_supply_warehouse_count, 1,
              "Supply warehouses shared by popular items");
DEFINE_bool(tpcc_hot_item_stats, false,
            "Collect hot-item selection counters");
DEFINE_uint64(tpcc_hot_item_validation_samples, 0,
              "Generate selections, report their distribution, and exit");
#else
DECLARE_uint32(tpcc_num_wh);
DECLARE_uint32(tpcc_active_warehouse_count);
DECLARE_uint64(tpcc_perc_payment);
DECLARE_uint64(tpcc_perc_order_status);
DECLARE_uint64(tpcc_perc_delivery);
DECLARE_uint64(tpcc_perc_stock_level);
DECLARE_bool(tpcc_retry_same_type);
DECLARE_uint64(tpcc_interactive_ms);
DECLARE_uint32(tpcc_hot_item_count);
DECLARE_double(tpcc_hot_item_ratio);
DECLARE_string(tpcc_home_warehouse_assignment);
DECLARE_uint64(tpcc_home_warehouse_seed);
DECLARE_bool(tpcc_hot_transaction_mode);
DECLARE_bool(tpcc_hot_transaction_keep_tpcc_routing);
DECLARE_bool(tpcc_hot_transaction_stats);
DECLARE_double(tpcc_hot_transaction_ratio);
DECLARE_uint32(tpcc_hot_warehouse_id);
DECLARE_uint32(tpcc_hot_district_count);
DECLARE_uint32(tpcc_hot_supply_warehouse_count);
DECLARE_bool(tpcc_hot_item_stats);
DECLARE_uint64(tpcc_hot_item_validation_samples);
#endif

constexpr std::size_t DIST_PER_WARE{10};
inline std::atomic<std::uint64_t> g_tpcc_item_selections{0};
inline std::atomic<std::uint64_t> g_tpcc_hot_branch_selections{0};
inline std::atomic<std::uint64_t> g_tpcc_neworder_transactions{0};
inline std::atomic<std::uint64_t> g_tpcc_hot_neworder_transactions{0};
inline std::atomic<std::uint64_t> g_tpcc_neworder_lines{0};
inline std::atomic<std::uint64_t> g_tpcc_neworder_remote_lines{0};
inline std::atomic<std::uint64_t> g_tpcc_hot_district_counts[DIST_PER_WARE]{};
constexpr std::size_t MAX_ITEMS{100000};
constexpr std::size_t CUST_PER_DIST{3000};
constexpr std::size_t LASTNAME_LEN{16};
