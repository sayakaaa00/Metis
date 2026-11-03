#!/usr/bin/env python3
"""Plot fixed-load active workers and TPS for Metis-test versus AdaTAM."""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


WAREHOUSES = (1, 4, 16, 32, 96)
METHODS = ("metis_test", "adatam")
COLORS = {"metis_test": "#9467bd", "adatam": "#ff7f0e"}
LABELS = {"metis_test": "Metis-test", "adatam": "AdaTAM"}
SAMPLE = re.compile(r"\[TAM sample\] bench_s=([0-9.]+) active_threads=(\d+)")


def save_csv(path, header, rows):
    with path.open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(header)
        writer.writerows(rows)


def read_samples(path):
    values = [(float(time), int(threads))
              for time, threads in SAMPLE.findall(path.read_text(errors="replace"))]
    if len(values) < 10 or any(b[0] <= a[0] for a, b in zip(values, values[1:])):
        raise ValueError(f"Missing or unordered thread samples: {path}")
    return values


def draw(axis, warehouse, traces, tps, duration, compact=False,
         methods=METHODS):
    for method in methods:
        for run in (1, 2):
            samples = traces[warehouse, method, run]
            times = [0.0] + [time for time, _ in samples] + [duration]
            threads = [96] + [value for _, value in samples]
            axis.step(times, threads + [threads[-1]], where="post",
                      color=COLORS[method],
                      linestyle="-" if run == 1 else "--",
                      linewidth=1.55 if compact else 1.8,
                      alpha=.85, label=f"{LABELS[method]} run {run}")
    metis = mean(tps[warehouse, "metis_test"])
    ada = mean(tps[warehouse, "adatam"])
    title = (f"W={warehouse}  |  Metis {metis:,.0f} TPS, AdaTAM {ada:,.0f} TPS"
             if len(methods) == 2 else
             f"W={warehouse}  |  Metis-test {metis:,.0f} TPS")
    axis.set_title(title, fontsize=10 if compact else 12)
    axis.set_xlim(0, duration)
    axis.set_ylim(0, 101)
    axis.set_yticks((8, 16, 24, 32, 48, 64, 96))
    axis.set_xlabel("Time (s)")
    axis.set_ylabel("Active workers")
    axis.grid(alpha=.3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-dir", type=Path, required=True)
    args = parser.parse_args()
    directory = args.experiment_dir
    config = dict(line.split("=", 1) for line in
                  (directory / "config.txt").read_text().splitlines()
                  if "=" in line)
    duration = float(config["fixed_extime"])
    with (directory / "results.csv").open(newline="") as source:
        rows = list(csv.DictReader(source))
    expected = {(w, m, r) for w in WAREHOUSES for m in METHODS for r in (1, 2)}
    actual = {(int(row["warehouse"]), row["method"], int(row["run"]))
              for row in rows}
    if actual != expected or len(rows) != len(expected):
        raise ValueError(f"Expected {len(expected)} unique fixed-load runs")
    traces = {}
    tps = defaultdict(list)
    summaries = []
    thread_rows = []
    for row in rows:
        warehouse = int(row["warehouse"])
        method = row["method"]
        run = int(row["run"])
        samples = read_samples(Path(row["trace"]))
        traces[warehouse, method, run] = samples
        tps[warehouse, method].append(int(row["tps"]))
        settled = [n for time, n in samples if time >= 2.0]
        summaries.append((method, warehouse, run, row["tps"],
                          f"{mean(settled):.1f}", min(settled), max(settled)))
        thread_rows.extend((method, warehouse, run, f"{time:.3f}", n)
                           for time, n in samples)
    save_csv(directory / "thread_samples.csv",
             ("method", "warehouse", "run", "bench_s", "active_threads"),
             thread_rows)
    save_csv(directory / "run_summary.csv",
             ("method", "warehouse", "run", "tps", "mean_threads_after_2s",
              "min_threads_after_2s", "max_threads_after_2s"), summaries)
    save_csv(directory / "tps_summary.csv",
             ("warehouse", "metis_mean_tps", "adatam_mean_tps", "metis_vs_adatam_pct"),
             [(w, round(mean(tps[w, "metis_test"])),
               round(mean(tps[w, "adatam"])),
               f"{100 * (mean(tps[w, 'metis_test']) / mean(tps[w, 'adatam']) - 1):.2f}")
              for w in WAREHOUSES])

    figure_dir = directory / "figures"
    figure_dir.mkdir(exist_ok=True)
    for warehouse in WAREHOUSES:
        fig, axis = plt.subplots(figsize=(10, 5))
        draw(axis, warehouse, traces, tps, duration)
        axis.legend(ncol=2, loc="upper right")
        fig.tight_layout()
        fig.savefig(figure_dir / f"comparison_threads_w{warehouse}.png", dpi=180)
        plt.close(fig)
        fig, axis = plt.subplots(figsize=(10, 5))
        draw(axis, warehouse, traces, tps, duration,
             methods=("metis_test",))
        axis.legend(ncol=2, loc="upper right")
        fig.tight_layout()
        fig.savefig(figure_dir / f"metis_threads_w{warehouse}.png", dpi=180)
        plt.close(fig)
    fig, axes = plt.subplots(3, 2, figsize=(14, 12), sharex=True, sharey=True)
    for warehouse, axis in zip(WAREHOUSES, axes.flat):
        draw(axis, warehouse, traces, tps, duration, compact=True)
    axes.flat[-1].axis("off")
    axes.flat[-1].legend(*axes.flat[0].get_legend_handles_labels(),
                         loc="center", fontsize=11)
    fig.suptitle("TPC-C fixed loads: active worker counts under mimalloc",
                 fontsize=16)
    fig.tight_layout(rect=(0, 0, 1, .97))
    fig.savefig(figure_dir / "comparison_threads_overview.png", dpi=180)
    plt.close(fig)

    fig, axes = plt.subplots(3, 2, figsize=(14, 12), sharex=True, sharey=True)
    for warehouse, axis in zip(WAREHOUSES, axes.flat):
        draw(axis, warehouse, traces, tps, duration, compact=True,
             methods=("metis_test",))
    axes.flat[-1].axis("off")
    axes.flat[-1].legend(*axes.flat[0].get_legend_handles_labels(),
                         loc="center", fontsize=11)
    fig.suptitle("Metis-test: active workers at each fixed TPC-C load",
                 fontsize=16)
    fig.tight_layout(rect=(0, 0, 1, .97))
    fig.savefig(figure_dir / "metis_threads_overview.png", dpi=180)
    plt.close(fig)

    fig, axis = plt.subplots(figsize=(9, 5))
    for method in METHODS:
        averages = [mean(tps[w, method]) / 1000 for w in WAREHOUSES]
        axis.plot(WAREHOUSES, averages, "o-", color=COLORS[method],
                  label=LABELS[method], linewidth=2)
    axis.set_xticks(WAREHOUSES)
    axis.set_xlabel("Fixed active home warehouses")
    axis.set_ylabel("Mean throughput (thousand TPS; log scale)")
    axis.set_yscale("log")
    axis.set_title("Metis-test vs AdaTAM: fixed TPC-C under mimalloc")
    axis.grid(alpha=.3)
    axis.legend()
    fig.tight_layout()
    fig.savefig(figure_dir / "tps_comparison.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
