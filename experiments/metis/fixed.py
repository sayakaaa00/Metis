#!/usr/bin/env python3
"""Static (fixed-load) comparison: Metis, hill climbing, Silo, Silo-BO, Cicada,
and ERMIA at each contention level.

  fixed.py --bench tpcc|ycsb [--methods ...] [--states ...] [--runs 2] [--extime 30|10]
           [--model-set min8|min6] [--models DIR]
  fixed.py --bench ycsb --hill-climbing-trace [--states ...]

Metis evaluates each level with its leave-one-out model (loo_<s>.txt), a model
that has never seen the level. Paper models: TPC-C min8, YCSB min6 (trained
on all nine skews). The method order is reversed on even runs.
Output ($METIS_OUT/<bench>/fixed/):
  results.csv          Silo, Silo-BO, Cicada, ERMIA (YCSB), hill climbing
  results_metis.csv    Metis
  ermia_3s/results.csv ERMIA on TPC-C (3-s runs, as in the paper)
  logs/                <method>_<state>_run<r>.log and .trace.log
--hill-climbing-trace: hill climbing on YCSB with an active-thread sample every
  10 ms control period -> $METIS_OUT/ycsb/hill_climbing_10ms_log/
  (paper: skew 0, 0.8, 0.9, 0.95, 0.99, 0.999).
"""
import argparse
import subprocess

import common as C

METHODS = ["metis", "hill_climbing", "silo_nobo", "silo_cbo_tuned", "cicada", "ermia"]
PAPER_MODELS = {"tpcc": "min8", "ycsb": "min6"}
HEADER = ["method", "state", "run", "tps", "abort_rate", "mode_threads", "mean_threads"]
ERMIA_TPCC_EXTIME = 3


def run_fixed(args, states, methods):
    out = C.OUT / args.bench / "fixed"
    model_set = args.model_set or PAPER_MODELS[args.bench]
    for m in methods:
        argv, _ = C.command(args.bench, m, states[0], 1, C.model_path(args.bench, model_set, "all", args.models))
        C.write_config(out, args, argv)
    for run in range(1, args.runs + 1):
        order = methods if run % 2 else list(reversed(methods))
        for s in states:
            for m in order:
                if args.bench == "tpcc" and m == "ermia":
                    run_ermia_tpcc(out / "ermia_3s", s, run)
                    continue
                res = out / ("results_metis.csv" if m == "metis" else "results.csv")
                if (m, s, str(run)) in C.done_keys(res, ["method", "state", "run"]):
                    continue
                model = C.model_path(args.bench, model_set, f"loo_{s}", args.models)
                argv, env = C.command(args.bench, m, s, args.extime, model, C.MIN_COUNT[model_set])
                try:
                    tps, abort, trace = C.run_one(argv, env, out / "logs" / f"{m}_{s}_run{run}.log")
                except subprocess.CalledProcessError as e:
                    C.append(res, HEADER, [m, s, run, "", "", f"failed_rc{e.returncode}", ""])
                    print(f"{args.bench} {m} state={s} run={run} FAILED rc={e.returncode}", flush=True)
                    continue
                mode, mean = C.settled_threads(trace)
                C.append(res, HEADER, [m, s, run, f"{tps:.0f}", abort, mode, mean])
                print(f"{args.bench} {m} state={s} run={run} tps={tps:,.0f} N={mode}", flush=True)


def run_ermia_tpcc(d, w, run):
    res = d / "results.csv"
    if (w, str(run)) in C.done_keys(res, ["W", "run"]):
        return
    argv, env = C.command("tpcc", "ermia", w, ERMIA_TPCC_EXTIME)
    tps, abort, _ = C.run_one(argv, env, d / "logs" / f"w{w}_run{run}.log")
    C.append(res, ["W", "run", "extime", "tps", "abort_rate"], [w, run, ERMIA_TPCC_EXTIME, f"{tps:.0f}", abort])
    print(f"tpcc ermia W={w} run={run} tps={tps:,.0f}", flush=True)


def run_hill_climbing_trace(args, states):
    d = C.OUT / "ycsb" / "hill_climbing_10ms_log"
    res = d / "results.csv"
    for run in range(1, args.runs + 1):
        for s in states:
            if ("hill_climbing", s, str(run)) in C.done_keys(res, ["method", "state", "run"]):
                continue
            argv, env = C.command("ycsb", "hill_climbing", s, args.extime)
            argv += ["--tam_log_period_us=10000"]
            if run == 1 and s == states[0]:
                C.write_config(d, args, argv)
            tps, abort, _ = C.run_one(argv, env, d / "logs" / f"hill_climbing_{s}_run{run}.log")
            C.append(res, ["method", "state", "run", "tps", "abort_rate"], ["hill_climbing", s, run, f"{tps:.0f}", abort])
            print(f"ycsb hill_climbing (10-ms log) state={s} run={run} tps={tps:,.0f}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=None)
    p.add_argument("--methods", default=",".join(METHODS))
    p.add_argument("--states", default="")
    p.add_argument("--model-set", choices=list(C.MIN_COUNT), default=None)
    p.add_argument("--models", default=None, help="directory with loo_<s>.txt (default: paper models)")
    p.add_argument("--hill-climbing-trace", action="store_true")
    args = p.parse_args()
    args.extime = args.extime or C.EXTIME[args.bench]
    states = args.states.split(",") if args.states else C.STATES[args.bench]
    if args.hill_climbing_trace:
        if args.bench != "ycsb":
            p.error("--hill-climbing-trace is for YCSB")
        run_hill_climbing_trace(args, states)
    else:
        run_fixed(args, states, args.methods.split(","))


if __name__ == "__main__":
    main()
