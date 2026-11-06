"""Shared settings of the Metis experiments: binaries, workload states, the
command line of every method, running one benchmark, and the oracle curves.

Common conditions: 96 workers, physical-first CPU order, mimalloc preloaded,
clocks_per_us=2900 (TSC of the evaluation machine). Control period: TPC-C
200 ms, YCSB 10 ms. Parked workers sleep 50 us per check.
"""
import csv
import os
import re
import shutil
import statistics
import subprocess
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = Path(os.environ.get("BUILD", ROOT / "build_release"))
MIMALLOC = BUILD / "mimalloc_override/libmimalloc.so"
SILO = {("tpcc", False): BUILD / "silo/tpcc_silo_nobackoff",
        ("tpcc", True): BUILD / "silo/tpcc_silo_backoff",
        ("ycsb", False): BUILD / "silo/ycsb_silo_nobackoff",
        ("ycsb", True): BUILD / "silo/ycsb_silo_backoff"}
STATES = {"tpcc": ["1", "2", "3", "4", "8", "16", "32", "96"],
          "ycsb": ["0.7", "0.8", "0.85", "0.9", "0.95", "0.99", "0.999"]}
PERIOD_US = {"tpcc": 200000, "ycsb": 10000}
# adaTAM step: best of a short sweep (TPC-C 8 of {2,4,8}; YCSB 4 of {1,2,4,8}).
ADATAM_STEP = {"tpcc": 8, "ycsb": 4}
WORKERS = 96
# Cicada/ERMIA YCSB have no pin-order option; pin worker i to CPU i instead
# (CCBENCH_PIN_CPU_LIST). On the evaluation machine (2 x 24 cores, SMT 2,
# CPUs 0-47 = one thread per core) this equals the physical-first order.
IDENTITY = ",".join(str(i) for i in range(min(WORKERS, os.cpu_count() or 1)))


def workload_args(bench, state, extime):
    """Workload and common runtime arguments (no controller, no pinning)."""
    if bench == "tpcc":
        return [f"--thread_num={WORKERS}", "--tpcc_num_wh=96", "--tpcc_num_items=100000",
                f"--tpcc_active_warehouse_count={state}",
                "--tpcc_home_warehouse_assignment=random_per_transaction",
                "--tpcc_perc_payment=43", "--tpcc_perc_order_status=4",
                "--tpcc_perc_delivery=4", "--tpcc_perc_stock_level=4",
                "--tpcc_interactive_ms=0", "--tpcc_retry_same_type=true",
                "--tpcc_log_retry_conflicts=false", f"--extime={extime}",
                "--clocks_per_us=2900"]
    return [f"--thread_num={WORKERS}", f"--extime={extime}", "--clocks_per_us=2900",
            "--ycsb_tuple_num=10000", "--ycsb_max_ope=10", "--ycsb_rratio=50",
            f"--ycsb_zipf_skew={state}"]


def silo_pin_args(bench):
    if bench == "tpcc":
        return ["--tpcc_pin_workers=true", "--tpcc_pin_order=physical_first"]
    return ["--pin_threads=true", "--ycsb_pin_order=physical_first"]


def tam_args(bench):
    """Arguments shared by every run that parks workers (Metis, adaTAM, fixed N)."""
    return ["--tam_min_threads=1", f"--tam_max_threads={WORKERS}",
            f"--tam_update_period_us={PERIOD_US[bench]}", "--tam_idle_sleep_us=50",
            "--tam_log_active_threads=true", "--tam_log_period_us=100000"]


def metis_command(bench, state, extime, model, learn=False, seed=1):
    return ([str(SILO[(bench, False)])] + workload_args(bench, state, extime) +
            silo_pin_args(bench) + tam_args(bench) +
            ["--metis_enable=true", f"--metis_learn={str(learn).lower()}",
             f"--metis_model_path={model}", f"--metis_seed={seed}"])


def command(bench, method, state, extime):
    """Return (argv, extra_env) of one method on one state.

    metis: Metis with the leave-one-out model of the state (fixed-load runs).
    adatam: hill climbing from 96 workers, tuned step. adatam_default: step 2.
    silo_nobo / silo_bo: Silo without / with backoff, all 96 workers.
    cicada / ermia: all 96 workers.
    fixed_<N>: Silo without backoff with the first N workers (oracle sweep).
    """
    if method == "metis":
        return metis_command(bench, state, extime,
                             HERE / bench / "models" / f"loo_{state}.txt"), {}
    if method in ("adatam", "adatam_default"):
        step = ADATAM_STEP[bench] if method == "adatam" else 2
        return ([str(SILO[(bench, False)])] + workload_args(bench, state, extime) +
                silo_pin_args(bench) + tam_args(bench) +
                ["--ada_tam_enable=true", f"--ada_tam_step={step}"]), {}
    if method.startswith("fixed_"):
        return ([str(SILO[(bench, False)])] + workload_args(bench, state, extime) +
                silo_pin_args(bench) + ["--tam_idle_sleep_us=50",
                                        f"--tam_fixed_threads={method[6:]}"]), {}
    if method in ("silo_nobo", "silo_bo"):
        return ([str(SILO[(bench, method == "silo_bo")])] +
                workload_args(bench, state, extime) + silo_pin_args(bench)), {}
    if method in ("cicada", "ermia"):
        exe = BUILD / "cc" / method / f"{bench}_{method}.exe"
        if bench == "tpcc":
            # GC effectively disabled (every 1e9 us): with the default interval
            # both protocols fail while reclaiming TPC-C records. The values are
            # reported as a reference with this caveat.
            return ([str(exe)] + workload_args(bench, state, extime) +
                    ["--tpcc_pin_order=physical_first", "--batch_th_num=0",
                     "--gc_inter_us=1000000000"]), {}
        return [str(exe)] + workload_args(bench, state, extime), {
            "CCBENCH_PIN_CPU_LIST": IDENTITY}
    raise ValueError(f"unknown method: {method}")


def run_one(argv, extra_env, log):
    """Run one benchmark with mimalloc preloaded. The controller log (stderr,
    redirected by the binary to logs/) is moved next to the run log as
    <log>.trace.log. Returns (tps, abort_rate, trace_path or None)."""
    log.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LD_PRELOAD=str(MIMALLOC), **extra_env)
    with log.open("w") as f:
        subprocess.run(argv, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
    body = log.read_text()
    trace = re.search(r'logs will be written to: "?([^"\n]+)"?', body)
    trace_path = None
    if trace:
        trace_path = log.with_suffix(".trace.log")
        shutil.move(str(ROOT / trace[1]), trace_path)
    tps = float(re.search(r"(?m)^throughput\[tps\]:\s+(\S+)", body)[1])
    abort = float(re.search(r"(?m)^abort_rate:\s+(\S+)", body)[1])
    return tps, abort, trace_path


def thread_samples(path):
    """[(seconds, active threads)] of a trace log."""
    if path is None or not path.exists():
        return []
    return [(float(t), int(n)) for t, n in re.findall(
        r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)", path.read_text())]


def settled_threads(path, skip_s=2.0):
    """Mode and mean of the active-thread samples after skip_s."""
    counts = defaultdict(int)
    for t, n in thread_samples(path):
        if t >= skip_s:
            counts[n] += 1
    if not counts:
        return "", ""
    total = sum(counts.values())
    mode = max(counts, key=counts.get)
    return mode, f"{sum(k * v for k, v in counts.items()) / total:.1f}"


def oracle_curve(bench):
    """state -> {N: mean TPS over runs} from <bench>/oracle/results.csv."""
    acc = defaultdict(lambda: defaultdict(list))
    with (HERE / bench / "oracle" / "results.csv").open() as f:
        for r in csv.DictReader(f):
            acc[r["state"]][int(r["threads"])].append(float(r["tps"]))
    return {s: {n: statistics.mean(v) for n, v in ns.items()} for s, ns in acc.items()}


def oracle(bench):
    """state -> (best N, best TPS, Ns within 98% of the best)."""
    out = {}
    for s, m in oracle_curve(bench).items():
        best = max(m, key=m.get)
        out[s] = (best, m[best], [n for n in sorted(m) if m[n] >= 0.98 * m[best]])
    return out
