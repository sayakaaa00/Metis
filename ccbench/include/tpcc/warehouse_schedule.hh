#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "../../../metis/shared_state.hh"
#include "../atomic_wrapper.hh"
#include "../result.hh"

namespace tpcc_runtime {

using Schedule = std::vector<std::pair<std::uint64_t, std::uint32_t>>;

inline Schedule parse_schedule(const std::string& specification,
                               std::uint32_t initial_warehouses,
                               std::uint32_t database_warehouses,
                               std::uint64_t duration_s) {
  Schedule schedule;
  if (specification.empty()) return schedule;
  std::istringstream input(specification);
  std::string item;
  while (std::getline(input, item, ',')) {
    unsigned long long seconds = 0;
    unsigned int warehouses = 0;
    char trailing = '\0';
    if (std::sscanf(item.c_str(), "%llu:%u%c", &seconds, &warehouses,
                    &trailing) != 2 || warehouses == 0 ||
        warehouses > database_warehouses ||
        warehouses > std::numeric_limits<std::uint16_t>::max() ||
        seconds >= duration_s ||
        (!schedule.empty() && seconds <= schedule.back().first)) {
      throw std::invalid_argument("Invalid TPC-C warehouse schedule: " + item);
    }
    schedule.emplace_back(seconds, warehouses);
  }
  if (schedule.empty() || schedule.front().first != 0 ||
      schedule.front().second != initial_warehouses) {
    throw std::invalid_argument(
        "TPC-C warehouse schedule must start at 0 with the initial count");
  }
  return schedule;
}

template <typename Workload>
class ScheduledControlLoop {
 public:
  ScheduledControlLoop(Schedule schedule, std::size_t workers,
                       std::uint64_t duration_s)
      : schedule_(std::move(schedule)), workers_(workers),
        duration_s_(duration_s) {}

  void operator()(std::uint64_t /*start_tsc*/) const {
    if (schedule_.empty()) {
      for (std::uint64_t second = 0; second < duration_s_; ++second)
        std::this_thread::sleep_for(std::chrono::seconds(1));
      return;
    }
    using Clock = std::chrono::steady_clock;
    const auto start = Clock::now();
    const auto deadline = start + std::chrono::seconds(duration_s_);
    auto previous = start;
    std::uint64_t previous_commits = 0;
    std::size_t next = 1;
    std::size_t check_phase = 0;
    std::fprintf(stderr,
                 "[TPC-C workload] bench_s=0.000 active_warehouses=%u\n",
                 schedule_.front().second);
    for (;;) {
      const auto now = Clock::now();
      if (now >= deadline) break;
      std::this_thread::sleep_until(
          std::min(now + std::chrono::milliseconds(200), deadline));
      const auto current = Clock::now();
      const double elapsed = std::chrono::duration<double>(current - start).count();
      if (next < schedule_.size() && elapsed >= schedule_[next].first) {
        Workload::set_runtime_active_warehouses(schedule_[next].second);
        std::fprintf(stderr,
                     "[TPC-C workload] bench_s=%.3f active_warehouses=%u\n",
                     elapsed, schedule_[next].second);
        ++next;
      }
      if (check_phase < next &&
          elapsed >= schedule_[check_phase].first + 1.0) {
        const auto warehouses =
            g_tpcc_runtime_active_warehouses.load(std::memory_order_acquire);
        std::size_t applied = 0;
        for (std::size_t i = 0; i < workers_; ++i) {
          applied += g_tpcc_worker_warehouses[i].load(
                         std::memory_order_acquire) == warehouses;
        }
        std::fprintf(stderr,
                     "[TPC-C workload] bench_s=%.3f active_warehouses=%u "
                     "applied_workers=%zu/%zu\n",
                     elapsed, warehouses, applied, workers_);
        ++check_phase;
      }
      std::uint64_t commits = 0;
      for (std::size_t i = 0; i < workers_; ++i)
        commits += loadAcquire(CCBenchResults[i].local_commit_counts_);
      const double seconds =
          std::chrono::duration<double>(current - previous).count();
      std::fprintf(stderr,
                   "[TPC-C interval] bench_s=%.3f active_warehouses=%u "
                   "tput=%.1f\n",
                   elapsed,
                   g_tpcc_runtime_active_warehouses.load(
                       std::memory_order_acquire),
                   seconds > 0.0 ? (commits - previous_commits) / seconds : 0.0);
      previous = current;
      previous_commits = commits;
    }
  }

 private:
  Schedule schedule_;
  std::size_t workers_;
  std::uint64_t duration_s_;
};

}  // namespace tpcc_runtime
