#!/usr/bin/env python3
"""Pilot: distinguish item skew from W=1 Payment and District bottlenecks."""

import csv
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
TYPES = ("NewOrder", "Payment", "OrderStatus", "Delivery", "StockLevel")
FIELDS = ["active_warehouses", "mix", "theta", "workers", "run", "seconds",
          "tps", "abort_rate", "log"]
for name in TYPES:
    FIELDS += [f"{name}_commits", f"{name}_aborts", f"{name}_tps", f"{name}_abort_rate"]


def parse_log(path: Path, seconds: int) -> dict:
    body = path.read_text()
    result = {
        "tps": int(re.search(r"(?m)^throughput\[tps\]:\s+(\d+)", body)[1]),
        "abort_rate": float(re.search(r"(?m)^abort_rate:\s+([0-9.]+)", body)[1]),
    }
    for name in TYPES:
        block = re.search(rf"Transaction type: {name}\n(.*?)(?=  Transaction type:|  Summary:)", body, re.S)
        if block is None:
            raise ValueError(f"Missing {name} in {path}")
        commits = int(re.search(r"commits:\s+(\d+)", block[1])[1])
        aborts = int(re.search(r"aborts:\s+(\d+)", block[1])[1])
        result[f"{name}_commits"] = commits
        result[f"{name}_aborts"] = aborts
        result[f"{name}_tps"] = commits / seconds
        result[f"{name}_abort_rate"] = aborts / (commits + aborts) if commits + aborts else 0
    return result


def main() -> None:
    binary = ROOT / "build_release/silo/tpcc_silo_without_backoff"
    allocator = ROOT / "build_release/mimalloc_override/libmimalloc.so"
    output = HERE / "contention_pilot_10s"
    (output / "logs").mkdir(parents=True, exist_ok=True)
    config = {
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "allocator_sha256": hashlib.sha256(allocator.read_bytes()).hexdigest(),
        "database_warehouses": 16, "items": 100000,
        "active_warehouses": [1, 8], "mixes": ["standard", "neworder_only"],
        "thetas": [0, 0.95], "workers_by_w": {"1": 8, "8": 48},
        "seconds": 10, "runs": 2, "software_workers": 96,
        "pin_order": "physical_first", "backoff": False,
        "home_assignment": "random_per_transaction", "item_zipf_seed": 1,
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
                present.add((int(row["active_warehouses"]), row["mix"],
                             float(row["theta"]), int(row["run"])))
    else:
        with csv_path.open("w", newline="") as stream:
            csv.DictWriter(stream, FIELDS).writeheader()
    conditions = [(w, mix, theta) for w in (1, 8)
                  for mix in ("standard", "neworder_only") for theta in (0, 0.95)]
    environment = os.environ.copy()
    environment["LD_PRELOAD"] = str(allocator)
    for run in (1, 2):
        for w, mix, theta in conditions if run == 1 else reversed(conditions):
            if (w, mix, theta, run) in present:
                continue
            n = 8 if w == 1 else 48
            log = output / "logs" / f"w{w}_{mix}_theta{theta}_run{run}.log"
            payment, other = (43, 4) if mix == "standard" else (0, 0)
            command = [str(binary), "--thread_num=96", "--tpcc_num_wh=16",
                       f"--tpcc_active_warehouse_count={w}", "--tpcc_num_items=100000",
                       "--tpcc_home_warehouse_assignment=random_per_transaction",
                       "--tpcc_item_zipf_enable=true", f"--tpcc_item_zipf_skew={theta}",
                       "--tpcc_item_zipf_seed=1", f"--tpcc_perc_payment={payment}",
                       f"--tpcc_perc_order_status={other}", f"--tpcc_perc_delivery={other}",
                       f"--tpcc_perc_stock_level={other}", "--tpcc_hot_item_ratio=0",
                       "--tpcc_hot_transaction_mode=false", "--tpcc_interactive_ms=0",
                       "--tpcc_retry_same_type=true", "--tpcc_log_retry_conflicts=false",
                       "--extime=10", "--clocks_per_us=2900",
                       f"--tpcc_fixed_active_workers={n}", "--tam_idle_sleep_us=50",
                       "--metis_test_enable=false", "--metis_paper_enable=false",
                       "--ada_tam_enable=false", "--tpcc_pin_workers=true",
                       "--tpcc_pin_order=physical_first"]
            print(f"W={w} mix={mix} theta={theta} N={n} run={run}", flush=True)
            with log.open("w") as stream:
                finished = subprocess.run(command, cwd=ROOT, env=environment,
                                          stdout=stream, stderr=subprocess.STDOUT)
            if finished.returncode:
                raise SystemExit(f"Benchmark exited {finished.returncode}: {log}")
            row = {"active_warehouses": w, "mix": mix, "theta": theta,
                   "workers": n, "run": run, "seconds": 10, "log": str(log)}
            row.update(parse_log(log, 10))
            with csv_path.open("a", newline="") as stream:
                writer = csv.DictWriter(stream, FIELDS)
                writer.writerow(row)
            present.add((w, mix, theta, run))
            print(f"  TPS={row['tps']} abort={row['abort_rate']}", flush=True)


if __name__ == "__main__":
    main()
