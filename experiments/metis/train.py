#!/usr/bin/env python3
"""Train the Metis model and build the models used for evaluation.

  train.py run   --bench tpcc|ycsb [--set min6] [--states ...] [--runs 2] [--extime 30]
  train.py merge --bench tpcc|ycsb [--set min6] [--states ...]

run:   one training run per contention level and run id: Metis moves to a
       uniformly random candidate thread count every control period and
       records one ridge-regression sample per move. The statistics are saved
       to $METIS_OUT/<bench>/train/<set>/state_<s>_run<r>.txt
       (paper: 30 s, 2 runs per level). The set name gives the smallest
       candidate (min6: 6..96, min8: 8..96).
merge: $METIS_OUT/<bench>/models/<set>/all.txt pools every level (dynamic
       workloads); loo_<s>.txt pools every level except s (static workloads
       evaluate s with a model that has never seen it).
Evaluate with the new models: fixed.py/dynamic.py --models $METIS_OUT/<bench>/models/<set>
"""
import argparse
import subprocess
import sys

import common as C


def cmd_run(args, states):
    d = C.OUT / args.bench / "train" / args.set
    for run_id in range(1, args.runs + 1):
        for s in states:
            model = d / f"state_{s}_run{run_id}.txt"
            if model.exists():
                continue
            argv = C.metis_command(args.bench, s, args.extime, model, C.MIN_COUNT[args.set],
                                   learn=True, seed=run_id * 1000 + len(s))
            if run_id == 1 and s == states[0]:
                C.write_config(d, args, argv)
            tps, _, _ = C.run_one(argv, {}, d / f"state_{s}_run{run_id}.log")
            print(f"train {args.bench} state={s} run={run_id} tps={tps:,.0f}", flush=True)


def cmd_merge(args, states):
    d = C.OUT / args.bench
    files = {s: sorted((d / "train" / args.set).glob(f"state_{s}_run*.txt")) for s in states}
    merge = [sys.executable, str(C.HERE / "merge_models.py")]
    out = d / "models" / args.set
    subprocess.run(merge + [str(out / "all.txt")] + [str(p) for s in states for p in files[s]], check=True)
    for s in states:
        rest = [str(p) for t in states if t != s for p in files[t]]
        subprocess.run(merge + [str(out / f"loo_{s}.txt")] + rest, check=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["run", "merge"])
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--set", choices=list(C.MIN_COUNT), default="min6")
    p.add_argument("--states", default="")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=30)
    args = p.parse_args()
    states = args.states.split(",") if args.states else C.STATES[args.bench]
    {"run": cmd_run, "merge": cmd_merge}[args.cmd](args, states)


if __name__ == "__main__":
    main()
