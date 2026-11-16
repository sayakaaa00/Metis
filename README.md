# Metis: Machine Learning Based Dynamic Thread Control for High-Contention Transaction Processing

This repository contains the code, experiment scripts, and figure scripts of the
Metis paper.

**Metis** selects the best number of active worker threads at runtime for
in-memory databases under high contention, without changing the concurrency
control protocol.

- One linear model, trained offline, predicts the relative throughput of every
  candidate count from the abort rate and the current count.
- The same model serves every contention level, including ones not seen in
  training.
- At runtime, Metis jumps to the predicted best count, refines it with a few
  measurements, and holds it until the workload changes.

Metis is implemented on Silo in [CCBench](#built-on-ccbench). It is evaluated on
YCSB and TPC-C against Silo, Silo with adaptive backoff (Silo-BO), Cicada,
ERMIA, and hill climbing on the active thread count.

## Repository layout

```
metis/          Metis: controller, thread throttling, control loop (see metis/README.md)
experiments/    reproducing the paper (see experiments/README.md)
  run/          experiment scripts
  figures/      figure scripts
  models/       Metis models used in the paper
  data/         submodule Metis-data: measured results of the paper (per-run logs and CSVs)
  paper_figures/  figures made from data/
  mysql/        submodule MySQL-Metis-experiments: Metis in MySQL (InnoDB)
ccbench/        CCBench, the benchmark Metis is built on (Silo, Cicada, ERMIA, YCSB, TPC-C, ...)
build.sh        builds the binaries used by the experiments
```

| Start here | Contents |
|---|---|
| [metis/metis.hh](metis/metis.hh) | Metis: features, the shared linear model, offline training, and the runtime search |
| [metis/README.md](metis/README.md) | How Metis plugs into the benchmark, the files of `metis/`, and the options |
| [experiments/README.md](experiments/README.md) | Reproducing the paper: setup, figures, experiment commands, settings |

## Quick start

Requirements: x86-64 Linux, GCC 13, CMake, and Python 3 with matplotlib
(Ubuntu 24.04; see [ccbench/docs/build_en.md](ccbench/docs/build_en.md)).

```sh
git clone --recurse-submodules https://github.com/sayakaaa00/Metis.git
cd Metis
./build.sh                           # build the binaries
experiments/figures/make_figures.sh  # paper figures from the measured results
```

`make_figures.sh` reads the measured results in
[experiments/data/](experiments/data) and writes the figures to
`experiments/paper_figures/`. They match the figures in the paper pixel for pixel.

A single run of Metis on TPC-C with 4 accessed warehouses (96 worker threads):

```sh
LD_PRELOAD=build_release/mimalloc_override/libmimalloc.so \
build_release/silo/tpcc_silo_nobackoff --thread_num=96 --tpcc_num_wh=96 \
  --tpcc_active_warehouse_count=4 --tpcc_home_warehouse_assignment=random_per_transaction \
  --tpcc_pin_workers=true --tpcc_pin_order=physical_first --extime=30 --clocks_per_us=2900 \
  --throttle_period_us=200000 --throttle_log_active_threads=true \
  --metis_enable=true --metis_min_count=8 \
  --metis_model_path=experiments/models/tpcc/min8/loo_4.txt
```

## License

- **Metis** (everything outside `ccbench/`): Apache License 2.0,
  Copyright 2026 Sayaka Tayama. See [LICENSE](LICENSE).
- **CCBench** (`ccbench/`): Apache License 2.0, Copyright 2019 Takayuki Tanabe.
  See [ccbench/LICENSE](ccbench/LICENSE).
- The submodules [experiments/data](experiments/data) and
  [experiments/mysql](experiments/mysql) are separate repositories with their
  own terms.

The following CCBench files were modified for Metis (thread throttling in the
Silo entry points, in-run workload changes, the backoff of the baselines, the
TPC-C and YCSB workloads, and the benchmark runner); the changes are in the
git history of this repository:

- `ccbench/cc/silo/`: `CMakeLists.txt`, `include/transaction.hh`, `transaction.cc`, `tpcc_silo.cc`, `ycsb_silo.cc`
- `ccbench/cc/cicada/`: `transaction.cc`, `tpcc_cicada.cc`, `ycsb_cicada.cc`
- `ccbench/cc/ermia/`: `include/transaction.hh`, `include/tuple.hh`, `include/version.hh`, `transaction.cc`, `util.cc`, `tpcc_ermia.cc`, `ycsb_ermia.cc`
- `ccbench/cc/{d2pl,mocc,mvto,oze,si,ss2pl,tictoc}/transaction.cc`
- `ccbench/common/`: `runner.hh`, `util.cc`
- `ccbench/include/`: `backoff.hh`, `cpu.hh`, `tpcc.hh`, `ycsb.hh`, `tpcc/tpcc_common.hh`, `tpcc/tpcc_initializer.hh`, `tpcc/tpcc_query.hh`, `tpcc/tpcc_tx_delivery.hh`, `tpcc/tpcc_tx_neworder.hh`
- Added: `ccbench/include/ycsb_skew_schedule.hh`, `ccbench/include/tpcc/warehouse_schedule.hh` (in-run workload changes for Cicada and ERMIA)

## Built on CCBench

This repository is a fork of [CCBench](https://github.com/thawk105/ccbench); the CCBench tree is in [ccbench/](ccbench).
CCBench re-implements major in-memory concurrency control protocols on a common
substrate so that they can be compared on identical workloads
([Tanabe et al., VLDB 2020][1]). It includes Silo, MOCC, Cicada, ERMIA, TicToc,
Oze, SI, SS2PL, MVTO, and D2PL, with the YCSB, TPC-C, and BoMB workloads.
TPC-C and BoMB were contributed by [@jnmt](https://github.com/jnmt).

- [ccbench/docs/architecture_en.md](ccbench/docs/architecture_en.md): repository overview, TxExecutor API, GC rules
- [ccbench/docs/build_en.md](ccbench/docs/build_en.md): host and devcontainer build
- [ccbench/docs/workloads_en.md](ccbench/docs/workloads_en.md), [ccbench/docs/protocols_en.md](ccbench/docs/protocols_en.md): workloads and protocols
- [ccbench/docs/runtime-args_en.md](ccbench/docs/runtime-args_en.md): runtime flags
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
