# Spike: dtable Field Cache-Line Move Adjacent to isa (libobjc2)

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repo:** libobjc2 (DTW-Thalion fork, `gnustep-audit/libobjc2/` subfolder, branch `master`)
**Depends on:** B1 `docs/spikes/2026-04-13-per-class-cache-version.md` (opaque struct, asmconstants, SOVERSION), B2 `docs/spikes/2026-04-13-tagged-pointer-nsstring.md` (small-object asm branch ordering)

---

## 1. Current state

### 1.1 `struct objc_class` byte layout (LP64 Unix)

Declared in `libobjc2/class.h:45-141` (marker comments `// begin: objc_class` at line 45 and `// end: objc_class` at line 142). On an LP64 Unix target (`long` = 8 bytes, pointers = 8 bytes):

| offset | field | declared at |
|---:|---|---|
| 0   | `Class isa`                             | `class.h:53`  |
| 8   | `Class super_class`                     | `class.h:59`  |
| 16  | `const char *name`                      | `class.h:64`  |
| 24  | `long version`                          | `class.h:69`  |
| 32  | `unsigned long info`                    | `class.h:74`  |
| 40  | `long instance_size`                    | `class.h:85`  |
| 48  | `struct objc_ivar_list *ivars`          | `class.h:89`  |
| 56  | `struct objc_method_list *methods`      | `class.h:94`  |
| 64  | `void *dtable`                          | `class.h:99`  |
| 72  | `Class subclass_list`                   | `class.h:104` |
| 80  | `IMP cxx_construct`                     | `class.h:109` |
| 88  | `IMP cxx_destruct`                      | `class.h:114` |
| 96  | `Class sibling_class`                   | `class.h:121` |
| 104 | `struct objc_protocol_list *protocols`  | `class.h:127` |
| 112 | `struct reference_list *extra_data`     | `class.h:131` |
| 120 | `long abi_version`                      | `class.h:136` |
| 128 | `struct objc_property_list *properties` | `class.h:140` |

(Same layout cited independently in B1 §1.6.)

On **Win64** `long` is 32 bits, so `version`, `info`, `instance_size`, and `abi_version` each contract by 4 bytes (plus padding), giving a smaller struct. This is why `DTABLE_OFFSET` differs per platform; see §1.2.

### 1.2 `DTABLE_OFFSET` and friends

Defined in `libobjc2/asmconstants.h:1-20`:

```
LP64 Unix:    DTABLE_OFFSET = 64   (asmconstants.h:2)
_WIN64:       DTABLE_OFFSET = 56   (asmconstants.h:9)
32-bit:       DTABLE_OFFSET = 32   (asmconstants.h:15)
```

The other offsets in the same header (`SHIFT_OFFSET`, `DATA_OFFSET`, `SLOT_OFFSET` at `asmconstants.h:3-6,10-13,17-19`) address fields inside the **dtable** structure and inside a **slot** structure — not `struct objc_class`. So within the class-layout domain there is exactly one hardcoded offset macro: `DTABLE_OFFSET`.

The offset is sanity-checked at C compile time in `dtable.c:17-18`:
```c
_Static_assert(__builtin_offsetof(struct objc_class, dtable) == DTABLE_OFFSET,
               ...);
```

### 1.3 x86-64 fast-path use

`libobjc2/objc_msgSend.x86-64.S:35-37` (`MSGSEND` macro body):

```
mov   (\receiver), %r10               # Load the dtable from the class   [isa load]
1:                                    # classLoaded
mov   DTABLE_OFFSET(%r10), %r10       # Load the dtable from the class into r10
```

Line 35 dereferences the receiver to fetch `isa` (offset 0 of the instance, pointing to the class). Line 37 then adds `DTABLE_OFFSET` (= 64 on LP64 Unix, 56 on Win64) to the class pointer and loads `dtable`.

**Cache-line analysis (x86-64, typical 64-byte line):**

- `isa` sits at class offset 0. If the class object begins on a 64-byte boundary (the libobjc2 allocator does *not* force this; malloc typically guarantees only 16-byte alignment), `isa` is at bytes [0..8) of line 0 of the class.
- `dtable` sits at class offset 64 (LP64 Unix). Best case, that is the first 8 bytes of line 1 — a **different** cache line. Even on Win64 where `dtable` is at offset 56, if the class happens to straddle a line boundary, the `dtable` load can still miss a separate line.
- Conclusion: under today's layout the `isa` load and the `dtable` load reside on **different 64-byte cache lines** in the common case. Two L1-miss opportunities on cold-class dispatch.

### 1.4 Other architectures using `DTABLE_OFFSET`

Grep across `libobjc2/` (`DTABLE_OFFSET`):

- `objc_msgSend.aarch64.S:76` — `ldr x9, [x9, #DTABLE_OFFSET]`
- `objc_msgSend.arm.S:64`     — `ldr r4, [r4, #DTABLE_OFFSET]`
- `objc_msgSend.mips.S:55`    — `LP  $t0, DTABLE_OFFSET($t0)`
- `objc_msgSend.riscv64.S:12` — `ld  t0, DTABLE_OFFSET(t0)`
- `objc_msgSend.x86-32.S:12`  — `mov DTABLE_OFFSET(%eax), %eax`
- `objc_msgSend.x86-64.S:37`  — as quoted above
- `asmconstants.h:2,9,15` — definitions
- `dtable.c:17` — static assert

Every architecture uses the macro in the same shape: load-class-pointer, add `DTABLE_OFFSET`, load dtable. This is the single common dispatch point — confirmed.

### 1.5 Consumers outside `objc_msgSend*.S`

- `block_trampolines.S` — greps clean for `DTABLE_OFFSET`, `objc_class`, and `isa` class-layout references. It does not touch `struct objc_class`.
- `eh_personality.c` — greps clean for `->dtable` / `->super_class` / `->isa`. Does not peek at class layout.
- `objcxx_eh*.cc` — no matches for `DTABLE_OFFSET` or hardcoded class offsets.
- `runtime.c` — accesses `cls->super_class`, `cls->sibling_class`, etc. *by C field name* (e.g. `runtime.c:46,62,408,447,523,530,533,534,548`). These recompile naturally against any reordered layout and do not carry hardcoded offsets.
- `dtable.c` — accesses fields by name; the static assert at `dtable.c:17` is the only offset-sensitive site.
- `sendmsg2.c:106` and `sendmsg2.c:373` — `class->dtable` / `cls->dtable` accessed by name from C slow paths.

**No consumer reads class fields by hardcoded offset other than the `DTABLE_OFFSET` asm dispatchers.** The existing asmconstants tracking is complete.

### 1.6 Public-header exposure of `struct objc_class`

Grep of `libobjc2/objc/` for `struct objc_class`:

- Only hit: `libobjc2/objc/runtime.h:85`:
  ```c
  typedef struct objc_class *Class;
  ```
  This is a forward declaration / typedef of an opaque pointer. **The struct is never defined in any public header.**
- There is no `objc/objc-class.h` in the tree (grep clean). No public `#define` for `DTABLE_OFFSET` or any class field offset.
- Public accessors (`class_getName`, `class_getSuperclass`, `class_getInstanceVariable`, etc.) live in `objc/runtime.h` and all take `Class` as an opaque token.

This confirms B1 §3.2's claim — and importantly extends it for B3: B1 was about *tail-append*, which is cheap even for non-opaque structs. B3 is about *reordering*, which requires the struct to be opaque not just at the C level but also to *inlined compiler codegen*. Clang's Objective-C front end **emits** `@implementation` metadata as class structures, so the compiler's notion of the layout (per `class.h`) must match at build time — but compiled `.o` files contain the *data* of the class, not hardcoded offset reads into it. The consumer of the *offset* is the runtime itself plus the asm dispatchers in this repo.

B1 §3.2 already noted that the gsv1 (`class.h:144-275`) and GCC-compat (`class.h:283-298`) legacy class structs must stay bit-compatible with what older compilers emit. For B3 this matters: both legacy structs also place `dtable` deep in the middle (legacy gsv1: `class.h:197`; gcc-compat: `class.h:293`, both at the same relative slot). Reordering `struct objc_class` does **not** require reordering the legacy structs — they are read via distinct codepaths when `objc_load_module` detects an older ABI — but the runtime code that copies-through legacy → current must be audited (`legacy.c` had 1 hit for `super_class` above).

### 1.7 Fields between `isa` and `dtable`

Seven fields (56 bytes on LP64, offsets 8..63): `super_class`, `name`, `version`, `info`, `instance_size`, `ivars`, `methods`. Hot-path status:

- `super_class` — read on every inherited-method slow-path lookup (`runtime.c:46,447`) and on the `cxx_construct` chain (`runtime.c:62,64`). Also read by `class_getSuperclass` (runtime API consumed by `+[NSObject superclass]` in libs-base). **Hot-ish**: mostly touched on slow-path, but `+superclass` itself is used casually by a lot of Objective-C code.
- `name` — `class_getName`, `+[NSObject description]`. Not hot per-dispatch but touched by logging/KVC/IB archiving.
- `version`, `info` — `info` is checked for flags (`CLS_RESOLVED` etc.) during class load and some runtime queries. `version` is effectively unused.
- `instance_size` — read by `class_getInstanceSize`, `class_createInstance`, every `+alloc`. **Hot** on allocation-heavy code.
- `ivars`, `methods` — touched only by the compiler emit path and `runtime.c` ivar / method introspection. Cold.

---

## 2. Proposed change

### 2.1 New layout

Move `dtable` to offset 8 (immediately after `isa`). New order:

| offset | field |
|---:|---|
| 0   | `Class isa` |
| 8   | `void *dtable` |
| 16  | `Class super_class` |
| 24  | `const char *name` |
| 32  | `long version` |
| 40  | `unsigned long info` |
| 48  | `long instance_size` |
| 56  | `struct objc_ivar_list *ivars` |
| 64  | `struct objc_method_list *methods` |
| 72  | `Class subclass_list` |
| ... | (remainder unchanged relative order) |
| ... | `struct objc_property_list *properties` |
| ... | (B1's `cache_generation` tail field if co-landed) |

### 2.2 `asmconstants.h` updates

```
LP64 Unix:   #define DTABLE_OFFSET 8
_WIN64:      #define DTABLE_OFFSET 8
32-bit:      #define DTABLE_OFFSET 4
```

All three stanzas at `asmconstants.h:1-20` change. `SHIFT_OFFSET`, `DATA_OFFSET`, `SLOT_OFFSET` are unaffected (they index into the dtable and slot structures, not into `struct objc_class`).

The `_Static_assert` in `dtable.c:17-18` continues to verify the match and will catch any discrepancy at build time.

Every `.S` file that uses `DTABLE_OFFSET` (enumerated in §1.4) rebuilds automatically; the macro is literally substituted. **No hand-edit of any asm file is required** — the change is confined to `class.h` and `asmconstants.h`.

### 2.3 Semantic preservation

Every field retains its C name and type. C code that accesses `cls->super_class`, `cls->name`, etc. (e.g. `runtime.c:46,62,523`, `dtable.c` method iteration) is unchanged; the compiler recomputes offsets. The only code affected by the offset change is the asm fast path (via `DTABLE_OFFSET`) and the static assert.

**Hot-path fields displaced:**
- `super_class` moves from offset 8 to 16. It now shares a cache line with `isa`+`dtable` on any 16-byte-aligned class allocation (which is malloc's floor on x86-64 SysV / Win64), **improving** `class_getSuperclass` locality, not degrading it.
- `instance_size` moves from offset 40 to 48 — still within the same 64-byte line as `isa` in the common case. No worse than today.
- `name`, `version`, `info`, `ivars`, `methods` — none were on a particularly hot path; their new offsets are arbitrary.

The legacy `struct objc_class_gsv1` (`class.h:144-275`) and `struct objc_class_gcc` (`class.h:283-298`) **are not modified**: they describe on-disk layouts produced by old compilers and must stay bit-compatible. The runtime's legacy-to-current copy path in `legacy.c` has been audited and is **RESOLVED SAFE**: `objc_upgrade_class` at `legacy.c:344-370` `calloc`s a fresh `struct objc_class` and then performs **field-by-field assignment** (`cls->isa = oldClass->isa;`, `cls->name = oldClass->name;`, ..., `cls->abi_version = oldClass->abi_version;`). There is no `memcpy` over the class head bytes, so reordering `struct objc_class` leaves this bridge correct — the compiler recomputes each assignment's destination offset. The only `memcpy` in `legacy.c` is at `legacy.c:374` inside `objc_upgrade_category`, which copies `struct objc_category_gcc` into `struct objc_category` — categories, not classes, and irrelevant to the B3 reorder.

### 2.4 Rollout shape

**Single-commit atomic change** is the only feasible option. Unlike B1 (which can phase because the change is a tail-append + a new optional field), a field reorder has no "dual layout" version: the runtime, the compiler-emitted class structures loaded from every `.o`, and the asm dispatchers all share one view of the layout. All consumers rebuild simultaneously against the new `class.h`.

There is no compatibility shim short of keeping both layouts and branching on a flag — the cost of that branch on every dispatch would erase the optimization.

---

## 3. ABI impact

### 3.1 What breaks

1. **Every compiled `.o` / `.dll` / `.so` that contains an `@implementation`** — clang emits class structures with the old field order baked in. Loading such an object against a new-layout runtime is undefined: the runtime would read `super_class` where the object file wrote `dtable`. *Every* module containing Objective-C implementations must be recompiled against the new `class.h`.
2. **Any consumer that linked against `libobjc.so.4.6` and reads class fields by offset.** Per §1.5 and §1.6, the only offset-reading consumers are the libobjc2 asm files themselves, which rebuild in lockstep.
3. **Legacy class path** (`struct objc_class_gsv1`, `struct objc_class_gcc`) is not directly broken because those structs keep their own layout — but the runtime code that bridges legacy classes to current classes must be re-audited.

Contrast with B1 (tail-append field): B1 §3.2 correctly concluded that tail-append is safe for compiled `.o` files because "compiler-emitted `.o` files produce class structures of the old size [and] the runtime allocates and zeroes the new field during class load/resolution." **That escape hatch does not exist for B3.** Reordering invalidates every object file.

### 3.2 Public header surface

`struct objc_class` is not defined in any public header (verified §1.6, only forward declaration at `objc/runtime.h:85`). So the C-level public API (function signatures, `Class` opaque type) is unchanged. The break is purely at the compiled-code layer: clang-emitted class metadata must match the runtime's view.

### 3.3 SOVERSION bump

B1 §3.5 cites the current version as `libobjc_VERSION 4.6` at `libobjc2/CMakeLists.txt:36` (re-verified: line 36 reads `set(libobjc_VERSION 4.6)`), applied as both `VERSION` and `SOVERSION` via `set_target_properties` on the `objc` target.

B1's proposed bump for the tail-append was a minor bump to 4.7, justified by "opaque struct tail-append, no symbol removal." **B3 cannot ride that same minor bump.** A field reorder that invalidates every compiled-against-4.6 class module is a **major** soname break by any reasonable semver-for-soname rule. Proposed: **libobjc_VERSION 5.0**, soname `libobjc.so.5`.

If B1 and B3 land together the single bump covers both (B1's minor and B3's major collapse into one major = 5.0).

### 3.4 Windows DLL versioning

`libobjc2/CMakeLists.txt:36-49` and the `MSVC` stanza do not show a `WINDOWS_EXPORT_ALL_SYMBOLS` setting. The Windows build produces `objc.dll` + `objc.lib` import lib. Windows does not carry a soname in the ELF sense, but the import-lib name / DLL name tracks the major version per standard libobjc2 practice. A 5.0 bump on Windows means the import lib filename changes and all GNUstep-Windows binaries must be rebuilt — which is functionally the same blast radius as on ELF.

### 3.5 Rebuild graph

Every binary that contains *any* `@implementation` must be rebuilt. On the audited tree this includes:

- **`libs-base`** — core GNUstep base. Mandatory rebuild.
- **`libs-gui`** — AppKit equivalent. Mandatory rebuild.
- **`libs-back`** — display backend. Mandatory rebuild.
- **`libs-corebase`** — CoreFoundation layer. Mandatory rebuild if it contains `@implementation` (it does; some Obj-C bridge classes).
- **`libs-opal`** — Quartz 2D equivalent. Mandatory rebuild.
- **`libs-quartzcore`** — CA equivalent. Mandatory rebuild.
- **Every third-party GNUstep framework and application shipped as a binary.** This is the big one: any distributed `.app` bundle with an old-libobjc2-compiled class must either be rebuilt or fall back to a parallel 4.x runtime.

Contrast with B1 rebuild graph (B1 §3.3), which was "only `libs-base` needs to rebuild, and only to opt in to the improvement." B3's rebuild graph is **universal**.

---

## 4. Performance estimate

### 4.1 Cache-miss reduction on cold dispatch

Cold-class dispatch today pays:

1. Load `isa` from receiver: 1 load; may miss L1 (the receiver data is usually already hot because the caller just touched the object). Call this L1 latency ~4 cycles, miss-to-L2 ~12 cycles.
2. Load `dtable` from `isa + DTABLE_OFFSET`: the *class* is cold if it hasn't been dispatched recently. The class header (containing `isa`) lands in one cache line; `dtable` lives 64 bytes later (§1.3), which is a separate line and a separate L1 probe. If the class is cold, this is a second ~12-cycle miss to L2 (or worse to L3).

After reorder: `isa` and `dtable` are both in the first 16 bytes of the class object. A single cache-line fill services both loads. Expected saving on a true cold-class dispatch: **~8–12 cycles**, but this number applies only to the narrow **L1-cold / L2-warm sub-case** — the scenario where the class's `isa`-line is missing from L1 but the `dtable`-line is resolvable from L2 at ~12 cycles.

In the more general **cold-to-L3** case (class not touched recently enough for L2 residency), Intel's spatial / adjacent-line prefetcher on x86-64 often pulls the 64-byte neighbor of any demand-missed line on the same miss, which tends to **collapse the two cache-line misses into one** even under today's layout. Under that prefetcher behavior, today's two loads already complete in (roughly) a single memory-latency window, and the reorder recovers only a small residual — much less than 8–12 cycles.

Either way the estimate points the same direction: the 8–12 cycle figure is an *upper bound* for the per-cold-call win, and the sub-1% whole-app conclusion in §4.2 actually **strengthens** with this correction, because the realized per-call saving is smaller than the 8–12 number implies.

### 4.2 Frequency of cold-class dispatch

In steady-state dispatch, the class is already in L1 from the previous call on the same class. The optimization pays off on:

- First dispatch to a class after program startup or after cache eviction.
- Polymorphic call sites where many distinct classes rotate through and each class is evicted between calls (uncommon in real apps).
- Benchmark microcode that deliberately flushes the class line.

In a typical AppKit-style workload where hot dispatch dominates, the fraction of dispatches that are truly cold-class is **small** — likely < 1% of total dispatch count. Multiplying by an 8–12 cycle saving per cold dispatch, the whole-app saving is almost certainly **sub-1%**.

### 4.3 Expected benchmark results

- **Dispatch microbenchmark (synthetic cold)**: could show 5–15% improvement per dispatch if the benchmark is constructed to always take the cold path (flush class line between calls). This is not representative of real workloads.
- **Real application dispatch-heavy workload** (AppKit scroll, text layout, KVO-light): sub-1% improvement, likely within noise.
- **Real application dispatch-light workload**: unmeasurable.

### 4.4 Existing benchmark

`instrumentation/benchmarks/bench_msg_send.m` **does exist** in the audited tree and was used in an earlier post-fix validation run. Inspection of the file confirms that it allocates a single `BenchTarget` instance inside an `@autoreleasepool` (`bench_msg_send.m:29`) and then spins 10M iterations of four micro-benchmarks against that one steady-state class:

- `msg_send_class` — `[obj class]` (`bench_msg_send.m:32-40`)
- `msg_send_noop` — `[obj noop]` (`bench_msg_send.m:43-51`)
- `msg_send_respondsToSelector` — `[obj respondsToSelector:sel]` (`bench_msg_send.m:54-63`)
- `msg_send_class_method` — `[cls class]` on a cached `Class` (`bench_msg_send.m:66-75`)

There is no `_mm_clflush`, no class rotation, and no cold-cache generation anywhere in the file. After the first few iterations the class line, the dtable, and the slot for each selector are all L1-resident and stay there. **It measures hot-path dispatch only** — exactly the regime where the B3 reorder's expected win is near zero (see §4.2).

Implication: the existing harness is the right binary to *extend*, not replace. A cold-dispatch mode would need to be added — ideally as a `--cold` flag on the existing `bench_msg_send` tool rather than as a separate binary — that allocates N distinct classes, flushes each class's cache line with `_mm_clflush` between calls, and rotates through them to defeat L1 warmth. The existing harness already supports multiple benchmarks per binary (see the four `BENCH`/`BENCH_JSON` blocks above), so a cold variant slots in naturally next to the hot ones.

Writing that cold mode is still non-trivial (clflush semantics, warmup control, stable cold-class generation), but the scaffolding, JSON output format, and timing infrastructure are all already in place.

### 4.5 Is it worth it?

Given (a) sub-1% whole-app win as the realistic outcome (and the §4.1 adjacent-line-prefetch correction makes it smaller still), (b) universal rebuild of every GNUstep binary as the cost, (c) no existing cold-dispatch benchmark — the existing `bench_msg_send.m` measures hot dispatch only and a `--cold` mode would need to be added — **the benefit does not justify the disruption.**

---

## 5. Risk

### 5.1 Correctness

**Low.** The change is mechanical: reorder fields in a struct, update one header's worth of offset constants, rebuild. The `_Static_assert` at `dtable.c:17` guarantees the asm and C views stay in sync, and the compiler recomputes every C-side offset. Wrong-dispatch risk is essentially zero: the legacy class bridge in `legacy.c` (`objc_upgrade_class`, `legacy.c:344-370`) uses field-by-field assignment on a fresh `calloc`'d struct rather than `memcpy`ing head bytes, so the reorder does not disturb it (see §2.3).

### 5.2 ABI break blast radius

**HIGH.** This is the core risk. Every compiled `.o` containing an `@implementation` produced by a clang linked against the old `class.h` emits a class metadata block that mis-matches the new runtime. Symptom: wild pointer dereferences during early class resolution, typically a crash in `objc_load_module` or during the first dispatch. No graceful degradation.

Contrast with B1 (tail-append): B1 is zero ABI break under its dual-counter phase A. B3 is an unconditional major ABI break with no phase option.

### 5.3 Rollback

In git terms: cheap. Revert one commit on `libobjc2/class.h` + `libobjc2/asmconstants.h`. In deployment terms: **every binary built against the broken runtime must itself be rebuilt back against the reverted runtime**. If the change has been in a release for any length of time, rollback pain scales with adoption.

### 5.4 Interaction with B1 (per-class cache generation)

B1 appends a field to the tail of `struct objc_class`. B3 reorders the head. The two changes are structurally independent — they touch different regions of the struct — but both bump SOVERSION. The team's leverage point:

- **If B3 is accepted**, it forces a major SOVERSION bump anyway. B1's tail-append can ride that major bump for free (instead of needing its own minor bump to 4.7, it lands as part of 5.0). This is the *only* scenario where B3's ABI cost is partially amortized.
- **If B1 lands first** as a 4.7 minor bump and B3 follows later as a 5.0 major bump, consumers pay two rebuild cycles in close succession. Worse for everyone.
- **If B3 is rejected**, B1 proceeds independently per its own spike.

### 5.5 Slow path / isa-chain walk

The Objective-C `super_class` chain is walked in the dispatch slow path (`runtime.c:46,447` and the C fallback in `sendmsg2.c` starting at `sendmsg2.c:106`). Moving `super_class` from offset 8 to offset 16 keeps it on the same cache line as `isa` on any 16-byte-aligned class allocation and is strictly non-worse for the slow-path walk. `class_getSuperclass` and `+[NSObject superclass]` get the same locality. No regression expected.

### 5.6 Small-object / tagged-pointer interaction

B2 §1.3/§1.4 documents that `objc_msgSend.x86-64.S:31-33` branches on `SMALLOBJ_MASK` *before* the dtable load at line 37. The small-object path fetches its class from `SmallObjectClasses[tag]` (`class_table.c:472`) — which is itself a `struct objc_class *`, so it benefits from the same locality improvement as the heap path. More importantly: the tagged-pointer asm branch is not affected by the reorder because it jumps past line 37 and rejoins after its own class lookup. The small-object path remains correct under the new layout.

---

## 6. Test strategy

### 6.1 Existing test coverage

`libobjc2/Test/` contains 40+ `.m` files exercising class creation, method dispatch, categories, protocols, exceptions, and ARC (directory listing confirmed; includes `Category.m`, `DirectMethods.m`, `Forward.m`, `objc_msgSend.m`, `objc_msgSend_WoA64.mm`, `AllocatePair.m`, `ManyManySelectors.m`, `MethodArguments.m`, `BlockImpTest.m`, `ExceptionTest.m`, etc.). Any of these that dispatches an Objective-C method exercises the asm fast path and will fail loudly if `DTABLE_OFFSET` is wrong. `Test/objc_msgSend.m` is the most directly relevant — it is specifically a `msgSend` correctness test.

For `_Static_assert` failures, the build breaks before any test runs — the safety net is tight.

### 6.2 Performance regression / improvement

**No existing benchmark targets cold dispatch** (see §4.4 — no `instrumentation/benchmarks/` directory exists in the audited tree). A new benchmark is required:

- `bench_msg_send_cold.m` — allocate N distinct classes, dispatch one method to each class, flush each class's cache line with `_mm_clflush` (x86) between calls, measure ns/dispatch. Compare pre- and post-reorder builds.
- `bench_msg_send_hot.m` — control: dispatch repeatedly to a single class. Expect **no change** (steady-state locality is unchanged).

Without these benchmarks there is no way to confirm the expected 8–12 cycle saving. The spike cannot produce a reliable performance number without them.

### 6.3 ABI regression test

- Build a trivial `@implementation Foo` test binary against `libobjc.so.4.6` (old layout).
- Attempt to load it against a new `libobjc.so.5.0` runtime.
- **Expected:** crash at class registration or first dispatch (reading `super_class` where the object file wrote `dtable`, or equivalent). Document this as the explicit failure signature so that production deployments see an immediate loud failure rather than silent corruption.
- Add a version check in `objc_load_module` that refuses to load modules compiled against an old `abi_version` when the runtime is 5.0+. This is a fail-early guard: given the field is already present at `class.h:136`, the runtime can (and should) reject older modules outright.

### 6.4 Correctness sweep

After the reorder, run the full `libobjc2/Test/` suite plus `libs-base` tests (Tests/base) plus `libs-gui` smoke tests. Method dispatch, KVO install, category load, and exception throw are the highest-risk functional areas.

---

## 7. Decision

**NO-GO**, with a conditional escape clause.

### 7.1 Rationale

The spike has three findings that collectively kill the GO case on its own merits:

1. **Realistic whole-app win is sub-1%.** On real workloads the fast path is dominated by hot dispatch, where the class is already L1-resident and the second load is free. The optimization only bites on cold-class dispatch, which is a small fraction of total dispatch count. An 8–12 cycle per-cold-call saving multiplied by a single-digit-percent share of calls is lost in measurement noise at the application level. (§4.1–§4.5)

2. **ABI cost is maximal.** Unlike B1's tail-append, field reordering has no phased or dual-layout option. Every binary in the GNUstep ecosystem must rebuild simultaneously, and a major SOVERSION bump (4.6 → 5.0, per `libobjc2/CMakeLists.txt:36`) is unavoidable. The cost is not "the libobjc2 team rebuilds once" — it is "every GNUstep app shipped as a binary rebuilds or breaks." (§3.1, §3.3, §3.5)

3. **No cold-dispatch benchmark exists to produce a baseline.** `instrumentation/benchmarks/bench_msg_send.m` exists and works, but it measures hot dispatch only — one steady-state class, no clflush, no class rotation (§4.4). A cold-dispatch mode (ideally a `--cold` flag on the existing tool) would need to be added before this spike could ground its expected win in a measured number. Committing to a universal rebuild on the strength of an unmeasured sub-1% estimate is not defensible.

The cost-benefit inverts decisively against the change: MAXIMAL ABI cost × sub-1% likely win × no measurement infrastructure = NO-GO.

### 7.2 Conditional escape: ride-along with an unrelated 5.0 bump

The **one** scenario in which this spike flips to NEEDS-DISCUSSION-leaning-GO is if some **other unrelated change** independently forces a libobjc2 SOVERSION bump to 5.0 — for example, a future removal of a deprecated exported symbol, a struct ivar visibility change, a major runtime refactor unrelated to B1, or any other pending ABI break that is already going to cost the ecosystem a universal rebuild. In that world, the rebuild cost of B3 is *already being paid* by someone else, and the field reorder becomes a "might as well" piggyback. The cost delta is (roughly) just the time to write the reorder patch, rebuild, and measure.

**B3 must not be framed as a B1 piggyback.** B1's design (per B1 §2.5 and §3.5) is specifically a phased dual-counter rollout that *avoids* the SOVERSION 4.6 → 5.0 bump — it lands as a minor 4.7 bump with a tail-append and a global-counter fallback. If B1 ships as designed, there is no major bump for B3 to ride on. The only way B1 would produce a 5.0 bump is if it took its rejected atomic-cutover alternative, which B1's own spike explicitly chooses against. Hanging B3's revival on B1 is therefore not a real escape clause — it would require B1 to abandon the design it just approved.

If and only if some unrelated 5.0 bump is under serious consideration, B3 should be re-opened and:

1. A `bench_msg_send_cold.m` benchmark should be written first and landed on `master` to establish a baseline.
2. The reorder patch should be prepared on a branch (not committed).
3. The benchmark should be re-run against the branch. If the measured improvement on cold dispatch is > 5% *and* there is any measurable improvement on a real-workload benchmark (e.g. a libs-base AppKit-smoke test), land it as part of the 5.0 bundle.
4. If the measured improvement on cold dispatch is ≤ 5% or real-workload improvement is unmeasurable even when the rebuild cost is sunk, drop the patch and stay with the existing layout.

Without that unrelated 5.0 bump, the recommendation is firmly **NO-GO**: do not reorder `struct objc_class` for this optimization alone.

### 7.3 Known unknowns (documented for completeness)

- **`legacy.c` head-bytes copy**: **RESOLVED SAFE.** `objc_upgrade_class` at `legacy.c:344-370` uses field-by-field assignment on a `calloc`'d new `struct objc_class`; the only `memcpy` in the file is at `legacy.c:374` and covers `struct objc_category_gcc`, which is unrelated to the class reorder. This removes one risk factor from §5, but does not change the NO-GO verdict — the ABI-break cost and sub-1% win analysis are unaffected.
- **`abi_version` field as runtime guard**: whether `objc_load_module` already rejects mismatched abi_versions, or would need a new check added as part of a 5.0 bump. Implementation detail for §6.3; not investigated in this spike.
- **Actual cold-class dispatch frequency in real GNUstep workloads**: the sub-1% whole-app estimate is a back-of-envelope from microarchitectural first principles, not a measurement. A profile of (say) a real GNUstep text editor under load would sharpen this number considerably.
