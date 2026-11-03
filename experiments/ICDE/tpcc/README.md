# TPC-C experiments

This directory contains the TPC-C experiment entry points. Existing scripts
remain at their current paths because prior commands and result metadata refer
to them. Use this index to choose an experiment; generated data belongs under
`results/` and is not an experiment script.

## Script index

| Script | Purpose | Main workload control |
|---|---|---|
| [`neworder_mix_sweep.sh`](neworder_mix_sweep.sh) | Sweep New-Order share at a fixed warehouse count using regular TPC-C behavior | New-Order percentage and thread count |
| [`hot_transaction_calibration.sh`](hot_transaction_calibration.sh) | Calibrate the custom hot-New-Order transaction workload | Hot-transaction ratio, hot warehouse/district/items |
| [`contention_sweep.sh`](contention_sweep.sh) | Sweep custom hot-item ratio at a fixed thread count | Hot-item ratio and hot-item/supplier settings |
| [`thread_sweep_neworder90.sh`](thread_sweep_neworder90.sh) | Find static thread-count peaks for hot-item ratios | Thread count and hot-item ratio; mix defaults to 90/7/1/1/1 |
| [`warehouse_contention_sweep.sh`](warehouse_contention_sweep.sh) | Change contention by changing warehouse count | Warehouse and thread count |
| [`native_warehouse_sweep.sh`](native_warehouse_sweep.sh) | Keeps the database at 96 warehouses and varies how many are selected as worker home warehouses | Total threads and active warehouse count |
| [`quick_contention_pilot.sh`](quick_contention_pilot.sh) | Short pilot over hot-item-set sizes | Delegates to `thread_sweep_neworder90.sh` |
| [`metis/model_learning.sh`](metis/model_learning.sh) | Train a held-out-ratio Metis/LinUCB model | Hot-transaction ratio and model parameters |
| [`metis/model_percheck.sh`](metis/model_percheck.sh) | Evaluate a trained Metis/LinUCB model | Target ratio and model parameters |

## Standard-mix New-Order sweep

`neworder_mix_sweep.sh` defaults to 96 warehouses, New-Order percentages
`45 55 65 75 85 90`, thread counts `8 16 24 32 48 64 96`, two repeats, and
five seconds per run. Its 45% baseline exactly matches the standard TPC-C
mix: New-Order 45%, Payment 43%, Order-Status 4%, Delivery 4%, Stock-Level 4%.
When New-Order is changed, the remaining percentage is distributed among the
other transaction types in their standard 43:4:4:4 ratio, with largest-
remainder rounding to integer percentages so the total remains 100%. When the
remainder is at least 4%, each non-New-Order type is kept at 1% or more to avoid
silently dropping a transaction type due to integer rounding.

The warehouse count stays constant throughout a sweep. The script sets
`--tpcc_home_warehouse_assignment=random_per_transaction`, which chooses a
home warehouse from the configured active home-warehouse range for each
logical transaction. With no `tpcc_active_warehouse_count` override, that range
is the full database. It does not pass custom `tpcc_hot_*` flags. Item,
supplier, district, and remote-line behavior therefore use the benchmark's
regular TPC-C generation. METIS and AdaTAM are disabled. The TPC-C retry and
interactive-delay settings are left at the benchmark defaults.
`NUMACTL_ARGS` defaults to `--interleave=all`; set it explicitly to empty
(`NUMACTL_ARGS=''`) to run without a numactl NUMA policy.

## Home warehouse assignment modes

The benchmark accepts `--tpcc_home_warehouse_assignment` with three values:

- `worker_affined` (default): preserve the existing worker-to-home mapping.
- `random_per_transaction`: choose uniformly from `1..tpcc_active_warehouse_count`
  for each logical transaction (or `1..tpcc_num_wh` when active count is 0).
  A retry retains the same selected home warehouse.
- `randomized_worker_affined`: shuffle a balanced list of home warehouses at
  startup and keep each worker's assignment fixed. The reproducible shuffle
  seed is `--tpcc_home_warehouse_seed` (default 1). When workers are fewer than
  active warehouses, some warehouses necessarily receive no worker.

The Metis learning and performance scripts expose these as
`HOME_WAREHOUSE_ASSIGNMENT` and `HOME_WAREHOUSE_SEED`; use the same values for
training and evaluation, and use separate model versions for different modes.

Example:

```bash
WAREHOUSES=96 \
NEW_ORDER_PERCENTAGES='45 55 65 75 85 90' \
THREADS='8 16 24 32 48 64 96' \
EXTIME=5 REPEATS=2 \
bash experiments/ICDE/tpcc/neworder_mix_sweep.sh
```

Each run creates a timestamped directory under `results/neworder_mix_sweep_*`
containing `config.txt`, raw `results.csv`, per-thread `summary.csv`,
`best_threads.csv`, and benchmark logs. The script refuses to overwrite an
existing result directory.

## Native-default active-warehouse sweep

`native_warehouse_sweep.sh` keeps the database size fixed at 96 warehouses.
For every requested total thread count and active warehouse count, it runs a
measurement; no combinations are skipped for divisibility or for having more
active warehouses than workers. `--tpcc_active_warehouse_count` defines the
logical terminal home-warehouse range `1..ACTIVE_WAREHOUSES`, while
`--tpcc_num_wh=96` keeps all 96 warehouses loaded. The script's
`HOME_WAREHOUSE_ASSIGNMENT` defaults to `worker_affined`; in that mode workers
may share homes when active warehouses do not exceed worker threads, and when
active warehouses exceed worker threads each worker rotates through its
strided home subset only after a successful transaction. The CSV records
average home warehouses per worker and workers per home warehouse; for
non-divisible combinations, individual worker assignments differ by at most
one logical home. Standard transaction mix,
remote transactions, retry behavior, hot-workload, METIS, TAM, and NUMA policy
remain at defaults. Logs are gzip compressed; `summary.csv` reports mean TPS,
abort rate, and latency for each mapping.

Example:

```bash
TOTAL_THREADS=96 \
ACTIVE_WAREHOUSES='96 48 32 24 16 12 8 6 4 3 2 1' \
EXTIME=5 REPEATS=2 \
bash experiments/ICDE/tpcc/native_warehouse_sweep.sh
```

For 96 total threads, this keeps the database at 96 warehouses while sweeping
from one worker per active warehouse to 96 workers sharing one home warehouse.
With the default `worker_affined` mode, the initial home mapping is
`(worker_id % active_warehouse_count) + 1`.
Remote Payment customers and New-Order supply warehouses still use the full
96-warehouse database, as in the standard workload. Supplying multiple values
for both variables considers their Cartesian product; only valid pairs run.
