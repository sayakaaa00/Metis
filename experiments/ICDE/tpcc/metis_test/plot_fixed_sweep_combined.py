#!/usr/bin/env python3
"""Combine the W=16/32 repeat sweep with the earlier W=1/4/96 sweep."""

import argparse
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


STATES = (1, 4, 16, 32, 96)
REPEATED = {16, 32}
WORKERS = (8, 16, 24, 32, 48, 64, 96)


def read_rows(path):
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-summary", type=Path, required=True)
    parser.add_argument("--repeat-summary", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    selected = {}
    for path, states, expected_runs, source_name in (
        (args.previous_summary, set(STATES) - REPEATED, 1, "previous_1_run"),
        (args.repeat_summary, REPEATED, 2, "additional_2_runs"),
    ):
        for row in read_rows(path):
            state = int(row["active_home_warehouses"])
            if state not in states:
                continue
            workers = int(row["active_workers"])
            if workers not in WORKERS or (state, workers) in selected:
                raise ValueError(f"Unexpected or duplicate point: W={state}, N={workers}")
            runs = int(row["runs"]) if "runs" in row else 2
            if runs != expected_runs:
                raise ValueError(f"Unexpected run count: W={state}, N={workers}")
            selected[state, workers] = (
                runs, float(row["mean_tps"]), float(row["min_tps"]),
                float(row["max_tps"]), source_name,
            )

    expected = {(state, workers) for state in STATES for workers in WORKERS}
    if set(selected) != expected:
        raise ValueError(f"Missing points: {sorted(expected - set(selected))}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    summary_path = args.output_dir / "fixed_sweep_combined_summary.csv"
    with summary_path.open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(("active_home_warehouses", "active_workers", "runs",
                         "mean_tps", "min_tps", "max_tps", "source"))
        for state in STATES:
            for workers in WORKERS:
                writer.writerow((state, workers, *selected[state, workers]))

    fig, ax = plt.subplots(figsize=(11.5, 7))
    for state in STATES:
        points = [selected[state, workers] for workers in WORKERS]
        means = [point[1] / 1000 for point in points]
        if state in REPEATED:
            lower = [(point[1] - point[2]) / 1000 for point in points]
            upper = [(point[3] - point[1]) / 1000 for point in points]
            ax.errorbar(WORKERS, means, yerr=[lower, upper], fmt="o-",
                        capsize=3, linewidth=1.8,
                        label=f"W={state} (2 runs)")
        else:
            ax.plot(WORKERS, means, "o-", linewidth=1.8,
                    label=f"W={state} (1 run)")

    ax.set_xticks(WORKERS)
    ax.set_xlabel("Active worker threads N (96 OS workers created)")
    ax.set_ylabel("Throughput (thousands of transactions/s)")
    fig.suptitle("TPC-C fixed workload: 96 database warehouses, balanced home assignment",
                 y=.985)
    ax.grid(alpha=.25)
    handles, labels = ax.get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(.5, .94),
               ncol=5, fontsize=9)
    fig.text(.5, .015,
             "For N < W, only N distinct home warehouses receive local transactions.",
             ha="center", fontsize=9)
    fig.subplots_adjust(left=.10, right=.98, bottom=.14, top=.82)
    figure_path = args.output_dir / "fixed_thread_sweep_combined.png"
    fig.savefig(figure_path, dpi=180)
    plt.close(fig)
    print(figure_path)


if __name__ == "__main__":
    main()
