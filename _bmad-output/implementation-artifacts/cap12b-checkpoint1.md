# CAP-12B — Checkpoint 1: the three entry conditions, measured

```
CAP-12B PLAN READY
the three §6.3 entry conditions are MEASURED, not derived
hosted measurement run 35085891349, all three legs green, on commit ef6a6b1
6.3.3 measured on this host against a REAL store through the PRODUCTION handler
```

CAP-12A §6.3 said CAP-12B **must not begin** until three things were settled,
"because each one can move the guaranteed surface". All three are settled
below, each by a measurement rather than by an argument, and **none of them
moved the surface** — which is itself the result, because two of them could
have.

---

## 6.3.1 — the four macOS rows, MEASURED on both architectures

**The vehicle.** `.github/workflows/measure-cap12.yml`, the CAP-11B watcher's
shape: `permissions: contents: read`, never called from `ci.yml`, nothing
`needs:` it, no `workflow_call`, and its output an artifact of typed rows.
It carries a `push:` trigger over its own sources for the reason CAP-11B's
watcher records — GitHub offers `workflow_dispatch` only for workflows on the
default branch, and this repository's shard branches are never merged before
their closure, so a dispatch-only file could not be run even once on the
branch that introduces it.

**Its first run was a debugging session, and it is on record as one.**
`test/cap12a/cap12a_probe.mm` had never been through a compiler anywhere.
Two defects were found by reading it and fixed **before** the first hosted
run rather than after it, which is why that run produced measurements instead
of a stack trace:

| defect | consequence had it shipped |
|---|---|
| `usleep()` with no `#include <unistd.h>` | C++ forbids an implicit declaration: a compile error on the first macOS leg |
| `[NSApp terminate:]` used to end the run | `terminate:` calls `exit()`, so `-[NSApplication run]` never returns and everything after it in `main` — **including writing the JSON this instrument exists for** — is dead code. The run would have exited 0 with no output |

Two smaller corrections went with them: `unsafe_unretained` spelled out where
`assign` meant it, and a per-row `carrier` field added to the probe's echo
reply, because the process-cumulative counters cannot answer a question asked
*per size* and `chunks == 1` cannot either (a stream read in one pass produces
one chunk too).

**The rows.** macOS 15.7.9, Apple clang 17.0.0, `macos-15-intel` and
`macos-15`. Every row identical on both architectures except the timing.

| §6.3.1 row | macos-x64 | macos-arm64 |
|---|---|---|
| `Range` reaches the handler through `[[task request] allHTTPHeaderFields]` | **yes** — 36 ranged requests, first `bytes=1000-1099` | **yes**, identical |
| a **206** with `Content-Range` on an `NSHTTPURLResponse`, read back by `fetch()` | **yes** — `bytes 1000-1099/1048576`, 100 bytes, **offset**-verified against the deterministic pattern | **yes**, identical |
| the **suffix** range `bytes=-128` | **yes** — `bytes 1048448-1048575/1048576` | **yes**, identical |
| which of `HTTPBody` / `HTTPBodyStream` carries a typed-array body, **1 MiB** | **`HTTPBody`** — 1 048 576 bytes, pattern verified | identical |
| … **16 MiB** | **`HTTPBody`** — 16 777 216, pattern verified | identical |
| … **256 MiB** | **`HTTPBody`** — 268 435 456, pattern verified | identical |
| a whole **8 MiB** body served synchronously | **200**, 8 388 608 bytes, **85.0 ms** page-side | **200**, 8 388 608 bytes, **25.0 ms** |

`HTTPBodyStream` was **nil in every one of those cases**, at every size. The
question CAP-7M never had to ask is answered: on this OS and toolchain
WebKit hands a typed-array `fetch` body to a custom scheme handler as one
contiguous `NSData`, and the production adapter therefore crosses the seam
with a **pointer** rather than a copy — a 256 MiB upload costs the seam
nothing.

**Two rows CAP-12A did not ask for, and both matter.**

- `stop_arrivals = 0`, `stops_while_serving = 0`, `suppressed_terminals = 0`,
  `caught_exceptions = 0`, and `handler_calls_off_main_thread = 0` on both
  architectures — even though the instrument *does* defer delivery from a
  `dispatch_after` chain, which is the shape that can produce an
  interleaving stop. §6.5's conclusion holds with room to spare: the
  Range-based plane does not reopen ledger `7M1-5`.
- **A `Blob`, a `File` and a `FormData` request body arrive as NEITHER
  `HTTPBody` NOR `HTTPBodyStream`.** The handler is entered, the request
  carries no body at all, and the page receives a successful response
  describing **zero bytes**. No crash, no diagnostic, nothing anywhere
  reporting that the body was dropped. This is new — CAP-12A could only
  record `DERIVED unknown` — and it is *worse* than the WebKitGTK fault of
  6.3.2, because a fault is visible. It is why the "never a `Blob`, a `File`
  or a `FormData`" rule is now justified on **three** engines rather than
  one.

**And the derived rows CAP-12A could not measure at all are now measured**:
the second authority `pweb://blob/…` is refused by the CSP with
`second_authority_requests: 0` on a path that would have counted one; an
`<img>` decodes from the reserved prefix; an `<audio>` plays and seeks a
ranged body (`duration = 60`, `currentTime = 55`); `EventSource` is **live**
on WKWebView; response streaming is **incremental**; 64 concurrent scheme
requests all complete. WebView2 remains the only engine that buffers, which
is what §4 rests on.

---

## 6.3.2 — the WebKitGTK fault against the CI baseline

**The baseline is the same version.** `ubuntu-24.04`, distribution
`libwebkit2gtk-4.1-dev`: `pkg-config --modversion webkit2gtk-4.1` reports
**2.52.6**, gtk+-3.0 3.24.41 — the dev host's version exactly.

That version reached the *typed row* only on the second measurement run
(`35089828854`), and the reason is recorded rather than tidied away: the
first run wrote the runner's facts file and then called the row emitter
without pointing it at one, so a question **about a version** came back
`webkitgtk_version: undecided`. The emitter now defaults to the path the
workflow writes, and the row reads
`webkit2gtk-4.1 2.52.6, gtk+-3.0 3.24.41`. The fault rows below were
measured identically on both runs.

| row | hosted `ubuntu-24.04`, webkit2gtk-4.1 2.52.6 |
|---|---|
| `POST` **`Blob`**, 1 MiB | **faults** — the page sees `TypeError: Load failed`, the handler records `req.exception Access violation` |
| `POST` **`File`**, 1 MiB | **faults**, identical |
| `POST` **`FormData`**, 1 MiB | **faults**, identical |
| `POST` typed array, 1 MiB | 1 048 576 received, pattern verified, 4 reads |
| `POST` typed array, 16 MiB | 16 777 216 received, pattern verified, 64 reads |
| `POST` typed array, 256 MiB | 268 435 456 received, pattern verified, 1 024 reads |
| whole 8 MiB synchronous | **200**, 8 388 608 bytes, 74.0 ms page-side |

**So the branch §6.3.2 named is taken: same fault → the workaround ships AND
the upstream report is owed.** It is written:
`docs/upstream/webkitgtk-uri-scheme-request-get-http-body-blob.md`, with the
backtrace, the kind-versus-size control table, and a version range that
claims **exactly 2.52.6 on two independent hosts** and nothing wider. The
report also carries the macOS silent-empty finding above, because a reader of
a WebKit bug should know that the other WebKit engine fails the same call
quietly.

The workaround is not a mask: a typed-array body **is** the transport
CAP-12A §6.2 ratified for its own reasons, and neither SDK can produce any
other kind.

---

## 6.3.3 — the 8 MiB window against a REAL store

**Measured through the PRODUCTION handler, against `TPWebMemoryBlobStore`,
on WebView2 — production plus drain, not a synthetic pattern.** The page
issues the 8 MiB blob read and, in the same turn, an ordinary asset request,
and records when each *arrived*.

| run | 8 MiB blob, page-side | the asset requested beside it |
|---|---|---|
| 1 | 41.8 ms | 46.0 ms |
| 2 | 38.5 ms | 44.3 ms |
| 3 | 38.2 ms | 43.9 ms |
| 4 | 40.0 ms | 45.6 ms |
| **Linux / WebKitGTK, for contrast** | **30 ms** | **16 ms** |

Three things follow, and the third is the decision.

1. **CAP-12A §5.3's arithmetic holds.** It projected ~45 ms for 8 MiB from
   the 256 MiB whole-body row; the real store through the real handler gives
   **38–42 ms**. The 8 MiB window bound stands as ratified.
2. **The serial-drain stall is real and it is small.** On WebView2 the
   ordinary asset arrives **~5–6 ms after** the blob — it waited. On
   WebKitGTK it arrives **before** it (16 ms against 30 ms), because that
   engine interleaves. Both match what CAP-12A measured at 256 MiB; at 8 MiB
   the same property costs milliseconds instead of 3.6 seconds, which is
   what bounding the window was for.
3. **A file-backed store is NOT forced, so it stays a later shard.** The
   entry condition existed because "a store reading from a file has a
   different production cost from one filling a pattern". A memory-backed
   store's production cost is a `Move` of the window, and the measurement
   says the whole exchange fits inside a single frame's budget. v1 ships
   memory-backed with ceilings.

---

## THE PLAN THESE THREE LICENSE

**The store.** `TPWebMemoryBlobStore`, in `src/assets/pweb.blobs.memory.pas`,
behind `IBlobStore` as CAP-12A §5.1 ratifies it, with the ceilings below. A
file-backed store changes only that file: `IBlobStore` names no filesystem
path, so nothing above it knows which kind of store it is talking to.

**The ceilings, with the arithmetic.**

| bound | v1 value | why this number |
|---|---|---|
| largest single blob | **8 MiB** | it is the window §5.3 bounds a response to, it is `PWEB_FETCH_MAX_RESPONSE`, and it is §5.3's upload chunk. One number, three uses — and making the largest blob *equal* the window is what lets a whole-body request always be answered without ranging |
| bytes per principal | **64 MiB** = 8 × the largest blob | the transient cost of serving one window was MEASURED at 2× on both engines, so a principal at its ceiling with one window in flight is 64 + 16 = 80 MiB: eight times the largest body the plane will serve, and an order of magnitude below the 2 048 MiB a WebView2 process absorbed for one 256 MiB body |
| blobs per principal | **128** = 16 × the eight largest-possible blobs | the byte ceiling bounds MEMORY; this bounds BOOKKEEPING, for a principal making thousands of tiny blobs. For the headline consumer bytes bind first and by a wide margin — `pweb.fetch` only reaches the plane above the 1 MiB inline cap, so 64 blobs already exhaust the byte ceiling |
| bytes in total | **256 MiB** = 4 × per principal | four principals can each reach their own ceiling before the total binds, and the fifth is refused **by name** rather than starving one silently. It is also exactly the largest single request body M3 measured crossing both engines intact |
| blobs in total | **512** = 4 × per principal | the same factor |

**The handler branch, per engine.** The reserved prefix is tested on the
canonical logical path `PWebParseAppUri` produced, **before** the asset store
is consulted, and from that point the answer is the translator's whatever
happens. WebView2 reads `Range` through
`ICoreWebView2HttpRequestHeaders.GetHeader` and the body through
`get_Content`; WebKitGTK through `webkit_uri_scheme_request_get_http_headers`
+ `soup_message_headers_get_one` and `webkit_uri_scheme_request_get_http_body`;
WKWebView through `allHTTPHeaderFields` and `HTTPBody`, across a private seam
that grows three out fields (status, reason, extra headers) and one in struct.

**The Range grammar — ONE rule on four engines, ratified here.**

| the header | the answer | why |
|---|---|---|
| absent | **200**, whole | — |
| `bytes=a-b`, `bytes=a-`, `bytes=-suffix` | **206** + `Content-Range` + `Accept-Ranges` | the guaranteed surface CAP-12A measured on every engine |
| **multi-range** (`bytes=0-9,20-29`) | **200, whole** | RFC 7233 §3.1 lets an origin server ignore a Range it does not understand, and "the handler answering 200 to a Range request" is itself part of the measured guaranteed surface. A 206 carrying only the first window would lie about what was asked, and `multipart/byteranges` is a second body format this plane refuses to own. It is safe here for a reason that is a measurement: a blob is at most one window, so "the whole thing" never exceeds the 8 MiB bound |
| **malformed** (`bytes=abc`, `bytes=20-10`, two dashes, an unknown unit) | **200, whole** | an invalid byte-range-spec invalidates the whole header; ignoring it is what RFC 7233 requires |
| **unsatisfiable** (first past the end, or a suffix length of 0) | **416** + `Content-Range: bytes */<total>` | an unsatisfiable range is a page BUG, and a whole body in reply is indistinguishable from success. RFC 7233 §4.4 defines 416 for exactly this and gives the page the real length so it can compute a range that exists. `Accept-Ranges` stays on: what was wrong was the range, not the capability |

**The fetch-door integration.** A declared-origin response between the 1 MiB
inline cap and the 8 MiB response ceiling stops being
`response_too_large_to_inline` and becomes a **success** carrying a
`BlobHandle` — `{token, url, size, type}` — which the page reads by URL.
`truncated` stays false in every envelope, `bytes` stays the wire length, and
`blob` is present and **null** in every other envelope so that no caller has
to feature-detect it. Above 8 MiB the transport still stops the read and the
refusal is unchanged. **An application with no blob store keeps the CAP-15B
answer byte for byte**, which is what makes this additive rather than a
change of contract for every host that already ships.

**The SDK read surface.** A handle type and one reader, in both SDKs:
`PWebBlobHandle` / `readBlob(handle, {offset, length})` in `@pweb/runtime`,
`TPWebBlobHandle` / `PWebReadBlob(handle, offset, length)` in the Pas2JS SDK.
No `create`, no `put`, no upload — that is CAP-12C. **Neither SDK builds a
blob URL**: `handle.url` comes from the runtime, which is the only place that
knows both spellings.

**The smallest diff.** Three new units under `src/assets/`, one branch in
each of the three adapters, one optional field on `TPWebHostOptions` plus the
CAP-9 ordering the host already owns, one constructor overload on the fetch
decorator, one refusal in `pwebbundle`, one paragraph in `docs/kernel.md`,
and the read surface in the two SDKs. **No frozen signature moves**, the
seven interfaces are untouched beyond ratifying `IBlobStore`, and
`PWEB_NATIVE_CSP` is byte-identical — re-measured, not assumed.

---

## VERDICT

```
CAP-12B PLAN READY
```

The three entry conditions are measured and recorded; none of them moved the
guaranteed surface; the two that could have — the macOS carrier question and
the choice of store — both came back in favour of the plan CAP-12A sketched.
Implementation proceeds in the same run.
