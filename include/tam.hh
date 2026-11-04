#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <limits>
#include <random>
#include <string>
#include <vector>

#include "gflags/gflags.h"
#include "adaptive_state.hh"
#include "metis_v2.hh"
#include "tsc.hh"  // for rdtscp()

// AdaTAM: Adaptive Thread Activity Management
//
// - BACK_OFF=0 のときに有効化して、throughput の変化を見ながら
//   実際にアクティブに動かす worker スレッド数を動的に決める。
// - 生成される物理スレッド数 (FLAGS_thread_num) は固定で、
//   active_threads_ 以下の thid を持つ worker だけが Tx を実行する。

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_bool(ada_tam_enable, false,
            "Enable adaptive thread activity management (AdaTAM)");
DEFINE_bool(metis_paper_enable, false,
            "Enable Metis_paper absolute-action thread activity management");
DEFINE_bool(metis_test_enable, false,
            "Enable experimental Metis-test TPCC controller");
DEFINE_bool(metis_test_learn, true, "Update Metis-test model during this run");
DEFINE_uint64(metis_test_fixed_threads, 0,
              "Use a fixed active count (0 enables Metis-test decisions)");
DEFINE_uint64(metis_test_active_warehouses, 16,
              "TPC-C active home warehouses for Metis-test context");
DEFINE_bool(metis_test_random_per_transaction, false,
            "TPC-C home warehouse is resampled for each transaction");
DEFINE_bool(metis_test_balanced_home_prefix, true,
            "Randomize warehouse order while balancing each active worker prefix");
DEFINE_double(metis_test_tps_scale, 400000.0,
              "Fixed TPCC TPS scale for Metis-test reward and context");
DEFINE_string(metis_test_reward_profile, "legacy",
              "Metis-test reward scale: legacy or physical_first_item100k");
DEFINE_uint64(metis_test_min_pulls_per_action, 1,
              "Initial samples per action while training Metis-test");
DEFINE_bool(metis_test_empirical_reward, false,
            "Use measured mean reward per absolute action on a fixed workload");
DEFINE_bool(metis_test_coarse_actions, false,
            "Probe representative absolute actions 8,16,24,32,48,64,96");
DEFINE_bool(metis_test_cross_workload, false,
            "Train or evaluate a warehouse-aware model across TPC-C workloads");
DEFINE_bool(metis_test_observed_load, false,
            "Use only measured probe throughput and abort rate for workload transfer");
DEFINE_uint64(metis_test_probe_intervals, 3,
              "TAM update intervals to average at the 96-worker reference action");
DEFINE_uint64(metis_test_reprobe_period_us, 0,
              "Periodically refresh the observed workload signature (0 disables)");
DEFINE_double(metis_test_observed_min_coefficient, 2.0,
              "Minimum learned coefficient for the observed abort-to-thread policy");
DEFINE_uint64(metis_test_exploration_seed, 1,
              "Seed for balanced Metis-test action exploration");
DEFINE_uint64(metis_test_idle_sleep_us, 50,
              "Sleep parked Metis-test workers for this many microseconds (0 spins)");
DEFINE_uint64(tam_idle_sleep_us, 50,
              "Sleep parked AdaTAM/Metis_paper workers for this many microseconds (0 spins)");
DEFINE_uint64(tam_update_period_us, 100000,
              "How often (in us) TAM updates active thread count");
DEFINE_uint64(tam_log_period_us, 100000,
              "How often (in us) TAM logs active thread count");
DEFINE_uint64(tam_min_threads, 1,
              "Minimum number of active worker threads is enabled");
DEFINE_uint64(tam_max_threads, 96,
              "Maximum number of active worker threads is enabled");
DEFINE_double(ada_tam_step, 2.0,
              "Step size (in threads) when AdaTAM increases/decreases active threads");
DEFINE_bool(tam_log_active_threads, false,
            "If true, log active thread count at each AdaTAM update");
DEFINE_uint64(benchmark_interval_tps_log_us, 0,
              "Log interval TPS to stderr at this period in us (0 disables)");
DEFINE_double(linucb_alpha, 1.0,
              "Exploration parameter alpha for LinUCBTAM");
DEFINE_double(linucb_lambda, 1.0,
              "Regularization parameter lambda for LinUCBTAM");
DEFINE_uint64(linucb_tam_min_pulls_per_action, 1,
              "Minimum number of times each LinUCBTAM action should be selected before pure UCB selection");
DEFINE_string(linucb_model_path, "",
              "Path to LinUCBTAM model file (load/save)");
DEFINE_bool(linucb_model_autosave, false,
            "If true, autosave LinUCBTAM model to linucb_model_path at end");
DEFINE_bool(linucb_abs_disable_tps_thread_context, false,
            "If true, exclude throughput-per-thread from Metis_paper context");
DEFINE_bool(linucb_abs_reward_log, true,
            "If true, use log-scaled reward in Metis_paper");
DEFINE_bool(linucb_abs_normalize_context_reward, false,
            "If true, normalize both context and reward into [0, 1] in Metis_paper");
DEFINE_double(linucb_abs_reward_thread_beta, 0.1,
              "Penalty coefficient beta for thread-scaled reward in Metis_paper");
DEFINE_double(linucb_abs_reward_history_alpha, 0.0,
              "EMA alpha for reward smoothing in Metis_paper (0 disables smoothing)");
DEFINE_bool(linucb_abs_disable_context_history, false,
            "If true, disable context history smoothing in Metis_paper");
DEFINE_uint64(linucb_abs_ignore_initial_steps, 0,
              "Number of initial Metis_paper update steps to ignore completely");

#else
DECLARE_bool(ada_tam_enable);
DECLARE_bool(metis_paper_enable);
DECLARE_bool(metis_test_enable);
DECLARE_bool(metis_test_learn);
DECLARE_uint64(metis_test_fixed_threads);
DECLARE_uint64(metis_test_active_warehouses);
DECLARE_bool(metis_test_random_per_transaction);
DECLARE_bool(metis_test_balanced_home_prefix);
DECLARE_double(metis_test_tps_scale);
DECLARE_string(metis_test_reward_profile);
DECLARE_uint64(metis_test_min_pulls_per_action);
DECLARE_bool(metis_test_empirical_reward);
DECLARE_bool(metis_test_coarse_actions);
DECLARE_bool(metis_test_cross_workload);
DECLARE_bool(metis_test_observed_load);
DECLARE_uint64(metis_test_probe_intervals);
DECLARE_uint64(metis_test_reprobe_period_us);
DECLARE_double(metis_test_observed_min_coefficient);
DECLARE_uint64(metis_test_exploration_seed);
DECLARE_uint64(metis_test_idle_sleep_us);
DECLARE_uint64(tam_idle_sleep_us);
DECLARE_uint64(tam_update_period_us);
DECLARE_uint64(tam_log_period_us);
DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_double(ada_tam_step);
DECLARE_bool(tam_log_active_threads);
DECLARE_uint64(benchmark_interval_tps_log_us);
DECLARE_double(linucb_alpha);
DECLARE_double(linucb_lambda);
DECLARE_uint64(linucb_tam_min_pulls_per_action);
DECLARE_string(linucb_model_path);
DECLARE_bool(linucb_model_autosave);
DECLARE_bool(linucb_abs_disable_tps_thread_context);
DECLARE_bool(linucb_abs_reward_log);
DECLARE_bool(linucb_abs_normalize_context_reward);
DECLARE_double(linucb_abs_reward_thread_beta);
DECLARE_double(linucb_abs_reward_history_alpha);
DECLARE_bool(linucb_abs_disable_context_history);
DECLARE_uint64(linucb_abs_ignore_initial_steps);
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
    // Shared with the TPC-C retry loop so parked workers stop between attempts.
    g_metis_test_active_threads.store(max_th, std::memory_order_release);
    last_time_ = rdtscp();
    last_committed_txs_ = 0;
    last_tput_ = 0.0;
    last_threads_ = static_cast<int64_t>(max_th);
    last_log_time_ = last_time_;
  }

  bool enabled() const { return FLAGS_ada_tam_enable; }

  uint64_t active_threads() const {
    return active_threads_.load(std::memory_order_acquire);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    if (stats_count_ == 0) return;

    double n    = static_cast<double>(stats_count_);
    double mean = stats_sum_ / n;
    double var  = stats_sq_sum_ / n - mean * mean;
    if (var < 0.0) var = 0.0;
    double stddev = std::sqrt(var);

    fprintf(stderr,
            "[AdaTAM] active_threads stats: count=%llu mean=%.3f stddev=%.3f\n",
            static_cast<unsigned long long>(stats_count_),
            mean,
            stddev);
  }

  // Leader スレッドから定期的に呼び出す。
  // committed_txs は全 worker のコミット総数（モニタスレッドなどから渡す）。
  void update(uint64_t committed_txs, uint64_t abort_txs) {
    (void)abort_txs;
    if (!FLAGS_ada_tam_enable) return;

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

    double step = FLAGS_ada_tam_step;
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
    g_metis_test_active_threads.store(static_cast<uint64_t>(next),
                                      std::memory_order_release);

    if (FLAGS_tam_log_active_threads) {
      uint64_t log_period = FLAGS_tam_log_period_us * clocks_per_us_;
      if (log_period == 0) log_period = period_clocks;
      if (now - last_log_time_ >= log_period) {
        // ログ行
        fprintf(stderr,
                "[AdaTAM] active_threads=%llu committed_txs=%llu tput=%.0f tx/s\n",
                static_cast<unsigned long long>(active_threads()),
                static_cast<unsigned long long>(committed_txs),
                committed_tput);

        // 統計量更新（active_threads の平均・分散用）
        double v = static_cast<double>(next);
        stats_count_ += 1;
        stats_sum_   += v;
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
  // tam_log_active_threads 時に active_threads の平均・分散をとるためのバッファ
  uint64_t stats_count_{0};
  double   stats_sum_{0.0};
  double   stats_sq_sum_{0.0};
};

class Metis_paper {
 public:
  Metis_paper() = default;

  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    total_threads_ = total_threads;
    clocks_per_us_ = clocks_per_us;

    uint64_t max_th = FLAGS_tam_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;
    uint64_t min_th = FLAGS_tam_min_threads;
    if (min_th == 0) min_th = 1;
    if (min_th > max_th) min_th = max_th;

    uint64_t initial_threads = max_th;
    active_threads_.store(initial_threads, std::memory_order_relaxed);
    target_threads_ = initial_threads;
    last_time_ = rdtscp();
    last_log_time_ = last_time_;
    last_committed_txs_ = 0;
    last_abort_txs_ = 0;
    last_action_index_ = -1;
    last_throughput_tps_ = 0.0;
    has_last_throughput_ = false;
    update_step_id_ = 0;

    double lambda = FLAGS_linucb_lambda;
    if (lambda <= 0.0) lambda = 1.0;

    for (size_t a = 0; a < kNumActions; ++a) {
      A_[a] = identity_matrix(lambda);
      b_[a] = {};
      action_pull_counts_[a] = 0;
    }
  }

  bool load_model(const std::string &path) {
    if (path.empty()) return false;
    std::ifstream in(path);
    if (!in) return false;

    std::string header;
    if (!(in >> header)) return false;
    if (header != "linucb_abs_model_v2") return false;

    for (size_t a = 0; a < kNumActions; ++a) {
      for (size_t i = 0; i < kContextDim; ++i) {
        for (size_t j = 0; j < kContextDim; ++j) {
          if (!(in >> A_[a][i][j])) return false;
        }
      }
      for (size_t i = 0; i < kContextDim; ++i) {
        if (!(in >> b_[a][i])) return false;
      }
      action_pull_counts_[a] = 0;
    }

    last_action_index_ = -1;
    last_x_ = {};
    target_threads_ = active_threads_.load(std::memory_order_relaxed);
    stats_count_ = 0;
    stats_sum_ = 0.0;
    stats_sq_sum_ = 0.0;
    last_throughput_tps_ = 0.0;
    has_last_throughput_ = false;
    update_step_id_ = 0;
    return true;
  }

  bool save_model(const std::string &path) const {
    if (path.empty()) return false;
    std::ofstream out(path, std::ios::trunc);
    if (!out) return false;

    out << "linucb_abs_model_v2\n";
    for (size_t a = 0; a < kNumActions; ++a) {
      for (size_t i = 0; i < kContextDim; ++i) {
        for (size_t j = 0; j < kContextDim; ++j) {
          out << A_[a][i][j] << ' ';
        }
      }
      for (size_t i = 0; i < kContextDim; ++i) {
        out << b_[a][i] << (i + 1 == kContextDim ? '\n' : ' ');
      }
    }
    return true;
  }

  bool enabled() const { return FLAGS_metis_paper_enable; }

  uint64_t active_threads() const {
    return active_threads_.load(std::memory_order_acquire);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    if (stats_count_ == 0) return;

    double n = static_cast<double>(stats_count_);
    double mean = stats_sum_ / n;
    double var = stats_sq_sum_ / n - mean * mean;
    if (var < 0.0) var = 0.0;
    double stddev = std::sqrt(var);

    fprintf(stderr,
            "[Metis_paper] active_threads stats: count=%llu mean=%.3f stddev=%.3f\n",
            static_cast<unsigned long long>(stats_count_),
            mean,
            stddev);
  }

  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (!FLAGS_metis_paper_enable) return;

    uint64_t now = rdtscp();
    uint64_t dt = now - last_time_;
    uint64_t period_clocks = FLAGS_tam_update_period_us * clocks_per_us_;
    if (dt < period_clocks) return;
    if (dt == 0) return;

    uint64_t committed_diff = committed_txs - last_committed_txs_;
    uint64_t abort_diff = abort_txs - last_abort_txs_;
    update_step_id_ += 1;

    double throughput_tps = 0.0;
    if (dt > 0) {
      throughput_tps = static_cast<double>(committed_diff) /
                       (static_cast<double>(dt) /
                        static_cast<double>(clocks_per_us_)) * 1e6;
    }

    double abort_rate = 0.0;
    uint64_t total_attempts = committed_diff + abort_diff;
    if (total_attempts > 0) {
      abort_rate = static_cast<double>(abort_diff) /
                   static_cast<double>(total_attempts);
    }

    if (update_step_id_ <= FLAGS_linucb_abs_ignore_initial_steps) {
      // Ignore startup TPS completely: do not learn, do not update reward
      // history, and do not let skipped steps affect future TPS trend.
      last_time_ = now;
      last_committed_txs_ = committed_txs;
      last_abort_txs_ = abort_txs;
      last_throughput_tps_ = 0.0;
      has_last_throughput_ = false;
      return;
    }

    uint64_t current_threads = active_threads_.load(std::memory_order_relaxed);
    double tps_trend = 0.0;
    if (has_last_throughput_) {
      tps_trend = throughput_tps - last_throughput_tps_;
    }

    double reward = 0.0;
    bool has_reward = false;
    if (reward_history_count_ >= kRewardWarmupHistory) {
      double rolling_mean_tps = reward_history_sum_tps_ /
                                static_cast<double>(reward_history_count_);
      double rolling_var_tps = reward_history_sq_sum_tps_ /
                               static_cast<double>(reward_history_count_) -
                               rolling_mean_tps * rolling_mean_tps;
      if (rolling_var_tps < 0.0) rolling_var_tps = 0.0;
      double rolling_std_tps = std::sqrt(rolling_var_tps);
      double denom =
          std::max(rolling_std_tps,
                   std::max(kRewardAbsoluteMinStd,
                            kRewardRelativeMinStdRatio * rolling_mean_tps));
      double zscore_tps = (throughput_tps - rolling_mean_tps) / denom;
      reward = zscore_tps;
      reward = std::clamp(reward, kRewardClipMin, kRewardClipMax);
      has_reward = true;
    }

    if (last_action_index_ >= 0 && has_reward) {
      size_t a = static_cast<size_t>(last_action_index_);
      add_outer_product(A_[a], last_x_);
      add_scaled_vector(b_[a], last_x_, reward);
    }

    uint64_t min_th = FLAGS_tam_min_threads;
    if (min_th == 0) min_th = 1;
    uint64_t max_th = FLAGS_tam_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;

    size_t best_action = 0;
    Vec best_x{};
    double best_score = -1e300;
    double alpha = FLAGS_linucb_alpha;
    if (alpha < 0.0) alpha = 0.0;

    bool any_effective_action = false;
    uint64_t min_pulls_per_action =
        FLAGS_linucb_model_autosave ? FLAGS_linucb_tam_min_pulls_per_action : 0;

    if (min_pulls_per_action > 0) {
      for (size_t a = 0; a < kNumActions; ++a) {
        uint64_t candidate = clamp_threads(kTargetThreads[a], min_th, max_th);
        if (candidate == current_threads && target_threads_ == candidate) {
          continue;
        }
        if (action_pull_counts_[a] < min_pulls_per_action) {
          best_action = a;
          best_x = build_context(abort_rate, throughput_tps, current_threads,
                                 candidate, tps_trend);
          any_effective_action = true;
          break;
        }
      }
    }

    if (!any_effective_action) {
      for (size_t a = 0; a < kNumActions; ++a) {
        uint64_t candidate = clamp_threads(kTargetThreads[a], min_th, max_th);
        if (candidate == current_threads && target_threads_ == candidate) {
          continue;
        }

        Mat invA;
        if (!invert_matrix(A_[a], invA)) {
          invA = identity_matrix(1.0);
        }
        Vec x = build_context(abort_rate, throughput_tps, current_threads,
                              candidate, tps_trend);
        Vec theta = mat_vec(invA, b_[a]);
        double mean = dot(x, theta);
        double bonus = std::sqrt(std::max(0.0, quad_form(invA, x)));
        double score = mean + alpha * bonus;
        if (score > best_score) {
          best_score = score;
          best_action = a;
          best_x = x;
          any_effective_action = true;
        }
      }
    }

    if (!any_effective_action) {
      best_action = 0;
      uint64_t fallback_candidate =
          clamp_threads(kTargetThreads[best_action], min_th, max_th);
      best_x = build_context(abort_rate, throughput_tps, current_threads,
                             fallback_candidate, tps_trend);
    }

    target_threads_ = clamp_threads(kTargetThreads[best_action], min_th, max_th);
    uint64_t next_threads = target_threads_;
    active_threads_.store(next_threads, std::memory_order_release);

    if (FLAGS_tam_log_active_threads) {
      uint64_t log_period = FLAGS_tam_log_period_us * clocks_per_us_;
      if (log_period == 0) log_period = period_clocks;
      if (now - last_log_time_ >= log_period) {
        fprintf(stderr,
                "[Metis_paper] active_threads=%llu target_threads=%llu action=%llu tput=%.0f tx/s abort_rate=%.4f\n",
                static_cast<unsigned long long>(active_threads()),
                static_cast<unsigned long long>(target_threads_),
                static_cast<unsigned long long>(kTargetThreads[best_action]),
                throughput_tps,
                abort_rate);

        double v = static_cast<double>(next_threads);
        stats_count_ += 1;
        stats_sum_ += v;
        stats_sq_sum_ += v * v;
        last_log_time_ = now;
      }
    }

    push_reward_history(throughput_tps, abort_rate);

    last_action_index_ = static_cast<int64_t>(best_action);
    action_pull_counts_[best_action] += 1;
    last_x_ = best_x;
    last_time_ = now;
    last_committed_txs_ = committed_txs;
    last_abort_txs_ = abort_txs;
    last_throughput_tps_ = throughput_tps;
    has_last_throughput_ = true;
  }

 private:
  static constexpr size_t kNumActions = 45;
  static constexpr size_t kContextDim = 11;
  static constexpr double kTpsScale = 1e6;
  static constexpr size_t kRewardWindowSize = 50;
  static constexpr size_t kRewardWarmupHistory = 10;
  static constexpr double kRewardAbsoluteMinStd = 50000.0;
  static constexpr double kRewardRelativeMinStdRatio = 0.015;
  static constexpr double kRewardClipMin = -3.0;
  static constexpr double kRewardClipMax = 3.0;
  static constexpr std::array<uint64_t, kNumActions> kTargetThreads{{8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90, 92, 94, 96}};
  using Vec = std::array<double, kContextDim>;
  using Mat = std::array<std::array<double, kContextDim>, kContextDim>;

  Vec build_context(double abort_rate, double throughput_tps,
                    uint64_t current_threads, uint64_t candidate_threads,
                    double tps_trend) const {
    const double tps_scaled = throughput_tps / kTpsScale;
    double current_threads_scaled = 0.0;
    if (total_threads_ > 0) {
      current_threads_scaled = static_cast<double>(current_threads) /
                               static_cast<double>(total_threads_);
    }
    double candidate_threads_scaled = 0.0;
    if (total_threads_ > 0) {
      candidate_threads_scaled = static_cast<double>(candidate_threads) /
                                 static_cast<double>(total_threads_);
    }
    const double delta_threads_scaled =
        candidate_threads_scaled - current_threads_scaled;
    const double tps_trend_scaled = tps_trend / kTpsScale;
    double tps_per_thread_scaled = 0.0;
    if (current_threads > 0) {
      tps_per_thread_scaled = throughput_tps /
                              (static_cast<double>(current_threads) * kTpsScale);
    }

    return {1.0,
            abort_rate,
            tps_scaled,
            current_threads_scaled,
            candidate_threads_scaled,
            delta_threads_scaled,
            abort_rate * candidate_threads_scaled,
            abort_rate * delta_threads_scaled,
            tps_per_thread_scaled,
            tps_trend_scaled,
            candidate_threads_scaled * candidate_threads_scaled};
  }

  void push_reward_history(double throughput_tps, double abort_rate) {
    if (reward_history_count_ == kRewardWindowSize) {
      double old_tps = reward_history_tps_[reward_history_head_];
      double old_abort_rate = reward_history_abort_rate_[reward_history_head_];
      reward_history_sum_tps_ -= old_tps;
      reward_history_sq_sum_tps_ -= old_tps * old_tps;
      reward_history_sum_abort_rate_ -= old_abort_rate;
    } else {
      reward_history_count_ += 1;
    }

    reward_history_tps_[reward_history_head_] = throughput_tps;
    reward_history_abort_rate_[reward_history_head_] = abort_rate;
    reward_history_sum_tps_ += throughput_tps;
    reward_history_sq_sum_tps_ += throughput_tps * throughput_tps;
    reward_history_sum_abort_rate_ += abort_rate;
    reward_history_head_ = (reward_history_head_ + 1) % kRewardWindowSize;
  }

  static uint64_t clamp_threads(uint64_t value, uint64_t min_th, uint64_t max_th) {
    if (value < min_th) return min_th;
    if (value > max_th) return max_th;
    return value;
  }

  static Mat identity_matrix(double diag) {
    Mat m{};
    for (size_t i = 0; i < kContextDim; ++i) {
      for (size_t j = 0; j < kContextDim; ++j) m[i][j] = 0.0;
      m[i][i] = diag;
    }
    return m;
  }

  static void add_outer_product(Mat &A, const Vec &x) {
    for (size_t i = 0; i < kContextDim; ++i) {
      for (size_t j = 0; j < kContextDim; ++j) {
        A[i][j] += x[i] * x[j];
      }
    }
  }

  static void add_scaled_vector(Vec &b, const Vec &x, double scale) {
    for (size_t i = 0; i < kContextDim; ++i) b[i] += scale * x[i];
  }

  static Vec mat_vec(const Mat &A, const Vec &x) {
    Vec y{};
    for (size_t i = 0; i < kContextDim; ++i) {
      y[i] = 0.0;
      for (size_t j = 0; j < kContextDim; ++j) y[i] += A[i][j] * x[j];
    }
    return y;
  }

  static double dot(const Vec &a, const Vec &b) {
    double sum = 0.0;
    for (size_t i = 0; i < kContextDim; ++i) sum += a[i] * b[i];
    return sum;
  }

  static double quad_form(const Mat &A, const Vec &x) {
    Vec Ax = mat_vec(A, x);
    return dot(x, Ax);
  }

  static bool invert_matrix(const Mat &A, Mat &inv) {
    double aug[kContextDim][2 * kContextDim];
    for (size_t i = 0; i < kContextDim; ++i) {
      for (size_t j = 0; j < kContextDim; ++j) {
        aug[i][j] = A[i][j];
        aug[i][j + kContextDim] = (i == j) ? 1.0 : 0.0;
      }
    }

    for (size_t col = 0; col < kContextDim; ++col) {
      size_t pivot = col;
      for (size_t row = col + 1; row < kContextDim; ++row) {
        if (std::fabs(aug[row][col]) > std::fabs(aug[pivot][col])) pivot = row;
      }
      if (std::fabs(aug[pivot][col]) < 1e-12) return false;
      if (pivot != col) {
        for (size_t j = 0; j < 2 * kContextDim; ++j) std::swap(aug[col][j], aug[pivot][j]);
      }

      double diag = aug[col][col];
      for (size_t j = 0; j < 2 * kContextDim; ++j) aug[col][j] /= diag;

      for (size_t row = 0; row < kContextDim; ++row) {
        if (row == col) continue;
        double factor = aug[row][col];
        for (size_t j = 0; j < 2 * kContextDim; ++j) {
          aug[row][j] -= factor * aug[col][j];
        }
      }
    }

    for (size_t i = 0; i < kContextDim; ++i) {
      for (size_t j = 0; j < kContextDim; ++j) {
        inv[i][j] = aug[i][j + kContextDim];
      }
    }
    return true;
  }

  std::atomic<uint64_t> active_threads_{0};
  uint64_t target_threads_{0};
  uint64_t total_threads_{0};
  uint64_t clocks_per_us_{0};
  uint64_t last_time_{0};
  uint64_t last_log_time_{0};
  uint64_t last_committed_txs_{0};
  uint64_t last_abort_txs_{0};
  int64_t last_action_index_{-1};
  Vec last_x_{};
  std::array<Mat, kNumActions> A_{};
  std::array<Vec, kNumActions> b_{};
  std::array<uint64_t, kNumActions> action_pull_counts_{};
  uint64_t stats_count_{0};
  double stats_sum_{0.0};
  double stats_sq_sum_{0.0};
  double last_throughput_tps_{0.0};
  bool has_last_throughput_{false};
  std::array<double, kRewardWindowSize> reward_history_tps_{};
  std::array<double, kRewardWindowSize> reward_history_abort_rate_{};
  size_t reward_history_head_{0};
  size_t reward_history_count_{0};
  double reward_history_sum_tps_{0.0};
  double reward_history_sq_sum_tps_{0.0};
  double reward_history_sum_abort_rate_{0.0};
  uint64_t update_step_id_{0};
};

// Experimental TPCC controller. Unlike Metis_paper, all absolute actions
// share one ridge model so a short, fixed-workload training run can transfer
// information between neighboring thread counts.
class Metis_test {
 private:
#ifdef METIS_TEST_SMT
  static constexpr size_t kDim = 14;
#else
  static constexpr size_t kDim = 12;
#endif
  static constexpr size_t kActions = 45;
  static constexpr std::array<uint64_t, kActions> kTargets = {
      8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,
      48,50,52,54,56,58,60,62,64,66,68,70,72,74,76,78,80,82,84,86,
      88,90,92,94,96};
  struct ObservedEpisode {
    double probe_tps{0.0};
    double probe_abort{0.0};
    std::array<uint64_t, kActions> counts{};
    std::array<double, kActions> reward_sums{};
  };

 public:
  void init(uint64_t total_threads, uint64_t) {
    if (!(FLAGS_metis_test_tps_scale > 0.0) ||
        !std::isfinite(FLAGS_metis_test_tps_scale) ||
        (FLAGS_metis_test_reward_profile != "legacy" &&
         FLAGS_metis_test_reward_profile != "physical_first_item100k") ||
        FLAGS_metis_test_active_warehouses == 0 ||
        (FLAGS_metis_test_observed_load &&
         (total_threads != 96 || FLAGS_tam_max_threads < 96 ||
          FLAGS_metis_test_probe_intervals == 0 ||
          FLAGS_metis_test_observed_min_coefficient <= 0.0 ||
          FLAGS_metis_test_observed_min_coefficient > 12.0))) {
      std::fprintf(stderr, "Invalid Metis-test scale, warehouse, probe, or thread configuration\n");
      std::abort();
    }
    total_threads_ = total_threads;
    g_metis_test_home_warehouses =
        std::vector<std::atomic<std::uint16_t>>(total_threads);
    g_metis_test_worker_warehouses =
        std::vector<std::atomic<std::uint32_t>>(total_threads);
    uint64_t initial = std::min(total_threads, FLAGS_tam_max_threads);
    if (FLAGS_metis_test_fixed_threads != 0) {
      initial = FLAGS_metis_test_fixed_threads;
    }
    if (initial == 0 || initial > total_threads) {
      std::fprintf(stderr, "Invalid Metis-test initial thread count\n");
      std::abort();
    }
    set_active(initial);
    last_time_ = std::chrono::steady_clock::now();
    start_time_ = last_time_;
    last_log_time_ = last_time_;
    last_committed_ = last_aborts_ = 0;
    last_tps_ = 0.0;
    have_last_tps_ = false;
    last_action_ = -1;
    settling_ = false;
    step_ = 0;
    observations_ = 0;
    samples_.fill(0);
    reward_sum_.fill(0.0);
    observed_episodes_.clear();
    observed_current_ = {};
    observed_coefficient_ = 6.0;
    observed_probing_ = FLAGS_metis_test_observed_load;
    observed_skip_probe_interval_ = false;
    observed_probe_count_ = 0;
    observed_probe_tps_sum_ = observed_probe_abort_sum_ = 0.0;
    observed_previous_probe_tps_ = observed_previous_probe_abort_ = 0.0;
    observed_anchor_tps_ = observed_anchor_abort_ = 0.0;
    observed_probe_time_ = last_time_;
    rng_.seed(FLAGS_metis_test_exploration_seed);
    double lambda = FLAGS_linucb_lambda > 0.0 ? FLAGS_linucb_lambda : 1.0;
    A_ = {};
    b_ = {};
    for (size_t i = 0; i < kDim; ++i) A_[i][i] = lambda;
  }

  bool enabled() const { return FLAGS_metis_test_enable; }
  uint64_t active_threads() const {
    return active_.load(std::memory_order_acquire);
  }

  bool load_model(const std::string& path) {
    std::ifstream in(path);
    std::string header;
    if (!(in >> header)) return false;
    if (header == "metis_test_observed_v1") {
      size_t actions, episodes;
      int coarse, balanced;
      uint64_t update_us, sleep_us, probe_intervals;
      if (!FLAGS_metis_test_observed_load ||
          !(in >> actions >> coarse >> balanced >> update_us >> sleep_us >>
            probe_intervals >> episodes) ||
          actions != kActions ||
          coarse != static_cast<int>(FLAGS_metis_test_coarse_actions) ||
          balanced != static_cast<int>(FLAGS_metis_test_balanced_home_prefix) ||
          update_us != FLAGS_tam_update_period_us ||
          sleep_us != FLAGS_metis_test_idle_sleep_us ||
          probe_intervals != FLAGS_metis_test_probe_intervals)
        return false;
      std::vector<ObservedEpisode> loaded;
      loaded.reserve(episodes);
      for (size_t i = 0; i < episodes; ++i) {
        ObservedEpisode episode;
        if (!(in >> episode.probe_tps >> episode.probe_abort) ||
            !(episode.probe_tps > 0.0) ||
            !std::isfinite(episode.probe_tps) ||
            !std::isfinite(episode.probe_abort)) return false;
        for (auto& count : episode.counts) if (!(in >> count)) return false;
        for (auto& sum : episode.reward_sums) if (!(in >> sum)) return false;
        loaded.push_back(episode);
      }
      observed_episodes_ = std::move(loaded);
      observed_coefficient_ = fit_observed_coefficient();
      return true;
    }
    if (FLAGS_metis_test_observed_load) return false;
    in.clear();
    in.seekg(0);
    size_t dim, actions;
    double scale;
    uint64_t warehouses;
    int random_per_tx;
    int balanced_prefix = 0;
    int empirical_reward = 0;
    int coarse_actions = 0;
    int cross_workload = 0;
    std::string reward_profile = "legacy";
    uint64_t idle_sleep_us = 0, update_period_us = 0;
    if (!(in >> header >> dim >> actions >> scale >> warehouses >> random_per_tx))
      return false;
    if ((header == "metis_test_model_v2" || header == "metis_test_model_v3" ||
         header == "metis_test_model_v4" || header == "metis_test_model_v5" ||
         header == "metis_test_model_v6" || header == "metis_test_model_v7") &&
        !(in >> balanced_prefix >> idle_sleep_us >> update_period_us))
      return false;
    if ((header == "metis_test_model_v3" || header == "metis_test_model_v4" ||
         header == "metis_test_model_v5" || header == "metis_test_model_v6" ||
         header == "metis_test_model_v7") &&
        !(in >> empirical_reward))
      return false;
    if ((header == "metis_test_model_v4" || header == "metis_test_model_v5" ||
         header == "metis_test_model_v6" || header == "metis_test_model_v7") &&
        !(in >> coarse_actions))
      return false;
    if ((header == "metis_test_model_v5" || header == "metis_test_model_v6" ||
         header == "metis_test_model_v7") &&
        !(in >> cross_workload))
      return false;
    if ((header == "metis_test_model_v6" || header == "metis_test_model_v7") &&
        !(in >> reward_profile))
      return false;
#ifdef METIS_TEST_SMT
    if (header != "metis_test_model_v7") return false;
#else
    if (header == "metis_test_model_v7") return false;
#endif
    if ((header != "metis_test_model_v1" && header != "metis_test_model_v2" &&
         header != "metis_test_model_v3" && header != "metis_test_model_v4" &&
         header != "metis_test_model_v5" && header != "metis_test_model_v6" &&
         header != "metis_test_model_v7") ||
        dim != kDim ||
        actions != kActions || scale != FLAGS_metis_test_tps_scale ||
        reward_profile != FLAGS_metis_test_reward_profile ||
        (warehouses != FLAGS_metis_test_active_warehouses &&
         !(cross_workload && warehouses == 0)) ||
        random_per_tx != static_cast<int>(FLAGS_metis_test_random_per_transaction) ||
        balanced_prefix != static_cast<int>(FLAGS_metis_test_balanced_home_prefix) ||
        empirical_reward != static_cast<int>(FLAGS_metis_test_empirical_reward) ||
        coarse_actions != static_cast<int>(FLAGS_metis_test_coarse_actions) ||
        cross_workload != static_cast<int>(FLAGS_metis_test_cross_workload) ||
        ((header == "metis_test_model_v2" || header == "metis_test_model_v3" ||
          header == "metis_test_model_v4" || header == "metis_test_model_v5" ||
          header == "metis_test_model_v6" || header == "metis_test_model_v7") &&
         (idle_sleep_us != FLAGS_metis_test_idle_sleep_us ||
          update_period_us != FLAGS_tam_update_period_us))) {
      return false;
    }
    Mat next_a{};
    Vec next_b{};
    std::array<uint64_t, kActions> next_samples{};
    std::array<double, kActions> next_reward_sum{};
    for (auto& row : next_a) for (double& value : row) if (!(in >> value)) return false;
    for (double& value : next_b) if (!(in >> value)) return false;
    for (uint64_t& value : next_samples) if (!(in >> value)) return false;
    if (header == "metis_test_model_v3" || header == "metis_test_model_v4" ||
        header == "metis_test_model_v5" || header == "metis_test_model_v6" ||
        header == "metis_test_model_v7")
      for (double& value : next_reward_sum) if (!(in >> value)) return false;
    if (!(in >> observations_)) return false;
    A_ = next_a;
    b_ = next_b;
    samples_ = next_samples;
    reward_sum_ = next_reward_sum;
    return true;
  }

  bool save_model(const std::string& path) const {
    if (path.empty()) return false;
    std::ofstream out(path, std::ios::trunc);
    if (!out) return false;
    out << std::setprecision(17);
    if (FLAGS_metis_test_observed_load) {
      const size_t episode_count = observed_episodes_.size() +
          (observed_current_.probe_tps > 0.0 ? 1 : 0);
      out << "metis_test_observed_v1 " << kActions << ' '
          << static_cast<int>(FLAGS_metis_test_coarse_actions) << ' '
          << static_cast<int>(FLAGS_metis_test_balanced_home_prefix) << ' '
          << FLAGS_tam_update_period_us << ' '
          << FLAGS_metis_test_idle_sleep_us << ' '
          << FLAGS_metis_test_probe_intervals << ' ' << episode_count << '\n';
      auto save_episode = [&out](const ObservedEpisode& episode) {
        out << episode.probe_tps << ' ' << episode.probe_abort << '\n';
        for (auto value : episode.counts) out << value << ' ';
        out << '\n';
        for (auto value : episode.reward_sums) out << value << ' ';
        out << '\n';
      };
      for (const auto& episode : observed_episodes_) save_episode(episode);
      if (observed_current_.probe_tps > 0.0) save_episode(observed_current_);
      return out.good();
    }
#ifdef METIS_TEST_SMT
    out << "metis_test_model_v7 "
#else
    out << (FLAGS_metis_test_reward_profile == "legacy" ?
            "metis_test_model_v5 " : "metis_test_model_v6 ")
#endif
        << kDim << ' ' << kActions << ' '
        << FLAGS_metis_test_tps_scale << ' '
        << (FLAGS_metis_test_cross_workload ? 0 :
            FLAGS_metis_test_active_warehouses) << ' '
        << static_cast<int>(FLAGS_metis_test_random_per_transaction) << ' '
        << static_cast<int>(FLAGS_metis_test_balanced_home_prefix) << ' '
        << FLAGS_metis_test_idle_sleep_us << ' '
        << FLAGS_tam_update_period_us << ' '
        << static_cast<int>(FLAGS_metis_test_empirical_reward) << ' '
        << static_cast<int>(FLAGS_metis_test_coarse_actions) << ' '
        << static_cast<int>(FLAGS_metis_test_cross_workload);
    if (FLAGS_metis_test_reward_profile != "legacy")
      out << ' ' << FLAGS_metis_test_reward_profile;
    out << '\n';
    for (const auto& row : A_) {
      for (double value : row) out << value << ' ';
      out << '\n';
    }
    for (double value : b_) out << value << ' ';
    out << '\n';
    for (uint64_t value : samples_) out << value << ' ';
    out << '\n';
    for (double value : reward_sum_) out << value << ' ';
    out << '\n' << observations_ << '\n';
    return out.good();
  }

  void print_stats() const {
    if (stats_count_ == 0) return;
    std::fprintf(stderr,
        "[Metis-test] active_threads stats: count=%llu mean=%.3f model_samples=%llu\n",
        static_cast<unsigned long long>(stats_count_), stats_sum_ / stats_count_,
        static_cast<unsigned long long>(observations_));
  }

  void update(uint64_t commits, uint64_t aborts) {
    const auto now = std::chrono::steady_clock::now();
    const double seconds = std::chrono::duration<double>(now - last_time_).count();
    if (seconds < static_cast<double>(FLAGS_tam_update_period_us) / 1e6 ||
        seconds <= 0.0) return;
    const double tps = (commits - last_committed_) / seconds;
    const uint64_t attempts = commits - last_committed_ + aborts - last_aborts_;
    const double abort_rate = attempts == 0 ? 0.0 :
        static_cast<double>(aborts - last_aborts_) / attempts;
    const double trend = have_last_tps_ ? tps - last_tps_ : 0.0;
    last_time_ = now;
    last_committed_ = commits;
    last_aborts_ = aborts;
    last_tps_ = tps;
    have_last_tps_ = true;
    ++step_;

    if (step_ <= FLAGS_linucb_abs_ignore_initial_steps) return;

    if (FLAGS_metis_test_observed_load) {
      // Keep the warehouse-aware context below for historical models only.
      // The observed-load policy uses no warehouse count or home map features.
      if (FLAGS_metis_test_fixed_threads != 0) {
        log(now, tps, abort_rate, 0.0, -1.0, 0.0, "fixed");
      } else {
        update_observed(now, tps, abort_rate);
      }
      return;
    }

    const double reward = tps / reward_scale();
    if (FLAGS_metis_test_fixed_threads == 0 && last_action_ >= 0) {
      if (settling_) {
        settling_ = false;
        log(now, tps, abort_rate, reward, -1.0, 0.0, "settle");
        return;  // Hold this action for a second interval before learning.
      }
      if (FLAGS_metis_test_learn) {
        for (size_t i = 0; i < kDim; ++i) {
          b_[i] += reward * last_x_[i];
          for (size_t j = 0; j < kDim; ++j) {
            A_[i][j] += last_x_[i] * last_x_[j];
          }
        }
        ++samples_[last_action_];
        reward_sum_[last_action_] += reward;
        ++observations_;
      }
    }

    if (FLAGS_metis_test_fixed_threads != 0) {
      log(now, tps, abort_rate, reward, -1.0, 0.0, "fixed");
      return;
    }

    const uint64_t min_th = std::max<uint64_t>(1, FLAGS_tam_min_threads);
    const uint64_t max_th = std::min(total_threads_, FLAGS_tam_max_threads);
    Mat inv{};
    if (!invert(A_, inv)) {
      std::fprintf(stderr, "Metis-test model matrix is singular\n");
      std::abort();
    }
    Vec theta = multiply(inv, b_);
    size_t best = kActions;
    Vec best_x{};
    double best_score = -std::numeric_limits<double>::infinity();
    double best_mean = 0.0, best_bonus = 0.0;
    const double alpha = std::max(0.0, FLAGS_linucb_alpha);
    const uint64_t current = active_threads();
    size_t forced_action = kActions;
    if (FLAGS_metis_test_learn &&
        FLAGS_metis_test_min_pulls_per_action > 0) {
      uint64_t min_samples = FLAGS_metis_test_min_pulls_per_action;
      std::vector<size_t> eligible;
      for (size_t a = 0; a < kActions; ++a) {
        if (!allowed(kTargets[a]) ||
            kTargets[a] < min_th || kTargets[a] > max_th ||
            samples_[a] >= FLAGS_metis_test_min_pulls_per_action) continue;
        if (samples_[a] < min_samples) {
          min_samples = samples_[a];
          eligible.clear();
        }
        if (samples_[a] == min_samples) eligible.push_back(a);
      }
      if (!eligible.empty())
        forced_action = eligible[rng_() % eligible.size()];
    }
    for (size_t a = 0; a < kActions; ++a) {
      const uint64_t candidate = kTargets[a];
      if (!allowed(candidate) || candidate < min_th || candidate > max_th ||
          (forced_action != kActions && a != forced_action)) continue;
      const Vec x = context(abort_rate, tps, current, candidate, trend);
      double mean = dot(x, theta);
      double bonus = std::sqrt(std::max(0.0, dot(x, multiply(inv, x))));
      if (FLAGS_metis_test_empirical_reward && samples_[a] != 0) {
        mean = reward_sum_[a] / samples_[a];
        bonus = 0.05 * std::sqrt(
            std::log(static_cast<double>(std::max<uint64_t>(2, observations_))) /
            samples_[a]);
      }
      const double score = mean + alpha * bonus;
      if (a == forced_action) {
        best = a; best_x = x; best_mean = mean; best_bonus = bonus;
        break;
      }
      if (score > best_score) {
        best = a; best_x = x; best_score = score;
        best_mean = mean; best_bonus = bonus;
      }
    }
    if (best == kActions) {
      log(now, tps, abort_rate, reward, -1.0, 0.0, "hold");
      return;
    }
    last_x_ = best_x;
    last_action_ = static_cast<int>(best);
    const bool changed = kTargets[best] != current;
    set_active(kTargets[best]);
    settling_ = changed;
    log(now, tps, abort_rate, reward, best_mean, best_bonus,
        changed ? "choose" : "hold");
  }

 private:
  using Vec = std::array<double, kDim>;
  using Mat = std::array<Vec, kDim>;

  static bool allowed(uint64_t candidate) {
    if (!FLAGS_metis_test_coarse_actions) return true;
    return candidate == 8 || candidate == 16 || candidate == 24 ||
           candidate == 32 || candidate == 48 || candidate == 64 ||
           candidate == 96;
  }

  size_t observed_target(double probe_abort, double coefficient) const {
    const double ideal = coefficient / std::max(0.005, probe_abort);
    size_t selected = kActions;
    double best_distance = std::numeric_limits<double>::infinity();
    for (size_t a = 0; a < kActions; ++a) {
      if (!allowed(kTargets[a]) || kTargets[a] < FLAGS_tam_min_threads ||
          kTargets[a] > std::min(total_threads_, FLAGS_tam_max_threads)) continue;
      const double distance = std::abs(std::log(kTargets[a] / ideal));
      if (distance < best_distance) {
        selected = a;
        best_distance = distance;
      }
    }
    return selected;
  }

  double fit_observed_coefficient() const {
    std::vector<const ObservedEpisode*> episodes;
    for (const auto& episode : observed_episodes_)
      if (episode.probe_tps > 0.0) episodes.push_back(&episode);
    if (FLAGS_metis_test_learn && observed_current_.probe_tps > 0.0)
      episodes.push_back(&observed_current_);
    if (episodes.empty()) return 6.0;

    double best_score = -std::numeric_limits<double>::infinity();
    std::vector<double> maximizers;
    const int first_step = static_cast<int>(std::ceil(
        FLAGS_metis_test_observed_min_coefficient / 0.05));
    for (int step = first_step; step <= 240; ++step) {
      const double coefficient = step * 0.05;
      double score_sum = 0.0;
      size_t usable = 0;
      for (const auto* episode : episodes) {
        double best_mean = 0.0;
        for (size_t a = 0; a < kActions; ++a) {
          if (allowed(kTargets[a]) && episode->counts[a] != 0)
            best_mean = std::max(best_mean,
                episode->reward_sums[a] / episode->counts[a]);
        }
        const size_t chosen = observed_target(episode->probe_abort, coefficient);
        if (chosen == kActions || episode->counts[chosen] == 0 ||
            best_mean <= 0.0) continue;
        score_sum += (episode->reward_sums[chosen] /
                      episode->counts[chosen]) / best_mean;
        ++usable;
      }
      if (usable == 0) continue;
      const double score = score_sum / usable;
      if (score > best_score + 1e-10) {
        best_score = score;
        maximizers.clear();
        maximizers.push_back(coefficient);
      } else if (std::abs(score - best_score) <= 1e-10) {
        maximizers.push_back(coefficient);
      }
    }
    // A range of coefficients often gives the same training reward. Its
    // center is less sensitive to noise in the next 96-worker probe.
    return maximizers.empty() ? 6.0 : maximizers[maximizers.size() / 2];
  }

  void update_observed(std::chrono::steady_clock::time_point now,
                       double tps, double abort_rate) {
    if (observed_probing_) {
      if (observed_skip_probe_interval_) {
        observed_skip_probe_interval_ = false;
        log(now, tps, abort_rate, 0.0, -1.0, 0.0, "probe_settle");
        return;
      }
      observed_probe_tps_sum_ += tps;
      observed_probe_abort_sum_ += abort_rate;
      ++observed_probe_count_;
      if (observed_probe_count_ < FLAGS_metis_test_probe_intervals) {
        log(now, tps, abort_rate, 0.0, -1.0, 0.0, "probe");
        return;
      }
      observed_current_ = {};
      observed_current_.probe_tps = std::max(1.0,
          observed_probe_tps_sum_ / observed_probe_count_);
      observed_current_.probe_abort =
          observed_probe_abort_sum_ / observed_probe_count_;
      // Changing the number of active homes normally moves throughput and
      // contention in opposite directions at the same 96-worker probe action.
      // Reject same-direction excursions caused by transient host slowdowns.
      const bool contradictory_probe = observed_previous_probe_tps_ > 0.0 &&
          ((observed_current_.probe_tps < observed_previous_probe_tps_ * 0.80 &&
            observed_current_.probe_abort <
                observed_previous_probe_abort_ * 0.80) ||
           (observed_current_.probe_tps > observed_previous_probe_tps_ * 1.25 &&
            observed_current_.probe_abort >
                observed_previous_probe_abort_ * 1.25));
      if (contradictory_probe) {
        observed_current_.probe_tps = observed_previous_probe_tps_;
        observed_current_.probe_abort = observed_previous_probe_abort_;
      }
      observed_probing_ = false;
      observed_probe_time_ = now;
      observed_anchor_tps_ = observed_anchor_abort_ = 0.0;
      last_action_ = -1;
      settling_ = false;
      log(now, tps, abort_rate, 1.0, observed_current_.probe_abort,
          observed_current_.probe_tps,
          contradictory_probe ? "probe_reject" : "probe_ready");
    } else {
      if (last_action_ >= 0) {
        if (settling_) {
          settling_ = false;
          log(now, tps, abort_rate, 0.0, -1.0, 0.0, "settle");
          return;
        }
        if (FLAGS_metis_test_learn) {
          ++observed_current_.counts[last_action_];
          observed_current_.reward_sums[last_action_] +=
              tps / observed_current_.probe_tps;
          ++observations_;
        }
      }
      // A real workload shift changes throughput and contention in opposite
      // directions at a fixed action. Probe immediately when both move far
      // enough; keep periodic probes as a fallback for smaller changes.
      // Fixed-workload training deliberately sweeps actions. Those action
      // changes can move TPS and abort rate as much as a workload switch;
      // probing again would split one training episode before all actions
      // receive their required samples. Dynamic evaluation still detects
      // changes and starts a new probe episode.
      const bool load_change = !FLAGS_metis_test_learn &&
          observed_anchor_tps_ > 0.0 &&
          ((tps < observed_anchor_tps_ * 0.70 &&
            abort_rate > std::max(0.03, observed_anchor_abort_ * 1.8)) ||
           (tps > observed_anchor_tps_ * 1.35 &&
            observed_anchor_abort_ > 0.02 &&
            abort_rate < observed_anchor_abort_ * 0.60));
      if (!load_change && tps > 0.0) {
        if (observed_anchor_tps_ == 0.0) {
          observed_anchor_tps_ = tps;
          observed_anchor_abort_ = abort_rate;
        } else {
          observed_anchor_tps_ = 0.9 * observed_anchor_tps_ + 0.1 * tps;
          observed_anchor_abort_ =
              0.9 * observed_anchor_abort_ + 0.1 * abort_rate;
        }
      }
      if (load_change || (FLAGS_metis_test_reprobe_period_us != 0 &&
          now - observed_probe_time_ >= std::chrono::microseconds(
              FLAGS_metis_test_reprobe_period_us))) {
        observed_previous_probe_tps_ = observed_current_.probe_tps;
        observed_previous_probe_abort_ = observed_current_.probe_abort;
        if (FLAGS_metis_test_learn && observed_current_.probe_tps > 0.0)
          observed_episodes_.push_back(observed_current_);
        observed_current_ = {};
        observed_probe_count_ = 0;
        observed_probe_tps_sum_ = observed_probe_abort_sum_ = 0.0;
        observed_anchor_tps_ = observed_anchor_abort_ = 0.0;
        observed_probing_ = true;
        observed_skip_probe_interval_ = active_threads() != total_threads_;
        last_action_ = -1;
        settling_ = false;
        set_active(total_threads_);
        log(now, tps, abort_rate, 0.0, -1.0, 0.0,
            load_change ? "change_probe" : "reprobe");
        return;
      }
    }

    size_t selected = kActions;
    if (FLAGS_metis_test_learn && FLAGS_metis_test_min_pulls_per_action != 0) {
      uint64_t fewest = FLAGS_metis_test_min_pulls_per_action;
      std::vector<size_t> eligible;
      for (size_t a = 0; a < kActions; ++a) {
        if (!allowed(kTargets[a]) || kTargets[a] < FLAGS_tam_min_threads ||
            kTargets[a] > std::min(total_threads_, FLAGS_tam_max_threads) ||
            observed_current_.counts[a] >= FLAGS_metis_test_min_pulls_per_action)
          continue;
        if (observed_current_.counts[a] < fewest) {
          fewest = observed_current_.counts[a];
          eligible.clear();
        }
        if (observed_current_.counts[a] == fewest) eligible.push_back(a);
      }
      if (!eligible.empty()) selected = eligible[rng_() % eligible.size()];
    }
    // Evaluation episodes are immutable. Fit once while loading the model;
    // running the grid search on every control tick stalls the hot path.
    const double coefficient = FLAGS_metis_test_learn ?
        fit_observed_coefficient() : observed_coefficient_;
    if (selected == kActions)
      selected = observed_target(observed_current_.probe_abort, coefficient);
    if (selected == kActions) {
      log(now, tps, abort_rate, 0.0, -1.0, coefficient, "hold");
      return;
    }
    const uint64_t current = active_threads();
    last_action_ = static_cast<int>(selected);
    set_active(kTargets[selected]);
    settling_ = kTargets[selected] != current;
    log(now, tps, abort_rate, tps / observed_current_.probe_tps,
        coefficient / std::max(0.005, observed_current_.probe_abort),
        coefficient, settling_ ? "choose" : "hold");
  }

  static double reward_scale() {
    if (FLAGS_metis_test_reward_profile == "physical_first_item100k") {
      // Two-run fixed-worker sweep, mimalloc, Item=100000, standard mix,
      // physical-core-first pinning, random-per-transaction home W.
      constexpr std::array<double, 7> ws = {1, 4, 8, 16, 32, 64, 96};
      constexpr std::array<double, 7> tps = {
          54349.5, 125190.0, 218270.5, 389050.5,
          598057.0, 779349.0, 880460.5};
      const double w = static_cast<double>(
          g_tpcc_runtime_active_warehouses.load(std::memory_order_acquire));
      if (w <= ws.front()) return tps.front();
      for (size_t i = 1; i < ws.size(); ++i) {
        if (w <= ws[i]) {
          const double f = (std::log(w) - std::log(ws[i - 1])) /
                           (std::log(ws[i]) - std::log(ws[i - 1]));
          return tps[i - 1] + f * (tps[i] - tps[i - 1]);
        }
      }
      return tps.back();
    }
    if (!FLAGS_metis_test_cross_workload)
      return FLAGS_metis_test_tps_scale;
    const double w = static_cast<double>(
        g_tpcc_runtime_active_warehouses.load(std::memory_order_acquire));
    return FLAGS_metis_test_tps_scale *
        (-std::expm1(-w / 16.0)) / (-std::expm1(-1.0));
  }

  static double dot(const Vec& x, const Vec& y) {
    double result = 0.0;
    for (size_t i = 0; i < kDim; ++i) result += x[i] * y[i];
    return result;
  }
  static Vec multiply(const Mat& m, const Vec& x) {
    Vec result{};
    for (size_t i = 0; i < kDim; ++i)
      for (size_t j = 0; j < kDim; ++j) result[i] += m[i][j] * x[j];
    return result;
  }
  static bool invert(const Mat& source, Mat& inverse) {
    double aug[kDim][2 * kDim]{};
    for (size_t i = 0; i < kDim; ++i) {
      for (size_t j = 0; j < kDim; ++j) aug[i][j] = source[i][j];
      aug[i][i + kDim] = 1.0;
    }
    for (size_t col = 0; col < kDim; ++col) {
      size_t pivot = col;
      for (size_t row = col + 1; row < kDim; ++row)
        if (std::abs(aug[row][col]) > std::abs(aug[pivot][col])) pivot = row;
      if (std::abs(aug[pivot][col]) < 1e-12) return false;
      for (size_t j = 0; j < 2 * kDim; ++j)
        std::swap(aug[col][j], aug[pivot][j]);
      const double scale = aug[col][col];
      for (size_t j = 0; j < 2 * kDim; ++j) aug[col][j] /= scale;
      for (size_t row = 0; row < kDim; ++row) {
        if (row == col) continue;
        const double factor = aug[row][col];
        for (size_t j = 0; j < 2 * kDim; ++j)
          aug[row][j] -= factor * aug[col][j];
      }
    }
    for (size_t i = 0; i < kDim; ++i)
      for (size_t j = 0; j < kDim; ++j) inverse[i][j] = aug[i][j + kDim];
    return true;
  }

  Vec context(double abort_rate, double tps, uint64_t current,
              uint64_t candidate, double trend) const {
    const double c = static_cast<double>(candidate) / total_threads_;
    const double current_ratio = static_cast<double>(current) / total_threads_;
    const double w = static_cast<double>(
        g_tpcc_runtime_active_warehouses.load(std::memory_order_acquire));
    double coverage = 0.0, concentration = 1.0;
    if (FLAGS_metis_test_random_per_transaction) {
      coverage = 1.0 - std::pow(1.0 - 1.0 / w, candidate);
      concentration = 1.0 + (w - 1.0) / candidate;
    } else {
      std::vector<uint64_t> counts(static_cast<size_t>(w), 0);
      for (size_t thid = 0; thid < candidate; ++thid) {
        const auto home = g_metis_test_home_warehouses[thid].load(
            std::memory_order_acquire);
        if (home >= 1 && home <= counts.size()) ++counts[home - 1];
      }
      double sum_squares = 0.0;
      for (auto n : counts) {
        coverage += (n != 0);
        sum_squares += static_cast<double>(n) * n;
      }
      coverage /= w;
      concentration = w * sum_squares / (candidate * candidate);
    }
    if (FLAGS_metis_test_cross_workload) {
      const double wl = std::log2(w + 1.0) / std::log2(97.0);
#ifdef METIS_TEST_SMT
      // physical_first uses 48 physical cores before SMT siblings. The step
      // captures the boundary; the fraction captures how many siblings run.
      const double smt_on = candidate > 48 ? 1.0 : 0.0;
      const double smt_fraction = candidate > 48 ?
          static_cast<double>(candidate - 48) / 48.0 : 0.0;
      return {1.0, abort_rate, tps / reward_scale(), current_ratio,
              c, c * c, wl, c * wl, c * c * wl, coverage,
              concentration, abort_rate * c, smt_on, smt_fraction};
#else
      return {1.0, abort_rate, tps / reward_scale(), current_ratio,
              c, c * c, wl, c * wl, c * c * wl, coverage,
              concentration, abort_rate * c};
#endif
    }
#ifdef METIS_TEST_SMT
    const double smt_on = candidate > 48 ? 1.0 : 0.0;
    const double smt_fraction = candidate > 48 ?
        static_cast<double>(candidate - 48) / 48.0 : 0.0;
    return {1.0, abort_rate, tps / FLAGS_metis_test_tps_scale,
            current_ratio, c, c - current_ratio, abort_rate * c,
            tps / (current * 10000.0), trend / FLAGS_metis_test_tps_scale,
            c * c, coverage, concentration, smt_on, smt_fraction};
#else
    return {1.0, abort_rate, tps / FLAGS_metis_test_tps_scale,
            current_ratio, c, c - current_ratio, abort_rate * c,
            tps / (current * 10000.0), trend / FLAGS_metis_test_tps_scale,
            c * c, coverage, concentration};
#endif
  }

  void set_active(uint64_t count) {
    active_.store(count, std::memory_order_release);
    g_metis_test_active_threads.store(count, std::memory_order_release);
  }
  void log(std::chrono::steady_clock::time_point now, double tps,
           double abort_rate, double reward, double predicted,
           double bonus, const char* phase) {
    if (!FLAGS_tam_log_active_threads) return;
    const auto period = std::chrono::microseconds(FLAGS_tam_log_period_us);
    if (now - last_log_time_ < period) return;
    const double value = active_threads();
    ++stats_count_; stats_sum_ += value;
    const auto benchmark_start_us =
        g_tpcc_benchmark_start_us.load(std::memory_order_acquire);
    const auto now_us = std::chrono::duration_cast<std::chrono::microseconds>(
        now.time_since_epoch()).count();
    const double benchmark_s = benchmark_start_us == 0 ? -1.0 :
        (now_us - benchmark_start_us) / 1e6;
    std::fprintf(stderr,
        "[Metis-test] elapsed_s=%.3f bench_s=%.3f phase=%s active_threads=%llu tput=%.0f abort_rate=%.4f "
        "reward=%.5f predicted=%.5f bonus=%.5f model_samples=%llu\n",
        std::chrono::duration<double>(now - start_time_).count(),
        benchmark_s, phase, static_cast<unsigned long long>(active_threads()), tps,
        abort_rate, reward, predicted, bonus,
        static_cast<unsigned long long>(observations_));
    last_log_time_ = now;
  }

  std::atomic<uint64_t> active_{0};
  uint64_t total_threads_{0};
  std::chrono::steady_clock::time_point last_time_{};
  std::chrono::steady_clock::time_point start_time_{};
  std::chrono::steady_clock::time_point last_log_time_{};
  uint64_t last_committed_{0}, last_aborts_{0}, step_{0}, observations_{0};
  double last_tps_{0.0};
  bool have_last_tps_{false}, settling_{false};
  int last_action_{-1};
  Vec last_x_{};
  Mat A_{};
  Vec b_{};
  std::array<uint64_t, kActions> samples_{};
  std::array<double, kActions> reward_sum_{};
  std::vector<ObservedEpisode> observed_episodes_{};
  ObservedEpisode observed_current_{};
  double observed_coefficient_{6.0};
  bool observed_probing_{false}, observed_skip_probe_interval_{false};
  uint64_t observed_probe_count_{0};
  double observed_probe_tps_sum_{0.0}, observed_probe_abort_sum_{0.0};
  double observed_previous_probe_tps_{0.0}, observed_previous_probe_abort_{0.0};
  double observed_anchor_tps_{0.0}, observed_anchor_abort_{0.0};
  std::chrono::steady_clock::time_point observed_probe_time_{};
  std::mt19937_64 rng_{};
  uint64_t stats_count_{0};
  double stats_sum_{0.0};
};


class TamController {
 public:
  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    if (static_cast<int>(FLAGS_metis_test_enable) +
        static_cast<int>(FLAGS_metis_paper_enable) +
        static_cast<int>(FLAGS_metis_v2_enable) +
        static_cast<int>(FLAGS_ada_tam_enable) > 1) {
      std::fprintf(stderr, "Enable only one TAM controller\n");
      std::abort();
    }
    if (FLAGS_metis_test_enable) {
      metis_test_.init(total_threads, clocks_per_us);
      if (!FLAGS_linucb_model_path.empty()) {
        std::ifstream model(FLAGS_linucb_model_path);
        if (model.good() && !metis_test_.load_model(FLAGS_linucb_model_path)) {
          std::fprintf(stderr, "Invalid Metis-test model: %s\n",
                       FLAGS_linucb_model_path.c_str());
          std::abort();
        }
        if (!model.good() && !FLAGS_linucb_model_autosave) {
          std::fprintf(stderr, "Missing Metis-test model: %s\n",
                       FLAGS_linucb_model_path.c_str());
          std::abort();
        }
      }
    }
    if (FLAGS_metis_paper_enable) {
      metis_paper_.init(total_threads, clocks_per_us);
      if (!FLAGS_linucb_model_path.empty()) {
        metis_paper_.load_model(FLAGS_linucb_model_path);
      }
    }
    if (FLAGS_metis_v2_enable) {
      metis_v2_.init(total_threads);
      if (!FLAGS_linucb_model_path.empty()) {
        std::ifstream model(FLAGS_linucb_model_path);
        if (model.good() && !metis_v2_.load_model(FLAGS_linucb_model_path)) {
          std::fprintf(stderr, "Invalid Metis v2 model: %s\n",
                       FLAGS_linucb_model_path.c_str());
          std::abort();
        }
        if (!model.good() && !FLAGS_metis_v2_learn) {
          std::fprintf(stderr, "Missing Metis v2 model: %s\n",
                       FLAGS_linucb_model_path.c_str());
          std::abort();
        }
      } else if (!FLAGS_metis_v2_learn) {
        std::fprintf(stderr, "Metis v2 evaluation needs --linucb_model_path\n");
        std::abort();
      }
    }
    if (FLAGS_ada_tam_enable) {
      adatam_.init(total_threads, clocks_per_us);
    }
  }

  bool enabled() const {
    return FLAGS_ada_tam_enable || FLAGS_metis_paper_enable ||
           FLAGS_metis_test_enable || FLAGS_metis_v2_enable;
  }

  uint64_t active_threads() const {
    if (FLAGS_metis_test_enable) return metis_test_.active_threads();
    if (FLAGS_metis_v2_enable) return metis_v2_.active_threads();
    if (FLAGS_metis_paper_enable) return metis_paper_.active_threads();
    return adatam_.active_threads();
  }

  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (FLAGS_metis_test_enable) {
      metis_test_.update(committed_txs, abort_txs);
      return;
    }
    if (FLAGS_metis_v2_enable) {
      metis_v2_.update(committed_txs, abort_txs);
      return;
    }
    if (FLAGS_metis_paper_enable) {
      metis_paper_.update(committed_txs, abort_txs);
      return;
    }
    adatam_.update(committed_txs, abort_txs);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    if (FLAGS_metis_test_enable) {
      metis_test_.print_stats();
    } else if (FLAGS_metis_v2_enable) {
      metis_v2_.print_stats();
    } else if (FLAGS_metis_paper_enable) {
      metis_paper_.print_stats();
    } else if (FLAGS_ada_tam_enable) {
      adatam_.print_stats();
    }
  }

  bool save_model(const std::string &path) const {
    if (FLAGS_metis_test_enable) return metis_test_.save_model(path);
    if (FLAGS_metis_v2_enable) return metis_v2_.save_model(path);
    if (FLAGS_metis_paper_enable) return metis_paper_.save_model(path);
    return false;
  }

 private:
  AdaTAM adatam_;
  Metis_paper metis_paper_;
  Metis_test metis_test_;
  MetisV2 metis_v2_;
};
