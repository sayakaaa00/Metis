#pragma once

#include <x86intrin.h>

#include <atomic>
#include <cmath>
#include <iostream>
#include <limits>

#include "atomic_wrapper.hh"
#include "result.hh"
#include "tsc.hh"
#include "util.hh"
#include "gflags/gflags.h"

using namespace std;

// Parameters of the adaptive backoff (gflags).
#ifdef GLOBAL_VALUE_DEFINE
DEFINE_uint64(backoff_update_period_us, 5000,
              "Backoff update period in microseconds");
DEFINE_double(backoff_step_us, 0.5,
              "Change of the base backoff per update in microseconds");
DEFINE_bool(backoff_fixed_enable, false,
            "Disable adaptive updates and use a fixed base backoff");
DEFINE_double(backoff_fixed_us, 0.0,
              "Fixed base backoff in microseconds when backoff_fixed_enable=true");
#else
DECLARE_uint64(backoff_update_period_us);
DECLARE_double(backoff_step_us);
DECLARE_bool(backoff_fixed_enable);
DECLARE_double(backoff_fixed_us);
#endif

class Backoff {
public:
  static std::atomic<double> Backoff_;
  static thread_local uint32_t ConsecutiveAborts_;
  static constexpr double kMinBackoff = 0;
  static constexpr double kMaxBackoff = 1000;

  uint64_t last_committed_txs_ = 0;
  double last_committed_tput_ = 0;
  uint64_t last_backoff_ = 0;
  uint64_t last_time_ = 0;
  size_t clocks_per_us_;

  Backoff(size_t clocks_per_us) { init(clocks_per_us); }

  void init(size_t clocks_per_us) {
    last_time_ = rdtscp();
    clocks_per_us_ = clocks_per_us;
    if (FLAGS_backoff_fixed_enable) {
      Backoff_.store(clamp_backoff(FLAGS_backoff_fixed_us),
                     std::memory_order_release);
    }
  }

  bool check_update_backoff() {
    if (FLAGS_backoff_fixed_enable) return false;

    const uint64_t period_cycles =
        static_cast<uint64_t>(FLAGS_backoff_update_period_us) * clocks_per_us_;
    if (chkClkSpan(last_time_, rdtscp(), period_cycles))
      return true;
    else
      return false;
  }

  void update_backoff(const uint64_t committed_txs) {
    if (FLAGS_backoff_fixed_enable) {
      Backoff_.store(clamp_backoff(FLAGS_backoff_fixed_us),
                     std::memory_order_release);
      return;
    }

    uint64_t now = rdtscp();
    uint64_t time_diff = now - last_time_;
    last_time_ = now;

    double new_backoff = Backoff_.load(std::memory_order_acquire);
    double backoff_diff = new_backoff - last_backoff_;

    uint64_t committed_diff = committed_txs - last_committed_txs_;
    double committed_tput = static_cast<double>(committed_diff) /
                            (static_cast<double>(time_diff) / clocks_per_us_) *
                            pow(10.0, 6);
    double committed_tput_diff = committed_tput - last_committed_tput_;

    last_committed_txs_ = committed_txs;
    last_committed_tput_ = committed_tput;
    last_backoff_ = new_backoff;

    double gradient;
    if (backoff_diff != 0)
      gradient = committed_tput_diff / backoff_diff;
    else
      gradient = 0;

    double step = FLAGS_backoff_step_us;
    if (gradient < 0)
      new_backoff -= step;
    else if (gradient > 0)
      new_backoff += step;
    else {
      if ((committed_txs & 1) == 0 ||
          new_backoff == kMaxBackoff) // 確率はおよそ 1/2, すなわちランダム．
        new_backoff -= step;
      else if ((committed_txs & 1) == 1 || new_backoff == kMinBackoff)
        new_backoff += step;
    }

    Backoff_.store(clamp_backoff(new_backoff), std::memory_order_release);
  }

  static void backoff(size_t clocks_per_us) {
    uint64_t start(rdtscp()), stop;
    double now_backoff = current_backoff_us();
    if (ConsecutiveAborts_ != std::numeric_limits<uint32_t>::max()) {
      ++ConsecutiveAborts_;
    }

    // printf("clocks_per_us * now_backoff:\t%lu\n",
    // static_cast<uint64_t>(static_cast<double>(clocks_per_us) * now_backoff));
    for (;;) {
      _mm_pause();
      stop = rdtscp();
      if (chkClkSpan(start, stop,
                     static_cast<uint64_t>(static_cast<double>(clocks_per_us) *
                                           now_backoff)))
        break;
    }
  }

  // Called on commit: the next abort starts again from the base backoff.
  static void reset() { ConsecutiveAborts_ = 0; }

  static double clamp_backoff(double backoff_us) {
    if (backoff_us < kMinBackoff) return kMinBackoff;
    if (backoff_us > kMaxBackoff) return kMaxBackoff;
    return backoff_us;
  }

  // Exponential backoff: base * 2^(consecutive aborts), capped at kMaxBackoff.
  static double current_backoff_us() {
    const double base_backoff =
        clamp_backoff(Backoff_.load(std::memory_order_acquire));
    if (base_backoff <= 0.0) return 0.0;

    double exp_backoff = std::ldexp(base_backoff, ConsecutiveAborts_);
    return clamp_backoff(exp_backoff);
  }
};

[[maybe_unused]] inline void
leaderBackoffWork([[maybe_unused]] Backoff& backoff,
                  [[maybe_unused]] std::vector<Result>& res) {
  if (backoff.check_update_backoff()) {
    uint64_t sum_committed_txs(0);
    for (auto& th : res) {
      sum_committed_txs += loadAcquire(th.local_commit_counts_);
    }
    backoff.update_backoff(sum_committed_txs);
  }
}

#ifdef GLOBAL_VALUE_DEFINE
std::atomic<double> Backoff::Backoff_(0);
thread_local uint32_t Backoff::ConsecutiveAborts_ = 0;
#endif
