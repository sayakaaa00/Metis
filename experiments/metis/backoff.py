#!/usr/bin/env python3
"""Backoff experiments on Silo (all 96 worker threads, silo/*_silo_backoff).

  backoff.py constant    --bench ycsb|tpcc [--states ...] [--backoffs ...] [--runs 2] [--extime 10]
  backoff.py exponential [--states ...] [--backoffs ...] [--runs 2] [--extime 10]      (YCSB)
  backoff.py tune        --bench ycsb|tpcc [--states ...] [--extime 10]

constant:    every wait lasts exactly the given duration
             (--backoff_fixed_exponential=false); the best duration per level is
             the "best fixed backoff" baseline.  -> $METIS_OUT/<bench>/backoff_constant/
exponential: the duration is the initial wait of an exponential backoff
             (doubled per consecutive abort).  -> $METIS_OUT/ycsb/backoff_exponential/
tune:        Silo with the adaptive backoff of Cicada (randomized wait) for 4 update
             periods x 4 steps, one run each; the best setting is common.SILO_BO.
             -> $METIS_OUT/<bench>/backoff_adaptive_tuning/sweep.csv
"""
import argparse

import common as C

CONSTANT = {"ycsb": (C.STATES["ycsb"], [0, 1, 2, 5, 10, 20, 30, 50, 100, 200, 500, 1000]),
            "tpcc": (C.STATES["tpcc"], [0, 1, 2, 5, 10, 20, 50, 100, 1000])}
EXPONENTIAL = (["0", "0.5", "0.7", "0.9", "0.99"], [0, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000])
TUNE_PERIODS_US = [1000, 5000, 20000, 100000]
TUNE_STEPS_US = [0.1, 0.5, 2.0, 8.0]
TUNE_STATES = {"tpcc": ["1", "4", "16"], "ycsb": ["0.7", "0.9", "0.99"]}


def fixed_backoff(bench, state, us, extime, exponential):
    argv, env = C.command(bench, "silo_bo", state, extime)
    return argv + ["--backoff_fixed_enable=true", f"--backoff_fixed_us={us}",
                   f"--backoff_fixed_exponential={str(exponential).lower()}"], env


def sweep(args, kind, states, backoffs):
    exponential = kind == "exponential"
    d = C.OUT / args.bench / f"backoff_{kind}"
    res = d / "results.csv"
    tpcc = args.bench == "tpcc"
    key = "state" if tpcc else "skew"
    header = [key, "backoff_us", "run", "tps", "abort_rate"] + (["mode_threads", "mean_threads"] if tpcc else [])
    C.write_config(d, args, fixed_backoff(args.bench, states[0], 0, 1, exponential)[0])
    for run in range(1, args.runs + 1):
        for b in (backoffs if run % 2 else list(reversed(backoffs))):
            for s in states:
                if (s, str(b), str(run)) in C.done_keys(res, [key, "backoff_us", "run"]):
                    continue
                argv, env = fixed_backoff(args.bench, s, b, args.extime, exponential)
                log = d / "logs" / (f"{s}_{b}_{run}.log" if tpcc else f"skew{s}_bo{b}_run{run}.log")
                tps, abort, _ = C.run_one(argv, env, log)
                C.append(res, header, [s, b, run, f"{tps:.0f}", abort] + (["", ""] if tpcc else []))
                print(f"{args.bench} backoff_{kind} {key}={s} backoff={b}us run={run} tps={tps:,.0f}", flush=True)


def tune(args, states):
    d = C.OUT / args.bench / "backoff_adaptive_tuning"
    res = d / "sweep.csv"
    C.write_config(d, args, C.command(args.bench, "silo_bo", states[0], 1)[0])
    for per in TUNE_PERIODS_US:
        for step in TUNE_STEPS_US:
            label = f"p{per // 1000}ms_s{step:g}"
            for s in states:
                if (label, s) in C.done_keys(res, ["config", "state"]):
                    continue
                argv, env = C.command(args.bench, "silo_bo", s, args.extime)
                argv += ["--backoff_randomized=true", f"--backoff_update_period_us={per}",
                         f"--backoff_step_us={step}"]
                tps, abort, _ = C.run_one(argv, env, d / "logs" / f"{label}_{s}.log")
                C.append(res, ["config", "period_us", "step_us", "state", "tps", "abort_rate"],
                         [label, per, step, s, f"{tps:.0f}", abort])
                print(f"{args.bench} tune {label} state={s} tps={tps:,.0f}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("kind", choices=["constant", "exponential", "tune"])
    p.add_argument("--bench", choices=["tpcc", "ycsb"], default="ycsb")
    p.add_argument("--states", default="")
    p.add_argument("--backoffs", default="")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=10)
    args = p.parse_args()
    if args.kind == "exponential" and args.bench != "ycsb":
        p.error("exponential is for YCSB")
    default_states, default_backoffs = (EXPONENTIAL if args.kind == "exponential"
                                        else CONSTANT[args.bench] if args.kind == "constant"
                                        else (TUNE_STATES[args.bench], []))
    states = args.states.split(",") if args.states else default_states
    backoffs = [int(b) for b in args.backoffs.split(",")] if args.backoffs else default_backoffs
    if args.kind == "tune":
        tune(args, states)
    else:
        sweep(args, args.kind, states, backoffs)


if __name__ == "__main__":
    main()
