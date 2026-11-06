#pragma once

// Metis: workload-agnostic control of the number of active worker threads.
//
// The controller runs the first N of the spawned workers and picks N from
// {8, 10, ..., 96}. It predicts the throughput ratio of a move c -> a with one
// shared linear model,
//
//   log(T(a) / T(c)) ~ theta^T x,   x = kron(phi(a) - phi(c), psi(c)),
//
// where phi(n) = (log v, v, v^2, cross-socket share, SMT share) with v = n/N
// describes how a thread count uses the CPU (the socket and SMT boundaries are
// read from the CPU topology), and psi(c) = (1, R, R^2, c/N) is the state
// observed at the current count c (R: abort rate). x = 0 when a = c, so staying
// always predicts a ratio of 1. No benchmark-specific input (warehouse count,
// skew) and no absolute throughput enters the model.
//
// Training (--metis_learn): move to uniformly random counts and add one ridge
// regression sample (x, log(T(a)/T(c))) per move. The sufficient statistics
// (A, b) are saved to --metis_model_path and can be summed across runs.
//
// Evaluation: starting from all workers,
//   1. move to the count with the best predicted gain (at most
//      --metis_model_moves moves to unmeasured counts),
//   2. refine locally by measuring the untried neighbours at +-4, then +-2
//      (at most --metis_refine_moves moves),
//   3. re-measure the best --metis_recheck measured counts for
//      --metis_recheck_intervals intervals each (plus the physical-core count
//      when the best count uses SMT siblings),
//   4. commit to the best measured count and hold it.
// While holding, a throughput or abort-rate deviation that lasts
// --metis_change_intervals intervals restarts the search. While searching,
// a large deviation at a remembered count, or a move whose outcome contradicts
// the prediction, discards the remembered measurements.

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <map>
#include <random>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include <unistd.h>

#include "gflags/gflags.h"
#include "adaptive_state.hh"

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_bool(metis_enable, false, "Enable the Metis active-thread controller");
DEFINE_bool(metis_learn, false,
            "Training run: explore random thread counts and save the model");
DEFINE_string(metis_model_path, "",
              "Model file (loaded for evaluation, written after training)");
DEFINE_double(metis_lambda, 1.0, "Ridge regularization of the model");
DEFINE_uint64(metis_seed, 1, "Seed for random exploration while training");
DEFINE_uint64(metis_physical_cores, 0,
              "Physical cores used for the SMT feature (0 = read CPU topology)");
DEFINE_uint64(metis_settle_intervals, 1,
              "Control intervals discarded after changing the active count");
DEFINE_double(metis_min_gain, 0.02,
              "Minimum predicted log-throughput gain needed to leave the current count");
DEFINE_uint64(metis_model_moves, 5,
              "Model-predicted moves to unmeasured counts allowed after a reset; "
              "afterwards only measured counts are compared (0 = unlimited)");
DEFINE_uint64(metis_refine_moves, 4,
              "Measured local-refinement moves allowed after a reset");
DEFINE_uint64(metis_memory_ms, 10000,
              "Measured throughput of a count overrides the model for this long");
DEFINE_double(metis_surprise, 0.4,
              "|observed - predicted| log-throughput change after a move that "
              "marks the remembered measurements as stale");
DEFINE_uint64(metis_recheck, 3,
              "Before committing, re-measure the best K measured counts (0 disables)");
DEFINE_uint64(metis_recheck_intervals, 3,
              "Intervals averaged per re-measurement of a top candidate");
DEFINE_uint64(metis_hold_base_intervals, 3,
              "Intervals averaged for the reference throughput after committing");
DEFINE_double(metis_change_tps, 0.20,
              "|log(T/T_hold)| that counts as a workload change");
DEFINE_double(metis_change_abort, 0.10,
              "|R - R_hold| that counts as a workload change");
DEFINE_uint64(metis_change_intervals, 2,
              "Consecutive deviating intervals that restart the search");
#else
DECLARE_bool(metis_enable);
DECLARE_bool(metis_learn);
DECLARE_string(metis_model_path);
DECLARE_double(metis_lambda);
DECLARE_uint64(metis_seed);
DECLARE_uint64(metis_physical_cores);
DECLARE_uint64(metis_settle_intervals);
DECLARE_double(metis_min_gain);
DECLARE_uint64(metis_model_moves);
DECLARE_uint64(metis_refine_moves);
DECLARE_uint64(metis_memory_ms);
DECLARE_double(metis_surprise);
DECLARE_uint64(metis_recheck);
DECLARE_uint64(metis_recheck_intervals);
DECLARE_uint64(metis_hold_base_intervals);
DECLARE_double(metis_change_tps);
DECLARE_double(metis_change_abort);
DECLARE_uint64(metis_change_intervals);
#endif

DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_bool(tam_log_active_threads);

class Metis {
 public:
  static constexpr size_t kPhi = 5;  // log v, v, v^2, cross-socket share, SMT share
  static constexpr size_t kPsi = 4;  // 1, R, R^2, c/N
  static constexpr size_t kDim = kPhi * kPsi;

  void init(uint64_t total_threads) {
    total_ = total_threads;
    if (!(FLAGS_metis_lambda > 0.0) || FLAGS_metis_recheck_intervals == 0 ||
        FLAGS_metis_hold_base_intervals == 0) {
      std::fprintf(stderr, "Invalid Metis configuration\n");
      std::abort();
    }
    min_ = std::max<uint64_t>(1, FLAGS_tam_min_threads);
    max_ = FLAGS_tam_max_threads == 0 ? total_
                                      : std::min(total_, FLAGS_tam_max_threads);
    if (min_ > max_) min_ = max_;
    physical_ = FLAGS_metis_physical_cores != 0 ? FLAGS_metis_physical_cores
                                                : count_physical_cores();
    physical_ = std::clamp<uint64_t>(physical_, 1, total_);
    // Physical-first pinning fills socket 0's physical cores first, then the
    // other sockets' physical cores, then SMT siblings.
    socket_cores_ = std::clamp<uint64_t>(count_socket0_physical_cores(), 1, physical_);
    actions_.clear();
    for (uint64_t n = 8; n <= 96; n += 2) {
      const uint64_t a = std::clamp(n, min_, max_);
      if (actions_.empty() || actions_.back() != a) actions_.push_back(a);
    }
    A_.assign(kDim * kDim, 0.0);
    b_.assign(kDim, 0.0);
    for (size_t i = 0; i < kDim; ++i) A_[i * kDim + i] = FLAGS_metis_lambda;
    samples_ = 0;
    rng_.seed(FLAGS_metis_seed);
    now_ = start_ = std::chrono::steady_clock::now();
    reset_interval_ = true;
    set_active(max_);  // start with every worker active
    settle_left_ = 1;  // discard the warm-up interval
    clear_accumulator();
  }

  uint64_t active_threads() const { return active_.load(std::memory_order_acquire); }

  // Called once per control period with the cumulative commit/abort counts.
  void update(uint64_t committed, uint64_t aborts) {
    const auto now = std::chrono::steady_clock::now();
    if (reset_interval_) {
      last_time_ = now;
      last_committed_ = committed;
      last_aborts_ = aborts;
      reset_interval_ = false;
      return;
    }
    const double dt = std::chrono::duration<double>(now - last_time_).count();
    if (dt <= 0.0) return;
    const uint64_t dc = committed - last_committed_;
    const uint64_t da = aborts - last_aborts_;
    last_time_ = now;
    last_committed_ = committed;
    last_aborts_ = aborts;
    now_ = now;
    const double tps = static_cast<double>(dc) / dt;
    const double abort = dc + da == 0 ? 0.0
                                      : static_cast<double>(da) / static_cast<double>(dc + da);
    if (settle_left_ > 0) {
      --settle_left_;
      log_line(tps, abort, "settle", 0.0, 0.0);
      return;
    }
    acc_tps_ += tps;
    acc_abort_ += abort;
    ++acc_n_;
    const uint64_t need = in_recheck_ ? FLAGS_metis_recheck_intervals : 1;
    if (acc_n_ < need) return;
    const double t = std::max(1.0, acc_tps_ / acc_n_);
    const double r = acc_abort_ / acc_n_;
    clear_accumulator();
    step(t, r);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    std::fprintf(stderr, "[Metis] samples=%llu decisions=%llu switches=%llu\n",
                 static_cast<unsigned long long>(samples_),
                 static_cast<unsigned long long>(decisions_),
                 static_cast<unsigned long long>(switches_));
  }

  // Model file: header (format, version, dimension, lambda, workers, physical
  // cores, samples), then A (row-major) and b.
  bool save_model(const std::string& path) const {
    std::ofstream out(path);
    if (!out) return false;
    out.precision(17);
    out << "metis_model 1 " << kDim << ' ' << FLAGS_metis_lambda << ' ' << total_
        << ' ' << physical_ << ' ' << samples_ << '\n';
    for (double v : A_) out << v << ' ';
    out << '\n';
    for (double v : b_) out << v << ' ';
    out << '\n';
    return static_cast<bool>(out);
  }

  bool load_model(const std::string& path) {
    std::ifstream in(path);
    std::string magic;
    int version = 0;
    uint64_t dim = 0, total = 0, physical = 0, samples = 0;
    double lambda = 0.0;
    if (!(in >> magic >> version >> dim >> lambda >> total >> physical >> samples) ||
        magic != "metis_model" || version != 1 || dim != kDim || total != total_ ||
        physical != physical_) {
      return false;
    }
    std::vector<double> A(kDim * kDim), b(kDim);
    for (double& v : A) if (!(in >> v)) return false;
    for (double& v : b) if (!(in >> v)) return false;
    A_ = std::move(A);
    b_ = std::move(b);
    samples_ = samples;
    return true;
  }

 private:
  // Measured throughput per count and when it was measured.
  using Memory = std::map<uint64_t, std::pair<double, std::chrono::steady_clock::time_point>>;

  // One measurement t (TPS) and r (abort rate) at the current count.
  void step(double t, double r) {
    const uint64_t cur = active_threads();
    if (have_prev_ && prev_n_ != cur && FLAGS_metis_learn) {
      const double reward = std::log(t / prev_t_);
      add_sample(features(cur, prev_n_, psi(prev_r_, prev_n_)), reward);
      log_line(t, r, "learn", reward, 0.0);
    }
    have_prev_ = true;
    prev_n_ = cur;
    prev_t_ = t;
    prev_r_ = r;
    if (FLAGS_metis_learn) {
      const uint64_t next = random_action();
      ++decisions_;
      log_line(t, r, "explore", 0.0, 0.0);
      move_to(next);
      return;
    }
    // ---- evaluation: search, then commit and hold ----
    if (holding_) {
      if (hold_base_left_ > 0) {  // reference throughput, averaged
        hold_base_t_ += t / FLAGS_metis_hold_base_intervals;
        hold_base_r_ += r / FLAGS_metis_hold_base_intervals;
        if (--hold_base_left_ == 0) log_line(t, r, "hold_base", 0.0, 0.0);
        return;
      }
      const bool deviates =
          std::fabs(std::log(t / hold_base_t_)) > FLAGS_metis_change_tps ||
          std::fabs(r - hold_base_r_) > FLAGS_metis_change_abort;
      deviating_ = deviates ? deviating_ + 1 : 0;
      if (!deviates) {  // follow slow drift
        hold_base_t_ = 0.9 * hold_base_t_ + 0.1 * t;
        hold_base_r_ = 0.9 * hold_base_r_ + 0.1 * r;
      }
      if (deviating_ < FLAGS_metis_change_intervals) {
        log_line(t, r, deviates ? "deviate" : "hold", 0.0, 0.0);
        return;
      }
      // Workload change: forget measurements and search again from here.
      surprises_ = 0;
      holding_ = false;
      deviating_ = 0;
      reset_search();
      log_line(t, r, "change", 0.0, 0.0);
    }
    const auto keep = std::chrono::milliseconds(FLAGS_metis_memory_ms);
    for (auto it = measured_.begin(); it != measured_.end();)
      it = now_ - it->second.second > keep ? measured_.erase(it) : std::next(it);
    // A change during the search makes the remembered throughputs stale: if
    // the current count now measures far from its remembered value, forget
    // everything and restart the search from here.
    if (const auto it = measured_.find(cur);
        it != measured_.end() &&
        std::fabs(std::log(t / it->second.first)) > FLAGS_metis_change_tps) {
      reset_search();
      log_line(t, r, "change_in_search", 0.0, 0.0);
    } else if (have_move_ && move_to_n_ == cur && surprises_ < 2 &&
               std::fabs(std::log(t / move_from_t_)) > 0.6 &&
               std::fabs(std::log(t / move_from_t_) - move_pred_) > FLAGS_metis_surprise) {
      ++surprises_;
      // The move's outcome contradicts the model by far more than its usual
      // error: the workload changed while searching.
      reset_search();
      log_line(t, r, "surprise", std::log(t / move_from_t_), move_pred_);
    }
    have_move_ = false;
    if (in_recheck_ && measured_.count(cur) != 0) {
      // Second measurement of a top candidate: average with the first one.
      const double k = static_cast<double>(FLAGS_metis_recheck_intervals);
      measured_[cur] = {(measured_[cur].first + k * t) / (1.0 + k), now_};
    } else {
      measured_[cur] = {t, now_};
    }
    if (in_recheck_) {
      if (!recheck_queue_.empty()) {
        const uint64_t next = recheck_queue_.back();
        recheck_queue_.pop_back();
        log_line(t, r, "recheck", 0.0, 0.0);
        move_to(next);
        return;
      }
      in_recheck_ = false;
      commit(t, r, cur);
      return;
    }
    // 1. Model-predicted move (measured counts are compared by measurement).
    const auto state = psi(r, cur);
    double pred = 0.0;
    const bool model_allowed =
        FLAGS_metis_model_moves == 0 || model_moves_ < FLAGS_metis_model_moves;
    uint64_t next = best_action(cur, state, &pred, model_allowed);
    if (next != cur && measured_.find(next) == measured_.end()) ++model_moves_;
    // 2. Measured local refinement: once the model (and memory) would hold,
    // measure the untried neighbours at +-4 then +-2 (bounded).
    if (next == cur && !refine_done_ && refine_moves_ < FLAGS_metis_refine_moves) {
      bool found = false;
      for (uint64_t step : {4ULL, 2ULL}) {
        for (int sign : {1, -1}) {
          if (sign < 0 && cur <= step) continue;
          const uint64_t cand = sign > 0 ? cur + step : cur - step;
          if (cand < min_ || cand > max_ ||
              std::find(actions_.begin(), actions_.end(), cand) == actions_.end() ||
              measured_.count(cand) != 0)
            continue;
          next = cand;
          found = true;
          break;
        }
        if (found) break;
      }
      if (found) {
        ++refine_moves_;
        log_line(t, r, "refine", 0.0, 0.0);
      } else {
        refine_done_ = true;
      }
    }
    ++decisions_;
    if (next != cur) {
      have_move_ = true;
      move_from_t_ = t;
      move_to_n_ = next;
      move_pred_ = predict(next, cur, state);
      log_line(t, r, "move", 0.0, move_pred_);
      move_to(next);
      return;
    }
    // 3. Search finished. Single-interval measurements are noisy and the TPS
    // curve is flat near its peak, so re-measure the best K counts (queued in
    // descending order of measured TPS) before committing.
    if (!recheck_done_ && FLAGS_metis_recheck > 0) {
      recheck_done_ = true;
      std::vector<std::pair<double, uint64_t>> ranked;
      for (const auto& [n, v] : measured_) ranked.push_back({v.first, n});
      std::sort(ranked.rbegin(), ranked.rend());
      recheck_queue_.clear();
      for (size_t i = 0; i < ranked.size() && i < FLAGS_metis_recheck; ++i)
        recheck_queue_.push_back(ranked[i].second);
      // Anchor: the physical-core count is the usual optimum at the SMT
      // boundary; always compare against it when the leader uses SMT siblings.
      if (!ranked.empty() && ranked.front().second > physical_ &&
          std::find(recheck_queue_.begin(), recheck_queue_.end(), physical_) ==
              recheck_queue_.end())
        recheck_queue_.push_back(physical_);
      std::reverse(recheck_queue_.begin(), recheck_queue_.end());  // pop_back = best first
      in_recheck_ = true;
      const uint64_t first = recheck_queue_.back();
      recheck_queue_.pop_back();
      log_line(t, r, "recheck", 0.0, 0.0);
      move_to(first);
      return;
    }
    commit(t, r, cur);
  }

  // 4. Commit to the best measured count and hold it.
  void commit(double t, double r, uint64_t cur) {
    surprises_ = 0;
    uint64_t best = cur;
    for (const auto& [n, v] : measured_)
      if (v.first > measured_[best].first) best = n;
    holding_ = true;
    deviating_ = 0;
    hold_base_left_ = FLAGS_metis_hold_base_intervals;
    hold_base_t_ = hold_base_r_ = 0.0;
    log_line(t, r, "commit", 0.0, 0.0);
    move_to(best);
  }

  void reset_search() {
    measured_.clear();
    model_moves_ = refine_moves_ = 0;
    refine_done_ = false;
    recheck_done_ = false;
    in_recheck_ = false;
  }

  // ---- model --------------------------------------------------------------
  std::array<double, kPsi> psi(double r, uint64_t c) const {
    return {1.0, r, r * r, static_cast<double>(c) / static_cast<double>(total_)};
  }

  std::array<double, kPhi> phi(uint64_t n) const {
    const double v = static_cast<double>(n) / static_cast<double>(total_);
    const double smt = n > physical_ && total_ > physical_
                           ? static_cast<double>(n - physical_) /
                                 static_cast<double>(total_ - physical_)
                           : 0.0;
    const double cross = physical_ > socket_cores_
                             ? static_cast<double>(std::min(n, physical_) -
                                                   std::min(n, socket_cores_)) /
                                   static_cast<double>(physical_ - socket_cores_)
                             : 0.0;
    return {std::log(v), v, v * v, cross, smt};
  }

  std::array<double, kDim> features(uint64_t a, uint64_t base,
                                    const std::array<double, kPsi>& state) const {
    const auto pa = phi(a), pb = phi(base);
    std::array<double, kDim> x{};
    for (size_t i = 0; i < kPhi; ++i)
      for (size_t j = 0; j < kPsi; ++j) x[i * kPsi + j] = (pa[i] - pb[i]) * state[j];
    return x;
  }

  void add_sample(const std::array<double, kDim>& x, double reward) {
    for (size_t i = 0; i < kDim; ++i) {
      b_[i] += reward * x[i];
      for (size_t j = 0; j < kDim; ++j) A_[i * kDim + j] += x[i] * x[j];
    }
    ++samples_;
  }

  bool solve(std::vector<double>& theta) const {
    std::vector<double> inv;
    if (!invert(A_, inv)) return false;
    theta.assign(kDim, 0.0);
    for (size_t i = 0; i < kDim; ++i)
      for (size_t j = 0; j < kDim; ++j) theta[i] += inv[i * kDim + j] * b_[j];
    return true;
  }

  // Predicted log(T(a)/T(base)); 0 when a == base.
  double predict(uint64_t a, uint64_t base, const std::array<double, kPsi>& state) const {
    std::vector<double> theta;
    if (a == base || !solve(theta)) return 0.0;
    const auto x = features(a, base, state);
    double mean = 0.0;
    for (size_t i = 0; i < kDim; ++i) mean += theta[i] * x[i];
    return mean;
  }

  // Best action relative to `base` (staying scores 0; leaving needs
  // metis_min_gain). Counts measured at both ends are compared by their
  // measured throughput instead of the model.
  uint64_t best_action(uint64_t base, const std::array<double, kPsi>& state,
                       double* best_pred, bool model_allowed) const {
    std::vector<double> theta;
    if (!solve(theta)) return base;
    uint64_t best = base;
    double best_score = 0.0;
    double pred_at_best = 0.0;
    const auto here = measured_.find(base);
    for (uint64_t a : actions_) {
      if (a == base) continue;
      const auto x = features(a, base, state);
      double score = 0.0;
      for (size_t i = 0; i < kDim; ++i) score += theta[i] * x[i];
      const auto m = measured_.find(a);
      if (m != measured_.end() && here != measured_.end()) {
        score = std::log(m->second.first / here->second.first);
      } else if (!model_allowed) {
        continue;  // model-move budget spent: compare measured counts only
      }
      if (score > best_score + (best == base ? FLAGS_metis_min_gain : 0.0)) {
        best_score = score;
        best = a;
        pred_at_best = score;
      }
    }
    *best_pred = pred_at_best;
    return best;
  }

  static bool invert(const std::vector<double>& src, std::vector<double>& inv) {
    const size_t n = kDim;
    std::vector<double> a(src);
    inv.assign(n * n, 0.0);
    for (size_t i = 0; i < n; ++i) inv[i * n + i] = 1.0;
    for (size_t col = 0; col < n; ++col) {
      size_t piv = col;
      for (size_t row = col + 1; row < n; ++row)
        if (std::fabs(a[row * n + col]) > std::fabs(a[piv * n + col])) piv = row;
      if (std::fabs(a[piv * n + col]) < 1e-12) return false;
      if (piv != col)
        for (size_t j = 0; j < n; ++j) {
          std::swap(a[col * n + j], a[piv * n + j]);
          std::swap(inv[col * n + j], inv[piv * n + j]);
        }
      const double d = a[col * n + col];
      for (size_t j = 0; j < n; ++j) {
        a[col * n + j] /= d;
        inv[col * n + j] /= d;
      }
      for (size_t row = 0; row < n; ++row) {
        if (row == col) continue;
        const double f = a[row * n + col];
        if (f == 0.0) continue;
        for (size_t j = 0; j < n; ++j) {
          a[row * n + j] -= f * a[col * n + j];
          inv[row * n + j] -= f * inv[col * n + j];
        }
      }
    }
    return true;
  }

  // ---- helpers ------------------------------------------------------------
  uint64_t random_action() {
    std::uniform_int_distribution<size_t> pick(0, actions_.size() - 1);
    return actions_[pick(rng_)];
  }

  void move_to(uint64_t next) {
    next = std::clamp(next, min_, max_);
    if (next != active_threads()) {
      set_active(next);
      ++switches_;
      settle_left_ = FLAGS_metis_settle_intervals;
    }
  }

  void set_active(uint64_t n) {
    active_.store(n, std::memory_order_release);
    g_active_threads.store(n, std::memory_order_release);
  }

  void clear_accumulator() {
    acc_tps_ = acc_abort_ = 0.0;
    acc_n_ = 0;
  }

  static bool read_topology(long cpu, const char* name, int& value) {
    char path[160];
    std::snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%ld/topology/%s", cpu,
                  name);
    FILE* f = std::fopen(path, "r");
    if (f == nullptr) return false;
    const bool ok = std::fscanf(f, "%d", &value) == 1;
    std::fclose(f);
    return ok;
  }

  static uint64_t count_socket0_physical_cores() {
    std::set<int> cores;
    const long n = sysconf(_SC_NPROCESSORS_CONF);
    for (long cpu = 0; cpu < n; ++cpu) {
      int pkg = -1, core = -1;
      if (!read_topology(cpu, "physical_package_id", pkg)) pkg = -1;
      if (!read_topology(cpu, "core_id", core)) core = -1;
      if (pkg == 0 && core >= 0) cores.insert(core);
    }
    return cores.empty() ? 1 : cores.size();
  }

  static uint64_t count_physical_cores() {
    std::set<std::pair<int, int>> cores;
    const long n = sysconf(_SC_NPROCESSORS_CONF);
    for (long cpu = 0; cpu < n; ++cpu) {
      int pkg = -1, core = -1;
      if (!read_topology(cpu, "physical_package_id", pkg)) pkg = -1;
      if (!read_topology(cpu, "core_id", core)) core = -1;
      if (pkg >= 0 && core >= 0) cores.insert({pkg, core});
    }
    return cores.empty() ? static_cast<uint64_t>(std::max(1L, n)) : cores.size();
  }

  void log_line(double tps, double abort, const char* what, double reward, double pred) {
    if (!FLAGS_tam_log_active_threads) return;
    const double s = std::chrono::duration<double>(now_ - start_).count();
    std::fprintf(stderr,
                 "[Metis] t=%.3f active=%llu tps=%.0f abort=%.4f phase=%s reward=%.4f pred=%.4f\n",
                 s, static_cast<unsigned long long>(active_threads()), tps, abort, what,
                 reward, pred);
  }

  uint64_t total_{96}, min_{1}, max_{96}, physical_{48}, socket_cores_{24};
  std::vector<uint64_t> actions_;
  std::vector<double> A_, b_;
  uint64_t samples_{0}, decisions_{0}, switches_{0};
  std::mt19937_64 rng_;
  std::atomic<uint64_t> active_{96};

  // Interval accounting.
  std::chrono::steady_clock::time_point start_, now_, last_time_;
  bool reset_interval_{true};
  uint64_t last_committed_{0}, last_aborts_{0};
  uint64_t settle_left_{0};
  double acc_tps_{0.0}, acc_abort_{0.0};
  uint64_t acc_n_{0};

  // Training: previous measurement.
  bool have_prev_{false};
  uint64_t prev_n_{0};
  double prev_t_{0.0}, prev_r_{0.0};

  // Search.
  Memory measured_;
  uint64_t model_moves_{0}, refine_moves_{0};
  bool refine_done_{false};
  bool recheck_done_{false}, in_recheck_{false};
  std::vector<uint64_t> recheck_queue_;
  bool have_move_{false};
  uint64_t move_to_n_{0}, surprises_{0};
  double move_from_t_{1.0}, move_pred_{0.0};

  // Hold.
  bool holding_{false};
  uint64_t deviating_{0}, hold_base_left_{0};
  double hold_base_t_{0.0}, hold_base_r_{0.0};
};
