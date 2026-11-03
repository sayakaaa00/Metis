#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

// Shared runtime workload state used by adaptive controllers. The inline
// variable keeps every benchmark binary self-contained while allowing the
// Silo control loop to update the value observed by worker-local workloads.
// A negative value disables dynamic overrides for ordinary protocol binaries.
inline std::atomic<double> g_current_ycsb_skew{-1.0};

// Populated by TPC-C workers before the start barrier in the Metis-test
// binary. The controller reads it only after the barrier has completed.
inline std::vector<std::atomic<std::uint16_t>> g_metis_test_home_warehouses;
inline std::vector<std::atomic<std::uint32_t>> g_metis_test_worker_warehouses;
inline std::atomic<std::uint64_t> g_metis_test_active_threads{0};
inline std::atomic<std::uint32_t> g_tpcc_runtime_active_warehouses{0};
inline std::atomic<std::int64_t> g_tpcc_benchmark_start_us{0};
