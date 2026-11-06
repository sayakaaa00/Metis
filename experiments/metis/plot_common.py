"""Shared style and helpers of the plotting scripts."""
import csv
from collections import defaultdict

import common as C

INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
METIS, ORACLE = "#2a78d6", "#eb6834"  # categorical slots 1 and 2
ADATAM = "#1baf7a"
BAND = "#f6d8cb"
FIGURES = C.HERE / "paper_figures"


def style(ax):
    ax.set_facecolor(SURFACE)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)


def trace(path):
    """Step series of the active threads, starting from all 96 workers at t=0."""
    pts = C.thread_samples(path)
    return [0.0] + [t for t, _ in pts], [96] + [n for _, n in pts]


def curve_ratio(curve, n):
    """TPS at N on the oracle curve relative to its best (linear interpolation)."""
    best = max(curve.values())
    if n in curve:
        return curve[n] / best
    xs = sorted(curve)
    lo = max((x for x in xs if x < n), default=xs[0])
    hi = min((x for x in xs if x > n), default=xs[-1])
    if lo == hi:
        return curve[lo] / best
    return (curve[lo] + (curve[hi] - curve[lo]) * (n - lo) / (hi - lo)) / best


def pick_runs(d, bench):
    """Per state: Metis run whose settled N is closer to the best on the oracle curve
    (tie -> higher TPS), and the adaTAM run with the lower TPS."""
    curves = C.oracle_curve(bench)
    runs = defaultdict(list)
    with (d / "results.csv").open() as f:
        for r in csv.DictReader(f):
            if r["method"] in ("metis", "adatam") and r["tps"]:
                runs[(r["method"], r["state"])].append(
                    (int(r["run"]), float(r["tps"]), int(r["mode_threads"])))
    out = {}
    for (m, s), rs in runs.items():
        if m == "metis":
            out[(m, s)] = max(rs, key=lambda x: (curve_ratio(curves[s], x[2]), x[1]))[0]
        else:
            out[(m, s)] = min(rs, key=lambda x: x[1])[0]
    return out
