---
title: 'CAP-15B — implement the native network door ratified by CAP-15A'
type: 'feature'
created: '2026-09-10'
status: 'in-review'
baseline_commit: 'aa7cc209f0fdbb6b151d3d0a42357c5036093e66'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-15A measured both candidate outbound-network doors, ratified
**option A — native `pweb.fetch`** — and wrote the CAP-15B contract as §1–§10 of
`cap15a-decision-artifact.md`. Nothing of it exists in the product: no
`pweb.fetch`, no schema 2, no `doctor` network row, no build proof.

**Approach:** Implement §1–§10 exactly. Two RPC units split so the transport is
**injected** (mORMot on Windows and Linux, `NSURLSession` on Darwin); schema 2
in the CLI reader with the §2 grammar and bounds; the capability wiring of §3
in both generated templates, fenced by a compile-time region so a project that
declared no origins does not compile the door at all; the doctor rows of §6;
the build proofs of §7 over a real built image; the `check_dev_trust`
extension of §8; the bundler refusal of §7.4; both frontend SDKs; `pweb
create` emitting schema 2; the tests, the corpus fields and the CI leg.

`PWEB_NATIVE_CSP` does not move. That is the shard's strongest claim and it is
measured on every leg rather than asserted.

## Boundaries & Constraints

**Always:** the CSP and the privileged origin are untouched; the capability
policy runs before the bridge and this shard adds no second authorization; the
nine-code taxonomy and protocol v1 are unchanged; `pweb.rpc.command.pas` is not
touched; the CAP-8A capability corpus gains nothing, so
`capability_policy_digest` and `navigation_policy_digest` are re-measured
unchanged.

**Never:** a frontend byte that names an origin, relaxes a policy or selects a
mode; a second RPC path, an eighth interface, a scheduler hook or a listening
socket; sockets, streaming or blobs; a followed redirect, a kept cookie, a
retry, an inherited proxy; any input at any layer that can disable TLS
validation.

## Acceptance (Given/When/Then)

1. **Given** a schema-1 project, **when** it is read and rebuilt, **then** its
   origin set is `[]`, no network region is compiled, and neither
   `pweb.rpc.fetch` nor `mormot.net.client` is on its compiled unit set.
2. **Given** a schema-2 project declaring `https` origins, **when** it is
   built, **then** the compiled allowlist digest — recomputed by the host from
   the array it carries — equals the digest computed from `pweb.json`, and the
   image carries no loopback origin, no wildcard and no TLS-relaxation
   identifier.
3. **Given** a development image that carries the loopback origin by design,
   **when** the release relaxation sweep is run over it, **then** it FIRES —
   so the release image's clean sweep is a discriminating check rather than a
   vacuous one.
4. **Given** a schema-2 project declaring a loopback origin, **when** `pweb
   build` runs, **then** it refuses at the open stage with
   `network_origin_loopback_release` naming the origin, before any write.
5. **Given** the shipped transport and a local server, **when** a dribbling
   response meets an 800 ms deadline, **then** the exchange ends within one
   slice of the bound and the wire log shows exactly one hit — no retry, no
   followed redirect, and no `Cookie` after a `Set-Cookie`.
6. **Given** a 16 MiB response, **when** it is read, **then** it is refused at
   the bound with at most one delivery over it, both when the length is
   declared and when it is not.
7. **Given** `network.fetch` revoked at runtime, **when** `pweb.fetch` is
   invoked through the real scheduler and the real policy, **then** the answer
   is `forbidden` and the transport entry count is zero.
8. **Given** macOS, **when** the §10 probe runs on x86_64 and arm64, **then**
   all seven ratified rows are measured and recorded, with the proxy row
   worded as what was measured and on what.

</frozen-after-approval>

## Deviations from the ratified contract

Every one was brought back as a Checkpoint-1 finding and approved before any
code was written; each is recorded old → new with the measurement or the
arithmetic that forced it, in the closure artifact's AMENDMENTS section.

- §2's origin byte bound: **262 → 267**, the arithmetic its own parenthesis
  states.
- §5's base64 inline cap, unspecified: **768 KiB**, so both inline caps
  produce the same maximum envelope.
- §7.3's release-image sweep: a substring sweep for `127.0.0.1`, `localhost`
  and `http://` is **already false today** — measured — so it becomes an
  ORIGIN sweep plus a positive presence check, and it must fire on a dev image.
- §7.3's `IgnoreTlsCertificateErrors`: replaced by mORMot's real spellings,
  because the ratified one would have swept vacuously.
- §8's "every loopback occurrence lies inside a `{$ifdef PWEB_DEV}`": there is
  no such region, and the grammar must name the two hosts because it is what
  accepts them. Pinned exactly instead.
