# CAP-15C — Checkpoint 1

Branch `phase/cap-15/c-native-socket-door`, cut from `main` at
`245ad806abdb7c7a988a66f533ee97ae331a10ce`. **Nothing under `src/` is
written.** What exists is the instrument this checkpoint asked for, and the
numbers it produced:

| file | what it is |
|---|---|
| `test/cap15c/ws_server.js` | a dependency-free RFC 6455 server (node's own `http`, `https`, `crypto`) whose JSONL log is the independent witness. It is **not a mORMot peer**, and nothing in it knows mORMot exists |
| `test/cap15c/wsspike.pas` | one row suite, two candidate transports: `m.*` mORMot's `THttpClientWebSockets` in raw-frame mode (the brief's shape) and `r.*` RFC 6455 framing written over `mormot.net.sock`'s `TCrtSocket` |
| `test/cap15c/run_cap15c_spike.ps1` | builds the spike, starts a plaintext witness and a self-signed wss witness, runs each transport in its **own process**, stops the witnesses through stdin so their logs flush, joins the rows with the wire |

Measured on **windows-x86_64** and **linux-x86_64** (WSL, Ubuntu 24.04, FPC
3.2.3, OpenSSL 3.0.13), 349 rows per target, in
`build/cap15c/{win,linux}/spike-<target>.json` (not committed). The first run
of the mORMot transport alone is kept beside them as
`spike-run1-mormot-<target>.json`.

**CAP-15B, verified rather than assumed.** HEAD `245ad80` is green on hosted CI
twice: run `34480791403` on `phase/cap-15/b-native-fetch-door` and run
`34852822671` on `main`, both `success`. Two things the repository does not yet
say, recorded here and not repaired (the shard is closed, and this one is not
its closure): `cap15b-final-artifact.md` still opens with `CAP-15B NOT READY`,
and no closure commit names the green run. Separately, the `v0.2.0` tag's CI run
`34852821007` on the same SHA concluded `failure`; it was not investigated,
because it is a tag run and not the branch or `main` run the shard's
acceptance names.

---

## 1. Raw-frame interop with a standard server — MEASURED FIRST

### The row, on both targets and both transports

| row | m (mORMot ws.client) win / linux | r (own framing over TCrtSocket) win / linux |
|---|---|---|
| handshake to a non-mORMot RFC 6455 server | ✓ / ✓ | ✓ / ✓ |
| two subprotocols offered, server selects `json.v2` | ✓ / ✓ **only with an override** (stock class: `Invalid HTTP Upgrade Sub-Protocol`) | ✓ / ✓ |
| subprotocol not offered by client | refused / refused | refused / refused |
| offered one, server selects none | **accepted** / **accepted** | refused / refused |
| offered two, server selects none | refused / refused | refused / refused |
| UTF-8 text echo, 256-byte binary echo | ✓ / ✓ | ✓ / ✓ |
| 1 MiB binary, client → server → client, sha256 equal | ✓ 16 ms / ✓ 8 ms | ✓ 16 ms / ✓ 16 ms |
| fragmentation: 100 000-byte text and binary in 7 frames, reassembled natively, sha256 equal | ✓ / ✓ | ✓ / ✓ |
| **a PING between two fragments** (RFC 6455 §5.4: control frames MAY be injected) | **connection killed, 1006** / **1006** | ✓ delivered, ping answered / ✓ |
| server PING `probe-1` answered natively, same payload, never in the page's queue | ✓ / ✓ | ✓ / ✓ |
| server-initiated close `4001`/`bye` surfaced as an event | ✓ / ✓ **only with `NotifyAllFrames = true`** | ✓ / ✓ |
| client close `4000`/`done` on the wire, echo surfaced | ✓ / ✓ | ✓ / ✓ |
| TCP dropped with no close frame | 1006 / 1006 | 1006 / 1006 |
| handshake answered `302 Found` | refused, `HTTP/1.1 302 Found`; witness 1 hit, **0 followed** | same |
| handshake answered `200 OK` | refused | refused |
| wss to a **self-signed loopback** certificate | refused: SChannel `80090325` / OpenSSL `certificate verify failed (self-signed certificate)`; witness 0 upgrades, `ECONNRESET` / `TLSV1_ALERT_UNKNOWN_CA` | same |
| handshake the server holds 5000 ms, 1000 ms bound | **upgraded at 5000–5016 ms** / **5000–5003 ms** | refused `handshake deadline` at **1016 ms** / **1009 ms** |
| unroutable connect `192.0.2.1:9`, 1000 ms bound | 1016–1078 ms / 1024 ms | 1016 ms / 1026 ms |
| frame of exactly 1 048 576 bytes | ✓ / ✓ | ✓ / ✓ |
| frame of 1 048 577 bytes | abrupt 1006 / 1006 (process-wide `WebSocketsMaxFrameMB := 1`) | close **1009** / **1009**; witness TCP closed 1–3 ms, no payload read |
| **one 64 MiB message as 4096 × 16 KiB frames** (no frame over the bound) | **delivered, 67 108 864 bytes; peak commit +132 378 624 / peak RSS +132 382 720** | close **1009** / **1009**, 0 delivered, **peak +0**; witness saw the close after **1 245 184 / 4 112 384** bytes sent |
| push latency after 500 / 2000 / 5000 ms idle | 64 / 236 / 172 ms · 0 / 15 / 204 ms (run 1: 63 / 158 / 93 · −3 / 38 / 95) | 0 / 0 / 0 · −4 / −4 / −1 ms (the negatives are clock-read granularity between node and the spike) |
| release against a server that never answers CLOSE, no explicit close first | **1032 ms** / **1015 ms** | 0 ms / 104 ms |
| release after an explicit close | 31 ms / 4 ms | 0 ms / 99 ms |
| every client frame masked | 0 unmasked / 0 | 0 / 0 |

**The handshake on the wire**, from the witness, identical on both targets:

```
m:  Host, Accept, User-Agent: Mozilla/5.0 (Win x64; mORMot) HCWS/4 wsspike,
    Content-Length: 0, Connection, Upgrade, Sec-WebSocket-Key,
    Sec-WebSocket-Version, Sec-WebSocket-Protocol, Authorization, X-Spike-Row
r:  Host, Upgrade, Connection, Sec-WebSocket-Key, Sec-WebSocket-Version,
    User-Agent: PWeb, Sec-WebSocket-Protocol, Authorization, X-Spike-Row
```

Both: `authorization` and an `x-` header forwarded; **no** `Origin`, **no**
`Cookie` (including on the handshake after a `Set-Cookie`), **no** `Proxy-*`.

**The one public observation** — `wss://echo.websocket.org`, both transports,
both targets: upgraded, echoed, close `1000` echoed. Typed an observation, never
a gate: TLS validation is not disableable in this product and a local server
cannot present a chain the system trusts, so the positive TLS row can only be
somebody else's server.

### F-1 — mORMot's reassembly is unbounded: a memory amplifier (MEASURED)

`WebSocketsMaxFrameMB` bounds **one frame**, and only in the 8-byte length form
(`mormot.net.ws.core.pas`, `TWebProcessInFrame.GetHeader`). Reassembly
(`TWebProcessInFrame.Step`, `pfsDataN`: `Append(outputframe.payload, data)`)
has no total at all, and the first hook that sees the message
(`OnBeforeIncomingFrame`, `ProcessIncomingFrame`) runs **after** it is whole.
Measured: a 64 MiB message in 16 KiB frames was delivered whole and the process
peak grew by **132 MiB** on both targets. That is the brief's adversarial
question — "can a flood exhaust memory" — answered yes.

It cannot be fixed from outside the library. `TWebProcessInFrame` is a record,
`TWebSocketProcess.GetFrame` is not virtual, `WebSocketsUpgrade` constructs
`TWebSocketProcessClient` by literal class name, and `TCrtSocket.SockInRead` is
not virtual. There is no seam to put a bound in.

### F-2 — a control frame between fragments kills the connection (MEASURED)

`pfsHeaderN` treats any opcode other than `focContinuation` as a state-machine
error. RFC 6455 §5.4 permits control frames between fragments, and a server
that sends a keep-alive PING during a long fragmented message is conformant.
Measured 1006 on both targets; the witness logged the socket error.

### F-3 — mORMot's handshake has no deadline (MEASURED)

A 1000 ms bound, a server holding the `101` for 5 s: **upgraded at 5000 ms**.
The socket timeout is per read, and the header read waits it out. This is ledger
`15A-5` — "a socket timeout is not a deadline" — met again on the handshake.
Unlike F-1 it is fixable from outside (a watchdog closing the socket), but it
has to be built.

### F-4 — `mormot.net.ws.client` links a server unit (MEASURED)

Its `uses` clause names `mormot.net.server` ("THttpServerRequest for
callbacks"), and `mormot.net.ws.core` adds `mormot.crypt.ecc` and
`mormot.crypt.jwt`. The spike's unit directory carries `mormot.net.server.ppu`
on both targets. No listener is opened, but every PWEB_NET image would carry a
server unit, and "no server in the image" is exactly what
`check_cap7l_nonetwork.sh`, `check_cap7m_nonetwork.sh` and the CAP-5/6/9C1
sweeps forbid by pattern (`mormot\.net\.(server|client|http)`), re-scoped by
15B §7.6 to "the only outbound client is the fetch transport". Taking this unit
would widen that claim to "and a server unit".

### F-5 — mORMot's handshake fingerprint and subprotocol rules (MEASURED)

The default User-Agent publishes the platform, the library and the executable
name (`Mozilla/5.0 (Win x64; mORMot) HCWS/4 wsspike`), beside `Accept` and a
`Content-Length: 0` on a GET. A subprotocol **list** cannot be accepted without
overriding `GetSubprotocols` and `IsSubprotocol`, and "offered, none selected"
is accepted for one offer and refused for two. Each of these is fixable from
outside; together they are a second fingerprint to keep aligned with CAP-15B's
`PWeb`.

### F-6 — two more costs of the library's process loop (MEASURED)

A close frame's code and reason reach the callback only with
`NotifyAllFrames = true`; the default delivers `ProcessStop`'s synthetic empty
close. A release without an explicit close first waits about one second for the
peer's close ACK (`Shutdown(waitForPong = true)`). Push latency after an idle
socket is up to 236 ms, because the loop paces itself with `HiResDelay`.

### RECOMMENDATION — the transport is RFC 6455 over `TCrtSocket` (a finding against the brief)

The brief names mORMot's WebSocket client in raw-frame mode, and asks that
**the file naming `mormot.net.ws.client` be the only one**. F-1 and F-2 make
that transport fail the contract the same brief ratifies, and neither is
reachable from outside the library. The measured alternative is on the table
above: **every row green on both targets**. It is:

- **the same socket layer** — `mormot.net.sock`'s `TCrtSocket`, which is what
  gives `THttpClientWebSockets` its connect, its TLS (SChannel on Windows,
  `mormot.lib.openssl11` on Linux) and its absence of any proxy logic;
- **with the handshake and framing written in the transport** (the spike's
  `TRawSocket` is about 380 lines with the handshake): bounded reassembly
  checked on each frame **header** before a payload byte is read, control frames
  permitted between fragments, masked-server-frame and RSV refusals, invalid
  UTF-8 closes 1007, the unpredictable mask from the AES-PRNG, a wall-clock
  handshake deadline observed in 20 ms slices, and a reader whose slice also
  observes the closing flag.

**The amendment it asks for:** the evidence row becomes
`mormot_net_ws_files = 0` (no file under `src/` names `mormot.net.ws.*` **or**
`mormot.net.server`), the 15B pin "exactly one file names `mormot.net.client`"
holds **unchanged**, and the new transport file names `mormot.net.sock`. The
cost is the framing code, which the shard then owns and the headless suite and
the four live legs gate. The alternative — an upstream fix and a repin — is not
in this shard's control; F-1 and F-2 are genuine library defects, and the plan
writes them up as upstream reports in the `2aa3475` shape whichever way the
ruling goes.

### F-7 — an outbound send is bounded per wait, not by a clock (MEASURED, both transports)

A server that stops reading (`/noread`), 1 MiB sends, a 2000 ms socket timeout:
the send that finally failed held its caller **4016 ms** on Windows (0 MiB
accepted) and **8041–8086 ms** on Linux (1 MiB accepted).
`TCrtSocket.TrySndLow` waits `TimeOut` per stall, so a peer that accepts a
trickle holds a scheduler worker indefinitely. The same answer as the
handshake: a wall-clock send deadline, the write done in slices against it.

---

## 2. Backpressure — MEASURED

Spike queue bound: 64 events, 1 MiB. The witness floods 1024 messages of
65 536 bytes (64 MiB), each carrying its sequence number and a fill byte, and
**honours the kernel**: a refused `write` waits for `drain`, and every block is
logged. The page does not poll for 3000 ms, sends one text frame, then drains.

| row | win (r / m) | linux (r / m) |
|---|---|---|
| queue at the end of the stall | 16 events, **1 048 576 bytes — exactly the byte bound** | same |
| reader thread parked | once, 3312 / 3312 ms | once, 3301 / 3299 ms |
| process memory, now-delta during the stall | +1 404 928 / +1 400 832 | +786 432 / +1 048 576 |
| witness: first refused write | after 2 ms, seq 19, 1 311 049 bytes in the kernel | after 0 ms, seq 1, 131 221 bytes |
| witness: longest block | 3302 / 3328 ms | 3168 / 2968 ms |
| witness: flood progress when the page's text arrived | 20 / 20 messages | 117 / 59 messages |
| drained | **1024 / 1024, 0 gaps, 0 corrupt**, done marker, 94 / 110 ms | **1024 / 1024, 0 gaps, 0 corrupt**, 68 / 131 ms |
| released while parked | 0 / 78 ms, **1 frame discarded at close** | 100 / 52 ms, 1 discarded |
| idle watchdog (bound 1500 ms, page polled once) | close 1001 at 1500 ms; witness `1001 after 1491 / 1492 ms` | 1502 / 1500 ms; witness 1502 / 1498 ms |

So the four claims the brief asks to measure hold, and on **both** transports,
because the mechanism is the queue and not the library: **reading stops** (the
server's kernel send path stayed blocked for the length of the stall, and the
page's own frame still reached it); **memory stays at the bound** (the queue
peaked at exactly 1 MiB, the process at +0.8–1.4 MiB); **nothing is dropped**
(1024 of 1024, every sequence number, every fill byte); and **the idle bound
closes a socket nobody polls**, with a code the server sees.

**One consequence to write into the contract rather than discover**: a socket
closed while frames are still queued or parked discards them — measured, one
frame. "Never a drop" is a property of a **live** socket under backpressure. A
closed socket's undelivered count belongs on its close event (§8,
`undelivered`), so a discard at close is typed rather than silent.

---

## 3. Darwin — `NSURLSessionWebSocketTask`, rows written, UNMEASURED

There is no macOS in reach of this host. As at 15B's Checkpoint 1, what can be
settled here is the **mechanism** for each row; the rows are measured by a
`test/cap15c/darwinsocketprobe.pas` on both hosted macOS legs and **gated**
there (`darwin_socket_failures = 0`), the shard's first hosted act. The
deployment floor is `macos-deployment-target = 12.0` (`webview.lock:53`);
`NSURLSessionWebSocketTask` needs 10.15, so availability is not in question.

| §10 row, applied to the socket | mechanism | the risk the run exists for |
|---|---|---|
| 1. bounded synchronous call on a worker | a session on a private serial delegate queue; `open` blocks the worker on a semaphore signalled by `didOpenWithProtocol:` or `didCompleteWithError:`; `send` on `sendMessage:completionHandler:` the same way | none known |
| 2. deadline during transfer | a wall-clock watchdog that calls `cancelWithCloseCode:reason:` at the handshake and send deadlines | F-3 and F-7 say the platform timeout is not the answer on the other two targets; it is measured here too |
| 3. no redirect followed | `willPerformHTTPRedirection:` answering `completionHandler(nil)`, plus a typed refusal of any non-101 | **unknown whether the delegate is consulted for a WebSocket upgrade at all**; the witness hit counts decide |
| 4. bound during the read | `maximumMessageSize = 1048576` set explicitly (the documented default is 1 MB, which is not a reason to leave it implicit), and `receiveMessageWithCompletionHandler:` **re-armed only when the queue has room** | **the row most likely to disappoint: whether CFNetwork keeps reading into its own buffer while no receive is armed.** The same flood row as §2 — witness blocks, process memory, 0 gaps — measured on the runner. If it buffers without bound, that returns as a finding and never as a silent fall-through |
| 5. cookie jar OFF, not merely unused | the 15B configuration: `HTTPCookieStorage = nil`, `HTTPShouldSetCookies = NO`, accept policy `Never`, `URLCache = nil`, `URLCredentialStorage = nil` | the witness's `Cookie` count after a `Set-Cookie` |
| 6. system trust | **no** `didReceiveChallenge:` implementation in the file | the self-signed witness must be refused |
| 7. no proxy inherited | `connectionProxyDictionary = @{}` | worded as 15B's rider 3: what was measured, on what |
| + fragmentation, §5.4 interleave, ping | framework-native | the same `/fragment?ping=1` row F-2 failed |
| + close code and reason | `URLSession:webSocketTask:didCloseWithCode:reason:` | the `4001`/`bye` row |
| + subprotocols and headers | `webSocketTaskWithRequest:` carrying `Sec-WebSocket-Protocol` and the allowlisted headers, the selection read from `task.response` | **Apple lists `Authorization` among the headers a session may manage itself**; whether it reaches the wire is a witness row, not an assumption |

---

## 4. The test server

`test/cap15c/ws_server.js` — node, no packages, loopback only, the CAP-15A/15B
shape: `--stdin-shutdown` opt-in, `--ttl` backstop, a JSONL log written before
any routing decision. Twenty routes cover every row above plus `/noread`.
Plaintext `ws://127.0.0.1:<port>` is what every must-PASS leg uses, under the
PWEB_DEV loopback rule. The one wss round trip to a public echo endpoint is an
observation, as §1 records.

**The witness had a defect of its own, found by reading its log rather than by
a failure.** Node's `http.Server` creates sockets with `allowHalfOpen`, so a
client FIN never closed an upgraded socket, and both `/noack` rows of the first
run read as connections still open after the client had closed them. Fixed: the
`end` event is logged as `tcp_peer_end` and answered. `/noread` still shows
`open` at shutdown, **correctly** — a paused socket reads no FIN, which is the
route's whole point.

---

## 5. The always-false conditional, extended

`test/cap7f/check_mormot_defines.ps1` sweeps `src/`, `tools/` and `examples/`
recursively (`:151-153`), so the three new units are covered **with no edit**.
Baseline on this branch: `MORMOT_DEFINES_PASS derived=206 scanned=93 exempt=14
hits=0`. What CAP-15C adds, and each one observed firing before it is kept:

- the socket transport's POSIX TLS import is written `{$ifdef UNIX}`, never
  `OSPOSIX` — the exact defect 15B shipped once;
- `test/cap7f/check_divergence.ps1` gains one allowlist row for
  `src/rpc/pweb.rpc.socket.mormot.pas` (2 directives, fingerprinted), and
  `src/rpc/pweb.rpc.socket.pas` joins the zero-conditional core;
- a CAP-15C contract row plants `{$ifdef OSPOSIX}` into a copy of the new
  transport and requires the sweep to name it.

---

## 6. The wss authorisation rule — ratify

**Recommended as the brief proposes, with the details the fetch grammar forces:**

1. A socket URL is byte-checked **before** parsing, exactly as a fetch URL is:
   at most 2048 bytes, ASCII only, no CR, LF or NUL, no userinfo, no fragment.
2. Its scheme maps to a **fetch** scheme, and the pair is fixed:
   `wss → https`, `ws → http`. Nothing else is a socket scheme.
3. The authority is validated by **the fetch grammar itself** —
   `PWebFetchParseOrigin` on `<mapped scheme>://<authority>` — so a socket host
   and a fetch host cannot mean two different things. `pweb.rpc.fetch.pas` stays
   byte-untouched; its exported parser is reused, not copied.
4. The mapped origin is compared with the **compiled allowlist by parsed
   components** (`PWebFetchSameOrigin`): scheme, host, port. **Default ports are
   canonical on both sides**: `wss://h` = `wss://h:443` ↔ `https://h`;
   `ws://h` = `ws://h:80` ↔ `http://h:80`.
5. **`ws://` is authorised only by a declared loopback `http` origin**, and that
   holds by construction rather than by a branch. The grammar accepts
   `http://127.0.0.1:<port>` and `http://localhost:<port>` only with an explicit
   port, and **a release `pweb build` refuses a loopback origin by name**
   (15B, `network_origin_loopback_release`). A release image's allowlist
   therefore carries no `http` origin, and no `ws://` URL can match anything in
   it. The decorator carries no `PWEB_DEV` region, as the 15B §8 amendment
   ruled for fetch. `localhost` and `127.0.0.1` stay distinct hosts: each
   authorises only its own spelling.
6. **No grammar change, no schema bump, no new field.** `network.origins`
   declares hosts; the capability selects which door may reach them.

Refused, and the headless suite pins each one: `ws://api.example.com`
(non-loopback plaintext); `wss://api.example.com:8443` against a declared
`https://api.example.com` (port-only mismatch); `wss://127.0.0.1:5173` against
a declared `http://127.0.0.1:5173` (the scheme pair is fixed, so a plaintext
declaration never authorises TLS or the reverse); `ws://localhost:5173` against
a declared `http://127.0.0.1:5173`; `wss://user@api.example.com`;
`WSS://api.example.com` (the scheme is compared exactly, as fetch does).

---

## 7. The bounds — one constants home, `src/rpc/pweb.rpc.socket.pas`

| constant | value | basis |
|---|---|---|
| `PWEB_SOCKET_MAX_SOCKETS` | **4** open sockets per **host process**, all principals, counted from the start of `open` | brief |
| `PWEB_SOCKET_CONNECT_DEADLINE_MS` | **10 000**, wall clock, TCP + TLS + handshake, not page-selectable | fetch's default; F-3 says it must be owned, and `r` measured it honoured within one slice |
| `PWEB_SOCKET_SEND_DEADLINE_MS` | **10 000**, wall clock | F-7 |
| `PWEB_SOCKET_MAX_MESSAGE` | **1 MiB** per message, **inbound checked on every frame header against the reassembled total**, outbound on the decoded bytes | brief; F-1; `r` measured 1 048 576 in, 1 048 577 closed 1009 |
| `PWEB_SOCKET_QUEUE_EVENTS` / `_QUEUE_BYTES` | **64** events / **1 MiB** per socket; one message always enters an empty queue, so the peak is 1 MiB and never more | §2, measured at exactly the bound |
| host-wide worst case | 4 × (1 MiB queue + 1 MiB reassembly + 64 KiB socket buffer) ≈ **8.3 MiB** | arithmetic over the three rows above |
| `PWEB_SOCKET_MAX_WAIT_MS` | **25 000**; `waitMs` absent means 0; larger is **refused, not clamped** (fetch's `timeoutMs` precedent) | below every idle bound by a margin |
| `PWEB_SOCKET_IDLE_MS` | **60 000** with no receive in flight and none returned | measured as a mechanism at 1500 ms (§2); the constant is 2.4 × the wait maximum |
| receives in flight per socket | **1**; a second concurrent one is `busy` | F-9 |
| `PWEB_SOCKET_MAX_PROTOCOLS` | **4**, RFC 7230 token grammar, ≤ 64 bytes each, no duplicates; the server's selection must be one offered; offered-but-none-selected is refused | brief; `r`'s measured rule, the consistent one of F-5 |
| handshake headers | **the 15B §4 allowlist, exactly**: `accept`, `accept-language`, `authorization`, `content-type`, `if-match`, `if-none-match`, `if-modified-since`, `x-*`; ≤ 16; values ≤ 4096 bytes; CR/LF/NUL refused on the bytes; a repeat refused. Everything a handshake owns — `host`, `upgrade`, `connection`, `sec-websocket-*`, `origin`, `cookie` — is outside it by construction | brief |
| page close code / reason | `1000` or `3000–4999` (WHATWG `close()`) / ≤ **123** UTF-8 bytes (RFC 6455 §5.5) | — |
| surfaced close reason | ≤ 123 bytes; the peer cannot send more | RFC 6455 §5.5 |
| socket id | 32 hex characters from the AES-PRNG | unguessable across principals |

The headless gate cross-checks this table against the unit's constants, the
TypeScript and Pas2JS SDK constants, and `docs/cli-contract.md` §5, so a
number cannot move in one place.

### F-8 — a 1 MiB outbound message cannot cross today's binding (DERIVED)

The binding refuses a whole request over `PWEB_BINDING_DEFAULT_MAX_REQUEST_BYTES
= 1 shl 20` (`src/webview/pweb.webview.binding.pas:83`, applied at `:529-538`
before any copy), and `TPWebHostOptions` (`pweb.webview.host.pas:174-202`)
exposes no way to raise it. A 1 MiB binary message is 1 398 104 base64
characters before the envelope. **The same arithmetic applies to CAP-15B's
1 MiB fetch body**, which is therefore unreachable end to end through a
generated host. That is derived from the constants and not measured; nothing
in 15B's composition sent a body that size.

**Proposed:** `TPWebHostOptions` gains `MaxRequestBytes` (0 = the binding's
default, so every existing composition is byte-identical in behaviour), and the
`PWEB_NET` region of both templates sets it to **2 MiB**, under the binding's
16 MiB hard ceiling. A text message whose JSON escaping pushes the invocation
past 2 MiB is refused by the binding's own `invalid_request`, and the SDK
documents that bound rather than hiding it. The composition smoke **measures**
1 MiB in both directions and a 1 MiB fetch body, so the correction to 15B lands
with a number.

### F-9 — four parked receives would starve every RPC (DERIVED)

`PWebDefaultHostOptions` gives `Workers = 4`, `MaxConcurrent = 4`
(`pweb.webview.host.pas:364-366`), and a parked long-poll holds one worker and
one source slot for up to 25 s. Four sockets polling means `Calculator.Add` is
queued until one returns, and "42 still answers" fails. **Proposed:** one
receive per socket (above), and the `PWEB_NET` region adds
`PWEB_SOCKET_MAX_SOCKETS` to both `options.Workers` and `options.MaxConcurrent`.
An application with no origins keeps today's scheduler exactly. The composition
smoke measures 42 answering while four sockets are parked.

---

## 8. Lifecycle, ownership, errors

**Ownership.** A socket belongs to the `(PrincipalId, WindowId)` of the context
that opened it. That context is native (`pweb.rpc.intf.pas:185-188`) and never
taken from the payload. An id owned by someone else and an id that never existed
answer **identically**, `service_error {category: "socket_not_found"}`, so the
door is not an oracle for another window's sockets.

### F-10 — the policy has no revocation signal (READ)

`TPWebCapabilityPolicy` mutates grants in `SetRuntimeGrants`,
`RevokeRuntimeGrant` and `ClearRuntimeGrants`
(`pweb.capabilities.policy.pas:237-250`) and tells nobody. "A revoked
`network.socket` closes every socket immediately" needs to be told.
**Proposed:** an additive `OnGrantsChanged` procedure on the **concrete class**
(the frozen `ICapabilityPolicy` is untouched). It is invoked after the store
changes, outside `FGrantLock`, with the principal id. The socket door's handler
asks `SnapshotCapabilities(principal, window)` whether `network.socket`
survived. If it did not, the door marks every socket of that principal closed —
so no send reaches a transport and no event reaches a receive — before the
revoking call returns, then hands the transport close to the closer.
Measured: transport send-entry count frozen at the revoke instant, witness sees
one close frame (1001) and FIN and nothing else. `capability_policy_digest` is
re-measured, and cannot move, because no decision changed. **Refused
alternative:** the decorator polling the policy — authorization inside the
decorator, which 15A §1 forbids, and "immediately" would become "within a
tick".

### F-11 — the host has no "this document is being replaced" signal (READ)

All three guards already classify every navigation through one function —
WebView2 `NavigationStarting` (`pweb.platform.webview2.pas:1007`), WebKitGTK
`decide-policy` (`pweb.platform.webkitgtk.pas:1384`), WKWebView
(`pweb.platform.cocoa.pas:1518`). A **top-level** (`pnkDocument`) decision
answered `pnaAllowTrusted` is the one engine-independent moment a document is
replaced. **Proposed:** `TPWebHostOptions` gains a `DocumentReplacing` procedure,
called on the GUI thread with the window id after that decision; each guard
makes the one call; the socket door's handler **never blocks** — it marks the
window's sockets closed and queues their transport close. The classifier is
untouched, so `navigation_policy_digest` cannot move. **The dev generation
switch is the same mechanism**: `PWebHostRequestReload`
(`pweb.webview.devhost.pas:377`) re-navigates through `webview_navigate` and the
same guard. It is still **measured separately**, on the dev host, because a
shared mechanism is a reason to expect one result and not a measurement of it.

**Host shutdown before the drain.** `PWebHostRun`'s teardown is: reload drain,
`binding.Close`, `schedulerRef.Shutdown` (`pweb.webview.host.pas:1077-1114`),
guard `Detach`, handler, destroy. A `BeforeDrain` procedure in the options is
called **immediately before `binding.Close`**, so every CAP-9 step keeps its
place and the socket close is prepended. It is also belt and braces:
`TSchedulerSource.Close` cancels the source token (`pweb.rpc.scheduler.pas:427`),
and a parked receive observes it within one slice, so the drain can never be
held for a wait. The CAP-9 order is re-measured.

**Errors.** `service_error` with a category, never a native detail, and the
nine-code taxonomy unchanged: `socket_not_found`, `socket_limit`,
`connect_failed`, `tls_failed`, `handshake_refused` (with a `reason` of
`redirect | status | upgrade | subprotocol` and never the server's text),
`deadline`, `message_too_large`, `send_failed`, `socket_closed`. A close event
carries `code`, `reason`, `wasClean`, `undelivered` and a `category`:
`remote | abnormal | page | idle | navigation | revoked | shutdown |
protocol_error | message_too_large`.

---

## 9. The unit map

| file | new? | holds | may not name |
|---|---|---|---|
| `src/rpc/pweb.rpc.socket.pas` | new | `TPWebSocketBridge`, the `IInvocationBridge` decorator for the four methods: URL grammar and the §6 mapping (reusing `PWebFetchParseOrigin`, `PWebFetchSameOrigin` and `PWebFetchParseOrigins`), the header and subprotocol allowlists, every §7 bound, the per-socket queue and its backpressure, ownership, the idle watchdog, the lifecycle handlers, the envelope | any `mormot.net.*`, any `{$ifdef}`, any operating system — joins the CAP-7F zero-conditional core |
| `src/rpc/pweb.rpc.socket.mormot.pas` | new | the Windows/Linux transport: `TCrtSocket` connect + TLS, the RFC 6455 handshake and framing of §1's recommendation, the sliced reader and writer | `mormot.net.client`, `mormot.net.ws.*`, `mormot.net.server` |
| `src/platform/macos/pweb.platform.cocoa.socket.pas` + `pweb_cocoa_bridge.{h,mm}` | new / grows | the Darwin transport over `NSURLSessionWebSocketTask` (§3) | any `mormot.net.*` |
| `src/security/pweb.capabilities.policy.pas` | grows, additively | `OnGrantsChanged` on the concrete class (F-10) | — |
| `src/webview/pweb.webview.host.pas` | grows, additively | `TPWebHostOptions.MaxRequestBytes`, `DocumentReplacing`, `BeforeDrain` (F-8, F-11) | — |
| the three platform guards | one call each | notify an allowed top-level document | — |
| `src/rpc/pweb.rpc.command.pas`, `pweb.rpc.fetch.pas`, `pweb.rpc.fetch.mormot.pas`, `pweb.platform.cocoa.fetch.pas`, `pweb.navigation.policy.pas`, `pweb.rpc.intf.pas`, `pweb.rpc.scheduler.pas`, `pweb.assets.htmlpolicy.pas` | **byte-untouched** | — | — |

**The seam** stays out of the frozen boundaries by shape, as 15B's did: a record
of plain function types, never an eighth interface.

```pascal
TPWebSocketTransport = record
  Open:    function(const Request: TPWebSocketRequest;
             const Sink: TPWebSocketSink; out Handle: Pointer): TPWebSocketOutcome;
  Send:    function(Handle: Pointer; Binary: Boolean;
             const Payload: RawByteString): TPWebSocketOutcome;
  Close:   procedure(Handle: Pointer; Code: Integer; const Reason: RawUtf8);
  Release: procedure(Handle: Pointer);
end;
```

`TPWebSocketSink.Deliver` is the decorator's queue. It **may block**, and
blocking it is the backpressure — which is why the sink is the decorator's and
never the transport's. Both transports export `PWebSocketNativeTransport`; the
generated program selects one inside the existing `PWEB_NET` region, beside the
fetch selection (ledger `15B-15`'s one conditional grows by one unit name, and
the two template contract pins move with it).

---

## 10. The SDK surface, both frontends

**`@pweb/runtime`, `sdk/typescript/src/socket.ts`** (exported from `index.ts`):

```ts
export const PWEB_METHOD_SOCKET_OPEN = "pweb.socket.open";      // and _SEND, _RECEIVE, _CLOSE
export const PWEB_CAP_NETWORK_SOCKET = "network.socket";        // advisory, never enforced here

export interface PWebSocketOptions {
  readonly protocols?: readonly string[];
  readonly headers?: Readonly<Record<string, string>>;
}

export class PWebSocket {
  static readonly CONNECTING = 0; static readonly OPEN = 1;
  static readonly CLOSING = 2;    static readonly CLOSED = 3;
  readonly url: string;
  readonly readyState: number;
  readonly protocol: string;
  readonly binaryType: "arraybuffer";
  onopen:    ((ev: PWebSocketEvent) => void) | null;
  onmessage: ((ev: PWebSocketMessageEvent) => void) | null;   // data: string | ArrayBuffer
  onerror:   ((ev: PWebSocketErrorEvent) => void) | null;     // code + category, never native text
  onclose:   ((ev: PWebSocketCloseEvent) => void) | null;     // code, reason, wasClean, category, undelivered
  constructor(url: string, options?: PWebSocketOptions);
  send(data: string | ArrayBuffer | ArrayBufferView): void;   // ordered, one invoke at a time
  close(code?: number, reason?: string): void;
}
```

WebSocket-**like**, and the differences are stated rather than papered over: no
`Blob`, no `bufferedAmount`, no `extensions`, no `addEventListener` (the four
handler properties are the surface), and **no URL construction, default origin,
header defaulting, retry or reconnect**. Each of those is a native decision or
an application's, never the SDK's, which is 15B's `httpFetch` rule.

**Pas2JS, `sdk/pas2js/pweb.native.pas`**, the twin beside `PWebFetch`:

```pascal
TPWebSocket = class
public
  OnOpen, OnError: TPWebSocketNotify;          // procedure(Sender: TPWebSocket; Info: TJSObject) of object
  OnMessage: TPWebSocketMessage;               // procedure(Sender: TPWebSocket; Data: JSValue) of object
  OnClose: TPWebSocketClosed;                  // procedure(Sender: TPWebSocket; Info: TJSObject) of object
  constructor Create(const AUrl: String; AOptions: TJSObject = nil);
  procedure Send(const AText: String);
  procedure SendBinary(ABuffer: TJSArrayBuffer);
  procedure Close(ACode: NativeInt = 1000; const AReason: String = '');
  property ReadyState: NativeInt read FReadyState;
  property Protocol: String read FProtocol;
end;
```

**The receive loop, and the sentence the contract carries about CAP-12.** Both
SDKs run one loop per socket:
`while not closed: events := await invoke("pweb.socket.receive", {id, waitMs: 25000}); dispatch(events)`.
**When CAP-12 brings streaming, that loop is the only thing that changes.** The
SDK surface above, the four method names, the event shapes and the native
decorator do not. This sentence goes into `docs/cli-contract.md` §5 verbatim, and
the contract gate pins it.

**The wire.**
`receive` answers
`{"events":[{"type":"open","protocol":"json.v2"},{"type":"message","text":"…"},{"type":"message","base64":"…"},{"type":"error","category":"…"},{"type":"close","code":4001,"reason":"bye","wasClean":true,"category":"remote","undelivered":0}]}`,
at most the queue (64 events, 1 MiB before encoding). `open` answers
`{"id":"<32 hex>"}` once the handshake completed, `send` and `close` answer `{}`,
and `close` is idempotent.

---

## 11. The smallest diff

**New production files: 4** — `src/rpc/pweb.rpc.socket.pas`,
`src/rpc/pweb.rpc.socket.mormot.pas`,
`src/platform/macos/pweb.platform.cocoa.socket.pas`,
`sdk/typescript/src/socket.ts`.

**Edited, additively: 14** — `pweb_cocoa_bridge.{h,mm}`;
`pweb.capabilities.policy.pas` (one notification); `pweb.webview.host.pas` (three
option fields and their three call sites); the three platform guards (one call
each); both `program.lpr` and both `app.services.pas` templates (inside
`PWEB_NET`: the socket decorator, `network.socket` in the ceiling, window and
principal sets, four `MapMethod` rows, the scheduler increments, `MaxRequestBytes`);
`sdk/typescript/src/index.ts`; `sdk/pas2js/pweb.native.pas`;
`tools/bundler/pwebbundle.pas` (`socket`, `sockets`, `ws`, `websocket` join
`network_field_in_bundle`); `docs/cli-contract.md` §5.

**Tests and gates** under `test/cap15c/`: the headless suite (every §6–§8 row,
the real `TPWebCapabilityPolicy` legs — granted, revoked, absent → decorator not
linked — with their own corpus, the CAP-8A corpus gaining nothing), the live
program on four targets, the Darwin probe, the contract gate, the host proofs,
the composition extension. Plus the evidence fields, the aggregator refusals,
`collection-paths.json` in the **same commit** (15B's `15B-26`), the
`check_dev_trust` section 7, the divergence row, and the platform-leg action.

**Build proofs**, 15B §7's with a socket twin:

- the CSP is byte-identical;
- `network.socket` and the decorator are in the image iff origins were declared;
- the compiled unit set of a network image carries `mormot.net.sock` and **no**
  `mormot.net.ws.*` and **no** `mormot.net.server`;
- `app.pwb` refuses a socket or ws field.

### F-12 — the ws release sweep has no natural firing twin (READ)

No file under `src/`, `tools/pweb/` or the templates carries a `ws://127.0.0.1`
literal. The CAP-10A HMR allowance is ratified and unused
(`test/cap10a/check_dev_trust.ps1:291`), and under §6's mapping rule the socket
door adds none. So a **dev** image carries no ws loopback literal either, and
the brief's "release sweep for ws:// followed by a loopback host, proven
discriminating on a dev image" cannot fire on a real dev image. It would pass
vacuously, which is the class this repository refuses. **Proposed:**

- the ws-literal sweep is proven discriminating on a **planted** witness image —
  a test-only unit carrying one literal, built by the host proofs — and is
  required to fire there;
- a source pin that no `ws://` or `wss://` literal appears in `src/**` code;
- 15B's origin sweep stays the natural discriminating twin for the thing that
  actually authorises `ws://`, the compiled `http` loopback origin.

---

## 12. Assumptions where the brief is silent

| question | assumption |
|---|---|
| "sockets per host" | per **native host process**, across all principals, counted from the start of `open` |
| `open` arguments | `url` string required; `protocols` array of strings and `headers` object optional; a present field of the wrong type is `invalid_request`, never an empty set (15B §4's rule for `headers`) |
| `send` | exactly one of `text` and `base64`; base64 decoded strictly; an empty text is a legal message |
| `receive` on a closed socket | returns what remains, the close event last; the socket record is removed once its close event has been received, or at the idle bound |
| `receive` with nothing queued and `waitMs = 0` | `{"events":[]}` |
| a server frame that is masked, carries RSV bits or an unknown opcode | close 1002, `category: "protocol_error"` |
| invalid UTF-8 in a text message | close 1007 |
| the close a **native** decision sends the server (idle, navigation, revoke, shutdown) | 1001, empty reason — the server learns nothing about why |
| an `open` in flight when its window navigates | completed as `socket_closed`, and its transport released |

---

## 13. Supersessions expected, none assumed

| digest or pin | why it moves |
|---|---|
| `generated_inventory_digest`, `pas2js_generated_inventory_digest`, the template pack sha256, `template_semantic_digest`, `public_semantic_digest`, the CAP-10B1 React closure pinned in CAP-10B2 | `program.lpr` and `app.services.pas` change inside `PWEB_NET` |
| the two template contract pins of `15B-15` | the transport selection names one more unit |
| `sdk_ship_table_digest`, `sdk_inventory_digest` | `socket.ts` is new |
| `ci_sequence_digest` | four legs gain the CAP-15C step |
| the CAP-7F evidence schema, in all three lists | the §1–§3 evidence fields |
| `test/cap11a/collection-paths.json` | the CAP-15C records |
| the CAP-7F divergence allowlist | one new row |
| the backlog census | the ledger rows this checkpoint opens |
| `navigation_policy_digest` `360d69f2…`, `capability_policy_digest` `23b87da5…` | **must not move**, re-measured |
| `pipeline_digest` | **must not move** for an empty-origins project |
| `PWEB_NATIVE_CSP`, CAP-14A's three digests, the CAP-9 shutdown order | **must not move**, re-measured |

---

## VERDICT

```
CAP-15C PLAN READY
```

Every Checkpoint-1 measurement the brief names is taken on the two targets this
host reaches:

- **Raw-frame interop** with a non-mORMot server: yes, for both transports.
- **Backpressure:** reading stops, the queue peaks at its bound, and 1024 of
  1024 messages arrive intact.
- **Idle close:** typed, and seen by the server.
- **TLS validation:** refused against a self-signed local server on SChannel
  and OpenSSL.
- **Public wss round trip:** one, as an observation.
- **Always-false gate:** baseline green, with its extension named.

The Darwin rows are written with their mechanisms and gated for the hosted run.
They are **unmeasured** here by construction, and the shard's PASS is
conditioned on them.

Four rulings are wanted before a line of `src/` is written, in order of weight:

1. **The transport (F-1 to F-6).** mORMot's WebSocket client fails the
   contract's memory bound and RFC 6455 §5.4, both measured, and neither is
   reachable from outside the library. The plan takes RFC 6455 framing over
   `TCrtSocket`, measured green on every row, and amends
   `mormot_net_ws_files = 1` to `0`.
2. **The two numbers that decide whether the contract is reachable at all:**
   the binding's request bound (F-8, which also corrects a latent 15B row) and
   the scheduler's slots (F-9).
3. **The two lifecycle seams the host does not have:** revocation (F-10) and
   document replacement plus shutdown (F-11). Both are additive, both leave the
   frozen interfaces and both digests alone.
4. **The ws release sweep's firing twin (F-12).**

F-7 (a wall-clock send deadline) and the §12 assumptions need no ruling to be
taken as written. Absent a different instruction I take each proposal as named,
record every departure from the brief as an amendment in the closure artifact,
and start with the headless suite.
