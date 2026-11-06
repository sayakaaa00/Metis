#!/usr/bin/env python3
"""Merge Metis models by pooling their ridge-regression statistics.

Each model stores A = lambda*I + sum(x x^T) and b = sum(r x). Pooling k models
gives A = sum(A_i) - (k-1)*lambda*I and b = sum(b_i), which equals fitting one
ridge regression on all observations. Headers (format, version, dimension,
lambda, worker count, physical cores) must match.

usage: merge_models.py OUT IN [IN ...]
"""
import sys
from pathlib import Path


def read(path):
    lines = Path(path).read_text().split("\n")
    head = lines[0].split()
    if head[:2] != ["metis_model", "1"]:
        raise SystemExit(f"not a Metis model: {path}")
    dim = int(head[2])
    A = [float(v) for v in lines[1].split()]
    b = [float(v) for v in lines[2].split()]
    if len(A) != dim * dim or len(b) != dim:
        raise SystemExit(f"truncated model: {path}")
    return head, A, b


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out, inputs = sys.argv[1], sys.argv[2:]
    head0, A, b = read(inputs[0])
    key = head0[:6]
    samples = int(head0[6])
    dim = int(head0[2])
    lam = float(head0[3])
    for path in inputs[1:]:
        head, Ai, bi = read(path)
        if head[:6] != key:
            raise SystemExit(f"incompatible header: {path}: {head[:6]} vs {key}")
        A = [x + y for x, y in zip(A, Ai)]
        b = [x + y for x, y in zip(b, bi)]
        samples += int(head[6])
    for i in range(dim):
        A[i * dim + i] -= (len(inputs) - 1) * lam
    head = key + [str(samples)]
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(" ".join(head) + "\n" + " ".join(repr(v) for v in A) +
                         " \n" + " ".join(repr(v) for v in b) + " \n")
    print(f"{out}: {len(inputs)} models, {samples} samples")


if __name__ == "__main__":
    main()
