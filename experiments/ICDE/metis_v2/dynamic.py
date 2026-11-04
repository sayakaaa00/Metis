#!/usr/bin/env python3
"""Dynamic-load comparison: Metis v2-A (all-state model), adaTAM, Silo with and
without backoff, under in-run workload changes.

TPC-C schedules change the active home-warehouse count W (seconds:W);
YCSB schedules change the Zipf skew (skew0,t1:skew1,t2:skew2).
Each run lasts 60 s; 2 runs, method order reversed on run 2. Interval TPS is
logged every 200 ms. Output: experiments/ICDE/metis_v2/<bench>/dynamic/.
"""
import argparse
import csv
import subprocess

import compare as C

TPCC_SCHEDULES = {
    "D1": "0:16,20:1,40:4",
    "D2": "0:2,20:96,40:3",
    "D3": "0:1,10:32,20:3,30:96,40:4,50:16",
    "D4_5s": ",".join(f"{t}:{1 if (t // 5) % 2 == 0 else 32}" for t in range(0, 60, 5)),
    "D4_2s": ",".join(f"{t}:{1 if (t // 2) % 2 == 0 else 32}" for t in range(0, 60, 2)),
}
YCSB_SCHEDULES = {"Y1": "0.7,20:0.95,40:0.8", "Y2": "0.99,20:0.7,40:0.9"}
METHODS = ["metis_v2", "adatam", "silo_bo", "silo_nobo"]


def argv_for(bench, method, schedule, extime):
    if bench == "tpcc":
        first = schedule.split(",")[0].split(":")[1]
        argv, env = C.command(bench, method, first, extime)
        argv = [f"--tpcc_active_warehouse_schedule={schedule}"
                if a.startswith("--tpcc_active_warehouse_schedule=") else a for a in argv]
    else:
        parts = schedule.split(",")
        argv, env = C.command(bench, method, parts[0], extime)
        t1, s1 = parts[1].split(":")
        t2, s2 = parts[2].split(":")
        argv += ["--ycsb_skew_change_enable=true", f"--ycsb_zipf_skew2={s1}",
                 f"--ycsb_skew_change_time_sec={t1}", "--ycsb_skew_change_enable2=true",
                 f"--ycsb_zipf_skew3={s2}", f"--ycsb_skew_change_time_sec2={t2}"]
    if method == "metis_v2":
        model = C.HERE / bench / "A" / "models" / "all.txt"
        argv = [f"--linucb_model_path={model}" if a.startswith("--linucb_model_path=") else a
                for a in argv]
    return argv + ["--benchmark_interval_tps_log_us=200000"], env


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=60)
    p.add_argument("--schedules", default="")
    p.add_argument("--methods", default=",".join(METHODS))
    args = p.parse_args()
    table = TPCC_SCHEDULES if args.bench == "tpcc" else YCSB_SCHEDULES
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
