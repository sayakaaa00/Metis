#!/usr/bin/env python3
"""Plot controller threads and Silo/Metis TPS for a live W schedule."""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


THREAD = re.compile(r"\[TAM sample\] bench_s=([0-9.]+) active_threads=(\d+)")
TPS = re.compile(r"\[Metis-test\].*?bench_s=([0-9.]+).*?tput=([0-9.]+)")
SWITCH = re.compile(
    r"\[TPC-C workload\] bench_s=([0-9.]+) active_warehouses=(\d+)[ \t]*$",
    re.MULTILINE)
COLORS = {"metis_test": "#9467bd", "adatam": "#ff7f0e",
          "silo_without_backoff": "#1f77b4", "silo_with_backoff": "#2ca02c"}
LABELS = {"metis_test": "Metis-test", "adatam": "AdaTAM (step=4)",
          "silo_without_backoff": "Silo without backoff",
          "silo_with_backoff": "Silo with backoff"}

def parse_phases(schedule, duration):
    changes = [tuple(map(int, item.split(":"))) for item in schedule.split(",")]
    if not changes or changes[0][0] != 0 or any(
            a[0] >= b[0] for a, b in zip(changes, changes[1:])):
        raise ValueError(f"Invalid warehouse schedule: {schedule}")
    return [(start, changes[index + 1][0] if index + 1 < len(changes)
             else duration, warehouse)
            for index, (start, warehouse) in enumerate(changes)]


def save_csv(path, header, rows):
    with path.open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(header)
        writer.writerows(rows)


def read_trace(path, expected_warehouses, duration):
    content = path.read_text(errors="replace")
    threads = [(float(t), int(n)) for t, n in THREAD.findall(content)]
    tps = [(float(t), float(v)) for t, v in TPS.findall(content)]
    changes = [(float(t), int(w)) for t, w in SWITCH.findall(content)]
    if (len(threads) < duration * 4 or
            [w for _, w in changes] != expected_warehouses):
        raise ValueError(f"Incomplete dynamic trace: {path}")
    if any(b[0] <= a[0] for a, b in zip(threads, threads[1:])):
        raise ValueError(f"Unordered thread samples: {path}")
    return threads, tps, changes


def decorate(axis, ylabel, phases, duration):
    for start, end, warehouse in phases:
        axis.axvspan(start, end, color="gray", alpha=.035)
        if start:
            axis.axvline(start, color="black", linestyle=":", linewidth=1)
        axis.text((start + end) / 2, .97, f"W={warehouse}",
                  transform=axis.get_xaxis_transform(), ha="center", va="top",
                  fontsize=10)
    axis.set_xlim(0, duration)
    axis.set_xlabel("Time from benchmark start (s)")
    axis.set_ylabel(ylabel)
    axis.grid(alpha=.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-dir", type=Path, required=True)
    args = parser.parse_args()
    directory = args.experiment_dir
    config = dict(line.split("=", 1) for line in
                  (directory / "config.txt").read_text().splitlines()
                  if "=" in line)
    duration = int(config["extime"])
    phases = parse_phases(config["schedule"], duration)
    expected_warehouses = [warehouse for _, _, warehouse in phases]
    variant = config.get("metis_variant", "observed")
    labels = dict(LABELS)
    labels["metis_test"] = ("Metis-test (warehouse-aware)" if variant ==
                            "warehouse_aware" else "Metis-test (observed)")
    with (directory / "results.csv").open(newline="") as source:
        rows = list(csv.DictReader(source))
    expected = {(method, run) for method in LABELS for run in (1, 2)}
    actual = {(row["method"], int(row["run"])) for row in rows}
    if len(rows) != len(expected) or actual != expected:
        raise ValueError("Expected two complete runs for all four methods")
    traces = {}
    thread_rows, tps_rows, phase_rows = [], [], []
    totals = defaultdict(list)
    for row in rows:
        method, run = row["method"], int(row["run"])
        threads, samples, changes = read_trace(
            Path(row["trace"]), expected_warehouses, duration)
        traces[method, run] = (threads, samples)
        totals[method].append(int(row["tps"]))
        thread_rows.extend((method, run, f"{t:.3f}", n) for t, n in threads)
        tps_rows.extend((method, run, f"{t:.3f}", round(v)) for t, v in samples)
        if method != "adatam":
            for start, end, warehouse in phases:
                settled = [v for t, v in samples if start + 2 <= t < end]
                if not settled:
                    raise ValueError(f"Missing settled interval in {row['trace']}")
                phase_rows.append((method, run, warehouse, round(mean(settled))))
    save_csv(directory / "thread_samples.csv",
             ("method", "run", "bench_s", "active_threads"), thread_rows)
    save_csv(directory / "tps_samples.csv",
             ("method", "run", "bench_s", "interval_tps"), tps_rows)
    save_csv(directory / "phase_tps.csv",
             ("method", "run", "active_warehouses", "mean_tps_after_2s"),
             phase_rows)
    save_csv(directory / "overall_summary.csv",
             ("method", "runs", "mean_tps", "min_tps", "max_tps"),
             [(method, len(totals[method]), round(mean(totals[method])),
               min(totals[method]), max(totals[method])) for method in LABELS])

    figure_dir = directory / "figures"
    figure_dir.mkdir(exist_ok=True)
    fig, axis = plt.subplots(figsize=(12, 5))
    for method in ("metis_test", "adatam"):
        for run in (1, 2):
            threads, _ = traces[method, run]
            times = [0.0] + [t for t, _ in threads] + [duration]
            values = [96] + [n for _, n in threads]
            axis.step(times, values + [values[-1]], where="post",
                      color=COLORS[method], linestyle="-" if run == 1 else "--",
                      linewidth=1.5, alpha=.82,
                      label=f"{labels[method]} run {run}")
    decorate(axis, "Active workers", phases, duration)
    axis.set_ylim(0, 104)
    axis.set_yticks((8, 16, 24, 32, 48, 64, 96))
    axis.set_title("TPC-C live load: Metis-test vs AdaTAM active threads")
    axis.legend(ncol=2, loc="upper center", bbox_to_anchor=(.5, -.18))
    fig.tight_layout()
    fig.savefig(figure_dir / "active_threads.png", dpi=180)
    plt.close(fig)

    fig, axis = plt.subplots(figsize=(12, 5))
    for method in ("silo_without_backoff", "silo_with_backoff", "metis_test"):
        for run in (1, 2):
            _, samples = traces[method, run]
            axis.plot([t for t, _ in samples], [v / 1000 for _, v in samples],
                      color=COLORS[method], linestyle="-" if run == 1 else "--",
                      linewidth=1.35, alpha=.8,
                      label=f"{labels[method]} run {run}")
    decorate(axis, "Interval throughput (thousand TPS)", phases, duration)
    highest = max(v for method in ("silo_without_backoff",
                                   "silo_with_backoff", "metis_test")
                  for run in (1, 2) for _, v in traces[method, run][1])
    axis.set_ylim(0, highest / 1000 * 1.15)
    axis.set_title("TPC-C live load: Silo and Metis-test TPS")
    axis.legend(ncol=3, loc="upper center", bbox_to_anchor=(.5, -.18),
                fontsize=8)
    fig.tight_layout()
    fig.savefig(figure_dir / "tps.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
