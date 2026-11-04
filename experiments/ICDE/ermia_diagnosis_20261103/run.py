#!/usr/bin/env python3
"""Why is ERMIA so slow here? Compare ERMIA before/after the reader-bitmap fix
with Silo (no backoff) at several worker counts.

The original ERMIA kept each version's readers in one 64-bit word and set bits
with `1 << thid` (a 32-bit int shift), so with more than 32 workers different
workers aliased the same bit. The fix widens the bitmap to two 64-bit words.

Workers are pinned in physical-first order (CPU 0..95 on this host). All
workers run (no thread-activity control). 10 s x 2 runs; run 2 reverses order.
"""
import csv
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
B = ROOT / "build_release"
MIMALLOC = ROOT / "build_release/mimalloc_override/libmimalloc.so"
IDENTITY = ",".join(str(i) for i in range(96))
EXTIME = 10

YCSB = {"ermia_orig": B / "cc/ermia/ycsb_ermia.exe.orig_20261103",
        "ermia_fixed": B / "cc/ermia/ycsb_ermia.exe",
        "silo": B / "silo/silo_without_backoff"}
TPCC = {"ermia_orig": B / "cc/ermia/tpcc_ermia.exe.orig_20261103",
        "ermia_fixed": B / "cc/ermia/tpcc_ermia.exe",
        "silo": B / "silo/tpcc_silo_without_backoff"}


def ycsb_cmd(method, skew, n):
    c = [str(YCSB[method]), f"--thread_num={n}", f"--extime={EXTIME}",
         "--clocks_per_us=2900", "--ycsb_tuple_num=10000", "--ycsb_max_ope=10",
         "--ycsb_rratio=50", f"--ycsb_zipf_skew={skew}"]
    if method == "silo":
        c += ["--pin_threads=true", "--ycsb_pin_order=physical_first"]
    return c


def tpcc_cmd(method, w, n):
    c = [str(TPCC[method]), f"--thread_num={n}", "--tpcc_num_wh=96",
         "--tpcc_num_items=100000", f"--tpcc_active_warehouse_count={w}",
         "--tpcc_home_warehouse_assignment=random_per_transaction",
         "--tpcc_perc_payment=43", "--tpcc_perc_order_status=4",
         "--tpcc_perc_delivery=4", "--tpcc_perc_stock_level=4",
         "--tpcc_retry_same_type=true", "--tpcc_log_retry_conflicts=false",
         f"--extime={EXTIME}", "--clocks_per_us=2900"]
    if method == "silo":
        c += ["--tpcc_pin_workers=true", "--tpcc_pin_order=physical_first",
              "--metis_test_enable=true", f"--metis_test_fixed_threads={n}",
              "--metis_test_learn=false", "--metis_test_idle_sleep_us=50",
              "--tam_update_period_us=200000"]
    else:
        c += ["--tpcc_pin_order=physical_first", "--batch_th_num=0",
              "--gc_inter_us=1000000000", "--gc_defer_record_reclamation=false"]
    return c


def main():
    conds = []
    for skew in ("0", "0.7", "0.9"):
        for n in (8, 32, 96):
            for m in YCSB:
                conds.append(("ycsb", f"skew{skew}", n, m, ycsb_cmd(m, skew, n)))
    for w in (1, 16, 96):
        for n in (32, 96):
            for m in TPCC:
                conds.append(("tpcc", f"W{w}", n, m, tpcc_cmd(m, w, n)))
    out = HERE / "results.csv"
    (HERE / "logs").mkdir(exist_ok=True)
    done = set()
    if out.exists():
        with out.open() as f:
            done = {(r["bench"], r["state"], r["threads"], r["method"], r["run"])
                    for r in csv.DictReader(f)}
    else:
        out.write_text("bench,state,threads,method,run,tps,abort_rate\n")
    for run in (1, 2):
        for bench, state, n, m, cmd in (conds if run == 1 else list(reversed(conds))):
            key = (bench, state, str(n), m, str(run))
            if key in done:
                continue
            log = HERE / "logs" / f"{bench}_{state}_n{n}_{m}_run{run}.log"
            env = dict(os.environ, LD_PRELOAD=str(MIMALLOC), CCBENCH_PIN_CPU_LIST=IDENTITY)
            with log.open("w") as f:
                rc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=f,
                                    stderr=subprocess.STDOUT).returncode
            body = log.read_text()
            m1 = re.search(r"(?m)^throughput\[tps\]:\s+(\S+)", body)
            m2 = re.search(r"(?m)^abort_rate:\s+(\S+)", body)
            tps = m1[1] if (rc == 0 and m1) else ""
            ab = m2[1] if (rc == 0 and m2) else f"failed_rc{rc}"
            with out.open("a") as f:
                f.write(f"{bench},{state},{n},{m},{run},{tps},{ab}\n")
            print(bench, state, n, m, run, tps, ab, flush=True)


if __name__ == "__main__":
    main()
