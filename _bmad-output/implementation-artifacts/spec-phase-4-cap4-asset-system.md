---
title: 'PWeb Phase 4 / CAP-4 asset system — Folder and ZIP stores behind pweb://app'
type: 'feature'
created: '2026-08-11'
status: 'done'
review_loop_iteration: 0
baseline_commit: '4ea6fdf61a6e02e3a17cdcb6c6bf823f1efc150f'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-phase-4-cap4w-windows-custom-scheme.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-4W proved `pweb://app` renders as a secure context through the borrowed-controller seam, but no `IAssetStore` implementation exists: frontends still load via `SetHtml`, not through the frozen asset contract.

**Approach:** Implement shared canonical-path validation and deterministic MIME, then `TFolderAssetStore` (dev, `frontend/dist/`) and `TZipAssetStore` (`app.zip`, mORMot `TZipRead`, no disk extraction), prove Folder/ZIP parity headless, then serve both through a production Pascal WebView2 `WebResourceRequested` handler on the proven CAP-4W seam, with runtime HTML/CSS/JS/secure-context verdicts in both modes and CAP-3 RPC still returning 42.

## Boundaries & Constraints

**Always:** `src/assets/pweb.assets.intf.pas` stays byte-frozen — `TryRead` only, no Exists, no streaming, no platform types. Stores independently fail closed on non-canonical input via one shared validator: reject empty/`.`/`..` segments, backslash, absolute/drive/UNC, NUL, invalid or overlong UTF-8, ADS colon, device names (with or without extension), trailing dot/space segments, and any `%` (handler decodes exactly once; a store-level `%` means double encoding — reject, never re-decode). Exact case-sensitive lookup on Windows in both stores; folder resolution confined below its root including reparse/symlink escapes. `TZipRead` shared reads are not reentrant (file-backed source shares one seekable `fSource`, `NameToIndex` is case-insensitive and delimiter-normalizing) — index raw `storedName` bytes privately, serialize archive access inside `TZipAssetStore`. Handler: verify scheme+authority, map `pweb://app/` → `index.html` in the URI layer only, decode once, `TryRead`, 200 + exact bytes + Content-Type, else deterministic 404 without leaking paths/reasons; no Pascal exception escapes a COM callback; preserve CAP-4W unregister/release/destroy ordering. Headless Folder/ZIP parity passes before any runtime handler work. Preserve all pins, the 17-export ABI, frozen Phase-0/1/2 paths vs `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5`, CAP-3/CAP-3U/CAP-4W.

**Ask First:** Any change to the frozen `IAssetStore` contract or `TAssetResponse`; any new pin or SDK bump; serving any asset via HTTP/localhost/file://; Windows-registry MIME; any weakening of a hosted CI gate.

**Never:** CAP-4b/blob/Range/streaming/upload/SharedBuffer, CAP-5 SDK, CAP-6 bundler/`app.pwb`/PWB1/SynLZ; `SetHtml`/`Eval` injection of the runtime frontend; recursive percent-decode; case-folding lookups; extracting ZIP assets to disk; modifying CAP-3 or the CAP-4W patch/seam.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Dev + packaged | same corpus via Folder and ZIP | byte- and ContentType-identical responses, zero-byte and NUL-containing assets included | N/A |
| Hostile path | `../x`, `a\b`, `/abs`, `C:/x`, `//srv/s`, `x.txt:ads`, `NUL.txt`, `x. `, `%2e%2e`, malformed `%zz`, overlong UTF-8 | `TryRead` False from both stores; handler 404 | fail closed, no exception |
| Wrong case | `assets/App.js` for stored `assets/app.js` | False in both stores on Windows | explicit exact-case check, not filesystem default |
| Hostile archive | duplicate, traversal, backslash, absolute-like, or case-colliding entry names | `TZipAssetStore` construction fails deterministically | archive rejected as a whole |
| Root escape | symlink/reparse point under folder root | False; nothing outside root ever opened | resolved path re-verified under root |
| Runtime A/B | `pweb://app/` in folder mode and zip mode | HTML+CSS+JS load normally, `isSecureContext===true`, `CalculatorService.Add({a:20,b:22})` → 42, machine verdict, clean exit | any miss fails the smoke |
| MIME | html/js/css/json/txt/svg/png/jpg/gif/webp/ico/woff/woff2/wasm + unknown | fixed table (+`; charset=utf-8` for text types), fallback `application/octet-stream` | N/A |

</frozen-after-approval>

## Code Map

- `src/assets/pweb.assets.intf.pas` — frozen contract; read-only; its comment block already ratifies the full fail-closed path list.
- `src/assets/pweb.assets.support.pas` — NEW shared validator + MIME resolver; `mormot.core.base` only (mirror `pweb.rpc.support.pas` precedent, CI isolation compile).
- `src/assets/pweb.assets.folder.pas`, `src/assets/pweb.assets.zip.pas` — NEW stores. ZIP: `deps/mormot2/src/core/mormot.core.zip.pas:524-600` (`TZipRead.Entry[].storedName`/`dir^.fileInfo.nameLen` raw names; `UnZip(aIndex)`; never `NameToIndex` — case-insensitive `SameTextS`, `NormalizeZipName`).
- `src/platform/windows/pweb.platform.webview2.pas` — NEW production handler; transliterate `test/cap4w/cap4w_probe.cpp:114-260` (borrowed controller → `get_CoreWebView2` → `ICoreWebView2_2.get_Environment` → `AddWebResourceRequestedFilter('pweb://app/*')` → `CreateWebResourceResponse`; `SHCreateMemStream`); minimal hand-declared COM interfaces from pinned SDK 1.0.1587.40 headers.
- `test/assets/` — NEW headless suite; register in `test/core/pwebtests.pas:32-63` (new published proc, outside the CAP-3U define); generate the fixture corpus and hostile ZIPs in-memory/temp at test time (`.gitignore:87` ignores `*.txt` repo-wide — commit no fixture bytes beyond the example frontend).
- `examples/06-assets/` — NEW runtime example (frozen layout name): committed `frontend/dist/{index.html,assets/app.css,assets/app.js}`, `mkappzip.pas` (TZipWrite → `app.zip`), `assetsapp.pas` with folder|zip mode arg; clone `examples/03-mormot-rpc/mormotrpc.pas:96-284` wiring (reporting bridge `example.report`, auto-close, teardown order).
- `.github/workflows/ci.yml:346-470` — gate style to extend: isolation compiles, pwebtests run, example smokes best-effort hosted/local-authoritative, freeze sweeps at `:456-470` stay untouched.

## Tasks & Acceptance

**Execution:**
- [x] `src/assets/pweb.assets.support.pas` — shared canonical-path validator + MIME table — one validation truth for stores and handler.
- [x] `test/assets/pweb.test.assets.pas` (+ fixture/crafted-zip helpers) — failing-first parity, hostile-path, hostile-archive, exact-case, root-confinement, repeated/concurrent-read cases; wire into `pwebtests.pas`.
- [x] `src/assets/pweb.assets.folder.pas` — `TFolderAssetStore` with exact-case per-segment verification and root confinement.
- [x] `src/assets/pweb.assets.zip.pas` — `TZipAssetStore`: deterministic construction-time entry validation over raw names, private lock around `UnZip`.
- [x] `src/platform/windows/pweb.platform.webview2.pas` — production `pweb://app` resource handler over `IAssetStore` on the CAP-4W seam.
- [x] `examples/06-assets/` — frontend fixture, `mkappzip`, dual-mode runtime app with machine verdict (HTML/CSS/JS/secure-context/RPC-42).
- [x] `.github/workflows/ci.yml` — CAP-4 isolation compiles, headless suite, example compile + zip build + best-effort dual-mode smoke, zero-HTTP sweep over new sources; no existing gate weakened.

**Acceptance Criteria:**
- Given the same corpus, when the headless suite runs Folder vs ZIP, then bytes and ContentType are identical, every hostile input returns False, and concurrent reads are deterministic — before any handler code compiles into an example.
- Given the runtime example in folder mode and zip mode, when it navigates `pweb://app/`, then CSS styling and JS execution are proven from the page, `isSecureContext` is true, Add returns 42 through the unchanged CAP-3 path, and the process exits 0 — with no HTTP/localhost/file:// anywhere.
- Given the final tree, when the full CI suite runs, then prior CAP-1/2/3U/3/4W gates and freeze diffs against `4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5` stay green with all pins intact.

## Spec Change Log

## Design Notes

The MIME table is deliberately the spec's minimum set plus the octet-stream fallback: types the fixture toolchain does not emit (`.map`, `.ttf`, `.otf`, `.webmanifest`, …) fall to the fallback by decision, not omission — extending the table is CAP-5/CAP-6 territory when a real frontend build needs it. Stores validate independently even though the handler validated first — defense in depth is ratified, not optional. ZIP validation happens once at construction (hostile archive = packaging error → fail whole store), so `TryRead` stays a lock-plus-lookup-plus-unzip. The Windows handler holds only borrowed/owned COM references per the CAP-4W probe ownership model; event/filter removal precedes reference release, which precedes `webview_destroy`. `TryRead('')` stays False; only the URI layer maps the root to `index.html`.

## Verification

**Commands:**
- `fpc -MObjFPC -Sh -B -FUbuild/fpc-assets -Fusrc/assets src/assets/pweb.assets.support.pas` (± mormot core paths per unit) — expected: assets units compile without webview/platform paths.
- pwebtests compile+run per `.github/workflows/ci.yml:436-447` plus `-Futest/assets` — expected: exit 0, prior counts preserved, new assets cases green.
- Example 06: build `mkappzip` + `assetsapp`; run with `PWEB_SMOKE_AUTOCLOSE_MS` in `folder` then `zip` mode — expected: machine verdict PASS ×4 + RPC 42, exit 0 twice.
- `git diff --exit-code 4653ba77ef03f0a37b0b0b0c4205ed6ecfe7e0f5 -- <frozen paths>` and the CAP-3 forbidden-network sweep extended to `src/assets`, `src/platform` — expected: empty / no hits.

## Suggested Review Order

**Canonical path validation and the URI layer**

- One fail-closed validation truth for stores and handler; every ratified rejection rule lives here.
  [`pweb.assets.support.pas:226`](../../src/assets/pweb.assets.support.pas#L226)

- Scheme/authority verification, the single percent-decode, and the only root→index.html mapping.
  [`pweb.assets.support.pas:370`](../../src/assets/pweb.assets.support.pas#L370)

**Folder store: exact case and confinement**

- Per-segment wide-API walk compares the on-disk spelling, defeating case folding and 8.3 aliases.
  [`pweb.assets.folder.pas:154`](../../src/assets/pweb.assets.folder.pas#L154)

- Kernel-normalized final path of the opened handle re-proves confinement, closing the check/open race.
  [`pweb.assets.folder.pas:205`](../../src/assets/pweb.assets.folder.pas#L205)

- Root canonicalized once through the kernel; long-path form; misconfiguration raises at startup.
  [`pweb.assets.folder.pas:116`](../../src/assets/pweb.assets.folder.pas#L116)

**ZIP store: deterministic archive validation**

- Raw stored-name bytes validated at construction: traversal, duplicates, case and file/dir collisions reject whole archives.
  [`pweb.assets.zip.pas:117`](../../src/assets/pweb.assets.zip.pas#L117)

- Private lock serializes the non-reentrant shared-source UnZip path.
  [`pweb.assets.zip.pas:237`](../../src/assets/pweb.assets.zip.pas#L237)

**Windows resource handler on the CAP-4W seam**

- The production request flow: re-verify URI, TryRead, 200 exact bytes or deterministic empty 404.
  [`pweb.platform.webview2.pas:272`](../../src/platform/windows/pweb.platform.webview2.pas#L272)

- Borrowed controller acquisition and checked filter/event registration.
  [`pweb.platform.webview2.pas:346`](../../src/platform/windows/pweb.platform.webview2.pas#L346)

- CAP-4W teardown ordering with apartment-affinity guard.
  [`pweb.platform.webview2.pas:407`](../../src/platform/windows/pweb.platform.webview2.pas#L407)

- Hand-transcribed pinned-SDK vtables: exact IIDs and slot order, unused slots stubbed.
  [`pweb.platform.webview2.pas:130`](../../src/platform/windows/pweb.platform.webview2.pas#L130)

**Runtime proof**

- Handler attach then navigate — the frontend loads only through IAssetStore, never SetHtml.
  [`assetsapp.pas:214`](../../examples/06-assets/assetsapp.pas#L214)

- Machine verdict gates on every page flag plus the CAP-3 worker-thread proof, latched once.
  [`assetsapp.pas:93`](../../examples/06-assets/assetsapp.pas#L93)

- The page itself proves the 404 contract: missing, non-canonical and wrong-case requests.
  [`app.js:19`](../../examples/06-assets/frontend/dist/assets/app.js#L19)

**Headless gates and CI**

- Folder/ZIP byte and ContentType parity over one generated corpus.
  [`pweb.test.assets.pas:483`](../../test/assets/pweb.test.assets.pas#L483)

- Hostile archives crafted as raw ZIP bytes, beyond what TZipWrite can express.
  [`pweb.test.assets.pas:648`](../../test/assets/pweb.test.assets.pas#L648)

- Concurrency over a file-backed archive large enough to hit the shared seekable source.
  [`pweb.test.assets.pas:881`](../../test/assets/pweb.test.assets.pas#L881)

- Layering proofs: stores compile webview-free, the handler rpc-free; zero-HTTP sweep follows.
  [`ci.yml:424`](../../.github/workflows/ci.yml#L424)

- Dual-mode hosted runtime gate under the CAP-4W conditional PASS/SKIP/FAIL policy.
  [`ci.yml:268`](../../.github/workflows/ci.yml#L268)
