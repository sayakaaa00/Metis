#!/usr/bin/env python3
"""Fixed-worker sweep for the W=1 New-Order-only item-skew workload."""

import argparse
import csv
import hashlib
import json
import os
import subprocess
from pathlib import Path

from run_contention_pilot import FIELDS, HERE, ROOT, parse_log


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--workers", required=True, nargs="+", type=int)
    parser.add_argument("--seconds", required=True, type=int)
    parser.add_argument("--runs", type=int, default=1)
    args = parser.parse_args()
    if min(args.workers) < 1 or max(args.workers) > 96 or args.seconds < 1 or args.runs < 1:
        parser.error("workers must be 1..96; seconds and runs must be positive")
    output = args.out if args.out.is_absolute() else HERE / args.out
    (output / "logs").mkdir(parents=True, exist_ok=True)
    binary = ROOT / "build_release/silo/tpcc_silo_without_backoff"
    allocator = ROOT / "build_release/mimalloc_override/libmimalloc.so"
    config = {
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "allocator_sha256": hashlib.sha256(allocator.read_bytes()).hexdigest(),
        "database_warehouses": 16, "active_warehouses": 1, "items": 100000,
        "software_workers": 96, "mix": "neworder_only", "thetas": [0, 0.95],
        "workers": args.workers, "seconds": args.seconds, "runs": args.runs,
        "pin_order": "physical_first", "item_zipf_seed": 1,
    }
    config_path = output / "config.json"
    if config_path.exists() and json.loads(config_path.read_text()) != config:
        raise SystemExit(f"Configuration changed: {config_path}")
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    csv_path = output / "results.csv"
    present = set()
    if csv_path.exists():
        with csv_path.open(newline="") as stream:
            for row in csv.DictReader(stream):
                present.add((float(row["theta"]), int(row["workers"]), int(row["run"])))
    else:
        with csv_path.open("w", newline="") as stream:
            csv.DictWriter(stream, FIELDS).writeheader()
    environment = os.environ.copy()
    environment["LD_PRELOAD"] = str(allocator)
    conditions = [(theta, n) for theta in (0, 0.95) for n in args.workers]
    for run in range(1, args.runs + 1):
        order = conditions if run % 2 else list(reversed(conditions))
        for theta, n in order:
            if (theta, n, run) in present:
                continue
            log = output / "logs" / f"theta{theta}_n{n}_run{run}.log"
            command = [str(binary), "--thread_num=96", "--tpcc_num_wh=16",
                       "--tpcc_active_warehouse_count=1", "--tpcc_num_items=100000",
                       "--tpcc_home_warehouse_assignment=random_per_transaction",
                       "--tpcc_item_zipf_enable=true", f"--tpcc_item_zipf_skew={theta}",
                       "--tpcc_item_zipf_seed=1", "--tpcc_perc_payment=0",
                       "--tpcc_perc_order_status=0", "--tpcc_perc_delivery=0",
                       "--tpcc_perc_stock_level=0", "--tpcc_hot_item_ratio=0",
                       "--tpcc_hot_transaction_mode=false", "--tpcc_interactive_ms=0",
                       "--tpcc_retry_same_type=true", "--tpcc_log_retry_conflicts=false",
                       f"--extime={args.seconds}", "--clocks_per_us=2900",
                       f"--tpcc_fixed_active_workers={n}", "--tam_idle_sleep_us=50",
                       "--metis_test_enable=false", "--metis_paper_enable=false",
                       "--ada_tam_enable=false", "--tpcc_pin_workers=true",
                       "--tpcc_pin_order=physical_first"]
            print(f"theta={theta} N={n} run={run}", flush=True)
            with log.open("w") as stream:
                finished = subprocess.run(command, cwd=ROOT, env=environment,
                                          stdout=stream, stderr=subprocess.STDOUT)
            if finished.returncode:
                raise SystemExit(f"Benchmark exited {finished.returncode}: {log}")
            row = {"active_warehouses": 1, "mix": "neworder_only", "theta": theta,
                   "workers": n, "run": run, "seconds": args.seconds, "log": str(log)}
            row.update(parse_log(log, args.seconds))
            with csv_path.open("a", newline="") as stream:
                writer = csv.DictWriter(stream, FIELDS)
                writer.writerow(row)
            present.add((theta, n, run))
            print(f"  TPS={row['tps']} abort={row['abort_rate']}", flush=True)


if __name__ == "__main__":
    main()
