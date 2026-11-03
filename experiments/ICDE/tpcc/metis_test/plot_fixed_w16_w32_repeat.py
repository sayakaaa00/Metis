#!/usr/bin/env python3
"""Summarize the additional two-run TPC-C worker sweeps for W=16 and 32."""

import argparse
import csv
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


STATES = (16, 32)
WORKERS = (8, 16, 24, 32, 48, 64, 96)


def read_config(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if "=" in line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs-dir", type=Path, required=True)
    parser.add_argument("--prefix", default="physical96_w16w32_repeat2_v1")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    inputs = {}
    for directory in sorted(args.logs_dir.glob(f"{args.prefix}_*")):
        if not (directory / "results.csv").exists():
            continue
        settings = read_config(directory / "config.txt")
        state = int(settings["active_warehouses"])
        if state not in STATES:
            continue
        for key, value in {
            "threads": "96", "warehouses": "96", "home_assignment":
            "randomized_worker_affined", "seed": "1", "balanced_home_prefix":
            "true", "idle_sleep_us": "50", "extime": "15", "runs": "2",
            "fixed_values": "8 16 24 32 48 64 96",
        }.items():
            if settings.get(key) != value:
                raise ValueError(f"Unexpected {key} in {directory}")
        if state in inputs:
            raise ValueError(f"Multiple directories for W={state}: {directory}")
        inputs[state] = directory
    if set(inputs) != set(STATES):
        raise ValueError(f"Expected W={STATES}, found {sorted(inputs)}")

    samples = {}
    seen_runs = set()
    for state, directory in inputs.items():
        with (directory / "results.csv").open(newline="") as source:
            rows = list(csv.DictReader(source))
        if len(rows) != len(WORKERS) * 2:
            raise ValueError(f"Incomplete sweep: {directory}")
        for row in rows:
            key = state, int(row["active_threads"])
            run = int(row["run"])
            if key[1] not in WORKERS or run not in (1, 2) or \
               (key, run) in seen_runs:
                raise ValueError(f"Unexpected or duplicate result: {directory}")
            seen_runs.add((key, run))
            samples.setdefault(key, []).append(int(row["tps"]))
            if float(row["actual_extime"]) != 15:
                raise ValueError(f"Unexpected duration: {directory}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    summary_path = args.output_dir / "two_run_mean_tps.csv"
    with summary_path.open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(("active_home_warehouses", "active_workers", "run1_tps",
                         "run2_tps", "mean_tps", "min_tps", "max_tps"))
        for state in STATES:
            for workers in WORKERS:
                values = samples[state, workers]
                if len(values) != 2:
                    raise ValueError(f"Expected 2 runs for W={state}, N={workers}")
                writer.writerow((state, workers, *values, mean(values),
                                 min(values), max(values)))

    fig, ax = plt.subplots(figsize=(10, 6))
    for state in STATES:
        groups = [samples[state, workers] for workers in WORKERS]
        averages = [mean(values) / 1000 for values in groups]
        lower = [mean(values) / 1000 - min(values) / 1000 for values in groups]
        upper = [max(values) / 1000 - mean(values) / 1000 for values in groups]
        ax.errorbar(WORKERS, averages, yerr=[lower, upper], fmt="o-",
                    capsize=3, linewidth=1.8, label=f"W={state}")
    ax.set_xticks(WORKERS)
    ax.set_xlabel("Active worker threads N (96 OS workers created)")
    ax.set_ylabel("Throughput (thousands of transactions/s)")
    ax.set_title("TPC-C fixed workload: two additional 15 s runs per point")
    ax.grid(alpha=.25)
    ax.legend(title="Active home warehouses")
    fig.tight_layout()
    fig.savefig(args.output_dir / "two_run_mean_tps.png", dpi=180)
    plt.close(fig)
    print(summary_path)


if __name__ == "__main__":
    main()
