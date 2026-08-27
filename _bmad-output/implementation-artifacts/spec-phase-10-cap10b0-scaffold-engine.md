# CAP-10B0 — the deterministic scaffold engine, template distribution and atomic creation contract

The private engine that `pweb create NAME --ui react` and
`pweb create NAME --ui pas2js` will use. CAP-10B0 freezes the engine and the
template-distribution contract; it exposes **no public command**.

Entry state: CAP-7, CAP-8, CAP-9 and CAP-10A are CLOSED. CAP-10A froze one
native FPC CLI, long-options-only parsing, `pweb.json` schema 1 with eight
required keys, exact project discovery, root-confined project paths, the
public exit codes, a source-mode doctor that mutates nothing, bounded
no-shell probes, `pweb://app` as the privileged origin in development and
production alike, and `TPWebRuntimeCommandBridge` — with `create`, `dev`,
`run` and `build` absent as unknown commands.

---

## Checkpoint-1 decisions (ratified before implementation)

### D1 — template carrier: a verified adjacent archive

`<sdk-root>/share/pweb/pweb-templates.zip`, resolved from
`<sdk-root>/bin/pweb`, plus a generated read-only registry compiled into the
consumer.

Rejected: an archive embedded in the executable (inflates the binary, makes
every template edit a CLI recompile, destroys the CAP-10A `cli-units`
evidence); an installed loose directory (N filesystem objects with N reparse
and case questions instead of one hashed blob, and no read-once-and-hash
point, so a window opens between verifying a tree and reading it).

### D2 — the pack is STORED, not deflated

CAP-6/CAP-7L measured that mORMot's static DEFLATE object emits different
bytes per toolchain, which is why `app.pwb`'s hash is pinned per toolchain
and `plugins.zip` generates its registry per target. Storing every entry
reaches no compressor, so the archive is a pure function of names, bytes,
CRC-32s and a fixed timestamp.

Measured before the decision: the same logical input built through the
`i386-win32` and `x86_64-win64` toolchains produced the identical archive,
byte for byte (`ec93470d…b477e`, 407 bytes, four builds).

Consequence, not a preference: the ZIP external attributes are zeroed, so
the format is **structurally incapable** of carrying a POSIX mode. The
file-mode question therefore has exactly one answer — the registry.

### D3 — SDK-root dependency model

A generated project contains application sources only. Future
`dev`/`run`/`build` supply every unit path from the SDK root associated with
the executing CLI. Rejected: vendoring the PWeb runtime and mORMot into
every project (measured: a PWeb host needs six `src/` paths, eight mORMot
unit directories, a statics directory and, on Win64, the CAP-3U mORMot
source patch — duplicating that per application turns one security fix into
an N-project migration); an environment-variable override (the ambient-input
class CAP-9C1 proved absent at the source).

CAP-10B0 freezes only the resolver contract and the portability rule: **no
generated file contains an absolute host path, a home directory, a user name
or a working directory.**

### D4 — the future `create` grammar

```
pweb create NAME --ui react|pas2js --bundle-id <reverse.dns> [--output <dir>]
```

- `--bundle-id` **required**, never defaulted. CAP-10A already ratified the
  reason; a default would give every developer who scaffolds `notes` the
  same `CFBundleIdentifier` and Windows `AppId`.
- `--output` names the **parent**; the destination is always `<output>/NAME`,
  so the directory name never diverges from the project identity.
- the destination **must not exist** — including an empty directory, because
  the commit is a rename and nonexistence is the one rule that behaves
  identically on POSIX `rename(2)` and Win32 `MoveFileExW`.
- no `--force`, no `--install`, no `--template-path`, no merge, no overwrite.
- **CAP-10B0 adds no exit code**; the engine returns typed refusal codes and
  CAP-10B1 ratifies the mapping, leaving the frozen CAP-10A taxonomy intact.

### D5 — identity: `NAME` matches `^[a-z][a-z0-9]*$`, 1..64 bytes

A strict subset of the schema-1 `name` grammar. `pweb create my-app` is
refused rather than transformed: `PWebCliValidProgramIdent` has no hyphen,
so a hyphenated NAME would force a lossy identifier transformation, an
option that applies only sometimes, or one constant executable name.

NAME is simultaneously the project name, the Pascal program identifier, the
executable base name and the destination directory. Every other schema-1
field comes from the template's declared layout or from a constant.

### D6 — six placeholders, one non-recursive pass

`{{PROJECT_NAME}} {{PASCAL_PROGRAM}} {{EXECUTABLE_NAME}} {{BUNDLE_ID}}
{{PROJECT_VERSION}} {{UI_KIND}}`. A doubled opening brace anywhere in a text
template opens a token; there is no escape and no literal form, so an
unknown or unresolved token is a hard failure rather than something that
survives into a generated file. Accepted cost: a template cannot contain a
doubled brace for its own purposes (JSX inline-style syntax does) — recorded
as a CAP-10B1 authoring constraint.

### D7 — `pweb create` remains absent by LINKAGE

The engine is not linked into `pweb` at all, and the contract check measures
that against the CLI's compiled unit set. CAP-10A's own `cli-units` evidence
is therefore literally unchanged, and "not implemented" is a fact about the
binary rather than a note in the help text.

---

## Scope

**MAY:** private template-pack and build units; a deterministic pack
builder; a private renderer, creation plan and atomic writer; the SDK-root
model; strict identity and placeholder grammars; four-target tests and CI;
the frozen template contract document.

**MUST NOT:** expose `pweb create`; create the React or Pas2JS scaffold;
invoke npm, pas2js or FPC; compile the generated application; run a package
manager; access the network; generate `app.pwb` or `plugins.zip`; implement
dev/run/build; vendor mORMot per project; change `pweb.json` schema 1;
modify any frozen runtime or security contract.

---

## Acceptance

1. trusted deterministic template carrier;
2. compiled read-only semantic registry;
3. executable-relative trusted resolution;
4. frozen SDK dependency model;
5. exact identity mapping ratified;
6. bounded fixed placeholder model;
7. strict text/binary handling;
8. complete creation plan before any write;
9. root-confined output paths;
10. destination-nonexistence rule;
11. atomic sibling-stage-and-rename commit;
12. no failure leaves a partial project;
13. generated `pweb.json` matches frozen schema 1;
14. no secret or absolute-path leakage;
15. no network, package-manager or compiler execution;
16. byte and semantic determinism on four targets;
17. `pweb create` publicly absent;
18. CAP-10A regressions green;
19. CAP-7/CAP-8/CAP-9 regressions green;
20. frozen contracts and pins unchanged;
21. hosted CI green.

## Test matrix

`T1–T12` template pack, list, registry and verifier · `R1–R10` renderer,
text contract and line endings · `P1–P10` creation plan, bounds and
collisions · `A1–A12` the filesystem transaction · `S1–S8` generated-project
security · plus the SDK resolver.
