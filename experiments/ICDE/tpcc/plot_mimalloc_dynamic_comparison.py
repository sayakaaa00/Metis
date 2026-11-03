#!/usr/bin/env python3
"""Combine the common allocator run and paired top-two rerun."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from plot_protocol_comparison import read_trace, save_csv


METHODS = (
    ("metis_retrained", "Metis-test, mimalloc trained"),
    ("silo_with_backoff", "Silo, backoff"),
    ("metis_previous", "Metis-test, glibc trained"),
    ("silo_without_backoff", "Silo, no backoff"),
    ("cicada", "Cicada*"),
    ("ermia", "ERMIA*"),
)
SCHEDULE = (16, 1, 96, 4, 32, 16)


def read_rows(path):
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--top-two", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = read_rows(args.baseline / "dynamic.csv")
    paired = read_rows(args.top_two / "dynamic.csv")
    selected = {
        "metis_retrained": [r for r in paired if r["method"] == "observed_metis"],
        "silo_with_backoff": [r for r in paired if r["method"] == "silo_with_backoff"],
        "metis_previous": [r for r in baseline if r["method"] == "observed_metis"],
        "silo_without_backoff": [r for r in baseline if r["method"] == "silo_without_backoff"],
        "cicada": [r for r in baseline if r["method"] == "cicada"],
        "ermia": [r for r in baseline if r["method"] == "ermia"],
    }
    if any(not value for value in selected.values()):
        raise ValueError("Missing method in the experiment inputs")
    args.output.mkdir(parents=True, exist_ok=True)
    summary, phases = [], []
    by_phase = defaultdict(list)
    for method, _ in METHODS:
        rows = selected[method]
        throughputs = [int(row["tps"]) for row in rows]
        summary.append((method, len(rows), round(mean(throughputs)),
                        min(throughputs), max(throughputs)))
        for row in rows:
            changes, samples = read_trace(Path(row["log"]))
            if tuple(w for _, w in changes) != SCHEDULE:
                raise ValueError(f"Unexpected schedule in {row['log']}")
            for index, (start, warehouse) in enumerate(changes):
                end = changes[index + 1][0] if index + 1 < len(changes) else 60.0
                settled = [tps for time, tps in samples if start + 2 <= time < end]
                if not settled:
                    raise ValueError(f"No settled samples in {row['log']}")
                value = mean(settled)
                by_phase[method, index + 1].append(value)
                phases.append((method, row["run"], index + 1, warehouse,
                               round(value)))
    save_csv(args.output / "dynamic_summary.csv",
             ("method", "runs", "mean_tps", "min_tps", "max_tps"), summary)
    save_csv(args.output / "dynamic_phase_metrics.csv",
             ("method", "run", "phase", "warehouse", "mean_tps_after_2s"),
             phases)

    fig, (top, bottom) = plt.subplots(2, 1, figsize=(11, 8))
    colors = plt.get_cmap("tab10").colors
    for index, ((method, label), (_, count, average, minimum, maximum)) in enumerate(
            zip(METHODS, summary)):
        color = colors[index]
        top.bar(index, average / 1000, color=color)
        top.errorbar(index, average / 1000,
                     yerr=[[max(0, average - minimum) / 1000],
                           [max(0, maximum - average) / 1000]],
                     fmt="none", ecolor="black", capsize=4)
        values = [mean(by_phase[method, phase]) / 1000 for phase in range(1, 7)]
        bottom.plot(range(1, 7), values, "o-", label=label,
                    color=color, linewidth=1.6, markersize=4)
    top.set_xticks(range(len(METHODS)),
                   [f"{label}\n(n={summary[i][1]})" for i, (_, label) in enumerate(METHODS)],
                   rotation=15, ha="right")
    top.set_ylabel("Whole-run throughput (kTPS)")
    top.grid(axis="y", alpha=.25)
    bottom.set_xticks(range(1, 7), [str(w) for w in SCHEDULE])
    bottom.set_xlabel("Active home warehouses (10 s per phase)")
    bottom.set_ylabel("TPS after switch +2 s (kTPS, symlog)")
    bottom.set_yscale("symlog", linthresh=1)
    bottom.set_ylim(bottom=0)
    bottom.grid(alpha=.25)
    bottom.legend(loc="upper center", bbox_to_anchor=(.5, -.17),
                  ncol=3, fontsize=8)
    fig.suptitle("TPC-C dynamic workload with mimalloc: 96 workers and DB warehouses")
    fig.tight_layout()
    fig.savefig(args.output / "dynamic_comparison.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
