# MORMOT-REPIN-2 — the mORMot pin on the three upstream binding fixes

```
MORMOT-REPIN-2 READY — hosted CI outstanding on the final HEAD
mormot.lock: da7e1c2f → 66d7d51c1fd21bd222b360382ed8e2b4f656aaad
Currency 5/5 unpatched on four targets · JS_SetMaxStackSize shadow removed · RP-2, 9A-3, 9A-4 CLOSED
```

Branch `phase/post-mvp/mormot-repin-2`, cut from `main` at
`4aed789bb029fb5f4e2bd4d14749268a7d82358a` after CAP-12B had merged. Spec:
`spec-phase-post-mvp-mormot-repin-2.md`, which carries the review triage.
Checkpoint: `mormot-repin-2-checkpoint1.md` (PLAN READY, carried straight into
implementation, amended after the review). This record is kept whole although
the documentation-budget hook flags records of this size: it is a shard
record, not a story, and splitting it would separate the measurements from
the decisions they support.

| commit | what |
|---|---|
| `291eb32d0c6feb9f1f414f91e9afe54cf8953e07` | measure — the `commit =` line only, so the hosted legs build the unpatched candidate (run 35141256648) |
| `ac04f72` | the pin, its comment, the shadow removed, the aarch64-darwin export aligned, the pin-derived literals |
| `c3723d7` | every Currency row `must_pass`, and the CAP-3U comments |
| `de8add5` | the checkpoint, five ledger entries, the dispositions, the backlog document, the three upstream reports resolved |
| `6dd1247` | review: the q22 depth probe, `test/cap9a/check_pinned_bindings.ps1`, the `9B1-8` runner fixes, the unit's comments |
| `fc17e67` | review: the corrections, the owed row `RP2-6`, the `9B1-8` closure `RP2-7` |
| the commit that adds this record | this file |

---

## CANDIDATE

**`66d7d51c1fd21bd222b360382ed8e2b4f656aaad`** — `2.4.16907`, 2026-09-16
13:16:20 +0200, *lib: fixed pas_malloc() wrapper definition*. Each of the
three hashes in the brief was resolved in the upstream tree: all three exist,
all three are on `master`, and all three descend from `da7e1c2f`. The
Currency and stack-size fixes are ancestors of `66d7d51c`, which is on
`master`'s first-parent line, so it is the smallest commit that carries all
three. The seventeen commits `master` carried after it are not taken
(fifteen on the first-parent line, plus one from each of the merged pull
requests #586 and #589: TLS 1.3, futex shutdown, TSynLog).

| fix | commit | reported as |
|---|---|---|
| Currency result register, SysV x64 and AArch64 | `6a27c07fc6c9f796711076561c293e68eb6b6398` | `RP-2` |
| `JS_SetMaxStackSize` takes `JSRuntime` | `37fa86b451304c15bacd34cf673cb4f0c40f0235` | `9A-3` |
| `pas_malloc` / `pas_malloc_usable_size` pointer-width | `66d7d51c1fd21bd222b360382ed8e2b4f656aaad` | `9A-4` |

`mormot.lock` names all three commits, the forum thread
<https://synopse.info/forum/viewtopic.php?pid=45803#p45803>, what was
measured before the move and where, and the two CAP-3U commits the previous
move was made for. Both of those are still in.

## STATICS

**Unchanged — no second pin.**

- `static/` is byte-identical between the pins.
- `2.4-stable` is still the newest release. Its asset reports `updated_at`
  2026-01-12T18:35:58Z and a GitHub digest equal to the pin.
- A fresh download on 2026-09-16 hashed to `ae2d8da2…` over 33 675 498 bytes.
- `res/` differs only in three liblizard headers (`int` → `size_t` in
  prototype text). The archive's `liblizard.a` predates that change, but PWeb
  links no lizard: no unit uses `mormot.lib.lizard`, and the CAP-9A link map
  names no lizard symbol.

## CURRENCY (FOUR TARGETS)

Unpatched candidate, `test/cap3u/cap3u_currency.pas`, arities 0/1/2, five
cases, each leg on its own compiler. Measured on hosted run **35141256648**
(the measurement commit) and on this host:

| target | compiler | before (`da7e1c2f`, run 34241426338) | **after** | table now |
|---|---|---:|---:|---|
| windows-x86_64 | FPC 3.2.2 win64 — hosted, and the dev host | 5/5 | **5/5** | 5 × `must_pass` (unchanged) |
| linux-x86_64 | `3.2.2+dfsg-32` hosted; FPC 3.2.3 WSL | 1/5 | **5/5** on both | 5 × `must_pass` (was 1) |
| macos-x86_64 | FPC 3.2.2 [2021/05/16] x86_64 | 1/5 | **5/5** | 5 × `must_pass` (was 1) |
| macos-arm64 | FPC 3.2.2 [2021/05/16] aarch64 | 0/5 | **5/5** | 5 × `must_pass` (was 0) |

`test/cap3u/currency-expectations.tsv` names run 35141256648 and its commit
as provenance. The "do not return Currency" limitation is retired from the
ledger (`RP2-1` closes `RP-2`), from `docs/backlog.md`, and from the CAP-11A
amendment row that described the step. The upstream report carries a
resolved header, with the rest of it left as filed.

The Win64 half is unchanged: one RUNTIME_FUNCTION on CallMethod, unwind
information inside the mapped `.xdata`, frame register RBP, and the matrix
**12/12**. This holds on the dev host (`00053560..000535EF`) and on the
hosted leg (`00054A80..00054B0F`). `cap3tests` 193/193.

**Residue, recorded.** The step `CAP-3U Currency return matrix (typed
observation, four targets)` keeps its name. A step name feeds the
`ci_sequence_digest` all four legs compare, so renaming it would be a declared
amendment for one word. Its action header explains the name, and that header
is outside the declared body digest (`2866347299e06fbc`, unchanged).

## QUICKJS SHADOWS

| shadow | state | proof |
|---|---|---|
| `JS_SetMaxStackSize(rt: JSRuntime; …)` re-declared in `pweb.script.quickjs.pas` | **removed**; `ApplyLimits` calls the pinned import with `FEngine.rt` | three gates, each seen firing — see below |
| any `pas_malloc` shadow on Windows/Linux | **none existed** — confirmed, as the ledger said | the Win64 link map shows upstream's `pas_malloc$int64$$pointer` and `pas_malloc_usable_size$pointer$$qword` |
| the aarch64-darwin `pas_*` export block | **kept** — a provision, not a workaround: `NOLIBCSTATIC` is still defined for Darwin/ARM at the candidate (`mormot.defines.inc:1062`) | `pas_malloc_usable_size` now returns `PtrUInt` like the pin and `cutils.h`; no platform directive touched, so the CAP-7F divergence fingerprint holds. **Its aarch64-darwin compile is owed to the hosted run** |

**Every probe is a permanent gate against the unpatched upstream, and each
was observed firing:**

| gate | what it holds | the positive leg | the negative leg, and how to repeat it |
|---|---|---|---|
| the compile of `pweb.script.quickjs.pas` | a revert of `JS_SetMaxStackSize` to `ctx: JSContext` | compiles on every leg | copy `deps/mormot2/src` aside, write `ctx: JSContext` back into `lib/mormot.lib.quickjs.pas`, compile the unit against the copy: `pweb.script.quickjs.pas(964,34) Error: Incompatible type for arg no. 1: Got "JSRuntime", expected "JSContext"`. It does not cover a change to an untyped pointer, which is what the next row is for |
| `test/cap9a/check_pinned_bindings.ps1`, run by both CAP-9A runners | the pinned `JS_SetMaxStackSize`, `pas_malloc`, `pas_realloc` and `pas_malloc_usable_size` declarations | 4/4 PASS at `66d7d51c` | every run rewrites each declaration to its pre-fix form and requires zero matches. `-MormotRoot` pointed at `da7e1c2f`'s two files refuses `JS_SetMaxStackSize(ctx: JSContext …)`, `pas_malloc(size: cardinal)` and the `integer` `pas_malloc_usable_size`, and passes `pas_realloc`, which was already pointer-width |
| CAP-9A q22, discriminating | the configured stack limit reaches the runtime | 494 frames at 256 KB, 1983 at the 1 MB default (Windows) | compile the harness against a copy of `src/script` with the `JS_SetMaxStackSize` call deleted: 494 and 494, `QUICKJS FAIL (q22 the configured stack limit does not decide the recursion depth …)`. The probe adds no corpus line, so `quickjs_corpus_digest` holds |
| CAP-9A q20–q23, CAP-9B2 L13 | the three limits fail safe | PASS on Windows and Linux | — (q22 alone could not tell a limit from QuickJS's own 256 KB default, which is why the row above exists) |
| `test/cap3u` | CallMethod's unwind and Currency result register | 12/12, 5/5 | carried from the 2026-09-08 repin |

**Upstream detail, recorded and not acted on.** `mormot.lib.static` declares
`pas_malloc(size: PtrInt)` and `pas_realloc(…; Size: PtrInt)`, although the
brief said PtrUInt and the commit's own subject says "PtrUInt / size_t
everywhere". Signedness changes nothing at the call boundary: all 64 register
bits arrive either way, and `GetMem` takes them as unsigned. Whether to say
so on the forum is the owner's call.

## DELTA

`da7e1c2f..66d7d51c`: 106 first-parent commits, 41 files, +4108 / −985.

- **core** (14 files):
  - the Currency fix in `mormot.core.interfaces.pas` (+7/−5, with
    `a5b75dde`'s int64 clamp refactoring);
  - `GetExtendedSsse3` in `mormot.core.base.asmx64.inc` (+1258/−8).
    `mormot.core.text` now routes text-to-float parsing through it wherever
    `ASMX64NOTPIC` is defined and the CPU has SSSE3, which covers Windows and
    Linux x64, hosted runners included. It is one `nostackframe` leaf routine
    with no call, no push, and no non-volatile register or XMM6–15 on Win64,
    so it needs no unwind entry. The whole chain on both platforms exercised
    it: JSON numbers across the suites, `cur-one-double`, and the SDK wire
    parity;
  - refactoring in `datetime`, `text`, `variants`, `unicode`, `fpcx64mm` and
    `os`.
- **lib** (3 files): `mormot.lib.quickjs.pas` +10/−11, which is only the two
  binding fixes; `mormot.lib.static.pas` +7/−4; one line of
  `openssl11.full.inc`.
- **version constants** (2 files): `src/mormot.commit.inc` and
  `mormot.commit-num.inc`, `2.4.16776` → `2.4.16907`. They are staged into
  every SDK root.
- **static bindings**: none. **`res/`**: three liblizard headers.
  **`src/script`, `mormot.defines.inc`, `mormot.uses.inc`**: untouched.
- **net / crypt / db / orm** (14 files): TLS 1.3 preparation, DNS, DHCP and
  SQL. CAP-15B and CAP-15C, whose paths cross `mormot.net.sock`, are green on
  both local platforms.
- **upstream `test/`** (5 files): not compiled by PWeb.

## SUPERSESSIONS

"Before" is the last green hosted run before the move, 35130141163, unless
the row says otherwise. "After" names where it was measured. The Windows and
Linux "after" values are this host's, on the final HEAD. The hosted run of
the final HEAD measures all four targets and supersedes them in the closure
record.

| value | before | after |
|---|---|---|
| `mormot.lock` commit | `da7e1c2fabb17cc18279c7c8599b563d35845168` | `66d7d51c1fd21bd222b360382ed8e2b4f656aaad` |
| `LICENSE.quickjs` sha256 (six sites) | `a1d491db9c87a750c2bb37d7d47b642ce4b94a0d56332640f1d14521233875bf` | `3475555a50debb194de75ba33eb0a08e92ea9995c2021249c7966a3f0923ee19` — Windows, Linux; line 17 only, and writing the old commit back reproduces the old digest |
| CAP-9C1 C30 expected pin | `mORMot2 commit  : da7e1c2f` | `mORMot2 commit  : 66d7d51c` |
| Currency expectations | 5 + 1 + 1 + 0 rows `must_pass` | 20 rows `must_pass` |
| `sdk_inventory_digest` windows-x86_64 | `fb2b7fc645bee0ec0a9f1c8ee3b36dfd915eb508c6acd26e9b18487ff1962f25` (319 files) | `83f2f07bcf3981698367bf598490fa79c331b7c55fbea63186976995bf6fa263` (319 files), archive `f91e7bafd1858a474622414c0b22a1f25cdc67343ed9cd95349cde375c46aff3` — dev host, `fc17e67` |
| `sdk_inventory_digest` linux-x86_64 | `e25e4918a9890cc9be2f289451db6338556ed733ef23a2ff95b95d9ac3cc9ed6` (235) | `91af9036e4a1e3c0478178b13d742687a7741ee3a5be909fc90420629e256486` (235 files), archive `c2c713fbfa6ced38d546efc1457e6994fb80e0fa9708a9b45019d83d0fd7824e` — WSL, `fc17e67` |
| `sdk_inventory_digest` macos-x86_64 | `6219c14797d3237fafc985b3093a0c3f334a54bdde8945a32fea74cb48007c68` (233) | **owed to the hosted run of the final HEAD** (`RP2-6`) |
| `sdk_inventory_digest` macos-arm64 | `42dad4846ef42c48384743ea4777a89c3325b5bea0459c1ee1687689294f636a` (230) | **owed to the hosted run of the final HEAD** (`RP2-6`) |
| `sdk_digest` | `b33df77e…` | unchanged — Windows, Linux |
| `sdk_ship_table_digest` | `92f53b63…` | unchanged — Windows, Linux. The ship table names the pinned tree without naming a commit, so its wording did not move |
| `quickjs_corpus_digest` | `601b86ff…` | unchanged — Windows, Linux (the depth probe adds no line) |
| `quickjs_package_digest` | `4b01cf06…` | unchanged — Windows, Linux |
| `quickjs_lifecycle_digest` | `6c8d0bd7…` | unchanged — Windows, Linux |
| `quickjs_release_digest` | `04c2db17…` | unchanged — Windows, Linux |
| `quickjs_gui_digest` | `1c88bda9…` | unchanged — Windows, Linux |
| `cap9c1_inventory_digest` | `a60b62a4…` | unchanged — Windows, Linux |
| `capability_policy_digest`, `navigation_policy_digest`, `security_corpus_digest`, `cli_digest`, `doctor_schema_digest` | `23b87da5…`, `360d69f2…`, `c5fc378b…`, `095c95b2…`, `de66b8bf…` | unchanged — Windows, Linux |
| `ci_sequence_digest` | `03799436…` (207 steps) | unchanged — as emitted by the CAP-7F emitters on Windows and Linux; no step entered or left |
| the CAP-11A declared body digest of the Currency step | `2866347299e06fbc` | unchanged — `check_migration_map.ps1` PASS; only the header comment and the table's reason column moved |
| `test/cap7f/mormot-defines.tsv` | pin-sha256 `33584f3e…` | unchanged — `mormot.defines.inc` hashes the same at both pins; `check_mormot_defines.ps1` PASS |
| statics sha256 | `ae2d8da2…` | unchanged — re-downloaded |

The CAP-9 corpora did not move although the binding **source** did. The five
decision corpora read the behaviour of the bound engine, and that behaviour
is the same.

## REGRESSIONS

The step bodies were replayed straight out of `.github/workflows/platform-leg.yml`
and each `.github/actions/<slug>/action.yml`, in sequence order. Every gate
that ran is green on both platforms.

**Linux** (WSL Ubuntu-24.04, FPC 3.2.3, WebKitGTK 2.52.6, Xvfb, Node 24.11.1):
steps 3, 5, 8, 10, 84–99 and 122–188 on **`fc17e67`**, in a git clone with
every untracked output removed first, as on a fresh checkout. All **84 bodies
exit 0**. Step 4, the distro package install, is the host's own state.

**Windows** (FPC 3.2.2 x86_64-win64, MSVC from Visual Studio 18, Node
24.11.1, the signed PowerShell 7.6.6):

- steps 15, 122–162 and 164–186 on **`fc17e67`**: all **65 bodies exit 0**;
- steps 8–121 on the pin-move tree (`ac04f72`–`de8add5`), all green. The
  later commits change nothing those steps compile or read: the CAP-9A
  harness and runners, comments in `pweb.script.quickjs.pas` (which none of
  steps 8–121 builds), and records.

Seven steps were not run here, each for a stated reason:

| step | why not here | where it is measured |
|---|---|---|
| 12 Install FPC | installs Lazarus on the host | the toolchain it installs is the one used |
| 67, 70, 74, 79 — CAP-6b1/6b2/6b3 setup gates and the CAP-6b4 profile matrix | they execute real installers on the host | hosted Windows leg of 35141256648, green against the candidate (all 82 steps before C30) |
| 80 CAP-10E E4 | installs the fixed-runtime profile | same run, green |
| 163 CAP-10D0 L2b | it copies the repository with its `build/`, and this host's `build/cap7l` holds two WSL-created symlinks robocopy cannot copy and retries indefinitely — a leftover no runner has | **owed to the hosted run of the final HEAD** (`RP2-6`); the measurement run stopped before it |

Steps 187–207 are the other targets' emitters and the upload/collection
block, which a replay has nothing to upload to. Four local-harness
mismatches were corrected, and each step was re-run once the harness matched
the runner:

- 26/27, a `cmd`-shell body;
- 61, which borrows the running `pwsh` as its validly signed payload, where
  this host's first `pwsh` is an unsigned dotnet-tool shim;
- 167, where the CM gates build under `RUNNER_TEMP`, and a scratchpad path
  trips PWeb's own `project_root_too_long`;
- 175/177, where the harness took a following comment block into an inline
  body.

| gate | Windows | Linux |
|---|---|---|
| CAP-3U unwind — one RUNTIME_FUNCTION, 12/12 | PASS | n/a |
| CAP-3 bridge `cap3tests` | 193/193 | n/a |
| PWeb suite `pwebtests` | 2703/2703 | CAP-7L headless suite PASS |
| CAP-3U Currency, all rows `must_pass` | 5/5 | 5/5 |
| ABI probes, signature pin, freeze sweeps (CAP-1/2/3) | PASS | CAP-7L ABI PASS |
| CAP-4, CAP-4W | PASS | — |
| CAP-5 SDKs, wire parity, zero-network, host examples, runtime smokes | PASS | CAP-7L frontends PASS |
| CAP-6 bundler, headless gates, release smoke; CAP-6b0–6b4 builds, fixtures, contracts, drain tests, isolation | PASS | — |
| CAP-7F host arguments; CAP-7L GUI matrix, release layout, zero transport | PASS | PASS |
| CAP-8B, CAP-8C real-window matrices | PASS | PASS |
| CAP-9A pinned binding declarations, 4 rules | PASS | PASS |
| CAP-9A q22 depth probe | 494 → 1983 frames | 562 → 2257 frames |
| CAP-9A / 9B1 / 9B2 / 9C1 / 9C2 (no shadow) | PASS | PASS |
| CAP-10A / B0 / B1 / B2 / C0 / C1 / C2 / C3 / D0 / D1 / D2 / E | PASS, except D0 L2b (owed) | PASS (L2b is not a Linux step) |
| CAP-11A structure, migration, schema, fetch, flakes, cases | PASS | PASS |
| **CAP-11B watcher contract, ref input, seeded verdicts, ledger** | PASS | PASS |
| CAP-12B, CAP-14A, CAP-14B, CAP-15B, CAP-15C | PASS | PASS |
| backlog disposition — 450 entries, 64 open | PASS | n/a (Windows-only step) |
| `check_backlog_selftest.ps1` | 26/26 refusals, tree restored | — |
| CAP-7F emit evidence | PASS | PASS |

**The watcher is unaffected.** `upstream-watch.yml` is triggered by none of
these paths. Its four gates pass on both platforms, and CAP-11B's ref-input
case reports the pinned plan byte-identical and the locks unchanged.

**The aggregator, locally.** The aggregate job needs four legs' evidence, so
it was run on this host's Windows and Linux evidence plus the macOS evidence
of run 35130141163, with two local artifacts aligned in the copies:

- the licence digest was advanced to the new value;
- the macOS commit and WSL compiler fields were set to match.

The result is `aggregate PASS`, and the negative self-test refused all 259
aggregator perturbations and both divergence perturbations. Before the
alignment, the only disagreements were exactly those artifacts (`fpc` 3.2.3
vs 3.2.2, and two `github_sha` values). No licence, SDK or corpus field
disagreed.

**macOS is the hosted run's.** The measurement run covered macOS up to
CAP-9C1: Currency, CAP-7M0/7M1/7M2, CAP-8B/8C, and CAP-9A/9B1/9B2 with the
re-declaration still present. Everything after that is `RP2-6`.

## VERDICT

**MORMOT-REPIN-2 READY — hosted CI outstanding.**

- The pin is on the smallest upstream commit that carries the three fixes,
  and each hash was checked against the tree.
- The statics did not need to move.
- The Currency return register is right on all four targets on the unpatched
  candidate, measured on each leg's own compiler, and every row gates.
- The `JS_SetMaxStackSize` re-declaration is gone. Three gates hold its
  replacement, and each was observed refusing a revert.
- There was no `pas_malloc` workaround to remove. The fix it would have
  guarded now has a gate of its own.
- `RP-2`, `9A-3` and `9A-4` are `CLOSED` by `RP2-1` to `RP2-3`, with the
  commits named, and `9B1-8` is closed by `RP2-7`.
- Every supersession is a measured pair, or is named as owed.

Windows and Linux are green locally on the committed HEAD. What only the
hosted run of the final HEAD can prove is one open row, `RP2-6`:

- the four legs and the aggregate green;
- on both macOS legs, CAP-9 without the re-declaration, including the new
  depth probe and declaration check, and CAP-10 to CAP-15;
- the aarch64-darwin compile of the widened export;
- the two macOS `sdk_inventory_digest` values;
- CAP-10D0 L2b on Windows.

The closure reads them from that run, records them here, and closes `RP2-6`.
