# CAP-16 — Checkpoint 1

Branch `phase/cap-16/signal-channel`, at
`f8a99a3f3da01b64cc5747b049ac39b0c6b25653` (CAP-1 … CAP-15 and CAP-12 closed;
v0.2.3 is the baseline). This checkpoint measures what the brief asked to be
measured before the plan is ratified, and states every ruling the brief left
open. **Verdict: PLAN READY** (§12). The implementation continues in the same
run.

The request this shard answers is **FR-M1, "Native → JS signal channel"**, from
the application-consumer feature requests of 2026-09-16. That file is not part
of the repository, so its acceptance criteria are restated here, in the words
this shard is held to:

| FR-M1 | acceptance |
|---|---|
| 1 | signal only: native emits `(topic, sequence)`, no payload; the topic grammar is the capability grammar or stricter |
| 2 | bounded GUI cost: a bounded queue coalesces per topic (last sequence wins) and caps the script rate |
| 3 | loss-tolerant: per-topic sequences are monotonic, the SDK exposes the last one, a signal lost before subscribing, during a navigation or a dev reload costs a re-read |
| 4 | capability-gated: subscribing needs a capability evaluated natively; revoking it stops delivery; replacing the document drops every subscription of that document |
| 5 | no eighth interface: built on Dispatch + Eval inside the host, as the socket door is an `IInvocationBridge` decorator |
| 6 | three engines, and the ordering of successive Evals MEASURED on each; if one can reorder, the sequence number is what the SDK trusts |
| 7 | safe encoding: the script is built only from JSON-encoded values; a topic can never break out of its string literal |
| 8 | SDKs: `onSignal(topic, cb)` / unsubscribe in `@pweb/runtime` and the Pas2JS SDK; `pweb.handshake` advertises the feature |
| 9 | the socket door migrates: the receive loop becomes "wait for a signal, then receive without waiting" and no longer holds a worker while a socket is quiet |
| 10 | proof: N quiet sockets no longer starve other invocations, and a flood of native changes keeps the GUI thread responsive |

---

## 1. What was measured

### M1 — the one injected script, per engine (`test/cap16/evalprobe.pas`)

A raw-webview instrument with every production piece that decides what a page
is allowed to run: the platform asset handler, the navigation guard,
`PWEB_NATIVE_CSP` on every response, a folder store behind `IAssetStore`, and
**the production encoder** `PWebSignalScript` from the new
`src/rpc/pweb.rpc.signal.pas`. The page (`test/cap16/fixture/probe/`) carries
no SDK; it measures the engine.

| row | windows-x86_64 (WebView2, Edg/153) | linux-x86_64 (WebKitGTK, WSL Ubuntu 24.04, Xvfb) | macOS (WKWebView) |
|---|---|---|---|
| the page's own `eval("1")` | **blocked** | **blocked** | hosted leg |
| the page's own `new Function(...)` | **blocked** | **blocked** | hosted leg |
| an inline `<script>` the page inserts | **blocked** (never ran) | **blocked** | hosted leg |
| natively evaluated scripts that arrived | **219 / 219** | **219 / 219** | hosted leg |
| `isTrusted` on the delivered event | false (0 / 219) | false (0 / 219) | hosted leg |
| K = 100 scripts from 100 **separate** GUI dispatches issued by a worker | **in order**, 100 / 100 | **in order**, 100 / 100 | hosted leg |
| K = 100 scripts back to back inside **one** dispatch | **in order**, 100 / 100 | **in order**, 100 / 100 | hosted leg |
| 18 hostile topics through the production encoder | **18 / 18 exact** | **18 / 18 exact** | hosted leg |
| anything a hostile topic spells ran (`window.__cap16_pwned`) | **no** | **no** | hosted leg |

The 18 hostile topics: `"`, `\`, `</script><script>…</script>`, U+2028,
U+2029, `'`, `"]);…;//`, a newline, `${…}`, U+1F600, the invalid pair
`C3 28`, a NUL, `<!--`, `-->`, U+FEFF, U+0085, a backtick breakout, and the
lone-surrogate bytes `ED A0 80`. The two invalid sequences arrive as the
WHATWG replacement decoding (`U+FFFD (` and three `U+FFFD` then `x`), which the
encoder produces on purpose rather than passing invalid bytes to an engine.

**So a native script runs under `PWEB_NATIVE_CSP` exactly as the upstream
promise resolution always has** — every PWeb invocation already resolves
through the same engine API (`ExecuteScript`, `webkit_web_view_evaluate_javascript`,
`evaluateJavaScript:`), which CAP-8B recorded when it measured user activation
— while the page itself still cannot evaluate a string. WKWebView is the one
engine this host cannot reach; the probe runs on both hosted macOS legs in the
CAP-16 step and its rows are gated there by name. The indirect witness is the
same as on the other two engines: every macOS invoke since CAP-7M resolves
through `evaluateJavaScript:` under this CSP.

### M2 — which bound starves at N = 4 (the unmodified CAP-15C instrument)

`test/cap15c/socketstarve.pas` at the pre-migration tree, three shapes, queue 32:

| workers / slots | windows N=3 | windows N=4 | linux N=3 | linux N=4 |
|---|---|---|---|---|
| 4 / 4 (the host defaults) | 0.185 ms | **24 973.966 ms** | < 1 ms | **24 953.758 ms** |
| **8** / 4 | 0.084 ms | **24 994.545 ms** | < 1 ms | **25 005.486 ms** |
| 4 / **8** | 0.097 ms | **24 971.094 ms** | < 1 ms | **25 083.354 ms** |

**Both bounds bind, independently.** With eight workers the unrelated invoke
waits in the source queue because the four parked receives hold the window's
four slots; with eight slots it is admitted but waits for a worker, because the
four parked receives hold all four. Raising either one alone moves nothing at
N = 4, which is why CAP-15C's template raised both (ledger `15C-6`) and why a
larger pool was never the fix (`15CS-1`). This is for the ledger; no default
moves.

---

## 2. THE SECURITY RULING — the one injected script

**R1. Exactly one eval site in shipped code.** `webview_eval(` is called once
in `src/**`, inside `PWebHostSignalEval` in `src/webview/pweb.webview.host.pas`;
the external declaration in `src/lib/pweb.lib.webview.pas` is the binding, not a
call. `IWebView.Eval` stays declared and unimplemented (no new method). Pinned
by the CAP-16 source gate and by the dev-trust check (§8 below), both proven to
fire on a planted second site.

**R2. One literal template.** `PWEB_SIGNAL_EVAL_TEMPLATE =
'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:%}))'`. Its one
variable part is the array `[["topic",seq],...]` built by `PWebSignalScript`:
every topic through `PWebSignalJsonString`, which emits **printable ASCII only**
(`"`, `\`, `<`, `>`, `&`, `'`, every control byte and every code point above
U+007E — U+2028/2029 included — become `\uXXXX`; an invalid UTF-8 byte becomes
the U+FFFD escape), and every sequence as a decimal integer. Topics are
grammar-restricted before they are declared (`[a-z0-9]+(\.[a-z0-9]+)*`, ≤ 64
bytes) and are encoded anyway; M1 is the proof that the encoding alone holds.

**R3. The receiver is a DOM `CustomEvent` named `pweb:signal` on `window`.**
Ratified over a global function: there is no global name the page and the
runtime must agree on, a page that never loaded an SDK has no listener and the
dispatch is a no-op rather than a `ReferenceError`, and a page that redefines
something can only break its own listeners.

**R4. The channel carries no authority.** A delivered pair names a topic the
page already subscribed to and a counter. Every read it prompts is an
invocation the capability policy decides from the native context. A page that
dispatches `pweb:signal` to itself bypasses nothing, because the signal was
never needed to make that read — it only says "now would be a good time".
Measured by the CAP-8 gates unchanged (`capability_policy_digest`,
`navigation_policy_digest`): the CAP-16 suite is its own program, like 15B's and
15C's, so the CAP-8A corpus gains no row.

**R5. No new activation source.** CAP-8B measured that a navigation issued in
the continuation of an engine-evaluated script reports user activation on
WebView2 and WebKitGTK. The signal script navigates nowhere, the classifier is
forbidden to read activation, and every invoke resolution already runs through
the same engine API — so the channel adds nothing the page did not already
have.

**R6. Wording.** `_bmad-output/specs/spec-pweb/security-model.md` gains "The one
injected script" (its exact shape, why it is not an authority channel, R1–R5),
and `docs/kernel.md` gains the matching landmine. The existing sentences that
say "never injected script" / "never any injected HTML" describe the release
navigation and the development reload, and stay true: neither path uses the
channel. Both are cross-referenced rather than rewritten. The dev-trust check
gains section 8, which pins the template byte for byte, the site count, and the
wording.

## 3. Channel and coalescing

`TPWebSignalChannel` (`src/rpc/pweb.rpc.signal.pas`) is an `IInvocationBridge`
decorator, platform-free (no `mormot.net.*`, no webview unit, no conditional),
joining the CAP-7F zero-conditional core list.

- `Signal(topic)` (application topics, host-wide sequence) and
  `SignalWindow(window, topic)` (runtime topics, per-window sequence) run on any
  thread, increment the sequence and mark the pair pending for every
  subscribed window. **Coalesced**: one pending entry per (window, topic), the
  last sequence wins; the arrays are sized once per window, so a signal never
  allocates.
- **The pacer** (one thread, woken by an RTL event, idle otherwise) dispatches
  at most one drain per window per tick and never more than one outstanding
  dispatch per window. An isolated signal is dispatched at once; a burst is
  paced at `1000 div R` ms.
- **The drain** runs on the GUI thread: one script carrying every pending pair
  in declaration order, then the queue is empty. It evaluates **under the
  channel lock**, so a revocation or a document replacement that returned can
  never be followed by a script carrying what it removed.
- A global `PWebSignal(topic)` reaches the channel of the running host (the
  host installs it for the length of its run; no reference is held).

## 4. Subscriptions and capability

- `pweb.signalSubscribe {topic}` → `{topic, seq}`;
  `pweb.signalUnsubscribe {topic}` → `{}`. Both are registered
  **capability-free** in the templates; the authority is per topic.
- Topics are declared at composition: application topics by the constructor
  (the `pweb.` prefix refused), runtime topics by `DeclareWindowTopic` before
  the host runs; the set freezes when the view attaches.
- Subscribing needs `signal.<topic>` — or, for a runtime topic, the capability
  its door declared (`pweb.socket` → `network.socket`) — in
  `SnapshotCapabilities(principal, window)`, read **under the channel lock** at
  the moment of the call. An undeclared topic, a missing capability and a
  caller that is not a trusted window principal are one answer: `forbidden`,
  with no subscription and no script.
- Bounds refused by name: `service_error {category: signal_limit, bound}`.
- Unsubscribing needs nothing and is idempotent: removing is always safe.
- A subscription belongs to the (window, principal) of the native context; a
  page cannot name another window. It ends on unsubscribe, document
  replacement, revocation and drain.
- QuickJS is out of scope (backlog `9A-2`: the pinned wrapper has no job pump),
  and a non-window principal is answered `forbidden`.

## 5. Hook ownership — single slot stays single slot

| slot | owner | how the socket door hears it |
|---|---|---|
| `TPWebCapabilityPolicy.OnGrantsChanged` | the channel (`AttachPolicy`, called by the host) | the channel's one door slot, after the channel's own drop, outside its lock |
| host `DocumentReplacing` | the channel (derived by the host from `Options.Signals`) | same |
| host `BeforeDrain` | the channel | same |

`TPWebSocketBridge.AttachPolicy` is retired; the door calls
`AttachSignals(channel)`, which declares `pweb.socket` and takes the channel's
one door slot. A host given `Options.Signals` **refuses** a composition that
also sets `DocumentReplacing` or `BeforeDrain`. No fan-out primitive exists.
Lock order: a door may call the channel while holding its own lock; the channel
never calls a door while holding its lock.

## 6. The socket migration and the waitMs supersession

- **`waitMs` is retired.** `pweb.socketReceive {id}` returns what is queued at
  once, always. `waitMs` absent or `0` is accepted; any other value is
  `invalid_request`. `PWEB_SOCKET_MAX_WAIT_MS`, `TPWebSocketBounds.MaxWaitMs`
  and both SDKs' `PWEB_SOCKET_RECEIVE_WAIT_MS` are removed. **A CAP-15C contract
  supersession**, reason `15CS-1`.
- **One topic, window-scoped: `pweb.socket`**, per-window sequence, read under
  `network.socket`. Ratified over `socket.<id>`: topics are declared at
  composition and an id is minted at run time; an id on the channel would be a
  name, which R4 forbids; the bounds stay static. The cost is at most
  `PWEB_SOCKET_MAX_SOCKETS` (4) `receive` calls per tick, each of which returns
  at once.
- Every queued event signals the owning window. The SDK loop is: open →
  subscribe (once per page, shared) → `receive` → wait until the socket
  topic's sequence moves past the one seen when the last `receive` started, or
  the keepalive elapses → `receive`. **No worker is ever parked.**
- **The keepalive, `PWEB_SOCKET_KEEPALIVE_MS = 20000`**, one third of the
  unchanged idle bound (`PWEB_SOCKET_IDLE_MS = 60000`), keeps a quiet socket
  from being closed as idle and bounds the latency of any signal lost in a way
  the design did not foresee. Cross-checked native ↔ both SDKs, and required
  below half the idle bound.
- ~~One receive in flight per socket stays (`busy` otherwise).~~
  **Revised during implementation:** `busy` is retired for receive. With no
  wait, a second receive is never observable as "in flight"; the take is one
  step under the door's lock, so two receives of one socket each get a
  disjoint, ordered part of the queue (ledger `16-7`).
- The network template keeps its four extra workers and slots (**no default
  moves**); their parked-poll reason is gone, and what they still cover —
  opens and sends running under their own 10 s wall-clock deadlines — is
  recorded against `15C-6`.
- **The gate: no decorator in `src/rpc` waits on an event from an invocation.**
  Every `WaitFor` / `RTLEventWaitFor` / `Sleep` site in the decorator units
  (`socket`, `signal`, `fetch`, `command`, `mormot`) must sit in an allowlisted
  routine — the socket keeper and the signal pacer thread bodies, and the two
  teardown paths — so the bound for invocations is **0**. The transports'
  I/O waits are the engine's, under their own deadlines, and are listed, not
  allowed in a decorator. Proven to fire on a planted `Arrived.WaitFor` in
  `Receive`.

## 7. Starvation — the proof

`test/cap15c/socketstarve.pas` keeps its name, its composition and its host
numbers (read from `PWebDefaultHostOptions`), and changes only the loop it
drives: N ∈ {0, 3, 4, 5, **8**} quiet sockets each subscribed through the
channel with nothing in flight, then the unrelated `CalculatorService.Add`
timed. The harness raises the **socket** bound to 8 through
`TPWebSocketBounds` so that N = 8 really is eight sockets (the host bound stays
4). Gated: every N answers 42 in **< 5 ms**, the scheduler holds **0**
invocations beside the quiet sockets, a `waitMs` receive is `invalid_request`,
and one socket still echoes through signal → receive. Windows and Linux; macOS
`not_applicable` by name.

## 8. The caller principal (12-5)

`pweb.rpc.mormot` sets a **thread-scoped** pointer to the invocation context
around `TRestServer.Uri()` (saved and restored, so nesting is exact) and
exposes two documented helpers:

- `PWebCallerPrincipal(out PrincipalId): Boolean` — False outside a bridged
  call, including on any thread a service starts itself;
- `PWebCallerBlobPut(Store, Content, ContentType, out Handle, out Ceiling)` —
  creates the blob **for the caller** (it takes no owner) and returns the same
  handle JSON `pweb.fetch` returns (`token`, `url`, `size`, `type`).

No bridge signature and no interface changes. Proven headless with
`Jobs.Snapshot` returning a 2 MiB log as a blob (the caller reads it, another
principal is refused exactly as an unknown token, outside a call the helper
refuses), and live by URL on every target.

## 9. Bounds — one constants home (`pweb.rpc.signal`)

| bound | value | why |
|---|---|---|
| `PWEB_SIGNAL_TICKS_PER_SECOND` (R) | **20** | a signal says "re-read"; 20 re-reads a second is past what a person can follow, and it keeps the GUI thread's worst case to 20 tiny scripts a second per window |
| `PWEB_SIGNAL_TICK_MS` | 50 | 1000 / R |
| `PWEB_SIGNAL_MAX_TOPICS` | 64 | per host, runtime topics included |
| `PWEB_SIGNAL_MAX_SUBSCRIPTIONS` | 32 | per window, so one script carries at most 32 pairs |
| `PWEB_SIGNAL_MAX_WINDOWS` | 8 | windows one channel tracks |
| `PWEB_SIGNAL_MAX_TOPIC_BYTES` | 64 | `signal.` + 64 stays inside the 128-byte capability bound |
| queue depth | ≤ 32 pairs per window, 256 in all | coalesced: bounded by subscriptions, never by signals |
| largest script | 2 912 bytes | 64 + 32 × (2 + 64 + 2 + 19 + 1 + 1) |
| `PWEB_SOCKET_KEEPALIVE_MS` | 20000 | §6 |

**The flood proof:** 10 000 `Signal` calls a second for three seconds from a
worker thread yield **at most 3 × R + 1** scripts, a page timer's lateness is
recorded beside an idle baseline (an observation, not a gate), and the
channel's pending state is the same size before and after.

## 10. The smallest diff

| file | change |
|---|---|
| `src/rpc/pweb.rpc.signal.pas` | **new** — the channel, the encoder, the bounds |
| `src/rpc/pweb.rpc.socket.pas` | `waitMs` retired, `AttachSignals` replaces `AttachPolicy`, every queued event signals, keepalive constant |
| `src/rpc/pweb.rpc.mormot.pas` | the thread-scoped caller context and its two helpers |
| `src/webview/pweb.webview.host.pas` | `Options.Signals`; the dispatch trampoline; **the one `webview_eval`**; hook derivation; install/uninstall; view detach before destroy |
| both templates' `program.lpr` / `app.services.pas` | the channel composed in every host, `AttachSignals` in `PWEB_NET`, the two methods registered capability-free |
| `sdk/typescript/src/signal.ts` (new), `socket.ts`, `handshake.ts`, `types.ts`, `index.ts`; `sdk/pas2js/pweb.native.pas` | `onSignal` / `offSignal` / `lastSeq`, the migrated socket loop, the `features` row |
| `test/cap16/*` (new), `test/cap15c/*` | the suite, the probe, the live host, the composition, the gates; the socket suite, live program and starvation instrument migrated |
| `test/cap10a/check_dev_trust.ps1` | section 8 |
| CI, CAP-7F, CAP-11A, backlog, docs | the step, the evidence fields, the collection paths, the ledger, the contracts |

Frozen and untouched: `PWEB_NATIVE_CSP`; the seven interfaces (Eval and
Dispatch exist, no method added); protocol v1; `pweb.rpc.fetch*`,
`pweb.blobs.*`; every pin.

## 11. Adversarial

| question | answer |
|---|---|
| can the channel carry data or authority? | No. Two values per pair, a declared topic and an integer (R2, R4); every read is an invocation under the policy |
| can a page reach another window's signals? | No. Subscriptions are keyed by the native (window, principal); `SignalWindow` targets one window; the suite subscribes two windows and asserts each script carries only its own pairs |
| can a topic break the script literal? | No. M1 on two engines through the production encoder, the headless suite over the same cases plus every byte value, and the grammar before any of it |
| can a flood stall the GUI thread or grow memory? | No. ≤ R scripts a second per window, one outstanding dispatch, pending state sized once (§9) |
| can any invocation still park a worker? | No. `receive` never waits (§6) and the decorator sweep holds the bound at 0 |
| can the page fake a signal to itself? | Yes, and it gains nothing: a signal only ever prompts a read the page was already allowed to make (R4) |
| can the release host eval anything but the template? | No. One call site, whose only caller is the channel's drain, whose only script is `PWebSignalScript` (R1, R2) |
| can a service create a blob for a principal other than the caller? | Not through the documented helper, which takes no owner and reads the caller from the thread-scoped native context; a service is native code at the executable's trust level and can always hold `IBlobStore` directly — that is the trust model, not a page path. The page never names the owner |

## 12. Verdict

**PLAN READY.** Every finding above carries the ruling this shard takes; none
moves a frozen contract, digest or pin without the supersession the brief
already named (the 15C `waitMs` contract, the security-model wording, the
socket and handshake corpora, `ci_sequence_digest`). The one engine not
measured here, WKWebView, is measured by the same probe on both hosted macOS
legs and gated there.
