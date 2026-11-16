#!/usr/bin/env python3
"""Time breakdown of Silo worker threads vs. YCSB skew (96 worker threads, no
backoff, no throttling): time on committed and aborted transactions and time
spent waiting on locked records, from the instrumented binary
silo/ycsb_silo_breakdown (METIS_BREAKDOWN). The plain binary
silo/ycsb_silo_nobackoff is run at a few skews to check the overhead.

  breakdown.py [--skews ...] [--plain-skews 0,0.9] [--runs 2] [--extime 10]
  -> $METIS_OUT/ycsb/breakdown/results.csv, logs/
"""
import argparse
import re

import common as C

HEADER = ["binary", "skew", "run", "tps", "abort_rate", "committed_cycles", "aborted_cycles",
          "wait_committed_cycles", "wait_aborted_cycles", "n_committed", "n_aborted", "span_cycles"]
PAT = re.compile(r"\[BREAKDOWN\] committed_cycles=(\d+) aborted_cycles=(\d+) wait_committed_cycles=(\d+) "
                 r"wait_aborted_cycles=(\d+) n_committed=(\d+) n_aborted=(\d+) span_cycles=(\d+)")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--runs", type=int, default=2)
    p.add_argument("--extime", type=int, default=10)
    p.add_argument("--skews", default="0,0.5,0.7,0.8,0.9,0.95,0.99,0.999")
    p.add_argument("--plain-skews", default="0,0.9")
    a = p.parse_args()
    d = C.OUT / "ycsb" / "breakdown"
    res = d / "results.csv"
    jobs = [("breakdown", s) for s in a.skews.split(",")] + [("plain", s) for s in a.plain_skews.split(",")]
    for run in range(1, a.runs + 1):
        for kind, s in (jobs if run % 2 else list(reversed(jobs))):
            if (kind, s, str(run)) in C.done_keys(res, ["binary", "skew", "run"]):
                continue
            argv, env = C.command("ycsb", "silo_nobo", s, a.extime)
            if kind == "breakdown":
                argv[0] = str(C.BREAKDOWN)
            if run == 1 and s == jobs[0][1]:
                C.write_config(d, a, argv)
            log = d / "logs" / f"{kind}_skew{s}_run{run}.log"
            tps, abort, _ = C.run_one(argv, env, log)
            m = PAT.search(log.read_text())
            C.append(res, HEADER, [kind, s, run, f"{tps:.0f}", abort] + (list(m.groups()) if m else [""] * 7))
            print(f"breakdown {kind} skew={s} run={run} tps={tps:,.0f} abort={abort}", flush=True)


if __name__ == "__main__":
    main()
