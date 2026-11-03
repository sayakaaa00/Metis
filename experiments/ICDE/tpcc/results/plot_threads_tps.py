#!/usr/bin/env python3
"""Plot transaction throughput (TPS) against total thread count from a CSV."""

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path


def find_column(fieldnames: list[str], requested: str) -> str:
    """Find a CSV column without depending on capitalization or whitespace."""
    normalized = {name.strip().casefold(): name for name in fieldnames}
    key = requested.strip().casefold()
    if key not in normalized:
        available = ", ".join(fieldnames)
        raise ValueError(f"CSV has no '{requested}' column. Available columns: {available}")
    return normalized[key]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a total_threads vs TPS plot from one or more results CSVs."
    )
    parser.add_argument("csv", type=Path, nargs="+", help="One or more input results CSVs")
    parser.add_argument(
        "-o", "--output", type=Path,
        help="Output image path (default: next to one input, or common parent for multiple inputs)",
    )
    parser.add_argument(
        "--threads-column", default="total_threads",
        help="Name of the thread-count column (default: total_threads)",
    )
    parser.add_argument(
        "--tps-column", default="TPS",
        help="Name of the throughput column (default: TPS)",
    )
    parser.add_argument(
        "--label-column",
        help=(
            "Column used to draw separate series (defaults to active_warehouses "
            "when present)"
        ),
    )
    args = parser.parse_args()

    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit(
            "matplotlib is required. On Debian/Ubuntu, install it in a virtual "
            "environment to avoid the externally-managed system Python:\n"
            "  python3 -m venv .venv\n"
            "  .venv/bin/python -m pip install matplotlib\n"
            "  .venv/bin/python "
            f"{Path(__file__).as_posix()} <results.csv> [<results2.csv> ...]"
        ) from exc

    # Keep input files as separate datasets and split each by active_warehouses
    # (or the requested label column) when that column is available.
    series: dict[tuple[str, str], dict[float, list[float]]] = {}
    series_labels: dict[tuple[str, str], str] = {}
    legend_title = "Input"
    for csv_path in args.csv:
        with csv_path.open(newline="", encoding="utf-8-sig") as csv_file:
            reader = csv.DictReader(csv_file)
            if not reader.fieldnames:
                raise SystemExit(f"Input CSV is empty or has no header: {csv_path}")
            threads_column = find_column(reader.fieldnames, args.threads_column)
            tps_column = find_column(reader.fieldnames, args.tps_column)
            if args.label_column:
                label_column = find_column(reader.fieldnames, args.label_column)
            else:
                try:
                    label_column = find_column(reader.fieldnames, "active_warehouses")
                except ValueError:
                    label_column = None

            file_series: dict[str, dict[float, list[float]]] = {}
            for row_number, row in enumerate(reader, start=2):
                try:
                    threads = float(row[threads_column])
                    tps = float(row[tps_column])
                except (TypeError, ValueError):
                    raise SystemExit(
                        f"Invalid numeric value in {csv_path}:{row_number} "
                        f"({threads_column}={row.get(threads_column)!r}, "
                        f"{tps_column}={row.get(tps_column)!r})"
                    )
                group = str(row[label_column]).strip() if label_column else ""
                file_series.setdefault(group or "(empty)", {}).setdefault(threads, []).append(tps)

            if not file_series:
                raise SystemExit(f"No data rows found in {csv_path}")

            for group, points in file_series.items():
                key = (str(csv_path), group)
                series[key] = points
                if label_column:
                    legend_title = label_column
                    series_labels[key] = group
                else:
                    series_labels[key] = csv_path.stem if len(args.csv) > 1 else "TPS"

    fig, ax = plt.subplots(figsize=(8, 5))
    thread_ticks = sorted(
        {threads for points in series.values() for threads in points}
    )
    for key, points_by_threads in series.items():
        x_values = sorted(points_by_threads)
        y_values = [
            sum(points_by_threads[threads]) / len(points_by_threads[threads])
            for threads in x_values
        ]
        ax.plot(x_values, y_values, marker="o", label=series_labels[key])

    ax.set_xticks(thread_ticks)
    ax.set_xticklabels(
        [str(int(value)) if value.is_integer() else f"{value:g}" for value in thread_ticks]
    )
    ax.set_xlabel("Threads number")
    ax.set_ylabel("TPS")
    ax.grid(True, linestyle="--", alpha=0.4)
    if len(series) > 1 or len(args.csv) > 1:
        ax.legend(title=legend_title)
    fig.tight_layout()

    if args.output:
        output = args.output
    elif len(args.csv) == 1:
        output = args.csv[0].with_name(f"{args.csv[0].stem}_threads_tps.png")
    else:
        common_parent = Path(os.path.commonpath([str(path.resolve().parent) for path in args.csv]))
        output = common_parent / "threads_tps_comparison.png"
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=200)
    print(f"Saved plot to {output}")


if __name__ == "__main__":
    main()
