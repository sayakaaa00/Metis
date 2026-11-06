#!/usr/bin/env python3
"""Oracle: sweep a fixed number N of active workers (Silo without backoff, the
first N of 96 workers active) and record TPS per state and N.

  oracle.py --bench tpcc|ycsb [--states ...] [--threads 8,10,...] [--runs 2] [--extime 10]

The oracle of a state is the N with the highest mean TPS over runs; the curve
is also the reference for the motivation figure and for judging the N chosen
by Metis. Paper: 10 s x 2 runs. TPC-C used the coarse grid below and then
2-step points around each best N; YCSB used the grid below. Run 2 visits the
points in reverse order. Output: <bench>/oracle/results.csv.
"""
import argparse
import csv

import common as C

THREADS = {"tpcc": [4, 6, 8, 10, 12, 14, 16, 24, 32, 48, 64, 96],
           "ycsb": list(range(8, 49, 2)) + [56, 64, 72, 80, 88, 96]}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--states", default="")
    p.add_argument("--threads", default="")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=10)
    args = p.parse_args()
    states = args.states.split(",") if args.states else C.STATES[args.bench]
    threads = ([int(n) for n in args.threads.split(",")] if args.threads
               else THREADS[args.bench])
    out = C.HERE / args.bench / "oracle"
    res = out / "results.csv"
    done = set()
    if res.exists():
        with res.open() as f:
            done = {(r["state"], r["threads"], r["run"]) for r in csv.DictReader(f)}
    else:
        out.mkdir(parents=True, exist_ok=True)
        res.write_text("state,threads,run,tps,abort_rate\n")
    for run in range(1, args.runs + 1):
        points = [(s, n) for s in states for n in threads]
        for s, n in (points if run % 2 else reversed(points)):
            if (s, str(n), str(run)) in done:
                continue
            argv, env = C.command(args.bench, f"fixed_{n}", s, args.extime)
            tps, abort, _ = C.run_one(argv, env, out / "logs" / f"{s}_n{n}_run{run}.log")
            with res.open("a") as f:
                f.write(f"{s},{n},{run},{tps:.0f},{abort}\n")
            print(f"oracle {args.bench} state={s} N={n} run={run} tps={tps:,.0f}", flush=True)


if __name__ == "__main__":
    main()
