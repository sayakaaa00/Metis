#!/usr/bin/env python3
"""Validate unique-order histograms and summarize the contention pilot."""

import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


HERE = Path(__file__).resolve().parent
THETAS = (0, 0.7, 0.8, 0.95)
TYPES = ("NewOrder", "Payment", "OrderStatus", "Delivery", "StockLevel")


def read_csv(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


def histograms():
    old = HERE.parent / "item_zipf_w1_20261103" / "histograms"
    summary = []
    reference_ids = None
    fig, ax = plt.subplots(figsize=(8, 5))
    for theta in THETAS:
        rows = read_csv(HERE / "histograms" / f"theta_{theta}.csv")
        counts = [int(row["count"]) for row in rows]
        ids = [int(row["item_id"]) for row in rows]
        assert [int(row["rank"]) for row in rows] == list(range(1, 100001))
        assert sorted(ids) == list(range(1, 100001))
        assert sum(counts) == 1_000_000
        if reference_ids is None:
            reference_ids = ids
        else:
            assert ids == reference_ids
        old_rows = read_csv(old / f"theta_{theta}.csv")
        assert [int(row["item_id"]) for row in old_rows] == ids
        old_counts = [int(row["count"]) for row in old_rows]
        summary.append({
            "theta": theta, "samples": sum(counts),
            "rank1_share": counts[0] / sum(counts),
            "top10_share": sum(counts[:10]) / sum(counts),
            "top100_share": sum(counts[:100]) / sum(counts),
            "top1000_share": sum(counts[:1000]) / sum(counts),
            "old_top100_share_independent_draws": sum(old_counts[:100]) / sum(old_counts),
        })
        # Logarithmic rank bins give visible tail means with 1M samples.
        edges = sorted(set([1, 100001] + [max(1, int(10 ** (i / 10))) for i in range(51)]))
        centers, means = [], []
        for lo, hi in zip(edges[:-1], edges[1:]):
            values = counts[lo - 1:hi - 1]
            if values:
                centers.append((lo * (hi - 1)) ** 0.5)
                means.append(statistics.mean(values))
        ax.plot(centers, means, label=f"θ={theta}")
    write_csv(HERE / "unique_histogram_summary.csv", summary)
    ax.set(xscale="log", yscale="log", xlabel="Popularity rank",
           ylabel="Mean accepted selections per item (1M lines)",
           title="TPC-C New-Order item Zipf, unique within each order")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(HERE / "unique_item_histogram.png", dpi=180)
    plt.close(fig)
    return summary


def pilot():
    rows = read_csv(HERE / "contention_pilot_10s" / "results.csv")
    assert len(rows) == 16
    groups = defaultdict(list)
    for row in rows:
        groups[(int(row["active_warehouses"]), row["mix"], float(row["theta"]))].append(row)
    summary = []
    for (w, mix, theta), group in sorted(groups.items()):
        assert len(group) == 2
        tps = [int(row["tps"]) for row in group]
        result = {"active_warehouses": w, "mix": mix, "theta": theta,
                  "workers": int(group[0]["workers"]),
                  "mean_tps": statistics.mean(tps), "min_tps": min(tps),
                  "max_tps": max(tps),
                  "mean_abort_rate": statistics.mean(float(row["abort_rate"]) for row in group)}
        for name in TYPES:
            commits = sum(int(row[f"{name}_commits"]) for row in group)
            aborts = sum(int(row[f"{name}_aborts"]) for row in group)
            result[f"{name}_tps"] = commits / 20
            result[f"{name}_abort_rate"] = aborts / (commits + aborts) if commits + aborts else 0
        summary.append(result)
    write_csv(HERE / "contention_pilot_summary.csv", summary)
    return summary


def neworder_sweep():
    coarse = read_csv(HERE / "neworder_w1_coarse_5s" / "results.csv")
    assert len(coarse) == 30
    fig, ax = plt.subplots(figsize=(8, 5))
    for theta in (0.0, 0.95):
        rows = sorted((row for row in coarse if float(row["theta"]) == theta),
                      key=lambda row: int(row["workers"]))
        ax.plot([int(row["workers"]) for row in rows],
                [int(row["tps"]) for row in rows], marker="o", label=f"θ={theta:g}")
    ax.set(xlabel="Active workers", ylabel="New-Order commits / second",
           title="DB=16, active W=1, New-Order only: 5 s × 1 run")
    ax.grid(True, alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(HERE / "neworder_w1_coarse_tps.png", dpi=180)
    plt.close(fig)

    groups = defaultdict(list)
    for row in read_csv(HERE / "neworder_w1_refine_10s" / "results.csv"):
        groups[(float(row["theta"]), int(row["workers"]))].append(row)
    assert len(groups) == 12
    summary = []
    for (theta, workers), rows in sorted(groups.items()):
        assert len(rows) == 2
        tps = [int(row["tps"]) for row in rows]
        summary.append({"theta": theta, "workers": workers,
                        "mean_tps": statistics.mean(tps),
                        "min_tps": min(tps), "max_tps": max(tps),
                        "mean_abort_rate": statistics.mean(float(row["abort_rate"]) for row in rows)})
    write_csv(HERE / "neworder_w1_refine_summary.csv", summary)
    return summary


if __name__ == "__main__":
    for row in histograms():
        print("hist", row)
    for row in pilot():
        print("pilot", row)
    for row in neworder_sweep():
        print("sweep", row)
