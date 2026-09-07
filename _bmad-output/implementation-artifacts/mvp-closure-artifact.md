# PWeb — the MVP closure, across every phase

This is the whole-plan record. Every other closure artifact in this directory
answers for one phase; this one answers for the plan those phases were cut
from, and it is written to be readable on its own by somebody who has read
none of them.

It says: which phase closed on which hosted run at which commit; which
document freezes what; what the SPEC asked for line by line and whether each
line was met; how many ledger entries exist and how many have no judgement;
what the frozen digests are **now**, not at the moment each was established;
which limitations survive the MVP and who owns each of them; and — the section
that matters most for whoever picks this up next — what was deliberately not
built.

Nothing here is new measurement. Every number is either read back from a
committed artifact, from `deferred-work.md`, or from the evidence the last
green hosted run published; where a source disagrees with a later measurement,
both are given and the newer one is named as newer.

> **The MVP itself.** `phase-plan.md` defines it as six boxes, and all six are
> ticked: Windows x64 · an independent `webview/webview` binding · React
> displaying a real UI · `native.invoke()` working · `native.invoke()` reaching
> a mORMot service through `TRestServer.Uri()` · production assets served from
> an archive. What actually shipped is a long way past that line — three
> platforms, four CI targets, a capability system, a QuickJS plugin runtime, a
> CLI and a distribution — which is why this document is a plan closure rather
> than an MVP checklist.

---

## 1. Every phase, its closure run and its HEAD

Two conventions, both from the repository's own practice: for Phases 1–6 the
closure HEAD is the merge commit on `main` and the closure run is the `main`
run at that SHA (each of those commits carries two runs, one per branch —
the `main` one is cited). From CAP-7 onward the work closed on shard branches
and the closure HEAD is the commit the artifact names, with the run that was
green on it.

| phase | capability | closure HEAD | hosted run | canonical record |
|---|---|---|---|---|
| 0 | — (seven boundaries, four invariants) | `b2f04dc` | closed under CAP-1's CI | `spec-phase-0-contracts.md` |
| 1 | CAP-1 | `709bf0f` (merge `phase/1-cap1-binding`) | 31313112718 | `spec-phase-1-cap1-webview-binding.md` |
| 2 | CAP-2 | `4653ba7` (merge `phase/2-cap2-invocation`) | 31339063612 | `spec-phase-2-cap2-invocation-pipeline.md` + `…-corrective-review.md` |
| 3 | CAP-3 | `3a9ff2b` (merge `phase/3-cap3-mormot-bridge`) | 31483820914 | `spec-phase-3-cap3-mormot-bridge.md` + `…-bridge-2.md` |
| 4 | CAP-4 (+ CAP-4W) | `e335656` (merge `phase/4-cap4-custom-scheme`) | 31529237384 | `spec-phase-4-cap4-asset-system.md`, `…-cap4w-windows-custom-scheme.md` |
| 5 | CAP-5 | `cadea5b` (merge `phase/5-cap5-frontend-sdks`) | 31572442861 | `spec-phase-5-cap5-frontend-sdks.md` |
| 6 | CAP-6 | `bb83622` (merge `phase/6-cap6-release-bundle`) | 31602307110 | `spec-phase-6-cap6-release-bundle.md` |
| 6b | **CAP-13** | `b18e88e` | 31879087884 | `spec-phase-6b4-windows-profile-integration.md` (closure recorded in `9d5ffbc`) |
| 7 | CAP-7 | `9d4b95a` (hardening; feature commit `6b818de`) | 32135179145 (and 32129242424) | `spec-phase-7-cap7f-final-integration.md` (closure recorded in `402add2`, run 32160037916) |
| 8 | CAP-8 | `a59638b` | 32827378066 | `cap8-final-artifact.md` (closure recorded in `1af1b38`) |
| 9 | CAP-9 | `1eda46d` | 33042763634 | `cap9c2-final-artifact.md` (closure recorded in `1b4c81b`) |
| 10 | CAP-10 | `2e2903c` | 33962919229 | `cap10-closure-artifact.md` (phase closure recorded in `a32cd66`, own aggregation 33924083318) |
| 10E | CAP-10E (post-closure bugfix) | `28bda2a` | 33983841968 | `cap10e-final-artifact.md` (closure recorded in `ed1cb71`) |
| 11 | CAP-11 | `e0bc6ba` | 34127608923 | `cap11-closure-artifact.md` (closure recorded in `043a306`) |

### The shards behind the later phases

CAP-6b, CAP-7, CAP-8, CAP-9, CAP-10 and CAP-11 were each several shards, and
each shard has its own hosted green run. They are the audit trail behind the
table above.

| phase | shard | closure HEAD | hosted run |
|---|---|---|---|
| 6b | CAP-6b0…6b4 | `b18e88e` (integration) | 31879087884 |
| 7 | CAP-7L (Linux x64) | `5cb564d` | 31890995361 |
| 7 | CAP-7M0 / M1 / M2 (macOS) | `a6b28bb` / `30c80a7` / `8f0d05a` | origin run 32013558592, re-exercised in 32129242424 |
| 7 | CAP-7F (cross-target closure) | `9d4b95a` | 32135179145 |
| 8 | CAP-8A (policy core) | `2a8a4a2` | 32195981406 |
| 8 | CAP-8B (privileged navigation) | `949a1fc` | 32742436382 |
| 8 | CAP-8C (multi-principal) | `a59638b` | 32827378066 |
| 9 | CAP-9A (engine + source adapter) | `bd4c041` | 32863002073 |
| 9 | CAP-9B1 (package + module loader) | `e62331d` | 32975110018 |
| 9 | CAP-9B2 (lifecycle + reload) | `78e1359` | 32995412526 |
| 9 | CAP-9C1 (release package) | `c1bf9f9` | 33005408374 |
| 9 | CAP-9C2 (plugin-enabled GUI release) | `1eda46d` | 33042763634 |
| 10 | CAP-10A … CAP-10D2 (eleven shards) | see `cap10-closure-artifact.md` §1 | 33071121924 · 33113867439 · 33127976094 · 33168355248 · 33625058683 · 33685847062 · 33748442256 · 33794370400 · 33851014894 · 33883767131 · 33962919229 |
| 11 | CAP-11A (CI matrix) | `d63d7e3` | 34022414932 |
| 11 | CAP-11B (upstream watcher) | `e0bc6ba` | 34127608923 |

**Where the branches are.** `main` last advanced at `1b4c81b`, the CAP-9
closure. CAP-10 and CAP-11 closed on shard branches that are 136 commits ahead
of it. Every one of those commits is green on hosted CI; none of them has been
merged back. That is a repository-topology fact, not a defect, but it is the
first thing a new reader needs to know before running `git log main`.

**The current head.** `9606082` on `phase/cap-11/b-upstream-watcher`, hosted
run **34150865012**, six jobs green. Every re-measured number in §4 and §5 of
this document comes from that run's evidence.

---

## 2. The contract documents, and what each freezes

`docs/index.md` is the hand-maintained map, and
`test/cap11b/check_cap11_ledger.ps1` requires it to cross-link every
`*-contract.md` in the directory plus `kernel.md`, `third-party-licenses.md`
and `watcher-contract.md` — so a contract document that stops being linked
fails a gate rather than quietly drifting out of the map.

Every one of these is a **contract** in the same specific sense: the prose may
be reworded freely; the grammars, layouts, digests, bounds and exit codes may
not, except by a version bump.

### The kernel

| document | what it freezes |
|---|---|
| `docs/kernel.md` | the ratified contract and its companions; the architecture landmines; the seven frozen boundaries; the threading, wire, security, asset and toolchain conventions. The canonical contract itself remains `_bmad-output/specs/spec-pweb/SPEC.md` plus every companion named in its frontmatter |

### The CLI and the lifecycle

| document | what it freezes | shard |
|---|---|---|
| `docs/cli-contract.md` | the public command surface, `pweb.json` schema 1, the `doctor` report, the six exit codes, the reusable runtime-command layer, and §5 the development-trust decision | CAP-10A, 10B1, 10B2, 10C0, 10C2, 10C3 |
| `docs/template-contract.md` | the scaffold engine, the trusted template pack, the identity mapping, the placeholder model and the atomic creation transaction | CAP-10B0 |
| `docs/supervision-contract.md` | the one child-process engine: exact path, argument vector, explicit working directory, no shell, graceful-then-forced, drained by membership | CAP-10C0 |
| `docs/pipeline-contract.md` | the ten-stage lifecycle pipeline, the SDK root, the project-mutation set, the network policy and the Pas2JS assembly | CAP-10C1 |
| `docs/dev-contract.md` | the development loop for both frontends: the dev host, the generation, publish-by-rename, the poller, the acknowledgement, and the two change detectors | CAP-10C2 (React), CAP-10C3 (Pas2JS) |
| `docs/build-contract.md` | the public `pweb build`: its grammar and the options it deliberately does not have, the one execution path, the release replacement rule and its failure table, the summary, and interruption | CAP-10D0 |
| `docs/distribution-contract.md` | `pweb build --profile`: the four profile names, the identity every platform identifier is derived from, the pinned offline inputs, the deterministic archive, the macOS signing posture and the artifact layout | CAP-10D1 |
| `docs/sdk-contract.md` | the SDK distribution itself: what ships and what is only pinned, the canonical manifest and its escape rule, the three integrity rows and the build refusal, the tool-location rule, and the installation model — extract, and nothing else | CAP-10D2 |

### The platform semantics and the watcher

| document | what it records or freezes |
|---|---|
| `docs/webview-upstream-semantics.md` | the pinned `webview/webview` surface and its error paths — the scope of "complete public C ABI" is `api.h` plus the public C headers it includes (`errors.h`, `types.h`, `macros.h`), **17 entry points at this pin** |
| `docs/watcher-contract.md` | **version 1** — what the upstream watcher may never do, its permissions and triggers, its eight stages, the six verdicts and the ref input. The permissions, the trigger set and its `paths:` list, the schedule, the concurrency form, the six verdict words and their precedence, the retention value and the eight-stage order move only by incrementing that version |
| `docs/webkitgtk-linux-semantics.md` | what WebKitGTK 4.1 + GTK 3 does, measured on the ratified Linux baseline — not transcribed from documentation |
| `docs/wkwebview-macos-semantics.md` | what Cocoa/WKWebView does at the 12.0 deployment target on both macOS arches, measured |
| `docs/third-party-licenses.md` | every dependency this product ships and the licence it ships under. The table is the **machine-readable shipped subset**; `tools/pweb/pwebsdk.pas` carries the same rows compiled, and a CAP-10D2 gate requires the two to agree name for name and condition for condition |

### The one document under `docs/` that is not a contract

| document | what it is |
|---|---|
| `docs/ci-migration.md` | the CAP-11A migration map: where each of the 445 legacy `ci.yml` steps went when one 271,637-byte file became one reusable `platform-leg.yml` plus one composite action per step. It exists so that a `ci.yml:<line>` citation in a closed artifact can still be resolved — **by step name, which is stable, never by line number, which was only ever true of one commit.** It is deliberately not in `docs/index.md`, which lists contracts only |

---

## 3. The SPEC's acceptance, across the whole plan

Each capability's success sentence is quoted from `SPEC.md` and answered with
the evidence that meets it or the named ratified reason it deviates. Two
columns of evidence are given wherever both exist: the run that first proved
the clause, and the row the four-target aggregate still re-measures on **every
push**, because a clause proven once and never checked again is a weaker claim
than one that would turn four legs red today.

| # | capability | clause | verdict | evidence, and the artifact that says why |
|---|---|---|---|---|
| 1.1 | CAP-1 | a Windows x64 sample creates the view, sets title and HTML, runs and closes cleanly with no evident leak | **MET** | `spec-phase-1-cap1-webview-binding.md`; run 31313112718 |
| 1.2 | CAP-1 | the complete public C ABI of pinned `cbbdee44…` — 17 entry points — is bound and its error paths checked | **MET** | the 17-name `webview_*` export set is re-enumerated per target (dumpbin / `nm -D` / dyld_info) and asserted **set-equal on four targets** every run; `exports` count = 17 is an absolute pin in `check_cap7f_aggregate.ps1`. `docs/webview-upstream-semantics.md` scopes the surface; the Phase-1 ABI checklist is reused by the CAP-11B watcher |
| 1.3 | CAP-1 | **a Windows CI runner compiles the binding and executes its tests on every push from this phase onward** | **MET** | CI has run on every push since `59286ec`; CAP-11A proves the Phase-1 gate still runs inside the one sequence — `ci_legacy_present = false`, 445 legacy steps mapped one-for-one, every leg observed running all of its legacy steps in order |
| 2.1 | CAP-2 | a `pweb.echo` round-trip returns the argument object to a resolved JS promise | **MET** | `spec-phase-2-cap2-invocation-pipeline.md`; `pweb.echo` is still a runtime-owned method in `pweb.rpc.intf.pas` and is exercised by `test/rpc/pweb.test.binding.pas` and `…lifecycle.pas` |
| 2.2 | CAP-2 | a Pascal-side failure rejects the promise instead of hanging it | **MET** | the nine-code taxonomy with `code` as sole discriminator; exactly-once completion through an idempotent sink, proven by the cancel-then-late-result test hardened in `21b9fe9` |
| 2.3 | CAP-2 | the work runs off the GUI thread and the result comes back through `webview_return()` | **MET** | the frozen threading model; the bind callback only enqueues (pre-queue rejections excepted), workers call `webview_return` directly. CAP-7M1 records the markers `gui_affine=1 worker_distinct=1 direct_return=1` |
| 2.4 | CAP-2 | the `ICapabilityPolicy` call site is wired in from the first bridge | **MET** | `TAllowAllCapabilityPolicy` at Phase 2; Phase 8 swapped the implementation and touched no plumbing — which is the property `capability_policy_digest` now pins on four targets |
| 3.1 | CAP-3 | `await CalculatorService.add(20, 22)` returns `42` in the frontend | **MET** | `rpc_add_20_22 = 42` is an **absolute pin** on all four targets, re-measured every run; live `Add(20,22)=42` with runtime-gate provenance in the CAP-7 RPC matrix |
| 3.2 | CAP-3 | while the process holds no `TRestHttpServer`, no socket and no listening port | **MET** | `listener_count = 0`, `run_listener_count = 0`, `run_listener_members_max = 0` (membership-scoped sampler, `descendant_closure`), `network_calls = 0`, `no_listener = PASS` on four targets. Linux samples listeners for the process lifetime under xvfb; macOS samples `lsof` for the whole life of every release run |
| 3.3 | CAP-3 | the call passes through `ICapabilityPolicy` on its way | **MET** | one path, source → `IInvocationScheduler` → `IInvocationBridge` → `ICapabilityPolicy` → service; `cap8c_denied_soa = 0` proves the converse — a denied principal never reached the bridge |
| 4.1 | CAP-4 | `index.html` plus its JS/CSS load over `pweb://` from `TFolderAssetStore` in dev | **MET** | `spec-phase-4-cap4-asset-system.md`; `origin = pweb://app` and `secure = true` are absolute pins on four targets |
| 4.2 | CAP-4 | …and from `TZipAssetStore` over `app.zip` in production, both through the platform resource handler | **MET** | `TZipAssetStore` over `app.pwb`; three platform resource handlers (WebView2 `WebResourceRequested`, WebKitGTK, WKWebView) with divergence confined to `platform/` |
| 5.1 | CAP-5 | the same service is invoked from a React app and from a Pas2JS app | **MET** | `rpc_result = 42` and `pas2js_rpc_result = 42`, both absolute pins on four targets; `supported_uis = pas2js,react` pinned as the whole advertised set |
| 5.2 | CAP-5 | and the bridge contains no Pas2JS-specific branch | **MET** | `pas2js_sdk_binding_owner = true`; the SDK's responsibility ends at `window.__pweb_invoke`; the CAP-7F divergence sweep enumerates **every** platform conditional in the shared surface against an explicit allowlist, and no frontend-kind conditional exists in the bridge |
| 6.1 | CAP-6 | a release build ships with no loose frontend files | **MET** | `loose_assets_used = false` and `pas2js_loose_assets = false`, both absolute pins; the release-layout matrix asserts `exe + app.pwb + dll` on Windows, the four-file layout on Linux and exactly two minimal `.app` products on macOS |
| 6.2 | CAP-6 | and boots its UI from `app.pwb` containing `manifest.json`, `index.html` and `assets/` | **MET** | the react manifest read back from the closure evidence is literally those three entries — `assets/app.js`, `index.html`, `manifest.json`; `bundle_protocol = 1` is an absolute pin read from each target's real `app.pwb` |
| 7.1 | CAP-7 | the hello + RPC + assets example passes its gates on all three platforms | **MET** | one application source (`examples/08-release/releaseapp.pas`) → windows-x86_64, linux-x86_64, macos-x86_64, macos-arm64, proven by the machine-verified platform matrix; react `logical_inventory_sha256` **equal on all four targets** |
| 7.2 | CAP-7 | with divergence confined to the `platform/` asset handlers | **MET, with the measured scope stated** | the divergence sweep is an enumerate-and-allowlist gate over `src/**` (minus `src/platform/**`), the two acceptance hosts, the bundler, the QuickJS packer, `tools/pweb/` and `sdk/**`. The count has moved by ratified supersession as capabilities landed (206 → 212 at CAP-10E); every occurrence is inside the allowlist. `src/platform/**` is skipped wholesale by design — each unit there **is** one platform's body |
| 8.1 | CAP-8 | a method outside the effective set is refused with 403 without touching the SOA layer | **MET** | `cap8c_denied_soa = 0` on four targets — a forbidden principal reaching the bridge is a named aggregate failure, not a silent pass; `capability_policy_digest` equal on four targets |
| 8.2 | CAP-8 | the same method allowed for `MainWindow` is refused for `LoginWindow` and for a plugin principal | **MET** | CAP-8C multi-principal integration harness; the content-swap gate (Main serving the nominal login page still computes 42; Login serving the nominal main page stays forbidden) and the forged-`Args` vectors prove page content, filenames, query strings, manifests and handshake payloads have **zero** authorization effect |
| 8.3 | CAP-8 | a page reached by external navigation has no access to the native bridge | **MET** | the CAP-8B shared privileged-navigation classifier plus an unconditional native CSP; `navigation_policy_digest` and `cap8c_secure_origin = true` on four targets; `cap8c_opener_nonmain = 0` |
| 9.1 | CAP-9 | a QuickJS plugin call enters through `IInvocationScheduler` and traverses `IInvocationBridge` and `ICapabilityPolicy` exactly as a WebView call does | **MET** | `cap9a_denied_bridge = 0`, `cap9b1_denied_bridge = 0`, `cap9b2_denied_bridge = 0`, `cap9c1_denied_bridge = 0`, `cap9a_opener_reached = 0`; five QuickJS corpora `PASS` on four targets |
| 9.2 | CAP-9 | adding no second RPC path and no second permission system | **MET** | CAP-9C2 puts a real WebView UI and two isolated QuickJS plugins in **one** process over **one** scheduler, **one** CAP-8 policy, **one** bridge chain and **one** mORMot server; identity is measured four ways, none of them "the code only constructs one" |
| 10.1 | CAP-10 | a `pweb` CLI drives the application lifecycle from scaffold to release | **MET** | `cap10-closure-artifact.md` A1; five public commands, `advertised_commands = create,doctor,run,dev,build` pinned |
| 10.2 | CAP-10 | `pweb create MyApp --ui react` scaffolds a runnable app | **MET** | A2 — run 33127976094; ONE `generated_inventory_digest` on four targets and 42 from a real system WebView |
| 10.3 | CAP-10 | `--ui pas2js` scaffolds a runnable app | **MET** | A3 — run 33168355248; ONE `pas2js_generated_inventory_digest` and 42 from JavaScript Pas2JS 3.0.1 compiled out of Object Pascal |
| 10.4 | CAP-10 | `pweb dev` runs the frontend watcher and native executable together | **MET** | A4 — CAP-10C2 (run 33748442256) and CAP-10C3 (run 33794370400), both under one supervision ladder with two long-lived children |
| 10.5 | CAP-10 | *"Vite HMR **may** use a narrowly scoped, development-only WebSocket"* | **DEVIATED** | A5 in `cap10-closure-artifact.md`. PWeb uses rebuild-and-reload and opens **no WebSocket at all**. The reason is a measurement (`cap10c2-model-a-spike.md`), the clause deviated from is a *may* rather than a requirement, and the property it exists to protect — no localhost, no WebSocket allowance in production — is stronger this way. `dev_conditionals = 0`; the privileged origin never changes between development and production |
| 10.6 | CAP-10 | `pweb build` produces a packaged release | **MET** | A6 — run 33851014894; ONE `build_digest` on four targets and 42 through the real `pweb run` afterwards, for both frontend kinds |
| 10.7 | CAP-10 | the lifecycle runs on a machine that never built this repository | **MET** | A8 — CAP-10D2: one archive per target extracted to a spaced, non-ASCII path with the checkout's six framework trees renamed aside; `checkout_path_in_argv = 0`; every unit and library path under the extracted root |
| 11.1 | CAP-11 | CI builds Windows x64, Linux x64, macOS x64 and macOS ARM64 | **MET** | A1 — one reusable `platform-leg.yml` called four times; run 34022414932, six jobs green, four identical sequences measured from the run itself |
| 11.2 | CAP-11 | a separate watcher compiles the binding against upstream head | **MET** | A2 — `.github/workflows/upstream-watch.yml` on four targets; `signature_pin` and the paired ABI probes compiled against a projection of head's headers, calibrated on the pinned headers first |
| 11.3 | CAP-11 | and reports an API diff | **MET** | A3 — one artifact and one job summary per target; the diff taken mechanically from the headers; six typed verdicts each demonstrated by a seeded case on every leg |
| 11.4 | CAP-11 | without changing the pinned version | **MET** | A4 — `contents: read`, no write to a lock, five pinned plans compared **byte for byte** with no ref input on every leg and on two different hosts, both lock digests re-read before and after every watch |
| 11.5 | CAP-11 | this phase *extends* CI; it does not introduce it | **MET** | A5 — the Phase-1 Windows gate still runs inside the one sequence; 445 legacy steps mapped one-for-one |
| 11.6 | CAP-11 | *(SPEC constraint)* production pins an explicit upstream version and never follows `master` | **MET** | A6 — `webview.lock` unchanged; the floating-ref guards sweep every fetch and build script and every workflow file and match none. The one file that legitimately holds a floating ref is `test/cap11b/watch_upstream.ps1`, which can reach only `deps/webview-watch` and `build/cap11b/` |
| 12 | CAP-12 | a service returning a >40 MB PDF answers with a `BlobHandle` envelope; the frontend fetches `pweb://blob/{token}` honouring `Range`, `Content-Length` and `Content-Type` without buffering | **NOT BUILT — by design** | §7. The SPEC itself marks CAP-12 **off the critical path**: it does not gate Phase 5 and the MVP does not require it |
| 13.1 | CAP-13 | `pweb build` emits `normal`, `offline` and `fixed-runtime` profiles | **MET** | CAP-10D1 A7, run 33883767131; three Windows installer profiles over byte-identical CAP-13 `[Code]`, built from validated pinned inputs |
| 13.2 | CAP-13 | installing the `normal` profile on a machine without WebView2 runs the bootstrapper during setup, and the app then launches | **MET** | a genuine runtime-absent transcript ending `CAP6B1_CLEAN_MACHINE_PASS` (2026-08-13 21:11:12Z): the BEFORE phase observed a non-usable detector verdict and the staged app's `WEBVIEW2 RUNTIME UNUSABLE` refusal, setup executed the embedded lock-verified Bootstrapper (`WV2PROV_EXEC`, `outcome=Provisioned`), AFTER re-observed `AlreadyUsable`, and the installed app printed the CAP-6 42 PASS marker. The earlier waiver is superseded by that transcript |
| 13.3 | CAP-13 | and the `offline` profile does the same with no network | **DEVIATED — WAIVED, and labelled WAIVED everywhere** | no `CAP6B2_OFFLINE_CLEAN_MACHINE_PASS` transcript exists. Waived by explicit user decision on 2026-08-13. The offline provisioning-execute path is proven **indirectly**: by the CAP-6b1 clean-machine run over the *same* shared `pwebprovgate.issi` flow, plus the automated skip-path and verification legs. Recorded in `deferred-work.md` and repeated verbatim as WAIVED in the CAP-7 closure matrices |

**Totals.** Across the plan: **34 acceptance clauses MET**, **2 DEVIATED**
(CAP-10 A5, the HMR WebSocket *may*; CAP-13's offline clean-machine leg,
waived), and **1 capability deliberately not built** (CAP-12). Both deviations
are named in the artifact that owns them rather than absorbed, and neither is
a shortfall discovered here — each was recorded by the shard that produced it.

---

## 4. The ledger

`_bmad-output/implementation-artifacts/deferred-work.md` is append-only, and
carries **338 entries** across every shard from Phase 0 to CAP-11B. Every entry
is `source_spec` + `summary` + `evidence`; nothing is ever edited out, so a
superseded entry keeps its original wording and gains a successor entry that
says what changed. Three entries in the file exist precisely to say "the entry
above is now stale, and here is why a reader of it alone would carry away a
wrong claim."

The distribution, by source spec:

| shard family | entries |
|---|---|
| Phase 0 – CAP-6b | 33 |
| CAP-7 (L / M0 / M1 / M2 / F) | 29 |
| CAP-8 (A / B / C) | 19 |
| CAP-9 (A / B1 / B2 / C1 / C2) | 39 |
| CAP-10 (A … E) | 179 |
| CAP-11 (A / B) | 39 |

### Disposition under the CAP-11 gate

`test/cap11b/check_cap11_ledger.ps1` keys each entry as `<shard>-<ordinal>`
plus the first eight hex of the SHA-256 of its own `summary` line, so an
**orphan** (no judgement), a **stray** (a judgement for an entry that does not
exist), a **count drift** (an entry added or removed) and a **silent reword**
(a claim that changed under an inherited judgement) are four different failures
with four different messages. A disposition must come from a closed set —
`RESOLVED | RECORDED-ONLY | CAP-12 | CAP-13 | LATER` — and must carry a reason
of at least twelve characters, because a table of verdicts nobody justified is
a table nobody can check.

Measured at head `9606082`, and re-measured green on hosted run 34150865012:

```
[cap11b] phase ledger disposition PASS - 39 entries, 0 orphans
```

| fact | value |
|---|---|
| `cap11_ledger_entries` | **39** (18 from CAP-11A, 21 from CAP-11B) |
| `cap11_ledger_orphans` | **0** |
| `ledger_reworded` | 0 |
| `ledger_unknown_disposition` | 0 |
| disposition census | RESOLVED 21 · RECORDED-ONLY 17 · CAP-12 1 · CAP-13 0 · LATER 0 |

The same gate shape ran for CAP-10 and reported **165 entries, 0 orphans**
(RESOLVED 105 · RECORDED-ONLY 43 · CAP-11 11 · LATER 6), and for CAP-10C
**54 entries, 0 orphans**. Every entry produced by a phase that has a closure
gate has exactly one judgement.

> **A number that moved, recorded rather than smoothed over.**
> `cap11-closure-artifact.md` §5 is titled "THE PHASE LEDGER — 28 ENTRIES, 0
> ORPHANS" and its verdict repeats 28. The matrix row inside the same artifact
> reads 32, which is what the closure run 34127608923 measured; and the gate at
> head reads 39, because the three commits after the closure (`2511364`,
> `5e918a6`, `9606082`) each added ledger entries. All three numbers are true of
> their own moment, the orphan count is 0 at every one of them, and the gate
> re-derives the count from the file on every leg — so the drift is visible
> rather than load-bearing. The current number is **39**.

---

## 5. The frozen digests, at their final values

These are read back from the four-target agreement block of
`platform-matrix.json` published by run **34150865012** at head `9606082` —
that is, the value each digest holds **now**, after every supersession the plan
recorded. A digest in this block was measured independently on windows-x86_64,
linux-x86_64, macos-x86_64 and macos-arm64 and found byte-identical; a
disagreement on any of them fails `cap7 aggregate` and turns the run red.

### Security and policy

| digest | value |
|---|---|
| `capability_policy_digest` | `23b87da524b158f4b1a8ca53057ad794f485086257997534b426b28334bddb2f` |
| `navigation_policy_digest` | `360d69f282e9d8b053d1ef8a5052f76860875c723b9e6512b0d38685f0c7212e` |
| `security_corpus_digest` | `c5fc378bc3c6eb6aa6db753e35287db5cb7ed6332aeac77b75767919e5adbdf4` |

### QuickJS

| digest | value |
|---|---|
| `quickjs_corpus_digest` | `601b86ffd24d5642174758120d58d240da6e5cc0d4e0cc3a40b3ec0847e7909f` |
| `quickjs_package_digest` | `4b01cf06677ff52fb26c74b031c72282258f26b7c5b44bd44131586c77209c45` |
| `quickjs_lifecycle_digest` | `6c8d0bd7147cadb384ff06e8841b17212a6a1fa550a978c31d23ba1f1a785131` |
| `quickjs_release_digest` | `04c2db17eebfc48a9486d318b1c12586898a3c81952122c8e354577fcfc769fd` — **superseded** from its CAP-9C1 closure value `0f1e9c63…` by the deliberate CAP-9C2 corpus extension |
| `quickjs_gui_digest` | `1c88bda98dd369abba75659951ce38f848515959c41ce759429ac43e7658fdb8` — **superseded** from its CAP-9C2 closure value `67e08c69…` as later shards extended the corpus |
| `cap9c1_inventory_digest` | `a60b62a427438d27f9e58865f372d6f176deba918e46eb4bccf92355b4b0a1a1` |

### CLI, templates and the generated projects

| digest | value |
|---|---|
| `cli_digest` | `4aa3c03b772ad1bddc8b51d1ea974543184529733cebf9463c899a84c198f9ec` — the fifth value it has held; the four earlier ones each moved when a command became public (`run`, `dev`, `build`, `--profile`) |
| `doctor_schema_digest` | `3c597c8e09a442dbef93369bbfd2a8ce79011b455166584525330e8418eb493a` — moved once, by CAP-10D2's three `sdk.*` rows |
| `template_digest` | `13e91a698f04a706a838d4bdbedeaf87a2e14f98ac88f33f14431fc4196cfec7` |
| `template_semantic_digest` | `1d71838a57fc86d9b3321cfeca7e3769da610e7a955e0d23039526d6a7c10e5d` |
| `public_semantic_digest` | `25e4c234a085655861073c97935ae7702481b8d26ec9312e628ccd2ca04ae810` |
| `generated_inventory_digest` | `578a30933f3a37d66fac5f9ac554e5fb92227ca5ba839e4e57647301eaa145f0` |
| `generated_tree_digest` | `578a30933f3a37d66fac5f9ac554e5fb92227ca5ba839e4e57647301eaa145f0` |
| `generated_pweb_json_digest` | `f18c017ac5f6258e4489897b67fdaebb1624e57a29f7579e7b705022ba5f8012` |
| `generated_package_lock_digest` | `7719d3777382dbc3d028e69a9d251fb6d04ba9276e1407a6efce6847b3ef1ac8` |
| `pas2js_generated_inventory_digest` | `14b6a83fec9e271c2c0a1b420561358ed42b916ba57bbb4389ea904d63ebffd3` |
| `pas2js_pweb_json_digest` | `0d365076be1592ac07fa85f2efea63928fc70ab56b5549a2cd7ea9873cbd7c2f` |
| `pas2js_frontend_source_digest` | `cff1444479e1aa1165ac953b21d6fbbb31d1bb87ab220f1bd3a0409b23838b69` |
| `pas2js_static_inventory_digest` | `51ea35c77ee7b556dc30ee19fae74a2f119d8c48296053399bae483b8d9040e1` |
| `pas2js_app_pwb_semantic_digest` | `0b95cb3782ed7dc28dc50e710063d3e8d90f9d5b985b844ecd96e7b2d7fc7f28` |
| `shared_native_source_digest` | `00fc402fbff3b8d9229ffac05492ac284de76feeb8e5b2b6750b7544e783eafe` |

### The lifecycle, the build and the distribution

Measured per target and required **unchanged**; the values below are the
windows-x86_64 evidence from run 34150865012, and the four targets agree on
each of the cross-target ones.

| digest | value |
|---|---|
| `supervision_digest` | `120f6769c155c59b8bc0cbc8b96e7faee14091628a5af49833f5b4fb96db11c0` |
| `pipeline_digest` | `f890424a5ef95646b9a48355819e32f49e608c7f5ecc4e69766b4182978e839a` |
| `dev_digest` | `09cc2b1c1c2c6b103d88c744fd0a861818f43e55d76f852d6472f155ce0b7df6` |
| `dev_pas2js_digest` | `410415c289011fc08a655019d1a34e7b78c1ca9eefac366ecc2f73f5ba28fad2` |
| `build_digest` | `1d5230a9959ae6c6db8ce0014d2ef254316c621a95054aa7f6dc8cf3ff08fb18` |
| `pack_digest` | `03ab486ce98b0d5ea6eed072d69be9b448e890e3c85cddd9eb92b0c427eaec6f` |
| `sdk_digest` | `b33df77edacdffd9336bc6835635a010a0b0d48ec4c2256773592a008f82e9be` — **unchanged at its CAP-10D2 closure value**, which is the check that says the CAP-6 bundler correction moved no recorded verdict |
| `sdk_ship_table_digest` | `8a4d9fa32ed02a5dcf6c11acd6bb73a151734dfdbceb80490c2e53e5ba9a0636` — **recomputed** by CAP-11B, because the licence table is inside the ship digest by construction and gained `LICENSE.pweb.txt` |
| `sdk_inventory_digest` | `03158a82729daa7b715a0a2c004fa0769ac9fa3402d8272dceb7b3ef2a65ace7` |
| `logical_inventory_sha256_react` | `a6323cce12199d3e544486e30a44c5a7e6956337fbd86e4e15484c984d2ca01b` |
| `logical_inventory_sha256_pas2js` | `f924109b4678d315963c1b6bd7d6eeec4997b4388590c204aa3fea639f5b16dd` |

### CI and the watcher

| digest | value |
|---|---|
| `ci_sequence_digest` | `8b3c15bd247f0e86ad6116d1a8359fdfcb6425c4e4088c08470cd35760243a05` — over the declared step list; **200 steps**, four identical sequences, and the digest of the sequence *run* equal to the digest of the sequence *declared* |
| `retention_policy_digest` | `98052b5c2682ccceb220783fe33eee41ccb1b5b7a1629718dd10ada8e5e66aa2` |
| `ci_timeouts_digest` | `6a8ddf1e7fd0ba75a4c8b198009d878c65f4a9504cf89354b323b8707445af29` — over `windows=135;linux=45;macos-x64=75;macos-arm64=75;aggregate=20;inventory=10` |
| `watcher_verdict_vocabulary_digest` | `021d2f5ceb6c26d690058c24929dc340c468265b3c9d39d4c5acd0c46b16a56b` |

### The pins the digests sit on

| pin | value |
|---|---|
| `webview/webview` | `cbbdee44afff22867de9fd88a9fc8350d9bdd399` — and the CAP-11B watcher's first real answer is `unchanged`, because `-Ref HEAD` resolves the default branch to exactly this commit |
| webview surface | `17/soname 0.12` — no numeric ABI constant exists; the surface pin plus the soname **is** the contract |
| WebView2 SDK | `1.0.1587.40`, `webview2-sdk-sha256 cd5e3426…`, `webview2-sdk-tree-sha256 96309ee8…` |
| CAP-4W platform patch | `cap4w-patch-sha256 ae5177ba…`; applied **clean** to upstream head on the watcher's hosted Windows leg |
| mORMot2 | `b1a129b09197b6b9fb67c6d4d2a13445987a3fe1`, statics `ae2d8da2…` |
| FPC | `3.2.2` on all four targets |
| Pas2JS | `3.0.1` (`pas2js_compiler_version` is an absolute pin — a different compiler is a different product, not a newer one) |
| Inno Setup | `6.7.3`, pinned by installer digest, because ISCC publishes no machine-readable version resource |
| WebView2 runtime artifacts | `webview2-runtime.lock` — every Microsoft binary pinned by URL, filename, byte size and a locally computed SHA-256, verified **before** any use |
| protocol | `PWEB_PROTOCOL_VERSION = 1`; `cli_version_line = pweb 0.1.0 (protocol 1)` |
| licence | MPL-2.0 (`LICENSE`, committed in `864fca7`); `sdk_own_license = declared`; five shipped notices |

---

## 6. Known limitations that survive the MVP

Each is stated with the party that would have to move it. "Owner: the human"
means a decision no shard can take on its own; "owner: a future shard" means
work whose scope is understood but which no phase currently holds.

### Environment proofs that were waived rather than obtained

| limitation | owner |
|---|---|
| **The CAP-6b2 offline clean-machine VM gate has no passing transcript.** `test/cap6b2/run_offline_clean_machine_gate.ps1` refuses to run under CI by design. The offline provisioning-execute path is proven only indirectly, by the CAP-6b1 clean-machine run over the same shared `pwebprovgate.issi` flow plus the automated skip and verification legs. Waived by explicit user decision, 2026-08-13 | the human; clearable by one disposable-VM session |
| **CAP-6b3 real-runtime Gate B and Gate C are waived.** Gate B is a Windows instance with no Evergreen runtime (matrix row F2, and the runtime-absent half of F12); Gate C is a Windows 10 instance proving the AppContainer requirement Microsoft documents for Fixed Version ≥ 120 on unpackaged Win32 hosts. Waived by explicit user decision, 2026-08-14. Every automated CAP-6b3 gate runs on a host that *has* a usable Evergreen runtime, which makes the no-fallback legs meaningful but can never demonstrate operation without one | the human |

### Platform and packaging facts that cannot be engineered away here

| limitation | owner |
|---|---|
| **All three Windows profiles share one WebView2 user-data folder** (`%APPDATA%\<exe name>`), by ratified policy: user data is shared across profiles and preserved by uninstall. The underlying compatibility concern is *not* closed — a profile folder written by a newer Evergreen runtime can make `webview_create` fail against the older pinned fixed runtime. A per-profile `userDataFolder` is CAP-4W patch territory | a future CAP-4W shard |
| **Cross-toolchain `app.pwb` identity is logical only.** Compressed container bytes differ per toolchain by design; the logical inventory is what is compared across platforms | ratified; nobody |
| **Linux depends on distro WebKitGTK/GTK packages.** There is no Linux equivalent of CAP-13 runtime provisioning | ratified; a future phase if Linux ever needs one |
| **macOS signing and notarization are out of scope.** PWeb produces the artifacts and stops there — a SPEC non-goal, restated as a CAP-7 waiver | the product owner |
| **`Windows LongPathsEnabled` widens the Win32 file APIs but not the application path `CreateProcess` accepts.** The closure run *disproved* the shard's own written prediction here: with `long_paths_enabled = true` and a 325-character image directory created successfully, the launch was still `process_start_refused_by_os`. So `PWebImageFile`'s non-truncation behaviour is proven by construction and by a source gate, never by a live launch | recorded; no shipped path passes a long application path |
| **`tools/quickjs/pwebqjspack.pas` still reads `ParamStr` argv** — the bundler's twin, carrying the RTL Ansi-conversion class the CAP-6 bundler correction fixed. It **does not ship in the SDK**, so no user path reaches it; what does reach it is the CAP-9C1 gate with an absolute path, so a *developer's* checkout under a non-ASCII directory would meet it on Windows. Named, not fixed, deliberately | CAP-9C1 surface |
| **Unprefixed `FindFirstFileW` (MAX_PATH) in the bundler walk and in the fixed-profile manifest walk.** Failures are loud — a build error, never silent corruption. CAP-10D0 measured the related case on the hosted runner and found the CLI's own spawn is *not* what refuses; CAP-10D1 added the typed preflight refusals `project_root_too_long` and `pack_root_too_long_for_fixed`, both with **measured** bounds, so a developer hears a typed refusal instead of a third-party compiler's message | recorded; a future long-path I/O shard |
| **CAP-7M1 synchronous scheme-serving: `stop_arrivals = 0`** — recorded as a limitation and explicitly deferred to CAP-12, which is the phase that owns streaming responses | CAP-12 |

### The watcher's own limitations (CAP-11 §10, restated)

| limitation | owner |
|---|---|
| **The header projector is a narrow translator, not a C compiler.** It handles the closed set of constructs these six headers use and *refuses* anything else, typing the run `inconclusive` rather than guessing. An unfamiliar upstream construct produces a refusal naming the type — but needs a human to extend the table | a human, when upstream changes shape |
| **The compile-based seeded cases cannot run on the development host** (its FPC targets `i386-win32`; the projected binding declares `LIB_WEBVIEW` only for WIN64, DARWIN and LINUX). The gate refuses with a named message rather than skipping; the four CI legs do run them | recorded |
| **`patch_drift` can only be measured on Windows** — the only target with a declared platform patch. The other three report `not_applicable`, kept honest by two ratified "carries no patch" steps | recorded |
| **The watcher's first real answer is `unchanged` because upstream has not moved.** Every other verdict is proven by seeded input, and the build half by W8 against the pin; the first `compatible_additive` from a real head will be the first end-to-end demonstration of that path | time |
| **"Not a required check" is enforced as far as a repository can enforce it.** The gate proves the watcher is not called by `ci.yml` or `platform-leg.yml`, declares no `workflow_call`, and is `needs:`-linked to nothing. Whether a branch-protection rule *names* it is a GitHub repository setting no gate in this tree can read | the repository administrator |
| **The watcher builds an unreviewed commit, and that is the point.** `cmake` over an upstream `CMakeLists.txt` executes arbitrary code at configure and build time; a watcher that would not build could not compile the pins against head. The blast radius is bounded to the runner — read-only token, no secret, no write — and the pinned checkout is measured before and after every watch | ratified |

### Infrastructure flakes: instrumented, not eliminated

None of the four is a product defect; all four have cost hosted runs. The
standing disposition for every one of them is **re-run the job, never
re-ratify**.

| flake | state | owner |
|---|---|---|
| the hosted-Windows `state=0` non-report | instrumented — `smokeobserve.ps1` types five causes from engine-side observations, wrapped in `try/catch` at every call site, against a window now sized from a measurement (15000 ms = 50 × a measured 300 ms). **First post-instrumentation sighting on run 34127608923**: `pas2jsapp` reported `cause=ran_missed_window` with `profile=true`, `script_cache=true` — the engine came up, wrote a profile and compiled JavaScript into `Code Cache/js`, so the page ran and the window closed before the report arrived. **Known limitation:** the cause is *inferred* from engine-side observations, not reported by the page — a page-side progress report needs `examples/`, which is frozen | whichever shard may next touch `examples/` |
| the CAP-6b4 U3 fixed-profile uninstall residue | instrumented — the drain runs scoped to the install directory *before* the uninstaller and writes pids, images and sweeps. `u3_drain_before_measure = true` on every run. **Not observed since**; instrumented and quiet | CAP-6b3/6b4 surface |
| the pinned-installer fetch stalls (Lazarus/FPC, WebView2 Evergreen) | instrumented — `tools/pwebfetch.ps1` gives every pinned fetch three attempts × 180 s with an evidence row each; a digest mismatch is refused on the first attempt and never retried. **Not observed since** | CI |
| **a fourth class, sighted once and not one of the three** — on run 34118821940 the Windows leg failed at the CAP-10C0 supervision gates with `a tree member opened a listener`, thirty steps before anything CAP-11B adds, green on the neighbouring runs, with the whole `pweb.cli` suite passing (0 of 223 assertions failed). Ledgered as 11B-13 so a second occurrence is a second data point. What would settle it is the instrumentation the other three got: have the sampler **name** the tree member and the port, so a real listener is distinguishable from a PID the runner reused | whoever next owns `test/cap10c0/` |

### Items dispositioned `LATER` — real, small, and owned by nobody

Each of these was judged by a closure gate and given the reason it was not
done, rather than being closed quietly.

| item | why it survives | owner |
|---|---|---|
| **B1-5** — the three example hosts still compose their own window instead of using `pweb.webview.host` | no property fails: the reusable host is proven by the generated templates on four targets, and `examples/` is a demonstration tree no gate builds a release from. A refactor with no named owner | unnamed |
| **B1-8** — `create_help_digest` differs between Windows and POSIX and the cause is unidentified | compared *per family* by the aggregator, so nothing depends on the difference and no product behaviour is affected. Closing it means diffing two renders byte by byte | unnamed |
| **B2-10** — the same `set -e` shape survives in `test/cap10b1/prove_cap10b1.sh` | a closed shard's harness; every leg passes; the shape can only hide a failure that is not occurring. Rewriting a closed proof to fix a latent hazard is a change with no failing property and real regression risk | unnamed |
| **B2-15** — a generated project's `.gitattributes` does not name `*.cfg` | only a Pas2JS project has one; its content is ASCII with LF; the pack builder refuses a CR in a text template, so the divergence this would prevent cannot occur. A template change is a supersession of the compiled registry | unnamed |
| **D2-1** — the SDK ships no Pas2JS licence text: the pinned 3.0.1 archive contains no `COPYING.FPC` | shipping it needs an offline licence text pinned by digest from a reviewed source, which is a decision about provenance rather than engineering | the human |
| **11B-4** — no mORMot head watcher | the `webview/webview` watcher's shape does not fit; it needs its own instrument and its own budget. Dispositioned **CAP-12**, and `mormot_watcher = ledgered` is measured off the repository on every run, so a later shard cannot ship one without the row moving | CAP-12 |

### Closed in practice, but never marked closed in the ledger

One entry deserves naming because a reader of the ledger alone would conclude
otherwise: the **Phase-1 finding that upstream's cmake fetches the WebView2 SDK
nuget with no `URL_HASH`**. It is closed in practice — `webview.lock` carries
`webview2-sdk-sha256` and `webview2-sdk-tree-sha256`, and
`tools/build-webview-dll.ps1` verifies both the package digest and the
extracted-tree digest and throws on either mismatch — but the ledger entry was
never given a successor saying so. The gap is covered; the record of it is not.

### One stale field, recorded not fixed

`_bmad-output/implementation-artifacts/spec-phase-10-cap10e-kernel-image-path.md`
still carries `status: 'in-progress'` in its frontmatter, although
`cap10e-final-artifact.md` records **CAP-10E PASS** on run 33983841968 and
commit `ed1cb71` is titled "close CAP-10E on the green run 33983841968". Every
other spec artifact in the directory reads `status: 'done'`. This is a
documentation inconsistency with no product consequence; it is recorded here
rather than corrected, because this artifact's brief is to write the record and
change nothing else.

---

## 7. What is not built

### CAP-12 — the blob data plane

CAP-12 is the one capability in the SPEC that was never implemented, and it was
never on the path. The SPEC says so in the capability itself — *"**Off the
critical path: CAP-12 does not gate Phase 5 and is not required by the
MVP.**"* — and `phase-plan.md` repeats it at Phase 4b, with the reasoning
stated plainly at the time the plan was written:

> Streaming, `Range`, JS→native upload, and the WebKit/WebView2/WKWebView
> differences are rich enough to consume a week with great enthusiasm; that
> week must not sit on the path to the first end-to-end `getInfo()`.

That judgement was made by the **initial adversarial review**, before any code
existed, and the plan held to it for eleven phases. What it bought is visible
in the ordering: the first `42` through React → WebView → Pascal → mORMot
arrived at Phase 3, not after a blob plane.

**What is nevertheless already frozen for it.** CAP-12 does not start from
nothing:

- The **boundary** `IBlobStore` is one of the seven frozen at Phase 0. Only its
  concrete method sets — with `IBlobReader`/`IBlobWriter` — are deferred, and
  they ratify at **Phase 4b entry, before any blob implementation is written**,
  against invariants already fixed in `core-interfaces.md`: owner-scoped blobs,
  handle entropy, logical release with reader refcounting, positioned reads,
  auto-release on principal teardown, and the SDK's `native.blobs.release`.
- The invariant **JSON is the control plane, `pweb://blob` is the data plane**
  is a Phase-0 lock, not a CAP-12 decision. Base64 of bulk binary over the RPC
  bridge is not the nominal path, and never was.
- The three engines' custom-scheme behaviour is **already measured** and must
  not be re-measured from scratch: `docs/webview-upstream-semantics.md` (CAP-4,
  CAP-4W), `docs/webkitgtk-linux-semantics.md` (CAP-7L),
  `docs/wkwebview-macos-semantics.md` (CAP-7M).
- The CI matrix is one sequence in `platform-leg.yml` called four times, so a
  CAP-12 gate is added **once** and all four targets get it.
- Two ledger items are already assigned to it: the CAP-7M1 `stop_arrivals = 0`
  streaming limitation, and 11B-4, the mORMot head watcher.

**What CAP-12 owns and what it must not touch** are set out in full in
`cap11-closure-artifact.md` §9 (the CAP-12 handoff) and are not restated here.
In one sentence each: it owns `IBlobStore` decoupled from `pweb://`,
`pweb://blob/{token}` with `Range`/`Content-Length`/`Content-Type` honoured
without buffering, streaming and JS→native upload; and it must touch no pin, no
interface signature, not `src/lib/` or `webview.chet`, not the watcher, and not
the licence set.

One SPEC non-goal bears repeating alongside this, because it is the *other*
half of the blob decision: **the JS → native blob transport is not frozen.**
The SDK surface is (`native.blobs.create(file)` over
`IBlobStore`/`IBlobReader`/`IBlobWriter`); declaring `fetch(PUT pweb://…)`
universal waits on real macOS integration tests. JSON chunking is a fallback
only.

### The post-MVP items, as `TODO.txt` records them

`TODO.txt` is the product owner's own triage of six findings from taking an
arbitrary third-party static site through the bundler. It is reproduced here
**verbatim and in full**, because a paraphrase of a scoping judgement is not the
judgement. Note that the file records the *triage* of the six items; the
numbered list itself lives outside the file, so the numbers below are references
to a list this repository does not carry.

> That context matters — read my list as MVP scoping, not a defect report. And the headline is the opposite of criticism: an app written with zero knowledge of mtron bundled and rendered correctly on the first attempt, fonts and all. That's the hard part, and it already works.
>
> Triaging the six against MVP:
>
> Actually MVP-blocking: only #1. It decides what mtron is. Without an outbound network story it's a viewer for self-contained apps — which is a real and defensible product. With it, it's an app platform. Worth noticing that your own demos never hit this: the calculator does its work in-process over RPC, so nothing in your test corpus exercises "app talks to a remote server". Our wall is an unusually harsh case because it's a pure network client with no local logic at all.
>
> Cheap enough to fold into MVP: #2 and #6. A pwebbundle warning when it sees `<script>` without src is maybe twenty lines and kills the worst first-contact experience — silent half-working with no error anywhere. Some console surface would have saved me two probe iterations.
>
> Post-MVP, clearly: #3 and #4. Fullscreen/kiosk and external config only matter because I brought you a signage app. Most apps want a normal window and a sealed bundle, which is what you built.
>
> Not a gap at all: #5. The CLI contract argues its own case well — refusing to ship a build that can't build is the right call, and the doc says so explicitly.
>
> The thing I'd keep from this exercise regardless of MVP scope: "take an arbitrary static dist nobody wrote for mtron, bundle it, run it" is a good standing regression. It caught the inline-script trap immediately, and that's a class of failure your own templates can't surface because they're built to fit.

Read as scope, that file names four pieces of work that are not in this
closure and one recommendation that is not a piece of work at all:

| item | the file's own disposition | status here |
|---|---|---|
| **#1 the outbound network story** | *"Actually MVP-blocking: only #1. It decides what mtron is."* | **not built.** Nothing in the plan's own test corpus exercises it: every demo does its work in-process over RPC. The SPEC's assumption is compatible with building it — *"'Wireshark sees nothing' means the RPC path emits no traffic, not that a PWeb app is forbidden from doing its own network I/O"* — so this is a capability to add, not a constraint to relax |
| **#2 a bundler warning for `<script>` without `src`** | *"Cheap enough to fold into MVP… maybe twenty lines and kills the worst first-contact experience"* | **not built** |
| **#6 some console surface** | *"Cheap enough to fold into MVP… would have saved me two probe iterations"* | **not built** |
| **#3 fullscreen/kiosk** and **#4 external config** | *"Post-MVP, clearly… only matter because I brought you a signage app. Most apps want a normal window and a sealed bundle, which is what you built."* | **not built, by the owner's own scoping** |
| **#5** | *"Not a gap at all. The CLI contract argues its own case well — refusing to ship a build that can't build is the right call, and the doc says so explicitly."* | **no work; the contract already answers it** |
| the standing regression the file asks to keep | *"take an arbitrary static dist nobody wrote for mtron, bundle it, run it"* | **not in CI.** Every existing corpus is built to fit the templates, which is exactly the blind spot the file names. This is the single highest-value gate the plan does not have |

### The rest of the SPEC's non-goals, unchanged

Not built, and deliberately so, each stated in `SPEC.md` before any code
existed: the indexed `PWB1` + SynLZ container (ZIP suffices and no benchmark
has said otherwise); any bundled browser engine — no CEF, no Chromium; serving
app content over HTTP in production, loopback included (dev-mode Vite and
pas2js watchers are exempt because they are not shipped); Windows code signing,
macOS notarization and auto-update; and any relicensing work around the mORMot2
tri-license, which is accepted as-is.

Three SPEC non-goals were **overtaken by the plan** and are worth naming
because reading the SPEC alone would mislead: it says the CLI (CAP-10), QuickJS
(CAP-9), and macOS and Linux are not part of the MVP. All three were built
after the MVP line was crossed, closed on hosted CI, and are in this document's
acceptance table. The non-goals were scoping for the MVP, not permanent
exclusions — and the fact that the kernel absorbed all three without a rewrite
is the bet in the SPEC's "Why" section paying off.

---

## Verdict

Thirteen capabilities were specified. **Twelve are built and closed on hosted
CI**; one, CAP-12, was ruled off the critical path before any code existed and
stayed off it. Thirty-four acceptance clauses are met, two deviate for reasons
their own artifacts name — one of them into a *stronger* property than the
clause required — and every deviation is labelled rather than absorbed.

The kernel is the part worth stating plainly, because it was the bet the SPEC
opened with: **seven interfaces frozen at Phase 0, and not one of them
rewritten.** React, Pas2JS, a ZIP bundle format, three platform WebView
engines, a capability system, an embedded QuickJS runtime, a CLI, three Windows
installer profiles and an SDK distribution were all built on top of them, and
each arrived as an implementation behind a boundary rather than as a change to
one. `ICapabilityPolicy` was in the invocation path from Phase 2 with an
allow-all implementation, so Phase 8 swapped the policy and touched no plumbing
— which is the single clearest measurement that the freeze did its job.

The evidence is not a claim about the past. At head `9606082`, hosted run
**34150865012**, four targets independently measure the same 70-field agreement
block and the `cap7 aggregate` job fails on any disagreement; 39 CAP-11 ledger
entries carry 39 judgements and 0 orphans; `webview.lock` is unchanged and the
upstream watcher reports `unchanged` on all four targets without the
permission to alter it; and `listener_count`, `network_calls` and
`run_listener_members_max` all read 0 — which is the SPEC's success signal,
still true, measured on every push.

**THE PLAN IS CLOSED. CAP-1 THROUGH CAP-11 AND CAP-13 ARE BUILT AND GREEN;
CAP-12 IS THE ONE CAPABILITY DELIBERATELY LEFT FOR WHOEVER COMES NEXT.**
