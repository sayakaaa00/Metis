#!/usr/bin/env python3
"""Train and evaluate Metis v2 (variants A, B1, B2) on TPC-C and YCSB.

  run.py train  --bench tpcc --variant A  [--states 1,2,...] [--runs 2] [--extime 30]
  run.py merge  --bench tpcc --variant A          # leave-one-out + all-state models
  run.py fixed  --bench tpcc --variant A  [--runs 2] [--extime 10]
  run.py dynamic --bench tpcc --variant A --schedule 0:16,20:1,40:4 [--runs 2]

Variants: A = probe-free, B1 = probe at N=96, B2 = probe at N=96 and N=48.
States: TPC-C standard mix active W; YCSB Zipf skew (10k tuples).
Common conditions: 96 workers, physical-first pinning, mimalloc, 50 us parked
sleep, clocks_per_us=2900. Control period: TPC-C 200 ms, YCSB 10 ms.
Outputs go to experiments/ICDE/metis_v2/<bench>/<variant>/.
"""
import argparse
import csv
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
MIMALLOC = ROOT / "build_release/mimalloc_override/libmimalloc.so"
BIN = {"tpcc": ROOT / "build_release/silo/tpcc_metis_test",
       "ycsb": ROOT / "build_release/silo/ycsb_metis_paper"}
STATES = {"tpcc": ["1", "2", "3", "4", "8", "16", "32", "96"],
          "ycsb": ["0.7", "0.8", "0.85", "0.9", "0.95", "0.99", "0.999"]}
PERIOD_US = {"tpcc": 200000, "ycsb": 10000}
VARIANT = {"A": ["--metis_v2_variant=A"],
           "B1": ["--metis_v2_variant=B", "--metis_v2_probe_points=1"],
           "B2": ["--metis_v2_variant=B", "--metis_v2_probe_points=2"]}


def base_command(bench, state, extime, schedule=None):
    if bench == "tpcc":
        w = state
        cmd = [str(BIN["tpcc"]), "--thread_num=96", "--tpcc_num_wh=96",
               "--tpcc_num_items=100000", f"--tpcc_active_warehouse_count={w}",
               f"--tpcc_active_warehouse_schedule={schedule or ''}",
               "--tpcc_home_warehouse_assignment=random_per_transaction",
               "--tpcc_balanced_home_prefix=true", "--tpcc_home_warehouse_seed=1",
               "--tpcc_perc_payment=43", "--tpcc_perc_order_status=4",
               "--tpcc_perc_delivery=4", "--tpcc_perc_stock_level=4",
               "--tpcc_hot_item_ratio=0", "--tpcc_hot_transaction_mode=false",
               "--tpcc_interactive_ms=0", "--tpcc_retry_same_type=true",
               "--tpcc_log_retry_conflicts=false", "--tpcc_pin_workers=true",
               "--tpcc_pin_order=physical_first", "--metis_test_idle_sleep_us=50"]
    else:
        cmd = [str(BIN["ycsb"]), "--thread_num=96", "--ycsb_tuple_num=10000",
               "--ycsb_max_ope=10", "--ycsb_rratio=50", f"--ycsb_zipf_skew={state}",
               "--pin_threads=true", "--ycsb_pin_order=physical_first"]
        if schedule:  # "0.7,20:0.95,40:0.8"
            parts = schedule.split(",")
            cmd[5] = f"--ycsb_zipf_skew={parts[0]}"
            t1, s1 = parts[1].split(":")
            t2, s2 = parts[2].split(":")
            cmd += ["--ycsb_skew_change_enable=true", f"--ycsb_zipf_skew2={s1}",
                    f"--ycsb_skew_change_time_sec={t1}", "--ycsb_skew_change_enable2=true",
                    f"--ycsb_zipf_skew3={s2}", f"--ycsb_skew_change_time_sec2={t2}"]
    cmd += [f"--extime={extime}", "--clocks_per_us=2900", "--tam_min_threads=1",
            "--tam_max_threads=96", f"--tam_update_period_us={PERIOD_US[bench]}",
            "--tam_idle_sleep_us=50", "--tam_log_active_threads=true",
            "--tam_log_period_us=100000", "--metis_v2_enable=true"]
    return cmd


def run(cmd, log_path):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LD_PRELOAD=str(MIMALLOC))
    with log_path.open("w") as f:
        subprocess.run(cmd, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
    body = log_path.read_text()
    trace = re.search(r'logs will be written to: "?([^"\n]+)"?', body)
    trace_path = log_path.with_suffix(".trace.log")
    if trace:
        shutil.move(str(ROOT / trace[1]), trace_path)
    tps = float(re.search(r"(?m)^throughput\[tps\]:\s+(\S+)", body)[1])
    abort = float(re.search(r"(?m)^abort_rate:\s+(\S+)", body)[1])
    return tps, abort, trace_path


def chosen_threads(trace_path, skip_s=2.0):
    """Mode and mean of active threads in [MetisV2] lines after skip_s."""
    counts = {}
    for line in trace_path.read_text().splitlines():
        m = re.match(r"\[MetisV2\] t=([\d.]+) active=(\d+)", line)
        if m and float(m[1]) >= skip_s:
            counts[int(m[2])] = counts.get(int(m[2]), 0) + 1
    if not counts:
        return "", ""
    total = sum(counts.values())
    mode = max(counts, key=counts.get)
    mean = sum(k * v for k, v in counts.items()) / total
    return mode, f"{mean:.1f}"


def outdir(args):
    return HERE / args.bench / args.variant


def write_config(d, args):
    d.mkdir(parents=True, exist_ok=True)
    b = BIN[args.bench]
    (d / f"config_{args.cmd}.txt").write_text(
        f"binary={b}\nbinary_sha256={hashlib.sha256(b.read_bytes()).hexdigest()}\n"
        f"allocator_sha256={hashlib.sha256(MIMALLOC.read_bytes()).hexdigest()}\n"
        f"args={vars(args)}\n")


def append(csv_path, row, header):
    new = not csv_path.exists()
    with csv_path.open("a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(header)
        w.writerow(row)


def done_keys(csv_path, cols):
    if not csv_path.exists():
        return set()
    with csv_path.open() as f:
        return {tuple(r[c] for c in cols) for r in csv.DictReader(f)}


def cmd_train(args):
    d = outdir(args)
    write_config(d, args)
    states = args.states.split(",") if args.states else STATES[args.bench]
    for run_id in range(1, args.runs + 1):
        for s in states:
            model = d / "train" / f"state_{s}_run{run_id}.txt"
            if model.exists():
                continue
            cmd = base_command(args.bench, s, args.extime) + VARIANT[args.variant] + [
                "--metis_v2_learn=true", f"--metis_v2_seed={run_id * 1000 + len(s)}",
                f"--linucb_model_path={model}"]
            tps, abort, _ = run(cmd, d / "train" / f"state_{s}_run{run_id}.log")
            print(f"train {args.bench} {args.variant} state={s} run={run_id} tps={tps:,.0f}",
                  flush=True)


def cmd_merge(args):
    d = outdir(args)
    states = STATES[args.bench]
    files = {s: sorted((d / "train").glob(f"state_{s}_run*.txt")) for s in states}
    merge = [sys.executable, str(HERE / "merge_models.py")]
    allf = [str(p) for s in states for p in files[s]]
    subprocess.run(merge + [str(d / "models" / "all.txt")] + allf, check=True)
    for s in states:
        rest = [str(p) for t in states if t != s for p in files[t]]
        subprocess.run(merge + [str(d / "models" / f"loo_{s}.txt")] + rest, check=True)


def cmd_fixed(args):
    d = outdir(args)
    write_config(d, args)
    states = args.states.split(",") if args.states else STATES[args.bench]
    out = d / "fixed.csv"
    header = ["state", "run", "tps", "abort_rate", "mode_threads", "mean_threads", "model"]
    done = done_keys(out, ["state", "run"])
    for run_id in range(1, args.runs + 1):
        order = states if run_id % 2 else list(reversed(states))
        for s in order:
            if (s, str(run_id)) in done:
                continue
            model = d / "models" / (f"loo_{s}.txt" if not args.all_model else "all.txt")
            cmd = base_command(args.bench, s, args.extime) + VARIANT[args.variant] + [
                "--metis_v2_learn=false", f"--linucb_model_path={model}",
                f"--metis_v2_alpha={args.alpha}"]
            tps, abort, trace = run(cmd, d / "fixed" / f"state_{s}_run{run_id}.log")
            mode, mean = chosen_threads(trace)
            append(out, [s, run_id, f"{tps:.0f}", abort, mode, mean, model.name], header)
            print(f"fixed {args.bench} {args.variant} state={s} run={run_id} "
                  f"tps={tps:,.0f} N={mode} (mean {mean})", flush=True)


def cmd_dynamic(args):
    d = outdir(args)
    write_config(d, args)
    out = d / "dynamic.csv"
    header = ["schedule", "run", "tps", "abort_rate", "model"]
    done = done_keys(out, ["schedule", "run"])
    first = args.schedule.split(",")[0]
    first_state = first.split(":")[1] if args.bench == "tpcc" else first
    model = d / "models" / (args.model or "all.txt")
    tag = args.schedule.replace(":", "-").replace(",", "_")
    for run_id in range(1, args.runs + 1):
        if (args.schedule, str(run_id)) in done:
            continue
        cmd = base_command(args.bench, first_state, args.extime, args.schedule) + \
            VARIANT[args.variant] + ["--metis_v2_learn=false",
                                     f"--linucb_model_path={model}",
                                     f"--metis_v2_alpha={args.alpha}",
                                     "--benchmark_interval_tps_log_us=200000"]
        tps, abort, _ = run(cmd, d / "dynamic" / f"{tag}_run{run_id}.log")
        append(out, [args.schedule, run_id, f"{tps:.0f}", abort, model.name], header)
        print(f"dynamic {args.bench} {args.variant} {args.schedule} run={run_id} "
              f"tps={tps:,.0f}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["train", "merge", "fixed", "dynamic"])
    p.add_argument("--bench", choices=["tpcc", "ycsb"], required=True)
    p.add_argument("--variant", choices=list(VARIANT), required=True)
    p.add_argument("--states", default="")
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=None)
    p.add_argument("--alpha", type=float, default=0.0)
    p.add_argument("--schedule", default="")
    p.add_argument("--model", default="")
    p.add_argument("--all-model", action="store_true")
    args = p.parse_args()
    if args.extime is None:
        args.extime = {"train": 30, "fixed": 10, "dynamic": 60}.get(args.cmd, 10)
    {"train": cmd_train, "merge": cmd_merge, "fixed": cmd_fixed,
     "dynamic": cmd_dynamic}[args.cmd](args)


if __name__ == "__main__":
    main()
