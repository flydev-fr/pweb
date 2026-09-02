---
title: 'CAP-10C1 — the private lifecycle pipeline: sources to the C0 run layout, in Pascal, through the C0 engine'
type: 'feature'
created: '2026-09-02'
status: 'in-progress'
baseline_commit: '2d5f74d2774ec182c3c24f93b18a19c99adf7e72'
review_loop_iteration: 0
context:
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/docs/supervision-contract.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10c0-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10b1-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10b2-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Everything that takes a generated project from sources to a
runnable application lives in four test harnesses —
`test/cap10b1/prove_cap10b1.{ps1,sh}` and `test/cap10b2/prove_cap10b2.{ps1,sh}`
— written twice in two languages, driven by a shell, and reaching into this
repository's `deps/` and `build/` for mORMot, the statics and the webview
library. CAP-10C0 froze one supervision engine and the `pweb run` layout it
launches, but nothing in Pascal can produce that layout, so `pweb dev`
(CAP-10C2) and `pweb build` (CAP-10D) have no pipeline to call.

**Approach:** Move what the harnesses do into private CLI units under
`tools/pweb/`: resolve the toolchain by the CAP-10A rules, materialise the
TypeScript SDK, install and build the frontend, pack `app.pwb` through the
frozen bundler, compile the native program against the SDK root and assemble
`<output>/<os>-<arch>/release/` exactly as CAP-10C0 resolves it — every child
run through the C0 supervise profile, no shell, no command string. The
pipeline stays private: no command is exposed, `pweb --help` still advertises
`create doctor run`, and a private driver (`pwebpipe`) exercises it. Parity is
the acceptance: on the same job the pipeline must produce the same `app.pwb`
bytes the harness produces, and `pweb run` must launch the result and receive
42.

## Boundaries & Constraints

**Always:**
- One execution path. Every child goes through `PWebCliExecute` in the
  `pepSupervise` profile, with an exact executable path, an argument vector
  and an explicit working directory. `pweb.cli.pipeline` is the only unit that
  calls it; every other pipeline unit is a **pure argv/plan builder**.
- No `{$ifdef}` outside `pweb.cli.platform`. Target selection is a runtime
  function of `(PWebCliHostOs, PWebCliHostArch, the probed FPC target)`, which
  is what makes the four-target argv table assertable from any one target and
  keeps every new unit off the CAP-7F divergence allowlist.
- Tools are resolved by the CAP-10A resolver (`PWebCliResolveTool`). A
  candidate inside the project root is reported and **never executed**. npm is
  reached only as `node <npm-cli.js>`; `npm.cmd` can never be the answer.
- mORMot, the mORMot statics, the webview library, the macOS bridge object,
  the PWeb Pascal source root, the TypeScript SDK and the Pas2JS SDK are all
  read from the **SDK root** resolved from the running image, by the same
  component-by-component walk `pweb.cli.sdk` already uses. Never from the
  project, never from an environment variable, never from the working
  directory.
- The pipeline writes only inside the ratified project-mutation set. The
  project tree minus that set is digested before the first stage and after
  every stage and must be unchanged.
- A failure or an interruption leaves no release directory and no partial
  layout: the layout is assembled in a sibling temp and committed by rename,
  as CAP-10B0 does.
- Exactly one stage may reach the network: `npm ci` for a React project.
- Every new pinned constant is cross-checked in CI against its lock or its
  ratified source, as `pweb.cli.toolchain` already requires.

**Ask First:**
- Any change to `pweb.json` schema 1, the CAP-10A parser or doctor rows, the
  CAP-10B0 engine, the CAP-10C0 engine, `pweb run`, the exit mapping or the
  run layout.
- Promoting the pipeline to a public command, or adding any option to `pweb`.
- Any CSP, privileged-origin, navigation or capability change.
- Re-baselining a frozen digest that this shard did not plan to move.

**Never:**
- Expose `dev` or `build`; link the pipeline units into `pweb.pas`.
- Start a watcher, a dev server, a proxy, HMR or a listener; add any `ws://`,
  `localhost` or `127.0.0.1` allowance anywhere.
- Modify a generated **source** file, or write anywhere outside the project
  root (the OS temp directory used by the toolchain's own children excepted).
- Vendor PWeb or mORMot into the project.
- Run `npm install`, `npm update`, or any floating resolution; run a lifecycle
  script beyond what this spec ratifies.
- Take any compiler, npm or bundler argument from `pweb.json` or from the
  environment.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| React pipeline | generated React project, node/npm/fpc present, SDK root complete | all ten stages run; `<output>/<target>/release/` holds the exe, `app.pwb` and the webview library; `pweb run` answers 42 | N/A |
| Pas2JS pipeline | generated Pas2JS project, pas2js 3.0.1 + fpc | same layout, entirely offline | N/A |
| npm entry point absent | `node` resolves, `npm-cli.js` is not at the ledgered path | refusal `npm_cli_unresolved`, exit 4, before any write | typed refusal, stage `toolchain` |
| Tool version mismatch | fpc < 3.2.2, or pas2js ≠ 3.0.1 | refusal `tool_version`, exit 4, before any write | typed refusal, observed vs expected recorded |
| Project-local tool | a `node` inside the project root is first on PATH | refusal `tool_inside_project` with its path, never executed | typed refusal |
| Doctor already refuses | a required CAP-10A row fails | the pipeline refuses with the **same cause**, exit 4, before any child runs | typed refusal, stage `doctor` |
| Registry override present | `.npmrc` / `.yarnrc` / `.pnpmfile.cjs` anywhere in the project | refusal `registry_override_present`, exit 3, before `npm ci` | typed refusal |
| Stale staged SDK | `frontend/.pweb/sdk/typescript` holds an extra file | the tree is removed and re-staged fresh; the extra file does not survive | not merged, ever |
| Seeded type error | `tsc` fails | stage `typecheck` fails, exit 5, real child status reported, no later stage runs, no release directory | pipeline stops, tree drained |
| Interruption mid-stage | Ctrl+C / SIGINT during `fpc` | the child tree is stopped by the C0 ladder, the pipeline reports `interrupted`, exit 5, no release directory | membership drain, no partial layout |
| Layout already built | `release/` exists from an earlier run | the new layout is committed by rename; the old one is reclaimed after the commit | never a merge, never a partial |

</frozen-after-approval>

## Code Map

**The frozen ground this builds on**

- `tools/pweb/pweb.cli.process.pas` — the ONE engine. `TPWebCliExecSpec`
  (`ExePath`, `Args`, `WorkDir`, `Profile`, `TimeoutMs`, `Sink`, `StopCheck`,
  `Started`, `TreeRoot`), `TPWebCliExecResult` with the six typed outcomes,
  `PWebCliExecute`. `pepSupervise` forwards both streams line by line and
  runs the graceful→forced ladder on a stop request.
- `tools/pweb/pweb.cli.platform.pas:144-232` — the write primitives the
  pipeline builds on: `PWebCliCreateDir` (one level, exclusive),
  `PWebCliWriteNewFile(Path, Content, SetExecBit)` (never overwrites, sets the
  POSIX mode after the write), `PWebCliDeleteFile`, `PWebCliRemoveEmptyDir`,
  `PWebCliRenameDir` (the commit; never replaces), `PWebCliRemoveStagedTree`
  (guarded recursive removal), `PWebCliListDir`, `PWebCliReadSmallFile(Path,
  MaxBytes, out Content, out TooBig)` — a caller-supplied bound, refuses a
  link, which is the whole of the copy primitive this shard needs. **No new
  platform primitive is required**, so `pweb.cli.platform.pas` keeps its
  ratified divergence count of 36.
- `tools/pweb/pweb.cli.sdk.pas` — the SDK-root anchor
  (`<sdk>/bin/pweb` → `sdk-root = parent(dir(image))`) and
  `PWebCliTemplatePackIn(Root, …)`, whose documented seam is "callers that
  need a DIFFERENT root pass it as a PARAMETER". Extended here, never
  duplicated.
- `tools/pweb/pweb.cli.project.pas` — `TPWebCliProject` (`Root`, `Name`,
  `Version`, `BundleId`, `Ui`, `NativeProgram`, `FrontendRoot`, `Output`,
  `ProgramIdent`, and the three `TPWebCliResolved` path records).
- `tools/pweb/pweb.cli.run.pas:PWebCliRunLogicalLayout` — the layout the
  pipeline must produce, stated once as a pure function of the descriptor.
- `tools/pweb/pweb.cli.probe.pas` — `PWebCliResolveTool` (PATH order, PATHEXT,
  duplicates counted, inside-project refused), `PWebCliRunProbe`.
- `tools/pweb/pweb.cli.doctor.pas:404-437, 620-700` — `AddPresenceRow` and the
  npm row; the requirement graph the pipeline reuses for its refusal.
- `tools/pweb/pweb.cli.toolchain.pas` — the pins and the C0 bounds; the new
  pipeline bounds and library names go here, beside them.
- `tools/pweb/pweb.cli.write.pas` — the CAP-10B0 temp-and-rename transaction
  the layout stage copies in shape (staging sibling, verify, `PWebCliRenameDir`
  as the commit, never reclaim a directory this process did not create).

**The harness this replaces (read for the argv, then leave alone)**

- `test/cap10b1/prove_cap10b1.ps1:110-190` — SDK staging, `npm ci`,
  `npm run typecheck`, `npm run build`, the `@pweb/runtime` link check.
- `test/cap10b1/prove_cap10b1.ps1:230-260` and
  `test/cap10b2/prove_cap10b2.ps1:365-375` — the Windows `fpc` argv inside the
  CAP-3U window.
- `test/cap10b1/prove_cap10b1.sh:79-135` — the Linux and macOS `fpc` argv
  (`-k-rpath=$ORIGIN -k-lgcc_s`; `PWEB_MACOS_FPC_FLAGS` +
  `PWEB_MACOS_FPC_LINK_BRIDGE`).
- `test/cap10b1/prove_cap10b1.sh:495-550` — the macOS `.app` and its
  `Info.plist` keys.
- `test/cap10b2/prove_cap10b2.ps1:120-215` — the pas2js argv, the BOM/CR
  normalisation, `assets/boot.js`, the static set, the semantic ZIP inventory.
- `tools/macos-buildenv.sh` — `-WM<target>`, `-Fl<static>`, `-Fl<dist>`,
  `-k-rpath -k@executable_path`, `-k-L<dist> -k-lwebview`, the bridge object,
  the four frameworks/runtimes, and `-k-no_fixup_chains` on aarch64 only.
- `tools/stage-ts-sdk.mjs` — the staging rule to port: a canonical manifest
  with the fixed key order `name version license type main types exports`,
  `JSON.stringify(…, null, 2)` + one LF, then `dist/src/**` verbatim in sorted
  order, into a directory that is removed first and never merged.
- `tools/patch-cap3u.ps1` — Windows-only, needs MSVC `ml64` and a mORMot **git
  checkout**; produces the patched `mormot.core.interfaces.pas` plus
  `src/core/x64callmethod.obj`.
- `test/cap10c0/run_cap10c0_gates.ps1:105-140, 220-300` — the project staging
  and the `RunPweb` sampler the C1 gate is modelled on.
- `test/cap7f/check_cap7f_aggregate.ps1:90-435` — `$allFields`,
  `$absolutePins`, `$mustPass`, `$equalityFields`, and the recorded reason why
  archive **bytes** are never compared across targets while their **semantic**
  inventories are.
- `test/cap7f/check_divergence.ps1:69-183` — a platform conditional in a file
  **not** on the allowlist fails; new units must carry none.
- `test/cap10a/check_dev_trust.ps1:70-100` — sweeps `tools/**/*.pas` string
  literals for development origins.
- `test/cap10c0/check_cap10c0_contracts.ps1:127-175` — the CLI unit-set
  measurement and the name-based-kill sweep over every `tools/pweb/*.pas`.

**Measured on the dev host before planning (2026-09-02)**

- `node <D>/node_modules/npm/bin/npm-cli.js ci --no-audit --no-fund
  --ignore-scripts` in the generated frontend: 27 packages, exit 0,
  `node_modules/@pweb/runtime` a symlink to `frontend/.pweb/sdk/typescript`.
- `node node_modules/typescript/bin/tsc -p tsconfig.json` → 0;
  `node node_modules/vite/bin/vite.js build` → 0.
- The resulting `dist/index.html`, `dist/assets/app.js`,
  `dist/assets/index.css` are **byte-identical** to the harness's
  `npm run build` output, from a different absolute path.
- `pwebbundle <that dist> app.pwb` produced
  `38df29f2170d3564569e4976f1ab059417c0a51c8437d7bbe404002deba7cdc0`, equal to
  `build/cap10b1/stage/app.pwb`. **The parity claim is achievable.**
- `tools/templates/react/frontend/package-lock.json` carries exactly **one**
  `hasInstallScript` package: `fsevents@2.3.3`, `dev`, `optional`,
  `os: ["darwin"]` — reached only by the dev watcher, never by `vite build`.
- `node tools/stage-ts-sdk.mjs` re-run into a fresh directory reproduces the
  staged tree byte for byte.

## Tasks & Acceptance

**Execution — production (private, not linked into `pweb.pas`):**

- [ ] `tools/pweb/pweb.cli.sdk.pas` -- add `PWebCliSdkLayout(Root, Os, Arch,
      Ui, out Layout, out Refusal)` resolving `share/pweb/{src/*, sdk/typescript,
      sdk/pas2js, deps/mormot2/src, deps/mormot2/static/<fpc-target>,
      lib/<os>-<arch>}` and `bin/pwebbundle[.exe]` through `PWebCliEntry`, with
      one typed refusal per missing component -- one SDK resolver, extended,
      never a second one; it must gain no new `uses` so the shipped CLI's unit
      set does not move.
- [ ] `tools/pweb/pweb.cli.toolchain.pas` -- add the pipeline bounds
      (`PWEB_CLI_PIPE_NPM_MS 600000`, `_TSC_MS 300000`, `_BUILD_MS 300000`,
      `_PACK_MS 120000`, `_FPC_MS 900000`, `_MAX_FILE_BYTES 268435456`,
      `_MAX_TREE_FILES 4096`, `_MAX_TREE_DEPTH 24`) and the library names from
      `webview.lock` (`webview.dll`, `libwebview.so.0.12`,
      `libwebview.0.12.dylib`, `pweb_cocoa_bridge.o`) -- stated once, each
      cross-checked in CI against its lock or ratified source.
- [ ] `tools/pweb/pweb.cli.toolset.pas` -- NEW: resolve node (≥
      `PWEB_CLI_NODE_MIN`), the npm CLI entry point by the C0-ledgered rule,
      fpc (≥ `PWEB_CLI_FPC_MIN`, with `-iTO`/`-iTP` recorded and checked
      against the host target) and pas2js (== `PWEB_CLI_PAS2JS_VERSION`) --
      typed observations and one refusal cause each, so the pipeline can fail
      closed before it writes anything.
- [ ] `tools/pweb/pweb.cli.stage.pas` -- NEW: the `stage-ts-sdk.mjs` rule in
      Pascal (canonical manifest, fixed key order, two-space indent, LF, one
      trailing newline; `dist/src/**` copied in sorted order; the destination
      removed first and never merged), the bounded tree copy over
      `PWebCliReadSmallFile` + `PWebCliWriteNewFile`, and the bounded tree
      digest used by the mutation gate.
- [ ] `tools/pweb/pweb.cli.frontend.pas` -- NEW: pure plans for `npm ci`,
      `tsc`, `vite build` (react) and `pas2js` (pas2js), plus the ratified
      Pas2JS static assembly — strip a UTF-8 BOM, delete **every** CR, write
      `assets/boot.js` = `rtl.run();\n`, place `index.html` and
      `assets/app.css` -- the CAP-10B2 normalisation moved from the harness
      into the product, because without it the Pas2JS `app.pwb` is an
      OS-family artifact.
- [ ] `tools/pweb/pweb.cli.pack.pas` -- NEW: the `app.pwb` plan — the SDK
      root's frozen bundler with exactly the two arguments the harness passes.
- [ ] `tools/pweb/pweb.cli.native.pas` -- NEW: the `fpc` argv builder as a
      **pure function** of (Os, Arch, FPC target, project, SDK layout, output
      dirs) for all four targets, plus the output-directory plan under
      `<output>/<target>/{units,obj}`.
- [ ] `tools/pweb/pweb.cli.layout.pas` -- NEW: assemble the C0 release layout
      into `<output>/<target>/.pweb-release.tmp`, verify it against
      `PWebCliRunLogicalLayout`, then commit by rename; generate the macOS
      `Info.plist` from the descriptor (`CFBundleExecutable`,
      `CFBundleIdentifier`, `CFBundleName`, `CFBundlePackageType`,
      `CFBundleShortVersionString`, `CFBundleVersion`,
      `LSMinimumSystemVersion` = `PWEB_CLI_MACOS_MIN`,
      `NSHighResolutionCapable`).
- [ ] `tools/pweb/pweb.cli.pipeline.pas` -- NEW: the ordered stage machine and
      the ONLY caller of `PWebCliExecute` -- stage identity, bound, sink
      prefix, stop check between and during stages, the project-mutation
      digest gate before the first stage and after every stage, the
      registry-override refusal, typed stage outcomes and the exit mapping.
- [ ] `src/webview/pweb.webview.host.pas` -- add `Flush(Output)` after the
      stdout diagnostics, and make `PWebHostAutoCloseThread` wait on an event
      the teardown sets after `webview_run` returns instead of sleeping the
      whole bound -- closes two ledgered CAP-10C0 debts; the teardown order
      after `webview_run` must remain exactly the string the contract gate
      reads.
- [ ] `tools/templates/react/src/app.services.pas` and
      `tools/templates/pas2js/src/app.services.pas` -- add `Flush(Output)`
      after the ready report -- the two files must stay byte-identical, which
      `shared_native_source_digest` measures.

**Execution — tests, gates and CI:**

- [ ] `test/cap10c1/build_cap10c1.ps1|.sh` -- extend the ONE staged SDK root
      at `build/cap10b1/sdk` with `share/pweb/deps/mormot2/{src,static/<target>}`,
      `share/pweb/lib/<os>-<arch>/` and `bin/pwebbundle[.exe]`; on Windows
      stage the **CAP-3U-patched** mORMot source and its `x64callmethod.obj`
      and restore the checkout afterwards; compile `pwebpipe` and `c1tests`,
      plus the layering isolation compiles that prove the pipeline units link
      no webview unit.
- [ ] `test/cap10c1/pwebpipe.pas` -- the private driver: `--project <path>`,
      optional `--stage-until <name>`, `--fail-stage <name>` (test-only), stage
      lines prefixed, no ANSI in its own lines, no absolute SDK/home path in
      any line it writes.
- [ ] `test/cap10c1/pweb.test.pipeline.pas` + `c1tests.pas` -- the headless
      suite: the four-target `fpc`/`npm`/`tsc`/`vite`/`pas2js` argv golden
      table, the manifest serialiser, the Pas2JS normalisation, the digest
      walk, the layout plan and its refusals, the mutation-set rule.
- [ ] `test/cap10c1/check_cap10c1_contracts.ps1` -- bounds and library names
      against `docs/pipeline-contract.md` and the locks; the pipeline units
      carry no platform conditional, no name-based process primitive, no
      environment read and no dev origin; they are **absent** from
      `build/cap10b1/cli-units`; `dev`/`build` still unknown.
- [ ] `test/cap10c1/run_cap10c1_gates.ps1` -- TC1–TC4, ST1–ST14, DB1–DB3,
      SF1–SF3 on real generated React and Pas2JS projects; emits
      `build/cap10c1/cli-<target>.json`.
- [ ] `test/cap10c1/listener_members.ps1` -- the membership-scoped sampler,
      dot-sourced and defining **functions only** (no `Set-StrictMode`, no
      preference variables — the CAP-6b3 lesson).
- [ ] `test/cap10c0/run_cap10c0_gates.ps1` -- dot-source that sampler and add
      `run_listener_members_max` / `run_listener_members_seen` /
      `run_listener_sampler_scope` **beside** the existing `run_listener_count`
      -- ratified at Checkpoint 1: the membership claim is measured on the C0
      legs too, while the pinned row keeps its exact "sampled against the
      application pid" provenance and is not re-baselined.
- [ ] `docs/pipeline-contract.md` -- NEW: the stages, their argv shapes, the
      bounds table, the mutation set, the network and script policy, the SDK
      root layout and the exit mapping.
- [ ] `.github/workflows/ci.yml` -- one four-step block per native job after
      the CAP-10C0 block; `test/cap7f/emit_evidence.ps1|.sh` and
      `test/cap7f/check_cap7f_aggregate.ps1` gain the C1 fields, pins,
      must-PASS and equality entries; `test/cap7f/check_cap7f_selftest.ps1`
      gains one negative leg per new aggregator refusal.
- [ ] `_bmad-output/implementation-artifacts/deferred-work.md` -- the template
      and host supersessions (old → new digests, with the flush as the
      reason), the npm-doctor-row decision, and anything measured and deferred.

**Acceptance Criteria:**

- Given a generated React project and a complete SDK root, when `pwebpipe`
  runs, then every child is spawned by `PWebCliExecute` with an exact path and
  an argv array, `app.pwb` is byte-identical to `build/cap10b1/stage/app.pwb`
  on the same job, and `pweb run --project <it>` answers 42.
- Given a generated Pas2JS project, when `pwebpipe` runs, then no stage opens
  a network connection, `app.pwb` is byte-identical to
  `build/cap10b2/stage/app.pwb`, and `pweb run` answers 42.
- Given any stage failure or a Ctrl+C mid-stage, when the pipeline stops, then
  no `release/` directory and no partial layout exist, the child tree is
  drained by membership, and the reported cause is the stage name plus the
  child's real typed status.
- Given a run of either pipeline, when the project tree minus the ratified
  mutation set is digested before and after every stage, then it is unchanged,
  and nothing outside the project root has been written by the pipeline.
- Given the four native jobs, when the aggregate runs, then the C1 corpus is
  present on every target, the semantic `app.pwb` digests agree across all
  four, the raw archive digests are recorded per target and never compared,
  `pweb --help` still advertises `create doctor run`, `dev` and `build` still
  exit 2, and every CAP-10C0 / B0 / B1 / B2 / 10A / 6b3 / 6b4 / 7 / 8 / 9 gate
  is green on its superseded-or-unchanged digests.

## Design Notes

**Why every stage unit is a pure plan builder.** The argv for a target is a
function of `(Os, Arch, FPC target, paths)`, so the whole matrix can be
asserted from any single target — the same trick CAP-10C0 used for the Windows
quoting golden table. It also keeps `{$ifdef}` out of every new unit, which is
what the CAP-7F divergence sweep requires of any file not on its allowlist.

**The `fpc` argv, per target** (S = `<sdk>/share/pweb`,
M = `S/deps/mormot2`, L = `S/lib/<os>-<arch>`, O = `<root>/<output>/<target>`):

```
common   -MObjFPC -Sh -B -FU O/units -FE O/obj -Fu <root>/src
         -Fu S/src/{lib,rpc,security,webview,assets} -Fu S/src/platform/<os>
         -Fi M/src -Fu M/src/{core,lib,crypt,net,db,orm,rest,soa}
windows  -Px86_64 -Twin64 -Xm  -Fl M/static/x86_64-win64
linux    -Fl M/static/x86_64-linux -Fl L -k-rpath=$ORIGIN -k-lgcc_s
macos    -WM12.0 -Fl M/static/<x86_64|aarch64>-darwin -Fl L
         -k-rpath -k@executable_path -k-L L -k-lwebview
         -k L/pweb_cocoa_bridge.o -k-framework -kCocoa -k-framework -kWebKit
         -k-lc++ -k-lobjc      [aarch64 only: -k-no_fixup_chains]
last     <root>/src/<ident>.lpr
```

**Why the SDK root carries a pre-patched mORMot on Windows.**
`tools/patch-cap3u.ps1` needs MSVC `ml64` and a mORMot **git checkout**, and it
patches this repository's `deps/`. A pipeline that did that would be mutating
its own framework's checkout on every build. The CAP-3U *semantics* are
preserved by staging the patched source and `x64callmethod.obj` into the SDK
root once, at install time — which is what a shipped SDK must do anyway — so
the build path has no patch window at all. A gate asserts the staged
`mormot.core.interfaces.pas` is the patched form and the object is present.

**`app.pwb` equality is two different claims.** The aggregator already records
the measurement that decides this: the mORMot static DEFLATE object emits
different bytes per toolchain and mORMot stamps the creating OS into the ZIP
`version made by` byte, which is why `pas2js_app_pwb_bytes` is deliberately
absent from the equality list while `pas2js_app_pwb_semantic_digest` is in it.
So C1 makes **byte** parity a same-job claim (pipeline vs harness) and
**semantic** parity the four-target claim. Requiring one archive hash on four
targets would be requiring something already measured to be false.

**The listener sampler.** POSIX membership is exact — every process whose pgid
is the application pid, because the C0 engine puts the child at the head of its
own group. Windows has no job handle outside `pweb`, so the sampler takes the
transitive descendant closure of the application pid, recomputed each pass;
`listener_sampler_scope` records which. `listener_members_seen` guards the
vacuous zero the same way `Sampled > 0` already does. It is dot-sourced by both
the C1 and the C0 gates, so one rule is measured on both, and it is added
**beside** `run_listener_count` rather than replacing it: a closed shard's
absolute pin keeps the provenance it was ratified with.

**Two riders ratified at Checkpoint 1.**

1. The C1 corpus records the resolved npm CLI entry point and the version it
   reported (`obs_npm_cli_path`, logical form only, and `obs_npm_version`) as
   typed per-target observations. The doctor's presence row is then not the
   only trace of the npm rule: the pipeline's own resolution is in the
   evidence, on every target, and a host where the ledgered path does not
   exist is visible as `npm_cli_unresolved` rather than as silence.
2. The auto-close closer's move to an event wait is re-measured rather than
   argued: the final report carries two tables from the closure run — the
   CAP-9 shutdown order as the contract gate reads it out of the host's source
   on each of the four targets, and the C0 `run_interrupt_clean` signal→exit
   and `StopToExitMs` / `KillToReapMs` timings on each, beside the CAP-10C0
   closure values. A semantics-neutral change has to look neutral in the
   numbers, not only in the reasoning.

## Verification

**Commands:**
- `pwsh test/cap10c1/build_cap10c1.ps1` (and `test/cap10c1/build_cap10c1.sh`)
  -- expected: the SDK root carries `deps/mormot2`, `lib/<target>` and
  `bin/pwebbundle`; `pwebpipe` and `c1tests` built; the layering compiles clean.
- `pwsh test/cap10c1/check_cap10c1_contracts.ps1` -- expected: PASS, and the
  pipeline units absent from `build/cap10b1/cli-units`.
- `pwsh test/cap10c1/run_cap10c1_gates.ps1` -- expected: every TC/ST/DB/SF leg
  PASS, `build/cap10c1/cli-<target>.json` written.
- `pwsh test/cap10b1/run_cap10b1_gates.ps1`, `test/cap10b2/run_cap10b2_gates.ps1`,
  `test/cap10c0/run_cap10c0_gates.ps1`, `test/cap10a/run_cap10a_gates.ps1`,
  `test/cap10a/check_dev_trust.ps1`, `test/cap7f/check_divergence.ps1` --
  expected: green, with the template digests moved exactly where the
  supersession record says and nowhere else.
- `gh run list --branch phase/cap-10/c1-lifecycle-pipeline` -- expected: all
  six jobs green on the final HEAD, `cap7 aggregate` recording the C1 corpus
  PASS on all four targets.
