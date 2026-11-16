# Metis: learned control of the number of active worker threads

This directory holds the experiment scripts, the trained models, and the figure
scripts of the Metis paper. The measured results are in the submodule
[data/](../../data) ([sayakaaa00/Metis-data](https://github.com/sayakaaa00/Metis-data)),
and `figures/make_figures.sh` regenerates the paper's figures from them; the output matches the paper's figures pixel for pixel. Metis runs on CCBench's Silo. The benchmark
spawns a fixed set of workers (96 here), and only the first N of them run
transactions. Metis picks N from {6, 8, ..., 96} (`--metis_min_count`) using one linear model of the
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
| [include/backoff.hh](../../include/backoff.hh) | Backoff of the Silo, Cicada, and ERMIA baselines: adaptive (hill climbing on the duration, optionally randomized as in Cicada) or fixed, with optional doubling per consecutive abort |
| [include/ycsb_skew_schedule.hh](../../include/ycsb_skew_schedule.hh) | In-run skew changes and throughput log for the Cicada and ERMIA YCSB binaries |

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
| `silo/ycsb_silo_breakdown` | Silo without backoff, plus a `[BREAKDOWN]` line: worker time on committed and aborted transactions and time spent waiting on locked records (`METIS_BREAKDOWN`) |
| `cc/{cicada,ermia}/{ycsb,tpcc}_*.exe` | Cicada, ERMIA |

## Reproducing the experiments

```sh
git submodule update --init data           # measured results (Metis-data)
experiments/metis/build.sh
experiments/metis/figures/make_figures.sh  # figures from data/ -> experiments/metis/paper_figures
```

The experiment scripts write to `$METIS_OUT` (default `results/`) in the same
layout as `data/`, so `METIS_DATA=results experiments/metis/figures/make_figures.sh`
plots new runs. Each run is appended to a results CSV, and a script skips runs
that are already recorded, so an interrupted script resumes where it stopped.
Metis uses the paper's models in [models/](models) unless `--models` points at
models trained with `train.py`.

| Experiment (paper) | Command | Output (`$METIS_OUT/...`, same as `data/...`) | Runs |
|---|---|---|---|
| Oracle: throughput of every fixed active thread count | `oracle.py --bench ycsb` / `--bench tpcc` | `<bench>/oracle/` | levels × N grid × 2 × 10 s |
| Training runs and models | `train.py run --bench B --set min6`, then `train.py merge --bench B --set min6` | `<bench>/train/<set>/`, `<bench>/models/<set>/` | levels × 2 × 30 s |
| Static workloads: all methods | `fixed.py --bench ycsb` / `--bench tpcc` | `<bench>/fixed/` | 6 methods × levels × 2 × 10 s / 30 s (ERMIA on TPC-C: 3 s) |
| Hill climbing with per-period samples (YCSB) | `fixed.py --bench ycsb --hill-climbing-trace --states 0,0.8,0.9,0.95,0.99,0.999` | `ycsb/hill_climbing_10ms_log/` | 6 × 2 × 10 s |
| Dynamic workloads D1 / Y1 | `dynamic.py throughput --bench tpcc` / `--bench ycsb` | `<bench>/dynamic/` | 5 methods × 2 × 60 s |
| Dynamic workloads D11 / Y4 (hill climbing) | `dynamic.py hill_climbing --bench tpcc` / `--bench ycsb` | `<bench>/dynamic_hill_climbing/` | 2 methods × 2 × 60 s |
| Fixed backoff duration | `backoff.py constant --bench ycsb` / `--bench tpcc` | `<bench>/backoff_constant/` | levels × durations × 2 × 10 s |
| Exponential backoff (YCSB) | `backoff.py exponential` | `ycsb/backoff_exponential/` | 5 skews × 11 durations × 2 × 10 s |
| Silo-BO setting | `backoff.py tune --bench ycsb` / `--bench tpcc` | `<bench>/backoff_adaptive_tuning/` | 16 settings × 3 levels × 10 s |
| Time breakdown (YCSB) | `breakdown.py` | `ycsb/breakdown/` | 10 × 2 × 10 s |
| Figures | `figures/make_figures.sh` | `paper_figures/` (`$METIS_FIG_OUT`) | seconds |

TPC-C runs also load the 96-warehouse database first. Contention levels: TPC-C
`W` = 1, 2, 3, 4, 8, 16, 32, 96 (the transaction's home warehouse is drawn from
the first `W` of 96 warehouses); YCSB Zipf skew 0, 0.5, 0.7, 0.8, 0.85, 0.9,
0.95, 0.99, 0.999. Static runs evaluate each level with the leave-one-out model
`loo_<level>.txt`; dynamic runs use `all.txt`.

The paper's Metis runs used two model sets ([models/](models), converted from
`data/<bench>/models`): `min8` (candidates 8..96) for static TPC-C and for D1/Y1,
and `min6` (candidates 6..96; YCSB trained on all nine skews) for static YCSB and
for D11/Y4. The scripts pick these by default and pass the matching
`--metis_min_count`.

A single run, for example Metis on TPC-C with W = 4:

```sh
LD_PRELOAD=build_release/mimalloc_override/libmimalloc.so \
build_release/silo/tpcc_silo_nobackoff --thread_num=96 --tpcc_num_wh=96 \
  --tpcc_active_warehouse_count=4 --tpcc_home_warehouse_assignment=random_per_transaction \
  --tpcc_pin_order=physical_first --extime=30 --clocks_per_us=2900 \
  --tam_update_period_us=200000 --tam_log_active_threads=true \
  --metis_enable=true --metis_min_count=8 --metis_model_path=experiments/metis/models/tpcc/min8/loo_4.txt
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
| `--metis_min_count` | 6 | Smallest candidate count (candidates: even counts from this to 96) |
| `--metis_recheck`, `--metis_recheck_intervals` | 3, 3 | Before committing, re-measure the best 3 measured counts for 3 intervals each |
| `--metis_recheck_physical` | true | When the best count uses SMT siblings, also re-measure the physical-core count |
| `--metis_model_moves`, `--metis_refine_moves` | 5, 4 | Budget of model-predicted moves and of local-refinement moves after a (re)start |
| `--metis_change_tps`, `--metis_change_abort`, `--metis_change_intervals` | 0.20, 0.10, 2 | Workload-change detection while holding |
| `--ada_tam_enable`, `--ada_tam_step` | false, 2 | AdaTAM and its step (paper: TPC-C 8, YCSB 4) |
| `--tam_fixed_threads` | 0 | Run only the first N workers (oracle) |
| `--backoff_update_period_us`, `--backoff_step_us` | 5000, 0.5 | Adaptive backoff: update period and step of the duration |
| `--backoff_randomized` | false | Wait a random duration in [0, current duration] and pick a random direction when the gradient is zero (Cicada) |
| `--backoff_adaptive_exponential` | false | Adaptive backoff: double the wait per consecutive abort |
| `--backoff_fixed_enable`, `--backoff_fixed_us`, `--backoff_fixed_exponential` | false, 0, true | Fixed backoff duration, doubled per consecutive abort unless `--backoff_fixed_exponential=false` |
| `--tam_update_period_us` | 100000 | Control period |
| `--tpcc_active_warehouse_schedule` | | In-run W changes, e.g. `0:16,20:1,40:4` |
| `--ycsb_skew_change_*`, `--ycsb_zipf_skew2/3` | | In-run skew changes (two at most) |
| `--tpcc_pin_order`, `--ycsb_pin_order` | socket0_first | `physical_first`: one thread per physical core (socket 0, then socket 1), then the SMT siblings |

## Files

| Path | Contents |
|---|---|
| `common.py` | Binaries, contention levels, the command line of every method (Silo-BO setting, Cicada/ERMIA backoff), running one benchmark |
| `oracle.py`, `train.py`, `fixed.py`, `dynamic.py`, `backoff.py`, `breakdown.py` | Experiment scripts (table above) |
| `merge_models.py` | Pools training runs into a model (also reads the headers of the files in `data/`) |
| `models/<bench>/{min8,min6}/` | The models used in the paper |
| `figures/` | One script per figure (`figcommon.py`: data paths and oracle curves), `make_figures.sh` |

The figures that the paper splits into one PDF per benchmark, and the MySQL
figures, are made in
[Tatzhiro/MySQL-Metis-experiments](https://github.com/Tatzhiro/MySQL-Metis-experiments)
(submodule `experiments/mysql`).

## Known issue: Cicada stalls under extreme contention

Cicada sometimes stops committing shortly after the start of a run at the
highest contention levels (TPC-C `W` = 1, YCSB skew 0.99 and above). On the
evaluation machine, 4 of 12 10-s runs of TPC-C `W` = 1 committed almost
nothing (about 10 txn/s instead of about 24,000). This happened in the binaries
built from the code used for the paper measurements and from this repository
alike. The paper's dynamic YCSB figure uses Cicada run 2 because run 1 stopped
committing at 38 s. Check `commit_counts_` in the Cicada logs when re-running.
