#!/usr/bin/env python3
"""Concatenate probe episodes for a warehouse-blind held-out model."""

import argparse
import math
from pathlib import Path


def read(path: Path):
    tokens = path.read_text().split()
    if len(tokens) < 8 or tokens[0] != "metis_test_observed_v1":
        raise ValueError(f"Invalid observed model: {path}")
    header = tokens[:7]
    actions = int(header[1])
    count = int(tokens[7])
    width = 2 + 2 * actions
    body = tokens[8:]
    if len(body) != count * width:
        raise ValueError(f"Invalid episode count in {path}")
    episodes = [body[i:i + width] for i in range(0, len(body), width)]
    for episode in episodes:
        if float(episode[0]) <= 0 or not all(
            math.isfinite(float(value)) for value in episode
        ):
            raise ValueError(f"Invalid probe or reward in {path}")
    return header, episodes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("models", type=Path, nargs="+")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"Refusing to overwrite {args.output}")
    parts = [read(path) for path in args.models]
    if any(header != parts[0][0] for header, _ in parts):
        raise ValueError("Incompatible observed models")
    episodes = [episode for _, part_episodes in parts for episode in part_episodes]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as output:
        output.write(" ".join(parts[0][0] + [str(len(episodes))]) + "\n")
        for episode in episodes:
            output.write(" ".join(episode) + "\n")
    print(f"{args.output}: {len(episodes)} probe episodes")


if __name__ == "__main__":
    main()
