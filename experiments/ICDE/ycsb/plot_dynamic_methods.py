#!/usr/bin/env python3
"""Plot time series from compare_dynamic_methods.sh results."""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

SAMPLE = re.compile(r"\[TPS sample\] bench_s=([\d.]+) interval_tps=([\d.]+)")
THREAD = re.compile(r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)")
COLORS = {
    "silo_without_backoff": "#7c3aed",
    "silo_with_backoff": "#059669",
    "metis_paper": "#dc2626",
    "adatam": "#2563eb",
}
LABELS = {
    "silo_without_backoff": "Silo without backoff",
    "silo_with_backoff": "Silo with backoff",
    "metis_paper": "Metis-paper",
    "adatam": "AdaTAM",
}


def series(path, pattern):
    bins = defaultdict(list)
    for line in Path(path).read_text().splitlines():
        match = pattern.search(line)
        if match:
            second = int(float(match.group(1)))
            if 0 <= second < 60:
                bins[second].append(float(match.group(2)))
    if len(bins) < 55:
        raise ValueError(f"Too few time bins ({len(bins)}): {path}")
    return {second: sum(values) / len(values) for second, values in bins.items()}


def aggregate(rows, pattern, methods):
    by_method = defaultdict(list)
    for row in rows:
        if row["method"] in methods:
            by_method[row["method"]].append(series(row["trace_log"], pattern))
    return by_method


def write_series(out, traces):
    with out.open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["method", "second", "mean", "min", "max", "runs"])
        for method, runs in traces.items():
            for second in range(60):
                values = [run[second] for run in runs if second in run]
                if values:
                    writer.writerow([method, second, sum(values) / len(values),
                                     min(values), max(values), len(values)])


def draw(out, traces, methods, ylabel, title):
    fig, ax = plt.subplots(figsize=(12, 4.8), layout="constrained")
    for method in methods:
        runs = traces[method]
        seconds = sorted(set.intersection(*(set(run) for run in runs)))
        x = [second + 0.5 for second in seconds]
        mean = [sum(run[second] for run in runs) / len(runs) for second in seconds]
        low = [min(run[second] for run in runs) for second in seconds]
        high = [max(run[second] for run in runs) for second in seconds]
        ax.plot(x, mean, color=COLORS[method], linewidth=1.8,
                label=LABELS[method])
        if len(runs) > 1:
            ax.fill_between(x, low, high, color=COLORS[method], alpha=0.12)
    for switch in (20, 40):
        ax.axvline(switch, color="0.4", linestyle="--", linewidth=0.8)
    ax.set_xlim(0, 60)
    ax.set_xlabel("Time from benchmark start (s)")
    ax.set_ylabel(ylabel)
    ax.set_title(title, pad=32)
    ax.grid(alpha=0.2)
    ax.legend(loc="upper right")
    ax.text(10, 1.01, "skew 0.70", ha="center", transform=ax.get_xaxis_transform())
    ax.text(30, 1.01, "skew 0.95", ha="center", transform=ax.get_xaxis_transform())
    ax.text(50, 1.01, "skew 0.80", ha="center", transform=ax.get_xaxis_transform())
    fig.savefig(out, dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()
    result_dir = args.result_dir
    with (result_dir / "results.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    tps_methods = ("silo_without_backoff", "silo_with_backoff", "metis_paper")
    threads_methods = ("metis_paper", "adatam")
    tps = aggregate(rows, SAMPLE, tps_methods)
    threads = aggregate(rows, THREAD, threads_methods)
    for method in (*tps_methods, "adatam"):
        if method not in {row["method"] for row in rows}:
            raise ValueError(f"Missing result: {method}")
    write_series(result_dir / "tps_timeseries.csv", tps)
    write_series(result_dir / "active_threads_timeseries.csv", threads)
    draw(result_dir / "tps_timeseries.png", tps, tps_methods,
         "Throughput (TPS)", "Dynamic YCSB: throughput over time")
    draw(result_dir / "active_threads_timeseries.png", threads, threads_methods,
         "Active threads", "Dynamic YCSB: active threads over time")


if __name__ == "__main__":
    main()
