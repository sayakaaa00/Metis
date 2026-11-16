# Reproducing the Metis experiments

This directory contains the experiment scripts, the models trained for the
paper, and the figure scripts. The measured results of the paper are in the
submodule [data/](data)
([sayakaaa00/Metis-data](https://github.com/sayakaaa00/Metis-data)). For an
overview of Metis, see the [top-level README](../README.md); for its implementation,
[metis/README.md](../metis/README.md).

1. [Setup](#1-setup)
2. [Figures from the measured results](#2-figures-from-the-measured-results)
3. [Running the experiments](#3-running-the-experiments)
4. [Paper settings](#4-paper-settings)
5. [Options of the baselines and workload changes](#5-options-of-the-baselines-and-workload-changes)
6. [Known issue](#6-known-issue-cicada-stalls-under-extreme-contention)

Layout of this directory:

```
run/            experiment scripts (write new runs to results/)
figures/        one script per figure, make_figures.sh
models/         the Metis models used in the paper
data/           submodule Metis-data: the measured results and the figures of the paper
mysql/          submodule MySQL-Metis-experiments: Metis in MySQL
```

## 1. Setup

**Machine.** The results were measured on AWS with 2 × Intel Xeon Platinum 8375C
(48 physical cores, 96 logical CPUs, 185 GiB, Ubuntu 24.04, GCC 13). The scripts
assume 96 worker threads and `--clocks_per_us=2900` (the TSC frequency of that
machine). On another machine, change `WORKERS` and `--clocks_per_us` in
[run/common.py](run/common.py). A Metis model records the worker and physical-core
counts, and Metis refuses a model trained on a different topology.

**Build.**

```sh
git submodule update --init experiments/data experiments/mysql
./build.sh   # Release build + mimalloc shared library (LD_PRELOAD)
```

| Binary (`build_release/...`) | Used for |
|---|---|
| `silo/{ycsb,tpcc}_silo_nobackoff` | Metis, hill climbing, oracle (fixed active thread count), Silo |
| `silo/{ycsb,tpcc}_silo_backoff` | Silo with backoff (Silo-BO, fixed and exponential backoff) |
| `silo/ycsb_silo_breakdown` | Silo plus a `[BREAKDOWN]` line: time on committed and aborted transactions and time waiting on locked records |
| `cc/{cicada,ermia}/{ycsb,tpcc}_*.exe` | Cicada, ERMIA |

## 2. Figures from the measured results

```sh
experiments/figures/make_figures.sh   # experiments/data/ -> experiments/results/figures/
```

The scripts plot the data of the paper's figures. The paper versions were redrawn
afterwards (one PDF per benchmark, a separate legend; Fig. 7 also draws Oracle
and Silo-BO). They are in [data/figures/](data/figures), and the
[Metis-data README](data/README.md#figures-of-the-paper) shows each one with its
data and script. Each figure has one script in
[figures/](figures). [figures/figcommon.py](figures/figcommon.py) holds the data
paths and the oracle curves.

| Output (`results/figures/`) | Paper | Script | Data (`data/`) |
|---|---|---|---|
| `eval_static.pdf` | Evaluation, static workloads | `plot_eval_static.py` | `*/fixed`, `*/oracle`, `*/backoff_constant` |
| `eval_dynamic_tps.pdf`, `eval_dynamic_tps_tpcc.pdf` | Evaluation, dynamic workloads | `plot_eval_dynamic_tps.py`, `plot_eval_dynamic_tps_tpcc.py` | `*/dynamic` |
| `eval_static_time.pdf`, `eval_static_tps.pdf` | Evaluation, hill climbing (static) | `plot_eval_static_time.py`, `plot_eval_static_tps.py` | `*/fixed/logs`, `ycsb/hill_climbing_10ms_log` |
| `eval_dynamic.pdf` | Evaluation, hill climbing (dynamic) | `plot_eval_dynamic.py` | `*/dynamic_hill_climbing` |

The paper splits some of these figures into one PDF per benchmark plus a
legend. That layout and the MySQL figures are made in
[Tatzhiro/MySQL-Metis-experiments](https://github.com/Tatzhiro/MySQL-Metis-experiments)
(submodule `experiments/mysql`).

## 3. Running the experiments

Every script writes to `$METIS_OUT` (default: `experiments/results/`) in the same layout as `data/`. To plot new runs
(after all the runs a figure needs, see the [figure table](#2-figures-from-the-measured-results)):

```sh
METIS_DATA=experiments/results experiments/figures/make_figures.sh
```

Each run is appended to a results CSV. A script skips runs that are already
recorded, so an interrupted script resumes where it stopped. The method order
is reversed on even runs. TPC-C runs first load the 96-warehouse database.
The scripts are in [run/](run) and run from any directory, e.g.
`python3 experiments/run/fixed.py --bench ycsb`.

| Step | Command | Output (`$METIS_OUT/...`) | Runs |
|---|---|---|---|
| Oracle: every fixed active thread count | `oracle.py --bench ycsb`, `oracle.py --bench tpcc` | `<bench>/oracle/` | levels × N × 2 × 10 s |
| Train Metis | `train.py run --bench B`, then `train.py merge --bench B` | `<bench>/train/`, `<bench>/models/` | levels × 2 × 30 s |
| Static workloads, all methods | `fixed.py --bench ycsb`, `fixed.py --bench tpcc` | `<bench>/fixed/` | 6 methods × levels × 2 × 10 s (YCSB) / 30 s (TPC-C) |
| Hill climbing, per-period samples | `fixed.py --bench ycsb --hill-climbing-trace --states 0,0.8,0.9,0.95,0.99,0.999` | `ycsb/hill_climbing_10ms_log/` | 6 × 2 × 10 s |
| Dynamic workloads D1 / Y1 | `dynamic.py throughput --bench tpcc`, `--bench ycsb` | `<bench>/dynamic/` | 5 methods × 2 × 60 s |
| Dynamic workloads D11 / Y4 | `dynamic.py hill_climbing --bench tpcc`, `--bench ycsb` | `<bench>/dynamic_hill_climbing/` | 2 methods × 2 × 60 s |
| Fixed backoff duration | `backoff.py constant --bench ycsb`, `--bench tpcc` | `<bench>/backoff_constant/` | levels × durations × 2 × 10 s |
| Exponential backoff | `backoff.py exponential` | `ycsb/backoff_exponential/` | 5 skews × 11 durations × 2 × 10 s |
| Silo-BO setting | `backoff.py tune --bench ycsb`, `--bench tpcc` | `<bench>/backoff_adaptive_tuning/` | 16 settings × 3 levels × 10 s |
| Time breakdown | `breakdown.py` | `ycsb/breakdown/` | 10 × 2 × 10 s |

Metis uses the paper's models in [models/](models) by default. To evaluate the
models trained by `train.py`, pass `--models $METIS_OUT/<bench>/models/min6
--model-set min6` to `fixed.py` or `dynamic.py`.

Besides the experiment scripts, [run/](run) contains [common.py](run/common.py)
(binaries, contention levels, and the command line of every method) and
[merge_models.py](run/merge_models.py) (pools training runs into a model).

## 4. Paper settings

**Contention levels.** TPC-C: `W` = 1, 2, 3, 4, 8, 16, 32, 96 accessed
warehouses (the home warehouse of each transaction is drawn from the first `W`
of 96). YCSB: 10,000 records, 10 operations per transaction, 50 % reads, Zipf
skew 0, 0.5, 0.7, 0.8, 0.85, 0.9, 0.95, 0.99, 0.999. Control period: 200 ms
(TPC-C), 10 ms (YCSB).

**Dynamic workloads** (60 s, two changes):

| Name | Change | Paper |
|---|---|---|
| `D1` | TPC-C `W` 16 → 1 (20 s) → 4 (40 s) | Throughput over time |
| `Y1` | YCSB skew 0.7 → 0.95 → 0.8 | Throughput over time |
| `D11` | TPC-C `W` 2 → 8 → 1 | Comparison with hill climbing |
| `Y4` | YCSB skew 0.99 → 0.5 → 0.95 | Comparison with hill climbing (Metis with `--metis_recheck_physical=false`) |

**Methods.**

| Method | Setting |
|---|---|
| Metis | Static runs: leave-one-out model `loo_<level>.txt` (never trained on that level). Dynamic runs: `all.txt` |
| Hill climbing | Step 8 (TPC-C) / 4 (YCSB), the best of a short sweep |
| Silo-BO | Adaptive backoff of Cicada (randomized wait); update period / step 1 ms / 0.5 µs (TPC-C), 20 ms / 2 µs (YCSB), from `backoff.py tune` |
| Cicada | Its adaptive backoff with the defaults of the Cicada paper (5 ms, 0.5 µs) |
| ERMIA | CCBench's adaptive backoff, doubled per consecutive abort; 3-s runs on TPC-C |
| Oracle | Silo with the best fixed active thread count of each level |

**Models.** [models/](models) holds the models used in the paper (converted
from `data/<bench>/models`). The scripts pick the model of each experiment; the
model behind each figure is listed in the
[Metis-data README](data/README.md#figures-of-the-paper).

## 5. Options of the baselines and workload changes

The options of Metis, hill climbing, and thread throttling are listed in
[metis/README.md](../metis/README.md#main-options).

| Option | Default | Meaning |
|---|---|---|
| `--backoff_update_period_us`, `--backoff_step_us` | 5000, 0.5 | Adaptive backoff: update period and step |
| `--backoff_randomized` | false | Random wait in [0, duration] and a random direction at zero gradient (Cicada) |
| `--backoff_adaptive_exponential` | false | Adaptive backoff: double the wait per consecutive abort |
| `--backoff_fixed_enable`, `--backoff_fixed_us`, `--backoff_fixed_exponential` | false, 0, true | Fixed backoff duration, doubled per consecutive abort unless `--backoff_fixed_exponential=false` |
| `--tpcc_active_warehouse_schedule` | | In-run changes of `W`, e.g. `0:16,20:1,40:4` |
| `--ycsb_skew_change_*`, `--ycsb_zipf_skew2/3` | | In-run skew changes (at most two) |
| `--benchmark_interval_tps_log_us` | 0 | Log the throughput of each interval |
| `--tpcc_pin_order`, `--ycsb_pin_order` | socket0_first | `physical_first`: one thread per physical core (socket 0, then socket 1), then the SMT siblings |

The recorded logs in `data/` use the option and log-tag names of the time of
measurement (see the [Metis-data README](data/README.md)); the figure scripts
read both those tags and the current ones.

## 6. Known issue: Cicada stalls under extreme contention

At the highest contention levels (TPC-C `W` = 1, YCSB skew 0.99 and above),
Cicada sometimes stops committing shortly after a run starts. On the evaluation
machine, 4 of 12 10-s runs of TPC-C `W` = 1 committed almost nothing (about
10 txn/s instead of about 24,000). This happened both with the binaries used for
the paper measurements and with this repository. The paper's dynamic YCSB figure
uses Cicada run 2 because run 1 stopped committing at 38 s. When re-running,
check `commit_counts_` in the Cicada logs.
