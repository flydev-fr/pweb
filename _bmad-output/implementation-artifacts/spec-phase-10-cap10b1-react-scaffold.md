# CAP-10B1 — the trusted React template and the public `pweb create` command

The first shard that turns the frozen CAP-10B0 engine into a command a
developer can run. It adds ONE trusted public template, links the engine
into the CLI for the first time, and proves the project it produces builds
and runs to `42` on four targets — without exposing `dev`, `run` or
`build`.

Entry state: CAP-7, CAP-8, CAP-9, CAP-10A and CAP-10B0 are CLOSED. CAP-10B0
froze the verified executable-relative template archive, the compiled
registry trust anchor, the SDK-root dependency model, the strict identity
mapping, the six-token non-recursive renderer, the immutable creation plan,
the destination-must-not-exist rule and the atomic sibling-stage + rename
commit — and deliberately shipped no public command and no runnable
template.

---

## Checkpoint-1 decisions (ratified before implementation)

### D1 — the public grammar, without `--output`

```
pweb create NAME --ui react --bundle-id <reverse.dns>
pweb create --help
```

`NAME` is one positional after the command; `--ui` and `--bundle-id` are
mandatory; long options only; every option is a singleton; values may be
written `--ui react` or `--ui=react`. No response file, no `--`, no
`/option`, no environment injection — the frozen CAP-10A parser contract,
unchanged.

**`--output` is NOT exposed.** CAP-10B0 *designed* it (`docs/template-contract.md`
§5) but ratified no default and no gate for it. The destination is
`<captured-CWD>/NAME`, read through the single CAP-10A CWD seam
(`PWebCliCwd`, called exactly once in `Main`) and never re-read. Shipping
one destination rule is smaller than shipping two, and `--output` stays
designed and unexposed for the shard that needs it.

`--project`, `--json`, `--with-paths` remain doctor-only and are
`option_not_for_command` on a create line. `--ui pas2js` is a **usage
failure** until CAP-10B2: the value is refused by the parser's own
allowlist, not by a template lookup, so the CLI can never advertise or
half-accept a UI it has no template for.

### D2 — the exit mapping (the CAP-10B0 deferred question, answered)

No new category. The frozen CAP-10A taxonomy `6 > 5 > 4 > 3 > 2 > 0` is
reused; **exit 5 is unreachable from `create`, because create starts no
child process.**

| exit | create causes |
|---|---|
| 0 | the destination now exists and holds the plan |
| 2 | invalid NAME, invalid `--bundle-id`, missing/duplicate/unknown option, missing NAME, extra positional, unsupported `--ui` value, `ptcTemplateUnknown`, `ptcTemplatePrivate` |
| 3 | `pcwParent`, `pcwParentNotWritable`, `pcwDestinationExists`, `pcwDestinationCase`, `pcwStageExists`, `pcwStageCreate`, `pcwWrite`, `pcwVerify`, `pcwMode`, `pcwCommit` |
| 4 | every `TPWebSdkRefusal`, and every runtime `TPWebTplCode` (`ptcPackSize`, `ptcPackDigest`, `ptcArchiveInvalid`, `ptcInventoryCount`, `ptcInventoryMismatch`, `ptcRegistry`) |
| 6 | any `TPWebScaffoldCode` from planning, plus `pcwDescriptor` — each provable only if a *verified* pack disagreed with its own compiled registry, which is an invariant failure and not a user error |

Rejected: a new category 7 for "the destination already exists". It is a
project-scoped refusal about a path the user named, which is exactly what 3
already means, and inventing a category is a visible act that has to earn
itself.

### D3 — the template is Vite, pinned exactly, with no React plugin

Measured on the dev host (node 24.11.1, the CI pin), three candidates
installed and compared:

| candidate | lock entries | required | optional | install scripts | lock lines |
|---|---|---|---|---|---|
| esbuild 0.28.2 (CAP-5 parity) | 57 | 11 | 46 | 1 (`esbuild`) | 969 |
| **vite 8.2.2 (rolldown)** | **70** | **23** | **47** | **1 (`fsevents`, darwin-only)** | **1269** |
| vite 7.3.6 (rollup+esbuild) | 94 | 21 | 73 | 2 | 1593 |

Vite 8 is chosen: `SPEC.md:111`, `phase-plan.md:94` and
`security-model.md:166` all name React/Vite and `pweb dev` running Vite HMR
behind `pweb://app`, so the template CAP-10C must extend is a Vite template.
Vite 7 is *larger* than Vite 8, which is the measurement that removed the
conservative option. `npm audit`: 0 vulnerabilities.

**No `@vitejs/plugin-react`.** Vite 8 compiles `.tsx` through the tsconfig's
`jsx: "react-jsx"` with no plugin — measured, builds and typechecks clean.
The plugin exists for Fast Refresh, which B1 must not implement, and drags
`oxc-transform-react`, `@rolldown/plugin-babel` and
`babel-plugin-react-compiler` in as peers. CAP-10C adds it with HMR.

Exact pins, reusing every existing repository pin that applies:

| package | version | source of the pin |
|---|---|---|
| `react` | `18.3.1` | CAP-5 lock, unchanged |
| `react-dom` | `18.3.1` | CAP-5 lock, unchanged |
| `@types/react` | `18.3.12` | CAP-5 lock, unchanged |
| `@types/react-dom` | `18.3.1` | CAP-5 lock, unchanged |
| `typescript` | `7.0.2` | CAP-5 lock + `sdk/typescript`, unchanged |
| `@pweb/runtime` | `0.1.0` | `sdk/typescript/package.json`, unchanged |
| **`vite`** | **`8.2.2`** | **NEW — the one additive frontend pin this shard asks for** |
| node | `24.11.1` | the CI `setup-node` pin, unchanged |

No caret, no tilde, no `latest`, no range. `esbuild` disappears from the
template's own manifest (it arrives transitively inside Vite's tree at
Vite's pinned version); `examples/04-react` keeps its esbuild build
untouched.

### D4 — the build output shape is the CAP-5-proven shape

`vite.config.ts` pins `entryFileNames: assets/app.js`,
`chunkFileNames: assets/[name].js`, `assetFileNames: assets/[name][extname]`
and `modulePreload.polyfill: false`, so the production tree is exactly

```
frontend/dist/index.html
frontend/dist/assets/app.js
frontend/dist/assets/index.css
```

— index.html at the root plus an `assets/` subtree, which is precisely what
the frozen CAP-6 bundler consumes. **Content hashes are deliberately turned
off**: there is no HTTP cache behind `pweb://app`, so a hash buys nothing and
costs a name that changes with every edit.

Measured on the dev host: script and stylesheet are **external**, the
bundle contains no `eval(`, no `localhost`, no `127.0.0.1`, no `file://`
and no `import.meta.hot`; rebuilding after touching every source mtime
reproduces all three files byte-for-byte.

**The one recorded risk, with its fallback.** Vite emits
`<script type="module" crossorigin src="/assets/app.js">`. No page in this
repository has ever loaded an ES module over `pweb://app` — CAP-5 and CAP-6
both serve a classic IIFE — so "a module script loads from the custom
scheme" is an unproven property on all four engines. The asset handlers
already serve `text/javascript; charset=utf-8`, which is a valid module MIME,
and `crossorigin` adds nothing a module script does not already require
(module fetches are always CORS-mode, and a same-origin URL passes). If any
target refuses it, the ratified fallback is
`build.rollupOptions.output.format: 'iife'` plus a six-line
`transformIndexHtml` that emits a classic `<script src>` — the CAP-5 shape
exactly. The fallback is a config change inside the template, not a design
change, and the artifact records which one shipped.

### D5 — `@pweb/runtime` resolves from the SDK root through a relative build stage

The generated `frontend/package.json` declares

```json
"@pweb/runtime": "file:.pweb/sdk/typescript"
```

— a project-relative specifier, never an absolute path, never a registry, never
a publication. The private build tooling copies the generated project to a
staging path and materializes the **pinned, pre-built** SDK from
`<sdk-root>/share/pweb/sdk/typescript/` into `<stage>/frontend/.pweb/sdk/typescript/`
before `npm ci`. The generated project directory itself is never mutated, and
its byte digest is re-measured after the build to prove it.

Measured end to end on the dev host: `npm install` links it, `tsc -p` passes
with `handshake`/`invoke`/`PWebError` imported, `vite build` bundles it, and
the lockfile records

```json
".pweb/sdk/typescript": { "name": "@pweb/runtime", "version": "0.1.0", "license": "MIT" }
```

with **no absolute path, no home directory and no host name** anywhere in the
file.

The staged SDK is a canonical minimal distribution — `package.json`
(name/version/license/type/main/types/exports only, no `devDependencies`) plus
`dist/src/**` — emitted by a committed script, so the bytes the lockfile
describes are a pure function of the repository. Consequence, stated rather
than smoothed over: **a freshly created project cannot `npm ci` on its own
until a PWeb command stages the SDK.** That is the SDK-root model working as
designed, and the generated README says so.

### D6 — one new reusable host unit; the generated application is thin

New production unit `src/webview/pweb.webview.host.pas`, exposing
`TPWebHostOptions` and `PWebHostRun`. It owns exactly what a PWeb host owns
and an application does not: locating `app.pwb` from the executable (with the
macOS `../Resources` shape), the pre-create platform check, the
handler/guard alias block and Cocoa's two-phase seam, the binding plus the
CAP-8A per-invocation capability snapshot, `TPWebRuntimeCommandBridge` with
the platform opener, the scheduler lifecycle and the exact reverse-order
teardown, and the two ratified CAP-7M2/CAP-7F host arguments
(`--pweb-verdict=<file>`, `--pweb-autoclose-ms=<N>`).

Rejected: generating that choreography into every project. It is ~120 lines
of platform conditionals plus ~250 lines of teardown ordering, and copying it
per application is the "generated platform adapter copy" the scope forbids —
the same reasoning CAP-10A used to promote `pweb.openExternal` out of four
private copies.

**The three existing example hosts are NOT migrated onto it.** Migrating them
would re-baseline `navigation_policy_digest`, `security_corpus_digest` and
`quickjs_gui_digest` for no CAP-10B1 gate. The new unit is purely additive:
no existing production file changes, so CAP-7/8/9 behaviour cannot change.
`test/cap7f/check_divergence.ps1` gains exactly one allowlist row (the new
unit's directive count and fingerprint); every other row, including
`releaseapp.pas` at 38 and `pweb.cli.platform.pas` at 24, is re-ratified
unchanged.

The generated `src/<NAME>.lpr` therefore carries **zero platform
conditionals** — a property the gate measures rather than asserts.

### D7 — the generated application's capability configuration

```
AppMaximum                 ['calculator.add']
window 'main'              ['calculator.add']
principal 'window:main'    ['calculator.add']
MapMethod                  CalculatorService.Add -> ['calculator.add']
RegisterZeroCapMethod      pweb.handshake
RegisterZeroCapMethod      app.ready
```

No allow-all, no `external.open`, no filesystem, process or network
capability, no QuickJS. `TPWebRuntimeCommandBridge` **is** installed with the
platform opener — one runtime-command path is the frozen architecture — but
`pweb.openExternal` is left unmapped, so the CAP-8A policy answers
`forbidden`/403 before the decorator is reached and the opener count is zero
because nothing ran. That is defence in depth, and the corpus records it.

`No.SuchMethod` is deliberately **not** registered. Under a production policy
an unmapped method is `forbidden`/403 — `forbidden` outranks
`method_not_found` by ratified design — so the starter's error probe expects
403, which is the honest production answer rather than the `404` the
allow-all example hosts produce.

`app.ready` is the starter's own zero-cap status channel, the established
`example.report` shape: the page posts one self-check object, the generated
host prints one deterministic line, and a developer deletes it when the demo
goes. It is the only reason the CI runtime gate can see `html`, `css`,
`secure` and `handshake` at all — no framework test hook exists, and none is
added.

### D8 — template-pack supersession, stated as a change and not hidden

Adding `react` changes the corpus. Two packs are now built from one trusted
source:

| pack | `--include` | consumer | contains |
|---|---|---|---|
| test pack | `all` | `tpltests` | `fixture` + `react` |
| **SDK pack** | `public` | the shipped `pweb` CLI | `react` only |

The public CLI compiles against the **public** registry, so it is
structurally incapable of reaching the private fixture — the `RequirePublic`
refusal is a second lock behind a first one. B0's recorded values are
preserved verbatim in its artifact; B1 records the previous and the new
values side by side with the reason. **No claim is made that any template
digest was unchanged.**

Superseded by this shard, with old → new recorded in the final artifact:
`template_digest`, `template_pack_digest`, `template_semantic_digest`,
`template_registry_digest`, `template_file_count`, and — because the parser
grew a command — CAP-10A's `cli_digest`. Unchanged and re-measured:
`doctor_schema_digest`, `navigation_policy_digest`, `security_corpus_digest`,
`quickjs_gui_digest`, `cli_version_line`, `cli_exit_taxonomy`.

The CAP-9C1/CAP-10B0 split is preserved: `template_semantic_digest` is a
four-target equality field, `template_pack_digest` is pinned per target and
reported side by side, and the known `ZIP_OS` made-by divergence remains
accepted.

### D9 — the generated tree, exactly

15 files. 14 template files plus one generated descriptor.

```
demo/
  pweb.json                     GENERATED by the serializer, not templated
  .gitattributes                from `gitattributes`
  .gitignore                    from `gitignore`
  README.md
  src/
    demo.lpr                    from src/program.lpr, out src/{{PASCAL_PROGRAM}}.lpr
    app.services.pas            the service, the policy and the app bridge
  frontend/
    index.html                  Vite root document
    package.json
    package-lock.json
    tsconfig.json
    vite.config.ts
    src/
      main.tsx
      App.tsx
      app.css
      vite-env.d.ts
```

No `app.pwb`, no `plugins.zip`, no executable, no webview library, no mORMot
or PWeb source, no `node_modules`, no `dist`, no `.env`, no database, no
certificate, no installer, no native binary. The set is asserted **exactly**,
in both directions.

No file contains a doubled opening brace: JSX inline styles are replaced by
CSS classes in `app.css`, and the Vite config nests objects with a space
after every `{`. A violation fails the pack build loudly, which is the
CAP-10B0 constraint working rather than being worked around.

### D10 — the private build proof, and what it deliberately is not

A committed CI harness, not `pweb build`, and no build orchestration enters
the CLI command table:

1. `pweb create demo --ui react --bundle-id com.example.demo` from an
   unrelated CWD, with the real staged CLI;
2. digest the generated tree; copy it to an unrelated clean staging path;
3. materialize `<sdk-root>/share/pweb/sdk/typescript` into
   `<stage>/frontend/.pweb/sdk/typescript`;
4. `npm ci`, `npm run typecheck`, `npm run build`;
5. `pwebbundle <stage>/frontend/dist <stage>/app.pwb`;
6. compile `<stage>/src/demo.lpr` against a **staged** PWeb SDK source root
   (not the repository's `src/`), inside the CAP-3U window on Win64;
7. assemble the minimal release layout (executable + `app.pwb` + the
   platform webview library) and run it from an unrelated CWD;
8. re-digest the original generated tree and require it unchanged.

Recorded limitation: mORMot and the webview library are still resolved from
`deps/`, because schema 1 carries no dependency model and CAP-10D owns
packaging. What step 6 *does* prove is that no PWeb path in the generated
project is repository-relative.

---

## Code Map

- `tools/pweb/pweb.cli.args.pas` — the one parser. Add `pccCreate`, a second
  positional for `NAME`, `--ui`/`--bundle-id` with the `--project` value
  discipline, and two usage codes for a missing operand and a missing
  required option. `PWebCliParseArgs` currently refuses a second positional
  outright (`pcuExtraPositional`).
- `tools/pweb/pweb.pas` — `Main` dispatches `pccDoctor` only, and reads the
  CWD once through `PWebCliCwd` in `RunDoctor`. Add `RunCreate` and lift the
  single CWD read so both commands share the one seam.
- `tools/pweb/pweb.cli.report.pas:99` `PWebCliUsageBanner` — the global help;
  add `create` and a `PWebCliCreateHelp`.
- `tools/pweb/pweb.cli.sdk.pas` — `PWebCliTemplatePack` / `PWebSdkRefusalText`;
  read-only, the exit-4 source.
- `tools/pweb/pweb.cli.template.pas:117-330` (bounds, `TPWebTplCode`,
  registry types) and `:453-480` (`PWebTplFind(..., RequirePublic)`,
  `PWebTplLoadPack`, `PWebTplVerifyPack`). Read-only.
- `tools/pweb/pweb.cli.scaffold.pas:200-270` — `PWebScaffoldNameValid`,
  `PWebScaffoldIdentityOf`, `PWebBuildPlan`, `PWebPlanInventoryDigest`, and
  `PWebScaffoldCodeText` for the exit mapping. Read-only.
- `tools/pweb/pweb.cli.write.pas:148` — `PWebCreateProject(ParentDir, Name,
  Plan, Tpl, Res)`; `ParentDir` must already be canonical. Read-only.
- `tools/templates/templates.list` — the trusted declaration and its grammar;
  add the `react` block beside `fixture`.
- `examples/04-react/frontend/**` — the CAP-5 parity source and exact pins.
  **Read-only: not modified to make templating easier.**
- `sdk/typescript/package.json` — `@pweb/runtime` 0.1.0, `main`
  `./dist/src/index.js`; must be built before it can be consumed.
- `examples/08-release/releaseapp.pas` — the composition being generalized:
  aliases at 200-230, `BuildReleasePolicy` at 305-356, `OpenExternalUri` at
  375, the pre-create checks at 480-620, `LoadReleaseBundle` at 640,
  `ParseArguments` at 690, `WriteVerdictFile` at 745, and the construction /
  teardown body from 780. **Read-only.**
- `src/security/pweb.navigation.policy.pas:129` — `PWEB_NATIVE_CSP`
  (`script-src 'self'`, `style-src 'self' 'unsafe-inline'`, no
  `unsafe-eval`). Read-only; the template adapts to it.
- `src/assets/pweb.assets.support.pas:298` — `text/javascript; charset=utf-8`
  for `.js`, which is what makes a module script legal.
- `tools/bundler/README.md` — `app.pwb` needs `index.html` at the root plus
  `assets/`; refuses lockfiles, `*.pas`, `node_modules` and `.map`.
- `tools/pweb/pweb.cli.doctor.pas:628-655` — `frontend.lockfile` requires
  `package.json` **and** `package-lock.json` in `frontend.root`; this is the
  ledgered B0 limitation the template closes.
- `test/cap10b0/build_cap10b0.ps1` / `.sh` — the staged
  `<root>/bin` + `<root>/share/pweb` SDK layout and the `--include all`
  invocation; B1 adds the `--include public` pack and the CLI built against
  it.
- `test/cap10b0/check_cap10b0_contracts.ps1:106-140` — rule 1
  (`create_linked = absent`) must be **inverted**, not deleted.
- `test/cap10b0/run_cap10b0_gates.ps1` — the `create_absent` leg and the
  `--help` absence loop; both invert.
- `test/cap7f/check_divergence.ps1:66-120` — the exact per-file allowlist.
- `test/cap7f/emit_evidence.ps1:744-855` and `emit_evidence.sh` — where the
  CAP-10A and CAP-10B0 records are folded in; B1 adds a third block to both.
- `test/cap7f/check_cap7f_aggregate.ps1` + `check_cap7f_selftest.ps1` — the
  four-target comparison and its negative self-test; every new refusal branch
  needs a fixture leg.
- `test/cap6/build_cap6.ps1` — the exact FPC unit paths, statics and CAP-3U
  window a PWeb host compile needs.
- `.gitattributes:97-115` — the `tools/templates/**` line-ending pins; `*.ts`
  and `*.tsx` are missing and must be added.
- `docs/template-contract.md` §5 — records the future `create` grammar;
  update to what B1 actually exposes.
- `docs/cli-contract.md` §1, §4 — the frozen public surface.

---

## Scope

**MAY:** the trusted `react` template; the public-visibility pack and its
registry; the `create` command, its help and its argument parsing; the exact
React package and lockfile; the generated Pascal application; one reusable
host unit; SDK-root staging for the TypeScript SDK and the PWeb sources;
private CI build/run harnesses; all four target jobs, the aggregator and its
self-test; docs.

**MUST NOT:** implement the Pas2JS template or accept `--ui pas2js`;
implement `dev`, `run` or `build`; run npm, FPC or Git during create; touch
the network during create; copy the PWeb runtime or mORMot into a generated
project; generate `app.pwb` or `plugins.zip`; enable QuickJS by default;
change `pweb.json` schema 1, the B0 transaction, the placeholder set, the
path rules or any bound; add `--force`, `--install` or `--template-path`;
weaken the CAP-8B CSP or navigation policy; migrate the CAP-6/CAP-9 example
hosts onto the new host unit.

---

## Acceptance

1. public `pweb create` command;
2. React the only UI this build supports, and the only one advertised;
3. exact NAME/bundle identity preserved from B0;
4. the React template added to the verified pack;
5. generated `pweb.json` matches schema 1;
6. the generated project is byte-identical on all four targets;
7. no secret and no absolute SDK path in any generated byte;
8. create is offline and executes no external tool;
9. destination creation remains atomic; no failure leaves a partial tree;
10. the generated project passes the real `pweb doctor`;
11. exact React package and lock metadata;
12. `@pweb/runtime` materialized from the trusted SDK root;
13. the frontend typechecks and builds;
14. the generated Pascal application compiles on all four targets;
15. the production CAP-8 policy is used, with no allow-all;
16. the real app loads `app.pwb` over `pweb://app`;
17. `CalculatorService.Add(20,22)` returns 42;
18. typed error mapping passes;
19. no raw primitive, no loose asset, no listener;
20. `dev`, `run` and `build` remain absent;
21. CAP-10A and CAP-10B0 regressions green;
22. CAP-7/CAP-8/CAP-9 regressions green;
23. frozen contracts and pins unchanged except the one ratified `vite` pin;
24. hosted CI green on four targets.

## Test matrix

`CLI1–CLI13` the real compiled executable — help, create help, absent
commands, a successful create, and eleven refusals with exact exit
categories · `TPL1–TPL8` registry validity, the surviving B0 fixture,
per-target determinism, four-target semantic equality, the recorded
supersession, the secret/dev-artifact sweep, the doubled-brace sweep and the
exact generated inventory · `DOC1–DOC5` strict parse, real doctor, identity
projection, no absolute path, relocation · `FE1–FE7` package and lock
exactness, typecheck, production build, `@pweb/runtime`-only imports, no raw
primitive, no HMR code in the output · `NAT1–NAT6` compile on four targets,
production policy, no allow-all, no listener code, no QuickJS, one
scheduler/policy/bridge path · `RUN1–RUN10` the real window, the secure
origin, HTML/CSS/JS, handshake, 42, typed errors, an unrelated CWD, no loose
assets, no listener, clean shutdown · `SEC1–SEC5` no secret, and zero
network, package-manager and compiler activity during create, with the
CAP-8B navigation and CSP invariants unchanged.
