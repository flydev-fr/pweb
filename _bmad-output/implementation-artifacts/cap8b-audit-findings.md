# CAP-8B audit findings — the measured record

Companion to `spec-phase-8-cap8b-privileged-navigation.md`. This file holds
what was **measured**, target by target, by `test/cap8b/`. Nothing here is a
design decision; the decisions it feeds are the D-items presented at
Checkpoint 1.

Rule for every row below: a value is recorded only if a probe observed it at
runtime. "Not supported" is a result. An API name is never evidence.

## The instrument had to be corrected twice, and both corrections are findings

Recorded because each one would have produced a confident, wrong table.

**The instrument measured its own chatter.** The first driver announced each
case through a native binding before performing it. Upstream resolves a
binding promise by running script through the engine, and the engine runs
host-injected script *with a user gesture* — so every case reported
`user_initiated = 1`, including plain script navigations. Case attribution was
moved to a native URI table and progress to beacons that ride the resource
handler (no script execution, no gesture, and they survive the document being
torn down). The readings inverted. An audit instrument that talks to native
between cases is measuring the conversation, not the subject.

**A derived value must not wear a measured value's name.** Each engine offers
a different amount: WebView2 reports a real gesture flag; WebKitGTK reports
`is_user_gesture`; WKWebView exposes **nothing** publicly
(`_isUserInitiated` is SPI and forbidden here), so the best available is an
inference from `navigationType`. Emitting `user_initiated: false` on all three
would have made a question that was never asked look like an answer that came
back negative. The schema therefore carries, per event,
`user_initiated_basis` (how this row was obtained, or `unavailable:<why>`),
emits `user_initiated` as JSON **null** wherever the engine was not asked, and
carries a top-level `user_initiated_semantics` sentence. Each event also
carries `policy` — true only for a hook that can *refuse* — so a target with
more observation hooks cannot appear to have cancelled more.

---

## Windows x64 / WebView2 — MEASURED

Runtime `151.0.4129.86` (dev host, `webview.dll` from the CAP-4W-patched
pinned upstream). Instrument `test/cap8b/cap8b_audit_win.cpp`, ten phases,
three consecutive runs in agreement.

**Reproduced on a clean hosted runner.** Run `32256330091` (all seven jobs
green, `cap7-aggregate` included — the audit steps disturb no existing gate)
carried the Windows probe on WebView2 **151.0.4129.72**, a different build
from the dev host's **.86**. Every measurement below matched: identical native
arrivals, identical activation table (`act-real-click` included — the
synthesized gesture works headlessly on a hosted runner), and a byte-identical
CSP row set. The findings are reproducible and not a property of one machine's
runtime build.

### W1 — bridge exposure

`window.__pweb_invoke` is `function` and `window.__webview__` is `object` in
**every** context probed, and `window.chrome.webview.postMessage` is reachable
from every one of them:

| context | shim visible | raw transport reachable | origin | **native call arrived** |
|---|---|---|---|---|
| trusted `pweb://app` top document | yes | yes | `pweb://app` | **YES** (shim + raw) |
| same-origin `pweb://app` iframe | yes | yes | `pweb://app` | no |
| wrong-authority `pweb://evil` iframe | yes | yes | `pweb://evil` | no |
| `data:` iframe | yes | yes | `null` (opaque) | no |
| `about:blank` iframe (parent-injected) | yes | yes | `null` | no |
| `window.open('pweb://app/…')` popup | — | — | — | no (and no report returned) |

Native arrivals across the whole exposure phase were exactly
`shim.top-trusted: 1` and `raw.top-trusted: 1`.

**Finding W1.** The intent's warning is correct and the naive check is
worthless: the shim IS injected into every frame on this engine
(`AddScriptToExecuteOnDocumentCreated` is all-frames), so proving isolation by
testing for the SDK symbol would prove nothing. What actually stops a subframe
is that upstream registers only `ICoreWebView2::add_WebMessageReceived`, which
fires for the **top-level document only**; frame messages would need
`ICoreWebView2Frame`, which upstream never wires. Today's isolation on Windows
is therefore **incidental** — a property of what upstream did not subscribe to,
not of anything PWeb enforces. It must not be left resting on that.

### W2 — navigation event coverage

| case | hook that fired | observed before execution | cancellable |
|---|---|---|---|
| top-level script `location` | `NavigationStarting` | yes | **yes** |
| anchor click (script `.click()`) | `NavigationStarting` | yes | yes |
| `target=_blank` / `window.open` | `NewWindowRequested` | yes | yes (`Handled=TRUE`) |
| subframe navigation | `FrameNavigationStarting` | yes | yes |
| wrong-authority subframe | `FrameNavigationStarting` | yes | yes |
| trusted subframe | `FrameNavigationStarting` | yes | yes |
| form submission | `NavigationStarting` | yes | yes |
| meta-refresh out of `pweb://` | `FrameNavigationStarting` | yes | yes |
| download | `DownloadStarting` (`ICoreWebView2_4`) | yes | yes |
| reload (trusted subframe) | `FrameNavigationStarting` | yes | yes |
| `http:`, `mailto:`, `blob:`, unknown scheme, late `about:blank` | `NavigationStarting` | yes | yes |
| `file:` | **no event at all** | engine refuses it itself | n/a |
| `data:` top-level | **no event at all** | engine refuses it itself | n/a |
| `javascript:` URL | **no event at all** | **it EXECUTED** (marker set) | **no** |
| `history.pushState` + `back()`, fragment | no event | same-document | n/a |

**Finding W2a — `javascript:` is not a navigation here.** It executes in-page
and the navigation hook never sees it. The navigation classifier therefore
cannot be the defence for it; the native CSP is (`script-src 'self'` without
`'unsafe-inline'` blocks `javascript:` URLs, and the CSP phase measured inline
script blocked). Any plan that lists "javascript: denied by the classifier"
would be describing something that does not happen.

**Finding W2b — a `WebResourceRequested` 302 is not followed.** Two dedicated
control phases: with a 302 to an external URL, only the first leg produced an
event and the target never navigated; with a 302 to another `pweb://`
authority — which stays inside the resource filter, so being *asked* for it
would prove the redirect was followed — the target was **never requested**.
`IsRedirected` was false on every event in every phase. Since a PWeb app has no
network, a server redirect cannot arise either; the reachable redirect is a
meta refresh, and that one **is** seen and cancellable. The redirect row of the
policy is therefore satisfied, but not by the mechanism the plan assumed.

### W3 — user activation (the control experiment)

Four phases, each a fresh WebView whose page makes no native call it does not
have to, one navigation measured per phase:

| control | how the navigation was initiated | `IsUserInitiated` |
|---|---|---|
| `act-plain` | plain script `location.href` from a timer | **false** ✅ |
| `act-after-bind` | script, in the continuation of a `webview_bind` promise | **TRUE** ❌ |
| `act-after-eval` | script the host injected via `webview_eval` | **TRUE** ❌ |
| `act-real-click` | a genuine mouse click (`SendInput`, absolute) | **true** ✅ |

**Finding W3 — this is the shard's most consequential measurement.**
`IsUserInitiated` reports true for a genuine gesture, but it *also* reports
true for any navigation performed after a native binding round-trip, because
upstream resolves that promise through `ExecuteScript` and WebView2 runs
host-injected script **with a user gesture**. That is not an exotic path: it is
the ordinary shape of a PWeb page (`await invoke(...)` then follow a link). So
on Windows the flag cannot, by itself, separate "the user clicked a link" from
"the bundle navigated right after an RPC" — which is exactly the separation
rules B and C of the recommended policy depend on.

This also invalidated the audit's own first run: an earlier driver announced
each case through a binding, and every case then read `user_initiated = 1`.
Case attribution was moved to a native URI table and the readings inverted.
A measurement instrument that talks to native between cases measures its own
chatter.

### W4 — native CSP on the custom scheme

Response-header CSP is **fully enforced** on `pweb://app` HTML:

| probe | result |
|---|---|
| same-origin script | **ran** (policy is usable) |
| same-origin `fetch` | **loaded** (policy is usable) |
| inline script | blocked (`script-src`) |
| external script | blocked (`script-src-elem`) |
| external `fetch` | blocked (`connect-src`) |
| `wss://` WebSocket | blocked (`connect-src`) |
| external iframe | blocked (`frame-src`) |
| **trusted `pweb://app` iframe** | **blocked** (`frame-src 'none'`) |
| `<object>` | blocked (`object-src`) |
| `eval` | blocked (`script-src`) |
| `<base href>` | ignored (`base-uri`) |
| worker | blocked (`worker-src`) |

**Finding W4a — a bundle `<meta>` CSP cannot weaken it.** The `csp-meta` phase
serves the same page carrying
`default-src * 'unsafe-inline' 'unsafe-eval'; script-src * …` and its result
table is **identical, row for row**. Policies combine restrictively, measured
rather than asserted.

**Finding W4b — `frame-src 'none'` blocks trusted subframes too**, so the
"no subframes in the privileged WebView" rule is enforced twice over, and does
not depend on the engine being able to tell a main frame from a subframe.

**Finding W4c — `connect-src 'self'` is the right value, and `'none'` is not.**
`'none'` blocks same-origin `fetch` as well, and the repository's existing
CAP-4 gates fetch their own assets (`examples/06-assets/.../app.js`). `'self'`
still blocked every external connection and every `wss://` in the measurement.

### W5 — authority confusion (what the hook is actually handed)

Five confusable authorities requested from trusted content. What matters is
not whether they loaded — the audit's own trust test is a crude prefix match —
but **what URI the hook was handed**, because that is the string a production
classifier would parse:

| requested | URI delivered to the hook | engine behaviour |
|---|---|---|
| `pweb://APP/child.html` | **`pweb://app/child.html`** | authority **lower-cased** |
| `pweb://app.evil/child.html` | `pweb://app.evil/child.html` | unchanged, distinct authority |
| `pweb://app@evil/child.html` | **no event at all** | refused before navigation |
| `pweb://app:8080/child.html` | **`pweb://app/child.html`** | **port stripped** |
| `pweb:///child.html` | **`pweb://child.html/`** | first path segment **becomes** the authority |

**Finding W5a — `pweb://APP/` cannot be rejected here, and should not be.**
The engine folds authority case before any hook sees it, so a case-sensitive
authority rule would never fire on this engine; it could only ever disagree
with the asset layer, which already compares case-insensitively per RFC 3986.
`pweb://APP` and `pweb://app` are the *same origin*, so rejecting one is not a
security gain. This is direct evidence for D3.

**Finding W5b — the port is stripped.** `pweb://app:8080/` arrives
indistinguishable from `pweb://app/`. The classifier must still reject a
port-bearing authority (defence in depth, and other engines may not
normalize), but on this engine it will never see one.

**Finding W5c — an empty authority is REPARSED, not passed through.**
`pweb:///child.html` becomes authority `child.html`. It is correctly not
`app`, so it is denied — but it shows why the classifier must parse exactly
the URI the engine hands it and must never "repair" a missing authority into
a more permissive value.

### W6 — bootstrap `about:blank`

`get_Source` before the first navigate reports `about:blank`, but **no
`NavigationStarting` event is ever raised for it** — the first event in every
phase is our own `pweb://app` navigation. A *later* `about:blank` navigation
does raise an event and was cancelled successfully.

**Finding W5.** The single-use bootstrap exception appears to be **unnecessary
on Windows**. An exception nothing needs is an exception nothing tests; it
should not be written unless another engine demands it.

---

## Linux x64 / WebKitGTK 4.1 — MEASURED

WebKitGTK 4.1 **2.52.3** + GTK 3.24.41 + libsoup 3.4.4, under Xvfb on the
dev host's WSL Ubuntu-24.04 — byte-identical stack versions to the hosted
`ubuntu-24.04` runner (hosted run 32256330091 reported the same three
versions before it stopped at a compile error). Ten phases, all ran.

**Reproduced on a clean hosted runner.** Hosted run `32257803956` produced a
Linux artifact matching the local one exactly: the same eleven native-arrival
entries (all five raw-transport breaches included), the same activation table,
the same `MEASURED ABSENT` frame-discrimination verdict and the same `<null>`
initial source. L1 below is the shard's most serious claim, and it does not
rest on one machine.

### L1 — bridge exposure: THE BRIDGE IS NOT ISOLATED AT ALL HERE

| context | shim visible | raw transport | origin | **native call arrived** |
|---|---|---|---|---|
| trusted `pweb://app` top document | `function` | yes | `pweb://app` | **YES** (shim + raw) |
| same-origin `pweb://app` iframe | `undefined` | yes | `pweb://app` | **YES (raw)** |
| wrong-authority `pweb://evil` iframe | `undefined` | yes | `pweb://evil` | **YES (raw)** |
| `data:` iframe | `undefined` | yes | `null` (opaque) | **YES (raw)** |
| `about:blank` iframe | `undefined` | yes | `null` | **YES (raw)** |
| `window.open('pweb://app/…')` popup | `function` | yes | `pweb://app` | **YES (shim + raw)** |

**Finding L1 — this is the shard's most serious measurement.** On Windows the
shim is visible everywhere but no subframe message reaches native. On Linux it
is the exact inverse and far worse: the shim is correctly top-frame-only, and
**the raw transport reaches the native binding from every single context** —
including a wrong-authority document, an opaque `data:` document and an
`about:blank` frame. Upstream registers the `__webview__` script message
handler on the user-content manager, and WebKitGTK exposes it in every frame
of the view.

So on Linux today, any subframe that loads is a full holder of the privileged
bridge, and an opened window inherits it whole. Windows' isolation is
incidental; Linux has none. This is precisely why the intent forbade proving
isolation by checking the public SDK symbol — doing so would have reported
this engine as safe.

### L2 — frame discrimination: MEASURED ABSENT

Resolved by `dlsym` against the installed library rather than assumed:
`webkit_response_policy_decision_is_main_frame_document` **does not resolve**,
and no candidate accessor identifies the frame *being navigated* in a
`NAVIGATION_ACTION` decision. `WebKitNavigationAction` exposes navigation
type, user gesture, redirect, and a target frame *name* for new-window actions
only — none of which says which frame is navigating. `WebKitFrame` lives in
the web-process extension API, not the UI process.

**Finding L2.** A navigation-time subframe rule on this engine can only be
URI-based, so **CSP `frame-src 'none'` is the primary subframe defence on
Linux** — and, given L1, it is load-bearing rather than defence in depth.
This settles D6.

### L3 — user activation: identical to Windows, including the false positives

| control | `webkit_navigation_action_is_user_gesture` |
|---|---|
| plain script `location.href` from a timer | `false` ✅ |
| script navigation after a binding promise | **`true`** ❌ |
| script navigation from host-injected eval | **`true`** ❌ |
| real XTEST pointer click (2.2, delivered) | `true` ✅ |

**Finding L3.** Two independent engines over-report identically, which makes
the defect a property of *how the runtime resolves binding promises* rather
than of one vendor's flag. It also means no amount of per-platform tuning
recovers the distinction.

### L4 — native CSP: enforced, and the bundle cannot weaken it

Delivered through `webkit_uri_scheme_response_set_http_headers` (libsoup 3
`SoupMessageHeaders`) — the only public way, since
`webkit_uri_scheme_request_finish` carries no headers at all. Every row
matches Windows exactly: same-origin script `ran`, same-origin fetch `loaded`,
and inline script, external script, external fetch, `wss://`, external frame,
**trusted frame**, `<object>`, `eval`, `base-uri` and worker all blocked, with
nine violation reports naming the directives. The weaker bundle `<meta>` run
is **identical row for row**.

This settles D4 (the Linux header mechanism works) and corroborates D5
(`connect-src 'self'` keeps same-origin fetch usable on both engines).

### L5 — bootstrap and downloads

`initial_source_before_navigate` is `<null>` — this engine performs no initial
`about:blank` at all, corroborating W6 that the bootstrap exception should not
be written.

`download_hook_available` is **false**, and the probe says why rather than
implying the engine is blind: on WebKitGTK a page cannot reach a download hook
on its own — an undisplayable response arrives at `decide-policy`, and only
`webkit_policy_decision_download()` turns it into a download. The response
decision *is* observed and refusable, which is what the policy needs.

## macOS x86_64 and arm64 / WKWebView — MEASURED

WebKit 20621.3.11.11.3, macOS 15.7.7 (24G720), hosted run `32257803956`, both
architectures. **The two architectures produced identical results in every
table below**, so they are reported once.

### M1 — bridge exposure: identical to Linux, i.e. none

Native arrivals, the only authority, were the same eleven entries Linux
produced: `raw.iframe-same-origin`, `raw.iframe-wrong-authority`,
`raw.iframe-data`, `raw.iframe-about-blank`, `raw.window-open`,
`raw.top-trusted`, plus `shim.top-trusted` and `shim.window-open`.

**Finding M1.** The shim is correctly top-frame-only, and the raw
`webkit.messageHandlers.__webview__` transport reaches the native binding from
**every** context — a wrong-authority document, an opaque `data:` document, an
`about:blank` frame, and an opened window that inherits the shim as well.

**Three of the four targets therefore have no bridge isolation whatsoever.**
Only Windows is isolated, and only because upstream never subscribed to the
frame-level message event. This is the single most important result of the
audit and it is what CAP-8B has to fix.

### M2 — frame discrimination: PRESENT (unlike Linux)

Every navigation event carries `main_frame` and `target_frame`:
`target_frame=main`, `target_frame=sub` (with `main_frame=false`) and
`target_frame=none-new-window` for a `target=_blank`. So a structural
"deny every subframe" rule IS enforceable here, exactly as on Windows through
its separate hook — and only Linux must fall back to CSP.

### M3 — native CSP: enforced, bundle cannot weaken it

Row for row identical to Windows and Linux, delivered through the scheme
handler's `NSHTTPURLResponse` header fields: same-origin script `ran`,
same-origin fetch `loaded`, and inline script, external script, external
fetch, `wss://`, external frame, trusted frame, `<object>`, `eval`, `base-uri`
and worker all blocked. The weaker bundle `<meta>` run is identical.

### M4 — user activation: no public flag, and the one public signal is spoofable

`user_initiated` is **null on every row** — this engine exposes no public
gesture flag (`_isUserInitiated` is SPI and forbidden here), so the probe
refuses to invent one. `nav_type` carries the real observation.

### M5 — bootstrap

`initial_source_before_navigate` is `<nil>`: no initial `about:blank`. With
Windows raising no event for its own and Linux reporting `<null>`, **the
bootstrap exception should not be written on any target.** D8 settled.

---

## The definitive user-activation matrix (all four targets)

The question the intent asked — can every platform reliably distinguish a
user-initiated external link from a script-initiated one — now has a complete
answer, and it is **no**, for a *different* reason on each engine:

| case | Win `IsUserInitiated` | Linux `is_user_gesture` | Linux `nav_type` | Linux conjunction | macOS `nav_type` (its only signal) |
|---|---|---|---|---|---|
| plain script `location` | false ✓ | false ✓ | OTHER | false ✓ | Other ✓ |
| **after a binding promise** | **true ✗** | **true ✗** | OTHER | false ✓ | Other ✓ |
| **after host-injected eval** | **true ✗** | **true ✗** | OTHER | false ✓ | Other ✓ |
| **script `a.click()`** | false ✓ | false ✓ | LINK_CLICKED | false ✓ | **LinkActivated ✗** |
| real input gesture | true ✓ | true ✓ | LINK_CLICKED | true ✓ | LinkActivated ✓ |

- **Linux can be made correct**: the conjunction `is_user_gesture AND
  navigation_type == LINK_CLICKED` classifies all five cases correctly.
- **Windows cannot**: it exposes no navigation type on
  `NavigationStartingEventArgs`, only the flag — which cannot tell a real
  click from a navigation issued right after any RPC.
- **macOS cannot**: it exposes no gesture flag at all, and its navigation type
  alone accepts a script-driven `element.click()`.

So a single shared rule is wrong on two engines, and no per-engine rule is
correct on Windows or macOS. This is the evidence for the P2 options.

---

## X1 — `frame-src 'none'` does NOT block an `about:blank` iframe (both engines)

Found by auditing the audit: question 3 never probed the *local-scheme*
frames, and CSP treats `about:blank` and `data:` specially. Added and
measured on both engines I can run:

| probe | Windows/WebView2 | Linux/WebKitGTK |
|---|---|---|
| external `https:` iframe | blocked | blocked |
| trusted `pweb://app` iframe | blocked | blocked |
| **`about:blank` iframe** | **loaded — same-origin child reachable** | **loaded — same-origin child reachable** |
| `data:` iframe | not observed as a violation | blocked |

**What this does and does not mean.** It is *not* a way in for hostile
content: an `about:blank` child has no content of its own, and only the
already-privileged parent can script it, so nothing crosses a trust boundary.
What it does mean is that **"no subframes in the privileged WebView" is not
literally achievable** — a trusted page can always create a same-origin empty
frame, and on Linux that frame can reach the native binding through the raw
transport (L1).

Consequence for the plan: the acceptance criterion must be worded as *"no
untrusted content executes in any frame"* rather than *"no frame exists"*, and
the bridge-isolation proof must not assert an absence of subframes it cannot
deliver. A test written to the stronger wording would fail on both engines for
a reason that is not a defect.

---

# Decisions proposed for Checkpoint-1 ratification

Drafted from the Windows measurements. Anything marked **[pending]** cannot be
settled until the other three targets report.

## P1 — the classification table, as measured

The recommended v1 table survives, with three amendments the measurements
force. The classifier's job is unchanged; what changes is the claim about
*which mechanism* enforces each row.

| URI / situation | action | enforced by |
|---|---|---|
| `pweb://app/<canonical>`, `pweb://app/`, fragment, reload, history within it | AllowTrusted | classifier |
| `https:` / `mailto:` | Cancel (+ external open only if P2 says so) | classifier |
| `http: ws: wss: ftp: blob:` + unknown schemes | Cancel | classifier |
| `pweb://` with any authority but `app` | Cancel | classifier |
| any subframe document | Cancel | classifier **and** `frame-src 'none'` |
| any new window | Cancel | classifier |
| download | Cancel | classifier |
| late `about:blank` | Cancel | classifier |
| **`file:`** | Cancel | **engine refuses it; no hook fires** |
| **top-level `data:`** | Cancel | **engine refuses it; no hook fires** |
| **`javascript:`** | Cancel | **CSP only — no hook fires and it EXECUTES without one** |

The last three rows still belong in the classifier as defence in depth — a
different engine may well hand them over — but the plan must not claim the
classifier is what stops them on Windows. For `javascript:` in particular, the
only thing standing between a tampered bundle and execution is
`script-src 'self'` without `'unsafe-inline'`.

## P2 — user activation: reliable parity is NOT achievable **[pending Linux/macOS]**

The intent anticipated this: *"If reliable parity cannot be achieved, present
options for human ratification."* On the evidence so far it cannot. Windows'
flag is true for a real click **and** for any navigation in the continuation of
a native binding call — the ordinary shape of a PWeb page. macOS exposes no
public gesture signal at all. Options, to be presented with the full data:

- **A — no external opener in CAP-8B.** Every external navigation is cancelled
  and nothing is ever handed to the OS. Strictly fail-closed and trivially
  provable, but it drops the `https:`/`mailto:` behaviour `security-model.md`
  ratified, so it is a scope reduction the human must accept explicitly.
- **B — accept the engine flag as measured.** Preserves the ratified
  behaviour, and accepts that a tampered bundle can open the system browser at
  an arbitrary URL immediately after any RPC. No code executes in the
  privileged origin, but it is a real exfiltration/phishing channel.
- **C — make the external open a capability, not a guess.** Cancel all raw
  external navigation, and let the app request an external open through the
  existing invocation path, authorized by the CAP-8A policy like any other
  method. "Who may open a browser" becomes an authorization decision instead
  of an inference from a flag that two of four engines cannot report honestly.
  It needs no kernel change and no second RPC path — but it adds product
  surface beyond navigation, so it is the human's call whether it belongs in
  CAP-8B or is deferred with the rule set to A in the meantime.

Recommendation, subject to the pending data: **A now, C recorded as the
successor** — because B is the only option that makes a security claim the
measurements do not support.

## P3 — trusted-origin comparison

Keep ONE truth: the canonical `PWebParseAppUri`, authority compared
case-insensitively per RFC 3986. The engine lower-cases the authority before
any hook sees it (W5a), so a case-sensitive rule could never fire, and
`pweb://APP` and `pweb://app` are the same origin. The intent's "reject
`pweb://APP/`" is therefore declined **with evidence**, and the classifier
still rejects userinfo, port, suffix and empty authorities on parsed
components — never on a prefix test.

## P4 — the CSP string

The candidate profile is enforced in full on Windows and a weaker bundle
`<meta>` cannot touch it. One deviation from the intent's draft, with
evidence: **`connect-src 'self'`, not `'none'`** — `'none'` also blocks
same-origin `fetch`, and `examples/06-assets/frontend/dist/assets/app.js` and
`test/cap7m/fixture/probe.js` both depend on it through the production
handlers. `'self'` blocked every external connection and every `wss://` in the
measurement. **[pending]** on the other three engines.

## P6 — the system external opener

Proposed private native APIs, one per platform, each taking the URI **as
data** — no shell string, no `cmd.exe`, no `/bin/sh`, no `system()`, no
subprocess interpolation anywhere:

| target | API | notes |
|---|---|---|
| Windows | `ShellExecuteExW` with `lpVerb=L"open"`, `lpFile=<uri>`, `lpParameters=nil`, `SEE_MASK_NOASYNC or SEE_MASK_FLAG_NO_UI` | the URI is a single argument handed to the registered protocol handler; nothing is parsed by a shell |
| Linux | `g_app_info_launch_default_for_uri(uri, nil, @err)` | public GIO; `libgio-2.0.so.0` is **already** a declared external of the production adapter (`pweb.platform.webkitgtk.pas:196`), so no new shipped library |
| macOS | `-[NSWorkspace openURL:]` through the existing private Objective-C++ bridge | public AppKit; no second dylib, no public C ABI change |

Guards, applied in the shared classifier **before** any platform code is
reached: scheme allowlist (`https`, `mailto` only — decided by the classifier,
never by the opener), bounded URI length, control-character rejection, and no
logging of the full query string or mail body. The opener is reached only from
`CancelAndOpenExternal`, never from a raw navigation event, and a failure
returns a native diagnostic and leaves the trusted page exactly where it was —
there is no internal-navigation fallback.

Test seam: a private function-pointer indirection with a counting fake, so the
"called exactly once / never called" assertions are deterministic in CI. It is
**not** a public kernel interface and does not appear in any of the seven
frozen contracts.

Note this section is a *proposal*, not a measurement: none of the three APIs
has been exercised yet, because the opener is production work that the intent
gates behind Checkpoint 1. If P2 lands on option A there is no opener to build
at all.

## P5 — bootstrap `about:blank`

Do not write the exception unless another engine demands it. Windows reports
`about:blank` as its initial source but raises no navigation event for it, and
a later `about:blank` is cancellable. **[pending]** — if Linux and macOS agree,
the Bootstrapping/Armed state machine should not be built at all.
