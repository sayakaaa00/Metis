# Metis: learned control of the number of active worker threads

This directory holds the experiment scripts, trained models, recorded results,
and figures of the Metis paper. Metis runs on CCBench's Silo. The benchmark
spawns a fixed set of workers (96 here), and only the first N of them run
transactions. Metis picks N from {8, 10, ..., 96} using one linear model of the
throughput ratio log(T(a)/T(c)). The model's inputs are the observed abort rate
and the CPU resources that a thread count uses (cross-socket share and SMT
share, read from the CPU topology). It gets no benchmark-specific input.

## Code

| File | Contents |
|---|---|
| [include/metis.hh](../../include/metis.hh) | Metis: features, ridge-regression model, training (random exploration), and evaluation: model-predicted moves, local refinement, re-measuring the top candidates, commit and hold, workload-change detection |
| [include/adatam.hh](../../include/adatam.hh) | AdaTAM, the hill-climbing baseline |
| [include/tam.hh](../../include/tam.hh) | Shared flags, controller selection (Metis / AdaTAM / fixed N), parking of inactive workers |
| [include/adaptive_control.hh](../../include/adaptive_control.hh) | Control loop on the main thread: feeds commit/abort counts to the controller every control period, writes the logs |
| [common/runner.hh](../../common/runner.hh) | Worker loop with the per-transaction gate |
| [include/tpcc.hh](../../include/tpcc.hh) | TPC-C workload: gate before every retry, in-run change of the active warehouse count |
| [cc/silo/ycsb_silo.cc](../../cc/silo/ycsb_silo.cc), [cc/silo/tpcc_silo.cc](../../cc/silo/tpcc_silo.cc) | Silo entry points (CPU pinning order, in-run workload changes) |
| [include/backoff.hh](../../include/backoff.hh) | Adaptive exponential backoff (Silo with backoff baseline) |

An inactive worker sleeps 50 µs per check (`--tam_idle_sleep_us`). While it
waits, it keeps announcing the current Silo epoch so that epoch advancement and
garbage collection continue.

## Requirements

- x86-64 Linux, GCC 13 (Ubuntu 24.04, as in [docs/build_en.md](../../docs/build_en.md)), CMake, Python 3 with matplotlib.
- The results were measured on 2 × Intel Xeon Platinum 8375C (48 physical
  cores, 96 hardware threads, 185 GiB, Ubuntu 24.04 KVM guest). The scripts
  assume 96 workers and `--clocks_per_us=2900` (the TSC frequency of that
  machine); change `WORKERS` and `--clocks_per_us` in
  [common.py](common.py) for another machine. Trained models record the worker
  and physical-core counts, and Metis refuses a model from a different
  topology.

## Build

```sh
experiments/metis/build.sh      # Release build + mimalloc shared library for LD_PRELOAD
```

| Binary (`build_release/...`) | Used for |
|---|---|
| `silo/{ycsb,tpcc}_silo_nobackoff` | Metis, AdaTAM, fixed-N sweeps, Silo without backoff |
| `silo/{ycsb,tpcc}_silo_backoff` | Silo with backoff |
| `cc/{cicada,ermia}/{ycsb,tpcc}_*.exe` | Cicada, ERMIA |

## Reproducing the experiments

All scripts run from any directory. Each run is appended to a `results.csv`,
and a script skips runs that are already recorded, so an interrupted script
resumes where it stopped. Delete or move the recorded results first if you
want fresh numbers.

| Step | Command | Runs (paper) |
|---|---|---|
| Oracle: TPS for every fixed N | `oracle.py --bench tpcc` / `--bench ycsb` | states × N grid × 2 runs × 10 s |
| Training runs | `train.py run --bench tpcc` / `--bench ycsb` | states × 2 runs × 30 s / 20 s |
| Models (all states, leave-one-out) | `train.py merge --bench tpcc` / `--bench ycsb` | none (seconds) |
| Fixed load: all methods | `compare.py --bench tpcc` / `--bench ycsb` | 6 methods × states × 2 runs × 30 s / 10 s |
| Dynamic load | `dynamic.py --bench tpcc --schedules D1,D2,D3` / `dynamic.py --bench ycsb` | schedules × 4 methods × 2 runs × 60 s |
| Figures and summaries | `make_figures.sh` | none (seconds) |

TPC-C runs also load the 96-warehouse database first.

Workload states: TPC-C standard mix with 96 warehouses, where the transaction's
home warehouse is drawn from the first W warehouses (W = 1, 2, 3, 4, 8, 16, 32,
96). YCSB: 10,000 records, 10 operations per transaction, 50 % reads, Zipf skew
0.7 to 0.999. Control period: TPC-C 200 ms, YCSB 10 ms. In the fixed-load
runs, Metis evaluates each state with a model trained without that state
(`models/loo_<state>.txt`). In the dynamic runs it uses the model trained on
all states (`models/all.txt`).

A single run, for example Metis on TPC-C with W = 4:

```sh
LD_PRELOAD=build_release/mimalloc_override/libmimalloc.so \
build_release/silo/tpcc_silo_nobackoff --thread_num=96 --tpcc_num_wh=96 \
  --tpcc_active_warehouse_count=4 --tpcc_home_warehouse_assignment=random_per_transaction \
  --tpcc_pin_order=physical_first --extime=30 --clocks_per_us=2900 \
  --tam_update_period_us=200000 --tam_log_active_threads=true \
  --metis_enable=true --metis_model_path=experiments/metis/tpcc/models/loo_4.txt
```

`--tam_log_active_threads=true` redirects the controller log (one `[Metis]`
line per decision, `[TAM sample]` every 100 ms) to `logs/`. The experiment
scripts move this log next to the run log as `*.trace.log`.

## Main options

| Option | Default | Meaning |
|---|---|---|
| `--metis_enable` | false | Run Metis |
| `--metis_learn` | false | Training run: random thread counts, save the model to `--metis_model_path` |
| `--metis_model_path` | | Model to load (evaluation) or write (training) |
| `--metis_recheck`, `--metis_recheck_intervals` | 3, 3 | Before committing, re-measure the best 3 measured counts for 3 intervals each. When the best count uses SMT siblings, the physical-core count is re-measured too |
| `--metis_model_moves`, `--metis_refine_moves` | 5, 4 | Budget of model-predicted moves and of local-refinement moves after a (re)start |
| `--metis_change_tps`, `--metis_change_abort`, `--metis_change_intervals` | 0.20, 0.10, 2 | Workload-change detection while holding |
| `--ada_tam_enable`, `--ada_tam_step` | false, 2 | AdaTAM and its step (paper: TPC-C 8, YCSB 4) |
| `--tam_fixed_threads` | 0 | Run only the first N workers (oracle) |
| `--tam_update_period_us` | 100000 | Control period |
| `--tpcc_active_warehouse_schedule` | | In-run W changes, e.g. `0:16,20:1,40:4` |
| `--ycsb_skew_change_*`, `--ycsb_zipf_skew2/3` | | In-run skew changes (two at most) |
| `--tpcc_pin_order`, `--ycsb_pin_order` | socket0_first | `physical_first`: one thread per physical core (socket 0, then socket 1), then the SMT siblings |

## Recorded results

| Path | Contents |
|---|---|
| `<bench>/oracle/results.csv` | TPS for each state, fixed N, and run (TPC-C: 2-step points around each best N added) |
| `<bench>/train/` | Model statistics of each training run |
| `<bench>/models/` | `all.txt` and `loo_<state>.txt` (pooled from `train/`) |
| `<bench>/compare_fixed/` | Fixed load, all methods: `results.csv` (TPS, abort rate, settled N), `summary.csv`, logs |
| `<bench>/dynamic/` | Dynamic load: `results.csv`, `convergence_summary.csv` (reach time, loss per phase), logs |
| `paper_figures/` | Figures of the paper (`make_figures.sh` regenerates them from the files above) |

The recorded results were produced before this directory was cleaned up for
publication (commit 8de261ce, with the same controller under the names
`metis_v2` and `--metis_v2_*`). The `config.txt` files and the logs still
show those names. The method `metis_v2` was renamed to `metis` in the CSV
files and log names, and the model headers were converted to the current
format.
