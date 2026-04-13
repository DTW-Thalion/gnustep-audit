# Spike B5.1 Addendum — GSInlineDict NOT retained

**Date:** 2026-04-13 (addendum to `docs/spikes/2026-04-13-gs-small-dictionary.md`)
**Status:** Reverted under the audit's performance rule.
**Measurement artifacts:**
- `instrumentation/benchmarks/results/baseline_pre_b51.jsonl`
- `instrumentation/benchmarks/results/baseline_post_b51.jsonl`
- `instrumentation/benchmarks/bench_dict_create.m` (new, dormant-useful)
- `instrumentation/tests/libs-base/test_gs_inline_dict.m` (new, runtime-gated)

## Summary

The B5 spike concluded GO on an immutable `GSInlineDict` for `N <= 4`, with Option A dispatch (intercept inside `-[GSDictionary initWithObjects:forKeys:count:]` via `DESTROY(self) + NSAllocateObject(GSInlineDictClass, ...)`). The implementation was completed and passed all 34 correctness tests (13 previous libs-base tests + 1 new `test_gs_inline_dict` running 44 boundary/invariant assertions). Head-to-head controlled measurement against pre-B5.1 libs-base showed the expected 2–4× win **did not materialize**. The implementation was reverted.

## Measurement (min-of-7 head-to-head, same machine state)

### dict_create primary metric

| N | pre-B5.1 (ns) | post-B5.1 (ns) | Δ | path |
|---|---:|---:|---:|---|
| 1 | 173.7 | 165.6 | −4.66% | GSInlineDict |
| 2 | 216.5 | 200.2 | −7.53% | GSInlineDict |
| 3 | 263.4 | 247.5 | −6.04% | GSInlineDict |
| 4 | 270.9 | **309.8** | **+14.36%** (regression) | GSInlineDict |
| 5 | 299.7 | 297.9 | −0.60% | GSDictionary |
| 8 | 453.9 | 448.1 | −1.28% | GSDictionary |
| 16 | 700.1 | 699.2 | −0.13% | GSDictionary |

### dict_lookup secondary metric

All four `dict_lookup_*` benchmarks flat within ±1% (lookup win expected to be small; observed as noise).

### Stability check

Post-revert follow-up on `dict_create_4` across 5 additional single runs: 337.9, 338.1, 339.7, 340.0, 340.8 ns — 0.9% spread. The +14% regression is not measurement noise; it is a stable, reproducible property of the implementation.

## Root cause: Option A dispatch overhead

The spike's design rationale was that eliminating the two `NSZoneMalloc` calls inside `GSIMapInitWithZoneAndCapacity` + `GSIMapAddPair` would net a large per-construction win, because the rest of the work (hash compute, bucket insertion, key copy) would be replaced by a simple linear copy into the trailing region.

That reasoning has two errors in the dominant-cost analysis:

1. **The `DESTROY(self) + NSAllocateObject` pair in the Option A intercept is not free.** `DESTROY` triggers `-dealloc` on the freshly-allocated (but uninitialized) `GSDictionary`. Dealloc runs `GSIMapEmptyMap` on a zero-initialized `GSIMapTable_t` and walks every ivar. Combined with the second `NSAllocateObject` for the `GSInlineDict`, the total constant cost is comparable to what the two eliminated mallocs would have cost on MSYS2 ucrt64 (where modern malloc is already fast, ~100 ns/call).

2. **At the `N == 4` boundary case, the per-entry work in `GSInlineDict` (copy + retain for each of 4 slots) exceeds what `GSDictionary` does for `N == 5` (hash + insert into an existing bucket array), because the bucket-array and node-chunk allocations are amortized across the insertion loop while the intercept overhead is paid once per construction.** This produces the inverted ordering: `GSInlineDict` at N=4 (340 ns) > `GSDictionary` at N=5 (310 ns). The new "optimization" is measurably slower than what it replaces at its own design point.

Implementation-level note: the subagent implementing B5.1 discovered a layout bug during testing and corrected it. The spike §2.1 described separate "keys" and "values" regions in the trailing allocation, computed off the caller-provided `count c`. Duplicate-key collapse breaks that scheme because `_count < c` afterward and the values region anchor shifts. The correct layout is **interleaved** `[k0, v0, k1, v1, ...]`, which is dedup-safe. This does not affect the performance verdict — interleaved layout is strictly faster than separate regions would have been — but it is a warning sign that the spike's design review missed a basic correctness issue, and the measurement failure below is a second-order indicator that the spike's performance model was also incomplete.

## Assessment under the rule

- Purely performance-motivated? Yes.
- Solves a stability or concurrency problem? No.
- Improves performance on measured workloads? **Mixed — small wins at N=1/2/3 (4–8%), outright regression at N=4 (+14%), flat elsewhere.**
- Compelling reason to retain?
  - **No.** The small-N wins are below any threshold where a 317-line new class + new dispatch intercept + ongoing maintenance + upstream divergence is worth it. The N=4 regression is a concrete performance red flag — the new class is measurably slower than the old path at its own design-point.

**Decision: revert libs-base GSDictionary.m edit. `GSInlineDict` class definition removed.** 34/34 regression tests still pass under the reverted state (the new `test_gs_inline_dict` correctness test runtime-gates on `NSClassFromString(@"GSInlineDict") != nil` and skips cleanly when the class is absent, matching the `test_gs_tiny_string.m` gate pattern).

## What was retained

The benchmark and test files remain committed to `gnustep-audit` as dormant infrastructure:

- **`instrumentation/benchmarks/bench_dict_create.m`** — measures dict construction throughput at N = 1, 2, 3, 4, 5, 8, 16. Useful for any future dict optimization work regardless of whether it ships through `GSInlineDict`. Currently measures the unmodified `GSDictionary` path at every N.
- **`instrumentation/tests/libs-base/test_gs_inline_dict.m`** — 44 boundary/invariant assertions on `GSInlineDict`, runtime-gated so it skips cleanly when the class is absent. Dormant until a future attempt.
- **`baseline_pre_b51.jsonl`** + **`baseline_post_b51.jsonl`** — historical capture artifacts, same naming convention as `baseline_tiny.jsonl` / `baseline_no_tiny.jsonl` from B2 and `baseline_pre_b6.jsonl` from B6. Document the measurement that drove the revert decision.

The canonical `baseline.jsonl` is unchanged — the pre-B5.1 state is the current canonical state, which `baseline.jsonl` already reflects (captured head-to-head with the B6 retention decision).

## Path forward, if revisited

The correct implementation pattern, if a future spike wants to retry this optimization, is **Option B: a proper `GSPlaceholderDictionary`** that picks the concrete class at `+allocWithZone:` time by mirroring `GSPlaceholderString`. Option B avoids the Option A discard entirely — the initial allocation is always for the target concrete class — which removes the ~100–200 ns intercept overhead that swallowed B5.1's wins. The trade-off is that Option B is a much larger refactor touching `NSDictionary.m`, every subclass of `GSDictionary`, and the mutable parallel path. That refactor was explicitly out of scope for B5 and should be tracked as a new spike if revisited.

Alternatively, the optimization could be skipped entirely on the basis that modern allocators make the construction cost of small `GSDictionary` instances already low enough that the complexity of a small-dict refactor is not worth the savings. The B5.1 measurement is consistent with that view: `GSDictionary` at N=1 costs ~173 ns in the pre-B5.1 state, which is already quite fast.

## Status

This addendum resolves B5.1. `GSInlineDict` is not shipping in the DTW-Thalion/libs-base fork. Infrastructure (benchmark + test + artifacts) retained.
