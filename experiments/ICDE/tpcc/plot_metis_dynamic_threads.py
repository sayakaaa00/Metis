#!/usr/bin/env python3
"""Plot sampled Metis-test worker transitions against live TPC-C workload."""

import argparse
import csv
import re
from bisect import bisect_right
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


FIELD = re.compile(r"([a-z_]+)=([0-9.]+|[a-z_]+)")


def parse_log(path):
    switches, samples = [], []
    for line in path.read_text(errors="replace").splitlines():
        fields = dict(FIELD.findall(line))
        if "[TPC-C workload]" in line and "applied_workers=" not in line:
            switches.append((float(fields["bench_s"]),
                             int(fields["active_warehouses"])))
        elif "[Metis-test]" in line and {"bench_s", "active_threads", "phase"} <= fields.keys():
            samples.append((float(fields["bench_s"]),
                            int(fields["active_threads"]), fields["phase"],
                            float(fields["tput"])))
    if not switches or not samples:
        raise ValueError(f"Missing workload switches or worker samples: {path}")
    return switches, samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dynamic-csv", type=Path, required=True)
    parser.add_argument("--output-prefix", type=Path, required=True)
    args = parser.parse_args()
    with args.dynamic_csv.open(newline="") as source:
        runs = sorted((row for row in csv.DictReader(source)
                       if row["method"] == "observed_metis"),
                      key=lambda row: int(row["run"]))
    if not runs:
        raise ValueError("No observed_metis runs in dynamic CSV")
    args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    data = []
    with args.output_prefix.with_suffix(".csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(("run", "bench_s", "active_warehouses", "active_threads",
                         "controller_phase", "interval_tps"))
        for run in runs:
            switches, samples = parse_log(Path(run["log"]))
            switch_times = [time for time, _ in switches]
            for time, threads, phase, tps in samples:
                warehouse = switches[max(0, bisect_right(switch_times, time) - 1)][1]
                writer.writerow((run["run"], f"{time:.3f}", warehouse,
                                 threads, phase, round(tps)))
            data.append((run["run"], switches, samples))

    fig, (workload, workers) = plt.subplots(
        2, 1, figsize=(13, 6.8), sharex=True,
        gridspec_kw={"height_ratios": [1, 2.4]})
    reference_switches = data[0][1]
    change_times = [time for time, _ in reference_switches]
    warehouses = [w for _, w in reference_switches]
    workload.step(change_times + [60], warehouses + [warehouses[-1]],
                  where="post", color="black", linewidth=2)
    for index, (start, warehouse) in enumerate(reference_switches):
        end = change_times[index + 1] if index + 1 < len(change_times) else 60
        workload.text((start + end) / 2, warehouse + 2.5, f"W={warehouse}",
                      ha="center", va="bottom", fontsize=9)
    for run, _, samples in data:
        times = [0.0] + [time for time, _, _, _ in samples] + [60.0]
        threads = [96] + [value for _, value, _, _ in samples]
        workers.step(times, threads + [threads[-1]], where="post",
                     linewidth=1.5, label=f"run {run}", alpha=.8)
    for axis in (workload, workers):
        for switch in range(10, 60, 10):
            axis.axvline(switch, color="gray", linestyle=":", linewidth=1)
        axis.grid(alpha=.25)
    workload.set_ylim(0, 110)
    workload.set_ylabel("Active home\nwarehouses")
    workload.set_yticks((1, 4, 16, 32, 96))
    workers.set_ylim(0, 105)
    workers.set_ylabel("Active workers")
    workers.set_yticks((8, 16, 24, 32, 48, 64, 96))
    workers.set_xlabel("Seconds from benchmark start")
    workers.set_xlim(0, 60)
    workers.legend(loc="upper right", ncol=3)
    fig.suptitle("Metis-test worker transitions under mimalloc (0.2 s samples)")
    fig.tight_layout()
    fig.savefig(args.output_prefix.with_suffix(".png"), dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
