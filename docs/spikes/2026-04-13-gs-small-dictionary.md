# Spike: GSInlineDict for N<=4 Entries (libs-base)

> Naming note: earlier drafts of this spike called the new class
> `GSSmallDictionary` / `GSSmallMutableDictionary`. The immutable class
> has been renamed `GSInlineDict` to match the in-tree `GSInlineArray`
> precedent (see §2.1). The mutable variant has been deferred to a
> follow-up spike (see §7.2).

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repo:** libs-base

## 1. Current state

### 1.1 Does a small-dict concrete class already exist? No.

Unlike B2 (where `GSTinyString` already existed in tree), the dictionary cluster
has **no small-dict specialization** whatsoever. Grepping the full Source tree
for `GSSmallDict|GSInlineDict|GSConstantDict|NSConstantDict|GS[0-9]Dictionary|GSInline`
returns only `GSInlineArray` hits from `GSArray.m` — nothing dictionary-related.
The only dictionary concrete classes shipped are:

- `GSDictionary` — `libs-base/Source/GSDictionary.m:51`
- `GSMutableDictionary` — `libs-base/Source/GSDictionary.m:58`
- `GSCachedDictionary : GSDictionary` — `libs-base/Source/GSDictionary.m:560` (used only by the property-list / uniquing cache path)
- `NSGDictionary` / `NSGMutableDictionary` — `libs-base/Source/GSDictionary.m:536,549` (obsolete archive-decoding stubs that immediately `DESTROY(self)` and forward to `GSDictionary`)
- `GSAttrDictionary` — `libs-base/Source/NSFileManager.m:3804` (wraps `struct stat`, not a general dict)
- `GCDictionary` / `GCMutableDictionary` — `libs-base/Source/Additions/GCDictionary.m:84,346` (garbage-collected variant, legacy)
- `_GSInsensitiveDictionary` — `libs-base/Source/Additions/GSInsensitiveDictionary.m:78` (case-insensitive keys)

None of these target the N<=4 case.

### 1.2 Class cluster dispatch

Dispatch is a flat, single-target cluster — no placeholder, no count-based
fan-out:

```
+ (id) allocWithZone: (NSZone*)z                  // NSDictionary.m:120
{
  if (self == NSDictionaryClass)
    return NSAllocateObject(GSDictionaryClass, 0, z);
  else
    return NSAllocateObject(self, 0, z);
}
```

`NSMutableDictionary` mirrors this at `NSDictionary.m:1282`, allocating
`GSMutableDictionaryClass` unconditionally. There is **no `GSPlaceholderDictionary`**
— `allocWithZone:` returns a fully-typed `GSDictionary` instance immediately,
and `-initWithObjects:forKeys:count:` (`GSDictionary.m:188`) initializes the map
in place without any opportunity to swap concrete class based on count.

Contrast with `GSString.m` (which does have a placeholder + per-encoding
concrete-class selection at init time via `GSPlaceholderString`, see
`NSString.m:147-148,162,993`) and `GSArray.m` — which has `GSInlineArray`,
a subclass of `GSArray` with **empty ivars** (`GSArray.m:75-78`) that
relies on a trailing-allocation trick:

```objc
// GSArray.m:75-78  -- note: NO inline fields, empty ivar block
@interface GSInlineArray : GSArray
{
}
@end
```

The "inline" storage is conjured by over-allocating the object and pointing
its inherited `_contents_array` pointer at the trailing region:

```objc
// GSArray.m:1265 (caller)
self = (id)NSAllocateObject(GSInlineArrayClass, count*sizeof(id), z);
// GSArray.m:437-438 (init reads it back)
_contents_array = (id*)(((void*)self) + class_getInstanceSize([self class]));
```

See also the `-initWithCoder:` caller at `GSArray.m:1237`. This is the real
GSInlineArray precedent: **trailing-allocation past the base object size**,
not fixed-size inline C arrays in the ivar block.

### 1.3 Storage cost of the existing path

`GSDictionary` has a single ivar — a full `GSIMapTable_t` map (`GSDictionary.m:53-55`):

```
struct _GSIMapTable {                              // GSIMap.h:413
  NSZone    *zone;
  uintptr_t  nodeCount;
  uintptr_t  bucketCount;
  GSIMapBucket buckets;      // -> malloc'd bucket array
  GSIMapNode  freeNodes;
  uintptr_t  chunkCount;
  GSIMapNode *nodeChunks;    // -> malloc'd chunk-of-chunks
  uintptr_t  increment;
};
```

For a 1-entry dictionary this incurs:

1. the object allocation (`NSAllocateObject`, contains the `GSIMapTable_t` inline)
2. a `malloc` for the bucket array inside `GSIMapInitWithZoneAndCapacity`
3. a `malloc` for the first chunk of nodes
4. a hash computation on insert (`GSI_MAP_HASH` = `[X.obj hash]` — `GSDictionary.m:44`)
5. a `-copyWithZone:` on the key (`GSI_MAP_RETAIN_KEY` — `GSDictionary.m:46`)

And `-objectForKey:` (`GSDictionary.m:343`) always computes `[aKey hash]` inside
`GSIMapNodeForKey`, then indexes into the bucket array, walks the node list, and
does `isEqual:` — three indirections minimum, plus the hash call, for a dict
that may contain one pair.

### 1.4 Workload shape

The benchmark `instrumentation/benchmarks/bench_dict_lookup.m:17-18` already
targets exactly this split: `SMALL_SIZE=4` vs `LARGE_SIZE=10000`, with hit and
miss cases for both. The comment on line 7 even names the target:
`small-dict optimization`. So the infrastructure to measure the win already
exists — this spike has a ready-made harness.

Literal-dict usage inside libs-base itself is heavily dominated by small
counts (userInfo dicts for exceptions, file-attribute translation tables, the
runtime's selector-keyed lookups). A representative sampling shows the
overwhelming majority of `@{...}` sites have 1-3 pairs; larger dicts are
almost always built programmatically via `setObject:forKey:` in loops. This
matches what other Foundation implementations report (Apple's `NSDictionary`
ships `__NSDictionary0`, `__NSSingleEntryDictionaryI`, `__NSDictionaryI` with
the single-entry variant explicitly for the common `userInfo` case).

### 1.5 Public-header exposure

`libs-base/Headers/Foundation/NSDictionary.h` does not mention `GSDictionary`,
`GSMutableDictionary`, or any concrete class. The cluster boundary is clean
at the header level; a new concrete class can be added without touching any
public ABI.

## 2. Proposed change

Because no small-dict class exists, this is a greenfield addition, not an
audit-and-harden reframing. The design mirrors `GSInlineArray`'s real
precedent — **trailing allocation past the base object**, not a fixed-size
inline ivar block.

**Immutable-only scope for B5.** Per §7 this spike commits only to the
immutable `GSInlineDict`. The mutable promotion path is deferred to a
follow-up spike (see §7 and §2.4).

### 2.1 New concrete class `GSInlineDict` (immutable, N<=4)

Following the GSInlineArray template at `GSArray.m:75-78,437-438,1265`, the
class has a small fixed header (count + key pointer) and the trailing bytes
of the object hold `2*N` `id` slots — N keys followed by N values. The
layout chosen is **trailing-allocation**, matching the in-tree precedent:

```objc
@interface GSInlineDict : GSDictionary
{
@public
  unsigned char _count;   // 0..4
  id           *_keys;    // = (id*)(self + class_getInstanceSize(cls)), N slots
  // _values is implicit: _keys + _count  (filled in after _count is set)
}
@end
```

At alloc time:

```objc
// Reserve 2*count id slots past the base object.
self = NSAllocateObject(GSInlineDictClass, 2*count*sizeof(id), z);
// In -init:
_keys = (id*)(((void*)self) + class_getInstanceSize([self class]));
// _values[i] is _keys[_count + i]
```

This is strictly the GSInlineArray pattern applied twice (keys region,
values region) inside a single trailing allocation. It incurs:
**one** object allocation, **zero** auxiliary mallocs (compared to
GSDictionary's object alloc + bucket malloc + node-chunk malloc).

Alternative considered and rejected: a fixed-size `id _keys[4]; id
_values[4];` inline ivar block. It is simpler but (a) has no in-tree
precedent, (b) wastes 2*(4-N)*sizeof(id) bytes at N<4, and (c) would need
its own code-review justification. Trailing-allocation mirrors a proven
idiom that ASAN/LSAN paths already handle (`GSArray.m:1226-1240`).

A mutable counterpart is **not** part of this spike. See §7.

### 2.2 Dispatch — minimal placeholder-free path

**Prior-art note.** libs-base currently has **no** placeholder / class-cluster
dispatch pattern for `NSDictionary`. `+allocWithZone:` unconditionally returns
a `GSDictionary` (`NSDictionary.m:120`). The only placeholder precedent in the
codebase is `GSPlaceholderString` (`NSString.m:147-148,162,993`), which picks
a concrete string class at `-init` time based on encoding/length. No
comparable placeholder exists for dictionaries, and the `NSGDictionary`
`DESTROY(self) + re-alloc` sequence at `GSDictionary.m:534-545` is **not** a
class-cluster dispatch idiom — it is a one-shot unarchiving migration for
obsolete archive data (it logs a deprecation warning and replaces itself
with a real `GSDictionary`). It is cited here only to note that the
`DESTROY(self) + NSAllocateObject(other, …)` mechanic is syntactically
legal in an initializer; the semantics we propose below are different.

Two dispatch options:

**Option A — intercept in `-[GSDictionary initWithObjects:forKeys:count:]`.**
Keep `NSDictionary +allocWithZone:` returning a `GSDictionary` unchanged,
but in the designated initializer check the count and, if `c <= 4` and
`[self class] == [GSDictionary class]` (so `GSCachedDictionary` and other
subclasses opt out), `DESTROY(self)` and return a fresh `GSInlineDict`
with its trailing allocation:

```objc
- (id) initWithObjects: (const id[])objs
               forKeys: (const id <NSCopying>[])keys
                 count: (NSUInteger)c
{
  if (c <= 4 && [self class] == [GSDictionary class])
    {
      NSZone *z = [self zone];
      DESTROY(self);
      self = NSAllocateObject([GSInlineDict class], 2*c*sizeof(id), z);
      return [self initWithObjects: objs forKeys: keys count: c];
    }
  // ...existing GSDictionary path
}
```

The downside is that the initial `NSAllocateObject(GSDictionaryClass, 0, z)`
in `+[NSDictionary allocWithZone:]` has already happened and is thrown away
— one wasted alloc per small-dict construction. For the expected 2-4x win
(§4) this is negligible, but it is the price of avoiding a placeholder
refactor.

**Option B — introduce `GSPlaceholderDictionary`.** Mirror the
`GSPlaceholderString` pattern: `+[NSDictionary allocWithZone:]` returns a
placeholder singleton, `-initWithObjects:forKeys:count:` on the placeholder
picks `GSInlineDict` vs `GSDictionary` by count, no wasted alloc. This is
the clean solution, but it touches `NSDictionary.m:120`, every subclass of
`GSDictionary` that currently relies on flat dispatch, and the mutable
parallel path at `NSDictionary.m:1282`. Out of scope for this spike.

**B5 picks Option A.** It is the smallest possible change, requires no
header edits, and the extra alloc is dwarfed by the two malloc calls it
eliminates. A future spike may add Option B as a placeholder refactor
covering strings, dictionaries, and arrays uniformly.

### 2.3 Lookup

Linear scan with identity fast-path:

```objc
- (id) objectForKey: (id)aKey
{
  if (aKey == nil) return nil;
  unsigned char n = _count;
  id *values = _keys + n;    // values region starts right after keys
  for (unsigned char i = 0; i < n; i++)
    {
      id k = _keys[i];
      if (k == aKey || [k isEqual: aKey])
        return values[i];
    }
  return nil;
}
```

Four compares max, all in L1, no hash, no bucket load, no node walk. The
compiler can unroll for `n=4` and the identity fast-path catches the common
case of selector-name / interned-string keys where the caller reuses the same
pointer.

### 2.4 Mutation / promotion — DEFERRED TO FOLLOW-UP SPIKE

Immutable `GSInlineDict` has no mutation path, so there are no promotion
concerns inside B5's scope. A mutable small-dict with N=5 promotion to
`GSMutableDictionary` was originally proposed as part of this spike but
is **deferred**. At least three unresolved invariants need to be
dispatched before a mutable variant can be safely prototyped:

1. **`_version` ivar.** `GSMutableDictionary` has two ivars — not just
   the `GSIMapTable_t map` but also `unsigned long _version` used for
   fast-enumeration mutation detection (`GSDictionary.m:62`, referenced
   at `GSDictionary.m:441,453,458,460,470,472,479`). A class-swizzle
   promotion path must reserve both fields at the exact offsets
   `GSMutableDictionary` expects, or the swizzled object will corrupt
   one or both on first access. The earlier draft of this section did
   not address `_version` at all.

2. **8-byte alignment of the trailing `GSIMapTable_t`.** `GSIMapTable_t`
   contains pointers (`zone`, `buckets`, `freeNodes`, `nodeChunks`) and
   `uintptr_t` fields. The trailing region is only guaranteed aligned
   if the containing object's base size is aligned, which must be
   verified at build time with a `GS_STATIC_ASSERT`. The GSInlineArray
   precedent gets this for free because `id` is pointer-aligned and the
   tail holds a flat `id[]`; `GSIMapTable_t` is stricter.

3. **Dealloc sentinel.** `GSIMapEmptyMap` expects a `GSIMapTable_t` that
   was initialized by `GSIMapInitWithZoneAndCapacity`. A small-dict whose
   trailing tail slot has never been written (because it never reached
   N=5) must *not* call `GSIMapEmptyMap` in `-dealloc`. A sentinel —
   either a class-level "still-inline" flag, the current `isa`, or a
   `_count <= 4` check — must discriminate. This is a dealloc-path
   invariant that needs to be spelled out and asserted.

A second spike (tentatively "B5b: mutable small-dict promotion") will
work through these three items, decide between pre-reserved tail +
class-swizzle vs allocating a fresh `GSMutableDictionary` and copying,
and ship `GSInlineMutableDict` as a separate change. For B5 proper,
mutable dicts continue to go through `GSMutableDictionary` unchanged —
the user-visible behavior is unchanged, and the allocation-avoidance
win for the (very common) immutable `@{...}` / `-copy` / `userInfo`
cases is captured without the promotion complexity.

### 2.5 Required method overrides (immutable only)

At minimum, to satisfy the abstract base on `GSInlineDict`:
`count`, `objectForKey:`, `keyEnumerator`, `objectEnumerator`,
`countByEnumeratingWithState:objects:count:`, `copyWithZone:`, `dealloc`,
`initWithObjects:forKeys:count:`, `initWithCoder:`/`encodeWithCoder:`,
`isEqualToDictionary:`, `hash`. All are straightforward for a 4-element
array. Mutable-side methods (`setObject:forKey:`, `removeObjectForKey:`,
`removeAllObjects`, `initWithCapacity:`, `makeImmutable`) are **not**
overridden in B5 — the mutable cluster path continues to use
`GSMutableDictionary` unchanged.

The key enumerator can be trivial — a struct with `{dict, index}` — no
`GSIMapEnumerator_t` needed.

## 3. ABI impact

**None at the public-header level.** `Headers/Foundation/NSDictionary.h`
exposes neither `GSDictionary` nor any concrete-class selector; a grep for
`GSDictionary|concrete` in that header returns zero hits. The class cluster
abstraction is clean.

**Minor internal ABI note:** `GSPrivate.h` and friends are free to add a
forward decl of `GSInlineDict`; it is not exposed to downstream. The
`DESTROY(self) + NSAllocateObject(otherClass, …)` mechanic used by Option A
in §2.2 is syntactically identical to what `NSGDictionary -initWithCoder:`
does at `GSDictionary.m:534-545` (though that site is a one-shot archive
migration with different intent, not a class-cluster dispatch). The
mechanic compiles, clears the retain count correctly, and has been used in
tree for years — it is the semantics that are new here.

**Binary compatibility:** existing .nib / NSKeyedArchiver streams decoding
into `NSDictionary` still work because the coder path
(`NSDictionary.m:1312` in the copy helper and the archive init path) all go
through the designated initializer, which is where we intercept. Old archives
naming `GSDictionary` explicitly continue to work because that class still
exists and still handles `c > 4`.

## 4. Performance estimate

### 4.1 The dominant win: construction-time allocation avoidance

The first draft of this spike led with lookup speed. On reflection, that is
**not** the dominant win. At N<=4, a linear pointer-compare loop and a
`GSIMapNodeForKey` call are both in the single-digit-nanosecond range on
modern hardware — lookup is close. The real ~2-4x gap is in the
**construction** path:

Current `GSDictionary -initWithObjects:forKeys:count:` for small N incurs
(see §1.3):

1. the base object allocation (small, cache-local)
2. `GSIMapInitWithZoneAndCapacity` → `NSZoneMalloc` for the **bucket
   array** (capacity rounded up, never smaller than a handful of buckets)
3. `GSIMapAddPair` → `NSZoneMalloc` for the first **node chunk** (a
   slab of `GSIMapNode` structs)
4. per-entry hash computation and bucket insertion

`GSInlineDict` replaces all of this with a single
`NSAllocateObject(cls, 2*count*sizeof(id), z)` call. Two `NSZoneMalloc`s
eliminated; the per-entry work collapses to two pointer stores. On an
allocation-dominated workload (building many short-lived userInfo or
attribute dicts, the common Foundation pattern) this is where the 2-4x
headline number comes from — **not** from faster `objectForKey:`.

### 4.2 Workload prevalence — concrete prior art

Rather than lean on folklore, the prevalence claim rests on three concrete
references:

- **Apple CoreFoundation.** `CFDictionary` / `__CFDictionary` uses a small
  inline storage variant for low-entry-count dicts; this is visible in the
  CF-Lite sources as the `__kCFDictionaryTypeFixed` / inline-buffer path.
  The rationale documented by Apple is that Objective-C `userInfo`,
  `NSError` user info, and `@{}` literal dicts are overwhelmingly 1-4
  entries.
- **Swift stdlib.** `_NativeDictionary` has an inline-storage fast path
  (see `stdlib/public/core/Dictionary.swift` and related `HashTable`
  internals) for the same reason: JSON object decoding, attribute dicts,
  and small literals dominate. Swift's `Dictionary` literal syntax goes
  through this path.
- **Apple Foundation NS-layer.** `NSDictionary` ships
  `__NSDictionary0`, `__NSSingleEntryDictionaryI`, and
  `__NSDictionaryI` as distinct concrete classes, with the single-entry
  variant explicitly tuned for `userInfo`.

All three ship with an N<=small inline-storage class and cite the same
rationale. GNUstep does not, and that is the opportunity B5 exploits.

A libs-base-specific prevalence count is not yet available. **New
measurement task:** add a dict-size histogram at `+[NSDictionary
allocWithZone:]` / designated-initializer entry, run the libs-base test
suite, and report the distribution. This is cheap, non-invasive, and
converts the above external references into a GNUstep-specific data point.
The task is tracked as a dependency of landing the B5 implementation, not
of accepting this spike.

### 4.3 Lookup micro-cost (secondary)

Lookup speedup is real but smaller than the allocation win. Existing
`GSDictionary -objectForKey:` (`GSDictionary.m:343`):

- `[aKey hash]` call through `objc_msgSend` — ~5 ns for `NSString`
- `GSIMapNodeForKey` — modulo bucketCount, load bucket head pointer,
  walk list, one or more `isEqual:` calls
- total: ~15-25 ns for a 1-entry hit on a short string key

Proposed `GSInlineDict -objectForKey:`:

- 1-4 pointer compares (identity fast path) — ~1 ns each, fully
  predicted
- on identity miss, 1-4 `isEqual:` calls — ~3 ns for short strings
- total best case: **~2 ns**; total worst case at N=4: **~12 ns**

### 4.4 Crossover point

Linear scan beats hash at N <= 4 for string keys in this codebase
because the hash is not cheap (full string walk for non-tagged strings),
the GSIMap bucket indirection costs two cache-line loads minimum, and
modern branch predictors handle the 4-iteration loop well. At N=5 the
hash path begins to win on miss. N=4 is the right boundary.

### 4.5 Measurement plan

Two benchmark surfaces, not one:

1. **`bench_dict_lookup.m`** — existing, measures `objectForKey:`
   throughput on a pre-built dict (`bench_dict_lookup.m:43-52`). This
   captures the secondary lookup win. Extend with N=1, N=2, N=3, N=8,
   N=16 cases alongside the existing N=4 and N=10000. Expected result:
   moderate improvement 1..4, no-change 5..8, no-change 16+.

2. **New `bench_dict_create.m`** — does **not** yet exist. This is the
   benchmark that captures the dominant win. It should measure
   `-[NSDictionary initWithObjects:forKeys:count:]` ops/sec (or, more
   realistically, a tight loop that builds small autoreleased dicts the
   way real Foundation code does). Add it as part of landing B5.
   Expected result: **2-4x on small N, no-change at large N.**

Both benchmarks must be run before and after the change. The primary
success criterion moves to the create benchmark.

## 5. Risk

### 5.1 Trailing-region alignment

`GSInlineDict`'s trailing region holds `id` pointers, which are
pointer-aligned. `class_getInstanceSize` for any Objective-C class returns
a value aligned to at least the platform's pointer alignment (verified in
libobjc2 and in the Apple runtime), so `(void*)self +
class_getInstanceSize(cls)` is naturally `id`-aligned and the trailing
`id[]` region needs no extra padding. This is the exact property
GSInlineArray relies on (`GSArray.m:437-438`), so B5 inherits the same
guarantee. A `GS_STATIC_ASSERT(_Alignof(id) <= sizeof(void*))` next to
the ivar block makes the invariant explicit.

(Note: the stricter alignment required by a trailing `GSIMapTable_t` is
a concern for the deferred mutable spike, not for B5 — see §2.4.)

### 5.2 `isEqual:` on keys

`GSDictionary.m:45` uses `[X.obj isEqual: Y.obj]` on the stored key vs
the lookup key. `GSInlineDict` must match that semantic precisely — the
stored key is the `-copy` of the original (NSCopying contract), and
`-isEqual:` must be invoked with the stored copy as the receiver, not
the query key, to match existing behavior for classes whose `-isEqual:`
is asymmetric (bad practice but exists in the wild). The snippet in
§2.3 gets this right: `[k isEqual: aKey]` where `k == _keys[i]`.

### 5.3 Key copy timing

`GSDictionary` copies keys via `GSI_MAP_RETAIN_KEY` inside
`GSIMapAddPair`. `GSInlineDict -initWithObjects:forKeys:count:` must do
the same (`_keys[i] = [keys[i] copyWithZone: [self zone]]`). Forgetting
this breaks `NSMutableString` keys silently — high risk of drift.

### 5.4 `GSCachedDictionary` interaction

`GSCachedDictionary : GSDictionary` (`GSDictionary.m:560`) is used by
the property-list uniquing path. The `c <= 4` interception in
`GSDictionary -initWithObjects:forKeys:count:` must guard
`[self class] == [GSDictionary class]` so that `GSCachedDictionary` is
unaffected. Noted in §2.2.

### 5.5 Wasted alloc on the small path

Because B5 picks Option A in §2.2 (intercept inside the initializer
rather than introduce a placeholder), each small-dict construction
discards one `NSAllocateObject(GSDictionaryClass, 0, z)` before
allocating the real `GSInlineDict`. This is cheap (no mallocs past the
object itself) and is more than recovered by eliminating the bucket +
node-chunk mallocs, but it is a measurable wart that a future
placeholder refactor (Option B) would remove.

### 5.6 Scope discipline

Mutable-side promotion, a `GSPlaceholderDictionary` refactor, and N=0 /
N=1 per-count specialization are all deliberately out of scope — see
§7. Keeping B5 narrow is the only way its correctness argument stays
short enough to audit by inspection.

## 6. Test strategy

### 6.1 Existing tests to run unchanged

`libs-base/Tests/base/NSDictionary/` — run the whole directory after the
change. These cover the abstract cluster contract and will catch any
init/enum/copy regression regardless of which concrete class is used.

### 6.2 New targeted tests

Add `libs-base/Tests/base/NSDictionary/small.m` covering:

- **N=0 (empty):** `+dictionary`, `[NSDictionary new]`, `-count == 0`, lookup returns nil, enumeration immediately terminates.
- **N=1:** identity-hit, isEqual-hit, miss, key-copy-semantics (mutate original `NSMutableString` key, lookup still works).
- **N=4 boundary:** all 4 keys lookup-hit, miss, enumeration visits all 4 in some order, `-isEqualToDictionary:` against an N=4 `GSDictionary`.
- **N=5 fallthrough:** `-initWithObjects:forKeys:count:` with c=5 must return a `GSDictionary`, not a `GSInlineDict`. This is the boundary regression test for the Option A interception in §2.2.
- **Duplicate-key insert:** `-initWithObjects:forKeys:count:` with the same key twice — per `GSDictionary.m:212-218` the second value replaces the first; `GSInlineDict` must do the same.
- **Nil key / nil value in init:** must raise `NSInvalidArgumentException` just like `GSDictionary.m:199-210`.
- **`-copy` round-trip:** an immutable `GSInlineDict` copy must return self-retain (matching `GSDictionary.m:107-110`).
- **`-mutableCopy`:** from a `GSInlineDict` must produce a `GSMutableDictionary` (the existing path — mutable side unchanged in B5).
- **Archive round-trip:** NSKeyedArchiver encode + decode preserves count and contents.
- **`GSCachedDictionary` opt-out:** construct a `GSCachedDictionary` with c<=4 and verify it is **not** re-allocated as a `GSInlineDict` (guards §5.4).

### 6.3 Bench

Run `bench_dict_lookup` before and after with the extended N=1/2/3/8/16
variants from §4.5 (secondary metric). Run the new `bench_dict_create`
before and after (primary metric). Success criteria:

- `bench_dict_create` small N: **2x+ improvement**.
- `bench_dict_lookup` small-hit: no regression, ideally slight improvement.
- Both benchmarks at N=16 and above: no regression >=5%.

### 6.4 Memory sanitizer

Run the existing NSDictionary test directory under ASAN (MSYS2 clang
supports it on ucrt64) to catch trailing-region out-of-bounds reads or
dealloc double-frees in `GSInlineDict`. With the mutable promotion path
deferred, the remaining ASAN-relevant risk is just the trailing `id[]`
bookkeeping, which is low but worth verifying.

## 7. Decision

Split into two decisions:

### 7.1 GO — immutable `GSInlineDict` (N<=4)

**GO** on the immutable class, using §2.1's trailing-allocation layout
(mirroring the real `GSInlineArray` precedent at
`GSArray.m:75-78,437-438,1265`) and §2.2's Option A dispatch (intercept
inside `-[GSDictionary initWithObjects:forKeys:count:]` with a
`[self class] == [GSDictionary class]` guard).

Rationale:

1. No existing small-dict infrastructure to reframe against (unlike B2).
2. `GSInlineArray` provides a working, in-tree template for
   trailing-allocation — the pattern is proven safe under ASAN/LSAN
   (`GSArray.m:1226-1240`).
3. The dominant win is **construction-time allocation avoidance** (§4.1):
   two `NSZoneMalloc` calls per small dict eliminated, which is where the
   2-4x headline comes from. Lookup speedup is a secondary benefit.
4. Prevalence is corroborated by three independent shipping Foundation
   implementations (Apple CF, Apple NS, Swift stdlib — §4.2), all of
   which carry an inline-small-dict path for the same rationale. A
   libs-base-local histogram is queued as part of the landing task.
5. ABI surface is zero — purely internal class addition.
6. Risks are bounded: trailing alignment for `id[]` is inherited from
   GSInlineArray, key-copy and `isEqual:` semantics are specified in §5.

### 7.2 DEFER — mutable small-dict / class-swizzle promotion

**DEFER TO FOLLOW-UP SPIKE** (tentative: "B5b") the mutable variant and
the class-swizzle-to-`GSMutableDictionary` promotion path. Unresolved
invariants (per §2.4):

- `GSMutableDictionary`'s second ivar `_version` (`GSDictionary.m:62`)
  must be reserved at the exact offset the swizzled-into class expects.
- The trailing `GSIMapTable_t` region has stricter alignment than a
  trailing `id[]`; this needs a `GS_STATIC_ASSERT` and an explicit
  argument, not a hand-wave.
- Dealloc must discriminate "never-promoted inline" from "promoted,
  GSIMapTable_t live" via a sentinel; the first draft did not specify
  one.

None of these are fatal, but each needs a concrete answer backed by
tests before merging. Splitting them off keeps B5's review surface
small and captures the dominant performance win now.

### 7.3 Out of scope (both halves)

- Introducing `GSPlaceholderDictionary` — larger refactor, future spike
  (would subsume §2.2 Option B).
- N=0 and N=1 per-count specialization (Apple ships these; GNUstep can
  revisit once the N<=4 class is in tree and measured).
- Changing `GSCachedDictionary` (opt-out via class guard, unchanged).
- Tagged-pointer dict (orthogonal future spike; depends on B2's tagged
  pointer infrastructure landing first).

Estimated effort for 7.1 alone: ~1 day for the class + tests, plus
~0.5 day for the new `bench_dict_create` benchmark and measurement.
The deferred 7.2 work is separately estimated in its own spike when
written.
