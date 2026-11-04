#!/usr/bin/env python3
"""Fixed-load comparison of Metis v2-A with adaTAM, Silo (with/without backoff),
Cicada, and ERMIA under the shared conditions.

  compare.py --bench tpcc [--runs 2] [--extime 30]
  compare.py --bench ycsb [--runs 2] [--extime 10]

All methods: 96 workers, physical-first CPU order, mimalloc, clocks_per_us=2900.
Metis v2-A uses the held-out (leave-one-out) model of each state; adaTAM starts
at 96 workers with the same control period as Metis (TPC-C 200 ms, YCSB 10 ms)
and the best step from a short sweep (TPC-C 8 of {2,4,8}; YCSB 4 of {1,2,4,8}). Silo/Cicada/ERMIA run all 96 workers. Method order is reversed
on even runs. Output: experiments/ICDE/metis_v2/<bench>/compare_fixed/.
"""
import argparse
import csv
import hashlib
import os
import re
import shutil
import subprocess
from pathlib import Path

import run as R

ROOT = R.ROOT
HERE = R.HERE
MIMALLOC = R.MIMALLOC
METHODS = ["metis_v2", "adatam", "silo_nobo", "silo_bo", "cicada", "ermia"]
# "adatam_default" (untuned step) is available via --methods.
IDENTITY = ",".join(str(i) for i in range(96))  # = physical-first on this host


def tpcc_common(w, extime):
    return ["--thread_num=96", "--tpcc_num_wh=96", "--tpcc_num_items=100000",
            f"--tpcc_active_warehouse_count={w}", "--tpcc_active_warehouse_schedule=",
            "--tpcc_home_warehouse_assignment=random_per_transaction",
            "--tpcc_home_warehouse_seed=1", "--tpcc_balanced_home_prefix=true",
            "--tpcc_perc_payment=43", "--tpcc_perc_order_status=4",
            "--tpcc_perc_delivery=4", "--tpcc_perc_stock_level=4",
            "--tpcc_hot_item_ratio=0", "--tpcc_hot_transaction_mode=false",
            "--tpcc_interactive_ms=0", "--tpcc_retry_same_type=true",
            "--tpcc_log_retry_conflicts=false", f"--extime={extime}",
            "--clocks_per_us=2900"]


def ycsb_common(skew, extime):
    return ["--thread_num=96", f"--extime={extime}", "--clocks_per_us=2900",
            "--ycsb_tuple_num=10000", "--ycsb_max_ope=10", "--ycsb_rratio=50",
            f"--ycsb_zipf_skew={skew}"]


def command(bench, method, state, extime):
    """Return (argv, extra_env)."""
    if method == "adatam_default":
        # Untuned adaTAM: the code's default step (2), same control period as
        # Metis (TPC-C 200 ms, YCSB 10 ms).
        argv, env = command(bench, "adatam", state, extime)
        return [a for a in argv if not a.startswith("--ada_tam_step=")] + [
            "--ada_tam_step=2"], env
    if method == "metis_v2":
        model = HERE / bench / "A" / "models" / f"loo_{state}.txt"
        return (R.base_command(bench, state, extime) + R.VARIANT["A"] +
                ["--metis_v2_learn=false", f"--linucb_model_path={model}"]), {}
    b = ROOT / "build_release"
    if bench == "tpcc":
        c = tpcc_common(state, extime)
        if method == "adatam":
            return ([str(b / "silo/tpcc_metis_test")] + c +
                    ["--tpcc_pin_workers=true", "--tpcc_pin_order=physical_first",
                     "--ada_tam_enable=true", "--tam_min_threads=1",
                     "--tam_max_threads=96", "--tam_update_period_us=200000",
                     "--ada_tam_step=8", "--tam_idle_sleep_us=50",
                     "--metis_test_idle_sleep_us=50", "--tam_log_active_threads=true",
                     "--tam_log_period_us=100000"]), {}
        if method in ("silo_nobo", "silo_bo"):
            name = "tpcc_silo_without_backoff" if method == "silo_nobo" else "tpcc_silo_with_backoff"
            return ([str(b / "silo" / name)] + c +
                    ["--tpcc_pin_workers=true", "--tpcc_pin_order=physical_first",
                     "--metis_test_enable=true", "--metis_test_fixed_threads=96",
                     "--metis_test_learn=false", "--metis_test_idle_sleep_us=50",
                     "--tam_update_period_us=200000"]), {}
        return ([str(b / "cc" / method / f"tpcc_{method}.exe")] + c +
                ["--tpcc_pin_order=physical_first", "--batch_th_num=0",
                 "--gc_inter_us=1000000000", "--gc_defer_record_reclamation=false"]), {}
    c = ycsb_common(state, extime)
    if method == "adatam":
        return ([str(b / "silo/ycsb_metis_paper")] + c +
                ["--pin_threads=true", "--ycsb_pin_order=physical_first",
                 "--ada_tam_enable=true", "--metis_paper_enable=false",
                 "--tam_min_threads=1", "--tam_max_threads=96",
                 "--tam_update_period_us=10000", "--ada_tam_step=4",
                 "--tam_idle_sleep_us=50", "--tam_log_active_threads=true",
                 "--tam_log_period_us=100000"]), {}
    if method in ("silo_nobo", "silo_bo"):
        name = "silo_without_backoff" if method == "silo_nobo" else "silo_with_backoff"
        return ([str(b / "silo" / name)] + c +
                ["--pin_threads=true", "--ycsb_pin_order=physical_first"]), {}
    return [str(b / "cc" / method / f"ycsb_{method}.exe")] + c, {
        "CCBENCH_PIN_CPU_LIST": IDENTITY}


def run_one(argv, extra_env, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LD_PRELOAD=str(MIMALLOC), **extra_env)
    with log.open("w") as f:
        subprocess.run(argv, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
    body = log.read_text()
    trace = re.search(r'logs will be written to: "?([^"\n]+)"?', body)
    trace_path = None
    if trace:
        trace_path = log.with_suffix(".trace.log")
        shutil.move(str(ROOT / trace[1]), trace_path)
    tps = float(re.search(r"(?m)^throughput\[tps\]:\s+(\S+)", body)[1])
    abort = float(re.search(r"(?m)^abort_rate:\s+(\S+)", body)[1])
    return tps, abort, trace_path


def threads_from_trace(path, skip_s=2.0):
    if path is None:
        return "", ""
    counts = {}
    for line in path.read_text().splitlines():
        m = re.search(r"bench_s=([\d.]+) active_threads=(\d+)", line)
        if m and float(m[1]) >= skip_s:
            counts[int(m[2])] = counts.get(int(m[2]), 0) + 1
    if not counts:
        return R.chosen_threads(path, skip_s)
    total = sum(counts.values())
    return max(counts, key=counts.get), f"{sum(k * v for k, v in counts.items()) / total:.1f}"


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
    states = args.states.split(",") if args.states else R.STATES[args.bench]
    out = HERE / args.bench / "compare_fixed"
    out.mkdir(parents=True, exist_ok=True)
    with (out / "config.txt").open("a") as f:
        f.write(f"extime={extime} runs={args.runs} methods={methods} states={states}\n")
        for m in methods:
            argv, _ = command(args.bench, m, states[0], extime)
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
                argv, env = command(args.bench, m, s, extime)
                try:
                    tps, abort, trace = run_one(argv, env, out / "logs" / f"{m}_{s}_run{run}.log")
                except subprocess.CalledProcessError as e:
                    # e.g. Cicada with deferred GC exhausting memory (OOM kill)
                    with res.open("a") as f:
                        f.write(f"{m},{s},{run},,,failed_rc{e.returncode},\n")
                    print(f"{args.bench} {m} state={s} run={run} FAILED rc={e.returncode}", flush=True)
                    continue
                mode, mean = threads_from_trace(trace)
                with res.open("a") as f:
                    f.write(f"{m},{s},{run},{tps:.0f},{abort},{mode},{mean}\n")
                print(f"{args.bench} {m} state={s} run={run} tps={tps:,.0f} N={mode}", flush=True)


if __name__ == "__main__":
    main()
