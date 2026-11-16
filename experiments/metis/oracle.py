#!/usr/bin/env python3
"""Oracle: throughput of Silo (no backoff) with a fixed number N of active
worker threads (the first N of 96), per contention level.

  oracle.py --bench ycsb [--states ...] [--group NAME] [--threads ...] [--runs 2] [--extime 10]
  oracle.py --bench tpcc [--states ...] [--runs 2] [--extime 10] [--no-refine]

The oracle of a contention level is the N with the highest mean throughput
over runs. Run 2 visits the points in reverse order.
YCSB: N in 8..48 (step 2) and 56..96 (step 8). Paper: skew 0.7-0.999
(group skew_0.7-0.999) and skew 0, 0.5, 0.9 (group skew_0_0.5_0.9).
  -> $METIS_OUT/ycsb/oracle/<group>/results.csv, logs/
TPC-C: coarse N grid, then every even N within +-8 of the best coarse N
(--no-refine skips this).  -> $METIS_OUT/tpcc/oracle/w<W>/results.csv, logs/
"""
import argparse
import statistics
from collections import defaultdict

import common as C

YCSB_THREADS = list(range(8, 49, 2)) + [56, 64, 72, 80, 88, 96]
TPCC_COARSE = [4, 8, 16, 24, 32, 48, 64, 96]
YCSB_GROUPS = {"skew_0.7-0.999": ["0.7", "0.8", "0.85", "0.9", "0.95", "0.99", "0.999"],
               "skew_0_0.5_0.9": ["0", "0.5", "0.9"]}


def sweep_ycsb(group, states, threads, runs, extime):
    d = C.OUT / "ycsb" / "oracle" / group
    res = d / "results.csv"
    header = ["skew", "threads", "run", "throughput_tps", "abort_rate", "actual_extime"]
    done = C.done_keys(res, ["skew", "threads", "run"])
    for run in range(1, runs + 1):
        points = [(s, n) for s in states for n in threads]
        for s, n in (points if run % 2 else reversed(points)):
            if (s, str(n), str(run)) in done:
                continue
            argv, env = C.command("ycsb", f"fixed_{n}", s, extime)
            tps, abort, _ = C.run_one(argv, env, d / "logs" / f"skew{s}_n{n}_run{run}.log")
            C.append(res, header, [s, n, run, f"{tps:.0f}", abort, extime])
            print(f"oracle ycsb skew={s} N={n} run={run} tps={tps:,.0f}", flush=True)


def sweep_tpcc(w, threads, runs, extime):
    d = C.OUT / "tpcc" / "oracle" / f"w{w}"
    res = d / "results.csv"
    header = ["active_warehouses", "active_threads", "run", "tps", "abort_rate", "log"]
    done = C.done_keys(res, ["active_threads", "run"])
    for run in range(1, runs + 1):
        for n in (threads if run % 2 else list(reversed(threads))):
            if (str(n), str(run)) in done:
                continue
            log = d / "logs" / f"w{w}_n{n}_run{run}.log"
            argv, env = C.command("tpcc", f"fixed_{n}", w, extime)
            tps, abort, _ = C.run_one(argv, env, log)
            C.append(res, header, [w, n, run, f"{tps:.0f}", abort, log.relative_to(C.OUT)])
            print(f"oracle tpcc W={w} N={n} run={run} tps={tps:,.0f}", flush=True)
    return res


def best_n(res):
    acc = defaultdict(list)
    for r in C.csv.DictReader(res.open()):
        acc[int(r["active_threads"])].append(float(r["tps"]))
    return max(acc, key=lambda n: statistics.mean(acc[n]))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--states", default="")
    p.add_argument("--group", default="", help="YCSB output group (default: the paper groups)")
    p.add_argument("--threads", default="")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=10)
    p.add_argument("--no-refine", action="store_true")
    args = p.parse_args()
    threads = [int(n) for n in args.threads.split(",")] if args.threads else None
    if args.bench == "ycsb":
        groups = ({args.group or "custom": args.states.split(",")} if args.states else YCSB_GROUPS)
        for g, states in groups.items():
            C.write_config(C.OUT / "ycsb" / "oracle" / g, args, C.command("ycsb", "fixed_8", states[0], 1)[0])
            sweep_ycsb(g, states, threads or YCSB_THREADS, args.runs, args.extime)
        return
    for w in (args.states.split(",") if args.states else C.STATES["tpcc"]):
        C.write_config(C.OUT / "tpcc" / "oracle" / f"w{w}", args, C.command("tpcc", "fixed_8", w, 1)[0])
        res = sweep_tpcc(w, threads or TPCC_COARSE, args.runs, args.extime)
        if not args.no_refine and not threads:
            b = best_n(res)
            fine = [n for n in range(max(4, b - 8), min(C.WORKERS, b + 8) + 1, 2) if n not in TPCC_COARSE]
            sweep_tpcc(w, fine, args.runs, args.extime)


if __name__ == "__main__":
    main()
