/*
 * pweb_cocoa_bridge.mm - the production Objective-C++ half of PWeb's macOS
 * pweb://app adapter. See pweb_cocoa_bridge.h for what this is, what it is
 * deliberately not, and the ownership model.
 *
 * THE WHOLE FILE IS THE THINGS PASCAL CANNOT EXPRESS: an override of
 * +[WKWebViewConfiguration new] on that class's own metaclass, an
 * @try/@catch barrier at every seam entry, an NSHTTPURLResponse, a
 * WKNavigationDelegate whose answers are delivered through blocks, and
 * -[NSWorkspace openURL:]. Everything else - the URI verdict, the store, the
 * MIME table, the refusal policy, the navigation classification and the CSP
 * string - stays in shared Pascal, unchanged and unduplicated.
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

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#include <fenv.h>
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
static uint64_t g_policy_headers_missing = 0;

/* CAP-8B navigation counters. Separate from the asset ones on purpose: a gate
   reading "cancelled" must never be reading a refused asset request. */
static uint64_t g_nav_action_decisions = 0;
static uint64_t g_nav_response_decisions = 0;
static uint64_t g_nav_download_events = 0;
static uint64_t g_nav_allowed = 0;
static uint64_t g_nav_cancelled = 0;
static uint64_t g_nav_handlers_completed = 0;
static uint64_t g_nav_unresolved_handles = 0;
static uint64_t g_nav_caught_exceptions = 0;

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

/* Split the Pascal security-header block into `headers`.
 *
 * The block is CRLF-separated `Name: Value` lines, produced by
 * PWebNativeSecurityHeaders. Splitting is ALL that happens here: no line is
 * synthesised, none is rewritten, and none is added when the block is empty -
 * because the policy has exactly one home and a bridge that could invent a
 * header would be a second one.
 *
 * A malformed line is SKIPPED rather than repaired: a header this file had to
 * guess at is not the header that was ratified. What the caller needs to know
 * is HOW MANY lines actually applied - the Pascal side refuses an empty block
 * before handing over, and serveTask: refuses the response when a NON-empty
 * block applied nothing, so "skipped everything" can never reach a page as
 * "served without a policy". Returning the count is what makes that second
 * refusal possible.
 */
static unsigned long pweb_apply_security_headers(NSMutableDictionary *headers,
                                                 const char *block) {
  unsigned long applied = 0;
  if ((headers == nil) || (block == NULL) || (block[0] == '\0')) {
    return 0;
  }
  NSString *all = [NSString stringWithUTF8String:block];
  if (all == nil) {
    return 0;
  }
  NSArray *lines = [all componentsSeparatedByString:@"\r\n"];
  for (NSString *line in lines) {
    const NSRange colon = [line rangeOfString:@":"];
    if ((colon.location == NSNotFound) || (colon.location == 0)) {
      continue; /* not a header line, and not something to repair */
    }
    NSString *name = [line substringToIndex:colon.location];
    NSString *value = [[line substringFromIndex:(colon.location + 1)]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
    if (([name length] == 0) || ([value length] == 0)) {
      continue;
    }
    [headers setObject:value forKey:name];
    applied += 1;
  }
  return applied;
}

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
  NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithCapacity:8];
  /* THE CAP-8B NATIVE POLICY, FIRST. MEASURED (M3): these header fields are
     enforced on pweb://app and a weaker bundle <meta> policy cannot relax a
     single row of them - which is what makes the CSP a property of the ENGINE
     rather than of the bundle a tamperer can edit. The rows are decided in
     src/security/pweb.navigation.policy.pas and merely transported here. */
  const unsigned long headers_applied =
      pweb_apply_security_headers(headers, asset->security_headers);
  if ((asset->security_headers[0] != '\0') && (headers_applied == 0)) {
    /* A NON-empty policy block out of which not one header line parsed is a
       policy that would be silently dropped on the way to the engine. Refuse
       the response instead of serving it naked - the same fail-closed answer
       the Pascal side already gives an empty or oversized block. The body
       NSData above owns asset->bytes and the autorelease pool frees it. */
    @try {
      NSError *error = [NSError errorWithDomain:@"pweb" code:1 userInfo:nil];
      [task didFailWithError:error];
      pweb_bump(&g_tasks_refused);
    } @catch (NSException *e) {
      (void)e;
      pweb_bump(&g_caught_exceptions);
    }
    [self settleTask:task];
    return;
  }
  /* ...AND THE TWO FACTS ABOUT THE BODY LAST, so they win. The policy block is
     a Pascal-side constant today, but a header line that could displace
     Content-Type would be a sniffing hole reachable by editing one string, and
     an ordering that makes that impossible costs nothing. */
  [headers setObject:mime forKey:@"Content-Type"];
  /* CAP-10C2: the engine must not answer a later request for this URL out of
     its own cache. The WebView2 adapter has sent this since CAP-4W; the two
     WebKit adapters did not, and MEASURED on WebKitGTK the consequence is
     exact: after the first document load the engine stops asking the store
     for `assets/app.js` at all, so a `pweb dev` generation switch re-runs the
     page against the PREVIOUS bundle's JavaScript. With the header the store
     is asked on every navigation and the page tracks the archive. It is not a
     development affordance: `app.pwb` is a replaceable, privileged bundle,
     and an engine cache is not something this runtime can invalidate. */
  [headers setObject:@"no-store" forKey:@"Cache-Control"];
  [headers setObject:[NSString stringWithFormat:@"%lld", (long long)[data length]]
              forKey:@"Content-Length"];
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
      /* CAP-8B, and it FAILS CLOSED rather than serving bare. Pascal attaches
         nosniff and Referrer-Policy to every asset and the CSP to every HTML
         one; an empty block means the policy layer did not run, and a
         privileged document served without it is precisely the state this
         shard exists to make unreachable. Refusing costs one asset; serving
         would cost the invariant. */
      if (asset.security_headers[0] == '\0') {
        pweb_bump(&g_policy_headers_missing);
        pweb_cocoa_free(asset.bytes);
        asset.bytes = NULL;
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
  out->policy_headers_missing = pweb_read(&g_policy_headers_missing);
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

int pweb_cocoa_mask_fpu_traps(void) {
  /* MEASURED, run 31951505821 on macos-x64: without this, EVERY cycle of the
     production runtime harness dies with
     `EInvalidOp: Invalid floating point operation` before a single asset is
     served - three cycles, three identical failures.

     This is CAP-7L's Linux defect on a second platform, and it did not
     transfer because the Linux remedy is x86-only. FPC does not leave the FPU
     in the C default state: it deliberately ENABLES the invalid-operation,
     divide-by-zero and overflow traps at startup on both architectures
     (rtl/aarch64/aarch64.inc:133 sets fpu_ioe|fpu_dze|fpu_ofe in FPCR; the
     x86_64 RTL does the equivalent to the x87 control word and MXCSR).
     WebKit, CoreGraphics and AppKit compute with NaNs, infinities and
     denormals as ordinary intermediate values - entirely legal IEEE-754
     arithmetic - so the first such computation traps inside a C frame that
     has no handler and the process dies.

     Note what the same run proves from the other side: `cap7m_probe`, the
     retained M0 instrument, drives a real WKWebView through the identical
     path and PASSES - because it is a pure C++ program that never had the
     traps enabled. Only the FPC-hosted process dies. That asymmetry is the
     diagnosis.

     fesetenv(FE_DFL_ENV) IS THE WHOLE FIX, and it is deliberately not
     hand-written bit-twiddling. The x86_64 remedy (x87 CW bits 0..5, MXCSR
     bits 7..12) and the AArch64 one (FPCR bits 8..12 and 15) are different
     registers with OPPOSITE polarity - 1 means "masked" on x86, 1 means
     "trap enabled" on ARM - and getting that backwards would silently leave
     the traps live on one architecture. FE_DFL_ENV is the C99 default
     environment, which by IEEE-754 has every trap disabled, and libc knows
     which register it lives in. FPC's getfpcr/setfpcr are not an option:
     they are implementation-internal to the system unit and are not exported
     by systemh.inc.

     It also normalises the rounding mode to FE_TONEAREST. That is not a
     behaviour change: FPC already rounds to nearest on both targets
     (rtl/aarch64/aarch64.inc:129 clears the FPCR rounding bits). As on Linux,
     this changes only how the FPU REPORTS exceptional results, never the
     results themselves.

     Returns 0 on success, which the caller treats as mandatory. */
  return fesetenv(FE_DFL_ENV);
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

/* ===================== CAP-8B: THE NAVIGATION SEAM ======================= *
 *
 * See the header for the invariant and for why no callback here may ever
 * reach pweb_cocoa_open_external. Three things are true of every hook below
 * and are the whole reason they are written this way:
 *
 *   THE ANSWER IS DECIDED BEFORE THE BARRIER. `policy` is initialised to
 *   Cancel and is only ever widened by a classifier that said Allow, so an
 *   exception, a nil object, a disowned seam and an unresolvable handle all
 *   land on the same refusal without anyone having to remember to write one.
 *
 *   THE DECISION HANDLER IS INVOKED EXACTLY ONCE ON EVERY PATH. WebKit hangs
 *   on a decision handler that is never called and raises on one called
 *   twice, so the call sits OUTSIDE the barrier, after it, unconditionally -
 *   and g_nav_handlers_completed lets a gate assert the property instead of a
 *   reader asserting it.
 *
 *   NOTHING HERE CLASSIFIES. The hooks translate WebKit's frame facts into
 *   the classifier's TPWebNavKind and translate its answer back. There is no
 *   URI comparison, no scheme test and no allowlist in this file.
 */

/* R-C4 (CAP-8C, human-ratified): PER-VIEW arming.

   The delegate OBJECT stays a process-wide singleton (WebKit holds it
   weakly; the global below keeps it alive), but the POLICY BINDING is per
   view: each armed guard handle is bound to exactly one WKWebView, and every
   decision resolves the ARRIVING view to ITS handle - so two privileged
   windows each answer through their own generation-checked Pascal guard,
   with their own per-slot counters, through one shared classifier.

   The two-step Create/Attach shape of the Pascal adapter is preserved
   exactly: pweb_cocoa_nav_arm STAGES a handle (armed, awaiting its view) and
   pweb_cocoa_nav_attach BINDS the staged handle to the view it is called
   with. A second arm while another handle is still staged-unattached is
   refused with the same one-armed message as before - that misuse (two
   guards racing for one pending slot, or double-arming one view) remains a
   loud pre-flight, never a silent rebinding.

   A view with NO binding fails closed: the delegate cancels without calling
   out, exactly as the disowned state always has. Slots are cleared handle
   first, view second, so a concurrent lookup can never read a stale pair
   (disown is callable from any thread; everything else here is main-thread
   affine). */
#define PWEB_COCOA_NAV_MAX_VIEWS 8
typedef struct pweb_nav_binding {
  void *view;      /* the WKWebView this binding serves; NULL = free slot */
  uint64_t handle; /* the generation-checked Pascal handle; 0 = disowned */
} pweb_nav_binding_t;
static pweb_nav_binding_t g_nav_bindings[PWEB_COCOA_NAV_MAX_VIEWS];
/* the handle armed by pweb_cocoa_nav_arm and not yet bound to a view */
static uint64_t g_nav_pending_handle = 0;
static pweb_cocoa_nav_fn g_nav_decide = NULL;
static int g_nav_installed = 0;

/* the binding lookup the delegate performs per decision: the ARRIVING view,
   never a process-global answer. Returns 0 when the view is unbound. */
static uint64_t pweb_nav_handle_for_view(void *view) {
  int i;
  if (view == NULL) {
    return 0;
  }
  for (i = 0; i < PWEB_COCOA_NAV_MAX_VIEWS; i++) {
    void *bound = __atomic_load_n(&g_nav_bindings[i].view, __ATOMIC_SEQ_CST);
    if (bound == view) {
      return __atomic_load_n(&g_nav_bindings[i].handle, __ATOMIC_SEQ_CST);
    }
  }
  return 0;
}

@interface PWebCocoaNavigationDelegate : NSObject <WKNavigationDelegate>
/* the ONE call out, and the only place a WebKit object becomes scalars */
- (BOOL)allowUrl:(NSURL *)url
         forView:(WKWebView *)view
            kind:(int)kind
       activated:(BOOL)activated;
- (void)refuseDownload:(WKDownload *)download;
@end

/* Referenced by -[WKWebView setNavigationDelegate:], which holds it WEAKLY;
   this global is what keeps it alive, exactly as g_handler is for the scheme
   handler. Created once and never released. */
static PWebCocoaNavigationDelegate *g_nav_delegate = nil;

@implementation PWebCocoaNavigationDelegate

- (BOOL)allowUrl:(NSURL *)url
         forView:(WKWebView *)view
            kind:(int)kind
       activated:(BOOL)activated {
  /* R-C4: the ARRIVING view resolves to ITS OWN guard handle - never a
     process-global answer, so two privileged windows cannot consult each
     other's policy binding or per-slot counters. */
  const uint64_t handle = pweb_nav_handle_for_view((void *)view);
  pweb_cocoa_nav_fn decide = g_nav_decide;
  if ((handle == 0) || (decide == NULL)) {
    /* disowned, unbound, or never armed: refuse, and NEVER call out. This is
       the state teardown leaves behind, and it must not be a state in which
       untrusted content can commit. */
    return NO;
  }
  /* THE URI IS THE WHOLE URI, for the same reason the asset seam insists on
     it: a path-only view of pweb://evil/x reads as /x, and the authority is
     the entire question. */
  NSString *absolute = (url != nil) ? [url absoluteString] : nil;
  const char *absolute_c = (absolute != nil) ? [absolute UTF8String] : NULL;
  if (absolute_c == NULL) {
    return NO; /* a URI this frame cannot even read is not a trusted one */
  }
  const int verdict = decide(handle, absolute_c, kind, activated ? 1 : 0);
  if (verdict == PWEB_COCOA_NAV_UNRESOLVED) {
    /* a released or never-claimed handler: counted separately, then refused
       exactly as for a Cancel, because a page must not tell the two apart */
    pweb_bump(&g_nav_unresolved_handles);
    return NO;
  }
  return (verdict == PWEB_COCOA_NAV_ALLOW) ? YES : NO;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:
                        (void (^)(WKNavigationActionPolicy))decisionHandler {
  WKNavigationActionPolicy policy = WKNavigationActionPolicyCancel;
  pweb_bump(&g_nav_action_decisions);
  @try {
    /* MEASURED (M2), and it is what lets this engine enforce the frame rules
       STRUCTURALLY where WebKitGTK cannot (L2 - frame discrimination MEASURED
       ABSENT there, so Linux leans on frame-src 'none'):
         targetFrame == nil  -> the action would open a NEW WINDOW. This is
           this backend's NewWindowRequested and the only place a target=_blank
           or window.open is refusable BEFORE upstream's WKUIDelegate - which
           owns the open panel and is deliberately not displaced - is consulted
           at all.
         otherwise isMainFrame separates a subframe from the document. */
    WKFrameInfo *target = [action targetFrame];
    int kind;
    if (target == nil) {
      kind = PWEB_COCOA_NAV_KIND_NEWWINDOW;
    } else if ([target isMainFrame] == NO) {
      kind = PWEB_COCOA_NAV_KIND_SUBFRAME;
    } else {
      kind = PWEB_COCOA_NAV_KIND_DOCUMENT;
    }
    /* -[WKNavigationAction shouldPerformDownload] is deliberately NOT folded
       into `kind`: the ratified mapping is frame-structural, and a download is
       refused where it becomes one, in didBecomeDownload: below. Two places
       deciding the same thing is how the two stop agreeing. */

    /* DIAGNOSTIC ONLY, and on this engine it is a DERIVATION rather than a
       measurement. MEASURED (M4): WKWebView publishes no gesture flag at all -
       -[WKNavigationAction _isUserInitiated] is private SPI and is forbidden
       here - and navigationType alone accepts a script-driven element.click().
       The classifier is required not to read this, the headless corpus proves
       it by running every row twice with the flag inverted, and it is carried
       only so the evidence record can compare targets. */
    const BOOL activated =
        ([action navigationType] == WKNavigationTypeLinkActivated);

    if ([self allowUrl:[[action request] URL]
               forView:webView
                  kind:kind
             activated:activated]) {
      policy = WKNavigationActionPolicyAllow;
    }
    /* NEVER WKNavigationActionPolicyDownload: this WebView writes nothing. */
  } @catch (NSException *ex) {
    (void)ex;
    pweb_bump(&g_nav_caught_exceptions);
    policy = WKNavigationActionPolicyCancel;
  } @catch (...) {
    pweb_bump(&g_nav_caught_exceptions);
    policy = WKNavigationActionPolicyCancel;
  }
  if (policy == WKNavigationActionPolicyAllow) {
    pweb_bump(&g_nav_allowed);
  } else {
    pweb_bump(&g_nav_cancelled);
  }
  @try {
    if (decisionHandler != nil) {
      decisionHandler(policy);
      pweb_bump(&g_nav_handlers_completed);
    }
  } @catch (NSException *ex) {
    (void)ex;
    pweb_bump(&g_nav_caught_exceptions);
  } @catch (...) {
    pweb_bump(&g_nav_caught_exceptions);
  }
}

/* The second gate, on the RESPONSE rather than the request. It is not
   redundant: the action hook judged the URI the frame asked for, and this one
   judges the URI a response actually arrived for, which is the only hook that
   sees a server-side redirect's destination. Same classifier, same two
   answers, and never WKNavigationResponsePolicyDownload - converting a
   response WebKit cannot display into a download is exactly what a privileged
   WebView must not do. */
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:
                          (void (^)(WKNavigationResponsePolicy))decisionHandler {
  WKNavigationResponsePolicy policy = WKNavigationResponsePolicyCancel;
  pweb_bump(&g_nav_response_decisions);
  @try {
    const int kind = ([navigationResponse isForMainFrame] != NO)
                         ? PWEB_COCOA_NAV_KIND_DOCUMENT
                         : PWEB_COCOA_NAV_KIND_SUBFRAME;
    /* no WKNavigationAction here, so there is no navigationType to derive
       from; the flag is diagnostic anyway and is reported as absent rather
       than invented */
    if ([self allowUrl:[[navigationResponse response] URL]
               forView:webView
                  kind:kind
             activated:NO]) {
      policy = WKNavigationResponsePolicyAllow;
    }
  } @catch (NSException *ex) {
    (void)ex;
    pweb_bump(&g_nav_caught_exceptions);
    policy = WKNavigationResponsePolicyCancel;
  } @catch (...) {
    pweb_bump(&g_nav_caught_exceptions);
    policy = WKNavigationResponsePolicyCancel;
  }
  if (policy == WKNavigationResponsePolicyAllow) {
    pweb_bump(&g_nav_allowed);
  } else {
    pweb_bump(&g_nav_cancelled);
  }
  @try {
    if (decisionHandler != nil) {
      decisionHandler(policy);
      pweb_bump(&g_nav_handlers_completed);
    }
  } @catch (NSException *ex) {
    (void)ex;
    pweb_bump(&g_nav_caught_exceptions);
  } @catch (...) {
    pweb_bump(&g_nav_caught_exceptions);
  }
}

/* A privileged WebView never writes a download. The classifier's pnkDownload
   row is a constant refusal, so there is no question to ask here and this hook
   does not pretend to ask one - asking would only create a branch on which an
   answer could be honoured.
 *
 * NO WKDownloadDelegate IS SET, deliberately, and that is a second refusal
 * rather than an omission: without a delegate no destination is ever decided,
 * so nothing reaches the disk even if the cancel were to fail. Both hooks are
 * macOS 11.3, below the pinned 12.0 deployment target, so neither needs an
 * @available guard. */
- (void)refuseDownload:(WKDownload *)download {
  pweb_bump(&g_nav_download_events);
  @try {
    if (download != nil) {
      [download cancel:nil];
    }
  } @catch (NSException *ex) {
    (void)ex;
    pweb_bump(&g_nav_caught_exceptions);
  } @catch (...) {
    pweb_bump(&g_nav_caught_exceptions);
  }
}

- (void)webView:(WKWebView *)webView
     navigationAction:(WKNavigationAction *)navigationAction
    didBecomeDownload:(WKDownload *)download {
  (void)webView;
  (void)navigationAction;
  [self refuseDownload:download];
}

- (void)webView:(WKWebView *)webView
    navigationResponse:(WKNavigationResponse *)navigationResponse
     didBecomeDownload:(WKDownload *)download {
  (void)webView;
  (void)navigationResponse;
  [self refuseDownload:download];
}

@end

int pweb_cocoa_nav_install(pweb_cocoa_nav_fn decide) {
  int ok = 0;
  if (decide == NULL) {
    return 0;
  }
  @autoreleasepool {
    @try {
      if (g_nav_installed) {
        /* Idempotent, but the decision function is process-wide state: a
           second, DIFFERENT one would silently rebind every future
           navigation. */
        return (g_nav_decide == decide) ? 1 : 0;
      }
      if (g_nav_delegate == nil) {
        g_nav_delegate = [[PWebCocoaNavigationDelegate alloc] init];
      }
      if (g_nav_delegate == nil) {
        return 0;
      }
      g_nav_decide = decide;
      g_nav_installed = 1;
      ok = 1;
    } @catch (NSException *ex) {
      (void)ex;
      pweb_bump(&g_nav_caught_exceptions);
      ok = 0;
    } @catch (...) {
      pweb_bump(&g_nav_caught_exceptions);
      ok = 0;
    }
  }
  return ok;
}

int pweb_cocoa_nav_arm(uint64_t handle) {
  uint64_t expected = 0;
  if ((handle == 0) || !g_nav_installed) {
    return 0;
  }
  /* R-C4: arming STAGES this handle for the next attach; the per-view
     binding is committed by pweb_cocoa_nav_attach. Exactly one handle may be
     staged at a time - a second, different arm before the first was attached
     (two guards racing one pending slot, or an attempt to double-arm one
     view) is refused with the same loud pre-flight as ever, never silently
     resolved in someone's favour. */
  if (!__atomic_compare_exchange_n(&g_nav_pending_handle, &expected, handle,
                                   false, __ATOMIC_SEQ_CST,
                                   __ATOMIC_SEQ_CST)) {
    return (expected == handle) ? 1 : 0;
  }
  return 1;
}

void pweb_cocoa_nav_disown(uint64_t handle) {
  uint64_t expected = handle;
  int i;
  if (handle == 0) {
    return;
  }
  /* the staged-but-unattached state, if it is ours */
  (void)__atomic_compare_exchange_n(&g_nav_pending_handle, &expected,
                                    (uint64_t)0, false, __ATOMIC_SEQ_CST,
                                    __ATOMIC_SEQ_CST);
  /* and every per-view binding carrying this handle: handle first, view
     second, so a concurrent lookup can never resolve a stale pair (this is
     the one entry point callable from any thread) */
  for (i = 0; i < PWEB_COCOA_NAV_MAX_VIEWS; i++) {
    if (__atomic_load_n(&g_nav_bindings[i].handle, __ATOMIC_SEQ_CST) ==
        handle) {
      __atomic_store_n(&g_nav_bindings[i].handle, (uint64_t)0,
                       __ATOMIC_SEQ_CST);
      __atomic_store_n(&g_nav_bindings[i].view, (void *)NULL,
                       __ATOMIC_SEQ_CST);
    }
  }
}

int pweb_cocoa_nav_installed_on(void *view) {
  int verdict = PWEB_COCOA_READBACK_ABSENT;
  if ((view == NULL) || (g_nav_delegate == nil)) {
    return PWEB_COCOA_READBACK_ABSENT;
  }
  @autoreleasepool {
    @try {
      WKWebView *wv = (WKWebView *)view;
      id current = [wv navigationDelegate];
      if (current == (id)g_nav_delegate) {
        verdict = PWEB_COCOA_READBACK_OURS;
      } else if (current == nil) {
        verdict = PWEB_COCOA_READBACK_ABSENT;
      } else {
        verdict = PWEB_COCOA_READBACK_FOREIGN;
      }
    } @catch (NSException *ex) {
      (void)ex;
      pweb_bump(&g_nav_caught_exceptions);
      verdict = PWEB_COCOA_READBACK_ABSENT;
    } @catch (...) {
      pweb_bump(&g_nav_caught_exceptions);
      verdict = PWEB_COCOA_READBACK_ABSENT;
    }
  }
  return verdict;
}

int pweb_cocoa_nav_attach(void *view) {
  int ok = 0;
  uint64_t pending;
  int i;
  int slot = -1;
  if ((view == NULL) || !g_nav_installed || (g_nav_delegate == nil)) {
    return 0;
  }
  /* Attaching an UNARMED delegate would install a hook that cancels every
     navigation including the trusted one, which looks exactly like a broken
     engine. Refuse instead. (R-C4: "armed" is the STAGED handle awaiting
     this attach.) */
  pending = __atomic_load_n(&g_nav_pending_handle, __ATOMIC_SEQ_CST);
  if (pending == 0) {
    return 0;
  }
  /* R-C4: one binding per view - a view that already has one is a
     double-arm misuse and is refused loudly, exactly as before. */
  if (pweb_nav_handle_for_view(view) != 0) {
    return 0;
  }
  for (i = 0; i < PWEB_COCOA_NAV_MAX_VIEWS; i++) {
    if (__atomic_load_n(&g_nav_bindings[i].view, __ATOMIC_SEQ_CST) == NULL) {
      slot = i;
      break;
    }
  }
  if (slot < 0) {
    return 0; /* more live guarded views than the registry holds: refuse */
  }
  @autoreleasepool {
    @try {
      WKWebView *wv = (WKWebView *)view;
      id current = [wv navigationDelegate];
      if ((current != nil) && (current != (id)g_nav_delegate)) {
        /* Upstream leaves this seam unset (cocoa_webkit.hh:490-494 installs
           only its WKUIDelegate), so anything here belongs to someone else and
           displacing it would break them silently. Install NOTHING. */
        return 0;
      }
      [wv setNavigationDelegate:g_nav_delegate];
      /* READ BACK, so "attached" is a property of the view rather than the
         absence of an exception - the same reason Attach re-reads the scheme
         handler instead of trusting the seam counter. */
      ok = (pweb_cocoa_nav_installed_on(view) == PWEB_COCOA_READBACK_OURS) ? 1
                                                                          : 0;
      if (ok) {
        /* commit the per-view binding: handle first, view second, so a
           concurrent lookup that sees the view also sees its handle - then
           clear the staging slot for the next guard's arm */
        __atomic_store_n(&g_nav_bindings[slot].handle, pending,
                         __ATOMIC_SEQ_CST);
        __atomic_store_n(&g_nav_bindings[slot].view, view, __ATOMIC_SEQ_CST);
        __atomic_store_n(&g_nav_pending_handle, (uint64_t)0, __ATOMIC_SEQ_CST);
      }
    } @catch (NSException *ex) {
      (void)ex;
      pweb_bump(&g_nav_caught_exceptions);
      ok = 0;
    } @catch (...) {
      pweb_bump(&g_nav_caught_exceptions);
      ok = 0;
    }
  }
  return ok;
}

void pweb_cocoa_nav_detach(void *view) {
  int i;
  if (view == NULL) {
    return;
  }
  /* R-C4 defensive half: whatever the delegate state, THIS view's binding
     slot is cleared (handle first, view second) - the caller has already
     disowned by handle, so this only matters when the call orders drift,
     and then it fails closed rather than leaving a resolvable pair. */
  for (i = 0; i < PWEB_COCOA_NAV_MAX_VIEWS; i++) {
    if (__atomic_load_n(&g_nav_bindings[i].view, __ATOMIC_SEQ_CST) == view) {
      __atomic_store_n(&g_nav_bindings[i].handle, (uint64_t)0,
                       __ATOMIC_SEQ_CST);
      __atomic_store_n(&g_nav_bindings[i].view, (void *)NULL,
                       __ATOMIC_SEQ_CST);
    }
  }
  if (g_nav_delegate == nil) {
    return;
  }
  @autoreleasepool {
    @try {
      WKWebView *wv = (WKWebView *)view;
      /* ONLY if it is ours: clearing a delegate we never installed would be
         the same silent breakage attach refuses to cause. */
      if ([wv navigationDelegate] == (id)g_nav_delegate) {
        [wv setNavigationDelegate:nil];
      }
    } @catch (NSException *ex) {
      (void)ex;
      pweb_bump(&g_nav_caught_exceptions);
    } @catch (...) {
      pweb_bump(&g_nav_caught_exceptions);
    }
  }
}

void pweb_cocoa_nav_get_stats(pweb_cocoa_nav_stats_t *out) {
  if (out == NULL) {
    return;
  }
  memset(out, 0, sizeof(*out));
  out->action_decisions = pweb_read(&g_nav_action_decisions);
  out->response_decisions = pweb_read(&g_nav_response_decisions);
  out->download_events = pweb_read(&g_nav_download_events);
  out->allowed = pweb_read(&g_nav_allowed);
  out->cancelled = pweb_read(&g_nav_cancelled);
  out->handlers_completed = pweb_read(&g_nav_handlers_completed);
  out->unresolved_handles = pweb_read(&g_nav_unresolved_handles);
  out->caught_exceptions = pweb_read(&g_nav_caught_exceptions);
}

/* ------------------------- the system opener ----------------------------- */

typedef struct {
  const void *url; /* NSURL *, borrowed for the synchronous call's duration */
  int ok;
} pweb_open_main_ctx;

/* static, and dispatch_sync_f instead of a block ON PURPOSE: clang emits
   global ___copy_helper_block/___destroy_helper_block TEXT symbols for a
   block that captures an object pointer, and the CAP-7M1 seam gate rightly
   refuses any callable export that is not pweb_cocoa_* (measured: hosted run
   32739228213, both arches). A plain function pointer plus a stack context
   generates no helper symbols at all. The exception barrier lives HERE, on
   the executing thread - an NSException raised inside a GCD-submitted body
   does NOT propagate to the submitting thread's frame. */
static void pweb_cocoa_open_on_main(void *raw) {
  pweb_open_main_ctx *ctx = (pweb_open_main_ctx *)raw;
  @try {
    ctx->ok =
        ([[NSWorkspace sharedWorkspace] openURL:(NSURL *)ctx->url] != NO) ? 1
                                                                          : 0;
  } @catch (NSException *ex) {
    (void)ex;
    pweb_bump(&g_caught_exceptions);
    ctx->ok = 0;
  } @catch (...) {
    pweb_bump(&g_caught_exceptions);
    ctx->ok = 0;
  }
}

int pweb_cocoa_open_external(const char *uri) {
  int ok = 0;
  if ((uri == NULL) || (uri[0] == '\0')) {
    return 0;
  }
  @autoreleasepool {
    @try {
      /* AS DATA, start to finish: one NSString, one NSURL, one message. There
         is no shell here, no argument vector to quote and nothing to
         interpolate - which is why the ratification names this API rather than
         any launcher that takes a command line (R-A.8). The scheme allowlist
         is PWebValidExternalUri's, upstream of this call, so this function has
         no policy of its own to disagree with. */
      NSString *text = [NSString stringWithUTF8String:uri];
      if (text == nil) {
        return 0;
      }
      NSURL *url = [NSURL URLWithString:text];
      if (url == nil) {
        return 0; /* a URI Foundation will not parse is not one we hand on */
      }
      /* ON THE MAIN THREAD, by marshalling rather than by assumption:
         NSWorkspace is an AppKit object and this function is reached from a
         scheduler WORKER (a bridge invocation never runs on the GUI thread).
         dispatch_sync_f keeps the call synchronous - the caller still learns
         the real outcome - and the is-main-thread check keeps a future
         main-thread caller from deadlocking on itself. The NSURL is borrowed
         across the synchronous hop; this frame outlives it by construction. */
      if ([NSThread isMainThread]) {
        pweb_open_main_ctx here;
        here.url = url;
        here.ok = 0;
        pweb_cocoa_open_on_main(&here);
        ok = here.ok;
      } else {
        pweb_open_main_ctx ctx;
        ctx.url = url;
        ctx.ok = 0;
        dispatch_sync_f(dispatch_get_main_queue(), &ctx,
                        &pweb_cocoa_open_on_main);
        ok = ctx.ok;
      }
    } @catch (NSException *ex) {
      (void)ex;
      pweb_bump(&g_caught_exceptions);
      ok = 0;
    } @catch (...) {
      pweb_bump(&g_caught_exceptions);
      ok = 0;
    }
  }
  return ok;
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
