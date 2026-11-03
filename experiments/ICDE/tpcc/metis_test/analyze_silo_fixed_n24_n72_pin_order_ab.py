#!/usr/bin/env python3
"""Summarize paired Silo fixed-N physical-first/socket0-first TPC-C runs."""

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    groups: dict[tuple[int, int], dict[str, dict[int, dict]]] = defaultdict(
        lambda: defaultdict(dict))
    with (args.output / "results.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            key = int(row["warehouse"]), int(row["active_threads"])
            order, run = row["pin_order"], int(row["run"])
            if run in groups[key][order]:
                raise ValueError(f"Duplicate result: {key}, {order}, {run}")
            groups[key][order][run] = row
    fields = ["warehouse", "active_threads", "physical_first_mean_tps",
              "socket0_first_mean_tps", "physical_first_gain_pct",
              "physical_first_run1_tps", "physical_first_run2_tps",
              "socket0_first_run1_tps", "socket0_first_run2_tps",
              "physical_first_mean_abort_rate", "socket0_first_mean_abort_rate"]
    with (args.output / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for (w, n), orders in sorted(groups.items()):
            if set(orders) != {"physical_first", "socket0_first"} or any(
                set(orders[o]) != {1, 2} for o in orders
            ):
                raise ValueError(f"Incomplete pair: W={w}, N={n}")
            a = orders["physical_first"]
            b = orders["socket0_first"]
            a_tps = [int(a[r]["tps"]) for r in (1, 2)]
            b_tps = [int(b[r]["tps"]) for r in (1, 2)]
            a_mean, b_mean = statistics.mean(a_tps), statistics.mean(b_tps)
            writer.writerow({
                "warehouse": w, "active_threads": n,
                "physical_first_mean_tps": round(a_mean),
                "socket0_first_mean_tps": round(b_mean),
                "physical_first_gain_pct": round(100 * (a_mean / b_mean - 1), 2),
                "physical_first_run1_tps": a_tps[0],
                "physical_first_run2_tps": a_tps[1],
                "socket0_first_run1_tps": b_tps[0],
                "socket0_first_run2_tps": b_tps[1],
                "physical_first_mean_abort_rate": round(statistics.mean(
                    float(a[r]["abort_rate"]) for r in (1, 2)), 4),
                "socket0_first_mean_abort_rate": round(statistics.mean(
                    float(b[r]["abort_rate"]) for r in (1, 2)), 4),
            })


if __name__ == "__main__":
    main()
