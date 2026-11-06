#pragma once

#include <atomic>
#include <cstdint>
#include <limits>
#include <vector>

// Runtime state shared between the active-thread controllers (Metis, AdaTAM),
// the benchmark control loop, and the workload code executed by workers.
// Inline variables keep every benchmark binary self-contained.

// Workers with thid >= g_active_threads park between transactions (and, in
// TPC-C, between retries). The maximum value keeps every worker active when
// no controller runs.
inline std::atomic<std::uint64_t> g_active_threads{
    std::numeric_limits<std::uint64_t>::max()};

// YCSB: Zipf skew requested by the control loop for in-run workload changes.
// A negative value disables the override.
inline std::atomic<double> g_current_ycsb_skew{-1.0};

// TPC-C: number of active home warehouses. The control loop changes it during
// a run (--tpcc_active_warehouse_schedule); workers pick up the new home map
// before their next transaction.
inline std::atomic<std::uint32_t> g_tpcc_runtime_active_warehouses{0};
inline std::vector<std::atomic<std::uint16_t>> g_tpcc_home_warehouses;
inline std::vector<std::atomic<std::uint32_t>> g_tpcc_worker_warehouses;
