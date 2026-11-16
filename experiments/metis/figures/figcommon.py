"""Shared paths and helpers of the figure scripts.

DATA: measured results, laid out as in Metis-data (default: the submodule
      data/ at the repository root; override with METIS_DATA, e.g. to plot
      the results of a new run written to METIS_OUT by the experiment scripts).
OUT:  output directory of the figures (default experiments/metis/paper_figures,
      override with METIS_FIG_OUT).
"""
import csv
import os
import re
import statistics
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DATA = Path(os.environ.get("METIS_DATA", ROOT / "data"))
OUT = Path(os.environ.get("METIS_FIG_OUT", Path(__file__).resolve().parents[1] / "paper_figures"))
OUT.mkdir(parents=True, exist_ok=True)

INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
METIS, ORACLE = "#2a78d6", "#eb6834"
HILL_CLIMBING = "#1baf7a"

YCSB_ORACLE = DATA / "ycsb/oracle/skew_0.7-0.999/results.csv"   # oracle of skew 0.7-0.999
YCSB_ORACLE_LOW = DATA / "ycsb/oracle/skew_0_0.5_0.9/results.csv"  # skew 0, 0.5 (and 0.9)
TPCC_SCHEDULES = {"D1": "0:16,20:1,40:4", "D11": "0:2,20:8,40:1"}
YCSB_SCHEDULES = {"Y1": "0.7,20:0.95,40:0.8", "Y4": "0.99,20:0.5,40:0.95"}


def _mean_curve(path, state_key, n_key, tps_key):
    acc = defaultdict(lambda: defaultdict(list))
    with Path(path).open() as f:
        for r in csv.DictReader(f):
            acc[r[state_key]][int(r[n_key])].append(float(r[tps_key]))
    return {s: {n: statistics.mean(v) for n, v in ns.items()} for s, ns in acc.items()}


def tpcc_curves():
    """W -> {N: mean TPS} of the TPC-C oracle sweep (tpcc/oracle/w<W>/results.csv)."""
    out = {}
    for d in sorted((DATA / "tpcc/oracle").glob("w*"), key=lambda p: int(p.name[1:])):
        out.update(_mean_curve(d / "results.csv", "active_warehouses", "active_threads", "tps"))
    return out


def oracle_curve(bench):
    """state -> {N: mean TPS} from the fixed-N oracle sweep."""
    if bench == "tpcc":
        return tpcc_curves()
    return _mean_curve(YCSB_ORACLE, "skew", "threads", "throughput_tps")


def _best(curves):
    out = {}
    for s, m in curves.items():
        best = max(m, key=m.get)
        out[s] = (best, m[best], [n for n in sorted(m) if m[n] >= 0.98 * m[best]])
    return out


def tpcc_oracle():
    """W -> (best N, best TPS, Ns within 98% of the best)."""
    return _best(tpcc_curves())


def ycsb_oracle():
    """skew (0.7-0.999) -> (best N, best TPS, Ns within 98% of the best)."""
    return _best(oracle_curve("ycsb"))


def ycsb_curves():
    """Motivation figure: 'skew=<s>' -> {N: mean TPS}, skew 0.7-0.999."""
    c = oracle_curve("ycsb")
    return {f"skew={s}": c[s] for s in sorted(c, key=float)}


def tpcc_curves_labeled():
    """Motivation figure: 'W=<w>' -> {N: mean TPS}."""
    return {f"W={w}": c for w, c in tpcc_curves().items()}


def curves(bench):
    """Oracle curves used by the step-level figures; YCSB adds skew 0 and 0.5."""
    c = oracle_curve(bench)
    if bench == "ycsb":
        for k, v in _mean_curve(YCSB_ORACLE_LOW, "skew", "threads", "throughput_tps").items():
            c.setdefault(k, v)
    return c


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


def phases(bench, sched):
    if bench == "tpcc":
        return [(int(x.split(":")[0]), x.split(":")[1]) for x in sched.split(",")]
    p = sched.split(",")
    return [(0, p[0])] + [(int(x.split(":")[0]), x.split(":")[1]) for x in p[1:]]


def style(ax):
    ax.set_facecolor(SURFACE)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)


def first(*paths):
    """First existing path. Metis logs are named metis_v2_* in the recorded data
    (data/) and metis_* in runs of the current experiment scripts."""
    return next((p for p in paths if p.exists()), paths[0])
