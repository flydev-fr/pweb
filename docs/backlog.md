# The backlog

`_bmad-output/implementation-artifacts/deferred-work.md` is append-only and
carries **349 entries** from Phase 0 to CAP-14A. It is a
ledger: it records what was found, in the words of the shard that found it,
and it never edits itself. That makes it excellent evidence and a poor
worklist — a reader who wants to know *what is still owed* has to resolve
every supersession chain by hand, and three phase-closure artifacts answer
that question for CAP-10 and CAP-11 only.

This document is the worklist. Every one of the 349 entries is disposed of
exactly once, with one verdict, an owner and a reason. **Forty-seven are open,**
**and those forty-seven are listed here in full**; the other 302 are in
`test/backlog/dispositions.tsv`, which is the table this document is written
from and the one the gate reads.

| verdict | count | what it means |
|---|---:|---|
| `FIX_NOW` | 4 | closed by this triage, one commit each, cited below |
| `UPSTREAM` | 3 | the defect belongs to a third-party project and a report is written; two of the three also carry a local workaround, and `RP-2` deliberately does not |
| `ROADMAP` | 40 | real work, deferred, with a named owner |
| `ACCEPTED` | 101 | a measured limitation, a ratification or a lesson — nothing is owed, and the record *is* the deliverable |
| `CLOSED` | 201 | the thing the entry describes is done |

`ACCEPTED` is not a synonym for ignored. It is the verdict for an entry whose
honest answer is a measurement — that WebView2 raises no navigation event for a
`javascript:` URL, that `plugins.zip` is deterministic per toolchain and not
across toolchains, that a waiver was a decision somebody took on a date. Those
entries are why the ledger is worth keeping, and they need an owner only if
somebody wants to change the answer.

---

## How an entry is keyed

`<shard>-<ordinal>` plus the first eight hex of the SHA-256 of the entry's own
`summary` line — the same key `test/cap10d2/check_cap10_ledger.ps1` and
`test/cap11b/check_cap11_ledger.ps1` already use, computed the same way, and
verified against both of their tables before this document was written: all 39
CAP-11 digests and all 165 CAP-10 digests match byte for byte. The ordinal
catches an entry added or removed; the digest catches an entry **reworded**,
because a verdict is a judgement about a specific claim and a claim that
changed needs its verdict read again rather than inherited.

The shard codes for phases 0 to 9, and for the two specs that were appended
after CAP-10 closed, are introduced here; `10A`, `B0`…`D2`, `11A` and `11B` are
the codes the existing gates already use, unchanged.

`test/backlog/check_backlog.ps1` holds `test/backlog/dispositions.tsv` — the
machine half of this document, six columns and one row per entry — to the
ledger: every entry disposed of exactly once, no stray row, no reworded claim
carrying an inherited verdict, a verdict from the closed set, an owner and a
reason on every row, and a **closing commit that exists in this repository's
history and is an ancestor of HEAD** on every `FIX_NOW`. It requires this
document to carry every open row and to state the counts its own table
measures, so the two halves cannot drift. A source spec it cannot key is a
refusal rather than a skip, so a ledger that grows a new spec cannot grow a
silently undisposed entry with it. And it re-measures the four closures below
in source, so that the one thing this triage fixed cannot quietly come undone.

`test/backlog/check_backlog_selftest.ps1` perturbs the tree fourteen ways — a
reworded entry, a missing row, a stray row, an unknown verdict, each of the
three commit rules, a reason nobody wrote, an open row dropped from this
document, a summary that disagrees with its own table, and each of the four
closures undone — requires the gate to refuse every one, and restores the tree
byte for byte. It earned its place immediately: the gate's first
`create_help_digest` check looked for the two field names anywhere in the
aggregator, where they also appear in the `$required` list, so it reported
success for a field deleted from the equality list it was guarding. Only a leg
that really deleted the line could show that.

### It runs on every hosted leg

The gate is a step of the one platform-leg sequence, `Backlog disposition -
every ledger entry has a verdict`, and it was wired in as a **declared CAP-11A
amendment** rather than slipped in: a composite action carrying the body, a row
in `test/cap11a/step-applicability.tsv`, and a row in
`test/cap11a/post-migration-amendments.tsv` recording what changed and why.

`ci_sequence_digest` moves with it, which is the point of declaring it:

| | steps | `ci_sequence_digest` |
|---|---:|---|
| before | 200 | `8b3c15bd247f0e86ad6116d1a8359fdfcb6425c4e4088c08470cd35760243a05` |
| after | 201 | `3d74864bbf0488ef282f18973bc85d45768507b4d6bad7d4cd21e80d79df351a` |

The digest is the SHA-256 of the declared step names, one per line — so it
moves for exactly one reason, a step entering the sequence, and the aggregate
compares it across four targets on every run.

Two shards have since entered the sequence the same way and moved it again, and
this row is where the arithmetic is kept honest rather than in a step number
that goes stale the moment anybody inserts anything: the mORMot repin's
Currency matrix took it to `7f7dc950…` (202), and CAP-14A's bundler CSP refusal
takes it to `412b21b257dd6945ad2bd95313d584bab67c0ef5d9cebde85cd92db9a77586d1`
(203). This gate now sits at ordinal **181**, immediately after CAP-14A's, and
`test/cap11a/step-applicability.tsv` is the record of where every step is.

**Windows only, and that is a checkout property rather than a preference.** The
gate resolves each `FIX_NOW` row's closing commit and requires it to be an
ancestor of `HEAD`, which needs the history. The `windows` leg is the one that
checks out with `fetch-depth: 0`, for the freeze diff against the Phase-0
baseline; the other three take the default shallow clone, where the gate
refuses rather than recording an unverified pass. Declaring it on four legs
would have meant three red legs stating a fact about `actions/checkout`.

The **self-test does not run in CI**, deliberately. It perturbs the working
tree and restores it in a `finally`, so a job cancelled mid-leg would leave the
tree perturbed for every step after it — and a gate added by one shard may not
raise the failure rate of a gate belonging to another (`10E-5`). It stays the
instrument a human runs before a push.

Declaring the amendment also closed a hole in the machinery that received it:
`check_migration_map.ps1` only ever *looked up* amendments by `job|name`, so a
row naming a step the migration map does not carry — which is what a step
**added** after the migration is — would have sat there being ignored, pinning
nothing. Every declared row must now answer to either a legacy step or a step
in today's sequence, and in the second case its body digest is measured against
the same stripped-body rule the legacy comparison uses.

---

## Where the verdicts came from

Two thirds of the ledger had already been judged. `cap10-closure-artifact.md`
disposes of 165 entries, `cap11-closure-artifact.md` of 39, and this document
**carries those verdicts forward rather than re-litigating them**:

- a phase closure's `RESOLVED` becomes `CLOSED`;
- a phase closure's `RECORDED-ONLY` becomes `ACCEPTED`;
- a phase closure that names a **later phase** (`CAP-11`, `CAP-12`, `CAP-13`,
  `LATER`) is re-read here, because for most of them that phase has since
  shipped.

**204 entries** carry a prior verdict and **22** of them are written out here
rather than carried forward. Of those 22:

- **18** are entries a closure sent to a later phase, which the rule above says
  to re-read. Eleven are now `CLOSED` because CAP-11 did what it was handed —
  the `ci.yml` split closed five separate budget entries at once, the bounded
  fetch closed the pinned-installer flake, the U3 drain closed the uninstall
  residue, and `LICENSE` at the repository root closed the licence question.
  Two became the `FIX_NOW` items below, four stayed on the roadmap, and one
  (`B2-16`) is a re-read that disagrees: CAP-11A instrumented the smoke
  observer and seeded the cause rule, but no fixture executes the CAP-10B1/B2
  proofs' own report parser, which is what that entry asked for.
- **2** keep their verdict and get a specific reason instead of the formula.
- **2 depart from a closure's final verdict**, and both in the same direction —
  `D2-4` and `11B-19` are `RECORDED-ONLY` in their closure and `ROADMAP` here,
  because each names work somebody is expected to do (a signature over the SDK
  manifest; a host-side flush or close-on-report) rather than a limitation
  nobody owes anything about. Nothing is re-litigated in the other direction:
  no closure's `RESOLVED` is reopened here.

The remaining **134 entries — Phase 0 through CAP-9, plus the two specs
appended after CAP-10 closed** — had no closure table at all. They are judged
here for the first time, and that is where most of this triage's work went.

---

## FIX_NOW — closed by this triage

Four items, one commit each. Three were this triage's own scope; the fourth,
`7M0-6`, was promoted from the roadmap afterwards on the owner's instruction.

### `B2-15` — the generated `.gitattributes` covers `*.cfg` · `e90cc74`

The template `.gitattributes` opens `* -text` and opts the text kinds back in by
extension. `.cfg` was not among them, so `frontend/pas2js.cfg` — which the
Pas2JS template ships as **product** — was binary in every generated project.
Nothing was broken by it, because `-text` converts nothing and the committed LF
bytes survive a Windows checkout; what the rule buys is the case the entry
named, a developer editing that file on Windows and committing CRLF into a
compiler configuration git had been told not to normalise.

The entry's second half is answered too. The same file lists `*.ts`/`*.tsx` for
a template the contract check forbids from ever containing TypeScript, and the
two copies are byte-identical by ratified design — so the honest fix is not to
remove a rule React needs but to say what the file is: one list serving both
templates, the union of the kinds either can ship.

Both templates move by **+392 bytes**, the file count does not move, and the
supersession is recorded where the pin lives: React's generated inventory
`578a3093…` → `5bcfb497…`, 72784 → 73176 bytes. Measured by rebuilding the pack
and running the gate, not computed. `check_cap10b0/b1/b2_contracts.ps1` and the
B0, B1 and B2 gates were re-run green on windows-x86_64 afterwards.

### `B1-8` — `create_help_digest` differs between Windows and POSIX · `5656508`

The entry recorded that `pweb create --help` produced one SHA-256 on Windows
and another on the three POSIX targets, that the text is a compile-time ASCII
constant, and that **nobody knew why**. It concluded, in writing and in two
places, that "the difference is in that string and not in the console seam".

That conclusion is backwards, and the measurement is cheap once it is asked
for. A probe linking the real `pweb.cli.report` and writing `PWebCliCreateHelp`
through the CLI's own `Emit` body produces **1025 bytes, 26 line feeds and one
sha256 `b5fced8d…` on windows-x86_64 and on linux-x86_64 alike** — byte
identical. The string was never the difference and neither was `Emit`.

The harness was. `Start-Process -RedirectStandardOutput` does not hand the file
to the child on Unix: it transcribes the stream a line at a time and **drops
every empty line**. The same text captured that way on Linux is 1020 bytes and
21 line feeds, and `diff` names the difference exactly — the help's five blank
lines, and nothing else. On Windows the same parameter gives the child the file
handle and the bytes arrive untouched.

The entry's own corroborating evidence turns out to say the same thing: it
noted that `create_stdout_digest`, produced through the same `Emit` path,
agreed on all four targets. It agreed because a creation report has no blank
line to lose. That was read as evidence the seam was innocent; it was evidence
the input had nothing to lose.

The capture is corrected to read the child's streams directly, and
`create_help_digest` and `create_help_bytes` go back into the four-target
equality list they were demoted from. Verified on windows-x86_64 and
linux-x86_64: identical values through the corrected path, and the real CLI on
Windows reports the same 1025 / `b5fced8d…` the probes did. **The three macOS
and Linux legs of the aggregate are the hosted run's to confirm** — that
promotion is the one part of this item not proven on four targets here.

### `8B-7` — `RepoRootFromExecutable` reduced to one test helper · `0029fc5`

The entry recorded three private copies of a repository-root walk and asked for
one shared helper; a later entry recorded a fourth. There were **nine**, and one
had already drifted: `test/cap9c2/quickjsgui.pas` walked up with
`ExpandFileName(dir + '..')`, which at a filesystem root resolves to the root
again and so has no termination condition of its own — it was held only by the
iteration bound, where the other eight stop when the parent stops moving. That
is the drift the entry predicted, in security-adjacent path resolution, arriving
exactly as described.

One unit, `test/security/pweb.test.reporoot.pas`, carrying the eight-copy
majority algorithm and the reason the ninth is not equivalent. The other seven
hosts name `-Futest/security` in both their `.ps1` and `.sh` twins.

**Where it lives is a proof rather than a preference, and the first attempt got
that wrong.** Two of the nine callers — `pweb.test.capabilities` and
`pweb.test.navigation` — live in `test/security`, so *every* compile that can
reach them already passes `-Futest/security`, and putting the helper beside
them means every such compile finds it by construction rather than by anyone
having enumerated the call sites correctly.

The first draft put it in `test/core`, on the narrower observation that the
mORMot-core suite's action passes `-Futest/core`. That was true and
insufficient. `test/rpc/cap3tests.pas` uses `pweb.test.capabilities.integration`,
which uses `pweb.test.capabilities` — and the CAP-3U action passes
`-Futest/rpc -Futest/security` and no `test/core`. Hosted run **34168635047**
died on the Windows leg at `Can't find unit pweb.test.reporoot used by
pweb.test.capabilities`, two minutes in. Reading the top of a uses clause is
not reading what it pulls in, and the fix is to make the question unnecessary
instead of answering it again.

All seven host gates and the 2,502-assertion mORMot-core suite were re-run
green on windows-x86_64, and so was the CAP-3U compile with the action's own
unit paths.

### `7M0-6` — every recursive delete names its target and its root · `b39e07c`

Promoted from `ROADMAP` after the triage, on the owner's instruction. Seven
sites across `test/cap7l/*.sh` and `tools/build-webview-so.sh` opened by
deleting a tree with a bare `rm -rf -- "${var}"`, with nothing validating the
variable first — so an empty one turned `rm -rf -- "${work}/abi"` into
`rm -rf -- /abi`. They were not wired to misfire, but that is an argument that
an accident is unlikely rather than impossible, in scripts CI runs as programs.

`tools/pwebrmtree.sh` is now the one guarded delete, and **the rule is lifted
rather than invented**: every refusal is `cap7m_rm_tree`'s, in its order — an
empty target, a missing or explicitly empty allowed root, `/`, a `..` path
*component* (matched against a slash-padded copy, so `report..old` stays a
legitimate filename), an unusable basename, a target
outside the allowed root (a literal, trailing-slashed prefix strip on `pwd -P`
output, so `/x/buildkit` can never pass as inside `/x/build`), and the root
itself. One narrowing: **the allowed root is required**, not defaulted, because
with six call sites a root every caller names beats a default every reader has
to know.

**Six sites name `build`; one names `dist`, and that is measured rather than
waived.** `run_release_layout.sh` deletes `dist/linux-x64/release`, which is
the CAP-7L release layout the release-layout gate reads back and CAP-10D1's
artifact rules point at — legitimately outside `build`, so the caller names the
root it means instead of the guard quietly widening for everyone.

`test/cap7l/check_rmtree.sh` drives all nine refusals **and all four accepts**
against a real filesystem — a guard that refused everything would pass a test
that only ever asked it to refuse — and sweeps the six scripts for a bare
delete returning. **14/14 under WSL**, with `bash -n` clean on all eight
touched scripts and `tools/build-webview-so.sh --print-plan` byte-identical to
its pinned expectation, so the sourcing changed no build decision.

What is **not** done, and why: `test/cap7m/cap7m_common.sh` and
`tools/build-webview-dylib.sh` carry the same rule twice, deliberately
duplicated by CAP-7M0 so a build tool would not depend on the test tree — which
is the gap this file closes on the `tools/` side. Retiring those two into this
one is the obvious next move and is not taken here: both are macOS-only, this
host cannot run either, and a consolidation nobody can execute before pushing
is how a green tree becomes four red legs.

---

## UPSTREAM — two reports, ready to post

Both are defects in the pinned `synopse/mORMot2` bindings, both were found by
measurement rather than by reading, and PWeb is exposed to neither: it declares
its own correctly-typed externals. Each report is a standalone file with every
PWeb-specific detail stripped, quoting only mORMot's own files.

| entry | report | subject |
|---|---|---|
| `9A-3` | [`docs/upstream/mormot-quickjs-js-setmaxstacksize-signature.md`](upstream/mormot-quickjs-js-setmaxstacksize-signature.md) | `JS_SetMaxStackSize` is declared with `JSContext` where the shipped C takes `JSRuntime *`, so the binding writes the stack bound into an unrelated field of a live object — measured as an access violation under allocation pressure |
| `9A-4` | [`docs/upstream/mormot-static-pas-malloc-size-t.md`](upstream/mormot-static-pas-malloc-size-t.md) | `pas_malloc(size: cardinal)` and `pas_malloc_usable_size(...): integer` against a C side that calls them with `size_t`, so an over-4 GiB request is silently truncated to its low 32 bits on every 64-bit target |

Neither has been submitted. Posting them is the owner's call, and the reports
are written to be posted as they stand.

---

## ROADMAP — 40 items, by owner

The full reasons are in the table; this is the shape of what is owed.

**CAP-12 owns eight.** The blob and `Range` plane brings the deferred macOS
delivery with it (`7M1-5`) and the carrier-side materialisation cap the frozen
`IAssetStore` cannot express (`9B1-6`); the cross-target comparison the CAP-11A
matrix now makes cheap finishes the ABI, fcntl and runtime facts no job compares
between architectures (`7F-3`); the evidence schema wants one declarative field
set instead of three hand-maintained lists whose required-versus-compared
distinction has already cost three red runs (`P6U-6`); the three example hosts
still compose the runtime by hand instead of through `pweb.webview.host`
(`B1-5`); a job pump would enable both the Promise-returning `pweb.invoke` and
dynamic `import()` (`9A-2`); a mORMot head watcher needs its own instrument and
its own budget (`11B-4`); and one host-side change — flush the report line, or
close the window on the first report — turns a 15-second smoke floor into a
300-millisecond run (`11B-19`).

**Pins and locks own six**, and each has a natural trigger rather than a date: a
`discovery-url` key so a WebView2 bump can find the next build (`6B4-10`), a
machine-readable ratified-versus-provisional marker (`7M1-3`), a pinned
`other_count` so an added RTTI symbol cannot pass silently (`7M1-10`), shape
assertions instead of string literals so a version bump does not read as
tampering (`7M0-5`), an `[InstallDelete]` in the fixed profile against the first
pin bump (`6B4-7`), and hash-pinning or vendoring the WebView2 SDK nuget the
upstream cmake fetches unverified (`P1-1`).

**Harness hygiene owns four**, all named and all mechanical — the fifth,
`7M0-6`'s seven unguarded recursive deletes, was promoted to `FIX_NOW` and is
closed above: the four copies of
`Invoke-Bounded` (`6B2-3`), the `set -e`-unreachable failure paths in
`prove_cap10b1.sh` (`B2-10`), the CAP-9A runner's case-sensitivity and its
unremoved `mktemp -d` (`9B1-8`), and `pwebqjspack.pas` still reading `ParamStr`
where the bundler now reads the kernel (`P6U-2`).

**Security surface owns six** and none of them is a live exposure: an opt-in
strict mode so a mistyped principal id fails loudly instead of to ceiling rights
(`8A-3`), the `security-model.md` wording the CAP-8B ratification wrote and
nobody applied (`8B-1`), a deterministic cross-engine download trigger so the
deny is measured rather than decided (`8B-8`), the hard-link case CAP-7L's
confinement algorithm does not close (`7M1-11`), the bundle loader's missing
reparse refusal where the plugin reader has one (`10E-2`), and a signature over
the SDK manifest, which needs a key nobody has ratified a home for (`D2-4`).

**The rest have their own owners**: the CI cost owner holds the uncached pas2js
fetch (`P5-1`) and the un-pinned Pascal line endings that stop half the POSIX
gates running under WSL (`10E-4`); CAP-13 holds whether a generated application
ships plugins (`9C2-3`); a macOS signing shard holds hardened runtime and
library validation (`7M1-9`); and the repository owner holds the supported-OS
floor no spec has ever ratified (`6B1-3`).

---

## Findings this triage produced

Three things turned up that are not in any entry, and are recorded here rather
than appended to an append-only ledger:

1. **`8B-7`'s three copies were nine, and one had drifted.** The entry said the
   copies "can drift independently"; between CAP-8B and the MVP one of them did,
   into a walk with no termination condition of its own. A deferral whose whole
   argument is "this will drift" is worth acting on before it does.
2. **`11A-8` cites the wrong key.** It is headed "D2-11 IS CLOSED" and closes
   the CAP-7F evidence-schema entry — but `D2-11` is the CAP-11 handoff. The
   schema entry is `P6U-5`, sourced from the bundler-argv spec, which is why the
   citation slipped. The ledger text is frozen; the disposition table has it
   right.
3. **`C1-11 (c)` was closed and never said so.** CAP-10D0 sent the SDK
   manifest's escape forms to CAP-10D2, whose handoff acknowledges inheriting
   it; `docs/sdk-contract.md` then ratified exactly the rule it asked for — a
   value decoded before it is re-encoded, so a redundant escape normalises, with
   lowercase `\u00xx` hex. No entry records the closure. This is the second
   instance of the class the MVP closure artifact already names.

---

## The open work, in full

Forty-seven rows: the four `FIX_NOW` items this triage closed, the three
`UPSTREAM` reports, and the forty on the roadmap. Everything else — 101
`ACCEPTED` and 201 `CLOSED` — is in `test/backlog/dispositions.tsv`.

| key | verdict | owner | reason |
|---|---|---|---|
| `7M0-6` | FIX_NOW · closed by `b39e07c` | this triage | the seven bare recursive deletes are gone: every removal now goes through `tools/pwebrmtree.sh`, which refuses an empty target, a missing or explicitly empty allowed root, `/`, a `..` path component, an unusable basename, a target outside the named root, and the root itself. The rule is lifted from the ratified `cap7m_rm_tree` with the allowed root made REQUIRED rather than defaulted, so no site can inherit a root its reader has to know. Six sites name `build`; `run_release_layout.sh` names `dist`, because the CAP-7L release layout is ratified at `dist/linux-x64/release` and is legitimately outside `build`. `test/cap7l/check_rmtree.sh` drives all nine refusals and all four accepts against a real filesystem and sweeps the six scripts for a bare delete returning - and requires the two ACCEPT cases too, because a guard that refused everything would pass a refusal-only test. 14/14 under WSL. One of those legs exists because the first version refused on a FRESH CHECKOUT: it resolved the target parent before asking whether there was anything to delete, and `build/cap7l` is made by the very step that removes `build/cap7l/webview-build`, so hosted run 34168635047 died with `its parent does not resolve` on a target that did not exist. The dev host had the directory from earlier runs, which is the local-harness-more-generous-than-CI shape this repository already names. An absent target is now a no-op, and a leg builds the fresh-checkout shape explicitly |
| `8B-7` | FIX_NOW · closed by `0029fc5` | this triage | `RepoRootFromExecutable` was duplicated across the CAP-8A, CAP-8B and CAP-8C hosts and had since grown a fourth copy. It is security-adjacent path resolution and the copies could drift independently; they are now one shared test helper with a contract check that keeps them one |
| `B1-8` | FIX_NOW · closed by `5656508` | this triage | `create_help_digest` differed between Windows and POSIX for a compile-time ASCII constant, and the ledger recorded that nobody knew why. The cause is now found and closed, and the field is compared across four targets again instead of being recorded per target |
| `B2-15` | FIX_NOW · closed by `e90cc74` | this triage | the generated `.gitattributes` opened `* -text` and never opted `.cfg` back in, so `frontend/pas2js.cfg` was treated as binary in every generated Pas2JS project and a Windows edit could commit CRLF into a compiler configuration. The template parity gate made it a supersession rather than a one-line change, which is why it waited |
| `9A-3` | UPSTREAM | synopse/mORMot2 | `mormot.lib.quickjs.pas` declares `JS_SetMaxStackSize(ctx: JSContext; ...)` where the pinned C takes `JSRuntime*`; calling the pinned binding was measured to corrupt the context. PWeb re-declares it correctly unit-local, so no PWeb path is affected. Report: `docs/upstream/mormot-quickjs-js-setmaxstacksize-signature.md` |
| `9A-4` | UPSTREAM | synopse/mORMot2 | `mormot.lib.static.pas` declares `pas_malloc(size: cardinal)` and `pas_malloc_usable_size(...): integer` where the pinned QuickJS C calls them with `size_t`, truncating an over-4 GiB request to its low 32 bits on 64-bit targets. Unreachable in PWeb under the per-plugin memory ceiling. Report: `docs/upstream/mormot-static-pas-malloc-size-t.md` |
| `RP-2` | UPSTREAM | synopse/mORMot2 | upstream `790154af` edits the `ABIX64` `CallMethod` block Win64 and SysV x64 SHARE, so removing the `imvCurrency` XMM0 read fixed Windows (0/5 to 5/5 over arities 0/1/2) and left Linux reading a leftover pointer out of RAX (0/5 to 1/5 — only the no-argument case is right). Hosted run 34241426338 widened it: macos-x86_64 is identical to Linux at 1/5, and macos-arm64 — a different ABI with its own CallMethod, untouched by that commit — is 0/5 with the same five values Win64 produced before it, so the result register is wrong on three ABIs and on aarch64 apparently always was. It predates the pin move and the pin move improves it. NOT worked around in the bridge, deliberately: a workaround would hide the defect from the report that should fix it. Report: `docs/upstream/mormot-imvcurrency-rax-sysv-x64.md` |
| `P1-1` | ROADMAP | next webview pin review | upstream's cmake fetches the WebView2 SDK nuget by version with no URL_HASH, so the integrity of that build input rests on nuget version immutability alone. Vendoring it or hash-pinning it is PWeb's move, not upstream's, and it belongs with the next pin bump |
| `P5-1` | ROADMAP | CI cost owner | the pinned pas2js archive is still fetched on every run with no cache; only the FPC disk image is cached. 11A-4 bounded the fetch, but CAP-11A's freeze forbade changing WHAT CI runs and 11A-14 sent caching to whoever next owns the matrix's cost |
| `P6-2` | ROADMAP | long-path shard | the Ansi-argv half is closed by P6U-1. The unprefixed `FindFirstFileW` MAX_PATH bound in the bundler's directory walk stands; failures are loud build errors, never silent corruption. Same family as 6B3-4 |
| `6B1-3` | ROADMAP | repository owner | `normal.iss` declares no MinVersion, so setup runs on Windows versions the Evergreen runtime no longer supports and fails later inside the bootstrapper with an opaque diagnostic. Picking the floor is a product decision ratified nowhere in the spec set |
| `6B2-3` | ROADMAP | the shard that next touches all four setup gate scripts | `Invoke-Bounded`/`Invoke-Captured` is still copy-pasted across `test/cap6b1`, `cap6b2`, `cap6b3` and `cap6b4`, and each copy has independently patched kill/wait semantics |
| `6B3-3` | ROADMAP | a per-profile userDataFolder shard | 6B4-3 ratified that user data is shared and preserved, and said in as many words that the compatibility concern is NOT closed by that policy: a profile folder written by a newer Evergreen can still make `webview_create` fail against the older pinned fixed runtime |
| `6B3-4` | ROADMAP | long-path shard | `pweb.platform.webview2.fixed.pas` composes every path by concatenation with no `\\?\` prefix, so a deep install plus the deepest members of the runtime subtree can exceed MAX_PATH. Same family as P6-2 |
| `6B4-7` | ROADMAP | the shard that first bumps the Fixed Runtime pin | `fixed.iss` authors no `[InstallDelete]`, so a pin-bumped fixed install over an older one strands the previous ~690 MB runtime tree and no gate would see it. Unreachable today because exactly one version is pinned, and real the moment a bump lands |
| `6B4-10` | ROADMAP | next WebView2 pin bump | `-Refresh` reads the `url` key, which is now the immutable CDN target, so a bump must re-resolve the fwlink by hand. A `discovery-url` key alongside `url` closes it and is a lock-schema change. Pairs with 7M1-3 |
| `7M0-5` | ROADMAP | next webview version bump | both native build scripts assert lock values as string literals rather than as shapes derived from `version.h`, so a routine version bump fails with a message that reads as tampering |
| `7M1-3` | ROADMAP | a lock-schema shard | no machine-readable marker distinguishes a RATIFIED pinned value from a provisional one; the distinction lives only in prose comments no gate reads. Pairs with 6B4-10 and 7M1-10 |
| `7M1-5` | ROADMAP | CAP-12 | a 206 response with `Content-Range` over a large body needs chunked or deferred delivery, at which point `stopURLSchemeTask:` really can interleave and the claim-once guards become load-bearing. `stop_arrivals=0` is printed as an explicit limitation on every runtime leg |
| `7M1-6` | ROADMAP | the shard that ratifies a cross-platform attach seam | `examples/06-assets` cannot select `TCocoaAssetHandler` without a ratified answer to what shape the attach seam has when one platform cannot attach after creation. That is an API question, not a macOS one |
| `7M1-9` | ROADMAP | a macOS signing shard | `DYLD_LIBRARY_PATH` can still redirect an ad-hoc-signed binary by leaf name ahead of `@rpath` expansion. Closure is hardened runtime plus library validation applied at signing time, and nothing in the tree signs. Pairs with D2-4 |
| `7M1-10` | ROADMAP | a lock-schema shard | the dylib export gate's RTTI allowance is unbounded: `other_count` is measured and recorded but never compared, so a patched upstream that added a C++ class with RTTI passes silently. Pinning it per architecture closes it |
| `7M1-11` | ROADMAP | a shard that revisits the CAP-7L confinement algorithm | a hard link inside the asset root pointing at an inode outside it is served on Linux and Darwin alike, and neither `readlink` nor `F_GETPATH` closes it. The named fix is same-device plus inode-set membership, or an `openat`-relative walk from a root descriptor |
| `7M1-14` | ROADMAP | the shard that next touches the macOS gate suite | a bash-3.2 self-referencing-`local` scan belongs beside the existing no-inline-macOS-flag scan. It was deliberately not added in the same change as the fix, because `run_cap7m_gates.sh` runs before every other macOS gate and a buggy scanner there blocks the whole job |
| `7F-3` | ROADMAP | CAP-12 | the 36 ABI probe facts, the 6 fcntl facts and the CAP-7M1 runtime markers are still per-target records no job compares between architectures. The 17-name export set and the logical inventories ARE compared across four targets; this is the named remainder |
| `8A-3` | ROADMAP | a host-hardening shard | `SnapshotCapabilities` on a principal or window id that was never configured yields the full `AppMaximum`, so a host typo fails open to ceiling rights instead of failing loudly. Ratified semantics rather than a defect, but an opt-in strict mode or a startup assertion would make misconfiguration a named failure |
| `8B-1` | ROADMAP | spec owner | the ratification records the intended new `security-model.md` wording — a privileged WebView never navigates to external content, and approved URIs reach the OS only through a capability-authorized invocation — and applying it to the spec is an explicit doc-only follow-up that has not been done |
| `8B-8` | ROADMAP | a shard that adds a deterministic cross-engine download trigger | the driver's cross-origin `download`-attribute anchor is treated by engines as a plain navigation, so the dedicated download events plausibly never fire and no gate asserts a download operation was actually prevented — dropping the Windows `put_Handled` turns no gate red |
| `8C-2` | ROADMAP | the shard that needs an external-content view | the frozen model already carries everything such a principal needs, and the `TrustedContent=false` gate is proven denied-before-method-row. What does not exist is host wiring, a guard profile, or a spec ratification |
| `9A-2` | ROADMAP | CAP-12 | the Promise-returning `pweb.invoke` was measured at Checkpoint 1 and not chosen; it needs a job pump and cross-enqueue JSValue rooting the pinned wrapper does not expose. It is the same ratification 9B1-2 waits on, and a shard wanting async-first plugin scripts owns both |
| `9B1-6` | ROADMAP | CAP-12 | module and manifest size bounds are checked after the carrier has already materialised the asset, because the frozen `TryRead` has no size, HEAD or streaming form. The real fix is a carrier-side materialisation cap, which needs `IAssetStore` ratification and belongs with the blob plane |
| `9B1-7` | ROADMAP | the shard that ratifies a module-source validator | module source shares the path validator, so a raw C1 control byte is refused even inside a comment or a string literal. Deterministic and fail-closed, but stricter than JavaScript requires, and whether module source gets its own validator is a decision to ratify rather than a second copy of a security validator to grow |
| `9B1-8` | ROADMAP | the shard that next touches `test/cap9a` | `run_quickjsfoundation.ps1` extracts `MARKER_PASS` case-sensitively and then tests it with `-match`, and `run_quickjsfoundation.sh` never removes its `mktemp -d`. Both shapes were corrected in the CAP-9B1 runners; the CAP-9A pair is untouched |
| `9B2-5` | ROADMAP | the shard that next revisits the CAP-9A script surface | the `PostScript`/`WaitScript`/`Eval` mailbox path gained no pending-job gate, and adding one would move the frozen CAP-9A corpus. It is the diagnostic surface rather than the production call API, and that shard should decide whether to extend the gate or retire the path |
| `9C2-3` | ROADMAP | CAP-13 | no `plugins.zip`, generated registry or `LICENSE.quickjs` enters the three Windows installer profiles. CAP-10 was named as the owner of deciding which generated applications include plugins and closed without doing it, so the decision now travels with the installers |
| `B1-5` | ROADMAP | CAP-12 | `examples/08-release`, `examples/07-quickjs` and the CAP-8 harnesses still compose the runtime by hand rather than through `pweb.webview.host`, so there are two compositions of one runtime and only one is exercised by a generated project. Migrating them re-baselines three frozen closure digests, which belongs to a shard whose gates already re-measure them |
| `B2-10` | ROADMAP | the shard that next touches `test/cap10b1` | `prove_cap10b1.sh` still captures `$?` after a bare simple command for `npm ci`, the typecheck, the build and the native compile, and extracts its ready report with an unguarded `grep` under `pipefail`. Under `set -e` those failure paths are unreachable. The identical shape was fixed in the CAP-10B2 twin |
| `B2-16` | ROADMAP | the owner of the smoke non-report | CAP-11A instrumented the OBSERVER and seeded the cause rule, but no fixture executes the CAP-10B1/B2 proofs' own report parser or their timeout path; the self-test legs all mutate an already-emitted evidence file and exercise the aggregator. Departs from the CAP-10 closure's CAP-11 disposition because CAP-11A closed the observer half only |
| `D2-1` | ROADMAP | a licensing shard, conditional | the SDK ships no compiler at all, and the pinned Pas2JS release archive additionally carries no licence text — its own README points at a `COPYING.FPC` the archive does not contain. Shipping Pas2JS becomes possible the day an offline licence text can be pinned by digest from a reviewed source, and not before |
| `D2-4` | ROADMAP | a release-signing shard | the manifest catches a half-copied, truncated or altered SDK but not a manifest rewritten to describe the altered bytes, and it does not notice its own absence. Closing the whole class needs a signature over the manifest and a key nobody has ratified a home for. Pairs with 7M1-9 |
| `P6U-2` | ROADMAP | a shard touching `tools/quickjs` | `pwebqjspack.pas` still reads `ParamStr`, so a CHECKOUT under a non-ASCII directory meets the same RTL Ansi conversion on Windows. It ships in no SDK and no `pweb` command spawns it, so the reach is a developer's machine rather than a user's |
| `P6U-6` | ROADMAP | CAP-12 | the schema-agreement gate compares the three field LISTS, and nothing enforces the required-versus-compared-versus-per-target DISTINCTION. That distinction has since cost two further red runs, at D1-17 and 11B-14. The named fix is a declarative field set: one place saying, per field, required, compared, or per-target |
| `10E-2` | ROADMAP | the CAP-4 / CAP-6 asset layer | `PWebBundleLoadFile` accepts a symbolic-link `app.pwb` while the plugin reader refuses one. The asymmetry is pre-existing and unowned; closing it means giving the bundle loader the reparse-refusing open `pweb.script.release.pas` already has, with a supersession of its own |
| `10E-4` | ROADMAP | CI owner | Pascal sources are not LF-pinned in `.gitattributes`, so `sed`-based marker extraction in several POSIX gates cannot run from a Windows checkout under WSL — the documented way of validating the Linux legs without spending a hosted run. Both candidate fixes are named, and the first is a checkout-behaviour change for every collaborator that should be decided rather than slipped in |
| `11B-4` | ROADMAP | CAP-12 | the webview watcher's shape does not fit mORMot head — no C headers, no platform patch, no library build, no signature pin — and `mormot.lock` pins statics to a release asset, so `build_failed` would be the normal outcome rather than news. A mORMot watcher is a different instrument with its own budget |
| `11B-19` | ROADMAP | CAP-12 | close-on-report is unavailable to every smoke driver, measured four ways. What remains owed is one of two host-side changes — flush the report line so a driver can see it, or close the window on the first report inside the host — either of which turns a 15-second floor into a 300-millisecond run. `examples/` and `src/` were frozen for CAP-11B |
| `14A-3` | ROADMAP | a shard that ratifies whether an SVG in a bundle is an image, a document, or both | `.svg` is not scanned by the CAP-14A CSP refusal, and the reason is sound for the common case: an SVG referenced as an image has scripting disabled by the image context, so a handler inside one is inert by design rather than by CSP and refusing it would refuse a working dist. The narrow case left open is an application that NAVIGATES to one — `PWebClassifyNavigation` permits any `pweb://app/...` top-level navigation — because that SVG is then a real document whose inline script `script-src 'self'` blocks with exactly the silence CAP-14A exists to end. No shipped corpus does it. Closing it is a decision about what an SVG in a bundle is, and only then a question of whether an XML tokenizer is a second scanner or a mode of the existing one |
