#include <fcntl.h>

#include <atomic>

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
#include "../../include/tsc.hh"
#include "../../include/util.hh"
#include "../../include/ycsb.hh"

#include "../../common/runner.hh"

using namespace std;

DEFINE_bool(pin_threads, true,
            "Pin each worker to a CPU (false lets the OS schedule it)");
DEFINE_string(ycsb_pin_order, "socket0_first",
              "Pinned worker CPU order: socket0_first or physical_first");
// In-run workload change: up to two skew changes at the given seconds.
DEFINE_bool(ycsb_skew_change_enable, false,
            "Enable the first in-run YCSB Zipf skew change");
DEFINE_double(ycsb_zipf_skew2, 0.0,
              "Zipf skew after ycsb_skew_change_time_sec");
DEFINE_uint64(ycsb_skew_change_time_sec, 0,
              "Seconds from start for the first skew change");
DEFINE_bool(ycsb_skew_change_enable2, false,
            "Enable the second in-run YCSB Zipf skew change");
DEFINE_double(ycsb_zipf_skew3, 0.0,
              "Zipf skew after ycsb_skew_change_time_sec2");
DEFINE_uint64(ycsb_skew_change_time_sec2, 0,
              "Seconds from start for the second skew change");

int main(int argc, char* argv[]) try {
  gflags::SetUsageMessage("YCSB Silo benchmark.");
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  chkArg();
  if (FLAGS_ycsb_pin_order != "socket0_first" &&
      FLAGS_ycsb_pin_order != "physical_first") {
    fprintf(stderr, "ycsb_pin_order must be socket0_first or physical_first\n");
    return 1;
  }
  g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew,
                            std::memory_order_release);

  AdaptiveControl adaptive;
  adaptive.init(TotalThreadNum);
  adaptive.setup_logs("logs");

  YcsbWorkload::displayWorkloadParameter();
  YcsbWorkload::makeDB<Tuple, void>(nullptr);

  initResult(TotalThreadNum);

  ccbench::run<TxExecutor, TransactionStatus, YcsbWorkload>(
      TotalThreadNum, ccbench::RunnerOptions{},
      // make_tx: silo-style, backoff is built into the executor when
      // BACK_OFF is defined; the runner-supplied `Backoff&` is unused.
      [](size_t thid, const bool& quit, Backoff& /*unused*/) {
        return TxExecutor(thid, &CCBenchResults[thid], quit);
      },
      // worker_init: WAL log file open (when WAL is defined), CPU pinning,
      // MasstreeWrapper thread_init.
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
        if (FLAGS_pin_threads) {
          if (FLAGS_ycsb_pin_order == "physical_first")
            setThreadAffinityPhysicalFirst(thid);
          else
            setThreadAffinity(thid);
        }
#endif
#if MASSTREE_USE
        MasstreeWrapper<Tuple>::thread_init(int(thid));
#endif
      },
      // worker_after_start: leader thread records epoch start TSC.
      [](TxExecutor& trans, size_t thid) {
        if (thid == 0) trans.epoch_timer_start = rdtscp();
      },
      nullptr,
      // Worker gate: inactive workers park between transactions.
      [&adaptive](TxExecutor& trans, size_t thid) {
        if (adaptive.worker_enabled(thid)) return true;
        park_worker(trans);
        return false;
      },
      // Control loop: controller updates and the in-run skew changes.
      [&adaptive](std::uint64_t start_tsc) {
        const bool change1 = FLAGS_ycsb_skew_change_enable &&
                             FLAGS_ycsb_skew_change_time_sec > 0;
        const bool change2 = FLAGS_ycsb_skew_change_enable2 &&
                             FLAGS_ycsb_skew_change_time_sec2 > 0;
        bool changed1 = false;
        bool changed2 = false;
        const std::uint64_t change1_clocks =
            FLAGS_ycsb_skew_change_time_sec * FLAGS_clocks_per_us *
            1000000ULL;
        const std::uint64_t change2_clocks =
            FLAGS_ycsb_skew_change_time_sec2 * FLAGS_clocks_per_us *
            1000000ULL;

        adaptive.run_control_loop(
            start_tsc, [&](std::uint64_t start, std::uint64_t now) {
              if (change1 && !changed1 && now - start >= change1_clocks) {
                g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew2,
                                          std::memory_order_release);
                std::cout << "[YCSB] Zipf skew changed (phase 1): "
                          << FLAGS_ycsb_zipf_skew << " -> "
                          << FLAGS_ycsb_zipf_skew2 << std::endl;
                changed1 = true;
              }
              if (change2 && !changed2 && now - start >= change2_clocks) {
                g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew3,
                                          std::memory_order_release);
                std::cout << "[YCSB] Zipf skew changed (phase 2): "
                          << FLAGS_ycsb_zipf_skew2 << " -> "
                          << FLAGS_ycsb_zipf_skew3 << std::endl;
                changed2 = true;
              }
            });
      },
      [&adaptive]() { adaptive.finish(); });

#if METIS_BREAKDOWN
  {
    uint64_t c = 0, a = 0, wc = 0, wa = 0, nc = 0, na = 0, span = 0;
    for (size_t t = 0; t < TotalThreadNum; ++t) {
      const auto& b = YcsbWorkload::breakdown()[t];
      c += b.committed; a += b.aborted; wc += b.wait_committed; wa += b.wait_aborted;
      nc += b.n_committed; na += b.n_aborted;
      if (b.last > b.first) span += b.last - b.first;
    }
    std::cout << "[BREAKDOWN] committed_cycles=" << c << " aborted_cycles=" << a
              << " wait_committed_cycles=" << wc << " wait_aborted_cycles=" << wa
              << " n_committed=" << nc << " n_aborted=" << na
              << " span_cycles=" << span << " threads=" << TotalThreadNum << std::endl;
  }
#endif

  return 0;
} catch (const bad_alloc&) { ERR; }
