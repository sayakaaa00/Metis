#!/usr/bin/env python3
from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path


def safe_float(value: str) -> float | None:
    value = value.strip()
    if value == "" or value.upper() == "NA":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    out_root = repo_root / "experiments" / "paper_replication" / "optTAM_scan_results"

    runs_file = out_root / "summary_runs.csv"
    avg_file = out_root / "summary_avg.csv"
    best_file = out_root / "best_by_skew.txt"

    if not runs_file.exists():
        raise FileNotFoundError(f"{runs_file} not found. Run the bash script first.")

    grouped: dict[tuple[str, str], list[tuple[float, float]]] = defaultdict(list)

    with runs_file.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = {"skew", "thread", "run", "throughput_tps", "abort_rate"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"summary_runs.csv is missing columns: {sorted(missing)}")

        for row in reader:
            skew = row["skew"].strip()
            thread = row["thread"].strip()
            throughput = safe_float(row["throughput_tps"])
            abort_rate = safe_float(row["abort_rate"])

            if throughput is None or abort_rate is None:
                continue

            grouped[(skew, thread)].append((throughput, abort_rate))

    avg_rows: list[dict[str, str]] = []
    best_by_skew: dict[str, dict[str, str]] = {}

    for (skew, thread), values in sorted(
        grouped.items(),
        key=lambda x: (float(x[0][0]), int(x[0][1]))
    ):
        throughputs = [v[0] for v in values]
        abort_rates = [v[1] for v in values]

        avg_tps = sum(throughputs) / len(throughputs)
        avg_abort = sum(abort_rates) / len(abort_rates)
        successful_runs = len(values)

        row = {
            "skew": skew,
            "thread": thread,
            "avg_throughput_tps": f"{avg_tps:.6f}",
            "avg_abort_rate": f"{avg_abort:.6f}",
            "successful_runs": str(successful_runs),
        }
        avg_rows.append(row)

        if skew not in best_by_skew or avg_tps > float(best_by_skew[skew]["avg_throughput_tps"]):
            best_by_skew[skew] = row

    with avg_file.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "skew",
                "thread",
                "avg_throughput_tps",
                "avg_abort_rate",
                "successful_runs",
            ],
        )
        writer.writeheader()
        writer.writerows(avg_rows)

    with best_file.open("w", encoding="utf-8") as f:
        f.write("Best combos per skew (by average throughput):\n")
        for skew in sorted(best_by_skew.keys(), key=float):
            row = best_by_skew[skew]
            f.write(
                f"  skew={row['skew']} "
                f"thread={row['thread']} "
                f"avg_throughput={row['avg_throughput_tps']} "
                f"avg_abort_rate={row['avg_abort_rate']} "
                f"successful_runs={row['successful_runs']}\n"
            )

    print(f"Wrote: {avg_file}")
    print(f"Wrote: {best_file}")


if __name__ == "__main__":
    main()