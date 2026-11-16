#include <fcntl.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#define GLOBAL_VALUE_DEFINE

#include "include/atomic_tool.hh"
#include "include/common.hh"
#include "include/result.hh"
#include "include/transaction.hh"
#include "include/util.hh"

#include "../../include/cpu.hh"
#include "../../../metis/control_loop.hh"
#include "../../include/debug.hh"
#include "../../include/fileio.hh"
#include "../../include/masstree_wrapper.hh"
#include "../../include/result.hh"
#include "../../include/tpcc.hh"
#include "../../include/tsc.hh"
#include "../../include/util.hh"

#include "../../common/runner.hh"

using namespace std;

DEFINE_bool(tpcc_pin_workers, true,
            "Pin each TPC-C worker to a CPU (false lets the OS schedule it).");
DEFINE_string(tpcc_pin_order, "socket0_first",
              "Pinned worker CPU order: socket0_first or physical_first.");

namespace {

// --tpcc_active_warehouse_schedule="0:16,20:1,40:4": W=16 from 0 s, W=1 from
// 20 s, W=4 from 40 s.
std::vector<std::pair<std::uint64_t, std::uint32_t>> parseWarehouseSchedule() {
  std::vector<std::pair<std::uint64_t, std::uint32_t>> schedule;
  if (FLAGS_tpcc_active_warehouse_schedule.empty()) return schedule;
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

} // namespace

int main(int argc, char* argv[]) try {
  gflags::SetUsageMessage("TPC-C Silo benchmark.");
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  chkArg();
  if (FLAGS_tpcc_pin_order != "socket0_first" &&
      FLAGS_tpcc_pin_order != "physical_first") {
    std::fprintf(stderr,
                 "tpcc_pin_order must be socket0_first or physical_first\n");
    return 1;
  }
  if (FLAGS_tpcc_home_warehouse_assignment != "worker_affined" &&
      FLAGS_tpcc_home_warehouse_assignment != "random_per_transaction") {
    std::fprintf(stderr,
                 "tpcc_home_warehouse_assignment must be worker_affined or "
                 "random_per_transaction\n");
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
  std::vector<std::pair<std::uint64_t, std::uint32_t>> warehouse_schedule;
  try {
    warehouse_schedule = parseWarehouseSchedule();
  } catch (const std::invalid_argument& error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
  g_tpcc_runtime_active_warehouses.store(
      FLAGS_tpcc_active_warehouse_count == 0 ? FLAGS_tpcc_num_wh :
      FLAGS_tpcc_active_warehouse_count, std::memory_order_release);

  ControlLoop control;
  control.init(TotalThreadNum);
  control.setup_logs("logs");

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
      // Worker gate: inactive workers park between transactions.
      [&control](TxExecutor& trans, size_t thid) {
        if (control.worker_enabled(thid)) return true;
        park_worker(trans);
        return false;
      },
      // Control loop: controller updates and the in-run warehouse schedule.
      [&control, &warehouse_schedule](std::uint64_t start_tsc) {
        const auto benchmark_start = std::chrono::steady_clock::now();
        if (!warehouse_schedule.empty()) {
          std::fprintf(stderr,
              "[TPC-C workload] bench_s=0.000 active_warehouses=%u\n",
              warehouse_schedule.front().second);
        }
        std::size_t next_change = 1;
        bool pending_applied_check = !warehouse_schedule.empty();
        double last_change_s = 0.0;
        control.run_control_loop(start_tsc,
            [&](std::uint64_t, std::uint64_t) {
              const double elapsed = std::chrono::duration<double>(
                  std::chrono::steady_clock::now() - benchmark_start).count();
              if (next_change < warehouse_schedule.size() &&
                  elapsed >= warehouse_schedule[next_change].first) {
                const auto warehouses = warehouse_schedule[next_change].second;
                TPCCWorkload<Tuple, void>::set_runtime_active_warehouses(
                    warehouses);
                std::fprintf(stderr,
                    "[TPC-C workload] bench_s=%.3f active_warehouses=%u\n",
                    elapsed, warehouses);
                ++next_change;
                last_change_s = elapsed;
                pending_applied_check = true;
              }
              // One second after a change, report how many active workers
              // have switched to the new home map.
              if (pending_applied_check && elapsed >= last_change_s + 1.0) {
                const auto warehouses =
                    g_tpcc_runtime_active_warehouses.load(
                        std::memory_order_acquire);
                std::size_t active = 0, applied = 0;
                for (std::size_t i = 0; i < g_tpcc_worker_warehouses.size();
                     ++i) {
                  if (!control.worker_enabled(i)) continue;
                  ++active;
                  applied += g_tpcc_worker_warehouses[i].load(
                      std::memory_order_acquire) == warehouses;
                }
                std::fprintf(stderr,
                    "[TPC-C workload] bench_s=%.3f active_warehouses=%u applied_workers=%zu/%zu\n",
                    elapsed, warehouses, applied, active);
                pending_applied_check = false;
              }
            });
      },
      [&control]() { control.finish(); });

  return 0;
} catch (const bad_alloc&) { ERR; }
