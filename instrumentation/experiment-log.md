# Experiment Log

Chronological record of every performance/architecture experiment attempted during the GNUstep audit, including those that were reverted. Primary docs (README, AUDIT-SUMMARY, phase findings) describe only the changes that **remain** in the trees relative to upstream GNUstep. This file is the audit trail for what was tried and abandoned so nobody has to re-derive it.

**Rule:** if a change was reverted, it lives here, not in the primary docs. If you are re-opening a question that looks like one of these experiments, read the relevant entry first.

---

## Index

| ID | Experiment | Outcome | Scope |
|---|---|---|---|
| B1 | Per-class method cache version counter | **REVERTED** | libobjc2 + libs-base |
| B5.1 | GSInlineDict small-dictionary optimization | **REVERTED** | libs-base |
| B6 | Autorelease pool page recycling | **RETAINED** | libobjc2 |
| B7 | NSZone compatibility shim | **RETAINED** | libs-base |
| GSTinyString | Tagged-pointer small-string factory | **DISABLED** | libs-base |
| PF-6 | Weak reference lock 64-way striping | **RETAINED** (claim qualified) | libobjc2 |
| PF-7 | `__atomic_load_n` over `__sync_fetch_and_add(x,0)` | **RETAINED as cleanup** (not a perf win) | libobjc2 |
| RB-2 | NULL selector guard on dispatch hot path | **REVERTED** | libobjc2 |
| TS-3 | LockGuards on selector introspection reads | **REVERTED** (other TS-3 parts retained) | libobjc2 |
| TS-14 | Bounded `cleanupPools` loop | **REVERTED** (recursive form restored) | libobjc2 |
| RB-7 | `protocol_copyPropertyList2` early-return outCount | **FIX-THE-FIX retained** | libobjc2 |

---

## B1 — Per-class method cache version counter

**Motivation.** `bench_kvc_cache_storm` showed a 23× slowdown in a microbenchmark that mutated methods on one class while another thread did KVC lookups on an unrelated class. Root cause on paper: libobjc2's `objc_method_cache_version` is a single process-wide monotonic counter, so *any* method replacement invalidates *every* KVC slot cache.

**Attempt A — tail-extend `struct objc_class`.**
Added a `uint32_t cache_version` field at the tail of `struct objc_class`. Result: `STATUS_STACK_BUFFER_OVERRUN` in 60/104 libobjc2 tests. Root cause: clang emits class structures with a hardcoded layout at compile time, so the runtime cannot extend the struct without ABI coordination with every consumer. Abandoned.

**Attempt B — side-band storage in `struct reference_list` via `cls->extra_data`.**
Put the per-class counter in runtime-owned side-band storage. Built cleanly, passed 34/34 regression tests, `bench_kvc_cache_storm` showed the expected 23× improvement. Committed as libobjc2 `0cc8962` + libs-base `c12ac2391`.

**Reviewer rejection.** A libobjc2 maintainer reviewed the change and stated: *"PF-4 was an intentional design choice. Method replacements are infrequent. The proposed change would make things worse."* The microbenchmark drives counter increments 10 000× per iteration, which does not happen in production — real applications perform method replacements on the order of hours apart. The per-class counter adds a pointer chase on every KVC lookup in exchange for eliminating a refresh cost that is virtually never paid.

**Action.** Full revert:
- libobjc2 `a361c1a` reverts `0cc8962`
- libs-base `2c5eb64fa` reverts `c12ac2391`

**Retained infrastructure.** `bench_kvc_cache_storm.m` and `baseline_pre_b1.jsonl` remain in `instrumentation/` so that a future engineer with a real workload demonstrating frequent counter motion can revisit the question with evidence instead of a microbenchmark.

**Lesson.** A microbenchmark that makes a theoretically-slow path fast does not justify a change if the path is never hit in practice. Domain-expert rejection beats synthetic wins.

---

## B5.1 — GSInlineDict small-dictionary optimization

**Motivation.** Small `NSDictionary` instances (N ≤ 8) are common in Foundation workloads and the general-purpose `GSDictionary` backing incurs hash-table overhead.

**Outcome.** Measured `bench_small_dict` head-to-head: GSInlineDict showed a **+14% regression** at N=4 relative to the baseline GSDictionary path, and break-even elsewhere. The promised 2-4× win did not materialize.

**Action.** Reverted in libs-base commit `0c630fb` (see `git log --grep=B5.1`).

**Lesson.** Copy a working micro-pattern from another runtime and measure before committing. The overhead of dispatching through two code paths (small vs general) can exceed the savings for sizes where the general path is already fast.

---

## B6 — Autorelease pool page recycling — RETAINED

**Motivation.** `emptyPool` frees and re-mallocs pool pages on every autorelease pool drain. Pages are fixed-size and a thread's working set typically fits in a few pages.

**Change.** Thread-local free list of pool pages inside `struct arc_tls`. `emptyPool` pushes drained pages onto the free list; `newPoolPage` pops from the free list before calling `malloc`. `drain_pool_free_list(tls)` is called from `cleanupPools` before `free(tls)` so thread exit does not leak.

**Outcome.** `bench_autorelease` showed measurable improvement on workloads with repeated pool churn. No regressions.

**Action.** Retained in libobjc2 commit `2a38eac`.

---

## B7 — NSZone compatibility shim — RETAINED

Stub `NSZone` accessors that mirror Apple Foundation's post-zone-removal behavior (`NSDefaultMallocZone()` returns a singleton, `NSZoneMalloc` routes to `malloc`). Retained as source compatibility for third-party code still referencing `NSZone*`. No perf impact.

---

## GSTinyString — DISABLED

**Motivation.** Observed that libs-base already contained an inert `GSTinyString` implementation (8 × 7-bit ASCII + 5-bit length + 3-bit tag in 64 bits). Enabling the factory path for qualifying strings should eliminate the allocation for short ASCII strings.

**Outcome.** Head-to-head on `bench_string_small` showed the factory path was slower than the regular `GSCString` path once test coverage was complete — the branch cost on every string construction outweighed the allocation savings for the narrow qualifying window.

**Action.** Factory disabled (the class remains in the tree as dormant code). See `docs/spikes/2026-04-13-tagged-pointer-nsstring-addendum.md` for the measurement data; that document is historical and should not be taken as a live recommendation.

---

## PF-6 — Weak reference lock 64-way striping — RETAINED, claim qualified

**Change.** Replaced the single global weak-reference lock with a 64-way striped lock keyed on object address.

**Reviewer comment.** *"Yes that refactoring would probably be good to do, though note that we don't hit the weak lock in most cases, only if an object is marked as having weak refs. Have you measured slowdown from this on anything that isn't a contrived microbenchmark? The quoted slowdown looks incredibly unlikely unless you have a microbenchmark doing nothing but hitting weak references from multiple threads."*

**Status.** The refactoring is correct and free of downside. The original "5-8× concurrent throughput" claim came from a microbenchmark that pinned multiple threads on the weak-ref path. For real workloads the weak lock is only on the critical path for objects that actually carry weak references — a minority. The code is retained; the **magnitude claim is not to be cited** outside the microbenchmark context.

---

## PF-7 — `__atomic_load_n` conversion — RETAINED AS CLEANUP

**Original claim.** Replacing `__sync_fetch_and_add(x, 0)` with `__atomic_load_n(x, __ATOMIC_SEQ_CST)` would eliminate a disguised RMW with a proper atomic load.

**Reviewer correction.** *"This will generate exactly the same code unless we explicitly use a weaker memory order (both are sequentially consistent by default)."* Confirmed: on x86-64 both forms emit the same `lock`-prefixed instruction. `kvc_counter_bump` measured 4 ns per RMW, matching `lock xadd`. **PF-7 is a no-op at the machine-code level.**

**Status.** Code retained because `__atomic_load_n` is semantically clearer (an explicit load vs a disguised RMW), but **not** attributable as a performance improvement. Future work: migrate libobjc2 atomics to C++11 `std::atomic<T>` (reviewer-suggested, out of scope for this audit).

---

## RB-2 — NULL selector guard — REVERTED

Added `if (UNLIKELY(selector == NULL)) return NULL;` to the top of `objc_msg_lookup_internal`. Reviewer: *"Selectors being null is undefined behaviour and cannot happen in compiler-generated code. Adding a null check on one of the hottest paths in the runtime would be a regression."* Reverted in libobjc2 `5d783fd`. **Rule going forward: trust the ObjC runtime contract on hot paths.**

---

## TS-3 — LockGuards on selector introspection — REVERTED

Added `LockGuard` around `selector_list->size()` reads in `isSelRegistered`, `sel_getNameRegistered`, and `sel_getNameNonUnique`. Reviewer: *"This counter grows monotonically. If a selector is registered while this call is happening, then the result is undefined. It's technically UB, in that there is an unsynchronised read."* — but intentional, because the worst case is a transient false negative on a selector that was registered mid-call, and that is cheaper than mutex contention on every introspection.

Three `LockGuard` additions reverted in `5d783fd`. **Other TS-3 changes retained**: TOCTOU re-check in `objc_register_selector`, reduced pre-allocation.

---

## TS-14 — Bounded `cleanupPools` loop — REVERTED

Replaced a recursive `cleanupPools(tls)` self-call with a bounded loop. Reviewer: *"This should not be called twice, the first caller nulls out the pointer after the cleanup. The one corner case where it can be called twice is if cleanup reallocates the TLS, in which case doing the cleanup twice is correct."*

The original recursive form handles the TLS-reallocation corner case correctly because the recursive call operates on the new TLS. The bounded-loop form only re-checks the same pointer — semantically wrong for the reallocation case.

Reverted in `5d783fd`. **B6 pool-page recycling is preserved** — `drain_pool_free_list(tls)` still sits between the (restored) recursive cleanup and `free(tls)`.

---

## RB-7 — `protocol_copyPropertyList2` outCount — FIX-THE-FIX

Original audit added a NULL-protocol guard before the deref. Reviewer: *"The null check is in a silly place (after the dereference), but the API contract here is that the argument must not be null, so it's actually dead code. This function also should be setting `*outCount = 0` in the early returns."*

The real bug was three early-return paths (old-protocol fast path, `properties == NULL`, `count == 0`) that left `*outCount` holding whatever garbage was on the caller's stack.

**Applied in `5d783fd`:**
- Removed the dead NULL check.
- Added `*outCount = 0;` to all three remaining early returns.
- Left the success-path `*outCount = count;` unchanged.

**Test impact.** `instrumentation/tests/libobjc2/test_protocol_null.m` was rewritten to verify the real contract (outCount = 0 on early returns with valid protocols) instead of the invalid NULL-protocol crash behavior it originally tested.

---

## Open reviewer clarifications

Noted in `docs/reviewer-feedback-2026-04-13.md` but unresolved:

1. **RB-1.** Reviewer said "the fix is incorrect" but the current code at `eh_personality.c:760-783` already saves `thrown_object = ex->object`, frees `ex`, then calls `_objc_unexpected_exception(thrown_object)` — which matches the reviewer's stated intent. Possible miscommunication; needs clarification on what specific defect the reviewer saw.
2. **TS-7.** Reviewer said the dual-lock `if (lock != lock2)` guard is needed "in a few more places." Both known dual-lock sites in `properties.m` (`objc_copyCppObjectAtomic`, `objc_copyPropertyStruct`) already carry the guard and grep finds no other `lock_for_pointer` dual-lock patterns. Needs clarification on which additional sites were intended.

---

## Spike history

The `docs/spikes/` directory contains the pre-reviewer-feedback analysis for each investigation. The **addendum** files in particular capture mid-experiment state and should be read as historical snapshots, not current recommendations:

- `2026-04-13-per-class-cache-version.md` and `-addendum.md` — B1 attempts and side-band retry, superseded by this log.
- `2026-04-13-gs-small-dictionary.md` and `-addendum.md` — B5.1, superseded by this log.
- `2026-04-13-tagged-pointer-nsstring.md` and `-addendum.md` — GSTinyString, superseded by this log.
- `2026-04-13-dtable-cache-line.md` — NO-GO (measurement showed no win).
- `2026-04-13-glyph-caching.md` — NO-GO.
- `2026-04-13-nszone-removal.md` — retained as shim (B7).
- `2026-04-13-pool-page-recycling.md` — retained (B6).

Primary truth lives in this log and in `docs/reviewer-feedback-2026-04-13.md`. When they disagree with a spike doc, they win.
