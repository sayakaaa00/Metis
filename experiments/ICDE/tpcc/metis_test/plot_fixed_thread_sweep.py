#!/usr/bin/env python3
"""Plot fixed worker count versus TPC-C TPS for each active-home count."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


STATES = (1, 4, 16, 32, 96)


def config(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if "=" in line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs-dir", type=Path, required=True)
    parser.add_argument("--model-version", default="physical96_fixed_sweep_v1")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    inputs = {}
    for directory in sorted(args.logs_dir.glob(f"{args.model_version}_*")):
        if not (directory / "results.csv").exists():
            continue
        settings = config(directory / "config.txt")
        state = int(settings["active_warehouses"])
        if int(settings["threads"]) != 96 or int(settings["warehouses"]) != 96:
            raise ValueError(f"Unexpected DB or worker count: {directory}")
        if settings["balanced_home_prefix"] != "true" or \
           int(settings["idle_sleep_us"]) != 50:
            raise ValueError(f"Unexpected home assignment or idle sleep: {directory}")
        inputs[state] = directory
    if set(inputs) != set(STATES):
        raise ValueError(f"Expected {STATES}, found {sorted(inputs)}")

    samples = []
    for state in STATES:
        with (inputs[state] / "results.csv").open(newline="") as source:
            for row in csv.DictReader(source):
                samples.append((state, int(row["active_threads"]),
                                int(row["run"]), float(row["tps"]),
                                float(row["abort_rate"])))
    by_condition = defaultdict(list)
    for state, workers, _, tps, _ in samples:
        by_condition[state, workers].append(tps)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with (args.output_dir / "fixed_sweep_samples.csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(("active_home_warehouses", "active_workers", "run",
                         "tps", "abort_rate"))
        writer.writerows(samples)
    with (args.output_dir / "fixed_sweep_summary.csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(("active_home_warehouses", "active_workers", "runs",
                         "mean_tps", "min_tps", "max_tps"))
        for state, workers in sorted(by_condition):
            values = by_condition[state, workers]
            writer.writerow((state, workers, len(values), mean(values),
                             min(values), max(values)))

    fig, ax = plt.subplots(figsize=(10, 6))
    for state in STATES:
        points = sorted((workers, mean(values))
                        for (w, workers), values in by_condition.items()
                        if w == state)
        xs = [x for x, _ in points]
        ys = [y / 1000 for _, y in points]
        line, = ax.plot(xs, ys, "o-", linewidth=1.8, label=f"W={state}")
        peak = max(points, key=lambda p: p[1])
        ax.scatter(peak[0], peak[1] / 1000, s=95, facecolors="none",
                   edgecolors=line.get_color(), linewidths=2)
        ax.annotate(f"{peak[0]}", (peak[0], peak[1] / 1000),
                    xytext=(0, 8), textcoords="offset points", ha="center",
                    fontsize=8, color=line.get_color())
    ax.set_xticks(sorted({workers for _, workers in by_condition}))
    ax.set_xlabel("Active worker threads (96 physical workers created)")
    ax.set_ylabel("Throughput (thousands of transactions/s)")
    ax.set_title("Fixed TPC-C: 96 database warehouses, balanced home assignment")
    ax.grid(alpha=.25)
    ax.legend(title="Active home warehouses")
    fig.tight_layout()
    fig.savefig(args.output_dir / "fixed_thread_sweep.png", dpi=180)
    plt.close(fig)
    print(args.output_dir / "fixed_thread_sweep.png")


if __name__ == "__main__":
    main()
