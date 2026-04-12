# GNUstep Performance Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans

**Goal:** Implement top 15 performance optimizations identified in the audit, organized in 3 sprints from quick wins to architectural changes.

**Architecture:** Sprint 1 = low-effort/high-impact quick wins. Sprint 2 = medium-effort core fixes. Sprint 3 = larger architectural improvements.

**Tech Stack:** Objective-C, C, C++. Build: GNUstep Make + CMake. Test: per-repo test suites + custom benchmarks.

---

## SPRINT 1: Quick Wins (low effort, high impact)

### Task 1: Replace `__sync_fetch_and_add(x,0)` with `__atomic_load_n` in libobjc2/arc.mm

**File:** `libobjc2/arc.mm`

**Problem:** `__sync_fetch_and_add(refCount, 0)` is used as a read-only atomic load at lines 256, 264, 341, 782, and 893. This issues a full read-modify-write (lock xadd on x86, ldxr/stxr loop on ARM) just to read a value. On ARM, this is 10-20 extra cycles per call. These are on the retain/release hot path.

**Before (5 occurrences):**
```c
// Line 256 (object_getRetainCount_np)
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);

// Line 264 (retain_fast)
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);

// Line 341 (objc_release_fast_no_destroy_np)
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);

// Line 782 (setObjectHasWeakRefs)
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);

// Line 893 (objc_delete_weak_refs)
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);
```

**After (all 5 occurrences):**
```c
uintptr_t refCountVal = __atomic_load_n(refCount, __ATOMIC_RELAXED);
```

**Rationale for `__ATOMIC_RELAXED`:** These loads feed into compare-and-swap loops (lines 264, 341, 782) or are just informational reads (lines 256, 893). The CAS provides its own ordering guarantees; the initial load is just to get a starting value for the retry loop. For line 256 (`object_getRetainCount_np`), the result is inherently approximate since it can change before the caller uses it. For line 893, the check is performed under `weakRefLock`, so the lock provides ordering.

**Steps:**
1. Open `libobjc2/arc.mm`
2. Replace all 5 occurrences of `__sync_fetch_and_add(refCount, 0)` with `__atomic_load_n(refCount, __ATOMIC_RELAXED)`
3. Build: `cd libobjc2 && mkdir -p build && cd build && cmake .. && cmake --build .`
4. Run tests: `cd libobjc2/build && ctest`

**Benchmark:** Micro-benchmark retain/release cycle on 10M objects, measure wall time before/after. Expect 5-15% improvement on ARM, 2-5% on x86.

---

### Task 2: Add `aligned(64)` to `objc_method_cache_version` in libobjc2/dtable.c

**File:** `libobjc2/dtable.c`, line 47

**Problem:** `objc_method_cache_version` is a global `_Atomic(uint64_t)` that is frequently read by every method dispatch (cache validation) and occasionally written when methods are added/replaced. Adjacent globals can share the same cache line, causing false sharing -- writer invalidates all readers' caches even though they access different variables.

**Before:**
```c
#ifndef NO_SAFE_CACHING
_Atomic(uint64_t) objc_method_cache_version;
#endif
```

**After:**
```c
#ifndef NO_SAFE_CACHING
_Atomic(uint64_t) objc_method_cache_version __attribute__((aligned(64)));
#endif
```

**Steps:**
1. Open `libobjc2/dtable.c`
2. Add `__attribute__((aligned(64)))` to the declaration
3. Build and run tests as in Task 1

**Benchmark:** Multi-threaded message send benchmark (4+ threads calling different methods on different objects). Measure cache miss counters with `perf stat -e cache-misses` before/after. Expect measurable reduction in L1d cache misses under contention.

---

### Task 3: Re-enable X11 expose event coalescing in libs-back

**File:** `libs-back/Source/x11/XGServerEvent.m`, lines 1188-1213

**Problem:** Expose event coalescing is disabled via `#if 0`. The active code path (lines 1194-1211) creates a separate `NSEvent` for every single `Expose` X event, flooding the event queue during rapid resizes or window uncovering. The disabled path accumulates rectangles and processes them in batch when `xEvent.xexpose.count == 0` (X11 signals last expose in a burst). The coalescing infrastructure already exists in `XGServerWindow.m` (`_addExposedRectangle:`, `_processExposedRectangles:`).

**Before:**
```objc
#if 0
              // ignore backing if sub-window
              [self _addExposedRectangle: rectangle : cWin->number : isSubWindow];

              if (xEvent.xexpose.count == 0)
                [self _processExposedRectangles: cWin->number];
#else
              {
                NSRect rect;
                NSTimeInterval ts = (NSTimeInterval)generic.lastMotion;
                
                rect = [self _XWinRectToOSWinRect: NSMakeRect(
                        rectangle.x, rectangle.y, rectangle.width, rectangle.height)
                             for: cWin];
                e = [NSEvent otherEventWithType: NSAppKitDefined
                             location: rect.origin
                             modifierFlags: eventFlags
                             timestamp: ts / 1000.0
                             windowNumber: cWin->number
                             context: gcontext
                             subtype: GSAppKitRegionExposed
                             data1: rect.size.width
                             data2: rect.size.height];
              }
              
#endif
```

**After:**
```objc
              // Coalesce expose events: accumulate rectangles, then process
              // the batch when X11 signals the last expose in the burst
              // (xexpose.count == 0). The _addExposedRectangle method
              // uses XUnionRectWithRegion to merge rects, and
              // _processExposedRectangles emits a single
              // GSAppKitRegionExposed event with the bounding rect.
              [self _addExposedRectangle: rectangle : cWin->number : isSubWindow];

              if (xEvent.xexpose.count == 0)
                {
                  [self _processExposedRectangles: cWin->number];
                }
```

**Steps:**
1. Open `libs-back/Source/x11/XGServerEvent.m`
2. Replace the `#if 0 ... #else ... #endif` block with the coalescing path
3. Build: `cd libs-back && make`
4. Test: open several overlapping windows, drag a window across them rapidly, verify redraws are correct and faster

**Benchmark:** Measure frame rate during rapid window expose using `xdotool` to cover/uncover a window 100 times. Count NSEvent objects generated per cycle.

---

### Task 4: Change CFArray growth from +16 to *2 in libs-corebase

**File:** `libs-corebase/Source/CFArray.c`, lines 442-457

**Problem:** `CFArrayCheckCapacityAndGrow` grows by a fixed +16 elements every time the capacity is exceeded. For arrays that grow to N elements, this causes O(N/16) reallocations and O(N^2/16) total bytes copied. Geometric doubling gives O(log N) reallocations and O(N) total copies (amortized O(1) per append).

**Before:**
```c
CF_INLINE void
CFArrayCheckCapacityAndGrow (CFMutableArrayRef array, CFIndex newCapacity)
{
  struct __CFMutableArray *mArray = (struct __CFMutableArray *) array;

  if (mArray->_capacity < newCapacity)
    {
      newCapacity = mArray->_capacity + DEFAULT_ARRAY_CAPACITY;

      mArray->_contents = CFAllocatorReallocate (CFGetAllocator (mArray),
                                                 mArray->_contents,
                                                 (newCapacity *
                                                  sizeof (const void *)), 0);
      mArray->_capacity = newCapacity;
    }
}
```

**After:**
```c
CF_INLINE void
CFArrayCheckCapacityAndGrow (CFMutableArrayRef array, CFIndex newCapacity)
{
  struct __CFMutableArray *mArray = (struct __CFMutableArray *) array;

  if (mArray->_capacity < newCapacity)
    {
      /* Geometric growth: double the current capacity, but ensure we
         reach at least newCapacity and at least DEFAULT_ARRAY_CAPACITY. */
      CFIndex grown = mArray->_capacity * 2;
      if (grown < newCapacity)
        grown = newCapacity;
      if (grown < DEFAULT_ARRAY_CAPACITY)
        grown = DEFAULT_ARRAY_CAPACITY;

      mArray->_contents = CFAllocatorReallocate (CFGetAllocator (mArray),
                                                 mArray->_contents,
                                                 (grown *
                                                  sizeof (const void *)), 0);
      mArray->_capacity = grown;
    }
}
```

**Steps:**
1. Open `libs-corebase/Source/CFArray.c`
2. Replace the function body as shown
3. Build: `cd libs-corebase && make`
4. Run tests: `cd libs-corebase && make check`

**Benchmark:** Append 1M elements to a CFMutableArray, measure wall time and count of `realloc` calls. Expect ~60,000x fewer reallocations (1M/16 vs log2(1M) = 20).

---

### Task 5: Increase JSON parser buffer from 64 to 4096 in libs-base

**File:** `libs-base/Source/NSJSONSerialization.m`, line 53

**Problem:** The JSON parser reads input in 64-character chunks. For a 1 MB JSON document, that means ~16,000 buffer refills, each calling `[NSString getCharacters:range:]`. Increasing to 4096 reduces refills to ~250 (64x fewer), dramatically reducing message send overhead and improving cache locality.

**Before:**
```c
/**
 * The number of (unicode) characters to fetch from the source at once.
 */
#define BUFFER_SIZE 64
```

**After:**
```c
/**
 * The number of (unicode) characters to fetch from the source at once.
 * 4096 unichar = 8 KB, which fits in L1 cache and amortizes the cost
 * of NSString/NSStream buffer refills across many parse operations.
 */
#define BUFFER_SIZE 4096
```

**Note:** The `ParserState` struct contains `unichar buffer[BUFFER_SIZE]` (line 82), which becomes 8 KB on the stack. Also, `parseString` has a local `unichar buffer[BUFFER_SIZE]` (line 356) which becomes another 8 KB. Total stack increase is ~16 KB per parse call. This is well within typical stack sizes (1-8 MB) and these functions are not deeply recursive. However, see Task 6 for adding a recursion limit.

**Steps:**
1. Open `libs-base/Source/NSJSONSerialization.m`
2. Change `#define BUFFER_SIZE 64` to `#define BUFFER_SIZE 4096`
3. Build: `cd libs-base && make`
4. Run tests: `cd libs-base && make check`

**Benchmark:** Parse a 1 MB JSON file 1000 times, measure total wall time. Expect 30-50% improvement for large documents.

---

### Task 6: Add JSON recursion depth limit in libs-base

**File:** `libs-base/Source/NSJSONSerialization.m`

**Problem:** `parseValue` calls `parseArray`/`parseObject` which call `parseValue` recursively with no depth limit. A malicious JSON input like `[[[[...` (10,000 deep) will stack-overflow. This is both a security fix and a performance guard (prevents the stack from ballooning). RFC 7159 recommends implementations set limits.

**Before (line 696-715):**
```c
NS_RETURNS_RETAINED static id
parseValue(ParserState *state)
{
  unichar c;

  if (state->error) { return nil; };
  c = consumeSpace(state);
  /*   2.1: A JSON value MUST be an object, array, number, or string,
   *   or one of the following three literal names:
   *   false null true
   */
  switch (c)
    {
      case (unichar)'"':
        return parseString(state);
      case (unichar)'[':
        return parseArray(state);
      case (unichar)'{':
        return parseObject(state);
```

**After:**

First, add a `depth` field to `ParserState` and a max depth constant:
```c
// Add after line 53 (#define BUFFER_SIZE 4096):
/**
 * Maximum nesting depth for JSON arrays/objects.  Prevents stack overflow
 * from deeply nested or malicious input.  512 is generous for real-world
 * JSON while still well within typical stack limits.
 */
#define MAX_NESTING_DEPTH 512
```

```c
// Add to the ParserState struct (after the sourceIndex field, around line 94):
  /**
   * Current nesting depth (incremented on [ or {, decremented on ] or }).
   * Used to prevent stack overflow from deeply nested input.
   */
  NSUInteger depth;
```

Then modify `parseArray` and `parseObject` to check/track depth:

```c
NS_RETURNS_RETAINED static NSArray*
parseArray(ParserState *state)
{
  unichar c = consumeSpace(state);
  NSMutableArray *array;

  if (c != '[')
    {
      parseError(state);
      return nil;
    }
  if (state->depth >= MAX_NESTING_DEPTH)
    {
      parseError(state);
      return nil;
    }
  state->depth++;
  // Eat the [
  consumeChar(state);
  array = [NSMutableArray new];
  c = consumeSpace(state);
  while (c != ']')
    {
      // ... (existing body unchanged) ...
    }
  // Eat the trailing ]
  consumeChar(state);
  state->depth--;
  // ... (rest unchanged) ...
}
```

Apply the same pattern to `parseObject`:
```c
NS_RETURNS_RETAINED static NSDictionary*
parseObject(ParserState *state)
{
  unichar c = consumeSpace(state);
  NSMutableDictionary *dict;

  if (c != '{')
    {
      parseError(state);
      return nil;
    }
  if (state->depth >= MAX_NESTING_DEPTH)
    {
      parseError(state);
      return nil;
    }
  state->depth++;
  // Eat the {
  consumeChar(state);
  dict = [NSMutableDictionary new];
  // ... (existing body unchanged) ...
  // Eat the trailing }
  consumeChar(state);
  state->depth--;
  // ... (rest unchanged) ...
}
```

The `depth` field is zero-initialized since `ParserState` is stack-allocated and the callers initialize all fields.

**Steps:**
1. Open `libs-base/Source/NSJSONSerialization.m`
2. Add `MAX_NESTING_DEPTH` constant
3. Add `depth` field to `ParserState` struct
4. Add depth check at start of `parseArray` and `parseObject`
5. Add `state->depth++` after the opening bracket check, `state->depth--` before return
6. Build and run tests
7. Add a test with 513-deep nesting to verify it returns an error

**Benchmark:** Parse 512-deep nested JSON to verify it succeeds. Parse 513-deep to verify it fails with an error. Parse normal JSON to verify no performance regression.

---

## SPRINT 2: Core Fixes (medium effort, high impact)

### Task 7: Stripe weak reference lock in libobjc2/arc.mm

**File:** `libobjc2/arc.mm`, line 709

**Problem:** All weak reference operations (`objc_storeWeak`, `objc_loadWeakRetained`, `objc_delete_weak_refs`, `objc_copyWeak`, `objc_moveWeak`, `objc_destroyWeak`, `objc_initWeak`) acquire the single global `weakRefLock`. On multi-threaded apps with many weak references (e.g., delegate patterns, SwiftUI-like reactive UIs), this becomes a serialization bottleneck. The weak ref table already uses object addresses as keys, so different objects are independent.

**Before:**
```cpp
mutex_t weakRefLock;

// ... in init_arc():
INIT_LOCK(weakRefLock);

// Every operation:
LOCK_FOR_SCOPE(&weakRefLock);
```

**After:**
```cpp
/**
 * Striped lock table for weak references.  We use 64 locks, selected
 * by hashing the object pointer.  This reduces contention from O(threads)
 * to O(threads/64) while keeping the implementation simple.
 * 64 * sizeof(mutex_t) = 64 * 40 bytes (pthread_mutex_t) = 2.5 KB,
 * and each lock gets its own cache line to avoid false sharing.
 */
#define WEAK_LOCK_COUNT 64
#define WEAK_LOCK_MASK  (WEAK_LOCK_COUNT - 1)

struct alignas(64) PaddedMutex {
	mutex_t lock;
};

PaddedMutex weakRefLocks[WEAK_LOCK_COUNT];

static inline mutex_t *weakLockForPointer(const void *ptr)
{
	// Shift right by 4 to discard alignment bits (objects are at least
	// 16-byte aligned), then mask to select a stripe.
	uintptr_t hash = ((uintptr_t)ptr >> 4) & WEAK_LOCK_MASK;
	return &weakRefLocks[hash].lock;
}
```

Update `init_arc()`:
```cpp
PRIVATE extern "C" void init_arc(void)
{
	for (int i = 0; i < WEAK_LOCK_COUNT; i++)
	{
		INIT_LOCK(weakRefLocks[i].lock);
	}
	// ... rest unchanged ...
}
```

Replace every `LOCK_FOR_SCOPE(&weakRefLock)` with the appropriate striped lock. The object pointer to hash on varies by function:

```cpp
// objc_storeWeak (line 834) - needs to lock BOTH old and new object.
// Use ordered locking to avoid deadlock:
extern "C" OBJC_PUBLIC id objc_storeWeak(id *addr, id obj)
{
	WeakRef *oldRef;
	id old;
	
	// Determine old object first (without lock, just a load)
	id oldObj = *addr;
	const void *oldPtr = (oldObj && classForObject(oldObj) == (Class)&weakref_class)
		? (const void*)((WeakRef*)oldObj)->obj : (const void*)oldObj;
	const void *newPtr = (const void*)obj;
	
	// Lock in pointer order to avoid deadlock
	mutex_t *lock1 = weakLockForPointer(oldPtr);
	mutex_t *lock2 = weakLockForPointer(newPtr);
	if (lock1 > lock2) { mutex_t *tmp = lock1; lock1 = lock2; lock2 = tmp; }
	
	LOCK_FOR_SCOPE(lock1);
	// Only take second lock if it's different
	__attribute__((cleanup(objc_release_lock)))
	__attribute__((unused)) mutex_t *lock2_holder = (lock1 != lock2) ? lock2 : NULL;
	if (lock2_holder) LOCK(lock2_holder);
	
	// ... rest of function body unchanged ...
}

// objc_loadWeakRetained (line 923) - lock based on the WeakRef's object
extern "C" OBJC_PUBLIC id objc_loadWeakRetained(id* addr)
{
	// We need to figure out which object this weak ref points to.
	// Read *addr, if it's a WeakRef, hash on ref->obj; else hash on *addr.
	id oldObj = *addr;
	const void *ptr = (oldObj && classForObject(oldObj) == (Class)&weakref_class)
		? (const void*)((WeakRef*)oldObj)->obj : (const void*)oldObj;
	LOCK_FOR_SCOPE(weakLockForPointer(ptr));
	// ... rest unchanged ...
}

// objc_delete_weak_refs (line 888) - lock based on obj
extern "C" OBJC_PUBLIC BOOL objc_delete_weak_refs(id obj)
{
	LOCK_FOR_SCOPE(weakLockForPointer((const void*)obj));
	// ... rest unchanged ...
}

// objc_copyWeak (line 986) - lock based on source object
extern "C" OBJC_PUBLIC void objc_copyWeak(id *dest, id *src)
{
	id oldObj = *src;
	const void *ptr = (oldObj && classForObject(oldObj) == (Class)&weakref_class)
		? (const void*)((WeakRef*)oldObj)->obj : (const void*)oldObj;
	LOCK_FOR_SCOPE(weakLockForPointer(ptr));
	// ... rest unchanged ...
}

// objc_moveWeak (line 1009) - same as copyWeak
// objc_destroyWeak (line 1016) - same pattern
// objc_initWeak (line 1035) - lock based on obj
```

**Important:** The `weak_ref_table` (robin_pg_map) is NOT thread-safe. With striped locks, different stripes could concurrently access the same hash table. Solution: also stripe the table itself into 64 independent tables:

```cpp
weak_ref_table &weakRefsForPointer(const void *ptr)
{
	static weak_ref_table tables[WEAK_LOCK_COUNT] = {
		weak_ref_table{16}, weak_ref_table{16}, /* ... initialized via a helper ... */
	};
	uintptr_t hash = ((uintptr_t)ptr >> 4) & WEAK_LOCK_MASK;
	return tables[hash];
}
```

Replace all `weakRefs()` calls with `weakRefsForPointer(obj)` where `obj` is the object being tracked.

**Steps:**
1. Open `libobjc2/arc.mm`
2. Replace `weakRefLock` with striped lock array
3. Replace `weakRefs()` with striped table array
4. Update every `LOCK_FOR_SCOPE(&weakRefLock)` call site
5. Update `init_arc()`
6. Build and run full test suite
7. Run the weak reference stress test: `libobjc2/Test/WeakReferences.m`

**Benchmark:** Spawn 8 threads each creating/destroying 100K weak references to distinct objects. Measure total wall time. Expect 4-8x improvement.

---

### Task 8: Rewrite NSCache with O(1) LRU linked list in libs-base

**File:** `libs-base/Source/NSCache.m`

**Problem:** `objectForKey:` calls `[_accesses removeObjectIdenticalTo: obj]` (line 109) which is O(n) -- it scans the entire `_accesses` array to find and remove the object. Then `[_accesses addObject: obj]` appends it. For a cache with N items, every cache hit is O(N). The eviction loop (line 249) also iterates `_accesses`. This makes NSCache useless for large caches.

**Before (key hot path in `objectForKey:`):**
```objc
if (obj->isEvictable)
  {
    // Move the object to the end of the access list.
    [_accesses removeObjectIdenticalTo: obj];
    [_accesses addObject: obj];
  }
```

**After -- replace `_accesses` NSMutableArray with an intrusive doubly-linked list:**

Add prev/next pointers to `_GSCachedObject`:
```objc
@interface _GSCachedObject : NSObject
{
  @public
  id object;
  NSString *key;
  int accessCount;
  NSUInteger cost;
  BOOL isEvictable;
  _GSCachedObject *_lruNext;
  _GSCachedObject *_lruPrev;
}
@end
```

Add list head/tail to NSCache (requires updating the ivar layout -- since `_accesses` is already an ivar, repurpose it or add new ivars). In practice, we keep `_accesses` as `id` and reinterpret, or better, add a small helper struct. The simplest approach: replace `_accesses` usage entirely.

Add private helper struct at file scope:
```objc
/* Intrusive doubly-linked LRU list.  Most-recently-used at tail,
   least-recently-used at head.  All operations are O(1). */
typedef struct {
  _GSCachedObject *head;
  _GSCachedObject *tail;
} _GSLRUList;

static inline void _lruRemove(_GSLRUList *list, _GSCachedObject *obj)
{
  if (obj->_lruPrev)
    obj->_lruPrev->_lruNext = obj->_lruNext;
  else
    list->head = obj->_lruNext;
  if (obj->_lruNext)
    obj->_lruNext->_lruPrev = obj->_lruPrev;
  else
    list->tail = obj->_lruPrev;
  obj->_lruNext = nil;
  obj->_lruPrev = nil;
}

static inline void _lruAppend(_GSLRUList *list, _GSCachedObject *obj)
{
  obj->_lruPrev = list->tail;
  obj->_lruNext = nil;
  if (list->tail)
    list->tail->_lruNext = obj;
  else
    list->head = obj;
  list->tail = obj;
}

static inline void _lruMoveToTail(_GSLRUList *list, _GSCachedObject *obj)
{
  _lruRemove(list, obj);
  _lruAppend(list, obj);
}
```

Repurpose `_accesses` ivar. Since `_accesses` is typed `id` in the class, we store a heap-allocated `_GSLRUList *` in it (cast through `void *`). Alternatively, if ivar layout can be changed, replace `_accesses` with two pointers. The cleanest approach using existing ivar space:

In `init`:
```objc
- (id) init
{
  if (nil == (self = [super init]))
    return nil;
  ASSIGN(_objects, [NSMapTable strongToStrongObjectsMapTable]);
  // Allocate LRU list struct, store in _accesses ivar (repurposed)
  _GSLRUList *lru = calloc(1, sizeof(_GSLRUList));
  _accesses = (id)lru;  // repurposed - no longer an NSMutableArray
  _lock = [NSRecursiveLock new];
  return self;
}
```

In `objectForKey:` -- O(1) move-to-tail:
```objc
- (id) objectForKey: (id)key
{
  _GSCachedObject *obj;
  id value;

  [_lock lock];
  obj = [_objects objectForKey: key];
  if (nil == obj)
    {
      [_lock unlock];
      return nil;
    }
  if (obj->isEvictable)
    {
      _lruMoveToTail((_GSLRUList *)_accesses, obj);
    }
  obj->accessCount++;
  _totalAccesses++;
  value = RETAIN(obj->object);
  [_lock unlock];
  return AUTORELEASE(value);
}
```

In `removeObjectForKey:` -- O(1) removal:
```objc
if (nil != obj)
  {
    [_delegate cache: self willEvictObject: obj->object];
    _totalAccesses -= obj->accessCount;
    if (obj->isEvictable)
      _lruRemove((_GSLRUList *)_accesses, obj);
    [_objects removeObjectForKey: key];
  }
```

In eviction -- iterate from head (LRU end):
```objc
- (void) _evictObjectsToMakeSpaceForObjectWithCost: (NSUInteger)cost
{
  // ... setup unchanged ...
  if (count > 0 && (spaceNeeded > 0 || count >= _countLimit))
    {
      _GSLRUList *lru = (_GSLRUList *)_accesses;
      _GSCachedObject *obj = lru->head;
      NSMutableArray *evictedKeys = nil;
      NSUInteger averageAccesses = ((_totalAccesses / (double)count) * 0.2) + 1;

      if (_evictsObjectsWithDiscardedContent)
        evictedKeys = [[NSMutableArray alloc] init];

      while (obj != nil && (spaceNeeded > 0 || [_objects count] >= _countLimit))
        {
          _GSCachedObject *next = obj->_lruNext;
          if (%.accessCount < averageAccesses && obj->isEvictable)
            {
              // ... eviction logic (existing) ...
            }
          obj = next;
        }
      // ... rest unchanged ...
    }
}
```

In `dealloc`:
```objc
- (void) dealloc
{
  free((_GSLRUList *)_accesses);
  // ... rest unchanged ...
}
```

In `removeAllObjects`:
```objc
_GSLRUList *lru = (_GSLRUList *)_accesses;
lru->head = nil;
lru->tail = nil;
```

**Steps:**
1. Open `libs-base/Source/NSCache.m`
2. Add `_lruNext`/`_lruPrev` to `_GSCachedObject`
3. Add `_GSLRUList` struct and helper functions
4. Rewrite `init`, `objectForKey:`, `removeObjectForKey:`, `removeAllObjects`, `_evictObjectsToMakeSpaceForObjectWithCost:`, `dealloc`
5. Build: `cd libs-base && make`
6. Run tests: `cd libs-base && make check`

**Benchmark:** Create NSCache with 10K entries, perform 1M random lookups, measure time. Before: O(10K) per lookup = 10B operations. After: O(1) per lookup = 1M operations. Expect 1000-10000x speedup for large caches.

---

### Task 9: Replace NSRunLoop timer linear scan with sorted insert in libs-base

**File:** `libs-base/Source/NSRunLoop.m`

**Problem:** `_limitDateForContext:` (line 1006) iterates all timers linearly to find the next one to fire. The comment at line 1033 says "We fire timers in the order in which they were added to the run loop rather than in date order." This is intentional fairness -- but finding the earliest unfired timer for the limit date still requires scanning all N timers.

**Revised approach:** Rather than a full min-heap replacement (which would change the documented firing order), add a cached `_earliestFireDate` that is updated on timer add/remove/fire, avoiding the full scan in `_limitDateForContext:` for the common case where no timers need firing.

Actually, reading the code more carefully, the scan at line 1041-1049 fires all past-due timers and also computes the earliest future fire date. The design is correct but the iteration is O(N) per run loop iteration. For most apps, N is small (<20 timers). This is a lower-priority optimization.

**Alternative simpler optimization:** The `_limitDateForContext:` method is called repeatedly. After firing all due timers, it scans the remaining timers to find the earliest future date. We can cache this result and invalidate on timer add/remove:

This requires changes to `GSRunLoopCtxt` which is in a private header. Given complexity and the small typical N, **defer this task or implement only if profiling shows it as a bottleneck in a specific application.** Mark as optional.

**Steps (if proceeding):**
1. Read `libs-base/Source/GSRunLoopCtxt.h` for the timer storage structure
2. Add `NSDate *_cachedLimitDate` field
3. Set to nil when timers are added/removed
4. In `_limitDateForContext:`, return cached value if non-nil and no timers are past-due
5. Build and test

**Benchmark:** Add 1000 timers firing at various future times, run the loop, measure `_limitDateForContext:` time. Expect improvement only when N > ~50.

---

### Task 10: Cache DPSimage pixel format conversions in libs-back

**File:** `libs-back/Source/cairo/CairoGState.m`, lines 1066-1144

**Problem:** Every time an image is drawn, the pixel format is converted from the source format (RGBA/RGB) to Cairo's ARGB format. This involves allocating a buffer (`malloc(reformattedDataSize)`), iterating every pixel, and performing bit manipulation. For the same image drawn multiple times (e.g., toolbar icons, button backgrounds), this conversion is repeated identically.

**Before (lines 1066-1106, 32-bit case):**
```c
reformattedDataSize = pixelsWide * pixelsHigh * sizeof(*reformattedDataPixel);

switch (bitsPerPixel)
  {
  case 32:
    reformattedData = malloc(reformattedDataSize);
    if (!reformattedData)
      {
        NSLog(@"Could not allocate drawing space for image");
        return;
      }
    // ... pixel-by-pixel conversion loop ...
    format = CAIRO_FORMAT_ARGB32;
    break;
  // ... 24-bit case ...
  }
```

**After -- cache the converted buffer on the NSBitmapImageRep using associated objects:**

Add at the top of the file:
```objc
#import <objc/runtime.h>

static const char kCachedCairoDataKey;
static const char kCachedCairoDataSizeKey;

typedef struct {
    void *data;
    size_t size;
    int bitsPerPixel;
    NSInteger pixelsWide;
    NSInteger pixelsHigh;
} CachedCairoConversion;

static void CachedCairoConversionDealloc(void *ptr)
{
    CachedCairoConversion *cached = (CachedCairoConversion *)ptr;
    if (cached->data)
        free(cached->data);
    free(cached);
}
```

Then wrap the conversion:
```c
// Check for cached conversion
CachedCairoConversion *cached = (CachedCairoConversion *)
    objc_getAssociatedObject(rep, &kCachedCairoDataKey);

if (cached
    && cached->bitsPerPixel == bitsPerPixel
    && cached->pixelsWide == pixelsWide
    && cached->pixelsHigh == pixelsHigh)
  {
    reformattedData = malloc(cached->size);
    memcpy(reformattedData, cached->data, cached->size);
    format = (bitsPerPixel == 32) ? CAIRO_FORMAT_ARGB32 : CAIRO_FORMAT_RGB24;
  }
else
  {
    // ... existing conversion code ...

    // Cache the result
    CachedCairoConversion *newCache = calloc(1, sizeof(CachedCairoConversion));
    newCache->data = malloc(reformattedDataSize);
    memcpy(newCache->data, reformattedData, reformattedDataSize);
    newCache->size = reformattedDataSize;
    newCache->bitsPerPixel = bitsPerPixel;
    newCache->pixelsWide = pixelsWide;
    newCache->pixelsHigh = pixelsHigh;
    objc_setAssociatedObject(rep, &kCachedCairoDataKey,
        [NSValue valueWithPointer: newCache],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Note: need a release mechanism -- use a tiny wrapper object instead
  }
```

**Simpler alternative** using an NSMutableDictionary cache keyed by image rep pointer (with weak-like invalidation on dealloc). However, associated objects is cleaner since it ties the cache lifetime to the image rep.

**Steps:**
1. Open `libs-back/Source/cairo/CairoGState.m`
2. Add cache-check code before the conversion switch statement
3. Add cache-store code after conversion completes
4. Build: `cd libs-back && make`
5. Test: draw the same image 100 times, verify only 1 conversion occurs

**Benchmark:** Draw a 512x512 image 1000 times, measure total `DPSimage` time. Expect ~10x speedup on repeated draws (memcpy is much faster than per-pixel bit manipulation + malloc).

---

### Task 11: Add live resize throttling in libs-gui

**File:** `libs-gui/Source/NSWindow.m`

**Problem:** During window live resize, every pixel of mouse movement triggers a full relayout and redraw cycle. On complex UIs, this can drop to <10 fps, making resize feel sluggish. macOS throttles live resize to 60fps and defers non-essential layout.

**Current state (from `NSWindow.m`):**
- `preservesContentDuringLiveResize` flag exists (line 2122) but only controls content preservation, not throttle
- No throttle mechanism exists in the current code

**Implementation -- add a display throttle during live resize:**

Add ivars or use associated objects for throttle state:
```objc
// In NSWindow's implementation section or a class extension:
static const char kLastResizeDisplayTimeKey;
static const double kLiveResizeMinInterval = 1.0 / 60.0;  // 60fps cap
```

Find the method that handles resize events and add throttling. The resize is driven by the backend sending `NSAppKitDefined` events with `GSAppKitWindowResized` subtype, which triggers `setFrame:display:`. Add throttling in the resize path:

```objc
// Add a helper method:
- (BOOL) _shouldThrottleLiveResizeDisplay
{
  if (![self inLiveResize])
    return NO;

  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  NSNumber *lastTime = objc_getAssociatedObject(self, &kLastResizeDisplayTimeKey);

  if (lastTime && (now - [lastTime doubleValue]) < kLiveResizeMinInterval)
    return YES;

  objc_setAssociatedObject(self, &kLastResizeDisplayTimeKey,
    @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return NO;
}
```

Then in the display path during resize (in `displayIfNeeded` or `_







`:
```objc
- (void) displayIfNeeded
{
  if ([self _shouldThrottleLiveResizeDisplay])
    return;
  // ... existing implementation ...
}
```

**Steps:**
1. Open `libs-gui/Source/NSWindow.m`
2. Find `displayIfNeeded` or the method called during resize
3. Add throttle check
4. Build: `cd libs-gui && make`
5. Test: resize a window with a complex view hierarchy, observe smoothness

**Benchmark:** Measure fps during resize of a window containing an NSTableView with 10K rows. Before: ~5-15 fps. After: capped at 60fps with dropped intermediate frames.

---

## SPRINT 3: Architectural Improvements (higher effort)

### Task 12: Replace NSView single `_invalidRect` with dirty region list in libs-gui

**File:** `libs-gui/Source/NSView.m`, around line 2841

**Problem:** Each NSView has a single `_invalidRect` that is the union of all dirty rectangles (line 2842: `invalidRect = NSUnionRect(_invalidRect, invalidRect)`). If two small corners of a large view are invalidated, the union covers the entire view, causing a full redraw. This is especially wasteful for views like NSTableView where individual cells update independently.

**Before (line 2841-2848):**
```objc
invalidRect = NSIntersectionRect(invalidRect, _bounds);
invalidRect = NSUnionRect(_invalidRect, invalidRect);
if (NSEqualRects(invalidRect, _invalidRect) == NO)
  {
    NSView	*firstOpaque = [self opaqueAncestor];

    _rFlags.needs_display = YES;
    _invalidRect = invalidRect;
```

**After -- implement a GSRegion (up to 8 rects, merge beyond):**

Add a new structure (in a private header or at the top of NSView.m):
```objc
#define GS_REGION_MAX_RECTS 8

typedef struct {
    NSRect rects[GS_REGION_MAX_RECTS];
    unsigned count;
} GSRegion;

static inline void GSRegionInit(GSRegion *region)
{
    region->count = 0;
}

static inline NSRect GSRegionBounds(const GSRegion *region)
{
    if (region->count == 0)
        return NSZeroRect;
    NSRect bounds = region->rects[0];
    for (unsigned i = 1; i < region->count; i++)
        bounds = NSUnionRect(bounds, region->rects[i]);
    return bounds;
}

static inline void GSRegionAddRect(GSRegion *region, NSRect rect)
{
    if (NSIsEmptyRect(rect))
        return;

    /* Check if the new rect is already contained in any existing rect */
    for (unsigned i = 0; i < region->count; i++)
      {
        if (NSContainsRect(region->rects[i], rect))
            return;
      }

    if (region->count < GS_REGION_MAX_RECTS)
      {
        region->rects[region->count++] = rect;
      }
    else
      {
        /* Merge the two closest rects, then add the new one */
        CGFloat minArea = CGFLOAT_MAX;
        unsigned mergeA = 0, mergeB = 1;
        for (unsigned i = 0; i < region->count; i++)
          for (unsigned j = i + 1; j < region->count; j++)
            {
              NSRect merged = NSUnionRect(region->rects[i], region->rects[j]);
              CGFloat area = merged.size.width * merged.size.height;
              if (area < minArea)
                {
                  minArea = area;
                  mergeA = i;
                  mergeB = j;
                }
            }
        region->rects[mergeA] = NSUnionRect(region->rects[mergeA],
                                            region->rects[mergeB]);
        region->rects[mergeB] = region->rects[region->count - 1];
        region->rects[region->count - 1] = rect;
        /* count stays the same since we merged two into one and added one */
      }
}

static inline BOOL GSRegionIsEmpty(const GSRegion *region)
{
    return region->count == 0;
}

static inline void GSRegionReset(GSRegion *region)
{
    region->count = 0;
}
```

This requires changing the `_invalidRect` ivar from `NSRect` to `GSRegion`, which is an ABI change. To minimize disruption, keep `_invalidRect` as the bounding box (for API compatibility) but add a private `GSRegion *_dirtyRegion` pointer:

```objc
// In view init:
_dirtyRegion = calloc(1, sizeof(GSRegion));

// In setNeedsDisplayInRect:
GSRegionAddRect(_dirtyRegion, invalidRect);
_invalidRect = GSRegionBounds(_dirtyRegion);

// In drawRect: / displayIfNeeded - iterate region rects:
for (unsigned i = 0; i < _dirtyRegion->count; i++)
  {
    NSRect dirtyRect = _dirtyRegion->rects[i];
    // ... clip and draw ...
  }
```

**Steps:**
1. Add `GSRegion` to a private header (`GSPrivate.h` or new `GSRegion.h`)
2. Add `_dirtyRegion` ivar to NSView (via class extension or category)
3. Modify `_setNeedsDisplayInRect_real:` to use `GSRegionAddRect`
4. Modify drawing code to iterate region rects
5. Build and test extensively -- this touches the core display pipeline

**Benchmark:** Invalidate two 10x10 rects at opposite corners of a 1000x1000 view. Before: redraws 1,000,000 pixels. After: redraws 200 pixels. Measure `drawRect:` time.

---

### Task 13: Fix CFRunLoop per-iteration malloc in libs-corebase

**File:** `libs-corebase/Source/CFRunLoop.c`, lines 482-505 and 522-523

**Problem:** Every iteration of `CFRunLoopNotifyObservers` and `CFRunLoopProcessTimers` calls `CFAllocatorAllocate` to create a snapshot array and `CFAllocatorDeallocate` to free it. This is a malloc+free per run loop iteration, which is wasteful when the count is small (typical case: <10 observers and <10 timers).

**Before (`CFRunLoopNotifyObservers`, line 482):**
```c
count = CFSetGetCount(context->observers);
observers = (CFRunLoopObserverRef*) CFAllocatorAllocate(NULL,
                                 sizeof(CFRunLoopObserverRef)*count, 0);
CFSetGetValues(context->observers, (const void**) observers);
// ... use observers ...
CFAllocatorDeallocate(NULL, (void*) observers);
```

**Before (`CFRunLoopProcessTimers`, line 522):**
```c
count = CFArrayGetCount(context->timers);
timers = (CFRunLoopTimerRef*) CFAllocatorAllocate(NULL,
                              sizeof(CFRunLoopTimerRef)*count, 0);
CFArrayGetValues(context->timers, CFRangeMake(0, count), (const void**) timers);
// ... use timers ...
CFAllocatorDeallocate(NULL, (void*) timers);
```

**After -- use stack buffer with heap fallback:**
```c
#define CFRUNLOOP_STACK_BUFFER_SIZE 64

// In CFRunLoopNotifyObservers:
CFRunLoopObserverRef stackObservers[CFRUNLOOP_STACK_BUFFER_SIZE];
CFRunLoopObserverRef *observers;

GSMutexLock (&rl->_lock);
count = CFSetGetCount(context->observers);
if (count <= CFRUNLOOP_STACK_BUFFER_SIZE)
  observers = stackObservers;
else
  observers = (CFRunLoopObserverRef*) CFAllocatorAllocate(NULL,
                                   sizeof(CFRunLoopObserverRef)*count, 0);
CFSetGetValues(context->observers, (const void**) observers);
GSMutexUnlock (&rl->_lock);

// ... use observers (unchanged) ...

if (observers != stackObservers)
  CFAllocatorDeallocate(NULL, (void*) observers);


// In CFRunLoopProcessTimers:
CFRunLoopTimerRef stackTimers[CFRUNLOOP_STACK_BUFFER_SIZE];
CFRunLoopTimerRef *timers;

GSMutexLock (&rl->_lock);
count = CFArrayGetCount(context->timers);
if (count <= CFRUNLOOP_STACK_BUFFER_SIZE)
  timers = stackTimers;
else
  timers = (CFRunLoopTimerRef*) CFAllocatorAllocate(NULL,
                                sizeof(CFRunLoopTimerRef)*count, 0);
CFArrayGetValues(context->timers, CFRangeMake(0, count), (const void**) timers);
GSMutexUnlock (&rl->_lock);

// ... use timers (unchanged) ...

if (timers != stackTimers)
  CFAllocatorDeallocate(NULL, (void*) timers);
```

Stack buffer size: `64 * sizeof(void*) = 512 bytes` on 64-bit -- negligible stack usage and covers 99%+ of real-world cases.

**Steps:**
1. Open `libs-corebase/Source/CFRunLoop.c`
2. Add `#define CFRUNLOOP_STACK_BUFFER_SIZE 64`
3. Modify `CFRunLoopNotifyObservers` and `CFRunLoopProcessTimers` as shown
4. Build: `cd libs-corebase && make`
5. Run tests: `cd libs-corebase && make check`

**Benchmark:** Run a CFRunLoop with 5 timers and 5 observers for 100K iterations. Measure malloc call count (via `DYLD_INSERT_LIBRARIES=libgmalloc.dylib` or `valgrind --tool=massif`). Before: 200K mallocs. After: 0 mallocs (all fit in stack buffer).

---

### Task 14: Persist CALayer presentation layers across frames in libs-quartzcore

**File:** `libs-quartzcore/Source/CARenderer.m`, lines 318-321 and `libs-quartzcore/Source/CALayer.m`, lines 648-666

**Problem:** Every frame, `_updateLayer:atTime:` calls `[layer discardPresentationLayer]` (line 320) which releases the presentation layer, then immediately calls `[layer presentationLayer]` (line 321) which creates a new one via `[[CALayer alloc] initWithLayer: self]`. This is an alloc+init+dealloc per layer per frame. For a UI with 100 layers at 60fps, that's 6000 alloc/dealloc cycles per second.

**Before (`CARenderer.m` lines 318-321):**
```objc
/* Destroy and then recreate the presentation layer.
   This is the easiest way to reset it to default values. */
[layer discardPresentationLayer];
CALayer * presentationLayer = [layer presentationLayer];
```

**Before (`CALayer.m` lines 648-666):**
```objc
- (id) presentationLayer
{
  if (!_modelLayer && !_presentationLayer)
    {
      [self displayIfNeeded];

      _presentationLayer = [[CALayer alloc] initWithLayer: self];
      [_presentationLayer setModelLayer: self];
      assert([_presentationLayer isPresentationLayer]);
    }
  return _presentationLayer;
}

- (void) discardPresentationLayer
{
  [_presentationLayer release];
  _presentationLayer = nil;
}
```

**After -- reset presentation layer in-place instead of destroying/recreating:**

Add a `resetToModelLayer:` method to CALayer:
```objc
// In CALayer.m:
- (void) resetToModelLayer: (CALayer *)model
{
  // Copy all animatable properties from model to self, resetting
  // to the model's current values. This is what initWithLayer: does,
  // but without the alloc/dealloc overhead.
  self.bounds = model.bounds;
  self.position = model.position;
  self.anchorPoint = model.anchorPoint;
  self.transform = model.transform;
  self.sublayerTransform = model.sublayerTransform;
  self.opacity = model.opacity;
  self.hidden = model.hidden;
  self.masksToBounds = model.masksToBounds;
  self.backgroundColor = model.backgroundColor;
  self.cornerRadius = model.cornerRadius;
  self.borderWidth = model.borderWidth;
  self.borderColor = model.borderColor;
  self.shadowColor = model.shadowColor;
  self.shadowOpacity = model.shadowOpacity;
  self.shadowOffset = model.shadowOffset;
  self.shadowRadius = model.shadowRadius;
  self.contents = model.contents;
  self.contentsRect = model.contentsRect;
  self.contentsGravity = model.contentsGravity;
  // Add any other animatable properties...
}
```

Update `presentationLayer` to reuse existing:
```objc
- (id) presentationLayer
{
  if (!_modelLayer && !_presentationLayer)
    {
      [self displayIfNeeded];
      _presentationLayer = [[CALayer alloc] initWithLayer: self];
      [_presentationLayer setModelLayer: self];
      assert([_presentationLayer isPresentationLayer]);
    }
  else if (!_modelLayer && _presentationLayer)
    {
      [self displayIfNeeded];
      [_presentationLayer resetToModelLayer: self];
    }
  return _presentationLayer;
}
```

Update `CARenderer.m`:
```objc
- (void) _updateLayer: (CALayer *)layer
               atTime: (CFTimeInterval)theTime
{
  if ([layer modelLayer])
    layer = [layer modelLayer];

  [CALayer setCurrentFrameBeginTime: theTime];

  /* Reuse presentation layer instead of destroy+recreate.
     resetToModelLayer: copies current model values, which
     animations will then override. */
  CALayer * presentationLayer = [layer presentationLayer];

  /* Tell the presentation layer to apply animations. */
  _nextFrameTime = MIN(_nextFrameTime, [presentationLayer applyAnimationsAtTime: theTime]);
  _nextFrameTime = MAX(_nextFrameTime, theTime);

  // ... rest unchanged ...
}
```

**Steps:**
1. Add `resetToModelLayer:` to `libs-quartzcore/Source/CALayer.m`
2. Declare it in `CALayer+FrameworkPrivate.h`
3. Modify `presentationLayer` to reuse existing presentation layer
4. Remove the `discardPresentationLayer` call from `CARenderer.m _updateLayer:atTime:`
5. Build: `cd libs-quartzcore && make`
6. Run tests (QuartzCore test suite)

**Benchmark:** Render 100 layers at 60fps for 10 seconds. Measure total allocations with `valgrind --tool=massif` or Instruments. Before: 60,000 CALayer allocs. After: 100 CALayer allocs (initial only).

---

### Task 15: Pre-render themed controls to cached bitmaps in libs-gui

**File:** `libs-gui/Source/GSThemeTools.m`, `GSDrawTiles` class (line 739+)

**Problem:** `GSDrawTiles` renders themed controls via 9-tile compositing every time a control is drawn. The `fillRect:background:fillStyle:` method (line 1100) calls style-specific methods like `scaleStyleFillRect:` which composite 9 separate images each time. For commonly-drawn controls (buttons, text fields, scroll bars), this is repeated thousands of times per second.

**Before (`fillRect:background:fillStyle:` at line 1100):**
```objc
- (NSRect) fillRect: (NSRect)rect
         background: (NSColor*)color
          fillStyle: (GSThemeFillStyle)aStyle
{
  if (color == nil)
    [[NSColor redColor] set];
  else
    [color set];

  switch (aStyle)
    {
      case GSThemeFillStyleNone:
           return [self noneStyleFillRect: rect];
      case GSThemeFillStyleScale:
           return [self scaleStyleFillRect: rect];
      // ... etc ...
    }
  return NSZeroRect;
}
```

**After -- add an NSImage cache keyed on (size, style, color):**

Add a cache dictionary to `GSDrawTiles`:
```objc
@interface GSDrawTiles : NSObject
{
  @public
  NSImage *images[9];
  NSRect rects[9];
  NSRect contentRect;
  GSThemeFillStyle style;
  // NEW: cached rendered results
  NSMutableDictionary *_cachedTiles;
}
```

Add a cache key helper:
```objc
static inline NSString *_tileCacheKey(NSSize size, GSThemeFillStyle aStyle, NSColor *color)
{
  // Round to nearest pixel to avoid cache explosion from subpixel differences
  int w = (int)(size.width + 0.5);
  int h = (int)(size.height + 0.5);
  return [NSString stringWithFormat: @"%d,%d,%d,%@", w, h, (int)aStyle,
          color ? [color description] : @"nil"];
}
```

Modify `fillRect:background:fillStyle:`:
```objc
- (NSRect) fillRect: (NSRect)rect
         background: (NSColor*)color
          fillStyle: (GSThemeFillStyle)aStyle
{
  if (rect.size.width <= 0.0 || rect.size.height <= 0.0)
    return NSZeroRect;

  /* Check the cache for a pre-rendered bitmap at this size */
  if (_cachedTiles == nil)
    _cachedTiles = [[NSMutableDictionary alloc] initWithCapacity: 4];

  NSString *key = _tileCacheKey(rect.size, aStyle, color);
  NSImage *cached = [_cachedTiles objectForKey: key];

  if (cached != nil)
    {
      /* Draw the cached bitmap */
      [cached drawInRect: rect
                fromRect: NSMakeRect(0, 0, rect.size.width, rect.size.height)
               operation: NSCompositeSourceOver
                fraction: 1.0];
      /* Compute content rect from cached tiles */
      return [self _contentRectForRect: rect];
    }

  /* Not cached: render into an NSImage, then draw and cache */
  NSImage *tileImage = [[NSImage alloc] initWithSize: rect.size];
  [tileImage lockFocus];

  /* Set up coordinate space matching the target rect */
  NSAffineTransform *xform = [NSAffineTransform transform];
  [xform translateXBy: -rect.origin.x yBy: -rect.origin.y];
  [xform concat];

  /* Render tiles the normal way */
  if (color == nil)
    [[NSColor redColor] set];
  else
    [color set];

  NSRect contentRect;
  switch (aStyle)
    {
      case GSThemeFillStyleNone:
           contentRect = [self noneStyleFillRect: rect]; break;
      case GSThemeFillStyleScale:
           contentRect = [self scaleStyleFillRect: rect]; break;
      case GSThemeFillStyleRepeat:
           contentRect = [self repeatStyleFillRect: rect]; break;
      case GSThemeFillStyleCenter:
           contentRect = [self centerStyleFillRect: rect]; break;
      case GSThemeFillStyleMatrix:
           contentRect = [self matrixStyleFillRect: rect]; break;
      case GSThemeFillStyleScaleAll:
           contentRect = [self scaleAllStyleFillRect: rect]; break;
      default:
           contentRect = NSZeroRect; break;
    }

  [tileImage unlockFocus];

  /* Cache it (limit cache size to prevent memory bloat) */
  if ([_cachedTiles count] > 32)
    [_cachedTiles removeAllObjects];
  [_cachedTiles setObject: tileImage forKey: key];

  /* Draw the cached result */
  [tileImage drawInRect: rect
               fromRect: NSMakeRect(0, 0, rect.size.width, rect.size.height)
              operation: NSCompositeSourceOver
               fraction: 1.0];
  [tileImage release];

  return contentRect;
}
```

Add cache invalidation in `dealloc`:
```objc
- (void) dealloc
{
  unsigned i;
  for (i = 0; i < 9; i++)
    RELEASE(images[i]);
  RELEASE(_cachedTiles);
  [super dealloc];
}
```

**Steps:**
1. Open `libs-gui/Source/GSThemeTools.m`
2. Add `_cachedTiles` ivar to `GSDrawTiles`
3. Add cache key helper function
4. Modify `fillRect:background:fillStyle:` to check/populate cache
5. Add `RELEASE(_cachedTiles)` to `dealloc`
6. Build: `cd libs-gui && make`
7. Test: theme rendering with various controls, verify visual correctness

**Benchmark:** Draw a themed button 10,000 times at the same size. Measure draw time. Before: 9 composites x 10,000 = 90,000 image composites. After: 1 full render + 9,999 single-image blits. Expect 5-8x speedup for repeated draws.

---

## Summary

| Sprint | Task | File | Impact | Risk |
|--------|------|------|--------|------|
| 1 | 1. atomic_load_n | libobjc2/arc.mm | High (hot path) | Very Low |
| 1 | 2. aligned(64) | libobjc2/dtable.c | Medium | Very Low |
| 1 | 3. Expose coalescing | libs-back/XGServerEvent.m | High (UI perf) | Low |
| 1 | 4. CFArray growth | libs-corebase/CFArray.c | High (large arrays) | Very Low |
| 1 | 5. JSON buffer size | libs-base/NSJSONSerialization.m | Medium | Very Low |
| 1 | 6. JSON depth limit | libs-base/NSJSONSerialization.m | Security + perf | Low |
| 2 | 7. Striped weak locks | libobjc2/arc.mm | High (multi-thread) | Medium |
| 2 | 8. NSCache O(1) LRU | libs-base/NSCache.m | Very High | Medium |
| 2 | 9. Timer optimization | libs-base/NSRunLoop.m | Low-Medium | Medium |
| 2 | 10. Cairo cache | libs-back/CairoGState.m | Medium (images) | Low |
| 2 | 11. Resize throttle | libs-gui/NSWindow.m | Medium (UX) | Low |
| 3 | 12. Dirty region list | libs-gui/NSView.m | High (redraw) | High |
| 3 | 13. CFRunLoop stack buf | libs-corebase/CFRunLoop.c | Medium | Low |
| 3 | 14. CALayer reuse | libs-quartzcore/CARenderer.m | High (animation) | Medium |
| 3 | 15. Tile caching | libs-gui/GSThemeTools.m | Medium (theming) | Medium |

**Estimated Total Impact:** 15-40% improvement in overall responsiveness for typical GNUstep applications, with specific hot paths seeing 2-10x improvements.
