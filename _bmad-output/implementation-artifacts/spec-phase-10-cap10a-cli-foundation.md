---
title: 'CAP-10A — Native pweb CLI foundation, project contract, doctor, and reusable runtime-command composition'
type: 'feature'
created: '2026-08-27'
status: 'done'
review_loop_iteration: 0
baseline_commit: '1b4c81b184929ef4cdc802163e339c7c53654acc'
context:
  - '_bmad-output/specs/spec-pweb/conventions.md'
  - '_bmad-output/specs/spec-pweb/security-model.md'
  - '_bmad-output/specs/spec-pweb/deployment.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** PWeb has a proven runtime (CAP-1..CAP-9) and no public entry point. Every
lifecycle action today is a per-shard PowerShell/bash script that knows the repository
layout, so a third-party developer has no way to describe a project or to ask whether
their machine can build it. Two debts block the rest of Phase 10: `pweb.openExternal`
lives as four byte-similar private copies (`examples/08-release/releaseapp.pas`,
`examples/07-quickjs/quickjsapp.pas`, `test/cap8b/navmatrix.pas`,
`test/cap8c/multiprincipal.pas`) that CAP-10B would multiply into every generated host,
and the canonical `security-model.md` still describes the gesture-based opener CAP-8B
measured to be undecidable and removed.

**Approach:** Ship one native FPC console executable `pweb` under `tools/pweb/` carrying
exactly `--help`, `--version` and `doctor`; one strict schema-1 `pweb.json` descriptor with
deterministic discovery and root-confined paths; a structured doctor engine with byte-equal
human and JSON projections over one result model and bounded, shell-free tool probes. Promote
the external-open command into one reusable `IInvocationBridge` decorator in `src/rpc/`, migrate
all four copies to it, and re-run the CAP-8/CAP-9 external-open gates unchanged. Ratify — but do
not implement — the dev-mode trust model, and mechanically pin the production trust profile
against it.

## Boundaries & Constraints

**Always:**
- The public lifecycle entry point is Pascal. No Node, Python, PowerShell or shell CLI.
- The CLI is offline and inert: it opens no socket, downloads nothing, installs nothing,
  mutates no registry, no PATH, no project file, no lock file and no `.env`.
- Every child process is launched by exact absolute executable path with an argument array,
  bounded timeout, bounded stdout+stderr capture, closed stdin and a killed child on timeout.
  Never `cmd.exe /c`, `/bin/sh -c`, `system()`, `popen`, mORMot `RunRedirect`/`RunCommand`.
- Project paths are relative, forward-slash, syntactically validated by the shared
  `PWebAssetPathValid`, then resolved segment-by-segment from the canonical project root with
  exact case and reparse-point/symlink refusal. Never a lexical prefix test.
- The canonical project root is captured once at startup; nothing later reads the CWD.
- Human and JSON doctor output derive from the same structured result array. JSON carries no
  ANSI, no timestamp, no prose that is not a fixed literal.
- `Effective = AppMaximum ∩ Principal ∩ Window ∩ RuntimeGrants`, the nine-code taxonomy, the
  seven interfaces, the scheduler, protocol v1, `app.pwb`, `plugins.zip` and every dependency
  pin stay byte-unchanged. `pweb.openExternal → external.open` keeps its exact CAP-8 mapping.
- A privileged WebView never navigates to external content; an approved `https`/`mailto` URI
  reaches the OS only through the capability-authorized runtime invocation.

**Ask First:**
- Any change to `IInvocationBridge`, `pweb.rpc.mormot.pas`, the scheduler path, the frozen
  contract units, or any lock file.
- Splitting `.github/workflows/ci.yml` per platform.
- Adding an eighth interface, a new export, a new wire method, or a second RPC path.
- Making `pweb doctor` execute anything that resolves inside the project root.
- Freezing a public CLI/descriptor/doctor field name not ratified at Checkpoint 1.

**Never:**
- `create`, `dev`, `run`, `build` — not implemented, not stubbed, not listed in help.
- Generating project files, starting a watcher, a WebView or a supervised app; producing
  `app.pwb`/`plugins.zip`; assembling releases or installers; touching CAP-13 provisioning.
- A package manager, global user configuration, telemetry, or network access.
- Implementing the dev proxy or the HMR WebSocket.
- Reading the descriptor from `app.pwb`, `plugins.zip`, browser storage, JavaScript or
  frontend output; accepting secret-bearing descriptor fields.
- Restoring gesture-based opener behaviour.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Help | `pweb --help` | usage on stdout listing only `doctor`; no ANSI when redirected | exit 0 |
| Version | `pweb --version` | exactly `pweb 0.1.0 (protocol 1)` | exit 0 |
| No command | `pweb` | usage on stderr | exit 2 |
| Unknown command / option / duplicate singleton / missing value / `--project=` empty / `--` / invalid UTF-8 / embedded NUL | any | one diagnostic line on stderr naming the offending token | exit 2 |
| `@file`, `/foo` | any platform | treated as positional, never expanded, never an option | exit 2 (unknown command) |
| Explicit project | `--project <dir\|dir/pweb.json>` | that descriptor only, canonicalized once, no upward search | missing/misnamed/non-exact-case → exit 3 |
| Upward discovery | no `--project` | nearest ancestor `pweb.json` from startup CWD, ≤64 levels, first match wins | none found before filesystem root → exit 3 |
| Descriptor refusals | malformed JSON, BOM, trailing content, comment, duplicate key, unknown key, secret-suggestive key, `schema≠1`, bad `ui`, bad identifier, non-strict UTF-8, >64 KiB | typed refusal code + one diagnostic | exit 3 |
| Path refusals | absolute, `..`, `.`, empty segment, backslash, drive/UNC, ADS/device name, control/NUL byte, `%`, reparse point on the chain, case mismatch | typed refusal naming the field | exit 3 |
| Doctor healthy | injected healthy environment | every required check `pass`; `doctor: PASS` | exit 0 |
| Doctor optional gap | optional tool absent | `warning` row, `doctor: PASS` | exit 0 |
| Doctor environment gap | required tool absent / malformed version / version below floor / configuration invalid | distinct `observed` category per cause, `fail` row | exit 4 |
| Doctor probe gap | spawn failure, timeout, output over bound | `fail` row with probe category; child killed; no deadlock | exit 5 |
| Doctor JSON | `--json` | canonical UTF-8 document, fixed key order, no ANSI, no timestamp, byte-identical for identical injected observations | exit as above |
| Tool inside project root | resolved executable under the canonical project root | `fail`, never executed | exit 4 |
| `pweb.openExternal` allowed | authorized principal, `https:`/`mailto:` URI | opener invoked exactly once, success envelope | — |
| `pweb.openExternal` denied | principal without `external.open` | `forbidden`/403 pre-bridge; opener count 0 | — |
| `pweb.openExternal` invalid | any other scheme, over-length, control byte, missing/non-string `url` | `invalid_request`; opener count 0 | — |
| Any other method | e.g. `CalculatorService.Add` | delegated to the inner bridge unchanged | — |

</frozen-after-approval>

## Code Map

**Evidence read-only (never modified by this shard)**
- `_bmad-output/specs/spec-pweb/SPEC.md`, `phase-plan.md` (Phase 10 row), `conventions.md`
  (layout, naming, FPC 3.2.2 floor, commit rules), `deployment.md` (Linux/Windows runtime facts).
- `_bmad-output/implementation-artifacts/cap8-final-artifact.md` (CAP-8 PASS),
  `cap9c2-final-artifact.md` (CAP-9 closure), `spec-phase-7-cap7f-final-integration.md`
  (`status: done`). Hosted CI green for the CAP-9 closure commit `1b4c81b`: run **33047734796**.
- `deferred-work.md` — the CAP-8C entry "RESOLVED (success-path evidence) / REVIEW DEFER
  (consolidation)" is the item this shard closes; the `ci.yml` documentation-budget entry
  (167 KB) names CAP-10 as the natural owner of the per-platform split.

**Reused, unchanged**
- `src/security/pweb.navigation.policy.pas` — `PWebValidExternalUri` :295 (the only external-URI
  gate), `PWEB_NATIVE_CSP` :120, `PWEB_EXTERNAL_URI_MAX_BYTES`, `PWebNavTrustedUri`.
- `src/assets/pweb.assets.support.pas` — `PWebAssetPathValid`, `PWebStrictUtf8`.
- `src/assets/pweb.assets.bundle.pas` — `PWebSemVerParse` / `PWebSemVerValid` / `PWebSemVerCompare`.
- `src/rpc/pweb.rpc.intf.pas` — `IInvocationBridge` :333, `TInvocationContext`,
  `PWEB_PROTOCOL_VERSION`, `PWEB_JSON_NULL`. `src/rpc/pweb.rpc.support.pas` —
  `PWEB_RUNTIME_VERSION`, `PWebSuccessResult`, `PWebDefaultErrorResult`.
- `src/platform/windows/pweb.platform.webview2.runtime.pas` — `PWebWv2Detect`,
  `PWebWv2DetectionUsable`, `PWEB_WV2_MIN_BUILD` (1587), `PWebWv2StatusText`.
- `src/assets/pweb.assets.folder.pas` — the ratified confinement model this shard re-applies to
  directories: Windows `FinalPathOfHandle` :179, POSIX `F_GETPATH`/`O_NOFOLLOW` block :86-104.
- `tools/bundler/pwebbundle.pas` — the precedent for a Pascal console tool in this repository.
- `test/cap6/build_cap6.ps1` — the exact `fpc` flag shape for a tool compile.
- `test/cap6/check_cap6_nonetwork.ps1` — the source-sweep shape reused for no-network/no-shell.

**Modified**
- `examples/08-release/releaseapp.pas` — `METHOD_OPEN_EXTERNAL` :214, `OpenExternalUri` :378
  (KEEP: host-private platform selection, its 6 directives untouched), `OpenExternalResult` :416
  (DELETE), `TReportingBridge.Invoke` :448 (delegate to the shared decorator).
- `examples/07-quickjs/quickjsapp.pas` — same shape: `METHOD_OPEN_EXTERNAL` :147,
  `OpenExternalUri` :515 (KEEP, counts `OpenerReached`), `OpenExternalResult` :529 (DELETE),
  `TGateBridge.Invoke` (delegate).
- `test/cap8b/navmatrix.pas` :323 and `test/cap8c/multiprincipal.pas` :456 — same, with their
  counting observers preserved exactly (`CountOpenOk/Refused/Failed`, per-principal arrays).
- `test/cap7f/check_divergence.ps1` — add `tools/pweb` to `$pascalRoots`; allowlist the CLI's
  platform regions by count + fingerprint. The two hosts' entries (38 / 34) must NOT move:
  their `{$ifdef}` regions are deliberately untouched.
- `test/cap7f/emit_evidence.ps1` / `.sh`, `test/cap7f/check_cap7f_aggregate.ps1`,
  `test/cap7f/check_cap7f_selftest.ps1` — the new corpus fields and their refusal branches.
- `.github/workflows/ci.yml` — CAP-10A steps in all four platform jobs.
- `_bmad-output/specs/spec-pweb/security-model.md` — the CAP-8B R-A rewording (doc only).
- `_bmad-output/implementation-artifacts/deferred-work.md` — close the consolidation entry,
  append the new residuals.

**New**
- `src/rpc/pweb.rpc.command.pas` — the reusable runtime-command decorator. Zero platform
  conditionals by construction (the opener is injected), so it stays off the divergence allowlist.
- `tools/pweb/pweb.pas` — `program pweb;` (verified: FPC 3.2.2 x86_64 compiles a program named
  `pweb` alongside dotted `pweb.cli.*` units and emits `pweb.exe`).
- `tools/pweb/pweb.cli.args.pas`, `pweb.cli.paths.pas`, `pweb.cli.project.pas`,
  `pweb.cli.probe.pas`, `pweb.cli.toolchain.pas`, `pweb.cli.doctor.pas`, `pweb.cli.report.pas`.
- `test/cap10a/clitests.pas` (+ `mormot.core.test` cases), `build_cap10a.ps1`/`.sh`,
  `run_cap10a_gates.ps1`/`.sh`, `check_cap10a_contracts.ps1`, `check_dev_trust.ps1`,
  `fixture/` (valid and hostile descriptors).
- `docs/cli-contract.md` — the public CLI/descriptor/doctor-JSON contract and the dev-trust record.

## Tasks & Acceptance

**Execution:**
- [x] `src/rpc/pweb.rpc.command.pas` -- add `TPWebExternalOpener`, `TPWebOpenOutcome`,
      `TPWebOpenObserver`, `PWEB_METHOD_OPEN_EXTERNAL`, `PWEB_CAP_EXTERNAL_OPEN` and
      `TPWebRuntimeCommandBridge` (constructor raises on nil inner or nil opener) --
      one implementation of the command semantics for every host present and future.
- [x] `examples/08-release/releaseapp.pas` -- delete the local result function and method
      literal, install the decorator, move the redacted log into an observer -- the release host
      stops carrying a private copy while its platform regions stay byte-identical.
- [x] `examples/07-quickjs/quickjsapp.pas` -- same, observer also increments `OpenerReached`.
- [x] `test/cap8b/navmatrix.pas`, `test/cap8c/multiprincipal.pas` -- same, observers preserve the
      existing counters so `navigation_policy_digest` and `security_corpus_digest` stay equal.
- [x] `tools/pweb/pweb.cli.args.pas` -- deterministic long-option parser, UTF-8/NUL validation,
      duplicate and missing-value refusals, typed usage errors -- one parser, no platform divergence.
- [x] `tools/pweb/pweb.cli.paths.pas` -- canonical root resolution, exact-case segment walk,
      reparse/symlink refusal, deepest-existing-prefix resolution for absent leaves.
- [x] `tools/pweb/pweb.cli.project.pas` -- strict JSON reader (duplicate/unknown/secret keys,
      BOM, comments, trailing bytes, size bound), schema-1 record, identifier grammars, discovery.
- [x] `tools/pweb/pweb.cli.probe.pas` -- PATH enumeration (no CWD, no project-local execution),
      bounded no-shell child execution with size-bounded stdout+stderr and killed child on timeout.
- [x] `tools/pweb/pweb.cli.toolchain.pas` -- the pinned expectations, cross-checked against the
      lock files by CI -- one source of truth per pin.
- [x] `tools/pweb/pweb.cli.doctor.pas` -- the `source`-mode requirement graph, the injected
      environment record, and the structured result array.
- [x] `tools/pweb/pweb.cli.report.pas` -- human and canonical-JSON emitters over one result array.
- [x] `tools/pweb/pweb.pas` -- wiring, exit-code mapping, console/colour policy, no stack traces.
- [x] `test/cap10a/clitests.pas` -- the C/P/D/R/T matrices as `mormot.core.test` cases.
- [x] `test/cap10a/*.ps1` / `*.sh` -- build, real-host doctor probe, corpus emission, contract
      cross-checks, no-shell/no-network sweeps, dev-trust gate.
- [x] `test/cap7f/*` and `.github/workflows/ci.yml` -- four-target wiring, evidence fields,
      aggregator equality, negative self-test refusals, divergence-root extension.
- [x] `_bmad-output/specs/spec-pweb/security-model.md` -- apply the CAP-8B R-A wording.
- [x] `docs/cli-contract.md`, `deferred-work.md` -- publish the contract, close the consolidation
      entry, ledger the residuals.

**Acceptance Criteria:**
- Given the four platform targets, when `pweb --help`, `--version`, `doctor` and `doctor --json`
  run, then the CLI decisions, the exit codes and the doctor JSON schema are identical on all four
  and only explicitly typed platform observations differ.
- Given a hostile descriptor corpus, when the CLI resolves it, then every vector is refused with
  its typed code and no path resolves outside the canonical project root.
- Given `pweb doctor` on a real CI host, when it completes, then the filesystem, registry, PATH,
  project and lock files are byte-unchanged and no process listened on a socket.
- Given the CAP-8 and CAP-9 external-open gates, when they re-run after the consolidation, then
  `navigation_policy_digest`, `security_corpus_digest`, `quickjs_*_digest` and the
  `opener_main`/`opener_login`/`opener_plugin` ledgers are unchanged.
- Given a repository-wide search, when it looks for a host-local external-open implementation,
  then only `src/rpc/pweb.rpc.command.pas` implements it and only the four hosts' private
  platform-opener selections remain.
- Given the production security profile, when the dev-trust gate runs, then it contains no
  `ws:`/`wss:`/`localhost`/`127.0.0.1` allowance and the privileged origin is exactly `pweb://app`.
- Given hosted CI, when the shard closes, then all six jobs are green on one run.

## Spec Change Log

## Design Notes

**Descriptor — schema 1, every key required, no optional keys.** Growth happens by schema bump,
never by an optional field that an older CLI would refuse and a newer one accept.

```json
{ "schema": 1, "name": "my-app", "version": "0.1.0", "bundleId": "com.example.myapp",
  "ui": "react",
  "native": { "program": "src/myapp.lpr" },
  "frontend": { "root": "frontend" },
  "output": "dist" }
```

Grammars, all ASCII, all exact-match: `name` `^[a-z][a-z0-9]*(-[a-z0-9]+)*$` (1..64);
`version` strict `X.Y.Z` via `PWebSemVerValid`; `bundleId`
`^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$` (2..5 labels, 1..128) — the single application-identity
anchor, so CAP-10B/D derive the Windows AppId and `CFBundleIdentifier` from it by a documented
rule instead of from a display string; `ui` exactly `react` or `pas2js`. The **basename of
`native.program` without its extension** IS the Pascal program identifier and the executable base
name and must match `^[a-z][a-z0-9]*$` — explicit, never derived.

**Doctor requirement graph.** CAP-10A implements exactly one mode, `source`. Required in it:
`fpc` ≥ 3.2.2 with the host's expected target; host architecture; the host WebView engine
(Windows `PWebWv2Detect` + build ≥ 1587; Linux `dlopen` of `libwebkit2gtk-4.1.so.0` and
`libgtk-3.so.0`; macOS product version ≥ 12.0 and `WebKit.framework` present); and, by `ui`,
Node ≥ 20.19.0 + npm + a `package-lock.json` beside `frontend.root/package.json`, or
`pas2js` == 3.0.1. The Inno Setup, WebView2 artifact, Xcode 16.4 / SDK 15.5, mORMot and static
asset rows belong to the future `build`/`release` modes and CAP-10A emits **no row at all** for
them — an absent row is honest, a `not_applicable` row for a check nobody can answer is not.

**Doctor JSON.** `{"doctor":1,"cli":{…},"host":{…},"project":{…},"summary":{…},"status":…,
"exit":…,"checks":[…]}`; checks ordered by `id`; every check carries
`id,status,severity,summary,observed,expected,remediation`. Paths are redacted by default —
inside the root as `<project>/rel`, otherwise `<external>/basename` — which is also what makes the
corpus four-way comparable; `--with-paths` opts into absolute paths.

**Exit codes.** `0` success · `2` usage · `3` invalid/missing project · `4` required environment
check failed · `5` probe could not be executed or bounded (spawn failure, timeout, output over
bound) · `6` internal. Precedence 6 > 5 > 4 > 3 > 2 > 0; warnings never change the code; human text
never changes the category; no stack trace by default.

**Runtime-command decorator.**

```pascal
type
  TPWebExternalOpener = function(const Uri: RawUtf8): Boolean;
  TPWebOpenOutcome = (pooRefused, pooFailed, pooOpened);
  TPWebOpenObserver = procedure(const Context: TInvocationContext;
    Outcome: TPWebOpenOutcome; UriBytes: PtrInt);
```

`invocation → scheduler policy call site (unchanged) → TPWebRuntimeCommandBridge → validate →
host opener` for `pweb.openExternal`, `→ FInner.Invoke` verbatim for everything else. No
`IInvocationBridge` change, no new interface, no new scheduler path, no platform conditional in the
decorator, no shell string anywhere. The three-branch platform opener stays host-private — that is
what "the host supplies the opener" means and it keeps the two hosts' ratified divergence
fingerprints byte-stable; only the command semantics and the two literals consolidate.

**Dev trust (ratified, not implemented).** The privileged origin is `pweb://app` in development
and production alike; `pweb dev` will proxy the frontend behind that handler; the only development
allowance is one `ws://127.0.0.1:<native-selected-port>` CSP data-channel entry for React HMR —
never a privileged-origin change, never a wildcard, never in a production build; Pas2JS dev needs
no WebSocket. CAP-10A records this in `docs/cli-contract.md` and pins the production side
mechanically: `check_dev_trust.ps1` fails if `PWEB_NATIVE_CSP` or any production source gains a
`ws:`/`wss:`/`localhost`/`127.0.0.1` allowance, or if any production artifact names a privileged
origin other than `pweb://app`.

**No-shell proof.** `pweb.cli.probe.pas` is the only unit that starts a process; it uses FPC's
`process` unit, whose POSIX body calls `fpexecv`/`fpexecve` (verified in the pinned FPC source) and
whose Windows body calls `CreateProcessW` — never a shell. `check_cap10a_contracts.ps1` sweeps
every CLI source for `cmd.exe`, `/bin/sh`, `system(`, `popen`, `RunRedirect`, `RunCommand`,
`ExecuteProcess`, `ShellExecute`, `SetCurrentDir` and `ChDir`, and asserts `GetCurrentDir` appears
exactly once (the single startup capture).

## Verification

**Commands:**
- `pwsh test/cap10a/build_cap10a.ps1` -- expected: `pweb.exe` and `clitests.exe` compile clean.
- `build/cap10a/bin/clitests.exe /noenter` -- expected: every C/P/D/R/T case passes, exit 0.
- `pwsh test/cap10a/run_cap10a_gates.ps1` -- expected: the real-host doctor probe runs
  non-mutating, the corpus is written to `build/cap10a/`, all negative vectors refuse.
- `pwsh test/cap10a/check_cap10a_contracts.ps1` -- expected: lock↔constant cross-checks pass, the
  no-shell and no-network sweeps report zero hits.
- `pwsh test/cap10a/check_dev_trust.ps1` -- expected: PASS, production profile free of any HMR
  allowance.
- `pwsh test/cap7f/check_divergence.ps1` -- expected: PASS, allowlist-only divergence, the two
  hosts still at 38 and 34 with unchanged fingerprints.
- `pwsh test/cap6/build_cap6.ps1; pwsh test/cap6/run_cap6_gates.ps1` -- expected: the CAP-6/CAP-8
  release gates green after the host migration.
- `build/cap8b`/`build/cap8c` real-window gates and the CAP-9 suites -- expected: identical
  digests to the CAP-9C2 closure run.

**Manual checks (if no CLI):**
- Hosted CI: all six jobs green on one run, `cli_corpus: PASS` on four targets, one `cli_digest`
  and one `doctor_schema_digest` equal across them, and the negative self-test reporting its new
  refusal branches red on fixtures before the real aggregation is trusted.
