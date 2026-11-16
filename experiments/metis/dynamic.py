#!/usr/bin/env python3
"""Dynamic workloads: the contention level changes twice during a 60-s run.

  dynamic.py throughput    --bench tpcc|ycsb [--schedules D1] [--methods ...] [--runs 2]
  dynamic.py hill_climbing --bench tpcc|ycsb [--schedules D11] [--runs 2]
  (both: [--model-set min8|min6] [--models DIR] [--extime 60])

TPC-C schedules change the number of accessed warehouses W ("seconds:W,...");
YCSB schedules change the Zipf skew ("skew0,t1:skew1,t2:skew2"). Metis uses the
model trained on all levels (all.txt). Every run logs the throughput of each
200-ms interval. The method order is reversed on even runs.

throughput:    Metis, Silo-BO, Silo, Cicada, ERMIA on D1 (TPC-C) / Y1 (YCSB).
               Paper models: min8.  -> $METIS_OUT/<bench>/dynamic/
               (results.csv; Metis in results_metis.csv; logs/)
hill_climbing: Metis and hill climbing on D11 (TPC-C) / Y4 (YCSB). Paper models:
               min6. On YCSB, the active thread count is sampled every 10-ms
               control period and Metis runs without the physical-core
               re-measurement (--metis_recheck_physical=false, method
               metis_norephys).  -> $METIS_OUT/<bench>/dynamic_hill_climbing/
"""
import argparse
import subprocess

import common as C

TPCC_SCHEDULES = {"D1": "0:16,20:1,40:4", "D11": "0:2,20:8,40:1"}
YCSB_SCHEDULES = {"Y1": "0.7,20:0.95,40:0.8", "Y4": "0.99,20:0.5,40:0.95"}
SETS = {
    "throughput": {"dir": "dynamic", "models": "min8", "sched": {"tpcc": "D1", "ycsb": "Y1"},
                   "methods": ["metis", "silo_cbo_tuned", "silo_nobo", "cicada", "ermia"]},
    "hill_climbing": {"dir": "dynamic_hill_climbing", "models": "min6", "sched": {"tpcc": "D11", "ycsb": "Y4"},
                      "methods": ["metis", "hill_climbing"]},
}
HEADER = ["schedule", "method", "run", "tps", "abort_rate"]


def phases(bench, sched):
    """[(start second, level)] of a schedule."""
    if bench == "tpcc":
        return [(int(x.split(":")[0]), x.split(":")[1]) for x in sched.split(",")]
    p = sched.split(",")
    return [(0, p[0])] + [(int(x.split(":")[0]), x.split(":")[1]) for x in p[1:]]


def argv_for(bench, method, schedule, extime, model, min_count):
    ph = phases(bench, schedule)
    argv, env = C.command(bench, method, ph[0][1], extime, model, min_count)
    if bench == "tpcc":
        argv += [f"--tpcc_active_warehouse_schedule={schedule}"]
    else:
        (t1, s1), (t2, s2) = ph[1], ph[2]
        argv += ["--ycsb_skew_change_enable=true", f"--ycsb_zipf_skew2={s1}",
                 f"--ycsb_skew_change_time_sec={t1}", "--ycsb_skew_change_enable2=true",
                 f"--ycsb_zipf_skew3={s2}", f"--ycsb_skew_change_time_sec2={t2}"]
    return argv + ["--benchmark_interval_tps_log_us=200000"], env


def main():
    p = argparse.ArgumentParser()
    p.add_argument("set", choices=list(SETS))
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=60)
    p.add_argument("--schedules", default="")
    p.add_argument("--methods", default="")
    p.add_argument("--model-set", choices=list(C.MIN_COUNT), default=None)
    p.add_argument("--models", default=None, help="directory with all.txt (default: paper models)")
    args = p.parse_args()
    cfg = SETS[args.set]
    table = TPCC_SCHEDULES if args.bench == "tpcc" else YCSB_SCHEDULES
    names = args.schedules.split(",") if args.schedules else [cfg["sched"][args.bench]]
    methods = args.methods.split(",") if args.methods else cfg["methods"]
    model_set = args.model_set or cfg["models"]
    model = C.model_path(args.bench, model_set, "all", args.models)
    out = C.OUT / args.bench / cfg["dir"]
    for m in methods:
        C.write_config(out, args, argv_for(args.bench, m, table[names[0]], args.extime, model,
                                           C.MIN_COUNT[model_set])[0])
    for run in range(1, args.runs + 1):
        order = methods if run % 2 else list(reversed(methods))
        for n in names:
            for m in order:
                name = m
                argv, env = argv_for(args.bench, m, table[n], args.extime, model, C.MIN_COUNT[model_set])
                if args.set == "hill_climbing" and args.bench == "ycsb":
                    argv += ["--tam_log_period_us=10000"]
                    if m == "metis":
                        argv += ["--metis_recheck_physical=false"]
                        name = "metis_norephys"
                res = out / ("results_metis.csv" if m == "metis" and args.set == "throughput" else "results.csv")
                if (n, name, str(run)) in C.done_keys(res, ["schedule", "method", "run"]):
                    continue
                try:
                    tps, abort, _ = C.run_one(argv, env, out / "logs" / f"{n}_{name}_run{run}.log")
                except subprocess.CalledProcessError as e:
                    C.append(res, HEADER, [n, name, run, "", f"failed_rc{e.returncode}"])
                    continue
                C.append(res, HEADER, [n, name, run, f"{tps:.0f}", abort])
                print(f"{args.bench} {n} {name} run={run} tps={tps:,.0f}", flush=True)


if __name__ == "__main__":
    main()
