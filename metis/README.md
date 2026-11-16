# Metis implementation

Metis is built into the Silo binaries of CCBench (`ccbench/cc/silo/`). The
benchmark starts a fixed number of worker threads, and only the first N of them
run transactions (thread throttling). A controller chooses N once per control
period.

```
worker thread i ──► gate: run a transaction only if i < N  (control_loop.hh → shared_state.hh)
                                     ▲
main thread: control loop ───────────┤ every control period:
  (control_loop.hh)                  │   commit/abort counts ──► controller ──► new N
                                     │
controller (thread_throttling.hh) = Metis (metis.hh)
                                  | hill climbing (hill_climbing.hh, baseline)
                                  | fixed N (oracle sweeps)
```

| File | Contents |
|---|---|
| [metis.hh](metis.hh) | Metis: features, the shared linear model (ridge regression), offline training (`--metis_learn`), and the runtime search: jump to the predicted best count, local refinement, re-measurement of the best counts, hold, workload-change detection |
| [hill_climbing.hh](hill_climbing.hh) | Hill climbing on the active thread count (baseline) |
| [thread_throttling.hh](thread_throttling.hh) | Chooses the controller (Metis, hill climbing, or a fixed N) and parks inactive worker threads |
| [control_loop.hh](control_loop.hh) | Runs on the main thread: the per-transaction gate of the worker threads, the control loop, and the controller log |
| [shared_state.hh](shared_state.hh) | State shared by the controllers, the control loop, and the workloads (active thread count, in-run workload changes) |

Changes inside CCBench that Metis relies on:

- `ccbench/cc/silo/{ycsb,tpcc}_silo.cc`: entry points with the control loop,
  physical-first CPU pinning, and in-run workload changes.
- `ccbench/include/tpcc.hh`: the gate before every retry, and in-run changes of
  the accessed warehouses.
- `ccbench/include/backoff.hh`: backoff of the baselines (Silo-BO, Cicada, ERMIA).
- `ccbench/include/ycsb_skew_schedule.hh`, `ccbench/include/tpcc/warehouse_schedule.hh`:
  in-run workload changes for Cicada and ERMIA (the baselines without thread throttling).

An inactive worker thread sleeps 50 µs per check (`--throttle_idle_sleep_us`)
and keeps announcing the current Silo epoch, so epoch advancement and garbage
collection continue.

## Main options

| Option | Default | Meaning |
|---|---|---|
| `--metis_enable` | false | Run Metis |
| `--metis_learn` | false | Training run: random counts; save the model to `--metis_model_path` |
| `--metis_model_path` | | Model to load (evaluation) or write (training) |
| `--metis_min_count` | 6 | Smallest candidate count (even counts from this to 96) |
| `--metis_model_moves`, `--metis_refine_moves` | 5, 4 | Budget of predicted jumps and of local-refinement moves per search |
| `--metis_recheck`, `--metis_recheck_intervals` | 3, 3 | Before holding, re-measure the best 3 counts for 3 control periods each |
| `--metis_recheck_physical` | true | When the best count uses SMT siblings, also re-measure the physical-core count |
| `--metis_change_tps`, `--metis_change_abort`, `--metis_change_intervals` | 0.20, 0.10, 2 | Workload-change detection while holding |
| `--hill_climbing_enable`, `--hill_climbing_step` | false, 2 | Hill climbing and its step |
| `--throttle_fixed_threads` | 0 | Run only the first N worker threads (oracle) |
| `--throttle_min_threads`, `--throttle_max_threads` | 1, 96 | Range of the active thread count |
| `--throttle_period_us` | 100000 | Control period |
| `--throttle_idle_sleep_us` | 50 | Sleep of an inactive worker thread per check |
| `--throttle_log_active_threads`, `--throttle_log_period_us` | false, 100000 | Write the controller log (`[Metis]` / `[HillClimbing]` decisions, `[Throttle sample]` active thread counts) to `logs/` |
