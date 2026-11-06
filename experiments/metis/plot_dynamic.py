#!/usr/bin/env python3
"""Dynamic-load time series: active threads (Metis, adaTAM) and interval TPS
(all methods) for each schedule, run 1. Writes <outdir>/<prefix><name>.png
(default: <bench>/dynamic/<name>.png).

  plot_dynamic.py --bench tpcc|ycsb [--run 1] [--schedules D1,D2] [--outdir DIR]
                  [--prefix PREFIX]
"""
import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

import common as C
import dynamic as D
import plot_common as P

COLORS = {"metis": ("Metis", "#2a78d6"), "adatam": ("adaTAM", "#1baf7a"),
          "silo_bo": ("Silo (backoff)", "#eda100"),
          "silo_nobo": ("Silo (no backoff)", "#e87ba4")}


def series(path, pattern):
    xs, ys = [], []
    if path is None or not path.exists():
        return xs, ys
    for line in path.read_text().splitlines():
        m = re.search(pattern, line)
        if m:
            xs.append(float(m[1]))
            ys.append(float(m[2]))
    return xs, ys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", default="tpcc")
    ap.add_argument("--run", default="1")
    ap.add_argument("--schedules", default="")
    ap.add_argument("--outdir", default="")
    ap.add_argument("--prefix", default="")
    args = ap.parse_args()
    table = D.schedules(args.bench)
    if args.schedules:
        table = {n: table[n] for n in args.schedules.split(",")}
    oracle = C.oracle(args.bench)
    d = C.HERE / args.bench / "dynamic"
    label = "W" if args.bench == "tpcc" else "skew"
    for name, sched in table.items():
        ph = D.phases(args.bench, sched)
        fig, (a1, a2) = plt.subplots(2, 1, figsize=(11, 6.4), sharex=True,
                                     facecolor=P.SURFACE,
                                     gridspec_kw={"height_ratios": [1, 1.2]})
        for ax in (a1, a2):
            P.style(ax)
            for t, _ in ph[1:]:
                ax.axvline(t, color=P.GRID, linewidth=1, zorder=0)
        # oracle best N and oracle TPS per phase
        for i, (t, s) in enumerate(ph):
            t2 = ph[i + 1][0] if i + 1 < len(ph) else 60
            a1.hlines(oracle[s][0], t, t2, color=P.ORACLE, linestyle="--", linewidth=1.3,
                      label="oracle best N" if i == 0 else None)
            a2.hlines(oracle[s][1], t, t2, color=P.ORACLE, linestyle="--", linewidth=1.3,
                      label="oracle TPS" if i == 0 else None)
            if len(ph) <= 6:
                a1.text((t + t2) / 2, 99, f"{label}={s}", ha="center", va="bottom",
                        fontsize=8, color=P.INK2)
        for m, (title, color) in COLORS.items():
            log = d / "logs" / f"{name}_{m}_run{args.run}.log"
            trace = log.with_suffix(".trace.log")
            src = trace if trace.exists() else log
            if m in ("metis", "adatam"):
                x, y = series(trace, r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)")
                a1.step(x, y, where="post", color=color, linewidth=1.6, label=title)
            x, y = series(src, r"\[TPS sample\] bench_s=([\d.]+) interval_tps=([\d.]+)")
            a2.plot(x, y, color=color, linewidth=1.3, label=title)
        a1.set_ylim(0, 104)
        a1.set_yticks([0, 24, 48, 72, 96])
        a1.set_ylabel("Active threads", color=P.INK2)
        a2.set_ylabel("Interval TPS (200 ms)", color=P.INK2)
        a2.set_xlabel("Time (s)", color=P.INK2)
        a2.set_ylim(bottom=0)
        a2.yaxis.set_major_formatter(FuncFormatter(
            lambda v, _: f"{v / 1e6:g}M" if v >= 1e6 else f"{v / 1e3:g}k"))
        a1.set_title(f"{args.bench.upper()} dynamic {name}: {sched}  (run {args.run})",
                     fontsize=11, color=P.INK, loc="left")
        a1.legend(frameon=False, fontsize=8, loc="upper right", ncol=3)
        a2.legend(frameon=False, fontsize=8, loc="upper center",
                  bbox_to_anchor=(0.5, -0.18), ncol=5)
        fig.tight_layout()
        out = (Path(args.outdir) if args.outdir else d) / f"{args.prefix}{name}.png"
        fig.savefig(out, dpi=140, facecolor=P.SURFACE)
        plt.close(fig)
        print(out)


if __name__ == "__main__":
    main()
