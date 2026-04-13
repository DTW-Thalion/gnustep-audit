# Spike: Per-Class Method Cache Generation Counters (libobjc2)

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repo:** libobjc2 (DTW-Thalion fork, `gnustep-audit/libobjc2/` subfolder, branch `master`)

---

## 1. Current state

### 1.1 Declaration

The global counter is declared in `libobjc2/dtable.c:47`:

```c
#ifndef NO_SAFE_CACHING
__attribute__((aligned(64))) _Atomic(uint64_t) objc_method_cache_version;
#endif
```

- The `aligned(64)` attribute is already in place (audit task PF-5, per
  `docs/superpowers/plans/2026-04-12-fix-libobjc2.md:1259-1280`). Confirmed
  present in the current tree.
- The declaration is guarded by `NO_SAFE_CACHING`: on targets without
  64-bit atomics (notably `__powerpc__ && !__powerpc64__`, see
  `libobjc2/objc/slot.h:34-36`) there is no counter and all slots are
  uncacheable.
- The symbol is exported as `OBJC_PUBLIC` in the public header
  `libobjc2/objc/slot.h:36`:
  ```c
  OBJC_PUBLIC extern _Atomic(uint64_t) objc_method_cache_version;
  ```
  This makes it part of the libobjc2 public ABI surface.

### 1.2 Neighbors on the cache line

The alignment attribute isolates the variable to its own 64-byte line, so
false sharing is not a concern. The neighboring file-scope symbols in
`dtable.c` (all `PRIVATE`) are:

- `PRIVATE dtable_t uninstalled_dtable;` (`dtable.c:30`)
- `PRIVATE InitializingDtable *temporary_dtables;` (`dtable.c:39`)
- `PRIVATE mutex_t initialize_lock;` (`dtable.c:41`)
- `static uint32_t dtable_depth = 8;` (`dtable.c:44`)

With `aligned(64)` these cannot share the counter's cache line.

### 1.3 Write sites (increments)

Every write increments the global unconditionally. Two sites in `dtable.c`:

1. `dtable.c:410` - inside `installMethodInDtable` when `oldMethod != NULL`
   (i.e., a method replaced an existing method):
   ```c
   if (NULL != oldMethod)
   {
   #ifndef NO_SAFE_CACHING
       objc_method_cache_version++;
   #endif
   }
   ```
2. `dtable.c:528` - inside `objc_update_dtable_for_new_superclass`, after
   `rebaseDtableRecursive` rewires the dtable for a new superclass:
   ```c
   LOCK_RUNTIME_FOR_SCOPE();
   rebaseDtableRecursive(cls, newSuper);
   // Invalidate all caches after this operation.
   #ifndef NO_SAFE_CACHING
       objc_method_cache_version++;
   #endif
   ```

Callers that feed these paths (by code inspection):

- `objc_update_dtable_for_class` (`dtable.c:441`) and
  `add_method_list_to_class` (`dtable.c:534`) both call
  `installMethodsInClass` -> `installMethodInDtable`. They bump the
  counter only when a replacement occurs (not on first install of a
  never-before-seen selector).
- Category loading path flows through `add_method_list_to_class`.
- `class_replaceMethod` / `class_addMethod` (runtime API,
  implementation elsewhere - likely `runtime.c`, not re-read here) also
  end up at `installMethodInDtable`. **Unknown:** did not open
  `runtime.c` to confirm direct call chain; next step would be
  `rg -n installMethodInDtable libobjc2/` and tracing callers.
- KVO swizzling in GNUstep base calls `class_addMethod` /
  `class_replaceMethod`, which triggers path 1.

Notably, the global is **not** bumped on the "install a wholly new
method" path: only on replacement or on superclass rebase. Method
addition goes through a normal dtable insert with no version bump -
correctness relies on the caller having looked up via `objc_get_slot2`
after the selector first existed. This asymmetry matters for §2.

### 1.4 Read sites

Three in libobjc2:

1. `sendmsg2.c:100` - `objc_msg_lookup_internal` writes the current
   version into the caller's `*version` out-parameter before doing the
   dtable lookup. Called via `objc_slot_lookup_version`.
2. `sendmsg2.c:370` - same pattern inside `objc_get_slot2`.
3. `sendmsg2.c:127-131`, `146-149`, and similar branches - clear
   `*version = 0` when the slot is uncacheable (type mismatch, missing
   selector, forwarding, etc.).

Public consumers reading the symbol outside libobjc2 (searched across
the whole gnustep-audit tree, excluding docs):

- `libs-base/Source/NSKeyValueCoding+Caching.m:214` - reads the counter
  to stamp an ivar-based cache slot.
- `libs-base/Source/NSKeyValueCoding+Caching.m:445` - passes `version`
  out-param through `objc_get_slot2`.
- `libs-base/Source/NSKeyValueCoding+Caching.m:623` - compares
  `objc_method_cache_version != cachedSlot->version` in the hot KVC
  get path:
  ```c
  if (objc_method_cache_version != cachedSlot->version)
  {
      // ... re-lookup slot, memcpy into cachedSlot ...
  }
  ```

**No other consumer in the audited tree reads the counter.** Notably:

- `libs-gui`, `libs-back`, `libs-corebase`, `libs-opal`,
  `libs-quartzcore`: zero hits.
- `libs-base` outside `NSKeyValueCoding+Caching.m`: zero hits.

### 1.5 Fast-path behavior

**The counter is NOT read by the assembly fast path.** Verified by
reading `libobjc2/objc_msgSend.x86-64.S:1-60` and confirmed via
`rg 'cache_version|method_cache' libobjc2/*.S` returning zero matches
across all architectures (`objc_msgSend.S`, `.x86-64.S`, `.x86-32.S`,
`.aarch64.S`, `.arm.S`, `.mips.S`, `.riscv64.S`).

The asm fast path loads the dtable from `isa->dtable` at
`DTABLE_OFFSET` (`objc_msgSend.x86-64.S:35,37`), walks the sparse array
(`SHIFT_OFFSET`/`DATA_OFFSET`, lines 41-56), and dereferences
`SLOT_OFFSET(%r10)` (line 60) to get the IMP. There is **no
per-callsite cached IMP stored in-line** - every dispatch goes through
the dtable. The dtable is mutated in place, so a method replacement
is visible to subsequent dispatches as soon as the writer has updated
the sparse array entry.

In other words: **the fast path has no "cache" to invalidate.** The
`objc_method_cache_version` global only exists to serve the higher-level
`objc_slot_lookup_version` / `objc_get_slot2` API, whose contract is
"if you save this version alongside the slot and re-check later, you
may skip the dtable lookup." The only consumer exploiting that contract
in the whole gnustep tree is the KVC cache in libs-base.

This dramatically narrows the problem. The "cache storm" described in
`phase1-libobjc2-findings.md` and `phase6-optimization-deep-dive.md`
affects exactly one cache: the KVC slot cache in libs-base.

### 1.6 struct objc_class layout

Internal definition in `libobjc2/class.h:45-142`. Fields in order:

| off (64-bit Unix) | field |
|---|---|
| 0 | `Class isa` |
| 8 | `Class super_class` |
| 16 | `const char *name` |
| 24 | `long version` |
| 32 | `unsigned long info` |
| 40 | `long instance_size` |
| 48 | `struct objc_ivar_list *ivars` |
| 56 | `struct objc_method_list *methods` |
| 64 | `void *dtable` |
| 72 | `Class subclass_list` |
| 80 | `IMP cxx_construct` |
| 88 | `IMP cxx_destruct` |
| 96 | `Class sibling_class` |
| 104 | `struct objc_protocol_list *protocols` |
| 112 | `struct reference_list *extra_data` |
| 120 | `long abi_version` |
| 128 | `struct objc_property_list *properties` |

`DTABLE_OFFSET` is asserted in `dtable.c:17-18` and hardcoded per-arch
in `asmconstants.h:1-20` (64 Unix, 56 Win64, 32 on 32-bit).

- No existing slot for a per-class cache generation counter.
- `abi_version` and `properties` are the current tail.
- The struct is emitted by the **Objective-C compiler** (clang) for
  every class definition, so its layout is part of the compiler/runtime
  contract, not purely internal. Confirmed: the gsv1 legacy class
  (`struct objc_class_gsv1`, `class.h:144-275`) and the GCC-compat
  class (`struct objc_class_gcc`, `class.h:283-298`) must stay
  bit-compatible with what older compilers emit.

The public header `libobjc2/objc/runtime.h` exposes `Class` as an
opaque pointer type; user code accesses fields only through accessor
functions (`class_getName`, etc.). **So the layout is not in the
public C header**, but clang's codegen bakes the layout into object
files it emits for `@implementation`. This matters for §3.

---

## 2. Proposed change

### 2.1 New field

Append to the tail of `struct objc_class` in `libobjc2/class.h` (after
`properties`):

```c
/**
 * Per-class cache generation counter. Incremented whenever a method
 * on this class (or a class it inherits from) is replaced. Used by
 * higher-level slot-caching APIs (objc_get_slot2,
 * objc_slot_lookup_version) to invalidate only the slots that
 * actually target this class.
 */
_Atomic(uint64_t) cache_generation;
```

Offset on 64-bit Unix: 136. No change to `DTABLE_OFFSET` and no asm
impact (fast path does not read the new field). `asmconstants.h` does
**not** need updating because only `DTABLE_OFFSET`, `SHIFT_OFFSET`,
`DATA_OFFSET`, and `SLOT_OFFSET` are referenced there, and none of them
move.

Compiler-emitted class objects from existing `.o` files have zero
trailing bytes for any field the runtime adds at the tail (they use the
old struct size); this is how libobjc2 already extends the class
struct across versions. Confirmed by the existing pattern of
`abi_version` and `properties` having been added post-hoc (they sit
after the gsv1 tail).

**Important caveat:** libobjc2 reads fields past the compiler-emitted
tail only after explicit runtime initialization. The runtime must
initialize `cache_generation = 0` during class load / resolution.
Search target for the implementation plan: `objc_load_class` in
`loader.c` or `class_table.c`.

### 2.2 Invalidation policy

A per-class bump happens only at the two existing write sites:

1. `dtable.c:410` (method replacement in `installMethodInDtable`) -
   change from global increment to:
   ```c
   atomic_fetch_add_explicit(&class->cache_generation, 1,
                             memory_order_release);
   ```
   **Subclass propagation:** because the replacement is also recursively
   installed into every subclass's dtable (`dtable.c:391-404`), the
   counter must also be bumped on each subclass that has a dtable. The
   existing recursion loop is the natural place.

2. `dtable.c:528` (superclass rebase) - bump `cls->cache_generation`
   and recurse through subclasses in `rebaseDtableRecursive`.

Events that flow through these sites:
- `class_replaceMethod` / `class_addMethod` replacing an existing
  method -> path 1. (KVO install lands here.)
- Category loading that overrides an inherited method -> path 1 (the
  replacement path in `installMethodInDtable`).
- `class_setSuperclass` / related rewiring -> path 2.

Events that *currently* do not bump the global and should continue not
bumping per-class:
- First-time install of a wholly new method. No slot could have been
  cached for it (version stamp from a call that returned NULL slot is
  already 0 / uncacheable per `sendmsg2.c:127-131`).

### 2.3 Fast path

**No change.** The asm fast path does not read the version counter,
and that remains true after this spike. The entire change is confined
to the C slot-lookup path and the invalidation sites.

### 2.4 New slot API contract

`objc_get_slot2(Class cls, SEL sel, uint64_t *version)` and
`objc_slot_lookup_version(...)` currently write the global version
into `*version`. New contract: they write
`cls->cache_generation` (for `objc_get_slot2`) or
`classForObject(*receiver)->cache_generation` (for
`objc_slot_lookup_version`). Consumers compare the saved value against
**the cache_generation of the class the slot was originally resolved
against** - which the consumer already stores (the KVC
`_KVCCacheSlot` struct in `libs-base/Source/NSKeyValueCoding+Caching.m:39`
records `Class cls`).

Concretely, libs-base becomes:

```c
// was: if (objc_method_cache_version != cachedSlot->version)
if (atomic_load_explicit(&cachedSlot->cls->cache_generation,
                         memory_order_acquire) != cachedSlot->version)
```

### 2.5 Transitional strategy

**Recommended: dual-counter, phased.**

Phase A (libobjc2 only, no consumer changes):
- Add `cache_generation` field to `struct objc_class`.
- Bump per-class counters at the two write sites **in addition to**
  the global `objc_method_cache_version++`.
- `objc_get_slot2` continues writing the global counter to `*version`
  to preserve behavior for all existing consumers.
- Export a new API `uint64_t objc_class_cache_generation_np(Class)`
  (or a `version2` out-parameter variant of `objc_get_slot2`) so new
  consumers can opt in.
- Effect: zero behavior change for libs-base until it opts in. Adds
  one atomic increment per method replacement - negligible (method
  replacement is rare).

Phase B (libs-base opt-in):
- Port `NSKeyValueCoding+Caching.m` to read
  `cachedSlot->cls->cache_generation` instead of the global.
- Keep the global in the header as deprecated-but-present so any
  out-of-tree consumer still compiles and links.

Phase C (optional, later):
- Remove the global once we are comfortable with ABI break. Or leave
  it forever as a frozen symbol - the cost is one atomic increment
  on the (already slow) method-replacement path.

This lets us land the new mechanism and get the KVC win without any
ABI break at all.

### 2.6 Alternative: atomic cutover (not recommended)

Remove the global and require libs-base to be rebuilt in lockstep.
Rejected because (a) the dual-counter overhead is zero-cost on the
hot path, (b) we want to ship the libobjc2 change independently of
the libs-base change, and (c) out-of-tree consumers (GNUstep apps
built against the published libobjc2 headers) may read the symbol.

---

## 3. ABI impact

### 3.1 Public header surface

- `objc/slot.h:36` declares `objc_method_cache_version` as
  `OBJC_PUBLIC extern`. Removing it would be an ABI break. The
  transitional strategy keeps it.
- `objc/runtime.h:977,987` declares `objc_get_slot2` and
  `objc_slot_lookup_version`. Their signatures do not change; only
  the semantics of what they write into `*version` change under
  phase B. Source and binary compatible at the C level. Consumer
  behavior is preserved because consumers only ever compare the
  stamp to the value they wrote and the value the runtime now writes
  (per-class) - they do not compare to the global.
  - **Footgun:** a consumer that stores a version from
    `objc_get_slot2` and compares against the *global*
    `objc_method_cache_version` will incorrectly think its slot is
    always stale. The libs-base code at
    `NSKeyValueCoding+Caching.m:214,623` does exactly this
    cross-comparison, so a naive semantic switch would break libs-base
    silently. **This is the main reason the transitional strategy
    must be phased, not atomic.**

### 3.2 struct objc_class layout

- `struct objc_class` is not directly defined in any public header
  (`objc/runtime.h` treats `Class` as opaque), so adding a tail field
  is not a source-compat break for well-behaved consumers.
- The layout is, however, part of the compiler/runtime contract:
  clang's Objective-C codegen emits class structures with exactly the
  fields described in `libobjc2/class.h:46-141`. Adding a tail field
  is safe because:
  - Compiler-emitted `.o` files produce class structures of the old
    size. The runtime allocates and zeroes the new field during class
    load/resolution.
  - No existing field moves, so existing consumers that access fields
    by offset continue to work.
- Binary compat: existing `libs-base.dll` / `libgnustep-base.so` will
  keep working against the new libobjc2, because they never read past
  `properties`. New libs-base builds see the new field.
- `abi_version` field in `struct objc_class` (`class.h:136`) could be
  bumped to signal "cache_generation present," but the runtime can
  also just always initialize it to 0 on every loaded class, which is
  simpler. Recommend not touching `abi_version`.

### 3.3 Consumers needing rebuild

Only consumers that want the per-class benefit:

- **libs-base**: must rebuild after phase B change to
  `NSKeyValueCoding+Caching.m`. Otherwise unaffected.
- **libs-gui, libs-back, libs-corebase, libs-opal, libs-quartzcore**:
  no code references the cache version. Zero rebuild required for
  correctness; they pick up the improvement transparently once
  libs-base is upgraded (since they dispatch through libs-base's KVC
  cache).

### 3.4 asmconstants.h

No update needed. Confirmed: only `DTABLE_OFFSET`, `SHIFT_OFFSET`,
`DATA_OFFSET`, `SLOT_OFFSET` are defined (`asmconstants.h:1-20`), and
`dtable.c:17-28` only asserts these four. The new tail field does
not affect any of them.

### 3.5 .so / DLL version bump

**Determination:** `libobjc2/CMakeLists.txt:36` defines
`set(libobjc_VERSION 4.6)`, and line 292 applies this to the
`objc` target as both `VERSION` and `SOVERSION ${libobjc_VERSION}`
via `set_target_properties`. The current SOVERSION is therefore
**4.6** (the `libobjc.so.4.6` / `objc.dll` import-lib soname).
Under the dual-counter strategy we export exactly one new
`OBJC_PUBLIC` symbol (`objc_class_cache_generation_np` or similar)
and append one tail field to the already-opaque `struct objc_class`;
no existing symbol is removed, renamed, or changes signature, and
because the struct is opaque to consumers (only runtime-internal
code accesses fields by offset) the layout change is not an ABI
break for external callers. Per standard semver-for-soname
policy, adding a symbol without removing any is a **minor bump**:
old binaries linked against 4.6 continue to resolve all their
imports against 4.7, while new binaries that reference the new
getter simply fail to link against an older 4.6 runtime (the
correct and expected behavior). A major SOVERSION bump would
only be required if we removed/renamed a symbol or changed a
public struct's visible layout. Resulting new version string:
**`libobjc_VERSION 4.7`** (soname `libobjc.so.4.7`).

---

## 4. Performance estimate

### 4.1 Baseline cache-storm scenario

The target workload is KVO installation followed by KVC-driven
property reads. KVO on GNUstep base installs new methods via
`class_addMethod` / `class_replaceMethod`, which lands at
`dtable.c:410` and increments the global counter. Every subsequent
KVC `valueForKey:` call checks
`objc_method_cache_version != cachedSlot->version`
(`NSKeyValueCoding+Caching.m:623`), sees a mismatch, and re-runs the
full `ValueForKeyLookup` - which iterates prefix variants, calls
`objc_get_slot2`, and updates the cache under a mutex.

So the storm is: `N` cached KVC slots, one unrelated KVO install ->
next `N` KVC reads all take the slow path (mutex, lookup, memcpy).
With typical AppKit scroll / tableview reload patterns, `N` can easily
be dozens to hundreds of distinct `(class, key)` pairs. Every KVO
observer add on any class flushes all of them.

### 4.2 Expected win

For the KVC cache hot path:

- **Steady state (no method mutation):** unchanged. Atomic load +
  compare of per-class counter is the same instruction count as the
  current global-counter check.
- **KVO install affecting an unrelated class:** current code
  re-runs `N` full lookups under lock. Per-class version means *zero*
  lookups re-run (all `N` cached slots point to classes the KVO did
  not touch). This is the main win.
- **KVO install affecting the same class being KVC-read:** no
  change. The slot legitimately needs re-resolution.

Magnitude: on a workload that installs one KVO observer per frame
while scrolling a 60-row table view that KVC-reads 4 keys per row,
we currently invalidate ~240 slots per frame -> 240 full KVC slow
paths. Per-class reduces that to 0 if the observed object is distinct
from the rows' class. Expected order-of-magnitude: **50-200x** on
the post-storm KVC burst, collapsing to "within noise" on the
steady-state case where there are no storms.

Whole-app win is bounded by how much of the app is actually going
through the KVC cache during storms. On a GNUstep text-editor
workload this is probably <5% of CPU. On a Cocoa-style
KVO-heavy MVC app it could be 10-30%.

### 4.3 Benchmark

No existing benchmark covers this. Closest existing:

- `instrumentation/benchmarks/bench_msg_send.m` - measures cold and
  warm dispatch throughput of `objc_msgSend`. Does **not** touch the
  KVC cache or exercise cache invalidation. Not useful as-is for this
  change.

**Missing benchmark to add** (part of the follow-up plan, not this
spike): `bench_kvc_cache_storm.m`. Shape:

1. Set up `K` classes each with a property `value`.
2. Instantiate `N` objects, populate a KVC cache by reading each
   object's `value` once.
3. Measure baseline: repeat KVC read across all objects, record
   ns/op.
4. Trigger a storm: `class_addMethod` on a wholly unrelated class.
5. Measure post-storm: repeat KVC reads, record ns/op.
6. Report baseline vs post-storm ratio. With the current global
   counter, step 6 should show a large ratio (cold re-lookup under
   lock). With per-class, the ratio should be ~1.0.

Parameters to sweep: `K` (1, 10, 100), `N` (100, 1000), storm
frequency (every read, every 10 reads, every 100 reads).

---

## 5. Risk

### 5.1 Correctness

Moderate-low. The change is confined to:
- Two write sites in `dtable.c`.
- The `*version` out-parameter path in `sendmsg2.c` (`objc_get_slot2`
  and `objc_msg_lookup_internal`).
- One consumer (`NSKeyValueCoding+Caching.m`).

The fast path is untouched, so there is no risk of random
wrong-method dispatch - the worst failure mode is the KVC cache
returning a stale IMP *once*, which was already the failure mode of
the existing code and is why the version check exists.

The main correctness trap: subclass propagation. When
`installMethodInDtable` recursively installs a replacement into
subclass dtables (`dtable.c:391-404`), we must bump each subclass's
`cache_generation` too, otherwise a KVC slot cached for a subclass
(via `objc_get_slot2(subclass, sel, ...)`) stamped with the
subclass's old generation would not notice that the inherited slot
has been replaced. This must be covered by a specific test (see §6).

### 5.2 ABI break blast radius

Under the transitional strategy: essentially zero. The global symbol
remains exported and maintained; new field is at struct tail; no
function signature changes.

Under atomic cutover (not recommended): high. Any out-of-tree consumer
reading the global would silently stop working at phase B. Not worth
the risk.

### 5.3 Rollback

Very cheap under the dual-counter strategy: revert the libobjc2
patch. Any libs-base that opted into phase B keeps working because
the global counter is still being maintained. A libs-base-only revert
is a one-file git revert.

### 5.4 Thread safety

The current global is `_Atomic(uint64_t)`. Reads and writes use C11
atomics (`sendmsg2.c:100,370` are plain loads which for `_Atomic`
imply `memory_order_seq_cst`; `dtable.c:410,528` are plain increments
which also imply `seq_cst`). The per-class field must preserve at
least release/acquire semantics across the
"install method, then bump counter" -> "check counter, then read
slot" pair. Recommended:

- Writer: `atomic_fetch_add_explicit(&cls->cache_generation, 1,
  memory_order_release)` **after** the SparseArray insert (not before).
- Reader: `atomic_load_explicit(&cls->cache_generation,
  memory_order_acquire)` before reading the cached IMP.

This is strictly weaker than the current seq_cst and is correct for
the pattern. If we want to be conservative, keep seq_cst everywhere;
the cost is negligible since method replacement is rare.

The two existing write sites already hold `LOCK_RUNTIME_FOR_SCOPE()`
(`dtable.c:446,524`), so writer-writer races are impossible.
Reader-writer races are the same as today.

---

## 6. Test strategy

### 6.1 Existing tests

In `libobjc2/Test/`:

- `Category.m` - verifies that a category-added method overrides the
  original class method (`[Foo replaced] == 2`). Exercises
  `add_method_list_to_class` -> `installMethodInDtable` with
  replacement. This is the closest existing test to our change path
  but does not cover the slot-version contract.
- `AllocatePair.m`, `RuntimeTest.m` - exercise runtime class creation
  / method installation APIs. Will not catch version-counter bugs
  because they do not consume `objc_get_slot2`'s `*version` output.
- No existing test in `libobjc2/Test/` calls
  `objc_slot_lookup_version` or `objc_get_slot2` and compares the
  returned version. **Unknown whether any other GNUstep test suite
  does; not searched beyond libs-base, which does cover it via KVC.**

In `libs-base` test suite: KVC tests exist under
`libs-base/Tests/base/KVC/` (not opened in this spike). These will
transitively catch the libs-base side of the change once phase B
lands. Next step: enumerate those tests.

### 6.2 New tests needed

Add to `libobjc2/Test/`:

1. `CacheGenerationBasic.m` - class `A` with method `-m`. Resolve
   slot, record its generation. Call `class_replaceMethod(A, -m)`.
   Verify `cls->cache_generation` (or the out-param value from a
   fresh `objc_get_slot2` call) changed.
2. `CacheGenerationSubclass.m` - class `A`, subclass `B`. Resolve
   slot on `B` for inherited `-m`, record `B`'s generation. Replace
   `-m` on `A`. Verify `B`'s generation also changed (tests subclass
   propagation in `installMethodInDtable`).
3. `CacheGenerationUnrelated.m` - classes `A` and `X` (unrelated
   hierarchies). Record `A`'s generation. Replace a method on `X`.
   Verify `A`'s generation is **unchanged** - this is the whole
   point of the change. A regression here would mean we collapsed
   back to global semantics.
4. `CacheGenerationSuperclass.m` - trigger
   `objc_update_dtable_for_new_superclass` (via `class_setSuperclass`
   or equivalent). Verify affected class and its subclasses see
   generation bumps.

For libs-base (phase B): extend existing KVC tests to assert that
after `class_addMethod` on an unrelated class, the cached KVC slot
for the original class is **not** re-resolved. This can be measured
by instrumenting the slot cache or via a timing assertion.

### 6.3 Benchmark before/after

See §4.3. Create `bench_kvc_cache_storm.m` under
`instrumentation/benchmarks/`. Metric: post-storm KVC read ns/op
normalized to baseline KVC read ns/op. Expected: ratio ~= 1.0
after change, ratio >> 1.0 before.

Report shape: baseline JSON committed under
`instrumentation/benchmarks/results/baseline-YYYY-MM-DD.json`
matching existing convention (`baseline-2026-04-12.json`).

---

## 7. Decision

**NEEDS-DISCUSSION**, leaning GO.

Rationale: the spike surfaced a fact that reframes the problem. The
`objc_method_cache_version` counter is **not** in the fast path - the
asm dispatchers do not read it, and the only real consumer of the
slot-version contract in the entire gnustep-audit tree is the KVC
cache in `libs-base/Source/NSKeyValueCoding+Caching.m`. The
"system-wide cache storm" described in Phase 1 findings is actually
"KVC cache storm in libs-base on KVO install." That is still worth
fixing - KVC is a hot path in AppKit-style workloads, and the fix is
genuinely cheap under the proposed dual-counter transitional strategy
(tail-append one atomic field, bump it at two existing sites, no
fast-path change, no ABI break) - but it is materially smaller in
scope than the original framing suggested.

The discussion the audit team needs to have before a plan is written:

1. **Is fixing only the KVC cache worth the libobjc2 ABI extension?**
   An alternative is to sidestep libobjc2 entirely: libs-base could
   own its own per-class generation tracking (a weak hash map
   keyed by `Class`, bumped from a libobjc2 runtime hook if one is
   available, or via wrapping `class_addMethod` /
   `class_replaceMethod`). This keeps libobjc2 unchanged. The cost
   is that the libs-base-side map needs its own maintenance and a
   hook into method mutation. **Worth costing.**

2. **Dual-counter phase A vs atomic cutover.** Phase A is safer but
   carries the global counter around forever. If the audit team is
   comfortable declaring a libobjc2 minor version bump with
   coordinated libs-base rebuild, atomic cutover is slightly cleaner.
   I recommend phase A.

3. **Benchmark baseline.** We should land the `bench_kvc_cache_storm`
   benchmark **first**, on `main`, to confirm the storm is measurable
   on this workload at all before committing to the runtime change.
   If the baseline shows the storm is not measurable in practice,
   this spike should flip to NO-GO.

If the team answers (1) "yes, runtime change is OK", (2) "phase A",
and (3) "benchmark lands first and confirms the problem," the
decision becomes GO and a follow-up implementation plan can be
written against this design.

### Known unknowns (next investigation steps)

- Chain of callers from `class_addMethod` / `class_replaceMethod` to
  `installMethodInDtable`. Next step: `rg -n installMethodInDtable
  libobjc2/` and trace.
- libobjc2 SOVERSION / DLL version scheme. Next step: read
  `libobjc2/CMakeLists.txt`.
- Whether any libs-base test currently exercises the KVC-cache
  invalidation path. Next step: enumerate
  `libs-base/Tests/base/KVC/`.
- aarch64 / riscv64 asm: spot-checked via rg to confirm zero matches
  for `cache_version`, but did not read the full `.S` files.
  Confident the fast path is uniform across arches but would want
  to eyeball `objc_msgSend.aarch64.S` before landing.
- Class-load code path that would zero-initialize the new field.
  Suspect `objc_load_class` in `loader.c`; not verified.
