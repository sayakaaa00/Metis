"""Shared settings of the Metis experiments: binaries, workload states, the
command line of every method, running one benchmark, and writing results.

Every experiment script writes to $METIS_OUT (default: results/ at the
repository root) in the same layout as the recorded results in data/
(Metis-data), so the figure scripts can plot either:
  METIS_DATA=$METIS_OUT experiments/metis/figures/make_figures.sh

Common conditions (paper): 96 worker threads, physical-first CPU order,
mimalloc preloaded, clocks_per_us=2900 (TSC of the evaluation machine).
Control period: TPC-C 200 ms, YCSB 10 ms. Parked workers sleep 50 us per check.
"""
import csv
import hashlib
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("METIS_OUT", ROOT / "results"))
BUILD = Path(os.environ.get("BUILD", ROOT / "build_release"))
MIMALLOC = BUILD / "mimalloc_override/libmimalloc.so"
SILO = {("tpcc", False): BUILD / "silo/tpcc_silo_nobackoff",
        ("tpcc", True): BUILD / "silo/tpcc_silo_backoff",
        ("ycsb", False): BUILD / "silo/ycsb_silo_nobackoff",
        ("ycsb", True): BUILD / "silo/ycsb_silo_backoff"}
BREAKDOWN = BUILD / "silo/ycsb_silo_breakdown"

# Contention levels: TPC-C number of accessed warehouses W, YCSB Zipf skew.
STATES = {"tpcc": ["1", "2", "3", "4", "8", "16", "32", "96"],
          "ycsb": ["0", "0.5", "0.7", "0.8", "0.85", "0.9", "0.95", "0.99", "0.999"]}
EXTIME = {"tpcc": 30, "ycsb": 10}
PERIOD_US = {"tpcc": 200000, "ycsb": 10000}
WORKERS = 96
# Hill climbing on the active thread count: best step of a short sweep
# (TPC-C 8 of {2, 4, 8}; YCSB 4 of {1, 2, 4, 8}).
ADATAM_STEP = {"tpcc": 8, "ycsb": 4}
# Silo-BO: Silo with the adaptive backoff of Cicada (randomized wait in
# [0, duration], hill climbing on the duration). Update period (us) and step
# (us) chosen by backoff.py tune (paper: data/<bench>/backoff_adaptive_tuning).
SILO_BO = {"tpcc": (1000, 0.5), "ycsb": (20000, 2.0)}
# Cicada/ERMIA YCSB have no pin-order option; pin worker i to CPU i instead
# (CCBENCH_PIN_CPU_LIST). On the evaluation machine (2 x 24 cores, SMT 2,
# CPUs 0-47 = one thread per core) this equals the physical-first order.
IDENTITY = ",".join(str(i) for i in range(min(WORKERS, os.cpu_count() or 1)))

# Trained models used in the paper (experiments/metis/models, converted from
# data/<bench>/models). min8: candidates 8..96, min6: candidates 6..96; YCSB
# min6 is trained on all nine skews. A model set trained by train.py is used
# with --models <dir>.
MODELS = HERE / "models"
MIN_COUNT = {"min8": 8, "min6": 6}


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
    """Arguments shared by every run that parks workers (Metis, hill climbing, fixed N)."""
    return ["--tam_min_threads=1", f"--tam_max_threads={WORKERS}",
            f"--tam_update_period_us={PERIOD_US[bench]}", "--tam_idle_sleep_us=50",
            "--tam_log_active_threads=true", "--tam_log_period_us=100000"]


def model_path(bench, model_set, name, models_dir=None):
    """Model file <name>.txt of a model set (paper models unless models_dir is given)."""
    return Path(models_dir or MODELS / bench / model_set) / f"{name}.txt"


def metis_command(bench, state, extime, model, min_count, learn=False, seed=1):
    return ([str(SILO[(bench, False)])] + workload_args(bench, state, extime) +
            silo_pin_args(bench) + tam_args(bench) +
            ["--metis_enable=true", f"--metis_learn={str(learn).lower()}",
             f"--metis_model_path={model}", f"--metis_seed={seed}",
             f"--metis_min_count={min_count}"])


def command(bench, method, state, extime, model=None, min_count=6):
    """Return (argv, extra_env) of one method on one contention level.

    metis:          Metis with the given model (fixed loads: leave-one-out model).
    adatam:         hill climbing on the active thread count from 96, tuned step.
    silo_nobo:      Silo, all 96 worker threads, no backoff.
    silo_cbo_tuned: Silo-BO (Silo with the tuned adaptive backoff of Cicada).
    silo_bo:        Silo with backoff, flags given by the caller (backoff.py).
    cicada:         Cicada with its adaptive backoff (paper defaults: 5 ms, 0.5 us).
    ermia:          ERMIA with CCBench's adaptive backoff, doubled per consecutive abort.
    fixed_<N>:      Silo without backoff, only the first N workers active (oracle).
    """
    silo = [str(SILO[(bench, False)])] + workload_args(bench, state, extime) + silo_pin_args(bench)
    if method == "metis":
        return metis_command(bench, state, extime, model, min_count), {}
    if method == "adatam":
        return silo + tam_args(bench) + ["--ada_tam_enable=true", f"--ada_tam_step={ADATAM_STEP[bench]}"], {}
    if method.startswith("fixed_"):
        return silo + ["--tam_idle_sleep_us=50", f"--tam_fixed_threads={method[6:]}"], {}
    if method == "silo_nobo":
        return silo, {}
    if method in ("silo_bo", "silo_cbo_tuned"):
        argv = [str(SILO[(bench, True)])] + workload_args(bench, state, extime) + silo_pin_args(bench)
        if method == "silo_cbo_tuned":
            period, step = SILO_BO[bench]
            argv += ["--backoff_randomized=true", f"--backoff_update_period_us={period}",
                     f"--backoff_step_us={step}"]
        return argv, {}
    if method in ("cicada", "ermia"):
        exe = BUILD / "cc" / method / f"{bench}_{method}.exe"
        extra = (["--backoff_randomized=true"] if method == "cicada"
                 else ["--backoff_adaptive_exponential=true"])
        if bench == "tpcc":
            # GC effectively disabled (every 1e9 us): with the default interval
            # both protocols fail while reclaiming TPC-C records.
            return ([str(exe)] + workload_args(bench, state, extime) + extra +
                    ["--tpcc_pin_order=physical_first", "--batch_th_num=0",
                     "--gc_inter_us=1000000000"]), {}
        return [str(exe)] + workload_args(bench, state, extime) + extra, {
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


def done_keys(path, keys):
    """Set of key tuples already recorded in a results CSV (for resuming)."""
    if not path.exists():
        return set()
    with path.open() as f:
        return {tuple(r[k] for k in keys) for r in csv.DictReader(f)}


def append(path, header, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        if new:
            w.writerow(header)
        w.writerow(row)


def write_config(out_dir, args, argv):
    """Append the script arguments and the binary (with its SHA-256) to config.txt."""
    out_dir.mkdir(parents=True, exist_ok=True)
    exe = Path(argv[0])
    with (out_dir / "config.txt").open("a") as f:
        f.write(f"{Path(sys.argv[0]).name} {vars(args)}\n")
        f.write(f"binary={exe} sha256={hashlib.sha256(exe.read_bytes()).hexdigest()}\n")


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
