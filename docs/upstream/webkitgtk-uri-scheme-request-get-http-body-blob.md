# `webkit_uri_scheme_request_get_http_body()` crashes the UI process for a blob-backed request body

**Project:** WebKitGTK (`libwebkit2gtk-4.1`)
**Entry point:** `webkit_uri_scheme_request_get_http_body()`
**Severity:** crash — SIGSEGV inside the library, in the UI process, from a
documented public accessor, reachable by any page a custom scheme handler
serves
**Reproduced on:** webkit2gtk-4.1 **2.52.6**, GTK 3.24.41, x86-64, on two
independent machines: a Debian-derived WSL2 host (FPC 3.2.3) and the hosted
`ubuntu-24.04` GitHub Actions image with the distribution's
`libwebkit2gtk-4.1-dev` (FPC 3.2.3). Same version, same fault, same
backtrace.

---

## Summary

A page served by a `WebKitURISchemeHandler` issues

```js
fetch('myscheme://app/upload', { method: 'POST', body: someBlob })
```

where `someBlob` is a `Blob`, a `File` or a `FormData`. The scheme callback
calls `webkit_uri_scheme_request_get_http_body()` to read it, and the call
does not return: the UI process takes SIGSEGV three frames inside the
library.

An `ArrayBuffer` or a string body of the **same size** goes through the same
call and returns a working `GInputStream`, so it is the body **kind** and not
the size or the size class.

## Backtrace

The public entry point is frame #4; the fault is three frames deeper. Frame
\#5 is the caller, which does nothing but make the call.

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

## Measurement

One page, one custom-scheme handler, eight request bodies differing in KIND
and in SIZE separately — because an earlier arrangement varied both at once
and produced four failures that could be read either way.

| body | size | result |
|---|---|---|
| `ArrayBuffer` | 1 MiB | 1 048 576 bytes received, pattern verified |
| `ArrayBuffer` | 16 MiB | 16 777 216 bytes received, pattern verified |
| `ArrayBuffer` | 256 MiB | 268 435 456 bytes received, pattern verified |
| string | 1 MiB | 1 048 576 bytes received |
| `ArrayBuffer` over `PUT` | 1 MiB | received |
| **`Blob`** | 1 MiB | **SIGSEGV inside the accessor** |
| **`File`** | 1 MiB | **SIGSEGV inside the accessor** |
| **`FormData`** | 1 MiB | **SIGSEGV inside the accessor** |

The three typed-array rows and the three faulting rows run in the same
process, through the same callback, one after another. The handler's own
timeline shows `req.enter`, `req.got_uri`, `req.got_method`,
`req.got_headers`, `req.read_range` and then nothing: the fault is inside the
body accessor, before it returns, with no `req.got_body` and no `req.open`.

## Version range

Confirmed identical on **2.52.6** on two independent hosts. Earlier and later
versions are **not** measured here, so the range this report claims is
exactly `2.52.6` and nothing wider.

## What this project does about it

Nothing that masks it. The transport it ratified independently — a
typed-array request body and nothing else — is the correct transport for its
own reasons (one contiguous buffer, no multipart envelope, no dependence on
how an engine chooses to transport a file), and its SDK cannot produce a
`Blob`, a `File` or a `FormData` body at all. The workaround and the right
answer happen to coincide, which is why it is shipped rather than deferred.

Two other engines were measured against the same page for contrast, and the
third is worth reporting because it is the *quieter* failure:

- **WebView2 (Windows):** all three blob-backed kinds are received and
  verified, `FormData` arriving as the expected multipart envelope.
- **WKWebView (macOS 15.7, both architectures):** a `Blob`, a `File` and a
  `FormData` body arrive as **neither `HTTPBody` nor `HTTPBodyStream`** — the
  handler is entered, the request carries no body at all, and the page gets a
  successful response describing zero bytes. No crash, no diagnostic, and
  nothing anywhere reports that the body was dropped.

## Reproducer

The instrument is `test/cap12a/` in this repository: `spikegtk.pas` is the
handler, `fixture/assets/probe.js` is the page, and
`test/cap12a/run_cap12a.sh` builds and runs it under `xvfb-run`. The three
faulting rows are `m3.post_blob_1m`, `m3.post_file_1m` and
`m3.post_formdata_1m`. A minimal C reproducer is not included here; the
sequence is three calls (`get_uri`, `get_http_method`, `get_http_body`) on a
request whose page-side body was a `Blob`.
