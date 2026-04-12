# Graphics Layer (libs-opal + libs-quartzcore) Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans

**Goal:** Fix 30 findings across libs-opal (14) and libs-quartzcore (16) — 6 Critical, 9 High, 10 Medium, 5 Low

**Architecture:** Fix crashes and bugs first, then add thread confinement assertions, then robustness, then performance.

**Tech Stack:** Objective-C, C. Build: GNUstep Make. Test: Tests/ directories.

**Repos:**
- `C:\Users\toddw\source\repos\gnustep-audit\libs-opal`
- `C:\Users\toddw\source\repos\gnustep-audit\libs-quartzcore`

**Findings reference:** `C:\Users\toddw\source\repos\gnustep-audit\docs\phase4-graphics-findings.md`

---

## Phase 1: Critical Crash Fixes (6 items)

### Step 1 — AR-O2: CGContext fill_path NULL deref in error logging
**File:** `libs-opal/Source/OpalGraphics/CGContext.m` lines 816-824
**Problem:** When `ctx` is NULL, the NSLog format string evaluates `!ctx->add` and `(!ctx && !ctx->add)`, both of which dereference the NULL `ctx` pointer. This is a guaranteed crash in what is supposed to be an error-handling path.

**Current code:**
```objc
static void fill_path(CGContextRef ctx, int eorule, int preserve)
{
  cairo_status_t cret;
  
  if(!ctx || !ctx->add)
    {
      NSLog(@"null %s%s%s in %s",
            !ctx ? "ctx" : "",
            (!ctx && !ctx->add) ? " and " : "", 
            !ctx->add ? "ctx->add" : "",
            __PRETTY_FUNCTION__);
      return;
    }
```

**Fix:** Restructure the NSLog to never dereference `ctx` when it is NULL:
```objc
static void fill_path(CGContextRef ctx, int eorule, int preserve)
{
  cairo_status_t cret;
  
  if(!ctx)
    {
      NSLog(@"null ctx in %s", __PRETTY_FUNCTION__);
      return;
    }
  if(!ctx->add)
    {
      NSLog(@"null ctx->add in %s", __PRETTY_FUNCTION__);
      return;
    }
```

**Verify:** Grep for identical pattern `(!ctx && !ctx->add)` in `stroke_path` (around line 788) and fix the same way. Both `stroke_path` and `fill_path` have this pattern.

---

### Step 2 — AR-O7: TIFF destination init condition inverted
**File:** `libs-opal/Source/OpalGraphics/image/OPImageCodecTIFF.m` line 337
**Problem:** The condition `[type isEqualToString: @"public.tiff"] || count != 1` means it rejects valid TIFF requests (type matches OR count is wrong). It should accept when type matches AND count is valid.

**Current code:**
```objc
- (id) initWithDataConsumer: (CGDataConsumerRef)consumer
                       type: (CFStringRef)type
                      count: (size_t)count
                    options: (CFDictionaryRef)opts
{
  self = [super init];
  
  if ([type isEqualToString: @"public.tiff"] || count != 1)
  {
    [self release];
    return nil;
  }
```

**Fix:** Negate the type check and use `||` (reject when type does NOT match OR count is wrong):
```objc
  if (![type isEqualToString: @"public.tiff"] || count != 1)
  {
    [self release];
    return nil;
  }
```

**Note:** Compare with `CGImageDestinationJPEG` at OPImageCodecJPEG.m:558 which uses `![(NSString*)type isEqual: @"public.jpeg"] || count != 1` — the correct pattern.

---

### Step 3 — AR-Q4: CAGLTexture divide-by-zero on alpha=0
**File:** `libs-quartzcore/Source/GLHelpers/CAGLTexture.m` lines 207-217
**Problem:** The unpremultiply loop divides by `data[i+3]/255.0` which is zero when alpha is 0, producing Inf/NaN pixel values that corrupt textures.

**Current code:**
```objc
  uint8_t * data = CGBitmapContextGetData(context);
  for(int i=0; i < bytesPerRow * height; i+=4)
    {
      #if !(GNUSTEP)
      /* let's undo premultiplication */
      for(int j=0; j<3; j++)
        {
          data[i+j] = data[i+j] / (data[i+3]/255.);
        }
      #endif
    }
```

**Fix:** Skip unpremultiply when alpha is 0 (fully transparent pixels have undefined color, so leave them as-is):
```objc
  uint8_t * data = CGBitmapContextGetData(context);
  for(int i=0; i < bytesPerRow * height; i+=4)
    {
      #if !(GNUSTEP)
      /* Undo premultiplication; skip fully transparent pixels to avoid division by zero */
      uint8_t alpha = data[i+3];
      if (alpha > 0 && alpha < 255)
        {
          double alphaFrac = alpha / 255.0;
          for(int j=0; j<3; j++)
            {
              double val = data[i+j] / alphaFrac;
              data[i+j] = (uint8_t)(val > 255.0 ? 255 : val);
            }
        }
      /* alpha == 255: already correct (premultiplied by 1.0) */
      /* alpha == 0: color channels are irrelevant, skip */
      #endif
    }
```

---

### Step 4 — TS-O1 + TS-O2: CGContext thread confinement assertion
**Files:**
- `libs-opal/Source/OpalGraphics/CGContext-private.h` lines 52-60
- `libs-opal/Source/OpalGraphics/CGContext.m` (init, and all public drawing functions)

**Problem:** All CGContext fields are `@public` with zero thread protection. CGContexts are not thread-safe by design (same as Apple's CoreGraphics), but there is no enforcement.

**Fix:** Add a debug-mode thread-confinement assertion. Store the creating thread's ID and assert on each operation.

**In CGContext-private.h**, add field to the class:
```objc
#include <pthread.h>

/* Debug thread confinement check */
#if !defined(NDEBUG)
#define OPAL_THREAD_CONFINEMENT_CHECK(ctx) \
  do { \
    if ((ctx) && !pthread_equal((ctx)->_ownerThread, pthread_self())) { \
      NSLog(@"WARNING: CGContext %p used from thread %p but owned by %p in %s", \
            (ctx), (void*)pthread_self(), (void*)(ctx)->_ownerThread, __PRETTY_FUNCTION__); \
    } \
  } while(0)
#else
#define OPAL_THREAD_CONFINEMENT_CHECK(ctx) ((void)0)
#endif

@interface CGContext : NSObject
{
@public
  cairo_t *ct;
  ct_additions *add;
  CGAffineTransform txtmatrix;
  CGFloat scale_factor;
  CGSize device_size;
#if !defined(NDEBUG)
  pthread_t _ownerThread;
#endif
}
```

**In CGContext.m** `initWithSurface:size:`, after `self = [super init]`:
```objc
#if !defined(NDEBUG)
  self->_ownerThread = pthread_self();
#endif
```

**In CGContext.m**, add `OPAL_THREAD_CONFINEMENT_CHECK(ctx)` as the first line in all public `CGContext*` functions. For example, in `CGContextSaveGState`:
```objc
void CGContextSaveGState(CGContextRef ctx)
{
  OPAL_THREAD_CONFINEMENT_CHECK(ctx);
  // ... existing code ...
```

Apply to: `CGContextSaveGState`, `CGContextRestoreGState`, `CGContextSetLineWidth`, `CGContextSetLineCap`, `CGContextSetLineJoin`, `CGContextSetMiterLimit`, `CGContextSetLineDash`, `CGContextSetFlatness`, all `CGContextStroke*`, `CGContextFill*`, `CGContextClip*`, `CGContextDraw*`, `CGContextSetFill*`, `CGContextSetStroke*`, etc. — all public functions taking a `CGContextRef`.

---

### Step 5 — TS-Q1: CATransaction global stack unprotected
**File:** `libs-quartzcore/Source/CATransaction.m` lines 38, 58-76
**Problem:** `static NSMutableArray *transactionStack` is modified from `+begin`, `+commit`, `+topTransaction` without any locking. The `+lock` and `+unlock` methods are stubs that just NSLog "unimplemented".

**Current code:**
```objc
static NSMutableArray *transactionStack = nil;

+ (void) begin
{
  if (!transactionStack)
    {
      transactionStack = [NSMutableArray new];
    }
  CATransaction *newTransaction = [CATransaction new];
  [transactionStack addObject: newTransaction];
  [newTransaction release];
}

+ (void) commit
{
  CATransaction *topTransaction = [self topTransaction];
  [topTransaction commit];
  [transactionStack removeObjectAtIndex: [transactionStack count]-1];
}
```

**Fix:** Add a static NSLock and wrap all transactionStack access:
```objc
static NSMutableArray *transactionStack = nil;
static NSLock *transactionStackLock = nil;

+ (void) initialize
{
  if (self == [CATransaction class])
    {
      transactionStackLock = [NSLock new];
    }
}

+ (void) begin
{
  [transactionStackLock lock];
  if (!transactionStack)
    {
      transactionStack = [NSMutableArray new];
    }

  CATransaction *newTransaction = [CATransaction new];
  [transactionStack addObject: newTransaction];
  [newTransaction release];
  [transactionStackLock unlock];
}

+ (void) commit
{
  [transactionStackLock lock];
  CATransaction *topTransaction = [self topTransaction];
  [topTransaction commit];
  [transactionStack removeObjectAtIndex: [transactionStack count]-1];
  [transactionStackLock unlock];
}

+ (void) lock
{
  [transactionStackLock lock];
}

+ (void) unlock
{
  [transactionStackLock unlock];
}
```

Also wrap `+topTransaction` similarly:
```objc
+ (CATransaction *) topTransaction
{
  /* Note: caller should already hold transactionStackLock in most cases,
     but if called standalone (from +animationDuration etc.), we lock here.
     NSLock is NOT recursive, so use tryLock to avoid deadlock when already held. */
  BOOL didLock = [transactionStackLock tryLock];
  if(![transactionStack lastObject])
    {
      if (didLock) [transactionStackLock unlock];
      [CATransaction begin];
      [transactionStackLock lock];
      [[transactionStack lastObject] setImplicit: YES];
      didLock = YES;
    }

  CATransaction *top = [transactionStack lastObject];
  if (didLock) [transactionStackLock unlock];
  return top;
}
```

**Alternative (simpler):** Use `NSRecursiveLock` instead to avoid the tryLock complexity:
```objc
static NSRecursiveLock *transactionStackLock = nil;
```
Then wrap every method body with `[transactionStackLock lock]` / `[transactionStackLock unlock]`.

---

### Step 6 — TS-Q2: CALayer sublayers mutated without sync
**File:** `libs-quartzcore/Source/CALayer.m` lines 841-881
**Problem:** `addSublayer:`, `removeFromSuperlayer`, `insertSublayer:atIndex:`, `insertSublayer:below:`, `insertSublayer:above:` all mutate `_sublayers` without synchronization. Meanwhile, CARenderer iterates sublayers in `_renderLayer:withTransform:` and `_updateLayer:atTime:`.

**Current code:**
```objc
- (void) addSublayer: (CALayer *)layer
{
  NSMutableArray * mutableSublayers = (NSMutableArray*)_sublayers;
  [mutableSublayers addObject: layer];
  [layer setSuperlayer: self];
}
```

**Fix:** Use `@synchronized(self)` on all sublayer mutation methods, and snapshot sublayers for iteration:

```objc
- (void) addSublayer: (CALayer *)layer
{
  @synchronized(self)
  {
    NSMutableArray * mutableSublayers = (NSMutableArray*)_sublayers;
    [mutableSublayers addObject: layer];
    [layer setSuperlayer: self];
  }
}

- (void)removeFromSuperlayer
{
  CALayer *sup = [self superlayer];
  @synchronized(sup)
  {
    NSMutableArray * mutableSublayersOfSuperlayer = (NSMutableArray*)[sup sublayers];
    [mutableSublayersOfSuperlayer removeObject: self];
    [self setSuperlayer: nil];
  }
}

- (void) insertSublayer: (CALayer *)layer atIndex: (unsigned)index
{
  @synchronized(self)
  {
    NSMutableArray * mutableSublayers = (NSMutableArray*)_sublayers;
    [mutableSublayers insertObject: layer atIndex: index];
    [layer setSuperlayer: self];
  }
}

- (void) insertSublayer: (CALayer *)layer below: (CALayer *)sibling
{
  @synchronized(self)
  {
    NSMutableArray * mutableSublayers = (NSMutableArray*)_sublayers;
    NSInteger siblingIndex = [mutableSublayers indexOfObject: sibling];
    if (siblingIndex == NSNotFound)
      {
        NSLog(@"%s: sibling not found in sublayers", __PRETTY_FUNCTION__);
        return;
      }
    [mutableSublayers insertObject: layer atIndex: siblingIndex];
    [layer setSuperlayer: self];
  }
}

- (void) insertSublayer: (CALayer *)layer above: (CALayer *)sibling
{
  @synchronized(self)
  {
    NSMutableArray * mutableSublayers = (NSMutableArray*)_sublayers;
    NSInteger siblingIndex = [mutableSublayers indexOfObject: sibling];
    if (siblingIndex == NSNotFound)
      {
        NSLog(@"%s: sibling not found in sublayers", __PRETTY_FUNCTION__);
        return;
      }
    [mutableSublayers insertObject: layer atIndex: siblingIndex + 1];
    [layer setSuperlayer: self];
  }
}
```

**In CARenderer.m**, snapshot sublayers before iterating (in `_updateLayer:atTime:` and `_renderLayer:withTransform:`):
```objc
  /* Tell all children to update themselves. */
  NSArray *sublayersCopy;
  @synchronized(layer)
  {
    sublayersCopy = [[layer sublayers] copy];
  }
  for (CALayer * sublayer in sublayersCopy)
    {
      [self _updateLayer: sublayer
                  atTime: theTime];
    }
  [sublayersCopy release];
```

Same pattern for `_renderLayer:withTransform:` near its sublayer iteration at the end.

---

## Phase 2: High Severity Fixes (9 items)

### Step 7 — AR-O8: CGContext+GState dash buffer under-allocation
**File:** `libs-opal/Source/OpalGraphics/CGContext+GState.m` line 88
**Problem:** `malloc(dashes_count)` allocates `dashes_count` bytes, but `cairo_get_dash` writes `dashes_count` doubles (8 bytes each). Heap buffer overflow.

**Current code:**
```objc
  dashes_count = cairo_get_dash_count(aCairo);
  if (dashes_count > 0)
  {
    dashes = malloc(dashes_count);
    
    if (dashes != NULL)
      {
        cairo_get_dash(aCairo, dashes, &dashes_offset);
      }
  }
```

**Fix:**
```objc
  dashes_count = cairo_get_dash_count(aCairo);
  if (dashes_count > 0)
  {
    dashes = malloc(dashes_count * sizeof(double));
    
    if (dashes != NULL)
      {
        cairo_get_dash(aCairo, dashes, &dashes_offset);
      }
  }
```

---

### Step 8 — AR-O1: No NaN/Inf validation on CGPath coordinates
**File:** `libs-opal/Source/OpalGraphics/CGPath.m` (all `CGPathAddLineToPoint`, `CGPathMoveToPoint`, `CGPathAddCurveToPoint`, `CGPathAddQuadCurveToPoint` functions)
**Problem:** NaN/Inf coordinates silently corrupt paths, producing invisible rendering bugs or crashes in Cairo.

**Fix:** Add a validation macro and use it in all path-add functions. Add near the top of the file:

```objc
#include <math.h>

static inline bool _OPPointIsValid(CGFloat x, CGFloat y)
{
  return !(isnan(x) || isnan(y) || isinf(x) || isinf(y));
}

#define OPPATH_VALIDATE_POINT(x, y) \
  do { \
    if (!_OPPointIsValid(x, y)) { \
      NSLog(@"%s: invalid coordinate (%g, %g)", __PRETTY_FUNCTION__, (double)(x), (double)(y)); \
      return; \
    } \
  } while(0)
```

Then add at the start of each function:

In `CGPathMoveToPoint`:
```objc
void CGPathMoveToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x, CGFloat y)
{
  OPPATH_VALIDATE_POINT(x, y);
  // ... existing code ...
```

In `CGPathAddLineToPoint`:
```objc
void CGPathAddLineToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x, CGFloat y)
{
  OPPATH_VALIDATE_POINT(x, y);
  // ... existing code ...
```

In `CGPathAddCurveToPoint`:
```objc
void CGPathAddCurveToPoint(CGMutablePathRef path, const CGAffineTransform *m,
  CGFloat cp1x, CGFloat cp1y, CGFloat cp2x, CGFloat cp2y, CGFloat x, CGFloat y)
{
  OPPATH_VALIDATE_POINT(cp1x, cp1y);
  OPPATH_VALIDATE_POINT(cp2x, cp2y);
  OPPATH_VALIDATE_POINT(x, y);
  // ... existing code ...
```

In `CGPathAddQuadCurveToPoint`:
```objc
void CGPathAddQuadCurveToPoint(CGMutablePathRef path, const CGAffineTransform *m,
  CGFloat cpx, CGFloat cpy, CGFloat x, CGFloat y)
{
  OPPATH_VALIDATE_POINT(cpx, cpy);
  OPPATH_VALIDATE_POINT(x, y);
  // ... existing code ...
```

---

### Step 9 — AR-O3: GState restore underflow
**File:** `libs-opal/Source/OpalGraphics/CGContext.m` lines 341-370
**Problem:** When restore produces NULL `ctx->add`, it logs a warning but continues. Subsequent draws dereference `ctx->add->fill_color` etc., crashing.

**Current code:**
```objc
void CGContextRestoreGState(CGContextRef ctx)
{
  // ... releases current add, sets ctx->add = ctadd->next ...
  
  if(!ctx->add)
    {
      NSLog(@"%s(%p): restoring produced null 'ct_additions'", __FUNCTION__, ctx);
    }

  cairo_restore(ctx->ct);
}
```

**Fix:** Add early return to prevent use of NULL add:
```objc
void CGContextRestoreGState(CGContextRef ctx)
{
  OPAL_THREAD_CONFINEMENT_CHECK(ctx);
  OPLOGCALL("ctx /*%p*/", ctx)
  OPRESTORELOGGING()
  ct_additions *ctadd;
  
  if (!ctx)
    {
      NSLog(@"%s: ctx == NULL", __PRETTY_FUNCTION__);
      OPRESTORELOGGING();
      return;
    }

  if (!ctx->add)
    {
      NSLog(@"%s(%p): GState stack underflow — no state to restore", __FUNCTION__, ctx);
      return;
    }

  CGColorRelease(ctx->add->fill_color);
  cairo_pattern_destroy(ctx->add->fill_cp);
  CGColorRelease(ctx->add->stroke_color);
  cairo_pattern_destroy(ctx->add->stroke_cp);
  ctadd = ctx->add->next;
  free(ctx->add);
  ctx->add = ctadd;

  if(!ctx->add)
    {
      NSLog(@"%s(%p): GState stack underflow — restoring produced null 'ct_additions'; further drawing ops will be no-ops", __FUNCTION__, ctx);
      /* Do NOT return here — still call cairo_restore to keep cairo in sync.
         But subsequent drawing operations will early-return due to NULL add. */
    }

  cairo_restore(ctx->ct);
}
```

---

### Step 10 — AR-O6: TIFF handle unchecked read beyond buffer
**File:** `libs-opal/Source/OpalGraphics/image/OPImageCodecTIFF.m` lines 83-88
**Problem:** `[data getBytes:buf range:NSMakeRange(pos, count)]` does not check if `pos + count` exceeds `[data length]`, which throws an `NSRangeException` that propagates into libtiff and corrupts its state.

**Current code:**
```objc
- (size_t) read: (unsigned char *)buf count: (size_t)count
{
  [data getBytes: buf range: NSMakeRange(pos, count)];
  pos += count;
  return count;
}
```

**Fix:** Clamp the read to available data:
```objc
- (size_t) read: (unsigned char *)buf count: (size_t)count
{
  NSUInteger available = [data length];
  if (pos >= (off_t)available)
    return 0;
  size_t canRead = (size_t)(available - pos);
  if (canRead > count)
    canRead = count;
  [data getBytes: buf range: NSMakeRange(pos, canRead)];
  pos += canRead;
  return canRead;
}
```

---

### Step 11 — AR-Q1: CALayer activeTime assert crashes on valid input
**File:** `libs-quartzcore/Source/CALayer.m` line 935
**Problem:** `assert(activeTime > 0)` fires for layers with future `beginTime` (activeTime can legitimately be <= 0 before the layer starts).

**Current code:**
```objc
- (CFTimeInterval) activeTimeWithTimeAuthorityLocalTime: (CFTimeInterval)timeAuthorityLocalTime
{
  CFTimeInterval activeTime = (timeAuthorityLocalTime - [self beginTime]) * [self speed] + [self timeOffset];
  assert(activeTime > 0);
  return activeTime;
}
```

**Fix:** Replace assert with clamp to 0:
```objc
- (CFTimeInterval) activeTimeWithTimeAuthorityLocalTime: (CFTimeInterval)timeAuthorityLocalTime
{
  CFTimeInterval activeTime = (timeAuthorityLocalTime - [self beginTime]) * [self speed] + [self timeOffset];
  if (activeTime < 0)
    activeTime = 0;
  return activeTime;
}
```

---

### Step 12 — AR-Q2: No circular parent-child protection
**File:** `libs-quartzcore/Source/CALayer.m` lines 841-847
**Problem:** `addSublayer:` allows adding an ancestor as a sublayer, creating a cycle that causes infinite recursion during rendering.

**Fix:** Add ancestor check in `addSublayer:` (inside the `@synchronized` block from Step 6):
```objc
- (void) addSublayer: (CALayer *)layer
{
  if (layer == nil)
    return;
  if (layer == self)
    {
      NSLog(@"%s: cannot add layer as sublayer of itself", __PRETTY_FUNCTION__);
      return;
    }
  /* Check for cycles: walk ancestors of self to ensure layer is not one of them */
  CALayer *ancestor = self;
  while ((ancestor = [ancestor superlayer]) != nil)
    {
      if (ancestor == layer)
        {
          NSLog(@"%s: refusing to add ancestor layer %@ as sublayer (would create cycle)",
                __PRETTY_FUNCTION__, layer);
          return;
        }
    }
  @synchronized(self)
  {
    /* Remove from old parent first */
    if ([layer superlayer] != nil)
      [layer removeFromSuperlayer];
    NSMutableArray * mutableSublayers = (NSMutableArray*)_sublayers;
    [mutableSublayers addObject: layer];
    [layer setSuperlayer: self];
  }
}
```

Apply the same cycle check to `insertSublayer:atIndex:`, `insertSublayer:below:`, `insertSublayer:above:`.

---

### Step 13 — AR-Q6: VLA stack overflow in _writeToPNG
**File:** `libs-quartzcore/Source/GLHelpers/CAGLTexture.m` lines 255-258
**Problem:** `char pixels[[self width]*[self height]*4]` is a VLA on the stack. A 1024x1024 texture = 4MB, easily overflowing the typical 1-2MB stack.

**Current code:**
```objc
- (void) _writeToPNG:(NSString*)path
{
  char pixels[[self width]*[self height]*4];
  [self bind];
  glGetTexImage([self textureTarget], 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
```

**Fix:** Use heap allocation:
```objc
- (void) _writeToPNG:(NSString*)path
{
  size_t bufSize = (size_t)[self width] * (size_t)[self height] * 4;
  char *pixels = (char *)malloc(bufSize);
  if (!pixels)
    {
      NSLog(@"%@: Failed to allocate %zu bytes for pixel buffer", NSStringFromSelector(_cmd), bufSize);
      return;
    }
  [self bind];
  glGetTexImage([self textureTarget], 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);

  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
  CGContextRef context = CGBitmapContextCreate(pixels, [self width], [self height], 8, [self width]*4, colorSpace, kCGImageAlphaPremultipliedLast);
  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  CGColorSpaceRelease(colorSpace);

  NSMutableData * data = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)data, (CFStringRef)@"public.png", 1, NULL);
  CGImageDestinationAddImage(destination, image, NULL);
  CGImageDestinationFinalize(destination);
  CGImageRelease(image);

  [data writeToFile:path atomically:YES];
  free(pixels);
}
```

---

### Step 14 — TS-Q3: GL context no thread affinity
**File:** `libs-quartzcore/Source/CARenderer.m` line 253
**Problem:** `[_GLContext makeCurrentContext]` is called in `render` without verifying it is called from the same thread that created it. OpenGL contexts are thread-bound.

**Fix:** Add a thread ID field to CARenderer and assert on it:

In `CARenderer.m`, add to the `@interface CARenderer()`:
```objc
#include <pthread.h>

@interface CARenderer()
// ... existing properties ...
@end

// Add an ivar or use an associated object. Simplest: instance variable.
```

Since we cannot add ivars to an existing category easily, use the `initWithNSOpenGLContext:options:` method:

```objc
// At the top of the file, after includes
#include <pthread.h>
#import <objc/runtime.h>

static const void *kCARendererOwnerThreadKey = &kCARendererOwnerThreadKey;

// In initWithNSOpenGLContext:options:, at end of if block:
      objc_setAssociatedObject(self, kCARendererOwnerThreadKey,
        [NSValue valueWithPointer:(void*)pthread_self()],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
```

Then in `-render` and `-beginFrameAtTime:timeStamp:`:
```objc
- (void) render
{
#if !defined(NDEBUG)
  {
    NSValue *ownerVal = objc_getAssociatedObject(self, kCARendererOwnerThreadKey);
    pthread_t owner = (pthread_t)[ownerVal pointerValue];
    if (!pthread_equal(owner, pthread_self()))
      {
        NSLog(@"WARNING: CARenderer %p render called from wrong thread", self);
      }
  }
#endif

  /* existing code ... */
```

---

### Step 15 — TS-Q4: Static currentFrameBeginTime shared
**File:** `libs-quartzcore/Source/CALayer.m` line 47-48
**Problem:** `static CFTimeInterval currentFrameBeginTime = 0` is a file-scope global shared by all layers across all threads/renderers.

**Current code:**
```objc
static CFTimeInterval currentFrameBeginTime = 0;
```

**Fix:** Make it a thread-local variable using `__thread` or `_Thread_local` (C11):
```objc
static _Thread_local CFTimeInterval currentFrameBeginTime = 0;
```

If the compiler does not support `_Thread_local`, use GCC's `__thread`:
```objc
static __thread CFTimeInterval currentFrameBeginTime = 0;
```

This ensures each rendering thread sees its own frame time.

---

## Phase 3: Medium Severity Fixes (10 items)

### Step 16 — TS-O3: Static default_cp init race
**File:** `libs-opal/Source/OpalGraphics/CGContext.m` lines 39, 76-79
**Problem:** `default_cp` is lazily initialized in `initWithSurface:size:` without any locking. Two threads creating CGContexts simultaneously race on the check and `cairo_pattern_reference`.

**Current code:**
```objc
static cairo_pattern_t *default_cp;

// In initWithSurface:size:
  if (!default_cp) {
    default_cp = cairo_get_source(self->ct);
    cairo_pattern_reference(default_cp);
  }
```

**Fix:** Use `dispatch_once` or `+initialize`:
```objc
#include <dispatch/dispatch.h>

// In initWithSurface:size: replace the if-block:
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    default_cp = cairo_get_source(self->ct);
    cairo_pattern_reference(default_cp);
  });
```

If `dispatch/dispatch.h` is unavailable under GNUstep, use `pthread_once`:
```objc
#include <pthread.h>

static pthread_once_t default_cp_once = PTHREAD_ONCE_INIT;
static cairo_t *_init_ct_for_default_cp = NULL;

static void _init_default_cp(void)
{
  default_cp = cairo_get_source(_init_ct_for_default_cp);
  cairo_pattern_reference(default_cp);
}

// In initWithSurface:size:
  _init_ct_for_default_cp = self->ct;
  pthread_once(&default_cp_once, _init_default_cp);
```

---

### Step 17 — TS-O5: Mutable CGPath realloc without sync
**File:** `libs-opal/Source/OpalGraphics/OPPath.m` lines 220-250
**Problem:** `CGMutablePath`'s `addElementWithType:points:` uses `realloc` on `_elementsArray`. If a path is shared across threads and mutated, this is a use-after-free.

**Fix:** This matches Apple's behavior: CGMutablePath is not thread-safe. Add a debug assertion similar to CGContext:

```objc
// In OPPath.h, add to CGMutablePath:
@interface CGMutablePath : CGPath
{
  NSUInteger _capacity;
#if !defined(NDEBUG)
  pthread_t _ownerThread;
#endif
}
```

In `CGMutablePath` init (add an init override in OPPath.m):
```objc
- (id) init
{
  self = [super init];
#if !defined(NDEBUG)
  _ownerThread = pthread_self();
#endif
  return self;
}
```

In `addElementWithType:points:`:
```objc
- (void) addElementWithType: (CGPathElementType)type points: (CGPoint[])points
{
#if !defined(NDEBUG)
  if (!pthread_equal(_ownerThread, pthread_self()))
    {
      NSLog(@"WARNING: CGMutablePath %p mutated from wrong thread", self);
    }
#endif
  // ... existing code ...
```

---

### Step 18 — AR-O4: JPEG imgbuffer memory leak on truncated JPEG
**File:** `libs-opal/Source/OpalGraphics/image/OPImageCodecJPEG.m` lines 382-498
**Problem:** In `createImageAtIndex:options:`, if the JPEG decompression throws an exception via longjmp/NS_HANDLER, the `imgbuffer` allocated at line 428 is leaked because cleanup only happens in the NS_HANDLER block for the source manager, not for imgbuffer.

**Current code (NS_HANDLER block):**
```objc
  NS_HANDLER
  {
    gs_jpeg_memory_src_destroy(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    NS_VALUERETURN(NULL, CGImageRef);
  }
  NS_ENDHANDLER
```

**Fix:** The imgbuffer is declared inside NS_DURING, so move its declaration outside and free in the handler:

```objc
- (CGImageRef)createImageAtIndex: (size_t)index options: (NSDictionary*)opts
{
  struct jpeg_decompress_struct  cinfo;
  struct gs_jpeg_error_mgr  jerrMgr;
  CGImageRef img = NULL;
  unsigned char *imgbuffer = NULL;
  
  if (!(self = [super init]))
    return NULL;

  memset((void*)&cinfo, 0, sizeof(struct jpeg_decompress_struct));
  gs_jpeg_error_mgr_create((j_common_ptr)&cinfo, &jerrMgr);
  
  NS_DURING
  {
    // ... existing code, but change:
    //   unsigned char *imgbuffer = NULL;
    // to just:
    //   (use the outer imgbuffer)
    
    // ... rest of decompression code ...
  } 
  NS_HANDLER
  {
    free(imgbuffer);  /* safe to call with NULL */
    gs_jpeg_memory_src_destroy(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    NS_VALUERETURN(NULL, CGImageRef);
  }
  NS_ENDHANDLER

  gs_jpeg_memory_src_destroy(&cinfo);
  jpeg_destroy_decompress(&cinfo);
  // ... rest ...
```

---

### Step 19 — AR-O5: Image codec dimension/allocation assertions
**File:** `libs-opal/Source/OpalGraphics/image/OPImageCodecJPEG.m` line 419 and OPImageCodecTIFF.m
**Problem:** Only 1 assertion in all image codecs. No dimension or allocation failure checks.

**Fix:** Add dimension validation after reading headers. In JPEG `createImageAtIndex:`:
```objc
    jpeg_read_header(&cinfo, TRUE);
    
    /* Validate dimensions to prevent excessive memory allocation */
    if (cinfo.image_width == 0 || cinfo.image_height == 0)
      {
        NSLog(@"JPEG: invalid dimensions %ux%u", cinfo.image_width, cinfo.image_height);
        gs_jpeg_memory_src_destroy(&cinfo);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
      }
    if (cinfo.image_width > 65535 || cinfo.image_height > 65535)
      {
        NSLog(@"JPEG: dimensions too large %ux%u", cinfo.image_width, cinfo.image_height);
        gs_jpeg_memory_src_destroy(&cinfo);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
      }
```

Add `malloc` failure check after `imgbuffer = malloc(...)`:
```objc
    imgbuffer = malloc(cinfo.output_height * rowSize);
    if (!imgbuffer)
      {
        NSLog(@"JPEG: failed to allocate image buffer (%u x %lu bytes)",
              cinfo.output_height, (unsigned long)rowSize);
        gs_jpeg_memory_src_destroy(&cinfo);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
      }
```

---

### Step 20 — AR-Q5: GL resource creation never error-checked
**Files:**
- `libs-quartzcore/Source/GLHelpers/CAGLTexture.m` lines 67-68
- `libs-quartzcore/Source/GLHelpers/CAGLSimpleFramebuffer.m` line 48
- `libs-quartzcore/Source/GLHelpers/CAGLProgram.m`

**Fix:** Add GL error checks after resource creation.

In `CAGLTexture.m` `-init`:
```objc
- (id) init
{
  self = [super init];
  if (!self)
    return nil;

  glGenTextures(1, &_textureID);
  GLenum err = glGetError();
  if (err != GL_NO_ERROR || _textureID == 0)
    {
      NSLog(@"CAGLTexture: glGenTextures failed (GL error 0x%04X)", err);
      [self release];
      return nil;
    }

  return self;
}
```

In `CAGLSimpleFramebuffer.m` `-initWithWidth:height:`:
```objc
  glGenFramebuffers(1, &_framebufferID);
  GLenum err = glGetError();
  if (err != GL_NO_ERROR || _framebufferID == 0)
    {
      NSLog(@"CAGLSimpleFramebuffer: glGenFramebuffers failed (GL error 0x%04X)", err);
      [self release];
      return nil;
    }
```

After `glFramebufferTexture2D`, check completeness:
```objc
  GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER_EXT);
  if (status != GL_FRAMEBUFFER_COMPLETE_EXT)
    {
      NSLog(@"CAGLSimpleFramebuffer: framebuffer incomplete (status 0x%04X)", status);
    }
```

---

### Step 21 — AR-Q7: Hardcoded 512x512 rasterization size
**File:** `libs-quartzcore/Source/CARenderer.m` lines 817-818
**Problem:** `const GLuint rasterize_w = 512, rasterize_h = 512` clips any layer larger than 512x512.

**Current code:**
```objc
  // TODO: 512x512 is NOT correct, we need to determine the actual layer size together with sublayers
  const GLuint rasterize_w = 512, rasterize_h = 512;
```

**Fix:** Compute from layer bounds:
```objc
  CGRect layerBounds = [[layer presentationLayer] bounds];
  GLuint rasterize_w = (GLuint)ceil(layerBounds.size.width);
  GLuint rasterize_h = (GLuint)ceil(layerBounds.size.height);
  if (rasterize_w == 0) rasterize_w = 1;
  if (rasterize_h == 0) rasterize_h = 1;
  /* Clamp to reasonable max to prevent GPU memory exhaustion */
  const GLuint maxRasterizeSize = 4096;
  if (rasterize_w > maxRasterizeSize) rasterize_w = maxRasterizeSize;
  if (rasterize_h > maxRasterizeSize) rasterize_h = maxRasterizeSize;
```

Also update the shadow rasterization sizes (lines 385, 457) similarly:
```objc
  const GLuint shadow_rasterize_w = rasterize_w, shadow_rasterize_h = rasterize_h;
```

Note: the shadow rasterize sizes are in `_renderLayer:withTransform:` which gets `texture` from the backing store. Use the texture dimensions there:
```objc
  const GLuint shadow_rasterize_w = [texture width] > 0 ? [texture width] : 512;
  const GLuint shadow_rasterize_h = [texture height] > 0 ? [texture height] : 512;
```

---

### Step 22 — TS-Q5: Global framebuffer stack without locking
**File:** `libs-quartzcore/Source/GLHelpers/CAGLSimpleFramebuffer.m` line 34
**Problem:** `static NSMutableArray *framebufferStack` is unprotected.

**Fix:** Since framebuffer operations are tightly coupled with GL context which is single-threaded per context, use thread-local storage instead of locking:

```objc
// Replace:
// static NSMutableArray * framebufferStack = nil;

// With a per-thread stack using NSThread dictionary:
static NSString *const kFramebufferStackKey = @"CAGLSimpleFramebufferStack";

static NSMutableArray *_framebufferStack(void)
{
  NSMutableDictionary *threadDict = [[NSThread currentThread] threadDictionary];
  NSMutableArray *stack = [threadDict objectForKey: kFramebufferStackKey];
  if (!stack)
    {
      stack = [NSMutableArray new];
      [threadDict setObject: stack forKey: kFramebufferStackKey];
      [stack release];
    }
  return stack;
}
```

Then replace all references to `framebufferStack` with `_framebufferStack()`.

---

### Step 23 — PF-Q2: O(n) NSPredicate filter on action registration
**File:** `libs-quartzcore/Source/CATransaction.m` lines 213-216
**Problem:** Every `registerAction:onObject:keyPath:` uses NSPredicate to filter duplicates, which is O(n) for n registered actions. With many animated properties this becomes quadratic.

**Current code:**
```objc
- (void)registerAction: (NSObject<CAAction> *)action
              onObject: (id)object
               keyPath: (NSString *)keyPath
{
  NSPredicate * sameActionsPredicate = [NSPredicate predicateWithFormat: @"object = %@ and keyPath = %@", object, keyPath];
  NSArray * duplicates = [_actions filteredArrayUsingPredicate: sameActionsPredicate];
  [_actions removeObjectsInArray: duplicates];
```

**Fix:** Use a dictionary keyed by (object+keyPath) for O(1) lookup:
```objc
// In CATransaction @interface, add:
@property (retain) NSMutableDictionary *actionsByKey;

// In -init:
_actionsByKey = [[NSMutableDictionary alloc] init];

// In -dealloc:
[_actionsByKey release];

// In registerAction:
- (void)registerAction: (NSObject<CAAction> *)action
              onObject: (id)object
               keyPath: (NSString *)keyPath
{
  NSString *compositeKey = [NSString stringWithFormat:@"%p:%@", object, keyPath];
  
  /* Remove old action with same key */
  NSDictionary *oldAction = [_actionsByKey objectForKey: compositeKey];
  if (oldAction)
    [_actions removeObject: oldAction];

  /* Add new action */
  NSDictionary * actionDescription = [NSDictionary dictionaryWithObjectsAndKeys:
    action, @"action",
    object, @"object",
    keyPath, @"keyPath",
    nil];

  [_actions addObject: actionDescription];
  [_actionsByKey setObject: actionDescription forKey: compositeKey];
}

// In -commit, clear the dict:
- (void) commit
{
  // ... existing commit code ...
  [_actions removeAllObjects];
  [_actionsByKey removeAllObjects];
}
```

---

### Step 24 — PF-Q6: defaultValueForKey linear string comparison
**File:** `libs-quartzcore/Source/CALayer.m` lines 190-264
**Problem:** `+defaultValueForKey:` uses a chain of `[key isEqualToString:...]` if-statements. O(n) per lookup.

**Fix:** Use a static NSDictionary for O(1) lookup:
```objc
+ (id) defaultValueForKey: (NSString *)key
{
  static NSDictionary *defaults = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    CGPoint anchorPt = CGPointMake(0.5, 0.5);
    CGRect contentsR = CGRectMake(0.0, 0.0, 1.0, 1.0);
    CGSize shadowOff = CGSizeMake(0.0, -3.0);

    defaults = [@{
      @"delegate": [NSNull null],
      @"anchorPoint": [NSValue valueWithBytes: &anchorPt objCType: @encode(CGPoint)],
      @"transform": [NSValue valueWithCATransform3D: CATransform3DIdentity],
      @"sublayerTransform": [NSValue valueWithCATransform3D: CATransform3DIdentity],
      @"shouldRasterize": @NO,
      @"opacity": @1.0f,
      @"contentsRect": [NSValue valueWithBytes: &contentsR objCType: @encode(CGRect)],
      @"shadowColor": [(id)CGColorCreateGenericRGB(0.0, 0.0, 0.0, 1.0) autorelease],
      @"shadowOffset": [NSValue valueWithBytes: &shadowOff objCType: @encode(CGSize)],
      @"shadowRadius": @3.0f,
      @"duration": @(__builtin_inf()),
      @"speed": @1.0f,
      @"autoreverses": @NO,
      @"repeatCount": @1.0f,
      @"beginTime": @0.0,
    } retain];
  });

  id val = [defaults objectForKey: key];
  if (val == [NSNull null])
    return nil;
  return val;
}
```

---

### Step 25 — PF-Q5: Texture re-upload every frame
**File:** `libs-quartzcore/Source/CARenderer.m` lines 741-745
**Problem:** In `_renderLayer:withTransform:`, when layer contents is a CGImageRef, it creates a new CAGLTexture and calls `loadImage:` every single frame. No caching.

**Current code:**
```objc
      else if ([layerContents isKindOfClass: NSClassFromString(@"CGImage")])
        {
          CGImageRef image = (CGImageRef)layerContents;
          texture = [CAGLTexture texture];
          [texture loadImage: image];
        }
```

**Fix:** Cache the texture on the backing store. Add a `contentsTexture` to the backing store for CGImage contents:

In `CABackingStore.h`, add a property (or use an associated object if header changes are undesirable):
```objc
@property (retain) CAGLTexture *cachedContentsTexture;
@property (assign) id cachedContentsSource;  /* weak ref to detect content changes */
```

In `CARenderer.m` `_renderLayer:withTransform:`:
```objc
      else if ([layerContents isKindOfClass: NSClassFromString(@"CGImage")])
        {
          CGImageRef image = (CGImageRef)layerContents;
          
          /* Reuse cached texture if image hasn't changed */
          CABackingStore *bs = [layer backingStore];
          if (bs && [bs cachedContentsSource] == (id)image && [bs cachedContentsTexture])
            {
              texture = [bs cachedContentsTexture];
            }
          else
            {
              texture = [CAGLTexture texture];
              [texture loadImage: image];
              if (!bs)
                {
                  bs = [CABackingStore backingStoreWithWidth: CGImageGetWidth(image)
                                                     height: CGImageGetHeight(image)];
                  [layer setBackingStore: bs];
                }
              [bs setCachedContentsTexture: texture];
              [bs setCachedContentsSource: (id)image];
            }
        }
```

---

## Phase 4: Low Severity Fixes (5 items)

### Step 26 — PF-O1: CGPath linear growth (+32 elements)
**File:** `libs-opal/Source/OpalGraphics/OPPath.m` lines 222-234
**Problem:** Path array grows by +32 elements at a time, causing O(n) total reallocs for large paths.

**Fix:** Switch to geometric growth (double capacity):
```objc
- (void) addElementWithType: (CGPathElementType)type points: (CGPoint[])points
{
#if !defined(NDEBUG)
  if (!pthread_equal(_ownerThread, pthread_self()))
    {
      NSLog(@"WARNING: CGMutablePath %p mutated from wrong thread", self);
    }
#endif

  if (_elementsArray)
  {
    if (_count + 1 > _capacity)
    {
      _capacity = _capacity * 2;
      if (_capacity < 64) _capacity = 64;
      _elementsArray = realloc(_elementsArray, _capacity * sizeof(OPPathElement));
    }
  }
  else
  {
    _capacity = 32;
    _elementsArray = malloc(_capacity * sizeof(OPPathElement));
  }
  // ... rest unchanged ...
```

---

### Step 27 — PF-O2: No state caching in CGContext
**Severity:** Low. **Status:** Document as known limitation. The CGContext is a thin wrapper over Cairo; adding state caching would require tracking every state variable. Not cost-effective for this audit. Add a `// TODO:` comment at the top of CGContext.m:

```objc
/* TODO: Performance — CGContext operations are direct Cairo wrappers with no
   state deduplication. Consider adding dirty-flag tracking for fill/stroke
   colors to avoid redundant cairo_set_source calls in tight draw loops. */
```

---

### Step 28 — PF-O3: CGPathGetBoundingBox scans all elements every call
**File:** `libs-opal/Source/OpalGraphics/CGPath.m` lines 127-172
**Severity:** Low for immutable paths (called once), medium for hot paths.

**Fix:** Cache bounding box on CGPath. Add a cached bbox field to `OPPath.h`:
```objc
@interface CGPath : NSObject
{
  NSUInteger _count;
  OPPathElement *_elementsArray;
  CGRect _cachedBoundingBox;
  BOOL _boundingBoxValid;
}
```

In `CGPathGetBoundingBox`:
```objc
CGRect CGPathGetBoundingBox(CGPathRef path)
{
  if (path->_boundingBoxValid)
    return path->_cachedBoundingBox;

  // ... existing computation ...
  
  CGRect result = CGRectMake(minX, minY, (maxX-minX), (maxY-minY));
  ((CGPath*)path)->_cachedBoundingBox = result;
  ((CGPath*)path)->_boundingBoxValid = YES;
  return result;
}
```

In `CGMutablePath`'s `addElementWithType:points:`, invalidate the cache:
```objc
  _boundingBoxValid = NO;
```

---

### Step 29 — PF-Q3: CAKeyframeAnimation / CASpringAnimation unimplemented
**Severity:** Low. These are non-functional stubs. Not a fix target for this plan. Document with TODO:

Add to `CAAnimation.m` or a new file:
```objc
/* TODO: CAKeyframeAnimation and CASpringAnimation are not yet implemented.
   They exist as stubs only. */
```

---

### Step 30 — PF-Q4: Deprecated glBegin/glEnd immediate mode
**File:** `libs-quartzcore/Source/CARenderer.m` (lines 425-434, 519-528, 562-571, 615-624)
**Severity:** Low (functional but slow). Four occurrences of `glBegin(GL_QUADS)` ... `glEnd()`.

**Fix:** Replace with vertex arrays (already partially used elsewhere in the file). Example replacement for the first occurrence (lines 425-434):

```objc
  /* Replace glBegin/glEnd with vertex arrays */
  GLfloat tw = [texture width] / 2.0f;
  GLfloat th = [texture height] / 2.0f;
  GLfloat quadVerts[] = {
    -tw, -th,
    -tw,  th,
     tw,  th,
     tw, -th,
  };
  GLfloat quadTexCoords[] = {
    0, 0,
    0, textureMaxY,
    textureMaxX, textureMaxY,
    textureMaxX, 0,
  };
  
  glVertexPointer(2, GL_FLOAT, 0, quadVerts);
  glTexCoordPointer(2, GL_FLOAT, 0, quadTexCoords);
  glDrawArrays(GL_QUADS, 0, 4);
```

Apply the same pattern to all four `glBegin`/`glEnd` blocks. Each has slightly different vertex coordinates — compute them from the texture dimensions used in the existing code.

---

## Verification Checklist

After all steps are complete:

1. **Build both repos:**
   ```bash
   cd libs-opal && make clean && make
   cd libs-quartzcore && make clean && make
   ```

2. **Run existing tests:**
   ```bash
   cd libs-opal/Tests && make check
   cd libs-quartzcore/Tests && make check
   ```

3. **Grep for remaining issues:**
   - `grep -rn 'assert(' libs-quartzcore/Source/` — verify AR-Q1 assert is removed
   - `grep -rn 'malloc(dashes_count)' libs-opal/Source/` — verify AR-O8 is fixed
   - `grep -rn '!ctx->add' libs-opal/Source/OpalGraphics/CGContext.m` — verify AR-O2 pattern is gone

4. **Thread safety smoke test:** Create a CGContext from one thread, attempt to use from another in debug mode; verify the assertion fires.

5. **TIFF write test:** Verify that TIFF destination init now accepts valid `public.tiff` type (was 100% broken before).

---

## Summary Table

| Step | ID | Sev | File | Description |
|------|-----|------|------|-------------|
| 1 | AR-O2 | Critical | CGContext.m:816 | Fix NULL deref in fill_path error log |
| 2 | AR-O7 | Critical | OPImageCodecTIFF.m:337 | Fix inverted condition in TIFF dest init |
| 3 | AR-Q4 | Critical | CAGLTexture.m:214 | Skip unpremultiply for alpha=0 |
| 4 | TS-O1/O2 | Critical | CGContext-private.h, CGContext.m | Thread confinement assertion |
| 5 | TS-Q1 | Critical | CATransaction.m | Lock transactionStack |
| 6 | TS-Q2 | Critical | CALayer.m:841-881 | Synchronized sublayer mutation |
| 7 | AR-O8 | High | CGContext+GState.m:88 | sizeof(double) in dash malloc |
| 8 | AR-O1 | High | CGPath.m | NaN/Inf coordinate validation |
| 9 | AR-O3 | High | CGContext.m:341-370 | GState restore underflow guard |
| 10 | AR-O6 | High | OPImageCodecTIFF.m:83-88 | Bounds check TIFF read |
| 11 | AR-Q1 | High | CALayer.m:935 | Clamp activeTime instead of assert |
| 12 | AR-Q2 | High | CALayer.m:841-847 | Cycle detection in addSublayer |
| 13 | AR-Q6 | High | CAGLTexture.m:256 | malloc instead of VLA |
| 14 | TS-Q3 | High | CARenderer.m:253 | GL context thread affinity assert |
| 15 | TS-Q4 | High | CALayer.m:48 | Thread-local currentFrameBeginTime |
| 16 | TS-O3 | Medium | CGContext.m:39 | dispatch_once for default_cp |
| 17 | TS-O5 | Medium | OPPath.m:220-250 | Debug thread assertion for mutable path |
| 18 | AR-O4 | Medium | OPImageCodecJPEG.m:382 | Fix imgbuffer leak on exception |
| 19 | AR-O5 | Medium | OPImageCodecJPEG.m:419 | Dimension/alloc validation |
| 20 | AR-Q5 | Medium | CAGLTexture.m, CAGLSimpleFramebuffer.m | GL error checking |
| 21 | AR-Q7 | Medium | CARenderer.m:818 | Dynamic rasterization size |
| 22 | TS-Q5 | Medium | CAGLSimpleFramebuffer.m:34 | Thread-local framebuffer stack |
| 23 | PF-Q2 | Medium | CATransaction.m:213 | Dictionary-based action dedup |
| 24 | PF-Q6 | Medium | CALayer.m:190 | NSDictionary for defaultValueForKey |
| 25 | PF-Q5 | Medium | CARenderer.m:741 | Texture caching |
| 26 | PF-O1 | Low | OPPath.m:222 | Geometric path array growth |
| 27 | PF-O2 | Low | CGContext.m | Document: no state caching (TODO) |
| 28 | PF-O3 | Low | CGPath.m:127 | Cached bounding box |
| 29 | PF-Q3 | Low | CAAnimation.m | Document: stubs unimplemented |
| 30 | PF-Q4 | Low | CARenderer.m | Replace glBegin/glEnd with vertex arrays |
