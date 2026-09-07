---
title: 'CAP-11B — the upstream watcher, and the closure of CAP-11'
type: 'feature'
created: '2026-09-07'
status: 'in-review'
baseline_commit: '864fca7c7dfd3f107b9ba8f915b9adf3be9e9cab'
review_loop_iteration: 0
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/webview.lock'
  - '{project-root}/_bmad-output/implementation-artifacts/cap11a-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The SPEC's CAP-11 acceptance has two halves. CAP-11A froze the first
(the four-target matrix). The second — *"a separate watcher compiles the binding
against upstream head and reports an API diff without changing the pinned
version"* — does not exist: nothing in this repository would notice that
`webview/webview` moved past `cbbdee44` until a human decided to look. CAP-11
also cannot close: its eighteen ledger entries have no phase-wide disposition,
there is no CAP-12 handoff, and commit `864fca7` tracked a `LICENSE` at the
repository root, which makes the absolute pin `sdk_own_license = 'undeclared'`
false on all four legs the moment that commit is pushed.

**Approach:** One standalone scheduled workflow that answers a single question
per target — *does the pinned binding still match upstream head, and if not,
what changed?* — and publishes the answer as a report it never acts on. The
diff is taken from the headers mechanically: the six public C headers are
parsed into a canonical model, the model is projected into a Pascal binding in
the watcher's own workspace, and `signature_pin` and the paired ABI probes are
compiled against that projection — first against the **pinned** headers as a
calibration, then against **head**. The watcher never re-pins, never writes the
tree, never fails the matrix, and its report is never an input to a build. The
shard then closes CAP-11: phase ledger, SPEC acceptance table, CAP-12 handoff,
`docs/watcher-contract.md`, and the licence regression the root `LICENSE` created.

## Boundaries & Constraints

**Always:**
- The watcher runs with `permissions: contents: read` at workflow level, no
  job-level grant, no secret, no token beyond the default read-only one.
- Its job conclusion is `success` whenever the watcher itself ran. The verdict
  lives inside the report, drawn from exactly six frozen words:
  `unchanged | compatible_additive | patch_drift | abi_break | build_failed |
  inconclusive`. `inconclusive` is legal and always names its cause.
- The API diff comes from the headers, mechanically. A declaration the parser
  cannot read is `inconclusive`, never a silent pass.
- Every ref-parameterised build script is byte-for-byte the pinned path when the
  ref input is absent, and that is gated, not asserted.
- The watcher's own gates run on the four platform legs like every other
  capability's; the watcher's *runtime* never does.
- CAP-11's closure disposes of every CAP-11 ledger entry with zero orphans.

**Ask First:**
- Moving any lock value, pin or digest that is not forced by the tracked
  `LICENSE` regression.
- Changing the six-word verdict vocabulary after it is pinned.

**Never:**
- Move `webview.lock`, `mormot.lock` or any pin; write into `src/`, `deps/`,
  `sdk/`, `tools/setup/`, `examples/`; regenerate `webview.chet` or the binding
  anywhere but the watcher's workspace.
- Open a PR, push a branch, create or update a GitHub issue, or auto-merge.
- Run the watcher from `ci.yml` or `platform-leg.yml`, `needs:`-link it, or make
  it a required check.
- Fail because upstream changed — a change is news, not a regression.
- Consume a previous watcher report as an input to a verdict (no
  `download-artifact`, no `gh run download`, no `actions/cache` in the watcher).
- Choose or write a licence. `LICENSE` at the root is a fact this shard *reads*.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| W1 dispatch | watcher runs on four targets | artifact `upstream-watch-<target>` (JSON + Markdown) + job summary; conclusion `success` | driver always exits 0 |
| W2 head == pin | ref input = the pinned SHA | `unchanged` on four targets, diff empty | N/A |
| W3 added prototype | seeded header with one extra `WEBVIEW_API` | `compatible_additive`; diff names the prototype | N/A |
| W4 changed signature | seeded header, one param added to `webview_navigate` | `abi_break`; `signature_pin` fails to compile; report names `webview_navigate` | calibration compile must have passed first, else `inconclusive` |
| W5 patch rejected | seeded tree where the CAP-4W patch context moved | `patch_drift` with the rejected hunk | Linux/macOS declare no patch → `not_applicable`, never `patch_drift` |
| W6 build fails | seeded non-zero library build | `build_failed` with the log tail; conclusion still `success` | N/A |
| W7 network refused | fetch seam refuses | `inconclusive` naming the cause; conclusion `success` | N/A |
| W8 pinned path | every build script invoked with no ref input | `--print-plan` output byte-identical to the recorded pinned plan; both locks' sha256 unchanged | any difference fails the leg |
| LI1 licence | `git ls-files LICENSE` non-empty | `sdk_own_license = declared`; SDK ships `LICENSE.pweb.txt`; manifest lists it on four targets | a documented/shipped mismatch fails PK3 |

</frozen-after-approval>

## Code Map

**Authority (read-only)**
- `_bmad-output/specs/spec-pweb/SPEC.md:57` — the CAP-11 acceptance line; `phase-plan.md:64-76` — the Phase 1 ABI checklist the watcher reuses; `phase-plan.md:96`.
- `webview.lock` — `commit = cbbdee44…`, six `sha256:core/include/webview/*.h` rows (the header set the watcher parses), `cap4w-patch-sha256`, `srclib-platform-patch-sha256`, `linux-soname`, `macos-dylib*`.
- `docs/webview-upstream-semantics.md` — "17 entry points at this pin"; `version.h` deliberately outside the binding.
- `_bmad-output/implementation-artifacts/cap11a-final-artifact.md` — closure run `34022414932` on `d63d7e3`, six jobs green; the 64 KB / 1,600-line bound; retention classes; the licence measurement and its ledger entry.
- `_bmad-output/implementation-artifacts/deferred-work.md:899-952` — the **eighteen** CAP-11A entries this closure must dispose of (317 entries total).

**The pinned path the watcher parameterises**
- `tools/get-webview.ps1` — 138 lines; reads the lock, fetches the exact SHA into `deps/webview`, verifies the six header checksums after CRLF→LF normalisation.
- `tools/build-webview-dll.ps1:100-110` (cmake args), `:154` (`webview_core_shared`), `:158` (`core/Release/webview.dll`), `:166` (dist copy).
- `tools/build-webview-so.sh:140-152` (cmake), `:159-166` (`real_lib`, SONAME assertion), `:171-180` (stage).
- `tools/build-webview-dylib.sh` — 419 lines; sources `tools/macos-buildenv.sh`; asserts arch, deployment target, WebKit link.
- `tools/patch-cap4w-webview.ps1` + `tools/cap4w/webview2-custom-scheme.patch` — the ONE platform patch; Windows only. `.github/actions/cap-7l-deps-webview-carries-no-linux-patch` and `cap-7m0-deps-webview-carries-no-macos-patch` prove the other three targets carry none.

**What is compiled against the projection**
- `test/core/signature_pin.pas` — 17 typed procedural constants; `fpc -Sh -FUbuild/fpc -Fusrc/lib -Fideps/mormot2/src -FEbuild/test`.
- `test/core/abi_probe.pas` (uses `pweb.lib.webview`, `.types`, `.errors`) and `test/core/abi_probe.c` (`-Ideps/webview/core/include`); compared line-by-line by `.github/actions/abi-probe-compare-any-diff-is-a-blocker` (≥ 30 facts).
- `src/lib/pweb.lib.webview.pas` — the shape the projector must reproduce: `webview_error_t = Integer`, enum members as consts, `webview_t = Pointer`, records with `array [0..N-1] of AnsiChar`, `webview_dispatch_fn`/`webview_bind_fn` named `<func>_<param>`, `external LIB_WEBVIEW name _PU + '<c name>'`.
- `src/lib/pweb.lib.webview.types.pas` / `.errors.pas` — pure alias views, copied verbatim into the workspace.
- `test/cap7l/check_webview_exports.sh` and `test/cap7m/check_webview_exports.sh` take a library path argument; `test/cap4w/check_webview_exports.ps1` takes `-DllPath`.

**CI structure the watcher must satisfy**
- `test/cap11a/check_ci_structure.ps1:22-44` — 64 KB / 1,600 lines over **every** file under `.github/`; `$PINNED_ACTIONS` (six SHA-pinned actions) enforced over every `.yml`/`.yaml`; retention swept only on the caller and the leg.
- `.github/workflows/platform-leg.yml:874-914` — the gate-step form to copy; `test/cap11a/step-applicability.tsv` — 196 rows, `ordinal / name / applies_to / conditionality`.
- Toolchain actions to reuse: `install-fpc-pinned-lazarus-3-4-installer-sha256-verified`, `install-the-ratified-webkitgtk-stack-and-fpc-distro-packages`, `cap-7m0-install-pinned-fpc-and-select-the-pinned-xcode`, `fetch-pinned-webview-webview-exact-sha-checksum-verified`, `fetch-pinned-mormot2-exact-sha-sha256-pinned-statics`.

**The licence regression**
- `tools/pweb/pwebsdk.pas:189-201` `LICENSE_TABLE` (4 rows), `:441-461` `ShipTableDigest`, `:579-611` the manifest/unratified check.
- `test/cap10d2/build_cap10d2.ps1:78-84` and `build_cap10d2.sh:104-110` — the staging calls.
- `docs/third-party-licenses.md:12-17` — the machine-readable table; `test/cap10d2/check_cap10d2_contracts.ps1:215-247` and `run_cap10d2_gates.ps1:440-470` read it mechanically.
- `test/cap7f/check_cap7f_aggregate.ps1:496-498` — `sdk_own_license = 'undeclared'`; `test/cap7f/emit_evidence.sh:1858-1866` and `emit_evidence.ps1:2055` already detect a tracked `LICENSE`.
- `docs/sdk-contract.md:89` — "every shipped **third-party** component's notice".

**Measured facts that shape the design**
- The default branch is `main`, 128 commits behind this branch; `workflow_dispatch` is only offered for workflows present on the default branch, so a dispatch-only watcher is unprovable on the branch that introduces it.
- `864fca7` (`LICENSE`, MPL-2.0, 16,726 B) is **local only** — no CI run has ever seen it. Runs: `34022414932` (`d63d7e3`) and `34028255921` (`a93265e`), both success.
- WSL on this host has fpc 3.2.3, cmake, gcc, pkg-config, nm and webkit2gtk-4.1 2.52.6 — the whole Linux watcher path is verifiable locally before any hosted run.

## Tasks & Acceptance

**Execution:**

*The diff and projection engine (new, `test/cap11b/`)*
- [x] `test/cap11b/extract_api.ps1` -- parse the six public headers into a canonical JSON model (functions, callback typedefs, enums with resolved values, structs, `void*` typedefs, `WEBVIEW_VERSION_*` macros) -- the diff must be mechanical, so prose is never consulted; an unparsable public declaration is a typed refusal.
- [x] `test/cap11b/diff_api.ps1` -- compare two models into added / removed / changed per category with both C spellings -- this is the report's content and the input to the verdict.
- [x] `test/cap11b/project_binding.ps1` -- project a model into `pweb.lib.webview.pas` in a workspace directory, using a fixed C→Pascal table; refuse on an unmapped C type -- so `signature_pin` can be compiled against *head's* header without ChetCLI, which is a Windows-only Delphi tool absent from every runner.
- [x] `test/cap11b/watch_upstream.ps1` -- the driver: the eight ordered steps, the verdict precedence, the JSON + Markdown report, the job summary, `exit 0` unconditionally -- one file owns the contract so four targets cannot disagree about it.

*The watcher workflow*
- [x] `.github/workflows/upstream-watch.yml` -- schedule + `workflow_dispatch` (optional `ref`) + `push` restricted to the watcher's own paths; `permissions: contents: read`; four-target matrix, `fail-fast: false`; toolchain via the ratified composite actions; one upload at `retention-days: 90` -- the `push` trigger exists because `workflow_dispatch` is not offered off the default branch, so without it the watcher could not be proven on the branch that adds it.

*Ref parameterisation with a byte-identity gate*
- [x] `tools/get-webview.ps1` -- add `-Ref`; absent = today's behaviour exactly, present = fetch that ref into `deps/webview-watch` with the pinned-header cross-check off and the resolved commit recorded.
- [x] `tools/build-webview-dll.ps1`, `tools/build-webview-so.sh`, `tools/build-webview-dylib.sh` -- add the same one input, deriving source/build/dist under `build/cap11b/`; with a ref the lock's *name* assertions (SONAME, dylib names) become recorded observations instead of refusals, because an upstream version bump is news, not a build failure.
- [x] all four scripts -- add `--print-plan` / `-PrintPlan`: resolve every path, flag and assertion mode, print a canonical block, touch nothing, exit 0.
- [x] `test/cap11b/pinned-plan.expected.txt` + `test/cap11b/check_ref_input.ps1` -- record the five pinned plans and compare byte-for-byte with no ref input; also assert every lock digest unchanged after a driver run.

*The gates that run on the four legs*
- [x] `test/cap11b/check_watcher_contract.ps1` -- source gate: exact permissions block, no secret, exact trigger set, no `workflow_call`, no reference from `ci.yml`/`platform-leg.yml`, allowlisted `uses:`, retention, no write to a lock or a frozen tree, no `git push`/`gh pr`/`gh issue`, no report ingestion.
- [x] `test/cap11b/check_cap11b_cases.ps1` + `test/cap11b/fixtures/**` -- the six seeded verdicts, offline, with a real FPC compile behind W4.
- [x] `test/cap11b/check_cap11_ledger.ps1` -- modelled on `test/cap10d2/check_cap10_ledger.ps1`: `<shard>-<ordinal>` plus the first eight hex of the summary digest; orphan / stray / count drift / silent reword are four different failures; requires the SPEC CAP-11 acceptance table, both hosted runs, the CAP-12 handoff and `docs/index.md` cross-linking `docs/watcher-contract.md`.
- [x] `.github/workflows/platform-leg.yml` + `test/cap11a/step-applicability.tsv` -- add the four CAP-11B gate steps once, all four targets, unconditional (196 → 200).
- [x] `test/cap7f/emit_evidence.ps1`, `emit_evidence.sh`, `check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1` -- add the CAP-11B rows, their comparisons and their absolute pins; raise the refusal floor.

*The licence regression (forced by a tracked `LICENSE`, not a decision)*
- [x] `tools/pweb/pwebsdk.pas` -- add `LICENSE.pweb.txt` (`swAlways`) to `LICENSE_TABLE`; the ship-table digest moves with it.
- [x] `docs/third-party-licenses.md` -- add the row and say plainly that the table is the *shipped notice* set, which now includes PWeb's own.
- [x] `test/cap10d2/build_cap10d2.ps1` / `.sh` -- stage `<repo>/LICENSE` as `LICENSE.pweb.txt`.
- [x] `docs/sdk-contract.md` -- one word at `:89`, and the manifest example.
- [x] `test/cap7f/check_cap7f_aggregate.ps1` -- `sdk_own_license = 'declared'`.

*Closure*
- [x] `docs/watcher-contract.md` (new) + `docs/index.md` -- the watcher contract and its row.
- [x] `_bmad-output/implementation-artifacts/cap11-closure-artifact.md` -- 11A and 11B runs, supersessions, the phase ledger with zero orphans and the three flakes' current state, `sdk_own_license` re-measured, the SPEC acceptance line by line, the CAP-12 handoff.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append the CAP-11B entries, including the mORMot-watcher decision and the issue decision with their reasons.

**Acceptance Criteria:**
- Given the watcher is dispatched on four targets, when every job finishes, then each publishes its artifact and job summary and every conclusion is `success`, whatever the verdict inside.
- Given the four build scripts are invoked with no ref input, when `--print-plan` is compared to the recorded pinned plan, then the output is byte-identical on all four targets and both lock digests are unchanged after a watcher run.
- Given the watcher's source, when the contract gate reads it, then `permissions` is exactly `contents: read`, no secret is referenced, neither `ci.yml` nor `platform-leg.yml` mentions it, and nothing in it can commit, push, open an issue, or read a previous report.
- Given nine cases, when the case gate runs on each leg, then the driver returns exactly the six typed verdicts, names the prototype for `abi_break` and the hunk for `patch_drift`, exits 0 every time, and case W8 — the one that is not seeded — runs the whole ref path for real against the pinned commit with build, exports and the paired ABI probe all `ok`.
- Given the projector, when it is run over the **pinned** headers, then `signature_pin` and both ABI probes compile and agree — the calibration that makes a head compile failure attributable to head rather than to the tool.
- Given `LICENSE` is tracked, when the four legs emit evidence, then `sdk_own_license` reads `declared`, the SDK archive contains `share/pweb/licenses/LICENSE.pweb.txt`, and the manifest lists it on all four targets.
- Given the CAP-11 ledger, when the closure gate runs, then every CAP-11 entry has a disposition, `cap11_ledger_orphans = 0`, the SPEC's CAP-11 acceptance is answered line by line, and `docs/index.md` cross-links `docs/watcher-contract.md`.
- Given the full matrix on this branch, when the closure run completes, then all six jobs are green — including the licence regression that would otherwise turn all four legs red.

## Design Notes

**Why a projector and not ChetCLI.** `tools/regen-webview-binding.ps1` needs
`ChetCLI.exe` at a hard-coded Windows path; no runner has it. But the generated
binding is a mechanical function of the headers, and reproducing that function
for the closed set of constructs these six headers use is small. The projector
is *calibrated on every run*: it first projects the pinned headers and compiles
`signature_pin` against the result. If that fails, the tool is broken and the
verdict is `inconclusive` — never `abi_break`. Only after calibration passes is
a failed head compile evidence about upstream.

**Verdict precedence** (first match wins; the report carries every observation
regardless): `abi_break` → `patch_drift` → `build_failed` → `inconclusive` →
`compatible_additive` → `unchanged`.

`inconclusive` is deliberately not first, and the original ordering — which put
it there — was corrected during implementation. `patch_drift`, `build_failed`
and the removals and changes behind `abi_break` are settled by git and the
headers alone, so a run whose Pascal toolchain could not calibrate still knows
those three for certain; burying them under a toolchain fault would throw away
the news the watcher exists to carry. What *does* depend on the projector is the
claim that nothing broke, so `inconclusive` outranks `compatible_additive` and
`unchanged`.

**The issue decision: no issue.** Writing a GitHub issue needs `issues: write`,
which cannot coexist with the ratified `contents: read`-only posture on a job
that compiles an unpinned upstream commit. And "one long-lived issue *titled by
the upstream commit*" is self-cancelling: the title changes with every new head,
so the rule would create a second issue for the next commit — the thing it
forbids. Artifact + job summary only.

**The mORMot decision: ledger it.** The webview watcher's shape is fetch head →
apply the pinned patch → build a shared library → parse C headers → project →
compile a signature pin → diff. mORMot head has no C headers, no patch, no
library build and no signature pin; its `statics-url` is pinned by sha256 to a
`2.4-stable` release asset, so compiling source head against those statics makes
`build_failed` the *normal* outcome rather than news. It does not fit the shape;
it is ledgered with that reason.

## Verification

**Commands (local, before any hosted run):**
- `pwsh -NoProfile -File test/cap11b/check_watcher_contract.ps1` -- expected: exit 0, every contract row PASS.
- `pwsh -NoProfile -File test/cap11b/check_ref_input.ps1` -- expected: exit 0, four plans byte-identical, both locks unchanged.
- `pwsh -NoProfile -File test/cap11b/check_cap11b_cases.ps1` -- expected: exit 0, six typed verdicts.
- `pwsh -NoProfile -File test/cap11b/check_cap11_ledger.ps1` -- expected: exit 0, `cap11_ledger_orphans = 0`.
- `pwsh -NoProfile -File test/cap11a/check_ci_structure.ps1` -- expected: exit 0 with the watcher present and every file under `.github/` inside the 64 KB / 1,600-line bound.
- `wsl -e bash -lc 'pwsh -NoProfile -File test/cap11b/watch_upstream.ps1 -Target linux -Ref <pinned sha>'` -- expected: `unchanged`, empty diff, exit 0, `webview.lock` sha256 unchanged.
- `wsl -e bash -lc 'tools/build-webview-so.sh --print-plan'` -- expected: byte-identical to the recorded pinned plan.
- `git diff --stat 864fca7 -- src/ sdk/ tools/setup/ examples/ deps/ *.lock` -- expected: empty.

**Hosted:**
- One `Upstream watch` run, four jobs, all `success`, four artifacts.
- One full `CI` run on the CAP-11B HEAD: six jobs green, `sdk_own_license = declared` on four targets, 200 steps in one sequence.
