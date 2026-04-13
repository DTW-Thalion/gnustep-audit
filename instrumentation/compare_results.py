#!/usr/bin/env python3
"""
Compare two JSONL benchmark result files produced by the GNUstep audit
benchmark harness.

Each line of input is one JSON object of the form:
  {"bench": "<name>", "iterations": N, "ns_per_op": X, "ops_per_sec": Y}

Usage:
  compare_results.py baseline.jsonl current.jsonl

Exit status:
  0 — no real regressions (differences that aren't plausibly measurement noise)
  1 — one or more real regressions

Noise handling
--------------
Sub-nanosecond ns_per_op measurements are dominated by timer resolution and
CPU turbo/cache variance. A flat 5% threshold flags many false positives on
those. We instead combine a relative threshold (5%) with an absolute floor
(0.5 ns) so that, e.g., a 1.3 -> 1.6 ns change (+23% but only 0.3 ns) is
treated as noise.
"""
import json
import sys


REGRESSION_PCT = 5.0      # relative threshold for "slower"
IMPROVEMENT_PCT = 5.0     # relative threshold for "faster"
ABSOLUTE_NS_FLOOR = 0.5   # ignore diffs smaller than this (timer noise)


def load(path):
    results = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = obj.get("bench") or obj.get("name")
            if not name or "ns_per_op" not in obj:
                continue
            results[name] = obj
    return results


def classify(baseline_ns, current_ns):
    delta_ns = current_ns - baseline_ns
    pct = (delta_ns / baseline_ns * 100.0) if baseline_ns > 0 else 0.0
    if abs(delta_ns) < ABSOLUTE_NS_FLOOR:
        return "~noise", pct
    if pct <= -IMPROVEMENT_PCT:
        return "FASTER", pct
    if pct >= REGRESSION_PCT:
        return "SLOWER", pct
    return "~flat", pct


def main(argv):
    if len(argv) != 3:
        print("Usage: compare_results.py baseline.jsonl current.jsonl", file=sys.stderr)
        return 2

    base = load(argv[1])
    curr = load(argv[2])
    names = sorted(set(base) | set(curr))

    print(f"{'Benchmark':<42} {'Baseline ns/op':>16} {'Current ns/op':>16} {'Delta':>10} {'Status':>10}")
    print("-" * 100)

    faster = slower = flat = noise = missing = new = 0
    regressions = []
    improvements = []

    for name in names:
        b = base.get(name)
        c = curr.get(name)
        if b and c:
            bns = b["ns_per_op"]
            cns = c["ns_per_op"]
            status, pct = classify(bns, cns)
            print(f"{name:<42} {bns:>16.2f} {cns:>16.2f} {pct:>+9.1f}% {status:>10}")
            if status == "FASTER":
                faster += 1
                improvements.append((name, bns, cns, pct))
            elif status == "SLOWER":
                slower += 1
                regressions.append((name, bns, cns, pct))
            elif status == "~noise":
                noise += 1
            else:
                flat += 1
        elif b:
            missing += 1
            print(f"{name:<42} {b['ns_per_op']:>16.2f} {'—':>16} {'—':>10} {'MISSING':>10}")
        else:
            new += 1
            print(f"{name:<42} {'—':>16} {c['ns_per_op']:>16.2f} {'—':>10} {'NEW':>10}")

    print("-" * 100)
    print(
        f"Summary: {faster} faster, {flat} flat, {noise} sub-noise, "
        f"{slower} slower | {missing} only-in-baseline, {new} only-in-current"
    )

    if improvements:
        improvements.sort(key=lambda x: x[3])
        print("\nTop improvements:")
        for n, b_, c_, p in improvements[:10]:
            print(f"  {n:<42} {b_:>14.1f} -> {c_:>14.1f} ns  ({p:+.1f}%)")

    if regressions:
        regressions.sort(key=lambda x: -x[3])
        print("\nReal regressions (beyond noise floor):")
        for n, b_, c_, p in regressions:
            print(f"  {n:<42} {b_:>14.1f} -> {c_:>14.1f} ns  ({p:+.1f}%)")
        return 1

    print("\nNo real regressions detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
