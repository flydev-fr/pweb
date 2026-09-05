---
title: 'CAP-6 bundler: a UTF-16 argv so a non-ASCII project path packs (ledger D2-13)'
type: 'bugfix'
created: '2026-09-05'
status: 'in-review'
baseline_commit: 'b78e0fb24bce947984821f4aae51c0519878e796'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `pwebbundle` reads its two arguments through the RTL, whose Windows
argv is an ANSI conversion of the command line, so a project whose root carries a
non-ASCII character reaches the bundler as `?tude apps` and the `pack` stage of
`pweb build` fails with `dist directory not found` about a directory that is
plainly there (ledger D2-13, reproduced on the dev host at ACP 1252: the argv
byte `$E9` is later read as UTF-8, because mORMot sets `DefaultSystemCodePage` to
`CP_UTF8`, and the RTL's UTF-8 to UTF-16 conversion yields U+FFFD).

**Approach:** read argv from the kernel on Windows — `GetCommandLineW` through
`CommandLineToArgvW` — exactly as `PWebCliImageDir` now asks the kernel for the
image path (D2-12), and convert to the process string type, which is UTF-8 here.
POSIX keeps `ParamStr`/`ParamCount`: argv there is bytes the RTL hands over
unchanged. Then prove it at both ends — a CAP-6 leg that packs a non-ASCII input
to a non-ASCII output and requires the archive to be byte-identical to the ASCII
one, and the CAP-10D2 clean-machine project root moved to a spaced AND accented
path on Windows, which is the `pack` stage running where D2-13 said it could not.

## Boundaries & Constraints

**Always:** the archive's bytes are a function of the logical corpus only — the
new CAP-6 leg asserts SHA256 equality with the ASCII build, so a change that
moved one byte fails. Windows-only code, inside `{$ifdef OSWINDOWS}`; the CAP-7F
divergence allowlist entry for `tools/bundler/pwebbundle.pas` is re-ratified in
the SAME commit if its count or fingerprint moves. `ParamStr(0)`/`ParamCount`
semantics are preserved by the replacement helpers.

**Ask First:** any change to the bundler's option grammar, its output format, or
the `pwebbundle <dist> <out.pwb>` argument contract `pweb.cli.pack` freezes.

**Never:** no new option, no new exit code, no `--profile`-style surface, no
change to `pweb.cli.pack`, no POSIX behaviour change, and no touching the wider
ledgered TFileName/MAX_PATH limitation (deferred-work line 17) — this closes the
argv layer and nothing else.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Non-ASCII input and output | `pwebbundle "<tmp>\<e-acute>tude dist" "<tmp>\<e-acute>tude out.pwb"` | exit 0; bytes identical to the ASCII-path build | N/A |
| ASCII paths, unchanged | every existing CAP-6 invocation | identical bytes and identical stdout to before | N/A |
| Options after a non-ASCII path | `... --min-runtime=0.2.0` at an accented path | manifest stamps `0.2.0`; option parsing unmoved | usage + exit 1 on an unknown option |
| `--verify` at a non-ASCII path | `pwebbundle --verify "<tmp>\<e-acute>tude out.pwb" 3` | verify OK, 3 cycles | exit 1 with the typed refusal text |
| Missing directory | a genuinely absent accented path | `dist directory not found: <the real path>` | exit 1, message spells the path correctly |

</frozen-after-approval>

## Code Map

- `tools/bundler/pwebbundle.pas` — the fix. `RunVerify` (`ParamCount`,
  `ParamStr(2)`, `ParamStr(3)`), `RunBuild` (`ParamCount`, `ParamStr(i)`) and the
  main block (`ParamCount >= 1`, `ParamStr(1) = '--verify'`) are the five call
  sites. It already imports `windows` under `{$ifdef OSWINDOWS}` and already
  talks to the wide API in `Collect`.
- `tools/pweb/pweb.cli.platform.pas:604-687` — the ratified precedent to mirror:
  the `CommandLineToArgvW` external declaration ("the ONLY shell32 import … it
  parses rather than executes"), `PWebCliRawArgs` in both bodies, and
  `PWebCliImageDir:1051` for the D2-12 comment shape.
- `deps/mormot2/src/core/mormot.core.os.pas:13002` —
  `SetMultiByteConversionCodePage(CP_UTF8)`: why `string` in this program is
  UTF-8 and why `Utf8ToString` is lossless here.
- `test/cap7f/check_divergence.ps1:107` — `tools/bundler/pwebbundle.pas` at
  `directives = 6`, fingerprint `7e329077…`; a bare `{$else}` is NOT counted (no
  platform symbol). Line 113 is `pwebqjspack.pas` carrying the same value today.
- `test/cap6/run_cap6_gates.ps1` — legs 1-9; `$h1` (line 74) is the ASCII-path
  SHA256 the new leg compares against. The gate runs on the Windows job only.
- `test/cap10d2/run_cap10d2_gates.ps1:671-688` — the comment that records WHY the
  clean-machine project root is spaced rather than accented, and `$projRoot`.
  Line 473 shows the house convention for a non-ASCII literal: `[char]0x00E9`.
- `test/cap6/check_cap6_nonetwork.ps1:21` — forbidden-pattern sweep over the
  bundler source; new code and comments must avoid `socket`, `http`, `file://`.
- `_bmad-output/implementation-artifacts/deferred-work.md:848-850` — the D2-13
  entry; `cap10-closure-artifact.md:270` — its row, keyed `c3483e49`, checked by
  `test/cap10d2/check_cap10_ledger.ps1` (a digest over the entry text).

## Tasks & Acceptance

**Execution:**
- [x] `tools/bundler/pwebbundle.pas` — add a Windows `CommandLineToArgvW` external
  plus `ArgCount`/`Arg` helpers (POSIX: `ParamCount`/`ParamStr`), and route all
  five call sites through them — the argv is the only broken layer.
- [x] `test/cap7f/check_divergence.ps1` — re-ratify the `pwebbundle.pas` row
  (count and fingerprint) in this commit, with a comment saying what moved and
  why, and note that its fingerprint no longer equals `pwebqjspack.pas`'s.
- [x] `test/cap6/run_cap6_gates.ps1` — new leg: pack a copy of the React dist at
  `<e-acute>tude dist` to `<e-acute>tude out.pwb`, require exit 0 and SHA256 ==
  `$h1`, re-run with `--min-runtime=0.2.0` and read the stamped manifest, then
  `--verify` the accented bundle; renumber the observational benchmark.
- [x] `test/cap10d2/run_cap10d2_gates.ps1` — on Windows, move `$projRoot` to a
  spaced AND accented name via `[char]0x00E9`; rewrite the comment from "it stays
  spaced because the bundler cannot" to what it now measures, and say why POSIX
  keeps the ASCII name (macOS normalises Unicode filenames, so an accented POSIX
  path would measure the OS rather than this fix).
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` — append the
  resolution entry; `cap10-closure-artifact.md` — flip the D2-13 row to RESOLVED
  with its new digest and a one-line reason.

**Acceptance Criteria:**
- Given the fixed bundler, when the CAP-6 gates run on the hosted Windows runner,
  then every existing leg passes unchanged and the new accented leg produces an
  archive whose SHA256 equals the ASCII-path archive's.
- Given a clean checkout, when `test/cap7f/check_divergence.ps1` runs, then it
  passes, and `check_cap7f_selftest.ps1` leg (e) still refuses through the
  `ALLOWLIST FINGERPRINT CHANGED` branch.
- Given the CAP-10D2 clean-machine leg on Windows, when `pweb build` runs on the
  react project under the accented root, then the `pack` stage exits 0, the leg
  records the root's shape and requires the accent by name, and the leg's other
  recorded rows are unchanged.
- Given `check_cap10_ledger.ps1`, when it runs, then the D2-13 ledger entry's
  `summary:` is UNCHANGED — so its digest stays `c3483e49` and the gate reports
  `ledger_reworded: 0` — while the closure row's disposition reads RESOLVED; the
  resolution is carried by an appended entry and by a `superseded_by` note on
  D2-13's `evidence:` line, which the digest does not cover.

## Verification

**Commands:**
- `pwsh -File test/cap6/build_cap6.ps1` — expected: the bundler compiles.
- `pwsh -File test/cap6/run_cap6_gates.ps1` — expected: ALL PASS locally.
- `pwsh -File test/cap6/check_cap6_nonetwork.ps1` — expected: PASS.
- `pwsh -File test/cap7f/check_divergence.ps1` — expected: exit 0 after the
  re-ratification.
- `pwsh -File test/cap10d2/check_cap10_ledger.ps1` — expected: exit 0.
- CAP-7F selftest leg (e), reproduced directly: swap the first
  `{$ifdef OSWINDOWS}` in the bundler for `{$ifdef ANDROID}`, run the
  divergence sweep, byte-restore — expected: the sweep refuses through the
  `ALLOWLIST FINGERPRINT CHANGED` branch, then passes again.
- A local `pweb build` from `build/cap10b1/sdk` on a project created under an
  accented root — expected: `pack` exits 0, the D2-13 reproduction inverted.
- A WSL compile of `tools/bundler/pwebbundle.pas` — expected: the POSIX body
  still compiles, since the Linux and macOS legs build the same program.
