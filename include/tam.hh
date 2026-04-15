#pragma once

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "gflags/gflags.h"
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
DEFINE_bool(linucb_tam_enable, false,
            "Enable LinUCB-based thread activity management (LinUCBTAM)");
DEFINE_uint64(tam_update_period_us, 100000,
              "How often (in us) TAM updates active thread count");
DEFINE_uint64(tam_min_threads, 1,
              "Minimum number of active worker threads is enabled");
DEFINE_uint64(tam_max_threads, 64,
              "Maximum number of active worker threads is enabled");
DEFINE_double(ada_tam_step, 2.0,
              "Step size (in threads) when AdaTAM increases/decreases active threads");
DEFINE_bool(tam_log_active_threads, false,
            "If true, log active thread count at each AdaTAM update");
DEFINE_double(linucb_alpha, 1.0,
              "Exploration parameter alpha for LinUCBTAM");
DEFINE_double(linucb_lambda, 1.0,
              "Regularization parameter lambda for LinUCBTAM");

#else
DECLARE_bool(ada_tam_enable);
DECLARE_bool(linucb_tam_enable);
DECLARE_uint64(tam_update_period_us);
DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_double(ada_tam_step);
DECLARE_bool(tam_log_active_threads);
DECLARE_double(linucb_alpha);
DECLARE_double(linucb_lambda);
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
    }
  }

 private:
  std::atomic<uint64_t> active_threads_{0};
  uint64_t total_threads_{0};
  uint64_t clocks_per_us_{0};
  uint64_t last_time_{0};
  uint64_t last_committed_txs_{0};
  double last_tput_{0.0};
  int64_t last_threads_{0};
  // tam_log_active_threads 時に active_threads の平均・分散をとるためのバッファ
  uint64_t stats_count_{0};
  double   stats_sum_{0.0};
  double   stats_sq_sum_{0.0};
};

class LinUCBTAM {
 public:
  LinUCBTAM() = default;

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
    last_abort_txs_ = 0;
    last_action_index_ = -1;
    last_x_ = {0.0, 0.0, 0.0};

    double lambda = FLAGS_linucb_lambda;
    if (lambda <= 0.0) lambda = 1.0;

    for (size_t a = 0; a < kNumActions; ++a) {
      A_[a] = identity_matrix(lambda);
      b_[a] = {0.0, 0.0, 0.0};
    }
  }

  bool enabled() const { return FLAGS_linucb_tam_enable; }

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
            "[LinUCBTAM] active_threads stats: count=%llu mean=%.3f stddev=%.3f\n",
            static_cast<unsigned long long>(stats_count_),
            mean,
            stddev);
  }

  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (!FLAGS_linucb_tam_enable) return;

    uint64_t now = rdtscp();
    uint64_t dt = now - last_time_;
    uint64_t period_clocks = FLAGS_tam_update_period_us * clocks_per_us_;
    if (dt < period_clocks) return;
    if (dt == 0) return;

    uint64_t committed_diff = committed_txs - last_committed_txs_;
    uint64_t abort_diff = abort_txs - last_abort_txs_;

    double committed_tput = 0.0;
    if (dt > 0) {
      committed_tput = static_cast<double>(committed_diff) /
                       (static_cast<double>(dt) /
                        static_cast<double>(clocks_per_us_)) *
                       1e6;  // tx/sec
    }

    double abort_rate = 0.0;
    uint64_t total_attempts = committed_diff + abort_diff;
    if (total_attempts > 0) {
      abort_rate = static_cast<double>(abort_diff) /
                   static_cast<double>(total_attempts);
    }

    int64_t current_threads =
        static_cast<int64_t>(active_threads_.load(std::memory_order_relaxed));

    Vec x = build_state_vector(committed_tput, abort_rate, current_threads);
    double reward = committed_tput;

    if (last_action_index_ >= 0) {
      size_t a = static_cast<size_t>(last_action_index_);
      add_outer_product(A_[a], last_x_);
      add_scaled_vector(b_[a], last_x_, reward);
    }

    // 現在のスレッド数に対して、実際にスレッド数を変化させられるアクションだけを候補にする。
    // 例えば current_threads が最小スレッド数に張り付いているときに「-4」を選んでも
    // clamp の結果は同じスレッド数になってしまうため、そのようなアクションはスキップする。
    uint64_t min_th = FLAGS_tam_min_threads;
    if (min_th == 0) min_th = 1;
    uint64_t max_th = FLAGS_tam_max_threads;
    if (max_th == 0 || max_th > total_threads_) max_th = total_threads_;

    size_t best_action = 0;
    double best_score = -1e300;
    double alpha = FLAGS_linucb_alpha;
    if (alpha < 0.0) alpha = 0.0;

    bool any_effective_action = false;

    for (size_t a = 0; a < kNumActions; ++a) {
      // このアクションを適用したときに実際に変化するスレッド数を事前に確認し、
      // clamp 後も current_threads と同じになるアクションは候補から外す。
      int64_t proposed = current_threads + kActionSteps[a];
      if (proposed < static_cast<int64_t>(min_th)) {
        proposed = static_cast<int64_t>(min_th);
      } else if (proposed > static_cast<int64_t>(max_th)) {
        proposed = static_cast<int64_t>(max_th);
      }
      if (proposed == current_threads) {
        continue;
      }

      Mat invA;
      if (!invert_matrix(A_[a], invA)) {
        invA = identity_matrix(1.0);
      }
      Vec theta = mat_vec(invA, b_[a]);
      double mean = dot(x, theta);
      double bonus = std::sqrt(std::max(0.0, quad_form(invA, x)));
      double score = mean + alpha * bonus;
      if (score > best_score) {
        best_score = score;
        best_action = a;
        any_effective_action = true;
      }
    }

    // すべてのアクションが current_threads に clamp されてしまう（min_th==max_th など）の場合は、
    // 元のロジックにフォールバックして何か 1 つ選ぶ。
    if (!any_effective_action) {
      for (size_t a = 0; a < kNumActions; ++a) {
        Mat invA;
        if (!invert_matrix(A_[a], invA)) {
          invA = identity_matrix(1.0);
        }
        Vec theta = mat_vec(invA, b_[a]);
        double mean = dot(x, theta);
        double bonus = std::sqrt(std::max(0.0, quad_form(invA, x)));
        double score = mean + alpha * bonus;
        if (score > best_score) {
          best_score = score;
          best_action = a;
        }
      }
    }

    int64_t next = current_threads + kActionSteps[best_action];

    if (next < static_cast<int64_t>(min_th)) next = static_cast<int64_t>(min_th);
    if (next > static_cast<int64_t>(max_th)) next = static_cast<int64_t>(max_th);

    active_threads_.store(static_cast<uint64_t>(next), std::memory_order_release);

    if (FLAGS_tam_log_active_threads) {
      fprintf(stderr,
              "[LinUCBTAM] active_threads=%llu action=%ld tput=%.0f tx/s abort_rate=%.4f\n",
              static_cast<unsigned long long>(active_threads()),
              static_cast<long>(kActionSteps[best_action]),
              committed_tput,
              abort_rate);

      // 統計量更新（active_threads の平均・分散用）
      double v = static_cast<double>(next);
      stats_count_ += 1;
      stats_sum_   += v;
      stats_sq_sum_ += v * v;
    }

    last_action_index_ = static_cast<int64_t>(best_action);
    last_x_ = x;
    last_time_ = now;
    last_committed_txs_ = committed_txs;
    last_abort_txs_ = abort_txs;
  }

 private:
  static constexpr size_t kNumActions = 4;
  static constexpr std::array<int64_t, kNumActions> kActionSteps{{-4, -2, +2, +4}};
  using Vec = std::array<double, 3>;
  using Mat = std::array<std::array<double, 3>, 3>;

  Vec build_state_vector(double tput, double abort_rate, int64_t threads) const {
    double tput_scaled = tput / 1e6;  // scale to O(1)
    double thread_scaled = 0.0;
    if (total_threads_ > 0) {
      thread_scaled = static_cast<double>(threads) /
                      static_cast<double>(total_threads_);
    }
    return {tput_scaled, abort_rate, thread_scaled};
  }

  static Mat identity_matrix(double diag) {
    Mat m{};
    for (size_t i = 0; i < 3; ++i) {
      for (size_t j = 0; j < 3; ++j) m[i][j] = 0.0;
      m[i][i] = diag;
    }
    return m;
  }

  static void add_outer_product(Mat &A, const Vec &x) {
    for (size_t i = 0; i < 3; ++i) {
      for (size_t j = 0; j < 3; ++j) {
        A[i][j] += x[i] * x[j];
      }
    }
  }

  static void add_scaled_vector(Vec &b, const Vec &x, double scale) {
    for (size_t i = 0; i < 3; ++i) b[i] += scale * x[i];
  }

  static Vec mat_vec(const Mat &A, const Vec &x) {
    Vec y{};
    for (size_t i = 0; i < 3; ++i) {
      y[i] = 0.0;
      for (size_t j = 0; j < 3; ++j) y[i] += A[i][j] * x[j];
    }
    return y;
  }

  static double dot(const Vec &a, const Vec &b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  }

  static double quad_form(const Mat &A, const Vec &x) {
    Vec Ax = mat_vec(A, x);
    return dot(x, Ax);
  }

  static bool invert_matrix(const Mat &A, Mat &inv) {
    // Gauss-Jordan inversion for 3x3
    double aug[3][6];
    for (size_t i = 0; i < 3; ++i) {
      for (size_t j = 0; j < 3; ++j) {
        aug[i][j] = A[i][j];
        aug[i][j + 3] = (i == j) ? 1.0 : 0.0;
      }
    }

    for (size_t col = 0; col < 3; ++col) {
      size_t pivot = col;
      for (size_t row = col + 1; row < 3; ++row) {
        if (std::fabs(aug[row][col]) > std::fabs(aug[pivot][col])) pivot = row;
      }
      if (std::fabs(aug[pivot][col]) < 1e-12) return false;
      if (pivot != col) {
        for (size_t j = 0; j < 6; ++j) std::swap(aug[col][j], aug[pivot][j]);
      }

      double diag = aug[col][col];
      for (size_t j = 0; j < 6; ++j) aug[col][j] /= diag;

      for (size_t row = 0; row < 3; ++row) {
        if (row == col) continue;
        double factor = aug[row][col];
        for (size_t j = 0; j < 6; ++j) {
          aug[row][j] -= factor * aug[col][j];
        }
      }
    }

    for (size_t i = 0; i < 3; ++i) {
      for (size_t j = 0; j < 3; ++j) {
        inv[i][j] = aug[i][j + 3];
      }
    }
    return true;
  }

  std::atomic<uint64_t> active_threads_{0};
  uint64_t total_threads_{0};
  uint64_t clocks_per_us_{0};
  uint64_t last_time_{0};
  uint64_t last_committed_txs_{0};
  uint64_t last_abort_txs_{0};
  int64_t last_action_index_{-1};
  Vec last_x_{0.0, 0.0, 0.0};
  std::array<Mat, kNumActions> A_{};
  std::array<Vec, kNumActions> b_{};
  uint64_t stats_count_{0};
  double   stats_sum_{0.0};
  double   stats_sq_sum_{0.0};
};

class TamController {
 public:
  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    if (FLAGS_ada_tam_enable && FLAGS_linucb_tam_enable) {
      std::fprintf(stderr,
                   "AdaTAM and LinUCBTAM cannot be enabled at the same time.\n");
      std::fflush(stderr);
      std::abort();
    }
    if (FLAGS_linucb_tam_enable) {
      linucb_.init(total_threads, clocks_per_us);
    }
    if (FLAGS_ada_tam_enable) {
      adatam_.init(total_threads, clocks_per_us);
    }
  }

  bool enabled() const {
    return FLAGS_ada_tam_enable || FLAGS_linucb_tam_enable;
  }

  uint64_t active_threads() const {
    if (FLAGS_linucb_tam_enable) return linucb_.active_threads();
    return adatam_.active_threads();
  }

  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (FLAGS_linucb_tam_enable) {
      linucb_.update(committed_txs, abort_txs);
      return;
    }
    adatam_.update(committed_txs, abort_txs);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    if (FLAGS_linucb_tam_enable) {
      linucb_.print_stats();
    } else if (FLAGS_ada_tam_enable) {
      adatam_.print_stats();
    }
  }

 private:
  AdaTAM adatam_;
  LinUCBTAM linucb_;
};
