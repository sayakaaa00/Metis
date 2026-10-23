#pragma once

#include <x86intrin.h>

#include <atomic>
#include <array>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <limits>

#include "atomic_wrapper.hh"
#include "result.hh"
#include "tsc.hh"
#include "util.hh"
#include "gflags/gflags.h"

using namespace std;

// AdaBO / LinUCBBO parameters as gflags
#ifdef GLOBAL_VALUE_DEFINE
DEFINE_uint64(backoff_update_period_us, 5000,
              "AdaBO update period in microseconds (how often to adjust backoff)");
DEFINE_double(backoff_step_us, 0.5,
        "AdaBO base step in microseconds (used by AdaBO gradient method)");
DEFINE_bool(backoff_fixed_enable, false,
            "If true, disable adaptive updates and use a fixed backoff time");
DEFINE_double(backoff_fixed_us, 0.0,
              "Fixed backoff time in microseconds when backoff_fixed_enable=true");

DEFINE_bool(linucb_bo_enable, false,
            "Enable LinUCB-based backoff management (LinUCBBO)");
DEFINE_double(linucb_bo_alpha, 1.0,
              "Exploration parameter alpha for LinUCBBO");
DEFINE_double(linucb_bo_lambda, 1.0,
              "Regularization parameter lambda for LinUCBBO");
DEFINE_bool(bo_log_backoff, false,
            "If true, log backoff value at each LinUCBBO update");
DEFINE_bool(backoff_log_enable, false,
            "If true, periodically log active AdaBO backoff values to a file");
DEFINE_uint64(backoff_log_interval_us, 10000,
              "AdaBO logging interval in microseconds");
#else
DECLARE_uint64(backoff_update_period_us);
DECLARE_double(backoff_step_us);
DECLARE_bool(backoff_fixed_enable);
DECLARE_double(backoff_fixed_us);

DECLARE_bool(linucb_bo_enable);
DECLARE_double(linucb_bo_alpha);
DECLARE_double(linucb_bo_lambda);
DECLARE_bool(bo_log_backoff);
DECLARE_bool(backoff_log_enable);
DECLARE_uint64(backoff_log_interval_us);
#endif

class Backoff {
public:
  static std::atomic<double> Backoff_;
  static FILE *LogFp_;
  static thread_local uint32_t ConsecutiveAborts_;
  static constexpr double kMinBackoff = 0;
  static constexpr double kMaxBackoff = 1000;
  static constexpr double kIncrBackoff = 0.5;
  //static constexpr double kIncrBackoff = 0.5;

  uint64_t last_committed_txs_ = 0;
  double last_committed_tput_ = 0;
  uint64_t last_backoff_ = 0;
  uint64_t last_time_ = 0;
  size_t clocks_per_us_;

  Backoff(size_t clocks_per_us) {
    init(clocks_per_us);
  }

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

    uint64_t period_cycles = static_cast<uint64_t>(FLAGS_backoff_update_period_us) * clocks_per_us_;
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
      if ((committed_txs & 1) == 0 || new_backoff == kMaxBackoff)  // 確率はおよそ 1/2, すなわちランダム．
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

  static void reset() { ConsecutiveAborts_ = 0; }

  static bool log_enabled() { return FLAGS_backoff_log_enable; }

  static uint64_t log_interval_us() { return FLAGS_backoff_log_interval_us; }

  static void set_log_file(FILE *fp) { LogFp_ = fp; }

  static FILE *log_file() { return LogFp_; }

  static double clamp_backoff(double backoff_us) {
    if (backoff_us < kMinBackoff) return kMinBackoff;
    if (backoff_us > kMaxBackoff) return kMaxBackoff;
    return backoff_us;
  }

  static double current_backoff_us() {
    const double base_backoff =
        clamp_backoff(Backoff_.load(std::memory_order_acquire));
    if (base_backoff <= 0.0) return 0.0;

    double exp_backoff = std::ldexp(base_backoff, ConsecutiveAborts_);
    return clamp_backoff(exp_backoff);
  }

  static void log_sample(uint64_t elapsed_us, uint64_t elapsed_interval_us,
                         uint64_t committed_txs, uint64_t abort_txs,
                         uint64_t committed_interval, uint64_t abort_interval) {
    if (!FLAGS_backoff_log_enable || LogFp_ == nullptr) return;

    double interval_tps = 0.0;
    if (elapsed_interval_us > 0) {
      interval_tps = static_cast<double>(committed_interval) * 1e6 /
                     static_cast<double>(elapsed_interval_us);
    }

    std::fprintf(LogFp_,
                 "elapsed_us=%llu backoff_us=%.3f committed=%llu abort=%llu interval_committed=%llu interval_abort=%llu interval_tps=%.3f\n",
                 static_cast<unsigned long long>(elapsed_us),
                 Backoff_.load(std::memory_order_acquire),
                 static_cast<unsigned long long>(committed_txs),
                 static_cast<unsigned long long>(abort_txs),
                 static_cast<unsigned long long>(committed_interval),
                 static_cast<unsigned long long>(abort_interval),
                 interval_tps);
    std::fflush(LogFp_);
  }

};

// LinUCBBO: LinUCB-based Backoff Optimizer
//
// - 状態ベクトル x = [throughput (scaled), abort_rate, backoff (scaled)]^T
// - 行動は backoff を {-1.0, -0.5, +0.5, +1.0} [us] だけ増減させる。
// - 報酬は committed throughput [tx/s]。
class LinUCBBO {
 public:
  LinUCBBO() = default;

  void init(uint64_t clocks_per_us) {
    clocks_per_us_ = clocks_per_us;
    last_time_ = rdtscp();
    last_committed_txs_ = 0;
    last_abort_txs_ = 0;
    last_action_index_ = -1;
    last_x_ = {0.0, 0.0, 0.0};

    double lambda = FLAGS_linucb_bo_lambda;
    if (lambda <= 0.0) lambda = 1.0;

    for (size_t a = 0; a < kNumActions; ++a) {
      A_[a] = identity_matrix(lambda);
      b_[a] = {0.0, 0.0, 0.0};
    }
  }

  bool enabled() const { return FLAGS_linucb_bo_enable; }

  void print_stats() const {
    if (!FLAGS_bo_log_backoff) return;
    if (stats_count_ == 0) return;

    double n    = static_cast<double>(stats_count_);
    double mean = stats_sum_ / n;
    double var  = stats_sq_sum_ / n - mean * mean;
    if (var < 0.0) var = 0.0;
    double stddev = std::sqrt(var);

    std::fprintf(stderr,
                 "[LinUCBBO] backoff stats: count=%llu mean=%.3f stddev=%.3f\n",
                 static_cast<unsigned long long>(stats_count_),
                 mean,
                 stddev);
  }

  // Leader スレッドなどから周期的に呼ぶ。
  // committed_txs / abort_txs は全 worker の累積コミット / アボート回数。
  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (!FLAGS_linucb_bo_enable) return;

    uint64_t now = rdtscp();
    uint64_t dt = now - last_time_;
    uint64_t period_clocks = FLAGS_backoff_update_period_us * clocks_per_us_;
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

    double current_backoff = Backoff::Backoff_.load(std::memory_order_relaxed);

    Vec x = build_state_vector(committed_tput, abort_rate, current_backoff);
    double reward = committed_tput;  // シンプルに throughput をそのまま報酬とする

    // 直前の行動に対するフィードバックで A, b を更新
    if (last_action_index_ >= 0) {
      size_t a = static_cast<size_t>(last_action_index_);
      add_outer_product(A_[a], last_x_);
      add_scaled_vector(b_[a], last_x_, reward);
    }

    const double min_backoff = Backoff::kMinBackoff;
    const double max_backoff = Backoff::kMaxBackoff;

    size_t best_action = 0;
    double best_score = -1e300;
    double alpha = FLAGS_linucb_bo_alpha;
    if (alpha < 0.0) alpha = 0.0;

    bool any_effective_action = false;

    // clamp 後に backoff が変化するアクションだけを候補にする。
    for (size_t a = 0; a < kNumActions; ++a) {
    double delta = kActionDeltasUs[a];
    double proposed = current_backoff + delta;
      if (proposed < min_backoff) proposed = min_backoff;
      else if (proposed > max_backoff) proposed = max_backoff;

      if (std::fabs(proposed - current_backoff) < 1e-12) {
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

    // すべてのアクションが実質的に効果を持たない（min==max など）の場合、
    // 元の LinUCB と同様に単純に最大スコアのアクションを選ぶ。
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

    double next = current_backoff + kActionDeltasUs[best_action];

    if (next < min_backoff) next = min_backoff;
    if (next > max_backoff) next = max_backoff;

    Backoff::Backoff_.store(next, std::memory_order_release);

    if (FLAGS_bo_log_backoff) {
      std::fprintf(stderr,
            "[LinUCBBO] backoff=%.3f action_step=%.1f tput=%.0f tx/s abort_rate=%.4f\n",
            next,
            kActionDeltasUs[best_action],
            committed_tput,
            abort_rate);

      // active backoff 値の平均・分散用統計
      stats_count_ += 1;
      stats_sum_   += next;
      stats_sq_sum_ += next * next;
    }

    last_action_index_ = static_cast<int64_t>(best_action);
    last_x_ = x;
    last_time_ = now;
    last_committed_txs_ = committed_txs;
    last_abort_txs_ = abort_txs;
  }

 private:
  static constexpr size_t kNumActions = 4;
  // backoff をどれだけ増減させるか [us]
  static constexpr std::array<double, kNumActions> kActionDeltasUs{{-1.0, -0.5, 0.5, 1.0}};
  using Vec = std::array<double, 3>;
  using Mat = std::array<std::array<double, 3>, 3>;

  Vec build_state_vector(double tput, double abort_rate, double backoff) const {
    double tput_scaled = tput / 1e6;  // O(1) になるようスケール
    double backoff_scaled = 0.0;
    if (Backoff::kMaxBackoff > 0.0) {
      backoff_scaled = backoff / Backoff::kMaxBackoff;
    }
    return {tput_scaled, abort_rate, backoff_scaled};
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

[[maybe_unused]] inline void
leaderBackoffWork([[maybe_unused]] Backoff &backoff, [[maybe_unused]] std::vector <Result> &res) {
  if (backoff.check_update_backoff()) {
    uint64_t sum_committed_txs(0);
    for (auto &th : res) {
      sum_committed_txs += loadAcquire(th.local_commit_counts_);
    }
    backoff.update_backoff(sum_committed_txs);
  }
}

#ifdef GLOBAL_VALUE_DEFINE
std::atomic<double> Backoff::Backoff_(0);
FILE *Backoff::LogFp_(nullptr);
thread_local uint32_t Backoff::ConsecutiveAborts_ = 0;
#endif
