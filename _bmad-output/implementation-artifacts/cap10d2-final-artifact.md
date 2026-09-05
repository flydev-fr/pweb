# CAP-10D2 — the PWeb SDK distribution

CAP-10D2 is one artifact and one claim: **everything CAP-10 built is now
something you can hand somebody**, and a machine that never built this
repository can use it.

```
tar -xzf pweb-sdk-0.1.0-<os>-<arch>.tar.gz

<sdk>/bin/pweb doctor
<sdk>/bin/pweb create demo --ui react|pas2js --bundle-id com.example.demo
<sdk>/bin/pweb build [--profile …]
<sdk>/bin/pweb run                                          -> 42
```

Installation is extraction. Nothing else is mutated — no `PATH`, no registry,
no shell profile, no file in a home directory, and nothing to uninstall.

`docs/sdk-contract.md` is the whole of the contract. `pweb --help` still
advertises **five** commands: there is no `pweb sdk`.

---

## 1. Ship / pin

The SDK ships PWeb's framework, its two frontend SDKs, its bundler, its
dependencies' sources and — on Windows — the packaging kit. **It ships no
compiler.**

| component | decision | licence | measured |
|---|---|---|---|
| `bin/pweb`, `bin/pwebbundle` | **ship** | this repository | 1.8 MB |
| `share/pweb/pweb-templates.zip` | **ship** | this repository | 105 KB |
| `share/pweb/src/**` | **ship** | this repository | 2.3 MB |
| `share/pweb/sdk/{typescript,pas2js}` | **ship** | MIT | 65 KB |
| `share/pweb/deps/mormot2/{src,static/<fpc-target>[,delphi]}` | **ship** | MPL 1.1 / GPL 2.0 / LGPL 2.1 | 32 MB |
| `share/pweb/lib/<os>-<arch>/**` | **ship** | MIT + BSD-style | 128 KB |
| `share/pweb/pack/**` | **ship**, Windows only | BSD-style (the loader) | 1.2 MB |
| `share/pweb/licenses/**`, `sdk-manifest.json` | **ship** | — | 84 KB |
| FPC, Node.js, npm | **pin only** | — | doctor rows stand |
| **the Pas2JS compiler** | **pin only** | — | see below |
| the Inno Setup compiler | **pin only** | — | 28 MB avoided |
| the three WebView2 artifacts | **pin only** | Microsoft terms | 523 MB avoided |
| `*.lock` | **never shipped**; digests only | — | `sdk_lock_files_shipped` = 0 |

**288 files, 38 MB, 11.4 MB gzipped** on `windows-x86_64`.

**Pas2JS is pinned, and the second reason is a measurement.** The first is the
rule: FPC, Node and Pas2JS are all host requirements with `pweb doctor` rows,
and bundling one of the three would make the rule "whichever one we felt like
carrying". The second is that **the pinned Pas2JS 3.0.1 archive contains no
`COPYING.FPC`** — its own `packages/rtl/README.txt` refers to a file
"included in this distribution" that is not in it, and `get-pas2js.ps1` moves
the whole archive root into `deps/`, so nothing is being filtered out. This
repository therefore has no offline, pinned, verifiable licence text for it,
and Checkpoint 1's own rule — no component whose licence is not ratified —
refuses it. `docs/third-party-licenses.md` is corrected on the same
measurement: it used to claim those texts ship inside the archive.

**The locks ship as digests and never as files**, and that is a frozen
contract deciding against the brief: `distribution-contract.md` §3, which the
CAP-10D2 handoff inherits verbatim, says the locks carry the vendors'
download addresses and are never shipped into an SDK. The intent behind the
brief's line is served anyway — the manifest records each lock's sha256, so a
package states which lock revision produced it with no address on anybody's
build path.

## 2. The manifest, and exactly what it claims

`share/pweb/sdk-manifest.json`, written by the packager and by nothing else:
schema, `pweb` version, protocol, target, the template pack's three digests,
the six lock digests, the licence set, and for every shipped file its relative
path, byte length and sha256 — bytewise ascending by path, so a duplicate is
impossible and the inventory digest is a function of the set.

**Canonical form, verified rather than trusted.** Fixed key order, two-space
indent, LF, one trailing newline, and the escape set of ECMAScript's
`JSON.stringify` exactly. The reader re-emits what it parsed and requires the
result to equal the bytes on disk, so "canonical" is a *measurement*. Measured
independently: the real 288-file manifest is byte-identical to
`JSON.stringify(JSON.parse(it), null, 2) + "\n"` in Node.

**Verification is FULL, never sampled.** Measured on the four hosted runners
over each target's own shipped set: **34 ms** on Linux (215 files), **81 ms**
on Windows (288 files), **283 ms** and **402 ms** on the two macOS runners
(210 and 213 files) — the slowest of them two fifths of a second, paid on
every doctor run and before every build. That is why there is no sample
policy to argue about: a sample would have made "one altered file is
detected" probabilistic, and a probabilistic tamper claim is not one worth
gating a build on.

| what it catches | what it does not |
|---|---|
| a half-copied SDK, a truncated download, an extraction that lost a file | a manifest rewritten to describe the altered bytes |
| a shipped byte that was altered — a patched mORMot unit, a replaced webview library, a rewritten template pack | its own absence: a root with no manifest is an UNPACKAGED root |
| a manifest that is malformed, non-canonical, of the wrong schema, or that describes a different release | a file ADDED to a shipped directory |

**The anchor, ratified.** The manifest is trusted for the *inventory*; the
**compiled CAP-10B0 registry** stays the authority for the template pack, so
the one artifact a user's new project is generated from is anchored in the
executable rather than in a file beside it — and the packager refuses to ship
a pack whose digest is not the registry's, so a package's two anchors agree by
construction. Compiling the manifest's own digest into `pweb` was considered
and **refused**: it would pin one binary to one package.

`pweb doctor` gains three `required` rows, `not_applicable/sdk_unpackaged` on
a root with no manifest — which is what this repository's own staged build
tree is, and why every CAP-10 gate before this shard behaves byte for byte as
it did. **`doctor_schema_digest` moves** from `2dda57ba…c8fa7aa` to
`3c597c8e…18eb493a`; its ONE absolute pin moves with it.

**The build refuses first.** The CAP-10C1 pipeline asks the question inside
the `open` stage, *before* the descriptor is judged, before the read-only tree
is digested, before a byte is written and before a child is spawned — the
CAP-10D1 `project_root_too_long` precedent, applied to the toolchain's own
bytes. Exit **4**, and `build_stage_count` is still ten.

## 3. C1-11 (c), closed

`PWebCliSdkManifest` re-emitted each value's **source bytes**, which agrees
with `JSON.stringify` only for as long as the input carries no redundant
escape: `A` and `\/` are legal JSON that stringify re-emits as `A` and
`/`. `ReadRawString` now routes every literal through `PWebSdkJsonCanonical`,
the one escape rule the whole distribution uses, and a literal it cannot
decode is a **refusal** rather than a value it guesses at.

Nineteen escape classes and eight normalisations are measured against the
reference, and fifteen forms are measured to be **refused** rather than
repaired — a lone surrogate, an unknown escape, a raw control byte, invalid
UTF-8, an overlong form, a surrogate encoded in UTF-8.

**The mjs script's role is CROSS-CHECKED, not retired**, and that is the
ratification: retiring it would remove the only independent implementation the
Pascal emitter is checked against. The CAP-10C1 ST1 gate keeps requiring
byte-identity on four targets on every leg, and now that the Pascal side
*normalises* rather than copies, the agreement is a real cross-check rather
than a coincidence of formatting. Measured on the real pinned SDK manifest:
byte-identical.

## 4. The packager

`tools/pweb/pwebsdk.pas`, private, in the `pwebtemplates` pattern. It reads
two trees it was told to read and writes the two artifacts it was told to
write: no process, no socket, no URL, no environment read — all four measured
at the source with concatenated, case-sensitive needles over
comment-stripped code, and `packaging_children_spawned` = false and
`packaging_network_calls` = 0 measured at runtime through the CAP-10C1
membership sampler.

**It assembles a declared table; it does not filter a directory.** The staged
SDK root in this repository carries `bin/pwebpipe` — the private CAP-10C1
lifecycle driver, which has to live there because it resolves its root from
the running image exactly as `pweb` does — and a packager that shipped
"whatever is in `bin/`" would have shipped a test driver to users. An
exception list is a thing to forget; an assembler needs none.

Ten refusals, each measured to fire on a fixture root:

| refusal | armed by |
|---|---|
| `sdk_secret_path` | a `.env`, a `server.pem`, a `node_modules` |
| `sdk_build_output` | a `.ppu` inside a SOURCE tree |
| `sdk_component_missing` | a ratified component absent |
| `sdk_lock_missing` | one of the six locks absent |
| `sdk_license_missing` / `sdk_license_unratified` | a notice absent, or one nobody ratified |
| `sdk_template_pack_mismatch` | a pack that is not the compiled registry's |
| `sdk_reparse_point` | a junction on Windows, a symlink on POSIX |

The **dirty-tree** refusal lives in `check_cap10d2_contracts.ps1`, where every
other git-dependent check in this repository lives: a Pascal build tool spawns
nothing, so it cannot ask git anything, and one that took a `--dirty` flag
would be taking somebody's word for it.

**The archive is `tar.gz` on all four targets, Windows included** — a recorded
deviation from the brief, for CAP-10D1's own measured reason. Both ZIP writers
here set `extFileAttr` to the MS-DOS plane and carry no Unix mode at all, so a
Windows-only ZIP would be a second writer with a second determinism claim and
a second inventory comparison — "one rule would become three". `tar.exe` has
been in Windows' System32 since 10 1803, and the gate resolves it **from the
system directory** by exact name rather than through PATH, which is the
CAP-10D1 `expand.exe` rule and which a developer machine made necessary
immediately: a Git/MSYS `tar` earlier on PATH answers `Cannot connect to C:`.

**Determinism is a property of the output.** Two runs of one commit on one
target produce a byte-identical manifest, an equal inventory digest and a
byte-identical archive. Cross-target byte equality is explicitly not claimed;
`sdk_ship_table_digest` — the DECISION, not the bytes — is what four targets
agree about.

## 5. The clean-machine proof

Per target: package, extract with the system `tar` to
`<runner-temp>/étude sdk/` — a space **and** a non-ASCII character — then, with
the checkout's six framework trees renamed aside, from an unrelated working
directory, with the extracted `bin/` **not** on PATH:

`doctor` → `create --ui react` and `--ui pas2js` → `build` both → `run` both →
**42** → `build --profile` for the target's profiles.

**The unreachability mechanism is ratified as six renamed trees**, not the
whole checkout: `build/cap10b1/sdk`, `src`, `sdk`, `deps/mormot2`, `tools`,
`examples`, each renamed under a `finally` that restores unconditionally.
Renaming a hosted runner's own workspace out from under the shell executing
the gate is destructive with no safe recovery if one handle is open, and the
rename is **sufficient rather than necessary** anyway: the claim that matters
is measured separately and is stronger — `checkout_path_in_argv` = 0 over
every stage command line, and every one of 94 `-Fu`/`-Fl` paths under the
extracted root.

**Three defects the leg found, and it found them by being real.** Every one
is a fact about paths that had never been exercised, because no gate before
this shard had ever put an SDK ROOT anywhere but an unspaced, ASCII build
directory.

1. **FIXED.** `PWebCliExeDir` took the running image from the RTL's
   `ParamStr(0)`, which FPC hands a Windows process through an ANSI
   conversion — so an SDK extracted into a directory whose name carries an
   accent resolved to a path the filesystem does not have, and **every
   command refused with `sdk_share_missing` while the extracted tree sat
   there complete**. One new platform primitive, `PWebCliImageDir`
   (`GetModuleFileNameW` on Windows, `Executable.ProgramFilePath` on POSIX
   where a path is bytes), fixes it. It adds no conditional REGION — each
   body already existed and each gained one function — and the CAP-7F
   divergence sweep confirms `pweb.cli.platform`'s count is unchanged at 36.
2. **FIXED, and it is the one that mattered most.** An SDK installed under a
   directory whose name has a **space** could not LINK on macOS. FPC
   accumulates every `-k` pass-through value into one options string and
   re-splits it on whitespace, and `pweb.cli.native` puts two SDK paths
   through `-k` there and only there — `-k-L<lib dir>` and
   `-k<pweb_cocoa_bridge.o>`. `ld` received
   `-L/Users/runner/work/_temp/étude` and `sdk/pweb-sdk-…/lib/macos-arm64`
   as two arguments:
   `ld: warning: search path '/Users/runner/work/_temp/étude' not found`.
   `PWebCliLinkPath` applies **FPC's own rule** to the paths FPC does not
   own — `maybequoted` is what the compiler uses for every `-Fl` directory
   it writes onto the linker line — and it is **conditional**, so a path
   without a space comes back byte-for-byte unchanged and not one argument
   vector CAP-10C1 pinned moves. The CAP-10C1 suite was re-run and is
   unchanged at 213 assertions.
3. **MEASURED HERE, FIXED AFTERWARDS — ledger D2-13, now RESOLVED.** As this
   shard closed, `pwebbundle` — the FROZEN CAP-6 bundler — still read its own
   argv through the same ANSI conversion as (1), so a PROJECT at a non-ASCII
   path failed at the `pack` stage with a message about a directory that is
   plainly there. The CLI's half was already correct: `CreateProcessW`
   delivers a UTF-16 command line intact, and every stage before `pack`
   succeeded on exactly that path. **It was closed on the CAP-6 route this
   shard named as the honest one**, in a separate commit: the bundler reads
   `GetCommandLineW` through `CommandLineToArgvW` on Windows and `ParamStr`
   on POSIX, no option, exit code or archive byte moved, and the CAP-6 gate
   pins the archive from an accented path byte for byte against the
   ASCII-path one. **This shard's clean-machine gate gained CM7 with it**: a
   Windows-only leg that creates and BUILDS a generated project at a spaced
   *and* accented root from the extracted SDK, and requires the `pack` stage
   by name — so `pack` runs exactly where this paragraph said it could not.
   The shape is recorded (`nonascii_project_path`, `nonascii_project_non_ascii`,
   `nonascii_build_exit`, `nonascii_pack_lines`) and the accent is required,
   read back from the path the build actually used. **CM7 stops before
   `run`**, and the boundary is a measurement: the first shape of this leg
   moved the existing react project onto the accented root and went red at
   `pweb run` — `pack` passed — because the generated *application* resolves
   its own `app.pwb` through `Executable.ProgramFilePath`, the same RTL layer
   one level further out and this time in shipped code. That is a separate
   user-facing defect with its own ledger entry and its own owner.

**And one gate defect, worth naming because it is the general shape.** CM1's
first draft required `pweb doctor` on the extracted SDK to report `pass` or
`warning`, and both macOS jobs failed it with
`platform.webview=fail/framework_absent` — which CAP-10C1 already MEASURED on
hosted macOS runners and closed by excluding that one row from the BUILD
verdict by name (ledger C1-15). A gate that required the overall status green
was re-imposing, one layer out, exactly the requirement CAP-10C1 removed. CM1
now asserts what the PIPELINE asserts: no required row other than
`platform.webview` may fail — and the two macOS jobs then build and run to
**42** with it still failing, which is the whole point of C1-15.

**Integrity, end to end:** on the pristine extraction all three rows pass; one
shipped byte flipped **in place** (same length, so only the digest can tell)
→ `sdk_integrity_mismatch`, build exit 4, nothing staged and the `toolchain`
stage never entered; a file removed → `sdk_integrity_missing`; a truncated,
schema-2, wrong-version or merely non-canonical manifest → four distinct
typed causes; and the manifest deleted → `not_applicable/sdk_unpackaged`, a
build that proceeds, because an unpackaged root is a legitimate arrangement.

## 6. The tool-location rule — one rule, no fallback chain

Whether a tool is resolved from the SDK root or from `PATH` is a **compiled
property of the tool**, not a search:

| resolved from the SDK root, PATH never consulted | resolved from PATH, the SDK never consulted |
|---|---|
| `pwebbundle`, the Inno Setup compiler | `fpc`, `node`, `pas2js` |

**No tool is in both columns**, so there is no chain to fall back along. Both
halves are measured at the source — the units that walk the SDK never call the
PATH resolver, and the PATH resolver never names an SDK-shipped tool — and at
runtime, with a decoy `pwebbundle` earlier on PATH leaving the build at exit
0.

## 7. Licences

Four notices, each from the provenance of the material it covers: mORMot's own
`LICENCE.md` from the pinned checkout, the two webview notices from the
directory the webview build wrote its binary into, and the QuickJS notice from
the CAP-9C1 package — **digest-verified** against the value
`docs/third-party-licenses.md` ratifies. The set is per target and the rule is
one table: `LICENSE.quickjs.txt` is absent on macOS because mORMot's static
tree carries `quickjs.o` for Windows and Linux and **not** for either Darwin
architecture, measured rather than assumed.

The gate compares the shipped set to that document's machine-readable table by
name and by condition; the contract check compares the packager's compiled
table to the same document. Both directions, so a component that gains or
loses a notice fails rather than shipping unremarked.

**PWeb's own licence is not declared anywhere in this repository**, so the
distribution ships third-party notices only. That is a real gap in a
distributable product, it is the owner's call rather than a shard's, and
inventing one would be the silent derivation `cli-contract.md` refuses.

## 8. Three stale statements in a frozen contract, corrected

`docs/distribution-contract.md` was written before CAP-10D1's last two commits
and was not brought forward with them. **Nothing in the product moved; the
document did.**

| it said | the code says |
|---|---|
| `dist/<profile>/` | `artifacts/<profile>/` (`PWEB_PACK_ARTIFACTS`) |
| `.pweb-pack.tmp` / `.pweb-dist-old.tmp` | `.pwpack.tmp` / `.pwold.tmp` |
| ISCC from the SDK, "else PATH" | from the SDK **and nowhere else**: there is no PATH branch |

Recorded in a new §11 of that document beside the constant that decides each.
The lesson is what a contract document is for: a frozen statement nobody
re-measures is one that quietly stops being true, and the CAP-10D2 handoff
inherited this document "verbatim" while it disagreed with the code in three
places.

## 9. Every supersession, recorded rather than claimed unchanged

| what | before | after | why |
|---|---|---|---|
| `doctor_schema_digest` | `2dda57ba…c8fa7aa` | `3c597c8e…18eb493a` | the three `sdk.*` rows; the digest is over the row set and severities and never over statuses, so it is the same on a packaged and an unpackaged root and on four targets |
| the SDK root layout | nine entries | **eleven** — `sdk-manifest.json` and `licenses/`, both ADDITIVE and read by no stage | `docs/pipeline-contract.md` §2 |
| `PWebCliSdkManifest`'s strings | the source bytes | the **canonical** escape form | C1-11 (c) |
| `PWebCliExeDir`'s source | the RTL's `ParamStr(0)` | `PWebCliImageDir` — the kernel | a non-ASCII installation path was a lost character |
| the two macOS `-k` linker paths | raw | `PWebCliLinkPath`, quoted iff spaced | a spaced installation path became two linker arguments; IDENTITY otherwise, so `pipeline_digest` and the C1 command matrix do not move |
| the CAP-10A "programs" exclusion | two | **three** (`pwebsdk.pas`) | a program resolves its own CWD and writes its own summary; a unit may do neither |
| the CAP-10D1 console-writer exclusion | one program | **two** | the same rule, for the same reason (C1-11 f) |
| the CAP-7F divergence allowlist | 13 files | **14** — `pwebsdk.pas` at 2 directives | its only conditional is the `{$apptype console}` guard every program carries; `pweb.cli.platform`'s own entry is UNCHANGED at 36 |
| `docs/distribution-contract.md` §3, §6, §7 | three stale statements | corrected | §8 above |
| `build_digest`, `pipeline_digest`, `dev_digest`, `dev_pas2js_digest`, `supervision_digest`, `pack_digest`, `cli_digest` | | **unchanged**, re-measured | CAP-10D2 moves no decision any of them froze |

Nothing else moved. The seven frozen interfaces, `TInvocationContext`,
`ICapabilityPolicy`, the scheduler, the mORMot bridge, the nine-code taxonomy,
protocol v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json` schema 1, the
CAP-10A parser grammar and exit taxonomy, the CAP-10B0 engine, the CAP-10C0
engine and layout, the CAP-10C1 ten stages and mutation set, the CAP-10C2/C3
dev host and ladder, the CAP-10D0 build grammar, the CAP-10D1 identity rules
and pinned inputs, the CAP-8A policy core, the CAP-8B classifier and CSP, the
CAP-9 runtime, **every CAP-13 file**, the three platform adapters and every
dependency pin: unchanged.

## 10. Evidence

| leg | what it proves |
|---|---|
| suite (226 assertions) | the escape rule class by class against `JSON.stringify`, the eight normalisations C1-11 (c) named, fifteen refusals, the document's round trip and every malformed shape's own cause, the `-k` link-path rule (identity, quoted and the real macOS vector) and the verifier over a fixture root for all seven ways an installation can be wrong |
| PK1 | two packaging runs of one commit: identical manifest bytes, identical inventory digest, identical archive bytes |
| PK2 | ten typed refusals, each armed and each measured to fire — including a reparse point, whose leg fails if it cannot arm itself |
| PK3 | the shipped licence set equals `docs/third-party-licenses.md`'s table, by name and by condition, in both directions |
| PK4 | `packaging_network_calls` = 0 and `packaging_children_spawned` = false, sampled by membership with the sampler's own liveness required |
| IN1 | `sdk.manifest`, `sdk.integrity`, `sdk.version` all pass on a pristine extraction, with the timing recorded |
| IN2 | a same-length byte flip and a deleted file: two distinct causes, build exit 4, nothing staged and the toolchain never entered |
| IN3 | malformed, wrong-schema, wrong-version, non-canonical and absent: five distinct answers |
| IN4 | the canonical emitter equals the reference for every escape class (C1-11 (c) closed) |
| CM1/CM2 | React and Pas2JS created, built and run to **42** from the extracted SDK, checkout aside, `bin/` off PATH |
| CM3 | every profile of the target built from the extracted SDK |
| CM4 | `checkout_path_in_argv` = 0 and 94 unit/library paths, all under the extracted root |
| CM5 | a decoy `pwebbundle` on PATH changes nothing |
| CM6 | four exported root variables change nothing, and no unit reads one |
| CL1-CL4 | eleven runs cited, the SPEC acceptance table at 7 met + 1 deviated, 163 ledger entries with **0 orphans**, `docs/sdk-contract.md` and the index |

Emitted per target into `build/cap10d2/cli-<target>.json` and aggregated field
by field by `test/cap7f/check_cap7f_aggregate.ps1`, which now carries
**fifty-four** CAP-10D2 decisions compared across four targets, seventeen
per-target facts required present and compared on none, and **forty-eight**
absolute pins — the values four targets could agree on and still be wrong. Ten
negative self-test legs (e1–e10) prove the new refusals fire.

**The hosted runs.** The closure HEAD, and the closure commit's own
aggregation:

| HEAD | hosted run | what was green |
|---|---|---|
| `1714b65c` | 33919712393 | the closure HEAD: all six jobs, ONE `sdk_digest` `b33df77e…` and ONE `sdk_ship_table_digest` `1308731a…` on four targets, **42** from both UIs out of an extracted SDK on every one, and the CAP-7F negative self-test firing its ten new refusals before the aggregate ran |
| `a32cd668` | 33924083318 | the closure COMMIT's own aggregation: all six jobs green again over the artifacts this shard wrote, with `cap10_runs_cited` at eleven and `cap10_ledger_orphans` at zero on four targets |

Three hosted runs were spent, and the two that were not green each bought a
real defect: 33914729625 measured the macOS clean-machine failure that a
gate printing only stderr could not explain, and 33917202306 printed the
children's own lines and named it — `ld: warning: search path
'/Users/runner/work/_temp/étude' not found`.

## 11. Cross-links

| document | what it freezes |
|---|---|
| [../../docs/sdk-contract.md](../../docs/sdk-contract.md) | this shard's contract |
| [../../docs/pipeline-contract.md](../../docs/pipeline-contract.md) | the SDK root, the ten stages and the mutation set |
| [../../docs/distribution-contract.md](../../docs/distribution-contract.md) | `pweb build --profile`, and the three statements CAP-10D2 corrected |
| [../../docs/third-party-licenses.md](../../docs/third-party-licenses.md) | the machine-readable shipped licence subset |
| [cap10d1-final-artifact.md](cap10d1-final-artifact.md) | the handoff this shard consumed |
| [cap10-closure-artifact.md](cap10-closure-artifact.md) | the PHASE closure this shard writes |

---

## Verdict

**CAP-10D2 PASS — SDK DISTRIBUTION FROZEN, CAP-10 CLOSED**

One SDK distribution per target, deterministic inventory and manifest; a
ratified ship/pin table with the licence set complete and no download
anywhere; a canonical manifest with the doctor's three integrity rows and the
build's exit-4 refusal, tamper detected, C1-11 (c) closed; the clean-machine
proof on four targets with the checkout aside and 42 from both UIs; one
tool-location rule with no fallback chain; installation is extraction; the
CAP-10 closure artifact with the SPEC acceptance table, 165 ledger entries at
0 orphans and the CAP-11 handoff; every regression green on the recorded
supersessions; every frozen contract and pin unchanged; hosted CI green on the
final HEAD.
