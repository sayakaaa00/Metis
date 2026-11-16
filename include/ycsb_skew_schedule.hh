#pragma once

// In-run YCSB skew schedule and interval-throughput log for the non-adaptive
// YCSB binaries (Cicada, ERMIA). Same flags and log format as ycsb_silo.cc /
// AdaptiveControl::run_control_loop, so experiments/metis/dynamic.py
// can drive these binaries unchanged. Include from exactly one translation
// unit per binary (it defines gflags), and never together with ycsb_silo.cc.
// All flags default to off, in which case the loop only sleeps FLAGS_extime.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>

#include "gflags/gflags.h"

#include "adaptive_state.hh"
#include "atomic_wrapper.hh"
#include "result.hh"
#include "tsc.hh"

DECLARE_uint64(clocks_per_us);
DECLARE_uint64(extime);
DECLARE_double(ycsb_zipf_skew);

DEFINE_bool(ycsb_skew_change_enable, false, "Enable the first in-run YCSB Zipf skew change");
DEFINE_double(ycsb_zipf_skew2, 0.0, "Zipf skew after ycsb_skew_change_time_sec");
DEFINE_uint64(ycsb_skew_change_time_sec, 0, "Seconds from start for the first skew change");
DEFINE_bool(ycsb_skew_change_enable2, false, "Enable the second in-run YCSB Zipf skew change");
DEFINE_double(ycsb_zipf_skew3, 0.0, "Zipf skew after ycsb_skew_change_time_sec2");
DEFINE_uint64(ycsb_skew_change_time_sec2, 0, "Seconds from start for the second skew change");
DEFINE_uint64(benchmark_interval_tps_log_us, 0,
              "Log committed-transaction throughput every N us to stderr (0 = off)");

struct YcsbSkewScheduleLoop {
  std::size_t total_threads;

  void operator()(std::uint64_t start_tsc) const {
    const bool change1 = FLAGS_ycsb_skew_change_enable && FLAGS_ycsb_skew_change_time_sec > 0;
    const bool change2 = FLAGS_ycsb_skew_change_enable2 && FLAGS_ycsb_skew_change_time_sec2 > 0;
    const std::uint64_t log_us = FLAGS_benchmark_interval_tps_log_us;
    if (!change1 && !change2 && log_us == 0) {  // original behavior
      for (std::size_t i = 0; i < FLAGS_extime; ++i)
        std::this_thread::sleep_for(std::chrono::seconds(1));
      return;
    }
    const std::uint64_t cpus = FLAGS_clocks_per_us;
    const std::uint64_t c1 = FLAGS_ycsb_skew_change_time_sec * cpus * 1000000ULL;
    const std::uint64_t c2 = FLAGS_ycsb_skew_change_time_sec2 * cpus * 1000000ULL;
    const std::uint64_t tick_us = log_us > 0 ? std::min<std::uint64_t>(log_us, 10000) : 10000;
    bool changed1 = false, changed2 = false;
    std::uint64_t last_tsc = start_tsc, last_committed = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(FLAGS_extime);
    for (;;) {
      const auto now_wall = std::chrono::steady_clock::now();
      if (now_wall >= deadline) break;
      std::this_thread::sleep_for(std::min(
          std::chrono::microseconds(tick_us),
          std::chrono::duration_cast<std::chrono::microseconds>(deadline - now_wall)));
      const std::uint64_t now = rdtscp();
      if (change1 && !changed1 && now - start_tsc >= c1) {
        g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew2, std::memory_order_release);
        std::fprintf(stderr, "[YCSB] Zipf skew changed (phase 1): %g -> %g\n",
                     FLAGS_ycsb_zipf_skew, FLAGS_ycsb_zipf_skew2);
        changed1 = true;
      }
      if (change2 && !changed2 && now - start_tsc >= c2) {
        g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew3, std::memory_order_release);
        std::fprintf(stderr, "[YCSB] Zipf skew changed (phase 2): %g -> %g\n",
                     FLAGS_ycsb_zipf_skew2, FLAGS_ycsb_zipf_skew3);
        changed2 = true;
      }
      if (log_us > 0 && now - last_tsc >= log_us * cpus) {
        std::uint64_t committed = 0;
        for (std::size_t i = 0; i < total_threads; ++i)
          committed += loadAcquire(CCBenchResults[i].local_commit_counts_);
        const double interval_s = static_cast<double>(now - last_tsc) / (cpus * 1e6);
        const double bench_s = static_cast<double>(now - start_tsc) / (cpus * 1e6);
        const std::uint64_t delta = committed - last_committed;
        std::fprintf(stderr,
                     "[TPS sample] bench_s=%.3f interval_tps=%.1f interval_committed=%llu "
                     "interval_s=%.6f\n",
                     bench_s, static_cast<double>(delta) / interval_s,
                     static_cast<unsigned long long>(delta), interval_s);
        last_tsc = now;
        last_committed = committed;
      }
    }
  }
};
