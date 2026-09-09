# CAP-15A — outbound network: measured, then decided

TODO.txt #1, in the reviewer's words: `PWEB_NATIVE_CSP` says
`connect-src 'self'`, so a frontend cannot reach a remote server. That makes
PWeb a platform for self-contained applications. **Is it an application
platform, and if so through which door?**

This shard measured both candidate doors on the same page, in the same window,
on every engine it could reach, and then decided. It changed no production
file: everything it built lives under `test/cap15a` (committed) and
`build/cap15a` (not committed).

**The rows are in `cap15a-measurements.md`.** This document carries the
decision, the threat model it rests on, and the contract CAP-15B is to build.

---

## HOW THE MEASUREMENT WAS BUILT, AND WHY IT CAN BE BELIEVED

One instrumented host, `test/cap15a/netprobe.pas`, ran the **same** probe page
twice per engine:

| mode | compiled against | what it shows |
|---|---|---|
| `baseline` | the shipped `src/security/pweb.navigation.policy.pas` | the product as it stands |
| `widened` | a **generated** shim of that unit whose `connect-src` also names the probe server's origin A | what a per-application CSP would open |

Four properties make the pair worth trusting:

1. **The two binaries differ by one token of one constant.** The shim is one
   exact substitution of `'connect-src ''self''; `, asserted to occur exactly
   once, written only under `build/`. Nothing widened is committed: the
   repository keeps the rule, not the result.
2. **The mode is derived, not declared.** `netprobe` reads `PWEB_NATIVE_CSP` at
   runtime and calls itself `widened` iff the policy it carries names a loopback
   origin. No environment variable can make a report claim a policy its binary
   does not have.
3. **The enforcement path is production** — the asset handler serving
   `pweb://app`, the navigation guard, the scheduler, the CAP-8A capability
   policy and the per-invocation effective snapshot. The spike parts are the CSP
   shim and `TSpikeFetchBridge`, a `pweb.fetch` `IInvocationBridge` decorator in
   the exact shape of the ratified `pweb.rpc.command.pas` layer.
4. **The server is the witness, not the page.** A dependency-free node server on
   two ports logged every request with its full header set. A page cannot read a
   `no-cors` request and could misreport the rest; a request that reached a
   socket is in the log. **Origin B is named by nothing** — not the CSP, not the
   native allowlist — so every refusal is measured as an absence.

### Coverage, stated before the conclusions

| target | engine | measured |
|---|---|---|
| `windows-x86_64` | WebView2 / Chromium 152 | **YES**, both modes |
| `linux-x86_64` | WebKitGTK 4.1 (2.52.6), WebKit 605.1.15 | **YES**, both modes, under WSLg |
| `macos-arm64` | WKWebView | **NO** |
| `macos-x86_64` | WKWebView | **NO** |

macOS is **not measured in this shard, and no claim below pretends otherwise.**
The Darwin branch of `test/cap15a/run_cap15a.sh` is written and mirrors the
proven CAP-8B recipe line for line, so the missing rows cost one run on a macOS
host. Which door that gates is the point of the recommendation: door A does not
depend on engine behaviour at all; door B cannot be specified without it.

The one prior fact this shard leans on rather than re-measuring: CAP-8B measured
on **all four** targets that `connect-src 'self'` blocked every external
connection and every `wss://` (`pweb.navigation.policy` header, ratification
R-B). The baseline runs reproduce that on two targets with a wire-level witness
the CAP-8B matrix did not have.

**RATIFIED: the two missing rows are not a baseline gap.** The baseline — that
the shipped `connect-src 'self'` refuses every external connection — is already
measured on all four targets by CAP-8B's R-B, and nothing in this shard weakens
or re-opens it. What the missing rows would add is *widened*-mode behaviour on
WKWebView: how that engine handles a named origin, its cookies and its
`no-cors` shapes. **That is door B's evidence and door B alone**, and door B is
refused below. So the CAP-15A coverage gap gates the reopening conditions and
nothing that ships.

---

## WHAT THE MEASUREMENTS SETTLED

Six findings decide the shard. Every one is a measurement; the rows and the raw
header dumps are in `cap15a-measurements.md`.

**1 — The shipped invariant holds, at the wire, and the native door works
underneath it unchanged.** In `baseline` mode, on both engines: **0** requests
the engine issued reached a socket; **27** the native door issued did. Every
engine-side shape was refused — `fetch`, `XHR`, preflighted `POST`,
`WebSocket`, `EventSource`, credentialed `fetch`, redirects, remote `<img>`,
remote `<script>`, `no-cors POST`, `sendBeacon`, and a real
`https://httpbin.org`. `sendBeacon` returned `true` while zero beacons arrived,
which is exactly why the wire log exists.

**2 — Door B works, and the `Origin` it presents is `pweb://app`.** With
`connect-src` widened, ordinary CORS applies in full on both engines: an exact
`Access-Control-Allow-Origin: pweb://app` passes, `*` passes, **`null` does
not**, a missing header does not, and `credentials: 'include'` against `*` is
refused. `httpbin.org` on the real internet echoed `Origin: pweb://app` back.

The consequence is the most important thing this shard learned: **door B does
not let an application talk to an existing API.** It lets it talk to a server
that has been *taught about PWeb* — one whose CORS configuration names the
literal string `pweb://app`. No third-party API does that, and many CDNs and
WAFs reject a non-`http(s)` `Origin` outright. Door B is therefore not "the app
can reach the internet"; it is "the app can reach a backend the developer also
modified" — which is the case door A already serves.

**3 — The engines diverge exactly where a threat model cannot tolerate
ambiguity.** WebKitGTK **stores and re-sends the remote origin's cookies**,
including on a `no-cors POST` the page cannot read and the runtime cannot see;
WebView2 sends none. Also divergent: `Origin: null` versus `pweb://app` on a
`no-cors` POST, the user's language list leaked on Windows and `C` on Linux, and
the refusal *shape* (a `securitypolicyviolation` event on Chromium, a
constructor throw on WebKit). One product, two credential models.

**4 — A named origin is a complete, uninspectable exfiltration channel.** A
`no-cors POST` and `navigator.sendBeacon` both delivered their bodies to a
server sending **no CORS headers at all**. CORS governs whether a page may
*read* a response; it never governed whether a page may *send*. Once an origin
is in `connect-src`, every line of JavaScript in the bundle can post arbitrary
bytes to it for the life of the page, with no capability check and no native
record.

**5 — Widening `connect-src` widens nothing else.** Remote images stayed refused
by `img-src` and remote scripts by `script-src-elem`, in both modes on both
engines. Door B as specified does not deliver "a normal web app": it is one
directive of a family, and each further one is its own decision with its own
blast radius.

**6 — The native door is fast enough to be the real answer, not a fallback.**
p50 **0.6 ms** on Windows and **1 ms** on Linux for the whole `page → binding →
scheduler → worker → policy → mORMot → socket → webview_return → promise` round
trip — **faster than the engine's own `fetch`** on loopback (1.0 ms), because it
skips the CORS machinery. 1 MiB crossed whole in 14–18 ms. Real TLS to
`httpbin.org` worked on both platforms. And the server sees no `Origin`, no
`Referer`, no `Cookie`, no client hints, no locale: the entire browser
fingerprint disappears.

The spike also found three defects in its own transport — mORMot silently
**re-sends** a failed request (one call, two hits on the wire); a socket timeout
is not a deadline (800 ms requested, 1609 ms observed); and the response bound
refused **after** reading all 32 MiB into memory. They are contract rows below,
not footnotes: a code review would not have found any of them.

---

## THREAT MODEL

Both rows assume what the repository assumes everywhere else: **the frontend is
the part that gets compromised** — a bad dependency, a poisoned build, a swapped
`app.pwb`.

| | door A — native fetch | door B — CSP per application |
|---|---|---|
| what authorizes a call | `ICapabilityPolicy` at the one call site, **per invocation** | nothing; the CSP is a page-load-time grant |
| where the allowlist lives | compiled into the native image | compiled into the native image (the CSP) |
| granularity | per method, principal and window, revocable at runtime (**measured**: `forbidden`, zero socket) | per origin, per document, for the life of the page |
| what a compromised frontend gains | the right to call `pweb.fetch` with a URL the native allowlist accepts, one bounded request at a time | a socket-equivalent to every named origin with no per-call gate |
| exfiltration surface | every request passes the runtime: method, URL, headers and body size are natively visible and refusable | `no-cors POST` and `sendBeacon` deliver arbitrary bytes with **zero** server cooperation (**measured**), invisible to the runtime |
| ambient credentials | none, ever: no cookie jar, no `Origin`, no `Referer` (**measured**) | **engine-dependent**: WebKitGTK sends the remote origin's cookies, WebView2 does not (**measured**) |
| identity handed to the server | a runtime user-agent and nothing else | `Origin: pweb://app`, the full UA, `sec-ch-ua` naming WebView2, and on Windows the user's language list (**measured**) |
| redirect containment | must be built (`RedirectMax = 0`) | the engines already re-check `connect-src` (**measured**) |
| what the policy can still refuse | method, origin, header set, body size, response size, deadline — and the capability itself, at runtime | **nothing**, once the page has loaded |
| observability for the operator | every call is a native invocation: countable, loggable, rate-limitable | invisible: the engine talks and the runtime does not know |
| how many engines must agree | **none** — the door never touches an engine | **four**, and the two measurable ones already disagree |

The last row is the whole decision. Door A's security properties are a property
of Pascal this repository owns; door B's are a property of four browser engines
it does not, and the two that could be measured **already differ on cookies** —
the most load-bearing detail in any web threat model.

One thing door B is genuinely better at, and it should be said: the engines'
redirect re-check is stricter than a hand-written client's default, and CORS
gives a *cooperating* backend a way to refuse a PWeb page it does not want.
Neither outweighs the rows above; neither is nothing.

---

## RECOMMENDATION — **RATIFIED 2026-09-09**

**Option A — native fetch only.** `pweb.fetch` behind the `network.fetch`
capability and a native origin allowlist. `PWEB_NATIVE_CSP` does not change:
`connect-src` stays `'self'`, byte for byte, in development and production, on
all four targets.

The reasons, in the order they carry weight:

1. **It is the repository's own rule.** `pweb.navigation.policy` exists to hold
   *one decision, shared by every engine*, and its header records that it was
   built that way because per-engine judgement (user activation) proved
   undecidable. Door B would put a **measured** per-engine security difference —
   cookies sent on Linux, not on Windows — inside the product's core promise.
   Door A has no engine surface, so the question cannot arise.
2. **Door B does not deliver what it appears to.** `Origin: pweb://app` plus
   `ACAO: null` refused means door B reaches only servers taught about PWeb —
   the case door A already serves, with a better threat model.
3. **The invariant is worth more than the convenience.** Door B converts a
   capability-checked, per-call, revocable, natively visible channel into a
   page-lifetime grant no policy can narrow and no operator can see. The
   `no-cors`/`sendBeacon` rows are not hypothetical.
4. **Door A is already fast enough to be the answer** — 0.6–1 ms p50, faster
   than the engine's own `fetch` on loopback, 1 MiB whole in 14–18 ms.
5. **It can be ratified on the evidence that exists.** Door A's behaviour does
   not depend on WKWebView, so the missing macOS rows do not block it. Door B
   cannot be specified without them.

**The brief's option C is refused as a CAP-15B scope**, and not on taste: its
opt-in half cannot be written today. A door B contract needs the WKWebView rows,
a decision about `wss://` under a widened `connect-src` (unmeasured on all
four), an engine-independent answer on cookies, and a directive-by-directive
scope for `img-src`/`media-src`/`font-src` — four open measurements. Shipping A
now and leaving C's second half unspecified is how a "both" decision quietly
becomes a B-shaped default.

**Door B is dispositioned, not forgotten.** It reopens when, and only when, all
three are true:

- the CAP-15A runner has been run on `macos-arm64` and `macos-x86_64` and the
  WKWebView rows are on record (one run each; the script is written);
- an engine-independent answer exists for the cookie divergence — either every
  engine can be made to send none, or the product accepts and documents a
  different credential model per platform. **And it is re-measured first**: the
  CAP-15A run set its cross-site cookie `SameSite=None` *without* `Secure`, over
  plaintext loopback, which a conformant engine may reject outright — so "WebView2
  sends none" may be a `SameSite` outcome rather than a jar outcome. The
  divergence is real either way, because WebKitGTK sent a cookie where WebView2
  sent none on the identical request; **which** divergence it is, is not settled,
  and a credential model cannot be written on an unsettled one;
- a named application needs something door A structurally cannot give: a
  third-party JS SDK that performs its own `fetch`, or live push that CAP-12's
  streaming work does not cover.

**What ships alongside A, so its costs are not a surprise:** the documented
limits — no remote images by URL (use `pweb.fetch` + `data:` for small, CAP-12's
blob plane for bulk), no push, no third-party fetch-performing SDKs — and the
`data:` escape hatch, measured working on both engines.

---

## CONTRACT FOR CAP-15B

A specification for the next shard, derived from the measurements. Numbers that
came from a measurement say so.

### 1. The method and where it lives

```
pweb.fetch          runtime-owned, in the reserved pweb.* namespace
network.fetch       the capability that authorizes it
```

One implementation, as an `IInvocationBridge` **decorator**, exactly like
`pweb.rpc.command.pas`: no eighth boundary, no second RPC path, no scheduler
hook, and **no authorization inside the decorator** — CAP-8A already ran.

Two units, not one, and the split is deliberate:

- `src/rpc/pweb.rpc.fetch.pas` — the decorator: argument parsing, the origin
  allowlist, the header allowlist, the bounds, the deadline, the envelope. It
  carries **no** `mormot.net.*` dependency and **no** `{$ifdef}`. The transport
  is **injected**, exactly as `pweb.rpc.command` injects the platform opener —
  which is what lets a headless test drive the whole door with no socket, and
  what lets Darwin supply a different transport without touching the decision.
- `src/rpc/pweb.rpc.fetch.mormot.pas` — the mORMot transport, selected on
  Windows and Linux, and the **only** file in shipped code permitted to name
  `mormot.net.client`.
- On Darwin the seam is filled by an `NSURLSession` transport in the adapter
  layer instead (§10). It names no `mormot.net.*` unit, so §8's "exactly one
  file names `mormot.net.client`" pin holds unchanged — which is the point of
  injecting the transport rather than conditionalising it.

`pweb.rpc.command.pas` is not touched: a runtime-owned method with a transport
has no business inside the unit whose whole claim is that it has none.

### 2. `pweb.json` schema **2**

Schema 1 has no optional keys by ratified choice, so this is a **bump** — the
visible, reviewable act the CLI contract asks for.

```json
{
  "schema": 2,
  "name": "my-app", "version": "0.1.0", "bundleId": "com.example.myapp",
  "ui": "react",
  "native":   { "program": "src/myapp.lpr" },
  "frontend": { "root": "frontend" },
  "output": "dist",
  "network":  { "origins": ["https://api.example.com", "https://auth.example.com:8443"] }
}
```

- **RATIFIED.** `network` is **required in schema 2** and `network.origins`
  **may be the empty array** — the absent-versus-empty distinction made
  explicit. `[]` does not mean "a door with nothing behind it": it means
  **`network.fetch` is absent by construction** — the decorator is not
  installed, the capability is never granted, and the door is not in the
  bridge chain at all (§3). It is what `pweb create` writes, and **`pweb
  create` emits schema 2** from CAP-15B onward.
- **RATIFIED: schema-1 projects stay valid and read as `[]`.** A schema-1
  descriptor is not deprecated, not warned about and not rewritten; the reader
  supplies the empty set, which is exactly the no-outbound-network application
  schema 1 could only be. So the bump adds a capability without invalidating a
  single existing project, and the "no optional keys" rule of schema 1 (CLI
  contract §2) is honoured rather than retro-fitted.
- **Origin grammar**, enforced at descriptor load rather than at build — a
  malformed origin is a refusal the moment the descriptor is read, in `dev`,
  `doctor` and `build` alike: scheme + lowercase host + optional `:port`, and
  nothing else. No path, query or fragment, no userinfo, no `*`, no wildcard
  label, no trailing dot, no uppercase, no IDN (punycode is the accepted
  spelling). **The scheme is `https`, and `https` alone, except for the
  development-only loopback exception ratified in the next bullet.**
  **Production is `https` only, with no wildcards and at most 8 origins.**
- **RATIFIED: loopback `http` is a DEVELOPMENT-ONLY exception, and it is the
  dev-trust model applied to the native door.** `http://127.0.0.1:<port>` and
  `http://localhost:<port>` — an explicit port, never a wildcard, never a
  non-loopback host — are accepted **only** by a host compiled under the C2 dev
  define `PWEB_DEV` (`tools/pweb/pweb.cli.toolchain.pas`,
  `PWEB_CLI_DEV_DEFINE`), and are **pinned absent from the release binary** by
  §7 and §8. This is deliberately the same shape as the `ws://127.0.0.1:<port>`
  HMR allowance ratified at CAP-10A: a development transport exception, never
  an origin exception, never selectable by a frontend field, and mechanically
  proven missing from production rather than merely intended to be. The reason
  it exists at all is that a developer's own API runs on loopback during
  development and the alternative is a self-signed certificate every developer
  installs into a machine trust store — a worse security outcome than a
  plaintext channel to their own machine that cannot survive a release build.
  An application that needs plaintext **in production** is one whose bytes
  anyone on the path can read, and a further schema bump is how that reopens.
- **Where the loopback origin is refused, and where it is not.** The descriptor
  **accepts** it — it is developer-controlled build metadata and a developer
  really does run their API on loopback. A **release** `pweb build` **refuses**
  it, by name, with its own diagnostic, and does **not** silently drop it: an
  origin that vanished between `pweb dev` and `pweb build` is a behaviour
  difference with no message anywhere, which is the exact failure class CAP-14A
  and CAP-14B exist to end. `doctor` names it first (§6), so a developer reads
  the constraint long before a build refuses on it.
- **Bounds**: at most **8** origins, each at most **262** bytes (`https://` + a
  253-byte host + `:65535`), duplicates refused after canonicalization. Eight
  covers an API, an auth host, a CDN and telemetry with room; an unbounded list
  is an unbounded surface for a reviewer to read.
- The descriptor is developer-controlled source-tree metadata, so it is a
  legitimate origin for this list — **but it is never read at runtime.**
  `pweb build` compiles the canonicalized set into the generated host as a
  Pascal literal, so `app.pwb` cannot change it. That is what keeps `AppMaximum`
  a native trust anchor.
- **No frontend field, anywhere, ever** — not `pweb.json`'s `frontend` block,
  not `app.pwb`, not `manifest.json`, not an environment variable — may name an
  origin, relax a policy or select a mode. Unchanged from CAP-10A §5.

### 3. The capability wiring

- `pweb.fetch` → `network.fetch`, mapped by the **host's** policy configuration.
- The generated host puts `network.fetch` in `AppMaximum` **iff**
  `network.origins` is non-empty, and installs the fetch decorator **iff** the
  same. An application that declared no origins cannot reach the door even by a
  native mistake, because the door is not in its bridge chain. A schema-1
  project reads as `[]` (§2) and therefore takes this branch, so **no existing
  project gains a network door by being rebuilt.**
- A nil transport at construction is a startup refusal, like a nil opener.
- Measured and to be kept: revoking the capability at runtime answered
  `forbidden` with **zero** socket activity.

### 4. The request contract

| field | rule | basis |
|---|---|---|
| `url` | absolute, `https`, origin equal to a declared origin **by parsed components** (scheme, host, port), never a prefix test. Under `PWEB_DEV` only, a declared loopback `http` origin is accepted by the same component comparison — the scheme is part of the comparison, so a dev-only origin can never match an `https` request or the reverse. **The default port is canonicalised away on both sides before comparison** (`https://api.example.com` and `https://api.example.com:443` are one origin, and declaring both is the duplicate §2 refuses); the §2 byte bound is measured on the canonical form. **The whole URL is byte-checked for CR, LF and NUL before parsing**, not only the header values: a request target is as splittable as a header and the spike checked only the headers | mirrors `PWebNavTrustedUri`'s discipline |
| `method` | `GET POST PUT PATCH DELETE HEAD` exactly, case-sensitive | — |
| `headers` | an **allowlist**: `accept`, `accept-language`, `authorization`, `content-type`, `if-match`, `if-none-match`, `if-modified-since`, plus `x-`-prefixed application headers; at most 16; any value containing CR, LF or NUL refused on the bytes. A `headers` field that is present but **not a JSON object** is `invalid_request`, never an empty header set — silently dropping every header would let a caller believe an `authorization` was sent | measured: `cookie` refused with no socket |
| `body` | ≤ **1 MiB** | JSON is the control plane; bulk is CAP-12's blob plane |
| response | ≤ **8 MiB**, enforced on `Content-Length` **and** on the running total **during the read** | measured defect: 32 MiB was read whole before refusal |
| inline body | ≤ **1 MiB** as text when valid UTF-8, else base64 with a smaller cap. **Between the inline cap and the 8 MiB ceiling the call is a typed refusal, not a success** — `service_error` with a `response_too_large_to_inline` category naming both bounds — because a success envelope with a null body and `truncated: false` is precisely the silently-half-working shape this repository refuses. `truncated` therefore never means "some of the body is here": it is reserved for a future streaming form and is `false` for every envelope this contract defines | measured: 1 MiB crossed page-to-page in 14–18 ms; and the spike itself returned a null body inside a `status: 200` envelope in exactly this window, which is how the gap was found |
| deadline | a **wall-clock total-request deadline** owned by the runtime, default 10 s, max 30 s, completing as `cancelled` and honouring the cancellation token. The token must be observable **during** the transfer and not only before it: a blocking socket read cannot see it, so the transport reads in bounded slices and checks between them — otherwise cancellation is a promise the door keeps only until the first byte | measured: an 800 ms socket timeout overshot to 1609 ms; and the spike checked its token only at entry |
| retries | **none**. The transport suppresses mORMot's own retry (`AsRetry := true`, or `RequestInternal` directly) | measured: one call, two `/slow` hits on the wire |
| redirects | `RedirectMax = 0`. A 3xx is returned with its `Location`; the runtime never follows one, because following it leaves the allowlist behind | measured: both engines re-check `connect-src` on a redirect target, and the door must be no weaker |
| proxy | never inherited; the transport passes an explicit no-proxy | mORMot's convenient entry points default to the system proxy |
| TLS | certificate validation on, and **no setting anywhere** — descriptor, environment, argument or Pascal — that can disable it. `https` is the only scheme a release binary can carry; the `PWEB_DEV` loopback exception of §2 is the one plaintext case, and it cannot be compiled into a release | — |
| cookies | no jar, no `Set-Cookie` honoured, no `Cookie` ever sent; an application carries its own `authorization` | measured: the native door sent none |
| streaming | out of scope: one request, one bounded response | — |

**Which of these the spike actually exercised, since the distinction matters.**
The rows marked *measured* were driven end to end by `TSpikeFetchBridge`. The
rest are **specified beyond the instrument**, and a CAP-15B reader should treat
them as contract rather than as evidence: `PATCH` (the spike refuses it), the
case-sensitive method comparison (the spike upper-cases first), `if-match` and
the general `x-` header prefix (the spike allows one literal header name), the
response-header allowlist, and the deadline's mid-transfer cancellation. That
list is not an apology — an instrument is built to answer a question, not to be
the implementation — but a contract row whose only witness is a spike that
contradicts it is a row somebody will later mistake for a measurement.

### 5. The response envelope

```json
{ "status": 200, "ms": 12, "bytes": 1234, "truncated": false,
  "headers": { "content-type": "application/json" },
  "bodyText": "…", "bodyBase64": null }
```

Response headers are an **allowlist too** — `content-type`, `content-length`,
`etag`, `last-modified`, `retry-after`, `location`, `x-`-prefixed — and
**`set-cookie` is never exposed**, so nothing in JavaScript can reconstruct a
jar the runtime refused to keep. `location` is in the list because §4 returns a
3xx with its `Location` instead of following it; an allowlist that omitted it
would have promised a redirect the envelope could not carry. A transport failure is `service_error` with a category, never a
native detail; the nine-code taxonomy is unchanged.

### 6. `pweb doctor` rows

| check | severity | applies | what it reports |
|---|---|---|---|
| `project.network_origins` | required | schema ≥ 2 | present, well-formed against the grammar, within the count and byte bounds, canonical and duplicate-free — and a declared loopback origin is reported **by name** as development-only, so a developer reads before a release build refuses |
| `platform.tls` | required | `network.origins` non-empty | which provider **this target** resolves: SChannel on Windows; OpenSSL ≥ 3 on Linux, named and version-reported; the Darwin answer from §8 |

`doctor` stays diagnostic-only: it **must not** connect to a declared origin,
resolve its name, or open a socket. It reads the descriptor and inspects the
machine, exactly as it does for every other row.

### 7. What `pweb build` must prove about the production artifact

1. **The CSP did not move.** `PWEB_NATIVE_CSP` in the built host is
   byte-identical to the shipped constant, `connect-src 'self'` included. Door
   A's strongest claim is that it changes nothing here, and the build says so
   mechanically.
2. **The compiled allowlist equals the declared set.** A digest over the sorted,
   canonicalized origins, computed from `pweb.json` and again from the generated
   Pascal literal in the built host, must match. That is the "production carries
   exactly the declared set" the brief asked for.
3. **The production binary carries no relaxation**: no `http://` origin literal,
   no `127.0.0.1`, no `localhost`, no `*`, no wildcard, no
   `IgnoreTlsCertificateErrors`, no proxy literal, no second file naming
   `mormot.net.client`. The loopback exception of §2 lives inside
   `{$ifdef PWEB_DEV}` and a release build is compiled without that define, so
   this proof is a **byte sweep of the built release image** and not a promise
   about source — the same standard the `ws://127.0.0.1` allowance has met on
   every leg since CAP-10A.
4. **`app.pwb` carries no network declaration.** The bundler refuses a manifest
   or descriptor field named `network`, `origins`, `connect` or `csp` with its
   own typed cause — the CAP-14A family, where the bundler refuses what the
   native policy will not honour.
5. **`network.fetch` is in `AppMaximum` iff origins were declared**, and the
   fetch decorator is installed iff the same.
6. **The zero-transport gates are re-scoped, not deleted.**
   `test/cap7l/check_cap7l_nonetwork.sh`, `test/cap7m/check_cap7m_nonetwork.sh`,
   `test/cap5`, `test/cap6`, `test/cap9c1` and the CAP-4 composite action
   currently forbid `mormot.net.(server|client|http)` and `socket` across a named
   file list. Their claim becomes, explicitly: **no listening socket, no server,
   no second RPC path — and the only outbound client in the image is
   `pweb.rpc.fetch.mormot`, reachable only through `network.fetch`.** The runtime
   half (this process owns no listening TCP socket) is unchanged and still
   passes; it was always the load-bearing half.

### 8. `check_dev_trust` extension

Add a CAP-15B section to `test/cap10a/check_dev_trust.ps1`, in the style of its
existing five:

- `PWEB_NATIVE_CSP` still carries `connect-src 'self'` and still contains no
  `ws:`, `wss:`, `http:`, `localhost` or `127.0.0.1` — **unchanged**, and now
  load-bearing for a second reason: it is the mechanical proof that door B was
  not taken.
- **No `https://` origin literal appears anywhere in `src/**`.** The allowlist is
  generated into an application, never present in the runtime.
- **The loopback exception is pinned to the dev define and to nothing else.**
  Every `127.0.0.1` and `localhost` occurrence in the fetch units lies inside a
  `{$ifdef PWEB_DEV}` region; no release compile path defines `PWEB_DEV`; and
  the built **release** image contains no loopback literal. The gate's existing
  section 1 — `PWEB_NATIVE_CSP` carries no `ws:`, `wss:`, `http:`, `localhost`
  or `127.0.0.1` — is unchanged, so the CSP and the native door are pinned
  apart: widening one can never be mistaken for widening the other.
- Exactly **one** file in `src/**` names `mormot.net.client`, and it is
  `src/rpc/pweb.rpc.fetch.mormot.pas`.
- `src/rpc/pweb.rpc.fetch.pas` names no `mormot.net.*` unit, no platform
  conditional and no operating system — the CAP-7F zero-conditional core list
  gains it.
- Both generated `program.lpr` templates install the fetch decorator only inside
  the region the descriptor's origins control, so a project that declared none
  cannot link the door.

### 9. What CAP-15B does **not** touch

`pweb.assets.htmlpolicy` needs **no change**: door A widens no directive, so the
four CAP-14A refusal classes are exactly as correct after it as before. (Under
door B the classifier would have had to learn each application's effective CSP —
a cost door B avoids paying only by not existing.)

### 10. TLS on Darwin — **DECIDED: `NSURLSession`, option 2**

Measured: Windows needs nothing new (SChannel is inside mORMot); Linux works
with **OpenSSL 3.0.13**, a runtime dependency the product does not currently
have and which `docs/third-party-licenses.md` does not list. macOS ships no
`libssl.dylib` in a default install. The three candidates were:

1. ship OpenSSL in the `.app` — a new bundled dependency, a licence row and a
   notarization consideration; **REFUSED**;
2. a second transport over `NSURLSession` behind the same injected seam;
   **RATIFIED**;
3. declare macOS network support out of scope for 15B; **REFUSED**.

**The ruling.** The Darwin transport is `NSURLSession`, written behind the
injected seam of §1, **in the adapter layer** — beside the existing
`pweb.platform.*` Cocoa work, not inside `src/rpc/pweb.rpc.fetch.pas`, which
keeps its no-`{$ifdef}`, no-`mormot.net.*` promise — and it uses the **system
trust store**. The measured cost is one platform file and no new dependency.

Why the other two are refused, since a refusal is worth more than a preference:
shipping OpenSSL inside the `.app` adds a bundled cryptographic library to a
product whose whole claim is that it bundles no engine, and it buys a second
trust store to keep current for the life of the application — a licence row and
a notarization surface in exchange for a worse security posture than the one
the operating system already maintains. Scoping macOS out is refused because
`doctor` would then report a `platform.tls` row that says the product does not
work on a target the product ships on, which is not a limitation but a hole.

**Measured at 15B's Checkpoint 1, not assumed.** `NSURLSession` is asynchronous
and completion-handler based where the seam is a bounded synchronous call on a
worker thread, and that adaptation — plus the deadline of §4, the redirect
refusal, the response bound enforced *during* the read, and the absence of a
cookie jar (`NSURLSession` has an ambient one by default and it must be turned
off, not merely unused) — is exactly what a checkpoint measurement is for. If
the measurement contradicts this ruling, that is a finding to bring back, not a
licence to fall through to option 1 or 3.

The injected transport is what makes this one platform file rather than a
redesign, which is why §1 splits the two units.

---

## LEDGER

| id | item | disposition |
|---|---|---|
| 15A-1 | TODO.txt #1, the outbound-network question | **ANSWERED and RATIFIED** — door A, door B dispositioned with three named reopening conditions, recorded in `docs/cli-contract.md` §5 |
| 15A-2 | macOS/WKWebView rows | **OWED, and door B's alone** — one run of `test/cap15a/run_cap15a.sh` per macOS architecture. The **baseline** is not owed: CAP-8B's R-B already measured `connect-src 'self'` refusing every external connection on all four targets. What is missing is widened-mode WKWebView behaviour, which only door B needs |
| 15A-3 | `wss://` under a widened `connect-src` | **OWED**, four targets. Only door B needs it |
| 15A-4 | mORMot re-sends a failed request | **CONTRACT ROW** for 15B (§4 retries) |
| 15A-5 | a socket timeout is not a deadline | **CONTRACT ROW** for 15B (§4 deadline) |
| 15A-6 | a response bound enforced after the read | **CONTRACT ROW** for 15B (§4 response) |
| 15A-7 | mORMot's convenient entry points inherit the system proxy | **CONTRACT ROW** for 15B (§4 proxy) |
| 15A-8 | OpenSSL is a new runtime dependency on Linux; macOS has no provider | **DECIDED** (§10): Darwin gets an `NSURLSession` transport behind the injected seam, in the adapter layer, on the system trust store, measured at 15B's Checkpoint 1. Bundling OpenSSL and scoping macOS out are both refused. The Linux OpenSSL runtime dependency still owes a `docs/third-party-licenses.md` row and a `doctor` `platform.tls` line |
| 15A-9 | WebKitGTK sends the remote origin's cookies, WebView2 does not | **RECORDED** — the decisive divergence against door B; must be resolved before B reopens |
| 15A-10 | the zero-transport source sweeps need re-scoping | **CONTRACT ROW** for 15B (§7.6) |
| 15A-11 | remote images by URL remain refused under both doors, and the directive-by-directive scope for `img-src`/`media-src`/`font-src` is undecided | **DOCUMENTED LIMIT** — `pweb.fetch` + `data:` for small, CAP-12 blob plane for bulk. The scoping decision named in the option-C refusal lands here rather than becoming a fourth reopening condition: it is a question only a door-B contract asks, so it is owed **with** condition 1 and not before it |
| 15A-12 | the CAP-15A spike itself | **KEEP UNTIL 15B CLOSES**, then reduce: `probe_server.js` and the `pweb.fetch` rows become the seed of a headless transport test with no socket |
| 15A-13 | the fixture's own bare recursive delete, on both runners | **CLOSED at ratification** — each runner now validates a delete target against `build` before removing it, and section 5b of `test/backlog/check_backlog.ps1` re-measures that, plus the "never a CI step" claim and the shim needle, on every hosted Windows leg |
| 15A-14 | seven further bounds on the measurements, found by reviewing the instrument after it ran | **RECORDED, not repaired** — the code is what produced the numbers, so the bounds go in `cap15a-measurements.md`. The cookie row is load-bearing: it narrows *which* divergence was measured and sharpens reopening condition 2, without moving the decision |
| 15A-15 | the runners would have failed on the macOS host 15A-2 owes | **CLOSED at ratification** — bash 3.2 aborts on an empty array expansion under `set -u`, so the Darwin leg died before compiling anything; fixed with option validation, a flushed wire log, and the widened shim removed at the end of a run. No measurement semantics moved |

---

## FREEZE

No source is frozen by this shard: it ratifies a **direction**, not an
implementation. What it does fix, so CAP-15B starts from it rather than from a
fresh guess:

- `PWEB_NATIVE_CSP` **does not change** for door A. `connect-src` stays `'self'`
  in development and production, on all four targets. If a CAP-15B commit moves
  that constant, it has left this decision.
- The names: `pweb.fetch`, `network.fetch`, schema 2's `network.origins`,
  `src/rpc/pweb.rpc.fetch.pas` + `src/rpc/pweb.rpc.fetch.mormot.pas`, and
  doctor's `project.network_origins` and `platform.tls`.
- The shape: an injected transport behind a decorator, which is what makes
  §10's Darwin answer one platform file rather than a redesign.
- **The four ratified rulings**, which CAP-15B implements rather than revisits:
  `network.origins` required in schema 2 and permitted to be empty, with `[]`
  meaning the door is absent by construction and schema-1 projects reading as
  `[]` (§2, §3); loopback `http` permitted **only** under `PWEB_DEV` and pinned
  absent from the release image, production `https` only, no wildcards, at most
  eight origins (§2, §7, §8); `NSURLSession` behind the injected seam as the
  Darwin transport, on the system trust store, measured at 15B's Checkpoint 1
  (§10); and the macOS coverage gap belonging to door B alone (Coverage).

No production file was modified. Everything built lives in `test/cap15a/`
(committed) and `build/cap15a/` (not committed), and the widened shim no longer
survives the run that produces it.

`test/cap15a` is **never a CI step** — a run compiles a binary whose
`connect-src` has been widened, and a gate that compiles a widened CSP is a gate
that can normalise one. That claim is now pinned rather than merely written
down: section 5b of `test/backlog/check_backlog.ps1` refuses if anything under
`.github` names the directory. Reading a file is not running it, which is why
the same section can also re-measure `15A-13`'s closure and the shim needle
without building anything.

---

## VERDICT

```
CAP-15A RATIFIED  —  option A, native fetch
```

PWeb **is** an application platform, and the door is **A — native fetch**:
`pweb.fetch` behind the `network.fetch` capability and a native,
per-application origin allowlist, with the frontend's `connect-src` left at
`'self'` exactly as it ships today.

The measurement that decides it is not a preference. Door B works, on both
engines that could be measured — and it works *differently* on each of them, in
the one place a threat model cannot tolerate ambiguity. Door A does not touch an
engine at all, and it is already faster than the engine's own `fetch`.

**Ratified on 2026-09-09**, with four rulings folded into the CAP-15B contract
above: schema 2's `network.origins` required and permitted to be empty (§2, §3);
loopback `http` as a `PWEB_DEV`-only exception pinned absent from the release
image (§2, §7, §8); `NSURLSession` as the Darwin transport behind the injected
seam (§10); and the macOS coverage gap belonging to door B alone (Coverage).

CAP-15B is **not** begun.
