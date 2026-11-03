#!/usr/bin/env python3
"""Check item-Zipf histograms and summarize fixed-worker measurements."""

import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


HERE = Path(__file__).resolve().parent
THETAS = (0, 0.7, 0.8, 0.95)
TYPES = ("NewOrder", "Payment", "OrderStatus", "Delivery", "StockLevel")


def csv_rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


def analyze_histograms():
    summaries = []
    reference_ids = None
    fig, ax = plt.subplots(figsize=(8, 5))
    edges = sorted(set([1, 100001] + [max(1, int(10 ** (i / 10))) for i in range(51)]))
    for theta in THETAS:
        rows = csv_rows(HERE / "histograms" / f"theta_{theta}.csv")
        ranks = [int(row["rank"]) for row in rows]
        ids = [int(row["item_id"]) for row in rows]
        counts = [int(row["count"]) for row in rows]
        assert ranks == list(range(1, 100001))
        assert sorted(ids) == list(range(1, 100001))
        if reference_ids is None:
            reference_ids = ids
        else:
            assert ids == reference_ids, "Popular item mapping changed with theta"
        assert sum(counts) == 1_000_000
        normalizer = sum(rank ** (-theta) for rank in ranks)
        summaries.append({
            "theta": theta, "samples": sum(counts),
            "distinct_items_sampled": sum(bool(count) for count in counts),
            "rank1_share": counts[0] / sum(counts),
            "top10_share": sum(counts[:10]) / sum(counts),
            "top100_share": sum(counts[:100]) / sum(counts),
            "top1000_share": sum(counts[:1000]) / sum(counts),
            "ideal_top100_share": sum(rank ** (-theta) for rank in range(1, 101)) / normalizer,
        })
        centers = []
        means = []
        for lo, hi in zip(edges[:-1], edges[1:]):
            values = counts[lo - 1:hi - 1]
            if values:
                centers.append(math.sqrt(lo * (hi - 1)))
                means.append(statistics.mean(values))
        ax.plot(centers, means, label=f"θ={theta}")
    write_csv(HERE / "histogram_summary.csv", summaries)
    ax.set(xscale="log", yscale="log", xlabel="Popularity rank", ylabel="Mean selections per item (1M draws)",
           title="TPC-C New-Order item selection, W=1, Item=100,000")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(HERE / "item_zipf_histogram.png", dpi=180)
    plt.close(fig)
    return summaries


def analyze_sweep():
    coarse = csv_rows(HERE / "coarse_5s" / "results.csv")
    assert len(coarse) == len(THETAS) * 19
    fig, ax = plt.subplots(figsize=(8, 5))
    for theta in THETAS:
        rows = sorted((row for row in coarse if float(row["theta"]) == theta),
                      key=lambda row: int(row["workers"]))
        ax.plot([int(row["workers"]) for row in rows],
                [int(row["tps"]) for row in rows], marker="o", label=f"θ={theta}")
    ax.set(xlabel="Active workers", ylabel="Committed transactions / second",
           title="Broad sweep: W=1, Item=100,000, 5 s × 1 run")
    ax.grid(True, alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(HERE / "coarse_tps_vs_workers.png", dpi=180)
    plt.close(fig)

    data = defaultdict(list)
    for row in csv_rows(HERE / "refine_10s" / "results.csv"):
        data[(float(row["theta"]), int(row["workers"]))].append(row)
    assert len(data) == len(THETAS) * 10
    summaries = []
    for (theta, workers), rows in sorted(data.items()):
        assert len(rows) == 2
        tps = [int(row["tps"]) for row in rows]
        record = {"theta": theta, "workers": workers, "mean_tps": statistics.mean(tps),
                  "min_tps": min(tps), "max_tps": max(tps),
                  "mean_abort_rate": statistics.mean(float(row["abort_rate"]) for row in rows)}
        for tx_type in TYPES:
            commits = sum(int(row[f"{tx_type}_commits"]) for row in rows)
            aborts = sum(int(row[f"{tx_type}_aborts"]) for row in rows)
            record[f"{tx_type}_tps"] = commits / 20
            record[f"{tx_type}_abort_rate"] = aborts / (commits + aborts)
        summaries.append(record)
    write_csv(HERE / "refine_summary.csv", summaries)
    best = [max((row for row in summaries if row["theta"] == theta), key=lambda row: row["mean_tps"])
            for theta in THETAS]
    write_csv(HERE / "best_by_theta.csv", best)
    fig, ax = plt.subplots(figsize=(8, 5))
    for theta in THETAS:
        rows = [row for row in summaries if row["theta"] == theta]
        ax.plot([row["workers"] for row in rows], [row["mean_tps"] for row in rows],
                marker="o", label=f"θ={theta}")
    ax.set(xlabel="Active workers", ylabel="Committed transactions / second",
           title="W=1, Item=100,000: 10 s × 2 runs per condition")
    ax.grid(True, alpha=0.25)
    ax.legend()
    fig.tight_layout()
    fig.savefig(HERE / "tps_vs_workers.png", dpi=180)
    plt.close(fig)
    return best


if __name__ == "__main__":
    for row in analyze_histograms():
        print("hist", row)
    for row in analyze_sweep():
        print("best", row)
