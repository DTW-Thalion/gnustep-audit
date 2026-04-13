# Spike: NSZone Removal or Compatibility Shim (libs-base)

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repo:** libs-base

## 1. Current state

### 1.1 NSZone.m is real zone machinery, not a shim

`libs-base/Source/NSZone.m` is a 1859-line hand-written allocator from 1997
(original author Yoo C. Chung, rewritten by Richard Frith-Macdonald). It is
*not* a thin wrapper over `malloc`. The file contains two distinct allocator
implementations plus a default-zone vtable:

- **Default zone** (`default_malloc` / `default_realloc` / `default_free`,
  `NSZone.m:161-235`) is the only path that truly delegates to libc
  `malloc`/`free`. It is the zone returned by `NSDefaultMallocZone()`
  (`NSZone.m:1795-1798`) and backs all allocation when the caller passes
  `NULL` or does not create a custom zone.
- **Non-freeable ("nfree") zone.** Forward declarations and supporting
  code run from `NSZone.m:520-527` and continue in the ~530 range; the
  nonfreeable zone section ends around `NSZone.m:527` before the ffree
  body begins. Calls to `free` on an nfree zone only decrement a use-count;
  memory is returned to the system only when the whole zone is recycled.
  Worst-fit allocation. The nfree vtable wiring is visible at
  `NSZone.m:1721-1754`.
- **Freeable ("ffree") zone** (body begins ~`NSZone.m:560` and runs through
  ~`NSZone.m:1500`), used when `NSCreateZone(start, gran, YES)` is called.
  Implements a segregated-fit allocator with `MAX_SEG` segregated free
  lists, an `add_buf` deferred-free buffer, per-chunk headers (`ff_block`),
  block coalescing, and recursive per-zone mutexes (`zone->lock`). Chunk
  header layout and block trailer setup are visible at
  `NSZone.m:1698-1716`. Note: the file is **not** a single continuous
  block from line 530 onward — the nonfreeable zone ends ~527 and the
  freeable zone begins ~560.
- `rmalloc` (`NSZone.m:1602`) is a post-recycle stub wired in at
  `NSZone.m:818` and `NSZone.m:1445` that raises `NSMallocException` when
  anyone tries to allocate out of a recycled zone.

This is genuinely several thousand lines of live allocator code, with its own
synchronization (`GS_MUTEX_INIT_RECURSIVE(zone->lock)` at `NSZone.m:1683`,
global `zoneLock` around the `zone_list` linked list). It is *not*
"already a no-op shim like Apple Foundation."

### 1.2 Modern runtime (gnustep-2.0 / libobjc2) already bypasses it

`NSAllocateObject` (`NSObject.m:823-864`) has a compile-time split:

```
#ifdef OBJC_CAP_ARC
  new = class_createInstance(aClass, extraBytes);   /* zone ignored */
#else
  ...
  new = NSZoneMalloc(zone, size);                   /* legacy path */
#endif
```

On our build (MSYS2 ucrt64 + gnustep-2.0 / libobjc2, which defines
`OBJC_CAP_ARC`), *every* object allocation already goes through
`class_createInstance` and the `zone` argument is silently dropped. The
custom ffree/nfree allocators in NSZone.m are therefore unreachable from
normal object allocation today. They can still be reached via explicit
`NSZoneMalloc(NSCreateZone(...), n)` calls, but essentially nothing in the
tree does this — see §1.4.

### 1.3 Public API surface (NSZone.h)

`Foundation/NSZone.h` is 254 lines. Public (`GS_EXPORT`) symbols:

- `NSCreateZone` (`NSZone.h:53-54`)
- `NSDefaultMallocZone` (`NSZone.h:59-60`)
- `NSZoneFromPointer` (`NSZone.h:68-69`)
- `NSZoneMalloc` (`NSZone.h:81-82`)
- `NSZoneCalloc` (`NSZone.h:94-95`)
- `NSZoneRealloc` (`NSZone.h:105-106`)
- `NSRecycleZone` (`NSZone.h:116-117`)
- `NSZoneFree` (`NSZone.h:127-128`)
- `NSSetZoneName` (`NSZone.h:133-134`)
- `NSZoneName` (`NSZone.h:139-140`)
- `NSZoneCheck`, `NSZoneStats` (GS-only, `NSZone.h:147-185`)
- `NSAllocateCollectable` / `NSReallocateCollectable` (`NSZone.h:239,246`)
- `GSOutOfMemory` (`NSZone.h:193`)
- `NSPageSize` / `NSAllocateMemoryPages` etc. (`NSZone.h:198-219`) — these
  are page allocators, *not* zone APIs, and are out of scope.

**Critical ABI observation:** `struct _NSZone` is **opaque** in the public
header (`NSZone.h:32`: `typedef struct _NSZone NSZone;`). The full struct
definition lives only in `NSZone.m:120-134` (function-pointer vtable plus
`gran`, `name`, `next`). No public header exposes layout. This means the
struct contents can be freely changed or replaced without breaking
downstream compile or link compatibility, *provided* the typedef name and
the opaque pointer survive. Contrast with B3 (dtable), where the struct was
effectively leaked through public-ish headers and layout changes had massive
blast radius. B7 does **not** have the B3 problem.

### 1.4 Internal libs-base call sites

`rg -c '(NSZoneMalloc|NSZoneFree|NSZoneCalloc|NSZoneRealloc|NSDefaultMallocZone|NSZoneFromPointer|NSCreateZone|NSRecycleZone|NSZoneName|NSSetZoneName)' libs-base/Source/` returns **784 occurrences across 107 files**. The top
offenders:

- `Source/GSString.m` — 75
- `Source/NSData.m` — 65
- `Source/NSString.m` — 66
- `Source/NSValue.m` — 24
- `Source/NSArray.m` — 19
- `Source/NSDictionary.m` — 19
- `Source/GSMime.m` — 19
- `Source/NSPropertyList.m` — 17

These are overwhelmingly `NSZoneMalloc(...)` / `NSZoneFree(...)` for
internal buffers (string storage, array backing stores, format scratch
space), almost always passing `[self zone]` or `NSDefaultMallocZone()` or
`0`. None of them actually depend on sub-allocator semantics — they are
idiomatic 1990s GNUstep "pass a zone through in case someone cares" code.

`+allocWithZone:` overrides: `rg '^\+ \(id\) ?allocWithZone:'` returns 57
files. Spot-checked examples (`NSArray.m`, `NSString.m`, `NSDictionary.m`)
all forward to `NSAllocateObject(self, 0, z)` or to a class cluster placeholder,
which in turn (on OBJC_CAP_ARC) ignores `z`. There are **no** overrides
that inspect the zone pointer or perform zone-specific allocation.

### 1.5 `-zone` and `+zone` on NSObject

`NSObject.m:2236-2244`:

```objc
- (NSZone*) zone { return NSZoneFromPointer(self); }
+ (NSZone*) zone { return NSDefaultMallocZone(); }
```

`NSZoneFromPointer` walks the `zone_list` calling each zone's `lookup`
function and falls back to `&default_zone` if none claims the pointer
(`NSZone.m:1620-1647`). With no custom zones ever created in practice (see
§1.6), `-zone` is a guaranteed-return of `&default_zone` — a global static
sentinel.

`[self zone]` is called in ~40 internal sites, almost all of the form
`NSZoneMalloc([self zone], n)`. It is also called from **libs-back** and
**libs-gui** (see §3).

### 1.6 External call-site survey

| Repo            | `NSZone*` API calls (non-ChangeLog) | `+allocWithZone:` overrides |
|-----------------|-------------------------------------|------------------------------|
| libs-gui        | ~120 refs across ~80 files          | many (GMAppKit.m:8, NSCell, NSView, …) |
| libs-back       | ~30 refs (CairoGState.m, GSContext.m, XGDragView.m, XGServerWindow.m, WIN32Server.m, xpbs.m) | a few |
| libs-corebase   | 0                                   | 0 |
| libs-opal       | 1 (OPFontDescriptor.m)              | 0 substantive |
| libs-quartzcore | 1 (CAAnimation.m)                   | 0 substantive |

Representative libs-back callers that *pass non-default zones*:

- `libs-back/Source/gsc/GSContext.m:204-206`: `NSZoneMalloc(z, sizeof(GSIArray_t))` where `z = [self zone]`.
- `libs-back/Source/x11/XGDragView.m:147`: `NSZoneMalloc(zone, (count+1)*sizeof(Atom))`.
- `libs-back/Source/x11/XGServerWindow.m:2251`: `NSZoneFree(0, window)`.

Every inspected external site is "threading the zone through for OpenStep
politeness"; none depend on sub-allocator behavior. But they *do* depend on
the symbols `NSZoneMalloc` / `NSZoneFree` / `NSDefaultMallocZone` /
`-zone` / `+allocWithZone:` continuing to exist and work.

### 1.7 No custom-zone code anywhere

`rg -n 'NSCreateZone\s*\(' libs-base libs-gui libs-back libs-corebase libs-opal libs-quartzcore` — searched; zero call sites outside NSZone.m itself. **Nobody in our tree actually creates a zone.** The segregated-fit and nonfreeable allocators in NSZone.m (~1100 lines of the 1859-line file) are dead code in practice.

### 1.8 Binary-size baseline

`Source/obj/libgnustep-base.obj/NSZone.m.o` = **45,482 bytes** (clang -O2,
ucrt64 build). For scale, `NSObject.m.o` = 105,624 bytes. A pure shim
rewrite would likely land around 4-6 KB (roughly 1/10 of current), saving
~40 KB of .text in libgnustep-base.dll. This is real but not dramatic.

### 1.9 Tests

`libs-base/Tests/base/` has no `NSZone/` directory. There is no dedicated
test suite for NSZone APIs. NSObject tests indirectly cover `+allocWithZone:`
via any normal `alloc`/`init` path, but do not exercise `NSCreateZone`,
`NSRecycleZone`, or zone-scoped `NSZoneMalloc` rings. Coverage is thin.

## 2. Proposed change

**Option A: Compatibility shim.** Replace the freeable/nonfreeable allocator
code in `NSZone.m` with trivial forwards to `malloc`/`calloc`/`realloc`/
`free`. Concretely:

1. Keep `struct _NSZone` as an internal type, unchanged in name. Keep one
   static `default_zone` instance as the sentinel returned by
   `NSDefaultMallocZone()`.
2. Rewrite `NSCreateZone` to `malloc(sizeof(NSZone))`, fill in the vtable
   with the same `default_malloc`/`default_realloc`/`default_free` function
   pointers used by `default_zone`, push onto `zone_list`, return it. This
   keeps `NSCreateZone() != NULL` (required by any caller that null-checks
   the result) and keeps `NSZoneFromPointer` functional enough to return a
   non-NULL zone.
3. `NSRecycleZone` becomes: if zone == `&default_zone`, raise (preserve
   current behavior at `NSZone.m:200-202`); otherwise remove from
   `zone_list` and `free(zone)`. Memory allocated via that zone is **not**
   tracked or reclaimed — same semantics as Apple Foundation today.
4. `NSZoneMalloc` / `NSZoneCalloc` / `NSZoneRealloc` / `NSZoneFree` become
   direct `malloc`/`calloc`/`realloc`/`free` calls. The `zone` argument is
   accepted and ignored (except for a NULL check that substitutes the
   default sentinel, preserving current `NSZone.m:1809-1810` behavior).
5. `NSZoneFromPointer` unconditionally returns `&default_zone`. This matches
   the fact that on OBJC_CAP_ARC there is no per-object zone tracking
   anyway.
6. `NSSetZoneName` / `NSZoneName` keep working against the `name` field in
   the opaque struct. Debuggers that format zone names continue to work.
7. `NSZoneCheck` returns `YES`. `NSZoneStats` returns a zeroed struct.
8. `+allocWithZone:` and `-zone` are **not** removed. Every override stays.
   `-zone` returns `&default_zone`. `+allocWithZone:` continues to call
   `NSAllocateObject`, which already ignores `zone` on OBJC_CAP_ARC.

**Rejected alternatives:**

- **Option B (internal cleanup, rip out ~784 internal NSZoneMalloc calls):**
  high-churn mechanical refactor touching 107 files with no behavior change
  under Option A — Option A subsumes it at runtime. Not worth the diff noise.
- **Option C (partial API removal of `NSCreateZone`/`NSRecycleZone`/
  `NSZoneFromPointer`):** `NSCreateZone` is unused by our tree, but
  removing a public `GS_EXPORT` symbol is a **SOVERSION major bump** per B1
  §3.5 rules (any symbol removal = MAJOR). Cost not justified for three
  symbols; keep them as shims.
- **Full removal of `+allocWithZone:`:** libobjc2 `fast_paths.m:36-50`
  (`objc_allocWithZone`) calls `[cls allocWithZone: NULL]` as its ultimate
  fallback path, and the dtable trivial-alloc optimization in
  `libobjc2/dtable.c:88-124` explicitly keys on overrides of `alloc` /
  `allocWithZone:`. Removing the selector from NSObject would break ARC
  codegen and the fast-path machinery runtime-wide. **Do not touch.**

## 3. ABI impact

Option A's changes, evaluated against libgnustep-base SOVERSION rules (cf.
B1 §3.5: symbol removal / public-struct layout change = MAJOR; additive =
MINOR; pure internal = zero):

| Change                                    | Kind      | ABI impact |
|-------------------------------------------|-----------|------------|
| `struct _NSZone` layout changed            | Internal — struct is opaque in `NSZone.h:32` | **Zero**. No public header exposes layout. |
| `NSZoneMalloc`/`Free`/`Calloc`/`Realloc`   | Impl change, same signature | **Zero**. |
| `NSCreateZone`, `NSRecycleZone`            | Impl change, semantics relaxed (no sub-allocator, no refcount) | **Zero** at symbol level. Behavioral (§5). |
| `NSDefaultMallocZone`, `NSZoneFromPointer` | Impl change, still returns non-NULL sentinel | **Zero**. |
| `NSZoneName`, `NSSetZoneName`              | Unchanged | **Zero**. |
| `NSZoneCheck`, `NSZoneStats`               | Neutered but still exported | **Zero**. |
| `+allocWithZone:`, `-zone` on NSObject     | Unchanged | **Zero**. |
| `NSAllocateObject`                         | Unchanged (already ignores zone on OBJC_CAP_ARC per `NSObject.m:828`) | **Zero**. |

**No SOVERSION bump required.** Every exported symbol from NSZone.h
remains live with a compatible signature. This is the critical difference
from B3: B3 changed a struct that callers were reaching into via macros, so
the effective ABI was leaked. Here the struct has been opaque since 1997
and nothing downstream reaches into it.

**Downstream caller verification** — grepped libs-gui, libs-back,
libs-corebase, libs-opal, libs-quartzcore for any direct struct field
access (`->malloc`, `->realloc`, `->free`, `->recycle`, `->check`,
`->lookup`, `->stats`, `->gran`, `->name`, `->next` on an `NSZone *`).
**Zero matches outside `libs-base/Source/NSZone.m` itself.** Downstreams
only use the opaque pointer.

## 4. Performance estimate

Not perf-motivated. Expected deltas:

- **Binary size:** `NSZone.m.o` shrinks from 45,482 bytes to ~4-6 KB.
  Net savings in `libgnustep-base-1_31.dll`: ~40 KB .text. Negligible
  runtime impact.
- **Allocation speed:** Today's default zone already calls `malloc`
  directly (`NSZone.m:162-174`). The shim eliminates one indirect call
  through the `default_zone.malloc` function pointer per
  `NSZoneMalloc`, saving a few ns per alloc when the compiler can inline
  the shim. Not measurable in practice.
- **Dead-code removal:** ~1100 lines of ffree/nfree allocator deleted.
  Reduces cognitive surface area and removes a class of latent bugs
  (we're not aware of active ones but the code has not seen serious
  maintenance in 20 years).

Note on dtable fast-path interaction: `libobjc2/dtable.c:118-120` contains
an explicit comment tolerating the "class overrides `+alloc` but not
`+allocWithZone:`" false negative — such classes simply fall through to a
harmless slow path rather than hitting the trivial-alloc optimization.
This is why Option A's "keep `+allocWithZone:` intact on NSObject" strategy
is sufficient even for subclasses that only override `+alloc`: the dtable
check already accepts that tradeoff by design, so Option A neither
introduces nor worsens any fast-path regression.

## 5. Risk

### 5.1 Behavioral risk — NSCreateZone semantics relaxed

After Option A, memory allocated through a caller-created zone is *not*
reclaimed when `NSRecycleZone` is called. If any third-party app relies on
`NSCreateZone` + `NSRecycleZone` as a bulk deallocator, that app will
**leak memory silently**. Mitigation: nobody in our tree does this, and
Apple Foundation has had identical behavior since macOS 10.6+, so any
app that works on modern macOS already tolerates the relaxation.

### 5.2 `+allocWithZone:` — do not remove

libobjc2 has two dependencies on this selector:

1. `libobjc2/fast_paths.m:36-50`, `objc_allocWithZone(Class cls)`, the
   ARC-emitted fast path for `alloc`. Falls back to
   `[cls allocWithZone: NULL]`.
2. `libobjc2/dtable.c:88-124`, `checkFastAllocInit` / `isTrivialAllocInit`
   optimization (doc comment starts at line 88, body runs through 124+),
   which inspects whether a class overrides `alloc` or `allocWithZone:`
   to decide whether `alloc`+`init` can be collapsed.

Removing `+allocWithZone:` from NSObject would break ARC allocation for
every class in the system. Option A keeps it intact. **No risk.**

### 5.3 `-zone` called from debugger / `po`

Some `po` formatters and GNUstep debugging tools call `-zone` to label
objects. Option A keeps `-zone` returning a valid non-NULL pointer (the
default sentinel) with a usable `name`, so this keeps working.

### 5.4 Downstream consumer assumptions

libs-gui and libs-back call `NSZoneMalloc([self zone], n)` ~150 times
combined. After Option A these calls behave identically (`[self zone]`
returns the sentinel, `NSZoneMalloc` calls `malloc`). **No code change
required in libs-gui or libs-back.** No recompile required against
unchanged headers.

### 5.5 Third-party app ecosystem

GNUstep third-party apps that use `NSCreateZone` explicitly: very rare in
surveyed code (GormCore, Étoilé, ProjectCenter — none create zones).
Apps that override `+allocWithZone:` for real — common, but Option A
doesn't touch dispatch.

### 5.6 Threading

The global `zoneLock` protects the `zone_list` linked list used by
`NSZoneFromPointer`. Under Option A, `zone_list` is still needed only to
back `NSSetZoneName`/`NSZoneName` for user-created zones. `NSZoneFromPointer`
no longer walks it (returns sentinel unconditionally). We can either keep
the lock for `zone_list` mutation in `NSCreateZone`/`NSRecycleZone`, or
drop the list entirely and have `NSZoneName` read `zone->name` directly.
Recommend keep-list-drop-walker for minimal diff.

### 5.7 GC code paths

`GSGarbageCollector.m` and the `NSAllocateCollectable` / `NSScannedOption`
surface (`NSZone.h:223-248`) are legacy GC holdovers. The current
`NSAllocateCollectable` at `NSZone.m:1783-1786` already just does
`NSZoneCalloc(NSDefaultMallocZone(), 1, size)` — it's already a shim.
No additional risk.

## 6. Test strategy

No dedicated NSZone test suite exists. Spike recommends adding
`libs-base/Tests/base/NSZone/GNUmakefile` + `basic.m` covering:

1. `NSZoneMalloc(NULL, 16)` returns non-NULL, `NSZoneFree(NULL, p)` does
   not crash.
2. `NSZoneMalloc(NSDefaultMallocZone(), 16)` round-trips.
3. `NSCreateZone(1024, 256, YES)` returns non-NULL, `NSZoneMalloc` on it
   returns writable memory, `NSRecycleZone` does not crash.
4. `NSZoneFromPointer(p)` returns non-NULL for any `p`.
5. `NSSetZoneName(z, @"test")` round-trips via `NSZoneName`.
6. `[[NSObject alloc] zone]` returns non-NULL.
7. `[NSObject allocWithZone: NULL]` returns an initialized `NSObject`.
8. Run full libs-base test suite (`make check`) under Option A to verify
   no regression in ~784 internal callers.
9. Build libs-gui + libs-back against shimmed libs-base and re-run their
   test suites / smoke-test a demo app (Ink.app).

Before landing, verify on Linux GNU/Linux and Windows MSYS2 (our CI
target) that `libgnustep-base-1_31.dll` shrinks by the expected ~40 KB
and re-exports all NSZone symbols (`nm --defined-only | grep NSZone`).

## 7. Decision

**GO — Option A (compatibility shim).**

The investigation contradicted my prior prediction of NO-GO. The key facts
that flipped the call:

1. **NSZone.m is *not* already a shim.** It contains ~1100 lines of live
   segregated-fit / worst-fit allocator code (`NSZone.m:530-1500`) that is
   effectively dead on the modern OBJC_CAP_ARC runtime but still compiled
   into every `libgnustep-base` build. There is real code and binary size
   to delete.
2. **`struct _NSZone` is opaque in the public header** (`NSZone.h:32`),
   and no downstream consumer (libs-gui, libs-back, libs-corebase,
   libs-opal, libs-quartzcore) reaches into the struct fields. B7 does
   **not** have B3's public-struct blast radius.
3. **Zero symbol removals required.** Every `GS_EXPORT` stays live with
   compatible signatures. No SOVERSION bump. This is a pure implementation
   swap behind a stable API surface.
4. **Modern allocation already bypasses NSZone.** `NSObject.m:823-864`
   shows `class_createInstance` under OBJC_CAP_ARC; the zone parameter is
   already ignored for object allocation. We are codifying a status quo
   that has existed de facto for years.
5. **libobjc2 dependencies on `+allocWithZone:` are preserved** by Option
   A (no method is removed), so fast_paths.m and dtable.c trivial-alloc
   detection continue to work.

The only behavioral change — `NSCreateZone` + `NSRecycleZone` no longer
acts as a bulk deallocator — matches Apple Foundation's behavior since
macOS 10.6+, and nobody in our surveyed repos creates a zone anyway.

Scope of work: ~1500 lines deleted from `NSZone.m`, ~200 lines of shim
added, ~50 lines of new test. Zero changes in libs-gui, libs-back,
NSObject.m, or any public header. One-week task for a focused session.

**Recommended follow-ups (out of scope for this spike):**

- Mark `NSCreateZone` / `NSRecycleZone` / `NSZoneFromPointer` /
  `NSZoneStats` / `NSZoneCheck` with `__attribute__((deprecated))` in
  `NSZone.h` so new code stops using them. Deprecation is *not* removal;
  no SOVERSION bump.
- After one or two releases, consider scripting the mechanical cleanup of
  internal `NSZoneMalloc([self zone], n)` -> `malloc(n)` in libs-base
  (Option B) as a diff-hygiene pass. Still not load-bearing.
