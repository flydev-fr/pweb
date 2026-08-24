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
 *   4. THE NAVIGATION DELEGATE (CAP-8B). WKNavigationDelegate is an
 *      Objective-C protocol whose decisions are delivered through BLOCKS, and
 *      Pascal has neither. CAP-8B MEASURED (M2) that this engine, unlike
 *      WebKitGTK, tells a new window from a subframe from a main frame at
 *      decision time - targetFrame == nil means a new window, otherwise
 *      targetFrame.isMainFrame - so the subframe and new-window rules are
 *      enforceable STRUCTURALLY here and not only through the CSP. Upstream
 *      owns the WKUIDelegate for its open panel (cocoa_webkit.hh:490-494) and
 *      leaves the navigation delegate unset, so this is an unoccupied seam and
 *      nothing of upstream's is displaced.
 *
 *   5. THE SYSTEM OPENER. -[NSWorkspace openURL:] takes an NSURL and needs an
 *      Objective-C frame. It is reachable ONLY from an explicit,
 *      capability-authorized runtime invocation (CAP-8B ratification R-A.2 and
 *      R-A.8): no navigation callback in this file may ever call it, because
 *      the four-target activation matrix measured that no engine can tell a
 *      genuine gesture from a script navigation issued after an RPC.
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

/* Longest native security-header block the seam will carry, INCLUDING the NUL.
   A fixed buffer for exactly the reasons the Content-Type one is: no second
   cross-boundary allocation, no second ownership rule, and a block that does
   not fit is a Pascal-side REFUSAL rather than a truncated policy - and a
   truncated Content-Security-Policy is a DIFFERENT policy, silently weaker
   than the one that was ratified. The current block (nosniff, Referrer-Policy
   and the CSP) is about 400 bytes. */
#define PWEB_COCOA_SECURITY_HEADERS_MAX 1024

/* One resolved asset, handed from Pascal to the bridge.

   bytes  : a pweb_cocoa_alloc() block the BRIDGE owns once resolve returns
            non-zero. Never NULL on success - a zero-length asset still gets
            a real allocation, so "empty" and "failed" can never be confused.
   length : exact body length; 0 is a legitimate asset, not a miss.
   content_type: NUL-terminated, never empty (an empty Content-Type would let
            the engine sniff).
   security_headers: the CAP-8B native policy, CRLF-separated `Name: Value`
            lines, NUL-terminated and NEVER empty on a serve.

            IT IS CARRIED ACROSS THE SEAM RATHER THAN SPELLED HERE, and that
            is the whole point: PWEB_NATIVE_CSP lives in exactly one file,
            src/security/pweb.navigation.policy.pas, shared byte-for-byte with
            Windows and Linux. A second copy of the policy string in
            Objective-C would be a second answer to the only question the
            response headers ask, and it would drift the first time one of the
            three was edited. MEASURED (M3): the header fields of this
            NSHTTPURLResponse ARE enforced on pweb://app, and a weaker bundle
            <meta> policy cannot relax a single row of them. */
typedef struct pweb_cocoa_asset {
  void *bytes;
  int64_t length;
  char content_type[PWEB_COCOA_CONTENT_TYPE_MAX];
  char security_headers[PWEB_COCOA_SECURITY_HEADERS_MAX];
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
  uint64_t policy_headers_missing; /* serves refused because Pascal attached no
                                    native security-header block: a privileged
                                    asset without the CSP is exactly what
                                    CAP-8B exists to prevent, so the bridge
                                    refuses it rather than serving it bare */
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
/* Put this thread's FPU in the C default (non-trapping) state. Returns 0 on
   success.

   MANDATORY BEFORE ANY WEBKIT WORK, and measured: FPC enables the
   invalid-operation, divide-by-zero and overflow traps at startup on BOTH
   architectures, while WebKit/CoreGraphics/AppKit compute with NaNs and
   infinities as ordinary intermediate values - so the first such computation
   kills an FPC-hosted process (`EInvalidOp`). CAP-7L hit this on
   Linux/WebKitGTK; the remedy there is x86-only, which is why it did not
   transfer.

   PER THREAD, which is why the adapter calls it more than once: at unit
   initialization (the main thread, before any worker exists, so workers
   inherit the masked state) and again in TCocoaAssetHandler.Create and
   TCocoaNavigationGuard.Create, both of which run on the thread that will
   actually host WebKit and neither of which is guaranteed by contract to be
   the same one. Idempotent, so calling it again costs nothing. */
int pweb_cocoa_mask_fpu_traps(void);

uint64_t pweb_cocoa_rss_kb(void);

/* ======================================================================== *
 *  CAP-8B: THE PRIVILEGED-NAVIGATION SEAM                                  *
 *                                                                          *
 *  THE INVARIANT: a WebView owning the privileged PWeb bridge may execute   *
 *  only trusted pweb://app content.                                        *
 *                                                                          *
 *  Nothing below DECIDES anything. Every hook translates a WKNavigation*    *
 *  object into the three scalars the shared classifier takes, calls out     *
 *  once, and translates the answer back into a WebKit policy constant. The  *
 *  classifier is src/security/pweb.navigation.policy.pas and it is the same *
 *  one Windows and Linux call; no WKWebView type appears in it and no       *
 *  policy table appears here.                                               *
 *                                                                          *
 *  NO CALLBACK BELOW MAY EVER REACH pweb_cocoa_open_external. That is       *
 *  ratification R-A.2, and it is not a style rule: the four-target matrix   *
 *  MEASURED that user activation cannot be told from a script navigation    *
 *  issued in the continuation of an RPC on two of four engines, and that    *
 *  this engine has no public gesture signal at all (M4 -                    *
 *  -[WKNavigationAction _isUserInitiated] is private SPI and is forbidden   *
 *  here). External opening is a capability-authorized invocation, never an  *
 *  inference from a flag.                                                   *
 * ======================================================================== */

/* TPWebNavKind, ordinal for ordinal. The adapter maps WebKit's frame facts
   onto these and nothing else; an integer outside this set is a Pascal-side
   DENIAL, never a guess. */
#define PWEB_COCOA_NAV_KIND_DOCUMENT 0
#define PWEB_COCOA_NAV_KIND_SUBFRAME 1
#define PWEB_COCOA_NAV_KIND_NEWWINDOW 2
#define PWEB_COCOA_NAV_KIND_DOWNLOAD 3

/* What the classifier answered. -1 exists for the same reason it does on the
   resolve callback: a released or never-claimed handle must be countable
   separately, and must then behave exactly like a refusal so nothing on the
   page can tell the two apart. */
#define PWEB_COCOA_NAV_ALLOW 1
#define PWEB_COCOA_NAV_CANCEL 0
#define PWEB_COCOA_NAV_UNRESOLVED (-1)

/* The ONE callback out of the navigation seam.

   handle        : the generation-checked Pascal handle, or 0 when disowned.
   absolute_url  : the WHOLE absolute URL of the request, never a path
                   accessor and never a rebuilt string - a path-only view of
                   pweb://evil/x reads as /x.
   kind          : one of PWEB_COCOA_NAV_KIND_*.
   user_activated: DIAGNOSTIC ONLY, and on this engine it is a derivation
                   rather than a measurement: WKNavigationType LinkActivated,
                   which MEASURED (M4) accepts a script-driven element.click().
                   The classifier is required not to read it, and the headless
                   corpus proves that by running every row twice with the flag
                   inverted.

   Returns PWEB_COCOA_NAV_ALLOW / _CANCEL / _UNRESOLVED. MUST NOT raise and
   MUST NOT block. */
typedef int (*pweb_cocoa_nav_fn)(uint64_t handle, const char *absolute_url,
                                 int kind, int user_activated);

/* Counters the CAP-8B gates assert on. All monotonic within a process.

   handlers_completed IS THE EXACTLY-ONCE WITNESS: WebKit hangs on a decision
   handler that is never called and raises on one called twice, so a gate
   asserts handlers_completed == action_decisions + response_decisions rather
   than trusting a code reading. allowed + cancelled equals the same sum.

   download_events is deliberately OUTSIDE both identities: a download is
   refused where it becomes one, and that hook has no decision handler to
   complete and no allow/cancel answer to give. */
typedef struct pweb_cocoa_nav_stats {
  uint64_t action_decisions;    /* decidePolicyForNavigationAction arrivals */
  uint64_t response_decisions;  /* decidePolicyForNavigationResponse arrivals */
  uint64_t download_events;     /* didBecomeDownload: arrivals, both hooks */
  uint64_t allowed;             /* decisions answered Allow */
  uint64_t cancelled;           /* decisions answered Cancel */
  uint64_t handlers_completed;  /* decision handlers actually invoked */
  uint64_t unresolved_handles;  /* callbacks whose handle did not resolve */
  uint64_t caught_exceptions;   /* exceptions caught at a navigation entry */
} pweb_cocoa_nav_stats_t;

/* Record the decision function and create the singleton delegate. Idempotent;
   like pweb_cocoa_install, a second, DIFFERENT function is refused rather than
   silently rebinding every future decision. Returns 1 on success. */
int pweb_cocoa_nav_install(pweb_cocoa_nav_fn decide);

/* Arm the navigation seam for one handler handle, exactly as pweb_cocoa_arm
   does for the scheme handler and for the same reason: the delegate is a
   process-wide singleton and a single callback can only consult one policy, so
   a second, different handle is refused rather than resolved in someone's
   favour. Returns 1 on success. */
int pweb_cocoa_nav_arm(uint64_t handle);

/* Disown: the delegate stops calling out. After this returns, no decision
   callback can be made for `handle` - and because the delegate then has no
   policy to consult, every hook FAILS CLOSED and cancels. Idempotent and safe
   from any thread (one atomic store). */
void pweb_cocoa_nav_disown(uint64_t handle);

/* Install the delegate on THIS WKWebView. `view` is the BROWSER_CONTROLLER
   native handle, which on Cocoa is the WKWebView itself.

   Returns 1 only if the read-back afterwards says OURS, so "attached" is a
   measured property of the view rather than the absence of an exception.
   Returns 0 - installing NOTHING - if a foreign delegate already owns this
   view: upstream leaves the navigation delegate unset, so anything there is
   somebody else's and displacing it would break them silently.

   Call it after webview_create and BEFORE webview_navigate. MEASURED (M5):
   this engine performs no initial about:blank at all, so there is no document
   to lose and no bootstrap exception to write. */
int pweb_cocoa_nav_attach(void *view);

/* Is OUR delegate the navigation delegate of THIS view? Same three values, and
   the same reading, as pweb_cocoa_handler_installed_on:
   PWEB_COCOA_READBACK_OURS / _ABSENT / _FOREIGN. Read-only, public API
   (-[WKWebView navigationDelegate]). */
int pweb_cocoa_nav_installed_on(void *view);

/* Remove the delegate from `view`, but ONLY if it is ours. Called AFTER
   pweb_cocoa_nav_disown and BEFORE the handle is released, so that a callback
   arriving in between finds a disowned seam and cancels rather than reaching a
   released Pascal object. */
void pweb_cocoa_nav_detach(void *view);

/* Snapshot of every navigation counter. `out` must not be NULL. */
void pweb_cocoa_nav_get_stats(pweb_cocoa_nav_stats_t *out);

/* Hand ONE URI to the operating system's default handler, as DATA.

   -[NSWorkspace openURL:] with an NSURL built from this exact string: no shell
   string, no /bin/sh, no system(), no subprocess and no interpolation
   anywhere. Returns 1 if the workspace accepted the URI, 0 otherwise - and 0
   is not an error path with a fallback, it is the end of the attempt: a
   refusal never turns into an internal navigation.

   THREAD AFFINITY IS SATISFIED HERE, not assumed of the caller: NSWorkspace
   is AppKit, the caller is a scheduler worker, and the openURL: message is
   dispatch_sync'd onto the main queue (direct when already on the main
   thread), so the result the caller sees is still the real one.

   THE SCHEME ALLOWLIST IS NOT HERE. Validation is PWebValidExternalUri in the
   shared classifier (https: and mailto: only, on parsed components, bounded
   length, no control bytes), so the rule has one home and this entry point has
   no policy of its own. Reachable ONLY from the capability-authorized runtime
   invocation; see the R-A.2 note at the top of this section. */
int pweb_cocoa_open_external(const char *uri);

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
