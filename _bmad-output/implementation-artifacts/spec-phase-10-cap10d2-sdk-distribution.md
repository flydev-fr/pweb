---
title: 'CAP-10D2 — the PWeb SDK distribution, its integrity model, and the closure of CAP-10'
type: 'feature'
created: '2026-09-04'
status: 'draft'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** everything CAP-10 built runs out of a repository checkout. There is
one staged SDK root (`build/cap10b1/sdk`), assembled by four build scripts, and
no way to hand somebody a PWeb that works on a machine that never built this
repository. Nothing verifies that an SDK is whole, so a half-copied or tampered
installation compiles silently against whatever bytes are there. And CAP-10 has
no closure: ten shards, 150 ledger entries and a SPEC acceptance line nobody has
ticked against evidence.

**Approach:** one private trusted-build tool (`tools/pweb/pwebsdk.pas`, in the
`pwebtemplates` pattern) assembles a ratified component set out of the staged SDK
root and writes two artifacts — a canonical `share/pweb/sdk-manifest.json` and
one deterministic archive per target. `pweb doctor` gains three rows over that
manifest and the CAP-10C1 pipeline refuses at `open`, before any write or spawn,
when the SDK it is about to compile against does not match its own manifest.
Four hosted targets then prove the whole claim on a clean machine with the
checkout renamed aside. CAP-10 closes with a phase artifact, a line-by-line SPEC
acceptance table, a phase-wide ledger gate at 0 orphans and the CAP-11 handoff.

## Boundaries & Constraints

**Always:**
- the SDK root layout of `pipeline-contract.md` section 2 moves only by recorded
  ADDITIVE entries: `share/pweb/sdk-manifest.json` and `share/pweb/licenses/`.
- one canonical JSON emitter and one escape rule, used by the writer and by the
  verifier and by the CAP-10C1 TypeScript-SDK re-emitter alike.
- verification is FULL: every manifest entry's byte length and sha256. Measured
  at 285 files / 38.5 MB, so a bounded sample would trade a deterministic claim
  for nothing.
- the packager spawns nothing, opens no socket and names no URL.
- installation is extraction. No PATH, registry, shell profile or home-directory
  write, at any point, on any target.
- every shipped third-party component carries its licence text exactly once
  under `share/pweb/licenses/`, and the set equals the shipped subset documented
  in `docs/third-party-licenses.md`.
- every deviation from the CAP-10D2 brief is recorded with the measurement or
  the frozen contract that forced it.

**Ask First:**
- moving a frozen digest, contract or dependency pin without a precedent.
- spending hosted CI on a leg the brief did not ask for.

**Never:**
- a public command or option. `pweb --help` still advertises five commands.
- `PWEB_SDK`, `PWEB_HOME`, `PWEB_MORMOT` or any environment-based root.
- a download at package, build or doctor time; a lock file inside the shipped
  SDK (`distribution-contract.md` section 3 freezes that the locks never ship).
- a change to the build grammar, the identity rules, the dev loop, the seam,
  `PWEB_NATIVE_CSP`, the privileged origin, schema 1, the seven interfaces, the
  adapters, the ten stages, the mutation set or any pin.
- CAP-11 or CAP-12 work.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| package | a staged SDK root and a clean checkout | `pweb-sdk-0.1.0-<os>-<arch>.tar.gz` plus a canonical `sdk-manifest.json`; identical inventory, manifest and archive bytes across two runs | N/A |
| package refuses | a reparse point, a `.env`, a credential-shaped name, `node_modules`, a build output, an absent lock, an absent licence, an unratified licence | typed refusal naming the logical path, nothing written | exit 1, one cause each |
| doctor pristine | an extracted SDK | `sdk.manifest`, `sdk.integrity`, `sdk.version` all pass | N/A |
| doctor unpackaged | the repository's staged root before packaging | all three `not_applicable`, cause `sdk_unpackaged` | N/A |
| doctor tampered | one shipped byte altered | `sdk.integrity` fails, cause `sdk_integrity_mismatch`, detail is the logical path | doctor exit 4 |
| build tampered | one shipped byte altered | pipeline refuses at `open`, cause `sdk_integrity_mismatch`, exit 4 | nothing staged, nothing spawned |
| build no manifest | the repository's staged root | unchanged CAP-10D0/D1 behaviour, byte for byte | N/A |
| manifest malformed | truncated, wrong schema, or version different from the running `pweb` | `sdk_manifest_malformed` / `sdk_manifest_schema` / `sdk_version_mismatch`, build refused exit 4 | typed rows |
| canonical escapes | a manifest string carrying a quote, a backslash, a slash, `\b\f\n\r\t`, a C0 byte, `A`, `é`, a surrogate pair | exactly `JSON.stringify`'s output for the same value | invalid UTF-8 or a lone surrogate refuses |
| clean machine | archive extracted to a spaced, non-ASCII path, checkout renamed aside, `bin/` not on PATH | doctor passes, `create` plus `build` plus `run` answer 42 for both UIs, no spawned argv names the checkout | N/A |

</frozen-after-approval>

## Code Map

Production, new:
- `tools/pweb/pweb.cli.sdkmanifest.pas` — NEW. The manifest model, the canonical
  JSON emitter and its escape rule, the strict reader, and the verifier
  (`PWebCliSdkVerifyIn` / `PWebCliSdkVerify` producing `TPWebCliSdkFact`).
  Depends only on `mormot.core.base`, `mormot.crypt.core`, `pweb.cli.platform`,
  `pweb.cli.sdk` — low enough that `pweb.cli.doctor` may use it.
- `tools/pweb/pwebsdk.pas` — NEW. The private packager, in the
  `tools/pweb/pwebtemplates.pas` pattern (`ParseArgs`/`Die`, explicit arguments,
  no spawn, no socket, two artifacts). Includes
  `pweb.templates.registry.inc` exactly as `tools/pweb/pweb.pas:181` does, so the
  compiled CAP-10B0 anchor travels into the manifest's `templates` block.

Production, touched:
- `tools/pweb/pweb.cli.doctor.pas:130-137` (`TPWebCliDoctorEnv`) — gains
  `Sdk: TPWebCliSdkFact`; `PWebCliRealEnv` fills it; three rows added to the
  requirement graph. Moves `doctor_schema_digest`.
- `tools/pweb/pweb.cli.pipeline.pas:512-532` (the `open` stage, beside the
  CAP-10D1 `project_root_too_long` refusal, which is the precedent: refused
  before the tree is digested, before any write, before any spawn).
- `tools/pweb/pweb.cli.stage.pas:864-899` (`PWebCliSdkManifest`) — the raw-byte
  re-emitter becomes a canonical re-serializer over the new escape rule. This is
  ledger item C1-11 (c).
- `tools/pweb/pweb.cli.toolset.pas:401-407` — the doctor row `sdk.integrity`
  reaches the pipeline through the existing `FirstRequiredFailure` adoption; no
  new plumbing.

Read-only evidence the design rests on:
- `docs/pipeline-contract.md` section 2 — the SDK root, and the anchor rule.
- `tools/pweb/pweb.cli.packpins.pas` — the compiled-pins/no-URL discipline the
  manifest's lock-digest block follows, and `PWEB_PACK_DEPS_*`/`PWEB_PACK_*`, the
  names of the packaging kit inside an SDK.
- `tools/pweb/pweb.cli.tar.pas` — the D1 deterministic writer, reused verbatim.
- `test/cap10b1/build_cap10b1.*`, `test/cap10c1/build_cap10c1.*`,
  `test/cap10d1/build_cap10d1.*` — the four scripts that stage the ONE SDK root;
  `build/cap10c1/bin/pwebpipe` is copied into `<sdk>/bin/` and is the reason the
  packager assembles a declared set instead of filtering a directory.
- `test/cap10c3/check_cap10c_ledger.ps1` — the ledger gate whose key scheme
  (`<shard>-<ordinal>` plus the sha8 of the summary) the phase-wide gate reuses.
- `test/cap10a/run_cap10a_gates.ps1:270-281` — how `doctor_schema_digest` is
  computed; `test/cap10c1/run_cap10c1_gates.ps1:825-829` — its ONE absolute pin.
- `test/cap7f/check_cap7f_aggregate.ps1:285-360` — the per-target and compared
  field lists, and the CAP-10D1 lesson about which list a new block belongs in.

## Tasks & Acceptance

**Execution:**
- [ ] `tools/pweb/pweb.cli.sdkmanifest.pas` -- NEW: manifest record, canonical
      emitter plus escape rule, strict reader, full verifier -- one writer and
      one verifier over one canonical form.
- [ ] `tools/pweb/pwebsdk.pas` -- NEW: the private packager over the ratified
      component table, the licence set, the lock digests and the D1 tar writer.
- [ ] `tools/pweb/pweb.cli.doctor.pas` -- add the three `sdk.*` rows and the
      injected fact -- the doctor is the one place a machine is diagnosed.
- [ ] `tools/pweb/pweb.cli.pipeline.pas` -- refuse at `open` on
      `sdk_manifest_*` / `sdk_integrity_*` with exit 4 -- nothing staged, nothing
      spawned, `build_stage_count` still ten.
- [ ] `tools/pweb/pweb.cli.stage.pas` -- route `PWebCliSdkManifest` through the
      canonical re-serializer -- closes C1-11 (c).
- [ ] `test/cap10d2/` -- build scripts (`.ps1` and `.sh`), the unit suite
      (`d2tests.pas`, `pweb.test.sdk.pas`), the gate (`run_cap10d2_gates.ps1`),
      the contract check (`check_cap10d2_contracts.ps1`) and the phase ledger
      gate (`check_cap10_ledger.ps1`).
- [ ] `docs/sdk-contract.md` -- NEW; `docs/index.md`,
      `docs/third-party-licenses.md`, `docs/distribution-contract.md` (sections 3,
      6 and 7 are stale against the shipped code) and `docs/pipeline-contract.md`
      section 2 updated.
- [ ] `_bmad-output/implementation-artifacts/cap10-closure-artifact.md` -- NEW:
      eleven runs, the SPEC acceptance table, every ledger disposition, the
      CAP-11 handoff.
- [ ] `.github/workflows/ci.yml` -- four jobs gain the D2 steps and the archive
      upload; `test/cap7f/check_cap7f_aggregate.ps1` gains the D2 fields, split
      correctly between compared and required-present.

**Acceptance Criteria:**
- Given a hosted runner of any of the four targets, when the D2 gate runs, then
  one SDK archive is produced whose inventory digest, manifest bytes and archive
  bytes are identical across two packaging runs of the same commit.
- Given that archive extracted to a path with a space and a non-ASCII character
  with the checkout renamed aside and the extracted `bin/` off PATH, when
  `pweb doctor`, `pweb create --ui react|pas2js`, `pweb build` and `pweb run`
  are executed from an unrelated working directory, then both UIs answer 42, no
  spawned argv names the checkout and every `-Fu` and `-Fl` path lies under the
  extracted root.
- Given a pristine extracted SDK with one shipped byte altered, when
  `pweb doctor` runs then `sdk.integrity` fails naming the logical path, and when
  `pweb build` runs then it exits 4 having staged nothing and spawned nothing.
- Given `sdk_licenses_complete`, when the gate compares
  `share/pweb/licenses/` against the shipped subset of
  `docs/third-party-licenses.md`, then the two sets are equal on every target.
- Given the phase ledger gate, when it parses every CAP-10 ledger entry, then
  `cap10_ledger_orphans = 0` and every disposition comes from the closed set.
- Given the SPEC's CAP-10 acceptance, when the closure table is read, then every
  line is met with cited evidence or carries a named ratified deviation.

## Design Notes

**The escape rule (ratified).** Exactly `JSON.stringify`'s: a quote becomes
`\"`, a backslash `\\`, U+0008/000C/000A/000D/0009 become `\b\f\n\r\t`, any
other code point below U+0020 becomes `\u00xx` with lowercase hex, and every
other byte is literal — a forward slash is not escaped and non-ASCII is not
escaped. Input is decoded first (`\uXXXX` and surrogate pairs included) and
re-encoded, so a redundant escape in the source normalises. Invalid UTF-8 or a
lone surrogate is a refusal, not a rewrite.

**The anchor (ratified).** The manifest is trusted for INVENTORY; the compiled
CAP-10B0 registry stays the authority for the template pack. A tampered mORMot
unit is caught by the inventory digest. A tampered manifest paired with a
tampered file, and an SDK whose manifest was deleted, are OUT OF SCOPE and said
so plainly: the manifest is not signed, and compiling its digest into `pweb`
would pin one binary to one package.

**The archive is `tar.gz` on all four targets** — a deviation from the brief's
`zip on Windows`, for the reason CAP-10D1 already measured when it refused
`tar(1)`: one rule, one determinism claim, one inventory comparison. The two ZIP
writers in this repository have no Unix mode plane, `tar.exe` has been in
Windows' System32 since 10 1803, and a second writer would be a second thing to
prove.

**pas2js and Inno Setup are PIN ONLY.** The SDK ships PWeb's framework, its two
frontend SDKs, its bundler and its dependencies' sources; it ships no compiler,
exactly as it ships no FPC and no Node. For pas2js there is a second, measured
reason: the pinned 3.0.1 archive contains no `COPYING.FPC` — its own
`packages/rtl/README.txt` names one that is not in the archive — so this
repository has no offline, pinned, verifiable licence text for it, and
Checkpoint 1's own rule refuses a component whose licence is not ratified.

**The SDK-shipped tool rule (one rule, no fallback chain).** Whether a tool is
resolved from the SDK root or from PATH is a COMPILED property of the tool, not
a search: `pwebbundle` and `ISCC` are SDK-root-only and PATH is never consulted
for them; `fpc`, `node` and `pas2js` are PATH-only by the CAP-10A rule and the
SDK is never consulted for them. No tool is in both columns, so there is no
chain to fall back along, and both halves are measured at the source.

## Verification

**Commands:**
- `pwsh test/cap10d2/check_cap10d2_contracts.ps1` -- expected: PASS, no violation.
- `pwsh test/cap10d2/check_cap10_ledger.ps1` -- expected: 0 orphans, 0 strays.
- `test/cap10d2/build_cap10d2.ps1` (Windows) or `.sh` (WSL, Linux, macOS) --
  expected: the packager, the suite and the drivers build; both new units
  compile in isolation.
- `pwsh test/cap10d2/run_cap10d2_gates.ps1` -- expected: PK1-PK4, IN1-IN4,
  CM1-CM6, CL1-CL4 all PASS and `build/cap10d2/cli-<target>.json` emitted.
- `pwsh test/cap10c1/run_cap10c1_gates.ps1` -- expected: green on the NEW
  `doctor_schema_digest`, whose single absolute pin this shard supersedes.
