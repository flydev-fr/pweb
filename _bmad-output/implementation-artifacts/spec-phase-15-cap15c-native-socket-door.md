---
title: 'CAP-15C — pweb.socket: the native WebSocket door'
type: 'feature'
created: '2026-09-14'
status: 'done'
baseline_commit: '245ad806abdb7c7a988a66f533ee97ae331a10ce'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/cap15c-checkpoint1.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap15a-decision-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap15b-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A page can reach a declared origin only by request/response
(`pweb.fetch`); there is no socket, and `PWEB_NATIVE_CSP` keeps `connect-src
'self'` so the engine will never open one.

**Approach:** Four runtime-owned methods — `pweb.socket.open | send | receive |
close` — behind one capability, `network.socket`, in the same `PWEB_NET` region
that installs the fetch decorator. The decorator is `TPWebSocketBridge`, over an
injected transport. `receive` is a bounded long-poll. Both SDKs expose a
WebSocket-like object whose receive loop is the only part CAP-12 streaming will
replace.

## Boundaries & Constraints

**Always:** the CSP, the fetch units, `pweb.rpc.command.pas`, the navigation
classifier, `ICapabilityPolicy` and the scheduler stay byte-untouched. Schema 2's
grammar does not change: `wss→https` / `ws→http` by parsed components, `ws://`
only through a declared loopback `http` origin, which a release build refuses.
Every bound lives in one constants home and is cross-checked. Frames are bounded
on the header against the reassembled total. A full queue stops reading and
never drops. A socket dies with its window, its document, its capability and
its host, before the scheduler drains. Refusals are typed `service_error`
categories, never native text.

**Ask First:** any departure from `cap15c-checkpoint1.md`'s rulings F-1…F-12 as
ratified. Any bound that moves after ratification.

**Never:** CAP-12, door B, a second RPC path, an eighth interface, a listening
socket, a server unit in the image, a followed redirect, a cookie, an inherited
proxy, disableable TLS, page-driven ping/pong or fragmentation, a new
`pweb.json` field, option or environment variable.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| open, declared | `wss://api.example.com/feed` with `https://api.example.com` declared | `{id}`; `open` event carries the selected protocol | — |
| port trick | `wss://api.example.com:8443` with `https://api.example.com` declared | refused before any socket | `invalid_request` |
| plaintext remote | `ws://api.example.com` | refused | `invalid_request` |
| flood | peer sends faster than the page polls | reading stops at 64 events / 1 MiB; nothing dropped | — |
| reassembly flood | peer sends a 64 MiB message in 16 KiB frames | close 1009 at 1 MiB, memory flat | close `message_too_large` |
| foreign id | window B sends on window A's id | same answer as an unknown id | `service_error socket_not_found` |
| revoke | `network.socket` revoked | every socket of the principal closed before the call returns; zero further transport | close `revoked` |
| navigation / generation switch | top-level trusted document replaced | the window's sockets close | close `navigation` |

</frozen-after-approval>

## Code Map

- `src/rpc/pweb.rpc.fetch.pas:342-395` -- exported `PWebFetchParseOrigin`, `PWebFetchSameOrigin`, `PWebFetchParseOrigins`: reused for §6 authority, never copied
- `src/rpc/pweb.rpc.fetch.pas:120-190` -- 15B constants and the request-header allowlist to mirror exactly
- `src/rpc/pweb.rpc.fetch.mormot.pas` -- 15B transport shape: `TNetTlsContext` zeroed, `{$ifdef UNIX} mormot.lib.openssl11`, never a proxy entry point
- `test/cap15c/wsspike.pas` (`TRawSocket`) -- the measured RFC 6455 handshake, framing, sliced reader; seed of the transport
- `deps/mormot2/src/net/mormot.net.sock.pas:2087-2310` -- `TCrtSocket.Create/OpenBind/CreateSockIn/SockInPending/SockInRead(UseOnlySockIn)/TrySndLow`
- `src/webview/pweb.webview.host.pas:174-202,355-368,1077-1114` -- options record, defaults (Workers 4, MaxConcurrent 4), teardown order
- `src/webview/pweb.webview.binding.pas:83,529-538` -- 1 MiB request bound applied to the whole request
- `src/security/pweb.capabilities.policy.pas:237-250` -- grant mutators, no notification
- `src/platform/windows/pweb.platform.webview2.pas:1007`, `src/platform/linux/pweb.platform.webkitgtk.pas:1384`, `src/platform/macos/pweb.platform.cocoa.pas:1518` -- the three navigation decision sites
- `src/webview/pweb.webview.devhost.pas:377` -- generation switch re-navigation
- `src/rpc/pweb.rpc.scheduler.pas:410-470` -- source Quiesce/Close cancels the token for in-flight work
- `tools/templates/{react,pas2js}/src/{program.lpr,app.services.pas}` -- the `PWEB_NET` regions
- `sdk/typescript/src/http.ts`, `sdk/pas2js/pweb.native.pas:110-138,307-318` -- the 15B SDK shapes to twin
- `test/cap15b/*` -- gate, build, host-proof, composition and Darwin probe shapes to extend
- `test/cap10a/check_dev_trust.ps1:380-470`, `test/cap7f/check_divergence.ps1:222-250`, `test/cap11a/collection-paths.json:205-221` -- pins to extend

## Tasks & Acceptance

**Execution:**
- [x] `test/cap15c/pweb.test.socket.pas` + `cap15ctests.pas` -- the headless suite FIRST (every matrix row, §6 refusals, bounds, ownership, lifecycle, real-policy legs with their own corpus) -- test-first
- [x] `src/rpc/pweb.rpc.socket.pas` -- decorator, constants home, queue, watchdog, lifecycle handlers -- the decision
- [x] `src/rpc/pweb.rpc.socket.mormot.pas` -- RFC 6455 over `TCrtSocket` with wall-clock connect/send deadlines -- F-1…F-7; the TLS context carries the host name (measured: OpenSSL checked no name without it)
- [x] `src/platform/macos/pweb.platform.cocoa.socket.pas`, `pweb_cocoa_bridge.{h,mm}`, the seven Darwin rows in `test/cap15c/socketlive.pas` -- Darwin transport and its rows (measured on the hosted macOS legs only) -- §3
- [x] `src/security/pweb.capabilities.policy.pas`, `src/webview/pweb.webview.host.pas`, three guards -- additive seams -- F-8, F-10, F-11
- [x] both templates' `program.lpr` + `app.services.pas` -- the `PWEB_NET` region grows -- F-9
- [x] `sdk/typescript/src/socket.ts`, `index.ts`, `sdk/pas2js/pweb.native.pas` -- the SDKs -- §10
- [x] `tools/bundler/pwebbundle.pas` -- socket/ws field refusal -- build proof
- [x] `test/cap15c/` live program, contracts, host proofs, composition extension; `check_dev_trust` §7; divergence row; evidence fields; aggregator refusals; `collection-paths.json`; platform-leg action -- same commit as the records
- [x] `docs/cli-contract.md` §5 -- the socket door, the CAP-12 sentence, the amendments

**Acceptance Criteria:**
- Given a schema-2 project with `[]`, when built, then neither socket unit, `network.socket` nor `mormot.net.sock`'s socket transport is on its compiled unit set, and `pipeline_digest` is unchanged.
- Given a network image, when its compiled unit set is swept, then it names no `mormot.net.ws.*` and no `mormot.net.server`, the CSP is byte-identical, and the ws-literal sweep is clean in release and fires on its planted twin.
- Given the live program on four targets against `test/cap15c/ws_server.js`, when it runs, then open, text and binary echo, a 1 MiB message both ways, a server close with code, a refused 3xx, and measured backpressure are all green.
- Given the Linux composition, when a created project opens a socket through `@pweb/runtime` with four sockets parked, then it echoes, 42 answers, and listener members are 0 with the client socket typed.
- Given macOS x86_64 and arm64, when the Darwin probe runs, then every §3 row is measured with `darwin_socket_failures = 0`.
- Given the final HEAD, when hosted CI runs, then all legs and the aggregate are green, with both policy digests unchanged.

## Design Notes

The seam is a record of plain function types, not an interface. `Sink.Deliver`
is the decorator's queue and may block; blocking it IS the backpressure.
`r`-transport numbers, the bounds table, the event wire shape and the SDK
signatures are in `cap15c-checkpoint1.md` §1, §7, §10 and are not restated here.

## Verification

**Commands:**
- `pwsh test/cap15c/run_cap15c_spike.ps1` -- expected: both transports' rows written on windows and linux (instrument, not gate)
- `pwsh test/cap15c/build_cap15c.ps1; pwsh test/cap15c/run_cap15c_gates.ps1` -- expected: all rows green, windows and WSL linux
- `pwsh test/cap7f/check_mormot_defines.ps1` -- expected: `hits=0`, and firing on the planted copy
- the full Windows and WSL CAP chains before any push -- expected: green
