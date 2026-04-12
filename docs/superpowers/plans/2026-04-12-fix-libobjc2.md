# libobjc2 Audit Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans

**Goal:** Fix all 31 audit findings in libobjc2 (2 Critical, 8 High, 12 Medium, 9 Low)

**Architecture:** Fixes applied bottom-up: security/crashes first, then thread safety, then robustness, then performance. Each fix is one atomic commit.

**Tech Stack:** C, C++, Objective-C, x86-64/AArch64 assembly. Build: CMake. Test: Test/ directory.

---

## Phase 1: CRITICAL (Fix First)

### Task 1: RB-1 — Use-after-free in objc_exception_rethrow

**File:** `eh_personality.c` (lines 724-744)

**Problem:** `ex` is freed on line 738, then `ex->object` is accessed on line 741.

**Steps:**
- [ ] Open `eh_personality.c`
- [ ] In `objc_exception_rethrow`, save `ex->object` to a local variable before calling `free(ex)`
- [ ] Apply the following change:

**Current code (lines 730-743):**
```c
		struct objc_exception *ex = objc_exception_from_header(e);
		assert(e->exception_class == objc_exception_class);
		assert(ex == td->caughtExceptions);
		assert(ex->catch_count > 0);
		// Negate the catch count, so that we can detect that this is a
		// rethrown exception in objc_end_catch
		ex->catch_count = -ex->catch_count;
		_Unwind_Reason_Code err = _Unwind_Resume_or_Rethrow(e);
		free(ex);
		if (_URC_END_OF_STACK == err && 0 != _objc_unexpected_exception)
		{
			_objc_unexpected_exception(ex->object);
		}
		abort();
```

**Fixed code:**
```c
		struct objc_exception *ex = objc_exception_from_header(e);
		assert(e->exception_class == objc_exception_class);
		assert(ex == td->caughtExceptions);
		assert(ex->catch_count > 0);
		// Negate the catch count, so that we can detect that this is a
		// rethrown exception in objc_end_catch
		ex->catch_count = -ex->catch_count;
		id thrown_object = ex->object;
		_Unwind_Reason_Code err = _Unwind_Resume_or_Rethrow(e);
		free(ex);
		if (_URC_END_OF_STACK == err && 0 != _objc_unexpected_exception)
		{
			_objc_unexpected_exception(thrown_object);
		}
		abort();
```

- [ ] Test: `cd libobjc2 && mkdir -p build && cd build && cmake .. -DTESTS=ON && cmake --build . && ctest -R ExceptionTest`
- [ ] Commit: `git add eh_personality.c && git commit -m "fix(RB-1): save ex->object before free to prevent use-after-free in objc_exception_rethrow"`

---

### Task 2: RB-2 — NULL selector dereference in objc_msg_lookup_internal

**File:** `sendmsg2.c` (line 105)

**Problem:** `selector->index` is accessed without checking if `selector` is NULL. A message send with a nil selector will crash.

**Steps:**
- [ ] Open `sendmsg2.c`
- [ ] Add a NULL check for `selector` before accessing `selector->index` at line 105

**Current code (lines 92-106):**
```c
struct objc_slot2 *objc_msg_lookup_internal(id *receiver, SEL selector, uint64_t *version)
{
	if (version)
	{
#ifdef NO_SAFE_CACHING
		// Always write 0 to version, marking the slot as uncacheable.
		*version = 0;
#else
		*version = objc_method_cache_version;
#endif
	}
	Class class = classForObject((*receiver));
retry:;
	struct objc_slot2 * result = objc_dtable_lookup(class->dtable, selector->index);
```

**Fixed code:**
```c
struct objc_slot2 *objc_msg_lookup_internal(id *receiver, SEL selector, uint64_t *version)
{
	if (version)
	{
#ifdef NO_SAFE_CACHING
		// Always write 0 to version, marking the slot as uncacheable.
		*version = 0;
#else
		*version = objc_method_cache_version;
#endif
	}
	if (UNLIKELY(selector == NULL))
	{
		return NULL;
	}
	Class class = classForObject((*receiver));
retry:;
	struct objc_slot2 * result = objc_dtable_lookup(class->dtable, selector->index);
```

- [ ] Test: `cd build && cmake --build . && ctest -R msgSend`
- [ ] Commit: `git add sendmsg2.c && git commit -m "fix(RB-2): add NULL selector guard in objc_msg_lookup_internal to prevent dereference crash"`

---

## Phase 2: HIGH Priority

### Task 3: TS-1 — Priority inversion in spinlock.h (sleep(0) spin-wait)

**File:** `spinlock.h` (lines 66-80)

**Problem:** `lock_spinlock()` calls `sleep(0)` after 10 failed CAS attempts. On Windows, `Sleep(0)` can cause priority inversion. Should use adaptive spinning followed by OS yield.

**Steps:**
- [ ] Open `spinlock.h`
- [ ] Replace `sleep(0)` spin loop with adaptive spinning using `_mm_pause()` / `__yield()` for short spins, and `SleepEx(0, FALSE)` on Windows / `sched_yield()` on POSIX for long spins

**Current code (lines 66-80):**
```c
inline static void lock_spinlock(volatile int *spinlock)
{
	int count = 0;
	// Set the spin lock value to 1 if it is 0.
	while(!__sync_bool_compare_and_swap(spinlock, 0, 1))
	{
		count++;
		if (0 == count % 10)
		{
			// If it is already 1, let another thread play with the CPU for a
			// bit then try again.
			sleep(0);
		}
	}
}
```

**Fixed code:**
```c
inline static void lock_spinlock(volatile int *spinlock)
{
	int count = 0;
	// Set the spin lock value to 1 if it is 0.
	while(!__sync_bool_compare_and_swap(spinlock, 0, 1))
	{
		count++;
		if (count < 40)
		{
			// Short spin: use CPU pause instruction to reduce contention
			// and power consumption without yielding the thread.
#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
			__builtin_ia32_pause();
#elif defined(__aarch64__) || defined(_M_ARM64)
			__asm__ volatile("yield");
#endif
		}
		else
		{
			// Adaptive backoff: yield to OS scheduler to avoid priority
			// inversion and wasted cycles under contention.
#ifdef _WIN32
			SleepEx(0, FALSE);
#else
			sched_yield();
#endif
			// Reset count to allow another burst of spinning before
			// the next yield, but keep it above the spin threshold.
			count = 30;
		}
	}
}
```

- [ ] Add `#include <sched.h>` for non-Windows in the `#else` block at top of file (after the existing `#include <unistd.h>`)
- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add spinlock.h && git commit -m "fix(TS-1): replace sleep(0) spinlock with adaptive spinning to prevent priority inversion"`

---

### Task 4: TS-2 — TOCTOU race in objc_register_selector

**File:** `selector_table.cc` (lines 434-453)

**Problem:** `objc_register_selector` calls `isSelRegistered(aSel)` outside the lock (line 436), then calls `selector_lookup` which acquires/releases its own lock (line 442), then acquires the lock again to register (line 450). Between these unlocked windows, another thread can register the same selector.

**Steps:**
- [ ] Open `selector_table.cc`
- [ ] Restructure `objc_register_selector` to hold the lock for the entire check-and-register sequence

**Current code (lines 434-453):**
```cpp
extern "C" PRIVATE SEL objc_register_selector(SEL aSel)
{
	if (isSelRegistered(aSel))
	{
		return aSel;
	}
	UnregisteredSelector unregistered{aSel->name, aSel->types};
	// Check that this isn't already registered, before we try
	SEL registered = selector_lookup(aSel->name, aSel->types);
	SelectorEqual eq;
	if (nullptr != registered && eq(unregistered, registered))
	{
		aSel->name = registered->name;
		return registered;
	}
	assert(!(aSel->types && (strstr(aSel->types, "@\"") != nullptr)));
	LockGuard g{selector_table_lock};
	register_selector_locked(aSel);
	return aSel;
}
```

**Fixed code:**
```cpp
extern "C" PRIVATE SEL objc_register_selector(SEL aSel)
{
	if (isSelRegistered(aSel))
	{
		return aSel;
	}
	LockGuard g{selector_table_lock};
	// Re-check under lock to avoid TOCTOU race
	if (aSel->index < selector_list->size())
	{
		return aSel;
	}
	UnregisteredSelector unregistered{aSel->name, aSel->types};
	// Check that this isn't already registered (lookup under existing lock)
	auto result = selector_table->find(unregistered);
	SEL registered = (result == selector_table->end()) ? nullptr : *result;
	SelectorEqual eq;
	if (nullptr != registered && eq(unregistered, registered))
	{
		aSel->name = registered->name;
		return registered;
	}
	assert(!(aSel->types && (strstr(aSel->types, "@\"") != nullptr)));
	register_selector_locked(aSel);
	return aSel;
}
```

- [ ] Test: `cd build && cmake --build . && ctest -R selector`
- [ ] Commit: `git add selector_table.cc && git commit -m "fix(TS-2): hold lock for entire check-and-register in objc_register_selector to prevent TOCTOU race"`

---

### Task 5: TS-3 — isSelRegistered reads selector_list without lock

**File:** `selector_table.cc` (lines 121-128)

**Problem:** `isSelRegistered` reads `selector_list->size()` without acquiring `selector_table_lock`. If `selector_list` is being resized concurrently, this is a data race.

**Steps:**
- [ ] Open `selector_table.cc`
- [ ] Add lock acquisition in `isSelRegistered`

**Current code (lines 121-128):**
```cpp
BOOL isSelRegistered(SEL sel)
{
	if (sel->index < selector_list->size())
	{
		return YES;
	}
	return NO;
}
```

**Fixed code:**
```cpp
BOOL isSelRegistered(SEL sel)
{
	LockGuard g{selector_table_lock};
	if (sel->index < selector_list->size())
	{
		return YES;
	}
	return NO;
}
```

- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add selector_table.cc && git commit -m "fix(TS-3): acquire selector_table_lock in isSelRegistered to prevent data race on selector_list"`

---

### Task 6: TS-4 — class_table lockless reads during hash table resize

**File:** `class_table.c`, `hash_table.h`

**Problem:** The hopscotch hash table used for class lookups (`class_table_internal_table_get`) does not use locks for read operations. If a resize happens concurrently, readers may see a partially initialized table.

**Steps:**
- [ ] Open `hash_table.h`
- [ ] Identify the `_table_get` function template and the resize function
- [ ] Add `__atomic_thread_fence(__ATOMIC_ACQUIRE)` before reading the table pointer in `_table_get`
- [ ] Add `__atomic_thread_fence(__ATOMIC_RELEASE)` after updating the table pointer in the resize function
- [ ] Alternatively, use `__atomic_load_n` / `__atomic_store_n` for the table pointer in get/resize

**Specific change:** In the generated `_table_get` function (from hash_table.h macro expansion), ensure the table data pointer is read with acquire semantics:

Add to `hash_table.h`, in the `MAP_TABLE_NAME##_table_get` function, before accessing the table cells:
```c
__atomic_thread_fence(__ATOMIC_ACQUIRE);
```

And in the `MAP_TABLE_NAME##_table_resize` function, after swapping the table pointer:
```c
__atomic_thread_fence(__ATOMIC_RELEASE);
```

- [ ] Read the full `hash_table.h` to find the exact insertion points for fences
- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add hash_table.h && git commit -m "fix(TS-4): add memory barriers to hash_table.h to prevent torn reads during resize"`

---

### Task 7: TS-5 — Complex 3-lock ordering in objc_send_initialize

**File:** `dtable.c` (lines 722-855)

**Problem:** `objc_send_initialize` acquires 3 locks in a complex sequence: runtime_mutex, LOCK_OBJECT (class-specific), and initialize_lock. The lock ordering is subtle and undocumented, which risks deadlock under unusual class hierarchies.

**Steps:**
- [ ] Open `dtable.c`
- [ ] Add block comments documenting the required lock ordering at lines 718-721 and at each lock acquisition
- [ ] Add assertions where possible to verify correct ordering

**Add before `objc_send_initialize` (before line 721):**
```c
/**
 * Lock ordering for objc_send_initialize:
 *
 *   1. LOCK_OBJECT(meta)     — per-class lock (outermost)
 *   2. runtime_mutex          — global runtime lock
 *   3. initialize_lock        — dtable initialization lock (innermost)
 *
 * IMPORTANT: runtime_mutex must NEVER be acquired while holding
 * initialize_lock. The sequence is:
 *   - Acquire LOCK_OBJECT(meta) to serialize +initialize per-class
 *   - Acquire runtime_mutex for class resolution and dtable creation
 *   - Acquire initialize_lock to update temporary dtable lists
 *   - Release runtime_mutex before running +initialize user code
 *   - Release initialize_lock after dtable setup
 *   - LOCK_OBJECT(meta) released by LOCK_OBJECT_FOR_SCOPE cleanup
 */
```

- [ ] Test: `cd build && cmake --build . && ctest -R Initialize`
- [ ] Commit: `git add dtable.c && git commit -m "fix(TS-5): document 3-lock ordering in objc_send_initialize to prevent future deadlocks"`

---

### Task 8: RB-3 — Type qualifier skip result discarded in objc_msg_lookup_sender

**File:** `sendmsg2.c` (lines 186-193)

**Problem:** The code advances `t` past type qualifiers in lines 187-191, but then line 192 switches on `selector->types[0]` instead of `*t`. The qualifier-skipping is dead code.

**Steps:**
- [ ] Open `sendmsg2.c`
- [ ] Change `selector->types[0]` to `*t` on line 192

**Current code (lines 185-198):**
```c
			const char *t = selector->types;
			// Skip type qualifiers
			while ('r' == *t || 'n' == *t || 'N' == *t || 'o' == *t ||
			       'O' == *t || 'R' == *t || 'V' == *t || 'A' == *t)
			{
				t++;
			}
			switch (selector->types[0])
			{
				case 'D': return &nil_slot_D_v1;
				case 'd': return &nil_slot_d_v1;
				case 'f': return &nil_slot_f_v1;
			}
```

**Fixed code:**
```c
			const char *t = selector->types;
			// Skip type qualifiers
			while ('r' == *t || 'n' == *t || 'N' == *t || 'o' == *t ||
			       'O' == *t || 'R' == *t || 'V' == *t || 'A' == *t)
			{
				t++;
			}
			switch (*t)
			{
				case 'D': return &nil_slot_D_v1;
				case 'd': return &nil_slot_d_v1;
				case 'f': return &nil_slot_f_v1;
			}
```

- [ ] Test: `cd build && cmake --build . && ctest -R msgSend`
- [ ] Commit: `git add sendmsg2.c && git commit -m "fix(RB-3): use qualifier-skipped type pointer in nil return switch instead of raw selector->types[0]"`

---

### Task 9: RB-4 — objc_storeStrong NULL-dereferences addr

**File:** `arc.mm` (line 640-647)

**Problem:** `objc_storeStrong` dereferences `addr` (line 643: `id oldValue = *addr`) without checking if `addr` is NULL.

**Steps:**
- [ ] Open `arc.mm`
- [ ] Add a NULL guard for `addr` at the top of `objc_storeStrong`

**Current code (lines 640-647):**
```cpp
extern "C" OBJC_PUBLIC id objc_storeStrong(id *addr, id value)
{
	value = objc_retain(value);
	id oldValue = *addr;
	*addr = value;
	objc_release(oldValue);
	return value;
}
```

**Fixed code:**
```cpp
extern "C" OBJC_PUBLIC id objc_storeStrong(id *addr, id value)
{
	if (NULL == addr) { return nil; }
	value = objc_retain(value);
	id oldValue = *addr;
	*addr = value;
	objc_release(oldValue);
	return value;
}
```

- [ ] Test: `cd build && cmake --build . && ctest -R ARC`
- [ ] Commit: `git add arc.mm && git commit -m "fix(RB-4): add NULL guard for addr parameter in objc_storeStrong"`

---

### Task 10: RB-6 — Wrong variable checked after strdup in selector_table.cc

**File:** `selector_table.cc` (line 498-499)

**Problem:** After `copy->types = strdup(copy->types)`, line 498 checks `copy->name == nullptr` instead of `copy->types == nullptr`. This means a failed allocation of `copy->types` goes undetected.

**Steps:**
- [ ] Open `selector_table.cc`
- [ ] Change `copy->name` to `copy->types` on line 498

**Current code (lines 495-503):**
```cpp
		if (copy->types != nullptr)
		{
			copy->types = strdup(copy->types);
			if (copy->name == nullptr)
			{
				fprintf(stderr, "Failed to allocate memory for selector %s\n", aSel.name);
				abort();
			}
			selector_name_copies += strlen(copy->types);
		}
```

**Fixed code:**
```cpp
		if (copy->types != nullptr)
		{
			copy->types = strdup(copy->types);
			if (copy->types == nullptr)
			{
				fprintf(stderr, "Failed to allocate memory for selector type %s\n", aSel.name);
				abort();
			}
			selector_name_copies += strlen(copy->types);
		}
```

- [ ] Test: `cd build && cmake --build . && ctest -R selector`
- [ ] Commit: `git add selector_table.cc && git commit -m "fix(RB-6): check copy->types instead of copy->name after strdup of types in objc_register_selector_copy"`

---

### Task 11: RB-7 — NULL check after dereference in protocol.c

**File:** `protocol.c` (lines 346-353)

**Problem:** Line 349-352 dereferences `p` (via `p->properties`, `p->optional_properties`, etc.), but the NULL check for `p` is on line 353 — after the dereference.

**Steps:**
- [ ] Open `protocol.c`
- [ ] Move the `NULL == p` check before the dereference

**Current code (lines 346-353):**
```c
objc_property_t *protocol_copyPropertyList2(Protocol *p, unsigned int *outCount,
		BOOL isRequiredProperty, BOOL isInstanceProperty)
{
	struct objc_property_list *properties =
	    isInstanceProperty ?
	        (isRequiredProperty ? p->properties : p->optional_properties) :
	        (isRequiredProperty ? p->class_properties : p->optional_class_properties);
	if (NULL == p) { return NULL; }
```

**Fixed code:**
```c
objc_property_t *protocol_copyPropertyList2(Protocol *p, unsigned int *outCount,
		BOOL isRequiredProperty, BOOL isInstanceProperty)
{
	if (NULL == p)
	{
		if (NULL != outCount) { *outCount = 0; }
		return NULL;
	}
	struct objc_property_list *properties =
	    isInstanceProperty ?
	        (isRequiredProperty ? p->properties : p->optional_properties) :
	        (isRequiredProperty ? p->class_properties : p->optional_class_properties);
```

- [ ] Test: `cd build && cmake --build . && ctest -R Protocol`
- [ ] Commit: `git add protocol.c && git commit -m "fix(RB-7): move NULL check before dereference in protocol_copyPropertyList2"`

---

### Task 12: RB-9 — Weak C++ symbols called without NULL checks

**File:** `eh_personality.c` (lines 44-50)

**Problem:** `__cxa_begin_catch`, `__cxa_end_catch`, `__cxa_rethrow`, `__cxa_get_globals` are declared as weak symbols. The comment on lines 44-46 says "We don't bother testing that these are 0 before calling them" — but if no C++ runtime is linked, calling these will crash.

**Steps:**
- [ ] Open `eh_personality.c`
- [ ] Find all call sites for these weak symbols and add NULL guards
- [ ] Focus on `__cxa_begin_catch` and `__cxa_end_catch` calls which are the most reachable without C++ exceptions in flight

**Current code (lines 44-50):**
```c
// Weak references to C++ runtime functions.  We don't bother testing that
// these are 0 before calling them, because if they are not resolved then we
// should not be in a code path that involves a C++ exception.
__attribute__((weak)) void *__cxa_begin_catch(void *e);
__attribute__((weak)) void __cxa_end_catch(void);
__attribute__((weak)) void __cxa_rethrow(void);
__attribute__((weak)) struct __cxa_eh_globals *__cxa_get_globals(void);
```

**Fix — update the comment and add a guard macro:**

After line 50, add:
```c
/**
 * Safe call wrappers for weak C++ exception symbols. If the C++ runtime
 * is not linked, these become no-ops / return NULL instead of crashing.
 */
static inline void *safe_cxa_begin_catch(void *e)
{
	if (__cxa_begin_catch)
		return __cxa_begin_catch(e);
	return NULL;
}
static inline void safe_cxa_end_catch(void)
{
	if (__cxa_end_catch)
		__cxa_end_catch();
}
static inline void safe_cxa_rethrow(void)
{
	if (__cxa_rethrow)
		__cxa_rethrow();
}
static inline struct __cxa_eh_globals *safe_cxa_get_globals(void)
{
	if (__cxa_get_globals)
		return __cxa_get_globals();
	return NULL;
}
```

- [ ] Then replace all call sites: `__cxa_begin_catch(` -> `safe_cxa_begin_catch(`, etc.
- [ ] Update the original comment to note the guards exist
- [ ] Test: `cd build && cmake --build . && ctest -R Exception`
- [ ] Commit: `git add eh_personality.c && git commit -m "fix(RB-9): add NULL guards for weak C++ exception symbols to prevent crash without C++ runtime"`

---

## Phase 3: MEDIUM Priority

### Task 13: TS-7 — Property spinlock deadlock when lock==lock2

**File:** `properties.m` (lines 127-137)

**Problem:** In `objc_copyCppObjectAtomic`, `lock` and `lock2` are computed from different pointers. If the hash collides (lock == lock2), `lock_spinlock(lock2)` deadlocks because the spinlock is non-reentrant.

**Steps:**
- [ ] Open `properties.m`
- [ ] Add a check: if `lock == lock2`, only acquire once

**Current code (lines 126-137):**
```c
OBJC_PUBLIC
void objc_copyCppObjectAtomic(void *dest, const void *src,
                              void (*copyHelper) (void *dest, const void *source))
{
	volatile int *lock = lock_for_pointer(src < dest ? src : dest);
	volatile int *lock2 = lock_for_pointer(src < dest ? dest : src);
	lock_spinlock(lock);
	lock_spinlock(lock2);
	copyHelper(dest, src);
	unlock_spinlock(lock);
	unlock_spinlock(lock2);
}
```

**Fixed code:**
```c
OBJC_PUBLIC
void objc_copyCppObjectAtomic(void *dest, const void *src,
                              void (*copyHelper) (void *dest, const void *source))
{
	volatile int *lock = lock_for_pointer(src < dest ? src : dest);
	volatile int *lock2 = lock_for_pointer(src < dest ? dest : src);
	lock_spinlock(lock);
	if (lock != lock2)
	{
		lock_spinlock(lock2);
	}
	copyHelper(dest, src);
	if (lock != lock2)
	{
		unlock_spinlock(lock2);
	}
	unlock_spinlock(lock);
}
```

- [ ] Apply the same fix to `objc_copyPropertyStruct` (lines 167-187) which has the same pattern:

**Current code (lines 173-181):**
```c
	if (atomic)
	{
		volatile int *lock = lock_for_pointer(src < dest ? src : dest);
		volatile int *lock2 = lock_for_pointer(src < dest ? dest : src);
		lock_spinlock(lock);
		lock_spinlock(lock2);
		memcpy(dest, src, size);
		unlock_spinlock(lock);
		unlock_spinlock(lock2);
	}
```

**Fixed code:**
```c
	if (atomic)
	{
		volatile int *lock = lock_for_pointer(src < dest ? src : dest);
		volatile int *lock2 = lock_for_pointer(src < dest ? dest : src);
		lock_spinlock(lock);
		if (lock != lock2)
		{
			lock_spinlock(lock2);
		}
		memcpy(dest, src, size);
		if (lock != lock2)
		{
			unlock_spinlock(lock2);
		}
		unlock_spinlock(lock);
	}
```

- [ ] Test: `cd build && cmake --build . && ctest -R Property`
- [ ] Commit: `git add properties.m && git commit -m "fix(TS-7): prevent spinlock deadlock when lock==lock2 in objc_copyCppObjectAtomic and objc_copyPropertyStruct"`

---

### Task 14: TS-12 — initAutorelease race on statics

**File:** `arc.mm` (lines 404-429)

**Problem:** `initAutorelease()` checks `Nil == AutoreleasePool` without synchronization. Two threads calling this concurrently could both see `Nil` and both try to initialize the statics.

**Steps:**
- [ ] Open `arc.mm`
- [ ] Protect `initAutorelease` with a static atomic flag

**Current code (lines 404-429):**
```cpp
static inline void initAutorelease(void)
{
	if (Nil == AutoreleasePool)
	{
		AutoreleasePool = objc_getClass("NSAutoreleasePool");
		if (Nil == AutoreleasePool)
		{
			useARCAutoreleasePool = YES;
		}
		else
		{
			useARCAutoreleasePool = (0 != class_getInstanceMethod(AutoreleasePool,
			                                                      SELECTOR(_ARCCompatibleAutoreleasePool)));
			if (!useARCAutoreleasePool)
			{
				[AutoreleasePool class];
				NewAutoreleasePool = class_getMethodImplementation(object_getClass(AutoreleasePool),
				                                                   SELECTOR(new));
				DeleteAutoreleasePool = class_getMethodImplementation(AutoreleasePool,
				                                                      SELECTOR(release));
				AutoreleaseAdd = class_getMethodImplementation(object_getClass(AutoreleasePool),
				                                               SELECTOR(addObject:));
			}
		}
	}
}
```

**Fixed code:**
```cpp
static inline void initAutorelease(void)
{
	static int autorelease_initialized = 0;
	if (__atomic_load_n(&autorelease_initialized, __ATOMIC_ACQUIRE))
	{
		return;
	}
	// Use CAS to ensure only one thread performs initialization
	int expected = 0;
	if (!__atomic_compare_exchange_n(&autorelease_initialized, &expected, -1,
	                                  false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
	{
		// Another thread is initializing or has finished; spin until done
		while (__atomic_load_n(&autorelease_initialized, __ATOMIC_ACQUIRE) != 1) {}
		return;
	}
	AutoreleasePool = objc_getClass("NSAutoreleasePool");
	if (Nil == AutoreleasePool)
	{
		useARCAutoreleasePool = YES;
	}
	else
	{
		useARCAutoreleasePool = (0 != class_getInstanceMethod(AutoreleasePool,
		                                                      SELECTOR(_ARCCompatibleAutoreleasePool)));
		if (!useARCAutoreleasePool)
		{
			[AutoreleasePool class];
			NewAutoreleasePool = class_getMethodImplementation(object_getClass(AutoreleasePool),
			                                                   SELECTOR(new));
			DeleteAutoreleasePool = class_getMethodImplementation(AutoreleasePool,
			                                                      SELECTOR(release));
			AutoreleaseAdd = class_getMethodImplementation(object_getClass(AutoreleasePool),
			                                               SELECTOR(addObject:));
		}
	}
	__atomic_store_n(&autorelease_initialized, 1, __ATOMIC_RELEASE);
}
```

- [ ] Test: `cd build && cmake --build . && ctest -R ARC`
- [ ] Commit: `git add arc.mm && git commit -m "fix(TS-12): use atomic CAS to prevent race in initAutorelease static initialization"`

---

### Task 15: TS-14 — cleanupPools double-free risk

**File:** `arc.mm` (lines 212-229)

**Problem:** `cleanupPools` releases `tls->returnRetained`, sets it to nil, calls `emptyPool`, then checks `tls->returnRetained` again. If `emptyPool` causes a dealloc that sets `returnRetained` to a new value, the recursive call can double-free.

**Steps:**
- [ ] Open `arc.mm`
- [ ] Restructure to use a loop instead of recursion, and clear returnRetained atomically

**Current code (lines 212-229):**
```cpp
static TLS_CALLBACK(cleanupPools)(struct arc_tls* tls)
{
	if (tls->returnRetained)
	{
		release(tls->returnRetained);
		tls->returnRetained = nil;
	}
	if (NULL != tls->pool)
	{
		emptyPool(tls, NULL);
		assert(NULL == tls->pool);
	}
	if (tls->returnRetained)
	{
		cleanupPools(tls);
	}
	free(tls);
}
```

**Fixed code:**
```cpp
static TLS_CALLBACK(cleanupPools)(struct arc_tls* tls)
{
	// Loop to handle the case where emptyPool causes new objects to be
	// placed in returnRetained during deallocation.
	for (int iterations = 0; iterations < 16; iterations++)
	{
		if (tls->returnRetained)
		{
			id retained = tls->returnRetained;
			tls->returnRetained = nil;
			release(retained);
		}
		if (NULL != tls->pool)
		{
			emptyPool(tls, NULL);
			assert(NULL == tls->pool);
		}
		if (!tls->returnRetained)
		{
			break;
		}
	}
	// If we still have a retained object after max iterations, release it
	// to avoid a leak, but don't recurse further.
	if (tls->returnRetained)
	{
		release(tls->returnRetained);
		tls->returnRetained = nil;
	}
	free(tls);
}
```

- [ ] Test: `cd build && cmake --build . && ctest -R ARC`
- [ ] Commit: `git add arc.mm && git commit -m "fix(TS-14): replace recursive cleanupPools with bounded loop to prevent double-free and stack overflow"`

---

### Task 16: TS-15 — init_runtime() race on first_run

**File:** `loader.c` (lines 37-83)

**Problem:** `init_runtime()` uses a non-atomic `static BOOL first_run = YES` to gate one-time initialization. Two threads calling this concurrently from `dlopen` can both see `first_run == YES` and double-initialize.

**Steps:**
- [ ] Open `loader.c`
- [ ] Replace `first_run` with an atomic CAS

**Current code (lines 37-65):**
```c
static void init_runtime(void)
{
	static BOOL first_run = YES;
	if (first_run)
	{
		// ... initialization code ...
		first_run = NO;
```

**Fixed code:**
```c
static void init_runtime(void)
{
	static volatile int init_state = 0; // 0=not started, 1=in progress, 2=done
	// Fast path: already initialized
	if (__atomic_load_n(&init_state, __ATOMIC_ACQUIRE) == 2)
	{
		return;
	}
	// Try to claim the initialization
	int expected = 0;
	if (__atomic_compare_exchange_n(&init_state, &expected, 1,
	                                 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
	{
		// We won the race — do initialization
		INIT_LOCK(runtime_mutex);
		init_selector_tables();
		init_dispatch_tables();
		init_protocol_table();
		init_class_tables();
		init_alias_table();
		init_early_blocks();
		init_arc();
#if defined(EMBEDDED_BLOCKS_RUNTIME)
		init_trampolines();
#endif
		init_builtin_classes();
		if (getenv("LIBOBJC_MEMORY_PROFILE"))
		{
			atexit(log_memory_stats);
		}
		if (dispatch_begin_thread_4GC != 0) {
			dispatch_begin_thread_4GC = objc_registerThreadWithCollector;
		}
		if (dispatch_end_thread_4GC != 0) {
			dispatch_end_thread_4GC = objc_unregisterThreadWithCollector;
		}
		if (_dispatch_begin_NSAutoReleasePool != 0) {
			_dispatch_begin_NSAutoReleasePool = objc_autoreleasePoolPush;
		}
		if (_dispatch_end_NSAutoReleasePool != 0) {
			_dispatch_end_NSAutoReleasePool = objc_autoreleasePoolPop;
		}
		__atomic_store_n(&init_state, 2, __ATOMIC_RELEASE);
	}
	else
	{
		// Another thread is initializing; spin until done
		while (__atomic_load_n(&init_state, __ATOMIC_ACQUIRE) != 2) {}
	}
}
```

- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add loader.c && git commit -m "fix(TS-15): use atomic CAS for init_runtime to prevent double-initialization race"`

---

### Task 17: RB-5 — object_getRetainCount_np NULL dereference

**File:** `arc.mm` (line 253-258)

**Problem:** `object_getRetainCount_np` does not check for nil `obj` before computing `((uintptr_t*)obj) - 1`.

**Steps:**
- [ ] Open `arc.mm`
- [ ] Add nil check

**Current code (lines 253-258):**
```cpp
extern "C" OBJC_PUBLIC size_t object_getRetainCount_np(id obj)
{
	uintptr_t *refCount = ((uintptr_t*)obj) - 1;
	uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);
	size_t realCount = refCountVal & refcount_mask;
	return realCount == refcount_mask ? 0 : realCount + 1;
}
```

**Fixed code:**
```cpp
extern "C" OBJC_PUBLIC size_t object_getRetainCount_np(id obj)
{
	if (nil == obj) { return 0; }
	uintptr_t *refCount = ((uintptr_t*)obj) - 1;
	uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);
	size_t realCount = refCountVal & refcount_mask;
	return realCount == refcount_mask ? 0 : realCount + 1;
}
```

- [ ] Test: `cd build && cmake --build . && ctest -R ARC`
- [ ] Commit: `git add arc.mm && git commit -m "fix(RB-5): add nil check in object_getRetainCount_np to prevent NULL dereference"`

---

### Task 18: RB-8 — Super-send doesn't validate super->class

**File:** `sendmsg2.c` (lines 283-290)

**Problem:** `objc_slot_lookup_super2` accesses `super->class` (line 288) and calls `dtable_for_class(class)` (line 289) without checking if `super->class` is NULL.

**Steps:**
- [ ] Open `sendmsg2.c`
- [ ] Add NULL checks for `super->class`

**Current code (lines 283-290):**
```c
struct objc_slot2 *objc_slot_lookup_super2(struct objc_super *super, SEL selector)
{
	id receiver = super->receiver;
	if (receiver)
	{
		Class class = super->class;
		struct objc_slot2 * result = objc_dtable_lookup(dtable_for_class(class),
				selector->index);
```

**Fixed code:**
```c
struct objc_slot2 *objc_slot_lookup_super2(struct objc_super *super, SEL selector)
{
	id receiver = super->receiver;
	if (receiver)
	{
		Class class = super->class;
		if (UNLIKELY(Nil == class))
		{
			return NULL;
		}
		struct objc_slot2 * result = objc_dtable_lookup(dtable_for_class(class),
				selector->index);
```

- [ ] Test: `cd build && cmake --build . && ctest -R msgSend`
- [ ] Commit: `git add sendmsg2.c && git commit -m "fix(RB-8): validate super->class is non-NULL before dtable lookup in objc_slot_lookup_super2"`

---

### Task 19: RB-10 — Category method list visible before dtable updated

**File:** `category_loader.c` (lines 12-26)

**Problem:** In `register_methods`, the method list is linked into `cls->methods` (line 17-18) before `add_method_list_to_class` updates the dtable (line 24). Another thread iterating `cls->methods` could see the new list, call through it, and hit a stale dtable that doesn't contain the new methods yet.

**Steps:**
- [ ] Open `category_loader.c`
- [ ] Add a write memory barrier after `add_method_list_to_class` and document the race window

**Current code (lines 12-26):**
```c
static void register_methods(struct objc_class *cls, struct objc_method_list *l)
{
	if (NULL == l) { return; }

	// Add the method list at the head of the list of lists.
	l->next = cls->methods;
	cls->methods = l;
	// Update the dtable to catch the new methods, if the dtable has been
	// created (don't bother creating dtables for classes when categories are
	// loaded if the class hasn't received any messages yet.
	if (classHasDtable(cls))
	{
		add_method_list_to_class(cls, l);
	}
}
```

**Fixed code:**
```c
static void register_methods(struct objc_class *cls, struct objc_method_list *l)
{
	if (NULL == l) { return; }

	// Update the dtable first so the methods are callable before the method
	// list is visible to other threads walking cls->methods.
	if (classHasDtable(cls))
	{
		add_method_list_to_class(cls, l);
	}
	// Ensure dtable update is visible before linking the method list.
	__atomic_thread_fence(__ATOMIC_RELEASE);
	// Add the method list at the head of the list of lists.
	l->next = cls->methods;
	cls->methods = l;
}
```

- [ ] Test: `cd build && cmake --build . && ctest -R Category`
- [ ] Commit: `git add category_loader.c && git commit -m "fix(RB-10): reorder dtable update before method list link and add memory barrier in category loading"`

---

### Task 20: RB-14 — objc_retainAutoreleasedReturnValue reads before pool array

**File:** `arc.mm` (lines 595-596)

**Problem:** `tls->pool->insert-1` is used without verifying `tls->pool->insert > tls->pool->pool` (i.e., the pool is non-empty). If the pool is empty, this reads before the start of the array.

**Steps:**
- [ ] Open `arc.mm`
- [ ] Add bounds check

**Current code (lines 593-599):**
```cpp
		if (useARCAutoreleasePool)
		{
			if ((NULL != tls->pool) &&
			    (*(tls->pool->insert-1) == obj))
			{
				tls->pool->insert--;
				return obj;
```

**Fixed code:**
```cpp
		if (useARCAutoreleasePool)
		{
			if ((NULL != tls->pool) &&
			    (tls->pool->insert > tls->pool->pool) &&
			    (*(tls->pool->insert-1) == obj))
			{
				tls->pool->insert--;
				return obj;
```

- [ ] Test: `cd build && cmake --build . && ctest -R ARC`
- [ ] Commit: `git add arc.mm && git commit -m "fix(RB-14): add bounds check before reading tls->pool->insert-1 in objc_retainAutoreleasedReturnValue"`

---

### Task 21: RB-15 — objc_setProperty_atomic missing nil obj check

**File:** `properties.m` (lines 76-88)

**Problem:** `objc_setProperty_atomic` does not check for nil `obj`. A nil `obj` would cause `(char*)obj + offset` to compute a wild pointer, leading to a crash on dereference.

**Steps:**
- [ ] Open `properties.m`
- [ ] Add nil check at the top of `objc_setProperty_atomic` and `objc_setProperty_atomic_copy`

**Current code (lines 76-88):**
```c
OBJC_PUBLIC
void objc_setProperty_atomic(id obj, SEL _cmd, id arg, ptrdiff_t offset)
{
	char *addr = (char*)obj;
	addr += offset;
	arg = objc_retain(arg);
```

**Fixed code:**
```c
OBJC_PUBLIC
void objc_setProperty_atomic(id obj, SEL _cmd, id arg, ptrdiff_t offset)
{
	if (nil == obj) { return; }
	char *addr = (char*)obj;
	addr += offset;
	arg = objc_retain(arg);
```

**Also fix `objc_setProperty_atomic_copy` (lines 90-103):**

**Current:**
```c
void objc_setProperty_atomic_copy(id obj, SEL _cmd, id arg, ptrdiff_t offset)
{
	char *addr = (char*)obj;
```

**Fixed:**
```c
void objc_setProperty_atomic_copy(id obj, SEL _cmd, id arg, ptrdiff_t offset)
{
	if (nil == obj) { return; }
	char *addr = (char*)obj;
```

**Also fix `objc_setProperty_nonatomic` (line 106) and `objc_setProperty_nonatomic_copy` (line 117) for completeness:**

Add `if (nil == obj) { return; }` as the first line in each.

- [ ] Test: `cd build && cmake --build . && ctest -R Property`
- [ ] Commit: `git add properties.m && git commit -m "fix(RB-15): add nil obj checks to all objc_setProperty variants to prevent NULL dereference"`

---

### Task 22: RB-11 — abort() without diagnostic information

**Files:** Various (any `abort()` call without a preceding fprintf)

**Steps:**
- [ ] Grep for `abort()` calls without a preceding diagnostic message
- [ ] Add `fprintf(stderr, ...)` before bare `abort()` calls in critical paths (e.g., `eh_personality.c:743`, `sendmsg2.c`)
- [ ] This is a quality improvement, not a crash fix

**Example fix in `eh_personality.c` line 743:**

**Current:**
```c
		abort();
```

**Fixed:**
```c
		fprintf(stderr, "objc_exception_rethrow: unhandled exception reached end of stack\n");
		abort();
```

- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add -A && git commit -m "fix(RB-11): add diagnostic messages before abort() calls for better crash debugging"`

---

### Task 23: RB-12 — objc_exception_cleanup is a no-op

**File:** `eh_personality.c`

**Steps:**
- [ ] Find the `objc_exception_cleanup` function
- [ ] Verify whether the no-op is intentional (it typically is — cleanup happens elsewhere in the exception lifecycle)
- [ ] Add a comment documenting why the function is intentionally a no-op
- [ ] Test: `cd build && cmake --build . && ctest -R Exception`
- [ ] Commit: `git add eh_personality.c && git commit -m "docs(RB-12): document why objc_exception_cleanup is intentionally a no-op"`

---

### Task 24: RB-13 — MSVC interop: struct layout may differ

**Steps:**
- [ ] Review `objc_exception` struct layout with `#pragma pack` or static_assert for size
- [ ] Add `static_assert(sizeof(struct objc_exception) == EXPECTED_SIZE)` or document that MSVC is not supported for this structure
- [ ] This is a documentation/assertion task; no behavioral change
- [ ] Commit: `git add eh_personality.c && git commit -m "docs(RB-13): add static_assert for objc_exception struct layout for MSVC interop safety"`

---

## Phase 4: LOW Priority (Performance)

### Task 25: PF-7 — __sync_fetch_and_add(x,0) as atomic load

**File:** `arc.mm` (lines 256, 264, 341)

**Problem:** `__sync_fetch_and_add(refCount, 0)` is used to atomically read the reference count. This performs an unnecessary read-modify-write with a bus lock. `__atomic_load_n` is cheaper.

**Steps:**
- [ ] Open `arc.mm`
- [ ] Replace all instances of `__sync_fetch_and_add(refCount, 0)` with `__atomic_load_n(refCount, __ATOMIC_SEQ_CST)`

**Line 256 (object_getRetainCount_np):**
```cpp
// Before:
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);
// After:
uintptr_t refCountVal = __atomic_load_n(refCount, __ATOMIC_SEQ_CST);
```

**Line 264 (retain_fast):**
```cpp
// Before:
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);
// After:
uintptr_t refCountVal = __atomic_load_n(refCount, __ATOMIC_SEQ_CST);
```

**Line 341 (objc_release_fast_no_destroy_np):**
```cpp
// Before:
uintptr_t refCountVal = __sync_fetch_and_add(refCount, 0);
// After:
uintptr_t refCountVal = __atomic_load_n(refCount, __ATOMIC_SEQ_CST);
```

- [ ] Test: `cd build && cmake --build . && ctest -R ARC`
- [ ] Commit: `git add arc.mm && git commit -m "perf(PF-7): replace __sync_fetch_and_add(x,0) with __atomic_load_n for atomic reads in ARC refcounting"`

---

### Task 26: PF-5 — objc_method_cache_version lacks cache line alignment

**File:** `dtable.c` (line 47)

**Problem:** `objc_method_cache_version` is not aligned to a cache line boundary, causing false sharing with adjacent variables.

**Steps:**
- [ ] Open `dtable.c`
- [ ] Add `__attribute__((aligned(64)))` to the declaration

**Current code (line 47):**
```c
_Atomic(uint64_t) objc_method_cache_version;
```

**Fixed code:**
```c
_Atomic(uint64_t) objc_method_cache_version __attribute__((aligned(64)));
```

- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add dtable.c && git commit -m "perf(PF-5): align objc_method_cache_version to 64-byte cache line to prevent false sharing"`

---

### Task 27: PF-11 — selector_list pre-allocated 65536 entries

**File:** `selector_table.cc` (line 365)

**Problem:** `init_selector_tables()` allocates `1<<16` (65536) TypeList entries upfront. Most programs use far fewer selectors at startup. Start with 1024 and let it grow dynamically.

**Steps:**
- [ ] Open `selector_table.cc`
- [ ] Change the initial allocation

**Current code (line 365):**
```cpp
	selector_list = new std::vector<TypeList>(1<<16);
```

**Fixed code:**
```cpp
	selector_list = new std::vector<TypeList>();
	selector_list->reserve(1024);
```

Note: Changed from constructing with size (which creates 65536 default-constructed elements) to reserve (which only allocates capacity without constructing elements). The `add_selector_to_table` function already calls `push_back` to add elements.

- [ ] Verify that all code accessing `selector_list` uses `size()` not `capacity()` for bounds checks (**confirmed**: `isSelRegistered` uses `size()`, `selLookup_locked` uses `size()`)
- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add selector_table.cc && git commit -m "perf(PF-11): reduce selector_list initial allocation from 65536 to 1024 reserve"`

---

### Task 28: PF-1 — dtable sparse array could use larger fanout

**File:** `dtable.c`

**Steps:**
- [ ] Review the sparse array shift value (`dtable_depth = 8`) and consider whether 16 would reduce lookup depth
- [ ] Profile before changing; this may not matter for typical selector counts
- [ ] If beneficial, change `dtable_depth` default
- [ ] Test: `cd build && cmake --build . && ctest`
- [ ] Commit: `git add dtable.c && git commit -m "perf(PF-1): evaluate dtable sparse array fanout for reduced lookup depth"`

---

### Task 29: PF-2 — Thread-local storage access overhead in ARC

**File:** `arc.mm`

**Steps:**
- [ ] Review `getARCThreadData()` and TLS access patterns
- [ ] Consider caching TLS pointer across multiple ARC calls in hot paths
- [ ] This is a micro-optimization; profile first
- [ ] Commit: `git add arc.mm && git commit -m "perf(PF-2): cache TLS pointer in ARC hot paths to reduce repeated TLS lookups"`

---

### Task 30: PF-3 — Autorelease pool linked list traversal

**File:** `arc.mm`

**Steps:**
- [ ] Review `emptyPool` loop and pool allocation
- [ ] Consider using a larger pool page size to reduce linked list traversal
- [ ] Profile before changing
- [ ] Commit: `git add arc.mm && git commit -m "perf(PF-3): optimize autorelease pool page size to reduce linked list traversal"`

---

### Task 31: PF-4 — selector_types_equal character-by-character comparison

**File:** `selector_table.cc`

**Steps:**
- [ ] Review `selector_types_equal` for possible fast-path optimization (pointer equality check already exists at top)
- [ ] Consider adding a length check before character comparison
- [ ] Profile before changing; this is a micro-optimization
- [ ] Commit: `git add selector_table.cc && git commit -m "perf(PF-4): add fast-path length check to selector_types_equal"`

---

## Build & Test Instructions

### Full build from scratch (MSYS2 ucrt64):
```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libobjc2
mkdir -p build && cd build
cmake .. -G "Ninja" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DTESTS=ON
cmake --build .
ctest --output-on-failure
```

### Running specific test suites:
```bash
ctest -R ExceptionTest    # Exception handling (RB-1, RB-9, RB-12)
ctest -R msgSend          # Message dispatch (RB-2, RB-3, RB-8)
ctest -R ARC              # ARC/refcounting (RB-4, RB-5, RB-14, TS-12, TS-14, PF-7)
ctest -R selector         # Selector table (TS-2, TS-3, RB-6, PF-11)
ctest -R Property         # Properties (TS-7, RB-15)
ctest -R Category         # Categories (RB-10)
ctest -R Protocol         # Protocols (RB-7)
```

### Validating thread safety fixes:
Thread safety fixes (TS-1 through TS-15) are difficult to test deterministically. Consider:
1. Running the full test suite under ThreadSanitizer: `cmake .. -DCMAKE_C_FLAGS="-fsanitize=thread" -DCMAKE_CXX_FLAGS="-fsanitize=thread"`
2. Stress-testing with concurrent class loading and message sends
3. Code review verification of lock ordering and atomics

---

## Execution Order Summary

| Order | ID(s) | Priority | Files | Type |
|-------|--------|----------|-------|------|
| 1 | RB-1 | CRITICAL | eh_personality.c | Use-after-free |
| 2 | RB-2 | CRITICAL | sendmsg2.c | NULL deref |
| 3 | TS-1 | HIGH | spinlock.h | Priority inversion |
| 4 | TS-2 | HIGH | selector_table.cc | TOCTOU race |
| 5 | TS-3 | HIGH | selector_table.cc | Data race |
| 6 | TS-4 | HIGH | hash_table.h | Data race |
| 7 | TS-5 | HIGH | dtable.c | Lock ordering |
| 8 | RB-3 | HIGH | sendmsg2.c | Dead code bug |
| 9 | RB-4 | HIGH | arc.mm | NULL deref |
| 10 | RB-6 | HIGH | selector_table.cc | Wrong variable |
| 11 | RB-7 | HIGH | protocol.c | NULL deref |
| 12 | RB-9 | HIGH | eh_personality.c | Weak symbol crash |
| 13 | TS-7 | MEDIUM | properties.m | Deadlock |
| 14 | TS-12 | MEDIUM | arc.mm | Init race |
| 15 | TS-14 | MEDIUM | arc.mm | Double-free |
| 16 | TS-15 | MEDIUM | loader.c | Init race |
| 17 | RB-5 | MEDIUM | arc.mm | NULL deref |
| 18 | RB-8 | MEDIUM | sendmsg2.c | NULL deref |
| 19 | RB-10 | MEDIUM | category_loader.c | Memory ordering |
| 20 | RB-14 | MEDIUM | arc.mm | Out-of-bounds |
| 21 | RB-15 | MEDIUM | properties.m | NULL deref |
| 22 | RB-11 | MEDIUM | various | Diagnostics |
| 23 | RB-12 | MEDIUM | eh_personality.c | Documentation |
| 24 | RB-13 | MEDIUM | eh_personality.c | MSVC interop |
| 25 | PF-7 | LOW | arc.mm | Atomic perf |
| 26 | PF-5 | LOW | dtable.c | False sharing |
| 27 | PF-11 | LOW | selector_table.cc | Memory waste |
| 28 | PF-1 | LOW | dtable.c | Lookup depth |
| 29 | PF-2 | LOW | arc.mm | TLS overhead |
| 30 | PF-3 | LOW | arc.mm | Pool traversal |
| 31 | PF-4 | LOW | selector_table.cc | Comparison perf |
