/*
 * CAP-7M0 feasibility probe: PROBES C, D, E, F, G and H in one bounded
 * Objective-C++ binary.
 *
 * THROWAWAY BY DESIGN. This file is a measuring instrument, not a draft of
 * the macOS adapter. It exists so that CAP-7M starts from measured facts
 * instead of from Apple's documentation and a hope, and so that one real
 * WKWebView proves the seam, the threading contract and the origin together
 * or not at all. Nothing here is mocked, substituted or headless.
 *
 * The macOS analogue of test/cap7l/cap7l_probe.c and test/cap4w/cap4w_probe.cpp,
 * and it follows the same conventions: MARKER key=value on stdout,
 * CAP7M_FAIL cycle=N reason=... on stderr, exit 0 (pass) / 1 (fail) / 2
 * (usage), watchdog-bounded, and the page reports its OWN facts as a JSON
 * object passed through window.__pweb_report - never inferred from "it
 * rendered".
 *
 * ============================ WHAT IT MEASURES ============================
 *
 * M6  (C) create -> title/size -> bind -> navigate -> render -> eval ->
 *         shutdown -> destroy, repeated. Cycles alternate the two shutdowns
 *         that a real app has: PROGRAMMATIC (webview_terminate) on odd
 *         cycles, USER-CLOSE (NSWindow close, which reaches upstream's
 *         windowWillClose: delegate) on even ones.
 *
 * M7  (D) the bind callback runs on the GUI thread; the service runs on a
 *         distinct worker; the worker's DIRECT webview_return resolves the
 *         JS promise. worker -> webview_dispatch -> webview_return is
 *         forbidden here exactly as it is in the product.
 *
 * M8  (D) eight concurrent invocations complete exactly once each; one
 *         forced error REJECTS with its payload intact; one invocation is
 *         deliberately still outstanding at shutdown and teardown drains it
 *         before webview_destroy; the callback's id/req are proven to be
 *         borrowed buffers by recording that the same address comes back.
 *
 * M9  (E) SEAM A: a handler set on webView.configuration AFTER
 *         webview_create. Apple documents that property as a COPY whose
 *         mutation "doesn't affect the web view's configuration", so this is
 *         expected to be ineffective - and an expected result still has to be
 *         measured. Uses its own scheme (pwebpost) so it cannot collide with
 *         the seam under test, and an ineffective result REFUSES seam A
 *         rather than failing the probe.
 *
 * M10 (E) SEAM B: a PWeb-owned pre-create seam. Upstream builds its
 *         WKWebViewConfiguration and its WKWebView both inside
 *         webview_create (cocoa_webkit.hh:450,486), so the only place a
 *         handler can be installed is between those two statements - from
 *         the outside. The seam is an override of +[WKWebViewConfiguration
 *         new] added with the PUBLIC Objective-C runtime, which calls
 *         [[cls alloc] init] (exactly what +new does) and then installs the
 *         handler with the PUBLIC setURLSchemeHandler:forURLScheme: before
 *         returning. deps/webview is not patched, the ABI does not change,
 *         and the export surface stays at 17.
 *
 * M11 (F) every URL that reaches the handler is captured VERBATIM and
 *         emitted. The probe itself never parses a URL: it serves an exact
 *         full-string allowlist and refuses everything else, so no second
 *         URI validator exists anywhere. PWebParseAppUri is the only thing
 *         that renders a verdict, and test/cap7m/uri_oracle.pas feeds it the
 *         captured strings afterwards.
 *
 * M12 (F) the hostile vectors are driven from the page: wrong authority,
 *         missing authority, .., %2e%2e, double-encoded, backslash,
 *         percent-encoded NUL and a malformed escape. A vector WebKit
 *         normalises or refuses before the handler is a recorded fact
 *         (defence in depth), not a substitute for the shared routine's
 *         verdict.
 *
 * M13 (G) the WKURLSchemeTask lifecycle. Unlike GIO, this API THROWS: Apple
 *         documents an NSException for a second response after completion,
 *         data before a response, finish before a response, finish/fail
 *         after either, and ANY callback after stopURLSchemeTask:. The
 *         terminal-state guard below is what a Pascal adapter will need, and
 *         a deliberate, contained post-stop callback measures that the guard
 *         is load-bearing rather than cargo-culted.
 *
 * M14 (G) whether WebKit copies the body at handoff. The response buffer is
 *         handed over with dataWithBytesNoCopy: and then POISONED in place
 *         the instant didReceiveData: returns. If the page still reads the
 *         original text, WebKit copied; if it reads the poison, WebKit kept
 *         the pointer and a Pascal adapter must keep the source alive. The
 *         buffer is deliberately never freed - measuring ownership must not
 *         become a use-after-free.
 *
 * M15 (H) the page states protocol/host/origin/isSecureContext. A false
 *         secure context is reported exactly and stops the shard.
 *
 * M20     no listener, no loopback, no HTTP: JS -> native stays
 *         webview_bind, in process. Proven from the outside by
 *         test/cap7m/check_cap7m_nonetwork.sh.
 *
 * Compiled WITHOUT ARC on purpose: the ownership of the +new return value,
 * of the retained tasks and of the response buffers is the very thing being
 * measured, and it has to be as explicit here as it will be in Pascal.
 *
 * Usage: cap7m_probe [cycles 1..20]
 */

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <mach/mach.h>
#include <objc/runtime.h>

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "webview/api.h"

#define PROBE_SCHEME @"pweb"
#define PROBE_POSTCREATE_SCHEME @"pwebpost"
#define PROBE_MAIN_URI "pweb://app/index.html"
#define PROBE_JS_URI "pweb://app/probe.js"
#define PROBE_CSS_URI "pweb://app/probe.css"
#define PROBE_HANDOFF_URI "pweb://app/handoff.txt"
#define PROBE_SLOW_URI "pweb://app/slow.bin"
#define PROBE_ECHOES 8
#define PROBE_TIMEOUT_SECONDS 60
/* A SECOND deadline, armed after the page reports and covering only the
   shutdown itself. The first one cannot: `finished` is set BEFORE the window
   is closed, so a close that never stops the run loop would sit inside
   webview_run with nothing watching it until the CI step timeout. */
#define PROBE_SHUTDOWN_SECONDS 20
#define PROBE_DRAIN_SECONDS 10
#define PROBE_HANDOFF_BODY "CAP7M-HANDOFF-OK"
/* M6 promises that a leak blocks, so the repeated create/destroy loop has to
   actually look. This is a coarse RUNAWAY detector and is described as one:
   WebKit legitimately grows its caches on the first navigation, so the bound
   is applied from cycle 2 onwards and is deliberately generous. A per-cycle
   leak of an entire WKWebView and its web content process shows up here; a
   few stray Objective-C objects will not, and this does not claim otherwise. */
#define PROBE_RSS_GROWTH_KB_PER_CYCLE_MAX 65536
#define PROBE_MIN_CYCLES_FOR_LEAK_CHECK 3

static const char kHtml[] =
    "<!doctype html><html><head><meta charset=\"utf-8\">"
    "<title>CAP-7M0</title>"
    "<link rel=\"stylesheet\" href=\"/probe.css\"></head>"
    "<body><main id=\"verdict\">CAP-7M0 PENDING</main>"
    "<script src=\"/probe.js\"></script></body></html>";

static const char kCss[] = "#verdict{color:rgb(1, 2, 3)}";

/* The page STATES every fact it is asked about. Nothing below is inferred
 * from the mere fact that something rendered. */
static const char kJs[] =
    "(async () => {"
    "  const out = {};"
    "  try {"
    "    out.protocol = location.protocol;"
    "    out.host = location.host;"
    "    out.origin = location.origin;"
    "    out.secure = window.isSecureContext === true;"
    /* webview_eval is ASYNCHRONOUS: evaluateJavaScript: returns immediately
       and the injected statement runs on a later turn, so reading a global
       right after the binding resolves is a race that would fail on a loaded
       machine and nowhere else. Wait for the injected code to say so. */
    "    const evaled = new Promise((r) => { window.__pweb_eval_seen = r; });"
    "    await window.__pweb_ready();"
    "    out.evaled = await Promise.race(["
    "      evaled.then(() => true),"
    "      new Promise((r) => setTimeout(() => r(false), 5000))"
    "    ]);"
    "    const node = document.getElementById('verdict');"
    "    out.css = getComputedStyle(node).color === 'rgb(1, 2, 3)';"
    "    const echoes = [];"
    "    for (let i = 0; i < 8; i++) { echoes.push(window.__pweb_invoke(i)); }"
    "    const values = await Promise.all(echoes);"
    "    out.concurrency = values.length === 8 &&"
    "      values.every((v, i) => Number(v) === i * 2 + 1);"
    "    out.rejected = false; out.payload = null;"
    "    try { await window.__pweb_fail('go'); }"
    "    catch (e) { out.rejected = true;"
    "      out.payload = (e && e.detail) ? e.detail : String(e); }"
    "    out.payloadintact = out.payload === 'payload-intact-42';"
    "    const blocked = async (u) => {"
    "      try { const r = await fetch(u); return r.ok === false; }"
    "      catch (e) { return true; }"
    "    };"
    "    out.wronghost = await blocked('pweb://evil/x');"
    "    out.emptyhost = await blocked('pweb:///x');"
    "    out.dotdot = await blocked('pweb://app/../secret');"
    "    out.encdotdot = await blocked('pweb://app/%2e%2e/secret');"
    "    out.dblenc = await blocked('pweb://app/%252e%252e/secret');"
    "    out.backslash = await blocked('pweb://app/a\\\\b');"
    "    out.nul = await blocked('pweb://app/a%00b');"
    "    out.badpercent = await blocked('pweb://app/a%zz');"
    "    out.notfound = await blocked('pweb://app/missing.txt');"
    /* M9 drives the request but does NOT decide the verdict from here: this
       fetch fails identically whether no handler is registered on the live
       configuration or a handler is registered and refuses. Only the
       handler-side counter can tell those apart, so the seam-A verdict is
       emitted natively as CAP7M_M9 and this is recorded for information. */
    "    out.postcreate_fetch_blocked = await blocked('pwebpost://app/probe');"
    "    const ok = await fetch('pweb://app/probe.css');"
    "    out.subresource = ok.ok === true;"
    /* M14: informative in BOTH directions - reading the original text means
       WebKit copied at handoff, reading the poison means it kept the pointer
       and a Pascal adapter must hold its source buffer alive until didFinish.
       Deliberately NOT part of out.ok: the second answer is a finding CAP-7M
       needs, not a probe failure. */
    "    const h = await fetch('pweb://app/handoff.txt');"
    "    out.handoff = (await h.text()) === 'CAP7M-HANDOFF-OK';"
    /* M13: the abort must land DURING data delivery. fetch() resolves at
       didReceiveResponse, so aborting a promise that has already settled
       does nothing at all - the body has to be awaited for the cancellation
       path to be exercised, which is the whole point of the case. */
    "    const ac = new AbortController();"
    "    const slow = fetch('pweb://app/slow.bin', { signal: ac.signal })"
    "      .then((r) => r.arrayBuffer());"
    "    setTimeout(() => ac.abort(), 50);"
    "    try { await slow; out.aborted = false; }"
    "    catch (e) { out.aborted = true; }"
    /* deliberately NOT awaited: one invocation is still in flight when the
       shutdown below begins, which is the whole point of M8's last third */
    "    window.__pweb_slow().then(() => {}, () => {});"
    /* out.handoff (M14), out.aborted (M13) and out.postcreate_fetch_blocked
       (M9) are RECORDED, not required: each is informative in both
       directions and each is emitted as its own native marker. Folding a
       measurement into the pass condition turns "we learned something" into
       "the shard failed". */
    "    out.ok = out.protocol === 'pweb:' && out.host === 'app' &&"
    "      out.origin === 'pweb://app' && out.secure && out.css &&"
    "      out.evaled && out.concurrency && out.rejected &&"
    "      out.payloadintact && out.wronghost && out.emptyhost &&"
    "      out.dotdot && out.encdotdot && out.dblenc && out.backslash &&"
    "      out.nul && out.badpercent && out.notfound && out.subresource;"
    "    node.textContent = out.ok ? 'CAP-7M0 PASS' : 'CAP-7M0 FAIL';"
    "  } catch (e) {"
    "    out.ok = false;"
    "    out.error = String(e);"
    "  }"
    /* the object, NOT JSON.stringify(out): webview serialises the argument
       itself, so a string would arrive double-encoded and every substring
       check below would silently miss */
    "  window.__pweb_report(out);"
    "})();";

/* ---------------------------------------------------------------------- */

struct probe_state {
  webview_t webview;
  unsigned cycle;
  int close_by_window; /* this cycle shuts down through NSWindow close */

  pthread_mutex_t mutex;
  pthread_cond_t wake;

  int finished;     /* the page reported, or a shutdown was requested */
  int run_returned; /* webview_run actually came back - NOT the same thing */
  int failed;
  int passed;

  /* M14/M13: recorded verdicts, parsed out of the page's own report. -1
     means the page never got far enough to state them. */
  int handoff_copied;
  int abort_delivered;

  unsigned main_requests;
  unsigned js_requests;
  unsigned css_requests;
  unsigned handoff_requests;
  unsigned slow_requests;
  unsigned refused_requests;
  unsigned postcreate_requests; /* M9: hits on the post-create scheme */

  unsigned stop_calls;          /* M13: stopURLSchemeTask: arrivals */
  unsigned caught_exceptions;   /* M13: NSExceptions caught at the boundary */
  int poststop_throws;          /* M13: -1 unknown, 0 no, 1 yes */

  unsigned echo_returns;
  unsigned error_returns;
  unsigned slow_returns;
  unsigned pending_workers;

  unsigned long gui_thread;
  int worker_was_distinct;

  const char *last_id_ptr; /* M8: borrowed-buffer evidence */
  int id_ptr_reused;

  char failure[512];
  char report[8192];
};

/* M6: resident size of THIS process, for the per-cycle leak bound. */
static unsigned long probe_rss_kb(void) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return (unsigned long)(info.resident_size / 1024u);
}

static void probe_fail(struct probe_state *state, const char *message) {
  pthread_mutex_lock(&state->mutex);
  if (!state->failed) {
    state->failed = 1;
    snprintf(state->failure, sizeof(state->failure), "%s", message);
  }
  pthread_cond_broadcast(&state->wake);
  pthread_mutex_unlock(&state->mutex);
}

/* ----------------------- the scheme handler ----------------------------- */

/*
 * The terminal-state guard M13 exists to design. Every task is tracked from
 * startURLSchemeTask: until it reaches a terminal callback OR is stopped, and
 * NOTHING is sent to a task that is not in that set. Apple raises an
 * NSException for each of those mistakes, and an NSException crossing into a
 * C++ - or later a Pascal - frame is undefined behaviour, not an error path.
 */
@interface PWebProbeSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, assign) struct probe_state *owner; /* NULL == disowned */
@end

@implementation PWebProbeSchemeHandler {
  NSMutableSet *_live; /* NSValue of the task pointer */
  NSLock *_lock;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _live = [[NSMutableSet alloc] init];
    _lock = [[NSLock alloc] init];
    _owner = NULL;
  }
  return self;
}

- (void)dealloc {
  [_live release];
  [_lock release];
  [super dealloc];
}

- (void)trackTask:(id<WKURLSchemeTask>)task {
  [_lock lock];
  [_live addObject:[NSValue valueWithPointer:task]];
  [_lock unlock];
}

/* Returns YES exactly once per task: the caller that takes the task out of
 * the live set owns the right to send it a terminal callback. */
- (BOOL)claimTask:(id<WKURLSchemeTask>)task {
  BOOL claimed = NO;
  NSValue *key = [NSValue valueWithPointer:task];
  [_lock lock];
  if ([_live containsObject:key]) {
    [_live removeObject:key];
    claimed = YES;
  }
  [_lock unlock];
  return claimed;
}

- (BOOL)isLive:(id<WKURLSchemeTask>)task {
  BOOL live;
  [_lock lock];
  live = [_live containsObject:[NSValue valueWithPointer:task]];
  [_lock unlock];
  return live;
}

/* Called at teardown. The set is keyed by task ADDRESS, and the allocator
   reuses addresses freely, so a task abandoned when cycle N's run loop
   stopped can alias a brand-new task in cycle N+1 - at which point isLive:
   answers YES for something this handler has never seen and claimTask:
   hands out a terminal callback that was already spent. Cycles do not share
   tasks, so the honest reset is to empty the set between them. */
- (void)resetTasks {
  [_lock lock];
  [_live removeAllObjects];
  [_lock unlock];
}

- (void)finishRefused:(id<WKURLSchemeTask>)task {
  /* Wrong authority, non-canonical path, missing asset and internal failure
     are ONE outcome with no reason attached, exactly like the Windows
     constant 404 and the Linux constant GError. */
  if (![self claimTask:task]) {
    return;
  }
  NSError *error = [NSError errorWithDomain:@"CAP7M"
                                       code:1
                                   userInfo:nil];
  [task didFailWithError:error];
}

- (void)finishBody:(id<WKURLSchemeTask>)task
              data:(NSData *)data
              type:(NSString *)mime {
  if (![self claimTask:task]) {
    return;
  }
  NSURLResponse *response =
      [[[NSURLResponse alloc] initWithURL:[[task request] URL]
                                 MIMEType:mime
                    expectedContentLength:(NSInteger)[data length]
                         textEncodingName:@"utf-8"] autorelease];
  [task didReceiveResponse:response];
  [task didReceiveData:data];
  [task didFinish];
}

/* M14: hand the body over WITHOUT a copy, then poison the source buffer the
 * instant didReceiveData: returns. What the page reads afterwards settles
 * whether WebKit copies at handoff or keeps the pointer. */
- (void)finishHandoff:(id<WKURLSchemeTask>)task {
  if (![self claimTask:task]) {
    return;
  }
  const size_t n = strlen(PROBE_HANDOFF_BODY);
  /* deliberately never freed: measuring ownership must not itself become a
     use-after-free, and this is a bounded probe */
  void *buffer = malloc(n);
  if (buffer == NULL) {
    NSError *error = [NSError errorWithDomain:@"CAP7M" code:2 userInfo:nil];
    [task didFailWithError:error];
    return;
  }
  memcpy(buffer, PROBE_HANDOFF_BODY, n);
  NSData *data = [NSData dataWithBytesNoCopy:buffer
                                      length:n
                                freeWhenDone:NO];
  NSURLResponse *response =
      [[[NSURLResponse alloc] initWithURL:[[task request] URL]
                                 MIMEType:@"text/plain"
                    expectedContentLength:(NSInteger)n
                         textEncodingName:@"utf-8"] autorelease];
  [task didReceiveResponse:response];
  [task didReceiveData:data];
  memset(buffer, 0xAA, n); /* poison, immediately after handoff */
  [task didFinish];
}

/* M13: a response that is deliberately slow, so the page can abort it and
 * stopURLSchemeTask: really arrives mid-flight. */
- (void)beginSlow:(id<WKURLSchemeTask>)task {
  NSURLResponse *response =
      [[[NSURLResponse alloc] initWithURL:[[task request] URL]
                                 MIMEType:@"application/octet-stream"
                    expectedContentLength:4096
                         textEncodingName:nil] autorelease];
  [task didReceiveResponse:response];
  [task didReceiveData:[NSData dataWithBytes:"...." length:4]];

  [task retain]; /* keep the object alive for the deferred half */

  /* The cycle this block belongs to, captured by value. dispatch_after is
     neither drained nor cancellable at teardown - drain_workers waits on
     pthread workers, not on the main queue - so this block can and does
     first run on the NEXT cycle's run loop. By then self.owner points at a
     DIFFERENT cycle's stack frame, and charging an exception (or a task
     claim) to it would file cycle N's behaviour under cycle N+1. */
  struct probe_state *owner_at_start = self.owner;

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        struct probe_state *owner_now = self.owner;
        if ((owner_at_start == NULL) || (owner_now != owner_at_start)) {
          /* the cycle that started this task is gone: touch nothing */
          [task release];
          return;
        }
        @try {
          /* THE GUARD. If the page aborted, stopURLSchemeTask: already took
             this task out of the live set and sending anything here would
             raise. */
          if ([self claimTask:task]) {
            [task didFinish];
          }
        } @catch (NSException *e) {
          (void)e;
          owner_at_start->caught_exceptions++;
        }
        [task release];
      });
}

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  @try {
    struct probe_state *state = self.owner;
    NSURL *url = [[task request] URL];
    /* THE URI IS THE WHOLE URI. No path accessor is ever consulted: on this
       backend as on GTK, a path-only view of pweb://evil/x reads as /x and
       would hand a wrong-authority request through as a legitimate asset. */
    NSString *observed = [url absoluteString];
    const char *observed_c =
        (observed != nil) ? [observed UTF8String] : "<nil>";
    const char *scheme_c = [[url scheme] UTF8String];

    /* Tracked FIRST, unconditionally. Every path below completes the task
       exactly once through claimTask:, including the disowned one - a task
       that is never completed is a request WebKit waits on forever. */
    [self trackTask:task];

    if (state == NULL) {
      /* disowned: fail closed, never serve */
      printf("CAP7M_URI cycle=0 verdict=refuse url=%s\n", observed_c);
      fflush(stdout);
      [self finishRefused:task];
      return;
    }

    /* the post-create scheme (M9) is counted and refused: reaching this at
       all would mean seam A works, which is the fact under measurement */
    if ((scheme_c != NULL) &&
        (strcmp(scheme_c, [PROBE_POSTCREATE_SCHEME UTF8String]) == 0)) {
      state->postcreate_requests++;
      printf("CAP7M_URI cycle=%u verdict=refuse url=%s\n", state->cycle,
             observed_c);
      fflush(stdout);
      [self finishRefused:task];
      return;
    }

    /* EXACT FULL-STRING allowlist -- not a parser, not a second validator.
       PWebParseAppUri is the only thing in this project that renders a
       verdict on a URI, and test/cap7m/uri_oracle.pas is where the captured
       strings meet it. */
    const int serve_main = (strcmp(observed_c, PROBE_MAIN_URI) == 0);
    const int serve_js = (strcmp(observed_c, PROBE_JS_URI) == 0);
    const int serve_css = (strcmp(observed_c, PROBE_CSS_URI) == 0);
    const int serve_handoff = (strcmp(observed_c, PROBE_HANDOFF_URI) == 0);
    const int serve_slow = (strcmp(observed_c, PROBE_SLOW_URI) == 0);
    const int serve =
        serve_main || serve_js || serve_css || serve_handoff || serve_slow;

    printf("CAP7M_URI cycle=%u verdict=%s url=%s\n", state->cycle,
           serve ? "serve" : "refuse", observed_c);
    fflush(stdout);

    if (serve_main) {
      state->main_requests++;
      [self finishBody:task
                  data:[NSData dataWithBytes:kHtml length:strlen(kHtml)]
                  type:@"text/html"];
    } else if (serve_js) {
      state->js_requests++;
      [self finishBody:task
                  data:[NSData dataWithBytes:kJs length:strlen(kJs)]
                  type:@"text/javascript"];
    } else if (serve_css) {
      state->css_requests++;
      [self finishBody:task
                  data:[NSData dataWithBytes:kCss length:strlen(kCss)]
                  type:@"text/css"];
    } else if (serve_handoff) {
      state->handoff_requests++;
      [self finishHandoff:task];
    } else if (serve_slow) {
      state->slow_requests++;
      [self beginSlow:task];
    } else {
      state->refused_requests++;
      [self finishRefused:task];
    }
  } @catch (NSException *e) {
    if (self.owner) {
      self.owner->caught_exceptions++;
    }
    NSLog(@"CAP7M caught NSException in startURLSchemeTask: %@", e);
  }
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  (void)webView;
  @try {
    struct probe_state *state = self.owner;
    const BOOL was_live = [self isLive:task];
    if (state != NULL) {
      state->stop_calls++;
    }
    /* After this the task must never be messaged again. Taking it out of the
       live set IS the guard - every later callback is claim-gated. */
    [self claimTask:task];

    /* MEASURED, once, and contained: is a post-stop callback really an
       NSException, or merely documented as one? The guard above is only
       worth its complexity if the answer is yes, and a guard nobody has
       tested is a guard nobody should trust. Only ever attempted on a task
       WebKit has just stopped, and only when the answer is still unknown. */
    if (was_live && (state != NULL) && (state->poststop_throws < 0)) {
      @try {
        [task didFinish];
        state->poststop_throws = 0;
      } @catch (NSException *e) {
        (void)e;
        state->poststop_throws = 1;
      }
    }
  } @catch (NSException *e) {
    if (self.owner) {
      self.owner->caught_exceptions++;
    }
    NSLog(@"CAP7M caught NSException in stopURLSchemeTask: %@", e);
  }
}

@end

/* ------------------- SEAM B: the pre-create override -------------------- */

/*
 * Upstream creates the configuration AND the web view inside webview_create,
 * so there is no moment between them that a caller can reach - unless the
 * caller owns the constructor. +[WKWebViewConfiguration new] is that
 * constructor (cocoa_webkit.hh:450 calls exactly this selector).
 *
 * The override is added to WKWebViewConfiguration's OWN metaclass with
 * class_addMethod. Note what is deliberately NOT done: class_getClassMethod
 * would return NSObject's inherited +new, and setting ITS implementation
 * would swizzle +new for every class in the process. Adding to this
 * metaclass affects this class alone.
 *
 * Like the CAP-7L GTK registration, it is installed once and never removed;
 * teardown DISOWNS it. With no owner it does nothing but forward.
 */
static PWebProbeSchemeHandler *g_seam_handler = nil;
static volatile int g_seam_armed = 0;
static int g_seam_installed = 0;
static unsigned g_seam_invocations = 0;
/* the identity of the configuration webview_create actually used, kept so
   M9 can compare it against what WKWebView.configuration hands back rather
   than taking Apple's "it is a copy" on trust */
static void *g_seam_last_config = NULL;

static id pweb_configuration_new(Class cls, SEL cmd) {
  (void)cmd;
  /* exactly what +new does, in public API */
  id config = [[cls alloc] init];
  if ((config != nil) && g_seam_armed && (g_seam_handler != nil)) {
    g_seam_last_config = (void *)config;
    @try {
      [(WKWebViewConfiguration *)config setURLSchemeHandler:g_seam_handler
                                              forURLScheme:PROBE_SCHEME];
      g_seam_invocations++;
    } @catch (NSException *e) {
      NSLog(@"CAP7M seam install raised: %@", e);
    }
  }
  return config; /* +1, as +new must return */
}

static int install_precreate_seam(void) {
  if (g_seam_installed) {
    return 1;
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
    /* The class already declares its OWN +new: replace that implementation,
       which is still confined to this class.
       The check below is the whole safety of this branch. class_getInstance-
       Method walks the superclass chain, so on a class that merely INHERITS
       +new from NSObject it returns NSObject's Method - and setting that
       implementation would swizzle +new for EVERY class in the process.
       Identical Method pointers mean inherited; refuse rather than guess. */
    Method own = class_getInstanceMethod(meta, @selector(new));
    Class super_meta = class_getSuperclass(meta);
    Method inherited = (super_meta != Nil)
                           ? class_getInstanceMethod(super_meta, @selector(new))
                           : NULL;
    if ((own == NULL) || (own == inherited)) {
      return 0;
    }
    method_setImplementation(own, (IMP)pweb_configuration_new);
  }
  g_seam_installed = 1;
  return 1;
}

/* --------------------------- the bindings ------------------------------- */

struct echo_job {
  webview_t webview;
  struct probe_state *state;
  char *id;
  long value;
  int kind; /* 0 echo, 1 forced error, 2 slow */
};

static void *echo_worker(void *argument) {
  struct echo_job *job = (struct echo_job *)argument;
  char result[128];

  if ((unsigned long)pthread_self() != job->state->gui_thread) {
    job->state->worker_was_distinct = 1;
  }

  if (job->kind == 2) {
    struct timespec nap = {0, 400 * 1000 * 1000};
    nanosleep(&nap, NULL);
  }

  /* THE FROZEN THREADING MODEL: a worker resolves by calling webview_return
     DIRECTLY. Never wrapped in webview_dispatch. Upstream forwards it
     through its own dispatch internally, so no Cocoa call runs here. */
  if (job->kind == 1) {
    snprintf(result, sizeof(result),
             "{\"code\":\"CAP7M_FORCED\",\"detail\":\"payload-intact-42\"}");
    if (webview_return(job->webview, job->id, 1, result) < WEBVIEW_ERROR_OK) {
      probe_fail(job->state, "worker webview_return (error path) failed");
    }
    __atomic_fetch_add(&job->state->error_returns, 1u, __ATOMIC_SEQ_CST);
  } else {
    snprintf(result, sizeof(result), "%ld", job->value * 2 + 1);
    if (webview_return(job->webview, job->id, 0, result) < WEBVIEW_ERROR_OK) {
      probe_fail(job->state, "worker webview_return failed");
    }
    if (job->kind == 2) {
      __atomic_fetch_add(&job->state->slow_returns, 1u, __ATOMIC_SEQ_CST);
    } else {
      __atomic_fetch_add(&job->state->echo_returns, 1u, __ATOMIC_SEQ_CST);
    }
  }

  free(job->id);
  __atomic_fetch_sub(&job->state->pending_workers, 1u, __ATOMIC_SEQ_CST);
  free(job);
  return NULL;
}

static void spawn_job(struct probe_state *state, const char *id,
                      const char *req, int kind) {
  struct echo_job *job = NULL;
  pthread_t thread;

  /* GUI-affine and copy-only: id and req are valid ONLY for this call */
  if ((unsigned long)pthread_self() != state->gui_thread) {
    probe_fail(state, "bind callback did not run on the GUI thread");
    return;
  }
  /* M8, and stated for exactly what it is: an address handed back a second
     time PROVES the buffer is reused, and therefore borrowed. The converse
     proves nothing - distinct addresses are equally consistent with an
     allocator that simply did not reuse one - so this is recorded as
     evidence, never asserted on. The lifetime rule the adapter follows is
     the documented one: id and req are valid only for the duration of the
     call, and everything below copies before returning. */
  if (state->last_id_ptr == id) {
    state->id_ptr_reused = 1;
  }
  state->last_id_ptr = id;

  job = (struct echo_job *)calloc(1, sizeof(*job));
  if (job == NULL) {
    probe_fail(state, "job allocation failed");
    return;
  }
  job->webview = state->webview;
  job->state = state;
  job->kind = kind;
  job->id = strdup(id);
  /* req is a JSON array, so the argument starts at req[1] - but an EMPTY
     req has its terminator at req[0], and req + 1 is then already past the
     end of the buffer. Check the length, do not assume the shape. */
  job->value = ((req != NULL) && (req[0] != '\0')) ? strtol(req + 1, NULL, 10)
                                                   : -1;
  if (job->id == NULL) {
    free(job);
    probe_fail(state, "id copy failed");
    return;
  }
  __atomic_fetch_add(&state->pending_workers, 1u, __ATOMIC_SEQ_CST);
  if (pthread_create(&thread, NULL, echo_worker, job) != 0) {
    __atomic_fetch_sub(&state->pending_workers, 1u, __ATOMIC_SEQ_CST);
    free(job->id);
    free(job);
    probe_fail(state, "worker thread could not start");
    return;
  }
  pthread_detach(thread);
}

static void invoke_binding(const char *id, const char *req, void *argument) {
  spawn_job((struct probe_state *)argument, id, req, 0);
}

static void fail_binding(const char *id, const char *req, void *argument) {
  spawn_job((struct probe_state *)argument, id, req, 1);
}

static void slow_binding(const char *id, const char *req, void *argument) {
  spawn_job((struct probe_state *)argument, id, req, 2);
}

/* M6: webview_eval executes. Done from a binding rather than before
 * navigation because upstream's eval_impl is a no-op while the URL is still
 * null, which would make an early call prove nothing. */
static void ready_binding(const char *id, const char *req, void *argument) {
  struct probe_state *state = (struct probe_state *)argument;
  (void)req;
  if ((unsigned long)pthread_self() != state->gui_thread) {
    probe_fail(state, "ready callback did not run on the GUI thread");
    return;
  }
  if (webview_eval(state->webview,
                   "window.__pweb_evaled = true;"
                   "if (window.__pweb_eval_seen) { window.__pweb_eval_seen(); }") <
      WEBVIEW_ERROR_OK) {
    probe_fail(state, "webview_eval failed");
  }
  webview_return(state->webview, id, 0, "null");
}

static void report_binding(const char *id, const char *req, void *argument) {
  struct probe_state *state = (struct probe_state *)argument;

  if ((unsigned long)pthread_self() != state->gui_thread) {
    probe_fail(state, "report callback did not run on the GUI thread");
    return;
  }
  if (req != NULL) {
    snprintf(state->report, sizeof(state->report), "%s", req);
    /* The two RECORDED verdicts, read out of the page's own words. Both
       answers are results; neither is a failure, which is why they are
       parsed here rather than folded into out.ok. */
    if (strstr(req, "\"handoff\":true") != NULL) {
      state->handoff_copied = 1;
    } else if (strstr(req, "\"handoff\":false") != NULL) {
      state->handoff_copied = 0;
    }
    if (strstr(req, "\"aborted\":true") != NULL) {
      state->abort_delivered = 1;
    } else if (strstr(req, "\"aborted\":false") != NULL) {
      state->abort_delivered = 0;
    }
  }
  state->passed = (req != NULL) && (strstr(req, "\"ok\":true") != NULL);
  webview_return(state->webview, id, 0, "null");

  pthread_mutex_lock(&state->mutex);
  state->finished = 1;
  pthread_cond_broadcast(&state->wake);
  pthread_mutex_unlock(&state->mutex);

  /* M6: the two shutdowns a real application actually has. */
  if (state->close_by_window) {
    NSWindow *window = (NSWindow *)webview_get_window(state->webview);
    if (window == nil) {
      probe_fail(state, "webview_get_window returned nil for the close cycle");
      webview_terminate(state->webview);
    } else {
      /* -close reaches upstream's windowWillClose: delegate, which is the
         path a user clicking the red button takes */
      [window close];
    }
  } else {
    webview_terminate(state->webview);
  }
}

/* ----------------------------- watchdog --------------------------------- */

static void terminate_on_gui_thread(webview_t webview, void *argument) {
  (void)argument;
  webview_terminate(webview);
}

static void *watchdog(void *argument) {
  struct probe_state *state = (struct probe_state *)argument;
  struct timespec deadline;
  int timed_out = 0;
  int rescue = 0;
  int stuck = 0;

  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += PROBE_TIMEOUT_SECONDS;

  /* Phase 1: wait for the page to report, for a failure, or for the deadline. */
  pthread_mutex_lock(&state->mutex);
  while (!state->finished && !state->failed) {
    if (pthread_cond_timedwait(&state->wake, &state->mutex, &deadline) ==
        ETIMEDOUT) {
      timed_out = 1;
      break;
    }
  }
  pthread_mutex_unlock(&state->mutex);

  if (timed_out) {
    probe_fail(state, "runtime probe timeout");
    rescue = 1;
  } else {
    /* A FAILURE IS ALSO A REASON TO SHUT DOWN. Leaving the wait loop because
       probe_fail was called and then returning quietly leaves webview_run
       spinning forever, so the job hangs until the CI step timeout - which
       reports as an infrastructure problem rather than as the defect the
       probe had already detected. */
    pthread_mutex_lock(&state->mutex);
    rescue = (state->failed && !state->run_returned) ? 1 : 0;
    pthread_mutex_unlock(&state->mutex);
  }

  /* Phase 2: the SHUTDOWN itself is on a deadline of its own. `finished` is
     set by report_binding BEFORE it closes the window, so phase 1 returning
     says nothing about whether the run loop actually stopped. Without this,
     an NSWindow close that fails to end the loop hangs unbounded - and that
     is precisely one of the two shutdown shapes M6 exists to measure. */
  if (!rescue) {
    struct timespec shutdown_deadline;
    clock_gettime(CLOCK_REALTIME, &shutdown_deadline);
    shutdown_deadline.tv_sec += PROBE_SHUTDOWN_SECONDS;

    pthread_mutex_lock(&state->mutex);
    while (!state->run_returned) {
      if (pthread_cond_timedwait(&state->wake, &state->mutex,
                                 &shutdown_deadline) == ETIMEDOUT) {
        break;
      }
    }
    stuck = !state->run_returned;
    pthread_mutex_unlock(&state->mutex);

    if (stuck) {
      probe_fail(state, state->close_by_window
                            ? "NSWindow close did not stop the run loop"
                            : "webview_terminate did not stop the run loop");
      rescue = 1;
    }
  }

  if (rescue) {
    /* cross-thread shutdown travels worker -> dispatch -> terminate */
    webview_dispatch(state->webview, terminate_on_gui_thread, NULL);
  }
  return NULL;
}

/* ------------------------------ one cycle -------------------------------- */

static int drain_workers(struct probe_state *state) {
  int waited_ms = 0;
  while (__atomic_load_n(&state->pending_workers, __ATOMIC_SEQ_CST) != 0u) {
    struct timespec nap = {0, 5 * 1000 * 1000};
    nanosleep(&nap, NULL);
    waited_ms += 5;
    if (waited_ms > PROBE_DRAIN_SECONDS * 1000) {
      return 0;
    }
  }
  return 1;
}

static int run_cycle(unsigned cycle) {
  struct probe_state state;
  webview_t webview = NULL;
  pthread_t dog;
  int dog_started = 0;
  int ok = 0;
  unsigned seam_before;

  memset(&state, 0, sizeof(state));
  pthread_mutex_init(&state.mutex, NULL);
  pthread_cond_init(&state.wake, NULL);
  state.gui_thread = (unsigned long)pthread_self();
  state.cycle = cycle;
  state.poststop_throws = -1;
  state.handoff_copied = -1;
  state.abort_delivered = -1;
  /* odd cycles terminate programmatically, even cycles close the window */
  state.close_by_window = ((cycle % 2u) == 0u);

  @autoreleasepool {
    if (!install_precreate_seam()) {
      fprintf(stderr, "CAP7M_FAIL cycle=%u reason=seam install failed\n", cycle);
      pthread_cond_destroy(&state.wake);
      pthread_mutex_destroy(&state.mutex);
      return 0;
    }
    if (g_seam_handler == nil) {
      g_seam_handler = [[PWebProbeSchemeHandler alloc] init];
    }
    g_seam_handler.owner = &state;
    seam_before = g_seam_invocations;
    __atomic_store_n(&g_seam_armed, 1, __ATOMIC_SEQ_CST);

    webview = webview_create(0, NULL);
    if (webview == NULL) {
      /* the no-session condition: NULL, never a code (c_api_impl discards it) */
      fprintf(stderr, "CAP7M_FAIL cycle=%u operation=webview_create\n", cycle);
      __atomic_store_n(&g_seam_armed, 0, __ATOMIC_SEQ_CST);
      g_seam_handler.owner = NULL;
      pthread_cond_destroy(&state.wake);
      pthread_mutex_destroy(&state.mutex);
      return 0;
    }
    state.webview = webview;

    if (g_seam_invocations == seam_before) {
      probe_fail(&state,
                 "the pre-create seam never ran -- webview_create did not go "
                 "through +[WKWebViewConfiguration new]");
      goto teardown;
    }
    printf("CAP7M_M10 cycle=%u precreate_seam_ran=1\n", cycle);

    /* M9: seam A, on the COPY that WKWebView.configuration hands back. Its
       own scheme, so it can never collide with the seam under test. */
    {
      id controller = (id)webview_get_native_handle(
          webview, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
      if (controller == nil) {
        probe_fail(&state, "borrowed browser controller unavailable");
        goto teardown;
      }
      WKWebViewConfiguration *after = [(WKWebView *)controller configuration];
      int installed = 0;
      @try {
        [after setURLSchemeHandler:g_seam_handler
                      forURLScheme:PROBE_POSTCREATE_SCHEME];
        installed = 1;
      } @catch (NSException *e) {
        NSLog(@"CAP7M post-create install raised: %@", e);
      }
      /* If the accessor returned the very object webview_create used, seam A
         would be viable and Apple's copy semantics would not apply here.
         Measured, not assumed - and the page's out.postcreate settles
         whether the installed handler is ever actually consulted. */
      printf("CAP7M_M9 cycle=%u postcreate_install_accepted=%d "
             "configuration_is_same_object=%d\n",
             cycle, installed,
             ((void *)after == g_seam_last_config) ? 1 : 0);
    }

    if (webview_set_title(webview, "CAP-7M0 probe") < WEBVIEW_ERROR_OK) {
      probe_fail(&state, "webview_set_title failed");
      goto teardown;
    }
    if (webview_set_size(webview, 800, 600, WEBVIEW_HINT_NONE) <
        WEBVIEW_ERROR_OK) {
      probe_fail(&state, "webview_set_size failed");
      goto teardown;
    }
    if ((webview_bind(webview, "__pweb_invoke", invoke_binding, &state) <
         WEBVIEW_ERROR_OK) ||
        (webview_bind(webview, "__pweb_fail", fail_binding, &state) <
         WEBVIEW_ERROR_OK) ||
        (webview_bind(webview, "__pweb_slow", slow_binding, &state) <
         WEBVIEW_ERROR_OK) ||
        (webview_bind(webview, "__pweb_ready", ready_binding, &state) <
         WEBVIEW_ERROR_OK) ||
        (webview_bind(webview, "__pweb_report", report_binding, &state) <
         WEBVIEW_ERROR_OK)) {
      probe_fail(&state, "webview_bind failed");
      goto teardown;
    }
    if (webview_navigate(webview, PROBE_MAIN_URI) < WEBVIEW_ERROR_OK) {
      probe_fail(&state, "webview_navigate failed");
      goto teardown;
    }

    if (pthread_create(&dog, NULL, watchdog, &state) != 0) {
      probe_fail(&state, "watchdog thread could not start");
      goto teardown;
    }
    dog_started = 1;

    if (webview_run(webview) < WEBVIEW_ERROR_OK) {
      probe_fail(&state, "webview_run failed");
    }

  teardown:
    /* run_returned is what releases the watchdog's SECOND deadline, and it
       is deliberately a different fact from `finished`: reaching this label
       means webview_run came back (or was never entered), which is exactly
       what the shutdown deadline is waiting to hear. */
    pthread_mutex_lock(&state.mutex);
    state.finished = 1;
    state.run_returned = 1;
    pthread_cond_broadcast(&state.wake);
    pthread_mutex_unlock(&state.mutex);
    if (dog_started) {
      pthread_join(dog, NULL);
    }

    /* M8: never destroy while an invocation is still in flight - a worker
       calling webview_return into destroyed state is exactly the failure
       this ordering exists to prevent. The deliberately un-awaited
       __pweb_slow() call is what makes this a real test rather than a
       formality. */
    if (!drain_workers(&state)) {
      probe_fail(&state, "outstanding invocations did not drain");
    }

    webview_unbind(webview, "__pweb_invoke");
    webview_unbind(webview, "__pweb_fail");
    webview_unbind(webview, "__pweb_slow");
    webview_unbind(webview, "__pweb_ready");
    webview_unbind(webview, "__pweb_report");

    /* DISOWN before destroy: the seam cannot be uninstalled, so it must be
       unable to reach this frame's state afterwards. Clearing the tracked
       task set goes with it - cycles never share tasks, and a stale entry
       keyed by an address the allocator later reuses would let the next
       cycle's task alias one this cycle abandoned. */
    __atomic_store_n(&g_seam_armed, 0, __ATOMIC_SEQ_CST);
    g_seam_handler.owner = NULL;
    [g_seam_handler resetTasks];

    if (webview_destroy(webview) < WEBVIEW_ERROR_OK) {
      probe_fail(&state, "webview_destroy failed");
    }
  }

  if (!state.failed) {
    if (!state.passed) {
      probe_fail(&state, "page verdict was not ok");
    } else if (state.main_requests != 1u) {
      probe_fail(&state, "main document was not requested exactly once");
    } else if (state.js_requests != 1u) {
      probe_fail(&state, "probe script was not requested exactly once");
    } else if (state.css_requests < 1u) {
      probe_fail(&state, "stylesheet subresource never reached the handler");
    } else if (state.handoff_requests < 1u) {
      probe_fail(&state, "the handoff asset never reached the handler");
    } else if (state.echo_returns != (unsigned)PROBE_ECHOES) {
      probe_fail(&state, "concurrent invocations did not complete exactly once");
    } else if (state.error_returns != 1u) {
      probe_fail(&state, "the forced error did not complete exactly once");
    } else if (state.slow_returns != 1u) {
      probe_fail(&state, "the outstanding invocation did not complete");
    } else if (!state.worker_was_distinct) {
      probe_fail(&state, "no invocation was serviced off the GUI thread");
    } else if (state.caught_exceptions != 0u) {
      probe_fail(&state, "an NSException reached the C++ boundary");
    } else {
      ok = 1;
    }
  }

  /* EVERY marker below is emitted whatever the verdict. A failing cycle is
     the one whose measurements are most worth having, and burying them in
     the pass branch throws away exactly the run someone will need to read at
     10x billing. */
  printf("CAP7M_M7 cycle=%u gui_affine=1 worker_distinct=%d direct_return=1\n",
         cycle, state.worker_was_distinct);
  /* id_ptr_reused=1 PROVES the buffer is borrowed; 0 proves nothing either
     way (see spawn_job). Recorded as evidence, never asserted on. */
  printf("CAP7M_M8 cycle=%u echoes=%u errors=%u outstanding=%u "
         "id_ptr_reused=%d\n",
         cycle, state.echo_returns, state.error_returns, state.slow_returns,
         state.id_ptr_reused);

  /* M9: the seam-A verdict, and the ONLY place it can honestly be read. The
     page cannot tell "no handler on the live configuration" from "handler
     consulted and refused" - both are a failed fetch - so the handler-side
     counter decides. */
  printf("CAP7M_M9 cycle=%u postcreate_hits=%u seam_a_effective=%s\n", cycle,
         state.postcreate_requests,
         (state.postcreate_requests > 0u) ? "yes" : "no");

  printf("CAP7M_M13 cycle=%u stops=%u caught_exceptions=%u "
         "poststop_throws=%d abort_delivered=%d\n",
         cycle, state.stop_calls, state.caught_exceptions,
         state.poststop_throws, state.abort_delivered);

  /* M14: the ownership rule a Pascal adapter has to follow, stated as a
     verdict rather than as a pass/fail. Both answers are results. */
  printf("CAP7M_M14 cycle=%u handoff=%s ownership=%s\n", cycle,
         (state.handoff_copied == 1)   ? "original-bytes"
         : (state.handoff_copied == 0) ? "poisoned-bytes"
                                       : "undetermined",
         (state.handoff_copied == 1) ? "webkit-copies-at-handoff"
         : (state.handoff_copied == 0)
             ? "webkit-retains-pointer--adapter-must-keep-source-alive"
             : "undetermined");

  printf("CAP7M_M6 cycle=%u shutdown=%s rss_kb=%lu\n", cycle,
         state.close_by_window ? "window-close" : "terminate",
         probe_rss_kb());
  printf("CAP7M_URI_TOTALS cycle=%u served=%u refused=%u\n", cycle,
         state.main_requests + state.js_requests + state.css_requests +
             state.handoff_requests + state.slow_requests,
         state.refused_requests);
  if (state.report[0] != '\0') {
    printf("CAP7M_REPORT cycle=%u %s\n", cycle, state.report);
  }

  if (!ok) {
    fprintf(stderr, "CAP7M_FAIL cycle=%u reason=%s\n", cycle,
            state.failure[0] != '\0' ? state.failure : "incomplete verdict");
  } else {
    printf("CAP7M_CYCLE_PASS cycle=%u served=%u refused=%u postcreate_hits=%u\n",
           cycle,
           state.main_requests + state.js_requests + state.css_requests +
               state.handoff_requests + state.slow_requests,
           state.refused_requests, state.postcreate_requests);
  }
  fflush(stdout);

  pthread_cond_destroy(&state.wake);
  pthread_mutex_destroy(&state.mutex);
  return ok;
}

int main(int argc, char **argv) {
  /* Three, not two: one of each shutdown shape, plus a third so the leak
     bound has a cycle to measure growth AGAINST. Cycle 1 is never the
     baseline - WebKit legitimately populates its caches on the first
     navigation, and treating that as a leak would be a false positive on
     every single run. */
  unsigned cycles = 3;
  unsigned cycle;
  unsigned failures = 0;
  unsigned long rss[21];

  memset(rss, 0, sizeof(rss));

  if (argc == 2) {
    const long parsed = strtol(argv[1], NULL, 10);
    if ((parsed < 1) || (parsed > 20)) {
      fprintf(stderr, "usage: cap7m_probe [cycles 1..20]\n");
      return 2;
    }
    cycles = (unsigned)parsed;
  } else if (argc != 1) {
    fprintf(stderr, "usage: cap7m_probe [cycles 1..20]\n");
    return 2;
  }

  /* EVERY cycle runs, even after one fails. Stopping at the first failure
     means a cycle-1 problem discards the window-close shutdown shape and
     every later measurement - on a runner that bills at 10x and whose whole
     guidance is to batch changes rather than iterate. The exit code still
     reflects the aggregate. */
  for (cycle = 1; cycle <= cycles; ++cycle) {
    if (!run_cycle(cycle)) {
      ++failures;
    }
    rss[cycle] = probe_rss_kb();
    printf("CAP7M_RSS cycle=%u rss_kb=%lu\n", cycle, rss[cycle]);
    fflush(stdout);
  }

  /* M6: "crash/hang/leak blocks". The crash and the hang are covered by the
     cycle verdict and the two watchdog deadlines; this is the leak. */
  if (cycles >= (unsigned)PROBE_MIN_CYCLES_FOR_LEAK_CHECK) {
    const unsigned long base = rss[2];
    const unsigned long last = rss[cycles];
    const unsigned long span = (unsigned long)(cycles - 2u);
    const unsigned long budget =
        (unsigned long)PROBE_RSS_GROWTH_KB_PER_CYCLE_MAX * span;
    const unsigned long growth = (last > base) ? (last - base) : 0ul;

    printf("CAP7M_M6_LEAK base_cycle=2 base_kb=%lu last_cycle=%u last_kb=%lu "
           "growth_kb=%lu budget_kb=%lu\n",
           base, cycles, last, growth, budget);
    if (growth > budget) {
      fprintf(stderr,
              "CAP7M_FAIL reason=resident size grew %lu KiB over %lu cycle(s), "
              "budget %lu KiB\n",
              growth, span, budget);
      ++failures;
    }
  } else {
    printf("CAP7M_M6_LEAK skipped=1 reason=needs>=%d cycles, ran %u\n",
           PROBE_MIN_CYCLES_FOR_LEAK_CHECK, cycles);
  }
  fflush(stdout);

  if (failures != 0u) {
    fprintf(stderr, "CAP7M_FAIL cycles=%u failed=%u\n", cycles, failures);
    return 1;
  }
  printf("CAP7M_PROBE_PASS cycles=%u\n", cycles);
  return 0;
}
