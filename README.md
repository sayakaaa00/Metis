# Metis: Machine Learning Based Dynamic Thread Control for High-Contention Transaction Processing

This repository contains the code, experiment scripts, and figure scripts of the
Metis paper.

In-memory databases lose throughput at high contention, where many transactions
access the same records. Thread throttling limits how many worker threads run
transactions. The best active thread count, however, depends on the contention
level and changes with the workload. **Metis** selects the best active thread
count at runtime without changing the concurrency control protocol.

- Metis treats the choice as a contextual bandit problem. The context is the
  abort rate and the current active thread count.
- One linear model, shared by all candidate counts and trained offline,
  predicts the throughput ratio of every candidate. One model therefore serves
  all contention levels, including ones not seen in training.
- At runtime, Metis jumps to the predicted best count, refines it with a few
  averaged measurements, and holds it until the workload changes.

Metis is implemented on Silo in [CCBench](#built-on-ccbench). It is evaluated on
YCSB and TPC-C against Silo, Silo with adaptive backoff (Silo-BO), Cicada,
ERMIA, and hill climbing on the active thread count.

## Quick start

Requirements: x86-64 Linux, GCC 13, CMake, and Python 3 with matplotlib
(Ubuntu 24.04; see [docs/build_en.md](docs/build_en.md)).

```sh
git clone --recurse-submodules https://github.com/sayakaaa00/ccbench-Metis.git
cd ccbench-Metis
experiments/metis/build.sh                 # build the binaries
experiments/metis/figures/make_figures.sh  # paper figures from the measured results
```

`make_figures.sh` reads the measured results in [data/](data) and writes the
figures to `experiments/metis/paper_figures/`. They match the figures in the
paper pixel for pixel.

A single run of Metis on TPC-C with 4 accessed warehouses (96 worker threads):

```sh
LD_PRELOAD=build_release/mimalloc_override/libmimalloc.so \
build_release/silo/tpcc_silo_nobackoff --thread_num=96 --tpcc_num_wh=96 \
  --tpcc_active_warehouse_count=4 --tpcc_home_warehouse_assignment=random_per_transaction \
  --tpcc_pin_workers=true --tpcc_pin_order=physical_first --extime=30 --clocks_per_us=2900 \
  --tam_update_period_us=200000 --tam_log_active_threads=true \
  --metis_enable=true --metis_min_count=8 \
  --metis_model_path=experiments/metis/models/tpcc/min8/loo_4.txt
```

To re-run the paper's experiments, see
[experiments/metis/README.md](experiments/metis/README.md).

## Repository layout

| Path | Contents |
|---|---|
| [include/metis.hh](include/metis.hh) | Metis: features, linear model (ridge regression), offline training, and the runtime search (jump, local refinement, re-measurement, hold, workload-change detection) |
| [include/adatam.hh](include/adatam.hh) | Hill climbing on the active thread count (baseline) |
| [include/tam.hh](include/tam.hh), [include/adaptive_control.hh](include/adaptive_control.hh) | Thread throttling: controller selection, the control loop, and parking of inactive worker threads |
| [include/backoff.hh](include/backoff.hh) | Backoff of the baselines (Silo-BO, Cicada, ERMIA) |
| [cc/silo/](cc/silo) | Silo, with the YCSB and TPC-C entry points used for Metis |
| [experiments/metis/](experiments/metis) | Experiment scripts, the trained models, and the figure scripts |
| [data/](data) | Submodule [Metis-data](https://github.com/sayakaaa00/Metis-data): measured results (per-run logs and CSVs) |
| [experiments/mysql/](experiments/mysql) | Submodule [MySQL-Metis-experiments](https://github.com/Tatzhiro/MySQL-Metis-experiments): Metis in MySQL (InnoDB) |

## Built on CCBench

This repository is a fork of [CCBench](https://github.com/thawk105/ccbench).
CCBench re-implements major in-memory concurrency control protocols on a common
substrate so that they can be compared on identical workloads
([Tanabe et al., VLDB 2020][1]). It includes Silo, MOCC, Cicada, ERMIA, TicToc,
Oze, SI, SS2PL, MVTO, and D2PL, with the YCSB, TPC-C, and BoMB workloads.
TPC-C and BoMB were contributed by [@jnmt](https://github.com/jnmt).

- [docs/architecture_en.md](docs/architecture_en.md): repository overview, TxExecutor API, GC rules
- [docs/build_en.md](docs/build_en.md): host and devcontainer build
- [docs/workloads_en.md](docs/workloads_en.md), [docs/protocols_en.md](docs/protocols_en.md): workloads and protocols
- [docs/runtime-args_en.md](docs/runtime-args_en.md): runtime flags
- Original CCBench experimental data: <https://github.com/thawk105/ccdata>

CCBench's binaries build with `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`
and land at `build/cc/<protocol>/<workload>_<protocol>.exe`. A `linux/amd64`
devcontainer is in [.devcontainer/](.devcontainer/). Under emulation, such as
on Apple Silicon, it is fine for development but not for measurements.

### Acknowledgments (CCBench)

Takayuki Tanabe extends thanks to:

- Cybozu Labs Youth (8th term, 2018-04-10 – 2019-04-10) for supporting this work.
- Takashi Hoshino, advisor at Cybozu Labs Youth.
- Hideyuki Kawashima and Osamu Tatebe, supervisors.

### References

```
[1] Takayuki Tanabe, Takashi Hoshino, Hideyuki Kawashima, and Osamu Tatebe. 2020.
    An analysis of concurrency control protocols for in-memory databases with CCBench.
    Proc. VLDB Endow. 13, 13 (September 2020), 3531–3544.
    https://doi.org/10.14778/3424573.3424575
```

[1]: http://www.vldb.org/pvldb/vol13/p3531-tanabe.pdf
