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

#define CPUID(INFO, LEAF, SUBLEAF) \
  __cpuid_count(LEAF, SUBLEAF, INFO[0], INFO[1], INFO[2], INFO[3])

#define GETCPU(CPU)                                                 \
  {                                                                 \
    uint32_t CPUInfo[4];                                            \
    CPUID(CPUInfo, 1, 0);                                           \
    /* CPUInfo[1] is EBX, bits 24-31 are APIC ID */                 \
    if ((CPUInfo[3] & (1 << 9)) == 0) {                             \
      CPU = -1; /* no APIC on chip */                               \
    } else {                                                        \
      CPU = (unsigned)CPUInfo[1] >> 24;                             \
      /*unsigned int cores = ((unsigned)CPUInfo[1] >> 16) & 0xff;*/ \
      /*if ((CPUInfo[3] & (1 << 28)) == 1) printf("HTT\n");*/       \
      /*printf("total core number : %d\n", cores);*/                \
    }                                                               \
    if (CPU < 0) CPU = 0;                                           \
  }

#ifdef Linux

// NUMA ソケットを跨がないように、まずソケット 0 を優先して埋め、
// それを超えたスレッドは他ソケットの CPU を順に使う。
//   - /sys/devices/system/cpu/cpu*/topology/physical_package_id から
//     package_id を読み取り、socket0 とその他の CPU を分類する。
//   - ordered_cpus = [socket0 の CPU 群] + [その他の CPU 群]
//   - myid に対して ordered_cpus[myid % ordered_cpus.size()] を割り当てる。
//   - /sys が読めない場合などは 0..N-1 を ordered_cpus として扱う。

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

    // もし何も取れなければ、従来どおり 0..N-1 を候補とする
    if (ordered_cpus.empty()) {
      for (long cpu = 0; cpu < nprocs; ++cpu) {
        ordered_cpus.push_back(static_cast<int>(cpu));
      }
      socket0_count = static_cast<int>(ordered_cpus.size());
    }
  });

  if (!ordered_cpus.empty()) {
    // スレッド ID に基づく決定的なマッピングで CPU を割り当てる。
    // - ソケット0に属する CPU が存在する場合、myid が socket0_count 以下なら
    //   ソケット0の CPU を優先的に利用する。
    // - それ以降のスレッドは、残りの CPU 群（他ソケット）を round-robin で使う。

    const int total = static_cast<int>(ordered_cpus.size());
    if (socket0_count > 0) {
      if (myid < socket0_count) {
        // thread_num <= socket0_count の範囲では、ソケット0内で 1:1 に近い割り当て。
        int idx = myid % socket0_count;
        return ordered_cpus[idx];
      } else {
        int other_cnt = total - socket0_count;
        if (other_cnt > 0) {
          int idx = socket0_count + ((myid - socket0_count) % other_cnt);
          return ordered_cpus[idx];
        } else {
          // ソケット0しかない場合は、ソケット0内で round-robin。
          int idx = myid % socket0_count;
          return ordered_cpus[idx];
        }
      }
    }

    // ソケット0が存在しない場合は、全 CPU を対象に単純な round-robin を行う。
    int idx = myid % total;
    return ordered_cpus[idx];
  }

  // フォールバック（理論上ここには来ない想定）
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

// プロセス全体の CPU アフィニティを、"ソケット0だけ" に制限するヘルパ。
// TotalThreadNum がソケット0の論理 CPU 数以下のときだけ適用することで、
// thread_num ≤ socket0 コア数なら必ず node0 だけを使うポリシーを実現する。
[[maybe_unused]] static void setProcessAffinitySocket0IfFits(
    int total_threads) {
  static bool applied = false;
  if (applied) return;

  long nprocs = sysconf(_SC_NPROCESSORS_CONF);
  if (nprocs < 1) nprocs = 1;

  std::vector<int> socket0_cpus;

  for (long cpu = 0; cpu < nprocs; ++cpu) {
    char path[256];
    std::snprintf(path, sizeof(path),
                  "/sys/devices/system/cpu/cpu%ld/topology/physical_package_id",
                  cpu);
    FILE *fp = std::fopen(path, "r");
    if (!fp) continue;
    int pkg = -1;
    if (std::fscanf(fp, "%d", &pkg) == 1 && pkg == 0) {
      socket0_cpus.push_back(static_cast<int>(cpu));
    }
    std::fclose(fp);
  }

  if (socket0_cpus.empty()) return;

  // thread_num ≤ ソケット0の論理 CPU 数のときだけ、node0 に閉じ込める
  if (total_threads <= static_cast<int>(socket0_cpus.size())) {
    cpu_set_t cpu_set;
    CPU_ZERO(&cpu_set);
    for (int cpu : socket0_cpus) {
      CPU_SET(cpu, &cpu_set);
    }

    pid_t pid = getpid();
    if (sched_setaffinity(pid, sizeof(cpu_set_t), &cpu_set) != 0) ERR;

    applied = true;
  }
}

static void setThreadAffinity(const int myid) {
  pid_t pid = syscall(SYS_gettid);
  cpu_set_t cpu_set;

  CPU_ZERO(&cpu_set);
  int cpu = chooseSocketAwareCpu(myid);
  CPU_SET(cpu, &cpu_set);

  if (sched_setaffinity(pid, sizeof(cpu_set_t), &cpu_set) != 0) ERR;

  return;
}

[[maybe_unused]] static void setThreadAffinityPhysicalFirst(const int myid) {
  pid_t pid = syscall(SYS_gettid);
  cpu_set_t cpu_set;
  CPU_ZERO(&cpu_set);
  CPU_SET(choosePhysicalFirstCpu(myid), &cpu_set);
  if (sched_setaffinity(pid, sizeof(cpu_set_t), &cpu_set) != 0) ERR;
}
#endif  // Linux

inline int cached_sched_getcpu() {
    thread_local int value = ::sched_getcpu();
    return value;
}
