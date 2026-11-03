#!/usr/bin/env python3
"""Plot interval TPS for fixed Metis-test runs with active-thread logging."""

import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read(path):
    rows = []
    for line in path.read_text().splitlines():
        elapsed = re.search(r"elapsed_s=([0-9.]+)", line)
        tps = re.search(r"tput=([0-9.]+)", line)
        if elapsed and tps:
            rows.append((float(elapsed.group(1)), float(tps.group(1))))
    if not rows:
        raise ValueError(f"No interval TPS in {path}")
    offset = rows[0][0]
    return [t - offset for t, _ in rows], [v for _, v in rows]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fig, ax = plt.subplots(figsize=(10, 4))
    for path in sorted(args.log_dir.glob("active_fixed_*_run_*.log")):
        elapsed, tps = read(path)
        label = re.search(r"active_fixed_(\d+)_run_(\d+)", path.name)
        ax.plot(elapsed, [value / 1000 for value in tps],
                label=f"{label.group(1)} threads", linewidth=1.3, alpha=0.85)
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("Interval TPS (thousands)")
    ax.set_title("TPC-C, active warehouses=16: fixed active threads")
    ax.grid(True, alpha=0.25)
    ax.legend()
    fig.tight_layout()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=180)
    print(args.output)


if __name__ == "__main__":
    main()
