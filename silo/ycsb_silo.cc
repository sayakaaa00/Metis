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

#include "gflags/gflags.h"

using namespace std;

// run 中に YCSB の Zipf skew を段階的に変化させるためのグローバル状態。
// 実体定義（ここ）と、extern 宣言（include/ycsb.hh）で共有する。
std::atomic<double> g_current_ycsb_skew{0.0};

#ifdef GLOBAL_VALUE_DEFINE
// CPU ピニング（setThreadAffinity / setProcessAffinitySocket0IfFits）を
// 有効にするかどうかを切り替えるフラグ。
// デフォルト false だが、scan スクリプトなどで問題を切り分けたい場合は
// --pin_threads=true を指定してピニングを無効化できる。
DEFINE_bool(pin_threads, false, "Enable NUMA-aware CPU pinning for workers/process");

// オプション: run 中に Zipf skew を 1〜2 回だけ切り替えるためのフラグ群。
// 例: 3 フェーズ (0〜10s:0.9, 10〜20s:0.7, 20〜30s:0.95)
//   --extime=30
//   --ycsb_zipf_skew=0.9
//   --ycsb_skew_change_enable=true
//   --ycsb_zipf_skew2=0.7
//   --ycsb_skew_change_time_sec=10
//   --ycsb_skew_change_enable2=true
//   --ycsb_zipf_skew3=0.95
//   --ycsb_skew_change_time_sec2=20
DEFINE_bool(ycsb_skew_change_enable, false,
            "Enable single in-run change of YCSB Zipf skew");
DEFINE_double(ycsb_zipf_skew2, 0.0,
              "Second-phase Zipf skew used after ycsb_skew_change_time_sec");
DEFINE_uint64(ycsb_skew_change_time_sec, 0,
              "Time (sec) from start at which to switch skew to ycsb_zipf_skew2");

// 2 回目の切り替え（最大で 3 フェーズまで）
DEFINE_bool(ycsb_skew_change_enable2, false,
            "Enable second in-run change of YCSB Zipf skew");
DEFINE_double(ycsb_zipf_skew3, 0.0,
              "Third-phase Zipf skew used after ycsb_skew_change_time_sec2");
DEFINE_uint64(ycsb_skew_change_time_sec2, 0,
              "Time (sec) from start at which to switch skew to ycsb_zipf_skew3");
#endif

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

static TamController g_tam;

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
  if (FLAGS_pin_threads) {
    setThreadAffinity(thid);
  }
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
  // 現在の skew の初期値を FLAGS_ycsb_zipf_skew から設定
  g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew, std::memory_order_release);
  
#ifdef Linux
  // TAM の active_threads ログを自動的に別ファイルへリダイレクトする
  // （tam_log_active_threads=true のときのみ有効）。
  if (FLAGS_tam_log_active_threads) {
    namespace fs = boost::filesystem;

    // 常にリポジトリ内の experiments/paper_replication/logs 配下に出力する。
    fs::path log_dir("experiments/paper_replication/logs");
    boost::system::error_code ec;
    fs::create_directories(log_dir, ec);
    if (ec) {
      std::fprintf(stderr, "failed to create TAM log dir: %s\n", ec.message().c_str());
    }

    char timestr[32];
    std::time_t now = std::time(nullptr);
    std::tm tm_buf;
    std::tm *tm = nullptr;
#ifdef _WIN32
    tm = std::localtime(&now);
#else
    if (localtime_r(&now, &tm_buf) != nullptr) tm = &tm_buf;
#endif
    if (tm) {
      std::strftime(timestr, sizeof(timestr), "%Y%m%d_%H%M%S", tm);
    } else {
      std::snprintf(timestr, sizeof(timestr), "unknown_time");
    }

  char path[512];
  std::snprintf(path, sizeof(path), "%s/tam_active_threads_%s.log",
          log_dir.string().c_str(), timestr);
    FILE *fp = std::fopen(path, "w");
    if (!fp) {
      std::perror("fopen tam_active_threads log");
    } else {
      int fd = fileno(fp);
      if (dup2(fd, STDERR_FILENO) == -1) {
        std::perror("dup2 tam_active_threads log");
        std::fclose(fp);
      } else {
        // 以降の fprintf(stderr, ...) はこのファイルに書き込まれる
        std::cout << "TAM active_threads logs will be written to: "
                  << path << std::endl;
        // fp は stderr と同じ FD を指すので、ここで明示的に fclose しなくても良い
      }
    }
  }
#endif

#ifdef Linux
  // プロセス全体を「ソケット0上の CPU」に閉じ込める（ただし TotalThreadNum が
  // ソケット0の論理 CPU 数以下のときだけ）。これにより、プログラム単体でも
  // thread_num ≤ socket0 コア数なら必ず node0 だけを使うポリシーを実現する。
  if (FLAGS_pin_threads) {
    setProcessAffinitySocket0IfFits(TotalThreadNum);
  }
#endif

  YcsbWorkload::displayWorkloadParameter();
  YcsbWorkload::makeDB<Tuple,void>(nullptr);

  alignas(CACHE_LINE_SIZE) bool start = false;
  alignas(CACHE_LINE_SIZE) bool quit = false;
  initResult();
  std::vector<char> readys(TotalThreadNum);
  std::vector<std::thread> thv;
  // ★ TAM 初期化（AdaTAM / LinUCBTAM が有効なときに初期化）
  if (g_tam.enabled()) {
    g_tam.init(TotalThreadNum, FLAGS_clocks_per_us);
  }
  for (size_t i = 0; i < TotalThreadNum; ++i)
    thv.emplace_back(worker, i, std::ref(readys[i]), std::ref(start),
                     std::ref(quit));
  waitForReady(readys);
  uint64_t start_tsc = rdtscp();
  storeRelease(start, true);

  // TAM: tam_update_period_us を唯一の周期パラメータとして使う
  uint64_t tick_us = FLAGS_tam_update_period_us;
  // 0 は不正値とみなし、事前に気付けるようにする（無限ループ防止）。
  if (tick_us == 0) {
    fprintf(stderr, "tam_update_period_us must be > 0\n");
    ERR;
  }

  // 実際の経過時間が FLAGS_extime 秒に達したらループを抜けるようにする。
  const uint64_t target_clocks =
      static_cast<uint64_t>(FLAGS_extime) * FLAGS_clocks_per_us * 1000000ULL;

  // Zipf skew を途中で 1〜2 回変更する場合のための制御変数。
  const bool enable_skew_change1 = FLAGS_ycsb_skew_change_enable &&
                                   (FLAGS_ycsb_skew_change_time_sec > 0);
  const uint64_t skew_change_clocks1 =
      static_cast<uint64_t>(FLAGS_ycsb_skew_change_time_sec) *
      FLAGS_clocks_per_us * 1000000ULL;
  bool skew_changed1 = false;

  const bool enable_skew_change2 = FLAGS_ycsb_skew_change_enable2 &&
                                   (FLAGS_ycsb_skew_change_time_sec2 > 0);
  const uint64_t skew_change_clocks2 =
      static_cast<uint64_t>(FLAGS_ycsb_skew_change_time_sec2) *
      FLAGS_clocks_per_us * 1000000ULL;
  bool skew_changed2 = false;

  while (true) {
    // ★ µs 単位でスリープ
    sleepUs(tick_us);

    if (g_tam.enabled()) {
      uint64_t committed_sum = 0;
      uint64_t abort_sum = 0;
      for (unsigned int i = 0; i < TotalThreadNum; ++i) {
        committed_sum += loadAcquire(SiloResult[i].local_commit_counts_);
        abort_sum += loadAcquire(SiloResult[i].local_abort_counts_);
      }
      g_tam.update(committed_sum, abort_sum);
    }

    uint64_t now = rdtscp();

    // 必要なら、指定された時刻で Zipf skew を切り替える。
    // 1 回目: 初期 skew -> skew2
    if (enable_skew_change1 && !skew_changed1 &&
        now - start_tsc >= skew_change_clocks1) {
      g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew2,
                                std::memory_order_release);
      std::cout << "[YCSB] Zipf skew changed in-run (phase1): "
                << FLAGS_ycsb_zipf_skew << " -> "
                << FLAGS_ycsb_zipf_skew2 << " at ~"
                << FLAGS_ycsb_skew_change_time_sec << " sec" << std::endl;
      skew_changed1 = true;
    }

    // 2 回目: skew2 (またはその時点の current skew) -> skew3
    if (enable_skew_change2 && !skew_changed2 &&
        now - start_tsc >= skew_change_clocks2) {
      g_current_ycsb_skew.store(FLAGS_ycsb_zipf_skew3,
                                std::memory_order_release);
      std::cout << "[YCSB] Zipf skew changed in-run (phase2): "
                << FLAGS_ycsb_zipf_skew2 << " -> "
                << FLAGS_ycsb_zipf_skew3 << " at ~"
                << FLAGS_ycsb_skew_change_time_sec2 << " sec" << std::endl;
      skew_changed2 = true;
    }

    if (now - start_tsc >= target_clocks) break;
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
  // TAM が有効かつ active_threads ログを取っている場合は、最後に
  // active_threads の平均・標準偏差をログに出力する。
  if (g_tam.enabled()) {
    g_tam.print_stats();
  }
  ShowOptParameters();
  std::cout << "actual_extime:\t" << actual_extime << std::endl;
  SiloResult[0].displayAllResult(FLAGS_clocks_per_us, FLAGS_extime, TotalThreadNum);
  threadinfo::destroy_all();

  return 0;
} catch (bad_alloc) {
  ERR;
}
