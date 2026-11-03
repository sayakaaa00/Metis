# MySQL 8.4 + BenchBase phase 1

This directory records the unmodified-MySQL baseline environment used before
adding the Metis admission controller.

## Fixed versions

- MySQL: `mysql-8.4.11`, commit `99960bf74fa919347e4f4e3ca47672f333d6e91f`
- BenchBase: commit `33c00473807ebd49304d114a6d769d2d2b2bbb34`
- Java runtime and BenchBase target: OpenJDK 25
- MySQL build type: `Release` (`-O3 -DNDEBUG`)

The external sources, build output, data, logs, and results live under
`/home/ubuntu/metis-mysql-lab/`. They are intentionally separate from CCBench.

## Layout

```text
/home/ubuntu/metis-mysql-lab/
  mysql-server/           unmodified MySQL source
  mysql-build-baseline/   Release build and executables
  mysql-data-baseline/    baseline data directory
  benchbase/              BenchBase source
  benchbase-run/          unpacked MySQL-profile distribution
  config/                 active MySQL configuration
  log/                    MySQL error log
  results/                BenchBase results
```

## Server control

Start:

```bash
/home/ubuntu/metis-mysql-lab/mysql-build-baseline/runtime_output_directory/mysqld \
  --defaults-file=/home/ubuntu/metis-mysql-lab/config/my-baseline.cnf \
  --daemonize
```

Check:

```bash
/home/ubuntu/metis-mysql-lab/mysql-build-baseline/runtime_output_directory/mysqladmin \
  --socket=/home/ubuntu/metis-mysql-lab/run/mysql-baseline.sock \
  -uroot ping
```

Stop cleanly:

```bash
/home/ubuntu/metis-mysql-lab/mysql-build-baseline/runtime_output_directory/mysqladmin \
  --socket=/home/ubuntu/metis-mysql-lab/run/mysql-baseline.sock \
  -uroot shutdown
```

The server listens only on `127.0.0.1:3307`.

## Rebuild BenchBase

The ccbench-compatible multi-operation YCSB extension is recorded in
`experiments/mysql/benchbase-ycsb-ccbench.patch`. On a fresh BenchBase checkout,
apply it before building:

```bash
git -C /home/ubuntu/metis-mysql-lab/benchbase apply \
  /home/ubuntu/ccbench-adaTAM/experiments/mysql/benchbase-ycsb-ccbench.patch

cd /home/ubuntu/metis-mysql-lab/benchbase
JAVA_HOME=/usr/lib/jvm/java-25-openjdk-amd64 \
  ./mvnw -Dfmt.skip=true -DskipTests \
  -Dmaven.compiler.source=25 -Dmaven.compiler.target=25 package -P mysql

cp target/benchbase-2023-SNAPSHOT-mysql.jar \
  /home/ubuntu/metis-mysql-lab/benchbase-run/benchbase.jar
```

`fmt` is skipped because the pinned formatting plugin is incompatible with
JDK 25. This does not change BenchBase runtime code.

## TPC-C smoke test

The smoke configuration is `tpcc-smoke.xml`: scale factor 1, four terminals,
30 seconds, unlimited request rate, and repeatable-read isolation.

```bash
cd /home/ubuntu/metis-mysql-lab/benchbase-run

java -jar benchbase.jar -b tpcc -c config/mysql/tpcc-smoke.xml \
  --create=true --load=false --execute=false

java -jar benchbase.jar -b tpcc -c config/mysql/tpcc-smoke.xml \
  --create=false --load=true --execute=false

java -jar benchbase.jar -b tpcc -c config/mysql/tpcc-smoke.xml \
  --create=false --load=false --execute=true \
  -d /home/ubuntu/metis-mysql-lab/results/tpcc-smoke -im 1000
```

Do not rerun `--create=true` or `--load=true` before an ordinary measurement.
Those options recreate or append benchmark state; use them only when preparing
a fresh data directory/database.

## First verified result

- DBMS: MySQL 8.4.11
- Measured requests: 35,467
- Throughput: 1,144.10 requests/s
- Median latency: 2.850 ms
- p95 latency: 6.503 ms
- p99 latency: 10.207 ms
- Unexpected SQL errors: 0

This is a connectivity and correctness smoke test, not the final performance
baseline. A final baseline needs a larger scale factor, an explicit warm-up,
longer measurements, system telemetry, and repeated runs.

## Fixed `innodb_thread_concurrency` sweep

`run_thread_concurrency_sweep.sh` uses four warehouses and 96 terminals
(about 24 terminals per warehouse), creating high contention without the
single-warehouse extreme. It sweeps `0 8 16 24 32 48 64 96`; each point gets
a 30-second warm-up and a 60-second measurement. By default it recreates and
loads scale factor 4 before every measured point, preventing TPC-C table growth
and execution order from biasing later settings. It collects results into
`summary.csv` and restores the limit to zero after success or failure.

```bash
./experiments/mysql/run_thread_concurrency_sweep.sh
```

Repeat every point three times with:

```bash
REPEATS=3 ./experiments/mysql/run_thread_concurrency_sweep.sh
```

For a quick but order-biased exploratory run, reuse the database with
`RESET_EACH_POINT=0`. In that mode, `PREPARE=1` forces one fresh load before
the complete sweep and `PREPARE=auto` loads only when scale factor 4 is absent.

Results go to `/home/ubuntu/metis-mysql-lab/results/thread-concurrency-sweep/`.

## Hot-item contention sweep

The BenchBase TPC-C generator in the lab also accepts `hot_item_ratio`,
`hot_item_count`, and `hot_supply_warehouse_count`. Run the requested
96-warehouse workload with one command:

```bash
./experiments/mysql/run_hot_contention_sweep.sh
```

It uses 96 terminals, 10 hot items, one hot supply warehouse, and a 0.70 hot
selection probability. Because scale factor 96 contains about 9.6 million
stock rows, it loads once and reuses the database across sweep points.

For the stronger 192-terminal condition (`hot_item_ratio=0.80`,
`hot_item_count=5`), run:

```bash
./experiments/mysql/run_hot_contention_192t_sweep.sh
```

Its results are written under
`/home/ubuntu/metis-mysql-lab/results/hot-contention-192t-thread-sweep/`.

This wrapper pre-warms for 60 seconds, measures two repetitions, and reverses
the limit order in repetition 2. Its default limits extend above the 96 CPUs:
`0 16 32 48 64 80 96 112 128 160 192`. `aggregate.csv` reports the mean and
standard deviation for each limit.

With the five-item hot set, a long reused-database run can drive TPC-C's
`stock.s_ytd DECIMAL(8,2)` field to its maximum and cause NewOrder SQL errors.
The common sweep script now records this error count and stops by default if it
is nonzero. Do not disable that check for performance results. A correctness-
first rerun can recreate scale factor 96 before every point, although it is
slow:

```bash
RESET_EACH_POINT=1 ./experiments/mysql/run_hot_contention_192t_sweep.sh
```

Restoring a prepared database snapshot before each point is the preferred
faster follow-up.

## ccbench-compatible YCSB skew and concurrency sweep

`run_ycsb_skew_thread_sweep.sh` uses the same logical defaults as the ccbench
YCSB experiments:

- 10,000 tuples (`SCALE_FACTOR=10`; BenchBase creates 1000 rows per unit)
- 10 point operations in one database transaction
- each operation is independently a 50% read or 50% blind update
- 30 measured seconds per point
- Zipf skews 0.70, 0.80, 0.90, and 0.95
- 192 client terminals

The stock BenchBase YCSB implementation commits after every one operation. The
local BenchBase patch adds `operationsPerTransaction` and `readRatio`, so all ten
operations execute on one JDBC connection and are committed together. This
matches the transaction boundary used by ccbench with `ycsb_max_ope=10`,
`ycsb_rratio=50`, and `ycsb_rmw=false`. MySQL row representation and logging
overheads remain DBMS-specific, so this is logical workload equivalence rather
than byte-for-byte storage equivalence.

Run the full sweep with:

```bash
./experiments/mysql/run_ycsb_skew_thread_sweep.sh
```

The default limits are
`0 8 16 24 32 48 64 80 96 112 128 160 192`, with two repetitions.
Repetition 1 is ascending and repetition 2 is descending. Every point has a
30-second warm-up followed by a 30-second measurement.

YCSB reads do not change the table. Blind updates replace the ten payload fields
with new random values, but this workload performs no insert or delete: the
10,000 primary keys and the Zipf key-selection probabilities stay unchanged.
Execution order can still affect MySQL physical state, including buffer-pool
temperature, dirty pages, redo/undo generation, purge/checkpoint work, and CPU
frequency. Balanced order is therefore retained as a low-cost control, even
though logical data-value drift does not change which keys are selected.

Results are written below
`/home/ubuntu/metis-mysql-lab/results/ycsb-skew-thread-sweep/<run-id>/`:

- `summary.csv`: every individual measurement
- `aggregate.csv`: mean and standard deviation for each skew/limit pair
- `best_by_skew.csv`: the highest mean-TPS limit for each skew
- `metadata.txt`: exact workload and version settings
- `skew-*/repeat-*/limit-*/`: BenchBase output, logs, and sampled server state

`PREPARE=auto` recreates and reloads the table when the existing row count is not
10,000. Use `PREPARE=1` to force a fresh initial table. Other settings can be
overridden, for example:

```bash
REPEATS=5 OPERATIONS_PER_TRANSACTION=10 READ_RATIO=50 \
  ./experiments/mysql/run_ycsb_skew_thread_sweep.sh
```
