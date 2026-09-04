# The public build contract (CAP-10D0)

```
pweb build [--project <path>] [--profile <name>]
pweb build --help
```

`build` runs the CAP-10C1 ten-stage lifecycle pipeline end to end for the
project's declared frontend kind and leaves the CAP-10C0 run layout under
`<output>/<os>-<arch>/release/`. It is the last command of the CAP-10
surface: `pweb --help` advertises `create doctor run dev build`, and

```
pweb create demo --ui react|pas2js --bundle-id com.example.demo
cd demo
pweb build
pweb run
```

is the whole path from nothing to a running application, on four targets,
from any working directory, with no script in between.

Everything here is a **contract**. The human prose may be reworded freely;
the command grammar, the replacement rule, the summary fields and the exit
codes may not, except by a version bump.

---

## 1. The grammar, and every option that is not in it

`build` takes `--project`, `--profile` and `--help` and **nothing else**.
CAP-10D0 ratified the first and the third; **CAP-10D1 ratified `--profile`**,
which turns the release into a distributable artifact and is the whole of
[distribution-contract.md](distribution-contract.md). Everything below is
CAP-10D0's, unchanged: without `--profile` this command is byte-for-byte what
that shard froze. Every refusal is
an existing CAP-10A cause — `unknown_option`, `duplicate_option`,
`option_not_for_command`, `extra_positional`, `missing_value`,
`empty_value`, `argument_encoding` — and this shard adds no usage code.

- **The frontend kind comes from `pweb.json`**, never from an option. A
  descriptor is the one place a project's identity is stated.
- **The target is the host target.** Nothing is cross-compiled; there is no
  `--target`, and `<os>-<arch>` is this machine's.
- **Every stage runs on every build.** The pipeline is resumable by design
  and deliberately does not resume: resumption is a decision about
  staleness, and a build tool that guesses what is still fresh ships a stale
  artifact. So there is no incremental mode, nothing to resume, and — since
  the release is replaced whole — nothing to clean.
- **No `--target`, `--clean`, `--release`/`--debug`, `--json`,
  `--watch`, `--install`, `--output` or `--force`**, no short option, no
  response file, no `--` terminator, and no option any environment variable
  can set. Each absence is a contract rather than an omission: an option
  exposed before its semantics are ratified can never be taken back.
  `test/cap10d0/check_cap10d0_contracts.ps1` refuses the parser that grew
  one.

SDK packaging is **CAP-10D2**, and none of its vocabulary is in the build
path. The CAP-13 profiles, the distributable Linux artifact and the macOS
signing posture arrived at **CAP-10D1**, behind `--profile` and behind
nothing else: the packaging driver is a second delegation from
`pweb.cli.build`, after the pipeline has committed and the CAP-10C0 resolver
has accepted the layout.

## 2. One execution path

`build` adds no way to run a child. It calls `PWebCliRunPipeline`
(`tools/pweb/pweb.cli.pipeline.pas`) exactly once through one private driver,
`tools/pweb/pweb.cli.build.pas`, which spawns nothing, resolves no tool,
knows no stage and carries no platform conditional; afterwards it reads the
committed layout with the same tree projection the pipeline uses. The
ratified set of units that call the CAP-10C0 engine is unchanged at four —
`pweb.cli.probe` (the doctor), `pweb.cli.run`, `pweb.cli.pipeline` and
`pweb.cli.dev` — and the gate measures the set rather than the intention.

The ten stages, their order, their bounds, the Pas2JS assembly, the
project-mutation set and the network policy are
[pipeline-contract.md](pipeline-contract.md), unchanged.

## 3. Replacing an existing release

C1 assembles a release in a sibling temporary directory and commits it by a
rename that must not replace. CAP-10D0 **ratifies that sequence as the
public rule**, `stage_aside_rename_reclaim`:

```
1  assemble the new release in <output>/<target>/.pweb-release.tmp
2  if release/ exists as a DIRECTORY:
     2a reclaim .pweb-old.tmp if the name is taken   (guarded remover)
     2b rename release -> .pweb-old.tmp              (never replaces)
3  rename .pweb-release.tmp -> release               (never replaces)
     on failure, and only if 2b happened: rename .pweb-old.tmp -> release
4  reclaim .pweb-old.tmp   (guarded, bounded; a failure is REPORTED and is
                            never fatal, and the exit code does not move)
5  verify by re-resolving through the CAP-10C0 resolver ITSELF
```

**A rename that would replace an existing path is never used**, on either
family: Windows calls `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING`, so
the kernel refuses it and leaves no check-then-commit window; POSIX has no
portable no-replace form (`renameat2(RENAME_NOREPLACE)` is Linux-only and
`renamex_np(RENAME_EXCL)` is Darwin-only), so the destination is `lstat`ed
immediately before the call, and the residual is bounded and recorded — only
an *empty* directory appearing inside that window could be replaced, because
a rename onto a non-empty directory is `ENOTEMPTY` and onto a file is
`ENOTDIR`. No user content can be destroyed by it.

**The window, stated honestly.** Between the two renames of steps 2b and 3
there is exactly one bounded instant in which no release exists at all
(`one_rename_no_release`). It cannot be removed:

- Windows has no atomic directory swap, and `MOVEFILE_REPLACE_EXISTING` does
  not apply to a populated directory;
- POSIX `rename(2)` replaces a directory only when the destination is an
  **empty** directory;
- Linux's `renameat2(RENAME_EXCHANGE)` would do it and is Linux-only, which
  would make one rule three;
- an indirection — a junction or a symlink at `release` — is refused by the
  **CAP-10C0 resolver itself**, which fails any reparse point anywhere on the
  layout chain (`layout_link`), so a swap-by-link produces a layout `pweb
  run` will not accept.

A `pweb run` that starts inside that instant answers `not_built`, which is a
correct answer. What never happens is a **partial** or a **mixed** layout: at
no point does `release/` hold some files from one build and some from
another.

### The failure table

| failure at | on disk afterwards | exit |
|---|---|---|
| any stage 1–8, or an interrupt before the layout stage | the previous `release/` untouched; no staging tree left | 3/4/5/6 per §9 of the pipeline contract |
| step 1 (`layout_input_missing`, `layout_stage_dir_failed`, `layout_stage_copy_failed`) | the previous `release/` untouched; the staged tree reclaimed | 6 |
| step 2 (`layout_reclaim_failed`) | the previous `release/` untouched — it has not been moved yet | 6 |
| step 3 (`layout_commit_failed`) | the previous release is renamed **back**; if that rollback also fails the tree is at `.pweb-old.tmp` and the diagnostic names it | 6 |
| step 4 | the new release is in place; `.pweb-old.tmp` remains and is reported | 0 |
| step 5 (`verify`) | the committed release is removed: no release, which `pweb run` answers `not_built` — a committed layout the run command would refuse is worse than none | 6 |

### Racing a running application

`pweb run` launches the application with the release directory as its
working directory, and the two families answer a build that races it
differently. **Measured, and recorded per target rather than claimed once:**

- **POSIX** — a directory that is a process's current directory renames
  freely and the running process keeps its inode, so the build replaces the
  layout underneath a live application, the old application runs to
  completion, and a run started afterwards gets the new one.
- **Windows** — a directory that is any process's current directory cannot
  be renamed, so step 2b fails, the build is refused with
  `layout_reclaim_failed` and the running application is untouched. `build`
  prints one advisory line naming the likely cause; the cause code and the
  exit category do not move.

Neither can produce a partial layout, and that is the property this rule
exists for.

## 4. What it prints

Human output only. A stage's forwarded child lines go to **stdout** with the
stage-name prefix the pipeline puts on them; every line this CLI writes
itself is `pweb: `-prefixed and goes to **stderr**, exactly as `run` and
`dev` split theirs. No ANSI from this CLI on either stream, ever — a tool's
own forwarded bytes are the tool's. No absolute path, no SDK location, no
home directory and no environment content reaches either stream.

One line per stage as the pipeline's own driver prints them, with the stage
names exactly as this contract names them, then the summary — **six fields
and no more**:

```
pweb: built demo
  ui           react
  target       windows-x86_64
  release      dist/windows-x86_64/release
  app.pwb      3f2c…
  bytes        4823104
pweb: run it with `pweb run`
```

The release directory is named **relative to the project**, which is both
the whole truth and the one form that is byte-identical on every machine.
The last line is emitted **only** when the CAP-10C0 resolver actually
accepted the committed layout in the `verify` stage: a build tool whose last
line tells you to run something it has not confirmed is runnable is a build
tool whose last line is a guess.

## 5. Exit codes

[pipeline-contract.md](pipeline-contract.md) §9, unchanged, and no seventh:

| code | meaning |
|---|---|
| 0 | every stage of this UI ran and the layout verified |
| 2 | the command line was refused |
| 3 | the project, its descriptor, its paths or its layout |
| 4 | the machine cannot build it: the doctor refused, or a tool is missing, unrunnable or the wrong target |
| 5 | a stage's child failed, died, or was stopped — its real typed status is printed |
| 6 | an invariant of the pipeline itself broke |

Human text never changes the category, and the category never depends on
what a tool printed.

## 6. Interruption

Ctrl+C, `SIGINT`, `SIGTERM` or `SIGHUP` travels through the CAP-10C0
graceful-then-forced ladder into the running child tree and is then observed
between stages, so an interrupted build stops within one stage's bound and
leaves the same nothing a failure leaves: the previous `release/` untouched,
the staging tree reclaimed, the tree drained by membership, and the ratified
category. The stop handler is installed **before** anything is spawned.

CAP-10C1 measured this on POSIX and recorded `interrupt_clean =
not_measured` on Windows, because a console control event there needs a
helper that attaches to a console of its own. `test/cap10d0/pwebbuilddrv`
is that measurement: it spawns the real `pweb build` with its own console
and delivers a real interrupt through `test/cap10c0/pwebchild`, so the
claim now exists on all four targets.

## 7. What a build does not do

It starts no watcher, no development server, no proxy, no HMR transport and
no listener; it opens no socket and binds no port; it changes no CSP and no
privileged origin; it modifies no generated **source** file; it vendors
neither PWeb nor mORMot into a project; it writes nothing outside the four
ratified writable prefixes and `<output>`; it reads no `.env` and injects no
environment variable into any child; and it produces no installer, archive,
DMG, tarball or signature. Each of those is a property of what the build
path does not link or does not write, and each is measured rather than
promised.

**Exactly one stage may reach the network**, `install`, and only for a React
project: `node <npm-cli.js> ci --no-audit --no-fund --ignore-scripts`
against the committed lockfile. A Pas2JS build declares no network stage and
makes none.

## 8. Cross-links

| document | what it freezes |
|---|---|
| [cli-contract.md](cli-contract.md) | the public command surface, `pweb.json` schema 1, the doctor report, the six exit codes |
| [supervision-contract.md](supervision-contract.md) | the one child-process engine every stage runs through |
| [pipeline-contract.md](pipeline-contract.md) | the ten stages, their bounds, the SDK root, the mutation set, the network policy and the release layout |
| [dev-contract.md](dev-contract.md) | the development loop, which shares the pipeline's prerequisites and none of this command's output |
