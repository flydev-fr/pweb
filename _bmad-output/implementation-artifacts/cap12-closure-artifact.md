# CAP-12 — phase closure: the blob plane's read side, and an upload kept ready

**CAP-12 is CLOSED on 12B.** Two shards. CAP-12A measured what four engines
can deliver and decided the plane from the answers; CAP-12B built it and proved
it on four targets. The read side of the SPEC's blob line is met. The upload
line is **deferred**, and the reason is not unfinished design: the transport is
ratified and proven, and nothing needs it yet. The CAP-12C brief is kept, ready,
at `_bmad-output/planning-artifacts/cap12c-brief.md`.

The SPEC states CAP-12 as one intent and one success sentence:

> **intent:** The frontend reads and writes bulk binary data without pushing it through the JSON invocation bridge.
>
> **success:** A service returning a >40 MB PDF answers with a `BlobHandle` envelope; the frontend fetches `pweb://blob/{token}` and the response honours `Range`, `Content-Length`, and `Content-Type` without buffering the whole payload in memory. **Off the critical path.**

This closure changes no plane code, no pin and no default. What it changes is
prose that pointed at nothing, one contract rule, and the ledger's bookkeeping;
§6 and §7 list every file.

## 1. THE HOSTED RUNS

| shard | commit | run | result |
|---|---|---|---|
| CAP-12A | `340417e` | 35075079887 | six jobs green; no CI step entered the sequence (206 steps), both frozen policy digests byte-identical, the five CAP-12A entries accepted by the backlog gate on the runner |
| CAP-12A entry conditions | `ef6a6b1`, then `a57b14e` | 35085891349, 35089828854 | the dispatch-only `measure-cap12.yml`: the four macOS rows MEASURED on both architectures, and the hosted WebKitGTK read at 2.52.6 with the same upload fault |
| CAP-12B | `75e0f7c429e680621d74953d642fc4c083d70ca1` | 35130141163 | six jobs green; step 185 ran and passed on four legs; `blob_corpus_digest` `5d0ce4b9…93bc` (31 lines) identical on four targets; every boolean row `true`; `blob_release_order = cap9`, `blob_csp_violations = 0`; `capability_policy_digest` and `navigation_policy_digest` unchanged; 207 steps |

The 12B record also carries the one red it met on the way (run 35127169228,
CAP-6b4 S6, the pre-existing D1-16 race, fixed in the harness as `12B-4`) and
the run before the fix (35108018300, green, identical plane code).

## 2. THE SPEC'S CAP-12 LINE, CLAUSE BY CLAUSE

**Verdict: MET for the read side.** Two clauses carry recorded deviations
rather than being rounded up — R3 is deviated outright, and R4 is met under a
spelling the measurements superseded — and R2 and R6 are met with their limits
stated. The write side is §3.

| clause | verdict | evidence |
|---|---|---|
| R1 | MET | *"reads … bulk binary data without pushing it through the JSON invocation bridge"* — a `pweb.fetch` response between the 1 MiB inline cap and the 8 MiB ceiling is a success carrying `"blob":{"token","url","size","type"}` with `bodyText` and `bodyBase64` both null; the page loads the bytes by URL. No base64 bulk crosses the bridge (12B §5) |
| R2 | MET for the runtime's own service | *"a service … answers with a `BlobHandle` envelope"* — the runtime-owned `pweb.fetch` service is the wired and proven producer. **An application's own mORMot service is not**: `TMormotInvocationBridge` hands a service the arguments and never the invocation context, so it cannot name the principal a blob must be owned by. An application `IInvocationBridge` decorator sees the context and could produce a handle exactly as the fetch door does, but no helper, template construct or proof covers that path (`12-5`, ROADMAP); `PWebBlobHandle` / `isPWebBlobHandle` in `@pweb/runtime` and `TPWebBlobHandle` in the Pas2JS SDK are the shipped type. `blob` is in every envelope and null in all but one case, so a caller never feature-detects it |
| R3 | DEVIATED | *"a >40 MB PDF"* — a v1 blob is **at most one 8 MiB window**, deliberately the same number as the response window CAP-12A §5.3 derived from WebView2's serial GUI-thread delivery and as `PWEB_FETCH_MAX_RESPONSE`. The ranged read path that a 40 MB body would need is built and proven, and the clamp lives in one place (`PWEB_BLOB_MAX_WINDOW_BYTES`); raising the blob ceiling is owed together with a file-backed store (`12B-3`, ROADMAP). Recorded here so the phase does not read as having served a 40 MB document |
| R4 | MET, spelling superseded (a recorded deviation) | *"fetches `pweb://blob/{token}`"* — the blob is fetched by URL from **`pweb://app/_pweb/blob/<32 hex>`**. CAP-12A §2 measured that the ratified `PWEB_NATIVE_CSP` (`connect-src 'self'`, `img-src 'self' data:`, `media-src 'self'`) refuses a second authority before any handler is asked, on both reachable engines, with a path that would have counted one. The invariant survives; its spelling does not. `docs/kernel.md` carries the correction |
| R5 | MET | *"honours `Range`, `Content-Length`, and `Content-Type`"* — single and suffix ranges answered 206 with `Content-Range` and `Accept-Ranges: bytes`, **offset-verified** against a deterministic pattern; a declined range 200 whole; an unsatisfiable one 416 with `bytes */<total>`; the type from `TBlobInfo.ContentType`, never from the path. Four targets, run 35130141163 (`blob_range_206`, `blob_range_declined_200`, `blob_range_416`, `blob_whole_by_url`) |
| R6 | MET within the v1 ceiling | *"without buffering the whole payload in memory"* — a response carries one window, read with `ReadAt` into the response body, so serving costs 2× the window (MEASURED on both engines) instead of 2× the body; CAP-12A measured 512 MiB held to serve a 256 MiB body whole. The v1 **store** is memory-backed, ratified by entry condition 6.3.3 (38–42 ms for a window against the real store), and the five ceilings bound what it holds (8 MiB per blob, 64 MiB per principal, 256 MiB in total). So the whole of a v1 blob IS held in memory, and that is acceptable only because a v1 blob is one window: the file-backed store a larger payload needs is owed with R3, by `12B-3` |
| R7 | MET | *Phase-0 exit criterion 2* — the concrete method sets of `IBlobStore` / `IBlobReader` / `IBlobWriter` were ratified at Phase 4b entry, before any blob implementation (CAP-12A §5.1), and `check_cap12b_contracts.ps1` C6 compares the ten ratified signatures and their order |
| R8 | MET | *"off the critical path"* — CAP-12 gated nothing before it; the MVP closed without it |

## 3. THE UPLOAD LINE — DEFERRED, WITH ITS REASON

The intent says *reads and writes*. The write side is deferred, and each part of
the reason is on record rather than argued:

- **No consumer.** Nothing in the runtime or the templates needs page→native
  bulk bytes, and no application has asked for them. A
  `native.blobs.create(file)` shipped without a consumer would be a surface
  nobody keeps honest.
- **The transport is ratified.** The SPEC's non-goals left the JS→native
  transport unfrozen until real macOS integration tests existed. They exist:
  `fetch(PUT)` to a blob URL **with a typed-array body and nothing else** is the
  transport (CAP-12A §6.2), measured byte-exact at 1, 16 and 256 MiB on
  WebView2 and WebKitGTK and, through `HTTPBody`, on WKWebView x64 and arm64
  (`HTTPBodyStream` nil at every size). The SDK reads a `File` as 8 MiB
  `ArrayBuffer` windows.
- **Both engine faults are measured and reported.** A `Blob`, `File` or
  `FormData` body faults the WebKitGTK 2.52.6 UI process inside
  `webkit_uri_scheme_request_get_http_body()` — `12A-1`, UPSTREAM, the report
  written at `docs/upstream/webkitgtk-uri-scheme-request-get-http-body-blob.md`
  with the version range pinned on two independent hosts — and arrives at a
  WKWebView handler as neither `HTTPBody` nor `HTTPBodyStream`, so the page
  gets a success describing zero bytes (`12B-1`).
- **The read path of the upload already runs.** CAP-12B drains every request
  body on all three engines and refuses it with `405`, `Allow: GET` and a
  receipt (bytes, crc32c, complete), so the path is a measurement rather than
  dead code (`12B-2`).

## 4. THE CAP-12C HANDOFF

`_bmad-output/planning-artifacts/cap12c-brief.md`, **`status: ready`**, not
begun. It carries what is already true (the transport, the two faults, the
window, the drained read path, the ratified `IBlobWriter`), what CAP-12C builds
(the store write behind `IBlobWriter`, the addressing of an upload with the
query string kept out of it, `native.blobs.create` and `native.blobs.release`
in both SDKs under CAP-5's zero-network rule, and the receipt turned into the
proof), and its two entry conditions: a named consumer, and the hosted
WebKitGTK version re-read. Its first decisions are how an upload is addressed
and how the SDK half meets CAP-5's zero-network rule. `12B-2` stays ROADMAP,
owned by CAP-12C.

What CAP-12C must not touch is unchanged from CAP-12A §6.4: no pin,
`PWEB_NATIVE_CSP`, the nine error codes and `PWEB_PROTOCOL_VERSION = 1`.

## 5. THE PHASE LEDGER — 14 ENTRIES, 0 ORPHANS

Keyed as everywhere else: `<shard>-<ordinal>` plus the first eight hex of the
SHA-256 of the entry's own `summary` line. **This table is read by
`test/backlog/check_backlog.ps1` §5d**: every 12A, 12B and 12 entry must appear
here with the digest measured from the ledger and the verdict held in
`test/backlog/dispositions.tsv`, the owner column is that table's cell
verbatim, and nothing else may appear.

| key | digest | verdict | owner | disposition |
|---|---|---|---|---|
| `12A-1` | `bf54f4e6` | UPSTREAM | WebKitGTK; the report is written, the version range is pinned | the blob-backed request body fault; report written, range pinned at 2.52.6 on two hosts; the product's typed-array transport routes around it on its own merits |
| `12A-2` | `89b8a181` | ACCEPTED | measured engine behaviour, nothing owed | WebView2 delivers no response body before it is complete, and drains bodies serially on the GUI thread; the plane is Range-based because of it |
| `12A-3` | `81963a97` | ACCEPTED | measured engine behaviour, nothing owed | a WebKitGTK media element refuses a custom-scheme resource, so media by URL is typed per engine and never promised |
| `12A-4` | `b0baa778` | CLOSED | CAP-12B | a blob's type comes from `TBlobInfo.ContentType`, never from the asset MIME table |
| `12A-5` | `863e0d64` | CLOSED | CAP-12B | the four derived macOS rows MEASURED on both architectures (run 35085891349) |
| `12B-1` | `4a03b815` | ACCEPTED | measured engine behaviour, nothing owed | WKWebView delivers a `Blob`/`File`/`FormData` body as zero bytes, silently |
| `12B-2` | `4613b0a3` | ROADMAP | CAP-12C | the upload transport built, drained, proven and refused by name; the brief is ready (§4) |
| `12B-3` | `a8dec6fc` | ROADMAP | the shard that wants blobs larger than one window | the 8 MiB blob ceiling, raised together with a file-backed store; §2 R3 |
| `12B-4` | `0aaa92c1` | CLOSED | itself | the CAP-6b4 S5/S6 drain |
| `12-1` | `8145e4ed` | ACCEPTED | the CAP-12 closure | this closure's record: the read side met with two recorded deviations, the upload deferred with its reason, the 12C brief ready |
| `12-2` | `6ef453d0` | CLOSED | itself | `7M1-5` closed by the Range decision and the macOS measurements behind it |
| `12-3` | `fe0a748a` | CLOSED | itself | the streaming promise removed and K9 inverted (§6) |
| `12-4` | `f45701e6` | ACCEPTED | the CAP-12 closure | the seven open rows CAP-12 owned without being blob-plane work, re-homed |
| `12-5` | `72468149` | CLOSED | CAP-16 | the SPEC's producer was proven for `pweb.fetch` only (§2 R2); found by the closure's own review, and CLOSED by CAP-16 (ledger `16-3`), which gave the mORMot bridge a thread-scoped caller context and one helper that creates a blob for the caller. **Superseded row:** this phase ledger read `ROADMAP` / `the first application that returns a blob from its own service` at the CAP-12 closure |

**Orphans: 0. Strays: 0. Rewords: 0.** Census: 5 CLOSED, 5 ACCEPTED,
3 ROADMAP, 1 UPSTREAM. At this closure's commits the backlog gate read
**455 ledger entries, 0 orphans, 63 open** (4 fix-now, 58 roadmap, 1 upstream),
125 accepted, 267 closed; the same branch's CAP-15C entries came after.

### The rows CAP-12 owned in other phases

A closed phase owns nothing. Eight open rows named `CAP-12` as their owner when
12B shipped, and a ninth, `12B-2`, named `CAP-12C`. The closure disposes of all
nine, and §5d now refuses an open row owned by `CAP-12`, `CAP-12A` or `CAP-12B`.

| key | before | after | why |
|---|---|---|---|
| `7M1-5` | ROADMAP, CAP-12 | **CLOSED** by `12-2` | the deferred macOS chunked delivery is not needed: a bounded ranged window is a whole body (CAP-12A §6.5), and the synchronous `startURLSchemeTask:` handler served the plane's rows on both macOS legs with `stop_arrivals = 0` |
| `9B1-6` | ROADMAP, CAP-12 | ROADMAP, the shard that ratifies a sized `IAssetStore` read | the blob plane never reads through `TryRead`, so it routed around the carrier-side materialisation bound and fixed none of it. The reason loses the clause that sent it to the blob plane |
| `7F-3` | ROADMAP, CAP-12 | ROADMAP, the shard that next extends the CAP-7F aggregator | comparing the ABI, fcntl and runtime facts between architectures is aggregator work |
| `P6U-6` | ROADMAP, CAP-12 | ROADMAP, the shard that next extends the CAP-7F aggregator | a declarative evidence field set is aggregator work |
| `9A-2` | ROADMAP, CAP-12 | ROADMAP, a shard wanting async-first plugin scripts | the owner its own reason already names |
| `B1-5` | ROADMAP, CAP-12 | ROADMAP, the example-host migration shard | the three hand-composed hosts are that shard's subject |
| `11B-19` | ROADMAP, CAP-12 | ROADMAP, the example-host migration shard | a flush or close-on-report is a host-side change in the same hosts |
| `11B-4` | ROADMAP, CAP-12 | ROADMAP, a mORMot head watcher shard, with its own budget | a different instrument from the webview watcher |
| `12B-2` | ROADMAP, CAP-12C | unchanged | CAP-12C exists as a ready brief |

## 6. "WHEN CAP-12 BRINGS STREAMING" — REMOVED

CAP-15C wrote that the socket SDK's receive loop was the only thing that would
change *when CAP-12 brings streaming*, and put it in four places. CAP-12A §6.2
refused that consumer by measurement — WebView2 buffers `text/event-stream`
entirely, six events produced 150 ms apart arriving within 0.1 ms of each
other, 763 ms after the request — and CAP-12 closed without a streaming route.
The sentence pointed at nothing, and so did the door-B reopening condition that
leaned on "CAP-12's streaming work".

| place | now says |
|---|---|
| `docs/cli-contract.md` §5, the SDKs paragraph | the long-poll is the receive loop, not a placeholder; the CAP-12A measurement; the data plane Range-based, not streaming-based; each parked receive holds one scheduler worker and one of its window's invocation slots for up to `waitMs`; and the half of the old promise that holds — the SDK surface, the four method names and the decorator are unaffected — kept in so many words |
| `docs/cli-contract.md`, door-B condition 3 | live push, which protocol v1 does not have and no streamed response can stand in for, with the same measurement |
| `sdk/typescript/src/socket.ts` | the same, in the header, with the class, its events and the four method names unaffected; the loop's own comment no longer names CAP-12 |
| `sdk/pas2js/pweb.native.pas` | the same, on `TPWebSocket`; likewise the loop's comment |
| `src/rpc/pweb.rpc.socket.pas` | the same, in the header — a comment, no compiled change |

**K9 of `test/cap15c/check_cap15c_contracts.ps1` is inverted to match.** It
used to require the promise in the four places. It now refuses the promise in
every tracked file under `docs/` and `sdk/` (**42**) and in the decorator, after
turning comment prefixes into spaces and a typographic apostrophe into a straight
one, so a promise wrapped across a JSDoc line cannot slip past; and it requires
the measurement's phrase in the four places that carried the promise. On the
unchanged tree it fired **eight** times — four promises, four missing
measurements — with nothing else in the contract gate moving; it was then
observed firing on a promise wrapped across ` * ` lines and on one spelled with a
typographic apostrophe, both planted in `sdk/typescript/README.md`, and passes on
the restored tree. CAP-5's zero-network sweep, which reads SDK comments too,
passes on the new text.

**The phrase had a second reader.** `test/cap10a/check_dev_trust.ps1` required
`only thing that changes` in the contract as its record of the CAP-15C receive
decision, and would have failed all four legs; it now requires
`Range-based, not streaming-based`, and was observed refusing a contract that
carried neither.

## 7. SUPERSESSIONS, RECORDED OLD → NEW

| what | old | new | why |
|---|---|---|---|
| CAP-15C K9 | requires "only thing that changes" in four files | refuses the CAP-12 streaming promise in every tracked file under `docs/` and `sdk/` plus the decorator, comment prefixes normalised; requires "Range-based, not streaming-based" in four | §6 |
| CAP-10A dev-trust receive-loop phrase | `only thing that changes` | `Range-based, not streaming-based` | §6 |
| backlog shard map | 46 source specs | 47: `cap12-closure-artifact.md` → `12` | the closure's own entries |
| backlog gate | sections 1–5c | plus §5d: the closure table read row by row (digest, verdict, owner), and no open row owned by `CAP-12`, `CAP-12A` or `CAP-12B` | §5 |
| backlog negative self-test | 26 perturbations | **34** | a phase entry dropped from the closure table, a verdict, a digest and an owner that disagree, a key the ledger does not carry, a key disposed twice, the artifact missing, an open row handed back to CAP-12 |
| backlog census | 450 entries; 63 open (58 roadmap); 123 accepted; 264 closed | **455**; **63** open (**58** roadmap); **125** accepted; **267** closed | five closure entries; `7M1-5` closed; `12-5` opened |
| `7M1-5` | ROADMAP, CAP-12 | CLOSED, `12-2` | §5 |
| seven owner cells | CAP-12 | named owners | `12-4` |
| `sdk_inventory_digest`, `sdk_archive_sha256` | per target | move on every target | the SDK ships `socket.ts`'s compiled output and `pweb.native.pas`, and both carry the new comment. Per-target rows, required present and compared on none; `sdk_digest` and `sdk_ship_table_digest`, the decisions the four targets agree on, do not move |

## 8. FREEZE CHECK

`git diff d46d6ad` over the frozen surface, for this closure's commits:

- `src/` — **one comment**, in `src/rpc/pweb.rpc.socket.pas`'s header. No
  declaration, no statement, no constant.
- `sdk/` — **comments only**, in `socket.ts` and `pweb.native.pas`.
- every `*.lock`, `webview.chet`, `src/lib/`, `tools/`, `examples/`,
  `.github/` — **unchanged**.
- `PWEB_NATIVE_CSP`, the nine error codes, `PWEB_PROTOCOL_VERSION`, the seven
  interface signatures, the host defaults — **unchanged**.

What was permitted and used: `docs/cli-contract.md`, `docs/backlog.md`,
`test/cap15c/check_cap15c_contracts.ps1` (K9), `test/cap10a/check_dev_trust.ps1`
(the one needle), `test/backlog/*`, `deferred-work.md` (append only), this
artifact, and the brief under `_bmad-output/planning-artifacts/`.

## 9. KNOWN LIMITATIONS

1. **One blob is one window.** A 40 MB document is not one handle in v1
   (§2 R3, `12B-3`).
2. **An application service cannot yet return a blob** of its own: a mORMot
   service never sees the principal (§2 R2, `12-5`).
3. **No upload.** The transport exists and is refused by name until a consumer
   arrives (§3, `12B-2`).
4. **No push.** Protocol v1 has none and the Range-based plane cannot supply
   one, so the socket door keeps its bounded long-poll, which holds a scheduler
   worker and an invocation slot while it waits. Whether that starves other
   invocations under the ratified host defaults is a question this branch
   measures separately and records in its own ledger entry.
5. **Media by URL is not promised** (`12A-3`).
6. **`HEAD` is not served** (12B §11).

## VERDICT

```
CAP-12 CLOSED — BLOB DATA PLANE, READ SIDE MET; UPLOAD DEFERRED, 12C READY
```

- The read side of the SPEC's line is met on four targets, with the URL
  spelling superseded by measurement, the size clause recorded as a deviation
  owned by `12B-3`, and an application service's own blob owed by `12-5`.
- The upload line is deferred with its reason: no consumer, a ratified and
  proven transport, and both engine faults measured and reported.
- The CAP-12C brief is kept ready.
- The promise that CAP-12 would bring streaming is gone from the contract, both
  SDKs and the decorator, and K9 refuses it everywhere it could come back.
- The phase ledger has 14 entries and no orphan, and no open row is owned by a
  closed phase.
