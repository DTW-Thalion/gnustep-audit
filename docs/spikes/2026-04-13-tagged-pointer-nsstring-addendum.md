# Spike B2 Addendum — Profile-Off vs Profile-On GSTinyString Measurement

**Date:** 2026-04-13 (addendum to `docs/spikes/2026-04-13-tagged-pointer-nsstring.md`)
**Status:** Item 3 of the B2 spike's residual scope, completed.
**Measurement artifacts:**
- `instrumentation/benchmarks/results/baseline_tiny.jsonl`
- `instrumentation/benchmarks/results/baseline_no_tiny.jsonl`

## Motivation

The B2 spike concluded GO on an audit-and-measure scope, with three follow-up items:
1. Targeted boundary unit tests (completed in commit `fbf39ba`)
2. Benchmark relabeling to expose tiny-string coverage (completed in `fbf39ba`)
3. **Profile-off vs profile-on libobjc2 measurement** (this addendum)

The user subsequently asked me to apply a general principle to performance changes:

> A purely performance-motivated change that does not solve a stability / concurrency issue AND does not actually improve performance → revert, unless there's a compelling reason to retain.

Applied to GSTinyString, this question becomes: **does the tagged-pointer small-string feature, taken as a whole, deliver net performance improvement on our measured workloads?** If not, the rule recommends revert.

## Measurement setup

**Tiny-on configuration:** current installed libs-base (`gnustep-base-1_31.dll`
from commit `e83889f97` on DTW-Thalion/libs-base master, which includes the B7
NSZone shim). `+[GSTinyString load]` calls `objc_registerSmallObjectClass_np`
and `useTinyStrings` is set to the result (YES on this libobjc2 build with
`OBJC_SMALL_OBJECT_SHIFT == 3`).

**Tiny-off configuration:** same source tree with a temporary one-file edit
to `Source/GSString.m:1122` — the registration call is retained (so
`+[GSTinyString alloc]` still returns a valid tagged pointer if any code
path calls it) but `useTinyStrings` is forced to `NO`, which short-circuits
every factory path that would otherwise construct a tiny string. The result:
short ASCII strings that previously became tagged pointers are now heap-backed
`GSCInlineString` / `GSCString` instances. All 33 runnable regression tests
pass under this configuration, confirming the change is functionally
equivalent for correctness.

**Methodology:** 3 full benchmark-suite runs per configuration, with a
discarded warmup pass, median-of-3 per benchmark. libobjc2 (PF-7, commit
`834c978`) was unchanged across both configurations; only libs-base was
swapped. The GSString.m edit was reverted immediately after the tiny-off
capture and libs-base was rebuilt and reinstalled, restoring the system to
tiny-on for all subsequent work.

## Results

**Headline: 1 tiny-win, 38 flat/noise, 4 tiny-losses** across 43 benchmarks.

### Tiny-losses (tiny-on slower than tiny-off)

| Benchmark | tiny-off (ns) | tiny-on (ns) | Δ | Notes |
|---|---:|---:|---:|---|
| `hash_short_5` | 2.0 | 7.7 | **+285%** | Heap caches hash in ivar; tagged recomputes every call |
| `hash_tiny_5` | 2.0 | 7.7 | **+285%** | Same observation, paired benchmark |
| `hash_equality_short` | 3.8 | 15.4 | **+305%** | Two `-hash` calls per iteration, double the tiny penalty |
| `runloop_100_timers` | 19,970.7 | 21,775.0 | +9.0% | Within the known 38.5% run-to-run spread for this benchmark — probably noise |

### Tiny-wins (tiny-on faster than tiny-off)

| Benchmark | tiny-off (ns) | tiny-on (ns) | Δ | Notes |
|---|---:|---:|---:|---|
| `autorelease_10_obj` | 467.0 | 439.1 | **−6.0%** | −28 ns across 10 objects; the only measurable win |

### Aggregate

- Total ns saved by tiny-on (sum across tiny-wins): **28 ns**
- Total ns added by tiny-on (sum across tiny-losses): **1827 ns** (of which 1804 is the noisy `runloop_100_timers`, leaving 23 ns of "real" loss on hash)
- Even discounting `runloop_100_timers` as noise, the hash losses are consistent and reproducible across multiple runs with zero spread

## Interpretation

The current benchmark suite shows GSTinyString is a **net loss on hash-heavy workloads and roughly neutral elsewhere.** The mechanism for the hash loss is well understood: `GSString -hash` (at `libs-base/Source/GSString.m:3530-3600` ASCII branch) caches its result in a per-instance ivar after first computation, so repeat calls are a ~2 ns ivar read. `GSTinyString -hash` (at `:1001-1033`) has no backing memory for a cache and must recompute `GSPrivateHash` from the packed pointer bits on every call, costing ~7.7 ns. For workloads that hash the same string many times (literal `NSDictionary` keys during app startup, repeated property lookups with the same KVC key, etc.) this is a net 3.85× slowdown on the per-call hash cost.

**However, the benchmark suite is incomplete for evaluating GSTinyString.** The features's primary intended wins are:

1. **Eliminating heap allocation for short-string construction.** Every `@"literal"` or `+[NSString stringWithCString:encoding:]` with a short ASCII input skips `malloc` for the NSString instance and the character buffer. The suite has no benchmark that measures short-string construction in a tight loop.
2. **Reducing allocator pressure / fragmentation** on workloads that churn many short strings. The suite has no allocator-pressure metric.
3. **Identity-based `-isEqual:`** for tagged pointers holding the same content (same bits → same pointer → trivial compare). The suite's `hash_equality_short` exercises the hash-comparison variant, not pointer-identity `isEqual:`.
4. **No retain/release overhead** for transient short strings inside `@autoreleasepool`. Partially measured by `autorelease_10_obj` (the one tiny-win) but not isolated.

The `autorelease_10_obj` tiny-win is consistent with (4): 10 autoreleased short strings in a pool cost 28 ns less with tinies because 10 retain/release ops become 10 no-ops. Scaled to a typical application this would be a real win, but the benchmarks at `autorelease_1_obj`, `autorelease_100_obj`, `autorelease_1000_obj` don't show the same pattern (they're using NSNumber autoreleases, not NSString), so the win is specific to the one benchmark that happens to exercise short strings.

## Assessment under the user's rule

Strict application of the rule to the currently-measured data says **revert GSTinyString**:

- It is a purely performance-motivated feature (no stability or concurrency justification).
- It does not solve a stability or concurrency problem.
- It does not improve performance on the measured workloads — 4 losses vs 1 win, with the losses being consistent and well-understood.

But the compelling reason to **NOT** revert is that the measurement is incomplete:

- The benchmark suite does not cover the feature's primary intended use cases (short-string construction throughput, allocator pressure, pointer-identity equality).
- Reverting a feature that ships in upstream `gnustep/libs-base` creates an unbounded divergence that the fork must maintain.
- The one measured win (`autorelease_10_obj`) confirms the retain/release no-op path IS delivering value on at least one workload.
- `GSTinyString` hash agreement is locked by the B2 correctness tests, so a future hash optimization (e.g., pointer-identity cache in a side table, or changing GSString's hash algorithm to be tag-compatible) would be safe to attempt.

## Recommendation

**Do NOT revert GSTinyString at this time.** Instead:

1. **Extend the benchmark suite to cover the primary tiny-string use cases.** Specifically add:
   - `bench_string_alloc_short`: tight loop of `+[NSString stringWithCString:encoding:]` on a short ASCII literal, measuring ns/op and implicitly measuring allocator pressure.
   - `bench_string_isEqual_short_identity`: `isEqualToString:` between two tagged pointers derived from the same literal (expected to short-circuit via pointer identity).
   - `bench_string_isEqual_short_different`: `isEqualToString:` between two tagged pointers of different content (forces unpack-and-compare).
   - `bench_string_retain_release_short`: tight retain/release loop on a short string (expected tiny-win from no-op retain/release).
2. **Re-run the profile-off vs profile-on comparison** on the extended suite. The decision is deferred until this data exists.
3. **File a separate spike** on `GSTinyString -hash` optimization, targeting either (a) a GSPrivateHash variant that operates directly on the packed-ASCII payload without the unichar widening step, or (b) a global per-thread pointer-identity hash cache for tagged strings. Target: close the 3.85× gap on the already-measured hash benchmarks without breaking the hash-agreement invariant with heap strings.
4. **Keep the two baseline artifacts** (`baseline_tiny.jsonl`, `baseline_no_tiny.jsonl`) committed in `instrumentation/benchmarks/results/` so the comparison can be rerun at any future point to detect regressions or validate hash optimization work.

## Status

This addendum resolves B2 spike item 3. Sprint 4 tiny-string scope is complete pending the suite extension recommended above, which should be tracked as a new task rather than reopening B2.
