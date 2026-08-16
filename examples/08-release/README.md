# CAP-6 release runtime — MyApp.exe + app.pwb

The production release shape: one executable and one deterministic
`app.pwb` bundle beside it (plus `webview.dll`), nothing else — no loose
frontend files, no dev fallback of any kind:

`app.pwb -> bundle loader (archive gate -> manifest -> compat predicate -> index.html) -> pweb://app handler -> TZipAssetStore -> React -> SDK -> scheduler -> mORMot -> 42`

The loader runs to completion **before** `webview_create` is ever
called: the ratified compatibility predicate
(`protocol IN supported set AND SemVer(runtime) >= SemVer(minRuntime)`,
numeric, never lexicographic) gates the bundle while zero of its JS has
executed. A missing, tampered or incompatible `app.pwb` prints a typed
refusal marker on stderr — `releaseapp: app.pwb REFUSED (<category>)` —
and exits nonzero with no WebView created. The bundle is located beside
the executable, never the current directory.

Build the bundle from the CAP-5 React dist with the CAP-6 bundler
(`tools/bundler/`, see its README for the manifest schema), then the
host inside the CAP-3U window (`test/cap6/build_cap6.ps1` does both
compiles):

```powershell
pwsh test/cap6/build_cap6.ps1
build/cap6/bin/pwebbundle.exe examples/04-react/frontend/dist build/cap6/app.pwb
```

Assemble the release directory (exe + `app.pwb` + `webview.dll` only)
and run — `test/cap6/run_cap6_gates.ps1` performs the assembly plus all
headless refusal gates, and `test/cap6/run_cap6_smoke.ps1` the hosted
run:

```powershell
$env:PWEB_SMOKE_AUTOCLOSE_MS = '8000'
.\releaseapp.exe        # no arguments: app.pwb sits beside the exe
```

Expected: the window renders `CalculatorService.Add(20, 22) = 42` and
the log ends with
`releaseapp: app.pwb -> pweb://app -> SDK -> mORMot -> 42 PASS`.
Delete `app.pwb` and run again: exit nonzero with
`releaseapp: app.pwb REFUSED (bundle file missing)` and no window.

The backend is line-identical to the CAP-5 hosts apart from the bundle
loading, window title and log prefix — no backend code branches on
frontend kind, and this host imports no folder store at all.

## macOS (CAP-7M2)

The SAME release host ships as two `.app` products per architecture —
`PWebReleaseReact.app` (`dev.pweb.release.react`) and
`PWebReleasePas2js.app` (`dev.pweb.release.pas2js`) — differing only in
`app.pwb` and Info.plist identity: `releaseapp` and
`libwebview.0.12.dylib` are byte-identical across both, which is the
hash-proven form of "no frontend-kind branch". Two identifiers because
WebKit keys persistent state by bundle identifier, so per-frontend state
stays disjoint. Inside a bundle the layout is exactly:

```
Contents/Info.plist
Contents/MacOS/releaseapp
Contents/MacOS/libwebview.0.12.dylib      @rpath + @executable_path
Contents/Resources/app.pwb                <exedir>/../Resources, never CWD
Contents/Resources/LICENSE.webview
```

The Cocoa platform seam is two-phase (the handler is constructed BEFORE
`webview_create` and `Attach`-proven just after — upstream builds the
WKWebViewConfiguration inside `webview_create`), and the pre-create
check is the FPU-trap gate over `PWebCocoaFpuTrapsMasked`.
`test/cap7m/build_cap7m_release.sh` compiles host and bundler;
`test/cap7m/run_cap7m_release.sh` assembles, gates and runs both
products (direct and via LaunchServices) on both architectures.

## Optional arguments (all platforms)

`releaseapp [--pweb-verdict=<file>] [--pweb-autoclose-ms=<N>]`

- `--pweb-verdict=<file>` — write the canonical PASS/FAIL verdict line
  to `<file>` atomically (temp + rename) on every exit path. This exists
  because `open -W` on macOS forwards neither stdout nor the exit code
  and LaunchServices does not inherit the caller's environment, so a
  file path passed in argv is the only deterministic evidence channel
  for a LaunchServices launch.
- `--pweb-autoclose-ms=<N>` — auto-close bound; the argument wins over
  the `PWEB_SMOKE_AUTOCLOSE_MS` environment variable.

Unknown arguments are refused with a nonzero exit, exactly as the old
no-arguments rule refused everything.
