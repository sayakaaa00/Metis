#pragma once

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>

#include <unistd.h>

#include "atomic_wrapper.hh"
#include "backoff.hh"
#include "result.hh"
#include "tam.hh"
#include "tsc.hh"

DECLARE_uint64(clocks_per_us);
DECLARE_uint64(extime);

/**
 * Runtime glue between AdaTAM/Metis and the common benchmark runner.
 *
 * The worker-facing gate is intentionally a small template-inlinable call.
 * Controller updates and optional workload changes run on the main thread at
 * the configured microsecond period.
 */
class AdaptiveControl {
public:
  void init(std::size_t total_threads) {
    total_threads_ = total_threads;
    if (tam_.enabled()) { tam_.init(total_threads_, FLAGS_clocks_per_us); }
  }

  bool worker_enabled(std::size_t thid) const {
    return !tam_.enabled() || thid < tam_.active_threads();
  }

  void setup_logs(const std::filesystem::path& log_dir) {
    if (!FLAGS_tam_log_active_threads
#if BACK_OFF
        && !Backoff::log_enabled()
#endif
    ) {
      return;
    }

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

    if (FLAGS_tam_log_active_threads) {
      const auto path = log_dir /
                        (std::string("tam_active_threads_") + timestamp +
                         ".log");
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

#if BACK_OFF
    if (Backoff::log_enabled()) {
      const auto path =
          log_dir / (std::string("backoff_") + timestamp + ".log");
      FILE* fp = std::fopen(path.c_str(), "w");
      if (fp == nullptr) {
        std::perror("fopen backoff log");
      } else {
        Backoff::set_log_file(fp);
        std::fprintf(
            fp,
            "# elapsed_us backoff_us committed abort interval_committed "
            "interval_abort interval_tps\n");
        std::fflush(fp);
        std::cout << "Backoff logs will be written to: " << path << std::endl;
      }
    }
#endif
  }

  template <typename TickHook>
  void run_control_loop(std::uint64_t start_tsc, const TickHook& tick_hook) {
    std::uint64_t tick_us = tam_.enabled() ? FLAGS_tam_update_period_us
                                           : 1000000ULL;
    if (tam_.enabled() && tick_us == 0) {
      std::fprintf(stderr, "tam_update_period_us must be > 0\n");
      std::abort();
    }
#if BACK_OFF
    if (Backoff::log_enabled()) {
      if (Backoff::log_interval_us() == 0) {
        std::fprintf(stderr, "backoff_log_interval_us must be > 0\n");
        std::abort();
      }
      tick_us = std::min(tick_us, Backoff::log_interval_us());
    }
#endif

    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(FLAGS_extime);
#if BACK_OFF
    std::uint64_t last_backoff_log_tsc = start_tsc;
    std::uint64_t last_backoff_log_committed = 0;
    std::uint64_t last_backoff_log_abort = 0;
#endif

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
      bool collect_results = tam_.enabled();
#if BACK_OFF
      collect_results = collect_results || Backoff::log_enabled();
#endif
      if (collect_results) {
        for (std::size_t i = 0; i < total_threads_; ++i) {
          committed_sum +=
              loadAcquire(CCBenchResults[i].local_commit_counts_);
          abort_sum += loadAcquire(CCBenchResults[i].local_abort_counts_);
        }
      }

      if (tam_.enabled()) { tam_.update(committed_sum, abort_sum); }

      const std::uint64_t now = rdtscp();
#if BACK_OFF
      if (Backoff::log_enabled()) {
        const std::uint64_t log_interval_clocks =
            Backoff::log_interval_us() * FLAGS_clocks_per_us;
        if (chkClkSpan(last_backoff_log_tsc, now, log_interval_clocks)) {
          const std::uint64_t elapsed_us =
              (now - start_tsc) / FLAGS_clocks_per_us;
          const std::uint64_t interval_us =
              (now - last_backoff_log_tsc) / FLAGS_clocks_per_us;
          const std::uint64_t interval_committed =
              committed_sum - last_backoff_log_committed;
          const std::uint64_t interval_abort =
              abort_sum - last_backoff_log_abort;
          Backoff::log_sample(elapsed_us, interval_us, committed_sum,
                              abort_sum, interval_committed, interval_abort);
          last_backoff_log_tsc = now;
          last_backoff_log_committed = committed_sum;
          last_backoff_log_abort = abort_sum;
        }
      }
#endif

      tick_hook(start_tsc, now);
      if (std::chrono::steady_clock::now() >= deadline) break;
    }
  }

  void run_control_loop(std::uint64_t start_tsc) {
    run_control_loop(start_tsc,
                     [](std::uint64_t /*start*/, std::uint64_t /*now*/) {});
  }

  void finish() {
    if (tam_.enabled()) {
      tam_.print_stats();
      if (FLAGS_metis_paper_enable && FLAGS_linucb_model_autosave &&
          !FLAGS_linucb_model_path.empty()) {
        if (tam_.save_model(FLAGS_linucb_model_path)) {
          std::cerr << "[LinUCB] model saved to: "
                    << FLAGS_linucb_model_path << std::endl;
        } else {
          std::cerr << "[LinUCB] failed to save model to: "
                    << FLAGS_linucb_model_path << std::endl;
        }
      }
    }
#if BACK_OFF
    if (Backoff::log_file() != nullptr) {
      std::fclose(Backoff::log_file());
      Backoff::set_log_file(nullptr);
    }
#endif
  }

private:
  TamController tam_;
  std::size_t total_threads_{0};
};
