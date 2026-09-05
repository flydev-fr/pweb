# The CI migration map (CAP-11A)

`.github/workflows/ci.yml` was one file of 271,637 bytes and 5,824 lines
carrying six jobs, and the four platform jobs declared 155, 92, 99 and 99 steps
that were kept in step by copying. CAP-11A replaced it with **one sequence** -
`.github/workflows/platform-leg.yml`, called four times from the caller -
and **one composite action per step** under `.github/actions/`. This table
says where each legacy step went.

The caller is `ci-matrix.yml` on the twin-run commit, where both
structures exist on purpose, and `ci.yml` from the removal commit onward,
where it takes the name the file it replaced used to have.

## How to resolve a `ci.yml:<line>` citation

Ratified artifacts cite the legacy file by line number and **stay as written**:
a closed shard records what it measured, and rewriting its citations would be
rewriting its record.

**Resolve by STEP NAME, not by line number.** A line number was only ever true
of the file at the commit that cited it - `ci.yml` grew by ~160 KB across CAP-8
to CAP-10, so `ci.yml:630` means different things in a CAP-7M0 artifact and in a
CAP-10D2 one. The step NAME is stable, and it is what this table is keyed on. So:

1. `git show <the citing commit>:.github/workflows/ci.yml` - the file is intact at
   every commit up to and including the twin-run commit, and every commit before
   it. Read the cited line there.
2. Scroll up to that line's `- name:` - that is the step it belongs to.
3. Find that name in the table below and read across to the new location.

The *Legacy lines* column carries the line numbers as of the twin-run commit, so a
citation made against that commit resolves directly;
`test/cap11a/ci-legacy-inventory.tsv` carries the same numbers in machine form.

## The one ratified restructuring

Every step keeps its name, its body, its `shell:`, its `if:`, its
`timeout-minutes:` and its position on its own leg. The single exception is the
**61 interleaved `actions/upload-artifact` steps** (103 rows, one per job). They
do not enter the sequence: an upload between two gates is how hosted run
`33955241980` cost the macos-x64 leg about thirty later steps and two capability
verdicts. Their declared paths are unioned per class into the collection block at
the end of the leg, and `test/cap11a/collection-paths.json` is that union.

**One consequence is stated rather than absorbed.** A legacy upload
declared its own `if-no-files-found`, and several records-class steps
declared `error`. The collection block has one setting per CLASS, and a
class is a union across four targets - so `error` there would fail a leg
for a file only one platform produces. The records class is therefore
`warn`. The class whose absence forfeits a verdict, `evidence`, keeps
`error`, and the aggregator refuses a missing target regardless.

| legacy artifact | class | now inside |
|---|---|---|
| `cap5-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap6-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap6b0-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap6b1-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap6b2-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap6b3-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap8b-nav-matrix-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap8c-multiprincipal-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap8b-nav-matrix-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap8c-multiprincipal-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7m2-release-x64` | release | `leg-release-<target>`, at each file's repository-relative path |
| `cap7m2-release-arm64` | release | `leg-release-<target>`, at each file's repository-relative path |
| `cap8b-nav-matrix-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap8b-nav-matrix-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap8c-multiprincipal-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap8c-multiprincipal-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9a-quickjs-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9a-quickjs-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9a-quickjs-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9a-quickjs-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b1-package-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b1-package-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b1-package-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b1-package-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b2-lifecycle-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b2-lifecycle-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b2-lifecycle-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9b2-lifecycle-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c1-release-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c1-release-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c1-release-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c1-release-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c2-gui-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c2-gui-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c2-gui-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap9c2-gui-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10a-cli-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10a-cli-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10a-cli-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10a-cli-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b0-template-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b0-template-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b0-template-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b0-template-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b1-create-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b1-create-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b1-create-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b1-create-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b2-pas2js-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b2-pas2js-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b2-pas2js-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10b2-pas2js-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c0-supervision-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c0-supervision-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c0-supervision-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c0-supervision-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c1-pipeline-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c1-pipeline-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c1-pipeline-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c1-pipeline-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c2-dev-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c2-dev-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c2-dev-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c2-dev-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c3-devpas2js-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c3-devpas2js-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c3-devpas2js-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10c3-devpas2js-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d0-build-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d0-build-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d0-build-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d0-build-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d1-pack-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d1-pack-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d1-pack-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d1-pack-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d2-sdk-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d2-sdk-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d2-sdk-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap10d2-sdk-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `pweb-sdk-windows` | dist | `leg-dist-<target>`, at each file's repository-relative path |
| `pweb-sdk-linux` | dist | `leg-dist-<target>`, at each file's repository-relative path |
| `pweb-sdk-macos-x64` | dist | `leg-dist-<target>`, at each file's repository-relative path |
| `pweb-sdk-macos-arm64` | dist | `leg-dist-<target>`, at each file's repository-relative path |
| `cap10e-imagepath-windows` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7f-evidence-windows` | evidence | `leg-evidence-<target>`, at each file's repository-relative path |
| `cap10e-imagepath-linux` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7f-evidence-linux` | evidence | `leg-evidence-<target>`, at each file's repository-relative path |
| `cap10e-imagepath-macos-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7f-evidence-macos-x64` | evidence | `leg-evidence-<target>`, at each file's repository-relative path |
| `cap10e-imagepath-macos-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7f-evidence-macos-arm64` | evidence | `leg-evidence-<target>`, at each file's repository-relative path |
| `cap7f-diagnostics-windows` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap7f-diagnostics-linux` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap7f-diagnostics-macos-x64` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap7f-diagnostics-macos-arm64` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap7m-measurements-x64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7m-measurements-arm64` | records | `leg-records-<target>`, at each file's repository-relative path |
| `cap7m-diagnostics-x64` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap7m-diagnostics-arm64` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap6b4-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap1-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |
| `cap7l-diagnostics` | diagnostics | `leg-diagnostics-<target>`, at each file's repository-relative path |

## Every step

| legacy step | legs | legacy lines | new location |
|---|---|---|---|
| `Checkout (full history for freeze diff against baseline)` | windows | 100 | `.github/workflows/platform-leg.yml step 1` |
| `Checkout` | linux, macos-x64, macos-arm64 | 2606, 3640, 4689 | `.github/workflows/platform-leg.yml step 2` |
| `Guard - no floating upstream ref in the Linux build/gate path` | linux | 2609 | `.github/actions/guard-no-floating-upstream-ref-in-the-linux-build-gate-path/action.yml` |
| `Install the ratified WebKitGTK stack and FPC (distro packages)` | linux | 2660 | `.github/actions/install-the-ratified-webkitgtk-stack-and-fpc-distro-packages/action.yml` |
| `Assert the toolchain and the ratified engine family` | linux | 2677 | `.github/actions/assert-the-toolchain-and-the-ratified-engine-family/action.yml` |
| `Guard - no floating upstream ref in the macOS build/gate path` | macos-x64, macos-arm64 | 3643, 4692 | `.github/actions/guard-no-floating-upstream-ref-in-the-macos-build-gate-path/action.yml` |
| `CAP-7M0 record the runner (M19)` | macos-x64, macos-arm64 | 3691, 4731 | `.github/actions/cap-7m0-record-the-runner-m19/action.yml` |
| `Fetch pinned webview/webview (exact SHA, checksum verified)` | windows, linux, macos-x64, macos-arm64 | 105, 2705, 3724, 4749 | `.github/actions/fetch-pinned-webview-webview-exact-sha-checksum-verified/action.yml` |
| `CAP-4W - exact Windows patch apply, restore and reapply` | windows | 109 | `.github/actions/cap-4w-exact-windows-patch-apply-restore-and-reapply/action.yml` |
| `Fetch pinned mORMot2 (exact SHA + sha256-pinned statics)` | windows, linux, macos-x64, macos-arm64 | 143, 2709, 3728, 4753 | `.github/actions/fetch-pinned-mormot2-exact-sha-sha256-pinned-statics/action.yml` |
| `Guard - no floating upstream ref in fetch/build path` | windows | 147 | `.github/actions/guard-no-floating-upstream-ref-in-fetch-build-path/action.yml` |
| `Install FPC (pinned Lazarus 3.4 installer, sha256-verified)` | windows | 197 | `.github/actions/install-fpc-pinned-lazarus-3-4-installer-sha256-verified/action.yml` |
| `Assert FPC 3.2.2` | windows | 210 | `.github/actions/assert-fpc-3-2-2/action.yml` |
| `MSVC environment` | windows | 217 | `.github/workflows/platform-leg.yml step 14` |
| `CAP-3U - FPC 3.2.2 Win64 CallMethod unwind and Currency ABI` | windows | 220 | `.github/actions/cap-3u-fpc-3-2-2-win64-callmethod-unwind-and-currency-abi/action.yml` |
| `Build webview.dll from pinned source (cmake + MSVC)` | windows | 431 | `.github/actions/build-webview-dll-from-pinned-source-cmake-msvc/action.yml` |
| `CAP-4W - public DLL ABI remains exactly 17 exports` | windows | 435 | `.github/actions/cap-4w-public-dll-abi-remains-exactly-17-exports/action.yml` |
| `CAP-4W - headless loader boundary and compile resource probe` | windows | 439 | `.github/actions/cap-4w-headless-loader-boundary-and-compile-resource-probe/action.yml` |
| `CAP-4W - custom-scheme runtime (best effort, local gate authoritative)` | windows | 443 | `.github/actions/cap-4w-custom-scheme-runtime-best-effort-local-gate-authoritative/action.yml` |
| `Compile binding units (FPC, ObjFPC mode)` | windows | 467 | `.github/actions/compile-binding-units-fpc-objfpc-mode/action.yml` |
| `Compile CAP-2 units (scheduler proven webview-free)` | windows | 482 | `.github/actions/compile-cap-2-units-scheduler-proven-webview-free/action.yml` |
| `Compile CAP-4 asset units (stores webview-free, handler rpc-free)` | windows | 514 | `.github/actions/compile-cap-4-asset-units-stores-webview-free-handler-rpc-free/action.yml` |
| `CAP-4 zero-HTTP asset-serving source proof` | windows | 541 | `.github/actions/cap-4-zero-http-asset-serving-source-proof/action.yml` |
| `Signature pin (compile-only gate over all 17 prototypes)` | windows | 575 | `.github/actions/signature-pin-compile-only-gate-over-all-17-prototypes/action.yml` |
| `ABI probe - Pascal side (committed binding)` | windows | 582 | `.github/actions/abi-probe-pascal-side-committed-binding/action.yml` |
| `ABI probe - C side (pinned headers, MSVC)` | windows | 591 | `.github/actions/abi-probe-c-side-pinned-headers-msvc/action.yml` |
| `ABI probe - compare (any diff is a blocker)` | windows | 600 | `.github/actions/abi-probe-compare-any-diff-is-a-blocker/action.yml` |
| `PWeb test suite (mormot.core.test)` | windows | 622 | `.github/actions/pweb-test-suite-mormot-core-test/action.yml` |
| `Binding surface + freeze-isolation sweeps` | windows | 655 | `.github/actions/binding-surface-freeze-isolation-sweeps/action.yml` |
| `Freeze sweep - RTL-only compile of isolation-critical intf units` | windows | 659 | `.github/actions/freeze-sweep-rtl-only-compile-of-isolation-critical-intf-units/action.yml` |
| `Freeze sweep - frozen contracts byte-identical to Phase-0 baseline` | windows | 670 | `.github/actions/freeze-sweep-frozen-contracts-byte-identical-to-phase-0-baseline/action.yml` |
| `Freeze sweep - the renamed src/lib patch key, and only that name` | windows | 707 | `.github/actions/freeze-sweep-the-renamed-src-lib-patch-key-and-only-that-name/action.yml` |
| `Freeze sweep - raw ABI layer equals the ratified platform block (CAP-1 baseline)` | windows | 738 | `.github/actions/freeze-sweep-raw-abi-layer-equals-the-ratified-platform-block-cap-1/action.yml` |
| `CAP-3 freeze sweep - Phase-0/1/2 implementation boundaries` | windows | 760 | `.github/actions/cap-3-freeze-sweep-phase-0-1-2-implementation-boundaries/action.yml` |
| `Compile smoke example and stage its DLL` | windows | 795 | `.github/actions/compile-smoke-example-and-stage-its-dll/action.yml` |
| `Smoke run (best effort - authoritative gate is local)` | windows | 809 | `.github/actions/smoke-run-best-effort-authoritative-gate-is-local/action.yml` |
| `Compile JS-binding example (CAP-2) and stage its DLL` | windows | 831 | `.github/actions/compile-js-binding-example-cap-2-and-stage-its-dll/action.yml` |
| `JS-binding example run (best effort - authoritative gate is local)` | windows | 847 | `.github/actions/js-binding-example-run-best-effort-authoritative-gate-is-local/action.yml` |
| `Stage CAP-3 runtime DLL` | windows | 869 | `.github/actions/stage-cap-3-runtime-dll/action.yml` |
| `mORMot RPC example run (best effort - authoritative gate is local)` | windows | 876 | `.github/actions/mormot-rpc-example-run-best-effort-authoritative-gate-is-local/action.yml` |
| `CAP-4 build app.zip from frontend fixture` | windows | 903 | `.github/actions/cap-4-build-app-zip-from-frontend-fixture/action.yml` |
| `CAP-4 dual-mode runtime (best effort, local gate authoritative)` | windows | 918 | `.github/actions/cap-4-dual-mode-runtime-best-effort-local-gate-authoritative/action.yml` |
| `CAP-5 fetch pinned pas2js (sha256-verified)` | windows | 955 | `.github/actions/cap-5-fetch-pinned-pas2js-sha256-verified/action.yml` |
| `CAP-5 setup pinned Node` | windows | 959 | `.github/workflows/platform-leg.yml step 44` |
| `CAP-5 TypeScript SDK typecheck + tests + wire capture` | windows | 964 | `.github/actions/cap-5-typescript-sdk-typecheck-tests-wire-capture/action.yml` |
| `CAP-5 Pas2JS SDK compile + semantic tests + wire capture` | windows | 982 | `.github/actions/cap-5-pas2js-sdk-compile-semantic-tests-wire-capture/action.yml` |
| `CAP-5 cross-SDK captured-wire parity` | windows | 996 | `.github/actions/cap-5-cross-sdk-captured-wire-parity/action.yml` |
| `CAP-5 protocol constant cross-check (native vs both SDKs)` | windows | 1003 | `.github/actions/cap-5-protocol-constant-cross-check-native-vs-both-sdks/action.yml` |
| `CAP-5 React frontend build (pinned lockfile, offline bundle)` | windows | 1007 | `.github/actions/cap-5-react-frontend-build-pinned-lockfile-offline-bundle/action.yml` |
| `CAP-5 Pas2JS frontend build (pinned toolchain)` | windows | 1025 | `.github/actions/cap-5-pas2js-frontend-build-pinned-toolchain/action.yml` |
| `CAP-5 zero-network sweep over SDKs and frontends` | windows | 1040 | `.github/actions/cap-5-zero-network-sweep-over-sdks-and-frontends/action.yml` |
| `CAP-5 host examples compile (re-applied CAP-3U window)` | windows | 1044 | `.github/actions/cap-5-host-examples-compile-re-applied-cap-3u-window/action.yml` |
| `CAP-5 runtime smokes - React and Pas2JS over pweb://app` | windows | 1048 | `.github/actions/cap-5-runtime-smokes-react-and-pas2js-over-pweb-app/action.yml` |
| `CAP-5 diagnostics on failure` | windows | 1053 | `leg-diagnostics-${target}` |
| `CAP-6 compile bundler + release host (CAP-3U window)` | windows | 1073 | `.github/actions/cap-6-compile-bundler-release-host-cap-3u-window/action.yml` |
| `CAP-6 headless gates - bundle, determinism, release layout, refusals` | windows | 1077 | `.github/actions/cap-6-headless-gates-bundle-determinism-release-layout-refusals/action.yml` |
| `CAP-6 zero-network sweep over bundle/release sources` | windows | 1085 | `.github/actions/cap-6-zero-network-sweep-over-bundle-release-sources/action.yml` |
| `CAP-6 release runtime smoke - app.pwb over pweb://app` | windows | 1089 | `.github/actions/cap-6-release-runtime-smoke-app-pwb-over-pweb-app/action.yml` |
| `CAP-6 diagnostics on failure` | windows | 1094 | `leg-diagnostics-${target}` |
| `CAP-6b0 isolation compile - runtime detector unit` | windows | 1124 | `.github/actions/cap-6b0-isolation-compile-runtime-detector-unit/action.yml` |
| `CAP-6b0 minimum cross-check (Pascal constant vs CAP-4W patch)` | windows | 1137 | `.github/actions/cap-6b0-minimum-cross-check-pascal-constant-vs-cap-4w-patch/action.yml` |
| `CAP-6b0 host WebView2 detection smoke (diagnostic evidence only)` | windows | 1141 | `.github/actions/cap-6b0-host-webview2-detection-smoke-diagnostic-evidence-only/action.yml` |
| `CAP-6b0 lock validator and fixture matrix (zero network)` | windows | 1146 | `.github/actions/cap-6b0-lock-validator-and-fixture-matrix-zero-network/action.yml` |
| `CAP-6b0 diagnostics on failure` | windows | 1154 | `leg-diagnostics-${target}` |
| `CAP-6b1 isolation compile - provisioning unit + setup helper` | windows | 1180 | `.github/actions/cap-6b1-isolation-compile-provisioning-unit-setup-helper/action.yml` |
| `CAP-6b1 innosetup.lock fixture matrix (zero network)` | windows | 1200 | `.github/actions/cap-6b1-innosetup-lock-fixture-matrix-zero-network/action.yml` |
| `CAP-6b1 contract cross-checks (markers + helper prefixes)` | windows | 1204 | `.github/actions/cap-6b1-contract-cross-checks-markers-helper-prefixes/action.yml` |
| `CAP-6b1 fetch pinned Inno Setup 6 (sha256-verified, silent, bounded)` | windows | 1212 | `.github/actions/cap-6b1-fetch-pinned-inno-setup-6-sha256-verified-silent-bounded/action.yml` |
| `CAP-6b1 build the normal-profile setup from the pinned locks (payload-listing proof)` | windows | 1217 | `.github/actions/cap-6b1-build-the-normal-profile-setup-from-the-pinned-locks-payload/action.yml` |
| `CAP-6b1 setup gates - skip path, layout, installed smoke, uninstall` | windows | 1225 | `.github/actions/cap-6b1-setup-gates-skip-path-layout-installed-smoke-uninstall/action.yml` |
| `CAP-6b1 diagnostics on failure` | windows | 1233 | `leg-diagnostics-${target}` |
| `CAP-6b2 fetch pinned Evergreen Standalone (sha256+authenticode, bounded, never executed)` | windows | 1277 | `.github/actions/cap-6b2-fetch-pinned-evergreen-standalone-sha256-authenticode-bounded/action.yml` |
| `CAP-6b2 build the offline-profile setup from the pinned locks (payload-listing proof)` | windows | 1287 | `.github/actions/cap-6b2-build-the-offline-profile-setup-from-the-pinned-locks-payload/action.yml` |
| `CAP-6b2 offline setup gates - streamed V-legs, isolated-dir skip path, layout, smoke, uninstall` | windows | 1295 | `.github/actions/cap-6b2-offline-setup-gates-streamed-v-legs-isolated-dir-skip-path/action.yml` |
| `CAP-6b2 diagnostics on failure` | windows | 1308 | `leg-diagnostics-${target}` |
| `CAP-6b3 fetch pinned Fixed Version Runtime (sha256+authenticode, bounded, never executed)` | windows | 1348 | `.github/actions/cap-6b3-fetch-pinned-fixed-version-runtime-sha256-authenticode-bounded/action.yml` |
| `CAP-6b3 build the fixed-profile setup from the pinned locks (expand + manifest + payload proof)` | windows | 1361 | `.github/actions/cap-6b3-build-the-fixed-profile-setup-from-the-pinned-locks-expand/action.yml` |
| `CAP-6b3 Fixed Runtime process-drain tests (path scoping, churn, no global kill)` | windows | 1375 | `.github/actions/cap-6b3-fixed-runtime-process-drain-tests-path-scoping-churn-no-global/action.yml` |
| `CAP-6b3 fixed setup gates - install, ACL by SID, manifest, observed identity, no-fallback, uninstall, abort probe` | windows | 1386 | `.github/actions/cap-6b3-fixed-setup-gates-install-acl-by-sid-manifest-observed-identity/action.yml` |
| `CAP-6b3 diagnostics on failure` | windows | 1398 | `leg-diagnostics-${target}` |
| `CAP-6b4 contract cross-checks (marker, basenames, runtime subdir, fixed [Files] order, sweeps, prior-gate aggregation)` | windows | 1435 | `.github/actions/cap-6b4-contract-cross-checks-marker-basenames-runtime-subdir-fixed/action.yml` |
| `CAP-6b4 build switch probes (offline abort probe + consolidated facts)` | windows | 1446 | `.github/actions/cap-6b4-build-switch-probes-offline-abort-probe-consolidated-facts/action.yml` |
| `CAP-6b4 release index from the three built profiles` | windows | 1457 | `.github/actions/cap-6b4-release-index-from-the-three-built-profiles/action.yml` |
| `CAP-6b4 profile isolation (per-profile ISCC listings, size envelopes, release index)` | windows | 1465 | `.github/actions/cap-6b4-profile-isolation-per-profile-iscc-listings-size-envelopes/action.yml` |
| `CAP-6b4 profile matrix - I1-I3, S1-S6, F1-F4, U1-U3 over the three real setups` | windows | 1481 | `.github/actions/cap-6b4-profile-matrix-i1-i3-s1-s6-f1-f4-u1-u3-over-the-three-real/action.yml` |
| `CAP-10E E4 fixed-runtime profile at a non-ASCII install directory` | windows | 1509 | `.github/actions/cap-10e-e4-fixed-runtime-profile-at-a-non-ascii-install-directory/action.yml` |
| `CAP-7F host-argument gate on the release triple (closes D1 on Windows)` | windows | 1529 | `.github/actions/cap-7f-host-argument-gate-on-the-release-triple-closes-d1-on-windows/action.yml` |
| `CAP-8B real-window navigation matrix (WebView2)` | windows | 1551 | `.github/actions/cap-8b-real-window-navigation-matrix-webview2/action.yml` |
| `CAP-8B upload the Windows nav-matrix record` | windows | 1559 | `leg-records-${target}` |
| `CAP-8C multi-principal integration harness (WebView2)` | windows | 1583 | `.github/actions/cap-8c-multi-principal-integration-harness-webview2/action.yml` |
| `CAP-8C upload the Windows multiprincipal record` | windows | 1591 | `leg-records-${target}` |
| `CAP-7L build libwebview.so from pinned source (cmake + gcc)` | linux | 2713 | `.github/actions/cap-7l-build-libwebview-so-from-pinned-source-cmake-gcc/action.yml` |
| `CAP-7L deps/webview carries no Linux patch` | linux | 2722 | `.github/actions/cap-7l-deps-webview-carries-no-linux-patch/action.yml` |
| `CAP-7L public ABI remains exactly 17 exports (nm -D)` | linux | 2733 | `.github/actions/cap-7l-public-abi-remains-exactly-17-exports-nm-d/action.yml` |
| `CAP-7L paired ABI probes + hand-declared symbol presence gate` | linux | 2737 | `.github/actions/cap-7l-paired-abi-probes-hand-declared-symbol-presence-gate/action.yml` |
| `CAP-7L setup pinned Node` | linux | 2742 | `.github/workflows/platform-leg.yml step 88` |
| `CAP-7L TypeScript SDK build + tests` | linux | 2755 | `.github/actions/cap-7l-typescript-sdk-build-tests/action.yml` |
| `CAP-7L React frontend build (pinned lockfile, offline bundle)` | linux | 2770 | `.github/actions/cap-7l-react-frontend-build-pinned-lockfile-offline-bundle/action.yml` |
| `CAP-7L fetch pinned pas2js (sha256-verified) and build its frontend` | linux | 2790 | `.github/actions/cap-7l-fetch-pinned-pas2js-sha256-verified-and-build-its-frontend/action.yml` |
| `CAP-7L compile every unit, probe and example for Linux` | linux | 2803 | `.github/actions/cap-7l-compile-every-unit-probe-and-example-for-linux/action.yml` |
| `CAP-7L headless gates - suite, POSIX store confinement, packaging` | linux | 2808 | `.github/actions/cap-7l-headless-gates-suite-posix-store-confinement-packaging/action.yml` |
| `CAP-7L GUI matrix (L4-L22) under Xvfb` | linux | 2815 | `.github/actions/cap-7l-gui-matrix-l4-l22-under-xvfb/action.yml` |
| `CAP-7L release layout - React and Pas2JS to 42 from an isolated dir` | linux | 2820 | `.github/actions/cap-7l-release-layout-react-and-pas2js-to-42-from-an-isolated-dir/action.yml` |
| `CAP-7L zero-transport proof (L20)` | linux | 2825 | `.github/actions/cap-7l-zero-transport-proof-l20/action.yml` |
| `CAP-7F host-argument gate on the release layout (closes D1 on Linux)` | linux | 2837 | `.github/actions/cap-7f-host-argument-gate-on-the-release-layout-closes-d1-on-linux/action.yml` |
| `CAP-8B real-window navigation matrix (WebKitGTK) under Xvfb` | linux | 2851 | `.github/actions/cap-8b-real-window-navigation-matrix-webkitgtk-under-xvfb/action.yml` |
| `CAP-8B upload the Linux nav-matrix record` | linux | 2856 | `leg-records-${target}` |
| `CAP-8C multi-principal integration harness (WebKitGTK) under Xvfb` | linux | 2877 | `.github/actions/cap-8c-multi-principal-integration-harness-webkitgtk-under-xvfb/action.yml` |
| `CAP-8C upload the Linux multiprincipal record` | linux | 2882 | `leg-records-${target}` |
| `CAP-7M0 cache the pinned FPC disk image` | macos-x64, macos-arm64 | 3737, 4762 | `.github/workflows/platform-leg.yml step 100` |
| `CAP-7M0 install pinned FPC and select the pinned Xcode` | macos-x64, macos-arm64 | 3743, 4768 | `.github/actions/cap-7m0-install-pinned-fpc-and-select-the-pinned-xcode/action.yml` |
| `CAP-7M0 deps/webview carries no macOS patch` | macos-x64, macos-arm64 | 3752, 4773 | `.github/actions/cap-7m0-deps-webview-carries-no-macos-patch/action.yml` |
| `CAP-7M0 build libwebview.dylib from pinned source (M1/M3/M16)` | macos-x64, macos-arm64 | 3763, 4784 | `.github/actions/cap-7m0-build-libwebview-dylib-from-pinned-source-m1-m3-m16/action.yml` |
| `CAP-7M0 public ABI remains exactly 17 exports (M2)` | macos-x64, macos-arm64 | 3772, 4793 | `.github/actions/cap-7m0-public-abi-remains-exactly-17-exports-m2/action.yml` |
| `CAP-7M0 paired ABI probes + Mach-O presence and dlopen gates (M4/M5)` | macos-x64, macos-arm64 | 3776, 4797 | `.github/actions/cap-7m0-paired-abi-probes-mach-o-presence-and-dlopen-gates-m4-m5/action.yml` |
| `CAP-7M1 compile the production Cocoa bridge (one object)` | macos-x64, macos-arm64 | 3786, 4807 | `.github/actions/cap-7m1-compile-the-production-cocoa-bridge-one-object/action.yml` |
| `CAP-7M0 compile the binding, mORMot core and the probe (M17)` | macos-x64, macos-arm64 | 3791, 4812 | `.github/actions/cap-7m0-compile-the-binding-mormot-core-and-the-probe-m17/action.yml` |
| `CAP-7M1 headless gates (suite + folder confinement)` | macos-x64, macos-arm64 | 3802, 4823 | `.github/actions/cap-7m1-headless-gates-suite-folder-confinement/action.yml` |
| `CAP-7M0 feasibility probes (M6-M15)` | macos-x64, macos-arm64 | 3811, 4830 | `.github/actions/cap-7m0-feasibility-probes-m6-m15/action.yml` |
| `CAP-7M1 production runtime gates (real WKWebView, folder + zip)` | macos-x64, macos-arm64 | 3822, 4841 | `.github/actions/cap-7m1-production-runtime-gates-real-wkwebview-folder-zip/action.yml` |
| `CAP-7M2 setup pinned Node` | macos-x64, macos-arm64 | 3835, 4852 | `.github/workflows/platform-leg.yml step 111` |
| `CAP-7M2 TypeScript SDK build + tests` | macos-x64, macos-arm64 | 3840, 4857 | `.github/actions/cap-7m2-typescript-sdk-build-tests/action.yml` |
| `CAP-7M2 React frontend build (pinned lockfile, offline bundle)` | macos-x64, macos-arm64 | 3855, 4872 | `.github/actions/cap-7m2-react-frontend-build-pinned-lockfile-offline-bundle/action.yml` |
| `CAP-7M2 fetch pinned pas2js (sha256 + native arch) and build its frontend` | macos-x64 | 3871 | `.github/actions/cap-7m2-fetch-pinned-pas2js-sha256-native-arch-and-build-its-frontend/action.yml` |
| `CAP-7M2 fetch pinned pas2js (sha256 + native compile) and build its frontend` | macos-arm64 | 4888 | `.github/actions/cap-7m2-fetch-pinned-pas2js-sha256-native-compile-and-build-its-frontend/action.yml` |
| `CAP-7M2 compile the release host and bundler` | macos-x64, macos-arm64 | 3884, 4901 | `.github/actions/cap-7m2-compile-the-release-host-and-bundler/action.yml` |
| `CAP-7M2 release .app gates - assembly, refusals, direct + LaunchServices to 42` | macos-x64, macos-arm64 | 3889, 4906 | `.github/actions/cap-7m2-release-app-gates-assembly-refusals-direct-launchservices-to-42/action.yml` |
| `CAP-7M2 release manifests and inventories` | macos-x64, macos-arm64 | 3897, 4911 | `leg-release-${target}` |
| `CAP-7M0 bundle layout measured from an unrelated CWD (M18)` | macos-x64, macos-arm64 | 3909, 4923 | `.github/actions/cap-7m0-bundle-layout-measured-from-an-unrelated-cwd-m18/action.yml` |
| `CAP-7M0 zero-transport proof (M20)` | macos-x64, macos-arm64 | 3914, 4928 | `.github/actions/cap-7m0-zero-transport-proof-m20/action.yml` |
| `CAP-8B real-window navigation matrix (WKWebView)` | macos-x64, macos-arm64 | 3927, 4938 | `.github/actions/cap-8b-real-window-navigation-matrix-wkwebview/action.yml` |
| `CAP-8B upload the macOS arm64 nav-matrix record` | macos-arm64 | 4943 | `leg-records-${target}` |
| `CAP-8B upload the macOS x64 nav-matrix record` | macos-x64 | 3932 | `leg-records-${target}` |
| `CAP-8C multi-principal integration harness (WKWebView)` | macos-x64, macos-arm64 | 3952, 4960 | `.github/actions/cap-8c-multi-principal-integration-harness-wkwebview/action.yml` |
| `CAP-8C upload the macOS x64 multiprincipal record` | macos-x64 | 3957 | `leg-records-${target}` |
| `CAP-8C upload the macOS arm64 multiprincipal record` | macos-arm64 | 4965 | `leg-records-${target}` |
| `CAP-9A QuickJS invocation foundation harness` | windows, linux, macos-x64, macos-arm64 | 1612, 2899, 3977, 4982 | `.github/actions/cap-9a-quickjs-invocation-foundation-harness/action.yml` |
| `CAP-9A upload the macOS arm64 quickjs record` | macos-arm64 | 4987 | `leg-records-${target}` |
| `CAP-9A upload the Windows quickjs record` | windows | 1620 | `leg-records-${target}` |
| `CAP-9A upload the Linux quickjs record` | linux | 2904 | `leg-records-${target}` |
| `CAP-9A upload the macOS x64 quickjs record` | macos-x64 | 3982 | `leg-records-${target}` |
| `CAP-9B1 QuickJS package and module-loader harness` | windows, linux, macos-x64, macos-arm64 | 1644, 2923, 4002, 5005 | `.github/actions/cap-9b1-quickjs-package-and-module-loader-harness/action.yml` |
| `CAP-9B1 upload the macOS x64 package record` | macos-x64 | 4007 | `leg-records-${target}` |
| `CAP-9B1 upload the Windows package record` | windows | 1652 | `leg-records-${target}` |
| `CAP-9B1 upload the Linux package record` | linux | 2928 | `leg-records-${target}` |
| `CAP-9B1 upload the macOS arm64 package record` | macos-arm64 | 5010 | `leg-records-${target}` |
| `CAP-9B2 QuickJS plugin lifecycle and reload harness` | windows, linux, macos-x64, macos-arm64 | 1676, 2946, 4024, 5025 | `.github/actions/cap-9b2-quickjs-plugin-lifecycle-and-reload-harness/action.yml` |
| `CAP-9B2 upload the macOS arm64 lifecycle record` | macos-arm64 | 5030 | `leg-records-${target}` |
| `CAP-9B2 upload the Windows lifecycle record` | windows | 1684 | `leg-records-${target}` |
| `CAP-9B2 upload the Linux lifecycle record` | linux | 2951 | `leg-records-${target}` |
| `CAP-9B2 upload the macOS x64 lifecycle record` | macos-x64 | 4029 | `leg-records-${target}` |
| `CAP-9C1 QuickJS release package and trusted loader harness` | windows, linux, macos-x64, macos-arm64 | 1707, 2969, 4042, 5043 | `.github/actions/cap-9c1-quickjs-release-package-and-trusted-loader-harness/action.yml` |
| `CAP-9C1 upload the macOS x64 release record and payload` | macos-x64 | 4047 | `leg-records-${target}` |
| `CAP-9C1 upload the Windows release record and payload` | windows | 1715 | `leg-records-${target}` |
| `CAP-9C1 upload the Linux release record and payload` | linux | 2974 | `leg-records-${target}` |
| `CAP-9C1 upload the macOS arm64 release record and payload` | macos-arm64 | 5048 | `leg-records-${target}` |
| `CAP-9C2 plugin-enabled acceptance frontend build` | windows, linux, macos-x64, macos-arm64 | 1735, 2990, 4061, 5062 | `.github/actions/cap-9c2-plugin-enabled-acceptance-frontend-build/action.yml` |
| `CAP-9C2 plugin-enabled release layout and real-GUI acceptance` | windows, linux, macos-x64, macos-arm64 | 1765, 3006, 4077, 5078 | `.github/actions/cap-9c2-plugin-enabled-release-layout-and-real-gui-acceptance/action.yml` |
| `CAP-9C2 upload the macOS arm64 plugin-enabled record and layout` | macos-arm64 | 5083 | `leg-records-${target}` |
| `CAP-9C2 upload the Windows plugin-enabled record and layout` | windows | 1773 | `leg-records-${target}` |
| `CAP-9C2 upload the Linux plugin-enabled record and layout` | linux | 3011 | `leg-records-${target}` |
| `CAP-9C2 upload the macOS x64 plugin-enabled record and layout` | macos-x64 | 4082 | `leg-records-${target}` |
| `CAP-10B0 build the scaffold engine, the pack and the suite` | windows, linux, macos-x64, macos-arm64 | 1810, 3039, 4111, 5108 | `.github/actions/cap-10b0-build-the-scaffold-engine-the-pack-and-the-suite/action.yml` |
| `CAP-10B1 build the public pack, the CLI and the SDK root` | windows, linux, macos-x64, macos-arm64 | 1817, 3044, 4116, 5113 | `.github/actions/cap-10b1-build-the-public-pack-the-cli-and-the-sdk-root/action.yml` |
| `CAP-10A build the suite and the probe fixture` | windows, linux, macos-x64, macos-arm64 | 1824, 3049, 4121, 5118 | `.github/actions/cap-10a-build-the-suite-and-the-probe-fixture/action.yml` |
| `CAP-10A contract cross-checks (pins, no shell, no network)` | windows, linux, macos-x64, macos-arm64 | 1831, 3054, 4126, 5123 | `.github/actions/cap-10a-contract-cross-checks-pins-no-shell-no-network/action.yml` |
| `CAP-10A development-trust gate` | windows, linux, macos-x64, macos-arm64 | 1837, 3060, 4132, 5129 | `.github/actions/cap-10a-development-trust-gate/action.yml` |
| `CAP-10A CLI gates + evidence` | windows, linux, macos-x64, macos-arm64 | 1843, 3066, 4138, 5135 | `.github/actions/cap-10a-cli-gates-evidence/action.yml` |
| `CAP-10A upload the CLI corpus` | windows, linux, macos-x64, macos-arm64 | 1851, 3073, 4145, 5142 | `leg-records-${target}` |
| `CAP-10B0 contract cross-checks (create linked, offline, limits)` | windows, linux, macos-x64, macos-arm64 | 1880, 3091, 4161, 5158 | `.github/actions/cap-10b0-contract-cross-checks-create-linked-offline-limits/action.yml` |
| `CAP-10B0 scaffold gates + evidence` | windows, linux, macos-x64, macos-arm64 | 1886, 3097, 4167, 5164 | `.github/actions/cap-10b0-scaffold-gates-evidence/action.yml` |
| `CAP-10B0 upload the scaffold corpus` | windows, linux, macos-x64, macos-arm64 | 1894, 3104, 4174, 5171 | `leg-records-${target}` |
| `CAP-10B1 contract cross-checks (one UI, exact pins, no exec)` | windows, linux, macos-x64, macos-arm64 | 1923, 3121, 4192, 5188 | `.github/actions/cap-10b1-contract-cross-checks-one-ui-exact-pins-no-exec/action.yml` |
| `CAP-10B1 create gates + evidence` | windows, linux, macos-x64, macos-arm64 | 1929, 3127, 4198, 5194 | `.github/actions/cap-10b1-create-gates-evidence/action.yml` |
| `CAP-10B1 private build proof and real GUI run` | windows, linux, macos-x64, macos-arm64 | 1937, 3134, 4205, 5201 | `.github/actions/cap-10b1-private-build-proof-and-real-gui-run/action.yml` |
| `CAP-10B1 upload the create corpus` | windows, linux, macos-x64, macos-arm64 | 1945, 3139, 4210, 5206 | `leg-records-${target}` |
| `CAP-10B2 build the react-only CLI that proves template_unknown` | windows, linux, macos-x64, macos-arm64 | 1977, 3157, 4229, 5226 | `.github/actions/cap-10b2-build-the-react-only-cli-that-proves-template-unknown/action.yml` |
| `CAP-10B2 contract cross-checks (two UIs, one native app, no npm)` | windows, linux, macos-x64, macos-arm64 | 1984, 3162, 4234, 5231 | `.github/actions/cap-10b2-contract-cross-checks-two-uis-one-native-app-no-npm/action.yml` |
| `CAP-10B2 pas2js create gates + evidence` | windows, linux, macos-x64, macos-arm64 | 1990, 3168, 4240, 5237 | `.github/actions/cap-10b2-pas2js-create-gates-evidence/action.yml` |
| `CAP-10B2 private build proof and real GUI run` | windows, linux, macos-x64, macos-arm64 | 1998, 3175, 4247, 5244 | `.github/actions/cap-10b2-private-build-proof-and-real-gui-run/action.yml` |
| `CAP-10B2 upload the pas2js corpus` | windows, linux, macos-x64, macos-arm64 | 2006, 3180, 4252, 5249 | `leg-records-${target}` |
| `CAP-10C0 build the supervision suite and the fixture child` | windows, linux, macos-x64, macos-arm64 | 2022, 3194, 4266, 5263 | `.github/actions/cap-10c0-build-the-supervision-suite-and-the-fixture-child/action.yml` |
| `CAP-10C0 contract cross-checks (bounds, no shell at the link, no name-kill, env, shutdown order)` | windows, linux, macos-x64, macos-arm64 | 2029, 3199, 4271, 5268 | `.github/actions/cap-10c0-contract-cross-checks-bounds-no-shell-at-the-link-no-name-kill/action.yml` |
| `CAP-10C0 supervision suite + pweb run gates + evidence` | windows, linux, macos-x64, macos-arm64 | 2035, 3205, 4277, 5274 | `.github/actions/cap-10c0-supervision-suite-pweb-run-gates-evidence/action.yml` |
| `CAP-10C0 upload the supervision corpus` | windows, linux, macos-x64, macos-arm64 | 2043, 3213, 4285, 5282 | `leg-records-${target}` |
| `CAP-10C1 complete the SDK root and build the pipeline driver` | windows, linux, macos-x64, macos-arm64 | 2060, 3230, 4302, 5299 | `.github/actions/cap-10c1-complete-the-sdk-root-and-build-the-pipeline-driver/action.yml` |
| `CAP-10C1 contract cross-checks (bounds, library names, linkage, no conditional, no env read)` | windows, linux, macos-x64, macos-arm64 | 2067, 3235, 4307, 5304 | `.github/actions/cap-10c1-contract-cross-checks-bounds-library-names-linkage-no/action.yml` |
| `CAP-10C1 lifecycle pipeline gates + app.pwb parity + evidence` | windows, linux, macos-x64, macos-arm64 | 2073, 3241, 4313, 5310 | `.github/actions/cap-10c1-lifecycle-pipeline-gates-app-pwb-parity-evidence/action.yml` |
| `CAP-10C1 upload the pipeline corpus` | windows, linux, macos-x64, macos-arm64 | 2081, 3249, 4321, 5318 | `leg-records-${target}` |
| `CAP-10C2 build the development suite, the driver and both host binaries` | windows, linux, macos-x64, macos-arm64 | 2099, 3267, 4339, 5336 | `.github/actions/cap-10c2-build-the-development-suite-the-driver-and-both-host-binaries/action.yml` |
| `CAP-10C2 contract cross-checks (bounds, linkage, dev-free release, CSP, no transport)` | windows, linux, macos-x64, macos-arm64 | 2105, 3271, 4343, 5340 | `.github/actions/cap-10c2-contract-cross-checks-bounds-linkage-dev-free-release-csp-no/action.yml` |
| `CAP-10C2 development-loop gates (DEV1-DEV14, T1-T5) + evidence` | windows, linux, macos-x64, macos-arm64 | 2111, 3277, 4349, 5346 | `.github/actions/cap-10c2-development-loop-gates-dev1-dev14-t1-t5-evidence/action.yml` |
| `CAP-10C2 upload the development corpus` | windows, linux, macos-x64, macos-arm64 | 2119, 3285, 4357, 5354 | `leg-records-${target}` |
| `CAP-10C3 build the pas2js development suite, the driver and both host binaries` | windows, linux, macos-x64, macos-arm64 | 2143, 3309, 4381, 5378 | `.github/actions/cap-10c3-build-the-pas2js-development-suite-the-driver-and-both-host/action.yml` |
| `CAP-10C3 contract cross-checks (bounds, detector linkage, no watch API, pas2js CSP + dev-free release)` | windows, linux, macos-x64, macos-arm64 | 2149, 3313, 4385, 5382 | `.github/actions/cap-10c3-contract-cross-checks-bounds-detector-linkage-no-watch-api/action.yml` |
| `CAP-10C3 the CAP-10C ledger disposition (CL2, CL3)` | windows, linux, macos-x64, macos-arm64 | 2154, 3318, 4390, 5387 | `.github/actions/cap-10c3-the-cap-10c-ledger-disposition-cl2-cl3/action.yml` |
| `CAP-10C3 pas2js development-loop gates (PD1-PD15, RD1, T1-T5, CL1-CL3) + evidence` | windows, linux, macos-x64, macos-arm64 | 2160, 3324, 4396, 5393 | `.github/actions/cap-10c3-pas2js-development-loop-gates-pd1-pd15-rd1-t1-t5-cl1-cl3/action.yml` |
| `CAP-10C3 upload the pas2js development corpus` | windows, linux, macos-x64, macos-arm64 | 2168, 3332, 4404, 5401 | `leg-records-${target}` |
| `CAP-10D0 build the public-build suite and its driver` | windows, linux, macos-x64, macos-arm64 | 2192, 3356, 4428, 5425 | `.github/actions/cap-10d0-build-the-public-build-suite-and-its-driver/action.yml` |
| `CAP-10D0 contract cross-checks (one execution path, ten stages, five commands, gate quoting)` | windows, linux, macos-x64, macos-arm64 | 2198, 3360, 4432, 5429 | `.github/actions/cap-10d0-contract-cross-checks-one-execution-path-ten-stages-five/action.yml` |
| `CAP-10D0 public-build gates (B1-B12, L1-L3, R1-R2) + evidence` | windows, linux, macos-x64, macos-arm64 | 2204, 3366, 4438, 5435 | `.github/actions/cap-10d0-public-build-gates-b1-b12-l1-l3-r1-r2-evidence/action.yml` |
| `CAP-10D0 upload the public-build corpus` | windows, linux, macos-x64, macos-arm64 | 2212, 3374, 4446, 5443 | `leg-records-${target}` |
| `CAP-10D1 contract cross-checks (pins vs locks, five engine callers, the anti-fork twins, no signing, no network)` | windows, linux, macos-x64, macos-arm64 | 2243, 3405, 4477, 5474 | `.github/actions/cap-10d1-contract-cross-checks-pins-vs-locks-five-engine-callers-the/action.yml` |
| `CAP-10D1 stage the packaging kit and build the suite and driver` | windows, linux, macos-x64, macos-arm64 | 2248, 3410, 4482, 5479 | `.github/actions/cap-10d1-stage-the-packaging-kit-and-build-the-suite-and-driver/action.yml` |
| `CAP-10D1 packaging gates + evidence` | windows, linux, macos-x64, macos-arm64 | 2252, 3414, 4486, 5483 | `.github/actions/cap-10d1-packaging-gates-evidence/action.yml` |
| `CAP-10D1 upload the packaging corpus` | windows, linux, macos-x64, macos-arm64 | 2260, 3422, 4494, 5491 | `leg-records-${target}` |
| `CAP-10D0 L2b - the CAP-10 chain at a repository path with a space` | windows | 2315 | `.github/actions/cap-10d0-l2b-the-cap-10-chain-at-a-repository-path-with-a-space/action.yml` |
| `CAP-10D2 contract cross-checks (no network, no env root, the licence table, the tool rule)` | windows, linux, macos-x64, macos-arm64 | 2411, 3451, 4523, 5520 | `.github/actions/cap-10d2-contract-cross-checks-no-network-no-env-root-the-licence-table/action.yml` |
| `CAP-10D2 the phase-wide CAP-10 ledger disposition (CL1-CL4)` | windows, linux, macos-x64, macos-arm64 | 2416, 3456, 4528, 5525 | `.github/actions/cap-10d2-the-phase-wide-cap-10-ledger-disposition-cl1-cl4/action.yml` |
| `CAP-10D2 stage the licence set and build the packager and suite` | windows, linux, macos-x64, macos-arm64 | 2421, 3461, 4533, 5530 | `.github/actions/cap-10d2-stage-the-licence-set-and-build-the-packager-and-suite/action.yml` |
| `CAP-10D2 SDK distribution gates (PK1-PK4, IN1-IN4, CM1-CM6, CL1-CL4) + evidence` | windows, linux, macos-x64, macos-arm64 | 2425, 3465, 4537, 5534 | `.github/actions/cap-10d2-sdk-distribution-gates-pk1-pk4-in1-in4-cm1-cm6-cl1-cl4-evidence/action.yml` |
| `CAP-10D2 upload the SDK distribution corpus` | windows, linux, macos-x64, macos-arm64 | 2433, 3473, 4545, 5542 | `leg-records-${target}` |
| `CAP-10D2 upload the SDK archive and its manifest` | windows, linux, macos-x64, macos-arm64 | 2450, 3490, 4562, 5559 | `leg-dist-${target}` |
| `CAP-10E image-path source gate (zero ParamStr(0), zero ProgramFilePath, one reader)` | windows, linux, macos-x64, macos-arm64 | 2465, 3507, 4577, 5572 | `.github/actions/cap-10e-image-path-source-gate-zero-paramstr-0-zero-programfilepath-one/action.yml` |
| `CAP-10E kernel image path - non-ASCII release host, junction, long path (E1/E2/E6/E7/E9)` | windows | 2473 | `.github/actions/cap-10e-kernel-image-path-non-ascii-release-host-junction-long-path-e1/action.yml` |
| `CAP-10E upload the Windows image-path record` | windows | 2481 | `leg-records-${target}` |
| `CAP-7F emit the Windows evidence artifact` | windows | 2497 | `.github/actions/cap-7f-emit-the-windows-evidence-artifact/action.yml` |
| `CAP-7F upload the Windows evidence` | windows | 2507 | `leg-evidence-${target}` |
| `CAP-10E kernel image path - non-ASCII release host and the symlink rule (E1/E2/E5/E9)` | linux | 3512 | `.github/actions/cap-10e-kernel-image-path-non-ascii-release-host-and-the-symlink-rule/action.yml` |
| `CAP-10E upload the Linux image-path record` | linux | 3520 | `leg-records-${target}` |
| `CAP-7F emit the Linux evidence artifact` | linux | 3534 | `.github/actions/cap-7f-emit-the-linux-evidence-artifact/action.yml` |
| `CAP-7F upload the Linux evidence` | linux | 3539 | `leg-evidence-${target}` |
| `CAP-10E kernel image path - non-ASCII (NFD) release host and the symlink rule (E1/E2/E5/E9)` | macos-x64, macos-arm64 | 4582, 5577 | `.github/actions/cap-10e-kernel-image-path-non-ascii-nfd-release-host-and-the-symlink/action.yml` |
| `CAP-10E upload the macOS x64 image-path record` | macos-x64 | 4589 | `leg-records-${target}` |
| `CAP-7F emit the macOS x64 evidence artifact` | macos-x64 | 4603 | `.github/actions/cap-7f-emit-the-macos-x64-evidence-artifact/action.yml` |
| `CAP-7F upload the macOS x64 evidence` | macos-x64 | 4608 | `leg-evidence-${target}` |
| `CAP-10E upload the macOS arm64 image-path record` | macos-arm64 | 5584 | `leg-records-${target}` |
| `CAP-7F emit the macOS arm64 evidence artifact` | macos-arm64 | 5598 | `.github/actions/cap-7f-emit-the-macos-arm64-evidence-artifact/action.yml` |
| `CAP-7F upload the macOS arm64 evidence` | macos-arm64 | 5603 | `leg-evidence-${target}` |
| `CAP-7F diagnostics on failure` | windows, linux, macos-x64, macos-arm64 | 2518, 3551, 4617, 5612 | `leg-diagnostics-${target}` |
| `CAP-7M0 per-arch headline facts to the run summary` | macos-x64, macos-arm64 | 4632, 5627 | `.github/actions/cap-7m0-per-arch-headline-facts-to-the-run-summary/action.yml` |
| `CAP-7M0 measurements (always uploaded - the shard's whole output)` | macos-x64, macos-arm64 | 4641, 5632 | `leg-records-${target}` |
| `CAP-7M0 diagnostics on failure (permissive by design)` | macos-x64, macos-arm64 | 4651, 5642 | `leg-diagnostics-${target}` |
| `CAP-6b4 diagnostics on failure` | windows | 2542 | `leg-diagnostics-${target}` |
| `Upload diagnostics on failure` | windows | 2560 | `leg-diagnostics-${target}` |
| `CAP-7L diagnostics on failure` | linux | 3566 | `leg-diagnostics-${target}` |

## The two consumer jobs

`macos-release-inventory` and `cap7-aggregate` moved from the legacy file
into the caller, unchanged in what they check. Both now read the per-leg
collection artifacts rather than the per-shard ones, and the aggregate
gained `test/cap11a/check_ci_sequence.ps1`, which measures the premise the
whole comparison rests on: that the four legs ran the same step sequence.
