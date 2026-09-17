---
title: CAP-12C — the JS->native upload, as typed-array windows
status: ready
created: 2026-09-17
kept_by: _bmad-output/implementation-artifacts/cap12-closure-artifact.md
begins_when: a named consumer needs page->native bulk bytes
---

# CAP-12C — the upload path

**Ready, not begun.** CAP-12 closed on 12B with the read side met and this line
deferred. What makes it deferrable is not unfinished design: the transport is
ratified, built, drained and proven byte-exact on three engines. What is missing
is a consumer. This brief is kept so the shard that finds one starts from the
decision, not from the measurements.

## What is already true, and is not this shard's to renegotiate

- **The transport is `fetch(PUT)` to a blob URL with a typed-array body, and
  nothing else** (CAP-12A §6.2). An `ArrayBuffer` or a typed array reaches the
  handler byte-exact at 1, 16 and 256 MiB on WebView2, WebKitGTK 2.52.6 and
  WKWebView (x64 and arm64).
- **Never a `Blob`, a `File` or a `FormData` body.** Two engine faults, both
  measured and both reported:
  - WebKitGTK 2.52.6: `webkit_uri_scheme_request_get_http_body()` faults the UI
    process for a blob-backed body (ledger `12A-1`, UPSTREAM;
    `docs/upstream/webkitgtk-uri-scheme-request-get-http-body-blob.md`);
  - WKWebView: the same kinds arrive as neither `HTTPBody` nor
    `HTTPBodyStream`, and the page gets a success describing zero bytes
    (ledger `12B-1`).
- **The window is 8 MiB** (CAP-12A §5.3): a 256 MiB single request took
  2 557 ms of serialised resource plane on WebView2. One request carries at most
  one window.
- **The request-body read path exists on all three engines** — drained in
  256 KiB chunks and bounded at 512 MiB on WebView2 and WebKitGTK, handed
  across the seam as a pointer into the engine's own `NSData` on WKWebView.
  Today a `PUT` or `POST` to
  `pweb://app/_pweb/blob/<token>` is answered `405`, `Allow: GET`, **after**
  the body has been read to its end, with a receipt: bytes, crc32c, complete
  (CAP-12B §4, ledger `12B-2`).
- **`IBlobWriter` is ratified** (`Append`, `Seal`, `Abandon`;
  `src/assets/pweb.blobs.intf.pas`) and `TPWebMemoryBlobStore` implements it
  with owner scoping and the five ceilings.
- `PWEB_NATIVE_CSP`, the nine error codes and `PWEB_PROTOCOL_VERSION = 1` do
  not move.

## What CAP-12C builds

1. **The store write.** The typed refusal becomes a write behind
   `IBlobWriter`: a window is appended to a blob the caller's principal owns,
   the last one seals it, and a failure abandons it. Ceilings are refused by
   name with the categories CAP-12B already emits.
2. **The addressing of an upload.** How the page names the blob it is writing
   before a token exists (a create call through `invoke`, or a reserved
   segment under `_pweb/`) is this shard's first decision, and it must keep the
   query string out of it (CAP-12A §2: the query is not a channel).
3. **The two SDK functions**, in `@pweb/runtime` and the Pas2JS SDK:
   `native.blobs.create(file)` — `slice()` plus `arrayBuffer()`, one 8 MiB
   window per request, never the `File` itself — and `native.blobs.release`.
   CAP-5's sweep forbids a browser network primitive in `sdk/**`, comments
   included, so the SDK side of the transport needs a ratified answer to that
   rule before it is written (CAP-12B met this and removed its reader).
4. **The receipt becomes the proof.** The crc32c the refusal already computes
   is compared with the page's own checksum of each window.

## Entry conditions

- A named consumer. Without one, this shard would ship a surface nobody keeps.
- The WebKitGTK version on the hosted runner is re-read; if `12A-1` is fixed
  upstream the typed-array rule stays anyway, because WKWebView's silent zero
  bytes do not depend on it.

## Out of scope

Response streaming, `EventSource`, media by URL, blobs larger than one window
(ledger `12B-3`, which wants a file-backed store first), and any native→page
push.
