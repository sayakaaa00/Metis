#!/usr/bin/env python3
"""Dynamic-load comparison: Metis (all-state model), adaTAM, Silo with and
without backoff, under in-run workload changes.

  dynamic.py --bench tpcc|ycsb [--schedules D1,D2] [--runs 2] [--extime 60]

TPC-C schedules change the active home-warehouse count W (seconds:W);
YCSB schedules change the Zipf skew (skew0,t1:skew1,t2:skew2). Each run lasts
60 s; 2 runs, method order reversed on run 2. Interval TPS is logged every
200 ms. Output: <bench>/dynamic/results.csv and logs/.
"""
import argparse
import csv
import subprocess

import common as C

TPCC_SCHEDULES = {
    "D1": "0:16,20:1,40:4",
    "D2": "0:2,20:96,40:3",
    "D3": "0:1,10:32,20:3,30:96,40:4,50:16",
    "D4_5s": ",".join(f"{t}:{1 if (t // 5) % 2 == 0 else 32}" for t in range(0, 60, 5)),
    "D4_2s": ",".join(f"{t}:{1 if (t // 2) % 2 == 0 else 32}" for t in range(0, 60, 2)),
    # No W=96; best N alternates far: 48 -> 6 -> 48 -> 16 -> 48 -> 20.
    "D5": "0:32,10:1,20:16,30:2,40:8,50:3",
}
YCSB_SCHEDULES = {"Y1": "0.7,20:0.95,40:0.8", "Y2": "0.99,20:0.7,40:0.9"}
METHODS = ["metis", "adatam", "silo_bo", "silo_nobo"]


def schedules(bench):
    return TPCC_SCHEDULES if bench == "tpcc" else YCSB_SCHEDULES


def phases(bench, sched):
    """[(start second, state)] of a schedule."""
    if bench == "tpcc":
        return [(int(x.split(":")[0]), x.split(":")[1]) for x in sched.split(",")]
    p = sched.split(",")
    return [(0, p[0])] + [(int(x.split(":")[0]), x.split(":")[1]) for x in p[1:]]


def argv_for(bench, method, schedule, extime):
    ph = phases(bench, schedule)
    argv, env = C.command(bench, method, ph[0][1], extime)
    if method == "metis":
        argv = [f"--metis_model_path={C.HERE / bench / 'models' / 'all.txt'}"
                if a.startswith("--metis_model_path=") else a for a in argv]
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
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=60)
    p.add_argument("--schedules", default="")
    p.add_argument("--methods", default=",".join(METHODS))
    args = p.parse_args()
    table = schedules(args.bench)
    names = args.schedules.split(",") if args.schedules else list(table)
    methods = args.methods.split(",")
    out = C.HERE / args.bench / "dynamic"
    out.mkdir(parents=True, exist_ok=True)
    with (out / "config.txt").open("a") as f:
        f.write(f"extime={args.extime} runs={args.runs} methods={methods}\n")
        for n in names:
            f.write(f"{n}={table[n]}\n")
    res = out / "results.csv"
    done = set()
    if res.exists():
        with res.open() as f:
            done = {(r["schedule"], r["method"], r["run"]) for r in csv.DictReader(f)}
    else:
        res.write_text("schedule,method,run,tps,abort_rate\n")
    for run in range(1, args.runs + 1):
        order = methods if run % 2 else list(reversed(methods))
        for n in names:
            for m in order:
                if (n, m, str(run)) in done:
                    continue
                argv, env = argv_for(args.bench, m, table[n], args.extime)
                log = out / "logs" / f"{n}_{m}_run{run}.log"
                try:
                    tps, abort, _ = C.run_one(argv, env, log)
                except subprocess.CalledProcessError as e:
                    with res.open("a") as f:
                        f.write(f"{n},{m},{run},,failed_rc{e.returncode}\n")
                    continue
                with res.open("a") as f:
                    f.write(f"{n},{m},{run},{tps:.0f},{abort}\n")
                print(f"{args.bench} {n} {m} run={run} tps={tps:,.0f}", flush=True)


if __name__ == "__main__":
    main()
