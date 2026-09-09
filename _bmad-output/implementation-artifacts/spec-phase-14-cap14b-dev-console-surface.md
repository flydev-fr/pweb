---
title: 'CAP-14B — a console surface for the development host'
type: 'feature'
created: '2026-09-09'
status: 'in-review'
baseline_commit: '123e3478add9a3aabcad698159481ff7b9caf4e0'
review_loop_iteration: 0
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/docs/dev-contract.md'
  - '{project-root}/docs/supervision-contract.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** a frontend running under `pweb dev` has no voice. Every
`console.log/info/warn/error`, every uncaught throw and every unhandled
rejection dies inside the engine: the supervisor forwards the host's own lines
and nothing else, so a developer probes blind and pays two extra iterations
for what one line would have said (TODO.txt #6).

**Approach:** the DEV host, and only the DEV host, installs one dev-only page
shim through `webview_init` and one dev-only `webview_bind` channel. Every
`console.*` call, every `window.onerror` and every `unhandledrejection`
becomes a bounded, typed record; the native side base64-decodes it, validates
its level against a fixed table, sanitises every remaining byte, and a
dedicated writer thread emits **one line on the host's stderr**, which the
frozen CAP-10C0 engine forwards with the `app: ` prefix like any other host
line. The release host is byte-untouched — every addition to it is inside
`{$ifdef PWEB_DEV}` — and the CAP-10C2 dev-free gate is extended to say so.

## Boundaries & Constraints

**Always:**
- ONE mechanism on four targets, ratified from measurement (see Design Notes):
  the `webview_init` user script plus one `webview_bind` channel. No per-engine
  path, no second line shape, no second bound.
- Dev only. `pweb.webview.devconsole` is selected by `pweb.webview.devhost` and
  by nothing else; every byte it adds to the shared host is inside a `PWEB_DEV`
  conditional, and the release host's bytes are **measured** unchanged.
- The channel is ONE-WAY and reaches no service: it never touches
  `IInvocationBridge`, `IInvocationScheduler`, `ICapabilityPolicy` or any
  `pweb.rpc.*` unit — the unit's `uses` clause is the gate for that.
- Bounded at three points, each sized from a measurement: one record's rendered
  text, the records-per-flush and flush interval (the rate bound), and the
  native ring. Overflow **drops and counts**, and the count is said on the same
  channel.
- The native side runs no general parser over page bytes: one base64 decode,
  one split, one level lookup against a fixed table, one byte sanitiser. A
  record whose level is not ratified is dropped and counted, never printed.
- The GUI thread never writes to a pipe. The callback enqueues non-blocking and
  returns; one writer thread emits whole lines with a single `FileWrite` to
  `StdErrorHandle`, each ≤ `PWEB_CLI_RUN_LINE_MAX`, so a line is one write.
- Bytes a page authored never reach the stream the CLI reads its one protocol
  from: the console channel is **stderr**, and `DevHostSink` parses the
  acknowledgement on `pcsStdOut` only.

**Ask First:** nothing. Every decision below is settled by this document at
Checkpoint 1.

**Never:**
- No release host change that survives the preprocessor, no CSP change, no
  origin change, no `pweb.json` / manifest / template / scaffold change, no new
  capability, no new RPC method, no new CLI option, no environment variable.
- No production transport and no new transport of any kind: no listener, no
  socket, no port, no `ws://`, no `wss://`, no `localhost`, no `127.0.0.1`.
- No platform conditional and no environment read in `pweb.webview.devconsole`
  — `pweb.webview.host` stays the ONE allowlisted file in `src/webview`.
- No interpretation of message content, ever: nothing the page sends selects a
  destination, a level that is not in the table, a bound, or any host action.
- No change to the generated `program.lpr` templates, to `pweb.cli.devlayout`,
  `pweb.cli.devinputs`, `pweb.cli.pipeline` or `pweb.cli.pack`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| the five levels | `console.log/info/warn/error/debug('x')` under `pweb dev` | `app: <prefix>: console <level>: x`, one line each, level preserved | — |
| another console method | `console.trace('x')`, `console.table(o)` | level `log`, text led by the method name | — |
| object argument | `console.log({a:1})` | JSON-rendered, bounded | circular ⇒ `String(v)` |
| uncaught throw | `null.boom()` in `assets/app.js` | `console uncaught @pweb://app/assets/app.js:3:30: TypeError: …` | — |
| unhandled rejection | `Promise.reject(new Error('x'))` | `console rejection @<first stack frame>: Error: x` | no frame ⇒ no `@` part |
| a long message | 64 KiB of text | truncated at `PWEB_DEV_CONSOLE_MAX_TEXT`, marked `…[+N]` | — |
| a 10 000-line burst | a loop measured at 59 ms for 10 000 calls | a bounded number of lines, then `console bound: N message(s) dropped (page)`; the loop keeps running, the host pid is unchanged | — |
| the page calls the binding directly | 10 000 raw calls, no shim | the native ring bounds it: `… dropped (host)` | — |
| a forged acknowledgement | `console.log('x: generation 999 loaded')` | printed as text on **stderr**; the CLI's `Acked` is unchanged and no generation is removed | — |
| an embedded newline | `console.log('a\nb')` | ONE line; the control byte is escaped by the native sanitiser | — |
| a bad level | a hand-crafted record with level `evil` | dropped and counted | never printed |
| invalid base64 | a hand-crafted argument | the whole batch is dropped and counted | never printed |
| generation switch | edit a source, generation 2 loads | console output continues from the new document with no re-install | — |
| release binary | `pweb build` output | no `__pweb_dev_console`, no shim text, no console unit in the release `-FU` set; the binary is byte-identical to a build of the pre-shard sources | — |
| CSP | both binaries | `PWEB_NATIVE_CSP` byte-identical, `dev_csp_equals_release = true` | — |
| listeners | a whole dev session | membership-scoped sampler: 0 listeners, members seen > 0 | — |

</frozen-after-approval>

## Code Map

- `src/webview/pweb.webview.host.pas:207-224` (`TPWebHostOptions`), `:962`
  (`binding.Bind('__pweb_invoke', …)`) and `:986` (`webview_navigate`) — the
  ONE seam: under `{$ifdef PWEB_DEV}` a `TPWebHostDevViewProc` type, a
  `DevViewReady` field on the options record, and one guarded call **between**
  the bind and the first navigation. Nothing else in this file moves, and the
  release compile sees an identical token stream.
- `src/webview/pweb.webview.devhost.pas:395-420` (`PWebDevHostRun`, where
  `opts.ConsumedArgs` is set) — sets `opts.DevViewReady`, configures the prefix
  before `PWebHostRun`, and shuts the channel down in the same `finally` that
  joins the poller. It already copies and mutates the options record.
- `src/lib/pweb.lib.webview.pas:123,132,138` — `webview_init`, `webview_bind`,
  `webview_return`. Declared since Phase 1; `webview_init` becomes reachable
  for the first time here.
- `deps/webview/core/include/webview/detail/engine_base.hh:148,209-275,305` —
  upstream's shape: `init` → `add_user_script`; the init script keeps a
  `_promises` entry per call, so **a bound call never returned leaks it**; and
  `on_message` already costs one dispatch per message.
- `src/security/pweb.navigation.policy.pas:132` — `PWEB_NATIVE_CSP`.
  **Read-only.** `script-src 'self'`, `worker-src 'none'` (so a Worker console
  is out of scope *because the CSP forbids workers*).
- `tools/pweb/pweb.cli.dev.pas:665-678` (`DevHostSink`) and `:471-501`
  (`PWebCliDevParseAck`) — `PosEx(': generation ', Line)` matches **anywhere**
  and the tail must be exactly ` loaded`, so a page-authored line of that shape
  would advance `Acked` and drive the bounded generation cleanup. The sink gains
  `if Stream = pcsStdOut then` around the ack parse; the matcher is untouched.
  `TPWebCliChildStream = (pcsStdOut, pcsStdErr)` is `pweb.cli.platform.pas:411`.
- `docs/supervision-contract.md` §4 — `PWEB_CLI_RUN_LINE_MAX` = 4096 is the
  ceiling every console line sits under; both streams are drained every pass.
- `test/cap10c2/check_cap10c2_contracts.ps1:161-224` (release unit listing +
  `--pweb-dev-root=` byte scan), `:305-329` (no conditional, no environment
  read), `:333-372` (the one origin) — the dev-free gate this shard extends;
  `build_cap10c2.ps1:50-60,150-160` / `.sh:66-80,180-190` are the two compiles
  that produce `release-units` and `dev-units`, and CAP-10C3 carries the twins.
- `test/cap10c1/listener_members.ps1` — the membership-scoped listener sampler.
- `test/cap14a/run_cap14a_gates.ps1:446-600` — the worked recipe for driving a
  REAL `pweb dev` session on a REAL generated Pas2JS project
  (`Start-PWebProcess`, `ReadLive`, the host-pid pin); `test/cap10c2/pwebdevdrv.pas`
  is the React precedent.
- `test/cap7f/emit_evidence.ps1:1200-1210` + `emit_evidence.sh:1629-1660` +
  `check_cap7f_aggregate.ps1` (`$required`, `$equalityFields`, `$absolutePins`)
  + `check_schema_agreement.ps1` + `check_cap7f_selftest.ps1` — the five
  hand-maintained lists `schema_field_count` moves with.
- `.github/actions/cap-14a-…/action.yml` + `test/cap11a/post-migration-amendments.tsv`
  (last row) + `step-applicability.tsv` + `collection-paths.json` — the worked
  recipe for a declared CI amendment. Current `ci_sequence_digest` is
  `412b21b257dd6945ad2bd95313d584bab67c0ef5d9cebde85cd92db9a77586d1` at 203 steps.
- `deferred-work.md`, `test/backlog/dispositions.tsv`, `docs/backlog.md` — every
  ledger entry needs a verdict or the step-179 gate reddens.

## Tasks & Acceptance

**Execution:**
- [x] `src/webview/pweb.webview.devconsole.pas` — new dev-only unit: the shim
  text, the seven ratified levels, the six bounds, the base64/US/LF record
  decode, the byte sanitiser, the bounded ring, the `webview_bind` callback
  (enqueue + `webview_return`, exception barrier) and the writer thread.
  No platform conditional, no environment read, no `pweb.rpc.*` unit.
- [x] `src/webview/pweb.webview.host.pas` — the ONE `{$ifdef PWEB_DEV}` seam:
  the proc type, the `DevViewReady` option field, and the guarded call between
  `binding.Bind` and `webview_navigate`.
- [x] `src/webview/pweb.webview.devhost.pas` — configure, install and shut the
  channel down; the unit header gains the paragraph that says what the channel
  is and what it can never be.
- [x] `tools/pweb/pweb.cli.dev.pas` — `DevHostSink` parses the acknowledgement
  on `pcsStdOut` only, with the comment that says which attack that closes.
- [x] `test/webview/pweb.test.devconsole.pas` — the headless decision corpus:
  every level, the method-name rule, truncation, the sanitiser, a bad level,
  invalid base64, an over-long batch, ring overflow and the dropped notice,
  and the position-extraction rule against BOTH engines' `Error.stack` shapes.
  Each case written as one line to `build/cap7f/dev-console.txt` for the
  four-target byte comparison.
- [x] `test/core/pwebtests.pas` — register the case; add `-Fusrc/webview` /
  `-Futest/webview` to the suite's search path if not already present.
- [x] `test/cap14b/run_cap14b_gates.ps1` — the four-target gate over a REAL
  `pweb dev` session on a REAL generated **Pas2JS** project and, where the node
  toolchain resolves, a REAL generated **React** project: the five levels, the
  uncaught throw and the unhandled rejection with position, the 10 000-line
  burst bounded and said, survival across a generation switch, the forged
  acknowledgement, the listener sample, and the CSP read from both binaries.
  Writes `build/cap14b/cli-<target>.json`.
- [x] `test/cap14b/check_cap14b_contracts.ps1` — checkout-only cross-checks:
  every CAP-14B addition to `pweb.webview.host.pas` is inside a `PWEB_DEV`
  conditional; the console unit's `uses` names no rpc, policy, scheduler or
  bridge unit; the bounds table agrees with `docs/dev-contract.md`; the level
  vocabulary is equal in unit, shim, gate and contract; and the release host
  built from the pre-shard sources and from these is **byte-identical**.
- [x] `test/cap10c2/{check_cap10c2_contracts,build_cap10c2}.ps1`,
  `build_cap10c2.sh` and the `test/cap10c3` twins — extend the dev-free gate:
  the console unit absent from the release unit set and present in the dev one,
  and `__pweb_dev_console` absent from the release binary's bytes.
- [x] `test/cap10a/check_dev_trust.ps1` — sweep the new unit for a transport
  origin and a transport call, exactly as the dev host is swept.
- [x] `.github/actions/cap-14b-…/action.yml`, `.github/workflows/platform-leg.yml`,
  `test/cap11a/{step-applicability,post-migration-amendments}.tsv`,
  `collection-paths.json` — the declared amendment, recording
  `ci_sequence_digest` 203 → 204 with its old and new values.
- [x] `test/cap7f/{emit_evidence.ps1,emit_evidence.sh,check_cap7f_aggregate.ps1,check_cap7f_selftest.ps1,check_schema_agreement.ps1}`
  — the new rows, the equality set, the absolute pins, and one perturbation
  proving a divergence is caught.
- [x] `docs/dev-contract.md` — a section for the console surface (mechanism,
  line shapes, levels, bounds, what it cannot reach) and the §11 amendment: the
  loop injects no JavaScript **to switch a generation**, and the dev host
  injects exactly one dev-only script that never reaches a release.
- [x] `deferred-work.md`, `test/backlog/dispositions.tsv`, `docs/backlog.md` —
  the shard's findings, each with a verdict.
- [x] `_bmad-output/implementation-artifacts/cap14b-final-artifact.md` — the
  shard record: the measured mechanism table, the dev-only proof, the bounds
  and their measurements, the regressions and the freeze.

**Acceptance Criteria:**
- Given a generated project under `pweb dev`, when its frontend calls
  `console.log/info/warn/error/debug`, then five lines reach the supervisor's
  output with their level preserved and `console_levels_seen` records all five.
- Given the same session, when the page throws uncaught and rejects a promise
  without a handler, then both arrive as typed lines carrying
  `source:line:col`, and `console_error_position = true` on four targets.
- Given a page that emits 10 000 lines in one loop, when the loop runs, then
  the supervisor receives a bounded number of lines and one line saying how
  many were dropped, the host pid is unchanged, the dev loop keeps publishing,
  and `console_bound_enforced = true`.
- Given a page that logs a string of the acknowledgement's shape, when the CLI
  reads it, then the generation counter does not move and no generation is
  removed.
- Given a generation switch, when the new document loads, then console output
  continues with no native re-install.
- Given a release build, when its unit directory is listed and its bytes are
  scanned, then the console unit and `__pweb_dev_console` are absent
  (`release_console_channel = absent`), and the binary is byte-identical to one
  built from the pre-shard sources.
- Given both binaries, when `PWEB_NATIVE_CSP` is extracted from each, then they
  are equal and `dev_csp_equals_release = true`.
- Given a whole dev session, when the membership-scoped sampler runs, then it
  saw at least one member and counted zero listeners.
- Given the production corpora — the CAP-6 gates, the CAP-7F aggregate, the
  CAP-10C2/C3 gates and the CAP-14A gates — when each re-runs, then every
  existing digest is unmoved.

## Design Notes

**The mechanism, measured before it was chosen.** Spikes ran on the ratified
Linux baseline (webkit2gtk-4.1 2.52.6, xvfb) against a real same-origin
custom-scheme page under `default-src 'self'; script-src 'self'`.

- A **document-start user script runs** while the page's own inline `<script>`
  is refused (`CONSOLE SECURITY ERROR Refused to execute a script…`). `onerror`
  on a same-origin script gives the real position
  (`spk://app/assets/app.js:3:30`); the same throw from a *user script* is
  sanitised to `Script error.` at `:0:0`, which is why the shim reports the
  page's positions and never its own.
- **WebKitGTK's `enable-write-console-messages-to-stdout` works** —
  `…:1:12: CONSOLE LOG …`, LOG/INFO/WARN/ERROR/DEBUG distinguished, positions
  on console calls and uncaught throws. REJECTED on four measured grounds: **no
  position for an unhandled rejection**; written by the WebKit **web process**,
  so its lines interleave with the host's out of order; **unbounded** — 10 000
  of 10 000 burst lines reached stdout from a page loop that took **59 ms**,
  ~170 000 lines/second; and it lands on **stdout**, where a page writing
  `x: generation 999 loaded` would advance the CLI's generation counter.
- **WebKitGTK's `console-message-sent`** is unreachable from a UI process:
  `WebKitConsoleMessage` comes only from `webkit-web-extension.h`, so it means
  shipping a second `.so` into the dev layout, loading it into the WebKit web
  process and inventing an IPC to carry lines back.
- **WebView2's DevTools protocol** delivers `Runtime.consoleAPICalled` arguments
  as `RemoteObject` previews, so the native side would have to interpret message
  content; and the pinned `ICoreWebView2` vtables live in a **release-linked**
  unit, so a dev path would either grow it or duplicate exact-slot-order
  declarations CAP-4W froze. Its logging switches are reached only through
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`, an environment variable.
- **WKWebView has no public console API**, and `webview_init` IS the
  `WKUserScript` route (upstream's Cocoa `add_user_script_impl`).

So **Linux need not depend on a shim and Windows effectively must**, and the
ratified answer is one mechanism on four targets: one line shape, one bound,
one gate, one thing to break.

**The wire, and why the native side runs no parser.** `webview_bind` hands the
callback the params array as text. The shim sends exactly one argument: base64
of a batch, records separated by LF, fields by U+001F —
`level ␟ method ␟ origin ␟ text`. The native side takes the bytes between the
first and last quote, base64-decodes (invalid ⇒ the whole batch is dropped and
counted), splits, looks the level up in a fixed seven-entry table (`log info
warn error debug uncaught rejection`; anything else is dropped and counted) and
replaces every byte below 0x20 and 0x7F. Base64 was chosen over a JSON decode
precisely so that no general parser ever meets page bytes and no crafted escape
can produce a second line.

**Position extraction is engine-divergent, and that was measured.** WebKit's
`Error.stack` first line is a bare frame — `@spk://app/assets/app.js:4:50` —
while V8's first line is `Name: message`. The shim therefore takes the first
stack line that ends in `:<digits>:<digits>` and none otherwise; the headless
corpus pins both shapes.

**Why stderr, and why one `FileWrite`.** The console channel carries bytes a
page authored, so it must not share the stream the CLI's one protocol is read
from — hence stderr, and hence `DevHostSink` parsing the acknowledgement on
`pcsStdOut` only. Two independent barriers, because either alone is one edit
from being lost. Lines are built whole, kept under `PWEB_CLI_RUN_LINE_MAX`, and
written with a single `FileWrite(StdErrorHandle, …)` rather than `WriteLn`:
FPC's text layer is not thread-safe and the poller already writes to stderr, and
a single write below `PIPE_BUF` is the platform's own atomicity.

**Why the GUI thread never writes.** Upstream already dispatches every bound
message onto the GUI thread, and a page can produce 170 000 of them a second. A
callback that wrote to a pipe would block the GUI loop on backpressure — the
literal "a flood stalls the dev loop". It enqueues into a fixed ring and
returns; overflow drops. It always calls `webview_return`, because upstream's
init script keeps a promise per call and never returning leaks it.

## Verification

**Commands:**
- `pwsh -File test/cap10c2/build_cap10c2.ps1` — expected: the release and dev
  unit sets built; the console unit in `dev-units` and absent from
  `release-units`.
- `pwsh -File test/cap10c2/check_cap10c2_contracts.ps1` — expected: PASS with
  the console unit and marker in the extended dev-free measurements.
- `build/test/pwebtests.exe /noenter` — expected: the new `Dev console` case
  green and `build/cap7f/dev-console.txt` written.
- `pwsh -File test/cap14b/check_cap14b_contracts.ps1` — expected: every host
  addition inside a `PWEB_DEV` conditional, the release binary byte-identical to
  the pre-shard build, one level vocabulary in four places.
- `pwsh -File test/cap14b/run_cap14b_gates.ps1` — expected: five levels, both
  error kinds with position, the bounded burst, the generation switch, the
  forged acknowledgement, zero listeners.
- `pwsh -File test/cap6/run_cap6_gates.ps1`, `test/cap14a/run_cap14a_gates.ps1`,
  `test/cap10c2/run_cap10c2_gates.ps1`, `test/cap10c3/run_cap10c3_gates.ps1` —
  expected: unchanged ALL PASS, every digest unmoved.
- `pwsh -File test/cap7f/check_schema_agreement.ps1` — expected: five lists,
  zero asymmetry.
- `pwsh -File test/cap11a/check_migration_map.ps1` and `check_ci_sequence.ps1` —
  expected: the added step declared, its body digest matching, 204 steps.
- `pwsh -File test/backlog/check_backlog.ps1` — expected: every ledger entry
  disposed.
- Under **WSL**: `bash test/cap10c2/build_cap10c2.sh`, the pwebtests suite, and
  `xvfb-run pwsh test/cap14b/run_cap14b_gates.ps1`, before any push.

**Manual checks:**
- `git diff --stat 123e347 -- src/security src/platform src/rpc src/assets tools/templates examples` —
  expected: empty. No CSP change, no adapter change, no template change.
