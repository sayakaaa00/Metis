#!/usr/bin/env python3
"""Repeatable fixed-worker Silo TPC-C item-Zipf sweep."""

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
TYPES = ("NewOrder", "Payment", "OrderStatus", "Delivery", "StockLevel")
FIELDS = ["theta", "workers", "run", "seconds", "tps", "abort_rate", "log"]
for tx_type in TYPES:
    FIELDS += [f"{tx_type}_commits", f"{tx_type}_aborts", f"{tx_type}_tps", f"{tx_type}_abort_rate"]


def parse_log(path: Path, seconds: int) -> dict:
    body = path.read_text()
    def number(pattern: str) -> str:
        match = re.search(pattern, body)
        if match is None:
            raise ValueError(f"Missing {pattern} in {path}")
        return match.group(1)

    row = {
        "tps": number(r"(?m)^throughput\[tps\]:\s+(\d+)"),
        "abort_rate": number(r"(?m)^abort_rate:\s+([0-9.]+)"),
    }
    for tx_type in TYPES:
        block = re.search(rf"Transaction type: {tx_type}\n(.*?)(?=  Transaction type:|  Summary:)", body, re.S)
        if block is None:
            raise ValueError(f"Missing {tx_type} in {path}")
        commits = int(re.search(r"commits:\s+(\d+)", block[1])[1])
        aborts = int(re.search(r"aborts:\s+(\d+)", block[1])[1])
        row[f"{tx_type}_commits"] = commits
        row[f"{tx_type}_aborts"] = aborts
        row[f"{tx_type}_tps"] = commits / seconds
        row[f"{tx_type}_abort_rate"] = aborts / (commits + aborts) if commits + aborts else 0
    return row


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--workers", required=True, nargs="+", type=int)
    parser.add_argument("--thetas", nargs="+", type=float, default=[0, 0.7, 0.8, 0.95])
    parser.add_argument("--seconds", type=int, default=8)
    parser.add_argument("--runs", type=int, default=1)
    args = parser.parse_args()
    if min(args.workers) < 1 or max(args.workers) > 96 or args.seconds < 1 or args.runs < 1:
        parser.error("workers must be 1..96 and seconds/runs must be positive")

    binary = ROOT / "build_release/silo/tpcc_silo_without_backoff"
    allocator = ROOT / "build_release/mimalloc_override/libmimalloc.so"
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "logs").mkdir(exist_ok=True)
    config = {
        "binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "allocator": str(allocator), "allocator_sha256": hashlib.sha256(allocator.read_bytes()).hexdigest(),
        "database_warehouses": 1, "active_warehouses": 1, "items": 100000,
        "software_workers": 96, "mix": "45/43/4/4/4", "controller": "none",
        "backoff": False, "pin_order": "physical_first", "item_zipf_seed": 1,
        "thetas": args.thetas, "workers": args.workers, "seconds": args.seconds, "runs": args.runs,
    }
    config_path = args.out / "config.json"
    if config_path.exists() and json.loads(config_path.read_text()) != config:
        raise SystemExit(f"Configuration differs from existing {config_path}")
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    csv_path = args.out / "results.csv"
    present = set()
    if csv_path.exists():
        with csv_path.open(newline="") as stream:
            for row in csv.DictReader(stream):
                present.add((row["theta"], int(row["workers"]), int(row["run"])))
    else:
        with csv_path.open("w", newline="") as stream:
            csv.DictWriter(stream, FIELDS).writeheader()

    environment = os.environ.copy()
    environment["LD_PRELOAD"] = str(allocator)
    for run in range(1, args.runs + 1):
        # Reverse candidate order on even repetitions to reduce time-order bias.
        workers = args.workers if run % 2 else list(reversed(args.workers))
        for theta in args.thetas:
            for n in workers:
                tag = (str(theta), n, run)
                if tag in present:
                    continue
                log = args.out / "logs" / f"theta_{theta}_n{n}_run{run}.log"
                command = [str(binary), "--thread_num=96", "--tpcc_num_wh=1",
                           "--tpcc_active_warehouse_count=1", "--tpcc_num_items=100000",
                           "--tpcc_item_zipf_enable=true", f"--tpcc_item_zipf_skew={theta}",
                           "--tpcc_item_zipf_seed=1", "--tpcc_perc_payment=43",
                           "--tpcc_perc_order_status=4", "--tpcc_perc_delivery=4",
                           "--tpcc_perc_stock_level=4", "--tpcc_hot_item_ratio=0",
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
                    raise SystemExit(f"Benchmark failed with exit {finished.returncode}: {log}")
                row = {"theta": theta, "workers": n, "run": run,
                       "seconds": args.seconds, "log": str(log)}
                row.update(parse_log(log, args.seconds))
                with csv_path.open("a", newline="") as stream:
                    writer = csv.DictWriter(stream, FIELDS)
                    writer.writerow(row)
                present.add(tag)
                print(f"  TPS={row['tps']} abort={row['abort_rate']}", flush=True)


if __name__ == "__main__":
    main()
