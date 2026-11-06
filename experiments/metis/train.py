#!/usr/bin/env python3
"""Train the Metis model and build the leave-one-out models.

  train.py run   --bench tpcc|ycsb [--states 1,2,...] [--runs 2] [--extime 30]
  train.py merge --bench tpcc|ycsb

run:   one training run per state and run id. Metis moves to uniformly random
       thread counts every control period and records one ridge-regression
       sample per move; the statistics are saved to
       <bench>/train/state_<s>_run<r>.txt (paper: TPC-C 30 s, YCSB 20 s, 2 runs).
merge: <bench>/models/all.txt pools every state (dynamic-load runs);
       <bench>/models/loo_<s>.txt pools every state except s (fixed-load runs
       evaluate s with a model that has never seen it).
"""
import argparse
import subprocess
import sys

import common as C


def cmd_run(args):
    d = C.HERE / args.bench / "train"
    states = args.states.split(",") if args.states else C.STATES[args.bench]
    for run_id in range(1, args.runs + 1):
        for s in states:
            model = d / f"state_{s}_run{run_id}.txt"
            if model.exists():
                continue
            argv = C.metis_command(args.bench, s, args.extime, model, learn=True,
                                   seed=run_id * 1000 + len(s))
            tps, _, _ = C.run_one(argv, {}, d / "logs" / f"state_{s}_run{run_id}.log")
            print(f"train {args.bench} state={s} run={run_id} tps={tps:,.0f}", flush=True)


def cmd_merge(args):
    d = C.HERE / args.bench
    states = C.STATES[args.bench]
    files = {s: sorted((d / "train").glob(f"state_{s}_run*.txt")) for s in states}
    merge = [sys.executable, str(C.HERE / "merge_models.py")]
    subprocess.run(merge + [str(d / "models" / "all.txt")] +
                   [str(p) for s in states for p in files[s]], check=True)
    for s in states:
        rest = [str(p) for t in states if t != s for p in files[t]]
        subprocess.run(merge + [str(d / "models" / f"loo_{s}.txt")] + rest, check=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["run", "merge"])
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--states", default="")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=None)
    args = p.parse_args()
    if args.extime is None:
        args.extime = 30 if args.bench == "tpcc" else 20
    {"run": cmd_run, "merge": cmd_merge}[args.cmd](args)


if __name__ == "__main__":
    main()
