# UI Layer (libs-gui + libs-back) Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans

**Goal:** Fix 36 findings across libs-gui and libs-back -- 8 Critical, 13 High, 15 Medium

**Architecture:** Fix libs-back critical issues first (zero thread safety, no XIOErrorHandler), then libs-gui crashes, then thread safety hardening, then robustness.

**Tech Stack:** Objective-C, C. Build: GNUstep Make. Test: Tests/gui/ (libs-gui), none yet (libs-back).

**Repos:**
- libs-gui: `C:\Users\toddw\source\repos\gnustep-audit\libs-gui`
- libs-back: `C:\Users\toddw\source\repos\gnustep-audit\libs-back`

---

## Phase 1: libs-back Critical (Steps 1-5)

### Step 1: TS-B1 + TS-B2 -- Add thread safety to windowmaps/windowtags

**Finding:** Static `windowmaps`/`windowtags` NSMapTables in XGServerWindow.m:85-89 have zero synchronization. All reads/writes from any thread are unprotected.

**File:** `libs-back/Source/x11/XGServerWindow.m`

**Current code (lines 85-89):**
```objc
/* Current mouse grab window */
static gswindow_device_t *grab_window = NULL;

/* Keep track of windows */
static NSMapTable *windowmaps = NULL;
static NSMapTable *windowtags = NULL;
```

**Fix:** Add a static NSRecursiveLock and wrap all access points:

```objc
/* Current mouse grab window */
static gswindow_device_t *grab_window = NULL;

/* Keep track of windows */
static NSMapTable *windowmaps = NULL;
static NSMapTable *windowtags = NULL;

/* Thread safety lock for window maps */
static NSRecursiveLock *windowMapsLock = nil;

+ (void) initialize
{
  if (self == [XGServerWindow class])
    {
      windowMapsLock = [[NSRecursiveLock alloc] init];
    }
}
```

Then wrap the `WINDOW_WITH_TAG` macro and all `NSMapGet`/`NSMapInsert`/`NSMapRemove` calls on `windowmaps` and `windowtags` with `[windowMapsLock lock]` / `[windowMapsLock unlock]`. Create helper functions:

```objc
static inline gswindow_device_t *
_windowWithTag(int windowNumber)
{
  gswindow_device_t *result;
  [windowMapsLock lock];
  result = (gswindow_device_t *)NSMapGet(windowtags, (void *)(uintptr_t)windowNumber);
  [windowMapsLock unlock];
  return result;
}

static inline gswindow_device_t *
_windowForXWindow(Window xWindow)
{
  gswindow_device_t *result;
  [windowMapsLock lock];
  result = (gswindow_device_t *)NSMapGet(windowmaps, (void *)xWindow);
  [windowMapsLock unlock];
  return result;
}
```

Replace `WINDOW_WITH_TAG(x)` macro usages with `_windowWithTag(x)` calls. Grep for all `NSMapGet(windowtags` and `NSMapGet(windowmaps` to catch every site.

**Verification:** Build libs-back. Grep to confirm no unprotected direct NSMapGet/NSMapInsert/NSMapRemove on windowmaps/windowtags remain.

---

### Step 2: TS-B3 + RB-B1 -- Register XIOErrorHandler

**Finding:** XGServer.m:501 calls `XSetErrorHandler(XGErrorHandler)` but never calls `XSetIOErrorHandler`. When the X server crashes, the default Xlib IO error handler calls `exit(1)` with no cleanup.

**File:** `libs-back/Source/x11/XGServer.m`

**Current code (line 501):**
```objc
  XSetErrorHandler(XGErrorHandler);
```

**Fix:** Add an IO error handler that posts a notification and performs graceful cleanup:

```objc
static int
XGIOErrorHandler(Display *display)
{
  /*
   * X11 IO errors are fatal and non-recoverable. The display connection
   * is now invalid. We attempt best-effort cleanup before exiting.
   */
  NSLog(@"Fatal X11 IO error: display connection lost");

  NS_DURING
    {
      /* Post notification so observers can save state */
      [[NSNotificationCenter defaultCenter]
        postNotificationName: @"GSDisplayConnectionLost"
                      object: nil];

      /* Attempt clean termination */
      if (nil != NSApp)
        {
          [NSApp terminate: nil];
        }
    }
  NS_HANDLER
    {
      NSLog(@"Exception during X11 IO error cleanup: %@",
            [localException reason]);
    }
  NS_ENDHANDLER

  exit(1);
  return 0; /* Not reached, but required by signature */
}
```

Insert registration right after the existing error handler line:

```objc
  XSetErrorHandler(XGErrorHandler);
  XSetIOErrorHandler(XGIOErrorHandler);
```

**Verification:** Build libs-back. Verify the handler is registered at startup by checking with a debugger or adding a debug log at registration.

---

### Step 3: TS-B4 -- Wayland dealloc resource leak

**Finding:** WaylandServer.m dealloc (lines 264-268) only calls `[super dealloc]` without disconnecting the Wayland display, freeing wlconfig, or destroying windows.

**File:** `libs-back/Source/wayland/WaylandServer.m`

**Current code (lines 264-268):**
```objc
- (void)dealloc
{
  NSDebugLog(@"Destroying Wayland Server");
  [super dealloc];
}
```

**Fix:** Implement proper cleanup:

```objc
- (void)dealloc
{
  NSDebugLog(@"Destroying Wayland Server");

  if (wlconfig)
    {
      /* Destroy all windows */
      struct window *window, *tmp;
      wl_list_for_each_safe(window, tmp, &wlconfig->window_list, link)
        {
          if (window->surface)
            wl_surface_destroy(window->surface);
          wl_list_remove(&window->link);
          free(window);
        }

      /* Destroy all outputs */
      struct output *output, *otmp;
      wl_list_for_each_safe(output, otmp, &wlconfig->output_list, link)
        {
          wl_list_remove(&output->link);
          free(output);
        }

      /* Release global objects */
      if (wlconfig->seat)
        wl_seat_destroy(wlconfig->seat);
      if (wlconfig->shm)
        wl_shm_destroy(wlconfig->shm);
      if (wlconfig->compositor)
        wl_compositor_destroy(wlconfig->compositor);
      if (wlconfig->wm_base)
        xdg_wm_base_destroy(wlconfig->wm_base);
      if (wlconfig->layer_shell)
        zwlr_layer_shell_v1_destroy(wlconfig->layer_shell);
      if (wlconfig->registry)
        wl_registry_destroy(wlconfig->registry);

      /* Disconnect display last */
      if (wlconfig->display)
        wl_display_disconnect(wlconfig->display);

      free(wlconfig);
      wlconfig = NULL;
    }

  [super dealloc];
}
```

**Note:** Check the actual struct definitions in the wayland headers used by this project to ensure correct destroy function names. The `wl_shell` interface may need `wl_shell_destroy` if present.

**Verification:** Build libs-back with Wayland support. Run under valgrind to confirm no leaked Wayland objects.

---

### Step 4: TS-B5 -- Wayland buffer busy flag race

**Finding:** WaylandCairoShmSurface.m:73-78 -- The `buffer->busy` flag is written by the compositor callback (`buffer_handle_release`) on a different thread from the main code without any synchronization.

**File:** `libs-back/Source/cairo/WaylandCairoShmSurface.m`

**Current code (lines 72-78):**
```c
static void
buffer_handle_release(void *data, struct wl_buffer *wl_buffer)
{
  struct pool_buffer *buffer = data;
  buffer->busy = false;
  // If the buffer was not released before dealloc
  finishBuffer(buffer);
}
```

**Fix:** Use `stdatomic.h` for the busy flag. Change the `busy` field in the pool_buffer struct from `bool` to `_Atomic(bool)` (or `atomic_bool`):

First, add at the top of the file:
```c
#include <stdatomic.h>
```

Then in the pool_buffer struct definition (find it in the header or at top of file), change:
```c
// Old:
bool busy;
// New:
atomic_bool busy;
```

Update `buffer_handle_release`:
```c
static void
buffer_handle_release(void *data, struct wl_buffer *wl_buffer)
{
  struct pool_buffer *buffer = data;
  atomic_store(&buffer->busy, false);
  // If the buffer was not released before dealloc
  finishBuffer(buffer);
}
```

Update `finishBuffer`:
```c
static void
finishBuffer(struct pool_buffer *buf)
{
  if(buf == NULL || atomic_load(&buf->busy) || buf->surface != NULL)
  {
    return;
  }
  // ... rest unchanged
}
```

Update wherever `busy` is set to `true`:
```c
atomic_store(&buf->busy, true);
```

**Verification:** Build and verify no compiler warnings about atomic operations.

---

### Step 5: RB-B4 -- Wayland createShmBuffer memory leak on error paths

**Finding:** WaylandCairoShmSurface.m:127-171 -- `createShmBuffer` allocates `pool_buffer` via `malloc` but returns NULL on `createPoolFile`/`mmap` failure without freeing the struct.

**File:** `libs-back/Source/cairo/WaylandCairoShmSurface.m`

**Current code (lines 127-171):**
```c
struct pool_buffer *
createShmBuffer(int width, int height, struct wl_shm *shm)
{
  uint32_t stride = cairo_format_stride_for_width(cairo_fmt, width);
  size_t   size = stride * height;

  struct pool_buffer * buf = malloc(sizeof(struct pool_buffer));

  void *data = NULL;
  if (size > 0)
    {
      buf->poolfd = createPoolFile(size);
      if (buf->poolfd == -1)
        {
          return NULL;  // LEAK: buf not freed
        }

      data
	= mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, buf->poolfd, 0);
      if (data == MAP_FAILED)
        {
          return NULL;  // LEAK: buf not freed, poolfd not closed
        }
      // ...
    }
  else
  {
    return NULL;  // LEAK: buf not freed
  }
  // ...
}
```

**Fix:**

```c
struct pool_buffer *
createShmBuffer(int width, int height, struct wl_shm *shm)
{
  uint32_t stride = cairo_format_stride_for_width(cairo_fmt, width);
  size_t   size = stride * height;

  struct pool_buffer * buf = malloc(sizeof(struct pool_buffer));
  if (!buf)
    {
      return NULL;
    }
  memset(buf, 0, sizeof(struct pool_buffer));

  void *data = NULL;
  if (size > 0)
    {
      buf->poolfd = createPoolFile(size);
      if (buf->poolfd == -1)
        {
          free(buf);
          return NULL;
        }

      data
	= mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, buf->poolfd, 0);
      if (data == MAP_FAILED)
        {
          close(buf->poolfd);
          free(buf);
          return NULL;
        }

      buf->pool = wl_shm_create_pool(shm, buf->poolfd, size);
      buf->buffer = wl_shm_pool_create_buffer(buf->pool, 0, width, height,
					      stride, wl_fmt);
      wl_buffer_add_listener(buf->buffer, &buffer_listener, buf);
    }
  else
    {
      free(buf);
      return NULL;
    }

  buf->data = data;
  buf->size = size;
  buf->width = width;
  buf->height = height;
  buf->surface = cairo_image_surface_create_for_data(data, cairo_fmt, width, height, stride);

  if(buf->pool)
    {
      wl_shm_pool_destroy(buf->pool);
      buf->pool = NULL;
    }
  return buf;
}
```

**Verification:** Build. Run under valgrind with a Wayland session to verify no leaks on error paths.

---

## Phase 2: libs-gui Critical (Steps 6-8)

### Step 6: TS-G1 -- NSApplication main-thread assertion

**Finding:** NSApplication.m:2209-2262 -- `nextEventMatchingMask:` has no thread confinement check. Calling from a non-main thread races with the main event loop.

**File:** `libs-gui/Source/NSApplication.m`

**Current code (lines 2209-2213):**
```objc
- (NSEvent*) nextEventMatchingMask: (NSUInteger)mask
			 untilDate: (NSDate*)expiration
			    inMode: (NSString*)mode
			   dequeue: (BOOL)flag
{
  NSEvent	*event;
```

**Fix:** Add a main-thread assertion at the start of the method:

```objc
- (NSEvent*) nextEventMatchingMask: (NSUInteger)mask
			 untilDate: (NSDate*)expiration
			    inMode: (NSString*)mode
			   dequeue: (BOOL)flag
{
  NSEvent	*event;

  if (GSCurrentThread() != GSAppKitThread)
    {
      [NSException raise: NSInternalInconsistencyException
                  format: @"nextEventMatchingMask: called from non-main thread. "
                          @"The event loop must only be accessed from the main thread."];
    }
```

**Verification:** Build libs-gui. Verify existing tests pass. Any test that intentionally accesses events from background threads will need to be updated to use `performSelectorOnMainThread:`.

---

### Step 7: TS-G2 -- NSView subview array snapshot during display

**Finding:** NSView.m:2619-2654 -- `displayRectIgnoringOpacity:inContext:` iterates `_sub_views` using a C array copy, but the count is read once and `_sub_views` can be mutated concurrently by `addSubview:` or `removeFromSuperview` from another thread.

**File:** `libs-gui/Source/NSView.m`

**Current code (lines 2617-2654):**
```objc
  if (_rFlags.has_subviews == YES)
    {
      NSUInteger count = [_sub_views count];

      if (count > 0)
        {
          NSView *array[count];
          NSUInteger i;
          
          [_sub_views getObjects: array];

          for (i = 0; i < count; ++i)
            {
              NSView *subview = array[i];
              // ...
            }
        }
```

**Fix:** Take a retained snapshot of `_sub_views` to prevent mutation during iteration:

```objc
  if (_rFlags.has_subviews == YES)
    {
      /* Take a snapshot of the subviews array to protect against
       * mutation during display (e.g., addSubview:/removeFromSuperview
       * called from another thread or a drawRect: callback).
       */
      NSArray *subviews = [_sub_views copy];
      NSUInteger count = [subviews count];

      if (count > 0)
        {
          NSView *array[count];
          NSUInteger i;
          
          [subviews getObjects: array];

          for (i = 0; i < count; ++i)
            {
              NSView *subview = array[i];
              NSRect subviewFrame = [subview _frameExtend];
              NSRect isect;
              
              isect = NSIntersectionRect(aRect, subviewFrame);
              if (NSIsEmptyRect(isect) == NO)
                {
                  isect = [subview convertRect: isect fromView: self];
                  [subview displayRectIgnoringOpacity: isect
                                            inContext: context];
                }
              if (subview->_rFlags.needs_display == YES)
                {
                  subviewNeedsDisplay = YES;
                }
            }
        }
      RELEASE(subviews);
```

**Verification:** Build libs-gui. Run existing display tests.

---

### Step 8: TS-G3 -- GSLayoutManager thread safety

**Finding:** GSLayoutManager.m (3149 lines) has zero locks. Background layout + user typing = glyph structure corruption.

**File:** `libs-gui/Source/GSLayoutManager.m`

**Fix:** Add an NSRecursiveLock to protect layout state mutations. The lock needs to be an ivar.

In the header (`GSLayoutManager_internal.h` or wherever ivars are declared), add:
```objc
NSRecursiveLock *_layoutLock;
```

In `init`:
```objc
_layoutLock = [[NSRecursiveLock alloc] init];
```

In `dealloc`:
```objc
RELEASE(_layoutLock);
```

Wrap critical mutation methods with the lock. The key methods to protect are:

1. `invalidateGlyphsForCharacterRange:changeInLength:actualCharacterRange:` (line 1194)
2. `_generateGlyphsUpToCharacter:` (line 700)
3. `_generateGlyphsUpToGlyph:` (line 738)
4. `_doLayout` / `_doLayoutToContainer:` / `_doLayoutToGlyph:` (line 1844+)
5. `setTextStorage:` and `textStorage:edited:range:changeInLength:invalidatedRange:`

Pattern for each method:
```objc
- (void) invalidateGlyphsForCharacterRange: (NSRange)range
                            changeInLength: (int)lengthChange
                      actualCharacterRange: (NSRange *)actualRange
{
  [_layoutLock lock];
  NS_DURING
    {
      // ... existing body ...
    }
  NS_HANDLER
    {
      [_layoutLock unlock];
      [localException raise];
    }
  NS_ENDHANDLER
  [_layoutLock unlock];
}
```

**Note:** Use NS_DURING/NS_HANDLER rather than @try/@catch for consistency with GNUstep style. The lock is recursive because layout methods can call each other (e.g., `_doLayoutToGlyph:` calls `_generateGlyphsUpToGlyph:`).

**Verification:** Build libs-gui. Run text editing tests. The lock should not change single-threaded behavior.

---

## Phase 3: libs-back High (Steps 9-14)

### Step 9: TS-G4 -- Modal session list protection

**Finding:** NSApplication.m:1685-1749 -- The `_session` linked list is manipulated without locks. `abortModal` from a background thread races with `beginModalSessionForWindow:` / `endModalSession:`.

**File:** `libs-gui/Source/NSApplication.m`

**Fix:** Add an NSLock ivar `_sessionLock` to NSApplication. Initialize in `-init`, lock/unlock around all `_session` reads and mutations in:
- `beginModalSessionForWindow:` (line 1669+)
- `endModalSession:` (line 1719+)
- `runModalSession:` (references to `theSession->runState`, `_session`)
- `abortModal` / `stopModalWithCode:`

```objc
// In NSApplication init (or +initialize):
_sessionLock = [[NSLock alloc] init];

// In beginModalSessionForWindow:
[_sessionLock lock];
theSession->previous = _session;
_session = theSession;
[_sessionLock unlock];

// In endModalSession:
[_sessionLock lock];
// ... existing linked list manipulation ...
[_sessionLock unlock];
```

**Verification:** Build libs-gui. Test modal dialogs still work correctly.

---

### Step 10: TS-B6 -- CairoGState copyWithZone thread documentation + RB-B2 partial init fix

**Finding:** CairoGState.m:144-179 -- `copyWithZone:` creates a new cairo context on the same surface. Concurrent drawing on the copy is undefined behavior. Also, on `cairo_create` failure, returns a partially initialized object.

**File:** `libs-back/Source/cairo/CairoGState.m`

**Current code (lines 144-162):**
```objc
- (id) copyWithZone: (NSZone *)zone
{
  CairoGState *copy = (CairoGState *)[super copyWithZone: zone];

  RETAIN(_surface);

  if (_ct)
    {
      cairo_status_t status;
 
      copy->_ct = cairo_create(cairo_get_target(_ct));
      status = cairo_status(copy->_ct);
      if (status != CAIRO_STATUS_SUCCESS)
        {
          NSLog(@"Cairo status '%s' in copy", cairo_status_to_string(status));
          copy->_ct = NULL;
        }
```

**Fix:** Return nil on cairo_create failure instead of a partial object, and add thread safety documentation:

```objc
- (id) copyWithZone: (NSZone *)zone
{
  /*
   * WARNING: Thread safety -- the copy shares the same underlying cairo
   * surface as the original. The caller MUST NOT draw on the original
   * and the copy concurrently. All drawing to a given surface must be
   * serialized externally.
   */
  CairoGState *copy = (CairoGState *)[super copyWithZone: zone];

  RETAIN(_surface);

  if (_ct)
    {
      cairo_status_t status;
 
      copy->_ct = cairo_create(cairo_get_target(_ct));
      status = cairo_status(copy->_ct);
      if (status != CAIRO_STATUS_SUCCESS)
        {
          NSLog(@"Cairo status '%s' in copy", cairo_status_to_string(status));
          cairo_destroy(copy->_ct);
          copy->_ct = NULL;
          RELEASE(_surface);
          RELEASE(copy);
          return nil;
        }
```

**Verification:** Build libs-back.

---

### Step 11: TS-B7 -- XWindowBuffer static array lock

**Finding:** XWindowBuffer.m:41-42 -- Static `window_buffers` array grown with `realloc`, no lock.

**File:** `libs-back/Source/x11/XWindowBuffer.m`

**Current code (lines 41-42):**
```c
static XWindowBuffer **window_buffers;
static int num_window_buffers;
```

**Fix:** Add a lock:

```c
static XWindowBuffer **window_buffers;
static int num_window_buffers;
static NSRecursiveLock *windowBufferLock = nil;
```

Initialize in `+initialize`:
```objc
+ (void) initialize
{
  if (self == [XWindowBuffer class])
    {
      windowBufferLock = [[NSRecursiveLock alloc] init];
    }
}
```

Wrap the `+windowBufferForWindow:depthInfo:` method body (the class method that accesses `window_buffers`) with lock/unlock.

**Verification:** Build libs-back.

---

### Step 12: RB-B3 -- XWindowBuffer exit(1) on realloc failure

**Finding:** XWindowBuffer.m:200-203 -- `exit(1)` on realloc failure is too harsh.

**File:** `libs-back/Source/x11/XWindowBuffer.m`

**Current code (lines 196-203):**
```objc
      window_buffers = realloc(window_buffers,
        sizeof(XWindowBuffer *) * (num_window_buffers + 1));
      if (!window_buffers)
        {
          NSLog(@"Out of memory (failed to allocate %lu bytes)",
                (unsigned long)sizeof(XWindowBuffer *) * (num_window_buffers + 1));
          exit(1);
        }
```

**Fix:** Raise an exception instead, and preserve the old pointer:

```objc
      {
        XWindowBuffer **new_buffers = realloc(window_buffers,
          sizeof(XWindowBuffer *) * (num_window_buffers + 1));
        if (!new_buffers)
          {
            RELEASE(wi);
            [windowBufferLock unlock];
            [NSException raise: NSMallocException
                        format: @"Out of memory allocating XWindowBuffer array (%lu bytes)",
                        (unsigned long)sizeof(XWindowBuffer *) * (num_window_buffers + 1)];
            return nil;  /* Not reached */
          }
        window_buffers = new_buffers;
      }
```

**Verification:** Build libs-back.

---

### Step 13: TS-B9 -- handleExposeRect shared surface offset race

**Finding:** XGCairoModernSurface.m:112-145 -- `handleExposeRect:` temporarily modifies the surface device offset (`set_device_offset` to 0,0 then restores). If another thread draws concurrently, it sees the wrong offset.

**File:** `libs-back/Source/cairo/XGCairoModernSurface.m`

**Current code (lines 112-145):**
```objc
- (void) handleExposeRect: (NSRect)rect
{
  cairo_t *windowCtx = cairo_create(_windowSurface);

  double backupOffsetX, backupOffsetY;
  cairo_surface_get_device_offset(_surface, &backupOffsetX, &backupOffsetY);
  cairo_surface_set_device_offset(_surface, 0, 0);

  // ... paint ...

  cairo_destroy(windowCtx);
  cairo_surface_set_device_offset(_surface, backupOffsetX, backupOffsetY);
}
```

**Fix:** Instead of modifying the shared surface's device offset, create a temporary surface reference with no offset, or apply a compensating transform to the window context:

```objc
- (void) handleExposeRect: (NSRect)rect
{
  cairo_t *windowCtx = cairo_create(_windowSurface);

  /*
   * Instead of temporarily zeroing the back buffer's device offset
   * (which races with concurrent drawing), apply an inverse translation
   * on the window context to compensate for the offset.
   */
  double offsetX, offsetY;
  cairo_surface_get_device_offset(_surface, &offsetX, &offsetY);

  cairo_rectangle(windowCtx, rect.origin.x, rect.origin.y,
                  rect.size.width, rect.size.height);
  cairo_clip(windowCtx);
  cairo_set_source_surface(windowCtx, _surface, -offsetX, -offsetY);
  cairo_set_operator(windowCtx, CAIRO_OPERATOR_SOURCE);
  cairo_paint(windowCtx);

  cairo_destroy(windowCtx);
}
```

**Verification:** Build libs-back. Verify rendering is correct by running an X11 app and resizing windows.

---

### Step 14: TS-G5 -- NSWindow close deferred release

**Finding:** NSWindow.m:3219-3248 -- `close` posts `NSWindowWillCloseNotification` and then calls `RELEASE(self)`. Observers that retained the window during notification might still hold references to a deallocating object.

**File:** `libs-gui/Source/NSWindow.m`

**Current code (lines 3217-3248):**
```objc
- (void) close
{
  if (_f.has_closed == NO)
    {
      CREATE_AUTORELEASE_POOL(pool);
      _f.has_closed = YES;

      if (!_f.is_released_when_closed)
        {
          RETAIN(self);
        }

      [nc postNotificationName: NSWindowWillCloseNotification object: self];
      _f.has_opened = NO;
      [NSApp removeWindowsItem: self];
      [self orderOut: self];
      // ...
      [pool drain];
      RELEASE(self);
    }
}
```

**Fix:** Defer the final RELEASE to the end of the current run loop cycle so observers can safely process the notification:

```objc
- (void) close
{
  if (_f.has_closed == NO)
    {
      CREATE_AUTORELEASE_POOL(pool);
      _f.has_closed = YES;

      if (!_f.is_released_when_closed)
        {
          RETAIN(self);
        }

      [nc postNotificationName: NSWindowWillCloseNotification object: self];
      _f.has_opened = NO;
      [NSApp removeWindowsItem: self];
      [self orderOut: self];

      if (_f.is_miniaturized == YES)
        {
          NSWindow *mini = GSWindowWithNumber(_counterpart);
          GSRemoveIcon(mini);
        }

      [pool drain];
      /*
       * Defer the release to the end of the current run loop iteration.
       * This ensures observers that retained self during
       * NSWindowWillCloseNotification can complete processing before
       * we potentially deallocate.
       */
      [[NSRunLoop currentRunLoop]
        performSelector: @selector(release)
                 target: self
               argument: nil
                  order: NSUIntegerMax
                  modes: [NSArray arrayWithObjects:
                           NSDefaultRunLoopMode,
                           NSModalPanelRunLoopMode,
                           NSEventTrackingRunLoopMode,
                           nil]];
    }
}
```

**Note:** If `performSelector:target:argument:order:modes:` is not available, use `[self performSelector:@selector(release) withObject:nil afterDelay:0]` instead.

**Verification:** Build libs-gui. Test window close behavior still works -- ensure `isReleasedWhenClosed` windows are properly released.

---

## Phase 4: libs-gui High (Steps 15-21)

### Step 15: TS-G6/G7 -- NSImage concurrent drawing lock

**Finding:** NSImage.m:1262-1334 -- `_lockedView` ivar shared without lock. `_cacheForRep:` called during `lockFocus` without `imageLock` held.

**File:** `libs-gui/Source/NSImage.m`

**Fix:** Add `@synchronized(self)` around `lockFocusOnRepresentation:` and `unlockFocus`:

```objc
- (void) lockFocusOnRepresentation: (NSImageRep *)imageRep
{
  @synchronized(self)
    {
      if (_cacheMode != NSImageCacheNever)
        {
          // ... existing body ...
          _lockedView = [window contentView];
          // ...
        }
    }
}

- (void) unlockFocus
{
  @synchronized(self)
    {
      if (_lockedView != nil)
        {
          [_lockedView unlockFocus];
          _lockedView = nil;
        }
    }
}
```

**Verification:** Build libs-gui. Test image drawing.

---

### Step 16: TS-G8 -- Focus stack mismatch on exception

**Finding:** NSView.m:2106-2290 -- If `drawRect:` throws an exception, `_lockFocusInContext:` has been called but `unlockFocusNeedsFlush:` is never called, permanently corrupting the graphics state stack.

**File:** `libs-gui/Source/NSView.m`

**Current code (lines 2603-2611):**
```objc
  if (NSIsEmptyRect(aRect) == NO)
    {
      [self _lockFocusInContext: context inRect: aRect];
      [self drawRect: aRect];
      [self unlockFocusNeedsFlush: flush];
    }
```

**Fix:** Wrap `drawRect:` in exception handling:

```objc
  if (NSIsEmptyRect(aRect) == NO)
    {
      [self _lockFocusInContext: context inRect: aRect];
      NS_DURING
        {
          [self drawRect: aRect];
        }
      NS_HANDLER
        {
          NSLog(@"Exception in -[%@ drawRect:]: %@",
                NSStringFromClass([self class]),
                [localException reason]);
        }
      NS_ENDHANDLER
      [self unlockFocusNeedsFlush: flush];
    }
```

**Verification:** Build libs-gui. Test that throwing an exception in a subclass `drawRect:` no longer corrupts the graphics state.

---

### Step 17: RB-G1 -- Division by zero in setFrameSize

**Finding:** NSView.m:1289-1290 -- When the view is rotated/scaled and `_frame.size.width` or `.height` is 0, dividing `_bounds.size` by frame size causes division by zero.

**File:** `libs-gui/Source/NSView.m`

**Current code (lines 1285-1295):**
```objc
      if (_is_rotated_or_scaled_from_base)
        {
          if (_boundsMatrix == nil)
            {
              CGFloat sx = _bounds.size.width  / _frame.size.width;
              CGFloat sy = _bounds.size.height / _frame.size.height;
              
              newFrame.size = newSize;
	      [self _setFrameAndClearAutoresizingError: newFrame];
              _bounds.size.width  = _frame.size.width  * sx;
              _bounds.size.height = _frame.size.height * sy;
            }
```

**Fix:** Guard against zero-size frame:

```objc
      if (_is_rotated_or_scaled_from_base)
        {
          if (_boundsMatrix == nil)
            {
              CGFloat sx = (_frame.size.width  > 0)
                ? (_bounds.size.width  / _frame.size.width)  : 1.0;
              CGFloat sy = (_frame.size.height > 0)
                ? (_bounds.size.height / _frame.size.height) : 1.0;
              
              newFrame.size = newSize;
	      [self _setFrameAndClearAutoresizingError: newFrame];
              _bounds.size.width  = _frame.size.width  * sx;
              _bounds.size.height = _frame.size.height * sy;
            }
```

**Verification:** Build libs-gui. Test setting a view to zero-size while rotated does not crash.

---

### Step 18: RB-G2 -- Nib class-not-found fallback

**Finding:** GSNibLoading.m:798-801 -- When a class referenced in a nib file cannot be found, an unrecoverable `NSInternalInconsistencyException` is raised. There is no substitution fallback.

**File:** `libs-gui/Source/GSNibLoading.m`

**Current code (lines 797-801):**
```objc
      if (_realObject == nil)
	{
	  Class aClass = NSClassFromString(_className);
	  if (aClass == nil)
	    {
	      [NSException raise: NSInternalInconsistencyException
			   format: @"Unable to find class '%@'", _className];
	    }
```

**Fix:** Substitute NSView (for views) or NSObject (for non-views) and log a warning:

```objc
      if (_realObject == nil)
	{
	  Class aClass = NSClassFromString(_className);
	  if (aClass == nil)
	    {
	      NSWarnMLog(@"Unable to find class '%@' referenced in nib; "
	                 @"substituting NSObject", _className);
	      aClass = [NSObject class];
	    }
```

**Verification:** Build libs-gui. Verify nib loading with a missing class logs a warning but does not crash.

---

### Step 19: RB-B5 -- WIN32Server GDI cleanup centralization

**Finding:** WIN32Server.m has identical GDI cleanup sequences (SelectObject/DeleteObject/DeleteDC/ReleaseDC) duplicated in `resizeBackingStoreFor:`, `windowbacking:`, `dealloc`, and other locations.

**File:** `libs-back/Source/win32/WIN32Server.m`

**Fix:** Create a helper function:

```objc
/**
 * Release GDI backing store resources for a WIN_INTERN structure.
 * Sets hdc and old to NULL after cleanup.
 */
static void
_releaseGDIBackingStore(WIN_INTERN *win)
{
  if (win->hdc != NULL)
    {
      HGDIOBJ old = SelectObject(win->hdc, win->old);
      if (old != NULL)
        DeleteObject(old);
      DeleteDC(win->hdc);
      win->hdc = NULL;
      win->old = NULL;
    }
}
```

Then replace all duplicated cleanup patterns. For example in `resizeBackingStoreFor:` (lines 720-728):

```objc
// Old:
      old = SelectObject(win->hdc, win->old);
      DeleteObject(old);
      DeleteDC(win->hdc);
      win->hdc = NULL;
      win->old = NULL;

// New:
      _releaseGDIBackingStore(win);
```

Similarly in `windowbacking:` (lines 1712-1716) and any other locations found by grepping for `DeleteObject` + `DeleteDC` sequences.

**Verification:** Build libs-back on Windows. Verify GDI cleanup still works.

---

### Step 20: TS-G9 -- GSTextStorage static `adding` variable

**Finding:** GSTextStorage.m:60 -- Static `adding` global variable is used to switch between equality modes in the attribute cache. This is shared across all instances and threads.

**File:** `libs-gui/Source/GSTextStorage.m`

**Current code (lines 60-78):**
```objc
static BOOL     adding;

static inline BOOL
cacheEqual(id A, id B)
{
  if (YES == adding)
    return [A isEqualToDictionary: B];
  else
    return A == B;
}
```

**Fix:** Replace the static global with a thread-local or pass the mode as a parameter. The simplest fix is to make it thread-local:

```objc
static _Thread_local BOOL adding;
```

Or, more GNUstep-idiomatically, use the thread dictionary:

```objc
static NSString *GSTextStorageAddingKey = @"GSTextStorage_adding";

static inline BOOL
cacheEqual(id A, id B)
{
  if ([[[NSThread currentThread] threadDictionary]
        objectForKey: GSTextStorageAddingKey] != nil)
    return [A isEqualToDictionary: B];
  else
    return A == B;
}
```

However, `_Thread_local` is simpler and faster, and GCC/Clang both support it:

```objc
static _Thread_local BOOL adding;
```

**Verification:** Build libs-gui. Test text editing to verify attribute caching still works.

---

### Step 21: TS-B8 -- WIN32Server cursor statics

**Finding:** WIN32Server.m:79-81 -- Static `update_cursor` and `current_cursor` accessed from callback thread and main thread without synchronization.

**File:** `libs-back/Source/win32/WIN32Server.m`

**Current code (lines 79-81):**
```c
static BOOL update_cursor = NO;
static BOOL should_handle_cursor = NO;
static NSCursor *current_cursor = nil;
```

**Fix:** Since these are only used from the Windows message pump (which is single-threaded on Win32), add a documentation comment. If multi-threaded access is actually possible, use `@synchronized`:

```objc
/*
 * Cursor state -- accessed only from the Windows message loop thread.
 * If these need to be accessed from other threads in the future,
 * wrap with a lock.
 */
static BOOL update_cursor = NO;
static BOOL should_handle_cursor = NO;
static NSCursor *current_cursor = nil;
```

If evidence of cross-thread access exists (check grep for references), add a lock instead.

**Verification:** Build libs-back on Windows.

---

## Phase 5: Medium Findings (Steps 22-36)

### Step 22: TS-G10 -- _current_event multi-path assignment

**Finding:** NSApplication.m -- `_current_event` is assigned from multiple code paths (lines 1903, 2259, etc.) without synchronization.

**File:** `libs-gui/Source/NSApplication.m`

**Fix:** Since the event loop should only run on the main thread (enforced by Step 6), this is safe as long as the main-thread assertion is in place. Add a comment documenting this:

```objc
  /* _current_event is only assigned on the main thread (enforced by
   * the main-thread assertion in nextEventMatchingMask:). */
  if (flag)
    ASSIGN(_current_event, event);
```

**Verification:** No code change needed beyond the Step 6 assertion. Verify with a grep that all `ASSIGN(_current_event` are in methods called from the main thread.

---

### Step 23: TS-G11 -- setNeedsDisplay cross-thread DESTROY safety

**Finding:** NSView.m:2807-2822 -- `setNeedsDisplay:` allocates an NSNumber, performs a cross-thread dispatch, then calls `DESTROY(n)`. If the main thread hasn't yet retained the object, DESTROY could free it prematurely.

**File:** `libs-gui/Source/NSView.m`

**Current code (lines 2807-2822):**
```objc
- (void) setNeedsDisplay: (BOOL)flag
{
  NSNumber *n = [[NSNumber alloc] initWithBool: flag];
  if (GSCurrentThread() != GSAppKitThread)
    {
      [self performSelectorOnMainThread: @selector(_setNeedsDisplay_real:)
            withObject: n
            waitUntilDone: NO];
    }
  else
    {
      [self _setNeedsDisplay_real: n];
    }
  DESTROY(n);
}
```

**Fix:** This is actually safe because `performSelectorOnMainThread:withObject:waitUntilDone:` retains its arguments. But to make the intent clearer and eliminate any doubt, use autorelease instead:

```objc
- (void) setNeedsDisplay: (BOOL)flag
{
  NSNumber *n = [[[NSNumber alloc] initWithBool: flag] autorelease];
  if (GSCurrentThread() != GSAppKitThread)
    {
      NSDebugMLLog (@"MacOSXCompatibility", 
                    @"setNeedsDisplay: called on secondary thread");
      [self performSelectorOnMainThread: @selector(_setNeedsDisplay_real:)
            withObject: n
            waitUntilDone: NO];
    }
  else
    {
      [self _setNeedsDisplay_real: n];
    }
}
```

**Verification:** Build libs-gui.

---

### Step 24: TS-G12 -- Window event filtering for closed windows

**Finding:** NSWindow.m:4066-4069 -- Events to closed/invisible windows are filtered only for non-NSAppKitDefined types. Other event types may still reach closed windows.

**File:** `libs-gui/Source/NSWindow.m`

**Current code (lines 4066-4069):**
```objc
  if (!_f.visible && [theEvent type] != NSAppKitDefined)
    {
      NSDebugLLog(@"NSEvent", @"Discard (window not visible) %@", theEvent);
      return;
    }
```

**Fix:** Also check `_f.has_closed`:

```objc
  if (_f.has_closed)
    {
      NSDebugLLog(@"NSEvent", @"Discard (window has closed) %@", theEvent);
      return;
    }
  if (!_f.visible && [theEvent type] != NSAppKitDefined)
    {
      NSDebugLLog(@"NSEvent", @"Discard (window not visible) %@", theEvent);
      return;
    }
```

**Verification:** Build libs-gui. Test that no events reach windows after close.

---

### Step 25: TS-G13 -- Graphics context stack underflow

**Finding:** NSGraphicsContext.m:250-268 -- `restoreGraphicsState` raises an exception when the stack is nil, but if the stack is empty (not nil), `lastObject` returns nil and silently sets the current context to nil.

**File:** `libs-gui/Source/NSGraphicsContext.m`

**Current code (lines 250-268):**
```objc
+ (void) restoreGraphicsState
{
  NSGraphicsContext *ctxt;
  NSMutableDictionary *dict = [[NSThread currentThread] threadDictionary];
  NSMutableArray *stack = [dict objectForKey: NSGraphicsContextStackKey];

  if (stack == nil)
    {
      [NSException raise: NSGenericException
		   format: @"restoreGraphicsState without previous save"];
    }
  ctxt = [stack lastObject];
  [NSGraphicsContext setCurrentContext: ctxt];
  if (ctxt)
    {
      [stack removeLastObject];
      [ctxt restoreGraphicsState];
    }
}
```

**Fix:** Also check for empty stack:

```objc
+ (void) restoreGraphicsState
{
  NSGraphicsContext *ctxt;
  NSMutableDictionary *dict = [[NSThread currentThread] threadDictionary];
  NSMutableArray *stack = [dict objectForKey: NSGraphicsContextStackKey];

  if (stack == nil || [stack count] == 0)
    {
      [NSException raise: NSGenericException
		   format: @"restoreGraphicsState without previous save"];
    }
  ctxt = [stack lastObject];
  [stack removeLastObject];
  [NSGraphicsContext setCurrentContext: ctxt];
  if (ctxt)
    {
      [ctxt restoreGraphicsState];
    }
}
```

**Verification:** Build libs-gui. Test that mismatched save/restore raises an exception.

---

### Step 26: TS-G14 -- NSPasteboard changeCount atomicity

**Finding:** NSPasteboard.m:1781-1796 -- `changeCount` reads from the server and assigns to the ivar non-atomically.

**File:** `libs-gui/Source/NSPasteboard.m`

**Fix:** This is a cross-process value obtained via DO. The read-then-write pattern is inherently non-atomic, but the ivar assignment itself should be safe since `changeCount` is an `int`. Add a comment documenting this is intentionally racy (the server is the source of truth):

```objc
/**
 * Returns the change count for the receiving pasteboard.  This count
 * is incremented whenever the owner of the pasteboard is changed.
 * Note: The local ivar is a cache; the server's value is authoritative.
 */
- (int) changeCount
{
  NS_DURING
    {
      int	count;

      count = [target changeCount];
      changeCount = count;
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return changeCount;
}
```

**Verification:** No functional change, just documentation.

---

### Step 27: TS-G15 -- NSWindow main-thread documentation

**Finding:** NSWindow.m has zero locks in 171KB and no main-thread enforcement.

**Fix:** Add main-thread assertions to the key entry points. At minimum, add to `sendEvent:`:

```objc
- (void) sendEvent: (NSEvent *)theEvent
{
  NSAssert(GSCurrentThread() == GSAppKitThread,
           @"NSWindow sendEvent: called from non-main thread");
  // ... existing body ...
```

And to `makeKeyAndOrderFront:`:
```objc
- (void) makeKeyAndOrderFront: (id)sender
{
  NSAssert(GSCurrentThread() == GSAppKitThread,
           @"NSWindow makeKeyAndOrderFront: called from non-main thread");
```

**Verification:** Build libs-gui. Existing tests should pass since they run on the main thread.

---

### Step 28: RB-G3 -- NaN/Inf validation on geometry inputs

**Finding:** NSView.m:1184-1245 -- No validation for NaN/Inf on geometry inputs to `setFrame:`. NaN causes infinite notification loops.

**File:** `libs-gui/Source/NSView.m`

**Fix:** Add validation at the start of `setFrame:`:

```objc
- (void) setFrame: (NSRect)frameRect
{
  BOOL	changedOrigin = NO;
  BOOL	changedSize = NO;
  NSSize old_size = _frame.size;

  if (isnan(frameRect.origin.x) || isnan(frameRect.origin.y)
      || isnan(frameRect.size.width) || isnan(frameRect.size.height)
      || isinf(frameRect.origin.x) || isinf(frameRect.origin.y)
      || isinf(frameRect.size.width) || isinf(frameRect.size.height))
    {
      NSWarnMLog(@"setFrame: called with invalid rect %@; ignoring",
                 NSStringFromRect(frameRect));
      return;
    }

  if (frameRect.size.width < 0)
```

Also add the same validation to `setFrameSize:`, `setFrameOrigin:`, `setBounds:`, `setBoundsSize:`, `setBoundsOrigin:`.

**Verification:** Build libs-gui. Test that setting NaN frame does not crash.

---

### Step 29: RB-G4 -- NSNibOutletConnector ivar set without retain

**Finding:** NSNibOutletConnector.m:63-69 -- When a setter is not found, the outlet ivar is set directly via `object_setIvar` without retaining the destination object.

**File:** `libs-gui/Source/NSNibOutletConnector.m`

**Current code (lines 63-69):**
```objc
              const char *name = [_tag cString];
              Class class = object_getClass(_src);
              Ivar ivar = class_getInstanceVariable(class, name);

              if (ivar != 0)
                {
                  object_setIvar(_src, ivar, _dst);
                }
```

**Fix:** Retain the destination to match setter behavior:

```objc
              const char *name = [_tag cString];
              Class class = object_getClass(_src);
              Ivar ivar = class_getInstanceVariable(class, name);

              if (ivar != 0)
                {
                  /* Retain _dst since we are setting the ivar directly
                   * without going through a setter method. This matches
                   * the retain semantics of typical outlet properties. */
                  id oldValue = object_getIvar(_src, ivar);
                  RETAIN(_dst);
                  object_setIvar(_src, ivar, _dst);
                  RELEASE(oldValue);
                }
```

**Verification:** Build libs-gui. Test nib loading with outlets.

---

### Step 30: RB-G5 -- NSNibControlConnector selector validation

**Finding:** NSNibControlConnector.m:37-43 -- No validation that the selector string in `_tag` produces a valid selector. `NSSelectorFromString` on nil returns NULL.

**File:** `libs-gui/Source/NSNibControlConnector.m`

**Current code (lines 37-43):**
```objc
- (void) establishConnection
{
  SEL sel = NSSelectorFromString(_tag);

  [_src setTarget: _dst];
  [_src setAction: sel];
}
```

**Fix:** Validate the selector:

```objc
- (void) establishConnection
{
  SEL sel = NULL;

  if (_tag != nil && [_tag length] > 0)
    {
      sel = NSSelectorFromString(_tag);
    }

  if (sel == NULL)
    {
      NSWarnMLog(@"NSNibControlConnector: invalid or nil action tag '%@' "
                 @"for connection from %@ to %@", _tag, _src, _dst);
    }

  [_src setTarget: _dst];
  [_src setAction: sel];
}
```

**Verification:** Build libs-gui. Test nib loading.

---

### Step 31: RB-G6 + RB-G7 -- lockFocus early return / nil context

**Finding:** NSView.m:2561-2611 -- `_lockFocusInContext:` returns early when gState==0 (line 2116-2118) but the caller still calls `unlockFocusNeedsFlush:`, causing stack corruption. Also, no nil context check before DPS calls.

**File:** `libs-gui/Source/NSView.m`

**Fix:** Check the return value of `_lockFocusInContext:` or add a guard in `displayRectIgnoringOpacity:inContext:`. The simplest fix is to make `_lockFocusInContext:` return BOOL:

Since changing the method signature is invasive, instead add a check in the caller:

```objc
  if (NSIsEmptyRect(aRect) == NO)
    {
      /*
       * Check if focus can actually be locked (deferred windows
       * have gState == 0, and _lockFocusInContext: returns early).
       */
      if (viewIsPrinting == nil && _window != nil && [_window gState] == 0)
        {
          /* Deferred window -- skip drawing */
        }
      else if (context != nil || (viewIsPrinting == nil && [_window graphicsContext] != nil)
               || (viewIsPrinting != nil && [[NSPrintOperation currentOperation] context] != nil))
        {
          [self _lockFocusInContext: context inRect: aRect];
          NS_DURING
            {
              [self drawRect: aRect];
            }
          NS_HANDLER
            {
              NSLog(@"Exception in -[%@ drawRect:]: %@",
                    NSStringFromClass([self class]),
                    [localException reason]);
            }
          NS_ENDHANDLER
          [self unlockFocusNeedsFlush: flush];
        }
    }
```

**Verification:** Build libs-gui. Test with deferred windows.

---

### Step 32: RB-G8 -- Print operation cancellation

**Finding:** NSPrintOperation.m:939-1088 -- No cancellation mechanism during the print page loop. Once printing starts, there is no way to abort.

**File:** `libs-gui/Source/NSPrintOperation.m`

**Fix:** Add a cancellation check in the page loop:

```objc
  /* Print each page */
  i = 0;
  while (i < (info.last - info.first + 1))
    {
      NSRect pageRect;

      /* Check for cancellation */
      if ([self isCancelled])
        {
          NSDebugLLog(@"NSPrinting", @"Print operation cancelled at page %d",
                      _currentPage);
          break;
        }

      if (knowsPageRange == YES)
```

If `isCancelled` does not exist on NSPrintOperation, add it:

```objc
// In the @interface or class extension:
@interface NSPrintOperation (Private)
- (BOOL) isCancelled;
- (void) cancel;
@end

// Implementation:
- (BOOL) isCancelled
{
  return _isCancelled;
}

- (void) cancel
{
  _isCancelled = YES;
}
```

Add `BOOL _isCancelled;` to the instance variables.

**Verification:** Build libs-gui.

---

### Step 33: RB-B6 -- Wayland titlewindow string comparison bug

**Finding:** WaylandServer.m:482 -- String comparison uses `==` instead of `isEqualToString:`.

**File:** `libs-back/Source/wayland/WaylandServer.m`

**Current code (line 482):**
```objc
  if (window_title == @"Window")
    {
      return;
    }
```

**Fix:**
```objc
  if ([window_title isEqualToString: @"Window"])
    {
      return;
    }
```

**Verification:** Build libs-back.

---

### Step 34: RB-B7 -- Headless backend runtime fallback

**Finding:** GSBackend.m:53-57 -- Headless backend is compile-time only (`#if BUILD_SERVER == SERVER_headless`), not a runtime fallback when no display is available.

**File:** `libs-back/Source/GSBackend.m`

**Fix:** Add a runtime fallback. After the server initialization block, check if the server was successfully created. If not, attempt headless:

```objc
+ (void) initializeBackend
{
  Class           contextClass;
  NSString       *context = nil;
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];

  /* Check for explicit headless mode request */
  if ([defs boolForKey: @"GSHeadless"])
    {
      Class headlessClass = NSClassFromString(@"HeadlessServer");
      if (headlessClass != nil)
        {
          [headlessClass initializeBackend];
          context = @"HeadlessContext";
          goto setup_context;
        }
    }

  /* Load in only one server */
#if BUILD_SERVER == SERVER_x11
  [XGServer initializeBackend];
#elif BUILD_SERVER == SERVER_win32
  [WIN32Server initializeBackend];
#elif BUILD_SERVER == SERVER_wayland
  [WaylandServer initializeBackend];
#elif BUILD_SERVER == SERVER_headless
  [HeadlessServer initializeBackend];
#else
  [NSException raise: NSInternalInconsistencyException
	       format: @"No Window Server configured in backend"];
#endif

setup_context:
  /* What backend context? */
  // ... existing context selection code ...
```

**Note:** Full runtime fallback would require the headless backend to be compiled into all builds, which is a larger change. The GSHeadless default is a pragmatic first step.

**Verification:** Build libs-back.

---

### Step 35: RB-G9 -- Unknown event type handling

**Finding:** NSApplication.m:2124-2174 -- The default case in `sendEvent:` handles unknown event types by sending to the event's window. If window is nil and event type is not `NSRightMouseDown`, the event is silently dropped.

**File:** `libs-gui/Source/NSApplication.m`

**Fix:** Add debug logging for dropped events:

```objc
      default:
	{
	  NSWindow *window = [theEvent window];

	  if (!theEvent)
	    NSDebugLLog(@"NSEvent", @"NSEvent is nil!\n");
	  if (type == NSMouseMoved)
	    NSDebugLLog(@"NSMotionEvent", @"Send move (%d) to %@", 
			(int)type, window);
	  else
	    NSDebugLLog(@"NSEvent", @"Send NSEvent type: %@ to %@", 
			theEvent, window);
	  if (window)
	    [window sendEvent: theEvent];
	  else if (type == NSRightMouseDown)
	    [self rightMouseDown: theEvent];
	  else
	    NSDebugLLog(@"NSEvent", @"Discarding event %@ with no target window",
	                theEvent);
	}
```

**Verification:** Build libs-gui.

---

### Step 36: TS-G13 (additional) + PF-5 -- NSNumber allocation per setNeedsDisplay

**Note:** PF-5 is a performance finding (not in the 36 fixes), but the fix is trivial and pairs with Step 23.

**Already addressed in Step 23** by using autorelease. For the perf angle, use cached NSNumber values:

```objc
- (void) setNeedsDisplay: (BOOL)flag
{
  /* NSNumber caches YES/NO values, so [NSNumber numberWithBool:] is efficient */
  NSNumber *n = [NSNumber numberWithBool: flag];
  if (GSCurrentThread() != GSAppKitThread)
    {
      NSDebugMLLog (@"MacOSXCompatibility", 
                    @"setNeedsDisplay: called on secondary thread");
      [self performSelectorOnMainThread: @selector(_setNeedsDisplay_real:)
            withObject: n
            waitUntilDone: NO];
    }
  else
    {
      [self _setNeedsDisplay_real: n];
    }
}
```

This uses `numberWithBool:` which returns cached singleton NSNumber instances for YES and NO, avoiding heap allocation entirely.

**Verification:** Build libs-gui.

---

## Execution Order Summary

| Phase | Steps | Focus | Risk |
|-------|-------|-------|------|
| 1 | 1-5 | libs-back critical: thread safety, XIOError, Wayland leaks | Medium -- touches X11/Wayland primitives |
| 2 | 6-8 | libs-gui critical: main thread assertions, view safety, layout manager | High -- layout manager lock is invasive |
| 3 | 9-14 | High: modal session lock, CairoGState, XWindowBuffer, expose race, window close | Medium |
| 4 | 15-21 | High: NSImage lock, focus stack, division-by-zero, nib fallback, GDI cleanup | Low-Medium |
| 5 | 22-36 | Medium: documentation, validation, string comparison, print cancel, etc. | Low |

## Testing Strategy

1. **libs-back has zero tests.** Each Phase 1-3 fix should be manually tested by:
   - Building the backend
   - Running a simple GNUstep app (e.g., `gopen` or `Gorm`)
   - Verifying basic window creation, drawing, resizing, and closing work

2. **libs-gui tests** exist in `Tests/gui/`. Run the full suite after each phase:
   ```bash
   cd libs-gui && make check
   ```

3. **Thread safety validation** -- for Steps 1, 8, 9, 11: stress-test with concurrent operations if possible (e.g., rapidly creating/destroying windows from background threads).

4. **Memory leak validation** -- for Steps 3, 5, 12: run under valgrind or AddressSanitizer.
