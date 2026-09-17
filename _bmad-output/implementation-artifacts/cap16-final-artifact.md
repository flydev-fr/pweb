# CAP-16 — the native → page signal channel, the socket door on it, and the caller principal

Branch `phase/cap-16/signal-channel`, baseline
`f8a99a3f3da01b64cc5747b049ac39b0c6b25653` (CAP-1 … CAP-15 and CAP-12 closed;
v0.2.3). Checkpoint 1 is `cap16-checkpoint1.md`; every ruling below is the one
it ratified, and the one departure from it is recorded there and as ledger
`16-7`.

**CLOSED on hosted run 35267611946**, commit
`d372e51290dcb7f8d98f5b7894486d5a58e28931` — the final HEAD of this branch.
All six jobs green: the four platform legs, the macOS release inventory and
`cap7 aggregate (windows = linux = macos-x64 = macos-arm64)`. The CAP-16 step
itself reports `success` on every leg, `cap16_failures = 0` on all four, and
the CAP-11A sequence gate measured the run's own step record at
`steps=208 digest=b2f3790f…`.

The measurements below were taken on this host — Windows 11 with WebView2
(Edg/153) and Ubuntu 24.04 under WSL with WebKitGTK 4.1 under Xvfb — and the
hosted run's four-target numbers, **WKWebView included**, are in
"the hosted run" below.

---

## SECURITY RULING (EVAL)

The channel is the first production script this runtime injects into a page,
and the ruling is pinned rather than described.

**One eval site.** `webview_eval(` is called exactly once in `src/**`, in
`PWebHostSignalEval` (`src/webview/pweb.webview.host.pas`); the external
declaration in `src/lib/pweb.lib.webview.pas` is the binding, not a call.
`IWebView.Eval` stays declared and unimplemented — no eighth interface, no new
method. Measured: `eval_sites_release = 1` on both targets, and the sweep was
observed **counting 2 on a planted twin** (K1) and again by the dev-trust
section 8.

**One literal template.**

```
window.dispatchEvent(new CustomEvent("pweb:signal",{detail:%}))
```

Its one variable part is the JSON array `[["topic",seq],…]` built by
`PWebSignalScript`. Every topic goes through `PWebSignalJsonString`, which
emits **printable ASCII only** — `"`, `\`, `<`, `>`, `&`, `'`, every control
byte and every code point above U+007E, U+2028 and U+2029 included, become
`\uXXXX`, and an invalid UTF-8 byte becomes the U+FFFD escape — and every
sequence is a decimal integer. The topic grammar (`[a-z0-9]+(\.[a-z0-9]+)*`,
at most 64 bytes) is checked at declaration and the value is encoded anyway.

**The engine rows, measured through the production encoder**
(`test/cap16/evalprobe.pas`, a raw-webview host carrying the platform asset
handler, the navigation guard and `PWEB_NATIVE_CSP` on every response):

| row | windows-x86_64 (WebView2) | linux-x86_64 (WebKitGTK) | macOS (WKWebView) |
|---|---|---|---|
| the page's own `eval("1")` | blocked | blocked | hosted leg |
| the page's own `new Function(…)` | blocked | blocked | hosted leg |
| an inline `<script>` the page inserts | blocked | blocked | hosted leg |
| native scripts that arrived | **219 / 219** | **219 / 219** | hosted leg |
| `isTrusted` on the delivered event | false (0) | false (0) | hosted leg |
| 100 scripts from 100 separate dispatches | **in order** | **in order** | hosted leg |
| 100 scripts back to back in one dispatch | **in order** | **in order** | hosted leg |
| 18 hostile topics | **18 / 18 exact** | **18 / 18 exact** | hosted leg |
| anything a hostile topic spells ran | **no** | **no** | hosted leg |

`eval_under_csp = true` on both: a native script runs while the page's own
`eval`, `Function` and inline script stay refused, so the channel needs no CSP
relaxation and the page gains none. `PWEB_NATIVE_CSP` is byte-identical to its
frozen text (`csp_policy_digest c98d03d5…` unchanged).

**The channel carries no authority.** A delivered pair names a topic the page
already subscribed to and a counter; every read it prompts is an ordinary
invocation the capability policy decides from the native context.
`capability_policy_digest 23b87da5…` and `navigation_policy_digest 360d69f2…`
are unchanged from the CAP-15C closure, and `raw_primitive_used = false`.

**Wording.** `_bmad-output/specs/spec-pweb/security-model.md` gains "The one
injected script" (its exact shape, and why it is not an authority channel);
`docs/kernel.md` gains the two matching landmines. The existing "never any
injected script" sentences describe the release navigation and the development
reload and stay true; they are cross-referenced, not rewritten. The dev-trust
check gained section 8, which pins the template byte for byte, the site count
and the wording, and was observed firing on the planted twin.

## CHANNEL AND COALESCING

`src/rpc/pweb.rpc.signal.pas` is an `IInvocationBridge` decorator, platform-free
(no webview unit, no `mormot.net.*`, no conditional) and on the CAP-7F
zero-conditional frozen core list beside `src/rpc/pweb.rpc.caller.pas`.

- `Signal(topic)` and `SignalWindow(window, topic)` run on any thread,
  increment the per-topic sequence and mark the pair pending per subscribed
  window. One pending entry per (window, topic) — **last sequence wins** — in
  arrays sized once per window, so a signal never allocates.
- The **pacer** (one thread, woken by an RTL event, idle otherwise) issues at
  most one `Dispatch` per window per tick, never more than one outstanding, on
  a **microsecond** clock: a millisecond clock gave 20.67 scripts a second
  against R = 20 on Linux, which is the whole reason the pacer reads
  `QueryPerformanceMicroSeconds`.
- The **drain** runs on the GUI thread and evaluates ONE script carrying every
  pending pair in declaration order, **under the channel lock**, so nothing a
  revocation or a document replacement removed can be carried by a script
  issued after that call returned.
- R = 20, 64 topics a host, 32 subscriptions a window, 8 windows, 64-byte
  topics, largest script 2 912 bytes — one constants home, cross-checked
  against both SDKs by K4.

Measured: 1000 signals on one topic → one dispatch, one script, one pair
(`signal_coalescing = true`); a flood of **30 000 signals in 3 s → exactly 60
scripts**, `signal_flood_evals_per_s = 20` on both targets, with a 10 ms page
timer's worst lateness `idle=1.5 flood=1.5` ms on Windows and `idle=2 flood=4`
ms on Linux under Xvfb (an observation, not a gate) and the channel's pending
state the same size before and after. Isolated latency: a signal reaches the page in
5.9 ms (Windows) / 6 ms (Linux).

## SUBSCRIPTIONS AND CAPABILITY

`pweb.signalSubscribe {topic}` → `{topic, seq}`; `pweb.signalUnsubscribe
{topic}` → `{}`. Both are registered **capability-free** in the templates: the
authority is per topic, `signal.<topic>`, read from
`SnapshotCapabilities(principal, window)` **under the channel lock at the
moment of the call**. Topics are declared at composition (application topics by
the constructor, which refuses the reserved `pweb.` prefix; runtime topics by
`DeclareWindowTopic`), and the set freezes when the view attaches.

An undeclared topic, a missing capability and a caller that is not a trusted
window principal are **one answer**: `forbidden`, with no subscription and
**zero scripts** — measured live (`signal_denied = forbidden scripts=0`) and
headless. Bounds are refused by name (`service_error`, category
`signal_limit`). A subscription belongs to the native (window, principal): two
windows each see only their own pairs, and `SignalWindow` reaches one window
only (`signal_window_isolation = true`).

Revocation stops delivery **before the revoking call returns**: revoked mid
flood, zero scripts carrying the topic afterwards, the other topic kept, and a
re-grant does **not** restore the subscription (ledger `16-5`, documented in
both SDK READMEs). Live: `signal_revoke = subscriptions=0 delivered_after=0`.
Replacing the document drops that window's subscriptions and its queue, the
other window's untouched; the page recovers by re-reading — live, a reload lost
**5** signals and the re-read recovered every one of them
(`signal_navigation = subscriptions_after=0 lost=5 recovered_seq=56`).

## HOOK OWNERSHIP

Single slot stays single slot.

| slot | owner | how the socket door hears it |
|---|---|---|
| `TPWebCapabilityPolicy.OnGrantsChanged` | the channel (`AttachPolicy`, called by the host) | the channel's one door slot, after the channel's own drop, outside its lock |
| host `DocumentReplacing` | the channel (derived by the host from `Options.Signals`) | same |
| host `BeforeDrain` | the channel | same |

`TPWebSocketBridge.AttachPolicy` is retired; the door calls
`AttachSignals(channel)`, which declares `pweb.socket` under `network.socket`
and takes the channel's one door slot. A host given `Options.Signals` **refuses
a composition** that also sets `DocumentReplacing` or `BeforeDrain`. No fan-out
primitive exists. The door may call the channel while holding its own lock; the
channel never calls a door while holding its lock, and the suite measures the
door being called after the channel's own work and outside its lock
(`signal_hooks_outside_lock = true`). The host gives the grants slot back on
drain (`signal_grants_slot_released = True`).

## SOCKET MIGRATION AND WAITMS SUPERSESSION

**`waitMs` is retired.** `pweb.socketReceive {id}` returns what is queued at
once, always: absent or `0` is accepted, **any other value is
`invalid_request`** — never clamped, never served as 0. `PWEB_SOCKET_MAX_WAIT_MS`,
`TPWebSocketBounds.MaxWaitMs` and both SDKs' `PWEB_SOCKET_RECEIVE_WAIT_MS` are
gone, and no file under `sdk/` names the parameter (K7, sweep over every
tracked `.ts`/`.pas`). This is a **CAP-15C contract supersession**, reason
`15CS-1`, recorded in `docs/cli-contract.md`.

**One topic, window-scoped.** Every queued event signals its window on
`pweb.socket` (per-window sequence, read under `network.socket`) — ratified
over `socket.<id>`, because an id on the channel would be a name and the
security ruling forbids names. The SDK loop in both SDKs is: open → subscribe
once per page → `receive` → wait until the topic's sequence moves past the one
seen when the last receive started, **or the 20 s keepalive elapses** →
`receive`. `PWEB_SOCKET_KEEPALIVE_MS = 20000` is one third of the unchanged
60 s idle bound, and K4 requires it below half of it.

**No decorator in `src/rpc` waits on an event from an invocation.** The gate
lists every `WaitFor` / `RTLEventWaitFor` / `Sleep` in the five decorator units
and requires each to sit in an allowlisted routine — the socket keeper and the
signal pacer thread bodies, and the two teardown paths — so the bound for
invocations is **0**: 6 waits, all accounted for, 5 transport waits listed as
the engine's own deadlines, and the sweep was observed **firing on a planted
`WaitFor` inside `TPWebSocketBridge.Receive`** (K6).

`busy` for a second receive is retired with the wait that made it observable
(ledger `16-7`): the take is one step under the door's lock, so two receives of
one socket each get a disjoint, ordered part of the queue. Measured by
`TwoReceiversShareTheQueue`: two page loops, 1000 messages, every message taken
exactly once, each loop's part in order, no refusal.

The socket corpus moved (`socket_corpus_digest 95b2cf7c… → 7cf7899e…`, 129
lines) and reads identically on Windows and Linux. The live socket exchange
still echoes through the migrated loop (`socket_signal_echo = cap16-echo`) and
the backpressure rows are unchanged (the 64-event and 1 MiB queue bounds still
park the reader, 1000 of 1000 delivered, 0 gaps).

## STARVATION CLOSED

`test/cap15c/socketstarve.pas` keeps its name, its composition and its host
numbers — read from `PWebDefaultHostOptions` in source: **4 workers, 4
simultaneous invocations per source, a queue of 32** — and changes only the
loop it drives: N quiet sockets, each subscribed through the channel with
nothing in flight, then the unrelated `CalculatorService.Add(20, 22)` timed.
The harness raises the **socket** bound to 8 so N = 8 really is eight sockets;
the host bound stays 4.

| N | windows-x86_64 | linux-x86_64 (WSL) | CAP-15C, same instrument, pre-migration |
|---:|---|---|---|
| 0 | 0.277 ms | 0.176 ms | 0.915 / 0.153 ms |
| 3 | 0.123 ms | 0.098 ms | 0.226 / 0.081 ms |
| 4 | **0.152 ms** | **0.081 ms** | **24 996.017 / 24 850.118 ms** |
| 5 | 0.108 ms | 0.106 ms | 24 984.483 / 23 072.573 ms |
| 8 | 0.159 ms | 0.098 ms | not measured (the bound refused the opens) |

The last column pairs the Windows number from hosted run 35246370993 (the
CAP-15C closure on `main`) with the Linux number from the local WSL run of the
same pre-migration instrument; the hosted Linux leg read 24 999.1 ms at N = 4
(ledger `15CS-1`).

Every row is `served`, answers 42, holds **0** invocations in flight beside the
quiet sockets, refuses a `waitMs` of 25 000 with `invalid_request` and carries
one echo through signal → receive. The gate is `< 5 ms` at every N on both
measuring legs; the slowest row is `socket_starvation_max_ms` (0.277 ms
Windows, 0.176 ms Linux). macOS says `not_applicable` by name, in both
directions, and the aggregator refuses either leg for saying the other's word.

Checkpoint 1 also measured **which bound starved** (ledger `16-8`): with 8
workers and 4 slots, and with 4 workers and 8 slots, N = 4 still waited about
25 s on both targets. Both bounds bind independently, so a larger pool was
never the fix. No default moved.

## CALLER PRINCIPAL (12-5)

`TMormotInvocationBridge.Invoke` sets a **thread-scoped** pointer to the
invocation context around `TRestServer.Uri()`, saved and restored so nesting is
exact, and two documented helpers read it:

- `PWebCallerPrincipal(out PrincipalId): Boolean` — False outside a bridged
  call, including on a thread a service started itself;
- `PWebCallerBlobPut(Store, Content, ContentType, out Handle, out Ceiling)`
  (`src/rpc/pweb.rpc.caller.pas`) — creates the blob **for the caller**, takes
  no owner, and returns the same handle JSON `pweb.fetch` returns (`token`,
  `url`, `size`, `type`).

No bridge signature and no interface changed. Measured headless with an
`IJobs.Snapshot` service returning a **2 MiB** log (the caller reads it byte for
byte; another principal is answered exactly as an unknown token; outside a call
nothing is created), and live by URL in the production host — 200, byte count
and FNV-1a equal to what the service wrote, `token` 32 characters
(`caller_principal_blob = true` on both targets). A service is native code at
the executable's trust level and can always hold `IBlobStore` directly; what
the documented helper cannot do is name an owner, and the page never names one.

## SDKS

`@pweb/runtime` gains `sdk/typescript/src/signal.ts`: `onSignal(topic, cb)`
returning `{topic, ready, off}`, `offSignal`, `lastSeq(topic)` and the
constants, with one `pweb:signal` listener on `globalThis`, sequence-trust
dedupe and the documented recovery pattern (subscribe, then read everything
once). `socket.ts` is migrated to the signal loop with the keepalive;
`handshake.ts` and `types.ts` carry `features`. The Pas2JS twin
(`sdk/pas2js/pweb.native.pas`) has `PWebOnSignal` / `PWebOffSignal` /
`PWebLastSeq` (−1 when unknown), `TPWebSignalSubscription`, the same socket loop
and the same handshake row. Both READMEs document the channel, the re-read and
the re-subscribe after a revocation. The SDK suites cover the new surface
(`signal.test.ts`, the Pas2JS window fake, the socket-loop and handshake
cases), and K4 cross-checks eight constants between the channel and both SDKs.
The handshake advertises `"features":["signal"]` at protocol **v1**, unchanged.
QuickJS is out of scope (`9A-2`, ledger `16-6`): the pinned wrapper has no job
pump, and a principal that is not a trusted window is answered `forbidden`.

## SUPERSESSIONS

| what | before | after | why |
|---|---|---|---|
| `pweb.socketReceive` contract | `waitMs` up to 25 000, clamped | `waitMs` retired; nonzero is `invalid_request` | `15CS-1` |
| a second receive in flight | `busy` | served, disjoint, ordered | ledger `16-7` |
| security-model wording | "never any injected script" only | plus "The one injected script" (R1–R5) and two `kernel.md` landmines | the first production script |
| CAP-15C socket corpus | `95b2cf7c…` | `7cf7899e…` (129 lines) | the migrated suite and the new two-receiver case |
| CAP-15C starvation rows | `served_after_a_parked_poll_returned … parked=4` | `served … in_flight=0 socket_bound=8 waitms=… echo=…`, plus `socket_starvation_n8` and `socket_starvation_max_ms`, gated < 5 ms | the starvation is closed, so the row is a gate and not a finding |
| CAP-5 handshake corpus | no `features` | `features` member | additive |
| CAP-10B1 React inventory (literal in `test/cap10b2/run_cap10b2_gates.ps1`) | `31244b06…`, 78 679 B | `869ff929…`, 80 939 B (16 files) | every generated host composes the channel; measured identically on Windows and Linux before the pin moved |
| template / public pack, both generated inventories, `shared_native_source_digest`, both `app.pwb` digests, the two release inventories, the SDK distribution digests (`sdk_files` 319 → 325) | CAP-15C closure values | measured this branch, equal across the targets that ran them | the templates and `src/` gained the channel; all compared, none pinned absolutely |
| CAP-7F evidence schema | 921 fields | **970** (47 CAP-16 + `socket_starvation_n8` + `socket_starvation_max_ms`) | the brief's evidence list |
| aggregator refusal floor | 248 → 253 (CAP-15C) | **287** (298 fired) | 12 starvation legs and 27 CAP-16 legs |
| `ci_sequence_digest` | `0379943652…` (207) | measured on the CAP-16 hosted run (208) | one step on four legs; recorded in `docs/ci-migration.md`, together with the CAP-12B row that table owed |
| backlog census | 457 entries, 64 open | **466**, **62** open (57 roadmap), 131 accepted, 273 closed | `16-1…16-9`; `15CS-1` and `12-5` CLOSED |

## REGRESSIONS

### windows-x86_64 (local chain, in CI order, one pass)

GREEN: CAP-10B0 build · CAP-10B1 build · CAP-10A build / contracts /
**dev-trust** (its record's new row reads `CAP-16: eval_sites_release=1
(planted twin 2); the one template is ratified and has no development
branch`) / gates · CAP-10B0 contracts / gates ·
CAP-10B1 contracts / gates / **private build proof and real GUI run** ·
CAP-10B2 build / contracts / gates (after the React pin moved) / proof ·
CAP-10C0 build / contracts / gates · CAP-10C1 build / contracts / gates ·
CAP-10C2 build / contracts / gates · CAP-10C3 build / contracts / ledger /
gates · CAP-10D0 build / contracts / gates · CAP-10D1 contracts / build /
gates · CAP-10D2 contracts / ledger / build / gates · CAP-10E source gate ·
CAP-14A contracts / gates · CAP-14B contracts / gates · CAP-15B contracts /
build / gates · CAP-12B contracts / build / gates · **CAP-15C contracts /
build / gates** · **CAP-16 contracts / build / gates** · CAP-7F divergence
sweep · CAP-7F always-false-conditional sweep · CAP-7F schema agreement
(970 = 970) · CAP-5 zero-network sweep · CAP-11A migration map / structure /
seeded cases · backlog gate.

Two steps were red on their first pass and are green now: `run_cap10b2_gates`
(the React inventory literal, superseded above) and `check_cap10d2_contracts`
(which refuses a modified shipped path — it was measured on an uncommitted
`sdk/pas2js/README.md`, and passes on the committed tree).

### linux-x86_64 (WSL Ubuntu 24.04, Xvfb, local chain in CI order)

GREEN: CAP-10B0 build · CAP-10B1 build · CAP-10A build / contracts /
dev-trust / gates · CAP-10B0 contracts / gates · CAP-10B1 contracts / gates /
proof · CAP-10B2 build / contracts / gates / proof · CAP-10C0 build /
contracts / gates · CAP-10C1 build / contracts / gates · **CAP-15C
composition** · **CAP-16 composition** · CAP-15C contracts / build / gates ·
CAP-16 contracts / build / gates · CAP-12B contracts / build / gates ·
CAP-15B contracts / build / gates · CAP-14A contracts / gates · CAP-14B
contracts / gates · CAP-10C2 build / contracts / gates · CAP-10C3 build /
contracts / ledger / gates · CAP-10D0 build / contracts / gates · CAP-10D1
contracts / build / gates · CAP-10D2 contracts / ledger / build / gates ·
CAP-10E source gate · CAP-7F divergence / always-false-conditional / schema
agreement · CAP-5 zero-network · backlog gate.

The CAP-16 composition is the day-one path, mechanised once on this leg:
`pweb create` → a declared `demo.tick` topic and a native worker thread that
signals it 40 times over 6 s → `pweb build` → `pweb run`. The page subscribed
through `@pweb/runtime`, was told **26** times and read the count **26**
(only from the signal callback — it has no reading timer), `CalculatorService.Add`
still answered **42**, the supervised application owned **0** listening sockets
across 39 samples, the release image carried one script literal and no
development console channel, and the page never named the raw primitive.

The CAP-7F aggregator and its negative self-test were run against a real
four-target evidence set — the last green `main` run (35246370993) — with the
CAP-16 rows and the new starvation shape patched in: **aggregate PASS**, and
the self-test **298 refusals fired** (floor 287), including all 12 starvation
legs and all 27 CAP-16 legs. The Windows emitter was run for real and its
`evidence.json` carries all 49 new fields.

### the hosted run — four targets, run 35267611946 on `d372e51`

| row | windows-x86_64 | linux-x86_64 | macos-x86_64 | macos-arm64 |
|---|---|---|---|---|
| `signal_suite` / `signal_contracts` | PASS | PASS | PASS | PASS |
| `signal_corpus_digest` | `af08e222…` — **the same 42 decisions on four targets** ||||
| `eval_sites_release` | 1 | 1 | 1 | 1 |
| `eval_engine` | webview2 | webkitgtk | **wkwebview** | **wkwebview** |
| `eval_under_csp` / `eval_page_csp` | true / eval, Function and inline all blocked ||||
| `eval_received` | 219/219 | 219/219 | **219/219** | **219/219** |
| `eval_ordering` | in_order / in_order | in_order / in_order | **in_order / in_order** | **in_order / in_order** |
| `eval_hostile_exact` / `eval_hostile_ran` | 18/18 / False | 18/18 / False | **18/18 / False** | **18/18 / False** |
| `eval_trusted_events` | 0 | 0 | 0 | 0 |
| `signal_denied` | forbidden scripts=0 ||||
| `signal_flood_sent` / `_scripts` / `_evals_per_s` | 30 000 / 60 / **20** | 30 000 / 60 / **20** | 30 000 / 60 / **20** | 29 999 / 60 / **20** |
| `gui_jitter_ms` (observation) | idle=0.9 flood=1.6 | idle=2 flood=3 | idle=3 **flood=38** | idle=9 flood=8 |
| `signal_latency_ms` (observation) | 6.3 | 6 | 6 | 21 |
| `signal_revoke` / `signal_navigation` | subscriptions=0 delivered_after=0 / lost=5, recovered ||||
| `socket_signal_echo` / `caller_principal_blob` | cap16-echo / true ||||
| `starvation_n4_ms` / `_n8_ms` | **0.127 / 0.274** | **0.264 / 0.140** | not_applicable | not_applicable |
| `socket_starvation_max_ms` | 0.289 | 0.269 | not_applicable | not_applicable |
| `signal_composition` / `_updates` | not_applicable | **PASS / 26** | not_applicable | not_applicable |
| `cap16_failures` | 0 | 0 | 0 | 0 |

**WKWebView is measured**, and it answers as the other two engines do: a
natively evaluated script runs under `PWEB_NATIVE_CSP` while the page's own
`eval` stays refused, every script arrives, both orderings hold, and no hostile
topic escapes its literal. Ledger `16-4` closes with it.

Two honest per-target observations rather than gates: macOS x64's page timer
was 38 ms late at worst under the flood (a shared-runner number on the slowest
leg — the bound it exists beside, at most R scripts a second, held at 20 on all
four), and macos-arm64's flood emitted 29 999 of 30 000 signals inside its
three-second window. `capability_policy_digest`, `navigation_policy_digest` and
`csp_policy_digest` are byte-identical to the CAP-15C closure on every leg.

## FREEZE

Untouched and measured so: `PWEB_NATIVE_CSP` (`csp_policy_digest c98d03d5…`);
the seven interfaces (`IWebView` is its eight methods, `Eval` and `Dispatch`
among them, no method added — K11); protocol **v1** (`bundle_protocol = 1`);
`capability_policy_digest 23b87da5…`; `navigation_policy_digest 360d69f2…`;
the fetch and blob units and the other 14 frozen units, byte-identical (K11);
`webview_pin cbbdee44…`; the mORMot pin `66d7d51c`; every lock file.

### the review, and what it changed

Three review layers read the whole diff. Nine findings survived verification
and were fixed in this branch: the handshake now **merges** into a `features`
member that already exists instead of adding a second one; `DetachView` clears
the flag that made a second `AttachView` unreachable; a replaced document
releases its window's **principal binding** along with its subscriptions, so
the next document's principal is answered by the policy rather than refused for
the life of the process; `PWebCallerBlobPut` encodes **every** string member;
the flood gate allows the ratified `R + 1` a second (a drain can land on each
end of a half-open window, so a gate written at exactly 60 would go red on the
run that fits the extra tick); the reload gate holds the **invariant** — what
was lost is what the re-read recovers — instead of the exact loss count a race
decides; K7's `waitMs` sweep is scoped to the **shipped** SDK so its suites can
assert the retirement; `docs/cli-contract.md` no longer swallows `waitMs` into
a code span and now tells an application generated before CAP-16 which two
registrations to add; and the SDK keepalive — the one thing that keeps a quiet
socket inside the idle bound — has a **test** with the clock under its control,
proven to fail on a neutered timer. Three findings were verified as real and
recorded rather than fixed (`16-10`, `16-11`, `16-12`); one — "a socket made
gone should still signal" — was implemented, measured, and **reverted** when the
suite showed it could not reach anyone: the revocation that closes the socket
removes the subscription first, by the ruling's own order.

## KNOWN LIMITATIONS

- **WKWebView is measured only on the hosted macOS legs** (`16-4`) — measured
  there, on run 35267611946, and not reachable from a development host.
- **A revoked subscription is not restored by a later grant** (`16-5`): the
  page subscribes again.
- **QuickJS plugins have no signal channel** (`16-6`, `9A-2`).
- **A signal can be lost** — before the subscription, across a navigation, on
  a page with no SDK — and costs a re-read, never correctness (`16-9`). A page
  can dispatch `pweb:signal` to itself and gains nothing by it.
- **The release image cannot pin "one script".** FPC materialises the template
  constant twice in the data section, so the composition holds the image to one
  *distinct* script literal and the exactly-one-site claim lives in the source
  gates.
- **A quiet socket costs one receive every 20 s** (the keepalive), which is what
  keeps it inside the unchanged 60 s idle bound.
- **A socket the runtime makes gone tells its page nothing** until that page's
  next receive (`16-10`): revocation, document replacement and shutdown each
  take the window's `pweb.socket` subscription with them, so there is no
  subscription left for a signal to travel on. Before CAP-16 the parked receive
  was woken; now a revoked socket's page learns within the keepalive.
- **The "no invocation waits" bound is about events** (`16-11`): the channel
  lock is deliberately held across one `webview_eval`, which is what makes a
  returned revocation final.
- **One target per window id, bounded by `PWEB_SIGNAL_MAX_WINDOWS`** (`16-12`).
- **The pacer wakes once a second when idle**, which is what retries a window
  whose dispatch the view refused; it costs one wake-up per second per host.

## VERDICT

FR-M1 acceptance 1–10 is met on four targets; the starvation is under 5 ms at
every N on both measuring legs; `waitMs` is retired with its supersession
recorded; 12-5 is closed; the security ruling is pinned by gates proven to
fire; every regression is green locally and on hosted run **35267611946**,
commit `d372e51290dcb7f8d98f5b7894486d5a58e28931` — six jobs green, the
aggregate included.

**CAP-16 PASS — SIGNAL CHANNEL FROZEN, STARVATION CLOSED**
