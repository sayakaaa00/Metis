#pragma once

#include <cpuid.h>
#include <sched.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <map>
#include <mutex>
#include <vector>

#include "debug.hh"

#define CPUID(INFO, LEAF, SUBLEAF)                                             \
  __cpuid_count(LEAF, SUBLEAF, INFO[0], INFO[1], INFO[2], INFO[3])

#define GETCPU(CPU)                                                            \
  {                                                                            \
    uint32_t CPUInfo[4];                                                       \
    CPUID(CPUInfo, 1, 0);                                                      \
    /* CPUInfo[1] is EBX, bits 24-31 are APIC ID */                            \
    if ((CPUInfo[3] & (1 << 9)) == 0) {                                        \
      CPU = -1; /* no APIC on chip */                                          \
    } else {                                                                   \
      CPU = (unsigned) CPUInfo[1] >> 24;                                       \
      /*unsigned int cores = ((unsigned)CPUInfo[1] >> 16) & 0xff;*/            \
      /*if ((CPUInfo[3] & (1 << 28)) == 1) printf("HTT\n");*/                  \
      /*printf("total core number : %d\n", cores);*/                           \
    }                                                                          \
    if (CPU < 0) CPU = 0;                                                      \
  }

#ifdef Linux

// Socket-aware CPU order (default pinning): fill the logical CPUs of socket 0
// first, then the CPUs of the other sockets, so that a run with few workers
// does not cross NUMA sockets. CPUs are classified by
// /sys/devices/system/cpu/cpu*/topology/physical_package_id; if the topology
// cannot be read, CPUs 0..N-1 are used in order.
static int chooseSocketAwareCpu(const int myid) {
  static std::once_flag cpu_init_flag;
  static std::vector<int> ordered_cpus;
  static long nprocs = 1;
  static int socket0_count = 0;       // how many entries at the head of
                                      // ordered_cpus belong to socket 0

  std::call_once(cpu_init_flag, [&]() {
    nprocs = sysconf(_SC_NPROCESSORS_CONF);
    if (nprocs < 1) nprocs = 1;

    std::vector<int> socket0_cpus;
    std::vector<int> other_cpus;

    for (long cpu = 0; cpu < nprocs; ++cpu) {
      char path[256];
      std::snprintf(path, sizeof(path),
                    "/sys/devices/system/cpu/cpu%ld/topology/physical_package_id",
                    cpu);
      FILE *fp = std::fopen(path, "r");
      if (!fp) continue;
      int pkg = -1;
      if (std::fscanf(fp, "%d", &pkg) == 1) {
        if (pkg == 0)
          socket0_cpus.push_back(static_cast<int>(cpu));
        else
          other_cpus.push_back(static_cast<int>(cpu));
      }
      std::fclose(fp);
    }

    if (!socket0_cpus.empty() || !other_cpus.empty()) {
      socket0_count = static_cast<int>(socket0_cpus.size());

      ordered_cpus.reserve(socket0_cpus.size() + other_cpus.size());
      ordered_cpus.insert(ordered_cpus.end(), socket0_cpus.begin(), socket0_cpus.end());
      ordered_cpus.insert(ordered_cpus.end(), other_cpus.begin(), other_cpus.end());
    }

    // Fall back to 0..N-1 when the topology is unavailable.
    if (ordered_cpus.empty()) {
      for (long cpu = 0; cpu < nprocs; ++cpu) {
        ordered_cpus.push_back(static_cast<int>(cpu));
      }
      socket0_count = static_cast<int>(ordered_cpus.size());
    }
  });

  if (!ordered_cpus.empty()) {
    // Deterministic mapping by worker ID: the first socket0_count workers use
    // socket 0, the rest use the other sockets round-robin.

    const int total = static_cast<int>(ordered_cpus.size());
    if (socket0_count > 0) {
      if (myid < socket0_count) {
        int idx = myid % socket0_count;
        return ordered_cpus[idx];
      } else {
        int other_cnt = total - socket0_count;
        if (other_cnt > 0) {
          int idx = socket0_count + ((myid - socket0_count) % other_cnt);
          return ordered_cpus[idx];
        } else {
          // Only socket 0 exists: round-robin within it.
          int idx = myid % socket0_count;
          return ordered_cpus[idx];
        }
      }
    }

    // No CPU on socket 0: round-robin over all CPUs.
    int idx = myid % total;
    return ordered_cpus[idx];
  }

  // Unreachable fallback.
  return myid % static_cast<int>(nprocs);
}

// Fill one logical CPU per physical core on socket 0, then on the other
// sockets, before using SMT siblings. For this machine the first 48 workers
// therefore occupy 48 distinct physical cores across both sockets.
static int choosePhysicalFirstCpu(const int myid) {
  static std::once_flag cpu_init_flag;
  static std::vector<int> ordered_cpus;

  std::call_once(cpu_init_flag, [&]() {
    std::map<std::pair<int, int>, std::vector<int>> cores;
    long nprocs = sysconf(_SC_NPROCESSORS_CONF);
    if (nprocs < 1) nprocs = 1;
    auto topology_value = [](long cpu, const char* name, int& value) {
      char path[256];
      std::snprintf(path, sizeof(path),
                    "/sys/devices/system/cpu/cpu%ld/topology/%s", cpu,
                    name);
      FILE* fp = std::fopen(path, "r");
      if (!fp) return false;
      const bool ok = std::fscanf(fp, "%d", &value) == 1;
      std::fclose(fp);
      return ok;
    };
    for (long cpu = 0; cpu < nprocs; ++cpu) {
      int socket = -1;
      int core = -1;
      if (topology_value(cpu, "physical_package_id", socket) &&
          topology_value(cpu, "core_id", core)) {
        cores[{socket, core}].push_back(static_cast<int>(cpu));
      }
    }
    auto append = [&](bool socket0, bool siblings) {
      for (const auto& [key, cpus] : cores) {
        if ((key.first == 0) != socket0) continue;
        const std::size_t begin = siblings ? 1 : 0;
        const std::size_t end = siblings ? cpus.size() : std::min<std::size_t>(1, cpus.size());
        for (std::size_t i = begin; i < end; ++i) {
          ordered_cpus.push_back(cpus[i]);
        }
      }
    };
    append(true, false);
    append(false, false);
    append(true, true);
    append(false, true);
    if (ordered_cpus.empty()) {
      for (long cpu = 0; cpu < nprocs; ++cpu) {
        ordered_cpus.push_back(static_cast<int>(cpu));
      }
    }
  });
  return ordered_cpus[myid % ordered_cpus.size()];
}

// Override: CCBENCH_PIN_CPU_LIST="0,1,24,25,..." pins worker i to
// the i-th listed CPU. Workers beyond the list use the remaining CPUs in
// ascending order. Returns -1 when the variable is unset or empty.
static int explicitPinCpu(const int myid) {
  static std::once_flag init_flag;
  static std::vector<int> order;
  std::call_once(init_flag, [&]() {
    const char* spec = std::getenv("CCBENCH_PIN_CPU_LIST");
    if (spec == nullptr || *spec == '\0') return;
    long nprocs = sysconf(_SC_NPROCESSORS_CONF);
    if (nprocs < 1) nprocs = 1;
    std::vector<bool> used(static_cast<std::size_t>(nprocs), false);
    const char* p = spec;
    while (*p != '\0') {
      char* end = nullptr;
      long cpu = std::strtol(p, &end, 10);
      if (end == p || cpu < 0 || cpu >= nprocs || used[cpu]) {
        std::fprintf(stderr, "Invalid CCBENCH_PIN_CPU_LIST: %s\n", spec);
        std::exit(1);
      }
      used[cpu] = true;
      order.push_back(static_cast<int>(cpu));
      p = (*end == ',') ? end + 1 : end;
      if (*end != ',' && *end != '\0') {
        std::fprintf(stderr, "Invalid CCBENCH_PIN_CPU_LIST: %s\n", spec);
        std::exit(1);
      }
    }
    for (long cpu = 0; cpu < nprocs; ++cpu)
      if (!used[cpu]) order.push_back(static_cast<int>(cpu));
  });
  if (order.empty()) return -1;
  return order[static_cast<std::size_t>(myid) % order.size()];
}

static void setThreadAffinity(const int myid) {
  pid_t pid = syscall(SYS_gettid);
  cpu_set_t cpu_set;

  CPU_ZERO(&cpu_set);
  int cpu = explicitPinCpu(myid);
  if (cpu < 0) cpu = chooseSocketAwareCpu(myid);
  CPU_SET(cpu, &cpu_set);

  if (sched_setaffinity(pid, sizeof(cpu_set_t), &cpu_set) != 0) ERR;

  return;
}

[[maybe_unused]] static void setThreadAffinityPhysicalFirst(const int myid) {
  pid_t pid = syscall(SYS_gettid);
  cpu_set_t cpu_set;
  CPU_ZERO(&cpu_set);
  const int cpu = explicitPinCpu(myid);
  CPU_SET(cpu >= 0 ? cpu : choosePhysicalFirstCpu(myid), &cpu_set);
  if (sched_setaffinity(pid, sizeof(cpu_set_t), &cpu_set) != 0) ERR;
}
#endif // Linux

inline int cached_sched_getcpu() {
  thread_local int value = ::sched_getcpu();
  return value;
}
