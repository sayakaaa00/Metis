#!/usr/bin/env python3
"""Summarize the fixed-N, no-controller TPC-C placement comparison."""

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    groups: dict[int, dict[str, dict[int, dict]]] = defaultdict(lambda: defaultdict(dict))
    with (args.output / "results.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            w = int(row["warehouse"])
            run = int(row["run"])
            mode = row["placement"]
            if run in groups[w][mode]:
                raise ValueError(f"Duplicate run: W={w}, mode={mode}, run={run}")
            groups[w][mode][run] = row
    fields = ["warehouse", "active_threads"]
    modes = ("os_scheduler", "socket0_first", "physical_first")
    for mode in modes:
        fields += [f"{mode}_mean_tps", f"{mode}_run1_tps", f"{mode}_run2_tps",
                   f"{mode}_mean_abort_rate"]
    fields += ["socket0_first_vs_os_pct", "physical_first_vs_os_pct",
               "physical_first_vs_socket0_pct"]
    with (args.output / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for w, by_mode in sorted(groups.items()):
            if set(by_mode) != set(modes) or any(set(by_mode[m]) != {1, 2} for m in modes):
                raise ValueError(f"Incomplete runs for W={w}")
            counts = {int(by_mode[m][r]["active_threads"]) for m in modes for r in (1, 2)}
            if len(counts) != 1:
                raise ValueError(f"Inconsistent active N for W={w}: {counts}")
            result = {"warehouse": w, "active_threads": counts.pop()}
            means = {}
            for mode in modes:
                runs = by_mode[mode]
                tps = [int(runs[r]["tps"]) for r in (1, 2)]
                means[mode] = statistics.mean(tps)
                result[f"{mode}_mean_tps"] = round(means[mode])
                result[f"{mode}_run1_tps"] = tps[0]
                result[f"{mode}_run2_tps"] = tps[1]
                result[f"{mode}_mean_abort_rate"] = round(
                    statistics.mean(float(runs[r]["abort_rate"]) for r in (1, 2)), 4)
            result["socket0_first_vs_os_pct"] = round(
                100 * (means["socket0_first"] / means["os_scheduler"] - 1), 2)
            result["physical_first_vs_os_pct"] = round(
                100 * (means["physical_first"] / means["os_scheduler"] - 1), 2)
            result["physical_first_vs_socket0_pct"] = round(
                100 * (means["physical_first"] / means["socket0_first"] - 1), 2)
            writer.writerow(result)


if __name__ == "__main__":
    main()
