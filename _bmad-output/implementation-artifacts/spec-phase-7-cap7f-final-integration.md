---
title: 'Phase 7 / CAP-7F — final cross-platform integration and CAP-7 closure'
type: 'chore'
created: '2026-08-18'
status: 'in-progress'
review_loop_iteration: 0
context:
  - '_bmad-output/specs/spec-pweb/conventions.md'
baseline_commit: '8f0d05aa42045a292af182f8a3f9287c148ae4e6'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** All four CAP-7 targets are individually closed (CAP-7L, CAP-7M0/M1/M2, on top of CAP-13), but nothing proves them against each other: no machine-readable per-target evidence exists off macOS, no CI job compares the targets semantically, the CAP-7M2 shared-host automation arguments (`--pweb-verdict=`, `--pweb-autoclose-ms=`) are executed by no gate on Windows/Linux (deferred-work.md:173-174), and CAP-7 itself has no closure record.

**Approach:** A closure shard, not another platform implementation. Add committed per-target evidence emitters and one final CI aggregation job that consumes compact uploaded artifacts and fails on any semantic disagreement (ABI surface, webview pin, origin, RPC verdict, logical app.pwb inventory, release layout, no-listener, host-argument coverage). Execute the shared-host argument paths on Windows and Linux. Audit platform divergence against an explicit allowlist. Then — only after the aggregation job is green on hosted CI — record CAP-7 CLOSED in this artifact. Expected production-code changes: none.

## Boundaries & Constraints

**Always:**
- Every evidence field derives from a check actually executed in the same hosted run; a conditional gate's SKIP and a ratified WAIVED are recorded as `SKIP`/`WAIVED`, never as `PASS`.
- The aggregator compares structured verdict fields, never localized prose; it must fail if a target's evidence artifact is absent, a required field is absent, any field disagrees semantically, or a waiver is mislabeled.
- The logical-inventory formula on Windows/Linux is byte-identical to `test/cap7m/run_cap7m_release.sh` `emit_manifest` (:271-288): rows `entry=<name> size=<bytes> sha256=<lowercase hex>`, LF line endings, entries in `LC_ALL=C` byte order, directories skipped; `logical_inventory_sha256` = SHA-256 of the manifest file bytes.
- New verification lives in committed scripts under `test/cap7f/`; CI steps stay thin invocations. `ci.yml` stays one file (the split is deferred work D5, not this shard).
- All existing jobs, steps, gates, freeze sweeps and their semantics are preserved unchanged; new steps append after existing gates within each job.
- Shell scripts follow bash-3.2-safe patterns and the `cap7m_prepare_dir`-style guarded deletes (no unguarded `rm -rf`).

**Ask First:**
- Any change to production source (`src/**`, `examples/08-release/releaseapp.pas`, `tools/bundler/`) — the target is zero; a testability correction needs explicit justification plus full platform reruns.
- If the cross-OS logical inventory comparison FAILS (e.g. frontend dist bytes differ between Windows/Linux/macOS builds): this is a ratified blocker — investigate and report, never normalize the difference away inside the emitter.
- Relaxing, reordering, or rewording any existing gate or ratified marker.

**Never:** begin CAP-8/CAP-10/CAP-11/CAP-12 (no upstream watcher, no CLI); Universal 2; Linux packages; macOS signing/notarization; modify CAP-13 installers, profiles, or WebView2 locks; redesign any platform adapter or the host argument interface; rerun clean-machine provisioning gates; rewrite earlier artifacts.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Aggregate, all agree | 4 evidence JSONs + macOS inventories present, all fields consistent | `platform-matrix.json` emitted + step summary; job green | N/A |
| Target artifact absent | one of 4 evidence artifacts missing | aggregation job fails naming the target | exit 1, no matrix |
| Field disagreement | export set, webview pin, protocol, origin, rpc value, or react `logical_inventory_sha256` differs | fail naming field + both values | exit 1 |
| Mislabeled waiver | evidence field `SKIP`/`WAIVED` where matrix requires `PASS` | fail; SKIP never promoted | exit 1 |
| Win/Linux args: PASS leg | `--pweb-verdict=<f> --pweb-autoclose-ms=4000`, env set to 55000 | verdict file holds canonical PASS line; wall clock proves argv won | FAIL verdict/timeout ⇒ gate fails |
| Win/Linux args: refusal | unknown arg (and separately malformed `--pweb-autoclose-ms=x`) | nonzero exit, usage message, FAIL verdict file still written | missing FAIL verdict ⇒ gate fails |
| Windows runtime unusable | hosted runner lacks WebView2/desktop | args gate records `SKIP` (same policy as `run_cap6_smoke.ps1`) → aggregator fails the runtime row | honest failure, not silent green |
| Divergence sweep | new platform conditional in scheduler/bridge/intf/capabilities/binding/SDKs/bundle semantics | sweep fails naming file:line | exit 1 |

</frozen-after-approval>

## Code Map

**Preconditions (verified from repository + hosted evidence — do not re-derive):**
- CAP-13 CLOSED: `spec-phase-6b4-windows-profile-integration.md:157`, commit `b18e88e91225421d32712de1d0c011afe771ce07`, run `31879087884` green (verified on flydev-fr/pweb).
- CAP-7L CLOSED: `spec-phase-7-cap7l-linux-x64-parity.md:307`, closure `5cb564da…`, run `31890995361` green (commit `eb527145`, verified).
- CAP-7M0 PASS: closure `a6b28bb`, run `31912129480` green (commit `529f017`, verified).
- CAP-7M1/M2 PASS: closure commits `30c80a7` / `8f0d05a`; mirror-era runs (`31953707173`, `31954668946`, `31968338053`) ran on the now-deleted public mirror `flydev-fr/poueb` and are no longer fetchable. Superseding evidence: **flydev-fr/pweb is now public** and run **`32013558592`** on `main` covers `8f0d05aa42…` (the CAP-7M2 closure commit = current HEAD) with all five jobs green: `windows`, `linux-x64`, `macos-x64`, `macos-arm64`, `macos release inventory` (verified 2026-08-18). Precondition satisfied.

**Evidence sources / reuse points:**
- `examples/08-release/releaseapp.pas` — shared host; args `ARG_VERDICT`/`ARG_AUTOCLOSE` :162-163, two-pass parse :466-521, argv-beats-env :686-692, `VERDICT_PASS` :160, verdict write on every exit :816-829. READ-ONLY this shard.
- `test/cap7m/run_cap7m_release.sh` — `emit_manifest` :271-288 (formula to replicate), inventory schema :569-587, refusal matrix :663, LS launch :417.
- `test/cap7m/cap7m_common.sh:62` `record_measurement`; `build/cap7m/measurements.txt` uploaded `if: always()` (ci.yml:2090/2387); `cap7m2-release-{x64,arm64}` artifacts = `manifest-{react,pas2js}.txt` + `inventory-{react,pas2js}.txt` (ci.yml:2059/2360).
- `test/cap7l/run_release_layout.sh` — Linux release dist `dist/linux-x64/release/` (four files), builds app.pwb per frontend with native `pwebbundle`, env-only autoclose :49, launches :85 — the D1 gap; runs under `xvfb-run -a` (ci.yml:1720).
- `test/cap6/run_cap6_gates.ps1` — Windows release dir `build/cap6/release` (:145-156, exe+app.pwb+dll), React-only app.pwb (ratified). `test/cap6/run_cap6_smoke.ps1` — conditional PASS/SKIP policy :29-49 to mirror in the args gate.
- Export-set checkers (identical 17-name list, three copies): `test/cap4w/check_webview_exports.ps1:47-52` (PE/dumpbin), `test/cap7l/check_webview_exports.sh:27-31` (ELF/nm -D), `test/cap7m/check_webview_exports.sh` (Mach-O/nm). x86_64 Mach-O carries 8 weak `_ZT[IS]` libc++ typeinfo symbols outside the 17 — permitted, already measured.
- Pins: `webview.lock:3-4` upstream `cbbdee44afff22867de9fd88a9fc8350d9bdd399`; soversion 0.12 (`webview.lock:22,49-51`); no numeric wrapper-ABI constant exists — the surface pin (exactly 17) + soname IS the wrapper ABI contract; `srclib-platform-patch-sha256` `webview.lock:86`; `fpc.lock` 3.2.2; `pas2js.lock` 3.0.1.
- No-listener gates: `test/cap7l/check_cap7l_nonetwork.sh` (ci.yml:1725), `test/cap7m/check_cap7m_nonetwork.sh` (:2078/2379), `test/cap5|cap6/check_*_nonetwork.ps1` (:1003/1048).
- ci.yml insertion points: windows job ends ~:1462 (cap6b4/cap1 diagnostics), linux ends ~:1732, macOS emit/upload area :2053-2100 / :2354-2400, aggregation precedent `macos-release-inventory` :2426-2481 (existence-check-before-diff pattern to copy).
- Divergence ground truth (allowlist content): `releaseapp.pas` 13 conditional regions (:89,114-127,138-146,255-306,319-420,431-440,549-555,614-652,674-680); shared units with conditionals: `src/lib/pweb.lib.webview.pas:18-32`, `src/assets/pweb.assets.folder.pas` (Darwin fcntl/F_GETPATH + Windows wide-API split), `src/assets/pweb.assets.bundle.pas:225,975,1212-1230` (I/O mechanism only); platform-private: `src/platform/{windows,linux,macos}/`. Zero conditionals (must stay zero): `pweb.rpc.scheduler.pas`, `pweb.rpc.intf.pas`, `pweb.rpc.mormot.pas`, `pweb.rpc.support.pas`, `pweb.capabilities.pas`, `pweb.webview.binding.pas`, `pweb.webview.intf.pas`, `pweb.assets.{intf,support,zip}.pas`, `sdk/typescript/`, `sdk/pas2js/`.
- Threading/runtime parity provenance for the matrix: CAP-7L :27,48,125; CAP-7M1 markers (`gui_affine=1 worker_distinct=1 direct_return=1`, both shutdown shapes, `Add(20,22)=42`); Windows CAP-2/3/5 suites; `method_not_found` taxonomy proven by the shared `pwebtests` suite executed natively per target (2,302 tests) + CAP-5 smokes — record provenance `unit-suite` vs `runtime-gate` per field, do not fake a GUI measurement.

## Tasks & Acceptance

**Execution:**
- [x] `test/cap7f/run_host_args_gate.ps1` -- NEW: on `build/cap6/release`, argumented launches: PASS leg (`--pweb-verdict` + `--pweb-autoclose-ms=4000` with env=55000, assert verdict line + argv-wins wall-clock bound), unknown-arg refusal, malformed-autoclose refusal (both must still write FAIL verdict), duplicate-arg refusal; PASS/SKIP policy mirrored from `run_cap6_smoke.ps1`; writes `build/cap7f/host-args.json` -- closes D1 on Windows.
- [x] `test/cap7f/run_host_args_gate.sh` -- NEW: same legs on `dist/linux-x64/release` under xvfb; writes `build/cap7f/host-args.json` -- closes D1 on Linux.
- [x] `test/cap7f/emit_evidence.ps1` -- NEW: Windows evidence `build/cap7f/evidence.json` (schema 1): target, os/arch, `fpc -iV`, MSVC note, webview pin (parsed from `webview.lock`), engine=WebView2, sorted 17-export set re-enumerated from built `webview.dll`, runtime verdict fields from the args-gate verdict file + smoke log (PASS/SKIP honest), app.pwb sha256 + `manifest-react.txt` + `logical_inventory_sha256` (formula-identical), release-layout result, no-listener result, `GITHUB_SHA`.
- [x] `test/cap7f/emit_evidence.sh` -- NEW: POSIX emitter, `uname` dispatch. Linux: nm -D export set, engine=WebKitGTK 4.1, react+pas2js inventories (rebuild react pwb — per-toolchain determinism guarantees bytes), args-gate + release-layout + nonetwork results. macOS (both arches): reuse `build/cap7m/measurements.txt` + existing release inventories; export-trie set from the built dylib (dyld_info, the M2 gate's own reader); engine=WKWebView; x86_64 weak-RTTI allowance recorded explicitly, never counted as drift.
- [x] `test/cap7f/check_divergence.ps1` -- NEW: repo-wide sweep of production platform conditionals (`src/**`, `examples/08-release/`, `tools/bundler/`) against the explicit allowlist above; any new conditional in the zero-conditional core units fails naming file:line; emits `build/cap7f/divergence.txt`. Runs in the aggregation job (checkout only, no build) and locally.
- [x] `test/cap7f/check_cap7f_aggregate.ps1` -- NEW: consumes 4 downloaded evidence files (+ macOS manifest/inventory artifacts): presence, schema, export-set equality across all targets, pin/protocol/origin/secure/rpc-42 equality, react `logical_inventory_sha256` equality across windows/linux/macos-x64/macos-arm64 (+ pas2js where present: linux/macOS), layout + no-listener + host-args = PASS per target, waiver labels intact; writes `build/cap7f/platform-matrix.json` + step summary.
- [x] `.github/workflows/ci.yml` -- add per-job thin steps: windows (args gate + emitter + upload `cap7f-evidence-windows`, `if-no-files-found: error`), linux (args gate + emitter + upload `cap7f-evidence-linux`), macos-x64/arm64 (emitter + upload `cap7f-evidence-macos-{x64,arm64}`); new final job `cap7-aggregate` on `ubuntu-24.04`, `needs: [windows, linux, macos-x64, macos-arm64, macos-release-inventory]`, checkout + pinned download-artifact + divergence sweep + aggregator; heavy builds not duplicated.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append: D1 CLOSED (args executed on Windows/Linux, run ID); record mirror-run unfetchability + superseding origin run `32013558592`; record cross-arch ABI-facts reconciliation remaining with CAP-11 where not covered here.
- [ ] `_bmad-output/implementation-artifacts/spec-phase-7-cap7f-final-integration.md` -- after the aggregation job is green on hosted CI for the final shard commit: Design Notes gain the canonical matrices (platform closure, toolchain, ABI, origin, RPC, layout, no-network, waivers) + "**CAP-7 CLOSED**" paragraph with exact commits/run IDs; `status: done`. This artifact is the canonical CAP-7 closure record (repo keeps no separate status file).

**Acceptance Criteria:**
- Given the shard branch pushed, when hosted CI runs, then all five existing jobs stay green AND `cap7-aggregate` is green, with `platform-matrix.json` uploaded covering exactly windows-x86_64, linux-x86_64, macos-x86_64, macos-arm64.
- Given the matrix, when read, then every target records: OS, arch, compiler, webview pin `cbbdee44…`, exactly 17 `webview_*` exports (set-equal across targets), engine, `origin=pweb://app` + `secure=true`, app.pwb compatibility + react `logical_inventory_sha256` equal on all four targets, RPC `Add(20,22)=42`, release-layout PASS, no-listener PASS, host-args PASS, hosted run/commit — and no field sourced from a waived/skipped check reads PASS.
- Given Windows and Linux runners, when the args gates run, then verdict-file, autoclose, unknown/malformed refusal, and argv-over-env legs all pass with FAIL-verdict evidence on refusal paths.
- Given the divergence sweep, when run on the closure commit, then zero platform conditionals outside the allowlist and zero in the frozen core units/SDKs.
- Given any single evidence artifact deleted or any field perturbed, when the aggregator runs, then it fails naming the target/field (negative-test the aggregator locally with a mutated fixture copy).
- Given all gates green, when CAP-7 CLOSED is recorded, then CAP-13/CAP-7L/M1/M2 waivers appear verbatim as WAIVED/limitations (M1 sync scheme-serving `stop_arrivals=0`, signing out of scope, per-toolchain compressed-byte identity only, Linux distro dependency, mirror-era provenance), and no earlier artifact is rewritten.

## Spec Change Log

## Design Notes

- **The riskiest comparison FAILED pre-push, was investigated, and is fixed at the root (2026-08-18, the Ask-First case exercised):** the Windows react logical inventory disagreed with the hosted macOS one by exactly one row — `index.html size=188` vs `size=177`. Root cause: `examples/04-react/frontend/src/index.html` (and its pas2js sibling) are committed LF (`i/lf`) but carried no `.gitattributes` eol pin, and Git for Windows defaults to `core.autocrlf=true` on the hosted windows runner as on the dev host, so the Windows checkout is CRLF; the react build `cpSync`s that file verbatim into `dist/` and `pwebbundle` packages the checkout bytes. `assets/app.js` (esbuild output) and `manifest.json` were already byte-identical cross-OS. Fix: `.gitattributes` pins both frontend `src/index.html` files `text eol=lf` — the CHECKOUT is corrected so every platform builds and ships the committed corpus; the emitter normalizes nothing. Verified: after re-smudge + rebuild, the Windows `manifest-react.txt` sha256 equals the hosted macOS x64/arm64 value `1bd9c287857eec079086463f84e317a0a852febd3fb65f77ff5ded7c4f627af4` (artifacts of run `32013558592`), row-for-row byte-identical. No production source was touched.
- **Riskiest comparison:** cross-OS react `logical_inventory_sha256` equality. Cross-ARCH byte identity is proven (M2: `2e36fd9e…`/`78d82971…` identical x64/arm64); cross-OS only compression bytes were ever compared (and differ by design). If dist bytes diverge across OS builds (esbuild/pas2js output, line endings), the aggregator fails — that is a genuine CAP-7 blocker to investigate under Ask First, not to paper over.
- **Formula fidelity:** PowerShell emitters must write LF-only, lowercase hex, ordinal (byte) sort — a CRLF or culture-sensitive sort silently breaks hash equality (precedent: the CRLF header-hash defect fixed in CAP-7L).
- **Wrapper ABI:** no numeric constant exists; the matrix records `webview_surface=17/soname 0.12` as the ABI statement per target.
- **Honesty invariants:** evidence emitted only by steps that run after the gates they summarize, inside the same job (a failed gate kills the job before upload); conditional Windows runtime keeps its SKIP path and the aggregator refuses SKIP — a runner regression turns the aggregate red, never silently green.
- **Aggregator robustness:** copy the `macos-release-inventory` existence-check-before-diff pattern (ci.yml:2448-2460); pinned action SHAs like the existing compare job.

### CAP-7 closure matrices (hosted run `32129242424`, commit `6b818de1a51027431c0ec9a67815ace4d467ad77`)

**Run provenance — recorded honestly, never as first-try green:** shard commits `5f74ec5` (frontend `index.html` LF checkout pin) + `6b818de` (CAP-7F gates, emitters, aggregation) on `phase/cap-7/f-final-integration`, hosted run `32129242424` on flydev-fr/pweb. Attempt 1: five of six jobs green — `linux-x64` (including the NEW D1 args gate and evidence emitter), `macos-x64`, `macos-arm64`, `macos release inventory`; `windows` failed at the KNOWN CAP-6b3 fixed-setup uninstall-leftovers flake (`test/cap6b3/run_fixed_setup_gates.ps1:477`, 11 WebView2 browser DLLs held by a lingering `msedgewebview2.exe` child; same signature as run `31918375036` during CAP-7M1; gates 1–8 including runtime-selection 42 passed first; the CAP-7F diff touches nothing in CAP-6b3), which skipped `cap7-aggregate`. Attempt 2 (`gh run rerun --failed`): `windows` green, `cap7-aggregate` green — all six jobs success. `platform-matrix.json` + `divergence.txt` uploaded as `cap7f-platform-matrix`.

**Platform closure matrix** (records referenced, not copied):

| target | capabilities | closure record | hosted evidence |
|---|---|---|---|
| windows-x86_64 | CAP-1…6 + CAP-13 (6b0–6b4) | `spec-phase-6b4-windows-profile-integration.md:157`, commit `b18e88e` | run `31879087884`; re-exercised in `32129242424` |
| linux-x86_64 | CAP-7L | `spec-phase-7-cap7l-linux-x64-parity.md:307`, closure `5cb564da` | run `31890995361`; re-exercised in `32129242424` |
| macos-x86_64 / macos-arm64 | CAP-7M0/M1/M2 | closures `a6b28bb` / `30c80a7` / `8f0d05a` | origin run `32013558592` (mirror-era runs unfetchable, see ledger); re-exercised in `32129242424` |
| cross-target | CAP-7F | this artifact | run `32129242424`, `cap7-aggregate` green |

**Toolchain matrix** (from the four evidence artifacts, strict equality where shown): FPC `3.2.2` on all four targets (`fpc.lock`); cc = MSVC (windows) / gcc 13.3.0 (linux) / Apple clang 17.0.0 (both macOS arches); frontends built with node 24.11.1 + pas2js 3.0.1 (locks) on every target that ships them.

**ABI matrix:** upstream pin `cbbdee44afff22867de9fd88a9fc8350d9bdd399` (`webview.lock:4`) on all four; wrapper ABI statement `webview_surface=17/soname 0.12` (no numeric constant exists — the surface pin + soname IS the contract); the 17-name `webview_*` export set re-enumerated per target (dumpbin / nm -D / dyld_info export trie) and SET-EQUAL across all four; macOS x86_64 additionally carries 8 weak `_ZT[IS]` libc++ RTTI records — the measured CAP-7M0 allowance, recorded as a count, never folded into the set; `srclib-platform-patch-sha256` `25592760…81988` (`webview.lock:86`) enforced by both freeze sweeps in the same run.

**Origin/asset matrix:** `origin=pweb://app` + `secure=true` on all four targets (runtime-gate provenance: the page's own report line); bundle protocol `1` read from each target's real `app.pwb`; react `logical_inventory_sha256` = `1bd9c287857eec079086463f84e317a0a852febd3fb65f77ff5ded7c4f627af4` EQUAL ON ALL FOUR targets — the first cross-OS logical-corpus equality ever executed (see the CRLF note above: it caught a genuine divergence pre-push, fixed at the checkout root); pas2js `logical_inventory_sha256` = `1ef786cfa852e4e6b5bb9c6447d69d258667d892a8aaf9aec85332f96dbd1e5b` equal on linux/macos-x64/macos-arm64 (Windows is React-only, ratified CAP-6 shape); compressed container bytes remain per-toolchain only (waiver, below).

**RPC matrix:** live `Add(20,22)=42` on all four targets, runtime-gate provenance (Windows/Linux: the CAP-7F args-gate PASS leg; macOS: the CAP-7M2 release runs); `method_not_found` taxonomy + envelope semantics proven by the shared `pwebtests` suite executed natively per target (unit-suite provenance, 2,302 tests) plus the CAP-5 smokes; threading/runtime parity carried by the prior shard records — CAP-7L `:27,48,125`, CAP-7M1 markers (`gui_affine=1 worker_distinct=1 direct_return=1`, both shutdown shapes), Windows CAP-2/3/5 suites — never faked as a new GUI measurement.

**Release-layout matrix:** windows `exe + app.pwb + dll` exactly (CAP-6 gate + emitter re-assert); linux the four-file `dist/linux-x64/release` (CAP-7L gate + emitter re-assert); macOS exactly the two minimal `.app` products per arch (CAP-7M2 R1 + emitter re-assert) — `release_layout=PASS` on all four in the same hosted run.

**No-network matrix:** windows CAP-5/CAP-6 zero-network source sweeps (re-executed by the emitter in the same job); linux L20 lifetime listener sampling under xvfb; macOS R11 whole-life `lsof` sampling on every direct release run + the M20 probe — `no_listener=PASS` on all four, runtime provenance recorded per target.

**Host-argument coverage (D1):** executed on ALL FOUR targets in the closure run — Windows and Linux for the first time via `test/cap7f/run_host_args_gate.{ps1,sh}` (PASS leg verdict file, argv-over-env 55000→4000 proven by wall clock — 4.6 s hosted Windows, 4 s hosted Linux (from the uploaded `host-args.json` artifacts), far under the 45 s bound — and unknown/malformed/duplicate refusals each leaving a FAIL verdict), macOS by the CAP-7M2 release suite (R3 LaunchServices verdict file, R9 warm argv-wins rerun, refusal matrix incl. the R4 refusal-verdict proof).

**Waivers and limitations (verbatim labels, never promoted to PASS):**
- CAP-6b2 offline clean-machine VM gate — WAIVED (user decision 2026-08-13; ledger).
- CAP-6b3 real-runtime Gates B/C (no-Evergreen instance; Windows 10 AppContainer) — WAIVED (user decision 2026-08-14; ledger).
- CAP-7M1 sync scheme-serving only: `stop_arrivals=0` recorded as a LIMITATION (deferred to CAP-12).
- macOS signing/notarization out of scope for CAP-7 (ad-hoc gate-local prep at most, recorded, never product signing).
- Cross-toolchain `app.pwb` identity is LOGICAL only — compressed container bytes differ per toolchain by design.
- Linux runtime dependency on distro WebKitGTK/GTK packages (ratified; no Linux CAP-13).
- CAP-7M1/M2 mirror-era run IDs unfetchable (mirror deleted); superseded by origin runs `32013558592` / `32129242424` (ledger).

**Closure state:** every acceptance criterion of this shard is met on hosted CI for the final shard commit; the canonical matrices above are the CAP-7 closure record. The `status: done` / "CAP-7 CLOSED" flip is deliberately left to human review of this record — it is the one remaining act of this artifact.

## Verification

**Commands:**
- `pwsh test/cap7f/check_divergence.ps1` -- expected: PASS, allowlist-only divergence (runs on dev host, no build).
- `pwsh test/cap6/build_cap6.ps1; pwsh test/cap6/run_cap6_gates.ps1; pwsh test/cap7f/run_host_args_gate.ps1; pwsh test/cap7f/emit_evidence.ps1` -- expected: evidence.json written, args gate PASS locally (Windows dev host has WebView2).
- Aggregator negative tests: run `check_cap7f_aggregate.ps1` against fixture copies (one artifact removed; one field mutated) -- expected: fail naming target/field; then against genuine downloads -- expected: PASS.
- `git push origin phase/cap-7/f-final-integration` then `gh run watch -R flydev-fr/pweb` -- expected: six jobs green including `cap7-aggregate`.

**Manual checks (if no CLI):**
- `platform-matrix.json` from the green run: four targets, field-by-field agreement, waivers labeled WAIVED.
- Final artifact: CAP-7 CLOSED recorded only after the closure-commit run is green.
