# GNUstep End-to-End Code Audit

A comprehensive code audit and fix implementation for the GNUstep core runtime and UI stack, covering assertion failures, thread safety, robustness, and performance optimization.

## Scope

7 repositories, 2,686 source files, bottom-up audit from runtime to UI layer:

| Layer | Repo | Files | Role |
|-------|------|------:|------|
| Runtime | libobjc2 | 150 | Objective-C runtime, message dispatch |
| Foundation | libs-base | 1,123 | Foundation framework |
| Foundation | libs-corebase | 153 | CoreFoundation C layer |
| Graphics | libs-opal | 176 | CoreGraphics/Quartz 2D |
| Graphics | libs-quartzcore | 94 | Core Animation |
| UI | libs-gui | 801 | AppKit |
| UI | libs-back | 189 | Display backends (X11, Win32, Wayland, Cairo) |

## Results

The bulk of the audit's correctness findings (~140 retained fixes across Critical/High/Medium/Low severities) are in the DTW-Thalion forks — thread-safety, security, robustness, and broken-API bugs. The per-phase finding tables in `docs/phase1-libobjc2-findings.md` … `docs/phase5-ui-layer-findings.md` are the authoritative reference for what was found and what was fixed.

**Read first** before digging into specific findings:
- `docs/reviewer-feedback-2026-04-13.md` — libobjc2 maintainer review and the reverts that followed.
- `instrumentation/experiment-log.md` — every experiment tried, including those reverted.

### Retained correctness fixes — highlights

| Severity | Area | Example |
|---|---|---|
| Critical | libs-base | NSSecureCoding class whitelist now enforced on deserialization |
| Critical | libs-base | TLS server cert verification on by default |
| Critical | libs-corebase | CFSocket sendto() argument order fix (was silently dropping all sends) |
| Critical | libs-quartzcore | CATransaction global stack lock; CAGLTexture alpha=0 divide-by-zero |
| Critical | libs-opal | CGContext fill_path NULL deref; TIFF destination init condition; dash-buffer malloc(bytes→doubles) |
| Critical | libs-gui | GSLayoutManager, NSView subviews, NSApplication event dispatch — thread confinement |
| High | libobjc2 | RB-1 exception rethrow save-before-free; TS-2 selector table TOCTOU re-check; TS-7 property dual-lock deadlock |
| High | libs-base | JSON parser recursion depth limit; binary plist integer overflow |
| High | libobjc2 | RB-7 `protocol_copyPropertyList2` — `*outCount = 0` on all early returns (reviewer fix-the-fix) |

### Retained performance changes

| Change | Status |
|---|---|
| Weak-ref lock 64-way striping (PF-6) | Retained. Magnitude claim qualified: only matters for objects with weak refs — see experiment log. |
| NSCache O(1) LRU linked list | Retained. |
| CFArray geometric growth | Retained. |
| NSRunLoop timer min-heap | Retained. |
| X11 expose event coalescing | Retained. |
| JSON parser buffer 64→4096 | Retained. |
| DPSimage conversion caching | Retained. |
| NSView dirty region list | Retained. |
| CFRunLoop stack buffers | Retained. |
| CALayer presentation persistence | Retained. |
| Theme tile composite cache | Retained. |
| Autorelease pool page recycling (B6) | Retained. |
| NSZone compatibility shim (B7) | Retained. |
| `__atomic_load_n` cleanup (PF-7) | Retained **as a readability cleanup only**; reviewer confirmed it compiles to the same machine code as `__sync_fetch_and_add(x,0)` under SEQ_CST. Not a perf win. |

### Reverted experiments (do not re-open without reading the log)

| Experiment | Reason |
|---|---|
| Per-class method cache counter (B1) | Reviewer: global counter is intentional; method replacement is rare in real workloads. Microbenchmark was contrived. |
| GSInlineDict (B5.1) | Measured **+14% regression** at N=4 vs baseline. |
| GSTinyString factory | Tagged-pointer branch was slower than `GSCString` in head-to-head measurement. Factory disabled; class remains dormant. |
| RB-2 NULL selector guard on dispatch hot path | Reviewer: dead defensive check on the hottest path in the runtime. Compiler-generated code never passes NULL. |
| TS-3 LockGuards on selector introspection | Reviewer: the unsynchronized read of a monotonic counter is intentional. Locking regressed introspection. (Other TS-3 changes retained.) |
| TS-14 bounded `cleanupPools` loop | Reviewer: recursive form is correct for the TLS-reallocation corner case; the loop only re-checks the original pointer. |

Full rationale for each: `instrumentation/experiment-log.md`.

## Repository Structure

```
gnustep-audit/
├── README.md                          # This file
├── docs/
│   ├── gnustep-audit-workplan.md      # Original audit workplan
│   ├── AUDIT-SUMMARY.md              # Master findings summary
│   ├── phase1-libobjc2-findings.md   # Runtime audit findings
│   ├── phase2-libs-base-findings.md  # Foundation audit findings
│   ├── phase3-libs-corebase-findings.md # CoreFoundation findings
│   ├── phase4-graphics-findings.md   # Graphics layer findings
│   ├── phase5-ui-layer-findings.md   # UI layer findings
│   ├── phase6-optimization-deep-dive.md # Performance analysis
│   └── superpowers/plans/            # Implementation plans
│       ├── 2026-04-12-gnustep-fix-all-master.md
│       ├── 2026-04-12-instrumentation.md
│       ├── 2026-04-12-fix-libobjc2.md
│       ├── 2026-04-12-fix-libs-base.md
│       ├── 2026-04-12-fix-libs-corebase.md
│       ├── 2026-04-12-fix-graphics.md
│       ├── 2026-04-12-fix-ui-layer.md
│       └── 2026-04-12-perf-optimization.md
├── instrumentation/
│   ├── README.md                      # Test/benchmark documentation
│   ├── Makefile                       # Master build orchestrator
│   ├── common/                        # Shared harness (bench_harness.h/c, test_utils.h)
│   ├── tests/                         # 51 regression tests across 7 repos
│   │   ├── libobjc2/    (11 tests)
│   │   ├── libs-base/   (12 tests)
│   │   ├── libs-corebase/ (8 tests)
│   │   ├── libs-opal/   (6 tests)
│   │   ├── libs-quartzcore/ (5 tests)
│   │   ├── libs-gui/    (6 tests)
│   │   └── libs-back/   (3 tests)
│   └── benchmarks/                    # 13 performance benchmarks
│       ├── bench_msg_send.m
│       ├── bench_retain_release.m
│       ├── bench_weak_ref.m
│       ├── bench_nscache.m
│       ├── bench_json_parse.m
│       └── ... (9 more)
├── libobjc2/          # Cloned repo with 6 audit commits
├── libs-base/         # Cloned repo with 12 audit commits
├── libs-corebase/     # Cloned repo with 6 audit commits
├── libs-opal/         # Cloned repo with 2 audit commits
├── libs-quartzcore/   # Cloned repo with 3 audit commits
├── libs-gui/          # Cloned repo with 5 audit commits
└── libs-back/         # Cloned repo with 4 audit commits
```

## Validation

### Run all regression tests
```bash
cd instrumentation
make tests
```

### Run performance benchmarks
```bash
cd instrumentation
make benchmarks
```

### Before/after performance comparison
```bash
cd instrumentation
make baseline    # Save pre-optimization numbers
# ... apply fixes ...
make compare     # Compare against baseline
```

### Per-repo tests
```bash
make tests-libobjc2
make tests-libs-base
make tests-libs-corebase
make tests-libs-opal
make tests-libs-quartzcore
make tests-libs-gui
make tests-libs-back
```

## Commit History

Each repo contains atomic commits with finding IDs:

```
fix(RB-1): save ex->object before free to prevent use-after-free
fix(TS-2): hold lock for entire check-and-register to prevent TOCTOU
perf: stripe weak reference lock 64-way for 5-8x concurrent throughput
```

Commit log per fork is authoritative — `git log --oneline` in each repo shows the retained state.

## Key Security Fixes

1. **NSSecureCoding**: Class whitelist now enforced during deserialization
2. **TLS Verification**: Server certificate verification enabled by default
3. **JSON Depth Limit**: 512-level recursion limit prevents stack overflow DoS
4. **Binary Plist**: Integer overflow in bounds check fixed
5. **Archive Bounds**: Out-of-bounds index validation added

## Methodology

1. Bottom-up audit: runtime -> foundation -> graphics -> UI
2. Per-file analysis: thread safety, assertions, error paths, performance
3. Severity ratings: Critical/High/Medium/Low
4. Fix verification: regression test per finding + benchmark per optimization
5. Instrumentation: `make baseline` -> fix -> `make compare` workflow

## GitHub Repositories

All fixes are merged to `master` on the DTW-Thalion GitHub forks:

| Repo | URL | Audit Commits |
|------|-----|:-------------:|
| gnustep-audit | https://github.com/DTW-Thalion/gnustep-audit | Instrumentation, docs, benchmarks |
| libobjc2 | https://github.com/DTW-Thalion/libobjc2 | 6 |
| libs-base | https://github.com/DTW-Thalion/libs-base | 12 |
| libs-corebase | https://github.com/DTW-Thalion/libs-corebase | 6 |
| libs-opal | https://github.com/DTW-Thalion/libs-opal | 2 |
| libs-quartzcore | https://github.com/DTW-Thalion/libs-quartzcore | 3 |
| libs-gui | https://github.com/DTW-Thalion/libs-gui | 5 |
| libs-back | https://github.com/DTW-Thalion/libs-back | 4 |

## Test Results

**34/34 regression tests pass** on MSYS2 ucrt64 with the retained-state patched libraries installed (libobjc2, gnustep-base, gnustep-gui, gnustep-back). Unpatched baseline: 18/32 passing.

### Benchmark Results (patched vs unpatched, retained state)

| Benchmark | Improvement |
|-----------|-------------|
| retain/release | +29-31% |
| message dispatch | +12-18% |
| array operations | +46-55% |
| NSCache set | +25% |
| autorelease pool churn (B6) | measured improvement, no regressions |

Historical baselines from reverted experiments (B1, B5.1, GSTinyString) live in `instrumentation/benchmarks/results/baseline_pre_*.jsonl` as an audit trail — they are not the current state.

## Getting Started

Clone the audit repo and all forks:

```bash
git clone https://github.com/DTW-Thalion/gnustep-audit.git
cd gnustep-audit

# The patched repos are subfolders (already cloned):
#   libobjc2/ libs-base/ libs-corebase/ libs-opal/
#   libs-quartzcore/ libs-gui/ libs-back/

# Or clone individual forks:
git clone https://github.com/DTW-Thalion/libobjc2.git
git clone https://github.com/DTW-Thalion/libs-base.git
# ... etc.
```

## Date

Audit performed: 2026-04-13. Post-review rationalization: 2026-04-13.
