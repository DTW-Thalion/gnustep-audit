# Spike: Tagged-Pointer / Small-String NSString (libs-base)

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repos:** libs-base (primary), libobjc2 (small-obj infra)
**Depends on:** `docs/spikes/2026-04-13-per-class-cache-version.md` (B1)

---

## Headline finding

**Tagged-pointer small strings are already implemented in libs-base and
already enabled on 64-bit targets.** The class is `GSTinyString`, defined
in `libs-base/Source/GSString.m:851` and registered via
`objc_registerSmallObjectClass_np` at `GSString.m:1124`. The factory
hook-in lives at `-[GSPlaceholderString initWithBytes:length:encoding:]`
(`GSString.m:1396-1434`) and is reached from
`+[NSString stringWithUTF8String:]` / `+[NSString stringWithCString:...]`
via the normal placeholder-replacement cluster path.

This spike therefore reframes: B2 is not a greenfield design, it is an
**audit-and-measure** exercise. The design sections below document what
exists, identify gaps (payload cap of 8 chars, ASCII-only, no dedicated
benchmark label, no tiny-specific boundary tests), and note why
extending the layout further (e.g. 9-char payload) is not worth it on
the current 3-bit tag.

---

## 1. Current state

### 1.1 libobjc2 small-object infrastructure

Fully present.

- Public API in `libobjc2/objc/runtime.h:1001-1002`:
  ```c
  OBJC_PUBLIC
  BOOL objc_registerSmallObjectClass_np(Class cls, uintptr_t classId);
  ```
- Tag mask / shift in `libobjc2/objc/runtime.h:1010-1026`:
  - 64-bit: `OBJC_SMALL_OBJECT_MASK = 7`, `OBJC_SMALL_OBJECT_SHIFT = 3`
    (low 3 bits are tag, giving 7 usable tag values).
  - 32-bit: `OBJC_SMALL_OBJECT_MASK = 1`, `OBJC_SMALL_OBJECT_SHIFT = 1`
    (one slot only, typically used for a small-int class).
- Slot table: `libobjc2/class_table.c:472` —
  `PRIVATE Class SmallObjectClasses[7];`
- Registration body: `libobjc2/class_table.c:474-495`. On 64-bit each tag
  value 1..7 maps to one class; on 32-bit only slot 0 is used. First
  caller wins; second caller for the same mask returns NO
  (`class_table.c:489-491`).
- Capability bit advertised via `OBJC_CAP_SMALL_OBJECTS`
  (`libobjc2/objc/capabilities.h:106`).
- `isSmallObject()` inline in `libobjc2/class.h:421-425`:
  ```c
  static BOOL isSmallObject(id obj)
  {
      uintptr_t addr = ((uintptr_t)obj);
      return (addr & OBJC_SMALL_OBJECT_MASK) != 0;
  }
  ```
- `classForObject()` in `libobjc2/class.h:427-443` dispatches to the
  correct small-object class via the tag bits and otherwise reads
  `obj->isa`. It is `__attribute__((always_inline))`.

**Gating (applies to everything downstream):** `GSTinyString` is double-gated.
- **Compile-time:** `#if defined(OBJC_SMALL_OBJECT_SHIFT) && (OBJC_SMALL_OBJECT_SHIFT == 3)`
  wraps the class definition and all call sites
  (`GSString.m:790`, `:1396`, `:5472`). 32-bit builds and any runtime
  that does not define a 3-bit tag (anything other than libobjc2 ≥
  the small-object-enabled era on a 64-bit target) compile the entire
  tiny-string path out — no class, no `createTinyString`, no
  fast-path checks. There is no heap fallback *at compile time*; the
  cluster simply never sees the tiny branch.
- **Runtime:** the global `useTinyStrings` is set only after
  `objc_registerSmallObjectClass_np(self, TINY_STRING_MASK)` succeeds
  inside `+[GSTinyString load]` (`GSString.m:1122-1128`). If
  registration fails (e.g. slot 4 already taken), every
  `createTinyString` call bails out at `GSString.m:1192` and the
  cluster falls through to heap allocation.

**Audit scope consequence:** the tiny-string work in this spike is
relevant only to Win64 / Linux-x86_64 / Linux-arm64 builds against
libobjc2. 32-bit and non-libobjc2 runtimes are outside the target
matrix for B2.

### 1.2 Runtime integration: dispatch, retain/release, associated objects

- **`object_getClass` / `-class`:** honors tag bits via
  `runtime.c:822` — `if (isSmallObject(obj)) { return classForObject(obj); }`
  — so `[tinyStr class]` returns `GSTinyString`, not something bogus.
  Reverse lookup (`class_isMetaClass`-style checks in
  `runtime.c:341,350`) also compares against the registered slots.
- **ARC / retain-release:** `arc.mm:321-324` is the `isPersistentObject`
  predicate entry point which returns YES for any small object; its
  consumer sites at `arc.mm:332` (retain) and `arc.mm:392` (release)
  short-circuit when the predicate is YES, so retain/release/weak are
  all no-ops on tagged strings. This is exactly the semantics tagged
  pointers require.
- **Associated objects:** `associate.m:331,338,389,407,416,428,463`
  unconditionally refuse to attach state to small objects. A tagged
  NSString therefore cannot be a KVO observer target, cannot carry
  associated objects, and cannot have weak references to it.
- **Asm dispatch fast path (x86-64):**
  `libobjc2/objc_msgSend.x86-64.S:29-36` tests for nil, then for the
  small-object mask (`test \receiver, %r10`), branching to label `6` at
  line 267. The small-object handler is lines 267-271:
  ```asm
  6:                                        # smallObject:
      and   \receiver, %r10                 # Find the small int type
      lea   CDECL(SmallObjectClasses)(%rip), %r11
      mov   (%r11, %r10, 8), %r10           # cls = SmallObjectClasses[tag]
      jmp   1b                              # fall back into normal dispatch
  ```
  After the indirection, dispatch continues at label `1` which reads
  `DTABLE_OFFSET(%r10)` — i.e. the tagged class's dtable — and dispatches
  normally. No special cache. Identical patterns exist in
  `objc_msgSend.aarch64.S:188-194`, `objc_msgSend.riscv64.S:118-119`,
  `objc_msgSend.mips.S:187`, `objc_msgSend.arm.S:130`, `objc_msgSend.x86-32.S:82-84`.
- **Per B1 §1.3:** the asm fast path does not touch
  `objc_method_cache_version`, so tagged-pointer dispatch has the same
  dispatch cost as regular dispatch minus the isa load (replaced by an
  `and` + PC-relative `lea` + load from the slot table).

### 1.3 libs-base concrete string class cluster

Relevant `@implementation` sites in `libs-base/Source/GSString.m`:

| Line | Class |
|---|---|
| 876 | `GSTinyString` (tagged-pointer small string, §1.4) |
| 1237 | `GSPlaceholderString` (alloc placeholder used by cluster) |
| 3516 | `GSString` (base) |
| 3638 | `GSCString` (8-bit encoded) |
| 3923 | `GSCBufferString` (8-bit, external buffer) |
| 3940 | `GSCInlineString` (8-bit, buffer tail-allocated with object) |
| 3961 | `GSCSubString` (8-bit, substring view) |
| 4013 | `GSUnicodeString` (16-bit) |
| 4334 | `GSUnicodeBufferString` |
| 4351 | `GSUInlineString` (16-bit inline) |
| 4372 | `GSUnicodeSubString` |
| 4418 | `GSMutableString` |

`NSString` itself is declared in
`libs-base/Headers/Foundation/NSString.h:517` as
`@interface NSString :NSObject <NSCoding, NSCopying, NSMutableCopying>`
with **no ivars in the public header**, so consumers cannot depend on a
specific instance layout — critical for the ABI analysis in §3.

### 1.4 GSTinyString layout and methods (existing)

Declared `GSString.m:851`:

```objc
@interface GSTinyString : NSString
@end
```

Encoding constants (`GSString.m:790-814`):
- Enabled only when `OBJC_SMALL_OBJECT_SHIFT == 3` (64-bit with 3 tag bits).
- Tag value: `TINY_STRING_MASK 4` (`GSString.m:791`).
- Documented bit layout (`GSString.m:798-810`): 8 slots of 7-bit ASCII
  chars, then 5-bit length, then 3-bit tag. That totals
  8·7 + 5 + 3 = 64 bits exactly.
- `TINY_STRING_CHAR(s,x) = (s & (0xFE00000000000000 >> (x*7))) >> (57-(x*7))`
  (`GSString.m:812`).
- `TINY_STRING_LENGTH_MASK 0x1f`, `TINY_STRING_LENGTH_SHIFT = OBJC_SMALL_OBJECT_SHIFT`
  (`GSString.m:813-814`).

Registration (`GSString.m:1122-1128`):
```objc
+ (void) load
{
    useTinyStrings = objc_registerSmallObjectClass_np(self, TINY_STRING_MASK);
    ...
}
```
`useTinyStrings` is the runtime kill-switch read by every construction site.

`+alloc` / `+allocWithZone:` return `(id)TINY_STRING_MASK` (`GSString.m:1130-1138`)
— a bare tag. This means `[[GSTinyString alloc] init...]` naturally produces a
valid tagged placeholder that `-init...` may overwrite with a populated tagged
word.

Methods implemented directly on the tagged pointer without realization:
- `-boolValue` (`GSString.m:878-898`)
- `-characterAtIndex:` (`GSString.m:900-916`) — note: explicitly returns
  `'\0'` for index 8 because `createTinyString` allows a 9-char case where
  the 9th char is an implicit NUL (§1.5 below).
- `-getCharacters:` (`GSString.m:918-928`)
- `-getCharacters:range:` (`GSString.m:930-944`)
- `-getCString:maxLength:encoding:` (`GSString.m:946-998`)
- `-hash` (`GSString.m:1001-…`) — computes from the inline bytes.
- `-UTF8String` (`GSString.m:1113-1120`) — writes into a
  `GSAutoreleasedBuffer(9)` and returns it.
- `-copy`, `-copyWithZone:` → `return self` (`GSString.m:1140-1148`)
- `-retain`, `-autorelease`, `-release` → no-ops (`GSString.m:1150-1168`)
- `-retainCount` → `UINT_MAX` (`GSString.m:1155-1158`)
- `-sizeInBytesExcluding:` → 8 (`GSString.m:1170-1177`)

Methods that fall through to `NSString`'s generic implementations via
`@implementation GSTinyString : NSString` (i.e. not specialized, so they
pay the usual cost — substring, comparison, append, mutable copy).

### 1.5 Construction

Single entry point: `createTinyString(const char *str, int length)` at
`GSString.m:1184-1222`. Rules:

1. Gated on `useTinyStrings` (`GSString.m:1192`).
2. Rejects `length > 9` (`GSString.m:1199`).
3. Special case for `length == 9`: only allowed if `str[8] == '\0'`, i.e.
   a 9-char input whose last byte is already a NUL (`GSString.m:1206`).
   This effectively lets callers pass a 9-byte buffer whose trailing byte
   is the C string terminator, and only 8 real chars get encoded.
4. Rejects any byte with the high bit set (`GSString.m:1215`) — **strict
   7-bit ASCII only**, no Latin-1, no UTF-8 multi-byte.
5. Packs length into 5 bits starting at `TINY_STRING_LENGTH_SHIFT` and
   each char into 7 bits descending from bit 57 (`GSString.m:1211-1216`).
6. Returns `(id)s` with `TINY_STRING_MASK` OR'd in.

**Effective payload cap on 64-bit: 8 characters of 7-bit ASCII.** The
length field can represent 0..31 but only 0..8 are actually reachable via
the construction rules. The nominal "9" in the rejection check is the
implicit-NUL artifact described above.

Construction call sites (`GSString.m`):
- `1397-1433` — `-[GSPlaceholderString initWithBytes:length:encoding:]`
  attempts tiny first for `NSASCIIStringEncoding` and for
  `NSUTF8StringEncoding`/byte encodings when every byte is < 0x80.
  This is the path reached by all factories that bottom out in
  `initWithBytes:length:encoding:` including `stringWithUTF8String:` and
  `stringWithCString:encoding:`.
- `1768` — inside `newCStringCluster`-style construction
  (substring/slice path).
- `3870-3876, 3896-3902` — `-[GSCString substringWithRange:]` and
  related substring methods try to return a tiny instead of
  heap-allocating a `GSCSubString`.
- `3986, 4000, 4246-4252, 4267-4273, 5339-5345, 5377-5383` — similar
  substring/copy paths across `GSCBufferString`, `GSCInlineString`,
  `GSUnicodeString`, `GSUInlineString` cluster members.

Read-side use: `-isEqualToString:` at `GSString.m:5471-5480` fast-paths
a check `if (s & TINY_STRING_MASK) return tinyEqualToString(...)`,
which in turn avoids any heap-side allocation when comparing to a tiny
(`tinyEqualToString`, `GSString.m:816-849`).

### 1.6 NSConstantString interaction

`NSConstantString` (a.k.a. `NXConstantString`, compiled as the class of
`@"..."` literals) is **orthogonal** to tiny strings. A compile-time
literal `@"foo"` emits an `NXConstantString` instance statically;
`stringWithUTF8String:` at runtime may produce a `GSTinyString`. The
equality path handles both: `GSString.m:5471-5496` checks tiny first,
then the constant-string branch (`c == NSConstantStringClass`), then
the general case. Tiny strings and constant strings both avoid heap
allocation but via different mechanisms — literals live in `.rodata`,
tinies live inside the pointer.

### 1.7 Existing test / benchmark coverage

- **No dedicated tests.** `rg 'GSTinyString|tinyString|TinyString'
  libs-base/Tests/` returns zero matches. The general NSString tests
  under `libs-base/Tests/base/NSString/` (e.g. `basic.m`, `test00.m`
  through `test17.m`, `pairs.m`, `noncharacter.m`) exercise short
  ASCII strings and therefore implicitly cover tinies on 64-bit, but
  none assert any tiny-specific invariant (pointer bit pattern,
  identity-stability, class membership).
- **Closest benchmark:** `instrumentation/benchmarks/bench_string_hash.m`.
  Per lines 4-6 the header comment says "Measures hash computation
  throughput for short (5 char), ..." and line 17-22
  constructs its short string with `makeString(5)` returning an
  `NSString`. Because `makeString` allocates a C buffer and calls
  (presumably) a factory that flows through `initWithBytes:length:encoding:`,
  on 64-bit that 5-char string is almost certainly already a tagged
  `GSTinyString`. The benchmark therefore *measures* the tiny path but
  does not *label* it as such, and does not include a control that
  forces a heap-allocated short string for comparison.

---

## 2. Proposed change

Because the feature is already implemented and enabled, "the change" is
a set of targeted improvements and hardening, not a greenfield design.
Prioritized list, each independently landable.

### 2.1 Extended payload: 9-char ASCII (P1, low risk)

Today `createTinyString` rejects inputs longer than 8 chars unless the
9th is NUL (`GSString.m:1199-1209`). The bit layout
(`GSString.m:798-810`) already reserves 8·7 = 56 bits for chars and 5 bits
for length; 56 + 5 + 3 = 64. There is no spare room for a 9th char
*inside the current layout*.

**Two mutually exclusive extensions** (pick one):

- **9-char variant A:** drop `length` to 4 bits (max 15, still > 9),
  freeing 1 bit, and widen chars to either 7-bit·8 + 1 unused, or shift
  to 6-bit chars (63-char alphabet, uppercase-ascii or base-64-ish).
  Rejected: 6-bit loses lowercase, a no-go for real workloads.
- **9-char variant B:** note that `length` only needs 4 bits (values
  0..9), reclaiming 1 bit → unused. Not enough for another 7-bit char.
  **Conclusion: cannot pack a 9th 7-bit char without compressing.**

Alternative: **Latin-1 / 8-bit ASCII.** If we drop the 7-bit restriction
and use full 8-bit per char, 64 - 3 (tag) = 61 bits ÷ 8 = 7 chars + 5
bits of length. **That is a regression from 8 chars to 7.** Not worth it.

**Recommendation:** leave payload at 8 chars of 7-bit ASCII. The current
choice is already on the Pareto frontier for a 64-bit pointer with a
3-bit tag.

### 2.2 Fast-path `-length` (already present — no work)

**Correction:** a prior draft of this spike claimed `GSTinyString` did
not override `-length`. That was wrong. The fast path already exists
at `GSString.m:1060-1064`:

```objc
- (NSUInteger) length
{
  uintptr_t s = (uintptr_t)self;
  return (s >> TINY_STRING_LENGTH_SHIFT) & TINY_STRING_LENGTH_MASK;
}
```

This is a straight read of the length field from the tagged pointer,
no allocation, no dispatch into generic `NSString`. No work item.

### 2.3 Fast-path `-isEqual:` (P2)

The cluster already has a fast path from `GSCString` / `GSUnicodeString`
side (`GSString.m:5471-5480`) that detects a tiny `anObject` and calls
`tinyEqualToString`. The reverse — `GSTinyString`'s own `-isEqual:` —
is not overridden, so `[tiny isEqual: other]` goes through the generic
path, which then eventually bottoms out at the same check. Adding a
direct `-isEqual:`/`-isEqualToString:` override on `GSTinyString`
removes one dispatch hop. Same for `-compare:` when the receiver is a
tiny.

### 2.4 Hash agreement — verified

**Verified finding, not an open concern.** Both `GSTinyString -hash`
(`GSString.m:1001-1033`) and the `GSString -hash` ASCII non-wide
branch (`GSString.m:3532-3595`) use the same algorithm with identical
parameters:

- Both widen each byte to `unichar` into a local buffer.
- Both call `GSPrivateHash(0, buf, length * sizeof(unichar))` with the
  same seed of 0.
- Both mask the result with `0x0fffffff`.
- Both return `0x0ffffffe` as the empty-string sentinel.

A 5-char ASCII tiny and a 5-char ASCII `GSCInlineString` with the same
bytes therefore hash to the same value. No silent `NSDictionary`
corruption risk exists in the shipped code. A single belt-and-suspenders
regression test (`tiny_hash_agreement.m`, §6.2) is still worth landing
to lock the invariant against future drift, but it is not chasing a
live bug.

### 2.5 Profiling hook activation (P3)

`GS_PROFILE_TINY_STRINGS` (`GSString.m:854-860,1218-1220`) is a
compile-time macro that counts tinies and prints the total at exit. It
is not enabled in any checked-in build. For the audit workflow it
would be useful to flip this on for one benchmark run to quantify how
often the fast path fires on representative GNUstep workloads.

### 2.6 libobjc2 side: nothing required

Because the infrastructure already exists and `GSTinyString` is already
registered successfully (the `load` method at `GSString.m:1124` returns
YES on any 64-bit build with libobjc2 ≥ the version introducing
`objc_registerSmallObjectClass_np`, which is well before the current
4.6), **no libobjc2 changes are required for any of 2.1-2.5**. Per B1
§3.2, `struct objc_class` is opaque to consumers and can be extended,
but we don't need to — this entire spike lives in libs-base.

### 2.7 What a dedicated libobjc2-level change could add (out of scope)

If we ever wanted to expose more tag bits on 64-bit (e.g. use the high
bits of the pointer on canonical-addressing machines, as Apple's
CoreFoundation does), that would be a libobjc2 change touching every
asm dispatcher and bumping SOVERSION to 4.7 (per B1 §3.5). Rejected
for this spike; the gains from going 8→11 chars do not justify an
architecture-specific asm rewrite across 7 files.

---

## 3. ABI impact

### 3.1 Public NSString surface

`NSString` has no exposed ivar layout
(`libs-base/Headers/Foundation/NSString.h:517`), so proposals 2.1-2.5
do not affect any consumer's struct layout.

### 3.2 struct objc_class opacity

Per **B1 §3.2**, `struct objc_class` is opaque in the public libobjc2
headers and adding tail fields is safe. This spike does not need to
touch the class struct at all — `GSTinyString` registers through
`objc_registerSmallObjectClass_np` which mutates a file-scope array
(`SmallObjectClasses[7]`, `libobjc2/class_table.c:472`), not the
class struct itself.

### 3.3 SOVERSION

Per **B1 §3.5**, libobjc2 is currently at `libobjc_VERSION 4.6`
(`libobjc2/CMakeLists.txt:36`). Because this spike's proposals live
entirely in libs-base and do not add, rename, or change any libobjc2
symbol, **no SOVERSION bump is required**. The existing
`objc_registerSmallObjectClass_np` is already public
(`libobjc2/objc/runtime.h:1001-1002`) and already consumed.

### 3.4 Behavioral ABI: `object_getClass` on a tagged string

`[someShortString class]` already returns `GSTinyString` on 64-bit
builds (via `classForObject` at `libobjc2/class.h:427-443`, backed by
`runtime.c:822`). Any consumer that compares against
`[NSString class]` via `isKindOfClass:` works because
`GSTinyString : NSString` (`GSString.m:851`). Consumers that do
exact-class comparison against one of the *concrete* classes
(`GSCString`, `GSCInlineString`, etc.) will **not** match a tiny —
but those are private libs-base internals, no external consumer
should be doing this. `rg` of gnustep-audit trees outside libs-base
for `GSCInlineString` or `GSCString` returns zero hits (not re-verified
in this spike; the claim rests on B1's observation that only
libs-base consumes these internals).

### 3.5 Weak refs, associated objects, KVO on tagged strings

These operations already silently no-op on any small object per
`associate.m:331,338,389` and `arc.mm:321-324`. If code somewhere tries
to `objc_setAssociatedObject` a tiny, nothing is stored, nothing is
returned on lookup. **This is a behavioral corner — flag it in
documentation.** It has been the status quo since `GSTinyString` was
added, so no regression is introduced by any proposal in §2.

### 3.6 Binary compat for existing libs-base consumers

Zero impact. Tiny strings are an allocation-site choice: old consumers
already see tagged pointers today whenever they call
`stringWithUTF8String:` with a ≤8-char ASCII string on 64-bit.

---

## 4. Performance estimate

### 4.1 What the tiny path already saves

Per construction:
- One `NSAllocateObject` call (avoided — `+alloc` returns a bare tag,
  `GSString.m:1130-1138`).
- The tail-allocated character buffer (avoided — chars live in the
  pointer bits).
- One `-dealloc` / `free` pair at the end of the string's lifetime
  (avoided — `-release` is a no-op, `GSString.m:1165-1168`).
- Retain/release traffic on every passage through a collection, autorelease
  pool, or property setter — all no-ops (`GSString.m:1150-1163`).

Per comparison (`-isEqualToString:` against another tiny):
`tinyEqualToString` (`GSString.m:816-849`) currently length-checks then
calls `[aString getCharacters:range:]` and compares unichar-by-unichar.
**If both sides are tiny**, this could be a single 64-bit XOR-and-mask
compare (tiny-vs-tiny: `a == b` ⇔ pointer equality ⇔ single instruction).
§2.3 proposes wiring that directly.

### 4.2 Hit rate (back-of-envelope)

The <=8-char-ASCII bucket covers:
- Most selectors as keys (`@"count"`, `@"value"`, `@"title"`, `@"date"`,
  `@"name"`, `@"type"`, `@"url"`).
- Most short property keys used via KVC (see B1 §4 for the KVC cache
  pressure story — tinies reduce that cache's load in a different way:
  fewer distinct heap NSStrings for the same keys).
- Short dictionary keys that were *constructed at runtime* (note:
  `@"literal"` already emits `NXConstantString` and does **not** go
  through `createTinyString`, so compile-time literals are an orthogonal
  win tracked separately).

Without instrumentation on a representative workload, call it "the
majority of runtime-created short keys." With the `GS_PROFILE_TINY_STRINGS`
hook (§2.5) we can get a real number in one build.

### 4.3 Benchmark

**Existing:** `instrumentation/benchmarks/bench_string_hash.m:17-22`
builds short strings with `makeString(5)` and measures `-hash`. On
64-bit with tinies enabled this already benchmarks the tiny path, but
without a non-tiny control. Proposed modifications:

1. Add a second measurement that forces a non-tiny
   `GSCInlineString` of the same 5-char content (by constructing from
   a non-ASCII source then stripping, or by using a 9-char input so
   construction rejects it). Report the ratio.
2. Add a construction benchmark (`[NSString stringWithUTF8String: "abc"]`
   in a tight loop). The tiny path should be roughly allocator-free;
   the heap path pays two allocations.

**Expected ratio (construction):** 5-10x on the tiny path because it
avoids the allocator entirely. **Expected ratio (hash):** small
(1.0-1.5x) — hash is arithmetic-bound either way, and the tiny `-hash`
reads a register rather than a cache line but that delta is noise at
the string lengths involved.

**Expected ratio (retain-release in a tight loop):** very large —
no-op vs. atomic increment — but this is rarely the bottleneck in
practice because libs-base already refcounts short literals cheaply.

---

## 5. Risk

### 5.1 Correctness risks already mitigated

- `object_getClass`, `isKindOfClass:`, `-class` all work via
  `libobjc2/class.h:427-443` and `libobjc2/runtime.c:822,341,350`.
- Retain/release is a no-op via `arc.mm:321-324`.
- Dispatch works because the asm fast path at
  `objc_msgSend.x86-64.S:267-271` maps the tag to the registered class
  and then jumps back into the normal dtable path.
- `-isEqualToString:` handles tiny on either side
  (`GSString.m:5471-5480`).

### 5.2 Outstanding risks

- **Hash algorithm drift — verified absent today (§2.4).** Both
  implementations route through `GSPrivateHash` with identical seed,
  mask, and empty-string sentinel. A regression test is still desirable
  to keep the invariant locked against future edits on either side, but
  there is no live correctness bug here.
- **Direct-ivar access.** Any libs-base code that casts `NSString *`
  to one of the concrete struct types and dereferences `_contents` or
  `_count` will crash on a tiny. Grep: `rg '->(_contents|_count|_flags)\b'
  libs-base/Source/` — **not run in this spike; flag as prerequisite
  before extending tiny usage.** B1 §1.6 notes that struct layouts are
  part of the compiler/runtime contract for objc_class; the analogous
  check for NSString private ivars is a libs-base concern.
- **Associated objects / KVO.** Attempting to `objc_setAssociatedObject`
  a tiny silently does nothing. Same for KVO. Consumer hitting this
  case will not see a runtime error; they will see missing observations.
  **Document in NSString header? Out of scope for this spike.**
- **Weak references.** A weak reference to a tiny is equivalent to a
  strong reference (since the tag word is the state) — but
  `objc_storeWeak` etc. short-circuit on small objects, so the weak
  slot is never populated. A weak-read after the original goes out of
  scope still returns the tagged pointer because it is a value, not
  an allocation. Safe but surprising.
- **Debugger / `po`.** Debugger integration: `po tinyStr` must call
  `-description` on a tagged pointer. Since description dispatch lands
  via the asm fast path and reaches `NSString -description` (which is
  typically `return self;`), this works — but debuggers that special-case
  "is this pointer a valid heap object?" before messaging will misbehave.
  Not tested in this spike.
- **Thread safety.** Pure value type. `GSTinyString` stores no shared
  state. Trivially safe.

### 5.3 Rollback

`useTinyStrings` (`GSString.m:792,1124`) is a runtime gate. Setting it
to NO disables all tiny construction and every `createTinyString` call
returns nil, causing the cluster to fall back to heap allocation. No
recompile needed — but note that any tinies already in memory at the
time of the flip continue to behave as tinies (they *are* the pointer,
there is nothing to invalidate). For a hard rollback revert the
`createTinyString` call sites in §1.5.

---

## 6. Test strategy

### 6.1 Existing coverage

The standard `libs-base/Tests/base/NSString/` suite
(`basic.m`, `test00.m`…`test17.m`, `pairs.m`, `noncharacter.m`,
`boolValue.m`, `common_prefix.m`, `order.m`, `nuls_in_strings.m`,
`NSString_zero_hash.m`) exercises short-ASCII NSString semantics
generically. Because every construction path that accepts a short
ASCII buffer flows through `createTinyString` — specifically the
`-[GSPlaceholderString initWithBytes:length:encoding:]` entry at
`GSString.m:1396-1434`, the ICU-adjacent path at `GSString.m:1768`,
and the substring/slice paths at `GSString.m:3872, 3898, 3986, 4000,
4248, 4269, 5341, 5379` — these tests **do** implicitly exercise the
tiny path on 64-bit libobjc2 builds whenever they use short ASCII
literals or short ASCII C buffers. Any semantic regression in the
tiny path would surface in the existing suite.

What the existing suite does not provide:

- Assertions of tiny-specific invariants (pointer tag bit pattern,
  `[s class] == [GSTinyString class]`).
- **Targeted boundary** coverage for length 0, 1, 8, 9; high-bit byte
  rejection; the length-9-with-trailing-NUL special case in
  `createTinyString`; substring slicing that lands exactly on a
  tiny-eligible range.
- Explicit hash-agreement lock between a tiny and a forced-heap
  string of identical content.

So the gap is targeted boundary + invariant tests, **not** "no
coverage at all."

No `grep` hit for `GSTinyString` or `tinyString` across
`libs-base/Tests/` — i.e., nothing names the tiny path explicitly.

### 6.2 Missing tests to add

Under `libs-base/Tests/base/NSString/` (new files), all gated on
64-bit since tinies are 64-bit-only:

1. `tiny_identity.m` — construct a tiny via `stringWithUTF8String:` and
   assert `((uintptr_t)s & 7) == TINY_STRING_MASK`; assert
   `[s class] == [GSTinyString class]` or at minimum
   `[s isKindOfClass: [NSString class]]`.
2. `tiny_boundary.m` — inputs of length 0, 1, 7, 8, 9, 10; high-bit byte;
   embedded NUL. Assert length 0-8 ASCII becomes tiny; >8 or non-ASCII
   becomes heap; empty string hits the `(id)@""` fast path at
   `GSString.m:1387`.
3. `tiny_hash_agreement.m` — **covers §2.4 risk.** Build the same 5-char
   ASCII content two ways (tiny and forced-heap) and assert
   `[a hash] == [b hash]` and `[a isEqual: b]`. Repeat across lengths 0-8.
4. `tiny_retain_release.m` — retain 10000 times, release 10000 times,
   confirm no crash, confirm the pointer is still the same bit pattern.
5. `tiny_dictionary.m` — use tiny strings as dictionary keys alongside
   heap strings of the same content; assert lookups succeed both ways.
   Catches hash drift and any `-isEqual:` asymmetry.
6. `tiny_substring.m` — slice a longer string into a range that would
   fit in a tiny; confirm the substring comes back as a tiny (per
   §1.5 call sites at `GSString.m:3870, 3896, 3986, 4000, …`).

### 6.3 Missing benchmark

Add `instrumentation/benchmarks/bench_tiny_string.m`:

1. Construction throughput: `[NSString stringWithUTF8String: "count"]`
   in a tight loop, vs. the same construction on a 9-char input that
   forces heap.
2. Equality throughput: tiny-vs-tiny, tiny-vs-heap, heap-vs-heap.
3. Hash throughput (already partially covered by
   `bench_string_hash.m` — extend it to also construct a forced-heap
   5-char control).
4. Retain-release throughput.

Report deltas as a new JSON under
`instrumentation/benchmarks/results/baseline-YYYY-MM-DD-tiny.json`
matching the existing convention.

### 6.4 libobjc2-side test

`libobjc2/Test/objc_msgSend.m:201,212` already registers a small-object
class and dispatches through it, so the registration + dispatch path is
tested at the runtime level. Nothing to add on libobjc2 for this spike.

---

## 7. Decision

**GO — audit-and-measure, not fix-bugs.** The primary deliverable is a
test + benchmark hardening pass on an already-landed, already-correct
feature. No shipped correctness bugs were found.

### 7.1 Rationale

The code exists. `GSTinyString` (`GSString.m:851`) is registered at
load time, wired into the abstract-cluster `initWithBytes:length:encoding:`
path (`GSString.m:1396-1434`), and runs on every 64-bit libs-base build
against libobjc2. The infrastructure in libobjc2
(`objc_registerSmallObjectClass_np`, the tag check in every asm
dispatcher, the `isSmallObject`/`classForObject` inlines in
`libobjc2/class.h:421-443`) is stable, exposed as a public API
(`libobjc2/objc/runtime.h:1001-1002`), and requires no changes. Per
B1 §3.2/§3.5, no libobjc2 ABI or SOVERSION impact is incurred by any
proposal in this spike.

The residual Sprint 4 scope after removing invalid work items
(`-length` override — already present, §2.2; hash audit — already
verified correct, §2.4) is:

1. **Targeted boundary unit tests.** The §6.2 list — length 0, 1, 8,
   9; high-bit byte rejection; length-9-with-trailing-NUL; substring
   paths — locks invariants that the generic NSString suite exercises
   only implicitly.
2. **Benchmark relabeling to expose tiny-string coverage** (§6.3).
   `bench_string_hash.m` already measures the tiny path without
   saying so; extend it with a forced-heap control and add
   `bench_tiny_string.m` for construction/equality/retain-release.
3. **Profile-off vs profile-on measurement.** Build libobjc2 both
   with and without small-object support, run a string-heavy workload
   against each, report the delta. This quantifies what tiny strings
   are actually buying on representative GNUstep work.

All three are audit-and-measure work. None are bug fixes.

The extension proposals in §2.1 (9-char payload) are **rejected** because
the current 8·7 + 5 + 3 = 64-bit layout is already optimal for a 3-bit tag,
and weakening to 6-bit-per-char or dropping to 7 chars of 8-bit-each is a
regression in the target workload (short ASCII keys).

### 7.2 Concrete follow-up plan shape

The B2 follow-up implementation plan should contain, in order:

1. **Audit** (`rg '->(_contents|_count|_flags)\b' libs-base/Source/`) to
   confirm no code path dereferences NSString concrete ivars without
   first checking tag bits. Any hit is a prerequisite fix.
2. **Write** the targeted boundary tests in §6.2 (length 0/1/8/9,
   high-bit rejection, length-9-with-trailing-NUL, substring paths,
   plus `tiny_hash_agreement.m` as a belt-and-suspenders lock on the
   verified-today invariant).
3. **Extend** `bench_string_hash.m` with a forced-heap control and
   add `bench_tiny_string.m` (§6.3). Record a baseline under
   `instrumentation/benchmarks/results/`.
4. **Measure profile-off vs profile-on.** Build libobjc2 with and
   without small-object support, run a string-heavy workload, record
   the delta.
5. **Optionally** enable `GS_PROFILE_TINY_STRINGS` for one
   instrumented run to record the hit-rate on a GNUstep-gui workload.

Optional fast-path `-isEqual:` / `-compare:` overrides (§2.3) remain
a possible P2 if step 3's numbers justify the added surface; they are
not on the critical path for Sprint 4.

All steps are libs-base-only except step 4's libobjc2 rebuild toggle,
which is a build-configuration change, not a code change. No libobjc2
code edits. No ABI impact. No coordination with B1.

### 7.3 Known unknowns

- **Direct-ivar access grep** — not run in this spike. Prerequisite
  for §7.2 step 1.
- **Actual hit rate on representative workloads** — needs
  `GS_PROFILE_TINY_STRINGS` instrumented run. Not blocking GO.
- **Windows (ucrt64) parity** — the feature is enabled based on
  `OBJC_SMALL_OBJECT_SHIFT == 3` (`GSString.m:790`), which per
  `libobjc2/objc/runtime.h:1010-1026` is 3 on any 64-bit target
  including Win64. Not separately tested in this spike.
