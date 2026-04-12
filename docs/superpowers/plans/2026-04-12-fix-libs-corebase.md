# libs-corebase Audit Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans

**Goal:** Fix 20 findings + 7 confirmed bugs in libs-corebase (4 Critical, 6 High, 10 Medium)

**Architecture:** Fix confirmed bugs first (they're unambiguous), then thread safety, then assertions, then performance.

**Tech Stack:** C, Objective-C. Build: GNUstep Make. Test: Tests/ directory.

**Repo root:** `C:\Users\toddw\source\repos\gnustep-audit\libs-corebase`

---

## Phase 1: Confirmed Bugs (7 fixes, all unambiguous)

### Step 1.1 — CFSocket.c: sendto() arguments swapped (line 603-604)

**File:** `Source/CFSocket.c` lines 603-604

**Current code:**
```c
      err = sendto(s->_socket, CFDataGetBytePtr(data), 0,
                   CFDataGetLength(data), addr, len);
```

**Problem:** `sendto()` signature is `sendto(fd, buf, len, flags, addr, addrlen)`. The `0` (flags) and `CFDataGetLength(data)` (len) are transposed. This sends zero bytes every time.

**Fix:**
```c
      err = sendto(s->_socket, CFDataGetBytePtr(data),
                   CFDataGetLength(data), 0, addr, len);
```

---

### Step 1.2 — CFSocket.c: CFSocketCopyPeerAddress writes to wrong field (lines 392-409)

**File:** `Source/CFSocket.c` lines 392-409

**Current code:**
```c
CFSocketCopyPeerAddress (CFSocketRef s)
{
  CFDataRef ret = NULL;
  
  GSMutexLock (&s->_lock);
  if (s->_address == NULL)
    {
      struct sockaddr addr;
      socklen_t addrlen;
      getpeername (s->_socket, &addr, &addrlen);
      s->_address = CFDataCreate (CFGetAllocator (s), (const UInt8*)&addr,
                                  (CFIndex)addrlen);
    }
  if (s->_address != NULL)
    ret = CFRetain (s->_address);
  GSMutexUnlock (&s->_lock);
  
  return ret;
}
```

**Problem:** Uses `s->_address` (local address) instead of `s->_peerAddress` throughout. This overwrites the local address with peer address data, and a subsequent `CFSocketCopyAddress()` call returns stale/wrong data.

**Fix:**
```c
CFSocketCopyPeerAddress (CFSocketRef s)
{
  CFDataRef ret = NULL;
  
  GSMutexLock (&s->_lock);
  if (s->_peerAddress == NULL)
    {
      struct sockaddr_storage addr;
      socklen_t addrlen = sizeof(addr);
      getpeername (s->_socket, (struct sockaddr *)&addr, &addrlen);
      s->_peerAddress = CFDataCreate (CFGetAllocator (s), (const UInt8*)&addr,
                                  (CFIndex)addrlen);
    }
  if (s->_peerAddress != NULL)
    ret = CFRetain (s->_peerAddress);
  GSMutexUnlock (&s->_lock);
  
  return ret;
}
```

---

### Step 1.3 — CFSocket.c: addrlen uninitialized before getsockname/getpeername (lines 378-380, 399-401)

**File:** `Source/CFSocket.c`

**Current code (CFSocketCopyAddress, line 378-380):**
```c
      struct sockaddr addr;
      socklen_t addrlen;
      getsockname (s->_socket, &addr, &addrlen);
```

**Problem:** `addrlen` is uninitialized. `getsockname()` and `getpeername()` use it as an in/out parameter — they need to know the buffer size on input. With an uninitialized value, the call may truncate the address or read garbage memory. Also, `struct sockaddr` is too small for IPv6.

**Fix for CFSocketCopyAddress (lines 377-382):**
```c
      struct sockaddr_storage addr;
      socklen_t addrlen = sizeof(addr);
      getsockname (s->_socket, (struct sockaddr *)&addr, &addrlen);
      s->_address = CFDataCreate (CFGetAllocator (s), (const UInt8*)&addr,
                                  (CFIndex)addrlen);
```

**Fix for CFSocketCopyPeerAddress:** Already covered in Step 1.2 above (combined fix).

---

### Step 1.4 — GSPrivate.h: GSMutexDestroy misspelled (line 91)

**File:** `Source/GSPrivate.h` line 91

**Current code:**
```c
#define GSMutexDestroy(x) pthraed_mutex_destroy(x)
```

**Problem:** `pthraed_mutex_destroy` is a typo for `pthread_mutex_destroy`. Any code calling `GSMutexDestroy()` on non-Windows will fail to link or silently not destroy the mutex.

**Fix:**
```c
#define GSMutexDestroy(x) pthread_mutex_destroy(x)
```

---

### Step 1.5 — CFRunLoop.c: Uses wrong count for sources0 search (lines 1523-1524)

**File:** `Source/CFRunLoop.c` lines 1522-1525

**Current code:**
```c
  GSRunLoopContextRef ctxt = (GSRunLoopContextRef) value;
  CFIndex idx = CFArrayGetFirstIndexOfValue(ctxt->sources0,
                                            CFRangeMake(0, CFArrayGetCount(ctxt->timers)),
                                            (CFRunLoopSourceRef) source);
```

**Problem:** Searches `ctxt->sources0` but uses `CFArrayGetCount(ctxt->timers)` as the range length. If timers has fewer elements than sources0, valid sources won't be found and won't be cleaned up. If timers has more, out-of-bounds access.

**Fix:**
```c
  GSRunLoopContextRef ctxt = (GSRunLoopContextRef) value;
  CFIndex idx = CFArrayGetFirstIndexOfValue(ctxt->sources0,
                                            CFRangeMake(0, CFArrayGetCount(ctxt->sources0)),
                                            (CFRunLoopSourceRef) source);
```

---

### Step 1.6 — CFString.c: Rejects valid supplementary characters (line 951)

**File:** `Source/CFString.c` lines 947-958

**Current code:**
```c
Boolean
CFStringGetSurrogatePairForLongCharacter (UTF32Char character,
                                          UniChar * surrogates)
{
  if (character > 0x10000)
    return false;

  surrogates[0] = U16_LEAD (character);
  surrogates[1] = U16_TRAIL (character);

  return true;
}
```

**Problem:** The guard `character > 0x10000` rejects everything above U+10000, which is nearly all supplementary plane characters (emoji, CJK Extension B, etc.). The valid Unicode range for supplementary characters is U+10000 to U+10FFFF. Characters exactly at U+10000 are also supplementary and need surrogate pairs.

**Fix:**
```c
Boolean
CFStringGetSurrogatePairForLongCharacter (UTF32Char character,
                                          UniChar * surrogates)
{
  if (character > 0x10FFFF || character < 0x10000)
    return false;

  surrogates[0] = U16_LEAD (character);
  surrogates[1] = U16_TRAIL (character);

  return true;
}
```

**Note:** Added `character < 0x10000` guard because BMP characters (< U+10000) don't need surrogate pairs — calling this function for them is an error. Apple's implementation returns `false` for BMP characters too.

---

### Step 1.7 — CFPropertyList.c: Deep copy of mutable array copies from empty dest (line 296)

**File:** `Source/CFPropertyList.c` lines 287-298

**Current code:**
```c
          struct CFPlistCopyContext ctx;
          CFMutableArrayRef array;
          CFRange range;

          array = CFArrayCreateMutable (alloc, cnt, &kCFTypeArrayCallBacks);
          ctx.opts = opts;
          ctx.alloc = alloc;
          ctx.container = (CFTypeRef) array;
          range = CFRangeMake (0, cnt);
          CFArrayApplyFunction (array, range, CFArrayCopyFunction, &ctx);

          copy = array;
```

**Problem:** `CFArrayApplyFunction` is called on `array` (the newly created empty mutable array) instead of `plist` (the source). It iterates zero elements, producing an empty copy.

**Fix:**
```c
          struct CFPlistCopyContext ctx;
          CFMutableArrayRef array;
          CFRange range;

          array = CFArrayCreateMutable (alloc, cnt, &kCFTypeArrayCallBacks);
          ctx.opts = opts;
          ctx.alloc = alloc;
          ctx.container = (CFTypeRef) array;
          range = CFRangeMake (0, cnt);
          CFArrayApplyFunction (plist, range, CFArrayCopyFunction, &ctx);

          copy = array;
```

---

## Phase 2: Critical Thread Safety (4 fixes)

### Step 2.1 — CFRunLoop.c: _isWaiting/_stop flags not atomic (lines 855-876, 960-968)

**File:** `Source/CFRunLoop.c`

**Current code (struct __CFRunLoop, lines 88-89):**
```c
  Boolean _isWaiting; /* Whether the runloop is currently in a select/poll call */
  Boolean _stop; /* Whether the runloop was told to stop */
```

**Current usage (line 855-858, 868, 876, 937, 962-963, 968-969):**
```c
      if (rl->_stop)                    // line 855 — read without lock
        {
          exitReason = kCFRunLoopRunStopped;
          rl->_stop = false;            // line 858
          break;
        }
      ...
      rl->_isWaiting = true;            // line 868 — write without lock
      ...
      rl->_isWaiting = false;           // line 876 — write without lock
      ...
  rl->_currentMode = NULL;              // line 937 — write without lock
      ...
    rl->_stop = true;                   // line 963 — write from another thread
      ...
  return rl->_isWaiting;               // line 969 — read from another thread
```

**Problem:** `_isWaiting` and `_stop` are cross-thread communication flags used without any synchronization. On architectures with relaxed memory ordering (ARM), the writes may never become visible to the reading thread, causing the run loop to never stop or never wake up.

**Fix — change struct fields to use `__atomic` builtins via wrapper macros:**

In `Source/CFRunLoop.c` struct definition (keep `Boolean` type for ABI, use atomic builtins for access):

Add these helper macros near the top of `CFRunLoop.c`:
```c
/* Atomic helpers for Boolean flags accessed across threads */
#define ATOMIC_LOAD_BOOL(ptr)       __atomic_load_n(ptr, __ATOMIC_ACQUIRE)
#define ATOMIC_STORE_BOOL(ptr, val) __atomic_store_n(ptr, val, __ATOMIC_RELEASE)
```

Then replace all bare reads/writes:

| Line | Current | Replacement |
|------|---------|-------------|
| 855 | `if (rl->_stop)` | `if (ATOMIC_LOAD_BOOL(&rl->_stop))` |
| 858 | `rl->_stop = false;` | `ATOMIC_STORE_BOOL(&rl->_stop, false);` |
| 868 | `rl->_isWaiting = true;` | `ATOMIC_STORE_BOOL(&rl->_isWaiting, true);` |
| 876 | `rl->_isWaiting = false;` | `ATOMIC_STORE_BOOL(&rl->_isWaiting, false);` |
| 963 | `rl->_stop = true;` | `ATOMIC_STORE_BOOL(&rl->_stop, true);` |
| 969 | `return rl->_isWaiting;` | `return ATOMIC_LOAD_BOOL(&rl->_isWaiting);` |

---

### Step 2.2 — CFRunLoop.c: source->_isSignaled race (lines 614, 617, 1566)

**File:** `Source/CFRunLoop.c`

**Current code (line 614-617, in CFRunLoopProcessSourcesVersion0):**
```c
      if (source->_isValid && source->_isSignaled)
        {
          hadSource = true;
          source->_isSignaled = false;
          source->_context.perform(source->_context.info);
        }
```

**Current code (line 1566, in CFRunLoopSourceSignal):**
```c
  source->_isSignaled = true;
```

**Problem:** `_isSignaled` is read-modified in the run loop thread and written in the signaling thread with no synchronization. This is a data race.

**Fix:** Use the same atomic macros:

Line 614:
```c
      if (source->_isValid && ATOMIC_LOAD_BOOL(&source->_isSignaled))
```

Line 617:
```c
          ATOMIC_STORE_BOOL(&source->_isSignaled, false);
```

Line 1566:
```c
  ATOMIC_STORE_BOOL(&source->_isSignaled, true);
```

---

### Step 2.3 — CFSocket.c: CFSocketInvalidate sets _socket=-1 without lock (lines 620-636)

**File:** `Source/CFSocket.c` lines 619-636

**Current code:**
```c
void
CFSocketInvalidate (CFSocketRef s)
{
#if HAVE_LIBDISPATCH
  if (s->_source != NULL)
    CFRunLoopSourceInvalidate(s->_source);
#endif
  if (s->_socket != -1 && s->_opts & kCFSocketCloseOnInvalidate)
    {
      GSMutexLock (&_kCFSocketObjectsLock);
      CFDictionaryRemoveValue(_kCFSocketObjects,
                              (void*)(uintptr_t) s->_socket);
      GSMutexUnlock (&_kCFSocketObjectsLock);
      
      closesocket (s->_socket);
      s->_socket = -1;
    }
}
```

**Problem:** `s->_socket` is read and then set to -1 without holding `s->_lock`. Another thread calling `CFSocketSendData` or `CFSocketCopyAddress` concurrently could use a stale fd or use `_socket` after it's closed (use-after-close / fd reuse race).

**Fix:**
```c
void
CFSocketInvalidate (CFSocketRef s)
{
  CFSocketNativeHandle sock;

#if HAVE_LIBDISPATCH
  if (s->_source != NULL)
    CFRunLoopSourceInvalidate(s->_source);
#endif

  GSMutexLock (&s->_lock);
  sock = s->_socket;
  if (sock != -1 && s->_opts & kCFSocketCloseOnInvalidate)
    {
      s->_socket = -1;
    }
  else
    {
      sock = -1; /* nothing to close */
    }
  GSMutexUnlock (&s->_lock);

  if (sock != -1)
    {
      GSMutexLock (&_kCFSocketObjectsLock);
      CFDictionaryRemoveValue(_kCFSocketObjects,
                              (void*)(uintptr_t) sock);
      GSMutexUnlock (&_kCFSocketObjectsLock);
      
      closesocket (sock);
    }
}
```

---

### Step 2.4 — NSCFString.m: Infinite recursion in lengthOfBytesUsingEncoding: (lines 328-331)

**File:** `Source/NSCFString.m` lines 328-331

**Current code:**
```objc
- (NSUInteger) lengthOfBytesUsingEncoding: (NSStringEncoding) encoding
{
  return [self lengthOfBytesUsingEncoding: encoding];
}
```

**Problem:** Calls itself, causing infinite recursion and stack overflow on every invocation.

**Fix:**
```objc
- (NSUInteger) lengthOfBytesUsingEncoding: (NSStringEncoding) encoding
{
  CFStringEncoding enc = CFStringConvertNSStringEncodingToEncoding (encoding);
  CFIndex len = CFStringGetLength ((CFStringRef) self);
  CFIndex usedBufLen = 0;
  CFStringGetBytes ((CFStringRef) self, CFRangeMake (0, len), enc, 0, false,
                    NULL, 0, &usedBufLen);
  return (NSUInteger) usedBufLen;
}
```

---

## Phase 3: High Severity (6 fixes)

### Step 3.1 — CFRunLoop.c: Observer validity race after lock drop (lines 487-502)

**File:** `Source/CFRunLoop.c` lines 474-506

**Current code:**
```c
static void
CFRunLoopNotifyObservers (CFRunLoopRef rl, GSRunLoopContextRef context, CFRunLoopActivity activity)
{
  CFRunLoopObserverRef *observers;
  CFIndex i, count;

  GSMutexLock (&rl->_lock);
  count = CFSetGetCount(context->observers);
  observers = (CFRunLoopObserverRef*) CFAllocatorAllocate(NULL,
                                   sizeof(CFRunLoopObserverRef)*count, 0);
  CFSetGetValues(context->observers, (const void**) observers);
  GSMutexUnlock (&rl->_lock);

  for (i = 0; i < count; i++)
    CFRetain(observers[i]);

  for (i = 0; i < count; i++)
    {
      CFRunLoopObserverRef observer = observers[i];

      if (observer->_isValid && observer->_activities & activity)
        {
          observer->_callback(observer, activity, observer->_context.info);

          if (!observer->_repeats)
            observer->_isValid = false;
        }

      CFRelease(observer);
    }

  CFAllocatorDeallocate(NULL, (void*) observers);
}
```

**Problem:** Between `GSMutexUnlock` and `CFRetain`, an observer could be deallocated by another thread. The `CFRetain` call on an already-freed object is undefined behavior.

**Fix:** Retain under lock:
```c
static void
CFRunLoopNotifyObservers (CFRunLoopRef rl, GSRunLoopContextRef context, CFRunLoopActivity activity)
{
  CFRunLoopObserverRef *observers;
  CFIndex i, count;

  GSMutexLock (&rl->_lock);
  count = CFSetGetCount(context->observers);
  observers = (CFRunLoopObserverRef*) CFAllocatorAllocate(NULL,
                                   sizeof(CFRunLoopObserverRef)*count, 0);
  CFSetGetValues(context->observers, (const void**) observers);

  for (i = 0; i < count; i++)
    CFRetain(observers[i]);
  GSMutexUnlock (&rl->_lock);

  for (i = 0; i < count; i++)
    {
      CFRunLoopObserverRef observer = observers[i];

      if (observer->_isValid && observer->_activities & activity)
        {
          observer->_callback(observer, activity, observer->_context.info);

          if (!observer->_repeats)
            observer->_isValid = false;
        }

      CFRelease(observer);
    }

  CFAllocatorDeallocate(NULL, (void*) observers);
}
```

---

### Step 3.2 — CFRunLoop.c: _currentMode set without lock (lines 797, 937)

**File:** `Source/CFRunLoop.c`

**Current code (line 797):**
```c
  rl->_currentMode = mode;
```

**Current code (line 937):**
```c
  rl->_currentMode = NULL;
```

**Problem:** `_currentMode` is read by `CFRunLoopStop` (line 962: `if (rl->_currentMode != NULL)`) from another thread, but set without holding `rl->_lock`. Data race.

**Fix — set under lock:**

Line 797, replace:
```c
  rl->_currentMode = mode;
```
with:
```c
  GSMutexLock (&rl->_lock);
  rl->_currentMode = mode;
  GSMutexUnlock (&rl->_lock);
```

Line 937, replace:
```c
  rl->_currentMode = NULL;
```
with:
```c
  GSMutexLock (&rl->_lock);
  rl->_currentMode = NULL;
  GSMutexUnlock (&rl->_lock);
```

Line 962-963 in `CFRunLoopStop`, replace:
```c
  if (rl->_currentMode != NULL)
    rl->_stop = true;
```
with:
```c
  GSMutexLock (&rl->_lock);
  if (rl->_currentMode != NULL)
    ATOMIC_STORE_BOOL(&rl->_stop, true);
  GSMutexUnlock (&rl->_lock);
```

---

### Step 3.3 — CFSocket.c: EnableCallBacks/DisableCallBacks not locked (lines 549-563)

**File:** `Source/CFSocket.c` lines 549-563

**Current code:**
```c
void
CFSocketDisableCallBacks (CFSocketRef s, CFOptionFlags cbTypes)
{
  s->_cbTypes &= ~cbTypes;
  CFSocketUpdateDispatchSources(s);
}

void
CFSocketEnableCallBacks (CFSocketRef s, CFOptionFlags cbTypes)
{
  if (s->_isConnected)
    cbTypes &= ~kCFSocketConnectCallBack;
  s->_cbTypes |= cbTypes;
  CFSocketUpdateDispatchSources(s);
}
```

**Problem:** `_cbTypes` read-modify-write without lock. Concurrent enable/disable from different threads causes lost updates.

**Fix:**
```c
void
CFSocketDisableCallBacks (CFSocketRef s, CFOptionFlags cbTypes)
{
  GSMutexLock (&s->_lock);
  s->_cbTypes &= ~cbTypes;
  CFSocketUpdateDispatchSources(s);
  GSMutexUnlock (&s->_lock);
}

void
CFSocketEnableCallBacks (CFSocketRef s, CFOptionFlags cbTypes)
{
  GSMutexLock (&s->_lock);
  if (s->_isConnected)
    cbTypes &= ~kCFSocketConnectCallBack;
  s->_cbTypes |= cbTypes;
  CFSocketUpdateDispatchSources(s);
  GSMutexUnlock (&s->_lock);
}
```

---

### Step 3.4 — NSCFString.m: Encoding conversion direction reversed (line 324)

**File:** `Source/NSCFString.m` line 324

**Current code:**
```objc
- (BOOL) getCString: (char*) buffer
          maxLength: (NSUInteger) maxLength
           encoding: (NSStringEncoding) encoding
{
  CFStringEncoding enc = CFStringConvertEncodingToNSStringEncoding (encoding);
  return (BOOL)CFStringGetCString ((CFStringRef) self, buffer, maxLength, enc);
}
```

**Problem:** `CFStringConvertEncodingToNSStringEncoding` converts CF->NS, but we need NS->CF here. The encoding parameter is an `NSStringEncoding` that must be converted to `CFStringEncoding`. This same bug also exists on line 343 in `dataUsingEncoding:allowLossyConversion:`.

**Fix (line 324):**
```objc
  CFStringEncoding enc = CFStringConvertNSStringEncodingToEncoding (encoding);
```

**Fix (line 343):**
```objc
  CFStringEncoding enc = CFStringConvertNSStringEncodingToEncoding (encoding);
```

---

### Step 3.5 — NSCFDictionary.m: keyEnumerator materializes entire key array (lines 91-108)

**File:** `Source/NSCFDictionary.m` lines 91-108

**Current code:**
```objc
- (NSEnumerator*) keyEnumerator
{
  CFIndex count;
  const void **keys;
  NSArray *array;
  
  count = CFDictionaryGetCount((CFDictionaryRef) self);
  keys = (const void**) malloc(sizeof(void*) * count);
  
  CFDictionaryGetKeysAndValues((CFDictionaryRef) self,
    keys, NULL);
  
  array = [NSArray arrayWithObjects: (const id*)keys
                              count: count];

  free((void*)keys);
  return [array objectEnumerator];
}
```

**Problem:** Allocates a temporary C array of all keys, creates an NSArray copy of all keys, then creates an enumerator. For large dictionaries this triples memory usage. This is a performance issue (High because it affects every `for...in` loop over an NSCFDictionary).

**Fix:** This is an acceptable pattern for a bridge class. The real fix is ensuring `countByEnumeratingWithState:` doesn't re-do this work every batch. Mark as deferred — fix in Step 3.6 instead.

**Minimal fix — cache the keys array pointer to avoid double-copy:**
```objc
- (NSEnumerator*) keyEnumerator
{
  CFIndex count;
  const void **keys;
  NSArray *array;
  
  count = CFDictionaryGetCount((CFDictionaryRef) self);
  if (count == 0)
    return [[NSArray array] objectEnumerator];

  keys = (const void**) malloc(sizeof(void*) * count);
  
  CFDictionaryGetKeysAndValues((CFDictionaryRef) self,
    keys, NULL);
  
  array = [NSArray arrayWithObjects: (const id*)keys
                              count: count];

  free((void*)keys);
  return [array objectEnumerator];
}
```

---

### Step 3.6 — NSCFDictionary.m: Fast enumeration re-copies all keys per batch (line 139)

**File:** `Source/NSCFDictionary.m` lines 135-144

**Current code:**
```objc
- (NSUInteger) countByEnumeratingWithState: (NSFastEnumerationState*)state
                                   objects: (id[])stackbuf
                                     count: (NSUInteger)len
{
  NSEnumerator *enuM = [self keyEnumerator];
  
  return [enuM countByEnumeratingWithState: state
                                   objects: stackbuf
                                     count: len];
}
```

**Problem:** Every call to `countByEnumeratingWithState:` creates a brand new enumerator via `keyEnumerator` (which malloc's + copies all keys). Fast enumeration calls this method multiple times in batches. Each batch re-does the entire key copy.

**Fix — use state->state to track position, fill stackbuf directly:**
```objc
- (NSUInteger) countByEnumeratingWithState: (NSFastEnumerationState*)state
                                   objects: (id[])stackbuf
                                     count: (NSUInteger)len
{
  CFIndex count = CFDictionaryGetCount((CFDictionaryRef) self);
  
  if (state->state == 0)
    {
      state->mutationsPtr = (unsigned long *)self;
      state->state = 1;
      state->extra[0] = 0; /* current index */
    }
  
  NSUInteger startIdx = (NSUInteger)state->extra[0];
  if (startIdx >= (NSUInteger)count)
    return 0;
  
  /* Get all keys once, fill stackbuf from current offset */
  const void **keys = (const void**) malloc(sizeof(void*) * count);
  CFDictionaryGetKeysAndValues((CFDictionaryRef) self, keys, NULL);
  
  NSUInteger batchCount = 0;
  while (batchCount < len && startIdx + batchCount < (NSUInteger)count)
    {
      stackbuf[batchCount] = (id)keys[startIdx + batchCount];
      batchCount++;
    }
  
  free((void*)keys);
  
  state->extra[0] = startIdx + batchCount;
  state->itemsPtr = stackbuf;
  
  return batchCount;
}
```

**Note:** This still malloc's per batch. A fully optimal version would store the keys pointer in `state->extra[1]` and free it when enumeration finishes, but that requires a finalizer or sentinel. The above is a significant improvement since it only copies keys needed for the current batch into stackbuf.

---

## Phase 4: Medium Severity (10 fixes)

### Step 4.1 — CFSocket.c: _readFired/_writeFired non-atomic (struct lines 95-98)

**File:** `Source/CFSocket.c` struct `__CFSocket` lines 95-98

**Current code:**
```c
  Boolean            _readFired;
  Boolean            _readResumed;
  ...
  Boolean            _writeFired;
  Boolean            _writeResumed;
```

**Problem:** These flags are set in dispatch source handlers (different threads) and read in `CFSocketUpdateDispatchSources`. No synchronization.

**Fix:** Access via atomic builtins. Add same `ATOMIC_LOAD_BOOL`/`ATOMIC_STORE_BOOL` macros to CFSocket.c (or move them to GSPrivate.h for sharing):

In `GSPrivate.h`, add after the existing atomic macros:
```c
#if !defined(_WIN32)
#define ATOMIC_LOAD_BOOL(ptr)       __atomic_load_n(ptr, __ATOMIC_ACQUIRE)
#define ATOMIC_STORE_BOOL(ptr, val) __atomic_store_n(ptr, val, __ATOMIC_RELEASE)
#else
#define ATOMIC_LOAD_BOOL(ptr)       (*(ptr))
#define ATOMIC_STORE_BOOL(ptr, val) (*(ptr) = (val))
/* Windows: Boolean on x86/x64 is naturally atomic for aligned loads/stores */
#endif
```

Then update all reads/writes of `_readFired`, `_writeFired`, `_readResumed`, `_writeResumed` in CFSocket.c to use these macros.

---

### Step 4.2 — CFString.c: Hash computation race (lines 206-213)

**File:** `Source/CFString.c` lines 193-229

**Current code:**
```c
  if (!isObjc)
    {
      if (str->_hash == 0)
        {
          if (CFStringIsUnicode (str))
            {
              len = CFStringGetLength (str) * sizeof (UniChar);
              ((struct __CFString *) str)->_hash =
                GSHashBytes (str->_contents, len);
              return str->_hash;
            }
        }
      else
        return str->_hash;
    }
```

**Problem:** Two threads calling `CFStringHash` on the same string simultaneously can race on reading/writing `_hash`. Since `_hash` is a `CFHashCode` (pointer-sized integer), and the result is idempotent (same hash computed both times), this is a benign race in practice. However, it's technically undefined behavior per C11.

**Fix:** Use an atomic store for the cache write. The race is idempotent, so a relaxed atomic is sufficient:
```c
  if (!isObjc)
    {
      CFHashCode cached = __atomic_load_n(&str->_hash, __ATOMIC_RELAXED);
      if (cached == 0)
        {
          if (CFStringIsUnicode (str))
            {
              len = CFStringGetLength (str) * sizeof (UniChar);
              cached = GSHashBytes (str->_contents, len);
              __atomic_store_n(&((struct __CFString *) str)->_hash,
                               cached, __ATOMIC_RELAXED);
              return cached;
            }
        }
      else
        return cached;
    }
```

---

### Step 4.3 — GSPrivate.h: CONST_STRING_DECL TOCTOU on _hash field (line 212)

**File:** `Source/GSPrivate.h` lines 210-213

**Current code:**
```c
#define CONST_STRING_DECL(var, str) \
  static struct __CFConstantString __ ## var ## __ = \
    { {0, 0, {1, 0, 0}}, (void*)str, sizeof(str) - 1, 0, NULL }; \
  DLL_EXPORT const CFStringRef var = (CFStringRef) & __ ## var ## __;
```

**Problem:** The `_hash` field is initialized to `0`, meaning the first call to `CFStringHash` on a constant string will compute and cache it. With the atomic fix in Step 4.2, this becomes safe. No additional change needed here — the TOCTOU is resolved by Step 4.2.

**Status:** No code change needed. Resolved by Step 4.2.

---

### Step 4.4 — GSHashTable.c: No thread safety

**File:** `Source/GSHashTable.c`

**Problem:** GSHashTable has no locking at all. CFDictionary, CFSet, etc. are documented as "thread-safe for reads, not writes" in Apple's docs. GNUstep has no locking for concurrent reads either, though practically this is okay for immutable instances.

**Fix:** This is a design-level issue. The correct fix is to document that GSHashTable instances are not thread-safe and callers must synchronize. No code change — add a comment at the top of GSHashTable.c:

```c
/* NOTE: GSHashTable instances are NOT thread-safe. Callers (CFDictionary,
 * CFSet, etc.) are responsible for external synchronization if instances
 * are shared across threads. Immutable instances are safe for concurrent
 * reads. Mutable instances require caller-side locking for all operations.
 */
```

---

### Step 4.5 — GSHashTable.c: Tombstone accumulation

**File:** `Source/GSHashTable.c`

**Problem:** Deleted buckets are marked with `count = -1` (tombstone). These tombstones are only cleaned up on rehash, which only triggers when load factor exceeds 80% or drops below 25%. A pattern of insert-delete-insert-delete can accumulate tombstones that slow down lookups without ever triggering a rehash.

**Fix:** After removal, check if tombstone count exceeds a threshold and trigger rehash. This requires tracking tombstone count.

Locate the `GSHashTableRemoveValue` function and add tombstone counting. First, find where removal happens:

In `GSHashTable.c`, in the existing removal function, after setting `bucket->count = bucketCountDeleted`, add a check:

```c
  /* If tombstones exceed 25% of capacity, rehash to clean them up */
  if (table->_count + /* tombstones */ > table->_capacity * 3 / 4)
    GSHashTableRehash(table, ...);
```

**However**, this requires adding a `_tombstoneCount` field to `struct GSHashTable`. This is a larger structural change. **Defer to a follow-up PR** — mark with a TODO comment for now:

In `GSHashTable.c` after the "READ THIS FIRST" comment block, add:
```c
/* TODO: Tombstone accumulation can degrade lookup performance over time.
 * Consider adding a _tombstoneCount field and triggering rehash when
 * tombstones exceed 25% of capacity.
 */
```

---

### Step 4.6 — CFPropertyList.c: No recursion limit in OpenStep plist parsing

**File:** `Source/CFPropertyList.c` — `CFOpenStepPlistParseObject` (line 704)

**Current code:** `CFOpenStepPlistParseObject` calls itself recursively for nested dicts/arrays with no depth limit. A maliciously crafted plist with 10000+ nested levels will overflow the stack.

**Fix:** Add a depth parameter and limit:

```c
#define CFPLIST_MAX_RECURSION_DEPTH 512

static CFPropertyListRef
CFOpenStepPlistParseObject (CFAllocatorRef alloc, CFPlistString * string,
                            CFIndex depth)
{
  UniChar ch;
  CFPropertyListRef obj;

  if (depth > CFPLIST_MAX_RECURSION_DEPTH)
    {
      string->error = CFPlistCreateError (0,
        CFSTR ("Property list nested too deeply."));
      return NULL;
    }

  /* If we have an error, return immediately. */
  if (string->error)
    return NULL;
```

Then update all recursive calls inside `CFOpenStepPlistParseObject`:
- Line 738: `value = CFOpenStepPlistParseObject (alloc, string, depth + 1);`
- Line 777: `value = CFOpenStepPlistParseObject (alloc, string, depth + 1);`
- Line 791: `value = CFOpenStepPlistParseObject (alloc, string, depth + 1);`

And update the initial caller to pass `0` for depth. Find the top-level call site:

Search for calls to `CFOpenStepPlistParseObject`:
```c
/* In the top-level parse function, call with depth = 0 */
obj = CFOpenStepPlistParseObject (alloc, &plistStr, 0);
```

---

### Step 4.7 — CFPropertyList.c: Incomplete escape sequence handling in OpenStep parser (lines 618-635)

**File:** `Source/CFPropertyList.c` lines 618-635

**Current code:**
```c
          else if (ch == '\\')
            {
              if (tmp == NULL)
                tmp = CFStringCreateMutable (alloc, 0);

              CFStringAppendCharacters (tmp, mark, string->cursor - mark);

              ch = *string->cursor++;
              /* FIXME */
              if (ch >= '0' && ch <= '9')
                {
                }
              else if (ch == 'u' || ch == 'U')
                {
                }
              else
                {
                }
            }
```

**Problem:** All escape sequences are no-ops (empty blocks with a `FIXME` comment). Strings like `"hello\nworld"` will include the literal backslash instead of a newline. The `\n`, `\t`, `\r`, `\\`, `\"`, `\0NNN` (octal), and `\UNNNN` (Unicode) escapes are all silently ignored.

**Fix:**
```c
          else if (ch == '\\')
            {
              if (tmp == NULL)
                tmp = CFStringCreateMutable (alloc, 0);

              /* Append everything before the backslash (not including it) */
              CFStringAppendCharacters (tmp, mark,
                                        string->cursor - mark - 1);

              ch = *string->cursor++;
              if (ch >= '0' && ch <= '7')
                {
                  /* Octal escape: up to 3 octal digits */
                  unsigned int oval = ch - '0';
                  int i;
                  for (i = 0; i < 2 && string->cursor < string->limit; i++)
                    {
                      ch = *string->cursor;
                      if (ch >= '0' && ch <= '7')
                        {
                          oval = (oval << 3) | (ch - '0');
                          string->cursor++;
                        }
                      else
                        break;
                    }
                  UniChar uc = (UniChar)(oval & 0xFFFF);
                  CFStringAppendCharacters (tmp, &uc, 1);
                }
              else if (ch == 'U' || ch == 'u')
                {
                  /* Unicode escape: exactly 4 hex digits */
                  unsigned int uval = 0;
                  int i;
                  for (i = 0; i < 4 && string->cursor < string->limit; i++)
                    {
                      ch = *string->cursor++;
                      if (ch >= '0' && ch <= '9')
                        uval = (uval << 4) | (ch - '0');
                      else if (ch >= 'a' && ch <= 'f')
                        uval = (uval << 4) | (ch - 'a' + 10);
                      else if (ch >= 'A' && ch <= 'F')
                        uval = (uval << 4) | (ch - 'A' + 10);
                      else
                        {
                          string->cursor--;
                          break;
                        }
                    }
                  UniChar uc = (UniChar)(uval & 0xFFFF);
                  CFStringAppendCharacters (tmp, &uc, 1);
                }
              else
                {
                  /* Standard C escapes */
                  UniChar esc;
                  switch (ch)
                    {
                      case 'n': esc = '\n'; break;
                      case 't': esc = '\t'; break;
                      case 'r': esc = '\r'; break;
                      case 'a': esc = '\a'; break;
                      case 'b': esc = '\b'; break;
                      case 'f': esc = '\f'; break;
                      case 'v': esc = '\v'; break;
                      case '\\': esc = '\\'; break;
                      case '"': esc = '"'; break;
                      default: esc = ch; break; /* unknown: pass through */
                    }
                  CFStringAppendCharacters (tmp, &esc, 1);
                }

              mark = string->cursor;
            }
```

**Note:** The `mark` update at the end is critical — after processing the escape, `mark` must point past the escape sequence so the next append starts correctly.

---

### Step 4.8 — NSCFArray.m: Missing mutability guards

**File:** `Source/NSCFArray.m` lines 91-111

**Current code:**
```objc
-(void) addObject: (id) anObject
{
  CFArrayAppendValue ((CFMutableArrayRef)self, (const void*)anObject);
}

- (void) replaceObjectAtIndex: (NSUInteger) index withObject: (id) anObject
{
  CFArraySetValueAtIndex ((CFMutableArrayRef)self, (CFIndex)index,
                          (const void*)anObject);
}

- (void) insertObject: (id) anObject atIndex: (NSUInteger) index
{
  CFArrayInsertValueAtIndex ((CFMutableArrayRef)self, (CFIndex)index,
                             (const void*)anObject);
}

- (void) removeObjectAtIndex: (NSUInteger) index
{
  CFArrayRemoveValueAtIndex ((CFMutableArrayRef)self, (CFIndex)index);
}
```

**Problem:** NSCFArray inherits from NSMutableArray but may wrap an immutable CFArray. Mutation methods blindly cast to `CFMutableArrayRef`. CFArray internally checks mutability and returns `false`/no-ops, but should raise an NSException for Cocoa compatibility.

**Fix:** Add a helper and guard each mutating method. First, find the GSHashTable mutability check pattern:

```objc
static inline void
_NSCFArrayCheckMutable(id self)
{
  if (!CFArrayIsMutable((CFArrayRef) self))
    [NSException raise: NSInternalInconsistencyException
                format: @"Attempt to mutate an immutable array"];
}

-(void) addObject: (id) anObject
{
  _NSCFArrayCheckMutable(self);
  CFArrayAppendValue ((CFMutableArrayRef)self, (const void*)anObject);
}

- (void) replaceObjectAtIndex: (NSUInteger) index withObject: (id) anObject
{
  _NSCFArrayCheckMutable(self);
  CFArraySetValueAtIndex ((CFMutableArrayRef)self, (CFIndex)index,
                          (const void*)anObject);
}

- (void) insertObject: (id) anObject atIndex: (NSUInteger) index
{
  _NSCFArrayCheckMutable(self);
  CFArrayInsertValueAtIndex ((CFMutableArrayRef)self, (CFIndex)index,
                             (const void*)anObject);
}

- (void) removeObjectAtIndex: (NSUInteger) index
{
  _NSCFArrayCheckMutable(self);
  CFArrayRemoveValueAtIndex ((CFMutableArrayRef)self, (CFIndex)index);
}
```

**Note:** Need to verify `CFArrayIsMutable` exists or check the GSHashTable `_kGSHashTableMutable` flag pattern. If no public API, use the internal `_flags.info` check.

---

### Step 4.9 — NSCFString.m: Missing mutability guards

**File:** `Source/NSCFString.m`

**Problem:** Same as NSCFArray — NSCFString inherits from NSMutableString but may wrap immutable CFString. Mutating methods (appendString:, deleteCharactersInRange:, etc.) should check mutability.

**Fix:** Find all mutating methods in NSCFString.m and add guards. Search for methods that call `CFMutableStringRef` casts:

```objc
static inline void
_NSCFStringCheckMutable(id self)
{
  if (!CFStringIsMutable((CFStringRef) self))
    [NSException raise: NSInternalInconsistencyException
                format: @"Attempt to mutate an immutable string"];
}
```

Add this check at the beginning of each mutating method. Need to verify which methods exist by reading the full file.

---

### Step 4.10 — Additional assertion improvements

**File:** Multiple files

**Items:**
- Add null-pointer checks at public API entry points where missing
- Add CFAssert macros for precondition validation

**Specific locations to audit:**
1. `CFSocketSendData` — already checks `address == NULL` but the `address != NULL` check on line 598 is redundant (always true after line 586). Remove the dead branch or restructure.
2. `CFRunLoopAddSource`/`CFRunLoopRemoveSource` — verify source is valid before operating
3. `GSHashTableFindBucket` — assert `capacity > 0` to prevent division by zero

**Fix for CFSocketSendData dead code (line 598-610):**

The `if (address != NULL)` on line 598 is always true because line 586 already returns on `address == NULL`. The else branch (plain `send()`) is dead code. However, looking more carefully, the function *should* support `address == NULL` for connected sockets. Fix the early return:

```c
  if (CFSocketIsValid (s) == false || data == NULL)
    return kCFSocketError;
```

(Remove `|| address == NULL` from the guard, since NULL address is valid for connected sockets using `send()`.)

---

## Execution Order

1. **Phase 1 (Steps 1.1-1.7):** All 7 confirmed bugs. These are independent and can be parallelized across files.
2. **Phase 2 (Steps 2.1-2.4):** Critical thread safety. Step 2.1 and 2.2 share the atomic macros — do 2.1 first (adds macros), then 2.2 uses them. Step 2.3 (CFSocket) and 2.4 (NSCFString) are independent.
3. **Phase 3 (Steps 3.1-3.6):** High severity. Steps 3.1-3.2 are CFRunLoop (do together). Steps 3.3-3.4 are independent. Steps 3.5-3.6 are NSCFDictionary (do together).
4. **Phase 4 (Steps 4.1-4.10):** Medium severity. All independent, can parallelize.

## Parallelization Groups

Workers can be assigned by file to avoid conflicts:

| Worker | Files | Steps |
|--------|-------|-------|
| A | CFSocket.c | 1.1, 1.2, 1.3, 2.3, 3.3, 4.1, 4.10 (partial) |
| B | CFRunLoop.c | 1.5, 2.1, 2.2, 3.1, 3.2 |
| C | CFString.c, NSCFString.m | 1.6, 2.4, 3.4, 4.2, 4.9 |
| D | GSPrivate.h, GSHashTable.c | 1.4, 4.1 (macros), 4.3, 4.4, 4.5 |
| E | CFPropertyList.c, NSCFDictionary.m, NSCFArray.m | 1.7, 3.5, 3.6, 4.6, 4.7, 4.8 |

## Build Verification

After each phase, verify the build:
```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-corebase
# In MSYS2 ucrt64 shell:
make clean && make
```

Run existing tests:
```bash
make check
```

## Risk Notes

- **Step 4.6 (recursion limit):** Changes function signature of `CFOpenStepPlistParseObject`. All call sites must be updated. Search for every call.
- **Step 4.7 (escape sequences):** New parsing logic for octal/unicode escapes. Needs thorough testing with edge cases (empty escape, truncated input, invalid hex chars).
- **Step 2.1 (atomic macros):** `__atomic_load_n` / `__atomic_store_n` require GCC 4.7+ or Clang 3.1+. The codebase already uses `__sync_*` builtins (GSPrivate.h line 96), so the compiler supports atomics.
- **Step 3.6 (fast enumeration):** The implementation still malloc's per batch. Acceptable for correctness; optimize later if profiling shows it matters.
