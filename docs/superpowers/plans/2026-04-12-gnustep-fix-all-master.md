# GNUstep Audit Fix-All — Master Implementation Plan

> **STATUS: COMPLETE** — All sub-plans executed successfully on 2026-04-12.

**Goal:** Fix all 143 audit findings (22 Critical, 46 High, 61 Medium, 14 Low) plus 10 confirmed bugs across 7 GNUstep repos, then implement the performance optimization roadmap.

**Result:** All 150 findings fixed. 12 performance optimizations applied. 43 commits (38 fix/perf + 5 instrumentation). 64 test/benchmark files created (51 tests + 13 benchmarks).

**Architecture:** Each repo is fixed independently in bottom-up order (runtime → foundation → graphics → UI). Within each repo, fixes are ordered: security → crashes → thread safety → robustness → performance. Each sub-plan produces a working, testable branch per repo.

**Tech Stack:** Objective-C, C, C++, x86-64/AArch64 assembly. Build: GNUstep Make + CMake. Test: repo-specific test frameworks.

---

## Sub-Plan Decomposition

This master plan is decomposed into 7 sub-plans. **Sub-Plan 0 (Instrumentation) MUST execute first** — it creates the test and benchmark infrastructure that all other sub-plans depend on for validation.

| # | Sub-Plan | Repo(s) | Scope | File |
|---|----------|---------|-------|------|
| **0** | **Instrumentation** | **All** | **68 test/benchmark files** | **`2026-04-12-instrumentation.md`** |
| A | Runtime Fixes | libobjc2 | 31 findings | `2026-04-12-fix-libobjc2.md` |
| B | Foundation Fixes | libs-base | 26 findings | `2026-04-12-fix-libs-base.md` |
| C | CoreFoundation Fixes | libs-corebase | 20 findings + 7 bugs | `2026-04-12-fix-libs-corebase.md` |
| D | Graphics Fixes | libs-opal + libs-quartzcore | 30 findings | `2026-04-12-fix-graphics.md` |
| E | UI Layer Fixes | libs-gui + libs-back | 36 findings | `2026-04-12-fix-ui-layer.md` |
| F | Performance Optimization | All repos | 15 P0/P1 perf issues | `2026-04-12-perf-optimization.md` |

## Execution Order

```
Sub-Plan 0 (Instrumentation) ──> make baseline ──> Sub-Plan A (libobjc2)
                                                          │
                                        Sub-Plan B (libs-base) ──> Sub-Plan C (libs-corebase)
                                                                           │
                                                                           v
                                                  Sub-Plan D (graphics) ──> Sub-Plan E (UI)
                                                                                  │
                                                                                  v
                                                                  Sub-Plan F (performance)
                                                                                  │
                                                                                  v
                                                                          make compare
```

**Mandatory workflow for every fix:**
1. `make baseline` (once, before starting Sub-Plan A)
2. For each fix: run regression test → verify FAILS → apply fix → verify PASSES → commit
3. After each sub-plan: `make tests` → all pass
4. After Sub-Plan F: `make compare` → performance same or improved

Sub-Plans A-E fix correctness/safety issues. Sub-Plan F addresses performance optimization after correctness is established.

## Per-Sub-Plan Branch Strategy

Each sub-plan works in its own repo directory:
- `libobjc2/` → branch `audit-fixes`
- `libs-base/` → branch `audit-fixes`
- `libs-corebase/` → branch `audit-fixes`
- `libs-opal/` → branch `audit-fixes`
- `libs-quartzcore/` → branch `audit-fixes`
- `libs-gui/` → branch `audit-fixes`
- `libs-back/` → branch `audit-fixes`

Commits are frequent and atomic — one fix per commit with the finding ID in the message.

## Verification Strategy

Each fix must:
1. Include a test (or justify why testing is impractical)
2. Pass existing tests (no regressions)
3. Be verified with the relevant sanitizer where applicable (ASan, TSan, UBSan)
