# CAP-10B1 — Final Artifact: the trusted React template and the public `pweb create`

CAP-10B1 closes on hosted run **33127976094** (2026-08-28, commit
`35f288ddc3b5c3b35dc6083afc32be12ee1ba335`, branch
`phase/cap-10/b1-react-scaffold`, baseline `a996751`): all six jobs green,
`cap7 aggregate` recording `create_corpus: PASS` and `proof_corpus: PASS` on
every target, ONE `generated_inventory_digest`
`1ca77cbb8dc0fed5844fa6aa958ca2727ea560f5bda0b50b23e1bd9b360f3230` — 15
files, 65765 bytes — equal on windows-x86_64, linux-x86_64, macos-x86_64 and
macos-arm64, with `pweb.json`
`f18c017a…ba5f8012` and `package-lock.json` `7719d377…b3ef1ac8` equal
everywhere, and `CalculatorService.Add(20, 22) = 42` from a real system
WebView on all four. The committed negative self-test reported **88
aggregator refusals + 2 divergence refusals** on the same run (73+2 before
this shard), so all fifteen new refusal branches are proven red on fixtures
before the real aggregation is trusted.

Two earlier hosted runs are part of the record rather than hidden by it.
Run **33126638202** turned both macOS legs red on a gate that judged the
RUNNER instead of the project, and its Linux leg exposed a digest that two
implementations of one projection could never agree on. Both are described
under *Adversarial review* below; both were defects in this shard's own
gates, and both were found by the four-target matrix rather than by reading
the code.

CAP-10B1 turns the frozen CAP-10B0 engine into a command. It adds ONE
trusted public template, links the scaffold engine into the CLI for the
first time, and proves that the project the command produces builds and runs
to `42` on four targets — while `dev`, `run` and `build` stay unknown
commands.

## What shipped

```
  tools/templates/react/          the trusted public template, 14 files
  src/webview/pweb.webview.host.pas  the reusable release-host composition
  tools/pweb/pweb.cli.args.pas    `create`, NAME, --ui, --bundle-id
  tools/pweb/pweb.cli.report.pas  the global help and `create --help`
  tools/pweb/pweb.pas             RunCreate, and the ONE working-directory read
  tools/stage-ts-sdk.mjs          the canonical TypeScript SDK distribution
  test/cap10b1/                   the create gates and the private build proof
```

`pweb create NAME --ui react --bundle-id <reverse.dns>` produces a
fifteen-file project; `pweb doctor` accepts it; its React frontend
typechecks and builds; its Pascal program compiles; and the result opens a
real system WebView over `pweb://app` and answers
`CalculatorService.Add(20, 22) = 42`.

## The production delta is one file

`git diff --name-status` against the CAP-10B0 closure `a996751` reports, for
`src/`, `sdk/`, `examples/` and `deps/`, exactly one change:

```
A  src/webview/pweb.webview.host.pas
```

No existing runtime source was touched, so CAP-7, CAP-8 and CAP-9 behaviour
cannot have changed by construction rather than by re-measurement — and the
frozen digests are re-measured anyway on the closure run.

## The command, and the one option it deliberately does not have

`--output` is designed in `docs/template-contract.md` §5 and **not
exposed**. CAP-10B0 ratified its meaning but neither a default nor a gate
over it, so shipping it would have meant shipping two destination rules on
the strength of one measurement. CAP-10B1 ships one: `NAME` inside the
captured working directory, read once through the single CAP-10A CWD seam
and never re-read.

`--ui pas2js` is a **usage** failure, refused by a compiled allowlist in the
parser rather than by a template lookup. A CLI whose refusal depends on
what happens to be in an archive is a CLI that would advertise a frontend
the moment somebody added one.

The exit mapping answers CAP-10B0's deferred question with **no new
category**: 2 for the command line and an unsupported or non-public
template, 3 for everything about the destination, 4 for the SDK and the
pack, 6 for a planning failure or a descriptor the frozen reader refuses.
**5 is unreachable** — `create` starts no child process, and the contract
check measures that over the `RunCreate` body rather than asserting it.

## Two packs, and a corpus that changed on purpose

| pack | `--include` | consumer | contains |
|---|---|---|---|
| test pack | `all` | the CAP-10B0 engine suite | `fixture` + `react` |
| SDK pack | `public` | the shipped `pweb` | `react` only |

The public CLI compiles against the **public** registry, so it cannot
describe the private fixture at all; `PWebTplFind`'s `RequirePublic` refusal
is the second lock behind that first one.

**Superseded, and recorded as superseded rather than claimed unchanged:**

| field | CAP-10B0 | CAP-10B1 (run 33127976094) |
|---|---|---|
| `template_digest` | `fe5353efd00e66c7abf40409265a6141447b870ba20ac396b0cf9d168b682af4` | `01f16572fd40f36ab594fd15a630533cf23cf1b7c9e298ae0d7c6c762ce26362` |
| `template_semantic_digest` | `61f381c0ffd0bebb1f0d002232fb03ebac9e159f728d66d557cb457336e90259` | `8ed72f247a105da8f7f77b6d752ba4d484f6d725151b60fa62445137dea0a8f6` |
| `template_file_count` | 8 | 22 |
| `cli_digest` (CAP-10A) | `dc068531acab62c2698c69f29ace521b0382d38c6489a71847c13ca9b8d4114b` | `97c7b846f61834bc1a4d05156c8cea876a2b2ba2d7f1c3b389ec63c5d6cebbe6` |

The `cli_digest` change is the parser growing a command; nothing else in the
CAP-10A decision corpus moved, and `doctor_schema_digest` proves it.

**Unchanged and re-measured on the closure run:** `doctor_schema_digest`
`2dda57baa324708ebc6d709556fc2a4ae865d820e29069c47a0e0d412fa8c7aa`,
`cli_version_line` `pweb 0.1.0 (protocol 1)`, `navigation_policy_digest`
`360d69f2…f0c7212e`, `security_corpus_digest` `c5fc378b…9e5adbdf4`,
`quickjs_gui_digest` `67e08c69…a967b36`.

The CAP-9C1 split is preserved and reproduced exactly. Both packs are the
same length on every target and split by OS family:

| pack | windows + linux | macos x64 + arm64 | bytes |
|---|---|---|---|
| test (`all`) | `4748ce01…3b0cf1bf` | `e327eaa0…01195c67` | 73790 |
| SDK (`public`) | `30ac777e…aa302417` | `31ce1e67…90975e43` | 67635 |

`template_semantic_digest` and `public_semantic_digest` are the four-target
equality fields; the bytes are pinned per target and rebuilt-and-compared on
each one (`PASS` everywhere). Two different CPUs agreeing exactly on macOS
is again what shows this is an OS-family property rather than a per-machine
one.

## The CAP-10B0 rule that was inverted rather than deleted

CAP-10B0's central claim was that the scaffold engine was **not linked into
the CLI at all**, measured against the CLI's own compiled unit set.
CAP-10B1 exposes the command, so the same measurement now has to come out
the other way: every engine unit must be in `build/cap10b1/cli-units`, and
`pweb.pas` must name them. A rule that is removed the moment it stops
holding was never load-bearing.

The same inversion runs through `run_cap10b0_gates.ps1` (`create_absent`
became `create_present`, and a bare `pweb create` is now a `missing_operand`
usage refusal), through the CAP-10A gates and suite, and through the
aggregator and its negative self-test.

Because `pweb` now compiles a generated registry in with `-Fi`, it can no
longer be built before the pack that registry describes exists. So there is
now **one** CLI: CAP-10B1's build produces it, CAP-10A's build consumes it,
and all three shards' gates measure the same executable. Two `pweb` binaries
that could disagree is exactly what the one-runtime rule refuses.

## The dependency seam, and what it actually guarantees

The generated `frontend/package.json` declares
`"@pweb/runtime": "file:.pweb/sdk/typescript"` — project-relative, never a
registry, never a publication. npm records that as `link: true`, so it
**links** the package and never fetches it.

That was tested by breaking it: with `.pweb` removed, `npm ci` still exits 0
and makes a **dangling link**, and the failure arrives at the first
typecheck as `Cannot find module '@pweb/runtime'`. The security property is
therefore stronger than "the version is pinned" — there is no code path on
which a package registry answers for that name — and the generated README
now says exactly that, having first said it wrongly.

The build proof measures the other half: it resolves the link's **reparse
target** and requires it to be the staged SDK. `Resolve-Path` does not
follow a Windows junction and would have compared a link with itself.

## Vite, chosen by measurement

| candidate | lock entries | required | optional | install scripts |
|---|---|---|---|---|
| esbuild 0.28.2 (CAP-5 parity) | 57 | 11 | 46 | 1 |
| **vite 8.2.2** | **70** | **23** | **47** | **1** |
| vite 7.3.6 | 94 | 21 | 73 | 2 |

Vite 7 is *larger* than Vite 8, which removed the conservative option.
`npm audit` reports 0 vulnerabilities, and the lockfile's install-script set
is pinned to exactly `fsevents` by the contract check — so a new one cannot
arrive unnoticed with a routine pin bump. `@vitejs/plugin-react` is absent
because it exists for Fast Refresh, which this shard must not implement.

Six of the seven pins are the existing CAP-5 pins. **`vite 8.2.2` is the one
additive frontend pin this shard asked for.**

The build output is pinned to the CAP-5-proven shape — `index.html` at the
root, `assets/app.js`, `assets/index.css`, no content hashes, external
script and external stylesheet — because there is no HTTP cache behind
`pweb://app` and the frozen CAP-6 bundler wants exactly that tree.

**One risk was recorded at Checkpoint 1 and retired by measurement.** Vite
emits `<script type="module" crossorigin>`, and no page in this repository
had ever loaded an ES module over `pweb://app`: CAP-5 and CAP-6 both serve a
classic IIFE. The ratified fallback was an `iife`-format build. It was not
needed — the module script loads and executes on WebView2, WebKitGTK and
WKWebView alike.

## The generated application, and why it is thin

`src/demo.lpr` registers one service, builds the bridge chain, builds the
policy and calls `PWebHostRun`. It carries **no platform conditional** except
`{$apptype console}` — measured on the template source by the contract
check — because locating `app.pwb`, checking the platform runtime, attaching
the `pweb://app` handler, installing the navigation guard and tearing all of
it down in the exact reverse order belong to `pweb.webview.host`.

Copying that into every scaffolded project is the defect CAP-10A removed
when it promoted `pweb.openExternal` out of four private copies — only
worse, because the copies would be in other people's repositories where no
gate of ours can ever see them again.

The policy is small and explicit:

```
AppMaximum ['calculator.add'] · window 'main' · principal 'window:main'
MapMethod CalculatorService.Add -> ['calculator.add']
RegisterZeroCapMethod pweb.handshake, app.ready
```

No allow-all, no filesystem, process or network capability, no QuickJS.
`TPWebRuntimeCommandBridge` **is** installed with the platform opener,
because one runtime-command path is the frozen architecture — and
`pweb.openExternal` is left **unmapped**, so the policy answers
`forbidden`/403 before the decorator is reached and the opener count is zero
because nothing ran. `No.SuchMethod` is not registered either, so the
starter's error demo shows the honest production answer — 403, not the 404
the allow-all example hosts produce.

**The three existing example hosts were deliberately NOT migrated onto the
new unit.** Doing so would re-baseline three frozen closure digests for no
gate of this shard. The cost is real and is ledgered: there are now two
compositions of one runtime.

## Adversarial review

All sixteen challenges were run. Three produced changes.

- **Can `@pweb/runtime` resolve from an untrusted registry?** The answer was
  better than the claim and the claim was wrong. `npm ci` with the SDK
  absent succeeds rather than failing, because npm links instead of
  fetching; the generated README said it would fail. The README now
  describes what actually happens, and the build proof gained
  `runtime_from_sdk_root`, which resolves the link's reparse target.
- **Can generated code use an allow-all policy, open a listener, or enable
  QuickJS?** All three were runtime-measured and none was refused at the
  source. The contract check now requires an explicit `SetAppMaximum`, and
  refuses `TAllowAllCapabilityPolicy`, any HTTP/socket unit and any script
  unit in the generated Pascal — before anything is built.
- **Can package install scripts execute unreviewed behaviour?** The
  lockfile's `hasInstallScript` set is now pinned to exactly `fsevents`, and
  the generated `package.json`'s script set to exactly `build` and
  `typecheck`.

Two further findings came from the hosted matrix rather than the review, and
both are the four-target aggregate earning its cost:

- **A gate that judged the runner instead of the project.** `pweb doctor`
  answers two questions in one report, and the first draft required exit 0 —
  so `platform.webview: fail/framework_absent` on the macOS runners turned a
  perfectly correct generated project red on two targets. The gate now
  asserts the project-scoped rows and the identity projection, and RECORDS
  the host rows, which is the CAP-10A discipline applied where it belonged.
- **Two implementations of one projection that disagreed about a
  comparer.** The same generated tree digested to `87999e1a…` from the
  PowerShell build proof and `1ca77cbb…` from its bash twin, because
  PowerShell's default `Sort-Object` is culture-aware and `LC_ALL=C sort` is
  bytewise: `App.tsx` and `app.css` order one way under each. A four-target
  equality field over that projection was unsatisfiable by construction.
  Every PowerShell sort feeding a digest is now ordinal behind a named
  helper, with the measurement written at its definition.

## Evidence

New four-target fields: `create_corpus` and `proof_corpus` (both must-PASS)
plus `advertised_ui`, `create_stdout_digest`, `create_refusals`,
`create_no_partial`, `create_deterministic`, `public_pack_digest`,
`public_pack_bytes`, `public_semantic_digest`, `public_registry_digest`,
`public_pack_deterministic`, `public_file_count`,
`generated_inventory_digest`, `generated_inventory_exact`,
`generated_pweb_json_digest`, `generated_package_lock_digest`,
`generated_file_count`, `generated_total_bytes`, `generated_no_host_path`,
`doctor_result`, `generated_tree_digest`, `generated_tree_unchanged`,
`frontend_typecheck`, `frontend_build`, `frontend_no_dev_code`,
`frontend_transport_clean`, `runtime_from_sdk_root`, `native_build`,
`secure_origin`, `rpc_result`, `error_mapping`, `listener_count`,
`raw_primitive_used`, `loose_assets_used`.

Five of them are **absolute pins** rather than mere agreements, because four
targets can agree and still be wrong together: `advertised_ui = react`,
`rpc_result = 42`, `listener_count = 0`, `raw_primitive_used = false`,
`loose_assets_used = false`.

`create_help_digest` is recorded per target and **not** compared — see the
open measurement in `deferred-work.md`. `doctor_exit` and
`doctor_host_failures` are per-host observations and travel the same way the
CAP-10A doctor observations do.

Fifteen create refusals are executed against the real compiled CLI on every
target, each required to produce its own machine-stable cause **and** its
exit category, with the destination parent asserted empty afterwards.
Fifteen new negative self-test legs (c70–c84) prove each new aggregator
refusal branch red on fixtures before the real aggregation is trusted.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler
and source lifecycle, the mORMot bridge, the nine-code taxonomy, protocol
v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json` schema 1, the
CAP-10A parser grammar, doctor and exit taxonomy, the CAP-10B0 scaffold
engine, transaction, path rules and placeholder set, the CAP-8A policy core,
the CAP-8B classifier and CSP, the CAP-9 runtime, package and lifecycle, the
platform adapters, the CAP-13 profiles and every dependency pin:
**unchanged**, except the one ratified additive frontend pin `vite 8.2.2`.

The divergence sweep gains exactly one allowlist row — the new host unit at
30 directives — and every other row is re-ratified unchanged, including
`releaseapp.pas` at 38 and `pweb.cli.platform.pas` at 24.

## Known limitations / deferred

See `deferred-work.md` (CAP-10B1 entries): `--output` designed and not
exposed; the SDK root staged for PWeb but not for mORMot or the webview
library; a freshly created project that cannot `npm ci` standalone; the
CAP-10C HMR handoff; the three example hosts not migrated onto the shared
host unit; `app.ready` as the starter's own channel; the `ci.yml`
documentation budget at 190.0 KB; the `create_help_digest` divergence as an
open measurement; and the comparer lesson.

**CAP-10B1 PASS — REACT SCAFFOLD AND CREATE COMMAND FROZEN**
