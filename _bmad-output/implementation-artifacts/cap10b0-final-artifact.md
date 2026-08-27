# CAP-10B0 — Final Artifact: the deterministic scaffold engine and the template contract

CAP-10B0 closes on hosted run **33097621494** (2026-08-27, commit
`941959ad80f627eae07140cc07b83d3eecb18d59`, branch
`phase/cap-10/b0-scaffold-engine`, baseline `5334857`): all six jobs green,
`cap7 aggregate` recording `template_corpus: PASS` on every target, ONE
`template_digest`
`fe5353efd00e66c7abf40409265a6141447b870ba20ac396b0cf9d168b682af4` and ONE
`template_semantic_digest`
`61f381c0ffd0bebb1f0d002232fb03ebac9e159f728d66d557cb457336e90259` equal on
windows-x86_64, linux-x86_64, macos-x86_64 and macos-arm64, with
`create_absent=PASS`, `network_calls=0` and `package_manager_calls=0`
everywhere. The committed negative self-test reported **73 aggregator
refusals + 2 divergence refusals** on the same run (60+2 before this shard),
so all thirteen new refusal branches are proven red on fixtures before the
real aggregation is trusted.

The CAP-10A digests are unchanged on the same run: `cli_digest`
`dc068531…4114b` and `doctor_schema_digest` `2dda57ba…c8fa7aa`, with
`pweb 0.1.0 (protocol 1)` on all four targets.

CAP-10B0 gives PWeb everything `pweb create` needs and deliberately withholds
the command itself. It adds one trusted template carrier, one generated
trust anchor, one placeholder model, one creation plan and one atomic
filesystem transaction — and it ships **no public command**, no React
scaffold and no Pas2JS scaffold.

## What shipped

```
  tools/templates/            the trusted source: templates.list + one
                              PRIVATE neutral fixture
  tools/pweb/pwebtemplates    the deterministic pack builder
  tools/pweb/pweb.cli.sdk       where the SDK is, and how that is decided
  tools/pweb/pweb.cli.template  pack, registry, grammars, verifier
  tools/pweb/pweb.cli.scaffold  identity, renderer, creation plan
  tools/pweb/pweb.cli.write     the atomic transaction
  docs/template-contract.md   the frozen contract
```

`create`, `dev`, `run` and `build` remain **unknown commands**. This shard
does not merely leave `create` undispatched: **the scaffold engine is not
linked into the `pweb` executable at all**, which
`test/cap10b0/check_cap10b0_contracts.ps1` measures against the CLI's own
compiled unit set on every CI leg. CAP-10A's `cli-units` evidence is
therefore literally unchanged, because the CLI it describes is literally
unchanged.

## The production delta is zero

`git diff --name-only` against the CAP-10A closure touches no file under
`src/`, `sdk/`, `examples/` or `deps/`. The freeze does not hold because
three digests were re-measured and matched; it holds because there was
nothing to re-measure. The digests were re-measured anyway:
`cli_digest dc068531…4114b` and `doctor_schema_digest 2dda57ba…c8fa7aa`,
each equal to its CAP-10A closure value.

## The carrier, the measurement that decided it, and the measurement that corrected it

CAP-6/CAP-7L had already measured that mORMot's static DEFLATE object emits
different bytes for `x86_64-win64` and `x86_64-linux`. That is why
`app.pwb`'s golden hash is pinned per toolchain and why CAP-9C1 generates
`plugins.zip`'s registry per target and compares only the semantic
inventory.

Before choosing a carrier, the same question was asked of a **stored**
archive: build one through `TZipWrite.AddStored` with the ratified fixed
timestamp, compile the identical source with two different FPC target
toolchains, and compare.

```
i386-win32    -> ec93470d…b477e  (407 bytes)
x86_64-win64  -> ec93470d…b477e  (407 bytes)
```

That measurement was sound, and the conclusion drawn from it was not. It
covered **one operating system**, and it was read as proving
OS-independence. Checkpoint 1 ratified `template_pack_digest` as a
four-target equality field on that basis.

**The matrix corrected it on the first hosted run.** Run `33093385300`
produced two archive hashes for one logical input:

| target | semantic inventory | pack bytes |
|---|---|---|
| windows-x86_64 | `61f381c0…e90259` | `65180990…3993ea` |
| linux-x86_64 | `61f381c0…e90259` | `65180990…3993ea` |
| macos-x86_64 | `61f381c0…e90259` | `55cd65bf…b5e0cc` |
| macos-arm64 | `61f381c0…e90259` | `55cd65bf…b5e0cc` |

Same length everywhere (6177 bytes), same semantic inventory everywhere, and
`macos-x86_64` agreeing with `macos-arm64` exactly — two different CPUs,
identical bytes. The cause is one line of mORMot:

```pascal
ZIP_OS = ( {$ifdef OSDARWIN} 19 {$else} 3 {$endif} ) shl 8;
ZIP_VERSION = (20 + ZIP_OS, 45 + ZIP_OS);
```

The ZIP `version made by` field records the **creating** operating system by
design; mORMot's own reader explicitly ignores it. One byte per entry.

So the contract is the CAP-9C1 split after all, reached by measurement
rather than inherited: **`template_semantic_digest` is compared across all
four targets**, **`template_pack_digest` is pinned per target** and reported
side by side, and **determinism is proved where it is real** — the gate
rebuilds the pack on each target and requires byte equality *there*, as a
must-PASS field.

The consequence for file modes is unchanged and is the useful half: because
the ZIP external attributes are zero, the archive is **structurally
incapable** of carrying a POSIX file mode whatever OS wrote it. The mode
question therefore has exactly one answer — the registry.

## The trust anchor

**The archive carries bytes. It carries nothing else, and it is believed
about nothing else.** Every name, output path, content kind, file mode, byte
length, digest and template id is a compiled constant in a generated
`pweb.templates.registry.inc`, emitted under `{$WRITEABLECONST OFF}`.

A substituted pack cannot redirect an output path, mark a file executable,
reclassify a binary as text, add or remove a file, redefine its own hash,
offer an unknown template id, or make a private template publicly
reachable. The source path on disk is literal and the `out` mapping lives in
the registry — which is also what lets a template ship `gitignore` and
generate `.gitignore` without a dot-file inside this repository quietly
changing what git tracks here.

The verifier's order is the proof: registry self-consistency → the bytes
read **once** while hashing → exact length → exact digest → the production
store over **those same bytes** → the entry count → the inventory entry by
entry. Only then does a store escape. There is no second read, so there is
no check-then-open race.

## Identity, stated and not derived

`NAME` matches `^[a-z][a-z0-9]*$` — a strict subset of the schema-1 `name`
grammar. `pweb create my-app` is **refused**, and the refusal is the point:
`PWebCliValidProgramIdent` has no hyphen, so a hyphenated NAME would force a
lossy identifier transformation, an option that applies only sometimes, or
one constant executable name for every project. NAME is simultaneously the
project name, the Pascal program identifier, the executable base name and
the destination directory; nothing is derived from a display string.

`--bundle-id` is **required and never defaulted**. CAP-10A wrote that reason
down and CAP-10B0 declines to unwrite it: a default would give every
developer who scaffolds `notes` the same `CFBundleIdentifier` and the same
Windows `AppId`.

The generated `pweb.json` is not a template file — it comes from a
serializer — and is then re-read from the staged tree by the **frozen
CAP-10A reader**, with every field compared to the plan including the
program identifier the reader derives for itself. Run end to end on the dev
host against a generated project, the real `pweb doctor` reports
`project.refusal = ok`, `name = demo`, `bundleId = com.example.demo`,
`programIdent = demo`, all three paths resolved.

## Six placeholders, and the constraint they cost

One non-recursive pass, no expressions, no conditions, no includes, no
environment interpolation. **A doubled opening brace anywhere in a text
template opens a token** — there is no escape sequence and no literal form —
so an unknown or unresolved token is a hard failure rather than something
that survives into somebody's new project.

That costs a real authoring constraint, recorded for CAP-10B1: JSX inline
styles are a doubled brace. The alternative — passing unrecognised braces
through — was rejected because it makes a typo in a token name a permanent
string in a generated project.

A rendered output path is checked twice: the canonical grammar with no
placeholder left (syntax), and **exactly the segment count of the template
it came from** (structure). No identity value can contain a `/` today; the
structural check is what keeps that true the day a grammar three units away
widens.

## The transaction

The parent must be canonical, link-free and writable; the destination must
not exist by exact spelling **and** by the case-folding volume's own answer;
a sibling staging directory is created exclusively; files are written with
`CREATE_NEW` / `O_CREAT|O_EXCL|O_NOFOLLOW`; the staged tree is re-read and
compared to the plan in **both directions**; the descriptor is re-parsed by
the frozen reader; and the commit is a same-parent rename that must not
replace.

Exclusivity is the kernel's, never a check followed by a hope. On any
failure the destination remains absent and the staging is reclaimed.

Two decisions worth naming because they cost something:

- **A staging directory that already exists is named and left alone.**
  Reclaiming a tree this process did not create is exactly the behaviour
  that turns a scaffolding tool into a deletion tool, and the failure that
  would fix is smaller than the failure it would cause.
- **An existing empty destination directory is refused like any other.**
  The commit *is* a rename, and requiring nonexistence is the one rule that
  behaves identically on POSIX `rename(2)` and Win32 `MoveFileExW`.

One residual is recorded rather than smoothed over: POSIX has no portable
no-replace rename, so the destination is `lstat`ed immediately before the
call and an **empty** directory appearing in that window would be replaced.
Nothing holding data can be — `ENOTEMPTY` and `ENOTDIR` see to that — so
*creation never destroys existing user content* holds unconditionally on
both families.

## Evidence

New four-target fields: `template_corpus` (must-PASS), `template_digest`,
`template_pack_digest`, `template_pack_schema`, `template_semantic_digest`,
`template_registry_digest`, `template_deterministic`,
`template_source_gate`, `template_offline`, `template_refusals`,
`template_file_count`, `create_absent`, `network_calls`,
`package_manager_calls`, and the per-target observation
`template_modes_applicable`.

That last one is deliberately **not** compared: POSIX has file modes and
Windows does not, which is a fact about the platform and travels exactly as
the CAP-10A doctor observations do.

The gate proves what a suite cannot: the pack is rebuilt into a second path
and the archive bytes *and* the registry text must be identical; and **seven
deliberately broken template sources** are staged — a link in the tree, an
undeclared file, a declared file that is missing, a CRLF text template, an
output naming a credential, a host path baked into a file, and a visibility
filter that selects nothing — each of which must fail with its own
diagnostic. A refusal nobody has watched fire is a comment.

Thirteen new negative self-test legs (c57–c69) prove each refusal branch red
on fixtures before the real aggregation is trusted, including the two subtle
ones: an **empty** digest on every target compares equal to every other
empty digest, and an absolute schema pin catches four targets that all
drifted together.

The self-test's own total stopped being a claim in the same shard. It ended
its summary with a hardcoded `60 aggregator refusals`, and the thirteen new
legs made that literal wrong the moment they landed — the run printed 60
while 73 fired. It now **counts** what actually refused and floors the
total, so the number is a measurement and adding a branch can never silently
under-report again.

## The CRLF rule, defended three times

CAP-7F once measured a real CRLF divergence in the frontend corpus
(`index.html` 188 bytes CRLF vs 177 LF). Here a CRLF checkout does not
merely diverge, it **fails the build** — so it is defended three times:
`.gitattributes` pins `tools/templates/**`, the engine refuses a CR byte in
any text template, and the contract check sweeps a bare checkout so the
failure is diagnosed as a *checkout* problem rather than as a mysterious
Windows-only build error.

## Adversarial review

All sixteen challenges were run. The most important finding did not come
from the review at all — it came from the matrix, and it is recorded above:
Checkpoint 1 ratified four-target archive-byte equality on a measurement
that covered one operating system, and the first hosted run refused it. That
is the four-target aggregate earning its cost.

Two further confirmed findings, both patched:

- **The renderer was quadratic.** `PWEB_TPL_FILE_MAX_BYTES` permits a 1 MiB
  text template, and appending one byte at a time to a managed string is
  roughly 5×10¹¹ byte copies for a file the limits explicitly allow — a hang
  rather than a failure, and one that would have been diagnosed as "CI is
  stuck". Nothing in the suite exercised the bound, because every fixture
  file is about 1 KB. The renderer now grows by doubling and copies runs
  with one `Move`, and a corpus row renders 512 KB with a token on every
  line so the linear behaviour is measured rather than argued.
- **An out-parameter typecast.** The plan builder passed a `RawByteString`
  through a typecast as the renderer's `RawUtf8` out parameter. It worked,
  and it read like a trick; it is now a real local plus one raw assignment.

A third finding belongs to the test harness rather than the product and is
worth the same weight: FPC does not define argument evaluation order and
**measurably** evaluates `Check(Call(out x), Message(x))` message-first on
this toolchain, so the first draft of the suite read `out` parameters before
the callee had set them and indexed a code-text array with stack garbage. It
faulted rather than reporting a wrong verdict, which was luck. Every such
assertion now binds the call to a local first.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler
and source lifecycle, the mORMot bridge, the nine-code taxonomy, protocol
v1, the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json` schema 1, the
CAP-10A parser, help, doctor and exit codes, the CAP-8A policy core, the
CAP-8B classifier and CSP, the CAP-9 runtime, package and lifecycle, the
platform adapters, the CAP-13 profiles and every dependency pin:
**unchanged**. The divergence sweep re-ratified with `pweb.cli.platform`
still at **24** conditionals — eight new filesystem primitives with two
whole platform bodies each went *inside* the existing regions, so the seam
grew without the divergence surface growing at all — and the four new engine
units carry zero.

## Known limitations / deferred

See `deferred-work.md` (CAP-10B0 entries): the POSIX commit-window residual;
the fixture declaring `ui: react` without a React frontend, so `pweb doctor`
on a fixture-generated project fails `frontend.lockfile` until CAP-10B1
ships the real template; the doubled-brace authoring constraint; the
quadratic renderer and the argument-order hazard, both recorded as lessons;
the deferred exit-code mapping; the shell-script executable-bit carve-out
that is not yet needed; the `ci.yml` documentation budget at 184.6 KB; the
`ZIP_OS` measurement that corrected a Checkpoint-1 decision; and the
CAP-10B1 handoff.

**CAP-10B0 PASS — SCAFFOLD ENGINE AND TEMPLATE CONTRACT FROZEN**
