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
DEFINE_bool(backoff_randomized, false,
            "Cicada-style backoff (Lim et al., SIGMOD 2017, Sec. 3.9): wait a duration drawn "
            "uniformly from [0, coordinated maximum], and choose a random direction when the "
            "hill-climbing gradient is zero or undefined");
DEFINE_bool(backoff_adaptive_exponential, false,
            "Adaptive backoff only: if true, the wait is the coordinated duration * "
            "2^(consecutive aborts) (capped); if false (CCBench default), every wait "
            "is the coordinated duration itself");
DEFINE_bool(backoff_fixed_exponential, true,
            "With backoff_fixed_enable=true: if true, the wait is backoff_fixed_us * "
            "2^(consecutive aborts) (capped); if false, every wait is exactly "
            "backoff_fixed_us");
#else
DECLARE_uint64(backoff_update_period_us);
DECLARE_double(backoff_step_us);
DECLARE_bool(backoff_fixed_enable);
DECLARE_double(backoff_fixed_us);
DECLARE_bool(backoff_randomized);
DECLARE_bool(backoff_adaptive_exponential);
DECLARE_bool(backoff_fixed_exponential);
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
      if (FLAGS_backoff_randomized) {
        // Cicada: choose a direction at random (stay inside [min, max]).
        const bool go_down = uniform01() < 0.5;
        if ((go_down && new_backoff > kMinBackoff) || new_backoff >= kMaxBackoff)
          new_backoff -= step;
        else
          new_backoff += step;
      } else if ((committed_txs & 1) == 0 ||
          new_backoff == kMaxBackoff) // 確率はおよそ 1/2, すなわちランダム．
        new_backoff -= step;
      else if ((committed_txs & 1) == 1 || new_backoff == kMinBackoff)
        new_backoff += step;
    }

    Backoff_.store(clamp_backoff(new_backoff), std::memory_order_release);
  }

  static double uniform01() {
    static thread_local uint64_t x = rdtscp() | 1;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;  // xorshift64
    return static_cast<double>(x >> 11) * (1.0 / 9007199254740992.0);
  }

  static void backoff(size_t clocks_per_us) {
    uint64_t start(rdtscp()), stop;
    double now_backoff = current_backoff_us();
    if (FLAGS_backoff_randomized) now_backoff *= uniform01();
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

  // The coordinated base backoff, or, if exponential growth is enabled
  // (backoff_adaptive_exponential / backoff_fixed_exponential),
  // base * 2^(consecutive aborts), capped at kMaxBackoff.
  static double current_backoff_us() {
    const double base_backoff =
        clamp_backoff(Backoff_.load(std::memory_order_acquire));
    if (base_backoff <= 0.0) return 0.0;
    if (FLAGS_backoff_fixed_enable ? !FLAGS_backoff_fixed_exponential
                                   : !FLAGS_backoff_adaptive_exponential)
      return base_backoff;

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
