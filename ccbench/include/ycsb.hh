#pragma once

#include <atomic>
#include <thread>
#include <vector>

#include "config.hh"
#include "../../metis/shared_state.hh"
#include "debug.hh"
#include "heap_object.hh"
#include "procedure.hh"
#include "random.hh"
#include "result.hh"
#include "tuple_body.hh"
#include "util.hh"
#include "workload.hh"
#include "zipf.hh"

#include "gflags/gflags.h"

#ifdef GLOBAL_VALUE_DEFINE
DEFINE_bool(ycsb_rmw, false,
            "True means read modify write, false means blind write.");
DEFINE_uint64(ycsb_max_ope, 10,
              "Total number of operations per single transaction.");
DEFINE_uint64(ycsb_rratio, 50, "read ratio of single transaction.");
DEFINE_uint64(ycsb_tuple_num, 1000000, "Total number of records.");
DEFINE_double(ycsb_zipf_skew, 0, "zipf skew. 0 ~ 0.999...");
#else
DECLARE_bool(ycsb_rmw);
DECLARE_uint64(ycsb_max_ope);
DECLARE_uint64(ycsb_rratio);
DECLARE_uint64(ycsb_tuple_num);
DECLARE_double(ycsb_zipf_skew);
#endif

enum class Storage : std::uint32_t {
  YCSB = 0,
  Size,
};

struct YCSB {
  alignas(CACHE_LINE_SIZE) std::uint64_t id_;
  char val_[VAL_SIZE];

  //Primary Key: key_
  //key size is 8 bytes.
  static void CreateKey(uint64_t id, char* out) {
    assign_as_bigendian(id, &out[0]);
  }

  void createKey(char* out) const { return CreateKey(id_, out); }

  [[nodiscard]] std::string_view view() const { return struct_str_view(*this); }
};

inline static void makeProcedure(std::vector<Procedure>& pro,
                                 Xoroshiro128Plus& rnd, FastZipf& zipf) {
  pro.clear();
  bool ronly_flag(true), wonly_flag(true);
  for (size_t i = 0; i < FLAGS_ycsb_max_ope; ++i) {
    uint64_t tmpkey;
    // decide access destination key.
    tmpkey = zipf() % FLAGS_ycsb_tuple_num;

    // decide operation type.
    if ((rnd.next() % 100) < FLAGS_ycsb_rratio) {
      wonly_flag = false;
      pro.emplace_back(Ope::READ, tmpkey);
    } else {
      ronly_flag = false;
      if (FLAGS_ycsb_rmw) {
        pro.emplace_back(Ope::READ_MODIFY_WRITE, tmpkey);
      } else {
        pro.emplace_back(Ope::WRITE, tmpkey);
      }
    }
  }

  (*pro.begin()).ronly_ = ronly_flag;
  (*pro.begin()).wonly_ = wonly_flag;

#if KEY_SORT
  std::sort(pro.begin(), pro.end());
#endif // KEY_SORT
}

class YcsbWorkload {
public:
  Xoroshiro128Plus rnd_;
  FastZipf zipf_;
  double current_skew_;

  YcsbWorkload() {
    rnd_.init();
    current_skew_ = FLAGS_ycsb_zipf_skew;
    FastZipf zipf(&rnd_, current_skew_, FLAGS_ycsb_tuple_num);
    zipf_ = zipf;
  }

#if METIS_BREAKDOWN
  // Per-worker time breakdown (cycles). Attempt time includes the spin time
  // recorded in tx.bd_wait_; the analysis subtracts it.
  struct alignas(64) Breakdown {
    uint64_t committed = 0, aborted = 0, wait_committed = 0, wait_aborted = 0;
    uint64_t n_committed = 0, n_aborted = 0, first = 0, last = 0;
  };
  static Breakdown* breakdown() {
    static Breakdown b[1024];
    return b;
  }
#endif

  template <typename TxExecutor, typename TransactionStatus>
  void run(TxExecutor& tx) {
    const double requested_skew =
        g_current_ycsb_skew.load(std::memory_order_acquire);
    if (requested_skew >= 0.0 && requested_skew != current_skew_) {
      current_skew_ = requested_skew;
      FastZipf zipf(&rnd_, current_skew_, FLAGS_ycsb_tuple_num);
      zipf_ = zipf;
    }
#if ADD_ANALYSIS
    uint64_t start = rdtscp();
#endif
    makeProcedure(tx.pro_set_, rnd_, zipf_);
#if ADD_ANALYSIS
    tx.result_->local_make_procedure_latency_ += rdtscp() - start;
#endif
    tx.is_ronly_ = (*tx.pro_set_.begin()).ronly_;

  RETRY:
    if (tx.isLeader()) { tx.leaderWork(); }

    if (loadAcquire(tx.quit_)) return;

#if METIS_BREAKDOWN
    Breakdown& bd = breakdown()[tx.thid_];
    const uint64_t bd_t0 = rdtscp();
    const uint64_t bd_w0 = tx.bd_wait_;
    if (!bd.first) bd.first = bd_t0;
#define METIS_BD_END(ok)                                   \
  do {                                                     \
    const uint64_t bd_t1 = rdtscp();                       \
    const uint64_t bd_w = tx.bd_wait_ - bd_w0;             \
    if (ok) { bd.committed += bd_t1 - bd_t0; bd.wait_committed += bd_w; ++bd.n_committed; } \
    else    { bd.aborted += bd_t1 - bd_t0; bd.wait_aborted += bd_w; ++bd.n_aborted; }       \
    bd.last = bd_t1;                                       \
  } while (0)
#else
#define METIS_BD_END(ok) do { } while (0)
#endif
    tx.begin();
    SimpleKey<8> key[tx.pro_set_.size()];
    HeapObject obj[tx.pro_set_.size()];
    uint64_t i = 0;
    for (auto& pro : tx.pro_set_) {
      YCSB::CreateKey(pro.key_, key[i].ptr());
      uint64_t k;
      parse_bigendian(key[i].view().data(), k);
      if (pro.ope_ == Ope::READ) {
        TupleBody* body;
        tx.read(Storage::YCSB, key[i].view(), &body);
        if (tx.status_ != TransactionStatus::aborted) {
          // Touch the value so the read is not optimized away.
          [[maybe_unused]] YCSB& t = body->get_value().cast_to<YCSB>();
        }
      } else if (pro.ope_ == Ope::WRITE) {
        obj[i].template allocate<YCSB>();
        // Materialize the payload before it gets std::move'd into update.
        [[maybe_unused]] YCSB& t = obj[i].ref();
        tx.update(Storage::YCSB, key[i].view(),
                  TupleBody(key[i].view(), std::move(obj[i])));
      } else if (pro.ope_ == Ope::READ_MODIFY_WRITE) {
        TupleBody* body;
        tx.read(Storage::YCSB, key[i].view(), &body);
        if (tx.status_ != TransactionStatus::aborted) {
          YCSB& old_tuple = body->get_value().cast_to<YCSB>();
          obj[i].template allocate<YCSB>();
          YCSB& new_tuple = obj[i].ref();
          memcpy(new_tuple.val_, old_tuple.val_, VAL_SIZE);
          tx.update(Storage::YCSB, key[i].view(),
                    TupleBody(key[i].view(), std::move(obj[i])));
        }
      } else {
        ERR;
      }

      if (tx.status_ == TransactionStatus::aborted) {
        tx.abort();
        METIS_BD_END(false);
        ++tx.result_->local_abort_counts_;
#if ADD_ANALYSIS
        ++tx.result_->local_early_aborts_;
#endif
        goto RETRY;
      }

      i++;
    }

    if (!tx.commit()) {
      tx.abort();
      METIS_BD_END(false);
      ++tx.result_->local_abort_counts_;
      goto RETRY;
    }
    METIS_BD_END(true);
#undef METIS_BD_END
    storeRelease(tx.result_->local_commit_counts_,
                 loadAcquire(tx.result_->local_commit_counts_) + 1);

    return;
  }

  template <typename Tuple, typename Param>
  static void partTableInit([[maybe_unused]] size_t thid, Param* p,
                            uint64_t start, uint64_t end) {
#if MASSTREE_USE
    MasstreeWrapper<Tuple>::thread_init(thid);
#endif

    for (auto i = start; i <= end; ++i) {
      SimpleKey<8> key;
      YCSB::CreateKey(i, key.ptr());
      HeapObject obj;
      obj.allocate<YCSB>();
      YCSB& ycsb_tuple = obj.ref();
      ycsb_tuple.id_ = i;
      Tuple* tmp = new Tuple();
      tmp->init(thid, TupleBody(key.view(), std::move(obj)), p);
      Masstrees[get_storage(Storage::YCSB)].insert_value(key.view(), tmp);
    }
  }

  static uint32_t getTableNum() { return (uint32_t) Storage::Size; }

  template <typename Tuple, typename Param>
  static void makeDB(Param* p) {
    size_t maxthread = decideParallelBuildNumber(FLAGS_ycsb_tuple_num);

    std::vector<std::thread> thv;
    for (size_t i = 0; i < maxthread; ++i)
      thv.emplace_back(partTableInit<Tuple, Param>, i, p,
                       i * (FLAGS_ycsb_tuple_num / maxthread),
                       (i + 1) * (FLAGS_ycsb_tuple_num / maxthread) - 1);
    for (auto& th : thv) th.join();
  }

  static void displayWorkloadParameter() {
    cout << "#FLAGS_ycsb_max_ope:\t" << FLAGS_ycsb_max_ope << endl;
    cout << "#FLAGS_ycsb_rmw:\t" << FLAGS_ycsb_rmw << endl;
    cout << "#FLAGS_ycsb_rratio:\t" << FLAGS_ycsb_rratio << endl;
    cout << "#FLAGS_ycsb_tuple_num:\t" << FLAGS_ycsb_tuple_num << endl;
    cout << "#FLAGS_ycsb_zipf_skew:\t" << FLAGS_ycsb_zipf_skew << endl;
  }
};
