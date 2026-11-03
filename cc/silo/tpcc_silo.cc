#include <fcntl.h>

#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

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

DEFINE_bool(tpcc_epoch_diagnostics, false,
            "Log Silo epoch progress during the TPC-C benchmark.");
DEFINE_bool(tpcc_pin_workers, true,
            "Pin each TPC-C worker to a socket-priority CPU (false lets the OS schedule it).");
DEFINE_string(tpcc_pin_order, "socket0_first",
              "Pinned worker CPU order: socket0_first or physical_first.");
DEFINE_uint64(tpcc_fixed_active_workers, 0,
              "Run only the first N workers without a TAM controller (0: all).");

namespace {

std::vector<std::pair<std::uint64_t, std::uint32_t>> parseWarehouseSchedule() {
  std::vector<std::pair<std::uint64_t, std::uint32_t>> schedule;
  if (FLAGS_tpcc_active_warehouse_schedule.empty()) return schedule;
#ifndef METIS_TEST
  throw std::invalid_argument(
      "TPC-C warehouse schedule requires the tpcc_metis_test binary");
#endif
  // The METIS_TEST build provides live home-warehouse remapping for every
  // controller. AdaTAM can therefore use the same schedule as Metis-test.
  std::istringstream input(FLAGS_tpcc_active_warehouse_schedule);
  std::string item;
  while (std::getline(input, item, ',')) {
    unsigned long long seconds = 0;
    unsigned int warehouses = 0;
    char trailing = '\0';
    if (std::sscanf(item.c_str(), "%llu:%u%c", &seconds, &warehouses,
                    &trailing) != 2 ||
        warehouses == 0 || warehouses > FLAGS_tpcc_num_wh ||
        warehouses > std::numeric_limits<std::uint16_t>::max() ||
        (!schedule.empty() && seconds <= schedule.back().first) ||
        seconds >= FLAGS_extime) {
      throw std::invalid_argument("Invalid TPC-C warehouse schedule: " + item);
    }
    schedule.emplace_back(seconds, warehouses);
  }
  const auto initial = FLAGS_tpcc_active_warehouse_count == 0
      ? FLAGS_tpcc_num_wh : FLAGS_tpcc_active_warehouse_count;
  if (schedule.empty() || schedule.front().first != 0 ||
      schedule.front().second != initial) {
    throw std::invalid_argument(
        "TPC-C warehouse schedule must start at 0 with the initial count");
  }
  return schedule;
}

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

int validateItemZipfDistribution() {
  g_tpcc_item_zipf_distribution.initialize(
      FLAGS_tpcc_num_items, FLAGS_tpcc_item_zipf_skew,
      FLAGS_tpcc_item_zipf_seed);
  Xoroshiro128Plus rng;
  FastZipf zipf(&rng, FLAGS_tpcc_item_zipf_skew, FLAGS_tpcc_num_items,
                g_tpcc_item_zipf_distribution.zetan);
  TPCCQuery::Option option;
  option.item_zipf = &zipf;
  std::vector<std::uint64_t> counts(FLAGS_tpcc_num_items + 1, 0);
  std::uint64_t sampled = 0;
  std::uint64_t orders = 0;
  std::uint64_t rollback_orders = 0;
  while (sampled < FLAGS_tpcc_item_zipf_validation_samples) {
    TPCCQuery::NewOrder order;
    order.generate(1, option);
    ++orders;
    rollback_orders += order.rbk == 1;
    for (unsigned int line = 0; line < order.ol_cnt; ++line) {
      const auto item = order.items[line].ol_i_id;
      const bool intentional_rollback = order.rbk == 1 &&
          line + 1 == order.ol_cnt && item > option.max_items;
      if (order.rbk == 1 && line + 1 == order.ol_cnt &&
          item <= option.max_items) return 1;
      if (intentional_rollback && item > 2 * option.max_items) return 1;
      if (!intentional_rollback &&
          (item < ID_START || item > option.max_items)) return 1;
      for (unsigned int earlier = 0; earlier < line; ++earlier)
        if (order.items[earlier].ol_i_id == item) return 1;
      if (!intentional_rollback && sampled < FLAGS_tpcc_item_zipf_validation_samples) {
        ++counts[item];
        ++sampled;
      }
    }
  }
  if (!FLAGS_tpcc_item_zipf_histogram_path.empty()) {
    std::ofstream output(FLAGS_tpcc_item_zipf_histogram_path);
    if (!output) {
      std::fprintf(stderr, "Cannot open item Zipf histogram output\n");
      return 1;
    }
    output << "rank,item_id,count\n";
    for (std::uint32_t rank = 0; rank < FLAGS_tpcc_num_items; ++rank) {
      const auto item = g_tpcc_item_zipf_distribution.item_for_rank[rank];
      output << rank + 1 << ',' << item << ',' << counts[item] << '\n';
    }
    if (!output) return 1;
  }
  std::uint64_t top100 = 0;
  for (std::size_t rank = 0;
       rank < std::min<std::size_t>(100, FLAGS_tpcc_num_items); ++rank)
    top100 += counts[g_tpcc_item_zipf_distribution.item_for_rank[rank]];
  std::printf("[TPC-C item Zipf validation] theta=%.6f samples=%llu "
              "orders=%llu rollback_orders=%llu duplicate_orders=0 "
              "top100=%llu top100_share=%.8f\n",
              FLAGS_tpcc_item_zipf_skew,
              static_cast<unsigned long long>(FLAGS_tpcc_item_zipf_validation_samples),
              static_cast<unsigned long long>(orders),
              static_cast<unsigned long long>(rollback_orders),
              static_cast<unsigned long long>(top100),
              static_cast<double>(top100) /
                  FLAGS_tpcc_item_zipf_validation_samples);
  return 0;
}

} // namespace

int main(int argc, char* argv[]) try {
  gflags::SetUsageMessage("TPC-C Silo benchmark.");
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  chkArg();
  if (FLAGS_tpcc_fixed_active_workers > TotalThreadNum ||
      (FLAGS_tpcc_fixed_active_workers != 0 &&
       (FLAGS_metis_test_enable || FLAGS_metis_paper_enable ||
        FLAGS_ada_tam_enable))) {
    std::fprintf(stderr,
                 "tpcc_fixed_active_workers must be <= total workers and "
                 "cannot be combined with a TAM controller\n");
    return 1;
  }
  if (FLAGS_tpcc_pin_order != "socket0_first" &&
      FLAGS_tpcc_pin_order != "physical_first") {
    std::fprintf(stderr,
                 "tpcc_pin_order must be socket0_first or physical_first\n");
    return 1;
  }
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
  if (FLAGS_tpcc_num_items == 0 || FLAGS_tpcc_num_items > MAX_ITEMS) {
    std::fprintf(stderr, "tpcc_num_items must be in [1, %zu]\n", MAX_ITEMS);
    return 1;
  }
  if (FLAGS_tpcc_item_zipf_enable &&
      (FLAGS_tpcc_num_items < 15 ||
       !std::isfinite(FLAGS_tpcc_item_zipf_skew) ||
       FLAGS_tpcc_item_zipf_skew < 0.0 ||
       FLAGS_tpcc_item_zipf_skew >= 1.0)) {
    std::fprintf(stderr,
                 "item Zipf requires at least 15 items and theta in [0, 1)\n");
    return 1;
  }
  if (FLAGS_tpcc_item_zipf_validation_samples != 0 &&
      !FLAGS_tpcc_item_zipf_enable) {
    std::fprintf(stderr,
                 "item Zipf validation requires tpcc_item_zipf_enable=true\n");
    return 1;
  }
  if (!FLAGS_tpcc_item_zipf_histogram_path.empty() &&
      FLAGS_tpcc_item_zipf_validation_samples == 0) {
    std::fprintf(stderr,
                 "item Zipf histogram requires validation samples\n");
    return 1;
  }
  if (FLAGS_tpcc_item_zipf_enable &&
      (FLAGS_tpcc_hot_item_ratio != 0.0 ||
       FLAGS_tpcc_hot_transaction_mode ||
       FLAGS_tpcc_hot_item_validation_samples != 0)) {
    std::fprintf(stderr,
                 "item Zipf cannot be combined with TPC-C hot-item modes\n");
    return 1;
  }
  std::vector<std::pair<std::uint64_t, std::uint32_t>> warehouse_schedule;
  try {
    warehouse_schedule = parseWarehouseSchedule();
  } catch (const std::invalid_argument& error) {
    std::fprintf(stderr, "%s\n", error.what());
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
      FLAGS_tpcc_hot_item_count > FLAGS_tpcc_num_items) {
    std::fprintf(stderr, "tpcc_hot_item_count must be in [1, %u]\n",
                 FLAGS_tpcc_num_items);
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
  if (FLAGS_tpcc_item_zipf_validation_samples > 0) {
    return validateItemZipfDistribution();
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
  g_tpcc_runtime_active_warehouses.store(
      FLAGS_tpcc_active_warehouse_count == 0 ? FLAGS_tpcc_num_wh :
      FLAGS_tpcc_active_warehouse_count, std::memory_order_release);
  g_tpcc_benchmark_start_us.store(0, std::memory_order_release);

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
        if (FLAGS_tpcc_pin_workers) {
          if (FLAGS_tpcc_pin_order == "physical_first")
            setThreadAffinityPhysicalFirst(thid);
          else
            setThreadAffinity(thid);
        }
#endif
#if MASSTREE_USE
        MasstreeWrapper<Tuple>::thread_init(int(thid));
#endif
      },
      [](TxExecutor& trans, size_t thid) {
        if (thid == 0) trans.epoch_timer_start = rdtscp();
      },
      nullptr,
      [&adaptive](size_t thid) {
        const bool enabled =
            (FLAGS_tpcc_fixed_active_workers == 0 ||
             thid < FLAGS_tpcc_fixed_active_workers) &&
            adaptive.worker_enabled(thid);
        // The runner calls this gate only between transactions. Parked
        // workers must still acknowledge the current Silo epoch.
        if (!enabled) atomicStoreThLocalEpoch(thid, atomicLoadGE());
        return enabled;
      },
      [&adaptive, &warehouse_schedule](std::uint64_t start_tsc) {
        const auto benchmark_start = std::chrono::steady_clock::now();
        g_tpcc_benchmark_start_us.store(
            std::chrono::duration_cast<std::chrono::microseconds>(
                benchmark_start.time_since_epoch()).count(),
            std::memory_order_release);
        if (!warehouse_schedule.empty()) {
          std::fprintf(stderr,
              "[TPC-C workload] bench_s=0.000 active_warehouses=%u\n",
              warehouse_schedule.front().second);
        }
        std::size_t next_change = 1;
        bool pending_applied_check = !warehouse_schedule.empty();
        double last_change_s = 0.0;
        double last_epoch_report_s = -1.0;
        adaptive.run_control_loop(start_tsc,
            [&](std::uint64_t, std::uint64_t) {
              const double elapsed = std::chrono::duration<double>(
                  std::chrono::steady_clock::now() - benchmark_start).count();
              if (FLAGS_tpcc_epoch_diagnostics &&
                  elapsed >= last_epoch_report_s + 1.0) {
                const auto epoch = atomicLoadGE();
                const auto reclaim = __atomic_load_n(
                    &ReclamationEpoch, __ATOMIC_ACQUIRE);
                std::size_t stale = 0, inactive_stale = 0, active = 0;
                for (std::size_t i = 0; i < TotalThreadNum; ++i) {
                  const bool enabled = adaptive.worker_enabled(i);
                  active += enabled;
                  if (__atomic_load_n(&ThLocalEpoch[i].obj_,
                                      __ATOMIC_ACQUIRE) != epoch) {
                    ++stale;
                    inactive_stale += !enabled;
                  }
                }
                std::fprintf(stderr,
                    "[Silo epoch] bench_s=%.3f global=%llu reclaim=%u "
                    "stale=%zu inactive_stale=%zu active=%zu\n",
                    elapsed, static_cast<unsigned long long>(epoch), reclaim,
                    stale, inactive_stale, active);
                last_epoch_report_s = elapsed;
              }
              if (next_change < warehouse_schedule.size() &&
                  elapsed >= warehouse_schedule[next_change].first) {
                const auto warehouses = warehouse_schedule[next_change].second;
#ifdef METIS_TEST
                TPCCWorkload<Tuple, void>::set_runtime_active_warehouses(
                    warehouses);
#endif
                std::fprintf(stderr,
                    "[TPC-C workload] bench_s=%.3f active_warehouses=%u\n",
                    elapsed, warehouses);
                ++next_change;
                last_change_s = elapsed;
                pending_applied_check = true;
              }
              if (pending_applied_check && elapsed >= last_change_s + 1.0) {
                const auto warehouses =
                    g_tpcc_runtime_active_warehouses.load(
                        std::memory_order_acquire);
                std::size_t active = 0, applied = 0;
                for (std::size_t i = 0;
                     i < g_metis_test_worker_warehouses.size(); ++i) {
                  if (!adaptive.worker_enabled(i)) continue;
                  ++active;
                  applied += g_metis_test_worker_warehouses[i].load(
                      std::memory_order_acquire) == warehouses;
                }
                std::fprintf(stderr,
                    "[TPC-C workload] bench_s=%.3f active_warehouses=%u applied_workers=%zu/%zu\n",
                    elapsed, warehouses, applied, active);
                pending_applied_check = false;
              }
            });
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
