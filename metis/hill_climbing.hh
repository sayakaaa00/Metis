#pragma once

// Hill climbing: control of the number of active worker threads
// (baseline). Every control period it compares the committed throughput with
// the previous period and moves the active count by --hill_climbing_step in the
// direction that improved throughput (a random direction when the gradient is
// zero).

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>

#include "gflags/gflags.h"
#include "shared_state.hh"
#include "../ccbench/include/tsc.hh"

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_bool(hill_climbing_enable, false, "Enable hill climbing on the active thread count");
DEFINE_double(hill_climbing_step, 2.0,
              "Threads added or removed per hill-climbing update");
#else
DECLARE_bool(hill_climbing_enable);
DECLARE_double(hill_climbing_step);
#endif

DECLARE_uint64(throttle_min_threads);
DECLARE_uint64(throttle_max_threads);
DECLARE_uint64(throttle_period_us);
DECLARE_uint64(throttle_log_period_us);
DECLARE_bool(throttle_log_active_threads);

class HillClimbing {
 public:
  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    total_threads_ = total_threads;
    clocks_per_us_ = clocks_per_us;
    uint64_t max_th = FLAGS_throttle_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;
    active_threads_.store(max_th, std::memory_order_relaxed);
    g_active_threads.store(max_th, std::memory_order_release);
    last_time_ = rdtscp();
    last_committed_txs_ = 0;
    last_tput_ = 0.0;
    last_threads_ = static_cast<int64_t>(max_th);
    last_log_time_ = last_time_;
  }

  uint64_t active_threads() const {
    return active_threads_.load(std::memory_order_acquire);
  }

  void print_stats() const {
    if (!FLAGS_throttle_log_active_threads || stats_count_ == 0) return;
    const double n = static_cast<double>(stats_count_);
    const double mean = stats_sum_ / n;
    const double var = std::max(0.0, stats_sq_sum_ / n - mean * mean);
    std::fprintf(stderr,
                 "[HillClimbing] active_threads stats: count=%llu mean=%.3f stddev=%.3f\n",
                 static_cast<unsigned long long>(stats_count_), mean,
                 std::sqrt(var));
  }

  // Called from the control loop with the cumulative commit count.
  void update(uint64_t committed_txs, uint64_t /*abort_txs*/) {
    const uint64_t now = rdtscp();
    const uint64_t dt = now - last_time_;
    const uint64_t period_clocks = FLAGS_throttle_period_us * clocks_per_us_;
    if (dt < period_clocks || dt == 0) return;

    const uint64_t committed_diff = committed_txs - last_committed_txs_;
    const double committed_tput =
        static_cast<double>(committed_diff) /
        (static_cast<double>(dt) / static_cast<double>(clocks_per_us_)) * 1e6;
    const double committed_tput_diff = committed_tput - last_tput_;

    const int64_t current_threads =
        static_cast<int64_t>(active_threads_.load(std::memory_order_relaxed));
    const int64_t threads_diff = current_threads - last_threads_;

    last_time_ = now;
    last_committed_txs_ = committed_txs;
    last_tput_ = committed_tput;
    last_threads_ = current_threads;

    const double gradient =
        threads_diff != 0 ? committed_tput_diff / static_cast<double>(threads_diff)
                          : 0.0;
    double step = FLAGS_hill_climbing_step;
    if (step <= 0.0) step = 1.0;

    int64_t next = current_threads;
    if (gradient < 0.0) {
      // The previous change hurt throughput: move the other way.
      next = current_threads - static_cast<int64_t>(step);
    } else if (gradient > 0.0) {
      next = current_threads + static_cast<int64_t>(step);
    } else if ((committed_txs & 1ULL) == 0ULL) {
      // No gradient: pick a direction from the parity of the commit count.
      next = current_threads - static_cast<int64_t>(step);
    } else {
      next = current_threads + static_cast<int64_t>(step);
    }

    uint64_t min_th = FLAGS_throttle_min_threads;
    if (min_th == 0) min_th = 1;
    uint64_t max_th = FLAGS_throttle_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;
    if (next < static_cast<int64_t>(min_th)) next = static_cast<int64_t>(min_th);
    if (next > static_cast<int64_t>(max_th)) next = static_cast<int64_t>(max_th);

    active_threads_.store(static_cast<uint64_t>(next), std::memory_order_release);
    g_active_threads.store(static_cast<uint64_t>(next), std::memory_order_release);

    if (FLAGS_throttle_log_active_threads) {
      uint64_t log_period = FLAGS_throttle_log_period_us * clocks_per_us_;
      if (log_period == 0) log_period = period_clocks;
      if (now - last_log_time_ >= log_period) {
        std::fprintf(stderr,
                     "[HillClimbing] active_threads=%llu committed_txs=%llu tput=%.0f tx/s\n",
                     static_cast<unsigned long long>(active_threads()),
                     static_cast<unsigned long long>(committed_txs),
                     committed_tput);
        const double v = static_cast<double>(next);
        stats_count_ += 1;
        stats_sum_ += v;
        stats_sq_sum_ += v * v;
        last_log_time_ = now;
      }
    }
  }

 private:
  std::atomic<uint64_t> active_threads_{0};
  uint64_t total_threads_{0};
  uint64_t clocks_per_us_{0};
  uint64_t last_time_{0};
  uint64_t last_log_time_{0};
  uint64_t last_committed_txs_{0};
  double last_tput_{0.0};
  int64_t last_threads_{0};
  uint64_t stats_count_{0};
  double stats_sum_{0.0};
  double stats_sq_sum_{0.0};
};
