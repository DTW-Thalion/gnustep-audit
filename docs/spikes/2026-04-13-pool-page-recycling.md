# Spike: Autorelease Pool Page Recycling (libobjc2)

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repo:** libobjc2

## 1. Current state

libobjc2 has its own ARC-managed autorelease pool implementation in
`libobjc2/arc.mm`, gated by `useARCAutoreleasePool`. When the runtime does
not find an `NSAutoreleasePool` class that advertises
`_ARCCompatibleAutoreleasePool`, it uses this inline implementation; on
a gnustep-base system the flag is flipped at `arc.mm:424-440` and all
`@autoreleasepool { ... }` blocks route through the code reviewed below
(`arc.mm:525-579`).

### Page structure

`struct arc_autorelease_pool` is declared at `arc.mm:108-123`:

```
#define POOL_SIZE (4096 / sizeof(void*) - (2 * sizeof(void*)))
struct arc_autorelease_pool {
    struct arc_autorelease_pool *previous;  // prev page in chain
    id                          *insert;    // bump pointer
    id                           pool[POOL_SIZE];
};
```

On 64-bit, `POOL_SIZE = 512 - 16 = 496` slots, so the struct is
`16 + 496*8 = 3984` bytes — the comment at `arc.mm:101-107` says the
struct "should be exactly one page in size" but the arithmetic is a bit
off: two header words are subtracted in *slots* but the comment subtracts
them in *bytes*. A real 4 KiB page would want `POOL_SIZE = 510` on 64-bit.
Minor, not load-bearing for this spike; noted for the eventual change.

### Allocation / free

The pool list hangs off the per-thread TLS block:

```
struct arc_tls {
    struct arc_autorelease_pool *pool;   // top of page stack
    id                           returnRetained;
};
```
(`arc.mm:125-129`). TLS itself uses Windows Fls APIs
(`arc.mm:43-58`) or `pthread_setspecific` (`arc.mm:60-77`); the key is
`ARCThreadKey` (`arc.mm:80`). `getARCThreadData()` lazily `calloc`s the
`arc_tls` struct on first use (`arc.mm:140-153`).

Page allocation happens in exactly two places, and both use `calloc` via
the type-safe `new_zeroed<T>` wrapper defined at `arc.mm:134-138`:

- In `autorelease()` when the current page is full or nil
  (`arc.mm:465-472`):
  ```
  if (NULL == pool || (pool->insert >= &pool->pool[POOL_SIZE])) {
      pool = new_zeroed<struct arc_autorelease_pool>();
      pool->previous = tls->pool;
      pool->insert   = pool->pool;
      tls->pool      = pool;
  }
  ```
- In `objc_autoreleasePoolPush()` on the same condition
  (`arc.mm:541-548`).

Page freeing happens in exactly one place: `emptyPool()` at
`arc.mm:196-198`, inside the drain loop, calls plain `free(old)` after
unlinking each page whose contents have been released. There is no
intermediate free list: pages round-trip straight through the libc
allocator.

Thread exit drains everything via `cleanupPools()` at
`arc.mm:212-235`, which calls `emptyPool(tls, NULL)` and then `free(tls)`.

### Thread-local caching already present?

**None.** There is no `__thread` or `thread_local` in `arc.mm`, no hot-page
or free-list pointer on `arc_tls`, no `#ifdef POOL_CACHE`, no
commented-out recycler, no prior attempt in `git log --oneline -- arc.mm`
(the only pool-related commits in the last ~24 changes are
`14619f2` "Fix autorelease pool emptying when new references are added"
and `3c13ecc` "arc.mm — NULL guards, init race fix, cleanupPools loop,
pool bounds check" — both correctness, not allocation). The spike is
therefore a **greenfield** change, not a reframe.

### How many pages per `@autoreleasepool { ... }`?

Important caveat that shapes §4. `objc_autoreleasePoolPush()` does **not**
allocate a page on entry — it just returns the current `insert` pointer
(`arc.mm:551`) and allocates lazily only when the current page is full.
Push/pop is therefore free in the common case; the only real cost on
drain is releasing the objects whose pointers are stored in the pool slots
(`arc.mm:189-206`). A page is allocated by `autorelease()` only when the
current one's 496 slots fill up (`arc.mm:466`). Concretely:

- `@autoreleasepool { [[[NSObject alloc] init] autorelease]; }` — zero
  page allocations, amortized (the page that holds the one slot was
  already there from the previous iteration).
- 100-object or 1000-object pools — occasional page allocation when a
  run crosses a 496-slot boundary; roughly one `calloc`+`free` per 496
  autoreleases.
- The pool-churn pattern page recycling is designed for is when a pool
  grows *beyond* the current page and the extra pages are then freed on
  drain.

### Prior art reference

Apple's objc4 `AutoreleasePoolPage::hotPage()` / `setHotPage()` caches
the current page on a per-thread TSD slot and uses a lock-free magic
number to validate reuse, with `push()` only touching memory that's
already in cache. That is a more aggressive optimization than what this
spike proposes — libobjc2 already has the "don't allocate on push"
property for free because the top page hangs off `tls->pool`
(`arc.mm:541-551`).

## 2. Proposed change

Add a bounded thread-local free list of recently-drained
`arc_autorelease_pool` pages to `arc_tls`, so that the page freed in
`emptyPool()` can be handed straight back to the next allocation site in
`autorelease()` / `objc_autoreleasePoolPush()` without round-tripping
through `calloc`/`free`.

### Shape

1. Extend `arc_tls` (`arc.mm:125-129`):
   ```
   struct arc_tls {
       struct arc_autorelease_pool *pool;
       id                           returnRetained;
       struct arc_autorelease_pool *free_list_head; // recycled pages
       int                          free_list_count;
   };
   ```
   Hanging the cache off the existing TLS struct avoids a second TLS
   lookup and reuses the existing `cleanupPools()` exit handler
   (`arc.mm:212-235`) for drain.

2. Add a compile-time cap:
   ```
   #define POOL_FREE_LIST_CAP 4   // 4 * ~4 KiB = ~16 KiB per thread
   ```

3. Introduce two helpers, inline in `arc.mm`:
   ```
   static inline struct arc_autorelease_pool *
   acquirePoolPage(struct arc_tls *tls);

   static inline void
   releasePoolPage(struct arc_tls *tls,
                   struct arc_autorelease_pool *page);
   ```

   `acquirePoolPage` pops from `free_list_head` if non-empty (decrementing
   `free_list_count`) and otherwise falls back to
   `new_zeroed<struct arc_autorelease_pool>()`. `releasePoolPage` pushes
   onto the free list if `free_list_count < POOL_FREE_LIST_CAP`, otherwise
   calls `free()`.

4. Call sites:
   - `arc.mm:468` and `arc.mm:544` become `pool = acquirePoolPage(tls);`
   - `arc.mm:198` (`free(old);`) becomes
     `releasePoolPage(tls, static_cast<struct arc_autorelease_pool*>(old));`
   - `cleanupPools()` (`arc.mm:212`) walks `free_list_head` and
     `free()`s every entry before `free(tls)`.

### Invariants and zero-state

`new_zeroed<T>` uses `calloc` (`arc.mm:137`), so fresh pages are
zero-initialized. Recycled pages are **not** necessarily zero — `insert`
was previously advanced and then walked back down. The good news is the
code at `arc.mm:469-471` immediately rewrites `previous` and `insert`
before any read, and the `pool[]` array is written before it's read
(`*pool->insert = obj;` at `arc.mm:473`). So recycled pages do **not**
need re-zeroing, which matters for cost: recycling is just two pointer
writes, not a 4 KiB memset. This is worth a comment in the new helper
explaining why the zero-state invariant is safe.

### Why not hot-page (Apple-style)?

Because libobjc2's `objc_autoreleasePoolPush()` already does not allocate
a page on entry (`arc.mm:541-551`), the hot-page win — "push doesn't touch
memory outside cache" — is mostly already paid for. The remaining cost is
the `calloc`/`free` pair on page overflow and drain-of-extra-pages, which
is exactly what a free list recovers. Keep the change minimal.

## 3. ABI impact

Internal change only. Scope:

- `struct arc_tls` grows by two fields (one pointer + one int + padding
  = 16 bytes on 64-bit). This struct is **not** part of the public ABI;
  it is defined locally in `arc.mm:125` and never exported. All users go
  through `arc_tls_load`/`arc_tls_store` via TLS on an opaque `void*`.
- `struct arc_autorelease_pool` layout is **unchanged**.
- No new exported symbols. (A future diagnostic
  `objc_arc_pool_freelist_count_np` could be added following the same
  `_np` convention as `objc_arc_autorelease_count_np` at `arc.mm:490`,
  but is out of scope for this spike.)
- No header changes.

Per B1 §3.5 (`docs/spikes/2026-04-13-per-class-cache-version.md`),
libobjc2's `SOVERSION` is pinned at `libobjc_VERSION = 4.6`
(`libobjc2/CMakeLists.txt:36`, consumed at line 292 as
`SOVERSION ${libobjc_VERSION}`). B1 establishes that SOVERSION bumps are
required only for changes to publicly observable layouts or exported
symbol signatures. Neither applies here, so **no SOVERSION bump**.

## 4. Performance estimate

### Status quo cost

On a typical `bench_autorelease.m`-style workload
(`instrumentation/benchmarks/bench_autorelease.m:1-158`):

- **`autorelease_empty_pool`** (`bench_autorelease.m:147-154`): zero page
  allocations. Pure push/pop, untouched by this spike. **No delta.**
- **`autorelease_1_obj`** (`bench_autorelease.m:26-37`): one autorelease
  per iteration. Amortized zero page allocations per iteration; crosses
  the 496-slot boundary once every ~496 iterations. At 100000 iterations
  that is ~200 `calloc`/`free` pairs across the run. **Negligible delta.**
- **`autorelease_10_obj`**: same as above, one boundary every ~50
  iterations → ~200 `calloc`/`free` pairs across 10000 iterations.
  **Small delta.**
- **`autorelease_100_obj`**: one boundary every ~5 iterations.
  **Modest delta** (~2000 allocator round-trips across the run).
- **`autorelease_1000_obj`** (`bench_autorelease.m:79-93`): each
  iteration autoreleases 1000 objects, spanning ~3 pages. Two extra
  pages are allocated on the way up and freed on the way down, per
  iteration: **~2000 `calloc`/`free` pairs per 1000 iterations**. This
  is the benchmark where the optimization should show up cleanly. At
  ~100 ns per `calloc` and ~80 ns per `free` on ucrt, ~400 ns per
  iteration is spent in the allocator. With a free-list cap of 4 pages,
  both extra pages are cached after iteration 1, so iterations 2..N pay
  zero allocator cost. **Expected savings: ~400 ns per iteration, or
  roughly `2 * (calloc + free) ≈ 360 ns`** — this should be visible as
  a double-digit percentage on `autorelease_1000_obj` if the pool
  dominates, probably single-digit overall because the 1000 object
  `alloc`/`init` calls dominate the iteration.
- **`autorelease_nested_5`** (`bench_autorelease.m:97-143`): each nested
  level autoreleases 10 objects inside its own pool, 50 total per
  iteration. All 50 slots live in the same page almost always — the
  only page allocations come from slot-boundary crossings in the
  outermost pool. **Small delta**, similar to `autorelease_10_obj`.

### Caveats

- These estimates assume `calloc` for a fixed ~4 KiB allocation hits
  the libc fast path. On ucrt (MSYS2 default for the GNUstep audit env),
  that is usually true, but the exact number will depend on heap state.
  A mimalloc-preloaded run would already absorb most of this cost and
  make the delta smaller.
- The benchmark harness times `@autoreleasepool` cycles that include the
  `[[NSObject alloc] init]` calls. On the non-`_fast_path_alloc` side,
  those dominate; on the fast path (`classForObject` / `objc_class_flag_fast_arc`)
  they are cheap and the allocator delta is more visible.
- The "200 ns per `@autoreleasepool` saved" figure from the spike brief
  is an **over-estimate** for libobjc2 specifically, because libobjc2
  already amortizes the page across multiple cycles (§1). The realistic
  figure is closer to `2*(calloc+free) / POOL_SIZE ≈ 0.4 ns per
  autorelease` in a one-object-per-pool workload, and roughly that times
  N for an N-page pool in the 1000-object case.

### Recommendation for measurement

Run `bench_autorelease_1000_obj` before/after with 10 trials each, take
the median, and confirm the delta matches the `2*(calloc+free)` estimate
to within 2x. If it doesn't, the allocator path is already faster than
assumed and the spike is NO-GO on data.

## 5. Risk

### Thread-local storage portability

Already solved. libobjc2's TLS layer (`arc.mm:43-77`) abstracts over
Windows Fls APIs and `pthread_setspecific`, and the `arc_tls` struct is
the TLS value. Adding fields to that struct needs zero portability work;
we do **not** need a second `__thread` or `thread_local` declaration,
which avoids the Windows `__thread` issue noted in the brief entirely.

### Free-list underflow / overflow

Bounded by `POOL_FREE_LIST_CAP` on the push side and by an explicit
`NULL` check on the pop side. Both are single-threaded (the list is
per-thread), so no locking or CAS is needed. Basic assertion at thread
exit in `cleanupPools()` that `free_list_count` matches the walked chain
length is cheap and catches the obvious bugs.

### Thread lifetime / memory held across drain

`cleanupPools()` at `arc.mm:212-235` already runs at thread exit via the
TLS destructor. Extending it to walk `free_list_head` and `free()` each
cached page is a four-line change and guarantees no leak across thread
teardown. Short-lived threads that allocate only one pool page will cache
it on first drain and release it on thread exit — worst-case extra
lifetime is the thread's own lifetime, bounded by the cap.

### Memory pressure

Under low-memory conditions, `calloc` starts failing before the OS frees
anything, and the cached pages in the free list are inaccessible to the
allocator. With `POOL_FREE_LIST_CAP = 4` this is 16 KiB per thread — on
a 32-thread process, 512 KiB held hostage. Acceptable for typical
workloads but worth a comment in the code. If it's ever a concern, a
future `objc_arc_drain_free_lists_np()` diagnostic entry point can force
the drain; again, out of scope.

### Correctness regression

The dangerous class of bug: recycled page has stale `insert` or
`previous` on reuse. Mitigated by the fact that both fields are
unconditionally rewritten at `arc.mm:469-471` and `arc.mm:545-547`
*before* the new page is linked into `tls->pool`. A new assertion in
`acquirePoolPage` that the returned page's caller-visible fields get
clobbered before use is cheap in debug builds.

## 6. Test strategy

### Correctness

1. **Existing: `libobjc2/Test/FastARCPool.m`.** Already exercises
   multi-page pools: it autoreleases `POOL_SIZE` (= 512 on 64-bit, which
   is slightly more than the runtime's 496-slot page) objects inside a
   `-dealloc`, forcing at least one extra page allocation from inside a
   drain (`FastARCPool.m:23-28`). Must continue to pass.
2. **New correctness test** (`libobjc2/Test/FastARCPoolRecycle_arc.m`):
   - Run 1000 cycles of `@autoreleasepool { alloc 2000 objects; }` to
     force 4+ page allocations per cycle. Assert no leak via
     `objc_arc_autorelease_count_np()` == 0 between cycles.
   - Populate the free list to its cap, drain the thread (via a helper
     thread), verify no Valgrind / AddressSanitizer finding. Use
     `pthread_create` directly — this is a libobjc2 Test, no Foundation
     required.
   - Reuse test: capture a page address via a diagnostic hook on first
     allocation, drain, allocate again, verify the second allocation
     returns the same address. This exercises the recycled path.
3. **Stress**: Tight loop on two threads, each doing
   `@autoreleasepool { N objects; }` with N varying to force
   multi-page pools on one side and single-page on the other. Verify
   both `free_list_count` stays within cap and no deadlock (should be
   trivially impossible, no locks).

### Performance

1. Re-run `bench_autorelease.m` before/after, 10 trials each, compare
   via `instrumentation/benchmarks/compare_results.py` if it exists.
   Primary target: `autorelease_1000_obj`. Secondary: `autorelease_nested_5`.
   Look for the predicted double-digit-% win on the 1000-object case.
2. If no measurable win, the spike is NO-GO on data — do not merge.

### Hygiene

- Build with `-DLIBOBJC2_DEBUG=1` and AddressSanitizer. Free-list pages
  should show no use-after-free on the reuse path.
- Confirm `cleanupPools()` teardown finds and frees every cached page
  by sprinkling a counter or by checking allocator stats after a
  join-all-threads sequence.

## 7. Decision

**GO** — subject to the §4 benchmark check passing.

- No caching exists today (§1).
- The change is small: ~40 lines, confined to `arc.mm`, no header or
  ABI ripple (§3).
- Thread-local storage is already abstracted; we reuse it (§5).
- There is a cheap, clear benchmark in the audit tree that will tell us
  whether the win is real (§4, §6).
- The only risk worth naming — recycled-page stale state — is
  neutralized by the existing unconditional rewrite of `previous` and
  `insert` at `arc.mm:469-471` and `arc.mm:545-547`.

**Preconditions on merge:**

1. `bench_autorelease_1000_obj` shows a measurable improvement
   (target: ≥5% wall-clock reduction, median of 10 trials) in an ucrt
   build with the system allocator.
2. `FastARCPool` and the new recycle test pass on Windows, Linux
   and macOS CI (whatever libobjc2's master branch runs).
3. No SOVERSION bump (per B1 §3.5 and `CMakeLists.txt:36`).

If precondition 1 fails — i.e., the allocator is already fast enough
that two `calloc`/`free` pairs per 1000 autoreleases are invisible —
downgrade to **NO-GO** and document the finding in a follow-up so this
spike doesn't get rediscovered.
