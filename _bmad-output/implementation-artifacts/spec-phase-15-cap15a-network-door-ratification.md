---
title: 'CAP-15A — ratify the native network door and its CAP-15B contract'
type: 'chore'
created: '2026-09-09'
status: 'done'
baseline_commit: '50bac334e3ae831e0b0037ae129688af794bfab8'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-15A measured both candidate outbound-network doors and produced a
decision artifact, a measurements artifact and the `test/cap15a` instrument, all
untracked. The decision is now ratified — **option A, native `pweb.fetch`** — with four
rulings that change the CAP-15B contract, and none of it is in the repository.

**Approach:** Commit CAP-15A as a **decision shard**: fold the four rulings into the
artifact's CAP-15B contract, record the decision in `docs/cli-contract.md` §5 with door
B's three reopening conditions, append the ledger entries with a disposition row
each so the backlog gate stays green, and keep `test/cap15a` as a fixture that no CI leg
runs. **No production file changes.**

## Boundaries & Constraints

**Always:** `PWEB_NATIVE_CSP` is untouched — `connect-src 'self'`, byte for byte. The
ledger is append-only and every appended entry gets exactly one `dispositions.tsv` row,
keyed `15A-<ordinal>` in the artifact's own ledger order with the eight-hex SHA-256 of
its `summary` line. `docs/backlog.md` carries every new open row and states the counts
its table measures. Every path is staged by name.

**Ask First:** moving `PWEB_NATIVE_CSP`, any `src/**` or `tools/**` change, or beginning
CAP-15B.

**Never:** begin CAP-15B — no `pweb.rpc.fetch*` unit, no schema-2 reader, no doctor row,
no gate extension. Never wire `test/cap15a` into CI: it builds a widened-CSP binary.
Never commit `.claude/settings.json` or anything under `build/`. Never edit or re-word an
existing ledger entry.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| backlog gate, after the append | 376 ledger entries, 376 TSV rows | `PASS`, 0 orphans, the new open count | n/a |
| a `15A-*` entry appended with no TSV row | ledger only | `LEDGER ORPHAN: 15A-n` | gate exits nonzero |
| the new source spec is unmapped | `$shards` lacks the CAP-15A spec | `UNMAPPED SOURCE SPEC` | gate exits nonzero |
| `docs/backlog.md` counts not updated | table still says `ROADMAP 41` | `does not state the measured ROADMAP count` | gate exits nonzero |
| dev-trust gate, after the §5 edit | CSP constant unchanged | `PASS`; the four required phrases still present | gate exits nonzero |

</frozen-after-approval>

## Code Map

- `_bmad-output/implementation-artifacts/cap15a-decision-artifact.md` -- untracked; carries
  the decision, threat model, the CAP-15B contract (§1–§10) and its LEDGER table.
  §2 currently refuses `http://` outright; §10 leaves Darwin TLS open with three options;
  the Coverage table and VERDICT still read "awaiting ratification". These are what the
  four rulings move.
- `_bmad-output/implementation-artifacts/cap15a-measurements.md` -- untracked; every measured
  row. Committed as-is.
- `test/cap15a/` -- untracked instrument (8 files). `run_cap15a.sh:144` opens with a bare
  `rm -rf -- "${unitdir}" "${outdir}"`, which ledger `7M0-6` closed everywhere else via
  `tools/pwebrmtree.sh` (sourced, `pweb_rm_tree <target> <allowed-root>`).
- `docs/cli-contract.md:497` -- §5 "The development-trust decision". Its
  `ws://127.0.0.1:<native-selected-port>` paragraph is the exact precedent for ruling 2:
  ratified, dev-only, pinned absent from production. The network decision joins it here.
- `test/backlog/check_backlog.ps1:70-110` -- `$shards`, the source-spec to shard-code map; an
  unmapped spec is a refusal. `:150` keys `<shard>-<ordinal>` and digests the `summary`
  line. `:295-320` requires each open row in `docs/backlog.md` and the five counts.
- `test/backlog/dispositions.tsv` -- 361 rows today, six tab-separated columns
  `key digest verdict owner commit reason`; owner at least 4 chars, reason at least 12,
  commit `-` for everything but `FIX_NOW`.
- `docs/backlog.md:4-13,394-397` -- prose totals (stale at 351/47 since CAP-14B), the five
  count rows at `:19-23`, and the open-work table at the tail.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- append-only ledger; entry shape is
  `- source_spec:` / `  summary:` / `  evidence:`.
- `src/security/pweb.navigation.policy.pas:120-137` -- read-only evidence for ruling 4: the
  `PWEB_NATIVE_CSP` comment records ratification R-B, `'self'` blocking every external
  connection on **all four** targets.
- `tools/pweb/pweb.cli.toolchain.pas:263` -- `PWEB_CLI_DEV_DEFINE = 'PWEB_DEV'`, the C2 dev
  define ruling 2 names.

## Tasks & Acceptance

**Execution:**
- [x] `_bmad-output/implementation-artifacts/cap15a-decision-artifact.md` -- fold the four rulings
      into the CAP-15B contract and close the verdict -- the artifact is the contract CAP-15B
      builds from, so a ruling that is not in it is not ratified.
- [x] `test/cap15a/run_cap15a.sh` -- route the tree delete through `tools/pwebrmtree.sh` --
      `7M0-6` is a re-measured closure; a kept fixture must not reintroduce the shape.
- [x] `docs/cli-contract.md` -- add the outbound-network decision to §5 with door B's three
      reopening conditions -- a decision only an artifact records is not a public contract.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- append the `15A-*` entries
      in the artifact's ledger order -- so `15A-n` means the same row in both documents.
- [x] `test/backlog/check_backlog.ps1` -- map the CAP-15A spec to shard code `15A` -- an
      unmapped spec is a refusal, not a skip.
- [x] `test/backlog/dispositions.tsv` -- add one row per entry with computed digests -- one entry,
      one verdict.
- [x] `docs/backlog.md` -- update the five counts, the prose totals and the open-work table --
      the document is the half a human reads.
- [x] `docs/index.md` -- extend the `cli-contract.md` row to name the network decision.

**Acceptance Criteria:**
- Given the amended artifact, when §2, §3, §8 and §10 are read, then loopback `http` is
  permitted only under `PWEB_DEV` and pinned absent from release, schema-1 projects read as
  `[]`, and Darwin TLS is decided as `NSURLSession` behind the injected seam.
- Given `git diff --stat` on the commit, when the paths are listed, then no file under
  `src/`, `tools/` or `examples/` appears and `.claude/settings.json` is absent.
- Given a hosted run of the tree, when the backlog and dev-trust gates execute, then both
  pass with the CSP constant unchanged.

## Spec Change Log

- **Triggering findings:** the three review layers agreed on two counting errors
  and raised two verification gaps. (a) The artifact's LEDGER stopped at
  `15A-12` while thirteen entries had been appended, breaking this spec's own
  frozen rule that keys run "in the artifact's own ledger order". (b) The I/O
  matrix and Verification block said 373 entries, an arithmetic slip from before
  the fixture-fix entry existed. (c) `15A-13` was dispositioned `CLOSED` for a
  fix **no gate re-measures**, in a repository whose gate header argues that a
  recorded fix without a failing test is a document rather than a gate. (d) The
  instrument is compiled by nothing, so reopening condition 1's public cost
  estimate — "one run per macOS architecture" — silently becomes "repair the
  instrument first" the moment a CAP-15B commit reformats the CSP constant both
  runners substitute.
- **Amended:** the counts are now read from the gate rather than typed. The
  artifact's LEDGER gained `15A-13`, `15A-14` and `15A-15` so the two ledgers
  agree ordinal for ordinal. `check_backlog.ps1` gained section 5b — five
  text-only assertions keyed to `15A`, beside the section that already
  re-measures the four `FIX_NOW` closures — and the self-test grew from fourteen
  perturbations to nineteen.
- **Known-bad state avoided:** a ratification whose own bookkeeping rule is
  broken by its own commit; and two claims (`15A-12`'s "never a CI step" and
  `15A-13`'s closure) asserted in four documents apiece with nothing able to
  fail on them.
- **KEEP:** section 5b must stay **text-only** — no compile, no run, no
  toolchain. `15A-12`'s ratified reason for keeping the instrument out of CI is
  that a *run* compiles a binary with a widened `connect-src`; assertions that
  only read files are compatible with that ruling and anything that builds is
  not. Keep `7M0-6`'s `$rmProtected` list untouched: widening a ratified
  closure's claim is a rewording, not a pin. Keep the instrument's measurement
  semantics frozen — the seven bounds found by reviewing it were recorded in
  `cap15a-measurements.md` and deliberately not fixed in code, because the code
  is what produced the numbers; only I/O robustness changed.

## Design Notes

The four rulings, and where each lands in the artifact:

1. **schema 2** — `network.origins` required, MAY be `[]`; `[]` means the decorator is not
   installed and `network.fetch` is never granted; schema-1 projects stay valid and read as
   `[]`; `pweb create` emits schema 2. Lands in §2 and §3.
2. **loopback `http`** — permitted in the DEV host only, under `PWEB_DEV`, pinned absent from
   the release binary. Production is `https` only, no wildcards, at most 8 origins. Lands in
   the §2 grammar, the §7 build proofs and the §8 `check_dev_trust` rows.
3. **Darwin TLS** — `NSURLSession` behind the injected seam, in the adapter layer, system
   trust store, measured at 15B's Checkpoint 1. Bundling OpenSSL and scoping macOS out are
   both refused. §10 becomes a decision, and ledger `15A-8` follows it.
4. **macOS is not a baseline gap** — CAP-8B proved `'self'` refuses every external connection
   on all four targets (R-B). The 15A gap is door B's alone, and door B is refused. Lands in
   Coverage and in ledger `15A-2`.

## Verification

**Commands:**
- `pwsh test/backlog/check_backlog.ps1` -- expected: `PASS`, 376 entries, 0 orphans, 0 reworded
- `pwsh test/backlog/check_backlog_selftest.ps1` -- expected: all nineteen perturbations refused, tree restored
- `pwsh test/cap10a/check_dev_trust.ps1` -- expected: `PASS`, production CSP unchanged
- `bash -n test/cap15a/run_cap15a.sh` -- expected: no syntax error after the delete rewrite
- `git diff --cached --name-only` -- expected: no `src/`, `tools/`, `examples/` or `.claude/` path

## Suggested Review Order

**The decision, and where it becomes public**

- Start here: the ratified verdict and the five reasons, in weight order.
  [`cap15a-decision-artifact.md:180`](cap15a-decision-artifact.md#L180)

- The same decision as a public contract, with door B's three reopening conditions.
  [`cli-contract.md:597`](../../docs/cli-contract.md#L597)

**The four rulings, folded into the CAP-15B contract**

- Loopback `http` as a dev-only exception, shaped on CAP-10A's HMR allowance.
  [`cap15a-decision-artifact.md:314`](cap15a-decision-artifact.md#L314)

- Darwin TLS decided: `NSURLSession` behind the injected seam, both alternatives refused.
  [`cap15a-decision-artifact.md:488`](cap15a-decision-artifact.md#L488)

**What the review changed, and why it is a gate rather than a note**

- Five text-only assertions: the delete guards, "never a CI step", the shim needle.
  [`check_backlog.ps1:442`](../../test/backlog/check_backlog.ps1#L442)

- Five perturbations that must be refused; a closure nothing can fail on is a document.
  [`check_backlog_selftest.ps1:197`](../../test/backlog/check_backlog_selftest.ps1#L197)

**The instrument, hardened without moving what it measures**

- Empty array expansion under `set -u`: bash 3.2 is what macOS ships.
  [`run_cap15a.sh:186`](../../test/cap15a/run_cap15a.sh#L186)

- The wire log is the witness, so it drains before the process leaves.
  [`probe_server.js:349`](../../test/cap15a/probe_server.js#L349)

- The guarded delete, POSIX half and Windows half.
  [`run_cap15a.sh:35`](../../test/cap15a/run_cap15a.sh#L35)
  [`run_cap15a.ps1:51`](../../test/cap15a/run_cap15a.ps1#L51)

**Bookkeeping**

- Seven bounds on what the numbers mean, recorded rather than repaired.
  [`cap15a-measurements.md:283`](cap15a-measurements.md#L283)

- Fifteen ledger rows, and the artifact table they must agree with ordinal for ordinal.
  [`cap15a-decision-artifact.md:530`](cap15a-decision-artifact.md#L530)
  [`dispositions.tsv:363`](../../test/backlog/dispositions.tsv#L363)

- Nine new open rows in the half a human reads.
  [`backlog.md:450`](../../docs/backlog.md#L450)
