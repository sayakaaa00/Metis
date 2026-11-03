#!/usr/bin/env python3
"""Sum independent LinUCB sufficient statistics, leaving one workload out."""

import argparse
import math
from pathlib import Path


def read_model(path: Path):
    tokens = path.read_text().split()
    length = 13 if tokens and tokens[0] in {"metis_test_model_v6", "metis_test_model_v7"} else 12
    header = tokens[:length]
    if len(header) != length or header[0] not in {"metis_test_model_v5", "metis_test_model_v6", "metis_test_model_v7"}:
        raise ValueError(f"Unsupported model: {path}")
    dim, actions = map(int, header[1:3])
    if header[4] != "0" or header[11] != "1" or header[9] != "0":
        raise ValueError(f"Expected a cross-workload, non-empirical model: {path}")
    body = tokens[length:]
    expected = dim * dim + dim + 2 * actions + 1
    if len(body) != expected:
        raise ValueError(f"Expected {expected} parameters in {path}, got {len(body)}")
    cut = dim * dim
    matrix = list(map(float, body[:cut]))
    vector = list(map(float, body[cut:cut + dim]))
    cut += dim
    samples = list(map(int, body[cut:cut + actions]))
    cut += actions
    rewards = list(map(float, body[cut:cut + actions]))
    observations = int(body[-1])
    if not all(math.isfinite(x) for x in matrix + vector + rewards):
        raise ValueError(f"Non-finite parameter in {path}")
    return header, matrix, vector, samples, rewards, observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lambda-value", type=float, default=1.0)
    parser.add_argument("models", type=Path, nargs="+")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"Refusing to overwrite {args.output}")
    parts = [read_model(path) for path in args.models]
    header = parts[0][0]
    if any(part[0] != header for part in parts):
        raise ValueError("Models have incompatible configurations")
    dim, actions = map(int, header[1:3])
    matrix = [sum(part[1][i] for part in parts) for i in range(dim * dim)]
    for i in range(dim):
        matrix[i * dim + i] -= (len(parts) - 1) * args.lambda_value
    vector = [sum(part[2][i] for part in parts) for i in range(dim)]
    samples = [sum(part[3][i] for part in parts) for i in range(actions)]
    rewards = [sum(part[4][i] for part in parts) for i in range(actions)]
    observations = sum(part[5] for part in parts)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as output:
        output.write(" ".join(header) + "\n")
        for row in range(dim):
            output.write(" ".join(format(x, ".17g") for x in
                                  matrix[row * dim:(row + 1) * dim]) + "\n")
        output.write(" ".join(format(x, ".17g") for x in vector) + "\n")
        output.write(" ".join(map(str, samples)) + "\n")
        output.write(" ".join(format(x, ".17g") for x in rewards) + "\n")
        output.write(f"{observations}\n")
    print(f"{args.output}: {observations} training observations from "
          f"{len(parts)} workloads")


if __name__ == "__main__":
    main()
