#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

#include "gflags/gflags.h"
#include "adaptive_state.hh"
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
DECLARE_uint64(tam_update_period_us);
DECLARE_uint64(tam_log_period_us);
DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_double(ada_tam_step);
DECLARE_bool(tam_log_active_threads);
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


class TamController {
 public:
  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    if (FLAGS_metis_paper_enable) {
      metis_paper_.init(total_threads, clocks_per_us);
      if (!FLAGS_linucb_model_path.empty()) {
        metis_paper_.load_model(FLAGS_linucb_model_path);
      }
    }
    if (FLAGS_ada_tam_enable) {
      adatam_.init(total_threads, clocks_per_us);
    }
  }

  bool enabled() const {
    return FLAGS_ada_tam_enable || FLAGS_metis_paper_enable;
  }

  uint64_t active_threads() const {
    if (FLAGS_metis_paper_enable) return metis_paper_.active_threads();
    return adatam_.active_threads();
  }

  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (FLAGS_metis_paper_enable) {
      metis_paper_.update(committed_txs, abort_txs);
      return;
    }
    adatam_.update(committed_txs, abort_txs);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    if (FLAGS_metis_paper_enable) {
      metis_paper_.print_stats();
    } else if (FLAGS_ada_tam_enable) {
      adatam_.print_stats();
    }
  }

  bool save_model(const std::string &path) const {
    if (FLAGS_metis_paper_enable) return metis_paper_.save_model(path);
    return false;
  }

 private:
  AdaTAM adatam_;
  Metis_paper metis_paper_;
};
