#pragma once

// Thread activity management (TAM): the benchmark spawns a fixed number of
// workers (--thread_num) and only workers with thid < N execute transactions.
// N is chosen by one of
//   - Metis      (--metis_enable, include/metis.hh),
//   - AdaTAM     (--ada_tam_enable, include/adatam.hh, hill-climbing baseline),
//   - a fixed N  (--tam_fixed_threads, used for the oracle sweeps),
// or all workers run when none is selected.

#include <x86intrin.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>

#include "gflags/gflags.h"
#include "adaptive_state.hh"
#include "adatam.hh"
#include "metis.hh"

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_uint64(tam_min_threads, 1, "Lower bound of the active worker count");
DEFINE_uint64(tam_max_threads, 96, "Upper bound of the active worker count");
DEFINE_uint64(tam_fixed_threads, 0,
              "Run only the first N workers without a controller (0: all)");
DEFINE_uint64(tam_update_period_us, 100000, "Control period in microseconds");
DEFINE_uint64(tam_idle_sleep_us, 50,
              "Sleep of a parked worker per check in microseconds (0 spins)");
DEFINE_bool(tam_log_active_threads, false,
            "Write controller decisions and active-thread samples to a log file");
DEFINE_uint64(tam_log_period_us, 100000,
              "Period of the active-thread samples in the log");
DEFINE_uint64(benchmark_interval_tps_log_us, 0,
              "Period of interval-throughput samples in the log (0 disables)");
#else
DECLARE_uint64(tam_min_threads);
DECLARE_uint64(tam_max_threads);
DECLARE_uint64(tam_fixed_threads);
DECLARE_uint64(tam_update_period_us);
DECLARE_uint64(tam_idle_sleep_us);
DECLARE_bool(tam_log_active_threads);
DECLARE_uint64(tam_log_period_us);
DECLARE_uint64(benchmark_interval_tps_log_us);
#endif

// Called by a worker that is not active: keep the protocol's epoch moving and
// wait for one idle period.
template <typename Tx>
inline void park_worker(Tx& tx) {
  if constexpr (requires(Tx& t) { t.announce_quiescent_epoch(); }) {
    tx.announce_quiescent_epoch();
  }
  if (FLAGS_tam_idle_sleep_us != 0) {
    std::this_thread::sleep_for(std::chrono::microseconds(FLAGS_tam_idle_sleep_us));
  } else {
    _mm_pause();
  }
}

class TamController {
 public:
  void init(uint64_t total_threads, uint64_t clocks_per_us) {
    if (static_cast<int>(FLAGS_metis_enable) + static_cast<int>(FLAGS_ada_tam_enable) +
            static_cast<int>(FLAGS_tam_fixed_threads != 0) > 1) {
      std::fprintf(stderr,
                   "Use at most one of --metis_enable, --ada_tam_enable, "
                   "--tam_fixed_threads\n");
      std::abort();
    }
    if (FLAGS_tam_fixed_threads > total_threads) {
      std::fprintf(stderr, "--tam_fixed_threads must be <= --thread_num\n");
      std::abort();
    }
    if (FLAGS_metis_enable) {
      metis_.init(total_threads);
      const std::string& path = FLAGS_metis_model_path;
      if (!path.empty() && std::ifstream(path).good()) {
        if (!metis_.load_model(path)) {
          std::fprintf(stderr, "Invalid Metis model: %s\n", path.c_str());
          std::abort();
        }
      } else if (!FLAGS_metis_learn) {
        std::fprintf(stderr, "Metis evaluation needs an existing --metis_model_path\n");
        std::abort();
      }
    }
    if (FLAGS_ada_tam_enable) adatam_.init(total_threads, clocks_per_us);
    if (FLAGS_tam_fixed_threads != 0)
      g_active_threads.store(FLAGS_tam_fixed_threads, std::memory_order_release);
  }

  // A controller updates the active count every control period.
  bool controlled() const { return FLAGS_metis_enable || FLAGS_ada_tam_enable; }

  // Some workers may be parked (controller or fixed N).
  bool gated() const { return controlled() || FLAGS_tam_fixed_threads != 0; }

  uint64_t active_threads() const {
    if (FLAGS_metis_enable) return metis_.active_threads();
    if (FLAGS_ada_tam_enable) return adatam_.active_threads();
    return FLAGS_tam_fixed_threads;
  }

  void update(uint64_t committed_txs, uint64_t abort_txs) {
    if (FLAGS_metis_enable) {
      metis_.update(committed_txs, abort_txs);
    } else if (FLAGS_ada_tam_enable) {
      adatam_.update(committed_txs, abort_txs);
    }
  }

  // After the run: statistics, and the trained Metis model.
  void finish() const {
    if (FLAGS_metis_enable) {
      metis_.print_stats();
      if (FLAGS_metis_learn && !FLAGS_metis_model_path.empty()) {
        if (metis_.save_model(FLAGS_metis_model_path)) {
          std::fprintf(stderr, "[Metis] model saved to: %s\n",
                       FLAGS_metis_model_path.c_str());
        } else {
          std::fprintf(stderr, "[Metis] failed to save model to: %s\n",
                       FLAGS_metis_model_path.c_str());
        }
      }
    } else if (FLAGS_ada_tam_enable) {
      adatam_.print_stats();
    }
  }

 private:
  Metis metis_;
  AdaTAM adatam_;
};
