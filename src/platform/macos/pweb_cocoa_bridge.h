/*
 * pweb_cocoa_bridge.h - the PRIVATE flat C seam between PWeb's Pascal macOS
 * adapter (src/platform/macos/pweb.platform.cocoa.pas) and the Objective-C++
 * that Pascal cannot express.
 *
 * ============================ WHAT THIS IS NOT ============================
 *
 * It is NOT an extension of the webview C ABI. No declaration below names a
 * `webview_*` symbol, the pinned upstream is not patched, no second dylib is
 * shipped, and the public export surface stays at exactly 17. This is one
 * object file, compiled by tools/build-macos-bridge.sh and linked into each
 * PWeb binary that hosts a macOS WebView.
 *
 * It is NOT a second URI validator, a second store, or a second binding
 * declaration surface. Every request feeds the WHOLE absolute URL back to
 * Pascal, which renders the only verdict this project recognises
 * (PWebParseAppUri). The bridge itself never parses a URL, never touches a
 * filesystem path, and never decides what to serve.
 *
 * ============================== WHY IT EXISTS =============================
 *
 * Three things need an Objective-C frame, and Pascal has none:
 *
 *   1. THE PRE-CREATE SEAM. Upstream builds the WKWebViewConfiguration and
 *      the WKWebView both inside webview_create (cocoa_webkit.hh:450,486), so
 *      there is no moment between them a caller can reach - unless the caller
 *      owns the constructor. CAP-7M0 MEASURED (run 31909938201) that the
 *      obvious post-create route is accepted, compares equal, and is then
 *      NEVER CONSULTED (postcreate_hits=0): the worst shape a wrong seam can
 *      take. So the seam is an override of +[WKWebViewConfiguration new] on
 *      that class's own metaclass, installed with the PUBLIC Objective-C
 *      runtime and using the PUBLIC setURLSchemeHandler:forURLScheme:.
 *
 *   2. THE EXCEPTION BARRIER. WKURLSchemeTask THROWS - Apple documents an
 *      NSException for a second response after completion, data before a
 *      response, finish before a response, finish/fail after either, and ANY
 *      callback after stopURLSchemeTask:. CAP-7M0 measured poststop_throws=1,
 *      so the guard is load-bearing rather than cargo-culted. An NSException
 *      crossing into a Pascal frame is undefined behaviour, not an error
 *      path, and only an Objective-C frame can @catch one.
 *
 *   3. THE RESPONSE OBJECT. Served assets need NSHTTPURLResponse, not a bare
 *      NSURLResponse: CAP-7M0 measured that a bare NSURLResponse LOADS the
 *      resource perfectly while fetch() reports status 0 and ok === false,
 *      because NSURLResponse carries no status code.
 *
 * ============================ OWNERSHIP MODEL =============================
 *
 * THE BRIDGE NEVER HOLDS A RAW PASCAL OBJECT POINTER. Ownership crosses as a
 * 64-bit generation-checked handle resolved through a Pascal-side registry
 * that bumps the generation on both claim and release, so a handle from a
 * freed handler is UNRESOLVABLE rather than dangling. That is strictly
 * stronger than a disowned pointer, and it is what makes "no callback after
 * handler destruction" a property of the REPRESENTATION rather than of the
 * teardown order.
 *
 * Response bodies cross the other way: Pascal allocates a copy through
 * pweb_cocoa_alloc and hands it over in pweb_cocoa_asset_t. The bridge OWNS
 * it from the moment pweb_cocoa_resolve_fn returns non-zero, whether the
 * task is served or abandoned, and releases it exactly once.
 *
 * Nothing here blocks, and nothing here is called from a worker: every entry
 * point is main/GUI-thread affine except where its comment says otherwise.
 */

#ifndef PWEB_COCOA_BRIDGE_H
#define PWEB_COCOA_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Longest Content-Type the seam will carry, INCLUDING the NUL. A fixed
   buffer, deliberately: it removes a second cross-boundary allocation and a
   second ownership rule, and a type that does not fit is a Pascal-side
   REFUSAL rather than a truncation. The current table's longest entry is
   "text/javascript; charset=utf-8" (30 bytes). */
#define PWEB_COCOA_CONTENT_TYPE_MAX 256

/* One resolved asset, handed from Pascal to the bridge.

   bytes  : a pweb_cocoa_alloc() block the BRIDGE owns once resolve returns
            non-zero. Never NULL on success - a zero-length asset still gets
            a real allocation, so "empty" and "failed" can never be confused.
   length : exact body length; 0 is a legitimate asset, not a miss.
   content_type: NUL-terminated, never empty (an empty Content-Type would let
            the engine sniff). */
typedef struct pweb_cocoa_asset {
  void *bytes;
  int64_t length;
  char content_type[PWEB_COCOA_CONTENT_TYPE_MAX];
} pweb_cocoa_asset_t;

/* Counters the Pascal gates assert on. Every field is monotonic within a
   process except live_tasks, which is the current size of the tracked set.
   A CALLER READING THESE PER CYCLE MUST TAKE DELTAS: they are process
   cumulative by design, so that a leak across cycles stays visible. */
typedef struct pweb_cocoa_stats {
  uint64_t seam_invocations;     /* +[WKWebViewConfiguration new] overrides
                                    that actually installed the handler */
  uint64_t tasks_started;        /* startURLSchemeTask: arrivals */
  uint64_t tasks_served;         /* completed with an NSHTTPURLResponse 200 */
  uint64_t tasks_refused;        /* completed with didFailWithError: */
  uint64_t tasks_stopped;        /* stopURLSchemeTask: that claimed a task */
  uint64_t stops_while_serving;  /* ... of those, ones claimed in SERVING:
                                    the interleaving a synchronous handler
                                    cannot produce and a chunked one will */
  uint64_t stops_ignored;        /* stopURLSchemeTask: for an unknown task */
  uint64_t suppressed_terminals; /* terminal deliveries the claim gate refused */
  uint64_t caught_exceptions;    /* NSExceptions caught at a seam entry */
  uint64_t unresolved_handles;   /* callbacks whose handle did not resolve */
  uint64_t live_tasks;           /* currently tracked, i.e. not yet settled */
} pweb_cocoa_stats_t;

/* The ONE callback out of the bridge.

   handle       : the generation-checked Pascal handle, or 0 when disowned.
   absolute_url : [[task request] URL] absoluteString - the WHOLE absolute
                  URL, never a path accessor and never a rebuilt string.
   asset        : filled by Pascal on success.

   Returns:
      1  serve - *asset is filled and its `bytes` block belongs to the bridge
      0  refuse - one outcome, no reason, no path, no native text
     -1  the handle did NOT resolve: a released or never-claimed handler. The
         bridge counts it separately (unresolved_handles) and then refuses
         exactly as for 0, because a page must not be able to tell the two
         apart.

   MUST NOT raise, MUST NOT block, and MUST leave *asset zeroed for every
   outcome other than 1 - including the ones it reaches by way of its own
   internal failure. */
typedef int (*pweb_cocoa_resolve_fn)(uint64_t handle, const char *absolute_url,
                                     pweb_cocoa_asset_t *asset);

/* Allocate / release a response body. Pairing the allocator with the
   deallocator on ONE side of the seam is why these exist: Pascal never has
   to assume which libc allocator the bridge frees with.
   pweb_cocoa_alloc(0) still returns a real, non-NULL block. */
void *pweb_cocoa_alloc(size_t n);
void pweb_cocoa_free(void *p);

/* Install the pre-create seam and the singleton scheme handler. Idempotent;
   the resolve function is recorded on the first successful call and must be
   the same on every later one. Returns 1 on success, 0 if the Objective-C
   runtime refused the override (in which case NOTHING is installed and the
   caller must fail loudly rather than proceed unhandled). */
int pweb_cocoa_install(pweb_cocoa_resolve_fn resolve);

/* Arm the seam for one handler handle. Every WKWebViewConfiguration created
   while armed gets the handler installed for the "pweb" scheme. Returns 1 on
   success, 0 if a different handle is already armed - two live handlers on
   one process-wide seam would both be served by a single callback that can
   only consult one store, so that is refused rather than resolved in
   someone's favour. */
int pweb_cocoa_arm(uint64_t handle);

/* Disown: the seam stops installing, and the installed handler stops calling
   out. After this returns, no resolve callback can be made for `handle`.
   Idempotent and safe from any thread (one atomic store). */
void pweb_cocoa_disown(uint64_t handle);

/* Claim and FAIL every task still live, so teardown never leaves a request
   WebKit waits on forever. Returns how many were failed. Called AFTER
   pweb_cocoa_disown and BEFORE the handle is released. */
unsigned long pweb_cocoa_fail_live_tasks(void);

/* Seam invocations so far. The adapter samples this before webview_create
   and again in Attach: a seam that silently stopped running can then never
   present as success.

   ON ITS OWN THIS PROVES LITTLE, and the adapter treats it as the cheap guard
   it is: the counter is process-global and monotonic, so ANY unrelated
   +[WKWebViewConfiguration new] anywhere in the process would move it. What
   settles the question per view is pweb_cocoa_handler_installed_on below. */
uint64_t pweb_cocoa_seam_invocations(void);

/* Does THIS WKWebView's live configuration have OUR handler installed for the
   pweb scheme?

     PWEB_COCOA_READBACK_OURS    ( 1)  our handler - the per-view proof
     PWEB_COCOA_READBACK_ABSENT  ( 0)  nothing visible: a NULL view, no
                                       installed seam, an accessor that
                                       raised, OR a configuration copy that
                                       does not carry the scheme-handler map
     PWEB_COCOA_READBACK_FOREIGN (-1)  a DIFFERENT handler owns pweb:// here

   THE THREE VALUES ARE NOT COSMETIC. CAP-7M0 measured that WRITING to the
   configuration a WKWebView hands back is silently ineffective; that is a
   statement about mutation, and whether a READ sees a registration the
   original was constructed with is a different question this project has not
   measured. So ABSENT is ambiguous - "the copy does not carry the map" and
   "nothing is installed" are indistinguishable from here - while FOREIGN is
   unambiguous and is the only one the adapter refuses on. ABSENT is recorded
   as a measurement instead, and is promoted to a refusal once a hosted run
   has reported OURS on both architectures.

   `view` is the BROWSER_CONTROLLER native handle, which on Cocoa is the
   WKWebView itself. The query is public API
   (-[WKWebViewConfiguration urlSchemeHandlerForURLScheme:], macOS 10.13+) and
   READ-only. */
#define PWEB_COCOA_READBACK_OURS 1
#define PWEB_COCOA_READBACK_ABSENT 0
#define PWEB_COCOA_READBACK_FOREIGN (-1)
int pweb_cocoa_handler_installed_on(void *view);

/* Is the +new override CONFINED to WKWebViewConfiguration's own metaclass?
   1 yes, 0 no.

   This is the single most dangerous line in the bridge made checkable:
   class_getClassMethod would have returned NSObject's INHERITED +new, and
   setting that implementation would have swizzled +new for EVERY class in the
   process. The check asserts all three observable halves of the confinement -
   WKWebViewConfiguration's metaclass +new IS ours, NSObject's metaclass +new
   is NOT, and constructing unrelated objects with +new does not move the seam
   counter. Deterministic, and needs no window. */
int pweb_cocoa_seam_is_confined(void);

/* Snapshot of every counter. `out` must not be NULL. */
void pweb_cocoa_get_stats(pweb_cocoa_stats_t *out);

/* Resident size of THIS process in KiB, or 0 if the kernel would not say.

   Here rather than in Pascal for one reason: the only portable-looking way to
   ask from Pascal is a hand-laid `struct rusage`, whose ru_maxrss sits behind
   two `struct timeval`s and means BYTES on Darwin and KiB on Linux. A wrong
   offset does not fail - it returns a plausible number, which is exactly how
   a leak bound quietly stops measuring anything. task_info() is two lines in
   a file that already includes <mach/mach.h> correctly. */
uint64_t pweb_cocoa_rss_kb(void);

/* ======================================================================== *
 *  DETERMINISTIC PROOF SURFACE                                             *
 *                                                                          *
 *  Everything below drives the SAME task state machine the real            *
 *  WKURLSchemeHandler uses, over a bridge-internal stub task, so that       *
 *  double-terminal suppression, post-stop suppression, idempotent cancel    *
 *  and the disowned-handler refusal are provable WITHOUT a window - which   *
 *  is the only way they can be gated deterministically rather than hoped    *
 *  for in a GUI run.                                                        *
 *                                                                          *
 *  The stub deliberately MIMICS WebKit's documented raising behaviour: a    *
 *  second terminal, or any delivery after a stop, raises an NSException.    *
 *  A guard nobody has tested is a guard nobody should trust, and a stub     *
 *  that quietly accepted misuse would let the claim gate be removed with    *
 *  every test still green.                                                  *
 *                                                                          *
 *  None of it is reachable from a page, from the webview ABI, or from any   *
 *  Pascal contract: a stub task exists only because this file created one.  *
 * ======================================================================== */

typedef struct pweb_cocoa_stub_outcome {
  int response_status;    /* HTTP status the stub was given, 0 if none */
  int64_t response_length;/* Content-Length header, -1 if absent */
  int64_t received_bytes; /* total bytes delivered through didReceiveData: */
  int finished;           /* didFinish arrived */
  int failed;             /* didFailWithError: arrived */
  int misuse_raised;      /* the stub raised on a misuse (i.e. a guard leaked) */
  uint32_t body_hash;     /* FNV-1a of the delivered bytes, for byte-identity */
} pweb_cocoa_stub_outcome_t;

/* Create/release a stub task for `absolute_url`. Returns 0 on failure. */
uint64_t pweb_cocoa_stub_task_create(const char *absolute_url);
void pweb_cocoa_stub_task_release(uint64_t task);

/* Drive the real handler entry points with the stub task. */
void pweb_cocoa_stub_task_start(uint64_t task);
void pweb_cocoa_stub_task_stop(uint64_t task);

/* Track the task exactly as startURLSchemeTask: does and return WITHOUT
   completing it - the state a chunked or deferred delivery would routinely
   produce and this synchronous handler never produces on its own. It exists
   so that teardown's claim-and-fail is proven rather than vacuous: without
   it, "Detach while the live-task set is non-empty" could not be reached at
   all and the assertion would pass by being unreachable. */
void pweb_cocoa_stub_task_leave_live(uint64_t task);

/* Attempt one more terminal delivery on a task the handler already finished.
   With the claim gate in place this is suppressed and the stub never sees it;
   without it, the stub raises and misuse_raised becomes 1. */
void pweb_cocoa_stub_task_deliver_again(uint64_t task);

/* Read what the stub actually observed. `out` must not be NULL. */
void pweb_cocoa_stub_task_outcome(uint64_t task, pweb_cocoa_stub_outcome_t *out);

#ifdef __cplusplus
}
#endif

#endif /* PWEB_COCOA_BRIDGE_H */
