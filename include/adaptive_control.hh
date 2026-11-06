#pragma once

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>

#include <unistd.h>

#include "atomic_wrapper.hh"
#include "result.hh"
#include "tam.hh"
#include "tsc.hh"
#include "util.hh"

DECLARE_uint64(clocks_per_us);
DECLARE_uint64(extime);

/**
 * Runtime glue between the active-thread controllers and the common
 * benchmark runner (common/runner.hh).
 *
 * - worker_enabled(): the per-transaction gate evaluated by every worker.
 * - run_control_loop(): runs on the main thread for the measurement period,
 *   feeds the cumulative commit/abort counts to the controller every
 *   --tam_update_period_us, writes the optional samples, and calls a
 *   workload-specific tick hook (in-run workload changes).
 * - With --tam_log_active_threads, stderr (controller decisions and samples)
 *   is redirected to logs/tam_active_threads_<timestamp>.log.
 */
class AdaptiveControl {
public:
  void init(std::size_t total_threads) {
    total_threads_ = total_threads;
    tam_.init(total_threads_, FLAGS_clocks_per_us);
  }

  bool worker_enabled(std::size_t thid) const {
    return !tam_.gated() || thid < tam_.active_threads();
  }

  void setup_logs(const std::filesystem::path& log_dir) {
    if (!FLAGS_tam_log_active_threads) return;

    std::error_code ec;
    std::filesystem::create_directories(log_dir, ec);
    if (ec) {
      std::fprintf(stderr, "failed to create benchmark log dir: %s\n",
                   ec.message().c_str());
      return;
    }

    char timestamp[32];
    const std::time_t now = std::time(nullptr);
    std::tm tm_buf {};
    if (localtime_r(&now, &tm_buf) != nullptr) {
      std::strftime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S", &tm_buf);
    } else {
      std::snprintf(timestamp, sizeof(timestamp), "unknown_time");
    }

    const auto path =
        log_dir / (std::string("tam_active_threads_") + timestamp + ".log");
    FILE* fp = std::fopen(path.c_str(), "w");
    if (fp == nullptr) {
      std::perror("fopen tam_active_threads log");
    } else if (dup2(fileno(fp), STDERR_FILENO) == -1) {
      std::perror("dup2 tam_active_threads log");
      std::fclose(fp);
    } else {
      std::cout << "TAM active_threads logs will be written to: " << path
                << std::endl;
      std::fclose(fp);
    }
  }

  template <typename TickHook>
  void run_control_loop(std::uint64_t start_tsc, const TickHook& tick_hook) {
    std::uint64_t tick_us = tam_.controlled() ? FLAGS_tam_update_period_us
                                              : 1000000ULL;
    if (tam_.controlled() && tick_us == 0) {
      std::fprintf(stderr, "tam_update_period_us must be > 0\n");
      std::abort();
    }
    if (FLAGS_benchmark_interval_tps_log_us > 0) {
      tick_us = std::min(tick_us, FLAGS_benchmark_interval_tps_log_us);
    }

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(FLAGS_extime);
    std::uint64_t last_tps_log_tsc = start_tsc;
    std::uint64_t last_tps_log_committed = 0;
    std::uint64_t last_thread_log_tsc = start_tsc;

    if (FLAGS_extime == 0) return;

    for (;;) {
      const auto now_wall = std::chrono::steady_clock::now();
      if (now_wall >= deadline) break;
      const auto remaining = deadline - now_wall;
      std::this_thread::sleep_for(
          std::min(std::chrono::microseconds(tick_us),
                   std::chrono::duration_cast<std::chrono::microseconds>(
                       remaining)));

      std::uint64_t committed_sum = 0;
      std::uint64_t abort_sum = 0;
      if (tam_.controlled() || FLAGS_benchmark_interval_tps_log_us > 0) {
        for (std::size_t i = 0; i < total_threads_; ++i) {
          committed_sum +=
              loadAcquire(CCBenchResults[i].local_commit_counts_);
          abort_sum += loadAcquire(CCBenchResults[i].local_abort_counts_);
        }
      }

      if (tam_.controlled()) { tam_.update(committed_sum, abort_sum); }

      const std::uint64_t now = rdtscp();
      if (FLAGS_benchmark_interval_tps_log_us > 0) {
        const std::uint64_t interval_clocks =
            FLAGS_benchmark_interval_tps_log_us * FLAGS_clocks_per_us;
        if (chkClkSpan(last_tps_log_tsc, now, interval_clocks)) {
          const double interval_s = static_cast<double>(now - last_tps_log_tsc) /
              (static_cast<double>(FLAGS_clocks_per_us) * 1e6);
          const double bench_s = static_cast<double>(now - start_tsc) /
              (static_cast<double>(FLAGS_clocks_per_us) * 1e6);
          const std::uint64_t delta = committed_sum - last_tps_log_committed;
          std::fprintf(stderr,
                       "[TPS sample] bench_s=%.3f interval_tps=%.1f "
                       "interval_committed=%llu interval_s=%.6f\n",
                       bench_s, static_cast<double>(delta) / interval_s,
                       static_cast<unsigned long long>(delta), interval_s);
          last_tps_log_tsc = now;
          last_tps_log_committed = committed_sum;
        }
      }
      if (tam_.gated() && FLAGS_tam_log_active_threads) {
        const std::uint64_t sample_clocks =
            std::max<std::uint64_t>(1, FLAGS_tam_log_period_us) *
            FLAGS_clocks_per_us;
        if (chkClkSpan(last_thread_log_tsc, now, sample_clocks)) {
          const double bench_s = static_cast<double>(now - start_tsc) /
              (static_cast<double>(FLAGS_clocks_per_us) * 1e6);
          std::fprintf(stderr,
                       "[TAM sample] bench_s=%.3f active_threads=%llu\n",
                       bench_s,
                       static_cast<unsigned long long>(tam_.active_threads()));
          last_thread_log_tsc = now;
        }
      }

      tick_hook(start_tsc, now);
      if (std::chrono::steady_clock::now() >= deadline) break;
    }
  }

  void finish() { tam_.finish(); }

private:
  TamController tam_;
  std::size_t total_threads_{0};
};
