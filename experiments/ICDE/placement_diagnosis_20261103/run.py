#!/usr/bin/env python3
"""Separate the cross-socket and SMT-sharing penalties at a fixed N=24.

Four placements of the 24 active workers (CCBENCH_PIN_CPU_LIST):
  1S-phys : 24 physical cores on socket 0           (baseline)
  1S-SMT  : 12 cores x 2 SMT threads on socket 0     (SMT sharing only)
  2S-phys : 12 + 12 physical cores on two sockets    (cross-socket only)
  2S-SMT  : 6 cores x 2 SMT on each socket           (both)
Workloads: YCSB at several skews / sizes and TPC-C standard mix at several W.
Each condition 10 s x 2 runs; run 2 reverses the order.
"""
import csv
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
MIMALLOC = ROOT / "build_release/mimalloc_override/libmimalloc.so"
YCSB = ROOT / "build_release/silo/ycsb_metis_paper"
TPCC = ROOT / "build_release/silo/tpcc_metis_test"
N = 24
EXTIME = 10


def cpus(*ranges):
    out = []
    for a, b in ranges:
        out += list(range(a, b + 1))
    return ",".join(map(str, out))


PLACEMENTS = {
    "1S-phys": cpus((0, 23)),
    "1S-SMT": cpus((0, 11), (48, 59)),
    "2S-phys": cpus((0, 11), (24, 35)),
    "2S-SMT": cpus((0, 5), (48, 53), (24, 29), (72, 77)),
}
WORKLOADS = [
    ("ycsb", "skew0.7_10k", {"skew": 0.7, "tuples": 10000}),
    ("ycsb", "skew0.9_10k", {"skew": 0.9, "tuples": 10000}),
    ("ycsb", "skew0.99_10k", {"skew": 0.99, "tuples": 10000}),
    ("ycsb", "skew0_10M", {"skew": 0.0, "tuples": 10000000}),
    ("tpcc", "W1", {"w": 1}),
    ("tpcc", "W4", {"w": 4}),
    ("tpcc", "W16", {"w": 16}),
    ("tpcc", "W32", {"w": 32}),
]


def command(kind, params):
    if kind == "ycsb":
        return [str(YCSB), "--thread_num=96", f"--extime={EXTIME}",
                "--clocks_per_us=2900", f"--ycsb_tuple_num={params['tuples']}",
                "--ycsb_max_ope=10", "--ycsb_rratio=50",
                f"--ycsb_zipf_skew={params['skew']}", "--pin_threads=true",
                "--ycsb_pin_order=physical_first", "--ada_tam_enable=true",
                "--metis_paper_enable=false", f"--tam_min_threads={N}",
                f"--tam_max_threads={N}", "--tam_update_period_us=1000000",
                "--tam_idle_sleep_us=50", "--tam_log_active_threads=false"]
    w = params["w"]
    return [str(TPCC), "--thread_num=96", "--tpcc_num_wh=96", "--tpcc_num_items=100000",
            f"--tpcc_active_warehouse_count={w}", "--tpcc_active_warehouse_schedule=",
            "--tpcc_home_warehouse_assignment=random_per_transaction",
            "--tpcc_balanced_home_prefix=true", "--tpcc_home_warehouse_seed=1",
            "--tpcc_perc_payment=43", "--tpcc_perc_order_status=4",
            "--tpcc_perc_delivery=4", "--tpcc_perc_stock_level=4",
            "--tpcc_hot_item_ratio=0", "--tpcc_hot_transaction_mode=false",
            "--tpcc_interactive_ms=0", "--tpcc_retry_same_type=true",
            "--tpcc_log_retry_conflicts=false", f"--extime={EXTIME}",
            "--clocks_per_us=2900", "--tam_min_threads=1", "--tam_max_threads=96",
            "--tam_update_period_us=200000", "--metis_test_enable=true",
            "--ada_tam_enable=false", "--metis_test_learn=false",
            "--metis_test_observed_load=false", "--metis_test_cross_workload=true",
            "--metis_test_coarse_actions=true", f"--metis_test_active_warehouses={w}",
            "--metis_test_balanced_home_prefix=true", "--metis_test_idle_sleep_us=50",
            "--metis_test_tps_scale=400000", f"--metis_test_fixed_threads={N}",
            "--linucb_alpha=0", "--tpcc_pin_workers=true",
            "--tpcc_pin_order=physical_first"]


def main():
    out = HERE / "results.csv"
    (HERE / "logs").mkdir(exist_ok=True)
    config = {
        "ycsb_sha256": hashlib.sha256(YCSB.read_bytes()).hexdigest(),
        "tpcc_sha256": hashlib.sha256(TPCC.read_bytes()).hexdigest(),
        "allocator_sha256": hashlib.sha256(MIMALLOC.read_bytes()).hexdigest(),
        "active_workers": N, "extime": EXTIME, "runs": 2,
        "placements": PLACEMENTS, "workloads": [w[1] for w in WORKLOADS],
    }
    (HERE / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    done = set()
    if out.exists():
        with out.open() as f:
            done = {(r["workload"], r["placement"], r["run"]) for r in csv.DictReader(f)}
    else:
        with out.open("w") as f:
            f.write("benchmark,workload,placement,run,tps,abort_rate,attempts_per_s\n")
    conds = [(k, name, p, pl) for k, name, p in WORKLOADS for pl in PLACEMENTS]
    for run in (1, 2):
        for kind, name, params, pl in (conds if run == 1 else list(reversed(conds))):
            if (name, pl, str(run)) in done:
                continue
            env = dict(os.environ, LD_PRELOAD=str(MIMALLOC),
                       CCBENCH_PIN_CPU_LIST=PLACEMENTS[pl])
            log = HERE / "logs" / f"{name}_{pl}_run{run}.log"
            with log.open("w") as f:
                subprocess.run(command(kind, params), cwd=ROOT, env=env, stdout=f,
                               stderr=subprocess.STDOUT, check=True)
            body = log.read_text()
            tps = float(re.search(r"(?m)^throughput\[tps\]:\s+(\S+)", body)[1])
            abort = float(re.search(r"(?m)^abort_rate:\s+(\S+)", body)[1])
            attempts = tps / (1 - abort) if abort < 1 else float("nan")
            with out.open("a") as f:
                f.write(f"{kind},{name},{pl},{run},{tps:.0f},{abort:.4f},{attempts:.0f}\n")
            print(f"{name} {pl} run{run} tps={tps:,.0f} abort={abort:.3f}", flush=True)


if __name__ == "__main__":
    main()
