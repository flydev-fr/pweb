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

## COMPOSITION

Every other proof in this shard is narrower than the thing a user does on day
one, and each of them is right: the descriptor reader through the production
functions, the compiled unit set of two real images, the allowlist digest
recomputed from a compiled array, the whole request contract through the
injected transport. None of them compiles a *scaffolded* project.

`test/cap15b/prove_cap15b_composition.sh` does, **once, on the Linux leg**:

```
pweb create demo --ui react   →  schema 2, "origins": []
declare https://example.com   →  one line of pweb.json, edited as a developer edits it
pweb build                    →  release layout, app.pwb, gen/app.network.inc
pweb run                      →  the page calls that origin through @pweb/runtime
```

Measured, `linux-x86_64`:

| row | value |
|---|---|
| `composition_create_schema` / `_origins_empty` | `2` / `true` |
| `composition_build` / `composition_include` | `PASS` / `present` |
| `composition_region` | `compiled` |
| `composition_digest_declared` = `_compiled` = `_recomputed` | `65cdccbc…` |
| `composition_rpc_ok` / `composition_rpc_result` | `true` / **42** |
| `composition_fetch` / `composition_fetch_status` | `rendered` / **200** |
| `composition_payload` | `rendered` |
| `composition_listener_samples` / `_members` | 47 / **0** |
| `composition_run_exit` | 0 |
| `composition` | **PASS** |

It is **Linux-only on purpose** and the other three targets emit
`not_applicable`, which is a *value*: the aggregator requires all seven rows
on every target, requires Linux to carry the measurements, and requires the
other three to carry the literal `not_applicable` — a target that quietly
started emitting a real value would be running an unratified leg, and a Linux
leg that quietly started emitting `not_applicable` would be a composition
that stopped running and still read green. `composition_listener_members` is
pinned absolutely at `0` on all four.

The payload row is **recorded, never gated**: rendering a real body from a
release build needs a reachable `https` origin with a valid chain, and a gate
that depends on somebody else's DNS goes red for their reasons. Reaching the
*door* is the claim — `rendered` or `service_error`, never `forbidden` (the
capability was not granted) and never `invalid_request` (the origin did not
match the compiled allowlist).

**It found a defect on its first run** that nothing else could have found:
`pweb create` verifies what it wrote by re-reading it, and compared the parsed
schema against `PWEB_CLI_SCHEMA` (1) instead of `PWEB_CLI_SCHEMA_CREATE` (2),
so every scaffold died with `descriptor_mismatch:schema` the moment create
started emitting schema 2. Ledger `15B-14`.

## THE ALWAYS-FALSE CONDITIONAL

`test/cap7f/check_divergence.ps1` *counts* platform conditionals against a
ratified allowlist. It cannot evaluate them — a count is the same whether the
symbol is ever defined or not. This shard shipped the missing half, because
this shard produced an instance of the defect: `pweb.rpc.fetch.mormot.pas`
first guarded its POSIX TLS import with `{$ifdef OSPOSIX}`, a **mORMot**
symbol defined only by `mormot.defines.inc`, which no unit under `src/`
includes. The unit compiled cleanly, linked no TLS layer, and every `https`
request died at the handshake. No compiler says anything: a dead region is
silence, not a warning.

The two namespaces are disjoint, so the rule is mechanical — `OSPOSIX`,
`OSWINDOWS`, `OSDARWIN`, `OSLINUX` are mORMot's; `UNIX`, `LINUX`, `DARWIN`,
`WINDOWS`, `MSWINDOWS` are FPC's own:

> A Pascal file that does not include `mormot.defines.inc` may not test a
> symbol that only `mormot.defines.inc` defines.

`test/cap7f/check_mormot_defines.ps1` derives the symbol set **from the pin**
(206 defines, so a mORMot repin widens the gate by itself), excludes the four
`CPU*` members FPC also predefines with a measured reason recorded for each,
and sweeps `src/`, `tools/`, `examples/` and both templates in both directive
spellings. Checkout-only; it runs in `ci.yml` beside the divergence sweep.

**The count asked for: the fetch transport was NOT the only one.** Four
further live dead regions were found, and each one is a ledger row rather than
a footnote:

| file | the region | why it was harmless — and would not have stayed so |
|---|---|---|
| `tools/pweb/pweb.pas` | `{$ifdef OSWINDOWS} {$apptype console} {$endif}` | console is FPC's default apptype, so four programs were *relying on a default while their source claimed to select it* |
| `tools/pweb/pwebsdk.pas` | same | same |
| `tools/pweb/pwebtemplates.pas` | same | same |
| `tools/templates/fixture/src/program.lpr` | same | same, in a file `pweb create` copies into somebody else's project |

All four now test FPC's `WINDOWS`. Final sweep:
`MORMOT_DEFINES_PASS derived=206 scanned=93 exempt=14 hits=0`. Ledger
`15B-13`.

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
| the CAP-7F evidence schema | 836 → **843** fields in all three lists (`emit_evidence.ps1`, `emit_evidence.sh`, the aggregator's `$required`), the seven `composition_*` rows |
| the backlog census | 389 entries / 54 open → **398** / **54**: `15B-12` closes, `15B-13` to `15B-21` are new |
| `cli_digest` | `4aa3c03b…c198f9ec` → **`095c95b2…75eb6f67`**, pinned in `test/cap10c1/run_cap10c1_gates.ps1` with the reason above it. Measured **identical on windows-x86_64 and linux-x86_64** before it was written down. The first time this value has moved for something other than a command becoming public: `project\|schema-2\|schema_unsupported` became `schema-3`, and eighteen `schema1-*` / `schema2-*` descriptor rows joined the corpus. 130 lines → 148 |
| the CAP-7F divergence allowlist | one row ADDED (`src/rpc/pweb.rpc.fetch.mormot.pas`, 2 directives), one RE-RATIFIED (`tools/pweb/pweb.cli.platform.pas`, 36 → 42 for the `platform.tls` probe's three bodies), and three fingerprints moved with **no count moving at all** (`pweb.pas`, `pwebtemplates.pas`, `pwebsdk.pas` — the `OSWINDOWS` → `WINDOWS` substitution). That last row is the fingerprint doing exactly what it exists for |
| the two template contracts | section 6 of `check_cap10b1_contracts.ps1` and `check_cap10b2_contracts.ps1` gains ONE named exception — the transport selection — pinned to its exact ordered directive texts, required to be present, and observed firing. Ledger `15B-15` owns removing it |
| `template_digest` (CAP-10B0 corpus) | moves: P10 pins the canonical descriptor and it is now the schema-2 document. 106 corpus lines, `2dfa9138…` |
| `docs/cli-contract.md` §2 | "schema 1" → **"schema 1 and schema 2"**, with the schema-2 document canonical, schema 1 kept beside it as still valid and reading as `[]`, and the 267-byte origin bound written in as a Checkpoint-1 amendment. The section had still said schema 2 was "ratified and not yet implemented" |
| `test/cap7f/mormot-defines.tsv` | **new, committed data**: the 206-symbol define set derived from the pin, plus the pin's sha256. The derivation is re-done and compared wherever `deps/mormot2` is present, and required on all four legs by C12 |
| the CAP-10B1 React closure, pinned in CAP-10B2 | inventory `5bcfb497…` → **`eabbc88d…`**, bytes 73176 → **76854**, count 16 unchanged: three template files grew (`program.lpr` and `app.services.pas` gain the fenced `PWEB_NET` region, `pweb.json` gains the network block at schema 2). Measured on windows-x86_64 locally and on the linux leg before being written |

## REGRESSIONS (local)

`check_dev_trust` PASS · CAP-5 and CAP-6 zero-network sweeps PASS ·
**CAP-7F divergence sweep PASS (220 platform conditionals, allowlist
re-ratified)** · `check_mormot_defines` PASS (derived 206, scanned 93,
hits 0), **in a full checkout and in a `git archive` checkout with no
`deps/` at all** · CAP-7F schema agreement PASS (843 fields, three lists,
zero asymmetry) · CAP-11A structure PASS (205 steps) and migration map PASS ·
**the twelve source contract gates PASS** — CAP-10A, 10B0, 10B1, 10B2, 10C1,
10C2, 10C3, 10D0, 10D1, 14A, 14B and 15B (now **C1–C14**) — and CAP-10D2's
own contract passes once the tree is committed, which is the one thing it
measures that a dirty working tree cannot satisfy · both CAP-10 and CAP-11
ledger gates PASS · backlog gate PASS (398 entries, 0 orphans, 54 open) and
its 19-leg negative self-test PASS.

**Both reachable chains are now exercised end to end, build and gates.** On
**windows-x86_64**: CAP-10A, 10B0, 10B1, 10C0, 10C1, 10C2, 10D0, 10D1, 10D2,
14A, 14B and 15B. Under **WSL on linux-x86_64**: CAP-10A, 10B0, 10B1, 10B2,
10C0, 10C1, 10C2, 10C3 — including both private build proofs — plus the
CAP-15B gates and the composition smoke. `cli_digest_unchanged`,
`doctor_schema_digest_unchanged`, `c0_supervision_digest_unchanged` and both
pipeline closures read true against the superseded pins on both targets.

**Three cross-cutting gates were red at the CAP-15B implementation commit
and are green here**, which is a finding of its own (ledger `15B-16`): a
shard's own scripts prove the shard, and the repository-wide sweeps prove the
repository. The divergence allowlist did not know about a new transport unit,
a doctor row that grew a platform seam, or three fingerprints the
always-false fix had moved; the two template contracts did not know that the
door needs one conditional in generated Pascal; and the CAP-10A `cli_digest`
pin did not know the parser corpus had gained eighteen descriptor rows. Every
one is checkout-only or near it. Every one would have cost a hosted run.

## HOSTED RUN 34443707568 — THREE FAILURES, THREE DEFECTS

The first hosted run of the branch went red on all four legs and the
aggregate. None of the three causes was in the door; all three were things a
shard's own scripts do not run, and each is now mechanised.

| leg | cause | fix, and the gate that would have caught it |
|---|---|---|
| macos-x64, macos-arm64 | `pweb_cocoa_bridge.h:523:53: error: '/*' within block comment [-Werror,-Wcomment]` — the banner comment wrote `exactly one file in src/** names mormot.net.client`, and `src/**` contains `/*` | reworded to `under src`; **C13** of `check_cap15b_contracts.ps1` now sweeps every `.h`/`.m`/`.mm` under `src/platform/macos` for both shapes `-Wcomment` refuses, and was **observed refusing the exact line** before the fix was kept. There is no macOS here, so a source rule is the only instrument that could have found it |
| windows, linux | the CAP-10B0 suite's `CheckEqual len a=242 b=210` — the canonical `pweb.json` is pinned byte for byte in `pweb.test.template.pas` P10 *and* in `docs/cli-contract.md` §2, and neither was updated when `create` began emitting schema 2. §2 was worse than stale: it still said schema 2 was "ratified and not yet implemented" | both carry the schema-2 document; §2 keeps schema 1 beside it as still valid and reading as `[]`, and now carries the 267-byte origin bound as a written Checkpoint-1 amendment. Ledger `15B-18` |
| cap7 aggregate | `deps/mormot2/src/mormot.defines.inc is absent` — the always-false sweep derives its symbol set from the pin, and the job it correctly lives in checks out the repository and fetches nothing | **a checkout-only gate that needs a dependency is not one.** The derived set is committed as `test/cap7f/mormot-defines.tsv` (206 symbols + the pin's sha256); the sweep still re-derives and refuses a mismatch **wherever the pin is present**, and **C12** requires that corroboration on all four legs — so a repin that moves the set turns four legs red rather than passing. Both paths proven locally: green in a `git archive` checkout with no `deps/` at all, and the stale-list refusal observed firing |

The pattern is the one ledger `15B-16` already named, met again: a shard's own
gates prove the shard. What this run adds is that **the dev host's blind spots
are a class too** — no macOS, and no hosted-job environment — and the answer to
both is the same as for the always-false conditional: a source rule that runs
where the code is, not where the compiler is.

## HOSTED RUN 34452631822 — TWO MORE, AND WHAT THEY HAVE IN COMMON

| leg | cause | fix |
|---|---|---|
| macos-x64, macos-arm64 | **CAP-7M0 gate M20** sweeps `pweb_cocoa_bridge.h` for `mormot\.net\.(server|client|http)` — and this shard's banner comment in that file explained that *"exactly one file under src names `mormot.net.client`"*. The sentence was true, and writing it there made it false | reworded to name no unit. **C14** now runs M20's SOURCE half on every target, **derived from the script** — the file list, the exempt list and the forbidden pattern are parsed out of `check_cap7m_nonetwork.sh` itself, so a copy cannot rot — and it was **observed refusing line 524 by name** |
| linux | **CAP-10B2** holds the CAP-10B1 closure's React inventory as a **literal** (`$CAP10B1_REACT_INVENTORY_DIGEST`, `_TOTAL_BYTES`) while CAP-10B1's own gate records it as a **row**. A row moves with the thing it measures; a literal must be moved by hand. Three template files grew, so `5bcfb497…` → `eabbc88d…` and 73176 → 76854 bytes (16 files, unchanged) | both superseded with the arithmetic written above them, **measured on two targets first** — the local windows record and the linux leg that went red |

**What the three runs have in common is a shape, not a bug.** Every failure so
far has been a *claim held somewhere the shard's own scripts do not run*: an
allowlist, a literal pin, a byte-for-byte document, a comment inside a swept
file. And in two cases the local check that should have caught it was
structurally incapable of doing so — M20 aborts on a non-Mac before its
platform-independent half, and the aggregate job carries no `deps/`. Both are
now mirrored where they can actually run.

**The Linux and Windows chains are now exercised end to end here.** On Windows:
CAP-10A, 10B0, 10B1, 10C0, 10C1, 10C2, 10D0, 10D1, 10D2, 14A, 14B — build and
gates, all green. Under WSL: CAP-10A, 10B0, 10B1, **10B2**, 10C0, 10C1, 10C2,
**10C3** — including both private build proofs — all green. What remains
unreachable from this host is macOS, and that is the same limitation the seven
Darwin rows are conditioned on.

## FREEZE

`PWEB_NATIVE_CSP`; the names `pweb.fetch`, `network.fetch`,
`network.origins`, `PWEB_NET`, `app.network.inc`, `project.network_origins`,
`platform.tls`; the injected-transport shape; the four CAP-15A rulings.

## KNOWN LIMITATIONS

1. **The §10 Darwin rows have not been measured** (ledger `15B-10`). No macOS
   exists on this development host; the probe is written, wired into the leg
   and gated, and the rows arrive with the first hosted run. Nothing stands
   in for them and the shard's PASS is conditioned on them.
2. `15B-11`: the Darwin proxy row can only say `no system proxy configured on
   the runner`. It is worded as what was measured, on what.
3. The public-TLS row is **recorded and never gates** — a real certificate
   chain cannot come from a local server, because TLS validation is not
   disableable anywhere in this product. The same reasoning makes
   `composition_payload` a recorded row.
4. The composition runs the **React** frontend on **linux-x86_64** only, by
   the decision that scoped it: breadth already runs on four targets and a
   fifth copy of the composition would buy four `npm install`s. The pas2js
   twin is a copy of the same path, not a different claim. Ledger `15B-12` is
   closed on that basis rather than left open as a coverage hole.
5. **A generated program now carries exactly one platform conditional**
   (ledger `15B-15`): the transport selection in the `uses` clause of
   `program.lpr`, inside the `{$ifdef PWEB_NET}` region. It selects a unit
   NAME and decides nothing else. Moving it into the framework means putting
   a macOS unit on every target's unit path, which re-measures the pipeline
   digest, the SDK ship table and both generated inventories — a shard, not
   a paragraph. Until then it is pinned to its exact directive texts in both
   template contract gates, required to be present, and both pins were
   observed firing.

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
