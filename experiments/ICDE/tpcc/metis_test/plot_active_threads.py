#!/usr/bin/env python3
"""Plot Metis-test active thread traces from saved active_*.log files."""

import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


THREADS = re.compile(r"active_threads=(\d+)")
ELAPSED = re.compile(r"elapsed_s=([0-9.]+)")


def read_trace(path: Path, nominal_period_s: float, initial_threads: int):
    threads = []
    elapsed = []
    for line in path.read_text().splitlines():
        match = THREADS.search(line)
        if not match:
            continue
        threads.append(int(match.group(1)))
        match = ELAPSED.search(line)
        elapsed.append(float(match.group(1)) if match else None)
    if not threads:
        raise ValueError(f"No active-thread samples in {path}")
    if any(value is None for value in elapsed):
        elapsed = [(i + 1) * nominal_period_s for i in range(len(threads))]
        inferred = True
    else:
        first = elapsed[0]
        elapsed = [value - first + nominal_period_s for value in elapsed]
        inferred = False
    # Metis-test starts at the maximum thread count before its first decision.
    elapsed.insert(0, 0.0)
    threads.insert(0, initial_threads)
    return elapsed, threads, inferred


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--period-us", type=int, default=200000)
    parser.add_argument("--initial-threads", type=int, default=96)
    parser.add_argument("--title", default="Metis-test active threads")
    args = parser.parse_args()

    paths = sorted(args.log_dir.glob("active_*.log"))
    if not paths:
        raise SystemExit(f"No active_*.log in {args.log_dir}")
    fig, axes = plt.subplots(len(paths), 1, figsize=(10, 2.2 * len(paths)),
                             sharex=True, squeeze=False)
    inferred_any = False
    for ax, path in zip(axes[:, 0], paths):
        elapsed, threads, inferred = read_trace(
            path, args.period_us / 1e6, args.initial_threads)
        inferred_any |= inferred
        ax.step(elapsed, threads, where="post", linewidth=1.5)
        ax.set_ylim(0, 100)
        ax.set_yticks([0, 24, 48, 72, 96])
        ax.set_ylabel(f"{path.stem}\nthreads")
        ax.grid(True, alpha=0.25)
    axes[-1, 0].set_xlabel("Elapsed time (approx. s)" if inferred_any
                           else "Elapsed time (s)")
    fig.suptitle(args.title)
    fig.tight_layout()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=180)
    print(args.output)


if __name__ == "__main__":
    main()
