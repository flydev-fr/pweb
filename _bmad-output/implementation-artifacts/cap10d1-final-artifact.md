# CAP-10D1 — distributable artifacts

CAP-10D1 is one option and one claim: **a developer who has just run
`pweb build` can produce, from that same release, one thing somebody else
can install or unpack — on four targets, with no script in between, and
without downloading anything.**

```
pweb create demo --ui react|pas2js --bundle-id com.example.demo
cd demo
pweb build --profile normal|offline|fixed-runtime   # windows
pweb build --profile archive                        # linux, macos
```

Without `--profile`, `pweb build` is byte-for-byte CAP-10D0 — and that is a
branch that is not taken rather than a sentence: `build_digest` is still
`1d5230a9…ff08fb18`, the summary is still the same five indented rows, and
no artifact directory comes into existence.

`docs/distribution-contract.md` is the whole of the contract.

---

## 1. The grammar

```
pweb build [--project <path>] [--profile <name>]

  windows-x86_64             normal | offline | fixed-runtime
  linux-x86_64, macos-*      archive
```

**The parser takes all four names on all four targets.** A parser whose
accepted set differed per platform is precisely the divergence CAP-10A
forbids, so `pweb build --profile normal` *parses* on Linux and is then
refused by the **command** — `profile_not_for_target`, exit 2, before the
project is opened. That separation is why **CAP-10D1 adds no usage cause**:
the CAP-10A taxonomy is still thirteen.

**The name is `fixed-runtime`, never `fixed`.** The brief writes `fixed`;
`deployment.md` names `fixed-runtime`, `pwebappsetup.issi` validates
`|normal|offline|fixed-runtime|` case-sensitively, that exact string is what
is written to a user's machine as the HKCU profile marker, and
`check_cap6b4_contracts.ps1` pins it. A shorter CLI spelling would put two
names on one mode. `--profile fixed` is refused like `--profile msix`, and
the refusal is measured.

The eight options CAP-10D0 refused are still refused.

## 2. Identity, and the two rules that decide collisions

| identifier | rule |
|---|---|
| Inno `AppId` | the `bundleId` **literal**, refused above 127 (Inno's ceiling; schema 1 allows 128) |
| `AppName` / `AppVersion` | `pweb.json` `name` / `version` |
| install directory | `{localappdata}\Programs\<vendor>\<app>` |
| profile marker | `HKCU\Software\PWeb\Apps\<bundleId>`, value `Profile` |
| uninstall registration | Inno's `<AppId>_is1` |
| setup basename | `<name>-<profile>-setup`, never `setup` |
| archive name | `<name>-<version>-<os>-<arch>.tar.gz` |
| `CFBundleIdentifier` | `bundleId` — the CAP-10C1 rule, unchanged |

`<vendor>` is the `bundleId` up to its **last** dot and `<app>` the last
label, so the pair is a **bijection** with the identifier: two applications
with different `bundleId`s can never share an install directory, which is
what makes the CAP-6b4 stale-tree reclaim safe to inherit. Same `bundleId`
⇒ same `AppId` ⇒ a rebuild **replaces itself**.

There is **no `AppPublisher`**: schema 1 states no organisation, and
inventing one is the silent derivation `cli-contract.md` refuses.

A metacharacter is **refused, never escaped** — nine bytes plus every
control byte, re-checked immediately before a value becomes a `/D` define.

## 3. Windows: the CAP-13 mechanics, for a generated application

**A generic manifest set was required, and the justification is two frozen
gates rather than a preference.** `pwebappsetup.issi` authors its `AppId`,
name, install directory and marker key as **literals**, and
`check_cap6b1_contracts.ps1:196-236` matches the literal `AppId=` directive
while `check_cap6b4_contracts.ps1:107-135` pins the marker key. Turning
either into a define breaks a CAP-13 gate. So CAP-10D1 authors
`tools/setup/app/` and **touches no CAP-13 file at all**.

**The fork is measured, not accepted.** `check_cap10d1_contracts.ps1`
requires the `[Code]` region of `app/pwebappprov.issi` to be
**byte-identical** to `pwebprovgate.issi`'s, and `app-fixed.iss`'s to
`fixed.iss`'s. The provisioning gate, the ownership-checked stale-tree
reclaim and the fixed-runtime verdict gate a generated installer runs are
therefore the bodies CAP-6b1, CAP-6b2 and CAP-6b3 proved at runtime, and a
CAP-13 body that moves without its twin is a red step.

| profile | hosted evidence | the claim it supports |
|---|---|---|
| `normal` | build → index → silent per-user install → launch → **42** → silent uninstall → path-scoped drain → zero residue, marker and registration both gone | *a generated application installs, runs and uninstalls cleanly from a PWeb-built installer* |
| `offline` | build + `Compressing:` payload inspection + index cross-check | *the artifact embeds the validated standalone and nothing else*; its runtime provisioning is CAP-6b2's, over the identical `[Code]` |
| `fixed-runtime` | cabinet verified → `expand` → loader → build + index cross-check | the same shape; the ACL/Authenticode verdict gate is CAP-6b3's, over the identical `[Code]` |

**Zero network is a property, not a promise.** No unit on the packaging path
links an HTTP client or names a URL — the locks that carry the vendors'
addresses are repository metadata and are never shipped into an SDK. An
absent pinned input is **exit 4** whose remediation names the provisioning
script; a **drifted** one is a *different* exit 4; and both are answered by
the **preflight, before the pipeline runs**, so a missing 212 MB artifact
costs one second rather than a full build.

**The cabinet is expanded from bytes already verified.** CAP-6b3's build
script additionally Authenticode-verifies the freshly expanded tree because
it expands a cabinet it has just re-fetched; that axis is not re-derived
here. The axis that protects a **user** is the one over the **deployed**
bytes, and that is the unchanged gate inside the installer.

## 4. Linux and macOS: one deterministic archive, written here

`<name>-<version>-<os>-<arch>.tar.gz`, one top-level directory, entries
bytewise-sorted, `mtime 0`, `uid`/`gid` 0, **empty** `uname`/`gname`, plain
ustar, mode `0755` on the program, the shared library and every directory
and `0644` otherwise — read from the release's own execute bit, never from a
name — gzipped through mORMot, whose header carries no timestamp.

Two alternatives were **measured** and refused, and the suite keeps
measuring them:

| candidate | measurement | verdict |
|---|---|---|
| the frozen CAP-6 ZIP writer | `extFileAttr` is `$A0`, MS-DOS attributes with no Unix mode plane — read back out of a real archive | **refused**: an extracted program loses its execute bit |
| a supervised `tar(1)` | GNU has `--sort=name`, macOS's bsdtar does not | **refused**: one rule would become three |

The macOS `.app` needs nothing more: the ad-hoc signature the linker applies
on arm64 lives **inside** the Mach-O, so tar preserves it and `codesign -dv`
on an extracted copy still answers — where a `ditto` zip would add
`__MACOSX` entries the inventory comparison would have to explain away.

## 5. The macOS posture, stated as a promise

`deployment.md` §*Out of scope* ratifies it; CAP-10D1 states what it means:

> The bundle is **not signed with a Developer ID and not notarized**. It runs
> on the machine that built it and on any machine it reaches without passing
> through quarantine. A copy downloaded by a browser carries
> `com.apple.quarantine` and Gatekeeper refuses it until the user removes
> that attribute or right-click-opens it. On arm64 the linker applies an
> **ad-hoc** signature, which satisfies the kernel's page-signing requirement
> and asserts no identity whatsoever.

`macos_codesign_observation` records `adhoc | unsigned | signed_identity`
per target; the third is a gate failure. There is **no `--sign`, no identity
lookup, no keychain access and no credential read** anywhere, and the source
gate sweeps thirteen spellings of signing and nine of a transfer.

## 6. Where the artifact lands — and the name that had to move

```
<output>/<os>-<arch>/
  release/                    UNTOUCHED by packaging, digested before and after
  artifacts/<profile>/
    <artifact>
    release-index.json        the CAP-6b4 seam, schema 1, four keys
```

**Not `dist/`, and that is a measurement.** The brief specifies
`dist/<profile>/`; the gate's first real run found that
`<output>/<target>/dist` is **already** the Pas2JS static assembly
directory the frozen CAP-10C1 pipeline writes (`PWEB_FE_DIST`,
`pweb.cli.pipeline.pas:711`), so an artifact of that name sits inside the
frontend staging tree and the next build is free to replace it. The frozen
layout did not move; the name did.

`artifacts/<profile>/` is replaced by the **CAP-10D0 rule, unchanged** —
stage aside, rename, reclaim — and a failed commit puts the previous
artifacts back. The index is written from the artifact **this run measured**,
never from what happens to be on disk.

## 7. One execution path, at five

Packaging children run through the CAP-10C0 engine and nothing else, in
`pepSupervise`, with the same sink, stop check, descendant drain and typed
outcome mapping every stage child gets. The enumerated caller set moves
**four → five** — `dev, package, pipeline, probe, run` — and the count was
never the invariant: *one engine, an enumerated caller set, and a build
driver that spawns nothing* is, and all three are re-measured on every leg.
`pweb.cli.build` still names **no** process API by any of the thirteen swept
spellings.

Packaging is **not** an eleventh stage: `build_stage_count` is still ten.

Exporting the pipeline's nested `RunStage` was considered and refused — it
closes over the run result, the notify context and the redaction tables, and
refactoring a frozen unit's spine to keep a count at four is the worse trade.

## 8. The four inherited ledger items, disposed of

| item | disposition |
|---|---|
| **C1-11 (a)** the toolset collapse | **CLOSED, RECORDED-ONLY**, on the second measurement its own disposition asked for. CAP-10D1 *does* need a resolution without the requirement graph — the preflight answers before the doctor runs — and it gets one from `PWebCliResolveTool`/`PWebCliRunProbe`, the CAP-10A primitives already below `PWebCliResolveToolset`. Measured: `pweb.cli.package` names `PWebCliResolveToolset` zero times |
| **C1-11 (b)** the `hadOld` rollback | **CLOSED.** `{$ifdef PWEB_LAYOUT_FAULTS}` arms a hook between the two renames; the suite arms it, requires `plrCommit`, and then requires the previous release **back in place and byte-identical**. Exactly one compile command passes the define, and the sweep that proves it cannot satisfy itself |
| **C1-11 (f)** the per-call-site `Flush` | **CLOSED as not needed**, with the reason promoted from observation to gate: no unit under `tools/pweb` writes to the console except `pweb.pas`, which has exactly two write sites and two flushes |
| the Windows long path | **DISPOSED.** The owner is still the pinned compiler; what changed is that it is no longer the thing that fails. `open` refuses `project_root_too_long` (exit 3) before anything is written or spawned, and the bound is **bracketed on the hosted runner** by three probe builds — the gate fails unless the pinned value lies strictly between the largest root that builds and the smallest that does not |

## 9. Every supersession, recorded rather than claimed unchanged

| what | before | after | why |
|---|---|---|---|
| `build_execute_callers` | four | **five**, `pweb.cli.package.pas` added | packaging runs real children through the one engine; the count was never the invariant |
| `cli_digest` | `9eb329ae…` | `4aa3c03b…` | the parser corpus records `args\|build --profile offline\|ok` where it recorded `unknown_option`, plus six rows for the option's value discipline and its per-command scope — exactly as CAP-10C0 moved it for `run`, CAP-10C2 for `dev` and CAP-10D0 for `build` |
| the D0 unratified-option list | nine | **eight**, `--profile` removed | it left the list in the shard that ratified its semantics |
| the pipeline bounds table | eight | **nine**, `PWEB_CLI_PIPE_MAX_ROOT_CHARS` | the first entry that table has ever gained, and the only one that is measured on a runner rather than chosen |
| the CAP-10A `--profile` case | `unknown_option` | accepted, with six new rows | the recorded supersession behind `cli_digest` |
| the D0 gate's option matrix (B9) | `--profile offline` → `unknown_option` | **three legs**: bare → `missing_value`, empty → `empty_value`, `run --profile` → `option_not_for_command` | ratifying an option is a supersession in **two** places, and the first hosted run found the one that was missed. The matrix does not get shorter: `--profile` is held to the same grammar every other build option obeys, so B9 still measures "the surface refuses everything it has not ratified" |
| the CAP-10C3 driver's whole-file write | one delete-then-`CREATE_NEW` | the same, **retried** for a bounded two seconds | PD7 rewrites the input set ~25×/s *while a build is in flight*, so it races PAS2JS's own read of that file. Nothing in the product changed; a driver that reported a compiler's file handle as `move_write_failed` was reporting the wrong thing |
| the CAP-7F cross-target equality set | the CAP-10D1 block pasted in whole: **44 per-target fields compared, 0 shared facts** | **31 shared facts compared, the 44 named in a deliberately-absent note** | CAP-7F keeps two lists that read alike and mean opposite things — required-present and compared-across-four. One paste put the per-target block in both, so a green run produced 124 disagreements that were all the aggregate asking Linux to have installed a Windows setup — and, worse, left `pack_digest`, the five-caller set, `signing_identity_used`, `secrets_read`, the rollback seam and the interrupt compared on **no** target. The 31 were **measured** equal on four real evidence files before being written |
| `build_digest`, `pipeline_digest`, `dev_digest`, `dev_pas2js_digest`, `supervision_digest`, `doctor_schema_digest` | | **unchanged**, re-measured | CAP-10D1 changes no decision any of them froze |

Nothing else moved. The seven frozen interfaces, `TInvocationContext`,
`ICapabilityPolicy`, the scheduler, the mORMot bridge, the nine-code
taxonomy, protocol v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json`
schema 1, the CAP-10A parser grammar and exit taxonomy, the CAP-10B0 engine,
the CAP-10C0 engine and layout, the CAP-10C1 ten stages and mutation set,
the CAP-10C2/C3 dev host and ladder, the CAP-8A policy core, the CAP-8B
classifier and CSP, the CAP-9 runtime, **every CAP-13 file**, the three
platform adapters and every dependency pin: unchanged.

## 10. Evidence

| leg | what it proves |
|---|---|
| suite | the profile allowlist and its per-target answer, the identity derivation and every metacharacter refusal, the AppId ceiling and the value one below it, two `bundleId`s that cannot collide and one that replaces itself, the ustar's absent host state, the two ratified modes, byte-equal writes, the two **measured** writer refusals, and the `hadOld` rollback |
| W1 | a generated application's normal installer: silent install into the user profile, launch, **42**, silent uninstall, path-scoped drain, zero residue, marker and registration both gone |
| W2/W3 | offline and fixed-runtime built from validated pinned inputs, payload inspected, index cross-checked against the artifact that landed |
| W4 | two `bundleId`s installed **side by side** with distinct directories, markers and registrations; one project rebuilt keeps **one** registration |
| W5 | an absent pinned input → exit 4 naming `get-webview2-runtime.ps1`; a **drifted** one → a different exit 4; the preflight refused, so the committed artifacts never moved |
| W6 | a compiler whose pin stamp is not the ratified one → exit 4 naming `get-innosetup.ps1` |
| W7 | a metacharacter identity refused at the descriptor, with no output directory produced |
| W8 | `release/` byte-identical before and after every profile; `artifacts/<profile>/` replaced whole with neither temporary sibling surviving |
| L1/M1 | the archive's inventory and per-file digests **equal the release**, mode 755 on the program, and an extracted copy answers **42** from an unrelated working directory |
| L2 | two builds of the same release produce a **byte-identical** archive |
| M2/M3 | `codesign -dv` observed per target; `CFBundleIdentifier` is the descriptor's `bundleId` and the `Info.plist` is CAP-10C1's |
| A1 | a foreign profile → exit 2, typed, **nothing built** and no artifact directory created |
| A2 | `pweb build` without `--profile`: `build_digest` at its CAP-10D0 closure value, five indented summary rows, no `artifacts/` |
| A3 | no signing spelling, no credential spelling and no transfer spelling anywhere on the packaging path; `signing_identity_used = false`, `secrets_read = 0` |
| A4 | a **real** interrupt during a profiled build leaves the previously committed artifacts byte-identical, the release untouched, no staging sibling and **zero** descendants |
| A5 | the four inherited ledger items disposed, and the long-path bound bracketed by measurement |

Emitted per target into `build/cap10d1/cli-<target>.json` and aggregated
field by field by `test/cap7f/check_cap7f_aggregate.ps1`, which refuses a
missing target, a packaging verdict that is not PASS, a diverging decision
corpus, a signing identity, a secret read, an altered release, a moved
CAP-10D0 corpus, a sixth engine caller, an unexercised rollback seam, a
surviving descendant, an artifact directory without `--profile`, a foreign
profile that built something, a pin mismatched against its lock, a lost
anti-fork equality, an undisposed ledger item or a SKIP promoted to a pass.
**Every one of those refusals has a negative self-test leg that proves it
fires** (d1–d15).

**The hosted run.** CAP-10D1's closure HEAD and the hosted run that was
green on it:

| shard | closure HEAD | hosted run | what it proved |
|---|---|---|---|
| CAP-10D1 | `89538dee` | 33883767131 | all six jobs green. One `pack_digest` `03ab486c…27eaec6f` — 39 decisions — equal on windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64, alongside the five-caller set, `pack_code_twins = 2`, `pack_pins_checked = 14` with `pack_pins_mismatched = none`, `signing_identity_used = false`, `secrets_read = 0`, `rollback_seam_exercised = true` and `pack_descendants_after_interrupt = 0` — the thirty-one facts four machines must agree about. Per target: a generated application **installed, ran 42 and uninstalled with zero residue** on Windows, two `bundleId`s side by side and a rebuild replacing itself; an extracted archive answering **42** at mode 755 with an inventory equal to the release on Linux and both macOS targets; `adhoc` on arm64 and `unsigned` on x64, `CFBundleIdentifier` = the descriptor's; the long-path bound **bracketed on the runner** (140 builds, 180 refuses `project_root_too_long`, pin 160) and the cabinet's own depth **re-measured** (119 = 119). `d0_build_digest` re-measured **unchanged** at its CAP-10D0 closure value `1d5230a9…ff08fb18`. The aggregate's own negative self-test fired **216** refusals first |

## 11. Cross-links

| document | what it freezes |
|---|---|
| [../../docs/distribution-contract.md](../../docs/distribution-contract.md) | `pweb build --profile` — this shard's contract |
| [../../docs/build-contract.md](../../docs/build-contract.md) | the public build command and the release replacement rule |
| [../../docs/pipeline-contract.md](../../docs/pipeline-contract.md) | the ten stages, their bounds and the release layout |
| [../../docs/cli-contract.md](../../docs/cli-contract.md) | the command surface, schema 1 and the six exit codes |
| [cap10d0-final-artifact.md](cap10d0-final-artifact.md) | the handoff this shard consumed |

---

## Verdict

**CAP-10D1 PASS — DISTRIBUTABLE ARTIFACTS FROZEN**

`pweb build --profile` is ratified on four targets: three Windows installer
profiles over the CAP-13 mechanics, one deterministic archive on Linux and
macOS, one identity derived from `pweb.json` and refused rather than escaped,
zero network, no signing identity and no credential read anywhere on the
path. `pweb build` without `--profile` is byte-for-byte CAP-10D0.
