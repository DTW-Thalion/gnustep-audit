#!/usr/bin/env bash
#
# capture_baseline.sh — capture a controlled benchmark baseline
#
# Strategy:
#   1. CPU warmup loop (~3 seconds of busy work) to lift the CPU out of
#      idle-frequency states before any measurement.
#   2. Per-binary warmup run, discarded (primes I-cache, D-cache, branch
#      predictor, TLB).
#   3. N measurement runs per binary (default 7).
#   4. Min-of-N per individual benchmark entry. Minimum is the correct
#      statistic for micro-benchmark timing on uncontrolled Windows
#      machines: noise (interrupts, antivirus scans, background
#      processes, thermal throttling) can only slow the measurement
#      down, never speed it up. The fastest observed run approximates
#      the machine's real capability under current thermal state.
#   5. Emits a JSONL file compatible with compare_results.py.
#
# Usage:
#   ./capture_baseline.sh [output.jsonl] [--runs N]
#
# Defaults:
#   output:  instrumentation/benchmarks/results/current.jsonl
#   runs:    7
#
# Caveats:
#   - This does NOT manipulate the Windows power plan. Users wanting
#     maximum determinism should manually set the "High performance"
#     plan before running and close background applications. The
#     script reports the active scheme at start so any drift is
#     visible in the captured context.
#   - Still subject to day-to-day machine thermal state drift. For
#     retain/revert decisions on marginal changes, prefer a head-to-
#     head measurement (swap binaries, measure both) over comparisons
#     across separate capture sessions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/benchmarks"
OBJ_DIR="$BENCH_DIR/obj"
DEFAULT_OUT="$BENCH_DIR/results/current.jsonl"

OUT="${1:-$DEFAULT_OUT}"
RUNS=7
if [[ "${2:-}" == "--runs" && -n "${3:-}" ]]; then
    RUNS="$3"
fi

if [[ ! -d "$OBJ_DIR" ]]; then
    echo "ERROR: benchmark obj/ directory not found at $OBJ_DIR" >&2
    echo "Run 'make' in $BENCH_DIR first." >&2
    exit 1
fi

bins=()
for b in "$OBJ_DIR"/bench_*.exe; do
    [[ -x "$b" ]] && bins+=("$b")
done
if [[ ${#bins[@]} -eq 0 ]]; then
    echo "ERROR: no bench_*.exe binaries found in $OBJ_DIR" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== capture_baseline.sh ==="
echo "  output:       $OUT"
echo "  runs:         $RUNS (min-of-$RUNS per benchmark)"
echo "  binaries:     ${#bins[@]}"
echo "  power scheme: $(powercfg -getactivescheme 2>/dev/null | head -1 || echo 'unknown')"
echo ""

# CPU warmup: 3 seconds of busy work to lift the CPU from idle states
echo "=== CPU warmup (3s busy loop) ==="
start=$(date +%s)
while (( $(date +%s) - start < 3 )); do
    : $((1 + 1))
    : $((1 + 1))
    : $((1 + 1))
    : $((1 + 1))
done

# Binary-level warmup: one discarded run of each benchmark
echo "=== Binary warmup (1 run per binary, discarded) ==="
for bin in "${bins[@]}"; do
    "$bin" --json 2>/dev/null > /dev/null || true
done

# Measurement runs
echo "=== $RUNS measurement runs ==="
for run in $(seq 1 "$RUNS"); do
    echo "  run $run/$RUNS"
    for bin in "${bins[@]}"; do
        "$bin" --json 2>/dev/null >> "$TMPDIR/all_runs.jsonl" || true
    done
done

# Min-of-N aggregation + JSONL emission
echo "=== Aggregating min-of-$RUNS ==="
python3 - "$TMPDIR/all_runs.jsonl" "$OUT" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
by_name = {}
for line in open(src):
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        o = json.loads(line)
    except json.JSONDecodeError:
        continue
    name = o.get("bench") or o.get("name")
    if not name or name.startswith("_") or "ns_per_op" not in o:
        continue
    key = name
    if key not in by_name or o["ns_per_op"] < by_name[key]["ns_per_op"]:
        by_name[key] = o
with open(dst, "w") as f:
    for name in sorted(by_name):
        o = by_name[name]
        o["bench"] = name
        o.pop("name", None)
        f.write(json.dumps(o) + "\n")
print(f"wrote {len(by_name)} entries to {dst}")
PY

echo ""
echo "=== Done ==="
