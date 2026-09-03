---
title: 'CAP-10C2 — public `pweb dev` for React: rebuild-and-reload behind pweb://app, over the C1 pipeline and the C0 engine'
type: 'feature'
created: '2026-09-03'
status: 'in-progress'
baseline_commit: '94694bcaf17ba6fdcab29875f66e3b9a1d6cad42'
review_loop_iteration: 0
context:
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/docs/supervision-contract.md'
  - '{project-root}/docs/pipeline-contract.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c0-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c1-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-10C1 froze a private pipeline that takes a generated project
to the CAP-10C0 run layout, and CAP-10C0 froze the engine that supervises what
it produced — but a developer still has no loop: editing `App.tsx` means
re-running a whole build by hand and relaunching the application, and `dev` is
an unknown command. The decision ratified since CAP-10A and never implemented
— that the privileged origin is `pweb://app` in development and in production
alike — has no code behind it.

**Approach:** Expose `pweb dev [--project <path>]` for `ui = react`. It runs
the C1 prerequisites (toolchain, SDK staging, conditional `npm ci`, one
`tsc`), compiles a **separate native-controlled DEV host** into
`<output>/<os>-<arch>/dev/`, supervises `vite build --watch` and the dev host
concurrently through the one C0 engine, and on every completed rebuild packs
an immutable **generation** with the frozen CAP-6 bundler and publishes it by
one directory rename. The running host swaps its asset store and re-navigates
to `pweb://app` — no restart, no listener, no proxy, no CSP change, no folder
store. `ui = pas2js` is refused with a typed cause until CAP-10C3; `build`
stays an unknown command.

## Boundaries & Constraints

**Always:**
- **One privileged origin, one CSP.** `pweb://app` is the only origin ever
  navigated, dev and production alike; `PWEB_NATIVE_CSP` is byte-identical in
  both binaries and gains nothing; no `ws://`, `wss://`, `localhost` or
  `127.0.0.1` string exists anywhere in this shard's source.
- **One execution path.** `npm`, `tsc`, `vite`, `pwebbundle`, `fpc` and the
  dev host all go through `PWebCliExecute` in the `pepSupervise` profile —
  exact path, argument vector, explicit working directory, no shell, no
  environment injection.
- **The dev host is a different binary**, compiled `-dPWEB_DEV` into
  `<output>/<os>-<arch>/dev/` with its own unit and object directories, and it
  refuses to start without the dev-root argument. The release binary is
  measured dev-free.
- **It serves only what the frozen bundler packed**: every generation is one
  `pwebbundle` `app.pwb` opened through `PWebBundleLoadFile`, so
  `loose_assets_used` is false in dev too.
- **A generation is immutable and published by one rename** — assembled in
  `<dev>/.gen.tmp`, renamed to `<dev>/gen-N` by `PWebCliRenameDir`, which must
  not replace. Nothing writes into a published generation.
- **The C1 project-mutation set is unchanged**; everything the loop writes is
  already inside it, and the read-only half is digested and must be unchanged.
- **No `{$ifdef}` outside `pweb.cli.platform`** and the ratified platform
  units; every new directive is re-ratified in the CAP-7F sweep.
- **Every new bound is a named constant** cross-checked by the contract gate.
- **Nothing printed names an absolute path**, the SDK, a home directory or the
  environment, and no ANSI reaches a redirected stream — including ANSI a
  child emitted.

**Ask First:**
- Any change to `pweb.json` schema 1, the CAP-10A parser grammar or doctor
  rows, the B0 engine, the C0 engine, `pweb run`, the run layout or the exit
  mapping beyond the additions this spec ratifies.
- Any change to `PWEB_NATIVE_CSP`, the privileged origin, the CAP-8 classifier
  or the CAP-9 shutdown order.
- Adding any allowance — `ws://`, `localhost`, a proxy, a listener — for any
  reason, temporary or otherwise.
- Re-baselining a frozen digest this shard did not plan to move, or moving a
  template beyond the ratified `vite.config.ts` supersession.
- Exposing `pweb build`, or implementing any part of Pas2JS development.

**Never:**
- Expose `build`; start a listener, a dev server, a proxy or an HMR transport;
  proxy HTTP through the host.
- Make the **production** host accept a dev argument, path or environment
  variable, link the dev unit, add a folder-served asset path or a watcher.
- Write into `<output>/<os>-<arch>/release/`, or let `pweb run` resolve
  anything under `dev/`.
- Let any frontend file select a security policy, a CSP, an origin or a mode.
- Publish a generation packed from a `dist/` the watcher may have been
  writing; inject JavaScript or call `location.reload()` to switch one.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| DEV1 first generation | `pweb dev`, unrelated CWD, React project | gen 1 packed, host on `pweb://app`, secure context, `Add(20,22)` = 42, `listener_members_max` = 0 | N/A |
| DEV2 source edit | `App.tsx` gains a marker | gen 2 published, marker rendered, 42 again, **host pid unchanged** | N/A |
| DEV3 style edit | `app.css` edited | next generation applies it (`--pweb-styled` still read back) | N/A |
| DEV4 broken rebuild | `App.tsx` made invalid | error forwarded (ANSI stripped), **previous generation stays live**, host alive; on fix the next generation publishes | never stops the host, never publishes |
| DEV5 rapid edits | five edits inside 250 ms | generations monotonic, no partial publish, final content correct | debounced; a snapshot invalidated mid-copy is retaken |
| DEV6 interrupt | Ctrl+C / `SIGINT` / `SIGTERM`, possibly mid-rebuild | whole set stops inside the C0 bounds, descendants 0, exit 0, no partial generation | a `.gen.tmp` left behind is removed at next start |
| DEV7 host dies | dev host killed externally | loop stops, **exit 5**, real typed status, watcher reaped, descendants 0 | N/A |
| DEV8 watcher dies | `vite --watch` killed externally | loop stops, **exit 5**, real typed status, host stopped through the ladder | N/A |
| DEV9 no dev root | dev binary run with no `--pweb-dev-root=`, an `app.pwb` beside it | refuses, exits nonzero, **never loads the beside-exe bundle** | fail-closed |
| DEV10 release untouched | `release/` tree digest before and after a dev session | identical | N/A |
| DEV11 pas2js | `pweb dev` on `ui = pas2js` | refused `dev_ui_unsupported`, exit 3, **nothing started, nothing written** | typed |
| DEV12 parsing | duplicate `--project`, `--json`, a positional, `--help` | existing causes, exit 2; `--help` advertises React only | typed |
| DEV13 output | both streams redirected | no ANSI, one exact line per generation: `pweb: generation N ready (<ms>)` | N/A |
| DEV14 network | second run, `node_modules` present, lockfile digest unchanged | **no `npm ci`**; `network_stages` = `none` | a changed lockfile, absent `node_modules` or a missing `vite`/`tsc` entry point re-runs it |
| T1 CSP | both host binaries | `PWEB_NATIVE_CSP` bytes identical | N/A |
| T2 release trust | release binary + its compiled unit set | dev unit absent, dev marker absent, `--pweb-dev-root=` refused | N/A |
| T3 no allowance | every source file of the shard | no `ws://`, `wss://`, `localhost`, `127.0.0.1` literal | N/A |
| T4 no loose assets | dev host at runtime | `loose_assets_used` = false | N/A |
| T5 one origin | every navigation the dev host performs | `pweb://app`, nothing else | N/A |

</frozen-after-approval>

## Code Map

**Authorities (cite, never re-narrate):** `docs/cli-contract.md` §1, §5, §7;
`docs/supervision-contract.md` §1–§8; `docs/pipeline-contract.md` §2–§9.

**Production surface to change**

- `tools/pweb/pweb.pas` — `uses` (`cthreads` on Unix, the dev unit, the
  pipeline units), `--help`, the `dev` dispatch, the exit mapping. Its unit
  list is measured by `check_cap10c1_contracts.ps1` (`pipeline_units_linked`),
  which must be re-based `false` → `true` with the reason recorded.
- `tools/pweb/pweb.cli.args.pas:44` `TPWebCliCommand` — add `pccDev`;
  `PWebCliParseArgs` accepts `dev` with `--project` and `--help` only.
- `tools/pweb/pweb.cli.dev.pas` **(new)** — the loop: prerequisites, the
  watcher, the generation machine, the two supervisor threads, the stop
  ladder, the notify sink.
- `tools/pweb/pweb.cli.devlayout.pas` **(new)** — `<output>/<os>-<arch>/dev/`:
  `app/`, `units/`, `obj/`, `gen-N/`, `.gen.tmp/`. Pure plan plus file
  operations over `PWebCliInfoPlist`, `PWebCliPipeCopyFile`,
  `PWebCliPipeEnsureDir`, `PWebCliPipeCopyTree`, `PWebCliPipeRemoveTree`,
  `PWebCliRenameDir`.
- `tools/pweb/pweb.cli.native.pas:110` — additive `PWebCliFpcDevCommand` over
  a shared private builder. **The release function's signature and output must
  not change**; `pipeline_digest` re-measured unchanged proves it.
- `tools/pweb/pweb.cli.toolchain.pas` — additive `PWEB_CLI_DEV_*` bounds.
- `src/webview/pweb.webview.host.pas` — the seam and only the seam:
  `TPWebHostOptions` (149–168) gains `ConsumedArgs`;
  `PWebHostParseArguments` (643) skips a declared-consumed argv string;
  `PWebHostRun` (734) gains a `const Store: IAssetStore` overload (nil ⇒
  `PWebHostLoadBundle`, 614); `PWebHostRequestReload` **(new)** mirrors
  `PWebHostTerminate` (361) with `webview_navigate`.
- `src/webview/pweb.webview.devhost.pas` **(new, dev-only)** — the swapping
  store, the `--pweb-dev-root=` parse and refusal, the poller, the reload, the
  one ratified `generation <N> loaded` line.
- `tools/templates/react/frontend/vite.config.ts` — the `writeBundle` sentinel
  (**template supersession**).

**Read-only — frozen, and why each matters here**

- `src/security/pweb.navigation.policy.pas:132` `PWEB_NATIVE_CSP`, 362
  `PWebNativeSecurityHeaders`.
- `src/assets/pweb.assets.intf.pas` `IAssetStore` (the swapping store is an
  implementation; the interface gains nothing); `pweb.assets.zip.pas`
  `TZipAssetStore` (its `fLock` is the discipline to copy);
  `pweb.assets.bundle.pas:921` `PWebBundleLoadFile`;
  `pweb.assets.support.pas` `PWebParseAppUri` / `PWebAssetPathValid` /
  `PWebAssetMimeType` — the rules the model-A spike is judged against.
- `tools/pweb/pweb.cli.pack.pas:52` — the whole bundler argument contract.
- `tools/pweb/pweb.cli.process.pas:711` `PWebCliExecute` is **re-entrant**: no
  unit-level mutable state; the Windows spawn restricts inheritance with
  `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`; the POSIX spawn
  (`pweb.cli.platform.pas:2570`) touches no heap between `fork` and `execve`
  and closes every descriptor above 2 — which is what makes two concurrent
  supervised children legal without touching the engine.
- `tools/pweb/pweb.cli.run.pas` `PWEB_CLI_RUN_RELEASE = 'release'` — why
  `pweb run` can never resolve a dev layout;
  `pweb.cli.pipeline.pas:233` `PWebCliMutationSet`.

**Tests and CI to extend**

- `test/cap10a/check_dev_trust.ps1` — pin the C2 decision.
- `test/cap10c0/pwebchild.pas:351` `ctrlbreak` and
  `test/cap10c0/pweb.test.supervise.pas:1462` `DrivePweb`
  (`SeparateConsole := True`) — the ratified Windows console-interrupt
  mechanism the C2 driver reuses.
- `test/cap10c1/listener_members.ps1` — dot-sourced membership sampler.
- `test/cap10c1/{run_cap10c1_gates,check_cap10c1_contracts,build_cap10c1}.*` —
  the shapes the C2 equivalents follow.
- `test/cap7f/check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1`,
  `emit_evidence.{ps1,sh}`.
- `.github/workflows/ci.yml` — the CAP-10C1 blocks at 2021–2059 (windows) are
  the template for the four C2 blocks.

## Tasks & Acceptance

**Execution:**

- [ ] `src/webview/pweb.webview.host.pas` -- the three-element seam
  (`ConsumedArgs`, the `Store` overload, `PWebHostRequestReload`) -- the
  smallest delta that lets a composition supply a store and ask for a
  re-navigation without production learning one dev name.
- [ ] `src/webview/pweb.webview.devhost.pas` -- new dev-only SDK unit: the
  swapping store, the argument, the refusal, the poller, the reload.
- [ ] `tools/templates/react/src/program.lpr` -- `{$ifdef PWEB_DEV}` selects
  `PWebDevHostRun`; the mode is native-controlled and nothing else selects it.
- [ ] `tools/templates/react/frontend/vite.config.ts` -- the
  `pweb-dev-sentinel` `writeBundle` plugin.
- [ ] `tools/pweb/pweb.cli.native.pas` -- additive `PWebCliFpcDevCommand` over
  a shared private builder, release vector provably unchanged.
- [ ] `tools/pweb/pweb.cli.devlayout.pas` -- new: the dev layout, the
  generations, the publish-by-rename, the bounded cleanup.
- [ ] `tools/pweb/pweb.cli.dev.pas` -- new: prerequisites, the two supervised
  threads, the sentinel watch, the pack, the publish, the ladder, the exits.
- [ ] `tools/pweb/pweb.cli.args.pas` -- `pccDev` and its option set.
- [ ] `tools/pweb/pweb.pas` -- link the pipeline and dev units, `dev` in
  `--help` and the dispatch, `cthreads` on Unix; `build` stays unknown.
- [ ] `tools/pweb/pweb.cli.toolchain.pas` -- the `PWEB_CLI_DEV_*` bounds.
- [ ] `test/cap10c2/` -- new: `build_cap10c2.{ps1,sh}`, `pweb.test.dev.pas` +
  `c2tests.pas` (the pure decisions), `pwebdevdrv.pas` (spawns the real
  `pweb dev` with `SeparateConsole` and drives the interrupt),
  `run_cap10c2_gates.ps1`, `check_cap10c2_contracts.ps1` -- DEV1–DEV14,
  T1–T5, and the C2 corpus.
- [ ] `test/cap10a/check_dev_trust.ps1` -- pin the C2 decision.
- [ ] `test/cap10b2/run_cap10b2_gates.ps1`,
  `test/cap10c1/check_cap10c1_contracts.ps1` -- move the literals the
  supersession and the new linkage move, each with a comment naming this shard.
- [ ] `test/cap7f/{check_cap7f_aggregate,check_cap7f_selftest}.ps1`,
  `emit_evidence.{ps1,sh}` -- the C2 fields, their pins, four-target equality,
  one negative self-test leg per new refusal.
- [ ] `.github/workflows/ci.yml` -- four C2 blocks per native job, xvfb on
  Linux.
- [ ] `docs/cli-contract.md` -- §1 gains `dev`; §5 records rebuild-and-reload
  for React in v1, the `ws://127.0.0.1:<port>` allowance staying ratified,
  unused and pinned absent, and that an HMR shard needs the spike's data.
- [ ] `docs/dev-contract.md` **(new)** -- the dev contract.
- [ ] `deferred-work.md` -- the supersession, the ratifications, the
  measurements and the CAP-10C3 handoff.

**Acceptance Criteria:**

- Given a React project on any of the four targets, when `pweb dev` runs from
  an unrelated working directory, then generation 1 is packed by the frozen
  bundler, the host opens on `pweb://app`, the page reports `secure = true`
  and `value = 42`, and no member of the supervised set holds a listener.
- Given a running `pweb dev`, when a source file changes, then a generation is
  published and rendered **without the host pid changing**, and the RPC value
  is 42 after every switch.
- Given a running `pweb dev`, when Ctrl+C / `SIGINT` / `SIGTERM` arrives —
  including mid-rebuild — then every member stops through the C0 ladder within
  its bounds, the drain reports zero descendants, the exit is 0 and no partial
  generation exists on disk.
- Given the same project built by the C1 pipeline, when the release binary is
  measured, then the dev unit is absent from its compiled unit set, the dev
  marker string is absent from its bytes, and it refuses `--pweb-dev-root=`.
- Given both binaries, when `PWEB_NATIVE_CSP` is extracted, then the byte
  strings are identical and neither contains `ws:`, `wss:`, `localhost`,
  `127.0.0.1` or `http:`.
- Given `pweb --help`, it advertises `create doctor run dev`; given
  `pweb build`, it is an unknown command with exit 2.
- Given the four native CI jobs, each emits the C2 corpus, the aggregate finds
  semantic equality on four targets with every absolute pin held, and the C0,
  C1, B0, B1, B2, CAP-10A, CAP-6b3/6b4 and CAP-7/8/9 gates stay green.

## Spec Change Log

## Design Notes

### 1. The dev loop model — the model-A spike, and the verdict

The spike ran the real dev server on the real generated project, crawled the
served module graph and read the bytes. The URL list, the measurements and
the reasoning are the evidence record
`_bmad-output/implementation-artifacts/cap10c2-model-a-spike.md`; the verdict
rests on three findings, and every one is a measurement:

1. **The query is load-bearing and the frozen URI layer cuts it.**
   `/src/app.css` is 2563 bytes of `text/javascript`; `/src/app.css?direct` is
   1938 bytes of `text/css` — one path, two bodies. Model A needs
   `PWebParseAppUri` to preserve and forward the query: a grammar relaxation.
2. **The MIME type must come from the proxied response.** `.tsx` and `.css`
   modules are served `text/javascript`, while `PWebAssetMimeType` derives
   `application/octet-stream` from `.tsx` — which every engine's module MIME
   check refuses. A change to the frozen asset-serving path.
3. **HMR would not connect and has nothing to connect for.** The client
   derives its socket host from the page URL, giving `ws://app:/` under
   `pweb://app`; and with no `@vitejs/plugin-react` in the template there is
   no Fast Refresh, so a `.tsx` edit already ends in `location.reload()`.

**Model A is refused for CAP-10C2** on findings 1 and 2 — each a grammar or
handler relaxation beyond the single ratified `ws://` allowance, which is
exactly the condition the shard's own rule refuses on. Finding 3 is recorded
because it is what an HMR shard would have to solve first.

**Model B — rebuild-and-reload — is chosen**, and §5 records it. The ratified
`ws://127.0.0.1:<native-selected-port>` allowance stays ratified, unused, and
pinned absent from every profile by `check_dev_trust.ps1`.

### 2. The completion signal — the sentinel, measured

Two candidates were measured against Vite 8.2.2 on the real project.

*Line parsing* is refused: watch mode prints `built in 51ms.` where a one-shot
build prints `✓ built in 52ms` — two spellings of one event — and the output
carries ANSI (measured: 256-colour SGR in the error path) whenever the
inherited environment enables colour, which the supervisor may not change.

*The sentinel* is ratified: a `writeBundle` plugin in the template's
`vite.config.ts` writes `<frontend>/.pweb/dev/build-id` containing
`<watcher-start-ms>.<n>`. Measured with a real `vite build --watch`:

| event | result |
|---|---|
| initial build | sentinel `…961.1` written |
| edit `App.tsx` | sentinel `…961.2` **310 ms** after the write; the marker is in `dist/assets/app.js` |
| syntax error | sentinel **unchanged**, watcher **alive**, the error printed |
| fix | sentinel `…961.3` |
| five edits 50 ms apart | five rebuilds, `…961.4`…`…961.8` — Vite does **not** coalesce |

`writeBundle` fires per completed write under Vite 8's Rolldown pipeline, and
`.pweb/` is already inside the C1 mutation set and git-ignored by the
template, so the sentinel costs no new writable prefix. It is written outside
`dist/`, so no `app.pwb` digest moves.

Two rules follow from the measurements and are ratified here:

- **Debounce, bounded.** After a sentinel change the CLI waits
  `PWEB_CLI_DEV_DEBOUNCE_MS` and re-reads; a further change restarts the wait,
  bounded by `PWEB_CLI_DEV_DEBOUNCE_MAX_MS`. Five rapid edits become one or
  two generations rather than five.
- **The snapshot is proved consistent.** `dist/` is copied into
  `<dev>/.gen.tmp/dist` and the sentinel is then **re-read**: if it moved
  during the copy the snapshot is discarded and retaken. Only a snapshot whose
  sentinel is stable across the copy is packed — the mechanical answer to
  "can a partial generation reach the host".

The CLI deletes the sentinel before starting the watcher and treats the first
one that appears as generation 1, so there is one build before the host starts
rather than a one-shot build plus the watcher's identical initial build.

### 3. The dev host, and the exact production seam

The dev binary is `fpc … -dPWEB_DEV -FU <dev>/units -FE <dev>/obj` — separate
unit and object directories, so the release build's compiled unit set is never
polluted and T2 is a directory listing rather than an inference. The generated
`program.lpr` is the only place the mode is selected: under `{$ifdef PWEB_DEV}`
it uses `pweb.webview.devhost` and calls `PWebDevHostRun(options, policy,
bridge)`; otherwise it calls `PWebHostRun` exactly as today.

The production host's delta is three things and no more:

1. `TPWebHostOptions.ConsumedArgs: TRawUtf8DynArray` — argv strings the
   composition has already consumed and validated. The production template
   leaves it empty, so the refusal set is byte-for-byte what it was: an
   unknown argument still raises (`pweb.webview.host.pas:696`). It exists
   because "the host refuses every argument it does not own" has to be
   composable for a composition to own one, and an exact-string list is
   stricter than a prefix.
2. A four-argument `PWebHostRun` overload taking `const Store: IAssetStore`;
   nil means the production rule (`PWebHostLoadBundle`, `app.pwb` beside the
   executable, never the CWD). The three-argument form delegates with nil.
3. `function PWebHostRequestReload: Boolean` — reads the existing
   `HostAutoCloseHandle` and `webview_dispatch`es a callback calling
   `webview_navigate(w, PWEB_HOST_ORIGIN)`. It is `PWebHostTerminate` with
   `webview_terminate` replaced, takes no parameter, and `PWEB_HOST_ORIGIN` is
   the only destination that exists. Production never calls it and gains no
   string.

`pweb.webview.devhost.pas` owns everything else: it parses
`--pweb-dev-root=<dir>` in the same two-pass, duplicate-refusing style,
**refuses to start without it** (so it never reaches `PWebHostLoadBundle`),
requires `<root>/gen-1/app.pwb`, opens it through `PWebBundleLoadFile` — the
production loader with the production refusals — wraps it in the swapping
store, starts the poller and hands the store to `PWebHostRun`.

### 4. The generation switch

```
<output>/<os>-<arch>/dev/
  app/          the dev binary + the webview library (macOS: <ident>.app)
  units/ obj/   the dev compiler outputs
  .gen.tmp/     one generation under construction — never published
  gen-1/ gen-2/ …   app.pwb, immutable, published by ONE rename
```

- **The store wrapper** is `TPWebDevGenerationStore`, a
  `TInterfacedObject, IAssetStore` holding the current `TZipAssetStore` behind
  a `TOSLock` — `TZipAssetStore`'s own lock discipline. `Swap` replaces the
  reference; a read in flight completes against the store it took.
  `IAssetStore` gains nothing; this is an implementation.
- **Publication** is `PWebCliRenameDir('<dev>/.gen.tmp' → '<dev>/gen-N')`,
  which must not replace. There is no `current` pointer file: a pointer needs
  a replacing rename, which this repository deliberately does not have (the
  host's verdict writer records that `RenameFile` does not replace on
  Windows), and a torn read is a failure mode a directory rename cannot have.
- **Discovery** is a bounded poll: the poller thread tests for
  `<root>/gen-<N+1>/app.pwb` every `PWEB_DEV_POLL_MS`, looking only forward.
  No listener, no socket, no IPC, no stdin protocol. A generation the frozen
  loader refuses is reported and skipped; the current one stays live.
- **The reload** is `PWebHostRequestReload` — a native navigate through
  `webview_dispatch`, the mechanism the auto-close and the CAP-10C0 POSIX stop
  helper already use. Never injected script, never `location.reload()`.
- **The acknowledgement** is one ratified flushed line on the host's stdout,
  `<prefix>: generation <N> loaded` — precisely the seam CAP-10C1 built when
  it closed the POSIX block-buffering debt. The CLI reads it from the engine's
  own line sink; the host writes nothing to disk.
- **Cleanup** is bounded: on generation N acknowledged the CLI removes `gen-M`
  for `M <= N - PWEB_CLI_DEV_KEEP_GENERATIONS` through the guarded
  `PWebCliPipeRemoveTree`. The host only looks forward, so a removed
  generation can never be the one it is about to open.

**A measured risk, stated before it is run.** Only the Windows handler sends
`Cache-Control: no-store` (`pweb.platform.webview2.pas:762`); the WebKitGTK and
Cocoa handlers send none, and the platform adapters are frozen. Whether a
re-navigation re-requests sub-resources is therefore an engine property to be
**measured** by DEV2/DEV3 on four targets in the first hosted run. If a target
serves a stale sub-resource the in-scope fallback is `pweb://app/?g=<N>` — the
query is cut by `PWebParseAppUri` and maps to `index.html`, the origin is
unchanged, no grammar moves. If that too is insufficient somewhere the shard
reports it rather than restarting the host, which would fail acceptance 4.

### 5. Start-up stages, ratified

| stage | when | why |
|---|---|---|
| open + toolchain | every start | the C1 rule verbatim, doctor verdict and `platform.webview` exclusion included — refuse before any write |
| stage_sdk | every start | C1 refuses a stale staged SDK; skipping it would compile against yesterday's runtime |
| `npm ci` | **conditionally** | absent `node_modules`, absent/unreadable install record, a `package-lock.json` digest differing from it, or an absent `vite`/`tsc` entry point; otherwise skipped. The record is `<frontend>/.pweb/dev/install-lock.sha256`. No new option. |
| `tsc` | once, at start | Vite does not typecheck, and per-generation typechecking would cost seconds per keystroke; a type error is a start-up refusal |
| native dev compile | every start | bounded, units cached under `<dev>/units` |
| first generation | before the host | the watcher's initial build; the host never starts on an empty store |

### 6. Supervision — two long-lived children, one ladder

`PWebCliExecute` runs one child to completion, so each long-lived member gets
a thread of its own; the engine is re-entrant (Code Map) and the Windows
handle list plus the POSIX pre-exec discipline make concurrent spawns safe.
The main thread owns the sentinel watch, the pack (a short-lived child run
synchronously), the publish and the cleanup.

```
main thread                         watcher thread          host thread
prerequisites
start watcher                    -> PWebCliExecute(vite --watch)
wait sentinel; pack gen-1
start host                                            -> PWebCliExecute(host)
loop: sentinel -> pack -> publish -> read `generation N loaded`
```

**One stop flag** — set by the console/signal handler
(`PWebCliStopRequested`), by the host exiting, by the watcher exiting or by an
internal failure — is the `StopCheck` of **both** long-lived executions, so one
request runs both ladders (graceful `WM_CLOSE` / `SIGTERM` to the group, then
forced, then drained by membership) concurrently, inside the C0 bounds. Output
is serialised through one critical section, prefixed `vite: ` or `app: `, with
**ANSI stripped** — measured necessary: Vite colours its output whenever the
inherited environment enables it, and the supervisor injects nothing.

Failure semantics: the host exiting by itself with status 0 stops the loop
with exit 0; the host exiting any other way, or the watcher exiting at all,
stops the loop with **exit 5** and the real typed status. A build or pack
child failing does **not** stop the loop — the previous generation stays live
(DEV4).

The Windows interrupt reuses the CAP-10C0 mechanism rather than a new one:
`pwebdevdrv` spawns `pweb dev` with `SeparateConsole := True`, then runs
`test/cap10c0/pwebchild.pas ctrlbreak <pid>`, which attaches to that console
and raises `CTRL_C_EVENT`. `interrupt_clean` is therefore measured on **all
four** targets, closing the C1 gap.

### 7. Public surface

```
pweb --help   ->  create  doctor  run  dev
pweb dev [--project <path>]        pweb dev --help        pweb build -> exit 2
```

`dev` accepts `--project` and `--help` and nothing else; every other refusal
is an existing CAP-10A cause (`option_not_for_command`, `duplicate_option`,
`extra_positional`) and no new usage code is added. The Pas2JS refusal is a
**project** category (exit 3), cause `dev_ui_unsupported`: the command line was
well formed and it is the declared `ui` this build's dev loop does not
implement. Exit mapping is C0's, plus one ratified addition — a dev-loop
invariant break is 6 and the supervised set failing is 5.

### 8. What moves, and what is re-measured unchanged

| field | expectation |
|---|---|
| `cli_digest` | **moves** — the parser corpus records `args\|dev\|ok` and the `dev` option rows, as CAP-10C0 moved it for `run`. Supersession recorded. |
| the React template digests (`template_digest`, `generated_*`, `public_semantic_digest`, …) | **move** — the `vite.config.ts` sentinel; the CAP-10B2 gate's literal moves in the same commit, as CAP-10C1 did |
| `pipeline_digest` | **unchanged**, re-measured — `PWebCliFpcCommand` must not move |
| every `c1_app_pwb_*` digest | **unchanged**, re-measured |
| `doctor_schema_digest`, `supervision_digest` | **unchanged**, re-measured |
| `pipeline_units_linked` | **moves** `false` → `true`; the C1 gate's assertion is inverted with a comment naming this shard |
| `advertised_commands` | `create,doctor,run,dev` |

## Verification

**Commands** (each `pwsh -NoProfile -File`, POSIX build via `.sh`):

- `test/cap10c2/build_cap10c2.ps1` -- CLI, suite, driver and fixtures build.
- `test/cap10c2/check_cap10c2_contracts.ps1` -- bounds match the constants,
  the dev unit is absent from the release unit set, no unratified platform
  conditional, the CSP bytes match, no transport allowance anywhere.
- `test/cap10c2/run_cap10c2_gates.ps1` -- DEV1–DEV14 and T1–T5 PASS,
  `build/cap10c2/dev-corpus.txt` carries at least one decision,
  `build/cap10c2/cli-<target>.json` emitted.
- `test/cap10a/check_dev_trust.ps1` -- PASS, including the new C2 pins.
- `test/cap7f/check_cap7f_selftest.ps1` -- one new negative leg per new
  aggregator refusal, each red on its fixture.
- `test/cap7f/check_divergence.ps1` -- re-ratifies with the dev unit counted.
- `test/cap10c1/run_cap10c1_gates.ps1`, `test/cap10c0/run_cap10c0_gates.ps1`
  -- unchanged verdicts, `pipeline_digest` = `f890424a…978e839a`.
- `gh run list` on the final HEAD -- six jobs green, `cap7 aggregate` PASS.

**Manual check:** the two host binaries scanned for `--pweb-dev-root=` and
`pweb.webview.devhost` — present in the dev one, absent from the release one.
