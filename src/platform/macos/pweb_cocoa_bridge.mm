/*
 * pweb_cocoa_bridge.mm - the production Objective-C++ half of PWeb's macOS
 * pweb://app adapter. See pweb_cocoa_bridge.h for what this is, what it is
 * deliberately not, and the ownership model.
 *
 * THE WHOLE FILE IS THE THREE THINGS PASCAL CANNOT EXPRESS: an override of
 * +[WKWebViewConfiguration new] on that class's own metaclass, an
 * @try/@catch barrier at every seam entry, and an NSHTTPURLResponse.
 * Everything else - the URI verdict, the store, the MIME table, the refusal
 * policy - stays in shared Pascal, unchanged and unduplicated.
 *
 * Compiled WITHOUT ARC on purpose: the ownership of the +new return value, of
 * the tracked tasks and of the response buffers is explicit here exactly as
 * it is in Pascal, and ARC would hide the very transfers this file exists to
 * make legible.
 *
 * A NOTE ON RACES THAT ARE STRUCTURALLY ABSENT, not merely untested. Every
 * request is resolved and completed inside startURLSchemeTask: on the main
 * thread, so stopURLSchemeTask: cannot interleave with serving and the live
 * set is empty between calls. The claim-once state machine is still built and
 * still gated, for two reasons: "structurally absent" is a property of THIS
 * implementation that a future chunked or deferred delivery (CAP-12's Range
 * plane will need one) would remove, and the invariants are cheap to hold and
 * expensive to retrofit. What the synchronous shape must never do is let the
 * guards go unproven - which is why the deterministic proof surface at the
 * bottom of the header exists.
 */

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#include <mach/mach.h>
#include <objc/runtime.h>

#include <stdlib.h>
#include <string.h>

#include "pweb_cocoa_bridge.h"

#define PWEB_COCOA_SCHEME @"pweb"

/* ------------------------------ counters -------------------------------- */

static uint64_t g_seam_invocations = 0;
static uint64_t g_tasks_started = 0;
static uint64_t g_tasks_served = 0;
static uint64_t g_tasks_refused = 0;
static uint64_t g_tasks_stopped = 0;
static uint64_t g_stops_while_serving = 0;
static uint64_t g_stops_ignored = 0;
static uint64_t g_suppressed_terminals = 0;
static uint64_t g_caught_exceptions = 0;
static uint64_t g_unresolved_handles = 0;

static inline void pweb_bump(uint64_t *counter) {
  __atomic_fetch_add(counter, 1u, __ATOMIC_SEQ_CST);
}

static inline uint64_t pweb_read(uint64_t *counter) {
  return __atomic_load_n(counter, __ATOMIC_SEQ_CST);
}

/* --------------------------- the seam state ------------------------------ */

/* The handle the seam installs FOR, and the handle the installed handler
   answers AS. 0 means disowned: no resolve callback can be made. Written with
   an atomic store so a Detach issued (incorrectly) off the GUI thread can
   never be observed half-written. */
static uint64_t g_armed_handle = 0;

static pweb_cocoa_resolve_fn g_resolve = NULL;
static int g_seam_installed = 0;

/* ------------------------- the task state machine ------------------------ */

/* FOUR REAL STATES, and the transitions are the guard.
 *
 *      New ──serve decision──▶ Serving ──deliver──▶ Completed
 *       │                          │
 *       └────────stop──────────────┴────────────▶ Cancelled
 *
 * The CLAIM is the transition OUT of a non-terminal state, and it succeeds
 * exactly once per task. Crucially the entry is NOT removed at the claim: it
 * is removed at SETTLE, after the terminal callback has actually been
 * delivered (or has raised). That split is not decoration - claiming and
 * removing in one step means an NSException thrown by didReceiveResponse:
 * leaves a task that is untracked AND unterminated, i.e. a resource WebKit
 * waits on forever while live_tasks reads 0 and every gate stays green.
 *
 * Terminal entries are removed rather than retained, because a process that
 * serves thousands of assets cannot keep one dictionary entry per request. */
typedef enum {
  PWEB_TASK_NEW = 0,
  PWEB_TASK_SERVING = 1,
  PWEB_TASK_COMPLETED = 2,
  PWEB_TASK_CANCELLED = 3,
  PWEB_TASK_UNTRACKED = -1
} pweb_task_state_t;

@interface PWebCocoaSchemeHandler : NSObject <WKURLSchemeHandler>
/* Shared entry point: the WKURLSchemeHandler protocol method and the
   deterministic stub driver both funnel through these two. */
- (void)handleTask:(id<WKURLSchemeTask>)task;
- (void)cancelTask:(id<WKURLSchemeTask>)task;
- (void)trackTaskOnly:(id<WKURLSchemeTask>)task;
/* Transition out of New/Serving into `terminal`, exactly once. The task stays
   TRACKED until settleTask:, so the caller still owns it if delivery raises. */
- (BOOL)claimTask:(id<WKURLSchemeTask>)task as:(pweb_task_state_t)terminal;
- (void)settleTask:(id<WKURLSchemeTask>)task;
- (unsigned long)failEveryLiveTask;
- (uint64_t)liveTaskCount;
@end

static PWebCocoaSchemeHandler *g_handler = nil;

@implementation PWebCocoaSchemeHandler {
  NSMutableDictionary *_states; /* NSValue(task pointer) -> NSNumber(state) */
  NSMutableArray *_live;        /* the task objects, RETAINED while tracked */
  NSLock *_lock;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _states = [[NSMutableDictionary alloc] init];
    _live = [[NSMutableArray alloc] init];
    _lock = [[NSLock alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_states release];
  [_live release];
  [_lock release];
  [super dealloc];
}

- (void)trackTaskOnly:(id<WKURLSchemeTask>)task {
  NSValue *key = [NSValue valueWithPointer:(const void *)task];
  [_lock lock];
  if ([_states objectForKey:key] == nil) {
    [_states setObject:[NSNumber numberWithInt:(int)PWEB_TASK_NEW] forKey:key];
    [_live addObject:task]; /* +1: we may have to fail it at teardown */
  }
  [_lock unlock];
}

- (void)markServing:(id<WKURLSchemeTask>)task {
  NSValue *key = [NSValue valueWithPointer:(const void *)task];
  [_lock lock];
  if ([[_states objectForKey:key] intValue] == (int)PWEB_TASK_NEW) {
    [_states setObject:[NSNumber numberWithInt:(int)PWEB_TASK_SERVING]
                forKey:key];
  }
  [_lock unlock];
}

/* Returns YES exactly once per task: whoever moves it out of New/Serving owns
   the right to send a terminal callback, and everyone else silently does
   nothing. Apple raises an NSException for each of the mistakes this
   prevents, and an NSException crossing into a Pascal frame is undefined
   behaviour, not an error path.

   The task remains TRACKED after a successful claim - see the state comment.
   Only settleTask: removes it. */
- (BOOL)claimTask:(id<WKURLSchemeTask>)task as:(pweb_task_state_t)terminal {
  BOOL claimed = NO;
  int previous = (int)PWEB_TASK_UNTRACKED;
  NSValue *key = [NSValue valueWithPointer:(const void *)task];
  [_lock lock];
  NSNumber *state = [_states objectForKey:key];
  if (state != nil) {
    previous = [state intValue];
    if ((previous == (int)PWEB_TASK_NEW) ||
        (previous == (int)PWEB_TASK_SERVING)) {
      [_states setObject:[NSNumber numberWithInt:(int)terminal] forKey:key];
      claimed = YES;
    }
  }
  [_lock unlock];
  /* The state the task was in when it was cancelled is a REAL distinction and
     not bookkeeping: a stop of a SERVING task is the interleaving a
     synchronous main-thread handler cannot produce and a future chunked or
     deferred delivery will. Recording it is how "structurally absent" stays a
     measured claim rather than an assumption. */
  if (claimed && (terminal == PWEB_TASK_CANCELLED) &&
      (previous == (int)PWEB_TASK_SERVING)) {
    pweb_bump(&g_stops_while_serving);
  }
  return claimed;
}

- (void)settleTask:(id<WKURLSchemeTask>)task {
  NSValue *key = [NSValue valueWithPointer:(const void *)task];
  /* The tracked array holds the only reference we are sure of; removing it
     could deallocate the task before the caller has finished messaging it. */
  [[task retain] autorelease];
  [_lock lock];
  [_states removeObjectForKey:key];
  [_live removeObjectIdenticalTo:task];
  [_lock unlock];
}

- (uint64_t)liveTaskCount {
  uint64_t n;
  [_lock lock];
  n = (uint64_t)[_states count];
  [_lock unlock];
  return n;
}

/* ONE refusal outcome, with no reason attached and no native text: wrong
   authority, non-canonical path, missing asset and internal failure are
   indistinguishable to the page, exactly as Windows answers a constant 404
   and Linux a constant GError. */
- (void)refuseTask:(id<WKURLSchemeTask>)task {
  if (![self claimTask:task as:PWEB_TASK_COMPLETED]) {
    pweb_bump(&g_suppressed_terminals);
    return;
  }
  @try {
    NSError *error = [NSError errorWithDomain:@"pweb" code:1 userInfo:nil];
    [task didFailWithError:error];
    pweb_bump(&g_tasks_refused);
  } @catch (NSException *e) {
    (void)e;
    pweb_bump(&g_caught_exceptions);
  }
  /* Settled whether or not the delivery raised: we held the claim, so no
     other path may attempt a terminal for this task, and leaving it tracked
     would keep live_tasks non-zero forever. */
  [self settleTask:task];
}

/* MEASURED, run 31909938201, and the reason this is NSHTTPURLResponse rather
   than NSURLResponse: a task completed with a bare NSURLResponse LOADS
   correctly - the HTML renders, the stylesheet applies - while fetch()
   reports status 0 and ok === false, because NSURLResponse carries no status
   code. Only NSHTTPURLResponse gives JavaScript a status. */
- (void)serveTask:(id<WKURLSchemeTask>)task asset:(pweb_cocoa_asset_t *)asset {
  if (![self claimTask:task as:PWEB_TASK_COMPLETED]) {
    pweb_bump(&g_suppressed_terminals);
    pweb_cocoa_free(asset->bytes);
    asset->bytes = NULL;
    return;
  }

  NSData *data;
  if (asset->length > 0) {
    /* The body becomes the bridge's the moment it is handed over: NSData owns
       and frees it. This is deliberately INDEPENDENT of CAP-7M0's
       handoff=original-bytes measurement - production is correct whether
       WebKit copies at handoff or retains the pointer. */
    data = [NSData dataWithBytesNoCopy:asset->bytes
                                length:(NSUInteger)asset->length
                          freeWhenDone:YES];
  } else {
    /* A zero-length asset is still an asset. It gets a real allocation on the
       Pascal side so "empty" and "failed" can never be confused; here the
       block is released outright and an empty NSData is delivered with an
       honest Content-Length: 0, rather than relying on
       dataWithBytesNoCopy:length:0 having a documented meaning. */
    pweb_cocoa_free(asset->bytes);
    data = [NSData data];
  }
  asset->bytes = NULL;

  NSString *mime = [NSString stringWithUTF8String:asset->content_type];
  if (mime == nil) {
    mime = @"application/octet-stream";
  }
  NSDictionary *headers = [NSDictionary
      dictionaryWithObjectsAndKeys:mime, @"Content-Type",
                                   [NSString stringWithFormat:@"%lld",
                                                              (long long)[data length]],
                                   @"Content-Length", nil];
  NSHTTPURLResponse *response =
      [[[NSHTTPURLResponse alloc] initWithURL:[[task request] URL]
                                   statusCode:200
                                  HTTPVersion:@"HTTP/1.1"
                                 headerFields:headers] autorelease];
  /* THE DELIVERY IS ITS OWN @try, and that is the whole reason the claim and
     the settle are separate steps. An NSException out of any of these three
     would otherwise leave a task that is claimed (so no other path may
     terminate it) and never terminated - a resource WebKit waits on forever,
     invisible because live_tasks would already read 0. Here we still hold the
     claim, so we can and must deliver exactly one terminal. */
  @try {
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
    pweb_bump(&g_tasks_served);
  } @catch (NSException *e) {
    (void)e;
    pweb_bump(&g_caught_exceptions);
    @try {
      /* didFailWithError: is legal after a response and after data - only
         after a TERMINAL is it not - so this is the correct recovery for the
         common case, and is itself guarded for the case where it is not. */
      NSError *error = [NSError errorWithDomain:@"pweb" code:1 userInfo:nil];
      [task didFailWithError:error];
      pweb_bump(&g_tasks_refused);
    } @catch (NSException *inner) {
      (void)inner;
      pweb_bump(&g_caught_exceptions);
    }
  }
  [self settleTask:task];
}

- (void)handleTask:(id<WKURLSchemeTask>)task {
  @autoreleasepool {
    @try {
      pweb_bump(&g_tasks_started);
      /* Tracked FIRST, unconditionally. Every path below completes the task
         exactly once through the claim gate, including the disowned one - a
         task that is never completed is a request WebKit waits on forever. */
      [self trackTaskOnly:task];

      const uint64_t handle = __atomic_load_n(&g_armed_handle, __ATOMIC_SEQ_CST);
      pweb_cocoa_resolve_fn resolve = g_resolve;
      if ((handle == 0) || (resolve == NULL)) {
        /* disowned, or never armed: fail closed, and NEVER call out */
        [self refuseTask:task];
        return;
      }

      /* THE URI IS THE WHOLE URI. No path accessor is ever consulted: a
         path-only view of pweb://evil/x reads as /x and would hand a
         wrong-authority request through as a legitimate asset. */
      NSURL *url = [[task request] URL];
      NSString *absolute = (url != nil) ? [url absoluteString] : nil;
      const char *absolute_c =
          (absolute != nil) ? [absolute UTF8String] : NULL;
      if (absolute_c == NULL) {
        [self refuseTask:task];
        return;
      }

      pweb_cocoa_asset_t asset;
      memset(&asset, 0, sizeof(asset));
      const int verdict = resolve(handle, absolute_c, &asset);
      if (verdict < 0) {
        /* the handle did not resolve: a released or never-claimed handler.
           No Pascal code ran, and none can. */
        pweb_bump(&g_unresolved_handles);
        [self refuseTask:task];
        return;
      }
      if (verdict == 0) {
        [self refuseTask:task];
        return;
      }
      [self markServing:task];
      [self serveTask:task asset:&asset];
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
      @try {
        [self refuseTask:task];
      } @catch (NSException *inner) {
        (void)inner;
      }
    }
  }
}

- (void)cancelTask:(id<WKURLSchemeTask>)task {
  @autoreleasepool {
    @try {
      /* After this the task must never be messaged again. Moving it to
         Cancelled IS the guard - every later terminal is claim-gated, and a
         second stop finds a task that is already terminal (or gone). */
      if ([self claimTask:task as:PWEB_TASK_CANCELLED]) {
        pweb_bump(&g_tasks_stopped);
        [self settleTask:task];
      } else {
        pweb_bump(&g_stops_ignored);
      }
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
  }
}

- (unsigned long)failEveryLiveTask {
  unsigned long failed = 0;
  NSArray *snapshot;
  [_lock lock];
  snapshot = [[_live copy] autorelease];
  [_lock unlock];
  for (id task in snapshot) {
    if (![self claimTask:(id<WKURLSchemeTask>)task as:PWEB_TASK_COMPLETED]) {
      continue;
    }
    @try {
      NSError *error = [NSError errorWithDomain:@"pweb" code:1 userInfo:nil];
      [(id<WKURLSchemeTask>)task didFailWithError:error];
      pweb_bump(&g_tasks_refused);
      ++failed;
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
    /* Settled even when the delivery raised: teardown must leave the set
       EMPTY, or the next cycle inherits a task nothing can ever terminate. */
    [self settleTask:(id<WKURLSchemeTask>)task];
  }
  return failed;
}

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  [self handleTask:task];
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  [self cancelTask:task];
}

@end

/* ------------------------ SEAM B: the pre-create override ---------------- */

/*
 * Upstream creates the configuration AND the web view inside webview_create,
 * so there is no moment between them a caller can reach - unless the caller
 * owns the constructor. +[WKWebViewConfiguration new] is that constructor
 * (cocoa_webkit.hh:450 calls exactly this selector).
 *
 * The override is added to WKWebViewConfiguration's OWN metaclass with
 * class_addMethod. Note what is deliberately NOT done: class_getClassMethod
 * would return NSObject's inherited +new, and setting ITS implementation
 * would swizzle +new for every class in the process. Adding to this metaclass
 * affects this class alone.
 *
 * Installed once and never removed; teardown DISOWNS it. With no armed handle
 * it does nothing at all but forward.
 */
static id pweb_configuration_new(Class cls, SEL cmd) {
  (void)cmd;
  id config = [[cls alloc] init]; /* exactly what +new does, in public API */
  if (config == nil) {
    return nil;
  }
  const uint64_t handle = __atomic_load_n(&g_armed_handle, __ATOMIC_SEQ_CST);
  if ((handle != 0) && (g_handler != nil)) {
    @try {
      [(WKWebViewConfiguration *)config setURLSchemeHandler:g_handler
                                               forURLScheme:PWEB_COCOA_SCHEME];
      pweb_bump(&g_seam_invocations);
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
  }
  return config; /* +1, as +new must return */
}

/* ------------------------------ the C seam ------------------------------- */

void *pweb_cocoa_alloc(size_t n) {
  /* malloc(0) may legitimately return NULL, and a NULL body would be
     indistinguishable from an allocation failure. A zero-byte asset is still
     an asset, so it gets a real block. */
  return malloc((n != 0) ? n : 1);
}

void pweb_cocoa_free(void *p) {
  if (p != NULL) {
    free(p);
  }
}

int pweb_cocoa_install(pweb_cocoa_resolve_fn resolve) {
  int ok = 0;
  if (resolve == NULL) {
    return 0;
  }
  @autoreleasepool {
    @try {
      if (g_seam_installed) {
        /* Idempotent, but the resolve function is process-wide state: a
           second, DIFFERENT one would silently rebind every future request. */
        return (g_resolve == resolve) ? 1 : 0;
      }
      Class config_class = objc_getClass("WKWebViewConfiguration");
      if (config_class == Nil) {
        return 0;
      }
      Class meta = object_getClass((id)config_class);
      if (meta == Nil) {
        return 0;
      }
      if (!class_addMethod(meta, @selector(new), (IMP)pweb_configuration_new,
                           "@@:")) {
        /* The class already declares its OWN +new: replace that
           implementation, which is still confined to this class.
           The check below is the whole safety of this branch.
           class_getInstanceMethod walks the superclass chain, so on a class
           that merely INHERITS +new from NSObject it returns NSObject's
           Method - and setting that implementation would swizzle +new for
           EVERY class in the process. Identical Method pointers mean
           inherited; refuse rather than guess. */
        Method own = class_getInstanceMethod(meta, @selector(new));
        Class super_meta = class_getSuperclass(meta);
        Method inherited =
            (super_meta != Nil)
                ? class_getInstanceMethod(super_meta, @selector(new))
                : NULL;
        if ((own == NULL) || (own == inherited)) {
          return 0;
        }
        method_setImplementation(own, (IMP)pweb_configuration_new);
      }
      if (g_handler == nil) {
        g_handler = [[PWebCocoaSchemeHandler alloc] init];
      }
      if (g_handler == nil) {
        return 0;
      }
      g_resolve = resolve;
      g_seam_installed = 1;
      ok = 1;
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
      ok = 0;
    }
  }
  return ok;
}

int pweb_cocoa_arm(uint64_t handle) {
  uint64_t expected = 0;
  if ((handle == 0) || !g_seam_installed) {
    return 0;
  }
  /* Two LIVE handlers on one process-wide seam would both be served by a
     single callback that can only consult one store, so a second arm is
     refused rather than silently resolved in someone's favour. */
  if (!__atomic_compare_exchange_n(&g_armed_handle, &expected, handle, false,
                                   __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
    return (expected == handle) ? 1 : 0;
  }
  return 1;
}

void pweb_cocoa_disown(uint64_t handle) {
  uint64_t expected = handle;
  if (handle == 0) {
    return;
  }
  (void)__atomic_compare_exchange_n(&g_armed_handle, &expected, (uint64_t)0,
                                    false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

unsigned long pweb_cocoa_fail_live_tasks(void) {
  unsigned long failed = 0;
  @autoreleasepool {
    @try {
      if (g_handler != nil) {
        failed = [g_handler failEveryLiveTask];
      }
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
  }
  return failed;
}

uint64_t pweb_cocoa_seam_invocations(void) {
  return pweb_read(&g_seam_invocations);
}

void pweb_cocoa_get_stats(pweb_cocoa_stats_t *out) {
  if (out == NULL) {
    return;
  }
  memset(out, 0, sizeof(*out));
  out->seam_invocations = pweb_read(&g_seam_invocations);
  out->tasks_started = pweb_read(&g_tasks_started);
  out->tasks_served = pweb_read(&g_tasks_served);
  out->tasks_refused = pweb_read(&g_tasks_refused);
  out->tasks_stopped = pweb_read(&g_tasks_stopped);
  out->stops_while_serving = pweb_read(&g_stops_while_serving);
  out->stops_ignored = pweb_read(&g_stops_ignored);
  out->suppressed_terminals = pweb_read(&g_suppressed_terminals);
  out->caught_exceptions = pweb_read(&g_caught_exceptions);
  out->unresolved_handles = pweb_read(&g_unresolved_handles);
  @autoreleasepool {
    @try {
      out->live_tasks = (g_handler != nil) ? [g_handler liveTaskCount] : 0;
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
  }
}

int pweb_cocoa_handler_installed_on(void *view) {
  /* THREE-VALUED ON PURPOSE, and the middle value is the whole point.
     Collapsing "nobody is visible here" into "somebody else owns it" would
     make a correct setup fail on an UNMEASURED Apple behaviour: whether the
     configuration a WKWebView hands back carries the scheme-handler map its
     original was constructed with. CAP-7M0 measured that WRITING there is
     silently ineffective - a statement about mutation, not about reading a
     copied registration - so the read-back is plausible but not established.

     A wrong guess in the strict direction costs a hosted run at 10x billing
     and reports a working adapter as broken; a wrong guess in the permissive
     direction is covered anyway, because the runtime gate's real evidence
     that this view is served is that pweb://app/index.html is requested and
     the page reports its own verdict. So the DEFINITELY-WRONG answer gates
     and the AMBIGUOUS one is recorded. Promote 0 to a refusal once a hosted
     run has shown 1 on both architectures (ledgered). */
  int verdict = PWEB_COCOA_READBACK_ABSENT;
  if ((view == NULL) || (g_handler == nil)) {
    return PWEB_COCOA_READBACK_ABSENT;
  }
  @autoreleasepool {
    @try {
      WKWebView *wv = (WKWebView *)view;
      id installed = [[wv configuration]
          urlSchemeHandlerForURLScheme:PWEB_COCOA_SCHEME];
      if (installed == g_handler) {
        verdict = PWEB_COCOA_READBACK_OURS;
      } else if (installed == nil) {
        verdict = PWEB_COCOA_READBACK_ABSENT;
      } else {
        /* Someone else owns pweb:// on this view. That is never ambiguous
           and never acceptable. */
        verdict = PWEB_COCOA_READBACK_FOREIGN;
      }
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
      verdict = PWEB_COCOA_READBACK_ABSENT;
    }
  }
  return verdict;
}

int pweb_cocoa_seam_is_confined(void) {
  int ok = 0;
  if (!g_seam_installed) {
    return 0;
  }
  @autoreleasepool {
    @try {
      Class config_class = objc_getClass("WKWebViewConfiguration");
      if (config_class == Nil) {
        return 0;
      }
      Class config_meta = object_getClass((id)config_class);
      Class object_meta = object_getClass((id)[NSObject class]);
      if ((config_meta == Nil) || (object_meta == Nil)) {
        return 0;
      }
      const IMP ours = (IMP)pweb_configuration_new;
      const int owns =
          (class_getMethodImplementation(config_meta, @selector(new)) == ours);
      const int leaked =
          (class_getMethodImplementation(object_meta, @selector(new)) == ours);

      /* The behavioural half, not just the table half: constructing unrelated
         objects with +new must not reach the seam at all. If the override had
         been installed on NSObject's metaclass, this counter would move. */
      const uint64_t before = pweb_read(&g_seam_invocations);
      id plain = [NSObject new];
      id array = [NSMutableArray new];
      const uint64_t after = pweb_read(&g_seam_invocations);
      const int quiet = (plain != nil) && (array != nil) && (after == before);
      [plain release];
      [array release];

      ok = (owns && !leaked && quiet) ? 1 : 0;
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
      ok = 0;
    }
  }
  return ok;
}

uint64_t pweb_cocoa_rss_kb(void) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return (uint64_t)(info.resident_size / 1024u);
}

/* ===================== DETERMINISTIC PROOF SURFACE ======================= *
 *
 * See the header. The stub MIMICS WebKit's documented raising behaviour so
 * the claim gate is proven load-bearing rather than assumed to be: a stub
 * that quietly accepted a second terminal would let the guard be deleted
 * with every test still green.
 */

@interface PWebCocoaStubTask : NSObject <WKURLSchemeTask> {
@public
  pweb_cocoa_stub_outcome_t outcome;
}
@property(nonatomic, retain) NSURLRequest *stubRequest;
@end

@implementation PWebCocoaStubTask

@synthesize stubRequest = _stubRequest;

- (instancetype)initWithUrl:(NSString *)url {
  self = [super init];
  if (self != nil) {
    memset(&outcome, 0, sizeof(outcome));
    outcome.response_length = -1;
    outcome.body_hash = 2166136261u; /* FNV-1a offset basis */
    NSURL *parsed = [NSURL URLWithString:url];
    if (parsed == nil) {
      [self release];
      return nil;
    }
    _stubRequest = [[NSURLRequest requestWithURL:parsed] retain];
  }
  return self;
}

- (void)dealloc {
  [_stubRequest release];
  [super dealloc];
}

- (NSURLRequest *)request {
  return _stubRequest;
}

- (void)raiseMisuse:(NSString *)what {
  outcome.misuse_raised = 1;
  [NSException raise:@"PWebCocoaStubTaskMisuse" format:@"%@", what];
}

- (void)didReceiveResponse:(NSURLResponse *)response {
  if (outcome.finished || outcome.failed) {
    [self raiseMisuse:@"response after a terminal callback"];
    return;
  }
  if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    outcome.response_status = (int)[http statusCode];
    NSString *len = [[http allHeaderFields] objectForKey:@"Content-Length"];
    outcome.response_length = (len != nil) ? (int64_t)[len longLongValue] : -1;
  } else {
    /* A bare NSURLResponse is exactly the CAP-7M0 constraint-12 defect, so
       the stub records status 0 and the gate can assert against it. */
    outcome.response_status = 0;
  }
}

- (void)didReceiveData:(NSData *)data {
  if (outcome.finished || outcome.failed) {
    [self raiseMisuse:@"data after a terminal callback"];
    return;
  }
  const unsigned char *p = (const unsigned char *)[data bytes];
  const NSUInteger n = [data length];
  outcome.received_bytes += (int64_t)n;
  for (NSUInteger i = 0; i < n; ++i) {
    outcome.body_hash ^= (uint32_t)p[i];
    outcome.body_hash *= 16777619u;
  }
}

- (void)didFinish {
  if (outcome.finished || outcome.failed) {
    [self raiseMisuse:@"a second terminal callback"];
    return;
  }
  outcome.finished = 1;
}

- (void)didFailWithError:(NSError *)error {
  (void)error;
  if (outcome.finished || outcome.failed) {
    [self raiseMisuse:@"a second terminal callback"];
    return;
  }
  outcome.failed = 1;
}

@end

uint64_t pweb_cocoa_stub_task_create(const char *absolute_url) {
  PWebCocoaStubTask *task = nil;
  if (absolute_url == NULL) {
    return 0;
  }
  @autoreleasepool {
    @try {
      NSString *url = [NSString stringWithUTF8String:absolute_url];
      if (url != nil) {
        task = [[PWebCocoaStubTask alloc] initWithUrl:url];
      }
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
      task = nil;
    }
  }
  return (uint64_t)(uintptr_t)task;
}

void pweb_cocoa_stub_task_release(uint64_t task) {
  PWebCocoaStubTask *stub = (PWebCocoaStubTask *)(uintptr_t)task;
  if (stub != nil) {
    [stub release];
  }
}

void pweb_cocoa_stub_task_start(uint64_t task) {
  PWebCocoaStubTask *stub = (PWebCocoaStubTask *)(uintptr_t)task;
  if ((stub == nil) || (g_handler == nil)) {
    return;
  }
  [g_handler handleTask:(id<WKURLSchemeTask>)stub];
}

void pweb_cocoa_stub_task_stop(uint64_t task) {
  PWebCocoaStubTask *stub = (PWebCocoaStubTask *)(uintptr_t)task;
  if ((stub == nil) || (g_handler == nil)) {
    return;
  }
  [g_handler cancelTask:(id<WKURLSchemeTask>)stub];
}

void pweb_cocoa_stub_task_leave_live(uint64_t task) {
  PWebCocoaStubTask *stub = (PWebCocoaStubTask *)(uintptr_t)task;
  if ((stub == nil) || (g_handler == nil)) {
    return;
  }
  /* Tracks the task exactly as startURLSchemeTask: does and then returns
     WITHOUT completing it - the state a chunked or deferred delivery would
     routinely produce and this synchronous handler never produces on its own.
     It exists so teardown's claim-and-fail is proven rather than vacuous. */
  @autoreleasepool {
    @try {
      [g_handler trackTaskOnly:(id<WKURLSchemeTask>)stub];
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
  }
}

void pweb_cocoa_stub_task_deliver_again(uint64_t task) {
  PWebCocoaStubTask *stub = (PWebCocoaStubTask *)(uintptr_t)task;
  if ((stub == nil) || (g_handler == nil)) {
    return;
  }
  @autoreleasepool {
    @try {
      /* Goes through the SAME claim gate every terminal delivery goes
         through. With the gate in place this is suppressed and the stub never
         sees it; without it, the stub raises and misuse_raised becomes 1. */
      if ([g_handler claimTask:(id<WKURLSchemeTask>)stub
                            as:PWEB_TASK_COMPLETED]) {
        [(id<WKURLSchemeTask>)stub didFinish];
        [g_handler settleTask:(id<WKURLSchemeTask>)stub];
      } else {
        pweb_bump(&g_suppressed_terminals);
      }
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
  }
}

void pweb_cocoa_stub_task_outcome(uint64_t task,
                                  pweb_cocoa_stub_outcome_t *out) {
  PWebCocoaStubTask *stub = (PWebCocoaStubTask *)(uintptr_t)task;
  if (out == NULL) {
    return;
  }
  memset(out, 0, sizeof(*out));
  if (stub == nil) {
    return;
  }
  *out = stub->outcome;
}
