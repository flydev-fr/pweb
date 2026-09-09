# CAP-15B — Checkpoint 1

Branch `phase/cap-15/b-native-fetch-door`, cut from `main` at `aa7cc20`.
Nothing is implemented. This document carries the two measurements §10 asks
for, the findings §1–§10 earned when it was read against the code and the
dependency, and the plan the shard would execute.

**CAP-15A verified.** Hosted run `34390332097` on commit `5977969`,
conclusion `success`, all six jobs green (`windows`, `linux`, `macos-x64`,
`macos-arm64`, `macos release inventory`, `cap7 aggregate`). The closure
commit `aa7cc20` is docs-only and its own run `34398950412` was still in
progress when this was written.

---

## 1. §10 — the Darwin `NSURLSession` measurement

### F-1 — this session cannot take that measurement, and no design decision waits on it

The dev host is Windows with WSL (Ubuntu 24.04, FPC 3.2.3, OpenSSL 3.0.13).
There is no macOS anywhere in reach except the hosted `macos-15` and
`macos-15-intel` runners. `NSURLSession` cannot be compiled, let alone run,
from here, so the seven rows §10 names are **UNMEASURED** at this checkpoint
and saying otherwise would be inventing evidence.

What can be settled without a Mac is *which mechanism* each row uses and
whether the mechanism is public, documented API — because §10's real risk is
not "does macOS have an HTTP client" but "can the asynchronous, ambient-state
API be made to satisfy §4 behind a synchronous injected seam". Row by row:

| §10 row | mechanism | status |
|---|---|---|
| async API → bounded synchronous call on a worker thread | `-[NSURLSession dataTaskWithRequest:]` (the **delegate** form, never the completion-handler form) on a session built with `sessionWithConfiguration:delegate:delegateQueue:` and a private serial `NSOperationQueue`; the calling worker blocks on a `dispatch_semaphore_t` that `URLSession:task:didCompleteWithError:` signals. A private delegate queue is what removes the run-loop requirement from the calling thread | mechanism public; **unmeasured** |
| deadline observable **during** the transfer | two, together: `NSURLSessionConfiguration.timeoutIntervalForResource` (a wall-clock *total resource* bound, which is exactly §4's semantic and not a per-read timeout), and a sliced `dispatch_semaphore_wait` that re-checks the monotonic deadline and `ICancellationToken.IsCancelled` between slices and calls `-[NSURLSessionTask cancel]` | mechanism public; **unmeasured** |
| `RedirectMax = 0` equivalent | `URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:` invoked with `nil` — documented to make the session deliver the 3xx response body and headers instead of following it, which is precisely what §4 requires (a 3xx returned with its `Location`) | mechanism public; **unmeasured** |
| response bound enforced **during** the read | `URLSession:dataTask:didReceiveResponse:completionHandler:` refuses on `expectedContentLength` with `NSURLSessionResponseCancel`; `URLSession:dataTask:didReceiveData:` keeps the running total and cancels the task at the byte that crosses the bound | mechanism public; **unmeasured** |
| ambient cookie jar **off**, not merely unused | `configuration.HTTPCookieStorage = nil` **and** `HTTPShouldSetCookies = NO` **and** `HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever`. `ephemeralSessionConfiguration` alone is refused as the answer: it gives a *private* jar, not *no* jar, and §4 says no jar. `URLCache = nil` and `URLCredentialStorage = nil` go with it, for the same reason | mechanism public; **unmeasured** |
| system trust store | by **not implementing** `URLSession:didReceiveChallenge:completionHandler:` at all. Default handling is full system evaluation, and an absent delegate method is the strongest possible form of "no setting anywhere can disable it" — there is no code path to reach | mechanism public; **unmeasured** |
| no proxy inherited | `configuration.connectionProxyDictionary = @{}` | mechanism public; **unmeasured, and the row I least trust** |

**The two rows I would not sign without a run**, and why:

1. **`connectionProxyDictionary = @{}`.** CFNetwork reads the system proxy
   configuration by default, and an empty dictionary is the documented way to
   override it — but "override with nothing" and "use nothing" have not always
   been the same thing across macOS releases, and a PAC-configured machine is
   the case where they diverge. This is `15A-7` on Darwin, and `15A-7` exists
   because the same class of default cost the spike a silent proxy on the
   other two targets.
2. **The overshoot of the running-total bound.** `didReceiveData:` delivers
   whatever CFNetwork has buffered; the bound is enforced at the *delivery*
   that crosses it, so peak memory is bound + one delivery. That is
   categorically better than the spike's 32 MiB, but the size of one delivery
   is an implementation detail of the framework and belongs in a measurement,
   not in a paragraph.

**Disposition proposed.** §10 forbids falling through to option 1 (ship
OpenSSL) or option 3 (scope macOS out) if the measurement disappoints, and
nothing here suggests it will: every row has a public mechanism and none of
them needs the seam to change shape. So the plan keeps `NSURLSession` and
makes the measurement the shard's **first hosted act**: `test/cap15b/`
carries a Darwin probe that drives all seven rows against a local server on
the runner and emits them as typed evidence fields, and the shard's PASS is
conditioned on those fields. If a row fails there, it returns as a finding —
never as a silent fall-through.

This is the honest reading of "measured at 15B's Checkpoint 1, not assumed":
the instrument is written here, the host is not here, and one hosted run
closes the gap. **I am not going to claim a measurement I did not take.**

---

## 2. §10 / ledger `15A-8` — Linux OpenSSL as a runtime dependency

### Measured, locally, this session

| fact | measurement |
|---|---|
| do the pinned mORMot statics carry OpenSSL? | **No.** `deps/mormot2/static/x86_64-linux` holds exactly `crc32c64.o`, `libdeflatepas.a`, `liblizard.a`, `quickjs.o`, `sha512-x64sse4.o`, `sqlite3.o` — no `libssl`, no `libcrypto`. `OPENSSLSTATIC` is defined by mORMot only for Android and one legacy macOS target, never for `x86_64-linux` |
| where does the provider come from, then? | **the system.** `mormot.lib.openssl11` dynamically loads `libssl.so.3` / `libcrypto.so.3` at first use, and registers itself as the TLS layer in its own `initialization` (`if not Assigned(NewNetTls) then @NewNetTls := @NewOpenSslNetTls`). TLS on POSIX therefore exists **only if the unit is linked** — it is a `uses` decision, not a runtime discovery |
| the WSL reference machine | `libssl.so.3` and `libcrypto.so.3` present at `/lib/x86_64-linux-gnu/`; `OpenSSL 3.0.13 30 Jan 2024`. A probe built against `deps/mormot2` and run there reports `openssl available: TRUE`, `OpenSSL 3.0.13 30 Jan 2024` |
| Windows | needs nothing. A probe linking `mormot.net.client` built and ran with `NewNetTls assigned: TRUE` — `mormot.net.sock.windows.inc` registers SChannel in its own initialization, with no unit named and no dependency added. §10's Windows claim is confirmed |

### Proposed `docs/third-party-licenses.md` row

It belongs beside the **GTK/WebKitGTK** entry, not beside the vendored ones,
because it is the same shape: a system library, dynamically linked,
unmodified, never redistributed by this project.

> ## OpenSSL 3 (Apache License 2.0, dynamically linked, Linux only)
>
> The Linux build reaches TLS through the target system's own OpenSSL 3
> (`libssl.so.3`, `libcrypto.so.3`), loaded at runtime by mORMot's
> `mormot.lib.openssl11` binding. **Nothing is vendored, bundled, patched or
> redistributed**: the pinned mORMot statics under
> `deps/mormot2/static/x86_64-linux` contain no cryptographic library, the
> release layout contains no OpenSSL file, and the shared objects belong to
> the distribution that installed them. OpenSSL 3 is distributed under the
> Apache License 2.0; those terms are satisfied by that distribution.
> Applications that choose to redistribute OpenSSL themselves — which PWeb
> neither does nor recommends — become responsible for carrying its licence
> text.
>
> Windows needs no such dependency (SChannel is inside mORMot, supplied by
> the operating system) and macOS needs none either (`NSURLSession` on the
> system trust store — `docs/cli-contract.md` §5).

The ship table at the top of that document gains **no** row: nothing new is
shipped. That is the point of the entry.

### Proposed `doctor` wording (§6, `platform.tls`)

Severity `required`; applies when `network.origins` is non-empty, otherwise
`not_applicable` with cause `no_network_origins`.

| target | status | cause | observed | expected | remediation |
|---|---|---|---|---|---|
| windows | pass | `ok` | `schannel` | `schannel (built in)` | — |
| linux, OpenSSL ≥ 3 | pass | `ok` | `openssl 3.0.13` | `openssl >= 3` | — |
| linux, OpenSSL < 3 | fail | `openssl_too_old` | `openssl 1.1.1w` | `openssl >= 3` | `install libssl3 / openssl 3 from your distribution` |
| linux, absent | fail | `openssl_missing` | `absent` | `openssl >= 3` | `install libssl3 (libssl.so.3) from your distribution` |
| macos | pass | `ok` | `nsurlsession (system trust store)` | `nsurlsession` | — |

`doctor` stays diagnostic-only: the Linux row is answered by `dlopen`-ing the
system library through the injected environment to read its version string.
No socket is opened, no name is resolved, no declared origin is contacted,
and nothing is written — the same standard every other row already meets.

---

## 3. Findings against §1–§10

Brought back rather than deviated from silently, as instructed. Each one
names what I would do absent a different instruction.

### F-2 — §7.3's release-image byte sweep cannot pass as written, and already cannot pass today (MEASURED)

§7.3 requires that the production binary carry "no `http://` origin literal,
no `127.0.0.1`, no `localhost`". Read as a byte sweep of the built image — and
§7.3 says explicitly that it *is* a byte sweep — that is false in both
directions:

| image | `http://` | `127.0.0.1` | `localhost` |
|---|---|---|---|
| **today's shape** — `mormot.rest.memserver` + `mormot.soa.server`, no door (linux-x86_64) | 0 | **3** | 0 |
| **with the door** — adds `mormot.net.client` + `mormot.lib.openssl11` (linux-x86_64) | **3** | 2 | 2 |
| **with the door** — adds `mormot.net.client` (windows-x86_64, SChannel) | **3** | 1 | 1 |

The occurrences are mORMot's own: the `http://` hits are the bare prefix and
`http://unix:`, and the `127.0.0.1` hits include `RemoteIP: 127.0.0.1` from
the REST core — which is why the *baseline*, before this shard adds anything,
already carries three of them. A sweep written this way would go red on the
first hosted run for a reason that has nothing to do with the network door,
and the obvious "fix" — deleting the terms — would delete the proof.

**Proposed replacement**, which keeps §7.3's intent exactly and is what the
evidence field `release_relaxation_literals = 0` should count:

1. **no loopback origin**: the image contains no `http://127.0.0.1`,
   `http://localhost`, `http://[::1]` or `http://0.0.0.0` — `http://`
   immediately followed by a loopback host, which is what the `PWEB_DEV`
   exception would look like if it survived a release compile. Measured 0 on
   both probes;
2. **no wildcard and no plaintext in the compiled set**: proven by the
   allowlist digest (below) plus the descriptor grammar, not by a substring
   search;
3. **no TLS relaxation**: see F-3 for the spellings that actually exist;
4. **no proxy inherited**: proven at the source (F-6) rather than at the
   bytes;
5. **exactly one `mormot.net.client` in the compiled unit set** — the
   existing CAP-14A "ppu corroboration" pattern, not a string search;
6. **positively**: every declared origin literal **is** present in the image,
   and so is the allowlist digest constant. `declared == compiled` proven by
   presence, which a substring-absence rule can never do.

### F-3 — §7.3 names a TLS-relaxation spelling that would sweep vacuously (MEASURED)

`IgnoreTlsCertificateErrors` occurs in mORMot only as the *parameter* name
`aIgnoreTlsCertificateErrors`, on the convenient entry points §4 already
forbids. The names that would actually appear if someone disabled validation
are `TNetTlsContext.IgnoreCertificateErrors` (37 occurrences in
`deps/mormot2/src`) and `IgnoreTlsCertError` (3). In a *binary* all four
count 0, because none of them is a string. So §7.3's row, taken literally, is
a check that cannot fail.

**Proposed**: the relaxation sweep is a **source** sweep over the fetch
units, forbidding `IgnoreCertificateErrors`, `aIgnoreTlsCertificateErrors`,
`IgnoreTlsCertError`, `AllowDeprecatedTls`, `DisableTls13` — plus the
convenient constructors `OpenUri`, `OpenOptions`, `TSimpleHttpClient`,
`HttpGet`, `HttpPost` (F-6). The binary sweep keeps only the rows F-2 leaves
it.

### F-4 — §2's 262-byte origin bound is five bytes short of its own worst case

§2 states "each at most **262** bytes (`https://` + a 253-byte host +
`:65535`)". That sum is `8 + 253 + 6 = 267`; 262 is `8 + 253 + 1`, i.e. the
colon without the port digits. As ratified, a maximum-length host with an
explicit port is refused by a bound whose own justification says it should
fit.

**Proposed**: `PWEB_FETCH_MAX_ORIGIN_BYTES = 267`, with the arithmetic spelled
in the constant's comment. Absent a different instruction I will implement
267 and record the correction here and in the closure artifact — implementing
262 would ship a bound the contract's own parenthesis contradicts.

### F-5 — §4/§5's base64 inline cap is unspecified

§4 says the inline body is "≤ 1 MiB as text when valid UTF-8, else base64
**with a smaller cap**", and never says what it is. Something has to be
chosen, and the choice is visible in an envelope.

**Proposed**: `PWEB_FETCH_MAX_BASE64_INLINE = 786432` (768 KiB). Encoded that
is exactly `786432 × 4 / 3 = 1048576` bytes — one MiB, with no padding — so
the two caps produce the same maximum envelope, which is the property that
made §4 want a smaller number in the first place. A binary response between
768 KiB and 8 MiB is then `service_error` /
`response_too_large_to_inline`, naming both the applicable inline cap and the
8 MiB ceiling, exactly as §4 requires for the text case.

### F-6 — §4's "no proxy" and "no retry" are provable at the source, and should be pinned there

Measured against the dependency:

- **retries.** `THttpClientSocket.Request`'s own declaration says "AsRetry is
  to be kept as false, because this method already retries by itself", and
  the retry state lives in `THttpClientRequest.Retry: set of (rMain, rAuth,
  rAuthProxy)`. Passing `AsRetry := true` enters with `rMain` already set, so
  the self-retry branch is not taken. This is `15A-4`'s ratified remedy and it
  works;
- **proxy.** `THttpRequestExtendedOptions.Proxy: RawUtf8` defaults to `''`,
  which means *use the system proxy*, and it is reached by `OpenUri`,
  `OpenOptions` and `TSimpleHttpClient`. `Create` + `OpenBind` consults
  nothing at all.

**Proposed**: the source gate over `src/rpc/pweb.rpc.fetch.mormot.pas`
requires `AsRetry := true` at the one call site and forbids `OpenUri`,
`OpenOptions`, `TSimpleHttpClient`, `HttpGet`, `HttpPost` outright. A rule
about a default is only as good as the constructor it forbids.

### F-7 — §4's response bound *during the read* is reachable without touching mORMot (MEASURED)

The spike could not do it; the API can. `THttpClientSocket.Request` takes an
`OutStream: TStream`, and `THttpSocket.GetBody(DestStream)` writes into it in
≤256 KiB slices (Content-Length path) or chunk by chunk (chunked path). A
custom sink therefore sees every slice before it is accumulated, so it can
refuse at the byte that crosses the bound, and can check the wall-clock
deadline and `ICancellationToken.IsCancelled` between slices. Two details make
it safe rather than hopeful:

- `RequestInternal`'s `except` block re-raises anything that is not `ENetSock`
  or `EHttpSocket` — its comment says "propagate custom exceptions to the
  caller (e.g. from progression)" — so a refusal raised by the sink reaches
  the transport and does **not** enter `DoRetry`;
- `RequestInternal` sets `TStreamRedirect(bodystream).ExpectedSize` from
  `Http.ContentLength` **before** calling `GetBody`, so a sink descending from
  `TStreamRedirect` gets §4's *Content-Length* half too, refusing a declared
  over-bound length with at most one slice read.

This is reported as a finding only because §4 marks the row "specified beyond
the instrument": it is now specified **and** mechanically underwritten on
Windows and Linux. Peak memory is bound + one slice, never 32 MiB.

One consequence worth stating: `GetBody` raises if a `Content-Encoding` is
present while an `OutStream` is used. The transport registers no compressor
and sends no `Accept-Encoding`, so a conformant server will not compress; a
non-conformant one that does becomes a typed `service_error`, never a silent
truncation.

### F-8 — §8's `https://` src-sweep trips on four comments today (MEASURED)

`src/**` contains four `https://` occurrences, **all in comments**:
`pweb.lib.webview.pas:5`, `pweb.script.package.pas:588`,
`pweb.navigation.policy.pas:319` and `:320`. Two of them sit inside single
quotes *within* the comment (`'https:///x'`, `'https://...'`), so the literal
extractor `check_dev_trust.ps1` already uses — which scans quoted spans line
by line — would flag them. Its own section 2 says a gate that could not tell a
literal from its explanation "would forbid the explanation".

**Proposed**: the §8 sweep strips Pascal comments (`//`, `{…}`, `(*…*)`)
before extracting literals, and then flags a literal matching an origin shape
(`^https?://[a-z0-9.\-]+(:\d+)?/?$`). Both halves are needed: stripping alone
would still miss nothing, and the shape test alone would still trip on
`'https://...'`.

### F-9 — the CAP-8A capability corpus must not gain a `network.fetch` row

`capability_policy_digest` is the SHA-256 of `capability-policy.txt`, the
CAP-8A decision corpus, and acceptance requires it unchanged. Adding
`network.fetch` to that corpus would move it. The capability is therefore
exercised only in the CAP-15B suite. Not a defect — a constraint that has to
be written down before someone "improves" the corpus.

---

## 4. The unit map against §1

| file | new? | what it holds | what it may not name |
|---|---|---|---|
| `src/rpc/pweb.rpc.fetch.pas` | new | `TPWebFetchBridge` (the `IInvocationBridge` decorator), the injected `TPWebFetchTransport` function type, the request/response records, the origin allowlist comparison, the header allowlists, every bound, the deadline, the envelope, the `pweb.fetch` / `network.fetch` constants | any `mormot.net.*`, any `{$ifdef}`, any operating system. Joins the CAP-7F zero-conditional core list |
| `src/rpc/pweb.rpc.fetch.mormot.pas` | new | `PWebFetchMormotTransport` — the one function satisfying the seam on Windows and Linux. `Create` + `OpenBind`, `RedirectMax := 0`, `AsRetry := true`, an explicit `TNetTlsContext`, the `TStreamRedirect` sink of F-7. Names `mormot.lib.openssl11` under `{$ifdef OSPOSIX}` so Linux has a TLS layer at all | — (this is the **only** file in `src/**` permitted to name `mormot.net.client`) |
| `src/platform/macos/pweb.platform.cocoa.fetch.pas` | new | `PWebFetchCocoaTransport` — the Pascal side of the Darwin transport | any `mormot.net.*` |
| `src/platform/macos/pweb_cocoa_bridge.{h,mm}` | grows | the `NSURLSession` entry points of §10, in the file that already owns every Objective-C frame this project needs | — |
| `src/rpc/pweb.rpc.command.pas` | **untouched** | — | — |
| `src/security/pweb.navigation.policy.pas` | **untouched** | — | — |
| `src/webview/pweb.webview.host.pas` | **untouched** | — | — |

**The seam is a plain function type, not an eighth interface** — deliberately
the same shape as `TPWebExternalOpener`, so the kernel's "no eighth boundary"
rule is satisfied by construction rather than by argument:

```pascal
TPWebFetchTransport = function(const Request: TPWebFetchRequest;
  const Token: ICancellationToken; out Response: TPWebFetchResponse):
  TPWebFetchOutcome;
```

A nil transport at construction raises, exactly as a nil opener does.

**Who selects the transport.** The generated `program.lpr`, inside the region
the descriptor's origins control, and nowhere else:

```pascal
{$ifdef PWEB_NET}
  pweb.rpc.fetch,
  {$ifdef DARWIN}
  pweb.platform.cocoa.fetch,
  {$else}
  pweb.rpc.fetch.mormot,
  {$endif DARWIN}
{$endif PWEB_NET}
```

That keeps `pweb.webview.host` byte-untouched, keeps `mormot.net.client` out
of every image whose project declared no origin, and keeps
`mormot_net_client_files = 0` on Darwin — all three by the compiler's own
reachability rather than by a promise.

---

## 5. Schema 2 in the reader, and how a schema-1 descriptor reads as `[]`

`tools/pweb/pweb.cli.project.pas` is a hand-written strict JSON reader. Its
`ParseObject` classifies members as `pjkString | pjkInteger | pjkObject |
pjkOther`, and **an array is `pjkOther` with its text discarded**. So schema 2
needs one structural addition and one branch:

1. **`pjkArray`** joins the kind enum, with the exact substring captured the
   way `pjkObject` already captures one (`SkipObjectOrArray` is already
   written and already used for `[`). Nothing else about the reader changes:
   the encoding rules, the duplicate-key rule, the trailing-content rule, the
   secret-key rule, the 64 KiB bound and the path model are all untouched;
2. **a string-array reader** for `network.origins`: elements must be strings
   (anything else is `pcrFieldType`), at most 8, each ≤ 267 bytes (F-4);
3. **the schema branch** replaces `if Result.Schema <> PWEB_CLI_SCHEMA` with
   an accepted set `{1, 2}`, and the known-key list becomes schema-dependent —
   `network` is unknown in schema 1 (so a schema-1 descriptor that carries it
   is `descriptor_unknown_field`, which is the honest answer) and required in
   schema 2;
4. **`TPWebCliProject` grows** `NetworkOrigins: TRawUtf8DynArray` and
   `NetworkOriginsDigest: RawUtf8`. **A schema-1 descriptor leaves the array
   `nil`** — `Default(TPWebCliProject)` already does that, so "reads as `[]`"
   is the *absence* of a branch rather than a branch, which is the strongest
   form the ruling can take;
5. **new refusals**, each one cause: `pcrOriginGrammar`, `pcrOriginCount`,
   `pcrOriginTooLong`, `pcrOriginDuplicate` — refused **at descriptor load**,
   so `dev`, `doctor` and `build` refuse identically because they all call
   `PWebCliOpenProject`;
6. **the grammar**, in one function `PWebCliValidOrigin(const Origin: RawUtf8;
   AllowLoopbackHttp: Boolean)`: parsed components only — scheme, lowercase
   host, optional `:port` — no path, query, fragment, userinfo, `*`, wildcard
   label, trailing dot, uppercase or byte ≥ `$80`. `https` always; `http`
   only with host `127.0.0.1` or `localhost` **and** an explicit port, and
   only where the caller says a dev host is being described;
7. **canonicalisation before comparison**: the default port is dropped on both
   sides (`https://a.example` and `https://a.example:443` are one origin, and
   declaring both is the duplicate refused by 5). The §2 byte bound is
   measured on the canonical form.

`pweb create` emits schema 2 with `"network": { "origins": [] }`
(`PWebScaffoldDescriptor` in `pweb.cli.scaffold.pas`, one literal).

---

## 6. Templates, SDKs, and the compiled allowlist

**Where the Pascal literal comes from.** §2 says `pweb build` compiles the
canonicalized set into the generated host as a Pascal literal, and the
pipeline's mutation gate forbids writing anywhere but
`<root>/<output>/`, `frontend/.pweb/`, `frontend/node_modules/` and
`frontend/dist/`. So the build generates
`<output>/<os>-<arch>/gen/app.network.inc` — the canonical origin array plus
`APP_NETWORK_ALLOWLIST_DIGEST` — and `pweb.cli.native` adds `-Fi<gen>` and
`-d<PWEB_CLI_NETWORK_DEFINE>` **only when the set is non-empty**. A project
with `[]` (which is every schema-1 project) therefore gets a compiler vector
byte-identical to today's, and CAP-10C1's `pipeline_digest` is re-measured
**unchanged** rather than re-baselined.

**Both templates** gain, inside `{$ifdef PWEB_NET}` and nowhere else:
`program.lpr` — the transport selection above, `{$I app.network.inc}`, and
the one construction line that installs the decorator; `app.services.pas` —
`network.fetch` in `AppMaximum`, in the window and principal sets, and
`MapMethod(PWEB_METHOD_FETCH, [PWEB_CAP_NETWORK_FETCH])`. Outside the region
neither file mentions the door, which is the mechanical form of §7.5's "iff".

**`@pweb/runtime`** gains `sdk/typescript/src/http.ts` exporting one
function — `fetch(request): Promise<PWebFetchResponse>` — that does nothing
but call `invoke('pweb.fetch', args)` and type the envelope. It contains no
URL construction, no default origin, no retry, no header defaulting and no
policy: every one of those is a native decision, and an SDK that helpfully
supplied one would be a second answer. `sdk/pas2js/pweb.native.pas` gains the
twin. Both are one new *file* in the TypeScript package, so
`sdk_ship_table_digest` supersedes.

---

## 7. The smallest production/test diff

**New production files: 3** — `src/rpc/pweb.rpc.fetch.pas`,
`src/rpc/pweb.rpc.fetch.mormot.pas`,
`src/platform/macos/pweb.platform.cocoa.fetch.pas`.

**Edited, all additively: 12** — `pweb_cocoa_bridge.h` / `.mm` (the
`NSURLSession` entry points), `tools/pweb/pweb.cli.project.pas` (schema 2),
`pweb.cli.toolchain.pas` (two constants), `pweb.cli.native.pas` (`-d` + `-Fi`,
non-empty sets only), `pweb.cli.pipeline.pas` (generate the include),
`pweb.cli.doctor.pas` (two rows), `pweb.cli.scaffold.pas` (schema 2 literal),
`tools/bundler/pwebbundle.pas` (§7.4's refusal), and the four template files
(`program.lpr` + `app.services.pas` × react, pas2js). Plus
`sdk/typescript/src/http.ts` (new) and `sdk/pas2js/pweb.native.pas` (edited).

Files deliberately **not** touched, and each is load-bearing:
`src/security/pweb.navigation.policy.pas` (the CSP), `src/rpc/pweb.rpc.command.pas`,
`src/rpc/pweb.rpc.intf.pas`, `src/rpc/pweb.rpc.scheduler.pas`,
`src/security/pweb.capabilities.policy.pas`, `src/assets/pweb.assets.htmlpolicy.pas`
(§9 says it needs no change and it does not), `src/webview/pweb.webview.host.pas`.

---

## 8. Assumptions I will take where §1–§10 is silent

Stated here so none of them is a surprise in a diff.

| question | assumption |
|---|---|
| `method` absent or `null` | `GET`. Present but not a string → `invalid_request` |
| `timeoutMs` above the 30 s maximum | `invalid_request`, **not** silently clamped. A clamp is the half-working shape this repository refuses; the spike clamped |
| a body on `GET` or `HEAD` | `invalid_request`. A body on a bodyless method is a smuggling shape, not a convenience |
| URL length | ≤ 2048 bytes, the same ceiling `PWEB_EXTERNAL_URI_MAX_BYTES` already applies to an external URI |
| a byte ≥ `$80` anywhere in the URL | refused before parsing, with CR/LF/NUL. Punycode is the accepted spelling of an IDN, on both sides |
| userinfo (`@`) in the URL authority | refused. It is the classic way to make `evil.com` read as `api.example.com` |
| a repeated allowlisted response header | combined in order with `", "`, per RFC 9110 §5.3. `set-cookie` is excluded before this rule can apply |
| response header name case | lowercased in the envelope; the allowlist compares lowercased |
| `truncated` | `false` in every envelope this contract defines, per §5 |

---

## 9. Supersessions expected, none assumed

Each is re-measured at implementation and recorded old → new; none is
declared "unchanged" without a run.

| digest | why it moves |
|---|---|
| `doctor_schema_digest` (`3c597c8e…`) | two new rows enter the id+severity shape. Its hard-coded copy in `test/cap10c1/run_cap10c1_gates.ps1:925` moves with it |
| `doctor_checks` | +2 |
| `generated_inventory_digest`, `pas2js_generated_inventory_digest` | `pweb.json`, `program.lpr` and `app.services.pas` all change content |
| `template_semantic_digest`, `public_semantic_digest`, the template pack sha256 | the pack is regenerated from changed sources |
| `sdk_ship_table_digest`, `sdk_inventory_digest` | the TypeScript package gains a file |
| `cli_digest` | the CLI corpus gains the new refusal causes |
| `ci_sequence_digest` (`e0d2e3f2…`, 204 steps) | the four legs gain the CAP-15B step |
| `navigation_policy_digest` (`360d69f2…`) | **must not move.** Re-measured, not assumed |
| `capability_policy_digest` (`23b87da5…`) | **must not move** — see F-9. Re-measured, not assumed |
| `pipeline_digest` | **must not move** for an empty-origins project, by the `-d`/`-Fi` design above. Re-measured |
| CAP-14A's three digests | **must not move**. Re-measured |

---

## VERDICT

```
CAP-15B PLAN READY
```

with one measurement this host structurally cannot take (F-1, the Darwin
`NSURLSession` rows — the instrument is in the plan, the run is the shard's
first hosted act) and eight findings against §1–§10 that want a ruling before
they become code: **F-2** and **F-3** because the build proofs of §7.3 would
otherwise go red for the wrong reason or pass for no reason at all, and
**F-4**, **F-5** and **F-8** because they are numbers and rules a
reviewer will read off the diff. Absent a different instruction I will take
the proposal named in each finding, implement §1–§10 as ratified everywhere
else, and record every correction in the closure artifact.
