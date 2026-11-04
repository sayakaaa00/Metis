#pragma once

// Metis v2: workload-agnostic active-thread control with a shared-parameter
// LinUCB model. Two variants share the model and the action set:
//
//  A (probe-free): after moving from c to a, the reward is log(T(a)/T(c)).
//    The context is the state observed at c (abort rate R_c and c itself).
//    Counts measured within the last metis_v2_memory_ms are compared by their
//    measured throughput instead of the model, which stops ping-pong between
//    two counts whose pairwise predictions disagree. A throughput jump at the
//    current count beyond metis_v2_change_tps clears that memory.
//  B (probe):      run the reference count N (and optionally the physical-core
//    count P) for a few intervals; the reward is log(T(a)/T(N)). The context is
//    the probe signature (log(1-R_N), its square, optionally log(T(P)/T(N))).
//    A hold phase detects
//    workload changes and re-probes.
//
// Features are x = kron(phi(a) - phi(base), psi(state)), so x = 0 when the
// candidate equals the base and the predicted log-ratio is 0. phi uses only
// a/N, the cross-socket share of physical cores beyond socket 0, and the SMT
// share max(0, a-P)/(N-P) (both read from the CPU topology); psi uses only abort rates and
// throughput ratios. No benchmark-specific input (warehouse count, skew) and
// no absolute throughput scale enters the model.

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
DEFINE_bool(metis_v2_enable, false, "Enable the Metis v2 controller");
DEFINE_string(metis_v2_variant, "A", "Metis v2 variant: A (probe-free) or B (probe)");
DEFINE_bool(metis_v2_learn, false, "Update the Metis v2 model during this run");
DEFINE_bool(metis_v2_explore_random, true,
            "While learning, choose uniformly random actions (off-policy data)");
DEFINE_double(metis_v2_alpha, 0.0, "UCB exploration coefficient when not exploring randomly");
DEFINE_double(metis_v2_lambda, 1.0, "Ridge regularization of the shared model");
DEFINE_uint64(metis_v2_settle_intervals, 1,
              "Control intervals discarded after changing the active count");
DEFINE_uint64(metis_v2_measure_intervals, 1,
              "Control intervals averaged per measurement");
DEFINE_uint64(metis_v2_probe_intervals, 3, "Measured intervals per probe point (B)");
DEFINE_uint64(metis_v2_probe_points, 1,
              "Probe points for B: 1 = reference N only, 2 = N and physical cores");
DEFINE_double(metis_v2_min_gain, 0.02,
              "Minimum predicted log-throughput gain needed to leave the current count");
DEFINE_double(metis_v2_change_tps, 0.20,
              "B: |log(T/T_hold)| that counts as a workload change");
DEFINE_double(metis_v2_change_abort, 0.10,
              "B: |R - R_hold| that counts as a workload change");
DEFINE_uint64(metis_v2_change_intervals, 2,
              "B: consecutive deviating intervals that trigger a re-probe");
DEFINE_uint64(metis_v2_reprobe_period_ms, 0,
              "B: periodic re-probe while holding (0 disables)");
DEFINE_uint64(metis_v2_train_reprobe_decisions, 20,
              "B: random training decisions between probes");
DEFINE_uint64(metis_v2_physical_cores, 0,
              "Physical cores used for the SMT feature (0 = read CPU topology)");
DEFINE_uint64(metis_v2_seed, 1, "Seed for random exploration");
DEFINE_uint64(metis_v2_memory_ms, 10000,
              "A: measured throughput per count overrides the model for this long");
DEFINE_double(metis_v2_surprise, 0.4,
              "A: |observed - predicted| log-throughput change after a move that "
              "marks the remembered measurements as stale");
DEFINE_uint64(metis_v2_recheck, 3,
              "A: before committing, re-measure the best K measured counts once "
              "and average with their earlier value (0 disables)");
DEFINE_uint64(metis_v2_recheck_intervals, 3,
              "A: intervals averaged per re-measurement of a top candidate");
DEFINE_bool(metis_v2_recheck_physical, true,
            "A: when the best measured count exceeds the physical cores, also "
            "re-measure the physical-core count before committing");
DEFINE_uint64(metis_v2_refine_moves, 4,
              "A: measured local-refinement moves allowed after a reset");
DEFINE_uint64(metis_v2_model_moves, 5,
              "A: model-predicted moves to unmeasured counts allowed after a reset; "
              "afterwards only measured counts are compared (0 = unlimited)");
#else
DECLARE_bool(metis_v2_enable);
DECLARE_string(metis_v2_variant);
DECLARE_bool(metis_v2_learn);
DECLARE_bool(metis_v2_explore_random);
DECLARE_double(metis_v2_alpha);
DECLARE_double(metis_v2_lambda);
DECLARE_uint64(metis_v2_settle_intervals);
DECLARE_uint64(metis_v2_measure_intervals);
DECLARE_uint64(metis_v2_probe_intervals);
DECLARE_uint64(metis_v2_probe_points);
DECLARE_double(metis_v2_min_gain);
DECLARE_double(metis_v2_change_tps);
DECLARE_double(metis_v2_change_abort);
DECLARE_uint64(metis_v2_change_intervals);
DECLARE_uint64(metis_v2_reprobe_period_ms);
DECLARE_uint64(metis_v2_train_reprobe_decisions);
DECLARE_uint64(metis_v2_physical_cores);
DECLARE_uint64(metis_v2_seed);
DECLARE_uint64(metis_v2_memory_ms);
DECLARE_uint64(metis_v2_model_moves);
DECLARE_uint64(metis_v2_refine_moves);
DECLARE_uint64(metis_v2_recheck_intervals);
DECLARE_bool(metis_v2_recheck_physical);
DECLARE_uint64(metis_v2_recheck);
DECLARE_double(metis_v2_surprise);
#endif

DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_uint64(tam_log_period_us);
DECLARE_bool(tam_log_active_threads);

class MetisV2 {
 public:
  static constexpr size_t kPhi = 5;  // log v, v, v^2, cross-socket share, smt share

  void init(uint64_t total_threads) {
    total_ = total_threads;
    variant_b_ = FLAGS_metis_v2_variant == "B";
    if ((!variant_b_ && FLAGS_metis_v2_variant != "A") ||
        FLAGS_metis_v2_measure_intervals == 0 ||
        FLAGS_metis_v2_probe_intervals == 0 ||
        (FLAGS_metis_v2_probe_points != 1 && FLAGS_metis_v2_probe_points != 2) ||
        !(FLAGS_metis_v2_lambda > 0.0)) {
      std::fprintf(stderr, "Invalid Metis v2 configuration\n");
      std::abort();
    }
    min_ = std::max<uint64_t>(1, FLAGS_tam_min_threads);
    max_ = FLAGS_tam_max_threads == 0 ? total_
                                      : std::min(total_, FLAGS_tam_max_threads);
    if (min_ > max_) min_ = max_;
    physical_ = FLAGS_metis_v2_physical_cores != 0 ? FLAGS_metis_v2_physical_cores
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
    psi_dim_ = variant_b_ ? (FLAGS_metis_v2_probe_points == 2 ? 4 : 3) : 4;
    dim_ = kPhi * psi_dim_;
    A_.assign(dim_ * dim_, 0.0);
    b_.assign(dim_, 0.0);
    for (size_t i = 0; i < dim_; ++i) A_[i * dim_ + i] = FLAGS_metis_v2_lambda;
    samples_ = 0;
    rng_.seed(FLAGS_metis_v2_seed);
    now_ = start_ = last_log_ = std::chrono::steady_clock::now();
    reset_interval_ = true;
    // Both variants start at the reference count (as the workshop Metis did).
    set_active(max_);
    phase_ = variant_b_ ? Phase::ProbeRef : Phase::Measure;
    settle_left_ = 1;  // discard the warm-up interval
    clear_accumulator();
  }

  uint64_t active_threads() const { return active_.load(std::memory_order_acquire); }

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
    // The hold baseline is averaged like a probe: right after a switch the
    // abort rate overshoots while parked workers finish their last attempt.
    const uint64_t need = in_recheck_ ? FLAGS_metis_v2_recheck_intervals
                          : (phase_ == Phase::ProbeRef || phase_ == Phase::ProbePhys ||
                             phase_ == Phase::Confirm)
                              ? FLAGS_metis_v2_probe_intervals
                              : (phase_ == Phase::Hold ? 1 : FLAGS_metis_v2_measure_intervals);
    if (acc_n_ < need) return;
    const double t = std::max(1.0, acc_tps_ / acc_n_);
    const double r = acc_abort_ / acc_n_;
    clear_accumulator();
    if (variant_b_) step_b(t, r); else step_a(t, r);
  }

  void print_stats() const {
    if (!FLAGS_tam_log_active_threads) return;
    std::fprintf(stderr, "[MetisV2] variant=%s samples=%llu decisions=%llu switches=%llu probes=%llu\n",
                 variant_b_ ? "B" : "A", static_cast<unsigned long long>(samples_),
                 static_cast<unsigned long long>(decisions_),
                 static_cast<unsigned long long>(switches_),
                 static_cast<unsigned long long>(probes_));
  }

  // Model file: header, configuration, sample count, A (row-major), b.
  bool save_model(const std::string& path) const {
    std::ofstream out(path);
    if (!out) return false;
    out.precision(17);
    out << "metis_v2_model 1 " << (variant_b_ ? "B" : "A") << ' '
        << FLAGS_metis_v2_probe_points << ' ' << dim_ << ' ' << FLAGS_metis_v2_lambda
        << ' ' << total_ << ' ' << physical_ << ' ' << samples_ << '\n';
    for (double v : A_) out << v << ' ';
    out << '\n';
    for (double v : b_) out << v << ' ';
    out << '\n';
    return static_cast<bool>(out);
  }

  bool load_model(const std::string& path) {
    std::ifstream in(path);
    std::string magic, variant;
    int version = 0;
    uint64_t points = 0, dim = 0, total = 0, physical = 0, samples = 0;
    double lambda = 0.0;
    if (!(in >> magic >> version >> variant >> points >> dim >> lambda >> total >>
          physical >> samples) ||
        magic != "metis_v2_model" || version != 1 ||
        variant != (variant_b_ ? "B" : "A") ||
        (variant_b_ && points != FLAGS_metis_v2_probe_points) || dim != dim_ ||
        total != total_ || physical != physical_) {
      return false;
    }
    std::vector<double> A(dim_ * dim_), b(dim_);
    for (double& v : A) if (!(in >> v)) return false;
    for (double& v : b) if (!(in >> v)) return false;
    A_ = std::move(A);
    b_ = std::move(b);
    samples_ = samples;
    return true;
  }

 private:
  enum class Phase { Measure, ProbeRef, ProbePhys, Explore, Confirm, Hold };

  // ---- variant A ---------------------------------------------------------
  void step_a(double t, double r) {
    const uint64_t cur = active_threads();
    if (have_prev_ && prev_n_ != cur && FLAGS_metis_v2_learn) {
      const double reward = std::log(t / prev_t_);
      add_sample(features(cur, prev_n_, psi_a(prev_r_, prev_n_)), reward);
      log_line(t, r, "learn", reward, 0.0);
    }
    have_prev_ = true;
    prev_n_ = cur;
    prev_t_ = t;
    prev_r_ = r;
    if (FLAGS_metis_v2_learn && FLAGS_metis_v2_explore_random) {
      const uint64_t next = random_action();
      ++decisions_;
      log_line(t, r, "explore", 0.0, 0.0);
      move_to(next);
      return;
    }
    // ---- evaluation: search, then commit and hold ----
    if (a_holding_) {
      if (a_confirm_left_ > 0) {  // baseline averaged like a probe
        a_base_t_ += t / FLAGS_metis_v2_probe_intervals;
        a_base_r_ += r / FLAGS_metis_v2_probe_intervals;
        if (--a_confirm_left_ == 0) log_line(t, r, "hold_base", 0.0, 0.0);
        return;
      }
      const bool deviates =
          std::fabs(std::log(t / a_base_t_)) > FLAGS_metis_v2_change_tps ||
          std::fabs(r - a_base_r_) > FLAGS_metis_v2_change_abort;
      a_deviating_ = deviates ? a_deviating_ + 1 : 0;
      if (!deviates) {  // follow slow drift
        a_base_t_ = 0.9 * a_base_t_ + 0.1 * t;
        a_base_r_ = 0.9 * a_base_r_ + 0.1 * r;
      }
      if (a_deviating_ < FLAGS_metis_v2_change_intervals) {
        log_line(t, r, deviates ? "deviate" : "hold", 0.0, 0.0);
        return;
      }
      // Workload change: forget measurements and search again from here.
      surprises_ = 0;
      a_holding_ = false;
      a_deviating_ = 0;
      measured_.clear();
      model_moves_ = refine_moves_ = 0;
      refine_done_ = false;
      recheck_done_ = false;
      in_recheck_ = false;
      log_line(t, r, "change", 0.0, 0.0);
    }
    const auto keep = std::chrono::milliseconds(FLAGS_metis_v2_memory_ms);
    for (auto it = measured_.begin(); it != measured_.end();)
      it = now_ - it->second.second > keep ? measured_.erase(it) : std::next(it);
    // A change during the search makes the remembered throughputs stale: if
    // the current count now measures far from its remembered value, forget
    // everything and restart the search from here.
    if (const auto it = measured_.find(cur);
        it != measured_.end() &&
        std::fabs(std::log(t / it->second.first)) > FLAGS_metis_v2_change_tps) {
      measured_.clear();
      model_moves_ = refine_moves_ = 0;
      refine_done_ = false;
      recheck_done_ = false;
      in_recheck_ = false;
      log_line(t, r, "change_in_search", 0.0, 0.0);
    } else if (have_move_ && move_to_n_ == cur && surprises_ < 2 &&
               std::fabs(std::log(t / move_from_t_)) > 0.6 &&
               std::fabs(std::log(t / move_from_t_) - move_pred_) >
                   FLAGS_metis_v2_surprise) {
      ++surprises_;
      // The move's outcome contradicts the model by far more than its usual
      // error: the workload changed while searching.
      measured_.clear();
      model_moves_ = refine_moves_ = 0;
      refine_done_ = false;
      recheck_done_ = false;
      in_recheck_ = false;
      log_line(t, r, "surprise", std::log(t / move_from_t_), move_pred_);
    }
    have_move_ = false;
    if (in_recheck_ && measured_.count(cur) != 0) {
      // Second measurement of a top candidate: average with the first one.
      const double k = static_cast<double>(FLAGS_metis_v2_recheck_intervals);
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
    const auto psi = psi_a(r, cur);
    double pred = 0.0;
    const bool model_allowed =
        FLAGS_metis_v2_model_moves == 0 || model_moves_ < FLAGS_metis_v2_model_moves;
    uint64_t next = best_action(cur, psi, FLAGS_metis_v2_min_gain, &pred, &measured_,
                                model_allowed);
    if (next != cur && measured_.find(next) == measured_.end()) ++model_moves_;
    // Measured local refinement: once the model (and memory) would hold,
    // measure the untried neighbours at +-4 then +-2 (bounded).
    if (next == cur && !refine_done_ && refine_moves_ < FLAGS_metis_v2_refine_moves) {
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
      move_pred_ = predict(next, cur, psi);
      log_line(t, r, "move", 0.0, move_pred_);
      move_to(next);
      return;
    }
    // Search finished. Single-interval measurements are noisy and the TPS
    // curve is flat near its peak, so re-measure the best K counts once
    // (queue in descending order of measured TPS) before committing.
    if (!recheck_done_ && FLAGS_metis_v2_recheck > 0) {
      recheck_done_ = true;
      std::vector<std::pair<double, uint64_t>> ranked;
      for (const auto& [n, v] : measured_) ranked.push_back({v.first, n});
      std::sort(ranked.rbegin(), ranked.rend());
      recheck_queue_.clear();
      for (size_t i = 0; i < ranked.size() && i < FLAGS_metis_v2_recheck; ++i)
        recheck_queue_.push_back(ranked[i].second);
      // Anchor: the physical-core count is the usual SMT boundary optimum;
      // always compare against it when the leader uses SMT siblings.
      if (FLAGS_metis_v2_recheck_physical && !ranked.empty() &&
          ranked.front().second > physical_ &&
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

  // Commit to the best measured count and hold it.
  void commit(double t, double r, uint64_t cur) {
    surprises_ = 0;
    uint64_t best = cur;
    for (const auto& [n, v] : measured_)
      if (v.first > measured_[best].first) best = n;
    a_holding_ = true;
    a_deviating_ = 0;
    a_confirm_left_ = FLAGS_metis_v2_probe_intervals;
    a_base_t_ = a_base_r_ = 0.0;
    log_line(t, r, "commit", 0.0, 0.0);
    move_to(best);
  }

  std::vector<double> psi_a(double r, uint64_t c) const {
    return {1.0, r, r * r, static_cast<double>(c) / static_cast<double>(total_)};
  }

  // ---- variant B ---------------------------------------------------------
  void step_b(double t, double r) {
    switch (phase_) {
      case Phase::ProbeRef:
        ref_t_ = t;
        ref_r_ = r;
        if (FLAGS_metis_v2_probe_points == 2 && physical_ < max_) {
          phase_ = Phase::ProbePhys;
          log_line(t, r, "probe_ref", 0.0, 0.0);
          move_to(std::clamp(physical_, min_, max_));
          return;
        }
        phys_ratio_ = 0.0;
        log_line(t, r, "probe_ref", 0.0, 0.0);
        after_probe();
        return;
      case Phase::ProbePhys:
        phys_ratio_ = std::log(t / ref_t_);
        if (FLAGS_metis_v2_learn)
          add_sample(features(active_threads(), max_, psi_b()), phys_ratio_);
        log_line(t, r, "probe_phys", phys_ratio_, 0.0);
        after_probe();
        return;
      case Phase::Explore: {
        const double reward = std::log(t / ref_t_);
        add_sample(features(active_threads(), max_, psi_b()), reward);
        log_line(t, r, "learn", reward, 0.0);
        if (++explore_count_ >= FLAGS_metis_v2_train_reprobe_decisions) {
          start_probe();
        } else {
          move_to(random_action());
        }
        return;
      }
      case Phase::Confirm:
        hold_t_ = t;
        hold_r_ = r;
        deviating_ = 0;
        hold_since_ = now_;
        phase_ = Phase::Hold;
        log_line(t, r, "hold_base", 0.0, 0.0);
        return;
      case Phase::Hold: {
        const bool deviates = std::fabs(std::log(t / hold_t_)) > FLAGS_metis_v2_change_tps ||
                              std::fabs(r - hold_r_) > FLAGS_metis_v2_change_abort;
        deviating_ = deviates ? deviating_ + 1 : 0;
        if (!deviates) {  // follow slow drift so only abrupt changes re-probe
          hold_t_ = 0.9 * hold_t_ + 0.1 * t;
          hold_r_ = 0.9 * hold_r_ + 0.1 * r;
        }
        const bool periodic =
            FLAGS_metis_v2_reprobe_period_ms != 0 &&
            now_ - hold_since_ >= std::chrono::milliseconds(FLAGS_metis_v2_reprobe_period_ms);
        if (deviating_ >= FLAGS_metis_v2_change_intervals || periodic) {
          log_line(t, r, periodic ? "reprobe_periodic" : "reprobe_change", 0.0, 0.0);
          start_probe();
          return;
        }
        log_line(t, r, "hold", 0.0, 0.0);
        return;
      }
      case Phase::Measure:
        return;
    }
  }

  void after_probe() {
    ++probes_;
    if (FLAGS_metis_v2_learn && FLAGS_metis_v2_explore_random) {
      phase_ = Phase::Explore;
      explore_count_ = 0;
      move_to(random_action());
      return;
    }
    double pred = 0.0;
    const uint64_t next = best_action(max_, psi_b(), 0.0, &pred);
    ++decisions_;
    log_line(ref_t_, ref_r_, "choose", 0.0, pred);
    phase_ = Phase::Confirm;
    move_to(next);
    if (settle_left_ == 0) settle_left_ = FLAGS_metis_v2_settle_intervals;
  }

  void start_probe() {
    phase_ = Phase::ProbeRef;
    move_to(max_);
    if (settle_left_ == 0) settle_left_ = FLAGS_metis_v2_settle_intervals;
  }

  // log(1-R): log of the committed fraction of attempts at the reference count.
  std::vector<double> psi_b() const {
    const double l = std::log(std::max(1e-4, 1.0 - ref_r_));
    if (FLAGS_metis_v2_probe_points == 2) return {1.0, l, l * l, phys_ratio_};
    return {1.0, l, l * l};
  }

  // ---- shared model -------------------------------------------------------
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

  std::vector<double> features(uint64_t a, uint64_t base,
                               const std::vector<double>& psi) const {
    const auto pa = phi(a), pb = phi(base);
    std::vector<double> x(dim_);
    for (size_t i = 0; i < kPhi; ++i)
      for (size_t j = 0; j < psi_dim_; ++j) x[i * psi_dim_ + j] = (pa[i] - pb[i]) * psi[j];
    return x;
  }

  void add_sample(const std::vector<double>& x, double reward) {
    for (size_t i = 0; i < dim_; ++i) {
      b_[i] += reward * x[i];
      for (size_t j = 0; j < dim_; ++j) A_[i * dim_ + j] += x[i] * x[j];
    }
    ++samples_;
  }

  // Score every action relative to `base`; staying at `base` scores 0.
  using Memory = std::map<uint64_t, std::pair<double, std::chrono::steady_clock::time_point>>;

  double predict(uint64_t a, uint64_t base, const std::vector<double>& psi) const {
    std::vector<double> inv;
    if (a == base || !invert(A_, inv)) return 0.0;
    const auto x = features(a, base, psi);
    double mean = 0.0;
    for (size_t i = 0; i < dim_; ++i) {
      double th = 0.0;
      for (size_t j = 0; j < dim_; ++j) th += inv[i * dim_ + j] * b_[j];
      mean += th * x[i];
    }
    return mean;
  }

  uint64_t best_action(uint64_t base, const std::vector<double>& psi, double min_gain,
                       double* best_pred, const Memory* memory = nullptr,
                       bool model_allowed = true) const {
    std::vector<double> inv;
    if (!invert(A_, inv)) return base;
    std::vector<double> theta(dim_, 0.0);
    for (size_t i = 0; i < dim_; ++i)
      for (size_t j = 0; j < dim_; ++j) theta[i] += inv[i * dim_ + j] * b_[j];
    uint64_t best = base;
    double best_score = 0.0;
    double pred_at_best = 0.0;
    for (uint64_t a : actions_) {
      if (a == base) continue;
      const auto x = features(a, base, psi);
      double mean = 0.0, quad = 0.0;
      for (size_t i = 0; i < dim_; ++i) {
        mean += theta[i] * x[i];
        double row = 0.0;
        for (size_t j = 0; j < dim_; ++j) row += inv[i * dim_ + j] * x[j];
        quad += x[i] * row;
      }
      double score = mean + FLAGS_metis_v2_alpha * std::sqrt(std::max(0.0, quad));
      if (memory != nullptr) {
        const auto m = memory->find(a);
        const auto here = memory->find(base);
        if (m != memory->end() && here != memory->end()) {
          mean = std::log(m->second.first / here->second.first);
          score = mean;
        } else if (!model_allowed) {
          continue;  // exploration budget spent: compare measured counts only
        }
      }
      if (score > best_score + (best == base ? min_gain : 0.0)) {
        best_score = score;
        best = a;
        pred_at_best = mean;
      }
    }
    *best_pred = pred_at_best;
    return best;
  }

  bool invert(const std::vector<double>& src, std::vector<double>& inv) const {
    const size_t n = dim_;
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
      settle_left_ = FLAGS_metis_v2_settle_intervals;
    }
  }

  void set_active(uint64_t n) {
    active_.store(n, std::memory_order_release);
    // The TPC-C retry loop parks workers above this count between attempts.
    g_metis_test_active_threads.store(n, std::memory_order_release);
  }

  void clear_accumulator() {
    acc_tps_ = acc_abort_ = 0.0;
    acc_n_ = 0;
  }

  static uint64_t count_socket0_physical_cores() {
    std::set<int> cores;
    const long n = sysconf(_SC_NPROCESSORS_CONF);
    for (long cpu = 0; cpu < n; ++cpu) {
      int pkg = -1, core = -1;
      char path[160];
      std::snprintf(path, sizeof(path),
                    "/sys/devices/system/cpu/cpu%ld/topology/physical_package_id", cpu);
      if (FILE* f = std::fopen(path, "r")) {
        if (std::fscanf(f, "%d", &pkg) != 1) pkg = -1;
        std::fclose(f);
      }
      std::snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%ld/topology/core_id", cpu);
      if (FILE* f = std::fopen(path, "r")) {
        if (std::fscanf(f, "%d", &core) != 1) core = -1;
        std::fclose(f);
      }
      if (pkg == 0 && core >= 0) cores.insert(core);
    }
    return cores.empty() ? 1 : cores.size();
  }

  static uint64_t count_physical_cores() {
    std::set<std::pair<int, int>> cores;
    const long n = sysconf(_SC_NPROCESSORS_CONF);
    for (long cpu = 0; cpu < n; ++cpu) {
      int pkg = -1, core = -1;
      char path[160];
      std::snprintf(path, sizeof(path),
                    "/sys/devices/system/cpu/cpu%ld/topology/physical_package_id", cpu);
      if (FILE* f = std::fopen(path, "r")) {
        if (std::fscanf(f, "%d", &pkg) != 1) pkg = -1;
        std::fclose(f);
      }
      std::snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%ld/topology/core_id", cpu);
      if (FILE* f = std::fopen(path, "r")) {
        if (std::fscanf(f, "%d", &core) != 1) core = -1;
        std::fclose(f);
      }
      if (pkg >= 0 && core >= 0) cores.insert({pkg, core});
    }
    return cores.empty() ? static_cast<uint64_t>(std::max(1L, n)) : cores.size();
  }

  void log_line(double tps, double abort, const char* what, double reward, double pred) {
    if (!FLAGS_tam_log_active_threads) return;
    const double s = std::chrono::duration<double>(now_ - start_).count();
    std::fprintf(stderr,
                 "[MetisV2] t=%.3f active=%llu tps=%.0f abort=%.4f phase=%s reward=%.4f pred=%.4f\n",
                 s, static_cast<unsigned long long>(active_threads()), tps, abort, what,
                 reward, pred);
  }

  uint64_t total_{96}, min_{1}, max_{96}, physical_{48}, socket_cores_{24};
  bool variant_b_{false};
  std::vector<uint64_t> actions_;
  size_t psi_dim_{4}, dim_{16};
  std::vector<double> A_, b_;
  uint64_t samples_{0}, decisions_{0}, switches_{0}, probes_{0};
  std::mt19937_64 rng_;
  std::atomic<uint64_t> active_{96};

  std::chrono::steady_clock::time_point start_, now_, last_time_, last_log_, hold_since_;
  bool reset_interval_{true};
  uint64_t last_committed_{0}, last_aborts_{0};
  uint64_t settle_left_{0};
  double acc_tps_{0.0}, acc_abort_{0.0};
  uint64_t acc_n_{0};
  Phase phase_{Phase::Measure};

  // A
  Memory measured_;
  uint64_t model_moves_{0};
  bool refine_done_{false};
  uint64_t refine_moves_{0}, a_deviating_{0}, a_confirm_left_{0};
  bool a_holding_{false};
  bool have_move_{false};
  bool recheck_done_{false}, in_recheck_{false};
  std::vector<uint64_t> recheck_queue_;
  uint64_t surprises_{0};
  uint64_t move_to_n_{0};
  double move_from_t_{1.0}, move_pred_{0.0};
  double a_base_t_{0.0}, a_base_r_{0.0};
  bool have_prev_{false};
  uint64_t prev_n_{0};
  double prev_t_{0.0}, prev_r_{0.0};
  // B
  double ref_t_{1.0}, ref_r_{0.0}, phys_ratio_{0.0};
  double hold_t_{1.0}, hold_r_{0.0};
  uint64_t deviating_{0}, explore_count_{0};
};
