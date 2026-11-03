#!/usr/bin/env python3
"""Plot fixed leave-one-out and live TPC-C workload-switch measurements."""

import argparse
import csv
import re
from pathlib import Path
from statistics import mean, median
from collections import Counter

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


ROOT = Path(__file__).resolve().parent
STATES = (1, 4, 16, 32, 96)
EXPECTED = {1: 8, 4: 8, 16: 16, 32: 32, 96: 96}
FIELD = re.compile(r"([a-z_]+)=([0-9.]+|[a-z_]+)")
COLORS = {"aware": "#1f77b4", "observed": "#d95f02"}
LABELS = {"aware": "Warehouse-aware LinUCB", "observed": "Observed-load policy"}


def read_log(path):
    samples, changes = [], []
    for line in path.read_text().splitlines():
        fields = dict(FIELD.findall(line))
        if "[TPC-C workload]" in line and "applied_workers=" not in line:
            changes.append((float(fields["bench_s"]), int(fields["active_warehouses"])))
        elif "[Metis-test]" in line and "bench_s" in fields:
            samples.append({"time": float(fields["bench_s"]),
                            "threads": int(fields["active_threads"]),
                            "tps": float(fields["tput"]),
                            "abort": float(fields["abort_rate"]),
                            "phase": fields["phase"]})
    if not samples or not changes:
        raise ValueError(f"Missing dynamic trace or workload events: {path}")
    return samples, changes


def read_tps(path):
    with path.open(newline="") as source:
        return [float(row["tps"]) for row in csv.DictReader(source)]


def fixed(out):
    measurements = {}
    for label in LABELS:
        measurements[label] = []
        for state in STATES:
            if label == "aware":
                path = ROOT / "logs/eval/cross_wh_loo_v1" / f"target_{state}_held_out/summary.csv"
            else:
                path = ROOT / "logs/eval/observed_wh_loo_v1" / f"target_{state}_midpoint_v1/summary.csv"
            measurements[label].append(read_tps(path))
    fig, (top, bottom) = plt.subplots(2, 1, figsize=(10, 7), sharex=True,
                                      gridspec_kw={"height_ratios": [1, 2]})
    xs = list(range(len(STATES)))
    top.plot(xs, [EXPECTED[s] for s in STATES], "o-", color="black",
             label="Both models")
    top.set_ylabel("Selected workers")
    top.set_yticks([8, 16, 32, 96])
    top.grid(alpha=.25)
    top.legend()
    for label, offset in (("aware", -.17), ("observed", .17)):
        values = measurements[label]
        averages = [mean(v) / 1000 for v in values]
        lower = [mean(v) / 1000 - min(v) / 1000 for v in values]
        upper = [max(v) / 1000 - mean(v) / 1000 for v in values]
        bottom.bar([x + offset for x in xs], averages, width=.32,
                   color=COLORS[label], label=LABELS[label])
        bottom.errorbar([x + offset for x in xs], averages,
                        yerr=[lower, upper], fmt="none", color="black", capsize=3)
    bottom.set_ylabel("Mean throughput (kTPS)\nrange across runs")
    bottom.set_xticks(xs, STATES)
    bottom.set_xlabel("Active warehouses (fixed, leave-one-out)")
    bottom.grid(axis="y", alpha=.25)
    bottom.legend()
    fig.suptitle("Fixed TPC-C: held-out workload evaluation (30 s per run)")
    fig.tight_layout()
    path = out / "fixed_comparison.png"
    fig.savefig(path, dpi=180)
    plt.close(fig)
    return measurements


def matched_fixed(out, model_name):
    rows = []
    for state in STATES:
        for label in LABELS:
            version = "warehouse_aware" if label == "aware" else "observed"
            directory = ROOT / "logs/eval" / model_name / f"{version}_matched_fixed_w{state}"
            if not (directory / "summary.csv").exists():
                return None
            trace = []
            for line in (directory / "active_1.log").read_text().splitlines():
                if "[Metis-test]" not in line or "bench_s=" not in line:
                    continue
                fields = dict(FIELD.findall(line))
                if float(fields["bench_s"]) >= 2.0:
                    trace.append(int(fields["active_threads"]))
            if not trace:
                raise ValueError(f"No settled fixed samples: {directory}")
            rows.append((label, state, read_tps(directory / "summary.csv")[0],
                         Counter(trace).most_common(1)[0][0], min(trace), max(trace)))
    with (out / "matched_fixed_metrics.csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(["model", "warehouse", "overall_tps", "modal_threads_after_2s",
                         "min_threads_after_2s", "max_threads_after_2s"])
        writer.writerows(rows)
    fig, (tps_ax, thread_ax) = plt.subplots(2, 1, figsize=(10, 7),
                                            sharex=True,
                                            gridspec_kw={"height_ratios": [2, 1]})
    xs = list(range(len(STATES)))
    for label, offset in (("aware", -.17), ("observed", .17)):
        model_rows = [r for r in rows if r[0] == label]
        tps_ax.bar([x + offset for x in xs], [r[2] / 1000 for r in model_rows],
                   width=.32, color=COLORS[label], label=LABELS[label])
        thread_ax.errorbar([x + offset for x in xs], [r[3] for r in model_rows],
                           yerr=[[r[3] - r[4] for r in model_rows],
                                 [r[5] - r[3] for r in model_rows]],
                           fmt="o", capsize=4, color=COLORS[label])
    tps_ax.set_ylabel("Throughput (kTPS, one 15 s run)")
    tps_ax.legend()
    thread_ax.set_ylabel("Modal workers\nrange after 2 s")
    thread_ax.set_yticks([8, 16, 32, 64, 96])
    thread_ax.set_xticks(xs, STATES)
    thread_ax.set_xlabel("Active warehouses (fixed, same models as dynamic test)")
    for ax in (tps_ax, thread_ax):
        ax.grid(axis="y", alpha=.25)
    fig.suptitle("Fixed TPC-C: five-state models used in the dynamic test")
    fig.tight_layout()
    fig.savefig(out / "matched_fixed_comparison.png", dpi=180)
    plt.close(fig)
    return {label: {state: modal for label_, state, _, modal, _, _ in rows
                    if label_ == label} for label in LABELS}


def dynamic(out, directory, duration, runs, targets):
    traces = {}
    for label in LABELS:
        traces[label] = []
        for run in range(1, runs + 1):
            traces[label].append(read_log(directory / label / f"active_{run}.log"))
    schedule = traces["aware"][0][1]
    for label in LABELS:
        for _, changes in traces[label]:
            if [w for _, w in changes] != [w for _, w in schedule]:
                raise ValueError("Runs used different warehouse sequences")

    phase_rows = []
    with (out / "dynamic_phase_metrics.csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(["model", "run", "phase", "warehouse", "start_s",
                         "end_s", "mean_tps_after_2s", "median_threads_after_2s",
                         "target_thread_fraction_after_2s", "first_target_hold_delay_s"])
        for label, runs_ in traces.items():
            for run, (samples, changes) in enumerate(runs_, 1):
                for stage, (start, warehouse) in enumerate(changes):
                    end = changes[stage + 1][0] if stage + 1 < len(changes) else duration
                    settled = [s for s in samples if start + 2 <= s["time"] < end]
                    if not settled:
                        raise ValueError(f"No settled observations: {label} run {run}, W={warehouse}")
                    target = targets[label][warehouse]
                    first = next((s["time"] - start for s in samples
                                  if start <= s["time"] < end and
                                  s["threads"] == target and
                                  s["phase"] in ("choose", "hold")), None)
                    row = [label, run, stage + 1, warehouse,
                           f"{start:.3f}", f"{end:.3f}",
                           f"{mean(s['tps'] for s in settled):.1f}",
                           median(s["threads"] for s in settled),
                           f"{mean(s['threads'] == target for s in settled):.3f}",
                           "" if first is None else f"{first:.3f}"]
                    writer.writerow(row)
                    phase_rows.append(row)

    fig, (tps_ax, share_ax) = plt.subplots(2, 1, figsize=(11, 7),
                                           sharex=True)
    stages = list(range(len(schedule)))
    for label, offset in (("aware", -.11), ("observed", .11)):
        stage_tps = [[float(row[6]) / 1000 for row in phase_rows
                      if row[0] == label and row[2] == stage + 1]
                     for stage in stages]
        stage_share = [[float(row[8]) for row in phase_rows
                        if row[0] == label and row[2] == stage + 1]
                       for stage in stages]
        tps_ax.errorbar([stage + offset for stage in stages],
                        [mean(values) for values in stage_tps],
                        yerr=[[mean(values) - min(values) for values in stage_tps],
                              [max(values) - mean(values) for values in stage_tps]],
                        fmt="o-", capsize=4, color=COLORS[label],
                        label=LABELS[label])
        share_ax.plot([stage + offset for stage in stages],
                      [mean(values) for values in stage_share], "o-",
                      color=COLORS[label], label=LABELS[label])
    tps_ax.set_yscale("log")
    tps_ax.set_ylabel("Throughput after 2 s (kTPS, log)")
    share_ax.set_ylabel("Fraction at own fixed-load choice")
    share_ax.set_ylim(0, 1.05)
    share_ax.set_xticks(stages,
                        [f"{w} W\n{int(t)}–{int(schedule[i+1][0]) if i+1 < len(schedule) else int(duration)} s"
                         for i, (t, w) in enumerate(schedule)])
    for ax in (tps_ax, share_ax):
        ax.grid(alpha=.25)
    tps_ax.legend()
    fig.suptitle("Dynamic TPC-C by workload phase (two runs, first 2 s excluded)")
    fig.tight_layout()
    fig.savefig(out / "dynamic_phase_comparison.png", dpi=180)
    plt.close(fig)

    for run in range(runs):
        fig, axes = plt.subplots(3, 1, figsize=(13, 8), sharex=True,
                                 gridspec_kw={"height_ratios": [1, 2, 2]})
        t = [start for start, _ in schedule] + [duration]
        w = [warehouse for _, warehouse in schedule]
        axes[0].step(t, w + [w[-1]], where="post", color="black")
        axes[0].set_ylabel("Active\nwarehouses")
        axes[0].set_yticks([1, 4, 16, 32, 96])
        for label in LABELS:
            samples = traces[label][run][0]
            axes[1].step([0] + [s["time"] for s in samples],
                         [96] + [s["threads"] for s in samples], where="post",
                         color=COLORS[label], label=LABELS[label], linewidth=1.4)
            axes[2].plot([s["time"] for s in samples],
                         [s["tps"] / 1000 for s in samples], color=COLORS[label],
                         label=LABELS[label], alpha=.8, linewidth=1.3)
        for label in LABELS:
            axes[1].step(t, [targets[label][x] for x in w] + [targets[label][w[-1]]],
                         where="post", linestyle="--", color=COLORS[label],
                         alpha=.65, label=f"{label} fixed-load choice")
        axes[1].set_ylabel("Active workers")
        axes[1].set_yticks([8, 16, 32, 96])
        axes[2].set_ylabel("Interval throughput\n(kTPS, log scale)")
        axes[2].set_yscale("log")
        axes[2].set_xlabel("Benchmark time (s)")
        for ax in axes:
            ax.set_xlim(0, duration)
            ax.grid(alpha=.2)
            for start, _ in schedule[1:]:
                ax.axvline(start, color="gray", linestyle=":", alpha=.6)
        axes[1].legend(ncol=3, fontsize=8)
        fig.suptitle(f"Dynamic TPC-C workload: run {run + 1}")
        fig.tight_layout()
        fig.savefig(out / f"dynamic_trace_run{run + 1}.png", dpi=180)
        plt.close(fig)

    with (out / "dynamic_overall.csv").open("w", newline="") as target:
        writer = csv.writer(target)
        writer.writerow(["model", "run", "overall_tps"])
        for label in LABELS:
            tps = read_tps(directory / label / "summary.csv")
            for run, value in enumerate(tps, 1):
                writer.writerow([label, run, int(value)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dynamic-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--model-name", default="dynamic_all_v1")
    parser.add_argument("--include-loo", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.include_loo:
        fixed(args.output_dir)
    targets = matched_fixed(args.output_dir, args.model_name)
    if targets is None:
        targets = {label: EXPECTED for label in LABELS}
    dynamic(args.output_dir, args.dynamic_dir, args.duration, args.runs, targets)
    print(args.output_dir)


if __name__ == "__main__":
    main()
