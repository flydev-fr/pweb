# CAP-12A — the blob data-plane measurement spike

**This directory is a measurement instrument, not product code.** Nothing here
is linked by a host, shipped in an artifact, or **run** by a CI gate — a run
puts a **throwaway store behind the production `pweb://app` seam**, and a gate
that does that is a gate that can normalise it. It is run by hand.

No file under `src/`, `examples/`, `tools/`, `sdk/` or `.github/` was changed by
CAP-12A, and `test/backlog/check_backlog.ps1` §5c now **enforces** that none of
them may even name this directory. What did change outside it is the ledger's
own machinery — five entries, their disposition rows, the counts in
`docs/backlog.md`, and the gate section that pins the claims on this page. The
verdict and every number it rests on are in
`_bmad-output/implementation-artifacts/cap12a-decision-artifact.md`. Read that
first; this file only says how to re-run the measurement and what the
instrument can and cannot see.

## What it measures

One instrumented window per engine loads **one page** —
`fixture/index.html` + `fixture/assets/probe.js`, shared by all three engines —
over `pweb://app`, and runs the M1–M5 rows the shard was named for:

| | question |
|---|---|
| **M1** | can the handler deliver a body in chunks the page observes before the body ends; does `text/event-stream` deliver live; does an `<img>` load from the blob prefix |
| **M2** | is a `Range` request header surfaced to the handler, and is a 206 with `Content-Range` honoured by `fetch()` and by a media element |
| **M3** | does a `fetch()` POST/PUT body reach the handler — as bytes or as a stream — for a string, an ArrayBuffer, a `Blob`, a `File` and a `FormData`, at 1 / 16 / 256 MiB |
| **M4** | what a 256 MiB body costs, how many scheme requests the engine runs and **delivers** at once, and what a slow producer does to the page's other requests and to the GUI thread |
| **M5** | answered by the artifact, from what M1–M4 measured — it is a seam decision, not a row |

Plus the **namespace** rows: `pweb://app/_pweb/blob/<id>` against a second
authority `pweb://blob/<id>`, and what the production URI parser does with a
query string.

## Why the production handler is not the instrument

The production adapters answer every request with the whole, already
materialised bytes of one `IAssetStore.TryRead`, because that is all the frozen
`TryRead` can give them. Measuring streaming through them would measure the
adapter, not the engine. So each leg carries a **spike handler** that
reproduces the production **seam** — the same borrowed native handle, the same
registration call, the same `PWebParseAppUri`, the same
`PWebNativeSecurityHeaders` on every response — and changes exactly one thing:
what it may put in the body.

What stays production, linked from `src/`: `PWebParseAppUri` and the canonical
asset-path rules, `TFolderAssetStore` behind the frozen `IAssetStore`,
`PWEB_NATIVE_CSP` and `PWebNativeSecurityHeaders`, and on Linux the platform
unit whose `initialization` masks the FPU traps GTK cannot survive.

## Files

| file | what it is |
|---|---|
| `blobsource.pas` | the throwaway store: the blob-id grammar, the deterministic body pattern, the one clock, the timeline, the RSS sampler |
| `spikegtk.pas` | the Linux/WebKitGTK spike handler — a pipe plus `g_unix_input_stream_new` is the lazy producer |
| `spikewv2.pas` | the Windows/WebView2 spike handler — a hand-written lazy `IStream` is the lazy producer |
| `blobprobe.pas` | the host: one window, two bindings, the watchdog, the JSON report |
| `fixture/` | the page, shared by every engine |
| `summarize.js` | the ONE place a measurement becomes a verdict |
| `run_cap12a.ps1` / `run_cap12a.sh` | the two runners; they differ in how they build and run, never in what a row means |
| `cap12a_probe.mm` / `run_cap12a_macos.sh` | the macOS instrument — **never compiled, never run** (below) |

## The one clock

M1 asks "did the page observe chunk 1 before the handler produced chunk 8?".
The page's clock is `performance.now()`; the handler's is the host process's.
Rather than correlate two clocks, **every page-side observation is reported
through a bound `mark()` call that the host timestamps on arrival**. A mark can
only be later than the event it reports, never earlier, so "mark(chunk 0) is
earlier than the production of chunk 7" is a sound one-clock statement — and it
is conservative in the right direction, because a host whose GUI thread the
engine is blocking delays the mark and makes `incremental` *harder* to conclude,
never easier.

Where that conservatism matters, a **second, page-side witness** decides
instead: `chunk_count` is what the page's `ReadableStream` reader actually
produced, and one delivery carrying the whole body cannot be an artefact of a
late mark.

## Running it

```powershell
# Windows: needs fpc, node, build/webview-dist/webview.dll and a WebView2 runtime
pwsh test/cap12a/run_cap12a.ps1
```

```bash
# Linux: needs fpc, node, build/cap7l/webview-dist staged, and a DISPLAY
xvfb-run -a test/cap12a/run_cap12a.sh
```

Each runner writes `build/cap12a/<target>.json` and then calls
`summarize.js`, which reads **every** target file present and prints the
table. A target whose file is absent prints `not_measured`, which is a
different thing from a failure and is never rolled into a pass.

## The macOS instrument has never been run

`cap12a_probe.mm` and `run_cap12a_macos.sh` have **not been compiled anywhere**.
The shard ran on a Windows host with WSL, which reaches WebView2 and WebKitGTK
and cannot reach WKWebView. Every macOS row in the decision artifact is
**DERIVED** — from Apple's documented `WKURLSchemeHandler` contract and from
what CAP-7M already measured in `docs/wkwebview-macos-semantics.md` — and is
marked as such. Treat the probe's first run as a debugging session, not as a
measurement.

One part of that instrument **is** verified from here: the runner extracts
`PWEB_NATIVE_CSP` out of `src/security/pweb.navigation.policy.pas` rather than
retyping it, and the extraction was checked byte for byte against the constant
the two measured legs carry at run time. (Its first version was wrong — a
Pascal literal doubles an embedded apostrophe, so a left-to-right quote scanner
produced `connect-src self` — and the script's own guard caught it. The guard
is therefore known to fire.)

## What the instrument cannot see

- **A `File` from `<input type=file>`.** The native file dialog cannot be
  driven here, so the `File` row constructs `new File([bytes], …)`. It is the
  same interface object; a picked file is backed by an OS file the engine may
  transport by descriptor, and that difference is named rather than papered
  over.
- **A process working set is not a data-plane cost.** `WorkingSetSize` and
  `statm` cannot separate what the handler allocated from pages the engine maps
  into the same process, and the figure moves between runs as the allocator
  reuses freed pages — the same whole-body row measured 251 MiB and then
  42 MiB on one machine. Every handler therefore **counts** what it had to hold
  and marks it (`*.materialised`); that is the number the artifact quotes, and
  the RSS figure is reported beside it without being attributed.
- **Video.** One `<audio>` element with a real RIFF/WAVE body carries the media
  rows. `<video>` would need a real container this spike does not generate.
