# CAP-15B — the native network door, built

```
CAP-15B NOT READY
hosted CI has not run on this HEAD; two acceptance rows are outstanding
```

The door CAP-15A ratified exists: `pweb.fetch`, behind the `network.fetch`
capability and a native per-application origin allowlist compiled into the
host, with `PWEB_NATIVE_CSP` unchanged. Everything mechanised here is green
on the two targets this development host can reach — Windows x86_64 and
Linux x86_64 under WSL — and the two rows that are not yet closed are named
at the end rather than implied.

---

## UNITS AND SEAM

| file | what it is |
|---|---|
| `src/rpc/pweb.rpc.fetch.pas` | the `IInvocationBridge` decorator: the origin grammar, both header allowlists, every bound, the deadline, the envelope, and the injected transport type. Names no `mormot.net.*` unit, carries no compiler conditional, names no operating system |
| `src/rpc/pweb.rpc.fetch.mormot.pas` | the Windows/Linux transport. **The only file in `src/**` that names `mormot.net.client`** |
| `src/platform/macos/pweb.platform.cocoa.fetch.pas` + `pweb_cocoa_bridge.{h,mm}` | the Darwin transport over `NSURLSession`, in the adapter layer, naming no `mormot.net.*` unit |

The seam is a **plain function type**, deliberately the shape of
`TPWebExternalOpener` rather than an interface, so the kernel's seven frozen
boundaries stay seven by construction:

```pascal
TPWebFetchTransport = function(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;
```

Both transports export the same `PWebFetchNativeTransport`, and the two units
are never on one compiled unit set, so the generated program names one
transport and carries no platform knowledge of its own. A nil transport, a
nil inner bridge or an origin the grammar refuses are all **startup**
refusals: the compiled allowlist is parsed once, by the same parser every
request URL goes through, so a malformed generated literal is loud before a
window exists.

`pweb.rpc.command.pas` is untouched.

## SCHEMA 2

The strict reader gains one member kind (`pjkArray`, captured by the bracket
walker that already skipped one), a bounded string-array reader, an accepted
schema window `{1, 2}`, a **schema-dependent** known-key set, and four typed
refusals: `network_origin_invalid`, `network_origin_count`,
`network_origin_duplicate`, plus the ordinary `descriptor_missing_field` and
`descriptor_field_type` for a missing or mistyped block.

**The schema is now read before any field rule of this build is applied.**
That ordering is the whole of "a future schema must not be interpreted
through this build's field rules": a schema-3 descriptor carrying a schema-3
key is refused as an unsupported *schema*, never as an unknown field.

**A schema-1 descriptor reads as `[]` by leaving `Default(TPWebCliProject)`
alone** — the absence of a branch rather than a branch — and gets the digest
of the empty set, because "no origins" is a set. `network` in a schema-1
descriptor is an unknown field. `pweb create` emits schema 2 with
`"origins": []`.

**The origin grammar lives once**, in `pweb.rpc.fetch.pas`, and the CLI calls
it. The descriptor reader, `pweb doctor`, the release-build refusal and the
running decorator therefore cannot disagree about what an origin is.

## CAPABILITY WIRING

`pweb.fetch` → `network.fetch`, mapped by the host's policy configuration and
by nothing in the decorator: CAP-8A's policy already ran at the scheduler.

The door is installed **iff** origins were declared, and that is a property of
the **compiled unit set**: `pweb build` and `pweb dev` push `-dPWEB_NET` and
generate `<output>/<target>/gen/app.network.inc` only for a non-empty set.
A project with `[]` does not compile `pweb.rpc.fetch` at all. Measured:
`nonet_links_fetch_decorator = false`, `nonet_links_mormot_net_client =
false`.

Three policy legs drive the **real** `TPWebCapabilityPolicy` and the **real**
scheduler, because the CAP-8A corpus is frozen by this shard's own acceptance
and that freeze must not become a coverage hole: granted → allowed with one
transport entry; revoked at runtime → `forbidden` with **zero**; absent from
`AppMaximum` → `forbidden` with zero, and the builder refuses to *construct*
a host that maps the method outside its ceiling at all.

## REQUEST AND RESPONSE

276 assertions, four cases, identical on Windows and Linux, all through the
injected transport with the **transport entry count asserted on every
refusal** — so a check that reached a socket would fail rather than pass
quietly. The corpus digest is
`dc3846477be5cb3b510facc7b717d928d5b7dc4957e4cbbfd90d8acf48e1e384`, 141
lines, byte-identical on both targets.

The six rows §4 marked "specified beyond the instrument" are covered
explicitly: `PATCH` accepted; `patch` refused (the comparison is
case-sensitive); `if-match` and a generic `x-` header accepted and an
unlisted one refused; the response allowlist with `location` present and
`set-cookie` absent; and the deadline carried to the transport with the
cancellation token.

## DARWIN TRANSPORT

`NSURLSession`, on a private serial delegate queue so the calling worker
needs no run loop; the redirect refused with `completionHandler(nil)`; the
bound enforced on `expectedContentLength` and again on the running total; the
jar removed by name (`HTTPCookieStorage = nil`, `HTTPShouldSetCookies = NO`,
accept policy `Never`) rather than merely made ephemeral; `URLCache` and
`URLCredentialStorage` nil; `connectionProxyDictionary` an empty dictionary;
and **no `didReceiveChallenge:` implementation anywhere in the file**, which
is the strongest form of "TLS validation cannot be turned off by any input at
any layer": there is no code path to reach.

`test/cap15b/darwinprobe.pas` measures all seven rows on a spawned worker
thread. **It has not run** — see KNOWN LIMITATIONS.

## DOCTOR

| row | severity | applies | measured |
|---|---|---|---|
| `project.network_origins` | required | schema ≥ 2 | `ok`, `ok_empty`, or a **warning** naming a declared loopback origin as development-only |
| `platform.tls` | required | origins non-empty | `schannel`; `openssl 3.0.13` (measured through the loader, not a file on a path); `nsurlsession` |

`doctor` still opens no socket, resolves no name and writes no byte: the
Linux row is a `dlopen` of the same two sonames the shipped transport loads,
released immediately — the technique the WebKitGTK row already uses.

## BUILD PROOFS

Measured on both targets, over **two real compiled images** built from the
same witness source:

| row | windows | linux |
|---|---|---|
| `csp_in_release_image` / `_dev_` / `_nonet_` | true / true / true | true / true / true |
| `navigation_csp_connect_src` | `connect-src 'self'` | `connect-src 'self'` |
| `allowlist_digest_declared_equals_compiled` | true | true |
| `release_relaxation_literals` | 0 | 0 |
| `dev_relaxation_literals` | **1** | **1** |
| `relaxation_sweep_discriminates` | true | true |
| `mormot_net_client_files` | 1 | 1 |
| `nonet_links_mormot_net_client` | false | false |

The digest row is closed end to end: the descriptor reader computes it, the
generated include carries it, and the **running image recomputes it from the
array it actually carries**. All three agree.

**Rider 1 is honoured.** The relaxation sweep runs twice — once over a release
image, which must be clean, and once over a development image that carries
the loopback origin by design, which must **fire**. Both results are pinned
absolutely in the aggregator.

The bundler refuses a root-level JSON document carrying `network`, `origins`,
`connect` or `csp` with its own cause `network_field_in_bundle`, and accepts
`data/config.json` carrying the same key name — nested application data is
data, not a manifest.

## DEV TRUST

`test/cap10a/check_dev_trust.ps1` gains section 6. Its section 1 is unchanged
and is now load-bearing for a second reason: it is the mechanical proof that
door B was not taken. The CSP and the native door are pinned **apart**.

## SDKS AND TEMPLATES

`@pweb/runtime` gains `src/http.ts` — `httpFetch`, one `invoke`, no URL
construction, no default origin, no retry, no redirect handling, no header
defaulting, no timeout policy. `sdk/pas2js/pweb.native.pas` gains the twin
`PWebFetch`. Both templates' `program.lpr` and `app.services.pas` gain a
`{$ifdef PWEB_NET}` region, and `test/cap15b/nethost.pas` is cross-checked
against them so the image proofs cannot drift from what a generated host
compiles.

## AMENDMENTS

Every one was brought back as a Checkpoint-1 finding and approved before any
code was written.

| § | old → new | what forced it |
|---|---|---|
| §2 | 262 → **267** bytes | `https://` (8) + 253 + `:65535` (6) = 267. 262 was the colon without its digits, and would have refused the case the parenthesis says must fit |
| §5 | unspecified → **768 KiB** base64 | 786432 × 4 ÷ 3 = 1048576 exactly, so both inline caps produce the same maximum envelope |
| §7.3 | substring sweep → **origin sweep + positive presence + a firing twin** | MEASURED: a PWeb-shaped image already carries `127.0.0.1` ×3 today, and the door's own library adds `http://`, `http://unix:` and `localhost`. The ratified sweep would have gone red for a reason unrelated to the door |
| §7.3 | `IgnoreTlsCertificateErrors` → `IgnoreCertificateErrors`, `IgnoreTlsCertError`, `aIgnoreTlsCertificateErrors` | the ratified spelling exists in mORMot only as that last parameter name, and counts zero in any binary: the row could not have failed |
| §8 | "inside a `{$ifdef PWEB_DEV}`" → **no such region at all**, hosts named only by the grammar, no full loopback origin literal, and the image proof beside it | there is no development branch in the door and there should not be; the grammar must name the hosts because it is what accepts them |

Additional rules stated where §4 was silent, all recorded: URL ≤ 2048 bytes
and ASCII-only; userinfo and a fragment refused; header values ≤ 4096 bytes;
a repeated header name refused; an absent `method` defaults to `GET`; a
`timeoutMs` over the maximum is refused rather than clamped; a body on a
bodyless method is refused.

## SUPERSESSIONS

| digest | old → new |
|---|---|
| `doctor_schema_digest` | `3c597c8e…18eb493a` → `de66b8bf…79f57c0fb7` (16 rows → 18) |
| `doctor_checks` | 16 → 18 |
| `cli_digest` | moves: the CAP-10A corpus gains the schema-2 rows and `schema-2` becomes `schema-3` |
| `generated_inventory_digest`, `pas2js_generated_inventory_digest` | move: `pweb.json`, `program.lpr` and `app.services.pas` all changed |
| the template pack sha256, `template_semantic_digest`, `public_semantic_digest` | move: the pack is regenerated from changed sources |
| `sdk_ship_table_digest`, `sdk_inventory_digest` | move: the TypeScript package gained a file |
| `ci_sequence_digest` | `e0d2e3f2…` (204) → measured on the CAP-15B hosted run (205) |
| `navigation_policy_digest` `360d69f2…`, `capability_policy_digest` `23b87da5…` | **must not move**, and are re-measured rather than assumed |
| `pipeline_digest` | **must not move** for an empty-origins project, by the `-d`/`-Fi`-iff design |

## REGRESSIONS (local)

`check_dev_trust` PASS · CAP-5 and CAP-6 zero-network sweeps PASS · CAP-11A
structure PASS (205 steps) · backlog gate PASS (389 entries, 0 orphans, 54
open) · CAP-10A suite 363/364 (the one failure is the unbuilt probe-child
fixture, unrelated) · CAP-15B contracts and gates PASS on Windows and Linux.

## FREEZE

`PWEB_NATIVE_CSP`; the names `pweb.fetch`, `network.fetch`,
`network.origins`, `PWEB_NET`, `app.network.inc`, `project.network_origins`,
`platform.tls`; the injected-transport shape; the four CAP-15A rulings.

## KNOWN LIMITATIONS

1. **The §10 Darwin rows have not been measured** (ledger `15B-10`). No macOS
   exists on this development host; the probe is written, wired into the leg
   and gated, and the rows arrive with the first hosted run.
2. **The end-to-end row is not mechanised in this shard's own leg** (ledger
   `15B-12`): a generated React and a generated Pas2JS project, created by
   the real CLI at schema 2, built and run, calling a real origin. Every
   *claim* it would make is covered by a narrower four-target proof; the
   **composition** is not, and its natural home is the existing CAP-10B2 /
   CAP-10C3 generated-project legs with an origin declared.
3. `15B-11`: the Darwin proxy row can only say `no system proxy configured on
   the runner`.
4. The public-TLS row is **recorded and never gates** — a real certificate
   chain cannot come from a local server, because TLS validation is not
   disableable anywhere in this product.

## A NOTE ON THIS DOCUMENT'S SIZE

The repository's documentation-budget hook flags this artifact and
`cap15b-checkpoint1.md` against a 20 KB "story" threshold. Both are kept
whole, deliberately: they are **records** rather than stories — a closure
artifact is what a future shard reads to learn what was frozen, and a
checkpoint record is only useful beside the measurements that justify its
findings. Splitting either would scatter a finding from its evidence. The
override is written here rather than taken silently, because a flagged hook
that nobody wrote a decision against reads as an ignored gate.

## VERDICT

```
CAP-15B NOT READY
```

Not because something is known to be wrong: everything mechanised is green on
both reachable targets, and the four measured defects CAP-15A found in its own
transport are each answered by a named mechanism and a number
(retry 1 hit; deadline 800 asked / 808–812 observed against 1609; bound
8454144 and 262144 bytes against 32 MiB; proxy consulted by construction).
It is NOT READY because PASS requires hosted CI green on the final HEAD with
the seven Darwin rows present, and neither has happened yet.
