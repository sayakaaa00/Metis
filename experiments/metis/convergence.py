#!/usr/bin/env python3
"""Convergence and stability metrics for the dynamic runs.

For every phase of every schedule/run and method:
  reach_s   time from the workload change until the 200 ms interval TPS enters
            >= 95% of the phase's oracle TPS and stays there (median of the
            remaining intervals of the phase >= 95%; we use the first interval
            from which the rest of the phase averages >= 95% and the interval
            itself is >= 95%). Phases never reaching it count as the phase length.
  loss      1 - (mean interval TPS in the phase / oracle TPS)
Stability (fixed loads, after 5 s): thread-count changes per second and stdev.
Writes <bench>/dynamic/convergence_summary.csv and prints a summary.
"""
import csv
import glob
import re
import statistics
from collections import defaultdict
from pathlib import Path

import common as C
import dynamic as D

HERE = C.HERE
METHODS = ["metis", "adatam", "adatam_default", "silo_bo", "silo_nobo"]


def samples(path, pattern):
    out = []
    if path.exists():
        for m in re.finditer(pattern, path.read_text()):
            out.append((float(m[1]), float(m[2])))
    return out


def dynamic_metrics(bench):
    table = D.schedules(bench)
    oracle = C.oracle(bench)
    d = HERE / bench / "dynamic"
    rows = []
    for name, sched in table.items():
        ph = D.phases(bench, sched)
        for m in METHODS:
            for run in ("1", "2"):
                log = d / "logs" / f"{name}_{m}_run{run}.log"
                trace = log.with_suffix(".trace.log")
                src = trace if trace.exists() else log
                tps = samples(src, r"\[TPS sample\] bench_s=([\d.]+) interval_tps=([\d.]+)")
                if not tps:
                    continue
                for i, (t0, s) in enumerate(ph):
                    t1 = ph[i + 1][0] if i + 1 < len(ph) else 60
                    target = 0.95 * oracle[s][1]
                    seg = [(t, v) for t, v in tps if t0 + 0.2 <= t <= t1]
                    if not seg:
                        continue
                    reach = t1 - t0
                    for k, (t, v) in enumerate(seg):
                        rest = [x for _, x in seg[k:]]
                        if v >= target and statistics.mean(rest) >= target:
                            reach = t - t0
                            break
                    loss = 1 - statistics.mean(v for _, v in seg) / oracle[s][1]
                    rows.append({"schedule": name, "method": m, "run": run, "phase": i,
                                 "state": s, "reach_s": round(reach, 2),
                                 "loss": round(loss, 4), "phase_len": t1 - t0})
    return rows


def stability(bench):
    out = {}
    for m in ("metis", "adatam", "adatam_default"):
        vals = []
        for f in glob.glob(str(HERE / bench / "compare_fixed" / "logs" / f"{m}_*_run*.trace.log")):
            xs = [n for t, n in samples(Path(f), r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)")
                  if t >= 5.0]
            if len(xs) < 5:
                continue
            ch = sum(1 for i in range(1, len(xs)) if xs[i] != xs[i - 1])
            vals.append((ch / (len(xs) * 0.1), statistics.pstdev(xs)))
        if vals:
            out[m] = (statistics.mean(v[0] for v in vals), statistics.mean(v[1] for v in vals))
    return out


def main():
    for bench in ("tpcc", "ycsb"):
        rows = dynamic_metrics(bench)
        path = HERE / bench / "dynamic" / "convergence_summary.csv"
        with path.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
        print(f"== {bench} (per schedule: median reach_s over phases x runs / mean loss)")
        agg = defaultdict(list)
        for r in rows:
            agg[(r["schedule"], r["method"])].append(r)
        for name in D.schedules(bench):
            cells = []
            for m in METHODS:
                v = agg.get((name, m))
                if v:
                    cells.append(f"{m}={statistics.median(x['reach_s'] for x in v):.1f}s/"
                                 f"{statistics.mean(x['loss'] for x in v):.3f}")
            print(f"  {name:6s} " + "  ".join(cells))
        for m, (c, sd) in stability(bench).items():
            print(f"  stability {m:15s} changes/s={c:.2f} stdev={sd:.1f}")


if __name__ == "__main__":
    main()
