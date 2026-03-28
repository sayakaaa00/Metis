#include <ctype.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <algorithm>
#include <cctype>

#include "boost/filesystem.hpp"

#define GLOBAL_VALUE_DEFINE

#include "include/atomic_tool.hh"
#include "include/common.hh"
#include "include/result.hh"
#include "include/transaction.hh"
#include "include/util.hh"

#include "../include/atomic_wrapper.hh"
#include "../include/backoff.hh"
#include "../include/cpu.hh"
#include "../include/debug.hh"
#include "../include/fileio.hh"
#include "../include/masstree_wrapper.hh"
#include "../include/random.hh"
#include "../include/result.hh"
#include "../include/tsc.hh"
#include "../include/util.hh"
#include "../include/ycsb.hh"
#include "../include/zipf.hh"
#include "../include/tam.hh"

using namespace std;

// ★ 追加: マイクロ秒単位のスリープヘルパ
static inline void sleepUs(uint64_t us) {
  if (us == 0) return;
  struct timespec req, rem;
  req.tv_sec  = us / 1000000ULL;
  req.tv_nsec = (us % 1000000ULL) * 1000ULL;  // µs → ns
  while (nanosleep(&req, &rem) == -1 && errno == EINTR) {
    req = rem;  // シグナルで中断されたら残り時間で再試行
  }
}

static AdaTAM g_tam;

void worker(size_t thid, char &ready, const bool &start, const bool &quit) {
  Result &myres = std::ref(SiloResult[thid]);
  TxExecutor trans(thid, (Result *) &myres, quit);
  YcsbWorkload workload;
#if BACK_OFF
  Backoff backoff(FLAGS_clocks_per_us);
#endif

#if WAL
  /*
  const boost::filesystem::path log_dir_path("/tmp/ccbench");
  if (boost::filesystem::exists(log_dir_path)) {
  } else {
    boost::system::error_code error;
    const bool result = boost::filesystem::create_directory(log_dir_path,
  error); if (!result || error) { ERR;
    }
  }
  std::string logpath("/tmp/ccbench");
  */
  std::string logpath;
  genLogFile(logpath, thid);
  trans.logfile_.open(logpath, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  trans.logfile_.ftruncate(10 ^ 9);
#endif

#ifdef Linux
  setThreadAffinity(thid);
  //printf("Thread #%d: on CPU %d\n", res.thid_, sched_getcpu());
  //printf("sysconf(_SC_NPROCESSORS_CONF) %d\n",
  //sysconf(_SC_NPROCESSORS_CONF));
#endif

#if MASSTREE_USE
  MasstreeWrapper<Tuple>::thread_init(int(thid));
#endif

  storeRelease(ready, 1);
  while (!loadAcquire(start)) _mm_pause();
  if (thid == 0) trans.epoch_timer_start = rdtscp();

  while (!loadAcquire(quit)) {
    // ★ AdaTAM gate: tam_enable && thid >= active_threads のスレッドは休止
    if (g_tam.enabled()) {
      uint64_t active = g_tam.active_threads();
      if (thid >= active) {
        // 軽いウェイト。スピンしすぎないように _mm_pause または sleepMs を使う
        _mm_pause();
        continue;
      }
    }

    workload.run<TxExecutor,TransactionStatus>(trans);
  }

  return;
}

int main(int argc, char *argv[]) try {
  gflags::SetUsageMessage("YCSB Silo benchmark.");
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  chkArg();
  
#ifdef Linux
  // プロセス全体を「ソケット0上の CPU」に閉じ込める（ただし TotalThreadNum が
  // ソケット0の論理 CPU 数以下のときだけ）。これにより、プログラム単体でも
  // thread_num ≤ socket0 コア数なら必ず node0 だけを使うポリシーを実現する。
  setProcessAffinitySocket0IfFits(TotalThreadNum);
#endif

  YcsbWorkload::displayWorkloadParameter();
  YcsbWorkload::makeDB<Tuple,void>(nullptr);

  alignas(CACHE_LINE_SIZE) bool start = false;
  alignas(CACHE_LINE_SIZE) bool quit = false;
  initResult();
  std::vector<char> readys(TotalThreadNum);
  std::vector<std::thread> thv;
  // ★ AdaTAM 初期化（BACK_OFF=0 && --tam_enable=true のときに有効）
  if (FLAGS_tam_enable) {
    g_tam.init(TotalThreadNum, FLAGS_clocks_per_us);
  }
  for (size_t i = 0; i < TotalThreadNum; ++i)
    thv.emplace_back(worker, i, std::ref(readys[i]), std::ref(start),
                     std::ref(quit));
  waitForReady(readys);
  uint64_t start_tsc = rdtscp();
  storeRelease(start, true);

  // TAM: tam_update_period_us を唯一の周期パラメータとして使う
  const uint64_t tick_us = FLAGS_tam_update_period_us;
  const uint64_t total_us =
      static_cast<uint64_t>(FLAGS_extime) * 1000000ULL;

  for (uint64_t elapsed_us = 0; elapsed_us < total_us; elapsed_us += tick_us) {
    // ★ µs 単位でスリープ
    sleepUs(tick_us);

    if (FLAGS_tam_enable) {
      uint64_t committed_sum = 0;
      for (unsigned int i = 0; i < TotalThreadNum; ++i) {
        committed_sum += loadAcquire(SiloResult[i].local_commit_counts_);
      }
      g_tam.update(committed_sum);
    }
  }

  storeRelease(quit, true);
  for (auto &th : thv) th.join();
  uint64_t end_tsc = rdtscp();
  long double actual_extime = round(
    (end_tsc-start_tsc) /
    ((long double)FLAGS_clocks_per_us * powl(10.0, 6.0)));

  for (unsigned int i = 0; i < TotalThreadNum; ++i) {
    SiloResult[0].addLocalAllResult(SiloResult[i]);
  }
  ShowOptParameters();
  std::cout << "actual_extime:\t" << actual_extime << std::endl;
  SiloResult[0].displayAllResult(FLAGS_clocks_per_us, FLAGS_extime, TotalThreadNum);

  return 0;
} catch (bad_alloc) {
  ERR;
}
