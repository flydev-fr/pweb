# CAP-11 — phase closure: the full matrix, and a watcher that reports and nothing else

**CAP-11 is CLOSED.** Two shards. CAP-11A made the four platform jobs one step
sequence and measured that premise from the run itself. CAP-11B added the second
half of the SPEC's acceptance — a separate watcher that compiles the binding
against upstream head and reports an API diff **without changing the pinned
version** — and closes the phase.

> **The verdict at the bottom of this file is written by the commit that carries
> the closure run's id, and not before.** `test/cap11b/check_cap11_ledger.ps1`
> refuses a document that declares `CAP-11B PASS` while leaving a hosted run
> `pending`, so the claim and its evidence land together or not at all.

The SPEC states CAP-11 as one intent and one success sentence:

> **intent:** The Phase 1 CI grows into the full target matrix, and upstream `webview/webview` drift is caught before it reaches production. This phase *extends* CI; it does not introduce it.

## 1. THE HOSTED RUNS

| shard | commit | run | result |
|---|---|---|---|
| CAP-11A | `d63d7e3` | 34022414932 | six jobs green — the first run in which `.github/workflows/ci.yml` *is* the caller |
| CAP-11B | `e0bc6ba` | 34127608923 | six jobs green — 200 steps, one sequence, and the watcher's contract in the matrix |

**What the closure run measured about itself**, verbatim from the aggregate's
own log:

```
[cap11a] run 34127608923 reports 6 job(s)
[cap11a] windows      job=101774164065 conclusion=success authored_steps=200
[cap11a] linux        job=101774165565 conclusion=success authored_steps=200
[cap11a] macos-x64    job=101774166132 conclusion=success authored_steps=200
[cap11a] macos-arm64  job=101774195445 conclusion=success authored_steps=200
[cap11a] four identical sequences of 200 steps, digest 8b3c15bd…60243a05
[cap11a] the sequence run is the sequence declared (8b3c15bd…60243a05)
[cap11a] windows runs all 125 of its legacy steps, in order
[CAP-7F] divergence sweep PASS - 212 platform conditionals, all inside the ratified allowlist
[CAP-7F] selftest PASS - 241 aggregator refusals + 2 divergence refusals
[CAP-7F] aggregate PASS - platform-matrix.json written
```

and the CAP-11B rows the four targets agreed on, read back from
`cap7f-platform-matrix`:

| row | value |
|---|---|
| `watcher_available` | `true` |
| `watcher_permissions` | `contents_read` |
| `watcher_in_matrix` | `false` |
| `watcher_verdict_vocabulary_digest` | `021d2f5c…6b16a56b` |
| `watcher_pinned_path_byte_identical` | `true` |
| `locks_unchanged_after_watch` | `true` |
| `watcher_seeded_verdicts` | `abi_break,build_failed,compatible_additive,inconclusive,patch_drift,unchanged` |
| `mormot_watcher` | `ledgered` |
| `cap11_ledger_entries` / `cap11_ledger_orphans` | `32` / `0` |
| `sdk_own_license` | **`declared`** |

CAP-11A's closure run measured its own premise: four identical sequences of 196
steps under digest `3b28ac8d…f4f5fe3a`, that digest equal to the digest of the
sequence declared, and every leg running all of its legacy steps in order.
CAP-11B's sequence is 200 steps — the same list plus four CAP-11B gate steps,
added once and inherited by all four targets, which is exactly what the CAP-11A
structure was built to make possible.

## 2. WHAT CAP-11B ADDED

`.github/workflows/upstream-watch.yml` is a standalone scheduled workflow that
answers one question per target and acts on nothing. It never re-pins, never
regenerates the binding into the tree, never commits, never fails the matrix,
and its report is never an input to a build. `docs/watcher-contract.md` is the
contract; the summary is:

| | |
|---|---|
| triggers | `schedule` (weekly) + `workflow_dispatch` + `push` filtered to the watcher's own sources |
| permissions | `contents: read`, workflow-level, no job grant, no secret, no token beyond the default |
| targets | Windows x64, Linux x64, macOS x86_64, macOS arm64 |
| output | one artifact per target (JSON + Markdown), retention 90 (records), plus a job summary |
| conclusion | `success` whenever the watcher ran — the verdict lives inside the report |
| verdicts | `unchanged \| compatible_additive \| patch_drift \| abi_break \| build_failed \| inconclusive` |

**The diff is mechanical.** `test/cap11b/extract_api.ps1` parses the six public
C headers `webview.lock` names into a canonical model — functions, callback
typedefs, enums with resolved values, structs, `void*` typedefs, the
`WEBVIEW_VERSION_*` macros — and a declaration it cannot read is a typed
refusal, never a silent pass. Measured on the pin: **17 functions, 2 callbacks,
3 enums, 2 structs, 1 typedef, 6 macros**, which is exactly the committed
binding and exactly the "17 entry points" `docs/webview-upstream-semantics.md`
scopes.

**The projector is calibrated on every run, and that is the load-bearing part.**
ChetCLI is a Windows-only Delphi tool at a hard-coded path that no runner has,
so `test/cap11b/project_binding.ps1` reproduces its mapping for the closed set
of constructs these headers use, taking the platform block verbatim from the
committed unit and refusing any unmapped C type. Before anything touches head,
the same projector runs over the **pinned** headers and `signature_pin` is
compiled against the result. If that fails the tool is broken and the verdict is
`inconclusive` — never `abi_break`.

**The first real answer is `unchanged`, and that is a fact about upstream.**
`tools/get-webview.ps1 -Ref HEAD` resolved `webview/webview`'s default branch to
`cbbdee44afff22867de9fd88a9fc8350d9bdd399` (2026-03-09T07:51:25Z) — the commit
`webview.lock` already pins. Which is why the other five verdicts are proved by
seeded input rather than by waiting.

**The watcher ran, hosted, on all four targets: run `34113334581` on commit
`c0354a0`, conclusion `success`** (and run `34107491647` on `3487764` before the
review's fixes, with the same four verdicts). Every leg fetched head, built the
library from it through the ref-parameterised build script, projected and
compiled the pins, checked the exports and published its report:

| target | verdict | platform patch | build | signature_pin | ABI probe | exports | diff |
|---|---|---|---|---|---|---|---|
| windows | `unchanged` | `webview2-custom-scheme.patch` — **clean** | ok | ok | ok | ok | 0/0/0 |
| linux | `unchanged` | none declared — *not_applicable* | ok | ok | ok | ok | 0/0/0 |
| macos-x64 | `unchanged` | none declared — *not_applicable* | ok | ok | ok | ok | 0/0/0 |
| macos-arm64 | `unchanged` | none declared — *not_applicable* | ok | ok | ok | ok | 0/0/0 |

Windows is the row worth reading twice: it is the only target with a declared
platform patch, and the run shows the pinned CAP-4W patch applying **clean** to
head — the `patch` stage exercised for real rather than only by a seed.

### The seeded verdicts (offline, on all four legs)

| case | seed | verdict | what the report has to name |
|---|---|---|---|
| W2 | head == the pin | `unchanged` | an empty diff |
| W3 | one added prototype | `compatible_additive` | `webview_set_icon`, added |
| W4 | one changed signature | `abi_break` | `webview_navigate`; `signature_pin` really fails to compile |
| W5c | **control**: the unedited fixture | `unchanged` | patch outcome `clean` |
| W5a | the patch's context moved | `patch_drift` | outcome `rejected`, with the hunk naming `win32_edge.hh` |
| W5b | the patch's position moved | `patch_drift` | outcome `offset`, with git's own displacement |
| W6 | the library build fails | `build_failed` | the log tail |
| W7 | the fetch is refused | `inconclusive` | the cause, and *not* `unchanged` |
| **W8** | **no seed at all**, ref = the pinned commit | `unchanged` | build `ok`, exports `ok`, ABI probe `ok`, the pinned checkout untouched |

W5c is the case that makes W5a and W5b mean anything, and it exists because the
first version of them did not: CRLF fixtures made both go green on a context
mismatch in a file neither of them touched.

**W8 is the case the adversarial review demanded, and it is not seeded.** Every
other case skips or fakes the build, and both the export comparison and the
paired ABI probe are guarded on `build ok` — so the half of the watcher that
compiles anything against a fetched tree was executed by *no gate*: a broken ref
build would have surfaced only as a `build_failed` verdict on the weekly run,
which the contract defines as legitimate news, on a job that concludes `success`
either way. W8 runs the whole ref path for real on the leg's own target against
the **pinned** commit, where the answer is knowable in advance. It costs one
library build per leg and it is the difference between "the watcher builds" and
"we believe the watcher builds".

## 3. REF PARAMETERISATION / PINNED-PATH IDENTITY

One optional input — `-Ref` / `--ref` — on `tools/get-webview.ps1`,
`build-webview-dll.ps1`, `build-webview-so.sh` and `build-webview-dylib.sh`.
Each also gained `--print-plan`, which resolves every path, flag and assertion
mode, prints them, and exits 0 having touched nothing.

| | pinned (no input) | ref |
|---|---|---|
| source | `deps/webview` | `deps/webview-watch` |
| build / dist | `build/webview-build-cap4w`, `build/cap7l/…`, `build/cap7m/…` | `build/cap11b/…` |
| header checksums | verified | not verified — they pin the *pinned* commit |
| CAP-4W patch | applied by the build script | applied and **typed** by the watcher |
| SONAME / dylib names | asserted | **observed** — a version bump is news, not a build failure |
| engine, deployment target, SDK pin | asserted | asserted |

`test/cap11b/pinned-plan.expected.txt` records the five pinned plans and
`test/cap11b/check_ref_input.ps1` compares them **byte for byte** on every leg,
then re-reads both lock digests. It also checks the mirror — that a *ref* plan
never names a pinned directory — because a script that ignored its input
entirely would pass the byte comparison perfectly.

Adding an input necessarily changes the source of these scripts. What must not
change is what they do when nobody passes one, and that is now a comparison
rather than a claim — verified byte-identical on the Windows host and under WSL,
which also proves the plans are host-independent.

## 4. SUPERSESSIONS ACROSS CAP-11

| what | before | after | why |
|---|---|---|---|
| the step sequence | 196 steps (CAP-11A) | **200** | four CAP-11B gate steps, added once, inherited by four targets |
| `ci_sequence_digest` | `3b28ac8d…f4f5fe3a` | recomputed | the digest is over the declared list, which grew |
| `sdk_own_license` | `undeclared` (absolute pin, CAP-11A) | **`declared`** | `<repo>/LICENSE` became tracked in `864fca7`; §6 |
| `LICENSE_TABLE` | 4 rows | **5** | `LICENSE.pweb.txt`, `swAlways` |
| `sdk_ship_table_digest` | CAP-10D2 value | recomputed | the licence table is inside the ship digest by construction |
| `.github/` largest file | 54,143 B | **55,775 B** (85 % of the 64 KB bound) | four steps on `platform-leg.yml` |
| `docs/index.md` | 12 documents | **13** | `watcher-contract.md` |

Nothing in `webview.lock` or `mormot.lock` moved. `src/`, `sdk/`, `deps/`,
`tools/setup/`, `examples/` and `webview.chet` are byte-untouched.

## 5. THE PHASE LEDGER — 28 ENTRIES, 0 ORPHANS

`test/cap11b/check_cap11_ledger.ps1` keys each entry as `<shard>-<ordinal>` plus
the first eight hex of the SHA-256 of its own `summary` line, so an orphan, a
stray, a count drift and a silent reword are four different failures with four
different messages.

| key | digest | disposition | reason |
|---|---|---|---|
| 11A-1 | 95839d39 | RESOLVED | `ci.yml` is a 15 KB caller over one 200-step sequence; the premise is measured from the run |
| 11A-2 | 7008df19 | RESOLVED | no gate depends on an upload; the collection block is last and its failure is typed INFRASTRUCTURE |
| 11A-3 | 8337ae0c | RESOLVED | the U3 drain reports before it measures; `u3_drain_before_measure` pinned true |
| 11A-4 | 12530023 | RESOLVED | every pinned fetch is three bounded attempts with a row each; no ceiling got longer |
| 11A-5 | e601b7cc | RECORDED-ONLY | the non-report cause is instrumented and its inference is stated; see §7 for its current state |
| 11A-6 | f77c24c0 | RESOLVED | retention, concurrency, per-job timeouts and the 64 KB / 1,600-line bound are gated |
| 11A-7 | 030c5240 | RESOLVED | superseded by 11B-6: `<repo>/LICENSE` is tracked and the SDK ships it |
| 11A-8 | 3cd2c754 | RESOLVED | the schema-agreement gate compares the three hand-maintained lists on every leg |
| 11A-9 | 1db27551 | RECORDED-ONLY | two review defects and their fixes, recorded so the reasoning is not re-derived |
| 11A-10 | 53dc4526 | RECORDED-ONLY | the Int32 job-id cast and three siblings, recorded with their seeded payloads |
| 11A-11 | 2a9178ef | RECORDED-ONLY | the shard's own non-blocking rule applied to itself, twice; recorded |
| 11A-12 | c3d20ce7 | RESOLVED | the drain reports and does not refuse, which is what D1-16 asked for |
| 11A-13 | dd6a17bb | RESOLVED | the fetch helper is bounded across mirrors; nine seeded cases, drift never retried |
| 11A-14 | 71f39aa1 | RECORDED-ONLY | three rejected review findings, recorded so they are not re-litigated; finding (2) came true and §6 is the answer |
| 11A-15 | 3ec2ff77 | RECORDED-ONLY | the non-report reached a fourth driver; instrumented, cause unchanged |
| 11A-16 | 28293caf | RECORDED-ONLY | a separator defect caught under WSL before it was pushed; the lesson holds for CAP-11B, which used WSL the same way |
| 11A-17 | 7f09472b | RESOLVED | CAP-11A closed on run 34022414932 |
| 11A-18 | a9990833 | RECORDED-ONLY | what three twin runs cost, and why the two discarded ones were worth running |
| 11B-1 | 2bf41240 | RESOLVED | the watcher exists, its contract is gated on four legs and `docs/watcher-contract.md` records it |
| 11B-2 | 15baaea8 | RESOLVED | the projector is calibrated on the pinned headers on every run before head is judged |
| 11B-3 | 40fd8675 | RECORDED-ONLY | no issue: `issues: write` cannot coexist with the ratified posture, and the title rule is self-cancelling |
| 11B-4 | cdab7d4d | CAP-12 | the mORMot head watcher does not fit this shape; it needs its own instrument and its own budget |
| 11B-5 | 726b4ebe | RESOLVED | the pinned plan is compared byte for byte with no ref input, on every leg |
| 11B-6 | 0e94ead7 | RESOLVED | D2-8 closes: the owner tracked a licence, the SDK ships it, the pin reads `declared` |
| 11B-7 | 952bf510 | RECORDED-ONLY | upstream head is the pinned commit at closure; a fact about upstream, not about the instrument |
| 11B-8 | 1185f8d8 | RECORDED-ONLY | five defects found by running the shard's own code; each is now gated or commented at its site |
| 11B-9 | 5038a385 | RECORDED-ONLY | the `push` trigger and the measurement that forces it; the trigger set is pinned |
| 11B-10 | 74aab1a5 | RECORDED-ONLY | the dev host's i386 FPC cannot run the compile-based cases; a named refusal, never a skip |
| 11B-11 | 787116f2 | RESOLVED | twelve review defects, every one patched in this commit; §9b names each and what it would have cost |
| 11B-12 | df2373d6 | RECORDED-ONLY | the watcher builds an unreviewed commit and the bound on that is the permissions; branch protection is not in the tree |
| 11B-13 | ee1b0fa6 | RESOLVED | superseded by 11B-15: the sampler types every listener by owner image, so this class names its owner instead of re-running |
| 11B-14 | eb4cb087 | RESOLVED | the shell emitter's reader truncated the one list row at its first comma; an absolute pin caught what equality could not |
| 11B-15 | 3a637757 | RESOLVED | 11B-13 answered: every sampled listener typed by owner image, must-PASS is host-owned = 0 |
| 11B-16 | c8ea7d90 | RECORDED-ONLY | superseded meaning, same names and same pin: the four `*_listener_members_max` rows are host-owned |
| 11B-17 | 0cd16a27 | RECORDED-ONLY | two more PowerShell array traps in the new sampler, both found by probing rather than reading |

**Orphans: 0. Strays: 0. Rewords: 0.** Census: 18 RESOLVED, 16 RECORDED-ONLY,
1 CAP-12.

## 6. `sdk_own_license`, RE-MEASURED

`git ls-files LICENSE` is **non-empty**: commit `864fca7` tracked
`<repo>/LICENSE`, Mozilla Public License 2.0, 16,726 bytes. So the row reads
**`declared`** on four targets, and it is a regression repair rather than a new
decision.

CAP-10D2 recorded the absence as a real gap in a distributable product and
called it the owner's call. CAP-11A re-measured it, found `<repo>/LICENSE`
absent and `<repo>/LICENSE.txt` untracked and ignored, pinned `undeclared`, and
left D2-8 open with the human as its owner. Its review then recorded the
consequence in as many words — *"that pin will turn all four legs red the day
someone commits a LICENSE"* — and answered that this is the enforcement, not a
side effect. The owner committed a licence; the pin moved in the open, beside
it.

What that took, and nothing more: `LICENSE_TABLE` in `tools/pweb/pwebsdk.pas`
gains a fifth row (`LICENSE.pweb.txt`, `swAlways`); `test/cap10d2/build_cap10d2.{ps1,sh}`
stage `<repo>/LICENSE` into `share/pweb/licenses/`;
`docs/third-party-licenses.md` gains the row and says plainly that its table is
the **shipped notice set**, of which one row is now not third-party;
`docs/sdk-contract.md` matches; and the absolute pin reads `declared`. The two
CAP-10D2 gates read both tables mechanically and require them to agree name for
name and condition for condition, so the packager and the document cannot drift
apart.

## 7. THE THREE FLAKES, CURRENT STATE

| flake | state | observed since instrumentation |
|---|---|---|
| the `state=0` non-report (B1-10, B2-16, D1-15, and the CAP-4 dual-mode driver) | instrumented; `smokeobserve.ps1` types four causes from engine-side observations, `undetermined` is legal, and the observer is wrapped in `try/catch` at every call site | **OBSERVED, and this is the first post-instrumentation sighting.** On run `34127608923` the Windows leg failed at `CAP-5 runtime smokes` with the familiar `state=0` line — and this time the row was not a mystery: four observations, every one `cause=ran_missed_window`, with `profile=true` on all four and `script_cache=true` on three (`engine_max` 4–6, 32–40 samples). The engine came up, it wrote a user-data profile, and on three of four it compiled JavaScript into `Code Cache/js` — so the page ran and the driver's window closed before the report arrived. That is a *timing* answer, not "we do not know", and it is the first time this flake has had one. Disposition unchanged: re-run the job, never re-ratify |
| the CAP-6b4 U3 uninstall residue (D1-16) | instrumented; the drain runs scoped to the install directory *before* the uninstaller and writes pids, images and sweeps | **not observed since**; `u3_drain_before_measure` reads `true` on every run. The state of the U3 uninstall residue is therefore: instrumented, quiet |
| the pinned-installer fetch stalls (C3-15) | instrumented; `tools/pwebfetch.ps1` gives every pinned fetch three attempts × 180 s with a row each, and a digest mismatch is refused on the first attempt and never retried | **not observed since**; `fetch_retry_max_attempts = 3`, `fetch_retry_bound_s = 180` |

**KNOWN LIMITATION, restated:** the non-report's cause is *inferred* from
engine-side observations, not reported by the page. `examples/` is frozen and a
page-side progress report belongs to whichever shard may next touch it.

**A FOURTH CLASS WAS SIGHTED DURING THIS SHARD, and it is none of the three.**
On run `34118821940` the Windows leg failed at `CAP-10C0 supervision suite +
pweb run gates + evidence` with `GATE FAILURE: a tree member opened a listener`
— thirty steps *before* anything CAP-11B adds, in a capability this shard did
not touch, and green on the neighbouring runs `34107491800` and `34113334940`.
The whole `pweb.cli` suite passed on that run (0 of 223 assertions failed) and
both release hosts reached `42` and `clean exit`; R9's own stderr reads
`pwebchild: no mode` / `exited 64`. Disposition: **re-run the job** — the same
answer the three instrumented flakes get — and ledger it (11B-13) so the next
occurrence is a second data point rather than a first. What would settle it is
the instrumentation CAP-11A gave the others: have the sampler *name* the tree
member and the port, so a real listener in a PWeb process is distinguishable
from a PID the runner reused. That belongs to whoever next owns
`test/cap10c0/`.

## 8. THE SPEC'S CAP-11 ACCEPTANCE, LINE BY LINE

| clause | verdict | evidence |
|---|---|---|
| A1 | MET | *"CI builds Windows x64, Linux x64, macOS x64, and macOS ARM64"* — one reusable `platform-leg.yml` called four times from `ci.yml`; run 34022414932, six jobs green, four identical sequences measured from the run |
| A2 | MET | *"a separate watcher compiles the binding against upstream head"* — `.github/workflows/upstream-watch.yml`, four targets, `signature_pin` and the paired ABI probes compiled against a projection of head's headers, calibrated on the pinned headers first |
| A3 | MET | *"and reports an API diff"* — one artifact and one job summary per target, the diff taken mechanically from the headers, six typed verdicts each demonstrated by a seeded case on every leg |
| A4 | MET | *"without changing the pinned version"* — `contents: read`, no write to a lock, the pinned plan compared byte for byte with no ref input, and both lock digests re-read before and after every watch |
| A5 | MET | *"This phase extends CI; it does not introduce it"* — the Phase 1 Windows gate still runs, inside the one sequence; 445 legacy steps mapped one-for-one and every leg observed running all of its legacy steps in order |
| A6 | MET | *"Production pins an explicit upstream `webview/webview` version and never follows `master` automatically"* (SPEC constraint) — `webview.lock` is unchanged; the floating-ref guards still sweep `tools/get-webview.ps1`, `build-webview-dll.ps1`, `build-webview-so.sh`, `build-webview-dylib.sh` and every workflow file, and none of them matches. The ONE file in this repository that legitimately holds a floating ref is `test/cap11b/watch_upstream.ps1`, which the guards deliberately do not sweep and which can reach only `deps/webview-watch` and `build/cap11b/` — asserted by the ref-plan mirror check and by the driver's before/after measurement of `deps/webview` |

## 9. THE CAP-12 HANDOFF

CAP-12 is the blob data plane. It is **off the critical path**: it does not gate
Phase 5 and the MVP does not require it (`phase-plan.md`, Phase 4b).

### What CAP-12 inherits verbatim — none of it is CAP-12's to renegotiate

- **The seven frozen boundaries.** `IWebView`, `IWebViewBinding`,
  `IInvocationBridge`, `IInvocationScheduler`, `IAssetStore`, `IBlobStore`,
  `ICapabilityPolicy` — no platform or implementation type in their signatures,
  no mORMot type name in `IInvocationBridge`'s.
- **`pweb://app` and the CSP.** The privileged origin never changes; the
  privileged WebView navigates only `pweb://app/...` and never to external
  content. `https:`/`mailto:` reach the OS only through the capability-authorised
  `pweb.openExternal` invocation, never a gesture.
- **The JSON control plane.** Every caller travels source →
  `IInvocationScheduler` → `IInvocationBridge` → `ICapabilityPolicy` → service.
  Named JSON object arguments or `null`; the nine-code error taxonomy with `code`
  as the sole normative discriminator; `PWEB_PROTOCOL_VERSION = 1`.
- **The threading model.** The bind callback only enqueues; workers call
  `webview_return()` directly; exactly-once completion through an idempotent
  sink; cooperative cancellation tokens plus short handle-use leases; Pascal
  exceptions never cross a C callback.
- **Asset-path fail-closed rules**, exact case-sensitive matching on every
  platform, and the kernel image-path reader (`src/security/pweb.imagepath.pas`)
  as the one reader in shipped code.
- **The CI matrix as it now stands**: one sequence in `platform-leg.yml`, four
  calls, the collection block last, the retention classes, the 64 KB /
  1,600-line bound, and the rule that a gate never depends on an upload. A CAP-12
  gate is added **once** and all four targets get it.
- **The watcher contract** (`docs/watcher-contract.md`). CAP-12 may read its
  reports; nothing CAP-12 builds may consume one as an input.

### What CAP-12 owns

- **`IBlobStore` decoupled from `pweb://`.** Its concrete method sets — together
  with `IBlobReader`/`IBlobWriter` — **ratify at Phase 4b entry, before any blob
  implementation is written**, against the invariants already fixed in
  `core-interfaces.md`: owner-scoped blobs, handle entropy, logical release with
  reader refcounting, positioned reads, auto-release on principal teardown, and
  the SDK's `native.blobs.release`.
- **The blob data plane**: `pweb://blob/{token}` with `Range`,
  `Content-Length` and `Content-Type` honoured without buffering the whole
  payload; streaming; JS→native upload. A service returning a >40 MB PDF answers
  with a `BlobHandle` envelope — no base64 bulk over the bridge.
- **The WebKit / WebView2 / WKWebView differences, already measured** and not to
  be re-measured from scratch: CAP-4 and CAP-4W for the Windows custom scheme,
  CAP-7L for WebKitGTK 4.1 (`docs/webkitgtk-linux-semantics.md`), CAP-7M for
  WKWebView (`docs/wkwebview-macos-semantics.md`). Those three documents are
  CAP-12's starting point for what each engine does with a custom-scheme
  response.

### What CAP-12 must not touch

- `webview.lock`, `mormot.lock` or any pin; `src/lib/` and `webview.chet`; the
  seven interface signatures; `pweb.rpc.intf.pas`'s independence from every
  `pweb.webview.*` unit.
- The watcher: it is not CAP-12's to call, to gate on, or to make required.
- The licence set: `LICENSE_TABLE` and `docs/third-party-licenses.md` move only
  when a shipped component changes, which is a measurement, never a preference.
- The `state=0` non-report instrumentation, unless CAP-12 is the shard that may
  touch `examples/` — in which case a page-side progress report is the fix the
  ledger has been asking for.

## 9b. THE ADVERSARIAL REVIEW, AND WHAT IT COST

Three independent reviewers read the whole diff. **Every finding that survived
checking was a patch; none required the intent to change**, and four of them
were defects a reading of the code would not have found:

| finding | why it mattered |
|---|---|
| `${{ inputs.ref }}` expanded inside a `pwsh` `run:` body | a dispatch input carrying a quote closes the argument and executes on the runner. It now reaches the script through `env:` and is validated against a ref's shape; the gate refuses any `${{ }}` in a `run:` |
| `compatible_additive` was unreachable on any run that built | the three ratified export gates assert *exactly* seventeen, so an additive upstream commit typed as `abi_break`. §10.3 |
| the whole ref BUILD path was executed by no gate | six cases skip the build, one fakes it, one refuses the fetch. W8 now runs it for real on every leg |
| nine seeded reports were appended to every leg's job summary | the driver inherits `GITHUB_STEP_SUMMARY`; publication is now an explicit opt-in only the watcher workflow sets |
| both output pipes drained sequentially | `cmake` and `fpc` fill stderr; a full buffer deadlocks the parent until the job timeout. Both are drained concurrently |
| `$x = if (…) { @() }` collapses to `$null` | `$badOther.Count` threw under StrictMode on the *healthy* path — found by W8, the case the review asked for, on its first run |
| `get-webview.ps1 --print-plan` printed a literal `checkout=` | the one mirror check that exists to notice a ref plan pointing at the pinned tree was comparing prose to prose. It prints the resolved variable now, as its three siblings already did |
| `-Record` re-ratifies the pinned plan and exits 0 first | refused when `GITHUB_ACTIONS` is set |
| the out-of-driver frozen check covered two of six locks | every lock, `webview.chet`, and `tools/`, `test/` and `docs/` with them |
| five of ten new evidence rows had no seeded refusal | nine now do; the aggregator's refusal floor rose 221 → 230 |
| Pascal reserved words, duplicate `unnamed`, zero-length arrays | all three would have produced a compile failure *caused by the projector* and read as `abi_break` about upstream |
| a `WEBVIEW_API` inside a `#if`, and a public header outside the flat scan | both are refusals now, so they type `inconclusive` rather than being projected for every target |

Everything above is in this commit. The contract gate's own negative self-test
grew from fourteen perturbations to **twenty-two**, one for each rule the review
added, so none of them can stop working quietly.

**Two more were found by the runs the review made possible, and both are the
kind only a hosted run finds.** The Windows leg's ref-input gate died because
`bash` on that runner is `C:\Windows\System32\bash.exe` — the WSL launcher,
always ahead of Git's on PATH, which exits 1 with an empty stderr; the gate now
resolves Git Bash by path and refuses the launcher by name. And the **control
case W5c fired on Windows**, exactly as designed: `tools/build-webview-dll.ps1`
leaves `deps/webview` patched, so a fixture copied from the working tree carried
a patched `win32_edge.hh` and the pinned patch was rejected by its own output.
Every fixture file now comes from `git show <pin>:<path>` — the blob, so it is
the pin and it is LF, whatever the working tree happens to be. The control case
has now caught two different false greens, which is two more than it would have
caught if it had not been written.

The last was found by an absolute pin: `watcher_seeded_verdicts` reached the
aggregate as `abi_break` on all three POSIX legs, because the shell emitter's
shared one-line JSON reader stops at the first **comma** and that row is the one
list. Three targets agreeing perfectly on a truncated value is precisely what an
equality comparison cannot see and what `$absolutePins` exists for (11B-14).

## 10. KNOWN LIMITATIONS

1. **The projector is a narrow translator, not a C compiler.** It handles the
   closed set of constructs these six headers use and *refuses* anything else,
   which types the run `inconclusive` rather than guessing. A future upstream
   that introduced an unfamiliar construct would produce a refusal naming the
   type, not a wrong answer — but it would need a human to extend the table.
2. **The compile-based seeded cases cannot run on the development host.** Its
   FPC targets `i386-win32` and the projected binding declares `LIB_WEBVIEW`
   only for WIN64, DARWIN and LINUX. `check_cap11b_cases.ps1` refuses with a
   named message rather than skipping; the four CI legs, which install the
   pinned x86_64 FPC, do run them.
3. **The export comparison is the watcher's own, not the three ratified gates'.**
   Those gates assert *exactly* the pinned seventeen, which against head would
   type a purely additive upstream commit as a break and make
   `compatible_additive` unreachable on any run that builds — the review found
   that, and it was real. The watcher compares the sets and types the
   difference; the ratified gates keep their job on the pinned path, where the
   matrix runs them on every push, and the contract gate cross-checks the
   entry-point lists so the two cannot drift.
4. **`patch_drift` can only be measured on Windows.** It is the only target with
   a declared platform patch; the other three report `not_applicable`, which the
   two ratified "carries no patch" steps keep honest.
5. **The watcher's first real answer is `unchanged` because upstream has not
   moved.** Every verdict other than `unchanged` is proven by seeded input, and
   the build half is proven by W8 against the pin; the day upstream does move,
   the first `compatible_additive` from a real head will be the first
   end-to-end demonstration of that particular path.
6. **"Not a required check" is enforced as far as a repository can enforce it.**
   The gate proves the watcher is not called by `ci.yml` or `platform-leg.yml`,
   declares no `workflow_call` and is `needs:`-linked to nothing. Whether a
   branch-protection rule *names* it is a GitHub repository setting, and no gate
   in this tree can read one.
7. **The watcher builds an unreviewed commit, and that is the point of §2 of the
   contract.** `cmake` over an upstream `CMakeLists.txt` executes arbitrary code
   at configure and build time; a watcher that would not build could not compile
   the pins against head. The blast radius is bounded to the runner — read-only
   token, no secret, no write to the repository — and the pinned checkout is
   measured before and after every watch.

## 11. FREEZE CHECK

`git diff` against the CAP-11A closure, over the frozen surface:

- `src/`, `sdk/`, `deps/`, `tools/setup/`, `examples/` — **no files changed**
- every `*.lock` — **unchanged**
- `webview.chet`, `src/lib/pweb.lib.webview.pas` and both view units — **unchanged**
- `docs/kernel.md` and every contract document except the three the licence
  regression required — **unchanged**

What was permitted and used: `.github/workflows/upstream-watch.yml`;
`platform-leg.yml` and `test/cap11a/step-applicability.tsv` (+4 steps, once, all
four targets); the ref input and `--print-plan` on `tools/get-webview.ps1` and
the three build scripts; `test/cap11b/**`; the CAP-7F emitters and aggregator
for the new evidence rows; the D2 packager's declared licence table and its two
staging scripts, forced by a tracked `LICENSE`; `docs/watcher-contract.md`,
`docs/index.md`, `docs/third-party-licenses.md`, `docs/sdk-contract.md`;
`deferred-work.md` and this artifact.

## VERDICT

The SPEC asked CAP-11 for two things. The matrix was the first and CAP-11A froze
it. The second was a watcher that compiles the binding against upstream head and
reports an API diff **without changing the pinned version**, and the load-bearing
word there is *without*: the value of this shard is in what the watcher cannot
do, and none of that is visible in a green run. So it is a source gate that runs
on all four legs and proves it refuses — fourteen perturbations of the watcher's
own sources, every one rejected — beside eight seeded cases that produce all six
verdicts offline, with a real compile behind `abi_break` and a control case that
makes the two drift cases mean something.

The pinned path is unchanged by comparison rather than by assertion: five plans,
byte-identical with no ref input, on every leg and on two different hosts. Both
locks are digested before and after every watch. The phase ledger has 28 entries
and no orphan. `sdk_own_license` reads `declared` because the owner declared one,
and the pin moved in the open beside the licence, exactly as CAP-11A said it
would have to.

Closure run **`34127608923`** on **`e0bc6ba`**, six jobs green; the watcher's own
run **`34118821510`**, four targets, all `unchanged`. Product code
byte-untouched.

CAP-11B PASS — UPSTREAM WATCHER FROZEN, CAP-11 CLOSED
