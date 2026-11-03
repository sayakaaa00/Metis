#!/usr/bin/env python3
"""Compare the seven-action and 45-action TPC-C measurements."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


LABELS = {"aware": "Warehouse-aware", "observed": "Observed-load"}
MODES = ("7 actions", "45 actions")
COLORS = {"7 actions": "#1f77b4", "45 actions": "#d95f02"}
STATES = (1, 4, 16, 32, 96)


def rows(path):
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def plot_fixed(data, output):
    fig, axes = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    xs = list(range(len(STATES)))
    for ax, label in zip(axes, LABELS):
        for mode in MODES:
            subset = {int(r["warehouse"]): r for r in data[mode]["fixed"]
                      if r["model"] == label}
            tps = [float(subset[w]["overall_tps"]) / 1000 for w in STATES]
            workers = [int(subset[w]["modal_threads_after_2s"]) for w in STATES]
            ax.plot(xs, tps, "o-", color=COLORS[mode], label=mode)
            for x, y, worker in zip(xs, tps, workers):
                ax.annotate(str(worker), (x, y),
                            xytext=(0, 7 if mode == "7 actions" else -14),
                            textcoords="offset points", ha="center", fontsize=8)
        ax.set_title(LABELS[label])
        ax.set_ylabel("Overall TPS (thousands)")
        ax.grid(alpha=.25)
        ax.legend()
    axes[-1].set_xticks(xs, STATES)
    axes[-1].set_xlabel("Fixed active warehouses (labels show modal workers)")
    fig.suptitle("Fixed TPC-C: same training states, one 15 s run per setting")
    fig.tight_layout()
    fig.savefig(output / "fixed_action_resolution.png", dpi=180)
    plt.close(fig)


def plot_dynamic(data, output):
    fig, (overall_ax, phase_ax) = plt.subplots(2, 1, figsize=(11, 8))
    x_positions = range(4)
    pairs = [(mode, label) for label in LABELS for mode in MODES]
    means = []
    lows = []
    highs = []
    for mode, label in pairs:
        values = [float(r["overall_tps"]) / 1000
                  for r in data[mode]["overall"] if r["model"] == label]
        means.append(mean(values))
        lows.append(mean(values) - min(values))
        highs.append(max(values) - mean(values))
    overall_ax.bar(x_positions, means,
                   color=[COLORS[mode] for mode, _ in pairs])
    overall_ax.errorbar(x_positions, means, yerr=[lows, highs], fmt="none",
                        color="black", capsize=4)
    overall_ax.set_xticks(list(x_positions),
                          [f"{LABELS[label]}\n{mode}" for mode, label in pairs])
    overall_ax.set_ylabel("Overall TPS (thousands)")
    overall_ax.grid(axis="y", alpha=.25)

    for mode in MODES:
        for label, marker in (("aware", "o"), ("observed", "s")):
            by_phase = defaultdict(list)
            for row in data[mode]["phase"]:
                if row["model"] == label:
                    by_phase[int(row["phase"])].append(
                        float(row["mean_tps_after_2s"]) / 1000)
            phase_ax.plot(sorted(by_phase),
                          [mean(by_phase[p]) for p in sorted(by_phase)],
                          marker=marker, linestyle="-" if label == "aware" else "--",
                          color=COLORS[mode], label=f"{LABELS[label]}, {mode}")
    phase_ax.set_yscale("log")
    phase_ax.set_ylabel("TPS after 2 s (thousands, log)")
    phase_ax.set_xticks(range(1, 7), ("16", "1", "96", "4", "32", "16"))
    phase_ax.set_xlabel("Dynamic phase: active warehouses (10 s each)")
    phase_ax.grid(alpha=.25)
    phase_ax.legend(ncol=2, fontsize=8)
    fig.suptitle("Dynamic TPC-C: two 60 s runs per setting")
    fig.tight_layout()
    fig.savefig(output / "dynamic_action_resolution.png", dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coarse", type=Path, required=True)
    parser.add_argument("--coarse-dynamic", type=Path,
                        help="Use a later seven-action dynamic rerun")
    parser.add_argument("--dense", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    data = {}
    for name, directory in (("7 actions", args.coarse), ("45 actions", args.dense)):
        dynamic_directory = args.coarse_dynamic if name == "7 actions" and \
            args.coarse_dynamic else directory
        data[name] = {
            "fixed": rows(directory / "matched_fixed_metrics.csv"),
            "overall": rows(dynamic_directory / "dynamic_overall.csv"),
            "phase": rows(dynamic_directory / "dynamic_phase_metrics.csv"),
        }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    plot_fixed(data, args.output_dir)
    plot_dynamic(data, args.output_dir)


if __name__ == "__main__":
    main()
