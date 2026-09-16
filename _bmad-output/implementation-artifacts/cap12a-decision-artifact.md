# CAP-12A — the blob data plane: measured, then decided

```
CAP-12A DECISION READY
two engines measured on this host, the third derived and named
no product file changed; the ledger's own machinery did, and section 8 says so
```

**The question this shard was named for.** `pweb://app` today serves whole,
in-memory, synchronous responses from a sealed bundle. A data plane needs, per
engine, answers to five things — and *a data plane the four engines cannot all
deliver is a data plane the product cannot promise.* CAP-12A measures those
five things and decides the plane from the answers rather than from the design
note.

**The headline, in one paragraph.** The measurements refuse the plane the SPEC
sketched and hand back a different one that every engine can actually deliver.
Response **streaming to the page does not exist on WebView2** — it drains the
handler's stream incrementally and then hands the page the entire body in a
single reader delivery — so a streaming data plane is unbuildable as a promise.
**Range is universal**: the request header reaches the handler and a
206 + `Content-Range` is honoured on both measured engines, with the same
already-measured mechanism available on WKWebView. So **the data plane is
Range-based, not streaming-based** — and that one substitution also spares the
ledgered `WKURLSchemeTask` race surface, because a bounded ranged window is a
whole body and the macOS handler may stay synchronous.

---

## 0. COVERAGE, STATED BEFORE THE CONCLUSIONS

| engine | state | how |
|---|---|---|
| **Windows x64 / WebView2** | **MEASURED** | `test/cap12a/run_cap12a.ps1` on this host; WebView2 Evergreen, `webview.dll` at the pinned commit |
| **Linux x64 / WebKitGTK 4.1** | **MEASURED** | `test/cap12a/run_cap12a.sh` under WSL + `xvfb-run`; WebKitGTK **2.52.6**, GTK 3.24.41, FPC 3.2.3 |
| **macOS x64 / WKWebView** | **DERIVED** | no Mac on this host. `test/cap12a/cap12a_probe.mm` is the instrument and **has never been compiled** |
| **macOS arm64 / WKWebView** | **DERIVED** | as above; the two macOS targets differ by ABI, not by engine semantics |

Every macOS row below is typed `DERIVED` and names what it is derived **from**
— Apple's documented `WKURLSchemeHandler` contract, or a fact CAP-7M already
MEASURED and recorded in `docs/wkwebview-macos-semantics.md`. None of them is
allowed to widen the guaranteed surface: §4 defines that surface from the
measured engines only, and §6 makes confirming the macOS rows an entry
condition for CAP-12B rather than a closing formality.

**The instrument.** One page — `test/cap12a/fixture/` — over `pweb://app`,
through the production seam, with a throwaway store behind it. What stays
production and unchanged: `PWebParseAppUri` and the canonical asset-path rules,
`TFolderAssetStore` behind the frozen `IAssetStore`, `PWEB_NATIVE_CSP` and
`PWebNativeSecurityHeaders` on **every** response. What is the spike: a
per-engine handler that reproduces the production seam and changes exactly one
thing — what it may put in the body — because the production adapter can only
ever hand over the finished bytes of one `TryRead`, and measuring streaming
through it would measure the adapter. `test/cap12a/README.md` sets this out in
full, including the three things the instrument cannot see.

**The clock.** Every page-side observation is reported through a bound `mark()`
the host timestamps on arrival, so a "before" comparison is a one-clock
statement. A mark can only be *later* than the event it reports, which makes
`incremental` harder to conclude and never easier — and where an engine blocks
the host's GUI thread, a second page-side witness (`chunk_count`, what the
reader actually produced) decides instead.

---

## 1. MEASUREMENTS PER ENGINE

### M1 — streamed responses

| row | WebView2 | WebKitGTK 2.52.6 | WKWebView |
|---|---|---|---|
| `fetch()` body as a `ReadableStream` | present | present | **DERIVED** present |
| 2 MiB in 8 chunks, 80 ms apart, **declared length** | **`buffered_whole`** — 1 reader delivery of 2 097 152 bytes; `fetch()` itself did not resolve for **583 ms**, after the last chunk was produced | **`incremental`** — 138 reader deliveries; the page reported chunk 0 **604 ms before the last chunk was produced**; `fetch()` resolved in **1 ms** | **DERIVED** incremental: `didReceiveData:` may be sent repeatedly after `startURLSchemeTask:` returns |
| the same body with **no declared length** | **`buffered_whole`**, identical | **`incremental`**, identical | **DERIVED** as above |
| what the engine did at the handler | pulled the lazy `IStream` **incrementally**: 64 `Read` calls of 32 768 bytes, 7 of them waiting on the producer, and 1 `Seek` | pulled the pipe as the page read it | **DERIVED**: the handler pushes; there is no pull |
| **the thread the engine pulls on** | **the host's GUI thread** (`istream_read_threads: "gui,"`) | a WebKit thread; the GUI thread is free | **DERIVED**: the main thread, and today synchronously |
| `EventSource` over `pweb://app` | **`buffered_whole`** — six events at a 150 ms producer interval arrived **within 0.1 ms of each other**, 763 ms in | **`live`** — six events spread over **747 ms**, matching the producer | **DERIVED** live |
| `<img>` from the reserved prefix | **decoded** (1×1 PNG, 0.7 ms) | **decoded** (1 ms) | **DERIVED** decoded |

**The WebView2 result is two facts, not one, and only the second one matters
to a data plane.** The engine *does* read a response `IStream` lazily and
honours a slow producer — that is measured at the handler. It then withholds
the response from the page until the body is complete. The page-side witness is
unambiguous and cannot be an artefact of the instrument's clock: the
`ReadableStream` reader produced **one** chunk carrying the whole 2 MiB, and
`fetch()` resolved only after 583 ms of a 640 ms production. There is no
mechanism in `WebResourceRequested` to do better: the response body is an
`IStream` and `put_Response` is the only delivery.

### M2 — Range

| row | WebView2 | WebKitGTK | WKWebView |
|---|---|---|---|
| `Range` request header surfaced to the handler | **yes**, 9 requests, values `bytes=1000-1099`, `bytes=-128`, `bytes=0-99`, `bytes=0-`, `bytes=458752-` | **yes**, 6 requests, values `bytes=1000-1099`, `bytes=-128`, `bytes=0-99`, `bytes=0-1445` | **DERIVED** yes, `[[task request] allHTTPHeaderFields]` |
| 206 + `Content-Range` + `Accept-Ranges` read back by `fetch()` | **honoured** — status 206, `bytes 1000-1099/1048576`, 100 bytes, and the **offset** verified against the deterministic pattern | **honoured**, identical | **DERIVED** honoured — CAP-7M MEASURED that `NSHTTPURLResponse` is what gives JavaScript a status at all, and 206 has nowhere to live on a bare `NSURLResponse` |
| suffix range `bytes=-128` | **honoured**, `bytes 1048448-1048575/1048576` | **honoured**, identical | **DERIVED** honoured |
| the handler answering **200** to a Range request | accepted; the page got the whole body | accepted | **DERIVED** accepted |
| `<audio>` on a 60 s RIFF/WAVE body | **played and seeked** — `duration = 60`, `currentTime = 55`, and the engine issued **two** ranged requests: `bytes=0-` then `bytes=458752-` | **refused** — `MEDIA_ERR_SRC_NOT_SUPPORTED`, for `audio/wav` and `audio/x-wav`, for a 206 and for a whole 200 alike | **DERIVED** plays |

**Range is the universal capability**, and it is the one the decision is built
on. Both measured engines surface the header, both honour 206 with a correct
`Content-Range`, and the window is checked for **offset** rather than length —
a handler that answered with the first N bytes instead of the requested window
would fail here and pass a length-only check.

**The WebKitGTK media refusal is an engine finding, not an environment one,
and the evidence says which.** The engine claims the type (`canPlayType`
returns `maybe` for both `audio/wav` and `audio/x-wav`), the host has a
complete GStreamer WAV path installed (`libgstwavparse`, `libgsttypefindfunctions`,
`libgstaudioconvert`, `libgstplayback`), and the failure arrives **9 ms after
the element's `setPreload`, before any pipeline or sink exists**:

```
webkitmediaplayer MediaPlayerPrivateGStreamer.cpp:905:setPreload: Setting preload to MetaData
webkitmediaplayer MediaPlayerPrivateGStreamer.cpp:1554:loadingFailed: Loading failed, error: FormatError
```

No `webkitwebsrc` line is ever logged: the source element is never created. A
missing audio sink — and this host genuinely has none — could not produce a
failure *before* pipeline construction. The `bytes=0-1445` request the handler
did see comes from the resource layer's own probe, not from the media pipeline.

### M3 — request bodies

Sizes and body kinds are varied **separately**, because the first arrangement
of these rows varied both at once and produced four failures that could be read
either way.

| row | WebView2 | WebKitGTK | WKWebView |
|---|---|---|---|
| `POST` ArrayBuffer, 1 MiB | **1 048 576 received, pattern verified**, 10 ms | **1 048 576, verified**, 6 ms | **DERIVED** received |
| `POST` ArrayBuffer, **16 MiB** | **16 777 216, verified**, 130 ms | **16 777 216, verified**, 78 ms | **DERIVED** received |
| `POST` ArrayBuffer, **256 MiB** | **268 435 456, verified**, 2 557 ms | **268 435 456, verified**, 1 107 ms | **DERIVED**, and the size at which `HTTPBody` vs `HTTPBodyStream` stops being academic |
| `POST` string, 1 MiB | 1 048 576 received | 1 048 576 received | **DERIVED** received |
| `PUT` ArrayBuffer, 1 MiB | **received**; `PUT` reaches the handler | **received** | **DERIVED** received |
| `POST` **`Blob`**, 1 MiB | **received, verified** | **the UI process faults** | **DERIVED unknown** |
| `POST` **`File`**, 1 MiB | **received, verified** | **the UI process faults** | **DERIVED unknown** |
| `POST` **`FormData`**, 1 MiB | **received** — 1 048 871 bytes, the multipart envelope over the 1 MiB part | **the UI process faults** | **DERIVED unknown** |
| how the body arrives | `ICoreWebView2WebResourceRequest.get_Content` → `IStream` | `webkit_uri_scheme_request_get_http_body` → `GInputStream` | **UNMEASURED** — `HTTPBody` *or* `HTTPBodyStream`, and which one WebKit populates for a blob-backed body is precisely the row CAP-7M never had to ask |

**`webkit_uri_scheme_request_get_http_body()` segfaults WebKitGTK 2.52.6 for
any blob-backed request body.** It is a crash inside the library, not an
artefact of the Pascal binding, and the backtrace says so — the public entry
point is frame #4 and the fault is three frames deeper inside WebKit, with the
spike's own code at frame #5 doing nothing but the call:

```
Thread 1 "blobprobe" received signal SIGSEGV, Segmentation fault.
0x00007ffff5553e5e in ?? () from /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0
#0  0x00007ffff5553e5e in ??? () at /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0
#1  0x00007ffff5888d7e in ??? () at /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0
#2  0x00007ffff589dc77 in ??? () at /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0
#3  0x00007ffff58d1278 in ??? () at /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0
#4  0x00007ffff330941d in webkit_uri_scheme_request_get_http_body () at /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0
#5  0x00000000004ec7af in ??? ()
```

An `ArrayBuffer` or string body of the **same size** goes through the same call
and returns a working stream, so it is the body **kind** and not the size. This
is an `UPSTREAM` candidate; §7 records it as one.

### M4 — memory and concurrency

| row | WebView2 | WebKitGTK | WKWebView |
|---|---|---|---|
| **bytes the handler had to hold** to serve 256 MiB **whole** | **512 MiB** — the Pascal string plus the copy `SHCreateMemStream` takes | **512 MiB** — the Pascal string plus the copy GIO's input stream owns | **DERIVED** 2× — `NSData` plus the source buffer, unless `dataWithBytesNoCopy:` is used (CAP-7M MEASURED that WebKit copies at handoff on that OS/toolchain) |
| **bytes the handler had to hold** to serve 256 MiB **streamed** | **0** — the lazy `IStream` fills the engine's own `Read` buffer | **1 MiB** — one producer chunk buffer | **DERIVED** one chunk |
| process working set, 256 MiB whole | +2 048 MiB | +243 MiB (one run), +469 MiB (another) | — |
| process working set, 256 MiB streamed | +2 048 MiB | +1 MiB | — |
| 1 / 8 / 64 simultaneous scheme requests: **all responded before any body ended** | 1 / 8 / 64 | 1 / 8 / 64 | **DERIVED**: today's synchronous handler cannot have two tasks live at once |
| how the engine **delivers** those bodies | **strictly serial** — with 8 concurrent bodies the drain switched owner exactly **8 times**, one block per body, EOFs 1.7 ms apart, all on the GUI thread | **interleaved** — 8 bodies, **32** owner switches (round-robin, four passes); 64 bodies, **256** switches | **DERIVED** serial |
| an unrelated 23 KB asset requested while a 4 s producer is mid-body | the handler was **reached at +303 ms** and answered in 420 µs; **the page received it at +3 621 ms** | handler reached at +296 ms; **the page received it at +9 ms** | **DERIVED**: the synchronous handler cannot be entered at all while it is serving |
| the page's own 20 ms timer during that row | max gap **21 ms** | max gap **25 ms** | — |

Two things follow, and both are decisions rather than curiosities.

**A process working set is not a data-plane cost, so it is reported and not
attributed.** `WorkingSetSize` and `statm` cannot separate what the handler
allocated from pages the engine maps into the same process, and the figure
moves between runs as the allocator reuses freed pages — the same whole-body
row measured 251 MiB and then 42 MiB on one machine. Every handler therefore
**counts** what it had to hold; that is the 512 MiB / 0 / 1 MiB row above, it
is identical on both engines, and it is the number `IBlobStore` controls.

**WebView2 serialises body delivery on the host's GUI thread.** It accepts 64
concurrent requests and then drains their bodies one after another, which is
why an ordinary asset — answered by the handler in 420 µs — did not reach the
page for 3.6 seconds. The page's JavaScript is unaffected (the renderer is a
different process; the timer kept its 20 ms cadence), so this is not a frozen
UI, it is a **stalled resource plane**. The stall is the preceding body's whole
production-plus-drain time, which is why §5 bounds the window a single response
may carry.

### M5 — the seam

`IAssetStore.TryRead(const Path: RawUtf8; out Asset: TAssetResponse): Boolean`
is frozen verbatim, and `TAssetResponse` is `Content: RawByteString` +
`ContentType: RawUtf8`. Measured against what the plane needs:

| what a ranged, bodied exchange needs | can the frozen seam give it? |
|---|---|
| the size of a resource **without materialising it** (for `Content-Length` and for a 206's `/total`) | **no** — `TryRead` has no size, HEAD or probe form. This is ledger `9B1-6` verbatim: bounds are checked *after* the carrier has already materialised the asset |
| a **window** of a resource | **no** — `TryRead` returns whole `Content` and nothing else |
| the **request**: method, headers, body | **no** — `TryRead` takes a path and nothing else |
| a content type that is not derived from the path extension | **no** — and measured: `PWebAssetMimeType`'s table carries **no audio or video type at all**, so `.wav`, `.mp4` and `.mp3` all resolve to `application/octet-stream` |
| serving a 256 MiB resource without holding 512 MiB | **no** — measured, identically, on both engines |

**The seam decision is additive, and nothing frozen moves.** `IAssetStore` and
`TAssetResponse` are untouched; the blob plane is a **second interface beside
the seven**, which is exactly what Phase 0 froze it as. `IBlobStore` is already
one of the seven boundaries; only its concrete method sets were deferred, "to
ratify at Phase 4b entry, before any blob implementation is written", and this
document is that entry. §5 ratifies them.

The handler seam changes shape, additively: today it is
`PWebParseAppUri → IAssetStore.TryRead → 200 + whole bytes`, and it becomes
`PWebParseAppUri → is this the reserved prefix? → IBlobStore : IAssetStore`,
with the reserved branch reading the request's method, `Range` header and body.
No existing branch changes behaviour.

---

## 2. NAMESPACE

### The decision

```
pweb://app/_pweb/blob/<token>          token = [0-9a-f]{32}
```

**not** `pweb://blob/<token>`, and the CSP is why.

### Why the second authority is impossible, measured

`PWEB_NATIVE_CSP` carries `connect-src 'self'`, `img-src 'self' data:` and
`media-src 'self'`. An origin is scheme + host + port, so `pweb://blob` is a
**different origin** from `pweb://app` and every one of those directives
refuses it. The measurement is not an inference:

| | WebView2 | WebKitGTK |
|---|---|---|
| `fetch('pweb://app/_pweb/blob/…')` | **served**, 1024 bytes, pattern verified | **served**, identical |
| `fetch('pweb://blob/…')` | **refused**, `TypeError: Failed to fetch` | **refused**, `TypeError: Load failed` |
| what refused it | `securitypolicyviolation` — `violatedDirective: connect-src`, `disposition: enforce` | the same event, `blockedURI: pweb://blob/whole-1024` |
| **did the handler ever see the request?** | **no** — and the Windows leg registered a deliberate `pweb://blob/*` `WebResourceRequested` filter so that it *would* have | **no** — and on this engine a `pweb` scheme is registered **context-wide**, so a second authority really does arrive at the callback |

Both legs report `second_authority_requests: 0` with a path that would have
counted one. That is a discriminating negative, not an absence nobody looked
for.

**The CSP does not move. It is the premise, not a variable** — CAP-15A ratified
it and measures it byte-identical on every leg. So the data plane lives inside
the privileged origin or it does not exist.

### What this supersedes, and what it does not

`docs/kernel.md` states the invariant as *"JSON is the control plane,
`pweb://blob` the data plane"*, and `_bmad-output/specs/spec-pweb/.memlog.md`
sketches `pweb://blob/{token}`. **The invariant survives; its spelling does
not.** The same sources decouple the boundary from the URL explicitly —
*"`IBlobStore` is decoupled from the URI scheme … a separate
`TWebViewBlobProtocol` translates `pweb://blob/{handle}` onto the store"* — so
the URL was always the translator's concern and never part of a frozen
signature. `pweb://blob` was written before CAP-8B ratified the native CSP;
CAP-15A then measured `connect-src 'self'` as load-bearing and refused to
weaken it. Correcting the spelling in `docs/kernel.md` is **CAP-12B's**, listed
in §6; CAP-12A changes no file outside `test/cap12a/`.

### The grammar, and why each part of it

| rule | why |
|---|---|
| reserved first segment **`_pweb`**, not `_pweb/blob` alone | later runtime-owned URL space gets room without a second reservation |
| `_pweb/blob/<token>`, exactly three segments | a fixed shape is checkable in one comparison before any store is consulted |
| `<token>` is **32 lowercase hex characters** | the frozen invariant is "≥ 128-bit handle entropy"; 32 hex digits is exactly 128 bits, fixed length, one segment, and it survives every canonical-path rule without an escape |
| total logical path **43 bytes** | against `PWEB_ASSET_PATH_MAX_BYTES = 2048` and the 255-byte segment ceiling, with room to spare |
| **no parameter may ride in a query string** | MEASURED: `PWebParseAppUri` cuts `?` and `#` before decoding, and `pweb://app/_pweb/blob/whole-1024?range=1` returned the *same resource* on both engines. Anything the plane needs per request travels in a **header** (`Range`) or in the token |

**The reservation is enforced twice, and neither place is sufficient alone.**

1. **At serve time.** The handler tests the reserved prefix **before** it
   consults `IAssetStore`. A bundle that somehow carried `_pweb/...` is
   unreachable rather than merely unlikely.
2. **At pack time.** `pwebbundle` refuses any logical path whose first segment
   is `_pweb`, with a typed cause naming the file — walk-time policy owned by
   the CLI, in the exact shape CAP-14A's refusal already has, and with no
   override, because the serve-time branch will not serve it anyway.

**The CAP-14A tokenizer is not the enforcement point, and saying so is part of
the answer.** That scanner decides which HTML *constructs* the native CSP would
refuse to execute — inline `<script>`, `on*=`, `javascript:`, a cross-origin
`src`. A bundle whose `index.html` referenced `pweb://app/_pweb/blob/…` in a
`src` is a same-origin relative reference the scanner accepts and should
accept. The path reservation is a **path** rule and belongs in the pack-time
walk beside the sourcemap exclusion, not in the HTML tokenizer.

---

## 3. SEAM DECISION

**`IBlobStore` is an additive second interface beside the seven frozen
boundaries. No frozen signature moves.** Specifically:

- `IAssetStore.TryRead` — **unchanged**, verbatim.
- `TAssetResponse` — **unchanged**. Its evolution rule permits additive growth,
  and this shard does not use it: nothing about the blob plane belongs in the
  response record of the *asset* plane.
- `IBlobStore` — its **method sets ratify here**, which is the Phase-4b-entry
  ratification the SPEC requires "before any blob implementation is written".
- `IBlobReader` / `IBlobWriter` — likewise.

A change to a frozen interface was tested against the standard "refused unless
measured impossible otherwise" and is **not needed**: everything the plane
requires is reachable through a second interface plus a branch in the handler
that runs before the asset store is consulted. The one measured deficiency of
the frozen seam that a *later* shard may still want to fix — `9B1-6`, that
module and manifest bounds are checked after the carrier has materialised the
asset — is **not** fixed by CAP-12B and stays on the ledger, because the blob
plane routes around it rather than through it.

---

## 4. GUARANTEED VERSUS OPTIONAL SURFACE

**The guaranteed surface is what the measured engines deliver and the derived
engine is expected to deliver, with every derived row required to be confirmed
before CAP-12B ships (§6).** Nothing derived widens it.

### Guaranteed — the product may promise these

| capability | evidence |
|---|---|
| a blob served **whole** by URL from `pweb://app/_pweb/blob/<token>`, correct bytes, correct content type | measured on both engines; offset-verified against a deterministic pattern |
| a **single-range** `Range` request reaching the handler, answered **206** with `Content-Range` and `Accept-Ranges: bytes`, read back correctly by `fetch()` | measured on both engines, for `a-b` and for `-suffix` |
| the handler answering **200** to a Range request it chooses not to honour | measured on both engines |
| an **`<img>`** whose `src` is a blob URL | measured on both engines |
| a **request body** carried to the handler as **bytes or a stream**, for a **string** or an **`ArrayBuffer`/typed array**, at **1, 16 and 256 MiB**, over **POST and PUT** | measured on both engines, byte-exact and pattern-verified |
| the **query string is not a channel** | measured on both engines |
| a second authority is **refused by the CSP before any request exists** | measured on both engines, with a path that would have counted one |

### Per-engine optional — typed, never assumed

| capability | WebView2 | WebKitGTK | what a consumer must do |
|---|---|---|---|
| **response streaming to the page** | **no** | yes | never depend on it; there is no negotiation and no feature test worth having, so the plane must not offer it at all |
| **`EventSource` live** | **no** | yes | §6 refuses the 12C consumer that wanted it |
| **media element** (`<audio>`/`<video>`) from a blob URL | yes, with engine-issued ranged requests | **no** | a typed capability the SDK reports; a page must have a fallback |
| **`Blob`/`File`/`FormData` as a request body** | yes | **faults the UI process** | the SDK must never produce one; §6 makes upload read into `ArrayBuffer` windows |
| **concurrent body delivery** | **no**, strictly serial on the GUI thread | yes | the plane bounds the window a single response carries (§5) so that serial delivery stays cheap |

**The shape of the decision.** Four of the five optional rows are optional
because **WebView2** cannot do them, and WebView2 is not a target the product
may drop. The fifth — media — is optional because WebKitGTK cannot. There is no
subset of engines for which a richer promise is safe.

---

## 5. THE CONTRACT — `IBlobStore`, ownership and bounds

### 5.1 The method sets (the Phase-4b-entry ratification)

No URI scheme, no WebView transport, no filesystem path, no platform stream
type, and no mORMot type beyond the `RawUtf8`/`RawByteString` aliases
`IAssetStore` already carries on record.

```pascal
{ What a reader can say about a blob without materialising it. The `Size`
  field is the whole reason this record exists: a 206 cannot be written
  without a total, and the frozen TryRead has no way to report one. }
TBlobInfo = record
  Size: Int64;
  ContentType: RawUtf8;
  Owner: RawUtf8;      // the principal id that created it
  Sealed: Boolean;     // no further Append is accepted
end;

IBlobReader = interface
  ['{...}']
  function Info(out Blob: TBlobInfo): Boolean;
  { POSITIONED READ - the frozen invariant, and now also the measured
    requirement: the guaranteed surface is ranged, so a window read into a
    caller-owned buffer is the ONLY read the plane needs. Returns the byte
    count, 0 at or past the end, -1 on failure. Never raises. }
  function ReadAt(Offset: Int64; Buffer: Pointer; Count: Integer): Integer;
end;

IBlobWriter = interface
  ['{...}']
  function Append(Buffer: Pointer; Count: Integer): Boolean;
  function Seal(const ContentType: RawUtf8; out Token: RawUtf8): Boolean;
  procedure Abandon;
end;

IBlobStore = interface
  ['{...}']
  function CreateBlob(const Owner: RawUtf8; SizeHint: Int64;
    out Writer: IBlobWriter): Boolean;
  { Owner-scoped by CONSTRUCTION, not by a check the caller may forget: a
    foreign principal's token is answered exactly as an unknown token is. }
  function OpenBlob(const Owner: RawUtf8; const Token: RawUtf8;
    out Reader: IBlobReader): Boolean;
  function Release(const Owner: RawUtf8; const Token: RawUtf8): Boolean;
  function ReleaseOwner(const Owner: RawUtf8): Integer;
  function Stats(out Count: Integer; out Bytes: Int64): Boolean;
end;
```

Three properties of that shape are measured rather than chosen:

- **`Info` before any bytes.** Both engines need a total for `Content-Range`
  and a length for `Content-Length`; the frozen `TryRead` cannot give one
  without materialising, and materialising was measured at **2× the body**.
- **`ReadAt` into a caller buffer, not a returned string.** The 512 MiB figure
  for a 256 MiB body is the *seam's* doubling — the Pascal string and then the
  engine's copy — and a returned `RawByteString` reproduces it for every
  window.
- **No stream type anywhere.** The three engines want three different things
  (`IStream`, `GInputStream`, `NSData`), and the plane is ranged, so the
  boundary never has to name one.

### 5.2 Ownership and lifetime

- **A blob belongs to the principal that created it.** Another principal's
  token is answered exactly as an unknown token is, with no store lookup
  distinguishable from the outside — the CAP-8C multi-principal rule, and the
  same shape CAP-15C gives a foreign socket id.
- **Bounded count and bytes**, per principal and in total. The refusal is a
  typed `service_error` category, never native text. The numbers are CAP-12B's
  to set from its own store, but the *shape* is fixed here: a ceiling on
  count, a ceiling on bytes, both per principal and in total, and a refusal
  that names which ceiling it hit.
- **Freed in the CAP-9 order**, which CAP-15C already spells for sockets and
  which blobs join unchanged: every blob of a window is released when its
  document is replaced — a navigation, a reload, and a development
  **generation switch**; every blob is released on host shutdown **before** the
  binding closes and the scheduler drains; revoking the governing capability
  releases every affected blob before the revoking call returns.
- **Logical release with reader refcounting.** `Release` makes the token
  unresolvable immediately; the bytes go when the last `IBlobReader` does. A
  scheme task mid-window therefore cannot read freed memory, and the handler is
  **detached before the store is released** so that no task can start after it.

### 5.3 Bounds, with the arithmetic

| bound | value | why this number |
|---|---|---|
| **window a single response may carry** | **8 MiB** | MEASURED: WebView2 delivers response bodies **serially on the host GUI thread**, so a body's production-plus-drain time is a stall for every other `pweb://app` response. A 256 MiB whole body took **1 434 ms** page-side on that engine; at 8 MiB the same rate gives **~45 ms**. It is also the CAP-15B response ceiling, so the two doors carry one number |
| **transient cost of serving one window** | **2× the window = 16 MiB** | MEASURED identically on both engines: the handler holds the window and the engine takes a copy |
| **upload chunk the SDK may put in one request** | **8 MiB** | the same ceiling from the other direction; and a 256 MiB single-request upload was measured at 2 557 ms on WebView2, which is 2.5 s of serialised resource plane |
| **token entropy** | 128 bits | the frozen invariant, spelled as 32 hex characters |

---

## 6. THE CONTRACT FOR CAP-12B AND CAP-12C

### 6.1 What CAP-12B builds

1. **`IBlobStore`/`IBlobReader`/`IBlobWriter`** exactly as §5.1 ratifies, in a
   new unit beside the asset units, naming no URI scheme.
2. **The reserved branch in all three platform handlers**, before the asset
   store: parse, test the `_pweb/` prefix, and on a match go to the blob
   protocol translator. Every existing branch keeps its current behaviour, and
   the existing gates must measure that it did.
3. **The blob protocol translator** — one unit that maps
   `pweb://app/_pweb/blob/<token>` and a `Range` header onto `IBlobStore`, and
   is the only thing in the tree that knows both spellings.
4. **`Range` on all three engines**: `ICoreWebView2HttpRequestHeaders.GetHeader`
   on Windows, `webkit_uri_scheme_request_get_http_headers` +
   `soup_message_headers_get_one` on Linux, `[[task request]
   allHTTPHeaderFields]` on macOS; 206 with `Content-Range`, `Accept-Ranges`
   and `Content-Length` on every one.
5. **Upload**, as **bytes only**: the request body is read through
   `get_Content` (Windows), `webkit_uri_scheme_request_get_http_body` (Linux,
   **only for non-blob-backed bodies** — see 6.3) and `HTTPBody`/
   `HTTPBodyStream` (macOS).
6. **The pack-time reservation** in `pwebbundle`: a logical path whose first
   segment is `_pweb` is refused with a typed cause naming the file, in the
   CAP-14A shape, with no override.
7. **The documentation correction**: `docs/kernel.md`'s invariant is re-worded
   from `pweb://blob` to the reserved prefix under `pweb://app`, citing this
   artifact. The invariant itself does not change.
8. **A content type that is not derived from the path.** MEASURED: the frozen
   MIME table carries no audio or video type at all, so a blob's type comes
   from `TBlobInfo.ContentType` and never from `PWebAssetMimeType`. The asset
   plane's table is not extended by CAP-12B — that is a separate decision about
   what an `app.pwb` may contain.

### 6.2 Which consumers 12B and 12C wire

| consumer | verdict | why |
|---|---|---|
| **`pweb.fetch` large responses → blob** | **WIRED, and it is the headline** | it needs only the guaranteed surface. CAP-15B's `response_too_large_to_inline` — a typed refusal between the 1 MiB inline cap and the 8 MiB ceiling — becomes a `BlobHandle` in a success envelope, and the page reads it by URL. `truncated` still never means "some of the body is here" |
| **images by URL** | **WIRED** | measured on both engines |
| **upload, page → native** | **WIRED, as `ArrayBuffer` windows** | and **never** as a `Blob`, a `File` or a `FormData`: those fault WebKitGTK. The SDK's `native.blobs.create(file)` reads the `File` with `slice()` + `arrayBuffer()` and PUTs 8 MiB windows. This is the measurement the SPEC deliberately waited for before freezing the JS→native transport, and it answers it: **`fetch(PUT pweb://…)` is ratified as the transport, with a typed-array body and nothing else** |
| **`pweb.socket` receive → `EventSource` stream** | **REFUSED, by measurement** | WebView2 buffers `text/event-stream` entirely: six events produced 150 ms apart arrived **within 0.1 ms of each other**, 763 ms after the request. CAP-15C's *"when CAP-12 brings streaming, the receive loop is the only thing that changes"* cannot be kept this way. **CAP-12C keeps the bounded long-poll.** The SDK surface, the four method names and the decorator are unaffected — which is the part of that promise that does hold |
| **media by URL** (`<audio>`/`<video>`) | **NOT PROMISED** | WebKitGTK refuses it outright. If CAP-12C exposes it at all it is a typed, per-engine capability the page must be able to do without |

### 6.3 The three entry conditions for CAP-12B

CAP-12B **must not begin** until these are settled, because each one can move
the guaranteed surface:

1. **The four macOS rows are measured**, not derived: that `Range` reaches the
   handler through `allHTTPHeaderFields`; that a 206 with `Content-Range` on an
   `NSHTTPURLResponse` is read back by `fetch()`; **which of `HTTPBody` and
   `HTTPBodyStream` carries a typed-array body**, at 1, 16 and 256 MiB; and
   that a whole body served synchronously still behaves at 8 MiB.
   `test/cap12a/cap12a_probe.mm` is the instrument and has never been
   compiled — its first run is a debugging session.
2. **The WebKitGTK upload fault is confirmed against the CI baseline**, not
   only against this host's 2.52.6. If the hosted Linux runner's WebKitGTK does
   not fault, the finding narrows to a version range; if it does, CAP-12B ships
   the workaround in 6.2 and the `UPSTREAM` report of §7 is posted.
3. **The 8 MiB window is re-measured against a real store**, not a synthetic
   producer: the serial-drain stall is proportional to production *plus* drain,
   and a store reading from a file has a different production cost from one
   filling a pattern.

### 6.4 What CAP-12B must not touch

- `webview.lock`, `mormot.lock` or any pin; `src/lib/` and `webview.chet`; the
  seven interface signatures **other than** ratifying `IBlobStore`'s method
  sets; `pweb.rpc.intf.pas`'s independence from every `pweb.webview.*` unit.
- **`PWEB_NATIVE_CSP`.** It does not move. It is the reason the namespace is
  what it is.
- The watcher; the licence set; `test/cap12a/` as a CI step.
- The nine-code error taxonomy and `PWEB_PROTOCOL_VERSION = 1`.

### 6.5 What the macOS synchronous handler must become — **almost nothing**

CAP-12 was named as the shard that would reopen the ledgered constraint that
*"every request is resolved and completed inside `startURLSchemeTask:` on the
main thread"*, and ledger `7M1-5` says so directly: *"a 206 response with
`Content-Range` over a large body needs chunked or deferred delivery, at which
point `stopURLSchemeTask:` really can interleave and the claim-once guards
become load-bearing."*

**The Range-based plane does not reopen it.** A bounded ranged window **is** a
whole body: it is produced, handed over and completed inside
`startURLSchemeTask:` exactly as an asset is today. What macOS gains is
additive and small — read `allHTTPHeaderFields` for `Range`, answer 206 with
`Content-Range` on the `NSHTTPURLResponse` the adapter already builds, and read
`HTTPBody`/`HTTPBodyStream` for an upload. The tracked-task set stays empty
between calls, `stop_arrivals` stays 0 and keeps being printed as the explicit
limitation it is, and the claim-once machinery stays built, gated and — exactly
as documented — never exercised by an interleaving this handler cannot produce.

**What it would have cost** is on record, because the alternative was priced
rather than waved away. Live streaming on macOS means `didReceiveData:` from a
`dispatch_after` chain after `startURLSchemeTask:` has returned, at which point:
a stop really can interleave with serving; a post-stop callback raises an
`NSException` (MEASURED, CAP-7M0 `poststop_throws=1`); the deferred half must
capture its owning cycle by value because `dispatch_after` is neither drained
nor cancellable at teardown; and `Content-Length` must be **omitted** for a body
meant to stay open. `test/cap12a/cap12a_probe.mm` contains that whole shape,
claim-once guard included, so a later shard that wants streaming on macOS has
the design and the price in one place. **`7M1-5` is therefore answered rather
than inherited: it is closed by the decision not to need it**, and would reopen
only with a streaming plane, which §4 has already refused on WebView2's
evidence.

---

## 7. LEDGER — what this shard found and did not fix

Appended to `_bmad-output/implementation-artifacts/deferred-work.md`; the
entries there carry the full text and evidence. In brief:

- **`12A-1` UPSTREAM candidate, WebKitGTK.**
  `webkit_uri_scheme_request_get_http_body()` segfaults the UI process for any
  blob-backed request body (`Blob`, `File`, `FormData`) on 2.52.6, with an
  identically sized typed-array body going through the same call unharmed.
  Backtrace in §1/M3. A report is owed once entry condition 6.3.2 has pinned
  the version range, and the workaround (typed-array windows) is in the CAP-12B
  contract deliberately — unlike `RP-2`, because here the workaround is the
  *product's own* correct transport rather than a mask over a defect.
- **`12A-2` ACCEPTED, WebView2.** No response streaming to the page, and body
  delivery serialised on the host GUI thread. Both are engine properties with
  no API to negotiate them; the plane is designed around them.
- **`12A-3` ACCEPTED, WebKitGTK.** A media element cannot play a custom-scheme
  resource: `FormatError` before any pipeline exists, with the type claimed and
  a complete decoder path installed.
- **`12A-4` ROADMAP, CAP-12B.** The frozen MIME table carries no audio or video
  type, so the asset plane cannot serve media with a correct type at all. The
  blob plane routes around it with `TBlobInfo.ContentType`; whether `app.pwb`
  should ever carry media is a separate decision.
- **`12A-5` ROADMAP, the shard that runs the macOS leg.** Four derived rows and
  one uncompiled instrument, listed as entry condition 6.3.1.

---

## 8. VERDICT

```
CAP-12A DECISION READY
```

- **MEASURED** on Windows x64 / WebView2 and Linux x64 / WebKitGTK 2.52.6, from
  a real page over `pweb://app`, through the production seam, with a throwaway
  store behind it. **DERIVED** on both macOS targets, every row typed and the
  instrument committed.
- **NAMESPACE**: `pweb://app/_pweb/blob/<32 hex>`, reserved at the first
  segment, enforced at serve time and at pack time, with a second authority
  measured impossible under the ratified CSP.
- **SEAM**: additive. `IBlobStore`/`IBlobReader`/`IBlobWriter` ratified here as
  the Phase-4b-entry ratification requires; `IAssetStore` and `TAssetResponse`
  untouched.
- **GUARANTEED SURFACE**: whole and **ranged** bytes by URL with a correct
  content type, 206 / `Content-Range` / `Accept-Ranges`, `<img>` by URL, and
  request bodies as bytes for string and typed-array shapes to 256 MiB.
  **OPTIONAL, TYPED**: response streaming, `EventSource`, media elements,
  `Blob`/`File`/`FormData` bodies, concurrent body delivery.
- **CONTRACT**: §6, including the refusal of the `EventSource` receive loop
  CAP-15C anticipated, the ratification of `fetch(PUT …)` with a typed-array
  body as the JS→native transport the SPEC deliberately left unfrozen, and the
  finding that the macOS synchronous handler does **not** have to change.
- **No product file changed, and the exception is named rather than glossed.**
  `git diff` against `main` over `src/`, `examples/`, `tools/`, `sdk/` and
  `.github/` is **empty**: no unit, no CLI, no template, no SDK byte and no
  workflow moved. What did change outside `test/cap12a/` is the **ledger's own
  machinery**, which appending to an append-only ledger requires: five entries
  in `deferred-work.md`, their five rows in `test/backlog/dispositions.tsv`,
  the counts and the three open rows in `docs/backlog.md`, and
  `test/backlog/check_backlog.ps1` — which gained the `12A` shard mapping and a
  new section 5c pinning CAP-12A's own containment claims. Those four checks
  are **proven to fire**: `test/backlog/check_backlog_selftest.ps1` grew four
  legs and reports **23/23 perturbations refused**, with the restored tree
  passing the gate.
- **The containment claims are now mechanical, not prose.** Section 5c refuses
  a workflow that names `test/cap12a` (a run puts a throwaway store behind the
  production seam), a `src/`, `tools/`, `examples/` or `sdk/` file that names
  it at all, a bare recursive delete in either POSIX runner, and a Windows
  runner that deletes without validating its target against an allowed root.

**CAP-12B is not begun.** Its three entry conditions are in §6.3.
