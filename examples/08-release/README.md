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
