#include <fcntl.h>

#include <cmath>
#include <filesystem>

#define GLOBAL_VALUE_DEFINE

#include "include/atomic_tool.hh"
#include "include/common.hh"
#include "include/result.hh"
#include "include/transaction.hh"
#include "include/util.hh"

#include "../../include/cpu.hh"
#include "../../include/adaptive_control.hh"
#include "../../include/debug.hh"
#include "../../include/fileio.hh"
#include "../../include/masstree_wrapper.hh"
#include "../../include/result.hh"
#include "../../include/tpcc.hh"
#include "../../include/tsc.hh"
#include "../../include/util.hh"

#include "../../common/runner.hh"

using namespace std;

namespace {

void printHotItemStats(const char* label) {
  const std::uint64_t total =
      g_tpcc_item_selections.load(std::memory_order_relaxed);
  const std::uint64_t hot =
      g_tpcc_hot_branch_selections.load(std::memory_order_relaxed);
  const double observed =
      total == 0 ? 0.0 : static_cast<double>(hot) / total;
  std::printf(
      "[TPC-C hot-item stats] mode=%s total=%llu hot=%llu "
      "observed_ratio=%.6f configured_ratio=%.6f "
      "hot_item_count=%u hot_supply_warehouse_count=%u\n",
      label, static_cast<unsigned long long>(total),
      static_cast<unsigned long long>(hot), observed,
      FLAGS_tpcc_hot_item_ratio, FLAGS_tpcc_hot_item_count,
      FLAGS_tpcc_hot_supply_warehouse_count);
}

void printHotTransactionStats(const char* label) {
  const std::uint64_t transactions =
      g_tpcc_neworder_transactions.load(std::memory_order_relaxed);
  const std::uint64_t hot_transactions =
      g_tpcc_hot_neworder_transactions.load(std::memory_order_relaxed);
  const std::uint64_t lines =
      g_tpcc_neworder_lines.load(std::memory_order_relaxed);
  const std::uint64_t remote_lines =
      g_tpcc_neworder_remote_lines.load(std::memory_order_relaxed);
  const double observed_hot_ratio =
      transactions == 0 ? 0.0
                        : static_cast<double>(hot_transactions) / transactions;
  const double observed_remote_ratio =
      lines == 0 ? 0.0 : static_cast<double>(remote_lines) / lines;
  char district_histogram[256];
  std::size_t histogram_size = 0;
  for (std::size_t district = 0; district < DIST_PER_WARE; ++district) {
    const auto count =
        g_tpcc_hot_district_counts[district].load(std::memory_order_relaxed);
    const int written = std::snprintf(
        district_histogram + histogram_size,
        sizeof(district_histogram) - histogram_size, "%s%zu:%llu",
        district == 0 ? "" : ";", district + ID_START,
        static_cast<unsigned long long>(count));
    if (written < 0 || static_cast<std::size_t>(written) >=
                           sizeof(district_histogram) - histogram_size) {
      break;
    }
    histogram_size += static_cast<std::size_t>(written);
  }
  std::printf(
      "[TPC-C hot-transaction stats] mode=%s neworder_attempts=%llu "
      "hot_neworder_attempts=%llu observed_hot_ratio=%.6f "
      "configured_hot_ratio=%.6f lines=%llu remote_lines=%llu "
      "observed_remote_line_ratio=%.6f hot_warehouse=%u hot_item_count=%u "
      "hot_district_count=%u hot_district_hist=%s\n",
      label, static_cast<unsigned long long>(transactions),
      static_cast<unsigned long long>(hot_transactions), observed_hot_ratio,
      FLAGS_tpcc_hot_transaction_ratio, static_cast<unsigned long long>(lines),
      static_cast<unsigned long long>(remote_lines), observed_remote_ratio,
      FLAGS_tpcc_hot_warehouse_id, FLAGS_tpcc_hot_item_count,
      FLAGS_tpcc_hot_district_count, district_histogram);
}

int validateHotItemDistribution() {
  g_tpcc_item_selections.store(0, std::memory_order_relaxed);
  g_tpcc_hot_branch_selections.store(0, std::memory_order_relaxed);
  TPCCQuery::Option option;
  for (std::uint64_t i = 0; i < FLAGS_tpcc_hot_item_validation_samples; ++i) {
    const std::uint32_t item = TPCCQuery::NewOrder::generate_item_id(option);
    if (item < ID_START || item > option.max_items) return 1;
  }
  printHotItemStats("validation");
  const double total = static_cast<double>(
      g_tpcc_item_selections.load(std::memory_order_relaxed));
  const double hot = static_cast<double>(
      g_tpcc_hot_branch_selections.load(std::memory_order_relaxed));
  const double observed = total == 0.0 ? 0.0 : hot / total;
  const double expected = FLAGS_tpcc_hot_item_ratio;
  const double sigma = total == 0.0
                           ? 0.0
                           : std::sqrt(expected * (1.0 - expected) / total);
  const double tolerance = std::max(0.002, 6.0 * sigma);
  const bool pass = total > 0.0 && std::fabs(observed - expected) <= tolerance;
  std::printf("[TPC-C hot-item validation] tolerance=%.6f result=%s\n",
              tolerance, pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}

} // namespace

int main(int argc, char* argv[]) try {
  gflags::SetUsageMessage("TPC-C Silo benchmark.");
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  chkArg();
  if (FLAGS_tpcc_home_warehouse_assignment != "worker_affined" &&
      FLAGS_tpcc_home_warehouse_assignment != "random_per_transaction" &&
      FLAGS_tpcc_home_warehouse_assignment != "randomized_worker_affined") {
    std::fprintf(stderr,
                 "tpcc_home_warehouse_assignment must be one of: "
                 "worker_affined, random_per_transaction, "
                 "randomized_worker_affined\n");
    return 1;
  }
  if (FLAGS_tpcc_active_warehouse_count > FLAGS_tpcc_num_wh) {
    std::fprintf(stderr,
                 "tpcc_active_warehouse_count must be in [1, tpcc_num_wh] (or 0 for all warehouses)\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_item_ratio < 0.0 || FLAGS_tpcc_hot_item_ratio > 1.0) {
    std::fprintf(stderr, "tpcc_hot_item_ratio must be in [0, 1]\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_transaction_ratio < 0.0 ||
      FLAGS_tpcc_hot_transaction_ratio > 1.0) {
    std::fprintf(stderr, "tpcc_hot_transaction_ratio must be in [0, 1]\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_district_count < 1 ||
      FLAGS_tpcc_hot_district_count > DIST_PER_WARE) {
    std::fprintf(stderr, "tpcc_hot_district_count must be in [1, %zu]\n",
                 DIST_PER_WARE);
    return 1;
  }
  if (FLAGS_tpcc_hot_transaction_mode && FLAGS_tpcc_hot_item_ratio != 0.0) {
    std::fprintf(stderr,
                 "tpcc_hot_item_ratio must be 0 in hot-transaction mode\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_transaction_mode && FLAGS_tpcc_hot_item_count < 15) {
    std::fprintf(stderr,
                 "tpcc_hot_item_count must be at least 15 in hot-transaction mode\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_warehouse_id == 0 ||
      FLAGS_tpcc_hot_warehouse_id > FLAGS_tpcc_num_wh) {
    std::fprintf(stderr, "tpcc_hot_warehouse_id must be in [1, tpcc_num_wh]\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_item_count == 0 ||
      FLAGS_tpcc_hot_item_count > MAX_ITEMS) {
    std::fprintf(stderr, "tpcc_hot_item_count must be in [1, %zu]\n",
                 MAX_ITEMS);
    return 1;
  }
  if (FLAGS_tpcc_hot_supply_warehouse_count == 0 ||
      FLAGS_tpcc_hot_supply_warehouse_count > FLAGS_tpcc_num_wh) {
    std::fprintf(
        stderr,
        "tpcc_hot_supply_warehouse_count must be in [1, tpcc_num_wh]\n");
    return 1;
  }
  if (FLAGS_tpcc_hot_item_validation_samples > 0) {
    return validateHotItemDistribution();
  }
  if (FLAGS_tpcc_hot_item_stats) {
    g_tpcc_item_selections.store(0, std::memory_order_relaxed);
    g_tpcc_hot_branch_selections.store(0, std::memory_order_relaxed);
  }
  if (FLAGS_tpcc_hot_transaction_stats) {
    g_tpcc_neworder_transactions.store(0, std::memory_order_relaxed);
    g_tpcc_hot_neworder_transactions.store(0, std::memory_order_relaxed);
    g_tpcc_neworder_lines.store(0, std::memory_order_relaxed);
    g_tpcc_neworder_remote_lines.store(0, std::memory_order_relaxed);
    for (std::size_t district = 0; district < DIST_PER_WARE; ++district) {
      g_tpcc_hot_district_counts[district].store(0,
                                                std::memory_order_relaxed);
    }
  }
  g_current_ycsb_skew.store(0.0, std::memory_order_release);

  AdaptiveControl adaptive;
  adaptive.init(TotalThreadNum);
  adaptive.setup_logs(std::filesystem::path("experiments") /
                      "paper_replication" / "logs");

  TPCCWorkload<Tuple, void>::displayWorkloadParameter();
  TPCCWorkload<Tuple, void>::makeDB(nullptr);

  initResult(TotalThreadNum);

  ccbench::RunnerOptions opts;
  opts.display_per_tx = true;

  ccbench::run<TxExecutor, TransactionStatus, TPCCWorkload<Tuple, void>>(
      TotalThreadNum, opts,
      [](size_t thid, const bool& quit, Backoff& /*unused*/) {
        return TxExecutor(thid, &CCBenchResults[thid], quit);
      },
      [](TxExecutor& trans, size_t thid) {
#if WAL
        std::string logpath;
        genLogFile(logpath, thid);
        trans.logfile_.open(logpath, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        trans.logfile_.ftruncate(1000000000);
#else
        (void) trans;
#endif
#ifdef Linux
        setThreadAffinity(thid);
#endif
#if MASSTREE_USE
        MasstreeWrapper<Tuple>::thread_init(int(thid));
#endif
      },
      [](TxExecutor& trans, size_t thid) {
        if (thid == 0) trans.epoch_timer_start = rdtscp();
      },
      nullptr,
      [&adaptive](size_t thid) { return adaptive.worker_enabled(thid); },
      [&adaptive](std::uint64_t start_tsc) {
        adaptive.run_control_loop(start_tsc);
      },
      [&adaptive]() {
        adaptive.finish();
        if (FLAGS_tpcc_hot_item_stats) { printHotItemStats("benchmark"); }
        if (FLAGS_tpcc_hot_transaction_stats) {
          printHotTransactionStats("benchmark");
        }
      });

  return 0;
} catch (const bad_alloc&) { ERR; }
