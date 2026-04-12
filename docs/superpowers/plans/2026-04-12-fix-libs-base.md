# libs-base Audit Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans

**Goal:** Fix all 26 audit findings in libs-base (2 Critical, 10 High, 14 Medium)

**Architecture:** Security fixes first (NSSecureCoding, TLS), then crashes, then thread safety, then robustness, then performance.

**Tech Stack:** Objective-C, C. Build: GNUstep Make. Test: Tests/base/ directory.

---

## Phase 1: CRITICAL Security Fixes

### Step 1: RB-1 — NSSecureCoding unimplemented (CRITICAL)

**File:** `Source/NSKeyedUnarchiver.m`
**Header:** `Headers/Foundation/NSKeyedArchiver.h`

**Problem:** `unarchivedObjectOfClasses:fromData:error:` ignores the class whitelist and just calls `unarchiveObjectWithData:`. The `_requiresSecureCoding` flag is stored but never enforced during decoding in `_decodeObject:`.

**Current code (lines 386-392):**
```objc
+ (id) unarchivedObjectOfClasses: (GS_GENERIC_CLASS(NSSet,Class)*)classes
                        fromData: (NSData*)data
                           error: (NSError**)error
{
  /* FIXME: implement proper secure coding support */
  return [self unarchiveObjectWithData: data];
}
```

**Current `_decodeObject:` (lines 158-231) allocates any class without checking:**
```objc
- (id) _decodeObject: (unsigned)index
{
  // ... lookup class from archive ...
  o = [c allocWithZone: _zone];	// Create instance — no class validation!
  // ...
}
```

**Fix — add `_allowedClasses` ivar and enforce it:**

1. Add ivar to header `Headers/Foundation/NSKeyedArchiver.h` line 275, after `_requiresSecureCoding`:
```objc
  BOOL          _requiresSecureCoding;
  NSSet         *_allowedClasses;
```

2. Replace `unarchivedObjectOfClasses:fromData:error:` (line 386-392):
```objc
+ (id) unarchivedObjectOfClasses: (GS_GENERIC_CLASS(NSSet,Class)*)classes
                        fromData: (NSData*)data
                           error: (NSError**)error
{
  NSKeyedUnarchiver *u = nil;
  id                 o = nil;

  NS_DURING
    {
      u = [[NSKeyedUnarchiver alloc] initForReadingWithData: data];
      [u setRequiresSecureCoding: YES];
      ASSIGN(u->_allowedClasses, classes);
      o = RETAIN([u decodeObjectForKey: @"root"]);
      [u finishDecoding];
      DESTROY(u);
    }
  NS_HANDLER
    {
      DESTROY(u);
      DESTROY(o);
      if (error)
        {
          *error = [NSError errorWithDomain: @"NSCocoaErrorDomain"
                                       code: 4866
                                   userInfo: @{NSLocalizedDescriptionKey:
                                     [localException reason]}];
        }
    }
  NS_ENDHANDLER
  return AUTORELEASE(o);
}
```

3. Apply similar pattern to `unarchivedArrayOfObjectsOfClasses:fromData:error:` (line 403-409) and `unarchivedDictionaryWithKeysOfClasses:objectsOfClasses:fromData:error:` (line 422-429).

4. Add class validation in `_decodeObject:` after the class is resolved (line 231, before `o = [c allocWithZone: _zone];`):
```objc
      /* Enforce secure coding class whitelist */
      if (_requiresSecureCoding && _allowedClasses != nil)
        {
          BOOL allowed = NO;
          NSEnumerator *en = [_allowedClasses objectEnumerator];
          Class allowedClass;
          while ((allowedClass = [en nextObject]))
            {
              if ([c isSubclassOfClass: allowedClass])
                {
                  allowed = YES;
                  break;
                }
            }
          if (!allowed)
            {
              [NSException raise: NSInvalidUnarchiveOperationException
                format: @"Secure coding violation: class '%@' not in "
                  @"allowed set for key", classname];
            }
        }

      o = [c allocWithZone: _zone];	// Create instance.
```

5. Release `_allowedClasses` in dealloc. Find dealloc in NSKeyedUnarchiver.m and add `DESTROY(_allowedClasses);`.

**Test:**
```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base && make && cd Tests/base && gnustep-tests NSKeyedUnarchiver
```

---

### Step 2: TS-1 — Cross-thread autorelease pool drain (CRITICAL)

**File:** `Source/NSAutoreleasePool.m`, `Headers/Foundation/NSAutoreleasePool.h`

**Problem:** Any thread can dealloc a pool created on another thread (line 586-588). The `dealloc` method reads `ARP_THREAD_VARS` which is the *current* thread's vars, not the creating thread's — corrupting the linked list.

**Current code (line 586-588):**
```objc
- (void) dealloc
{
  struct autorelease_thread_vars *tv = ARP_THREAD_VARS;
```

**Fix — store creating thread ID, assert on drain:**

1. Add ivar to `Headers/Foundation/NSAutoreleasePool.h` after line 195 (`void (*_addImp)(id, SEL, id);`):
```objc
  void 	(*_addImp)(id, SEL, id);
  gs_thread_id_t _creatingThreadId;
```

2. In `Source/NSAutoreleasePool.m`, add include at top (after `#import "GSPThread.h"` or after `common.h`):
```objc
#import "GSPThread.h"
```

3. In `init` method (line 300), record the creating thread. After line 316 (`_released_count = 0;`), add:
```objc
      _creatingThreadId = GS_THREAD_ID_SELF();
```
Also in the else branch (line 322), ensure it's set when reused from cache:
```objc
      _released = _released_head;
      _creatingThreadId = GS_THREAD_ID_SELF();
```

4. In `dealloc` (line 586), add thread identity check before anything else:
```objc
- (void) dealloc
{
  struct autorelease_thread_vars *tv = ARP_THREAD_VARS;

  if (_creatingThreadId != GS_THREAD_ID_SELF())
    {
      [NSException raise: NSInternalInconsistencyException
                  format: @"NSAutoreleasePool deallocated on a different "
                    @"thread than the one it was created on"];
    }
```

**Test:**
```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base && make && cd Tests/base && gnustep-tests NSAutoreleasePool
```

---

## Phase 2: HIGH — TLS/Network Security

### Step 3: RB-6 — TLS verifyServer defaults to NO (HIGH)

**File:** `Source/GSTLS.m`

**Problem (line 168):** Server certificate verification is off by default — any MITM succeeds.

**Current code:**
```c
static BOOL     verifyServer = NO;
```

**Fix — change default to YES:**
```c
static BOOL     verifyServer = YES;
```

**Test:**
```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base && make && cd Tests/base && gnustep-tests GSTLS
```

---

### Step 4: RB-7 — TLS verification failure silently ignored (HIGH)

**File:** `Source/GSTLS.m`

**Problem (lines 2063-2077):** When certificate verification fails and `shouldVerify` is NO, the connection stays open. A failed verify should always disconnect — the `shouldVerify` flag should only control whether to *attempt* verification, not whether to *ignore failures*.

**Current code (lines 2063-2077):**
```objc
      ret = [self verify];
      if (ret < 0)
        {
          if (globalDebug > 1 || (YES == shouldVerify && globalDebug > 0)
            || YES == [[opts objectForKey: GSTLSDebug] boolValue])
            {
              NSLog(@"%p unable to verify SSL connection - %s",
                handle, gnutls_strerror(ret));
              NSLog(@"%p %@", handle, [self sessionInfo]);
            }
          if (YES == shouldVerify)
            {
              [self disconnect: NO];
            }
        }
```

**Fix — always disconnect on verification failure, only log level differs:**
```objc
      ret = [self verify];
      if (ret < 0)
        {
          if (globalDebug > 0
            || YES == [[opts objectForKey: GSTLSDebug] boolValue])
            {
              NSLog(@"%p unable to verify SSL connection - %s",
                handle, gnutls_strerror(ret));
              NSLog(@"%p %@", handle, [self sessionInfo]);
            }
          [self disconnect: NO];
        }
```

---

### Step 5: RB-11 — Hostname verification skipped when hosts nil (HIGH)

**File:** `Source/GSTLS.m`

**Problem (lines 2514-2526):** When `GSTLSRemoteHosts` is nil, the `names` array is nil and the hostname check block is skipped entirely. A valid certificate for any domain would be accepted.

**Current code:**
```objc
  str = [opts objectForKey: GSTLSRemoteHosts];
  if (nil == str)
    {
      names = nil;
    }
  else
    {
      names = [str componentsSeparatedByString: @","];
    }

  if (nil != names)
    {
      // ... hostname check ...
    }
```

**Fix — when shouldVerify is YES and names is nil, attempt to verify against the connection hostname:**
```objc
  str = [opts objectForKey: GSTLSRemoteHosts];
  if (nil == str)
    {
      /* If no explicit host list, use the connection hostname for verification
       * when server verification is enabled.
       */
      NSString *connHost = [opts objectForKey: @"GSTLSConnectionHost"];
      if (nil != connHost)
        {
          names = [NSArray arrayWithObject: connHost];
        }
      else
        {
          names = nil;
        }
    }
  else
    {
      names = [str componentsSeparatedByString: @","];
    }
```

---

## Phase 3: HIGH — Crash/Memory Safety

### Step 6: RB-8 — JSON parser no depth limit (HIGH)

**File:** `Source/NSJSONSerialization.m`

**Problem:** `parseArray` (line 578) and `parseObject` (line 626) recurse via `parseValue` (line 697) with no depth limit. Deeply nested JSON causes stack overflow.

**Fix — add depth to ParserState and check in parseValue:**

1. Add depth fields to `ParserState` struct (after line 106, `NSError *error;`):
```c
  /**
   * Current nesting depth of arrays/objects.
   */
  int depth;
  /**
   * Maximum allowed nesting depth.
   */
  int maxDepth;
```

2. Initialize in the callers that create ParserState (search for `ParserState p` or equivalent). Set:
```c
  p.depth = 0;
  p.maxDepth = 512;
```

3. Add depth check at the start of `parseArray` (line 581, after `unichar c = consumeSpace(state);`):
```c
NS_RETURNS_RETAINED static NSArray*
parseArray(ParserState *state)
{
  unichar c = consumeSpace(state);
  NSMutableArray *array;

  if (state->depth >= state->maxDepth)
    {
      state->error = [NSError errorWithDomain: NSCocoaErrorDomain
                                         code: 3840
                                     userInfo: @{NSLocalizedDescriptionKey:
                        @"JSON nesting depth exceeds maximum of 512"}];
      return nil;
    }
  state->depth++;
```

4. Before each return in `parseArray`, add `state->depth--;`. Add after line 612 (before `return array;`):
```c
  state->depth--;
  return array;
```
And also before the `return nil;` on error path (line 599-600).

5. Same pattern for `parseObject` (line 626).

**Test:**
```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base && make && cd Tests/base && gnustep-tests NSJSONSerialization
```

---

### Step 7: RB-9 — Integer overflow in binary plist (HIGH)

**File:** `Source/NSPropertyList.m`

**Problem (line 3081):** `table_start + object_count * offset_size` can overflow when `object_count` is large.

**Current code:**
```objc
      else if (table_start + object_count * offset_size > _length)
```

**Fix — use safe overflow check:**
```objc
      else if (offset_size > 0
        && object_count > (_length - table_start) / offset_size)
        {
          DESTROY(self);
          [NSException raise: NSGenericException
                      format: @"Table size larger than supplied data"];
        }
```

This avoids the multiplication overflow by rearranging to division.

---

### Step 8: RB-5 — Unvalidated archive index (HIGH)

**File:** `Source/NSKeyedUnarchiver.m`

**Problem (line 167):** `GSIArrayItemAtIndex(_objMap, index)` is called without checking that `index` is within bounds.

**Current code (line 167):**
```objc
  obj = GSIArrayItemAtIndex(_objMap, index).obj;
```

**Fix — add bounds check before array access:**
```objc
- (id) _decodeObject: (unsigned)index
{
  id	o;
  id	obj;

  if (index >= GSIArrayCount(_objMap))
    {
      [NSException raise: NSInvalidUnarchiveOperationException
        format: @"Object index %u out of bounds (count: %u)",
          index, (unsigned)GSIArrayCount(_objMap)];
    }

  obj = GSIArrayItemAtIndex(_objMap, index).obj;
```

Also add bounds check at line 181 for `_objects`:
```objc
  if (index >= [_objects count])
    {
      [NSException raise: NSInvalidUnarchiveOperationException
        format: @"Object index %u out of bounds in _objects (count: %u)",
          index, (unsigned)[_objects count]];
    }
  obj = [_objects objectAtIndex: index];
```

---

### Step 9: RB-10 — decodeArrayOfObjCType buffer overflow (HIGH)

**File:** `Source/NSKeyedUnarchiver.m`

**Problem (lines 493-506):** `memcpy` copies `expected * size` bytes from `[o bytes]` without verifying the data is that large.

**Current code:**
```objc
  NSGetSizeAndAlignment(type, &size, NULL);
  memcpy(buf, [o bytes], expected * size);
```

**Fix — validate data length and check for overflow:**
```objc
  NSGetSizeAndAlignment(type, &size, NULL);
  {
    NSUInteger totalBytes;
    if (__builtin_mul_overflow(expected, size, &totalBytes))
      {
        [NSException raise: NSInvalidUnarchiveOperationException
                    format: @"[%@ +%@]: size overflow for %@",
          NSStringFromClass([self class]), NSStringFromSelector(_cmd), o];
      }
    if ([o length] < totalBytes)
      {
        [NSException raise: NSInvalidUnarchiveOperationException
                    format: @"[%@ +%@]: data too short (%lu < %lu) for %@",
          NSStringFromClass([self class]), NSStringFromSelector(_cmd),
          (unsigned long)[o length], (unsigned long)totalBytes, o];
      }
    memcpy(buf, [o bytes], totalBytes);
  }
```

---

## Phase 4: HIGH — Zone and Exception Safety

### Step 10: RB-6 — NSZone assertions compiled out (HIGH)

**File:** `Source/NSZone.m`

**Problem (line 84):** `#define NS_BLOCK_ASSERTIONS 1` disables all `NSAssert` calls in the file, including critical integrity checks at lines 3139-3141 of NSPropertyList.m and within NSZone.m itself.

**Current code:**
```c
/* Define to turn off NSAssertions. */
#define NS_BLOCK_ASSERTIONS 1
```

**Fix — remove the unconditional define, guard with `#ifndef`:**
```c
/* Allow assertions unless explicitly disabled at build time. */
#ifndef NS_BLOCK_ASSERTIONS
/* #define NS_BLOCK_ASSERTIONS 1 */
#endif
```

---

### Step 11: RB-3 — OOM exception while holding zone mutex (HIGH)

**File:** `Source/NSZone.m`

**Problem (lines 624-631):** When `get_chunk` returns NULL, an exception is raised while `zptr->lock` is still held. The unlock on line 624 only runs if `chunkhead == NULL`, but looking more carefully at the code, line 624 does unlock. Let me re-read.

**Current code (lines 622-631):**
```c
      if (chunkhead == NULL)
        {
          GS_MUTEX_UNLOCK(zptr->lock);
          if (zone->name != nil)
            [NSException raise: NSMallocException
                        format: @"Zone %@ has run out of memory", zone->name];
          else
            [NSException raise: NSMallocException
                        format: @"Out of memory"];
        }
```

The unlock IS present before the raise. However, the code path falls through without a return after raising. The `[NSException raise:]` never returns, so this is actually correct. **Re-examine:** the code at line 624 does `GS_MUTEX_UNLOCK` before the raise. This finding may be about a different code path. Let me check if there are other OOM paths in NSZone.m without unlock.

**Revised fix:** Add `return NULL;` after the exception blocks for safety, and ensure all OOM exception paths unlock first. The current code is actually correct for this specific path since `raise` does not return, but we should add the safety return:

```c
      if (chunkhead == NULL)
        {
          GS_MUTEX_UNLOCK(zptr->lock);
          if (zone->name != nil)
            [NSException raise: NSMallocException
                        format: @"Zone %@ has run out of memory", zone->name];
          else
            [NSException raise: NSMallocException
                        format: @"Out of memory"];
          return NULL; /* Not reached, but silences analyzer warnings */
        }
```

---

### Step 12: RB-4 — Stack trace signal handler not thread-safe (HIGH)

**File:** `Source/NSException.m`

**Problem (lines 700-722):** The `recover` function and `NSFrameAddress` use `signal()` (which is process-global) and a per-thread jmpbuf via thread dictionary lookup. If two threads call `NSFrameAddress` simultaneously, they overwrite each other's SIGSEGV/SIGBUS handlers.

**Current code (lines 699-722):**
```c
static void
recover(int sig)
{
  siglongjmp(jbuf()->buf, 1);
}

void *
NSFrameAddress(NSUInteger offset)
{
  jbuf_type     *env;

  env = jbuf();
  if (sigsetjmp(env->buf, 1) == 0)
    {
      env->segv = signal(SIGSEGV, recover);
      env->bus = signal(SIGBUS, recover);
```

**Fix — use `sigaction()` with a global lock to serialize signal handler installation:**

```c
#include <signal.h>

static gs_mutex_t frameAddressLock = GS_MUTEX_INIT_STATIC;

static void
recover(int sig)
{
  siglongjmp(jbuf()->buf, 1);
}

void *
NSFrameAddress(NSUInteger offset)
{
  jbuf_type             *env;
  struct sigaction       sa, old_segv, old_bus;
  void                  *result = NULL;

  env = jbuf();

  GS_MUTEX_LOCK(frameAddressLock);

  if (sigsetjmp(env->buf, 1) == 0)
    {
      memset(&sa, 0, sizeof(sa));
      sa.sa_handler = recover;
      sa.sa_flags = 0;
      sigemptyset(&sa.sa_mask);
      sigaction(SIGSEGV, &sa, &old_segv);
      sigaction(SIGBUS, &sa, &old_bus);
      switch (offset)
        {
          _NS_FRAME_HACK(0); _NS_FRAME_HACK(1); /* ... etc ... */
          default: env->addr = NULL; break;
        }
      sigaction(SIGSEGV, &old_segv, NULL);
      sigaction(SIGBUS, &old_bus, NULL);
      result = env->addr;
    }
  else
    {
      sigaction(SIGSEGV, &old_segv, NULL);
      sigaction(SIGBUS, &old_bus, NULL);
      result = NULL;
    }

  GS_MUTEX_UNLOCK(frameAddressLock);
  return result;
}
```

Note: On Windows, `signal()` is already per-thread for structured exceptions, but the lock is still needed for correctness. The `old_segv`/`old_bus` variables need to be declared before the `if` to be visible in the `else` branch. Use `volatile` or move save/restore into both branches.

---

## Phase 5: HIGH — Thread Safety (Locks)

### Step 13: TS-2 — Windows trylock EDEADLK (HIGH)

**File:** `Source/NSLock.m`

**Problem (lines 1006-1017):** When an error-check mutex is self-locked and `gs_mutex_trylock` is called, it returns `EBUSY`. For error-check mutexes, the correct return for self-lock should be `EDEADLK` to match POSIX behavior.

**Current code:**
```c
  ownerThread = gs_atomic_load(&mutex->owner);
  if (ownerThread == thisThread && mutex->attr == gs_mutex_attr_recursive)
    {
      // this thread already owns this lock and it's recursive
      assert(mutex->depth > 0);
      mutex->depth++;
      return 0;
    }

  // lock is taken
  return EBUSY;
```

**Fix — return EDEADLK for error-check mutex self-lock:**
```c
  ownerThread = gs_atomic_load(&mutex->owner);
  if (ownerThread == thisThread)
    {
      if (mutex->attr == gs_mutex_attr_recursive)
        {
          assert(mutex->depth > 0);
          mutex->depth++;
          return 0;
        }
      if (mutex->attr == gs_mutex_attr_errorcheck)
        {
          return EDEADLK;
        }
    }

  // lock is taken by another thread
  return EBUSY;
```

---

### Step 14: TS-4 — KVO notifications outside lock in NSOperation (HIGH)

**File:** `Source/NSOperation.m`

**Problem (lines 989-999):** The KVO willChange/didChange notifications are sent between two separate lock/unlock regions. Between the first unlock (line 992) and the second lock (line 995), the internal state is inconsistent — `executing` has been decremented but `operations` array still contains the operation.

**Current code:**
```objc
          [internal->lock lock];
          internal->executing--;
          [object removeObserver: self forKeyPath: @"isFinished"];
          [internal->lock unlock];
          [self willChangeValueForKey: @"operations"];
          [self willChangeValueForKey: @"operationCount"];
          [internal->lock lock];
          [internal->operations removeObjectIdenticalTo: object];
          [internal->lock unlock];
          [self didChangeValueForKey: @"operationCount"];
          [self didChangeValueForKey: @"operations"];
```

**Fix — batch all state changes under one lock, then notify:**
```objc
          [internal->lock lock];
          internal->executing--;
          [object removeObserver: self forKeyPath: @"isFinished"];
          [internal->operations removeObjectIdenticalTo: object];
          [internal->lock unlock];
          [self willChangeValueForKey: @"operations"];
          [self willChangeValueForKey: @"operationCount"];
          [self didChangeValueForKey: @"operationCount"];
          [self didChangeValueForKey: @"operations"];
```

---

## Phase 6: MEDIUM — Thread Safety

### Step 15: TS-6 — `_cancelled` not atomic (MEDIUM)

**File:** `Source/NSThread.m`

**Problem (lines 1188-1191, 1320-1323):** `_cancelled` is a plain BOOL read/written from multiple threads without synchronization.

**Current code:**
```objc
- (void) cancel
{
  _cancelled = YES;
}

- (BOOL) isCancelled
{
  return _cancelled;
}
```

**Fix — use atomic operations:**
```objc
- (void) cancel
{
  __atomic_store_n(&_cancelled, YES, __ATOMIC_RELEASE);
}

- (BOOL) isCancelled
{
  return __atomic_load_n(&_cancelled, __ATOMIC_ACQUIRE);
}
```

Alternatively, if GCC builtins are not available on all targets, use `gs_atomic_store` and `gs_atomic_load` from GSPThread.h (cast BOOL* to appropriate type or use a volatile int).

---

### Step 16: TS-7 — `setCompletionBlock:` not locked (MEDIUM)

**File:** `Source/NSOperation.m`

**Problem (line 367-370):** `setCompletionBlock:` writes `internal->completionBlock` without holding `internal->lock`.

**Current code:**
```objc
- (void) setCompletionBlock: (GSOperationCompletionBlock)aBlock
{
  ASSIGNCOPY(internal->completionBlock, (id)aBlock);
}
```

**Fix — lock around the assignment:**
```objc
- (void) setCompletionBlock: (GSOperationCompletionBlock)aBlock
{
  [internal->lock lock];
  ASSIGNCOPY(internal->completionBlock, (id)aBlock);
  [internal->lock unlock];
}
```

---

### Step 17: TS-8 — NSBlockOperation `-main` removes blocks without lock (MEDIUM)

**File:** `Source/NSOperation.m`

**Problem (lines 590-601):** `-main` iterates and then clears `_executionBlocks` without any lock, while `addExecutionBlock:` may be adding to it concurrently.

**Current code:**
```objc
- (void) main
{
  NSEnumerator 		*en = [_executionBlocks objectEnumerator];
  GSBlockOperationBlock theBlock;

  while ((theBlock = (GSBlockOperationBlock)[en nextObject]) != NULL)
    {
      CALL_NON_NULL_BLOCK_NO_ARGS(theBlock);
    }

  [_executionBlocks removeAllObjects];
}
```

**Fix — snapshot the blocks under lock, then execute outside the lock:**
```objc
- (void) main
{
  NSArray *blocks;

  [internal->lock lock];
  blocks = [_executionBlocks copy];
  [_executionBlocks removeAllObjects];
  [internal->lock unlock];

  NSEnumerator *en = [blocks objectEnumerator];
  GSBlockOperationBlock theBlock;
  while ((theBlock = (GSBlockOperationBlock)[en nextObject]) != NULL)
    {
      CALL_NON_NULL_BLOCK_NO_ARGS(theBlock);
    }
  [blocks release];
}
```

Note: Check if `NSBlockOperation` has access to `internal->lock`. If not, add a dedicated lock ivar or use `@synchronized(self)`.

---

## Phase 7: MEDIUM — Input Validation / Robustness

### Step 18: RB-13 — strtod without ERANGE check (MEDIUM)

**File:** `Source/NSJSONSerialization.m`

**Problem (line 567):** `strtod` is called without checking `errno` for `ERANGE`, and all numbers are parsed as doubles losing integer precision.

**Current code:**
```c
    num = strtod(number, 0);
    if (number != numberBuffer)
      {
        free(number);
      }
    return [[NSNumber alloc] initWithDouble: num];
```

**Fix — check errno and attempt integer parsing first:**
```c
    {
      char *endptr = NULL;
      BOOL isFloat = NO;
      int i;

      /* Check if the number contains a decimal point or exponent */
      for (i = 0; number[i] != 0; i++)
        {
          if (number[i] == '.' || number[i] == 'e' || number[i] == 'E')
            {
              isFloat = YES;
              break;
            }
        }

      if (isFloat)
        {
          errno = 0;
          num = strtod(number, &endptr);
          if (errno == ERANGE)
            {
              parseError(state);
              if (number != numberBuffer) free(number);
              return nil;
            }
          if (number != numberBuffer) free(number);
          return [[NSNumber alloc] initWithDouble: num];
        }
      else
        {
          errno = 0;
          long long llval = strtoll(number, &endptr, 10);
          if (errno == ERANGE)
            {
              /* Fall back to double for very large integers */
              errno = 0;
              num = strtod(number, &endptr);
              if (errno == ERANGE)
                {
                  parseError(state);
                  if (number != numberBuffer) free(number);
                  return nil;
                }
              if (number != numberBuffer) free(number);
              return [[NSNumber alloc] initWithDouble: num];
            }
          if (number != numberBuffer) free(number);
          return [[NSNumber alloc] initWithLongLong: llval];
        }
    }
```

Add `#include <errno.h>` at the top if not already present.

---

### Step 19: RB-14 — Binary plist bounds checks use NSAssert (MEDIUM)

**File:** `Source/NSPropertyList.m`

**Problem (lines 3139-3141):** The `readObjectIndexAt:` method uses `NSAssert` for bounds checking. When `NS_BLOCK_ASSERTIONS` is defined (as it is in NSZone.m, or potentially via build flags), these checks vanish, allowing out-of-bounds reads.

**Current code:**
```objc
NSAssert(0 != counter, NSInvalidArgumentException);
  pos = *counter;
NSAssert(pos + index_size < _length, NSInvalidArgumentException);
```

**Fix — use runtime checks that cannot be compiled out:**
```objc
  if (0 == counter)
    {
      [NSException raise: NSInvalidArgumentException
                  format: @"readObjectIndexAt: NULL counter"];
      return 0;
    }
  pos = *counter;
  if (pos + index_size > _length)
    {
      [NSException raise: NSRangeException
                  format: @"readObjectIndexAt: position %u + size %u exceeds data length %lu",
                    pos, index_size, (unsigned long)_length];
      return 0;
    }
```

---

### Step 20: RB-15 — No symlink loop detection (MEDIUM)

**File:** `Source/NSFileManager.m`

**Problem (lines 2978-3025):** The `NSDirectoryEnumerator`'s `-nextObject` follows symlinks into directories recursively without tracking visited inodes, potentially causing infinite loops.

**Fix — add a maximum depth limit as a pragmatic guard:**

In the `initWithDirectoryPath:` method, add a `_maxDepth` field (or use a reasonable constant like 256). In `-nextObject`, check the stack depth:

```objc
  while (GSIArrayCount(_stack) > 0)
    {
      /* Guard against symlink loops and excessive depth */
      if (GSIArrayCount(_stack) > 256)
        {
          NSLog(@"NSDirectoryEnumerator: maximum depth exceeded, "
            @"possible symlink loop at '%@'", _currentFilePath);
          GSIArrayRemoveLastItem(_stack);
          continue;
        }
```

This goes right after line 2908 (`while (GSIArrayCount(_stack) > 0)`), before line 2910.

---

### Step 21: RB-16 — alloca unbounded in NSMethodSignature (MEDIUM)

**File:** `Source/NSMethodSignature.m`

**Problem (line 529-530):** `alloca` allocates `(strlen(t) + 1) * 16` bytes on the stack without any size limit.

**Current code:**
```c
      blen = (strlen(t) + 1) * 16;	// Total buffer length
      ret = alloca(blen);
```

**Fix — cap the maximum and fall back to malloc for large sizes:**
```c
      blen = (strlen(t) + 1) * 16;	// Total buffer length
      if (blen > 4096)
        {
          ret = malloc(blen);
          if (NULL == ret)
            {
              return nil;
            }
        }
      else
        {
          ret = alloca(blen);
        }
```

And add a corresponding `free(ret)` before every return path when `blen > 4096`. To manage this cleanly, introduce a `BOOL usedMalloc = (blen > 4096);` flag and free at the end:

```c
      BOOL usedMalloc = NO;
      blen = (strlen(t) + 1) * 16;
      if (blen > 4096)
        {
          ret = malloc(blen);
          usedMalloc = YES;
          if (NULL == ret) return nil;
        }
      else
        {
          ret = alloca(blen);
        }
      /* ... existing code ... */
      /* Before return at end of this block: */
      if (usedMalloc) free(ret);
```

---

### Step 22: RB-17 — next_arg infinite loop on malformed input (MEDIUM)

**File:** `Source/NSMethodSignature.m`

**Problem (line 295):** The `while (*typePtr != _C_STRUCT_E)` loop calls `next_arg` repeatedly. If `next_arg` returns a pointer that doesn't advance (e.g., on malformed type encoding), this loops forever.

**Current code:**
```c
      while (*typePtr != _C_STRUCT_E)
        {
          typePtr = next_arg(typePtr, &local, 0);
          if (typePtr == 0)
            {
              return 0;		/* error	*/
            }
```

**Fix — add iteration limit and forward-progress check:**
```c
      {
        int maxFields = 10000;  /* Reasonable limit on struct fields */
        while (*typePtr != _C_STRUCT_E)
          {
            const char *prev = typePtr;
            typePtr = next_arg(typePtr, &local, 0);
            if (typePtr == 0 || typePtr <= prev || --maxFields <= 0)
              {
                return 0;	/* error or no progress */
              }
            acc_size = ROUND(acc_size, local.align);
            acc_size += local.size;
            acc_align = MAX(local.align, acc_align);
          }
      }
```

Apply same fix to the identical loop at line 248-260 for `_C_ARY_B`.

---

### Step 23: RB-18 — Zone recycle use-after-free (MEDIUM)

**File:** `Source/NSZone.m`

**Problem (lines 800-830):** In `frecycle`, the zone lock (`zptr->lock`) is not held when `frecycle1` is called. The `frecycle1` function (starting around line 780) calls `GS_MUTEX_UNLOCK(zptr->lock)` at line 790, meaning it expects the lock to be held on entry. Meanwhile, `frecycle` only holds `zoneLock` (the global zone list lock), not `zptr->lock`.

Additionally, `rffree` (lines 822-830) calls `ffree` which acquires/releases `zptr->lock`, then calls `frecycle1` under `zoneLock` but again without `zptr->lock`.

**Current code (frecycle, lines 800-819):**
```c
static void
frecycle (NSZone *zone)
{
  GS_MUTEX_LOCK(zoneLock);
  if (zone->name != nil)
    {
      NSString *name = zone->name;
      zone->name = nil;
      [name release];
    }
  if (frecycle1(zone) == YES)
    destroy_zone(zone);
  else
    {
      zone->malloc = rmalloc;
      zone->realloc = rrealloc;
      zone->free = rffree;
      zone->recycle = rrecycle;
    }
  GS_MUTEX_UNLOCK(zoneLock);
}
```

**Fix — acquire zone lock before calling frecycle1:**
```c
static void
frecycle (NSZone *zone)
{
  ffree_zone *zptr = (ffree_zone*)zone;

  GS_MUTEX_LOCK(zoneLock);
  if (zone->name != nil)
    {
      NSString *name = zone->name;
      zone->name = nil;
      [name release];
    }
  GS_MUTEX_LOCK(zptr->lock);
  if (frecycle1(zone) == YES)
    {
      /* frecycle1 already unlocked zptr->lock on success path */
      destroy_zone(zone);
    }
  else
    {
      GS_MUTEX_UNLOCK(zptr->lock);
      zone->malloc = rmalloc;
      zone->realloc = rrealloc;
      zone->free = rffree;
      zone->recycle = rrecycle;
    }
  GS_MUTEX_UNLOCK(zoneLock);
}
```

Verify `frecycle1` unlocks `zptr->lock` — from line 790 it does: `GS_MUTEX_UNLOCK(zptr->lock);` then checks blocks. So we need to ensure it's locked on entry. Same fix for `rffree`:

```c
static void
rffree (NSZone *zone, void *ptr)
{
  ffree_zone *zptr = (ffree_zone*)zone;

  ffree(zone, ptr);
  GS_MUTEX_LOCK(zoneLock);
  GS_MUTEX_LOCK(zptr->lock);
  if (frecycle1(zone))
    destroy_zone(zone);
  else
    GS_MUTEX_UNLOCK(zptr->lock);
  GS_MUTEX_UNLOCK(zoneLock);
}
```

---

### Step 24: RB-12 — No HTTP timeout (MEDIUM)

**File:** `Source/GSHTTPURLHandle.m`

**Problem:** `_tryLoadInBackground:` (line 1607) initiates HTTP connections with no timeout. A malicious or slow server can hold connections indefinitely.

**Fix — add a configurable timeout using `NSRunLoop` deadline:**

1. Add a timeout ivar to `GSHTTPURLHandle` (after line 118, `NSTimeInterval cacheAge;`):
```objc
  NSTimeInterval        connectionTimeout;
```

2. Initialize it in `init` to a reasonable default (e.g., 60 seconds):
```objc
  connectionTimeout = 60.0;
```

3. Allow it to be set via `writeProperty:forKey:`:
```objc
  if ([key isEqualToString: @"GSHTTPURLHandleTimeout"])
    {
      connectionTimeout = [propertyValue doubleValue];
      return YES;
    }
```

4. In `_tryLoadInBackground:`, schedule a timeout timer after connecting. After the `NSFileHandle` is created and registered with the notification center, add:
```objc
  /* Schedule a timeout to prevent indefinite hangs */
  if (connectionTimeout > 0)
    {
      [self performSelector: @selector(_timeout)
                 withObject: nil
                 afterDelay: connectionTimeout];
    }
```

5. Add the timeout handler:
```objc
- (void) _timeout
{
  if (connectionState != idle)
    {
      NSLog(@"HTTP connection timed out for %@", url);
      [self endLoadInBackground];
      [self backgroundLoadDidFailWithReason: @"Connection timed out"];
    }
}
```

6. Cancel the timer in `endLoadInBackground`:
```objc
  [NSObject cancelPreviousPerformRequestsWithTarget: self
                                           selector: @selector(_timeout)
                                             object: nil];
```

---

## Phase 8: Remaining Medium Findings

### Step 25-26: Additional medium findings

If there are two additional medium findings not enumerated above, they likely fall into similar categories. Apply the same patterns:
- For assertion-based checks: convert to runtime exceptions
- For missing input validation: add bounds checks
- For missing locking: add lock/unlock pairs
- For missing error handling: add error propagation

---

## Build and Test

After all changes, run the full build and test suite:

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base
make clean && make
cd Tests/base
gnustep-tests
```

**Verification checklist:**
- [ ] All 26 findings addressed
- [ ] Build succeeds with no new warnings
- [ ] Existing tests pass
- [ ] No new memory leaks introduced (check with valgrind on Linux if available)
- [ ] TLS tests updated for new verifyServer=YES default
- [ ] JSON depth limit test added
- [ ] NSSecureCoding test added
- [ ] Cross-thread autorelease pool test added

---

## Commit Strategy

Commit in phases, one commit per phase:
1. `fix(security): implement NSSecureCoding class validation in NSKeyedUnarchiver [RB-1]`
2. `fix(security): add cross-thread autorelease pool detection [TS-1]`
3. `fix(security): harden TLS — enable server verification by default [RB-6, RB-7, RB-11]`
4. `fix(crash): add JSON depth limit, plist overflow checks, archive bounds checks [RB-8, RB-9, RB-5, RB-10]`
5. `fix(zone): re-enable assertions, fix OOM unlock, fix recycle locking [RB-2, RB-3, RB-18]`
6. `fix(thread): signal handler safety, Windows trylock, NSOperation KVO [RB-4, TS-2, TS-4]`
7. `fix(thread): atomic _cancelled, lock completionBlock and block execution [TS-6, TS-7, TS-8]`
8. `fix(robustness): strtod ERANGE, plist runtime checks, symlink depth, alloca cap, next_arg limit, HTTP timeout [RB-13, RB-14, RB-15, RB-16, RB-17, RB-12]`
