#!/usr/bin/env python3
"""Summarize paired Metis-test-SMT worker pinning A/B measurements."""

import argparse
import csv
import re
import statistics
from collections import Counter, defaultdict
from pathlib import Path


def modal_threads(trace: Path) -> int:
    counts: Counter[int] = Counter()
    pattern = re.compile(r"\[TAM sample\] bench_s=([0-9.]+) active_threads=(\d+)")
    for line in trace.read_text().splitlines():
        match = pattern.search(line)
        if match and float(match.group(1)) >= 2:
            counts[int(match.group(2))] += 1
    if not counts:
        raise ValueError(f"No active-thread samples after 2 seconds: {trace}")
    return counts.most_common(1)[0][0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    groups: dict[int, dict[str, dict[int, dict]]] = defaultdict(lambda: defaultdict(dict))
    with (args.output / "results.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            w, run, pin = int(row["warehouse"]), int(row["run"]), row["pin_workers"]
            row["tps"] = int(row["tps"])
            row["abort_rate"] = float(row["abort_rate"])
            row["modal_threads"] = modal_threads(Path(row["trace"]))
            groups[w][pin][run] = row
    fields = ["warehouse", "pin_on_mean_tps", "pin_off_mean_tps", "pin_on_gain_pct",
              "pin_on_run1_tps", "pin_off_run1_tps", "pin_on_run2_tps",
              "pin_off_run2_tps", "pin_on_mean_abort_rate", "pin_off_mean_abort_rate",
              "pin_on_modal_threads", "pin_off_modal_threads"]
    with (args.output / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for w, modes in sorted(groups.items()):
            if set(modes) != {"true", "false"} or set(modes["true"]) != {1, 2} or set(modes["false"]) != {1, 2}:
                raise ValueError(f"Incomplete paired runs for W={w}")
            on = modes["true"]
            off = modes["false"]
            on_mean = statistics.mean(on[r]["tps"] for r in (1, 2))
            off_mean = statistics.mean(off[r]["tps"] for r in (1, 2))
            writer.writerow({
                "warehouse": w,
                "pin_on_mean_tps": round(on_mean),
                "pin_off_mean_tps": round(off_mean),
                "pin_on_gain_pct": round(100 * (on_mean / off_mean - 1), 2),
                "pin_on_run1_tps": on[1]["tps"],
                "pin_off_run1_tps": off[1]["tps"],
                "pin_on_run2_tps": on[2]["tps"],
                "pin_off_run2_tps": off[2]["tps"],
                "pin_on_mean_abort_rate": round(statistics.mean(on[r]["abort_rate"] for r in (1, 2)), 4),
                "pin_off_mean_abort_rate": round(statistics.mean(off[r]["abort_rate"] for r in (1, 2)), 4),
                "pin_on_modal_threads": "/".join(str(on[r]["modal_threads"]) for r in (1, 2)),
                "pin_off_modal_threads": "/".join(str(off[r]["modal_threads"]) for r in (1, 2)),
            })


if __name__ == "__main__":
    main()
