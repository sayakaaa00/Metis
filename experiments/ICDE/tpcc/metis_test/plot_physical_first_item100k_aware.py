#!/usr/bin/env python3
"""Plot held-out fixed and 16→96→4 dynamic TPC-C evaluation results."""

import argparse
import csv
import re
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


STATES = (1, 4, 8, 16, 32, 64, 96)
METHODS = ("metis_test", "silo_without_backoff", "silo_with_backoff",
           "cicada", "ermia")
LABELS = {"metis_test": "Metis-test (held-out)",
          "silo_without_backoff": "Silo, no backoff",
          "silo_with_backoff": "Silo, backoff",
          "cicada": "Cicada", "ermia": "ERMIA"}
FIELDS = re.compile(r"([a-z_]+)=([0-9.]+)")


def read_csv(path):
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def write_csv(path, fields, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(fields)
        writer.writerows(rows)


def trace(path):
    samples = []
    for line in path.read_text(errors="replace").splitlines():
        if "[Metis-test]" not in line:
            continue
        values = dict(FIELDS.findall(line))
        if not {"bench_s", "active_threads", "tput"} <= values.keys():
            continue
        samples.append((float(values["bench_s"]),
                        int(values["active_threads"]),
                        float(values["tput"])))
    if not samples:
        raise ValueError(f"No timestamped samples: {path}")
    return samples


def plot_fixed(source, output, model_label):
    data = read_csv(source / "results.csv")
    grouped = defaultdict(list)
    for row in data:
        grouped[row["method"], int(row["warehouse"])].append(row)
    for method in METHODS:
        for w in STATES:
            if len(grouped[method, w]) != 2:
                raise ValueError(f"Need 2 runs: {method}, W={w}")
    summary = []
    for method in METHODS:
        for w in STATES:
            rows = grouped[method, w]
            tps = [int(row["tps"]) for row in rows]
            abort = [float(row["abort_rate"]) for row in rows]
            summary.append((method, w, 2, round(mean(tps), 1), min(tps),
                            max(tps), round(mean(abort), 5)))
    write_csv(output / "fixed_summary.csv",
              ("method", "warehouse", "runs", "mean_tps", "min_tps",
               "max_tps", "mean_abort_rate"), summary)

    fig, axes = plt.subplots(len(STATES), 1, figsize=(10, 15), sharex=True,
                             layout="constrained")
    thread_rows = []
    for ax, w in zip(axes, STATES):
        for row in sorted(grouped["metis_test", w], key=lambda r: int(r["run"])):
            samples = trace(Path(row["trace"]))
            times = [0.0] + [s[0] for s in samples]
            threads = [96] + [s[1] for s in samples]
            ax.step(times, threads, where="post", linewidth=1.4,
                    label=f"run {row['run']}")
            settled = [s[1] for s in samples if s[0] >= 2.0]
            modal = Counter(settled).most_common(1)[0][0]
            thread_rows.append((w, int(row["run"]), modal,
                                min(settled), max(settled),
                                round(mean(settled), 2)))
        ax.set_ylabel(f"W={w}\nthreads")
        ax.set_ylim(0, 100)
        ax.set_yticks((8, 24, 48, 72, 96))
        ax.set_xlim(0, 30)
        ax.grid(alpha=.25)
        ax.legend(loc="upper right", ncol=2, fontsize=8)
    axes[-1].set_xlabel("Benchmark time (s)")
    fig.suptitle(f"{model_label} active threads: fixed leave-one-W-out evaluation")
    fig.savefig(output / "fixed_held_out_active_threads.png", dpi=180)
    plt.close(fig)
    write_csv(output / "fixed_thread_summary.csv",
              ("warehouse", "run", "modal_threads_after_2s",
               "min_threads_after_2s", "max_threads_after_2s",
               "mean_threads_after_2s"), thread_rows)

    fig, ax = plt.subplots(figsize=(10, 6), layout="constrained")
    for method in METHODS:
        rows = [row for row in summary if row[0] == method]
        averages = [row[3] / 1000 for row in rows]
        lower = [(row[3] - row[4]) / 1000 for row in rows]
        upper = [(row[5] - row[3]) / 1000 for row in rows]
        ax.errorbar(STATES, averages, yerr=[lower, upper], fmt="o-",
                    capsize=3, linewidth=1.6,
                    label=(f"{model_label} (held-out)" if method == "metis_test"
                           else LABELS[method]))
    ax.set_xscale("log", base=2)
    ax.set_xticks(STATES, [str(w) for w in STATES])
    ax.set_xlabel("Active home warehouses W (log scale)")
    ax.set_ylabel("Committed TPS (thousands)")
    ax.set_title("TPC-C fixed workloads: Item=100,000, physical-first pinning")
    ax.grid(alpha=.25)
    ax.legend()
    fig.savefig(output / "fixed_protocol_tps.png", dpi=180)
    ax.set_yscale("symlog", linthresh=1)
    ax.set_title("TPC-C fixed workloads: TPS on symlog scale")
    fig.savefig(output / "fixed_protocol_tps_symlog.png", dpi=180)
    plt.close(fig)


def plot_dynamic(source, output, schedule, model_label):
    data = read_csv(source / "results.csv")
    grouped = defaultdict(list)
    for row in data:
        grouped[row["method"]].append(row)
    methods = METHODS[:3]
    for method in methods:
        if len(grouped[method]) != 2:
            raise ValueError(f"Need 2 dynamic runs: {method}")
    summary = []
    phase_rows = []
    binned = defaultdict(list)
    metis_traces = []
    switches = [(int(t), int(w)) for t, w in
                (part.split(":", 1) for part in schedule.split(","))]
    if [t for t, _ in switches] != [0, 20, 40]:
        raise ValueError("Expected a 60 s schedule with switches at 0, 20, 40")
    phases = tuple((start, end, w) for (start, w), (end, _) in
                   zip(switches, switches[1:] + [(60, 0)]))
    schedule_label = "→".join(str(w) for _, w in switches)
    for method in methods:
        values = [int(row["tps"]) for row in grouped[method]]
        summary.append((method, 2, round(mean(values), 1), min(values), max(values)))
        for row in sorted(grouped[method], key=lambda r: int(r["run"])):
            samples = trace(Path(row["trace"]))
            if method == "metis_test":
                metis_traces.append((int(row["run"]), samples))
            for second in range(60):
                values = [s[2] for s in samples if second <= s[0] < second + 1]
                if not values:
                    raise ValueError(f"No TPS samples for second {second}: {row['trace']}")
                binned[method, second].append(mean(values))
            for index, (start, end, w) in enumerate(phases, 1):
                settled = [s for s in samples if start + 2 <= s[0] < end]
                phase_rows.append((method, int(row["run"]), index, w,
                                   len(settled), round(mean(s[2] for s in settled), 1),
                                   (Counter(s[1] for s in settled).most_common(1)[0][0]
                                    if method == "metis_test" else 96)))
    write_csv(output / "dynamic_summary.csv",
              ("method", "runs", "mean_tps", "min_tps", "max_tps"), summary)
    write_csv(output / "dynamic_phase_summary.csv",
              ("method", "run", "phase", "warehouse", "samples_after_2s",
               "mean_tps_after_2s", "modal_threads_after_2s"), phase_rows)

    fig, ax = plt.subplots(figsize=(11, 4.5), layout="constrained")
    for run, samples in metis_traces:
        ax.step([0] + [s[0] for s in samples],
                [96] + [s[1] for s in samples], where="post",
                linewidth=1.5, label=f"{model_label} run {run}")
    ax.axhline(96, linestyle="--", color="gray", linewidth=1,
               label="Silo fixed at 96")
    for second in (20, 40):
        ax.axvline(second, linestyle=":", color="black", linewidth=1)
    for start, end, w in phases:
        x = (start + end) / 2
        ax.text(x, .89, f"W={w}", transform=ax.get_xaxis_transform(),
                ha="center", va="top")
    ax.set_xlim(0, 60)
    ax.set_ylim(0, 100)
    ax.set_yticks((8, 16, 24, 32, 48, 64, 80, 96))
    ax.set_xlabel("Benchmark time (s)")
    ax.set_ylabel("Active threads")
    ax.set_title(f"{model_label} active threads: W={schedule_label}")
    ax.grid(alpha=.25)
    ax.legend(loc="center right")
    fig.savefig(output / "dynamic_active_threads.png", dpi=180)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(11, 5), layout="constrained")
    seconds = list(range(60))
    for method in methods:
        averages = [mean(binned[method, second]) / 1000 for second in seconds]
        lower = [min(binned[method, second]) / 1000 for second in seconds]
        upper = [max(binned[method, second]) / 1000 for second in seconds]
        label = (f"{model_label} (all-W model)" if method == "metis_test"
                 else LABELS[method])
        line, = ax.plot([second + .5 for second in seconds], averages,
                        linewidth=1.6, label=label)
        ax.fill_between([second + .5 for second in seconds], lower, upper,
                        color=line.get_color(), alpha=.12)
    for second in (20, 40):
        ax.axvline(second, linestyle=":", color="black", linewidth=1)
    for start, end, w in phases:
        x = (start + end) / 2
        ax.text(x, .97, f"W={w}", transform=ax.get_xaxis_transform(),
                ha="center", va="top")
    ax.set_xlim(0, 60)
    ax.set_ylim(bottom=0)
    ax.set_xlabel("Benchmark time (s)")
    ax.set_ylabel("Interval committed TPS (thousands, 1 s bins)")
    ax.set_title(f"TPC-C dynamic workload: W={schedule_label}")
    ax.grid(alpha=.25)
    ax.legend(loc="lower center", ncol=3)
    fig.savefig(output / "dynamic_protocol_tps.png", dpi=180)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixed", type=Path)
    parser.add_argument("--dynamic", type=Path)
    parser.add_argument("--schedule", default="0:16,20:96,40:4")
    parser.add_argument("--model-label", default="Metis-test")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.fixed and not args.dynamic:
        parser.error("Provide --fixed and/or --dynamic")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.fixed:
        plot_fixed(args.fixed, args.output, args.model_label)
    if args.dynamic:
        plot_dynamic(args.dynamic, args.output, args.schedule, args.model_label)


if __name__ == "__main__":
    main()
