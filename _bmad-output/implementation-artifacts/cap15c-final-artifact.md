# CAP-15C — the native socket door, built

CAP-15C NOT READY

Branch `phase/cap-15/c-native-socket-door`, from `245ad806abdb7c7a988a66f533ee97ae331a10ce`.
Contract: `docs/cli-contract.md` §5, *The native socket door*. Checkpoint:
`cap15c-checkpoint1.md` (PLAN READY, amended below). Spec:
`spec-phase-15-cap15c-native-socket-door.md`.

The verdict is NOT READY for the reasons the brief makes non-negotiable and
nothing else: no hosted run has executed this branch, so the four-target
contract rows, the seven Darwin rows and hosted CI green on the final HEAD are
all still owed. Every row that can be measured on the two reachable targets
was measured, and is recorded below as measured and where.

---

## UNITS AND SEAM

| unit | role | platform knowledge |
|---|---|---|
| `src/rpc/pweb.rpc.socket.pas` | the decorator: URL and wss authority, handshake and subprotocol allowlists, the per-socket event queue, the bounds, ownership, the lifecycle seams, the ONE constants home | none - no `mormot.net.*`, no conditional, no OS, no `PWEB_DEV` (K1, frozen zero-conditional core) |
| `src/rpc/pweb.rpc.socket.mormot.pas` | Windows and Linux transport: RFC 6455 framing over `mormot.net.sock`'s `TCrtSocket`, one I/O thread per socket | one `{$ifdef UNIX}` naming `mormot.lib.openssl11`, allowlisted at 2 directives |
| `src/platform/macos/pweb.platform.cocoa.socket.pas` + `pweb_cocoa_bridge.{h,mm}` | Darwin transport: `NSURLSessionWebSocketTask` behind the same seam, MRC, `-Werror` | the adapter layer |

The seam is `TPWebSocketTransport`, a record of four plain function types -
`Open`, `Send`, `Close`, `Release` - plus a sink the transport calls back:
`Room(size)`, `Deliver`, `Closed`. Both transports export the same
`PWebSocketNativeTransport`, never both compiled, so the generated program
names one transport and no conditional beyond the unit selection CAP-15B
already carries. `pweb.rpc.command.pas` and every fetch unit are
byte-identical to the baseline (K15).

Additive seams outside the door, each told and never asked:
`TPWebCapabilityPolicy.OnGrantsChanged` (notified after the grant lock is
released, from the three grant mutators); `TPWebHostOptions.MaxRequestBytes`,
`DocumentReplacing` and `BeforeDrain`; one `PWebNavTrustedDocumentHook` per
platform guard, called after a trusted `pnkDocument` verdict (K8). The
generated `program.lpr` installs the door beside fetch inside `PWEB_NET`,
attaches the policy, raises the request bound, adds four workers and slots,
and arms the two host seams; `app.services.pas` grants `network.socket` and
maps the four methods there only (K6).

Methods: `pweb.socketOpen {url, protocols?, headers?} -> {id}`,
`pweb.socketSend {id, text | base64} -> {}`,
`pweb.socketReceive {id, waitMs?} -> {events}`,
`pweb.socketClose {id, code?, reason?} -> {}`, behind ONE capability,
`network.socket`.

## WSS AUTHORITY

Ratified as recommended: a `wss://host[:port]/...` URL is authorised by a
declared `https://host[:port]` origin **by parsed components**, with the scheme
pair fixed; a declared `http://127.0.0.1:<port>` authorises
`ws://127.0.0.1:<port>`; default ports are canonical both ways. The decorator
reads the scheme as a token, maps it, and hands `<mapped>://<authority>` to
**the fetch grammar itself** - `PWebFetchParseOrigin` and
`PWebFetchSameOrigin` - so a socket host and a fetch host cannot mean two
things. No grammar change, no schema bump, no new field.

Measured in the corpus (128 lines, `95b2cf7c…`, identical on windows-x86_64
and linux-x86_64): a port-only mismatch (`wss://api.example.com:8443` against
`https://api.example.com`), `ws://` to a non-loopback host, a suffix trick
(`api.example.com.evil.example`), `https://` and `http://` passed as socket
URLs, userinfo and the userinfo trick, fragments, CR/LF, raw and escaped NUL,
spaces, non-ASCII, uppercase scheme, empty authority, port 0 and overflow,
IPv6, over-2048-byte URLs - all `invalid_request` with **zero transport
opens** - and `ws://127.0.0.1:5173` accepted against a development allowlist
and refused against a release allowlist. Under a release build the loopback
origin itself is refused by name (CAP-15B), so "dev loopback accepted under
PWEB_DEV only" is a property of what can be compiled in.

No source file spells a socket URL (K4, dev-trust §2 and §7), and no image
carries a `ws://` loopback literal - with the sweep proven to fire (BUILD
PROOFS).

## QUEUE AND BACKPRESSURE

| bound | value |
|---|---|
| sockets per host | 4 (`limit|fifth-socket|socket_limit|opens=4`) |
| connect deadline, wall clock, TLS and upgrade included | 10 s; measured 1000 ms for a 1000 ms bound on Windows, 1003 ms on Linux |
| send deadline, wall clock | 10 s; measured 2000 ms / 2008 ms for a 2000 ms bound against a server that stopped reading |
| message, both directions | 1 MiB; 1 MiB at the bound echoed, over it closed 1009 `message_too_large`; a page send over it refused with zero sends |
| per-socket queue | 64 events or 1 MiB |
| long-poll wait maximum | 25 s, refused (not clamped) above it |
| idle bound | 60 s (1500 ms under test), closed 1001, category `idle` |
| request bound in a network host | 2 MiB |

**When the queue is full the transport stops reading, and nothing is
dropped.** The `Room(size)` sink seam is asked before a message is taken off
the socket; while it answers no, the I/O thread keeps writing and stops
reading, so TCP pushes back. Measured against a server flooding 1024 messages
at a page that did not poll for three seconds: the queue parked at 16 events /
1 048 576 bytes with no memory growth, the server's longest blocked write was
**3074 ms on Windows and 2965 ms on Linux**, a page send still reached the
wire while reading was stopped (at server message 20 / 135), and afterwards
all 1024 arrived with 0 gaps and 0 corrupt. A 64 MiB fragmented message was
closed 1009 after 1.2 MiB (Windows) / 3.8 MiB (Linux) had been written by the
server, with no measured memory peak. A receive in flight counts as polling.

## LIFECYCLE AND OWNERSHIP

- **Ownership.** A socket belongs to the window principal that opened it;
  another principal's send, receive or close is answered exactly as an
  unknown id, with zero transport calls (`principal_isolation`).
- **Navigation.** A trusted document verdict calls the host's document seam,
  which closes that window's sockets (1001 on the wire) and leaves other
  windows untouched; a later send answers `socket_not_found`
  (`close_on_navigation`, L1 on both targets; suite row).
- **Generation switch.** A development generation switch is
  `PWebHostRequestReload` -> `webview_navigate(PWEB_HOST_ORIGIN)`, a trusted
  re-navigation through the same verdict. Witnessed by K8 (the reload path and
  the hook placement on all three platforms), the suite seam, L1, and on
  Linux a real window's reload closing a real socket in the composition
  (`close_on_generation_switch`).
- **Revocation.** `OnGrantsChanged` re-reads each window's capabilities with
  `SnapshotCapabilities`; a socket whose principal lost `network.socket` is
  closed before the revoking call returns, with zero further sends and a late
  frame discarded (`revoke_closes_all`: 0 open after the call, 1001 on the
  wire).
- **Shutdown.** `BeforeDrain` runs after the document hook is disarmed and
  **before** `binding.Close` and `scheduler.Shutdown` (K8 pins the order): new
  opens are refused, every socket is released synchronously (109 ms Windows /
  64 ms Linux for two sockets), 1001 on the wire, and every CAP-9 step keeps
  its place. On Linux the composition shuts a real host down with a socket
  open and reads the close from the witness.
- **Close.** Page codes 1000 or 3000-4999, reason at most 123 bytes of valid
  UTF-8, idempotent. A native close carries 1001 and no reason on the wire;
  the category (`page`, `remote`, `abnormal`, `idle`, `navigation`,
  `revoked`, `shutdown`, `protocol_error`, `message_too_large`) and
  `undelivered` are typed on the page's close event.

## RAW-FRAME INTEROP

Against `test/cap15c/ws_server.js` - a dependency-free RFC 6455 server that
is not mORMot, whose JSONL log is the independent witness - on windows-x86_64
and linux-x86_64: handshake with `json.v2` selected; text, binary and 1 MiB
echo (31 ms / 26 ms to send the 1 MiB); fragmented text and binary reassembled
(SHA match) with a server ping between fragments; the server's ping answered
with its own payload natively and no client-initiated ping; server close
4001/`bye` surfaced as `remote`; page close 4000/`done` on the wire; every
client frame masked; handshake headers exactly `Host, Upgrade, Connection,
Sec-WebSocket-Key, Sec-WebSocket-Version, User-Agent, Sec-WebSocket-Protocol,
Authorization, x-live` with `User-Agent: PWeb`, no `Origin`, no `Cookie`
(including after a `Set-Cookie`), no proxy header, no `Content-Length`; a 302
refused `handshake_refused:redirect` and never followed (2 hits, 0 follows);
a 200 refused `:status`; a wrong or missing subprotocol refused
`:subprotocol`; an untrusted certificate refused `tls_failed` before any
upgrade. `raw_frame_standard_server = true` on both.

**TLS name verification - measured, and fixed in the socket transport.** A
certificate TRUSTED by the process but issued for `wrong.example` opened
`wss://127.0.0.1` on Linux: mORMot's OpenSSL layer checks a name only when
`TNetTlsContext.HostNamesCsv` is set. The transport now assigns exactly that
field; on Linux the live pair reads `live_tls_trusted_right_name = success`
(the control) and `live_tls_trusted_wrong_name = service_error:tls_failed`
with zero upgrades on the wrong-name witness. SChannel validates against the
target name it is given; NSURLSession evaluates server trust by default.

## DARWIN TRANSPORT

`NSURLSessionWebSocketTask` behind the same seam, under the fetch door's
section-10 discipline: bounded synchronous calls with a deadline sliced
against cancellation; the deadline observed during a send (cancel with 1001);
`willPerformHTTPRedirection` answered nil and counted; `maximumMessageSize`
set to the bound and EMSGSIZE mapped to 1009; an ephemeral configuration with
no cookie storage, `HTTPShouldSetCookies = NO`, no cache, no credential
storage, an empty `connectionProxyDictionary`, and the system trust store.
Receive is re-armed only when `Room` says yes - **whether the framework then
stops reading the socket is a measurement the macOS legs make, never an
inference**.

It is compiled MRC under `-Wall -Wextra -Werror` (C13 sweeps its comments),
type-checked off a Mac with `-dDARWIN -Cn` (2 sources), and linked by every
program that names it (K10). Its seven rows - opens, redirects offered, proxy
dictionary empty, cookie storage nil, should-set-cookies, open on main thread,
maximum message size - are written by `socketlive` on macOS, required numeric
by the aggregator, with the four configuration read-backs pinned; the other
two targets say `not_applicable` by name. **Not measured yet: no macOS host
has run this branch.**

## SDKS

`@pweb/runtime` exports `PWebSocket`; the Pas2JS SDK exports `TPWebSocket`.
Both present `onopen`, `onmessage`, `onerror`, `onclose` over the four calls,
run one bounded long-poll after another, keep sends ordered, throw (TS) or
raise `EPWebError invalid_request` (Pas2JS) on a send to a socket that is not
open, and construct no URL, supply no origin, add no header and never
reconnect. **When CAP-12 brings streaming, the receive loop is the only thing
that changes** - written into §5, both SDKs and the decorator (K9). Constants
cross-checked against the native unit (K5). `tsc --noEmit` clean; the Pas2JS
harness 72/72; the TypeScript SDK's own tests run on the Linux chain.

## BUILD PROOFS

`test/cap15c/sockethost.pas` is the socket twin of CAP-15B's `nethost`,
compiled four times - release, dev, planted twin, no network - with K7
pinning that it carries the template's constructs.

| row | windows-x86_64 | linux-x86_64 |
|---|---|---|
| `PWEB_NATIVE_CSP` byte-identical in release, dev and no-network images | true | true |
| `connect-src` | `'self'` | `'self'` |
| door, `network.socket`, `pweb.socketOpen` in the image iff `PWEB_NET` | true / absent from nonet | true / absent from nonet |
| compiled allowlist digest equals the declared one | true | true |
| `release_ws_relaxation_literals` | 0 | 0 |
| `dev_image_ws_relaxation_literals` | 0 | 0 |
| `dev_twin_ws_relaxation_literals` (planted, must fire) | 1 | 1 |
| `mormot_net_ws_files` (compiled unit set) | 0 | 0 |
| socket transport on the unit set / in a nonet image | yes / no | yes / no |
| `app.pwb` refuses `socket`, `sockets`, `websocket`, `ws`, `wss` | true (nested data accepted) | true |

The `ws://` sweep needed a planted twin because no image this product builds
carries a `ws://` loopback literal: a development image derives the ws
authority from its `http://` origin by components, and measures 0. Source
rules: `test/cap15c/check_cap15c_contracts.ps1` K1-K16, each negative rule
observed firing on a planted case where it was new (K3's name rule, K14's
pattern), and `check_dev_trust` section 7.

## SUPERSESSIONS

| what | before | after | why |
|---|---|---|---|
| brief: transport `mormot.net.ws.client` raw-frame, `mormot_net_ws_files = 1` | - | own RFC 6455 over `mormot.net.sock`, `= 0` | measured at Checkpoint 1 (ledger 15C-3) |
| brief: `pweb.socket.open` etc. | three segments | `pweb.socketOpen` etc. | frozen two-segment grammar (15C-4) |
| binding request bound in a network host | 1 MiB default | 2 MiB | a 1 MiB base64 message could not cross (15C-5) |
| scheduler in a network host | 4 workers / 4 slots | 8 / 8 | parked long-polls must not starve RPC (15C-6) |
| CAP-5 SDK zero-network pattern | bare `WebSocket` | anchored, plus `ws://`/`wss://` | the SDK's own class names (15C-9) |
| CAP-6 zero-network pattern | bare `socket` on the raw line | `socket` matched in code (literals and comments removed); URL and loopback patterns still on the raw line; planted-vector self-test | the bundler must spell the socket field names to refuse them (15C-16) |
| six zero-transport sweep headers | fetch is the only outbound client | fetch and socket transports | re-scoped, not deleted (K13) |
| divergence allowlist / frozen core | - | socket transport at 2 directives; decorator frozen | K11 |
| dev-trust | sections 1-6 | section 7 | the socket door's development-trust half |
| bundler refusal | `network`, `origins`, `connect`, `csp` | plus `socket`, `sockets`, `websocket`, `ws`, `wss` | build proof B5 |
| evidence / aggregator | - | 44 CAP-15C fields: all required, 26 compared, 25 pinned absolutely, `socket_suite` must read PASS, 4 per-target families | the brief's refusals |
| `test/cap11a/collection-paths.json` records | - | +15 CAP-15C paths, same commit | CAP-15B's lesson |
| CAP-10B1 React project inventory, held as literals in `test/cap10b2/run_cap10b2_gates.ps1` | `eabbc88d…`, 76 854 bytes, 16 files | `31244b06…`, 78 679 bytes, 16 files | the React template's `program.lpr` and `app.services.pas` grew inside `PWEB_NET`; measured identically in the Windows and Linux CAP-10B1 records |
| `step-applicability.tsv` / `ci_sequence_digest` | 205 steps | 206 steps, measured on the CAP-15C hosted run | one step on four legs |
| backlog census | 404 entries, 53 open | 419 entries, 57 open | ledger 15C-1..15C-15 |

## REGRESSIONS

### windows-x86_64 (local chain, one pass, in CI order)

GREEN: `pwebtests` (the CAP-8A/8B corpora - `capability-policy.txt`
`23b87da5…`, `navigation-policy.txt` `360d69f2…`, both equal to the values on
record); CAP-5 protocol, zero-network sweep and both real-frontend smokes;
CAP-6 gates and release smoke; CAP-7F divergence (222 conditionals, all
allowlisted), mormot defines, schema agreement, host arguments; CAP-10A
(contracts, dev trust, gates); CAP-10B0; CAP-10B1 (gates and the real-window
build proof); CAP-10C0 (including the Pas2JS `pweb run` answering 42); C1;
C2; D0; D1; D2 gates; the CAP-10 and CAP-11 ledgers; CAP-11A structure,
flake instrumentation and migration map; CAP-14A; CAP-14B; CAP-15B
(contracts, build, gates); CAP-15C (contracts, build, gates - 121 rows, 0
failures); the backlog gate (420 entries, 0 orphans). Also: the headless
socket suite 322/322 with corpus `95b2cf7c…`, `tsc --noEmit` clean, the
Pas2JS harness 72/72.

NOT GREEN, each with its cause:

| step | cause | disposition |
|---|---|---|
| CAP-6 zero-network sweep | a real regression of this shard: the bundler's socket-field refusal spelled `socket` | FIXED and re-run PASS (ledger 15C-16) |
| CAP-10D2 contracts | 13 violations, every one "a shipped path is modified in the working tree" - this shard's own uncommitted files | clears on commit; re-run after it |
| CAP-5 host build, CAP-6 release-host build | this host's bare `fpc` is the i386 compiler and these two scripts, unlike the CAP-10 ones, pass no `-Px86_64`; they rely on the CI runner's compiler | environmental; the same host units are compiled by the CAP-10 chain above |

### linux-x86_64 (WSL, in the declared CI order)

A HOST FINDING FIRST, because it cost a chain and would read as a regression
if it were not measured. Part-way through the Linux chain every real-window
run started to hang - React and Pas2JS alike, `pweb run` and the build
proofs alike - for 90 s, until the harness killed it, while the same proofs
had passed earlier in the same chain. It is NOT this shard:

| run | tree | result |
|---|---|---|
| `prove_cap10b2.sh` | CAP-15C working tree | Pas2JS app killed at 91 s, no report |
| `prove_cap10b2.sh` | the baseline commit `245ad80`, rebuilt in its own tree | Pas2JS app killed at 92 s, no report - identical |
| `prove_cap10b2.sh` with `WAYLAND_DISPLAY` unset, `GDK_BACKEND=x11` | CAP-15C working tree | exit 0 in 21 s, report received, React/Pas2JS parity PASS |

WSLg had stopped serving its compositor while still advertising
`WAYLAND_DISPLAY=wayland-0` - no such socket existed in `XDG_RUNTIME_DIR` or
under `/mnt/wslg` - and GTK waits on it instead of using the Xvfb display
`xvfb-run` provides. The rest of the Linux chain was re-run with the
override exported. Hosted runners have no WSLg and are unaffected.

A SECOND HOST FINDING, of the same kind: the WSL copy is synced from the
Windows checkout, whose gitignored `sdk/typescript/dist` dates from
2026-09-09 - before CAP-15C - and the sync excluded `node_modules` but not
`dist`, so CAP-10B1 staged a runtime with no socket module and the socket
composition refused on its own precondition. The last batch rebuilt the SDK
from the current source, confirmed `dist/src/socket.js` in the staged root,
and re-ran every step that consumes it. Hosted CI builds the SDK fresh.

GREEN, in the declared order: the TypeScript SDK build and its 29 tests; the
React and Pas2JS frontend builds; CAP-7L build and gates; CAP-10A (contracts,
dev trust, gates); CAP-10B0; CAP-10B1 (gates, real-window proof: 42); CAP-10B2
(gates with the superseded pin, real-window proof: Pas2JS exit 0, parity
PASS); CAP-10C0; C1 (after the proof it compares against was re-run in
order); C2; C3 (and the CAP-10C ledger); D0; D1; the CAP-10 ledger; CAP-14A;
CAP-14B; **CAP-15B composition** (33 s) and gates; **CAP-15C composition**
(34 s) - a release build declaring `https://127.0.0.1:18791`, the page's
`PWebSocket` opened and `echoed`, a real reload closed the replaced
document's socket `1001/`, host shutdown closed the socket left open `1001/`
before the drain, `rpc_result 42`, 47 listener samples with 0 listeners and 1
client connection typed - then CAP-15C contracts, build and gates (0
failures, corpus `95b2cf7c…` identical to Windows,
`tls_name_verification = measured_wrong_name_refused`, the flood's longest
blocked write 2678 ms, a 1 MiB send in 20 ms); the divergence, mormot
defines, CAP-5 and CAP-6 sweeps, dev trust and the backlog gate.

NOT GREEN, each with its cause:

| step | cause | disposition |
|---|---|---|
| CAP-7L zero-transport runtime half | needs the release layout `run_release_layout.sh` builds, which this chain did not run; its source half passed (12 files clean) | ordering; the source half is the part this shard touched |
| CAP-10D2 contracts | "a shipped path is modified in the working tree" - the WSL copy's index belongs to an older commit and its synced files are CRLF | the same rule as on Windows; a local-copy property, clears in a clean checkout |

CAP-10D2 build and gates were first blocked on the QuickJS licence the CAP-9C1
release harness stages; that harness could not read its own marker from a
CRLF copy of `quickjsrelease.pas`. With the WSL copy's cap9 sources
normalised to LF (in the copy only), CAP-9C1 passed its C1-C30 matrix and
CAP-10D2 build and gates passed in 133 s.

## FREEZE

Held: `src/rpc/pweb.rpc.fetch.pas`, `pweb.rpc.fetch.mormot.pas`,
`pweb.platform.cocoa.fetch.pas`, `pweb.rpc.command.pas` and
`pweb.navigation.policy.pas` byte-identical to the baseline (K15, LF sha256
pinned); schema-2 grammar unchanged; no new `pweb.json` field, CLI option or
environment variable; `PWEB_NATIVE_CSP` unchanged; `capability_policy_digest`
`23b87da5…` and `navigation_policy_digest` `360d69f2…` re-measured unchanged
on Windows. CAP-12 not begun; door B not reopened.

## KNOWN LIMITATIONS

1. **CAP-15B's fetch transport has the TLS name gap on Linux** (ledger
   15C-1): a trusted certificate issued for another host is accepted. It was
   measured here and deliberately not fixed, because this shard freezes the
   fetch units byte for byte; the fix is the one line the socket transport
   now carries, plus a trusted-right-name / trusted-wrong-name live pair. It
   should be the next thing done.
2. The fetch decorator accepts an escaped NUL that mORMot rewrites to `?`
   (15C-7); same owner.
3. Darwin: nothing measured (15C-12).
4. On Linux a trusted subframe document also closes the window's sockets
   (15C-8), the safe direction.
5. The generation-switch row is witnessed by composition rather than by a
   `pweb dev` run holding a socket (15C-13).
6. The CAP-15B final artifact still reads NOT READY (15C-14).

## VERDICT

CAP-15C NOT READY
