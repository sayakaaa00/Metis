#!/usr/bin/env python3
"""Summarize fixed and live TPC-C workload results across protocols."""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


STATES = (1, 4, 16, 32, 96)
METHODS = (
    "silo_without_backoff", "silo_with_backoff", "cicada", "ermia",
    "observed_metis",
)
LABELS = {
    "silo_without_backoff": "Silo, no backoff",
    "silo_with_backoff": "Silo, backoff",
    "cicada": "Cicada",
    "ermia": "ERMIA",
    "observed_metis": "Metis-test observed",
}
FIELDS = re.compile(r"([a-z_]+)=([0-9.]+|[a-z_]+)")


def rows(path):
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def save_csv(path, header, data):
    with path.open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(header)
        writer.writerows(data)


def fixed(data, output, methods):
    values = defaultdict(list)
    for row in data:
        values[row["method"], int(row["warehouse"])].append(float(row["tps"]))
    summary = []
    fig, ax = plt.subplots(figsize=(10, 6))
    xs = list(range(len(STATES)))
    for method in methods:
        points = [values[method, w] for w in STATES]
        if any(not v for v in points):
            raise ValueError(f"Missing fixed results for {method}")
        averages = [mean(v) / 1000 for v in points]
        lower = [mean(v) / 1000 - min(v) / 1000 for v in points]
        upper = [max(v) / 1000 - mean(v) / 1000 for v in points]
        ax.errorbar(xs, averages, yerr=[lower, upper], fmt="o-", capsize=3,
                    linewidth=1.7, label=LABELS[method])
        for warehouse, group in zip(STATES, points):
            summary.append((method, warehouse, len(group), round(mean(group)),
                            round(min(group)), round(max(group))))
    save_csv(output / "fixed_summary.csv",
             ("method", "warehouse", "runs", "mean_tps", "min_tps", "max_tps"),
             summary)
    ax.set_xticks(xs, STATES)
    ax.set_xlabel("Fixed active home warehouses")
    ax.set_ylabel("Overall throughput (thousands of transactions/s)")
    ax.set_title("TPC-C fixed workloads: 96 database warehouses, 96 workers")
    ax.grid(alpha=.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(output / "fixed_protocols.png", dpi=180)
    plt.close(fig)


def read_trace(path):
    changes, samples = [], []
    for line in path.read_text(errors="replace").splitlines():
        fields = dict(FIELDS.findall(line))
        if "[TPC-C workload]" in line and "applied_workers=" not in line:
            changes.append((float(fields["bench_s"]),
                            int(fields["active_warehouses"])))
        elif ("[TPC-C interval]" in line or "[Metis-test]" in line) and \
             "bench_s" in fields and "tput" in fields:
            samples.append((float(fields["bench_s"]), float(fields["tput"])))
    if not changes or not samples:
        raise ValueError(f"Missing dynamic events or TPS samples: {path}")
    return changes, samples


def dynamic(data, output, duration, methods):
    overall = defaultdict(list)
    phase = defaultdict(list)
    phase_rows = []
    for row in data:
        method = row["method"]
        run = int(row["run"])
        overall[method].append(float(row["tps"]))
        changes, samples = read_trace(Path(row["log"]))
        if [w for _, w in changes] != [16, 1, 96, 4, 32, 16]:
            raise ValueError(f"Unexpected schedule: {row['log']}")
        for index, (start, warehouse) in enumerate(changes):
            end = changes[index + 1][0] if index + 1 < len(changes) else duration
            settled = [tps for time, tps in samples
                       if start + 2 <= time < end]
            if not settled:
                raise ValueError(f"No settled interval: {row['log']} phase {index+1}")
            average = mean(settled)
            phase[method, index + 1].append(average)
            phase_rows.append((method, run, index + 1, warehouse,
                               f"{start:.3f}", f"{end:.3f}",
                               len(settled), round(average)))
    save_csv(output / "dynamic_phase_metrics.csv",
             ("method", "run", "phase", "warehouse", "start_s", "end_s",
              "samples_after_2s", "mean_tps_after_2s"), phase_rows)
    save_csv(output / "dynamic_summary.csv",
             ("method", "runs", "mean_tps", "min_tps", "max_tps"),
             [(m, len(overall[m]), round(mean(overall[m])),
               round(min(overall[m])), round(max(overall[m]))) for m in methods])

    fig, (top, bottom) = plt.subplots(2, 1, figsize=(11, 8))
    xs = list(range(len(methods)))
    averages = [mean(overall[m]) / 1000 for m in methods]
    lower = [mean(overall[m]) / 1000 - min(overall[m]) / 1000 for m in methods]
    upper = [max(overall[m]) / 1000 - mean(overall[m]) / 1000 for m in methods]
    top.bar(xs, averages, color=plt.get_cmap("tab10").colors[:len(methods)])
    top.errorbar(xs, averages, yerr=[lower, upper], fmt="none", color="black",
                 capsize=4)
    top.set_xticks(xs, [LABELS[m] for m in methods], rotation=15, ha="right")
    top.set_ylabel("Overall throughput (kTPS)")
    top.grid(axis="y", alpha=.25)
    for method in methods:
        values = [phase[method, i] for i in range(1, 7)]
        if any(not v for v in values):
            raise ValueError(f"Missing dynamic phase for {method}")
        averages = [mean(v) / 1000 for v in values]
        lower = [mean(v) / 1000 - min(v) / 1000 for v in values]
        upper = [max(v) / 1000 - mean(v) / 1000 for v in values]
        bottom.errorbar(range(1, 7), averages, yerr=[lower, upper],
                        fmt="o-", capsize=2, linewidth=1.5,
                        label=LABELS[method])
    bottom.set_xticks(range(1, 7), ("16", "1", "96", "4", "32", "16"))
    bottom.set_xlabel("Dynamic phase: active home warehouses (10 s each)")
    bottom.set_ylabel("TPS after first 2 s (thousands, symlog scale)")
    # ERMIA can produce zero commits for an entire high-contention phase.
    # A regular log axis would silently omit those measured zeros.
    bottom.set_yscale("symlog", linthresh=1)
    bottom.set_ylim(bottom=0)
    bottom.grid(alpha=.25)
    bottom.legend(loc="upper center", bbox_to_anchor=(.5, -.16),
                  ncol=3, fontsize=8)
    fig.suptitle("TPC-C live workload switches: 96 database warehouses")
    fig.tight_layout()
    fig.savefig(output / "dynamic_protocols.png", dpi=180)
    plt.close(fig)


def observed_trace(data, output):
    observed = sorted((row for row in data if row["method"] == "observed_metis"),
                      key=lambda row: int(row["run"]))
    if not observed:
        return
    fig, (top, bottom) = plt.subplots(2, 1, figsize=(12, 7), sharex=True)
    for row in observed:
        times, tps, threads = [], [], []
        for line in Path(row["log"]).read_text(errors="replace").splitlines():
            if "[Metis-test]" not in line:
                continue
            fields = dict(FIELDS.findall(line))
            if not {"bench_s", "tput", "active_threads"} <= fields.keys():
                continue
            times.append(float(fields["bench_s"]))
            tps.append(float(fields["tput"]) / 1000)
            threads.append(int(fields["active_threads"]))
        if not times:
            raise ValueError(f"Missing Metis-test trace: {row['log']}")
        label = f"run {row['run']}"
        top.plot(times, tps, label=label, linewidth=1.2, alpha=.8)
        bottom.step(times, threads, where="post", label=label, linewidth=1.4)
    for axis in (top, bottom):
        for switch in range(10, 60, 10):
            axis.axvline(switch, color="gray", linewidth=.8, alpha=.6)
        axis.grid(alpha=.25)
        axis.legend(loc="upper right")
    for index, warehouses in enumerate((16, 1, 96, 4, 32, 16)):
        top.text(index * 10 + 5, .97, f"W={warehouses}", ha="center", va="top",
                 transform=top.get_xaxis_transform(), fontsize=9)
    top.set_ylabel("Interval throughput (kTPS)")
    bottom.set_ylabel("Active workers")
    bottom.set_xlabel("Seconds from benchmark start")
    bottom.set_yticks((8, 16, 24, 32, 48, 64, 96))
    bottom.set_xlim(0, 60)
    fig.suptitle("Observed Metis-test response to live TPC-C workload switches")
    fig.tight_layout()
    fig.savefig(output / "observed_metis_dynamic_trace.png", dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-dir", type=Path, required=True)
    args = parser.parse_args()
    directory = args.experiment_dir
    settings = dict(line.split("=", 1) for line in
                    (directory / "config.txt").read_text().splitlines()
                    if "=" in line)
    fixed_data = rows(directory / "fixed.csv")
    dynamic_data = rows(directory / "dynamic.csv")
    methods = tuple(method for method in METHODS
                    if any(row["method"] == method for row in (dynamic_data or fixed_data)))
    if fixed_data:
        fixed(fixed_data, directory, methods)
    if dynamic_data:
        dynamic(dynamic_data, directory,
                float(settings["dynamic_extime"]), methods)
        observed_trace(dynamic_data, directory)
    print(directory)


if __name__ == "__main__":
    main()
