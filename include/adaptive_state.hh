#pragma once

#include <atomic>

// Shared runtime workload state used by adaptive controllers. The inline
// variable keeps every benchmark binary self-contained while allowing the
// Silo control loop to update the value observed by worker-local workloads.
// A negative value disables dynamic overrides for ordinary protocol binaries.
inline std::atomic<double> g_current_ycsb_skew{-1.0};
