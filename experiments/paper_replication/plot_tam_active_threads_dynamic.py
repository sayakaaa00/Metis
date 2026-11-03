#!/usr/bin/env python3
import os
import re

import matplotlib.pyplot as plt


# ==== Settings for dynamic 3-phase environment ================================

# TAM update period [microseconds]
UPDATE_US = 1000.0  # 1 ms

# 3-phase dynamic skew pattern (match compare_tam_dynamic.sh)
PHASE_SKEWS = [0.9, 0.7, 0.99]
PHASE_DURS_SEC = [20, 20, 20]

# Per-phase optimal thread counts (for horizontal lines & first-reach markers)
PHASE_OPT_THREADS = [26, 32, 21]
PHASE_NAMES = ["phase1", "phase2", "phase3"]


def parse_log(path: str):
    pattern = re.compile(r"active_threads=(\d+)")
    active_threads = []
    with open(path, "r") as f:
        for line in f:
            m = pattern.search(line)
            if not m:
                continue
            active_threads.append(int(m.group(1)))
    return active_threads


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description=(
            "Plot TAM active_threads over time (dynamic 3-phase skew) "
            "and show per-phase optimal threads & first reach times"
        )
    )
    parser.add_argument("logfile", help="path to tam_active_threads_*.log")
    parser.add_argument(
        "--out",
        help=(
            "output png path (default: same dir, "
            "basename + _active_threads_dynamic.png)"
        ),
    )

    args = parser.parse_args()

    active = parse_log(args.logfile)
    if not active:
        print(f"no active_threads lines found in {args.logfile}")
        return

    # time axis: each sample is UPDATE_US microseconds apart
    dt_ms = UPDATE_US / 1000.0
    times_ms = [dt_ms * i for i in range(len(active))]

    plt.figure(figsize=(10, 4))
    ax = plt.gca()
    ax.plot(times_ms, active, drawstyle="steps-post")
    ax.set_xlabel("time [ms]")
    ax.set_ylabel("active_threads")

    title = "LinUCBTAM"
    ax.set_title(title)

    # always start x-axis at 0
    ax.set_xlim(left=0)

    # ==== Compute phase boundaries in time [ms] ===============================

    phase_starts_ms = [0.0]
    for d in PHASE_DURS_SEC[:-1]:
        phase_starts_ms.append(phase_starts_ms[-1] + d * 1000.0)
    phase_ends_ms = [s + d * 1000.0 for s, d in zip(phase_starts_ms, PHASE_DURS_SEC)]

    # Optionally draw vertical lines at phase boundaries (except t=0)
    for t_ms in phase_starts_ms[1:]:
        ax.axvline(x=t_ms, color="gray", linestyle=":", linewidth=0.8)

    # ==== Draw per-phase optimal thread horizontal lines ======================

    colors = ["red", "green", "blue"]
    for idx, opt_thr in enumerate(PHASE_OPT_THREADS):
        c = colors[idx % len(colors)]
        label = f"{PHASE_NAMES[idx]} optimal={opt_thr}"
        if idx < len(PHASE_SKEWS):
            label += f" (skew={PHASE_SKEWS[idx]})"
        ax.axhline(y=opt_thr, color=c, linestyle="--", linewidth=1, label=label)

    # ==== Compute first reach time per phase ==================================

    first_reach_times = [None] * len(PHASE_OPT_THREADS)
    for t, thr in zip(times_ms, active):
        for idx, (start_ms, end_ms, opt_thr) in enumerate(
            zip(phase_starts_ms, phase_ends_ms, PHASE_OPT_THREADS)
        ):
            # already have a first reach for this phase
            if first_reach_times[idx] is not None:
                continue
            # outside this phase's time range
            if not (start_ms <= t < end_ms):
                continue
            # reached optimal in this phase for the first time
            if thr == opt_thr:
                first_reach_times[idx] = t

    # mark first reach points on the plot
    for idx, t in enumerate(first_reach_times):
        if t is None:
            continue
        opt_thr = PHASE_OPT_THREADS[idx]
        c = colors[idx % len(colors)]
        ax.scatter([t], [opt_thr], color=c, zorder=3,
                   label=f"{PHASE_NAMES[idx]} first reach {t:.1f} ms")

    ax.grid(True, linestyle="--", alpha=0.5)
    ax.legend(loc="best", fontsize=8)

    out_path = args.out
    if not out_path:
        base, _ = os.path.splitext(args.logfile)
        out_path = base + "_active_threads_dynamic.png"

    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    print(f"saved plot to {out_path}")


if __name__ == "__main__":
    main()
