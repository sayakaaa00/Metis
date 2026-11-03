#!/usr/bin/env python3
"""Explain pinned TPC-C TPS peaks using attempts, commits, and aborts."""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def number(log, name):
    match = re.search(rf"^{re.escape(name)}:\s+([0-9]+)", log, re.MULTILINE)
    if match is None:
        raise ValueError(f"Missing {name}")
    return int(match.group(1))


def parse_log(path):
    log = path.read_text()
    commits = number(log, "commit_counts_")
    aborts = number(log, "abort_counts_")
    seconds = number(log, "actual_extime")
    types = {
        name: (int(n_commit), int(n_abort))
        for name, n_commit, n_abort in re.findall(
            r"Transaction type: (\w+)\s+commits: (\d+)\s+aborts: (\d+)",
            log,
        )
    }
    if sum(value[0] for value in types.values()) != commits:
        raise ValueError(f"Commit count mismatch in {path}")
    if sum(value[1] for value in types.values()) != aborts:
        raise ValueError(f"Abort count mismatch in {path}")
    delivery_commits, delivery_aborts = types["Delivery"]
    return {
        "commits_per_second": commits / seconds,
        "attempts_per_second": (commits + aborts) / seconds,
        "abort_fraction": aborts / (commits + aborts),
        "delivery_abort_fraction": delivery_aborts /
        (delivery_commits + delivery_aborts),
        "delivery_abort_share": delivery_aborts / aborts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--warehouse-values", type=int, nargs="+", default=[4, 16, 32])
    args = parser.parse_args()

    groups = defaultdict(list)
    for source in args.results:
        with source.open(newline="") as handle:
            for row in csv.DictReader(handle):
                w = int(row["active_warehouses"])
                n = int(row["active_threads"])
                if w not in args.warehouse_values:
                    continue
                groups[w, n].append(parse_log(Path(row["log"])))
    if any(len(runs) != 2 for runs in groups.values()):
        raise ValueError("Every candidate must have exactly two runs")

    rows = []
    for (w, n), runs in sorted(groups.items()):
        row = {"active_warehouses": w, "active_threads": n}
        for field in runs[0]:
            row[field] = round(mean(run[field] for run in runs), 5)
        rows.append(row)
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / "attempt_abort_metrics.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    warehouses = sorted({row["active_warehouses"] for row in rows})
    fig, axes = plt.subplots(len(warehouses), 1, figsize=(9, 3.5 * len(warehouses)),
                             sharex=True, layout="constrained")
    if len(warehouses) == 1:
        axes = [axes]
    first_right = None
    for ax, w in zip(axes, warehouses):
        data = [row for row in rows if row["active_warehouses"] == w]
        ns = [row["active_threads"] for row in data]
        attempts = [row["attempts_per_second"] / 1000 for row in data]
        commits = [row["commits_per_second"] / 1000 for row in data]
        aborts = [row["abort_fraction"] * 100 for row in data]
        ax.plot(ns, attempts, "o-", color="#4c78a8", label="Attempts/s")
        ax.plot(ns, commits, "s-", color="#f58518", label="Commits/s (TPS)")
        ax.axvline(48, color="gray", linestyle="--", linewidth=1)
        ax.set_title(f"W={w}", loc="left")
        ax.set_ylabel("Transactions/s (thousands)")
        ax.set_ylim(bottom=0)
        ax.grid(alpha=0.25)
        right = ax.twinx()
        if first_right is None:
            first_right = right
        right.plot(ns, aborts, "^-", color="#54a24b", label="Abort rate")
        right.set_ylabel("Abort rate (%)")
        right.set_ylim(0, 100)
    handles, labels = axes[0].get_legend_handles_labels()
    right_handles, right_labels = first_right.get_legend_handles_labels()
    axes[0].legend(handles + right_handles, labels + right_labels,
                   loc="upper left")
    axes[-1].set_xlabel("Pinned active workers N")
    axes[-1].set_xticks(sorted({row["active_threads"] for row in rows}))
    fig.suptitle("mimalloc TPC-C fixed workload: OS-default memory, pinned workers")
    fig.savefig(args.output / "attempts_commits_aborts.png", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    main()
