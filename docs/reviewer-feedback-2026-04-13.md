# Reviewer Feedback on Audit Findings — 2026-04-13

An expert libobjc2 maintainer reviewed several of the audit's committed findings and provided feedback identifying incorrect, incomplete, or misclassified fixes. This document captures the full exchange and the resulting actions.

## Process

1. Reviewer examined audit commits across libobjc2 and libs-base and wrote brief assessments per finding.
2. Each assessment was triaged against the audit's performance rule and correctness gates.
3. Actions were executed in two batches: B1 Phase A revert first (largest blast radius), then smaller reverts/fix-the-fixes.
4. This document is the historical record — future auditors should consult it before re-opening any of the findings below.

## Per-finding verdicts and actions

### RB-1 — exception rethrow use-after-free (eh_personality.c)

**Reviewer:** *"The issue RB-1 is kind-of real, but the fix is incorrect (we should free the object before calling the unexpected exception handler, because it may not return), though this is almost unreachable code. It can basically happen only if there is an internal error in the unwind library."*

**Assessment:** The current code at `eh_personality.c:760-783` already does what the reviewer describes as the correct fix — it saves `thrown_object = ex->object` into a local, then calls `free(ex)`, then calls `_objc_unexpected_exception(thrown_object)`. The handler is invoked after the struct is freed, and thrown_object is a valid `id` held in a local variable that survives the handler call.

The reviewer's assertion that "the fix is incorrect" is puzzling because the code matches their stated intent. Possible interpretations:
- The reviewer read only the commit message and thought the fix was a variable rename without reordering.
- The reviewer meant something more subtle about object ownership that is not clear from the feedback text.

**Action:** **No change.** Current code at `a492a11:760-783` in libobjc2 master already has the correct order. Documenting as "verified against reviewer's stated intent; may warrant follow-up clarification" if an actual defect is identified.

### RB-2 — null selector guard in objc_msg_lookup_internal (sendmsg2.c)

**Reviewer:** *"RB-2 is not correct, selectors being null is undefined behaviour and cannot happen in compiler-generated code. Adding a null check on one of the hottest paths in the runtime would be a regression."*

**Assessment:** Agree completely. The audit added `if (UNLIKELY(selector == NULL)) { return NULL; }` to the top of `objc_msg_lookup_internal`, which is on the message-dispatch hot path. The reviewer's point is correct: the ObjC runtime contract is that selectors are non-null in any code reaching this function, and compiler-generated dispatch code never produces a NULL selector. The check is dead weight.

**Action: REVERT.** libobjc2 commit `5d783fd` removes the check.

### TS-3 — selector table unsynchronized read (selector_table.cc)

**Reviewer:** *"TS-3 is incorrect. This counter grows monotonically. If a selector is registered while this call is happening, then the result is undefined. It's technically UB, in that there is an unsynchronised read."*

**Assessment:** The reviewer is saying the unsynchronized read of `selector_list->size()` in `isSelRegistered`, `sel_getNameRegistered`, and `sel_getNameNonUnique` is **intentional**. The counter is monotonic, so the worst case is a transient false negative on a selector that was registered mid-call — which is acceptable because the caller either sees the registration or doesn't. Adding LockGuards as the audit did trades that acceptable transient against mutex contention on selector introspection, a regression.

**Action: REVERT.** libobjc2 commit `5d783fd` removes the three LockGuard additions. The other changes in the original `bfe1610` commit (TOCTOU re-check in `objc_register_selector`, reduced pre-allocation) are preserved — only the LockGuard additions are reverted.

### TS-7 — skip double-lock when two pointers hash to same spinlock (properties.m)

**Reviewer:** *"TS-7 looks like a fix that we need in a few more places, not sure why it's only highlighted in the place the code was copied to, not the place it was copied from."*

**Assessment:** Inconclusive. The audit applied the `if (lock != lock2)` guard to BOTH dual-lock sites in `properties.m`: `objc_copyCppObjectAtomic` (lines 130-147) and `objc_copyPropertyStruct` (lines 176-197). A grep across libobjc2 for `lock_for_pointer` found no other dual-lock patterns. The reviewer's "more places" comment may refer to callers that should be protected but currently aren't, or may be a misread of the audit's scope.

**Action:** **No change.** Both known dual-lock sites are already protected. Flagging for reviewer clarification on which additional sites were intended.

### TS-14 — bounded cleanupPools loop (arc.mm)

**Reviewer:** *"I think TS-14 is spurious, this should not be called twice, the first caller nulls out the pointer after the cleanup. The one corner case where it can be called twice is if cleanup *reallocates* the TLS, in which case doing the cleanup twice is correct. Do you have a test case that demonstrates this?"*

**Assessment:** We do not have a test case that demonstrates the double-call scenario. The audit finding was based on code inspection, not a demonstrated failure mode. The original recursive `cleanupPools(tls)` call handles the reallocation corner case correctly — when `release()` during `emptyPool` triggers ARC code that creates a new TLS for the same thread, the recursive call operates on the new TLS, and doing cleanup twice in that scenario is correct behavior, not a bug.

The audit's bounded-loop replacement changes the semantics in a way that is incorrect for this corner case: the loop only re-checks the same `tls` pointer, not the newly-reallocated TLS instance.

**Action: REVERT.** libobjc2 commit `5d783fd` restores the original recursive form. The B6 pool-page recycling work (`drain_pool_free_list(tls)` call added between the recursive cleanup and `free(tls)`) is preserved.

### RB-6 — CFArray / similar copy-paste bug

**Reviewer:** *"RB-6 looks like the right fix, simple copy-and-paste bug. Note that this happens only when memory is exhausted, at which point most Objective-C programs will start failing."*

**Assessment:** Agreement on the fix. The OOM caveat is good context for future reviewers — the fix is worth keeping even though the path is cold.

**Action: No change.** Keep the fix as-is.

### RB-7 — null check after deref and missing outCount=0 (protocol.c)

**Reviewer:** *"RB-7, the null check is in a silly place (after the dereference), but the API contract here is that the argument must not be null, so it's actually dead code. This function also should be setting `*outCount = 0` in the early returns."*

**Assessment:** The original audit fix moved the NULL check before the deref, which the reviewer says is dead code because the API contract forbids NULL. The reviewer's other observation is the real issue: `protocol_copyPropertyList2` has FOUR early return paths (NULL protocol, old-protocol fast path, properties == NULL, count == 0) and the original audit only set `*outCount = 0` in the first one.

**Action: FIX-THE-FIX.** libobjc2 commit `5d783fd`:
- Removes the NULL protocol check entirely (trust the API contract).
- Adds `*outCount = 0;` to all three remaining early returns.
- Leaves the success-path `*outCount = count;` unchanged.

The `test_protocol_null.m` test was also rewritten (in the companion gnustep-audit commit) to verify the real contract (outCount = 0 on early returns with valid protocols) instead of the invalid NULL-protocol crash behavior it previously tested.

### PF-6 — weak reference lock striping

**Reviewer:** *"PF-6, yes that refactoring would probably be good to do, though note that we don't hit the weak lock in most cases, only if an object is marked as having weak refs. Have you measured slowdown from this on anything that isn't a contrived microbenchmark? The quoted slowdown looks incredibly unlikely unless you have a microbenchmark doing nothing but hitting weak references from multiple threads."*

**Assessment:** The reviewer concedes the refactoring is correct but challenges the claimed 5-8× slowdown that motivated it. Their point: the weak lock is only on the critical path for operations on objects that actually have weak refs — a minority of objects in typical workloads. Our audit claim of a severe cross-thread slowdown was based on the spike's estimate, not a measurement I verified.

**Action: Keep the code, amend the documentation.** PF-6 already landed and the code change is correct (it hurts nothing). The slowdown magnitude claim in the audit documentation should be qualified as "microbenchmark measurement under contrived weak-ref contention; real-workload impact unverified." This doc is the qualifying record.

### PF-7 — __sync_fetch_and_add(x, 0) → __atomic_load_n(x, __ATOMIC_SEQ_CST)

**Reviewer:** *"PF-7, this will generate exactly the same code unless we explicitly use a weaker memory order (both are sequentially consistent by default). We should move this code over to C++11 atomics at some point."*

**Assessment:** The reviewer is right and this is load-bearing correction. PF-7 was presented as a performance optimization (replacing a "disguised atomic load" pattern with the proper atomic load). In reality, both forms emit identical machine code under SEQ_CST (the default for `__sync_*` and for `__atomic_load_n` when no memory order is specified). On x86-64, both compile to the same `lock`-prefixed sequence.

Our own B1 benchmark confirms this: `kvc_counter_bump` measured 4 ns per atomic RMW (exactly the cost of a `lock xadd`), which is what both `__sync_fetch_and_add(x, 0)` and `__atomic_load_n(x, __ATOMIC_SEQ_CST)` compile to.

**This means PF-7 is a no-op at the machine-code level.** Both the original PF-7 commit (`3c13ecc`) and today's completion commit (`834c978`) generate identical instruction sequences to the pre-audit code.

**Action: Keep the code, amend the documentation.** The readability win is real — `__atomic_load_n` is semantically clearer than `__sync_fetch_and_add(x, 0)` (an explicit load vs a disguised RMW). But the commits should NOT be attributed as performance improvements. This doc is the qualifying record.

Future work the reviewer suggested: migrate libobjc2 atomics to C++11 `std::atomic<T>` for modern code hygiene. Out of scope for this audit.

### PF-4 — global method cache version counter (→ B1 revert)

**Reviewer:** *"PF-4 was an intentional design choice. Method replacements are infrequent. The proposed change would make things worse."*

**Assessment:** This is the load-bearing rejection of B1 Phase A. The global `objc_method_cache_version` counter was deliberately designed as a single process-wide monotonic value, on the assumption that method replacements are rare events (hours or days apart in real applications). Our B1 microbenchmark `bench_kvc_cache_storm` measured a 23× reduction by directly incrementing the counter 10,000 times per iteration — a workload that does not occur in production.

Adding per-class counters introduces a pointer-chase on every KVC check in exchange for eliminating a refresh cost that is virtually never paid. Net effect on real applications: slightly slower.

**Action: REVERT B1 Phase A.** Full details are in `docs/spikes/2026-04-13-per-class-cache-version-addendum.md`. The reverts are:
- `DTW-Thalion/libobjc2` commit `a361c1a` reverts `0cc8962`.
- `DTW-Thalion/libs-base` commit `2c5eb64fa` reverts `c12ac2391`.
- `DTW-Thalion/gnustep-audit` commit `013ac99` updates the addendum and canonical baseline.

`bench_kvc_cache_storm` benchmark + historical `baseline_pre_b1.jsonl` retained as infrastructure for anyone who later finds a real workload where the counter moves frequently enough to matter.

## Summary table

| Finding | Verdict | Action | Commit |
|---|---|---|---|
| RB-1 | Fix appears correct per reviewer's intent | No change; flagged for clarification | — |
| RB-2 | Dead check on hot path | Revert | `libobjc2 5d783fd` |
| TS-3 | Intentional unsynchronized read | Revert LockGuards | `libobjc2 5d783fd` |
| TS-7 | Audit covered both known sites | No change; clarification needed | — |
| TS-14 | Spurious, recursive form correct | Revert to recursive form | `libobjc2 5d783fd` |
| RB-6 | Correct | No change | — |
| RB-7 | Missing outCount=0 in 3 early returns | Fix-the-fix | `libobjc2 5d783fd` |
| PF-6 | Code correct, slowdown claim contrived | Doc amendment | this file |
| PF-7 | Same machine code, not a perf win | Doc amendment | this file |
| PF-4 / B1 | Intentional design, microbenchmark contrived | Revert Phase A | `libobjc2 a361c1a`, `libs-base 2c5eb64fa`, `gnustep-audit 013ac99` |

## Lessons

1. **Microbenchmarks can validate a theoretically-slow path without that path ever being hit in practice.** The KVC cache storm and the weak lock contention claims both suffered from this. The review rule should be: before claiming a slowdown, identify a realistic workload that triggers it, not just construct a loop that maxes out the bad path.

2. **Domain expertise beats microbenchmark optimism.** The reviewer knew the design history of the global cache counter and the weak-ref lock, and correctly rejected "fixes" that would have regressed real workloads to speed up contrived ones. Trust the maintainer's judgment when it contradicts synthetic measurements.

3. **Readability-motivated changes should be labeled as such.** PF-7 is a fine cleanup but was mis-labeled as a perf optimization. Future audit commits should distinguish "this is a readability/correctness improvement that compiles to the same code" from "this is a performance improvement that measurably changes runtime cost."

4. **API contracts matter more than defensive checks.** RB-2 (NULL selector), RB-7 (NULL protocol), and TS-3 (unsynchronized read) all added defensive code on the basis of "crash-resistant is better than crashing." The reviewer's position — trust the contract, don't add checks to hot paths — is the correct ObjC runtime discipline and matches the rest of libobjc2's style. Future audits should match the existing code's discipline on this rather than tacking on defensive checks from outside that discipline.

## Open items for reviewer follow-up

1. **RB-1** — reviewer said "the fix is incorrect" but the current code matches their stated intent. Request clarification on what specific defect they see.
2. **TS-7** — reviewer said the fix is needed "in a few more places" but both known dual-lock sites in `properties.m` are already protected. Request which additional sites were intended.

## Artifacts retained

- `bench_kvc_cache_storm.m` — microbenchmark infrastructure (not a production-workload indicator)
- `baseline_pre_b1.jsonl` — historical capture before B1 attempt
- `docs/spikes/2026-04-13-per-class-cache-version-addendum.md` — full B1 post-mortem including the failed tail-field attempt, the working side-band retry, and the revert decision
