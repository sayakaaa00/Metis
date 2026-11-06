#!/usr/bin/env python3
"""Fixed-load comparison of Metis with adaTAM, Silo (with/without backoff),
Cicada, and ERMIA (common.py: command()).

  compare.py --bench tpcc [--runs 2] [--extime 30]
  compare.py --bench ycsb [--runs 2] [--extime 10]

Metis evaluates each state with its leave-one-out model (a model that has not
seen the state). The method order is reversed on even runs.
Output: <bench>/compare_fixed/results.csv and logs/.
"""
import argparse
import csv
import hashlib
import subprocess
from pathlib import Path

import common as C

METHODS = ["metis", "adatam", "silo_nobo", "silo_bo", "cicada", "ermia"]
# "adatam_default" (untuned step) is available via --methods.


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=None)
    p.add_argument("--methods", default=",".join(METHODS))
    p.add_argument("--states", default="")
    args = p.parse_args()
    extime = args.extime or (30 if args.bench == "tpcc" else 10)
    methods = args.methods.split(",")
    states = args.states.split(",") if args.states else C.STATES[args.bench]
    out = C.HERE / args.bench / "compare_fixed"
    out.mkdir(parents=True, exist_ok=True)
    with (out / "config.txt").open("a") as f:
        f.write(f"extime={extime} runs={args.runs} methods={methods} states={states}\n")
        for m in methods:
            argv, _ = C.command(args.bench, m, states[0], extime)
            f.write(f"{m}: {argv[0]} sha256={hashlib.sha256(Path(argv[0]).read_bytes()).hexdigest()}\n")
    res = out / "results.csv"
    done = set()
    if res.exists():
        with res.open() as f:
            done = {(r["method"], r["state"], r["run"]) for r in csv.DictReader(f)}
    else:
        res.write_text("method,state,run,tps,abort_rate,mode_threads,mean_threads\n")
    for run in range(1, args.runs + 1):
        order = methods if run % 2 else list(reversed(methods))
        for s in states:
            for m in order:
                if (m, s, str(run)) in done:
                    continue
                argv, env = C.command(args.bench, m, s, extime)
                try:
                    tps, abort, trace = C.run_one(argv, env, out / "logs" / f"{m}_{s}_run{run}.log")
                except subprocess.CalledProcessError as e:
                    with res.open("a") as f:
                        f.write(f"{m},{s},{run},,,failed_rc{e.returncode},\n")
                    print(f"{args.bench} {m} state={s} run={run} FAILED rc={e.returncode}", flush=True)
                    continue
                mode, mean = C.settled_threads(trace)
                with res.open("a") as f:
                    f.write(f"{m},{s},{run},{tps:.0f},{abort},{mode},{mean}\n")
                print(f"{args.bench} {m} state={s} run={run} tps={tps:,.0f} N={mode}", flush=True)


if __name__ == "__main__":
    main()
