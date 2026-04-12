# Phase 2: libs-base Foundation Audit Findings

**Date:** 2026-04-12
**Status:** ALL FIXED — 12 commits across security, crash, thread safety, and robustness categories
**Repo:** libs-base (1,123 files, Foundation framework)

---

## Executive Summary

libs-base has **2 Critical, 10 High, 14 Medium** severity findings. The most impactful:

1. **NSSecureCoding completely unimplemented** (Critical) — deserialization attack surface wide open
2. **Cross-thread autorelease pool drain corrupts pool chain** (Critical)
3. **TLS server verification disabled by default** (High) — MITM vulnerability
4. **JSON parser has no recursion depth limit** (High) — stack overflow DoS
5. **NSCache is O(n) per access and never evicts non-discardable objects** (High perf) — cache is broken
6. **NSRunLoop timer processing is O(n) per iteration** (High perf)

---

## 1. Thread Safety Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| TS-1 | **Critical** | NSAutoreleasePool.m:588 | Cross-thread pool drain corrupts *calling* thread's pool chain — no thread identity check |
| TS-2 | **High** | NSLock.m:1008 vs :393 | Windows trylock never returns EDEADLK; `lockBeforeDate:` deadlock detection broken on Windows |
| TS-3 | **High** | NSRunLoop.m:885-948 | NSRunLoop has zero internal locking; any cross-thread access is unsafe (by design, matching Apple) |
| TS-4 | **High** | NSOperation.m:991-999 | KVO notifications sent outside lock; transient inconsistent state for operationCount |
| TS-5 | **Medium** | NSLock.m:944-989 | SRWLOCK depth/owner fields not atomically coupled (safe in practice, fragile) |
| TS-6 | **Medium** | NSThread.m:1190 | `_cancelled` flag written/read without atomic — technically UB |
| TS-7 | **Medium** | NSOperation.m:368 | `setCompletionBlock:` not protected by lock; potential use-after-free |
| TS-8 | **Medium** | NSOperation.m:600 | `NSBlockOperation -main` removes execution blocks without lock |
| TS-9 | **Medium** | NSThread.m:636-658 | Thread exit exception handler double-cleanup of `ref` |
| TS-10 | **Medium** | Multiple | No enforced lock ordering hierarchy across the framework |

---

## 2. Assertion & Robustness Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| RB-1 | **Critical** | NSKeyedUnarchiver.m:389-445 | NSSecureCoding completely unimplemented — `unarchivedObjectOfClasses:` ignores class whitelist; `requiresSecureCoding` flag never checked during decode. Attacker-controlled archive data can instantiate **any runtime class**. Classic deserialization vulnerability. |
| RB-2 | **High** | NSZone.m:84 | `NS_BLOCK_ASSERTIONS` hardcoded to 1 — all zone integrity checks disabled in production |
| RB-3 | **High** | NSZone.m:624-631 | OOM exception raised while holding zone mutex → permanent deadlock |
| RB-4 | **High** | NSException.m:700-722 | Stack trace via `signal()` (not `sigaction()`) — global handler installed/removed per-call, races with other threads |
| RB-5 | **High** | NSKeyedUnarchiver.m:167 | Unvalidated archive index → out-of-bounds GSIArray/NSArray access |
| RB-6 | **High** | GSTLS.m:168 | TLS server verification **disabled by default** (`verifyServer = NO`) — HTTPS vulnerable to MITM |
| RB-7 | **High** | GSTLS.m:2063-2076 | TLS verification failure silently ignored when `shouldVerify == NO` |
| RB-8 | **High** | NSJSONSerialization.m:578-624 | No recursion depth limit in JSON parser — stack overflow DoS on deeply nested input |
| RB-9 | **High** | NSPropertyList.m:3081 | Integer overflow in binary plist bounds check: `object_count * offset_size` overflows unsigned 32-bit |
| RB-10 | **Medium** | NSKeyedUnarchiver.m:493-506 | `decodeArrayOfObjCType:` copies data without verifying archive data length matches expected size → buffer overflow |
| RB-11 | **Medium** | GSTLS.m:2515-2518 | Hostname verification skipped when `GSTLSRemoteHosts` is nil (common case) |
| RB-12 | **Medium** | GSHTTPURLHandle.m:108-145 | No timeout handling — slow server causes indefinite hang |
| RB-13 | **Medium** | NSJSONSerialization.m:567 | `strtod` without ERANGE check; all JSON numbers become doubles (precision loss for large ints) |
| RB-14 | **Medium** | NSPropertyList.m:3139-3141 | Binary plist bounds checks use NSAssert — disappear in release builds |
| RB-15 | **Medium** | NSFileManager.m:2686-2703 | No symlink loop detection in directory enumeration — infinite loop / memory exhaustion |
| RB-16 | **Medium** | NSMethodSignature.m:529 | `alloca(strlen(t) * 16)` with unchecked size — stack overflow on long type strings |
| RB-17 | **Medium** | NSMethodSignature.m:295 | `next_arg()` struct parser loops infinitely on malformed input missing closing character |
| RB-18 | **Medium** | NSZone.m:800-830 | Zone recycle frees zone struct while other threads may be reading it |

---

## 3. Performance Findings

| ID | Sev | Issue | Impact | Fix |
|----|-----|-------|--------|-----|
| PF-1 | **P0** | NSCache: O(n) linear scan per access (line 109) + non-discardable objects never evicted | Cache is essentially broken | Replace `_accesses` array with doubly-linked list; implement eviction for all object types |
| PF-2 | **P0** | NSRunLoop: O(n) timer scan every iteration (line 1040-1097) | Degrades linearly with timer count | Use min-heap per mode |
| PF-3 | **P1** | NSString: No small-string / tagged-pointer optimization | 2 heap allocations per short string | Implement tagged pointer for <=11-byte ASCII |
| PF-4 | **P1** | NSDictionary: No small-dictionary optimization | Full hash table overhead for 1-3 entry dicts | `GSSmallDictionary` for <=4 entries |
| PF-5 | **P1** | JSON: Always NSMutableString + all numbers as double | Throughput + precision loss | Stack buffer for short strings; detect integers |
| PF-6 | **P2** | NSMutableData: Initial growth=1, Fibonacci growth | Many early reallocations | Set minimum initial capacity to 64-128 bytes |
| PF-7 | **P2** | NSString: No encoding conversion cache | Redundant UTF8String conversions | Cache UTF-8 repr lazily |
| PF-8 | **P2** | NSData: No mmap equivalent on Windows | Large file penalty on Windows | Use CreateFileMapping/MapViewOfFile |
| PF-9 | **P2** | NSRunLoop performer removal: O(n*m) cross-mode scan | Scales poorly with modes x performers | Set-based lookup per mode |
| PF-10 | **P3** | NSAutoreleasePool: 16-slot IMP cache; O(depth) parent walk in init | Minor per-pool overhead | Expand to 64 slots; track depth as counter |
| PF-11 | **P3** | JSON emit: character-at-a-time string building | Output throughput | Use NSMutableData with direct UTF-8 writes |
| PF-12 | **P3** | NSMethodSignature cache never evicts | Unbounded memory growth | Add LRU eviction or size cap |

---

## Top 10 Actionable Fixes

| Priority | ID | Description | Effort |
|----------|----|-------------|--------|
| 1 | RB-1 | Implement NSSecureCoding class whitelist enforcement | Medium |
| 2 | RB-6 | Change TLS `verifyServer` default to YES | Trivial |
| 3 | RB-8 | Add recursion depth limit to JSON parser | Small |
| 4 | RB-9 | Fix integer overflow in binary plist bounds check | Small |
| 5 | TS-1 | Add thread identity check to autorelease pool drain | Small |
| 6 | RB-3 | Ensure zone mutex is released before raising OOM exception | Small |
| 7 | PF-1 | Replace NSCache linear scan with O(1) linked list | Medium |
| 8 | PF-2 | Replace NSRunLoop timer array with min-heap | Medium |
| 9 | TS-2 | Return EDEADLK from Windows trylock on error-check mutex | Small |
| 10 | RB-5 | Add bounds check on archive index before array access | Small |
