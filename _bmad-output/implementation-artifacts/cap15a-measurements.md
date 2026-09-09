# CAP-15A — the measurements

Evidence companion to `cap15a-decision-artifact.md`, which carries the decision
and the CAP-15B contract. This file carries the rows: what each engine actually
did, at the wire, and what the spike's own transport got wrong. Read the
decision first; come here to check it.

Raw evidence, all under `build/cap15a/` (not committed):

```
summary-windows-x86_64.json   summary-linux-x86_64.json      the joined evidence
<target>-baseline.json        <target>-widened.json          the host reports
requests-<target>-<mode>.jsonl                               the server's wire log
```

The instrument is `test/cap15a/` and its README explains how to re-run it. In
short: one host, two builds per engine differing by **one token** of
`PWEB_NATIVE_CSP` (`baseline` = the shipped `connect-src 'self'`; `widened` =
that plus the probe server's origin A), the mode **derived** from the constant
the binary carries rather than declared, the production enforcement path
throughout, and a two-port node server whose JSONL log is the witness for
everything the page cannot read. **Origin B is named by nothing**, so every
refusal is measured as an absence.

## Coverage

| target | engine | measured |
|---|---|---|
| `windows-x86_64` | WebView2 / Chromium 152 (`Edg/152.0.0.0`) | **YES**, both modes |
| `linux-x86_64` | WebKitGTK 4.1 (2.52.6), WebKit 605.1.15 | **YES**, both modes, under WSLg |
| `macos-arm64` | WKWebView | **NO** |
| `macos-x86_64` | WKWebView | **NO** |

## 0 — the shipped product, at the wire

| | windows-x86_64 | linux-x86_64 |
|---|---|---|
| requests the **engine** put on a socket | **0** | **0** |
| requests the **native door** put on a socket | 27 | 27 |
| requests that reached the unnamed origin B | 0 | 0 |
| host report | `COMPLETE` | `COMPLETE` |

Every engine-side row was refused and nothing reached a socket, while the native
door worked in the same binary under the same unmodified CSP.
`navigator.sendBeacon` returned `true` on both engines while **zero** beacon
arrived — a page cannot tell whether a beacon left; the wire log can.

## The page's own view of itself (identical on both engines)

```json
{"origin":"pweb://app","protocol":"pweb:","host":"app","secureContext":true,
 "crossOriginIsolated":false,"hasWebSocket":true,"hasEventSource":true,
 "hasSendBeacon":true,"hasSubtleCrypto":true,"hasServiceWorker":true,
 "hasStorage":true}
```

`pweb://app` is a real tuple origin and a secure context on both engines — which
is why CORS works at all under the widening, and why `Origin` is a usable value
rather than `null`. This confirms at the wire what CAP-4W's
`HasAuthorityComponent` + `TreatAsSecure` and CAP-7L's
`register_uri_scheme_as_secure` + `_as_cors_enabled` were for.

## M1 — fetch / XHR

| row | win base | linux base | win widened | linux widened |
|---|---|---|---|---|
| simple GET, `ACAO: <origin>` | blocked-csp | blocked-csp | **ok 200** | **ok 200** |
| simple GET, `ACAO: *` | blocked-csp | blocked-csp | **ok 200** | **ok 200** |
| simple GET, `ACAO: null` | blocked-csp | blocked-csp | **refused (CORS)** | **refused (CORS)** |
| simple GET, no `ACAO` | blocked-csp | blocked-csp | refused (CORS) | refused (CORS) |
| preflighted `POST` + custom header | blocked-csp | blocked-csp | **ok 200** | **ok 200** |
| preflight answered without CORS | blocked-csp | blocked-csp | refused (CORS) | refused (CORS) |
| `XMLHttpRequest` GET | blocked-csp | blocked-csp | **ok 200** | **ok 200** |
| GET the **unnamed** origin B | blocked-csp | blocked-csp | **blocked-csp** | **blocked-csp** |
| GET `https://httpbin.org/get` (real internet) | blocked-csp | blocked-csp | **ok 200** | **ok 200** |

**`Origin: pweb://app`** on every engine-side request on both engines —
preflight, WebSocket upgrade and the real-internet call included.
`httpbin.org` echoed the whole header set back:

```
"Origin": "pweb://app",
"Sec-Ch-Ua": "\"Microsoft Edge\";v=\"152\", … \"Microsoft Edge WebView2\";v=\"152\"",
"Accept-Language": "fr,fr-FR;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6"   (Windows)
"Accept-Language": "C"                                                 (Linux)
```

The full header set a widened engine request carries, from the wire log:

```
windows: host connection sec-ch-ua-platform user-agent sec-ch-ua sec-ch-ua-mobile
         accept origin sec-fetch-site sec-fetch-mode sec-fetch-dest
         accept-encoding accept-language
linux:   origin accept user-agent accept-encoding accept-language connection host
         sec-fetch-dest sec-fetch-mode sec-fetch-site
```

Preflights carried `Access-Control-Request-Headers: content-type,x-cap15a` on
both engines. **Ordinary CORS semantics apply in full**, and `ACAO: null` does
**not** satisfy an `Origin: pweb://app` request — which kills the "just answer
null" workaround before anyone proposes it.

## M2 — WebSocket and EventSource

| row | win base | linux base | win widened | linux widened |
|---|---|---|---|---|
| `ws://` to the named origin | blocked-csp | threw | **ok, 2 frames** | **ok, 2 frames** |
| `ws://` to the unnamed origin | blocked-csp | threw | blocked-csp | **threw** `The operation is insecure.` |
| `EventSource`, `ACAO: <origin>` | blocked-csp | threw | **ok, 3 events** | **ok, 3 events** |
| `EventSource`, no `ACAO` | blocked-csp | threw | error | error |

Both work under the widening; the upgrade carries `Origin: pweb://app` on both
engines. **The refusal shape diverges**: Chromium raises a
`securitypolicyviolation` naming `connect-src`, WebKit throws from the
constructor and reports no violation event. A frontend that wants to detect the
refusal must handle both.

`wss://` is **not measured** — the spike has no TLS server. CAP-8B's four-target
result stands for the baseline; a widened `connect-src` with `wss://` is
unmeasured everywhere.

## M3 — cookies, credentials, redirects

| row | win widened | linux widened |
|---|---|---|
| `document.cookie` write then read on `pweb://app` | accepted, **reads back empty** | accepted, **reads back empty** |
| credentialed `fetch` receiving `Set-Cookie` | ok 200 | ok 200 |
| the next credentialed request's `Cookie` header | **absent** (`{"cookie":null}`) | **`c15a_lax=1`** |
| `credentials: 'include'` against `ACAO: *` | refused (CORS) | refused (CORS) |
| redirect within the named origin | ok 200 | ok 200 |
| redirect **into the unnamed** origin | **blocked-csp** (`connect-src`) | **blocked-csp** (`connect-src`) |
| `Referer` seen by the server, any row | **never** | **never** |

1. **The `pweb://app` origin has no cookie jar of its own.** A write is accepted
   and reads back empty on both engines.
2. **WebKitGTK stores and re-sends the *remote* origin's cookies; WebView2 does
   not.** The Linux wire log:

   ```
   /cookiecheck?acao=origin&acac=1 -> c15a_lax=1
   /echo?acao=star                 -> c15a_lax=1
   /exfil?acao=none                -> c15a_lax=1
   ```

   The third line is the serious one: the cookie rode a **`no-cors` POST**, a
   request the page cannot read and the runtime cannot see. Windows sent no
   cookie on any row. One product, two credential models.
3. **Both engines re-apply `connect-src` to a redirect target**, and **server B
   was never reached in any of the four runs**. The engines are stricter here
   than a hand-written native client's default — a requirement door A must copy,
   not a bonus.

`Referer` was never sent on any row: the `Referrer-Policy: no-referrer` that
already rides every `pweb://app` response pays for itself outbound too.

## M4 — the native door (`pweb.fetch`)

Measured in **both** modes, i.e. including under the shipped, unmodified
`connect-src 'self'`.

| row | windows | linux |
|---|---|---|
| GET, loopback | ok 200 | ok 200 |
| POST with a JSON body | ok 200 | ok 200 |
| GET `https://httpbin.org/get` (real TLS) | **ok 200**, 1412–1560 ms | **ok 200**, 835–1393 ms |
| TLS provider actually used | SChannel, already inside mORMot | **OpenSSL 3.0.13**, a new runtime dependency |
| header outside the allowlist (`cookie`) | `invalid_request`, no socket | `invalid_request`, no socket |
| origin outside the **native** allowlist | `invalid_request`, **0 requests at B** | `invalid_request`, **0 requests at B** |
| 1 MiB response, page to page | 16–18 ms | 14 ms |
| 32 MiB response | `service_error` "over the 8388608 byte bound" | same |
| 20 × 1 KiB GET, `performance.now()` p50 | **0.6 ms** (min 0.5, max 1.1) | **1 ms** (min 1, max 3) |
| the engine's own `fetch`, same series, widened | 1.0 ms (min 0.9, max 2.0) | 1 ms (min 0, max 1) |
| capability revoked at runtime, then called | `forbidden`, **no socket** | `forbidden`, **no socket** |

**What the server sees from the native door:** no `Origin`, no `Referer`, no
`Cookie`, no `Sec-Fetch-*`, no client hints, no `Accept-Language`. The whole
browser fingerprint — including the string `Microsoft Edge WebView2` and the
user's language list — disappears:

```json
"headers": {"Accept":"*/*","Host":"httpbin.org","User-Agent":"PWeb-CAP15A-spike"}
```

**The native door is not slower than the engine.** On loopback it is faster
(0.6 ms against 1.0 ms on Windows) because it skips the engine's CORS
machinery; against the real internet the difference vanishes under network
latency. The whole `page → binding → scheduler → worker → policy → mORMot →
socket → webview_return → promise` round trip costs well under a millisecond.

### What a pure network client can and cannot do through this door

Works today: fetch JSON, render it, authenticate with its own `authorization`
header, poll.

Cannot, measured:

- **remote images by URL** — `img-src 'self' data:` refuses them in *both* modes.
  The measured escape hatch is `pweb.fetch` → base64 → `data:` URL, which loaded
  on both engines (`naturalWidth=1`). Right for icons, wrong for bulk — the
  kernel already forbids base64 bulk and CAP-12's blob plane is the answer.
- **live push** — no `WebSocket`, no `EventSource`, no streaming.
- **third-party JS SDKs that perform their own `fetch`** — analytics, maps,
  payments simply will not work. This is the honest cost of door A.

### Three defects the spike found in its own transport

Each is now a contract row in the decision artifact's §4.

1. **mORMot re-sends a failed request.** `THttpClientSocket.Request` "already
   retries by itself" (its own declaration comment,
   `deps/mormot2/src/net/mormot.net.client.pas:876`). One `pweb.fetch` with an
   800 ms bound produced **two** `/slow` hits in the wire log. For a
   non-idempotent `POST` that is a duplicate order, not a slow one.
2. **A socket timeout is not a deadline.** `THttpClientSocket.Create(800)`
   yielded an observed 1603–1622 ms and returned mORMot's `666` client-error
   status rather than raising.
3. **The response bound refused *after* reading everything.** 32 MiB was pulled
   whole into memory in 50–60 ms and *then* rejected, so a hostile or
   misconfigured server can make the process allocate at will.

And one found by reading rather than measuring, worth as much: mORMot's
convenient entry points (`OpenUri`, `OpenOptions`, `TSimpleHttpClient`) default
`THttpRequestExtendedOptions.Proxy` to `''`, which means **"use the system
proxy"**. A door built on them would route an application's traffic through a
machine setting nobody declared. The spike used `Create` + `OpenBind`, which
consults nothing.

## M5 — what a widened `connect-src` does not widen, and what it hands away

| row | win base | linux base | win widened | linux widened |
|---|---|---|---|---|
| remote `<img src>` | blocked (`img-src`) | blocked (`img-src`) | **blocked (`img-src`)** | **blocked (`img-src`)** |
| remote `<script src>` | blocked | blocked | **blocked (`script-src-elem`)** | **blocked (`script-src-elem`)** |
| `no-cors POST`, server sends **no** CORS headers | nothing arrived | nothing arrived | **body delivered** | **body delivered** |
| `navigator.sendBeacon`, same | nothing arrived | nothing arrived | **body delivered** | **body delivered** |

**Widening `connect-src` widens nothing else.** The remote image is still refused
by `img-src`, the remote script by `script-src-elem`. Door B as literally
specified does not deliver "a normal web app": it is one directive of a family,
and each further one (`img-src`, `media-src`, `font-src`, `style-src`) is its own
decision with its own blast radius.

**A named origin is a complete, uninspectable exfiltration channel.** From the
widened wire log, on both engines:

```
exfil POST /exfil?acao=none  body=CAP15A-EXFIL-NOCORS-widened
exfil POST /exfil?acao=none  body=CAP15A-BEACON-widened
```

`?acao=none` means the server sent **no CORS headers at all**. CORS governs
whether a page may *read* a response; it has never governed whether a page may
*send*. Once an origin is in `connect-src`, every line of JavaScript in the
bundle can post arbitrary bytes to it, for the life of the page, with no
capability check, no native record, and no way for the page's own author to
notice.

## Bounds and honest limits of this measurement

- **macOS/WKWebView is unmeasured**, on both architectures. Every table says so.
- **The transport measured was loopback plain `http` plus one real internet
  origin** (`httpbin.org`). Loopback is deliberate: `127.0.0.1` is a
  potentially-trustworthy origin, so secure-context and mixed-content questions
  do not contaminate the CORS measurement. Plain `http` to a **non-loopback**
  host from a `TreatAsSecure` page is mixed content and was not measured; the
  proposed schema-2 grammar refuses `http://` anyway.
- **`wss://` under a widened `connect-src` is unmeasured** on all four engines.
- **`nativeMs` in the host reports is coarse** — it comes from `GetTickCount64`,
  whose resolution is ~10–16 ms on Windows. A `nativeMs` of 0 beside a `pageMs`
  of 18 means "below the native clock's resolution", not "instantaneous". Every
  latency figure quoted is from the page's `performance.now()`.
- **The latency figures are loopback figures on one developer machine**, and the
  20-sample series is a sanity measurement, not a benchmark. They support the
  qualitative claim — the native door is not slower than the engine's own
  `fetch` — and no number in a datasheet.
- **The exfiltration rows prove delivery, not undetectability everywhere.** A
  network observer or an outbound firewall still sees the traffic; what is
  measured is that **nothing inside PWeb** sees or can refuse it.
- **`TSpikeFetchBridge` is not the contract.** It is one implementation, and
  three of its behaviours are recorded above precisely because they are wrong
  for a product.

### Found by reviewing the instrument after it ran, and recorded rather than repaired

An adversarial read of the instrument at ratification found seven more bounds.
None of them moves the decision; two of them narrow a claim, and the first is
the load-bearing one. They are written here rather than fixed in the code,
because the code above is the code that produced the numbers above, and an
instrument quietly edited after its run is an instrument nobody can audit.

- **The cookie row is narrower than it reads, and it is the row that decided the
  shard.** `/setcookie` sets `c15a_none=1; Path=/; SameSite=None` **without
  `Secure`**, over plaintext loopback. A conformant engine rejects
  `SameSite=None` without `Secure` outright, so the only cookie that could
  certainly have been stored is the `Lax` one — and a `Lax` cookie is not
  expected on a cross-site request in the first place. What is measured is that
  **WebKitGTK sent a cookie on a request where WebView2 sent none**: the
  divergence is real. Whether it is a *jar* divergence or a *`SameSite`*
  divergence is **not** settled, and reopening condition 2 now says so and
  requires a re-measurement over `https` with a correctly formed cookie.
- **The `script-src-elem` refusal is not unambiguous.** `m5.remote-script` points
  at `/echo?acao=star`, which answers `application/json`; a module MIME check
  refuses that too. The conclusion — widening `connect-src` widens nothing else —
  is corroborated by the `img-src` row, which has no such ambiguity, but the
  script row on its own does not carry it. A re-run should point at a real `.js`
  route.
- **The mode derivation is a substring test over the whole CSP, not over
  `connect-src`.** `netprobe` calls itself `widened` when `127.0.0.1` appears
  anywhere in `PWEB_NATIVE_CSP`. That is sound for every binary that has ever
  been built — the shipped constant carries no loopback term in any directive —
  but it is a weaker property than the claim "derived from the constant". A
  re-run should test the `connect-src` term the shim actually substitutes,
  especially now that a CAP-15B **dev** host may legitimately carry a loopback
  origin outside the CSP.
- **Two native counters count more than their names say.** `CountFetchOk` is
  incremented when the transport returns, before the response-bound refusal, so
  an over-bound response is counted as a success; `CountFetchRefusedUri` also
  counts method and body-bound refusals. Both are diagnostics: the graded
  baseline row is computed from the **wire log**, not from these, so the
  conclusion does not rest on them.
- **`summarize.js` splits native from engine traffic by user-agent alone**, while
  the host report in the same object carries `native.fetch_attempted`. Joining
  the two would corroborate "0 engine-side requests" instead of trusting one
  header comparison.
- **A response between 4 MiB and 8 MiB was never issued**, and in that window the
  spike returns a success envelope with `truncated: false` and no body at all.
  The driver requests only 1 MiB and 32 MiB, so the window is latent rather than
  measured — and it is why the ratified §4 makes that range a typed refusal.
- **`p50` is the upper median.** With an even sample count the driver takes
  `okms[n/2]` rather than averaging the two middle values. At 20 samples on a
  sub-millisecond loopback series this changes nothing a conclusion rests on.
