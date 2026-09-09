# CAP-14B — a console surface for the development host

**Spec:** `spec-phase-14-cap14b-dev-console-surface.md`
**Baseline:** `123e3478add9a3aabcad698159481ff7b9caf4e0`
**Branch:** `phase/cap-14/b-dev-console-surface`

The defect, recorded as TODO.txt #6 by an external reviewer: a frontend under
`pweb dev` had no voice. Every `console.log`, `console.warn` and
`console.error`, every uncaught throw and every unhandled rejection died
inside the engine while the supervisor forwarded the host's own lines and
nothing else — so a developer probed blind and paid iterations for what one
line would have said.

---

## MECHANISMS

**Spiked before ratified.** Three spikes ran on the ratified Linux baseline
(webkit2gtk-4.1 **2.52.6**, GTK 3, `xvfb-run`) against a real same-origin
custom-scheme page served under `default-src 'self'; script-src 'self'`.

| candidate | measured | verdict |
|---|---|---|
| **document-start user script** (`webview_init`) | RUNS while the page's own inline `<script>` is refused (`CONSOLE SECURITY ERROR Refused to execute a script…`). `window.onerror` on a same-origin script gives the real `spk://app/assets/app.js:3:30`; the same throw from a *user script* is sanitised to `Script error.` at `:0:0` | **CHOSEN**, on four targets |
| WebKitGTK `enable-write-console-messages-to-stdout` | works — `…:1:12: CONSOLE LOG …`, LOG/INFO/WARN/ERROR/DEBUG distinguished, positions on console calls and uncaught throws | **refused**, four grounds below |
| WebKitGTK `console-message-sent` | `WebKitConsoleMessage` is included only from `webkit-web-extension.h` | **refused** — a web-process extension library, loaded into the WebKit web process, plus an IPC to carry lines back |
| WebView2 DevTools protocol | `Runtime.consoleAPICalled` hands arguments as `RemoteObject` previews; the pinned `ICoreWebView2` vtables live in `src/platform/windows/pweb.platform.webview2.pas`, a **release-linked** unit | **refused** — it would make the native side interpret message content, and would either grow a release unit or duplicate exact-slot-order declarations CAP-4W froze |
| WebView2 browser logging switches | reachable only through `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` | **refused** — an environment variable; the supervisor injects none and the dev units are swept for reads |
| WKWebView | no public console API at all; `webview_init` **is** the `WKUserScript` route (upstream's Cocoa `add_user_script_impl`) | the shim is the only route |

The four measured grounds against the WebKitGTK stdout flag, each decisive on
its own:

1. **No position for an unhandled rejection** — `CONSOLE JS ERROR Unhandled
   Promise Rejection: Error: …` with nothing before it.
2. Written by the WebKit **web process**, so its lines interleave with the
   host's out of order (measured: `SHIM|` and `CONSOLE` lines alternate
   non-deterministically).
3. **Unbounded** — 10 000 of 10 000 burst lines reached stdout, from a page
   loop that took **59 ms**. About 170 000 lines a second.
4. It lands on **stdout**, which is the stream `PWebCliDevParseAck` reads the
   development loop's one protocol from.

### The answer to "does Windows or Linux depend on a shim at all?"

**Linux does not have to** — the stdout flag exists and was measured working.
**Windows effectively does** — CDP is the only native path and is refused on
three independent grounds. macOS has nothing else at all. The shim is chosen
on all four **by ratification, not by necessity**, and the reason is one line
shape, one bound, one gate and one thing to break.

### What was built

```
page (dev only)  console.*  window.onerror  unhandledrejection
                     |  render, bound, batch (page-side)
                     v  window.__pweb_dev_console(base64 of a batch)
native callback  decode -> non-blocking push onto a fixed ring -> return
                     v
writer thread    one whole line, one FileWrite to StdErrorHandle
                     v
CAP-10C0 engine  forwarded like any host line, prefixed `app: `
```

`src/webview/pweb.webview.devconsole.pas` is the whole of it. Eight levels and
no others — `log,info,warn,error,debug,uncaught,rejection,dropped` — with
every function-valued property of `console` discovered rather than listed, and
a method whose name is not its level named in the text.

**One binding call carries base64 of a batch**, records separated by LF and
fields by U+001F. The native side takes the bytes between the first and last
quote, base64-decodes (invalid ⇒ the whole batch is dropped and counted),
splits, looks the level up in a fixed table, and replaces every byte below
`$20`. Base64 was chosen over a JSON decode precisely so that **no general
parser ever meets page bytes**. The one digit it reads is a `dropped` count;
the `(page)`/`(host)` attribution beside it is written natively.

---

## DEV-ONLY PROOF

The release host is **byte-untouched**, and that is measured three ways rather
than asserted:

| measurement | result |
|---|---|
| every CAP-14B addition to `pweb.webview.host.pas` sits inside a `PWEB_DEV` conditional — a positional line scan, nesting-aware, **on every leg with no toolchain at all** | `console_host_markers_outside_dev = 0` (absolute pin) |
| the same file compiled twice — once as it is, once with **all 26** `PWEB_DEV` lines physically removed — and the emitted objects compared | `release_host_object_unchanged = true` on windows-x86_64 (`c55492c2…`) and on linux-x86_64 (`f157935b…`) |
| a real `pweb build` release binary scanned for `__pweb_dev_console`, for the shim's own marker, and for `--pweb-dev-root=` | `release_console_channel = absent`, `release_dev_argument = absent`; the development binary carries both |

The object comparison was **corroborated independently** against the shard's
baseline commit: `git show 123e3478:src/webview/pweb.webview.host.pas`
compiled in place produced the identical `c55492c2…`. The shipped gate uses
the strip-based form instead, because it needs no git history and therefore
answers the same on a shallow checkout as on a full one.

**Which of the two is the four-target invariant, and why.** The source scan
is, and the object comparison corroborates it. This leg compiles a unit whose
platform body differs per target and needs that target's toolchain to be
complete; where it is not, the row reads `not_applicable` rather than turning
the leg red for a claim the compiler could not make. That is the CAP-14A
lesson from hosted run 34316904346 applied before it could cost a second run.

The CAP-10C2 dev-free gate is **extended rather than duplicated**: the console
unit joins the release-unit listing, the dev-unit listing, the byte scan (two
markers now, one per development-only unit), the platform-conditional and
environment-read sweep, and the transport sweep. `test/cap10c3` carries the
Pas2JS twins. `test/cap10a/check_dev_trust.ps1` sweeps the new unit for the
service path it may never name.

```
release_dev_unit_absent           true      dev_host_unit_present       true
release_console_unit_absent       true      dev_console_unit_present    true
dev_marker_in_release_binary      false     dev_marker_in_dev_binary    true
console_marker_in_release_binary  false     console_marker_in_dev_binary true
```

`console_uses_count = 7` and the unit list is **closed**: `sysutils`,
`mormot.core.base`, `mormot.core.os`, `mormot.core.unicode`,
`mormot.core.text`, `mormot.core.buffers`, `pweb.lib.webview`. It names no rpc
unit, no scheduler, no bridge and no capability policy, and the whole file is
swept for each of them by name.

---

## BOUNDS

**Sized from a measurement, not from a feeling.** A page loop issuing 10 000
`console.log` calls completed in **59 ms** — about 170 000 lines a second.
Nothing downstream survives that unbounded, so the channel is bounded three
times, and each bound says what it dropped.

| bound | value | what it covers |
|---|---|---|
| `PWEB_DEV_CONSOLE_MAX_TEXT` | 1024 | one record's rendered text, truncated on a UTF-8 boundary |
| `PWEB_DEV_CONSOLE_MAX_ORIGIN` / `_MAX_METHOD` | 512 / 32 | the position and the method name |
| `PWEB_DEV_CONSOLE_MAX_BATCH` / `_FLUSH_MS` | 32 / 50 | the page-side **rate** bound |
| `PWEB_DEV_CONSOLE_MAX_PENDING` | 256 | records the page holds before dropping and counting |
| `PWEB_DEV_CONSOLE_MAX_PAYLOAD` | 98304 | base64 bytes per call, refused **before** a decode is attempted |
| `PWEB_DEV_CONSOLE_MAX_BATCHES` | 64 | the host ring — the **authoritative** bound |
| `PWEB_DEV_CONSOLE_LINE_MAX` | 3072 | one emitted line, 1024 bytes under the supervisor's `PWEB_CLI_RUN_LINE_MAX` of 4096 |

**Which bound actually fires, measured — and it differs per machine.** A page
loop is synchronous and the shim's flush is a timer, so the *page* queue is
what closes on an ordinary runaway, deterministically: 10 000 offered →
**256 emitted** and one `console dropped: 9744 (page)` line, identically on
windows-x86_64 and linux-x86_64. That is an absolute pin.

The *host* ring is reached only by a caller that skips the shim, which the
gate does deliberately with 4 000 direct calls carrying 8 records each — and
whether it overflows is a **race** between the writer thread's drain and the
GUI thread's dispatches:

| target | direct records offered | emitted | dropped at the ring |
|---|---:|---:|---:|
| windows-x86_64 | 32 000 | ~1 300 | ~30 700 |
| linux-x86_64 | 32 000 | 15 928 | 24 |

So the live leg requires only what a race cannot fake — the direct calls
produce lines, do not stall the loop and do not restart the host — and the
ring is pinned where it is **deterministic**: the headless `RingBound` case
drives the real ring and the real writer path past capacity and asserts the
exact emitted count and the single notice.

**The GUI thread never writes to a pipe.** Upstream dispatches every bound
message onto the GUI thread, so a callback that wrote to stderr would block
the GUI loop on backpressure — the literal "a flood stalls the dev loop". The
callback decodes, enqueues non-blocking and returns; one writer thread emits.
Lines are written whole with a single `FileWrite(THandle(StdErrorHandle), …)`
and never with `WriteLn`, because FPC's text layer is not thread-safe and the
generation poller already writes there.

---

## ADVERSARIAL

| question | answer, and how it is measured |
|---|---|
| **Can the channel reach native services?** | No. The unit list is closed and the whole file is swept for `pweb.rpc`, `IInvocationBridge`, `IInvocationScheduler`, `ICapabilityPolicy`, `pweb.capabilities`, `pweb.assets`, `webview_navigate` and `webview_eval`. It carries no method, no arguments and no result; the promise every bound call creates is resolved with a constant. |
| **Can a page message change supervisor behaviour?** | No, and this was a **real latent defect** the shard closed. `PWebCliDevParseAck` matches the acknowledgement shape *anywhere* in a line and `DevHostSink` ran it over **both** streams, so a page logging `x: generation 999 loaded` would have advanced the CLI's counter and driven the bounded cleanup that deletes live generations. Two independent barriers now: the channel is **stderr**, and the acknowledgement is parsed on **stdout** only. Measured: the probe logs exactly that string, it prints as ordinary text, `console_generations_after_forgery = 1`. |
| **Can one record become two lines?** | No, and structurally rather than cosmetically. LF frames records, so an embedded one splits the record and the tail — carrying no separators — is refused; every remaining byte below `$20` and `$7F` is replaced natively. Pinned by six headless rows and by "no emitted line carries a line break, whatever the page put in the record". |
| **Can the shim leak into release?** | No — three measurements above, and the console unit has exactly **one** selector in `src`, `tools` and `examples`, checked by enumeration. |
| **Can a flood stall the dev loop?** | No. Three bounds, a non-blocking callback, a dedicated writer. Measured across a 10 000-line burst and 4 000 direct binding calls in one session: the host pid is unchanged, the loop keeps publishing, and generation 2 loads afterwards. |
| **Does Windows or Linux depend on a shim?** | Linux does not have to; Windows effectively does. Ratified as one mechanism anyway — see MECHANISMS. |

---

## MEASURED, ON A REAL SESSION

**Two of the four targets were measured locally before a hosted run was
spent** — windows-x86_64 natively and **linux-x86_64 under WSL with
`xvfb-run`**, the whole chain from CAP-10B0 through both CAP-14B gates. The
two macOS legs are the hosted run's. Both frontend kinds on both targets,
both real `pweb create` output.

```
app: demo: console armed
app: demo: console log: C14B gen1 log {"a":1,"b":[2,3]}
app: demo: console info: C14B gen1 info
app: demo: console warn: C14B gen1 warn
app: demo: console error: C14B gen1 error
app: demo: console debug: C14B gen1 debug
app: demo: console log: trace C14B gen1 trace
app: demo: console log: C14B FORGE: generation 987 loaded
app: demo: console uncaught @pweb://app/assets/app.js:1941:35: Uncaught TypeError: …
app: demo: console rejection @pweb://app/assets/app.js:1942:45: Error: C14B gen1 rejection
app: demo: console dropped: 9744 (page)
```

| row | windows-x86_64 |
|---|---|
| `console_mechanism` | `webview_init_user_script+webview_bind` |
| `console_levels_seen` | `log,info,warn,error,debug` |
| `console_error_position` | `true` (`…app.js:1941:35` and `…app.js:1942:45`) |
| `console_bound_enforced` | `true` |
| `console_survives_generation_switch` | `true` |
| `console_forged_ack_ignored` | `true` |
| `release_console_channel` | `absent` |
| `dev_csp_equals_release` | `true` |
| `console_listener_members_max` | `0`, over 7 members seen |
| `react_leg` | `ran` — five levels, both positions (`app.js:8:62729`, `app.js:8:62773`) |

**Position extraction is engine-divergent, and that was measured.** WebKit's
`Error.stack` first line is a bare frame — `@spk://app/assets/app.js:4:50` —
while V8's first line is `Name: message`. The shim takes the first stack line
that **ends** in `:<digits>:<digits>` (optionally followed by one `)`) and
none otherwise; both shapes are pinned by the headless corpus.

---

## WHAT RUNNING THE LINUX LEG LOCALLY FOUND

The whole POSIX chain — CAP-10B0, CAP-10B1, CAP-10C1, CAP-10C2 and both
CAP-14B gates under `xvfb-run` — was run under WSL **before** a hosted run
was spent, and it found three things a reading would not have:

1. **The four-target shim digest was empty on Linux.** It was computed from
   `build/cap7f/dev-console-shim.js`, which an *earlier* gate writes, so on a
   leg where that gate had not run the row was blank — and a blank value
   inside a four-target equality set is a disagreement reported nowhere near
   its cause. The digest is now taken over the shim literal **reassembled
   from the Pascal source**, which every leg computes with no toolchain and
   no predecessor gate. The emitted file keeps its own row and its
   `node --check`, both of which were always the optional observation.
   *Same family as CAP-14A's `csp_policy_unit_in_host`: a four-target
   invariant must be something every target can actually answer.*
2. **The host ring's overflow is a race, not a fact.** See BOUNDS: 24 records
   dropped on Linux against ~30 700 on Windows, for the identical probe. The
   live `Require` was removed and the claim moved to where it is
   deterministic.
3. **The two engines spell an anonymous stack frame differently.** V8 writes
   `    at url:1:2`, WebKit writes `@url:1:2` — so the first Linux record read
   `console rejection @@pweb://app/assets/app.js:1942:54`, with a doubled
   `@` because the native side writes the one that introduces a position.
   `trimFrame` now drops a leading `@` as well as a leading `at `, and the
   origin field holds a bare `url:line:col` on every engine.

**And one thing about the route itself**, recorded for the next shard that
takes it: the POSIX chain cannot run from a Windows checkout mounted at
`/mnt/c`. `build_cap10c2.sh` reaches its scaffolding step and fails with
`pweb: create failed: mode: .gitattributes`, because the scaffold engine's
atomic-creation transaction checks file modes and DrvFs reports modes it
refuses. From a copy of the tree inside the WSL filesystem the same script
exits 0. Second instance of the ledger's `10E-4` family — copy, do not debug.

---

## THE ONE DEFECT THIS SHARD GAVE ITSELF, AND CLOSED

The channel's first real dev session printed `console armed` and then **not
one console line**. The cause: the shim is built by concatenating Pascal
literals, which carry **no escapes**, so a character class written with
doubled backslashes reached the engine as a range running from the letter `u`
to a backslash — ends the wrong way round, a `SyntaxError` thrown while the
shim was being **parsed**. Nothing installed, nothing threw anywhere the host
could see, and the symptom was indistinguishable from "the page logged
nothing" — the very defect this shard exists to close, wearing a different
hat.

Closed three ways, because one fix would have been a fix for one escape
rather than for the class:

- the shim contains **no backslash at all** — `hasPos` and `trimFrame` are
  hand-written scans that replace two regular expressions, and the rule is
  enforced by both the contract gate and the headless suite;
- `PWebDevConsoleInstall` writes `console armed`, or
  `console unavailable: bind=<n> init=<n>`, so "the console said nothing" can
  be told from "the console is not there";
- the emitted shim is written to `build/cap7f/dev-console-shim.js`, digested
  as `console_shim_sha256` and compared on four targets, and held to
  `node --check` by the contract gate wherever node resolves.

---

## REGRESSIONS

| gate | result |
|---|---|
| `test/core/pwebtests` | **0 / 2 703** assertions failed; the new `Dev console` case is 67 of them |
| `test/cap6/run_cap6_gates.ps1` | ALL PASS, deterministic rebuild `08E04E1E177D0EE6626595A91A403824E27745937AF6228D151FBB2BB945A4FE` **unmoved** |
| `test/cap6/check_cap6_nonetwork.ps1` | PASS |
| `test/cap14a/check_cap14a_contracts.ps1` + `run_cap14a_gates.ps1` | PASS; `bundler_digest`, `csp_policy_digest`, `html_policy_digest` all unmoved |
| `test/cap10c2/*` and `test/cap10c3/*` (build, contracts, gates) | PASS on Windows with four new facts each; `build_cap10c2.sh` also PASS on Linux, with the console unit in `dev-units` and absent from `release-units` |
| `test/cap10a/check_dev_trust.ps1` | PASS |
| `test/cap7f/check_schema_agreement.ps1` | PASS — **812** fields, three lists, zero asymmetry |
| `test/cap11a/check_migration_map.ps1` / `check_ci_structure.ps1` | PASS — 204 steps, 13 declared added-step amendments |
| `test/backlog/check_backlog.ps1` + `check_backlog_selftest.ps1` | PASS; 14/14 negative legs refused |
| `test/cap10c3/check_cap10c_ledger.ps1` | PASS — 54 entries, 0 orphans |

The console unit is deliberately **not** in `test/cap6/check_cap6_nonetwork.ps1`'s
swept set: that sweep covers what the *release host* links, and this unit
never reaches one. It is swept by CAP-10C2 §5/§6 and by CAP-10A's
development-trust gate instead, which are the sweeps that cover the
development surface.

`test/cap7f/check_cap7f_selftest.ps1` gains eight negative legs — one compared
digest and seven absolute pins — and its floor moves **240 → 248**. It skips
on a dev host because it perturbs a complete four-target evidence set.

### CI

One step added to the one platform-leg sequence, declared as an amendment:

```
CAP-14B development console surface gates (C0, R1, D1-D6, B1-B2) + evidence
  windows,linux,macos-x64,macos-arm64   unconditional   ordinal 181
  ci_sequence_digest 412b21b2…(203)  ->  e0d2e3f2…(204)
  action body digest 44e778d238e11175
```

Both scripts run and the step fails afterwards rather than short-circuiting —
the CAP-14A rule, kept for the CAP-14A reason. The Linux branch wraps the gate
in `xvfb-run`, because **every** console line it reads comes out of a real
development host with a real window.

---

## FREEZE

Held, and measured rather than promised:

- **no release host change** — the emitted object is byte-identical with and
  without the `PWEB_DEV` regions;
- **no CSP or origin change** — `PWEB_NATIVE_CSP` is byte-identical in both
  binaries and unchanged from the baseline; `pweb://app` is still the only
  destination and the dev host still calls no `webview_navigate`;
- **no schema change** — no `pweb.json`, manifest, template or scaffold moved;
  `git diff --stat` over `src/security`, `src/platform`, `src/rpc`,
  `src/assets`, `tools/templates` and `examples` is empty;
- **no new capability, no new RPC method, no new CLI option, no environment
  variable**;
- **no production transport** — `transport_hits = 0` over the new unit and the
  dev host, and the membership-scoped sampler counted **0** listeners over 7
  members of a live session.

The one thing that moved outside `src/webview` is `tools/pweb/pweb.cli.dev.pas`:
`DevHostSink` now parses the acknowledgement on `pcsStdOut` only. That is a
hardening of an existing latent defect, not a change to the ratified
acknowledgement line, whose shape is untouched.

---

## LEDGER

Ten entries, each with a verdict in `test/backlog/dispositions.tsv`.
**CLOSED:** `14B-1` the shim's Pascal-escape trap, `14B-2` the forgeable
acknowledgement, `14B-7` the four-target digest a leg could not compute.
**ACCEPTED:** `14B-3` which bound actually fires, `14B-4` the staged-SDK
integrity interaction, `14B-6` the dispatch cost that is upstream's shape,
`14B-8` the host ring's overflow as a race, `14B-9` the two engines' frame
spellings, `14B-10` why the POSIX chain needs a tree inside WSL.
**ROADMAP:** `14B-5` a Worker's console, owned by whichever shard relaxes
`worker-src 'none'`.

---

## VERDICT

**CAP-14B PASS — DEVELOPMENT CONSOLE SURFACE FROZEN**

The verdict stands on **two targets measured end to end locally** —
windows-x86_64 natively and linux-x86_64 under WSL with `xvfb-run`, each
running a real `pweb dev` session over a real generated Pas2JS project and a
real generated React one — plus every checkout-only gate. It is completed by
the hosted run's **macos-x86_64 and macos-arm64** legs, which are the two the
dev host cannot be built for here.
