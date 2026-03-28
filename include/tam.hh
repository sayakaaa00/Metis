#pragma once

#include <atomic>
#include <cstdint>

#include "gflags/gflags.h"
#include "tsc.hh"  // for rdtscp()

// AdaTAM: Adaptive Thread Activity Management
//
// - BACK_OFF=0 のときに有効化して、throughput の変化を見ながら
//   実際にアクティブに動かす worker スレッド数を動的に決める。
// - 生成される物理スレッド数 (FLAGS_thread_num) は固定で、
//   active_threads_ 以下の thid を持つ worker だけが Tx を実行する。

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_bool(tam_enable, false,
            "Enable adaptive thread activity management (AdaTAM)");
DEFINE_uint64(tam_update_period_us, 100000,
              "How often (in us) AdaTAM updates active thread count");
DEFINE_uint64(tam_min_threads, 1,
              "Minimum number of active worker threads when AdaTAM is enabled");
DEFINE_uint64(tam_max_threads, 64,
              "Maximum number of active worker threads when AdaTAM is enabled");
DEFINE_double(tam_step, 2.0,
              "Step size (in threads) when AdaTAM increases/decreases active threads");
#else
DECLARE_bool(tam_enable);
DECLARE_uint64(tam_update_period_us);
DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_double(tam_step);
#endif

class AdaTAM {
 public:
  AdaTAM() = default;

  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    total_threads_ = total_threads;
    clocks_per_us_ = clocks_per_us;
    uint64_t max_th = FLAGS_tam_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;
    uint64_t min_th = FLAGS_tam_min_threads;
    if (min_th == 0) min_th = 1;
    if (min_th > max_th) min_th = max_th;
    active_threads_.store(max_th, std::memory_order_relaxed);
    last_time_ = rdtscp();
    last_committed_txs_ = 0;
    last_tput_ = 0.0;
    last_threads_ = static_cast<int64_t>(max_th);
  }

  bool enabled() const { return FLAGS_tam_enable; }

  uint64_t active_threads() const {
    return active_threads_.load(std::memory_order_acquire);
  }

  // Leader スレッドから定期的に呼び出す。
  // committed_txs は全 worker のコミット総数（モニタスレッドなどから渡す）。
  void update(uint64_t committed_txs) {
    if (!FLAGS_tam_enable) return;

    uint64_t now = rdtscp();
    uint64_t dt = now - last_time_;
    uint64_t period_clocks = FLAGS_tam_update_period_us * clocks_per_us_;
    if (dt < period_clocks) return;  // まだ更新周期に達していない

    if (dt == 0) return;

    // backoff.hh と同様に、前回からの throughput 差とスレッド数差から gradient を見る
    uint64_t committed_diff = committed_txs - last_committed_txs_;
    double committed_tput = static_cast<double>(committed_diff) /
                            (static_cast<double>(dt) /
                             static_cast<double>(clocks_per_us_)) *
                            1e6;  // tx/sec
    double committed_tput_diff = committed_tput - last_tput_;

    int64_t current_threads =
        static_cast<int64_t>(active_threads_.load(std::memory_order_relaxed));
    int64_t threads_diff = current_threads - last_threads_;

    last_time_ = now;
    last_committed_txs_ = committed_txs;
    last_tput_ = committed_tput;
    last_threads_ = current_threads;

    double gradient;
    if (threads_diff != 0)
      gradient = committed_tput_diff / static_cast<double>(threads_diff);
    else
      gradient = 0.0;

    double step = FLAGS_tam_step;
    if (step <= 0.0) step = 1.0;

    int64_t next = current_threads;

    if (gradient < 0.0) {
      // gradient < 0: 直前のスレッド数変化は悪影響 → 逆方向に動かす
      next = current_threads - static_cast<int64_t>(step);
    } else if (gradient > 0.0) {
      // gradient > 0: 直前の変化は良かった → 同じ方向に進める（ここでは単純に増やす）
      next = current_threads + static_cast<int64_t>(step);
    } else {
      // gradient ≒ 0 : throughput の変化が小さい場合は、奇数/偶数でランダムに決める
      // committed_txs の LSB を使う（backoff.hh と同様の発想）
      if ((committed_txs & 1ULL) == 0ULL) {
        next = current_threads - static_cast<int64_t>(step);
      } else {
        next = current_threads + static_cast<int64_t>(step);
      }
    }

    uint64_t min_th = FLAGS_tam_min_threads;
    if (min_th == 0) min_th = 1;
    uint64_t max_th = FLAGS_tam_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;

    if (next < static_cast<int64_t>(min_th)) next = static_cast<int64_t>(min_th);
    if (next > static_cast<int64_t>(max_th)) next = static_cast<int64_t>(max_th);

    active_threads_.store(static_cast<uint64_t>(next), std::memory_order_release);
  }

 private:
  std::atomic<uint64_t> active_threads_{0};
  uint64_t total_threads_{0};
  uint64_t clocks_per_us_{0};
  uint64_t last_time_{0};
  uint64_t last_committed_txs_{0};
  double last_tput_{0.0};
  int64_t last_threads_{0};
};
