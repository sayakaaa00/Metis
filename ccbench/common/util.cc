
#include "./../include/atomic_wrapper.hh"
#include "./../include/util.hh"

#include <sched.h>

bool chkSpan(struct timeval& start, struct timeval& stop, long threshold) {
  long diff = 0;
  diff += (stop.tv_sec - start.tv_sec) * 1000 * 1000 +
          (stop.tv_usec - start.tv_usec);
  if (diff > threshold)
    return true;
  else
    return false;
}

size_t decideParallelBuildNumber(size_t tuple_num) {
  // if table size is very small, it builds by single thread.
  if (tuple_num < 1000) return 1;

  // Respect a process-level affinity mask when choosing loader threads.
  size_t hw = std::thread::hardware_concurrency();
  if (hw == 0) hw = 1;

  cpu_set_t set;
  CPU_ZERO(&set);
  if (sched_getaffinity(0, sizeof(set), &set) == 0) {
    const int available = CPU_COUNT(&set);
    if (available > 0 && static_cast<size_t>(available) < hw) {
      hw = static_cast<size_t>(available);
    }
  }

  for (size_t i = hw; i > 0; --i) {
    if (tuple_num % i == 0) { return i; }
    if (i == 1) ERR;
  }

  return 0;
}

// TODO: enable this if we want to use
// void displayProcedureVector(std::vector<Procedure> &pro) {
//   printf("--------------------\n");
//   size_t index = 0;
//   for (auto &&elem : pro) {
//     printf(
//             "-----\n"
//             "op_num\t: %zu\n"
//             "key\t: %zu\n"
//             "r/w\t: %d\n",
//             index, elem.key_, (int) (elem.ope_));
//     ++index;
//   }
//   printf("--------------------\n");
// }

void displayRusageRUMaxrss() {
  struct rusage r {};
  if (getrusage(RUSAGE_SELF, &r) != 0) ERR;
  printf("maxrss:\t%ld kB\n", r.ru_maxrss);
}

void readyAndWaitForReadyOfAllThread(std::atomic<size_t>& running,
                                     const size_t thnm) {
  running++;
  while (running.load(std::memory_order_acquire) != thnm) _mm_pause();
}

void waitForReadyOfAllThread(std::atomic<size_t>& running, const size_t thnm) {
  while (running.load(std::memory_order_acquire) != thnm) _mm_pause();
}

bool isReady(const std::vector<char>& readys) {
  for (const char& b : readys) {
    if (!loadAcquire(b)) return false;
  }
  return true;
}

void waitForReady(const std::vector<char>& readys) {
  while (!isReady(readys)) { _mm_pause(); }
}

void sleepMs(size_t ms) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

void sleepMicroSec(size_t ms) {
  std::this_thread::sleep_for(std::chrono::microseconds(ms));
}
