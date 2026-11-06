#pragma once

#include <atomic>
#include <thread>
#include <vector>
#include <set>

#include "config.hh"
#include "adaptive_state.hh"
#include "debug.hh"
#include "heap_object.hh"
#include "procedure.hh"
#include "random.hh"
#include "result.hh"
#include "tuple_body.hh"
#include "util.hh"
#include "workload.hh"
#include "zipf.hh"

#if ADAPTIVE_TAM
#include "tam.hh"
#endif

#include "./tpcc/tpcc_initializer.hh"
#include "./tpcc/tpcc_query.hh"
#include "./tpcc/tpcc_tables.hh"
#include "./tpcc/tpcc_tx_neworder.hh"
#include "./tpcc/tpcc_tx_payment.hh"
#include "./tpcc/tpcc_tx_orderstatus.hh"
#include "./tpcc/tpcc_tx_delivery.hh"
#include "./tpcc/tpcc_tx_stocklevel.hh"

template <typename Tuple, typename Param>
class TPCCWorkload {
public:
  Param* param_;
  Xoroshiro128Plus rnd_;
  HistoryKeyGenerator hkg_;
  uint16_t w_id; // home warehouse
  uint16_t home_warehouse_base_;
  uint32_t home_warehouse_stride_;
  uint32_t active_warehouses_;

  TPCCWorkload() { rnd_.init(); }

  void prepare(TxExecutor& tx, [[maybe_unused]] Param* p) {
    hkg_.init(tx.thid_, true);
    const auto active_warehouses = FLAGS_tpcc_active_warehouse_count == 0
                                       ? FLAGS_tpcc_num_wh
                                       : FLAGS_tpcc_active_warehouse_count;
    active_warehouses_ = active_warehouses;
    home_warehouse_base_ =
        static_cast<uint16_t>(tx.thid_ % active_warehouses) + 1;
    w_id = home_warehouse_base_;
    if (runtime_home_tracking_enabled()) {
      g_tpcc_home_warehouses[tx.thid_].store(home_warehouse_base_,
                                             std::memory_order_release);
      g_tpcc_worker_warehouses[tx.thid_].store(active_warehouses_,
                                               std::memory_order_release);
    }

    // A physical worker can represent multiple logical TPC-C terminals. Give
    // each worker a disjoint strided subset of home warehouses, then rotate
    // between those homes after each committed transaction. Aborted retries
    // stay on the current home warehouse because this advances only on commit.
    home_warehouse_stride_ =
        FLAGS_tpcc_home_warehouse_assignment == "worker_affined" &&
                active_warehouses > FLAGS_thread_num
            ? static_cast<uint32_t>(FLAGS_thread_num)
            : 0;
  }

  template <typename TxExecutor, typename TransactionStatus>
  void run(TxExecutor& tx) {
    if (runtime_home_tracking_enabled()) {
      refresh_runtime_home(tx.thid_);
    }
    Query query;
    TPCCQuery::Option option;
    const TxType retry_type =
        FLAGS_tpcc_retry_same_type ? decideQueryType(option) : TxType::None;
    uint16_t transaction_home_warehouse = w_id;
    if (FLAGS_tpcc_home_warehouse_assignment == "random_per_transaction") {
      transaction_home_warehouse = static_cast<uint16_t>(
          random_int(1, active_warehouses_));
    }

  RETRY:
#if ADAPTIVE_TAM
    // All locks from the preceding attempt have been released before RETRY.
    // Honor a lower active-thread count before starting the next attempt:
    // TPC-C retries can be long, so waiting for the next transaction would
    // delay a decrease of the active count.
    while (tx.thid_ >= g_active_threads.load(std::memory_order_acquire) &&
           !loadAcquire(tx.quit_)) {
      park_worker(tx);
    }
#endif
    // A parked worker may resume an aborted attempt after a warehouse switch.
    // Its old logical home must be replaced before the next retry starts.
    if (runtime_home_tracking_enabled() && refresh_runtime_home(tx.thid_)) {
      transaction_home_warehouse =
          FLAGS_tpcc_home_warehouse_assignment == "random_per_transaction"
              ? static_cast<uint16_t>(random_int(1, active_warehouses_))
              : w_id;
    }
    if (FLAGS_tpcc_retry_same_type) {
      // Preserve the logical transaction type, but regenerate its parameters
      // on every retry.  Regeneration is necessary because New-Order includes
      // an intentional 1% rollback input; retrying that exact input forever
      // would prevent the worker from making progress.
      query.generate(retry_type, transaction_home_warehouse, option);
    } else {
      query.generate(transaction_home_warehouse, option);
    }

    if (tx.isLeader()) { tx.leaderWork(); }

    if (loadAcquire(tx.quit_)) return;

    tx.begin();

    switch (query.type) {
      case TxType::NewOrder:
        if (!run_new_order<TxExecutor, TransactionStatus>(tx,
                                                          &query.new_order)) {
          tx.status_ = TransactionStatus::aborted;
        }
        break;
      case TxType::Payment:
        if (!run_payment<TxExecutor, TransactionStatus, Tuple>(
                tx, &query.payment, &hkg_)) {
          tx.status_ = TransactionStatus::aborted;
        }
        break;
      case TxType::OrderStatus:
        if (!run_order_status<TxExecutor, TransactionStatus, Tuple>(
                tx, &query.order_status)) {
          tx.status_ = TransactionStatus::aborted;
        }
        break;
      case TxType::Delivery:
        if (!run_delivery<TxExecutor, TransactionStatus>(tx, &query.delivery)) {
          tx.status_ = TransactionStatus::aborted;
        }
        break;
      case TxType::StockLevel:
        if (!run_stock_level<TxExecutor, TransactionStatus>(
                tx, &query.stock_level)) {
          tx.status_ = TransactionStatus::aborted;
        }
        break;
      default:
        ERR;
        break;
    }

    if (tx.status_ == TransactionStatus::aborted) {
      tx.abort();
      tx.result_->local_abort_counts_++;
      tx.result_->local_abort_counts_per_tx_[get_tx_type(query.type)]++;
#if ADD_ANALYSIS
      ++tx.result_->local_early_aborts_;
#endif
      goto RETRY;
    }

    if (!tx.commit()) {
      tx.abort();
      if (tx.status_ == TransactionStatus::invalid) return;
      tx.result_->local_abort_counts_++;
      tx.result_->local_abort_counts_per_tx_[get_tx_type(query.type)]++;
      goto RETRY;
    }

    if (loadAcquire(tx.quit_)) return;
    tx.result_->local_commit_counts_++;
    tx.result_->local_commit_counts_per_tx_[get_tx_type(query.type)]++;

    if (home_warehouse_stride_ != 0) {
      const auto next_home = static_cast<uint32_t>(w_id) + home_warehouse_stride_;
      w_id = static_cast<uint16_t>(next_home <= active_warehouses_
                                       ? next_home
                                       : home_warehouse_base_);
    }

    return;
  }

  static uint32_t getTableNum() { return (uint32_t) Storage::Size; }

  // Called by the control loop for --tpcc_active_warehouse_schedule. Worker i
  // gets home warehouse (i mod warehouses) + 1 before its next transaction.
  static void set_runtime_active_warehouses(uint32_t warehouses) {
    for (uint32_t i = 0; i < FLAGS_thread_num; ++i)
      g_tpcc_home_warehouses[i].store(static_cast<uint16_t>(i % warehouses) + 1,
                                      std::memory_order_release);
    // Publish the workload change after the complete home map is available.
    g_tpcc_runtime_active_warehouses.store(warehouses,
                                           std::memory_order_release);
  }

  static void makeDB([[maybe_unused]] Param* param) {
    if (runtime_home_tracking_enabled() &&
        g_tpcc_home_warehouses.size() != FLAGS_thread_num) {
      g_tpcc_home_warehouses =
          std::vector<std::atomic<std::uint16_t>>(FLAGS_thread_num);
      g_tpcc_worker_warehouses =
          std::vector<std::atomic<std::uint32_t>>(FLAGS_thread_num);
    }
    if (g_tpcc_runtime_active_warehouses.load(std::memory_order_acquire) == 0) {
      g_tpcc_runtime_active_warehouses.store(
          FLAGS_tpcc_active_warehouse_count == 0 ? FLAGS_tpcc_num_wh :
          FLAGS_tpcc_active_warehouse_count, std::memory_order_release);
    }
    Xoroshiro128Plus rand;
    rand.init();

    set_tx_name(TxType::NewOrder, "NewOrder");
    set_tx_name(TxType::Payment, "Payment");
    set_tx_name(TxType::OrderStatus, "OrderStatus");
    set_tx_name(TxType::Delivery, "Delivery");
    set_tx_name(TxType::StockLevel, "StockLevel");

    TPCCInitializaer<Tuple, Param>::load(param);
  }

  static void displayWorkloadParameter() {
    std::printf("#FLAGS_tpcc_num_wh:\t%u\n", FLAGS_tpcc_num_wh);
    std::printf("#FLAGS_tpcc_num_items:\t%u\n", FLAGS_tpcc_num_items);
    std::printf("#FLAGS_tpcc_active_warehouse_count:\t%u\n",
                FLAGS_tpcc_active_warehouse_count == 0
                    ? FLAGS_tpcc_num_wh
                    : FLAGS_tpcc_active_warehouse_count);
    std::printf("#FLAGS_tpcc_home_warehouse_assignment:\t%s\n",
                FLAGS_tpcc_home_warehouse_assignment.c_str());
    std::printf("#FLAGS_tpcc_retry_same_type:\t%s\n",
                FLAGS_tpcc_retry_same_type ? "true" : "false");
  }

  static void displayWorkloadResult() {}

private:
  static bool runtime_home_tracking_enabled() {
    return !FLAGS_tpcc_active_warehouse_schedule.empty();
  }

  bool refresh_runtime_home(std::size_t thread_id) {
    const auto runtime_warehouses =
        g_tpcc_runtime_active_warehouses.load(std::memory_order_acquire);
    if (runtime_warehouses == active_warehouses_) return false;
    active_warehouses_ = runtime_warehouses;
    home_warehouse_base_ = g_tpcc_home_warehouses[thread_id].load(
        std::memory_order_acquire);
    w_id = home_warehouse_base_;
    home_warehouse_stride_ =
        FLAGS_tpcc_home_warehouse_assignment == "worker_affined" &&
                active_warehouses_ > FLAGS_thread_num
            ? static_cast<uint32_t>(FLAGS_thread_num) : 0;
    g_tpcc_worker_warehouses[thread_id].store(
        active_warehouses_, std::memory_order_release);
    return true;
  }
};
