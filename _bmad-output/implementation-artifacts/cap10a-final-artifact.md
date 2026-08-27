# CAP-10A — Final Artifact: the native `pweb` CLI, the project contract, and the reusable runtime-command layer

**Hosted run outstanding.** Everything below is measured on the Windows dev
host; the four-target aggregation is what the closure record will name.

CAP-10A gives PWeb a public entry point and takes away its last duplicated
security decision. It adds one native FPC console executable, one strict
project descriptor, one diagnostic command with two byte-agreeing
projections, and one reusable runtime-command layer that four hosts now share
instead of four copies of.

## What shipped

```
  pweb --help | --version | doctor [--json] [--with-paths]
                                   [--project <path>] [--no-color] [--verbose]

  tools/pweb/          pweb.pas + 8 private pweb.cli.* units
  src/rpc/             pweb.rpc.command.pas - the ONE external-open command
  docs/cli-contract.md the frozen public surface
```

`create`, `dev`, `run` and `build` are **unknown commands**: not stubs, not
"not implemented" placeholders, and absent from `--help`. A command that
parses is a promise, and the gate asserts help advertises none of them.

## The runtime-command promotion, and how it is known to be inert

By the close of CAP-9, `pweb.openExternal` existed as four byte-similar
private copies — the CAP-6 release host, the CAP-9 QuickJS host, the CAP-8B
navigation matrix and the CAP-8C multi-principal harness — each deciding the
same three things and none of them able to notice the others drifting.
CAP-10B was about to generate more.

The decision now lives once, as an `IInvocationBridge` decorator:

```
invocation -> TryEnqueue -> scheduler -> ICapabilityPolicy (authoritative)
           -> TPWebRuntimeCommandBridge
                pweb.openExternal -> PWebValidExternalUri -> host opener
                anything else     -> the inner bridge, verbatim
           -> the application/mORMot bridge
```

No interface changed. No new scheduler path. The capability mapping
`pweb.openExternal -> external.open` is untouched and the policy still runs
before the bridge, so a denied principal is answered `forbidden`/403 with the
opener count reading zero because **nothing ran**, not because something
declined. The layer carries no `{$ifdef}`, names no operating system, builds
no command string and starts no process: the platform opener is injected, and
a nil inner bridge or a nil opener is refused at construction rather than
becoming a plausible runtime answer.

The proof that this is behaviour-preserving is not the diff. It is the three
frozen digests, re-measured on the dev host after the migration:

| digest | value | source of the expectation |
|---|---|---|
| `navigation_policy_digest` | `360d69f282e9d8b053d1ef8a5052f76860875c723b9e6512b0d38685f0c7212e` | CAP-8 closure |
| `security_corpus_digest` | `c5fc378bc3c6eb6aa6db753e35287db5cb7ed6332aeac77b75767919e5adbdf4` | CAP-8 closure |
| `quickjs_gui_digest` | `67e08c692f2290e16721ba9c866162f3b5ac0f17338236977917d8a25a967b36` | CAP-9C2 closure |

Each equal to its recorded value, with the real-window ledgers unchanged:
CAP-8B `open_ok=2 open_refused=1 open_failed=0 opener_unexpected_uri=0`, and
CAP-8C `opener_main=3 opener_login=0 opener_plugin=0`. The CAP-9C2 gate
reports `PASS` with `listeners=0`.

## The project contract

`pweb.json`, schema 1, **eight required keys and no optional keys** — growth
is a schema bump, which is a visible act, rather than an optional field that a
new CLI accepts and an old one refuses while both call themselves schema 1.

The reader is strict where strictness is cheap and the failure is expensive:
no BOM, strict shortest-form UTF-8 over the whole document, no comments,
nothing after the top-level object, duplicate keys refused *after* escape
decoding, unknown keys refused, integers only in their strict form, raw
control bytes refused inside strings, 64 KiB ceiling. A key whose **name**
suggests a credential gets its own diagnostic rather than the generic
unknown-field one, so the refusal survives a schema that adds fields.

Identifiers are stated, never inferred. The Pascal program identifier and the
executable base name are the basename of `native.program` without its final
extension; `bundleId` is the single application-identity anchor from which
CAP-10B/D will derive the Windows AppId and the `CFBundleIdentifier`. Nothing
is derived from a display string.

## Path confinement

Syntax is the shared `PWebAssetPathValid` — the same ratified grammar that
governs `pweb://app` assets, so the CLI and the runtime cannot disagree about
what a canonical path is. Resolution is a filesystem question asked one
segment at a time: the root canonicalized once through the kernel, every
segment matched against its **exact on-disk spelling read from the directory
itself**, a reparse point at any position refusing the whole path, and the
deepest existing directory re-canonicalized and compared byte-exactly. A
lexical prefix test would pass here for free and prove nothing.

The link refusal is proved against a **real** link on every target: an NTFS
junction on Windows (no privilege required) and a symlink on POSIX. A machine
that cannot create the fixture fails the suite rather than recording a weaker
corpus line.

## Doctor

One structured result array; the human report and the JSON document are two
projections of it. Thirteen rows in the `source` mode — the only mode this
build implements. The build and release requirements emit **no row at all**,
and that absence is the honest shape: schema 1 carries no dependency model, so
where a generated project's mORMot lives is a question this build cannot
answer, and a `not_applicable` row would read as a verdict on a question
nobody asked.

`pweb doctor` mutates nothing, and the gate **measures** it: the fixture tree
and every lock file in the repository are hashed before and after a real run
and required to be identical. Output-directory writability is asked as a
permission question — a directory handle opened for write access on Windows,
`access(W_OK|X_OK)` on POSIX — never by creating a probe file.

Probes are exact-path, argument-array, bounded (15 s), stdin-closed, both
streams drained together and captured to a 64 KiB ceiling with the excess
read-and-discarded, child terminated and reaped on timeout. There is no
command string anywhere in the CLI, so there is no grammar for a value to
escape from — and no descriptor value reaches the probe layer at all, because
the tool names are compile-time constants.

Two decisions worth naming because they cost something:

- **`npm` is diagnosed by presence, never by version.** On Windows its only
  entry point is a batch file `CreateProcess` cannot run; interrogating it
  needs `cmd.exe`, which this CLI does not have and will not grow. A check
  that answered on POSIX and lied on Windows would be worse than one that
  makes no version claim at all.
- **An executable that resolves inside the project root is reported and never
  executed.** Schema 1 has no toolchain model, so a `node` sitting in the
  project is an unexplained binary with a familiar name. The empty PATH entry
  — the working directory, by POSIX definition — is dropped for the same
  reason.

## Development trust, pinned before any development code exists

The privileged origin is `pweb://app` in development and production alike;
`pweb dev` will serve the frontend behind that handler; the single development
allowance will be one exact `ws://127.0.0.1:<native-selected-port>` CSP
data-channel entry for React HMR — a transport exception, never an origin
exception, and never in a production build.

`check_dev_trust.ps1` pins the production half today, on every CI leg: the
native CSP carries no `ws:`, `wss:`, `localhost`, `127.0.0.1` or `http:`; no
production source carries a development origin **as data** (a comment
explaining the refusal is not a violation, and the gate can tell the
difference); `security-model.md` carries the CAP-8B wording and no longer
promises the removed gesture-based opener; and `docs/cli-contract.md` records
the decision so CAP-10C implements what was agreed rather than what it can
remember. The runtime suite asserts the same invariants on all four targets.

The canonical wording was corrected in three places — `security-model.md`,
`SPEC.md` and `docs/kernel.md` — all of which still described links opening in
the system browser, which is the navigation-time behaviour CAP-8B measured to
be undecidable and removed.

## Evidence

New four-target fields: `cli_corpus` (must-PASS), `cli_digest`,
`doctor_schema_digest`, `cli_version_line`, `cli_exit_taxonomy`,
`doctor_checks`, `doctor_no_mutation`, `doctor_json_deterministic`.

What is compared is deliberately narrow. `cli_digest` is the decision corpus
of the parser, the descriptor reader and the confinement walk — pure logic
over injected inputs, byte-equal by construction. `doctor_schema_digest` is
the document shape plus the ordered row set and each row's severity. The
per-host **observations** — tool versions, engine versions, paths — travel in
their own artifact and are never compared, because requiring four runners to
agree on them would be requiring four identical machines.

Nine new negative self-test legs (c48–c56) prove each refusal branch red on
fixtures before the real aggregation is trusted, including the subtle one:
an **empty** digest on every target compares equal to every other empty
digest, so a gate that stopped emitting would look exactly like one that
passed everywhere.

The divergence sweep now covers `tools/pweb` and holds the CLI at
`pweb.cli.platform` (24 directives) plus the program's `{$apptype console}`
(2). Every other CLI unit is at zero, and `pweb.rpc.command.pas` joins the
frozen zero-conditional core list.

## Adversarial review

All sixteen challenges were run. One confirmed finding, patched: the Windows
engine row reports the WebView2 version **as the registry supplied it**, and
the host release line is whatever the OS says — neither is this CLI's to
promise control-byte-free, so an escape sequence arriving through one of them
would have become ANSI in a report whose `--no-color` path had just promised
to carry none. The JSON side was already safe (its escaper encodes every byte
below 0x20); the human renderer now neutralizes control bytes in every value
that did not originate as a fixed literal, and a test injects an escape
through an observed value and requires it not to survive.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler and
source lifecycle, the mORMot bridge, the nine-code taxonomy, protocol v1, the
SDK wire, `app.pwb`, `plugins.zip`, the CAP-8A policy core, the CAP-8B
classifier and CSP, the CAP-9 runtime/package/lifecycle, the platform
adapters, the CAP-13 profiles and every dependency pin: **unchanged**. No new
kernel interface, no RPC unit re-baseline, no plugin-format change, no new
export, no new wire method. The production delta is one new `src/rpc` unit and
the wiring of four hosts to it.

## Known limitations / deferred

See `deferred-work.md` (CAP-10A entries): the `source`-only requirement graph
and what a `build`/`release` mode needs first; npm diagnosed by presence; the
POSIX non-UTF-8 path refusal; the FPC `ForceDirectories` fixture hazard; the
`ci.yml` documentation budget re-assigned to CAP-11; and the CAP-10B handoff.
The CAP-8C consolidation entry is CLOSED by this shard.

**Verdict pending the hosted four-target run.**
