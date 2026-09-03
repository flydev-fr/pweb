---
title: 'CAP-10C3 — public `pweb dev` for Pas2JS: CLI-owned change detection over the C1 assembly, and the CAP-10C closure'
type: 'feature'
created: '2026-09-03'
status: 'done'
baseline_commit: '36ef6881c818ad3aae3dfb000ba434cbc05c661e'
review_loop_iteration: 0
context:
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/docs/dev-contract.md'
  - '{project-root}/docs/pipeline-contract.md'
  - '{project-root}/docs/supervision-contract.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c0-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c1-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c2-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-10C2 shipped `pweb dev` as rebuild-and-reload behind
`pweb://app` and proved every property of it — the separate native-controlled
dev host, the immutable generation, the publish-by-rename, the forward-only
poller, the acknowledgement, the two-children ladder, the exit mapping — for
React only. `ui = pas2js` is refused with `dev_ui_unsupported`. The whole of
`docs/dev-contract.md` except its completion signal is frontend-agnostic, and
the one thing Pas2JS does not have is Vite's `writeBundle`: the compiler has
no watch mode and the CAP-10C1 assembly runs in the CLI rather than in the
build. Nothing decides *when* to rebuild. CAP-10C also has no closure: four
shards of evidence, four sets of supersessions and 54 ledger entries sit
unconsolidated, and CAP-10D has no handoff.

**Approach:** Give the CLI the detection Pas2JS cannot give it — one bounded
poll over a ratified input set, fingerprinted by **content** — and run the
C2 loop underneath it with the C1 Pas2JS plan and the C1 assembly, both
unchanged. A generation is `pas2js` → assembly → frozen bundler →
`<dev>/gen-N/app.pwb` → publish-by-rename → the C2 poller → navigate → 42.
No WebSocket, no listener, no proxy, no CSP change, no platform watch API,
and no change to the C2 host, seam, generation rule, poller or ladder. Then
close CAP-10C: one closure artifact citing the four hosted green runs and
every supersession, the final `docs/cli-contract.md` §5 wording, a disposition
for every C0/C1/C2 ledger entry under a gate that refuses an orphan, and the
CAP-10D handoff. `pweb build` stays an unknown command.

## Boundaries & Constraints

**Always:**
- **One privileged origin, one CSP.** `pweb://app` is the only origin ever
  navigated, dev and production alike; `PWEB_NATIVE_CSP` is byte-identical in
  the Pas2JS dev binary and the Pas2JS release binary; no `ws://`, `wss://`,
  `localhost` or `127.0.0.1` string exists anywhere in this shard's source.
- **One execution path.** `pas2js`, `pwebbundle`, `fpc` and the dev host all
  go through `PWebCliExecute` in the `pepSupervise` profile — exact path,
  argument vector, explicit working directory, no shell, no environment
  injection, and `pweb.cli.dev` stays the only unit of the dev loop that runs
  a child.
- **Detection is CLI-owned, bounded and content-based.** One walk of the
  ratified input set every `PWEB_CLI_DEV_POLL_MS`; the fingerprint is a
  digest of sorted `path|size|sha256(content)` lines; every bound is a named
  constant cross-checked against the contract; nothing outside the project
  root is walked or read.
- **Only a generation whose inputs were stable across compile + assembly is
  packed.** The fingerprint is taken before the compile and re-taken after
  the assembly; a moved one discards and rebuilds, bounded by the C2
  `PWEB_CLI_DEV_SNAPSHOT_TRIES`.
- **The C1 Pas2JS plan and assembly are called, never re-implemented.**
  `PWebCliPas2jsCommand` and `PWebCliAssemblePas2jsDist` are used verbatim,
  which is what makes generation 1's `app.pwb` byte-identical to the
  pipeline's for the same sources.
- **A generation is immutable and published by one rename**, and the C2
  layout, numbering, reclaim, cleanup, poller and acknowledgement are used
  unchanged.
- **The C1 project-mutation set is unchanged**; a Pas2JS session writes only
  under `<output>/`, and the read-only half of the tree is digested and must
  be unchanged.
- **No platform file-watch API anywhere**, and no `{$ifdef}` outside
  `pweb.cli.platform` and the ratified platform units.
- **Nothing printed names an absolute path**, the SDK, a home directory or
  the environment, and no ANSI reaches a redirected stream — including ANSI a
  compiler emitted.
- **Every C0/C1/C2 ledger entry gets a disposition**, and a committed gate
  refuses an orphan rather than a reviewer noticing one.

**Ask First:**
- Any change to `pweb.json` schema 1, the CAP-10A parser grammar or doctor
  rows, the B0 engine, the C0 engine, `pweb run`, the run layout, the C1 ten
  stages or bounds, or the C2 host, seam, generation rule, poller or ladder.
- Any change to `PWEB_NATIVE_CSP`, the privileged origin, the CAP-8
  classifier, the CAP-9 shutdown order, the platform adapters or any pin.
- Adding any allowance — `ws://`, `localhost`, a proxy, a listener — for any
  reason, temporary or otherwise.
- Superseding the Pas2JS template, or re-baselining any frozen digest this
  spec did not plan to move.
- Exposing `pweb build`, or beginning any part of CAP-10D, CAP-11 or CAP-12.

**Never:**
- Expose `build`; start a listener, a dev server, a proxy or an HMR
  transport; proxy anything through the host.
- Add file-watch code to the host or to the production runtime, or a
  platform watch API (`ReadDirectoryChangesW`, `inotify`, `FSEvents`,
  `kqueue`) anywhere at all.
- Watch or read anything outside the project root, or follow a symlink or
  reparse point inside the input set.
- Publish a generation whose inputs moved during the compile or the
  assembly, or write into a published generation.
- Write into `<output>/<os>-<arch>/release/`, or let `pweb run` resolve
  anything under `dev/`.
- Let any frontend file select a security policy, a CSP, an origin or a mode.
- Delete the `dev_ui_unsupported` path: it stays in the code, and under test,
  for the next UI kind.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| PD1 first generation | `pweb dev`, unrelated CWD, Pas2JS project | gen 1 packed before the host starts, host on `pweb://app`, secure context, `Add(20,22)` = 42, listener members 0, network calls 0 | N/A |
| PD2 source edit | `frontend/src/app.pas` gains a marker | gen 2 published and loaded, marker rendered, 42 again, **host pid unchanged** | N/A |
| PD3 style edit | `frontend/app.css` edited | next generation applies it (`--pweb-styled` still read back from the applied sheet) | N/A |
| PD4 markup edit | `frontend/index.html` edited | next generation applies it | N/A |
| PD5 compile error | `app.pas` made invalid | compiler output forwarded (ANSI stripped, `pas2js: ` prefix), **previous generation stays live**, host alive; on fix the next generation publishes | never stops the host, never publishes |
| PD6 rapid edits | five edits, each faster than one generation | generations strictly monotonic, no partial publish, the page's own arithmetic is the **last** edit's | debounced, bounded |
| PD7 edit during compile | the input set is rewritten while a compile is in flight | the generation is discarded and rebuilt, and the loop says so; a later quiet window publishes the correct content | bounded by `PWEB_CLI_DEV_SNAPSHOT_TRIES`, then reported and abandoned |
| PD8 outside the input set | `src/app.services.pas` (native) or `README.md` edited | **no rebuild**, no generation | N/A |
| PD9 symlink in the input set | a link under `frontend/src` | refused `dev_input_link`, exit 3, nothing started | typed, fail-closed |
| PD10 input-set bounds | more than `PWEB_CLI_DEV_MAX_INPUT_FILES` files under `frontend/src` | refused `dev_input_bound`, exit 3, **before the first compile** | typed |
| PD11 interrupt | Ctrl+C / `SIGINT` / `SIGTERM`, possibly mid-rebuild | the whole set stops inside the C0 bounds, descendants 0, exit 0, no partial generation | a `.gen.tmp` left behind is removed at next start |
| PD12 host dies | dev host killed externally | loop stops, **exit 5**, real typed status, descendants 0, nothing left behind (the detector is a CLI thread, not a child) | N/A |
| PD13 release untouched | `release/` tree digest before and after a Pas2JS dev session | identical | N/A |
| PD14 assembly parity | gen 1's `app.pwb` vs the C1 pipeline's Pas2JS `app.pwb` for the same sources | byte-identical | N/A |
| PD15 output | both streams redirected | no ANSI; one exact line per generation, `pweb: generation N ready (<ms>)` | N/A |
| RD1 React regression | the whole CAP-10C2 suite and gates | green, `dev_digest` unchanged or the supersession recorded | N/A |
| T1 CSP | the Pas2JS dev host and the Pas2JS release host | `PWEB_NATIVE_CSP` bytes identical | N/A |
| T2 release trust | the Pas2JS release binary + its compiled unit set | dev unit absent, dev marker absent | N/A |
| T3 no allowance | every source file of the shard, and every CSP profile | no `ws://`, `wss://`, `localhost`, `127.0.0.1` | N/A |
| T4 no loose assets | the Pas2JS dev host at runtime | `loose_assets_used` = false — every generation is one `app.pwb` | N/A |
| T5 dev trust wording | `docs/cli-contract.md` §5 | `check_dev_trust.ps1` pins the final wording: both UIs rebuild-and-reload, the `ws://` allowance ratified, unused, pinned absent | N/A |
| PU1 refusal retained | `PWebCliDevUiSupported` over an unratified UI ordinal | false ⇒ `dev_ui_unsupported`, exit 3 | typed |
| CL1 closure | the closure artifact | cites four hosted green runs and every supersession | N/A |
| CL2 ledger | every C0/C1/C2 deferred entry | has exactly one disposition; **no orphan** | gate fails naming the entry |
| CL3 handoff | the closure artifact and `docs/index.md` | the CAP-10D handoff is present and every contract document is cross-linked | N/A |

</frozen-after-approval>

## Code Map

**Authorities (cite, never re-narrate):** `docs/dev-contract.md` (all of it;
§12 names what C3 owns), `docs/pipeline-contract.md` §3 "The Pas2JS
assembly", `docs/cli-contract.md` §1 §4 §5, `docs/supervision-contract.md`,
`_bmad-output/implementation-artifacts/cap10c{0,1,2}-final-artifact.md`,
`cap10c2-model-a-spike.md`.

**Reused verbatim — call, never copy:**
- `tools/pweb/pweb.cli.frontend.pas:297` `PWebCliPas2jsCommand` — the C1
  argv: `@<cfg>`, `-Fu<sdk pas2js>`, `-o<out.js>`, `<src>/<ident>app.lpr`,
  workdir `<frontend>`.
- `tools/pweb/pweb.cli.frontend.pas:387` `PWebCliAssemblePas2jsDist` — strip
  BOM, strip **every** CR, `assets/boot.js` = `rtl.run();\n` byte-exact,
  `index.html` and `assets/app.css` placed.
- `tools/pweb/pweb.cli.devlayout.pas` — `PWebCliDevEnsureLayout`,
  `DevStageApp`, `BeginGeneration`, `DiscardGeneration`, `TrimGeneration`,
  `PublishGeneration`, `TmpBundle`, `CleanGenerations`, `ResetGenerations`.
  **Unchanged**; only `SnapshotDist` (React's dist copy) goes unused for
  Pas2JS, because the compiler writes straight into `.gen.tmp/dist`.
- `tools/pweb/pweb.cli.pack.pas` `PWebCliPackCommand`; `pweb.cli.native.pas`
  `PWebCliFpcDevCommand`; `pweb.cli.toolset.pas:436` (pas2js resolved for
  `puiPas2js` only, no Node at any point); `pweb.cli.sdkroot.pas:348`
  (`PWebCliSdkLayout(..., Pas2js=True)` requires `sdk/pas2js/pweb.native.pas`).
- `src/webview/pweb.webview.devhost.pas` and `pweb.webview.host.pas` —
  **read-only**. The host is already frontend-agnostic: it opens
  `gen-N/app.pwb`, polls forward, swaps the store and re-navigates.
- `tools/templates/pas2js/src/program.lpr:60-70,116-124` — the `PWEB_DEV`
  region is **already there** (CAP-10C2 put it in both templates). The
  template needs no change; the Pas2JS inventory does not move.

**Production changes:**
- `tools/pweb/pweb.cli.toolchain.pas:166-256` — five new bounds beside the
  C2 block, same comment discipline.
- `tools/pweb/pweb.cli.devinputs.pas` — **NEW**: the input set, the bounded
  walk, the content fingerprint, the typed refusals. Pure plan + file
  operations; no spawn, no environment read, no platform conditional, so any
  single target can assert the whole rule (the C1/C2 property, kept).
- `tools/pweb/pweb.cli.dev.pas` — the Pas2JS branch: `PWebCliDevUiSupported`,
  the skipped React-only stages, no watcher thread, the detector loop,
  `MakePas2jsGeneration`, `NetworkStages = none`.
- `tools/pweb/pweb.cli.report.pas:116` (`PWebCliUsageBanner`) and `:265`
  (`PWebCliDevHelp`) — both UIs advertised.

**Test surface (read for shape, then mirror):**
- `test/cap10c2/build_cap10c2.{ps1,sh}` — isolation compiles, suite+driver,
  the two host binaries from one **real** scaffolded project.
- `test/cap10c2/pwebdevdrv.pas` — the driver: one supervised `pweb dev`,
  every state change inside the engine's own `StopCheck`, three scenarios,
  a key=value report with no absolute path.
- `test/cap10c2/run_cap10c2_gates.ps1:302` — projects scaffolded by the real
  CLI on this job, never borrowed from another shard's stage.
- `test/cap10c1/listener_members.ps1` — the membership-scoped sampler,
  dot-sourced.
- `test/cap7f/check_cap7f_aggregate.ps1:98-530` (required / absolute pins /
  must-PASS / equality lists) and `check_cap7f_selftest.ps1` (a negative leg
  per new refusal, red on a fixture before the real aggregation is trusted).
- `test/cap10a/check_dev_trust.ps1:150-260` — section 5 is where the final
  §5 wording and the Pas2JS template region get pinned.

**Read-only evidence already verified in the repository:**
- CAP-10C2 PASS, hosted run **33751306417** green on the C2 closure HEAD
  `36ef6881c818ad3aae3dfb000ba434cbc05c661e` (and 33748442256 on `765d5d0`).
- The adapter `Cache-Control: no-store` change (`cef3691`) touched no digest
  expectation anywhere: `git show --stat` lists two adapters, the C2 gates and
  the dev loop, and **no** gate digests those adapter sources — so nothing was
  claimed unchanged. It is recorded in `deferred-work.md:657` with the human
  ratification and pinned in source by `check_cap10c2_contracts.ps1` §9.
- `deferred-work.md` carries **13** CAP-10C0, **16** CAP-10C1 and **25**
  CAP-10C2 entries (lines 506-667) — 54 dispositions to write.

## Tasks & Acceptance

**Execution:**
- [x] `tools/pweb/pweb.cli.toolchain.pas` -- add `PWEB_CLI_DEV_POLL_MS`,
  `_MAX_INPUT_FILES`, `_MAX_INPUT_DEPTH`, `_INPUT_FILE_MAX`,
  `_INPUT_PATH_MAX` -- every bound named once, cross-checked by the gate.
- [x] `tools/pweb/pweb.cli.devinputs.pas` -- NEW -- the ratified input set,
  the bounded content-fingerprint walk, `dev_input_link` /
  `dev_input_bound` / `dev_input_unreadable`.
- [x] `tools/pweb/pweb.cli.dev.pas` -- accept `ui = pas2js`: skip
  `stage_sdk`/`install`/`typecheck`, run no watcher child, drive the loop
  from the fingerprint, build a generation with the C1 plan + assembly, keep
  the previous generation live on a compile error, and keep
  `PWebCliDevUiSupported` as the one refusal predicate.
- [x] `tools/pweb/pweb.cli.report.pas` -- `pweb --help` and `pweb dev --help`
  advertise both UIs and what each start-up runs.
- [x] `docs/dev-contract.md` -- the Pas2JS half: detection, the stage table's
  second column, the one-member supervised set, the new bounds, and §12
  replaced by what CAP-10D inherits.
- [x] `docs/cli-contract.md` -- §1 and §5 final wording.
- [x] `docs/index.md` -- cross-link every contract document.
- [x] `test/cap10c3/build_cap10c3.{ps1,sh}` -- isolation compiles, the suite,
  the driver, and the Pas2JS release + dev host binaries from one real
  scaffolded project.
- [x] `test/cap10c3/pweb.test.devpas2js.pas` + `c3tests.pas` -- the headless
  suite and its corpus: the four-target pas2js dev argv table, the input-set
  rule, the fingerprint's content-sensitivity and mtime-insensitivity, the
  bounds and the link refusal, the consistency rule, `DevUiSupported` over an
  unratified ordinal.
- [x] `test/cap10c3/pwebp2jdrv.pas` -- the driver: PD1-PD8 and PD11 in the
  `loop` scenario, PD12 in `killhost`.
- [x] `test/cap10c3/check_cap10c3_contracts.ps1` -- bounds vs contract, the
  help texts, the refusal retained in source, no transport literal, no
  platform watch API anywhere, CSP identical across the Pas2JS pair, the
  Pas2JS release unit set dev-free.
- [x] `test/cap10c3/check_cap10c_ledger.ps1` -- CL2: every C0/C1/C2 ledger
  entry has exactly one disposition in the closure artifact; an orphan, a
  count drift or an edited summary is a failure.
- [x] `test/cap10c3/run_cap10c3_gates.ps1` -- PD/RD/T/PU/CL, emitting
  `build/cap10c3/cli-<target>.json`.
- [x] `test/cap10a/check_dev_trust.ps1` -- pin the final §5 wording and the
  Pas2JS template's `PWEB_DEV` region.
- [x] `test/cap7f/check_cap7f_aggregate.ps1` + `check_cap7f_selftest.ps1` --
  the C3 fields, pins, must-PASS and equality rows, each with a negative leg.
- [x] `.github/workflows/ci.yml` -- a CAP-10C3 block in each of the four
  native jobs, after the C2 block, plus the corpus artifact.
- [x] `_bmad-output/implementation-artifacts/cap10c-closure-artifact.md` --
  the four green runs, the consolidated supersessions, the 54-row disposition
  table, the CAP-10D handoff.
- [x] `_bmad-output/implementation-artifacts/cap10c3-final-artifact.md` --
  the shard's own closure.

**Acceptance Criteria:**
- Given a real generated Pas2JS project on any of the four targets, when
  `pweb dev` runs from an unrelated working directory, then generation 1 is
  packed before the host starts, the window opens on `pweb://app`, the page
  reports `secure: true` and `42`, and every later source, style or markup
  edit publishes exactly one further generation the host loads **without the
  process restarting**.
- Given a compile error, when the loop runs, then the compiler's output is
  forwarded, the previous generation stays live, the host stays alive, and a
  fix publishes the next generation.
- Given an edit that lands during a compile, when the generation is
  assembled, then it is discarded and rebuilt, and no generation whose inputs
  moved is ever published.
- Given the same sources, when generation 1 is packed, then its `app.pwb` is
  byte-identical to the CAP-10C1 pipeline's Pas2JS `app.pwb`.
- Given a Pas2JS dev session, when it ends by interrupt or by an externally
  killed host, then the exit is 0 or 5 respectively, descendants are 0, and
  no partial generation survives.
- Given the shipped executable, when `pweb --help` and `pweb dev --help` are
  read, then both UIs are advertised and `pweb build` still answers
  `unknown_command` with exit 2.
- Given the CAP-10C closure artifact, when the ledger gate runs, then every
  CAP-10C0/C1/C2 deferred entry carries exactly one disposition and the
  aggregate reports `cap10c_ledger_orphans = 0`.
- Given the final HEAD, when hosted CI runs, then all six jobs are green and
  the `cap7 aggregate` agrees field-by-field on four targets.

## Design Notes

**Why polling, and why the fingerprint is content rather than `(size,
mtime)`.** Three native watch APIs would be three bodies in
`pweb.cli.platform`, three semantics (`ReadDirectoryChangesW` buffer
overflow, `inotify` watch-descriptor exhaustion, the FSEvents/kqueue split)
and three ways for one loop to behave differently on four targets — for a
five-file input set. Polling is one body, no allowlist growth, and provably
identical everywhere. Within polling, `(path, size, mtime)` is the obvious
fingerprint and the wrong one: FPC's portable timestamp layer is
second-granular, so two edits inside one second that leave the length alone
are one fingerprint, and the detector silently stops detecting — which is
adversarial question 4 answered by "it can". Hashing the bytes costs a few
kilobytes of reads four times a second, is immune to both, and adds a
property worth having on its own: a `touch` or a `git checkout` that changes
no byte costs no generation.

**Why the compiler writes straight into `.gen.tmp/dist`.** React needs a copy
because `vite --watch` owns `frontend/dist` and may be writing it; that is
what `PWebCliDevSnapshotDist` and the C2 snapshot proof exist for. Pas2JS has
no concurrent writer, so the generation under construction *is* the output
directory, and the consistency question moves from "did `dist` move while I
copied it" to "did the *inputs* move while I compiled and assembled" — which
is the same proof over the correct subject.

**The supervised set has one long-lived member for Pas2JS.** There is no
watcher child to supervise, so the watcher slot is empty; the stop flag, the
`DevStopCheck`, the C0 ladder, the join, the drain and the exit categories
are the same code reached with one member instead of two. That is not a
change to the ladder — `docs/dev-contract.md` §7 gets a sentence, not a new
mechanism.

Generation shape, per generation, in order:

```
BeginGeneration              -> <dev>/.gen.tmp/dist[/assets]
fingerprint(before)
pas2js  @cfg -Fu<sdk> -o<tmp>/dist/assets/app.js  <src>/<ident>app.lpr
AssemblePas2jsDist(frontend, <tmp>/dist)          -- C1, unchanged
fingerprint(after) <> before  -> Discard, retry   -- bounded by TRIES
pwebbundle <tmp>/dist <tmp>/app.pwb               -- frozen CAP-6
TrimGeneration -> PublishGeneration(N)            -- ONE rename
```

**The ledger gate's key.** Each C0/C1/C2 entry is keyed
`<shard>-<ordinal>` plus the first eight hex of the SHA-256 of its `summary:`
line. The closure table carries both, so an orphan, a count drift and a
silently reworded entry are three distinct failures with three distinct
messages — and the ledger's append-only rule keeps the ordinals stable.

## Verification

**Commands:**
- `wsl -e bash -lc 'cd <repo> && test/cap10c3/build_cap10c3.sh'` -- expected:
  suite, driver and both host binaries built; the Pas2JS **release** unit set
  carries no `pweb.webview.devhost.ppu`. Run **before** any push: the POSIX
  leg is where CAP-10C2 spent three hosted runs.
- `pwsh test/cap10c3/check_cap10c3_contracts.ps1` -- expected: PASS; every
  bound agrees with `docs/dev-contract.md`, no transport literal, no watch
  API, CSP identical.
- `pwsh test/cap10c3/run_cap10c3_gates.ps1` -- expected: PASS on the running
  target, `build/cap10c3/cli-<target>.json` written.
- `pwsh test/cap10c3/check_cap10c_ledger.ps1` -- expected: 54 entries, 0
  orphans.
- `pwsh test/cap10c2/run_cap10c2_gates.ps1`, `pwsh
  test/cap10c1/run_cap10c1_gates.ps1`, `pwsh test/cap10c0/...`,
  `test/cap10b{0,1,2}`, `test/cap10a`, `test/cap6b{3,4}`, `test/cap7f` --
  expected: all green (RD1 and the regression set), run in full and not as a
  subset.
- `pwsh test/cap7f/check_cap7f_selftest.ps1` and `check_cap7f_aggregate.ps1`
  over downloaded evidence -- expected: every new refusal red on its fixture,
  then the real aggregation green.

**Manual checks (if no CLI):**
- `gh run view <id>` on the final HEAD: six jobs green, `cap7 aggregate`
  PASS, one `dev_pas2js_digest` equal on four targets, `dev_digest` and
  `pipeline_digest` re-measured unchanged.
