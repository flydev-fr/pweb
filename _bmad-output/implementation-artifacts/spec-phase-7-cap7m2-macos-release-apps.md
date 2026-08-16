---
title: 'CAP-7M2 — production macOS .app release bundles: both frontends, both architectures, one shared release host'
type: 'feature'
created: '2026-08-16'
status: 'done'
review_loop_iteration: 0
context: []
baseline_commit: '30c80a76b8da5e4b90994ba4702f6e678d0e011b'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-7M1 closed with the production Cocoa adapter proven to 42 on both native architectures (run `31953707173`; closure commit covered green by run `31954668946`), but no macOS release application exists: `examples/08-release/releaseapp.pas` has never compiled on Darwin (its `{$ifdef LINUX}{$else}` split selects the *Windows* units there), the macOS jobs build no frontend, no bundler and no `.app`, and `pas2js.lock` has no Darwin entry at all — while upstream ships **no aarch64-darwin Pas2JS 3.0.1 binary whatsoever**.

**Approach:** Extend the one shared release host with a Darwin platform seam (two-phase Cocoa handler, `Contents/Resources/app.pwb` resolution from the executable, FPU-trap pre-check) plus optional `--pweb-verdict=`/`--pweb-autoclose-ms=` arguments so LaunchServices launches are machine-checkable. Assemble, per architecture, two `.app` products — `PWebReleaseReact.app` (`dev.pweb.release.react`) and `PWebReleasePas2js.app` (`dev.pweb.release.pas2js`) — differing only in `app.pwb` and Info.plist identity, with byte-identical executable and dylib (hash-proven native-host parity). Acquire Pas2JS 3.0.1 for darwin-x86_64 from the pinned upstream zip and for aarch64-darwin by compiling `utils/pas2js/pas2js.pp` natively with the pinned FPC 3.2.2 from the FPC repository at exact commit `f27c414bad8c3082abb4c31c0682e9648e42d7ec` (branch `pas2js/fixes_3_0`, pastojs = 3.0.1) — no Rosetta anywhere. Gate direct and LaunchServices launches of both frontends on both arches to 42, fail-closed refusals from the real `.app`, and a cross-architecture logical-inventory comparison job.

## Boundaries & Constraints

**Always:**
- Every ratified macOS invariant holds: webview pin `cbbdee44`, floor 12.0 on every Mach-O, Xcode 16.4/SDK 15.5 selection via the existing `get-fpc-macos.ps1` + `record_environment`, 17 exports, one binding surface, linked ObjC++ seam, `@rpath/libwebview.0.12.dylib` + `LC_RPATH @executable_path`, `-k-no_fixup_chains` only via `tools/macos-buildenv.sh` link arrays, native arches with `assert_native_arch` (Rosetta refused) in every new script.
- The M1 adapter, scheduler, bridge, wire, `app.pwb` format, core interfaces and all dependency pins are read-only. Windows and Linux jobs stay green; their steps stay byte-identical except where a task below names an edit.
- Release mode fails closed before any WebView exists: missing/malformed/incompatible/tampered `app.pwb` ⇒ typed `app.pwb REFUSED (…)` marker + nonzero exit; no folder store, no `frontend/dist`, no SetHtml, no `file:`, no localhost, ever.
- `app.pwb` resolves only from the executable location (`Contents/Resources/` on Darwin); the dylib only via `@executable_path`; gates run from `cwd=/` with all three `DYLD_*` stripped and from relocated paths containing spaces and non-ASCII.
- Frontends and SDKs are byte-untouched; React imports only `@pweb/runtime`, Pas2JS compiles from real Pascal via the Pas2JS SDK; the staged Pas2JS compiler's Mach-O arch must equal the host arch (`lipo -archs`), so a leftover x86_64 binary can never run under Rosetta silently.
- Every new `*.sh` is mode 100755, joins both macOS floating-ref guard lists and the zero-transport sweep; deletion only through `cap7m_rm_tree` with an explicit allowed root; no unguarded `rm -rf` on a default path.
- arm64 code-signing state is **recorded** (`codesign -dvv`/`--verify`), ad-hoc at most, never represented as product signing.

**Ask First:**
- **The aarch64 Pas2JS acquisition** (new `pas2js.lock` keys + an FPC-repo source pin + native compile in `get-pas2js.ps1`): ratify at Checkpoint 1 — the alternative (Rosetta on the pinned x86_64 binary) contradicts the no-Rosetta invariant and is not taken.
- **Two `.app` products with distinct bundle identifiers** (`dev.pweb.release.react` / `dev.pweb.release.pas2js`): product identity, not a test-only mutation — it is what isolates per-frontend WebKit state (adversarial Q9) and LaunchServices instance identity.
- **The shared host gaining two optional CLI arguments** on all three platforms (LaunchServices cannot deliver env vars or capture stdout; a verdict file named in argv is the deterministic channel).
- **Secure-origin evidence shape**: the CAP-5 frontends report `secure` only (not protocol/host/origin) and are frozen; the four release secure-origin gates are the conjunction of the release verdict's `"secure":true` (host predicate already requires it) and the M1 runtime origin-object gates (`protocol/host/origin/secure` per cycle) staying green on the same adapter — stated, not hidden.
- Any further new pinned artifact, lock key or lock file.

**Never:** Universal 2; DMG/PKG; Developer ID signing or notarization; CAP-7F auto-update, CAP-8, CAP-10, CAP-11, CAP-12; editing frontends, SDKs, the Cocoa adapter/bridge/state machine, `pwebbundle` semantics or `app.pwb` format; an 18th export; moving the dylib to `Frameworks/`; an HTTP/listener transport; a native frontend-kind branch; mocked rendering; Rosetta.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| R1 exact layout | assembled product | each `.app` is exactly `Contents/Info.plist`, `Contents/MacOS/{releaseapp, libwebview.0.12.dylib}`, `Contents/Resources/{app.pwb, LICENSE.webview}`; `dist/macos-<arch>/release/` holds exactly the two products | any extra/missing entry ⇒ die (find-sort string compare, M18 style) |
| R2 direct launch | relocated `.app` under a temp dir with spaces + non-ASCII, `cwd=/`, 3×`DYLD_*` stripped | `… -> 42 PASS` marker + `clean exit`, exit 0 — React and Pas2JS, x64 and arm64 | nonzero/absent marker ⇒ blocker |
| R3 LaunchServices | `open -W -n <app> --args --pweb-verdict=<file> --pweb-autoclose-ms=N` | app launches, exits, verdict file exists and carries the PASS marker; written atomically (temp+rename) | missing/failed verdict ⇒ blocker; stale instances prevented by fresh `-n` + per-run verdict path |
| R4 missing bundle | `app.pwb` removed from the real `.app` | `app.pwb REFUSED (bundle file missing)`, nonzero, before any WebView | any fallback ⇒ blocker |
| R5 tampered bundle | truncated + garbage variants | `app.pwb REFUSED (bundle archive invalid)`, nonzero | — |
| R6 hidden dylib | `libwebview.0.12.dylib` moved out | deterministic nonzero abort naming the dylib; restored before asserting | resolution via any `DYLD_*` ⇒ blocker |
| R7 arch parity | x64 vs arm64 logical inventories | identical entry names, sizes, uncompressed SHA-256s, manifest bytes, plist semantics, frontend rev (compare job) | any semantic divergence ⇒ blocker; compressed bytes may differ |
| R8 host parity | React vs Pas2JS product, same arch | `releaseapp` and dylib SHA-256 byte-identical across both products | differing exe ⇒ frontend-kind branch ⇒ blocker |
| R9 warm rerun | second direct launch, same product | full verdict again incl. live RPC 42 | stale-cache pass ⇒ blocker; per-frontend WebKit state under the product's own bundle id is removed between frontends (only `~/Library/WebKit/<id>` and `~/Library/Caches/<id>`, via `cap7m_rm_tree`, root `$HOME/Library`) |
| R10 plist | generated Info.plist | `plutil -lint` clean; semantic readback: executable/identifier/name/APPL/version pair = `PWEB_RUNTIME_VERSION`/`LSMinimumSystemVersion=12.0`/HiRes; regenerated byte-identical; `LSMinimumSystemVersion` == Mach-O minos | — |
| R11 no listener | sampled during a release run | zero listening TCP sockets held by the releaseapp process (M20 mechanism) | WebKit child IPC is not a finding |
| R12 pas2js toolchain | `deps/pas2js-darwin/bin/pas2js` | `-iV` = 3.0.1 and `lipo -archs` = host arch on both runners | wrong arch or version ⇒ die at fetch |
| R13 determinism | each app.pwb rebuilt after touching dist mtimes | byte-identical SHA-256 per toolchain | — |
| R14 Mach-O | every produced binary | job arch only, minos 12.0, `@rpath` load + `@executable_path` rpath where it calls in, no checkout path (`pweb_macos_assert_macho`) | — |

</frozen-after-approval>

## Code Map

**Reusable verbatim — do not fork.**
- `examples/08-release/releaseapp.pas` — THE shared host (Windows+Linux proven). Verdict predicate `:152-171` (requires `"ok"/"handshake"/"secure"/"rendered"/"rpc"/"errmap"` + `"value":42` + worker≠GUI); bundle load `:338-353` (`Executable.ProgramFilePath + 'app.pwb'`); autoclose env `:448-459`; teardown `:461-518`. PASS marker `:521-522`: `releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS`.
- `src/platform/macos/pweb.platform.cocoa.pas` — `TCocoaAssetHandler`: `Create(store)` **before** `webview_create`, `Attach(w)` after (raises unless seam ran), idempotent `Detach`; `PWebCocoaFpuTrapsMasked` for the pre-create check. Wiring order model: `test/cap7m/cap7m_runtime.pas:475-533,571-598`.
- `tools/macos-buildenv.sh` — all flags/link arrays (`PWEB_MACOS_FPC_LINK_MORMOT` for pwebbundle, `…_LINK_BRIDGE` for releaseapp), `pweb_macos_assert_macho`, `pweb_macos_record`. `PWEB_MACOS_FPC_LINK_*` exist only after `pweb_macos_init_fpc` — call `assert_fpc_target` first (`build_cap7m.sh:44` precedent).
- `test/cap7m/cap7m_common.sh` — `assert_native_arch:211`, `assert_fpc_target:244`, `record_environment:286`, `cap7m_prepare_dir:83`, `cap7m_rm_tree:148` (allowed root via `${2-…}`), `record_measurement`.
- `test/cap7m/check_release_layout.sh` — the M18 template: staging via `mktemp` + subshell-guarded cleanup trap `:72-88`; plist heredoc `:99-121` (extend with identifier/name/version per product); exact-manifest string compare `:124-129`; otool assertions `:132-151`; codesign recording `:163-186`; stripped-env run `:188-201`; hidden-dylib negative `:203-222`. **Keep this M0 gate untouched and running.**
- `test/cap7l/run_release_layout.sh` — the Linux sibling: per-frontend `pwebbundle <dist> <release>/app.pwb` + run + `grep '"value":42'` `:72-97`; exact-set `:60-66`; missing-so negative `:99-113`.
- `tools/bundler/pwebbundle.pas` — portable CLI `pwebbundle <dist> <out.pwb>`; deterministic (fixed DOS age `$00210000`, level 6, global name sort, atomic temp+rename); refusal texts in `src/assets/pweb.assets.bundle.pas:241-258` (`bundle file missing`, `bundle archive invalid`, …). `PWEB_RUNTIME_VERSION = '0.1.0'` at `src/rpc/pweb.rpc.support.pas:34` — extract by strict grep for the plist version pair.
- `test/cap7m/build_cap7m.sh` — unit-path sets `mormot_core:64`, `mormot_all:72`, `pweb_units:83` (already carries `-Fusrc/platform/macos`); bridge-link fpc shape `:250-253`; Mach-O sweep `:274-290`. Compile model for the new script.
- CI shapes: setup-node `actions/setup-node@49933ea5…` + `24.11.1` (`ci.yml:1640-1643`); TS SDK/React/pas2js steps `ci.yml:1653-1699`; upload-artifact `@ea165f8d…`. macOS guard lists `ci.yml:1814-1823` and `:2060-2069` (byte-identical `files="${files} …"` appends). Insert new macOS steps between `CAP-7M1 production runtime gates` and `CAP-7M0 bundle layout` in both jobs; existing steps byte-identical.
- `test/cap7m/check_cap7m_nonetwork.sh` — sweep list `:57-80` + runtime listener-sampling mechanism to reuse in the release gate.
- `tools/get-pas2js.ps1` — lock reader + version assertion pattern; two-way OS split `:31-45` to become three-way. `examples/05-pas2js/frontend/build.ps1:12-20` — compiler resolution to gain the darwin arm.

**Measured facts (do not rediscover).** `pas2js-darwin-x86_64-3.0.1.zip` sha256 `4b0b2fb02e181563a06d0c588c7f3813bfb3eb8e9b45d616078ab152c882ee32` (fetched twice, stable); its `bin/pas2js` is thin x86_64; no aarch64/universal/source artifact exists on getpas2js.freepascal.org. FPC repo `https://gitlab.com/freepascal.org/fpc/source.git` @ `f27c414bad8c3082abb4c31c0682e9648e42d7ec` (= `pas2js/fixes_3_0` head): `packages/pastojs/src/pas2jscompiler.pp` has `VersionMajor=3, VersionMinor=0, VersionRelease=1`; `utils/pas2js/pas2js.pp` present. WebKit state is currently neither isolated nor cleaned by any M1 gate; M0 measured plist carried `NSHighResolutionCapable`. `open -W` does not forward exit codes or stdout — hence the verdict file.

## Tasks & Acceptance

**Execution:**
- [x] `pas2js.lock` -- add `darwin-url`/`darwin-sha256`/`darwin-rootdir` (values above) and `darwin-arm64-source-url`/`darwin-arm64-source-commit` (FPC repo @ `f27c414bad8c…`) with a comment stating why (no upstream aarch64 binary of the pinned logical version) -- the pin is the ratification record.
- [x] `tools/get-pas2js.ps1` -- three-way split: Windows unchanged; darwin → `deps/pas2js-darwin` from the zip; on arm64 additionally fetch the FPC repo at the exact commit (git fetch by SHA, like deps/webview) and compile `utils/pas2js/pas2js.pp` natively with pinned FPC into `deps/pas2js-darwin/bin/pas2js` (RTL `packages/` + `pas2js.cfg` from the zip); assert `-iV` = 3.0.1 **and** `lipo -archs` = host arch on Darwin -- a version or arch drift dies at fetch, not mid-gate.
- [x] `examples/05-pas2js/frontend/build.ps1` -- darwin branch selecting `deps/pas2js-darwin/bin/pas2js` -- same sources, same pinned logical compiler.
- [x] `examples/08-release/releaseapp.pas` + `README.md` -- Darwin seam: three-way uses/alias (`TCocoaAssetHandler`), `CheckCocoaRuntimeUsable` pre-create check over `PWebCocoaFpuTrapsMasked`, handler `Create(store)` before `webview_create` + `Attach(w)` after (non-Darwin sites unchanged), Darwin bundle path `<exedir>/../Resources/app.pwb` (ExpandFileName, never CWD); optional `--pweb-verdict=`/`--pweb-autoclose-ms=` args on all platforms (unknown args still refused; arg wins over env; atomic temp+rename write of the canonical PASS/FAIL line on every exit path) -- one shared host, zero frontend-kind branches.
- [x] `test/cap7m/build_cap7m_release.sh` -- NEW: source `cap7m_common.sh`; `assert_native_arch`/`assert_fpc_target`/`record_environment`; compile `pwebbundle` (`…_LINK_MORMOT`, `mormot_core` + asset units) into `build/cap7m/bin` and `releaseapp` (`…_LINK_BRIDGE`, `pweb_units` + `mormot_all`) into `build/cap7m/ex`; `pweb_macos_assert_macho` each (releaseapp `--require-dylib --require-rpath`) -- mirrors `build_cap7l.sh:132-164`.
- [x] `test/cap7m/run_cap7m_release.sh` -- NEW: per frontend assemble the `.app` into `dist/macos-<arch>/release/` (plist heredoc per product + `plutil -lint` + semantic readback + regeneration byte-check; version pair greped strictly from `pweb.rpc.support.pas`); app.pwb via `pwebbundle` + determinism double-build (R13); exact-set gates (R1); Mach-O/rpath/no-checkout-path asserts; exe/dylib cross-product hash parity (R8); codesign state recording (+ deterministic `codesign -s -` only if LS demonstrably requires it, recorded as local prep); per-frontend WebKit state cleanup (R9 bounds); relocated direct runs ×2 (R2, space + non-ASCII, cwd=/, DYLD stripped) and LS run (R3) per frontend; refusal matrix R4/R5/R6 on the React product; listener sampling (R11); emit `manifest-<frontend>.txt` + `inventory-<frontend>.txt` (arch, frontend, bundle path, exe/dylib/app.pwb sha256, logical inventory + its sha256, plist semantic sha256, minos, toolchain versions, frontend rev, codesign state) into `build/cap7m/release-apps/` and `record_measurement` CAP7M2 headline facts -- the shard's whole proof, one script, M18 discipline throughout.
- [x] `test/cap7m/check_cap7m_nonetwork.sh` -- add `examples/08-release/releaseapp.pas`, `tools/bundler/pwebbundle.pas`, `test/cap7m/build_cap7m_release.sh`, `test/cap7m/run_cap7m_release.sh` to the sweep -- the release surface joins the no-transport claim.
- [x] `test/cap7m/summarize_cap7m.sh` -- add a CAP7M2 release table (per-frontend verdicts, inventory hashes, codesign state) -- the release facts must reach the step summary, not only the artifact.
- [x] `.github/workflows/ci.yml` -- both macOS jobs: insert (between the M1 runtime gates and M18) setup-node + TS SDK build/tests + React build + pas2js fetch/build + `build_cap7m_release.sh` + `run_cap7m_release.sh`, upload `cap7m2-release-<arch>` (manifests+inventories, `if-no-files-found: error`), extend both guard lists (2 scripts) and the failure-diagnostics paths; add job `macos-release-inventory` (`needs:` both macOS jobs, ubuntu, pinned `actions/download-artifact@<v4 SHA>`) asserting R7 -- hosted proof on both arches plus the mechanical cross-arch gate the M0 ledger called for.
- [x] `docs/wkwebview-macos-semantics.md` -- record: LS launches deliver argv but neither env nor stdout (verdict-file rationale); `Contents/Resources` resolution rule; measured codesign state per arch; WebKit per-bundle-id state model and why the products carry distinct identifiers -- the surprises belong where the next reader looks.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- record the cross-arch reconciliation entry as partially landed (release inventory now mechanically compared; ABI/export cross-check still deferred); ledger anything newly deferred -- append-only closure.

**Acceptance Criteria:**
- Given both hosted macOS jobs green, when their gates run, then React and Pas2JS each reach 42 from the final relocated `.app` via direct and LaunchServices launches on x86_64 **and** arm64, with R1-R14 all asserted and the M1 runtime/headless gates still green in the same runs.
- Given the merged shard, when `windows:` and `linux:` run, then every existing gate is green with their steps byte-identical except the shared-host and pas2js-script edits named above.
- Given the compare job, when both macOS jobs upload, then the logical app.pwb inventories, plist semantics and frontend revision are identical across architectures, and the job fails on any divergence.
- Given the tree at close, when inspected, then no Universal 2, installer, signing-identity, notarization, CAP-7F/8/10/11/12 or frontend/SDK/adapter change exists, and no macOS flag is written outside `tools/macos-buildenv.sh`.

## Implementation record

**GREEN — run `31968338053`, all five jobs, commit `366eecc`** (public
`flydev-fr/poueb` mirror; nothing pushed to the private origin per the
no-budget constraint): `windows`, `linux-x64`, `macos-x64`, `macos-arm64`
and the new `macos-release-inventory` compare job all succeeded.

**Measured, both architectures (identical values unless split):**

| | x86_64 | arm64 |
|---|---|---|
| React direct / warm / LaunchServices | pass / pass / pass | same |
| Pas2JS direct / warm / LaunchServices | pass / pass / pass | same |
| listening TCP sockets (sampled to exit) | 0 | 0 |
| argv-over-env autoclose | `argv_wins=yes` (8 s vs 55 s) | same |
| refusal matrix (missing/truncated/garbage/hidden-dylib/bad-arg/FAIL-verdict) | all pass | same |
| app.pwb determinism (rebuild after mtime touch) | identical | same |
| app.pwb sha256 react / pas2js | `2e36fd9e…` / `78d82971…` | **byte-identical to x64** |
| logical inventory sha256 react / pas2js | `1bd9c287…` / `1ef786cf…` | identical |
| exe/dylib parity across products | `exe_identical=yes dylib_identical=yes` | same |
| product Mach-Os | `arch=x86_64 minos=12.0 @rpath + @executable_path` | `arch=arm64`, same rest |
| codesign state (recorded, never product signing) | `unsigned`, ran unsigned | `adhoc (linker-signed)`, dylib verify pass, bundle-level verify fail-or-unsigned, LS launched without any post-assembly `codesign -s -` |
| staged Pas2JS 3.0.1 | upstream binary, `x86_64 minos=10.8` | **compiled natively from FPC repo `f27c414b`**, `arm64 minos=11.0`, `-iV=3.0.1` |

The compare job's verdict line: *"cross-architecture release inventory:
identical logical corpus, plist semantics and frontend rev on both
architectures"* — app.pwb came out byte-identical across arches, stronger
than the semantic equality the spec required.

**Two defects found by the first hosted run (`31967748216`), both fixed in
`366eecc`:** the CAP-6b1 marker-contract checker requires the literal
`': app.pwb -> … 42 PASS'` inside `releaseapp.pas`, which the marker
centralization had split (fixed by folding `': '` into the constant); and
the new checkout-path scan matched `otool -L`'s first line — the inspected
file's own path — because `dist/` lives inside the checkout (fixed with
`tail -n +2`, the exact trap `tools/macos-buildenv.sh:454-461` documents).
Sixteen review findings were patched before the first push; the review's
YAML-splice finding (the compare job swallowing a displaced diagnostics
path line) would have made the compare job fail unconditionally.

**Secure origin** is proven as the ratified conjunction: the release
verdict's `"secure":true` on all four legs plus the M1 runtime
origin-object gates (`protocol=pweb:`, `host=app`, `origin=pweb://app`,
`secure=true` per cycle) green in the same run on both architectures.

## Spec Change Log

## Design Notes

**Two products, one binary.** The Linux gate swaps `app.pwb` inside one directory; macOS instead ships two `.app` products because WebKit keys persistent state by bundle identifier — distinct identifiers make per-frontend state disjoint (adversarial Q9) and LaunchServices instance identity unambiguous, while the byte-identical `releaseapp`/dylib hashes prove the host has no frontend-kind branch (R8) more strongly than a diff would.

**Verdict file, not stdout.** `open -W` forwards neither stdout nor the exit code, and LaunchServices does not inherit the caller's environment — so the only deterministic LS-side evidence channel is a file path passed in argv, written atomically on every exit path. Direct launches keep the real exit code and stderr; both gates therefore stay.

**aarch64 Pas2JS.** The pinned logical version (3.0.1) exists upstream as win64/linux-x64/darwin-x64 binaries only. Rosetta is banned, so arm64 compiles the same-version compiler natively from the FPC repo revision whose pastojs *is* 3.0.1 (`pas2js/fixes_3_0` @ `f27c414bad8c…`), verified by `-iV`; the compare job then proves the two arches' frontend outputs semantically identical — the source-built compiler is cross-checked against the official binary's output, not trusted.

## Verification

**Commands (hosted, both `macos-15-intel` and `macos-15`):**
- `test/cap7m/build_cap7m_release.sh` -- expected: releaseapp + pwebbundle native Mach-Os, minos 12.0, `@rpath` load + `@executable_path` rpath on releaseapp.
- `test/cap7m/run_cap7m_release.sh` -- expected: R1-R14 pass; four PASS verdicts per arch (React/Pas2JS × direct/LS); refusal matrix fails closed; manifests + inventories emitted.
- `windows:` / `linux:` jobs -- expected: green, CAP-6 gates and CAP-7L release layout included (shared-host edits regression-proven).
- `macos-release-inventory` job -- expected: zero cross-arch divergence.

**Manual checks (if no CLI):**
- `git -C deps/webview status --porcelain` empty; `git ls-files -s -- '*.sh'` shows 100755 for both new scripts.
- `git grep -n 'no_fixup_chains' -- ':!tools/macos-buildenv.sh' ':!_bmad-output' ':!docs'` returns no new inline copy.

## Suggested Review Order

**The Darwin seam in the shared release host**

- Entry point: the two-phase Cocoa wiring — handler armed before `webview_create`, attached after.
  [`releaseapp.pas:638`](../../examples/08-release/releaseapp.pas#L638)
- Bundle resolution from the executable only: `<exedir>/../Resources/app.pwb`, never CWD.
  [`releaseapp.pas:427`](../../examples/08-release/releaseapp.pas#L427)
- The Darwin pre-create check: FPU traps must be masked before WebKit computes.
  [`releaseapp.pas:264`](../../examples/08-release/releaseapp.pas#L264)
- Three-way uses/alias split — the old `{$ifdef LINUX}{$else}` picked Windows units on Darwin.
  [`releaseapp.pas:114`](../../examples/08-release/releaseapp.pas#L114)

**The LaunchServices evidence channel**

- Two-pass argument parsing: verdict path captured first so even a refusal leaves evidence.
  [`releaseapp.pas:462`](../../examples/08-release/releaseapp.pas#L462)
- Atomic verdict write — POSIX rename; per-process temp name; Windows delete window scoped honestly.
  [`releaseapp.pas:529`](../../examples/08-release/releaseapp.pas#L529)

**Product assembly and its gates**

- Per-product assembly: deterministic Info.plist heredoc, lint, semantic readback, regeneration byte-check.
  [`run_cap7m_release.sh:473`](../../test/cap7m/run_cap7m_release.sh#L473)
- The exact-set layout gate now sees files, directories and symlinks alike.
  [`run_cap7m_release.sh:252`](../../test/cap7m/run_cap7m_release.sh#L252)
- Direct launches: relocated (space + non-ASCII), cwd=/, DYLD stripped, listener-sampled to exit.
  [`run_cap7m_release.sh:347`](../../test/cap7m/run_cap7m_release.sh#L347)
- LaunchServices launch through a bounded `open -W`, verdict file as the only proof.
  [`run_cap7m_release.sh:417`](../../test/cap7m/run_cap7m_release.sh#L417)
- Refusal matrix: missing/tampered/garbage/hidden-dylib plus the unknown-argument case.
  [`run_cap7m_release.sh:663`](../../test/cap7m/run_cap7m_release.sh#L663)
- Logical inventory emission — pattern-safe unzip, single-pass hash, the R7 comparison input.
  [`run_cap7m_release.sh:271`](../../test/cap7m/run_cap7m_release.sh#L271)

**The aarch64 Pas2JS acquisition**

- The pins: upstream darwin zip + FPC repo commit whose pastojs is exactly 3.0.1.
  [`pas2js.lock:43`](../../pas2js.lock#L43)
- The native compile: pinned-FPC assertion, exact-SHA fetch, `-iV`/`lipo` gates.
  [`get-pas2js.ps1:173`](../../tools/get-pas2js.ps1#L173)

**CI**

- Both macOS jobs: seven inserted steps, guard-list additions, release artifacts.
  [`ci.yml:2049`](../../.github/workflows/ci.yml#L2049)
- The cross-architecture inventory comparison job (R7) — the mechanical gate the M0 ledger deferred.
  [`ci.yml:2426`](../../.github/workflows/ci.yml#L2426)

**Peripherals**

- Compile step for pwebbundle + releaseapp with the centralized flag arrays.
  [`build_cap7m_release.sh:1`](../../test/cap7m/build_cap7m_release.sh#L1)
- Darwin compiler-dir branch for the Pas2JS frontend build.
  [`build.ps1:12`](../../examples/05-pas2js/frontend/build.ps1#L12)
- Sweep, summary and semantics-doc extensions; ledger entries.
  [`check_cap7m_nonetwork.sh:57`](../../test/cap7m/check_cap7m_nonetwork.sh#L57)
