# Phase 3: libs-corebase CoreFoundation Audit Findings

**Date:** 2026-04-12
**Status:** ALL FIXED — 6 commits including 7 confirmed bug fixes
**Repo:** libs-corebase (153 files, CoreFoundation layer)

---

## Executive Summary

libs-corebase has **7 confirmed bugs**, **4 Critical, 6 High, 10 Medium** findings. The codebase has only 1-2 assertions across all source files — the assertion gap is severe. Additionally, several outright bugs were found in CFSocket and CFRunLoop.

Key issues:
1. **CFSocket sendto() arguments swapped** (Bug) — no data ever sent
2. **CFRunLoop multiple data races** on `_isWaiting`, `_stop`, `_currentMode` (Critical)
3. **Only 1 assertion in entire codebase** — zero parameter validation on any public API
4. **CFArray uses linear growth (+16)** — O(n^2) sequential appends
5. **CFRunLoop mallocs/frees temp arrays every iteration** (High perf)

---

## 1. Confirmed Bugs

| # | File:Line | Bug | Impact |
|---|-----------|-----|--------|
| 1 | CFSocket.c:603-604 | `sendto()` args swapped: `len` and `flags` transposed | **No data ever sent** via CFSocket |
| 2 | CFSocket.c:392-409 | `CFSocketCopyPeerAddress` writes to `_address` not `_peerAddress` | Returns wrong address |
| 3 | CFSocket.c:379,399 | `addrlen` uninitialized before `getsockname`/`getpeername` | Undefined behavior |
| 4 | GSPrivate.h:91 | `GSMutexDestroy` misspelled as `pthraed_mutex_destroy` | Mutexes never destroyed |
| 5 | CFRunLoop.c:1523-1524 | `CFRunLoopSourceRemoveInvalidated` uses `ctxt->timers` count for `ctxt->sources0` search | Wrong range searched |
| 6 | CFString.c:951 | `CFStringGetSurrogatePairForLongCharacter` rejects valid chars > U+10000 | All supplementary Unicode rejected |
| 7 | CFPropertyList.c:296 | `CFPropertyListCreateDeepCopy` mutable array copies from empty dest instead of source | Empty array returned |

---

## 2. Thread Safety Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| TS-1 | **Critical** | CFRunLoop.c:868,876,855,963 | `_isWaiting` and `_stop` flags written/read across threads without atomics or lock |
| TS-2 | **Critical** | CFRunLoop.c:614,617 / :1566 | `source->_isSignaled` set by `CFRunLoopSourceSignal` from any thread; read without lock in dispatch |
| TS-3 | **High** | CFRunLoop.c:493-498 | Observer `_isValid`/`_repeats` read after dropping lock; races with `CFRunLoopObserverInvalidate` |
| TS-4 | **High** | CFRunLoop.c:797,937 | `_currentMode` set without lock; read by `CFRunLoopStop` from other thread |
| TS-5 | **High** | CFSocket.c:620-636 | `CFSocketInvalidate` sets `_socket = -1` without lock; concurrent callback reads stale fd |
| TS-6 | **High** | CFSocket.c:550-563 | `CFSocketDisableCallBacks`/`EnableCallBacks` modifies `_cbTypes` without lock |
| TS-7 | **Medium** | CFSocket.c:181,193,725,765 | `_readFired`/`_writeFired` flags non-atomic across dispatch threads |
| TS-8 | **Medium** | CFString.c:206-211 | Hash computation stores result without lock; torn write on 32-bit |
| TS-9 | **Medium** | CFString.c:260-307 | `__CFStringMakeConstantString` unlocked dictionary lookup races with locked insert |
| TS-10 | **Medium** | GSHashTable.c | Zero locking — not safe for concurrent reads during rehash |
| TS-11 | **Medium** | NSCFArray.m, NSCFString.m | No mutability guard — mutation calls on immutable CF objects silently corrupt memory |

---

## 3. Assertion Gap Analysis

**Current state:** 1 assertion in GSHashTable.c, 1 allocation check in CFString.c. **Zero parameter validation on any public CF API.**

### Priority 1 — NULL parameter checks (prevents crashes):
All public APIs in CFRunLoop.c, CFSocket.c, CFString.c, CFData.c, CFDictionary.c, CFArray.c, CFBase.c need NULL checks on primary parameters.

### Priority 2 — Type ID validation (prevents type confusion):
All public CF functions should verify `CFGetTypeID(obj) == expectedTypeID` before operating.

### Priority 3 — Range/bounds checks:
CFStringGetCharacterAtIndex, CFStringGetCharacters, CFArrayGetValueAtIndex, CFArrayApplyFunction need bounds validation.

### Priority 4 — Mutability guards:
All CFMutableXxx functions should assert mutability before modification.

---

## 4. Robustness Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| RB-1 | **Medium** | CFPropertyList.c:703 | No recursion depth limit — stack overflow on deeply nested plists |
| RB-2 | **Medium** | CFPropertyList.c:627-634 | Incomplete OpenStep plist escape sequences (FIXME comments) |
| RB-3 | **Low** | CFPropertyList.c:937-941 | Base64 encoding for binary plist data unimplemented |
| RB-4 | **Medium** | GSHashTable.c | Tombstone accumulation degrades probe chains; no cleanup except rehash |

---

## 5. Performance Findings

| ID | Sev | Issue | Impact | Fix |
|----|-----|-------|--------|-----|
| PF-1 | **High** | CFArray linear growth (+16) | O(n^2) sequential appends | Geometric doubling |
| PF-2 | **High** | CFString ASCII hash allocates temp buffer (line 220) | malloc+copy+free on every first hash | Hash ASCII bytes in-place |
| PF-3 | **High** | CFRunLoop mallocs/frees temp arrays every iteration for timers, sources, observers | Allocation overhead per wakeup x5 | Stack-allocated small buffers or persistent scratch arrays |
| PF-4 | **High** | CFRunLoop uses pipe() instead of eventfd() | 2 fds per run loop; no Windows support | Use eventfd() on Linux; WaitForMultipleObjects on Windows |
| PF-5 | **High** | NSCFDictionary keyEnumerator materializes entire key array | O(n) allocation per enumeration start | Implement stateful iteration with CFDictionaryApplyFunction |
| PF-6 | **High** | NSCFDictionary fast enumeration re-copies all keys per batch | Destroys O(1)-per-batch guarantee | State-based iteration |
| PF-7 | **Medium** | CFMutableString exact-fit growth (no geometric factor) | O(n) reallocations for append patterns | capacity *= 2 on grow |
| PF-8 | **Medium** | GSHashTable double lookup in Add/Set (retrieve then insert) | 2 full hash probes per insert | Merge into single probe |
| PF-9 | **Medium** | GSHashTableBucket 24 bytes (count field wastes 6 bytes) | 33% memory overhead per bucket | Bitfield or sentinel for count |
| PF-10 | **Medium** | CFRunLoop poll() has only millisecond timer resolution | Timers can fire up to 1ms late | ppoll() or timerfd |
| PF-11 | **Medium** | Version-1 sources (port-based) unimplemented | No Mach port equivalent | Implement or document limitation |

### Bridging Bugs (cause crashes, not just perf):
| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| BUG-1 | **High** | NSCFString.m:330-331 | `lengthOfBytesUsingEncoding:` calls itself recursively → stack overflow |
| BUG-2 | **Medium** | NSCFString.m:324 | `getCString:maxLength:encoding:` uses wrong encoding conversion direction |
| BUG-3 | **Medium** | NSCFDictionary.m:193-210 | `_cfSetValue:`/`_cfReplaceValue:` do redundant remove-then-set (3 lookups instead of 1) |
