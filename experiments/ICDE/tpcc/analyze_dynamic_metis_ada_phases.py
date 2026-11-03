#!/usr/bin/env python3
"""Compare Metis-test and AdaTAM controller samples within each W phase."""

import argparse
import csv
import re
from pathlib import Path
from statistics import mean


METIS = re.compile(
    r"\[Metis-test\].*?bench_s=([\d.]+).*?active_threads=(\d+) "
    r"tput=([\d.]+)"
)
ADA = re.compile(
    r"\[AdaTAM\] active_threads=(\d+) committed_txs=\d+ "
    r"tput=([\d.]+) tx/s\n"
    r"\[TAM sample\] bench_s=([\d.]+) active_threads=\d+"
)


def samples(path, method):
    content = path.read_text(errors="replace")
    if method == "metis_test":
        return [(float(t), int(n), float(tps))
                for t, n, tps in METIS.findall(content)]
    return [(float(t), int(n), float(tps))
            for n, tps, t in ADA.findall(content)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-dir", type=Path, required=True)
    parser.add_argument("--skip-after-switch-s", type=float, default=2.0)
    args = parser.parse_args()
    directory = args.experiment_dir
    config = dict(line.split("=", 1) for line in
                  (directory / "config.txt").read_text().splitlines()
                  if "=" in line)
    changes = [tuple(map(int, part.split(":")))
               for part in config["schedule"].split(",")]
    duration = int(config["extime"])
    phases = [(start, changes[index + 1][0]
               if index + 1 < len(changes) else duration, w)
              for index, (start, w) in enumerate(changes)]
    rows = []
    for method in ("metis_test", "adatam"):
        for run in (1, 2):
            path = directory / "traces" / f"{method}_run{run}.log"
            series = samples(path, method)
            if len(series) < duration * 4:
                raise ValueError(f"Too few controller samples: {path}")
            for start, end, w in phases:
                settled = [(n, tps) for t, n, tps in series
                           if start + args.skip_after_switch_s <= t < end]
                if not settled:
                    raise ValueError(f"Missing settled W={w} samples: {path}")
                rows.append((method, run, w, len(settled),
                             round(mean(tps for _, tps in settled)),
                             round(mean(n for n, _ in settled), 2)))
    output = directory / "controller_phase_metrics.csv"
    with output.open("w", newline="") as destination:
        writer = csv.writer(destination)
        writer.writerow(("method", "run", "active_warehouses", "samples",
                         "mean_interval_tps_after_2s", "mean_workers_after_2s"))
        writer.writerows(rows)
    print(output)


if __name__ == "__main__":
    main()
