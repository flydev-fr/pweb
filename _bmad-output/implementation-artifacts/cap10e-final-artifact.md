# CAP-10E — kernel-resolved image path in every shipped host

**Corrective shard on shipped code.** One defect, one helper, every site, a
four-target proof, and every supersession measured rather than assumed.

---

## SITE AUDIT

Swept: `src/**`, `tools/**`, `examples/**`, `sdk/**`, Pascal comments
stripped. Every hit is listed, including the ones judged harmless.

### The image-path readers this shard moved — 5 readers, 8 lines

| # | site | lines | what it resolves |
|---|---|---|---|
| 1 | `src/webview/pweb.webview.host.pas` `PWebHostLoadBundle` | 707 (DARWIN), 710 | `app.pwb` — the composition **every generated application** is built from |
| 2 | `src/script/pweb.script.release.pas` `PWebReleaseDirectory` | 1582 | the `plugins.zip` / plugin root |
| 3 | `src/platform/windows/pweb.platform.webview2.fixed.pas` `PWebWv2FixedRuntimeRoot` | 643 (+ doc text 14, 286) | the bundled WebView2 Fixed Runtime tree |
| 4 | `examples/08-release/releaseapp.pas` `LoadReleaseBundle` | 657, 660 | `app.pwb` |
| 5 | `examples/07-quickjs/quickjsapp.pas` `AppBundleFile`, `PackageDirectory` | 913, 916, 925 | `app.pwb` and the plugin root |

### Two corrections to the brief's site list, both material

**1. Site 2 in the brief is the wrong file.** The brief named
`tools/setup/pwebwv2fixed.pas`. That program takes the runtime root as an
**argument** and reads no image path at all; the read is in
`src/platform/windows/pweb.platform.webview2.fixed.pas:643`.

**2. The fifth site the brief asked to be hunted for is real, and it sits
inside E4's own gate.** `tools/setup/pwebwv2fixed.pas:176-240` and
`tools/setup/pwebwv2prov.pas:210-255` read their paths through the RTL's
argv, and Inno Setup hands them the install directory on a command line —
so an accented `/DIR=` meets the **identical** conversion ledger D2-13
measured. E4 cannot pass without fixing it. Both now read the kernel's
command line through a shared `tools/setup/pwebsetupargs.pas`.

### Hits judged harmless, reported as asked

All are **argv** (`ParamStr(i>0)`), which is a different question from the
image path, and none of them resolves a trusted file beside the executable:

- `src/webview/pweb.webview.host.pas:756,772` and
  `src/webview/pweb.webview.devhost.pas:272` — the two ratified host
  arguments (verdict file, autoclose): values, never a location.
- `examples/08-release/releaseapp.pas`, `examples/07-quickjs/quickjsapp.pas`
  `ParseArguments` — the same two arguments.
- `examples/04-react/reactapp.pas`, `examples/05-pas2js/pas2jsapp.pas`,
  `examples/06-assets/assetsapp.pas`, `examples/06-assets/mkappzip.pas` —
  Phase 4/5 demos that take an asset folder on the command line. They ship
  in no SDK and resolve nothing beside their executable.
- `tools/bundler/pwebbundle.pas:128-130` — the **POSIX half** of its own
  kernel-argv reader (ledger D2-13); argv there is bytes the RTL hands over
  unchanged.
- `tools/pweb/pweb.cli.platform.pas:1983` — `PWebCliRawArgs`, the POSIX half
  of the CLI's kernel-argv seam (ledger D2-12).
- `tools/pweb/pwebsdk.pas`, `tools/pweb/pwebtemplates.pas` — private build
  tools' own command lines; never shipped.
- `tools/quickjs/pwebqjspack.pas:481-482` — **ledgered and not this
  shard's**: the bundler's twin still reads its two paths through the RTL
  argv. It does not ship in the SDK, no `pweb` command spawns it, and
  closing it is CAP-9C1 surface with a supersession of its own.
- **`sdk/` — zero hits**, both the TypeScript and the Pas2JS SDK.

`test/cap10e/check_image_path.ps1` pins all of this: `paramstr0_path_sites`
**0**, `programfilepath_sites` **0**, and the argv readers above are a
ratified per-file list that is exact in both directions — a file that stops
reading argv must leave it, so a reason cannot rot into fiction.

---

## HELPER AND LAYER

**`src/security/pweb.imagepath.pas`** — a new leaf unit exposing
`PWebImageFile` and `PWebImageDir` (the latter with its trailing delimiter,
so a call site changes its *source* and not its concatenation). Three whole
platform bodies:

| target | mechanism |
|---|---|
| Windows | `GetModuleFileNameW(0, …)` over a 32767-wide buffer, then **one** UTF-16 → UTF-8 → `string` conversion |
| Linux | `readlink('/proc/self/exe')` |
| macOS | `_NSGetExecutablePath` + `realpath` |

It uses the RTL and `mormot.core.base`/`.unicode` and **no PWeb unit at
all**, so `src/webview`, `src/script`, `src/platform/<os>`, both acceptance
hosts and the CLI reach it without any of them reaching each other. An
unanswerable kernel returns `''`, and every call site refuses — a relative
path would hand the trusted location back to the working directory, which is
the one input the whole model exists to exclude.

### Why `src/security`, and not `src/platform`

Three constraints, and only one placement satisfies all of them.

1. **`docs/kernel.md` freezes the repository layout and unit naming.** No
   new top-level `src/` directory was available, and
   `pweb.platform.<engine>.pas` is reserved for engine bodies.
2. **`src/platform/**` is skipped *wholesale* by the CAP-7F divergence
   sweep** (`check_divergence.ps1:29-31`), precisely because each unit there
   is **one** platform's body. A three-body unit there would have hidden
   three real conditional regions from the gate that exists to catch them.
3. **`src/security` is already one of the five `PWEB_SDK_UNIT_DIRS`** the
   SDK stages and hands to the compiler
   (`tools/pweb/pweb.cli.sdkroot.pas:89-93`), and is on the `-Fu` line of
   every build that compiles any of the five sites. So a **generated
   application gets the helper with zero change** to the SDK layout,
   `pweb.cli.sdkroot.pas`, `pweb.cli.native.pas` or the ship table.

And it belongs there on merit: this is the root of the CAP-9C1 startup trust
chain — every one of the five sites uses it to locate a *trusted* file.

### The CLI is a caller, not a twin

`PWebCliImageDir`'s two platform bodies were **deleted** and replaced by one
shared body over `PWebImageDir`, in the SHARED-BODIES section whose header
already states the rule. It is exported so `test/cap10e/imageprobe.pas` can
*measure* the identity on four targets rather than assert it.

---

## SYMLINK / REPARSE / LONG-PATH RULES

### POSIX symlink — ratified, and a real behaviour change

`ExpandFileName(ParamStr(0))` made a path absolute without resolving links;
`/proc/self/exe` and `realpath` resolve them. A host launched through
`/tmp/x/host → /opt/app/host` now loads `/opt/app/app.pwb` where it loaded
`/tmp/x/app.pwb` before. **This is the stricter rule**: a writable directory
can no longer decide which bundle a trusted binary reads.

E5 measures it with a **decoy** — a corrupt `app.pwb` beside the link — so
"the real one was used" and "the decoy was used" have different,
unmistakable outcomes (42 versus a typed refusal) instead of two
indistinguishable 42s. The CLI's own final answer does **not** move on
POSIX, because `PWebCliCanonicalDir` already resolved every link.

Superseded wording, re-stated in the same commit: the mechanism sentences in
`test/cap7l/run_release_layout.sh:8,70`,
`test/cap7f/run_host_args_gate.sh:94` and
`docs/wkwebview-macos-semantics.md`. The **rule** ("beside the executable,
never the CWD") is unchanged; only who is asked moved.

### Windows reparse — the brief's claim is corrected, not quietly satisfied

The brief asked for `junction_refused = true`. **That is not provable as
written, and making it true would have broken the freeze.**

`PWebBundleLoadFile` is `FileExists` plus `TZipAssetStore` — it refuses
*nothing* reparse-related. Only CAP-9C1's `ReadAndHashOnce` refuses a
reparse point, and only on `plugins.zip` itself. No host refuses a junction
on the **directory chain** today, and adding one would change which file is
loaded on previously-green layouts — which this shard was explicitly
forbidden to do.

What the measurement shows is that there is nothing there to refuse:
`GetModuleFileNameW` returns the path the **loader was given**, junction and
all, so `app.pwb` resolves through the same junction to the **same file**.
The property that actually matters — a junction cannot make a trusted binary
read a bundle from some *other* directory — holds by construction. E6
therefore records `junction_on_chain=transparent_same_file`, measured with a
real `mklink /J` and the host answering 42 through it.

E6 also asks the question the trusted model *does* answer,
`bundle_file_reparse`, as an **observation**: a symbolic-link `app.pwb` is
accepted by the release host and refused by the plugin reader. That
asymmetry is pre-existing and unowned; it is in the ledger with what closing
it would cost.

### Windows long path

The ratified rule: the helper returns the kernel's path **verbatim** — no
`\\?\` prefix, which `PWebWv2FixedPathShapeOk` refuses by name — over a
32767-wide buffer, so the only failure the helper can own is a silent
truncation, and `GetModuleFileNameW` returning 0 or the buffer size is
refused rather than trimmed. E7 creates an over-`MAX_PATH` directory and
tries to start the probe there twice, plain form then device form, recording
`long_paths_enabled` beside the outcome so a reader never has to guess why
it resolved or did not. That row is why the closure run could answer a
question the dev host could not, and it answered it in the direction the
shard did not predict — see **KNOWN LIMITATIONS 2**.

---

## NON-ASCII RUNS (FOUR TARGETS)

### Measured on the dev host first, and that is the point

Three cycles of hosted CI were spent on this shard before any of them
reached CAP-10E's own gates, and each was a repository rule the change met
badly rather than a defect in the change. So the claim was moved onto the
dev host wherever the dev host could carry it — which, for the user-facing
claim, turned out to be everywhere:

| what | where | result |
|---|---|---|
| the defect and the fix, in one process | `%TEMP%\étude cap10e`, Windows | `image_dir_hex` carries `c3a9` (a real UTF-8 `é`); `rtl_program_file_path` carries the bare byte `e9`; `rtl_equals_kernel=false` |
| the RTL argv, directly | a 20-line probe, Windows | `ParamStr(1)` ends `…5ce9…`, the kernel's argv ends `…5cc3a9…` |
| the release host, before the fix | `%TEMP%\étude cap10e\release`, Windows | `app.pwb REFUSED (bundle file missing)`, exit 1 |
| the release host, after | same directory, rebuilt | **42 PASS** |
| **a generated application, both frontends** | `%TEMP%\étude cm7local`, Windows, from the staged SDK | `create` ok, `build` exit 0 with 3 `pack` lines, **`run` = 42** for React **and** Pas2JS |
| the release host and the symlink rule | Linux under WSL | `nonascii_release_host=42`; `symlink_rule=real_image` with a 41-byte corrupt decoy `app.pwb` beside the link that was **not** used |
| the junction and the long path | Windows | `junction_on_chain=transparent_same_file` (42 through a real `mklink /J`); `long_path_outcome=process_start_refused_by_os` at 318 chars with `long_paths_enabled=false` |
| the whole CAP-7F aggregate | the previous green run's evidence, with this shard's rows injected at the values the gates produce | **PASS** — required, equality and pin lists proven consistent before a hosted run reached them |

`rtl_equals_kernel` is **true** on Linux and **false** on Windows, which is
the defect's own shape: POSIX argv is bytes the RTL hands over unchanged,
exactly as ledger D2-13 recorded. macOS turns out to answer **false** too,
for an entirely different reason — see below.

### The hosted four-target record

Every row below is read from the run's own evidence artifacts, not retyped
from a log.

| row | windows | linux | macos-x64 | macos-arm64 |
|---|---|---|---|---|
| `image_path_source` | kernel | kernel | kernel | kernel |
| `cli_equals_helper` | true | true | true | true |
| `probe_verdict` | PASS | PASS | PASS | PASS |
| `image_dir_non_ascii` | true | true | true | true |
| `nonascii_release_host` (E2) | 42 | 42 | 42 | 42 |
| `nonascii_app_run_react` (E1) | 42 | 42 | 42 | 42 |
| `nonascii_app_run_pas2js` (E1) | 42 | 42 | 42 | 42 |
| `nonascii_build_exit_react` / `_pas2js` | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| `paramstr0_path_sites` (E8) | 0 | 0 | 0 | 0 |
| `programfilepath_sites` (E8) | 0 | 0 | 0 | 0 |
| `image_reader_count` (E8) | 1 | 1 | 1 | 1 |
| `symlink_rule` (E5) | posix_only | real_image | real_image | real_image |
| `nonascii_project_form` | nfc | nfc | **nfd** | **nfd** |
| `rtl_equals_kernel` (observation) | **false** | true | **false** | **false** |

### Two macOS facts MEASURED that the project had assumed

**APFS preserves the composition it is given.** CAP-10D2 kept its non-ASCII
leg Windows-only partly because "macOS normalises the Unicode in a
filename". CAP-10E composed the directory **decomposed** on purpose and
recorded the bytes that came back: `nonascii_dir_form_requested=nfd`,
`nonascii_dir_form_observed=nfd`, and `image_dir_hex` carrying `65cc81`
(`e` + U+0301). The HFS+ behaviour the assumption came from is not what
these runners have, so the variable is cheap to measure rather than a
reason to avoid the platform.

**`rtl_equals_kernel` is false on macOS for a different reason than on
Windows**, and the shard predicted otherwise. It reasoned "POSIX argv is
bytes the RTL hands over unchanged", and Linux confirms that with `true`.
macOS answers `false` — because the kernel path is `realpath`-resolved and
the RTL's is not: the probe reports
`/private/var/folders/…/étude cap10e/imageprobe` where the RTL reports
`/var/folders/…`, and `/var` is a symlink Apple ships. **So the POSIX
symlink rule this shard ratified is not an edge case exercised only by the
E5 decoy leg: it changes the resolved path on every macOS run.** That is a
stronger justification for the rule than the one written down in advance,
and it is exactly why `rtl_equals_kernel` is a per-target row rather than a
compared one — the same `false` means "the RTL mangled the bytes" on
Windows and "the RTL did not resolve `/var`" on macOS.

---

## FIXED PROFILE

E4 is the **CAP-6b3 gate body run a second time**, parameterised with
`-InstallLeaf`, never copied — a copy would drift away from the ten legs the
first time one of them changed. `/DIR=` is passed **only** when the caller
asks for somewhere else, so the ratified run's command line is byte-for-byte
what it always was. Everything downstream is already keyed off
`$InstallDir`, including the path-scoped drain, so the accented run
exercises the same ACL-by-SID verification, the same observed pinned
identity, the same no-fallback negative legs and the same clean uninstall.

---

## SUPERSESSIONS

Every row below was **measured on this tree**, not assumed.

### CAP-7F divergence allowlist

| file | before | after | why |
|---|---|---|---|
| `src/security/pweb.imagepath.pas` | — | **6** / `39f51825…` | **NEW.** The implementation `uses` clause and the three whole function bodies. Six and not nine because a bare `{$else}` carries no platform symbol. |
| `src/webview/pweb.webview.host.pas` | 42 / `23fcee78…` | **unchanged** | the fix is a unit, not an inlined conditional |
| `src/script/pweb.script.release.pas` | 10 / `218a2592…` | **unchanged** | " |
| `examples/07-quickjs/quickjsapp.pas` | 34 / `4be277b3…` | **unchanged** | " |
| `examples/08-release/releaseapp.pas` | 38 / `8ee3c908…` | **unchanged** | " |
| `tools/pweb/pweb.cli.platform.pas` | 36 / `e1fcbe24…` | **unchanged** | two bodies were **removed**, and both lived inside regions other primitives keep open |

Sweep total **206 → 212**. The ledger entry that commissioned this shard
predicted all four call-site rows would move. **They did not**, and the
reason is the shape of the fix; the re-ratification note in
`check_divergence.ps1` says so rather than leaving a reader to notice.

`tools/setup/**` is not on the swept surface, so the two setup helpers need
no row.

### What the shard makes move, and what it deliberately does not

| record | expectation | why |
|---|---|---|
| `sdk_ship_table_digest` | **unchanged** | `share/pweb/src` is an `skTree` entry in `SHIP_TABLE`, so a new file under it ships automatically; `pwebsdk.pas` is untouched |
| `sdk_digest` | **unchanged** | it is the digest of the CAP-10D2 **suite's** own decision corpus, not of the gate's rows — the same check D2-13's closure used to say "the correction moved no recorded verdict" |
| `sdk_inventory_digest`, `sdk_archive_sha256`, `sdk_files` | **move** | `share/pweb/src` gains `pweb.imagepath.pas`, and the Windows `pack/bin` helpers were recompiled. Per-target by construction and compared on none |
| `quickjs_gui_digest` | **moves, equally on four** | the CAP-9C2 runner corpus gains four rows (`nonascii_layout_dir_non_ascii`, `nonascii_quickjs_host`, `nonascii_ui_add`, `nonascii_quickjs_add`), added in the same order by both twins. The **host's** own row set is untouched: the accented run writes to its own corpus file and is deliberately excluded from the hashed one |
| `cli_digest`, `doctor_schema_digest` | **unchanged** | the CLI's observable output does not move; `PWebCliImageDir` answers what it always answered on Windows, and on POSIX its canonical answer is unchanged because `PWebCliCanonicalDir` already resolved every link |
| CAP-10D2 CM7 rows | **grow and change kind** | Windows-only build-and-stop becomes four-target build-and-**run**; `nonascii_build_exit` splits into `_react`/`_pas2js`, and `nonascii_app_run_react`/`_pas2js` are new and pinned to `42` |
| CAP-6b3 profile rows | **new second run** | the same gate body at an accented `/DIR=`, recording `fixed_profile_nonascii_dir` |
| CAP-7F aggregate | **20 new fields per target** | 14 compared, 6 per-target — the split made from the ledger lesson that cost CAP-10D2 two red runs, and proven locally before any hosted run reached the aggregator |

**The two "unchanged" claims are MEASURED, on hosted evidence, and they are
the ones that matter most**, because they are what says a corrective shard
corrected only what it meant to. On the Linux job of run `33979925286`:

- `sdk_digest` = `b33df77edacdffd9336bc6835635a010a0b0d48ec4c2256773592a008f82e9be`
  — **identical to the CAP-10D2 closure value**;
- `sdk_ship_table_digest` = `1308731a9bd5ee743dfaf50f231e04accbe249908f40b069baf83beac5ced6e8`
  — **identical to the CAP-10 closure artifact's value**.

The same job carried `nonascii_app_run_react` = **42** and
`nonascii_app_run_pas2js` = **42** at `étude apps`, with
`nonascii_build_exit_react`/`_pas2js` = 0 and 6 `pack` lines — the leg
CAP-10D2 had to stop before `run` on, now running.

The remaining measured values are in the closure run's
`platform-matrix.json`; see VERDICT.

---

## REGRESSIONS

### Locally, before anything was pushed

| sweep | result |
|---|---|
| every checkout-only contract gate — 24 of them, CAP-5 through CAP-10E plus the divergence sweep and the binding surface | **all PASS** |
| every CLI isolation compile — 29 units, on Linux, with the exact flags each build script uses | **all PASS, zero gaps** |
| `test/cap6/run_cap6_gates.ps1` (the CAP-6 headless gates, on the rebuilt release host) | **ALL PASS**, including the deterministic rebuild and the non-ASCII argv leg |
| the CAP-7F aggregate, on the previous green run's evidence with this shard's rows injected | **PASS** |
| the four new CAP-7F self-test legs, each perturbed in turn | **all four refuse and name their field** |

### Three hosted cycles, and what each one caught

None of the three was a defect in the change; each was a repository rule the
change met badly, and each is now closed by a sweep rather than by a patch:

1. **CAP-9C1's ambient-input sweep** reads `pweb.script.release.pas` as raw
   text and forbids the string `ParamStr`. A *comment* explaining the defect
   tripped it. The comment now says what it means without naming the retired
   entry point, and says why it does so.
2. **CAP-10D0's quoting rule** forbids a CAP-10 gate from calling
   `Start-Process` directly, because a path with a space splits the argument
   vector — which is the very hazard this shard's gate launches into. The
   gate now dot-sources `test/cap10d0/psargs.ps1` like every other.
3. **CAP-10D2's `pweb.cli.sdkmanifest` isolation compile** carries a
   deliberately narrow unit path, and the CLI seam now stands on the shared
   helper. Both twins gained `-Fusrc/security`, with the reservation stated:
   the helper is a leaf, so nothing about what `sdkmanifest` may reach was
   widened.

The response to the third was to stop finding these one run at a time: the
two sweeps above — every checkout-only gate, every isolation compile —
now run on the dev host in under ten minutes.

### The hosted four-target record

Closure run **`33983841968`** on commit **`28bda2a`**, every job green:

| job | conclusion |
|---|---|
| `windows` | **success** |
| `linux-x64 (GTK 3 + WebKitGTK 4.1)` | **success** |
| `macos-x64 (Cocoa + WKWebView)` | **success** |
| `macos-arm64 (Cocoa + WKWebView)` | **success** |
| `macos release inventory (x64 = arm64)` | **success** |
| `cap7 aggregate (windows = linux = macos-x64 = macos-arm64)` | **success** |

That is every pre-existing gate of CAP-5 through CAP-10D2 — CAP-6, 6b1–6b4,
7L, 7M2, 8, 9A–9C2, 10A–10D2 — running on the new digests, plus this shard's
own E1–E9, plus the four-target equality aggregate. **E10 is the run
itself.** The CAP-10E record from each target carries `verdict=PASS` and
`violations=0`.

Two things in that list are worth naming, because they are where a
corrective shard is most likely to have done damage without noticing:

- **CAP-6b4's profile matrix passed on the same job that runs E4.** The
  earlier red — `S5: setup exited 5` behind a RestartManager hold — was
  this shard's step *ordering* making ledger D1-16's residue likelier, not
  a defect in the fix. E4 now sits after the matrix; both are green in the
  same job, which is the measurement that says the ordering was the cause.
- **`sdk_digest` and `sdk_ship_table_digest` came back at their CAP-10D2
  closure values on Windows and on Linux alike** — `b33df77e…` and
  `1308731a…`. A new file shipped into `share/pweb/src`, and the two
  records that would have caught an unintended distribution change did not
  move.

One infrastructure flake occurred and is not a result: the Windows job's
first attempt timed out installing the pinned FPC/Lazarus toolchain at the
20-minute step limit, before any repository code ran. `gh run rerun
--failed` re-ran Windows inside the same run, preserving the four jobs that
were already green.

---

## FREEZE CHECK

Production diff, and nothing else in `src/`, `sdk/`, `examples/`,
`tools/setup/`:

- **the helper** — `src/security/pweb.imagepath.pas` (new)
- **the five image-path readers** — one line each, plus a fail-closed guard
  where `''` would otherwise have become a relative path
- **the two setup-helper argv readers** — the ratified D2-13 region through
  a shared `tools/setup/pwebsetupargs.pas` (new), no conditional, because
  both consumers are Windows-only programs
- **one CLI body** — `PWebCliImageDir`, two platform bodies collapsed into
  one shared caller

No interface, pin, CSP, origin, layout or profile change.
`PWEB_SDK_UNIT_DIRS` and the SDK ship table are untouched, and
`sdk_ship_table_digest` is measured unchanged rather than assumed so.

`git diff --stat` from the shard's baseline `657846d`, over the frozen
surface, is the whole of it:

```
examples/07-quickjs/quickjsapp.pas                 |  25 ++-
examples/08-release/releaseapp.pas                 |  18 +-
src/platform/windows/pweb.platform.webview2.fixed.pas |  19 +-
src/script/pweb.script.release.pas                 |  16 +-
src/security/pweb.imagepath.pas                    | 222 +++++++++++++++++  (new)
src/webview/pweb.webview.host.pas                  |  24 ++-
tools/setup/pwebsetupargs.pas                      | 128 ++++++++++++      (new)
tools/setup/pwebwv2fixed.pas                       |  41 ++--
tools/setup/pwebwv2prov.pas                        |  34 ++--
tools/pweb/pweb.cli.platform.pas                   |  32 +/- 54 -
```

**`sdk/` is untouched**, and nothing under `tools/` outside `tools/setup/`
and `tools/pweb/` moved at all. The CLI is the only file that got
**smaller**: two platform bodies removed, one shared caller added.

---

## KNOWN LIMITATIONS

1. **A bundle *file* that is itself a reparse point is accepted by the
   release host and refused by the plugin reader.** Pre-existing, unowned,
   and measured by E6 rather than legislated: closing it means giving
   `PWebBundleLoadFile` the reparse-refusing open that
   `pweb.script.release.pas` already has, which is CAP-4/CAP-6 asset-layer
   surface with a supersession of its own.
2. **Windows refuses to *start* a process whose image path exceeds
   `MAX_PATH`, and the `LongPathsEnabled` opt-in does not lift the
   refusal.** The dev host measured it at 318 characters with
   `long_paths_enabled=false`, and the shard wrote down the expectation that
   a runner with the flag on would upgrade E7 into a real non-truncation
   measurement. **The closure run disproved that expectation**: the hosted
   Windows runner reports `long_paths_enabled=true`, the 325-character
   directory was created without complaint (`long_path_dir_created=true`),
   and the launch was refused all the same —
   `long_path_outcome=process_start_refused_by_os`,
   `long_path_launch_form=none`. The registry opt-in governs the Win32
   *file* APIs; it does not extend `CreateProcess`'s application path. So
   the refusal is the OS's answer before any PWeb code exists, and it is
   **not** a condition a better runner can lift. The consequence for this
   shard is stated rather than glossed: the helper's long-path behaviour —
   the 32767-wide buffer, and `GetModuleFileNameW` returning 0 or the buffer
   size refused instead of trimmed — is proven by construction and by the
   source gate, **not** by a live >`MAX_PATH` launch, and measuring it would
   need a launch mechanism that does not pass a long application path to
   `CreateProcess`. No shipped path does, which is why the gap is a
   limitation and not a defect.
3. **If a process *is* started through the `\\?\` device form**, the kernel
   spells the image path back with that prefix — and a fixed-runtime profile
   launched that way would refuse its own runtime root on
   `PWebWv2FixedPathShapeOk`. A real interaction between two ratified rules
   that nothing currently exercises, because no shipped path launches an
   application that way. Named for whoever owns it next.
4. **`tools/quickjs/pwebqjspack.pas` and `tools/pweb/pwebtemplates.pas`
   still read argv through the RTL.** Neither ships; both are already
   ledgered with their owner. Widening into them would have been a second
   deliverable under a one-deliverable brief.

---

## VERDICT

Closure run **`33983841968`**, commit
**`28bda2a95a9626cc51ebd2efa34cb45cd9e940d3`**, branch
`phase/cap-10/d2-sdk-distribution`. Every job **success**, including
`cap7 aggregate (windows = linux = macos-x64 = macos-arm64)`.

The three lines that carry the shard:

```
[CAP-7F] divergence sweep PASS - 212 platform conditionals, all inside the ratified allowlist
[CAP-7F] selftest cap10e-image-source / cap10e-paramstr0 / cap10e-nonascii-run / cap10e-second-reader:
         aggregator refused as required (nonzero exit, no matrix)
[CAP-7F] aggregate PASS - platform-matrix.json written
```

The aggregator writes **no matrix at all** on a single disagreement, so the
existence of `platform-matrix.json` at `github_sha` `28bda2a9…` is the
statement that this shard's 14 compared fields agreed on four targets and
its 6 per-target fields were present on all four. The four negative
self-tests say the aggregate would have gone red had any of them not: flip
`image_path_source` away from `kernel`, raise `paramstr0_path_sites` above
zero, drop a non-ASCII run below 42, or add a second reader of the kernel
primitives, and the matrix is not written.

Answering the seven adversarial questions on that evidence:

1. **No shipped code derives a path from `ParamStr(0)`.**
   `paramstr0_path_sites` = 0 and `programfilepath_sites` = 0 over 90 files
   of `src,tools,examples,sdk`, on every target, gated at every run.
2. **No symlink or junction redirects a trusted file.** POSIX resolves the
   real image and ignored a 41-byte decoy `app.pwb` beside the link on
   three targets; Windows measured a real `mklink /J` as
   `transparent_same_file`, the junction naming the same directory rather
   than a different one.
3. **Nothing previously green loads a different file.** Every CAP-5..10D2
   gate is in this run, and the two records that would catch a distribution
   change — `sdk_digest` `b33df77e…`, `sdk_ship_table_digest` `1308731a…` —
   came back at their CAP-10D2 closure values.
4. **No digest moved without a recorded reason.** The SUPERSESSIONS table
   states each one and its cause; the two "unchanged" claims are hosted
   measurements, not assumptions.
5. **The CLI keeps no second implementation.** Two platform bodies were
   deleted for one shared caller, and `cli_equals_helper` = true on four
   targets proves the seam agrees with the helper at runtime, not just in
   source.
6. **macOS composition is measured, not assumed.** `nfd` requested, `nfd`
   observed, `65cc81` in the bytes — and the same leg caught a second
   assumption, that POSIX RTL argv always equals the kernel path, which
   `/var` → `/private/var` disproves.
7. **Nothing beyond the audited sites moved.** Ten files: one new helper,
   five call sites, one new setup argv reader with its two consumers, one
   CLI body. `sdk/` untouched.

One prediction this shard wrote down was **disproved** by the closure run
and is recorded as such rather than quietly dropped: a Windows runner with
`long_paths_enabled=true` does **not** upgrade E7 into a live
non-truncation measurement, because `CreateProcess` refuses the
over-`MAX_PATH` application path regardless. KNOWN LIMITATIONS 2 now states
what is proven by construction versus by measurement, and the ledger
carries the rule.

**CAP-10E PASS — KERNEL-RESOLVED IMAGE PATH IN EVERY SHIPPED HOST**

The application that could not start under `C:\…\étude\` starts. It starts
on Windows, Linux, macOS x64 and macOS arm64; as a generated React
application and as its Pas2JS twin; as the release host, the QuickJS host
and a fixed-runtime profile installed at an accented `/DIR=`; through a
junction and through a symlink; and it starts because every one of them now
asks the kernel which file it is, in exactly one place.
