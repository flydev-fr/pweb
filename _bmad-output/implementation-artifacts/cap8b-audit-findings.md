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

## Linux x64 / WebKitGTK 4.1 — PENDING (hosted run 32256330091)

## macOS x86_64 / WKWebView — PENDING (hosted run 32256330091)

## macOS arm64 / WKWebView — PENDING (hosted run 32256330091)

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

## P5 — bootstrap `about:blank`

Do not write the exception unless another engine demands it. Windows reports
`about:blank` as its initial source but raises no navigation event for it, and
a later `about:blank` is cancellable. **[pending]** — if Linux and macOS agree,
the Bootstrapping/Armed state machine should not be built at all.
