# The `pweb` CLI contract (CAP-10A, CAP-10B1, CAP-10B2, CAP-10C0, CAP-10C2, CAP-10C3, CAP-10D0)

The public surface frozen by CAP-10A and extended by CAP-10B1, CAP-10B2,
CAP-10C0, CAP-10C2, CAP-10C3 and CAP-10D0:
what the
executable accepts, what `pweb.json` means, what `pweb doctor --json` emits,
what each exit code promises, and the development-trust decision CAP-10C2
implements.

Everything here is a **contract**. The human report may be reworded freely;
the command grammar, the descriptor schema, the JSON document, the status
vocabulary and the exit codes may not, except by a version bump.

---

## 1. The command surface

```
pweb --help
pweb --version
pweb create NAME --ui react|pas2js --bundle-id <reverse.dns>
pweb create --help
pweb doctor [--json] [--with-paths] [--project <path>] [--no-color] [--verbose]
pweb run [--project <path>]
pweb run --help
pweb dev [--project <path>]
pweb dev --help
pweb build [--project <path>]
pweb build --help
```

That is the whole of it in this build, and with CAP-10D0 it is the complete
CAP-10 surface. `build` was **not** a command for four shards — not a stub,
not a "not implemented" placeholder, and not listed in `--help` — because a
command that parses is a promise, and a lifecycle CLI that promises a build
it cannot perform is worse than one that has not got there yet. It is a
command here for exactly the same reason: this executable performs the whole
of one. A name outside the five is still refused with `unknown_command` and
exit 2.

**CAP-10D0 adds `build`** ([build-contract.md](build-contract.md)). It runs
the CAP-10C1 ten-stage pipeline end to end for the project's declared `ui`
and leaves the CAP-10C0 run layout, so `pweb create` → `pweb build` →
`pweb run` is the whole path from nothing to a running application. It takes
`--project` and `--help` and nothing else, adds no usage cause, adds no exit
category, adds no stage and adds no second way to run a child: the pipeline
underneath it is CAP-10C1's, unchanged.

**CAP-10C0 adds `run` and the engine under it** (section 7 and
[supervision-contract.md](supervision-contract.md)). `run` launches an
already-built application in production mode and supervises it; it builds
nothing. It takes `--project` and nothing else, and passes the application
no argument at all.

**CAP-10C2 adds `dev`, and CAP-10C3 completes it** (section 5 and
[dev-contract.md](dev-contract.md)). `dev` builds a project, launches it,
watches the frontend, and on every completed rebuild publishes an immutable
generation the running window loads **without the application restarting**.
It takes `--project` and `--help` and nothing else and adds no usage cause.
**Both ratified frontend kinds are implemented** — `react` since CAP-10C2 and
`pas2js` since CAP-10C3 — and a project declaring any other kind is refused
with the project cause `dev_ui_unsupported` (exit 3) rather than pretending
to a loop this build does not implement. It opens no listener, no development
server and no proxy; the privileged origin stays `pweb://app`. The lifecycle
pipeline CAP-10C1 froze as private is linked into this executable to serve it
— which was not the same thing as advertising a build, and `build` stayed
unknown until CAP-10D0 made it perform one.

**CAP-10B2 adds the second frontend and nothing else.** It ships one more
trusted public template, widens the compiled `--ui` allowlist to the two kinds
schema 1 already ratified, and moves exactly one exit mapping: a template the
compiled registry does not describe is now an **environment** failure (4)
rather than a usage one, because with a two-value allowlist no command line
can reach that code — it means the pack this installation carries does not
describe a template this build advertises. Nothing else about the command
surface changed; `run`, `dev` and `build` were all still unknown
commands then, and each became one in the shard that made it do the whole
of what its name says.

CAP-10B0 built the private engine — the template carrier, the identity
mapping, the placeholder model and the atomic creation transaction, all
frozen in `docs/template-contract.md` — and deliberately did not expose it.
**CAP-10B1 exposes it.** The engine is now linked into this executable, which
`test/cap10b0/check_cap10b0_contracts.ps1` still measures against the CLI's
own compiled unit set on every CI leg — the same measurement as before,
required to come out the other way.

### `pweb create`

```
pweb create NAME --ui react|pas2js --bundle-id <reverse.dns>
```

- `NAME` is one positional operand, and it is the whole of the project's
  identity: the directory, `pweb.json`'s `name`, the Pascal program
  identifier and the executable base name are one stated value. Its grammar
  is `^[a-z][a-z0-9]*$`, 1..64 bytes — a strict subset of the schema-1
  `name` grammar, and `pweb create my-app` is refused rather than
  transformed. `docs/template-contract.md` §6 records why.
- **`--ui` is required**, and the values this build accepts are exactly
  `react` and `pas2js` — the two frontend kinds schema 1 has ratified since
  CAP-10A, each shipped with the trusted template that makes the claim true.
  The accepted set is a **compiled allowlist in the parser**, not a lookup in
  whatever archive happens to be installed: a CLI whose refusal depends on the
  contents of an archive is a CLI that would advertise a frontend the moment
  somebody added one. There is no alias (`p2js`, `pas`, `js`) and no case
  fold: `--ui React` and `--ui PAS2JS` are refused exactly like `--ui svelte`,
  because schema 1 matches `ui` case-sensitively and a CLI that accepted a
  spelling the descriptor reader later refuses would be scaffolding a project
  its own `doctor` rejects.
- **`--bundle-id` is required and never defaulted.** Inventing an
  organisation from a project name is the silent derivation this contract
  refuses, and a default would give every developer who scaffolds `notes`
  the same `CFBundleIdentifier` and the same Windows `AppId`.
- The destination is **`NAME` inside the working directory**, which is read
  once at startup and never again. There is no `--output` in this build.
- The destination **must not exist** — not as a file, not as a non-empty
  directory, not as an empty one, not as a symlink or junction, and not as a
  case-colliding sibling.
- **No `--force`, no `--install`, no `--template-path`, no merge, no
  overwrite**, and `--project`, `--json`, `--with-paths`, `--verbose` and
  `--no-color` are all refused on a create line as options this command does
  not have.
- **Creation is offline and inert.** It writes source files. It does not run
  npm, pnpm, yarn, pas2js or FPC, download anything, initialise a repository
  or open a browser, and it starts no child process of any kind.
- **Creation is atomic.** Every failure leaves the destination absent; the
  transaction is `docs/template-contract.md` §10, unchanged.

On success it prints five deterministic lines and no ANSI on any stream:

```
pweb: created demo
  ui           react
  bundle id    com.example.demo
  directory    demo
  files        15
```

The directory is named **relative to the working directory**, which is both
the whole truth — the destination is always `NAME` there — and the one form
that is byte-identical on every machine. No SDK path, no home directory and
no registry digest is ever printed.

**Long options only.** There are no short forms in v1: every alias is a second
spelling of a contract that is about to be frozen. A value may be written
`--project X` or `--project=X`; an empty value is an error, never a default.

Refused, each with its own machine-stable cause: an unknown command, an
unknown option, a repeated option, a missing value, an empty value, an option
that does not belong to the command, more than one positional, an argument
that is not valid UTF-8, and an argument carrying an embedded NUL.

Deliberately **not** implemented, and each absence is part of the contract:

- **response files.** `@args.txt` is an ordinary positional and is never
  expanded;
- **`--` as a terminator.** It is simply an unknown option;
- **environment-supplied options.** No environment variable can set, override
  or inject an option. `PATH` and `PATHEXT` are read to *find* tools, which is
  a different thing;
- **platform-divergent syntax.** `/json` is a positional on **every** platform.
  A Windows-only option form would make one command line mean two things on
  two machines.

`--version` prints exactly one line:

```
pweb 0.1.0 (protocol 1)
```

The CLI version is the runtime version: the two ship together, and one
identity is easier to reason about than two that must be kept in step.

---

## 2. The project descriptor — `pweb.json`, schema 1

```json
{
  "schema": 1,
  "name": "my-app",
  "version": "0.1.0",
  "bundleId": "com.example.myapp",
  "ui": "react",
  "native":   { "program": "src/myapp.lpr" },
  "frontend": { "root": "frontend" },
  "output": "dist"
}
```

**Every key is required and there are no optional keys.** That is a choice
about how the contract grows: an optional key added to schema 1 later would be
accepted by a new CLI and refused by an old one while both call themselves
schema 1 — a silent change of meaning. Growth happens by bumping `schema`, and
a bump is a visible, reviewable act.

The descriptor is **developer-controlled build metadata**, at the trust level
of the developer's own source tree. It is never read from `app.pwb`,
`plugins.zip`, browser storage, JavaScript or a build output, and it carries no
password, key, credential, certificate path or executable command string. A key
whose *name* suggests a credential is refused with its own diagnostic
(`descriptor_secret_field`) rather than the generic unknown-field one, so the
refusal survives a future schema that adds fields. `.env` files are not read at
all.

### Grammars

| field | grammar |
|---|---|
| `name` | `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`, 1..64 bytes |
| `version` | strict `X.Y.Z` (no prerelease, no build metadata) |
| `bundleId` | `^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$`, 2..5 labels, ≤128 bytes |
| `ui` | exactly `react` or `pas2js` |
| paths | canonical logical paths, resolved under the canonical project root |

**The program identifier is not derived from a display string.** It is the
basename of `native.program` without its final extension, and that basename
must itself match `^[a-z][a-z0-9]*$`. `src/myapp.lpr` yields `myapp`, which is
the Pascal program identifier *and* the executable base name.

`bundleId` exists in schema 1 for the same reason: macOS needs a
`CFBundleIdentifier` and Windows setup needs a stable `AppId`, and inventing
either from a name plus a guessed organisation is exactly the silent derivation
this contract refuses. The identity is stated once, by the developer. CAP-10B/D
derive the platform identifiers from it by documented rules.

### Reader strictness

UTF-8 with no BOM; strict shortest-form UTF-8 over the whole document; no
comments; nothing after the top-level object; duplicate keys refused *after*
escape decoding (so `"name"` cannot smuggle a second `name`); unknown keys
refused; integers only in their strict form (no sign, no leading zero, no
fraction, no exponent); raw control bytes refused inside strings; bounded at
64 KiB.

### Path model

Every descriptor path is relative, forward-slash and validated by the shared
canonical-logical-path grammar — the same one that governs `pweb://app` assets.
Refused: absolute forms, drive and UNC prefixes, backslashes, `.`, `..` and
empty segments, NUL and control bytes, `%`, Windows device names, ADS colons,
trailing dots and spaces.

Resolution is then a **filesystem** question, asked one segment at a time:

- the project root is canonicalized once through the kernel;
- every segment must exist in its parent with its **exact on-disk spelling**,
  read from the directory itself — a case variant is a miss on NTFS and APFS
  just as it is on ext4;
- a reparse point (symlink, junction) at **any** position refuses the whole
  path. The CLI never follows a link out of a project;
- the deepest existing directory is re-canonicalized and required to equal what
  the walk built. A lexical prefix test would pass here for free and prove
  nothing.

A trailing segment that does not exist yet is allowed — that is what `dist`
looks like before the first build. Whether a path must *exist* is an
environment question the doctor answers; syntax, case and the link refusal are
descriptor questions and refuse at load.

**A project root may carry non-ASCII characters, on every platform including
Windows.** Nothing in the path is read through a code page: the CLI takes its
own argv from `GetCommandLineW`, resolves its image directory from
`GetModuleFileNameW`, and hands every child a UTF-16 command line built by
`PWebCliWindowsCommandLine`. The one tool that stood outside that rule was the
frozen CAP-6 bundler `pwebbundle`, which read its argv through the RTL and
therefore failed the `pack` stage on such a root; it now reads the kernel's
command line too, so the guarantee is whole (ledger D2-13). The Windows path
**length** ceiling is a separate matter and still refuses — see
`docs/distribution-contract.md` and `project_root_too_long`.

### Project discovery

1. `--project <path>` names either the descriptor or its containing directory.
   It is canonicalized exactly, and **nothing else is searched** — no upward
   walk, no sibling guess, no fallback. Naming a file that is not exactly
   `pweb.json` is an error, never a hint to look nearby.
2. Otherwise the walk climbs from the working directory, stops at the **first**
   directory carrying a `pweb.json` with that exact spelling, and stops at the
   filesystem root.

The working directory is read **exactly once**, at startup, to seed that walk.
From that moment the canonical project root is the only anchor: no later
resolution consults the working directory, and the process never changes it.

---

## 3. `pweb doctor`

Diagnostic only. It inspects and reports. It downloads nothing, installs
nothing, and writes not one byte anywhere: not the project, not a lock file,
not the registry, not `PATH`, not a temporary probe file. Output-directory
writability is asked as a *permission* question — a directory handle opened for
write access on Windows, `access(W_OK|X_OK)` on POSIX — never by creating
something and deleting it.

### The requirement graph

CAP-10A implements exactly one mode, **source**: what must be true to open,
edit and compile this project on this machine.

| check | severity | applies |
|---|---|---|
| `cli.version` | required | always |
| `host.platform` | required | always |
| `platform.webview` | required | always |
| `project.descriptor` | required | always |
| `project.native_program` | required | with a project |
| `project.frontend_root` | required | with a project |
| `project.output` | required | with a project |
| `toolchain.fpc` | required | always |
| `frontend.node` | required | `ui: react` |
| `frontend.npm` | required | `ui: react` |
| `frontend.lockfile` | required | `ui: react` |
| `frontend.dependencies` | optional | `ui: react` |
| `frontend.pas2js` | required | `ui: pas2js` |

The build and release modes — Inno Setup, the pinned WebView2 artifacts,
Xcode 16.4 and SDK 15.5, the mORMot and `webview` pins, the three Windows
profiles — belong to CAP-10C/D and this build emits **no row at all** for them.
That absence is deliberate: schema 1 carries no dependency model, so where a
generated project's mORMot lives is a question this build genuinely cannot
answer, and a `not_applicable` row for it would read like a considered verdict
on a question nobody asked.

A row is never downgraded to hide a failed prerequisite. An absent required
tool **fails**; an absent optional feature **warns**; a check that does not
apply to this project's UI is **not applicable, with its reason recorded**.

### Pinned expectations

| what | value | source of truth |
|---|---|---|
| FPC | `>= 3.2.2` | `fpc.lock` `version` |
| Node.js | `>= 20.19.0` | the workflow's own `node-version` pin must satisfy it |
| Pas2JS | `== 3.0.1` exactly | `pas2js.lock` `version` |
| macOS | `>= 12.0` | `webview.lock` `macos-deployment-target` |
| WebView2 | build `>= 1587` | the CAP-6b0 detector (never re-spelled) |

Pas2JS is pinned **exactly** rather than by a floor: the SDK is compiled by it,
so a different compiler is a different product, not a newer one.

Every constant is cross-checked against its lock by
`test/cap10a/check_cap10a_contracts.ps1` on every CI leg. A constant nobody
cross-checks is a number somebody typed.

### Executable resolution

`PATH` is searched in order; on Windows each `PATHEXT` extension is tried in
`PATHEXT` order and the name matches case-insensitively, because that is what
the operating system itself does; on POSIX the name must match byte-exactly and
the file must carry the execute bit. A symlink on `PATH` **is** followed —
refusing links is a confinement rule for project paths, and nearly every
package-managed tool on `PATH` is a link. An **empty** `PATH` entry, which POSIX
defines as the working directory, is dropped: the CLI must never execute
something because of where it was invoked from.

An executable that resolves **inside the canonical project root** is reported
with its path and **never executed**. Schema 1 has no toolchain model, so a
`node` sitting in the project is an unexplained binary with a familiar name.

`npm` is diagnosed by **presence**, not by version: on Windows its only entry
point is `npm.cmd`, a batch file that `CreateProcess` cannot run and only
`cmd.exe` could interrogate. A check that answered on POSIX and lied on Windows
would be worse than one that makes no version claim at all.

### Tool probes

Exact absolute executable path, argument array, bounded timeout (15 s), stdin
closed immediately, stdout **and** stderr drained together in one non-blocking
loop, each captured to a 64 KiB ceiling and read-and-discarded past it, child
terminated and reaped on timeout. No `cmd.exe /c`, no `/bin/sh -c`, no
`system()`, no `popen`, no mORMot `RunRedirect`/`RunCommand` — and no command
string anywhere, so there is no grammar for a value to escape from.

### The JSON document

```json
{
  "doctor":1,
  "cli": {"version":"0.1.0","protocol":1},
  "host": {"os":"linux","arch":"x86_64"},
  "project": {
    "present":true, "refusal":"ok", "detail":"", "schema":1,
    "name":"my-app", "version":"0.1.0", "bundleId":"com.example.myapp",
    "ui":"react", "programIdent":"myapp", "discovered":false,
    "root":"<project>", "descriptor":"<project>/pweb.json"
  },
  "summary": {"pass":10,"warning":2,"fail":0,"notApplicable":1},
  "status":"warning",
  "checks": [
    {"id":"…","status":"…","severity":"…","cause":"…","summary":"…",
     "observed":"…","expected":"…","remediation":"…","path":"…"}
  ]
}
```

Canonical by construction: fixed key order, rows sorted by `id`, UTF-8, no
ANSI, no localized prose in any machine field, and **no timestamp anywhere** —
a document that changes every second cannot be compared across four platforms,
and comparing it across four platforms is the point.

`status` vocabulary: `pass`, `warning`, `fail`, `not_applicable`.
`severity` vocabulary: `required`, `optional`.
The machine authority is `id` + `status` + `cause`; `summary` and
`remediation` are diagnostic aids and may be reworded.

**Paths are redacted by default.** Inside the project a path becomes
`<project>/relative`; outside it becomes `<external>/basename`. That is a
privacy measure and, just as importantly, what makes the corpus four-way
comparable: a machine path is the one field that cannot be equal on a Windows
runner, an Ubuntu runner and two macOS runners. `--with-paths` opts into
absolute paths for a human who is debugging.

The human report is the **other projection of the same result array**. Neither
mode can say anything the other cannot; if they ever disagree it is because one
formats badly, never because they measured different things. Status markers are
ASCII — `[ ok ] [warn] [fail] [ -- ]` — never emoji, which render as a box on
half the consoles this runs on and cannot be grepped for. Colour appears only
when stdout is a terminal that accepted the request, never when redirected,
never with `--no-color`, and never in JSON.

---

## 4. Exit codes

| code | meaning |
|---|---|
| 0 | success (warnings do not change it) |
| 2 | usage error — the command line was refused |
| 3 | project error — no usable `pweb.json`, or a destination that cannot become one |
| 4 | environment error — a required check failed, or the SDK's own trusted resources are missing or untrusted |
| 5 | probe error — a required probe could not be run or bounded |
| 6 | internal error |

Precedence is 6 > 5 > 4 > 3 > 2 > 0. Human diagnostic text never changes the
category, and there is no stack trace by default: an internal failure is a
category, and the CLI is not a debugger.

**Neither CAP-10B1 nor CAP-10B2 added a category.** `create`'s refusals map
onto the six that already existed, and the mapping is exact:

| exit | `create` causes |
|---|---|
| 0 | the destination now exists and holds the plan |
| 2 | invalid `NAME`, invalid `--bundle-id`, a missing, duplicated or unknown option, a missing operand, an extra positional, an unsupported `--ui`, a non-public template id |
| 3 | the destination's parent is missing, not a directory, a link or not writable; the destination exists or case-collides; the staging sibling is taken or cannot be created; a write, a verification, a file mode or the committing rename failed |
| 4 | the SDK root could not be resolved from the running image, or the template pack is missing, the wrong size, the wrong digest, not a readable archive, does not match the registry compiled into this executable, or **does not carry a template this build advertises** |
| 6 | any planning failure, and a generated descriptor the frozen reader refuses — each reachable only if a pack that passed its own digest disagreed with its own compiled registry, which is an invariant failure and not a user error |

**CAP-10B2 moved one row and nothing else.** An unknown template id was a
usage cause while `--ui` had one accepted value and the pack had one template;
with a compiled two-value allowlist checked before any lookup, a typed
frontend kind can no longer reach the lookup at all, so reaching it means the
installation's pack does not describe an advertised template — the same class
of fact as a missing or tampered pack, and nothing the user did. The refusal
is proven rather than reasoned about: `test/cap10b2` compiles a second CLI
against a react-only pack and requires `create --ui pas2js` to answer 4 with
`template_unknown`.

**`create` can never produce a 5.** It starts no child process, so there is
no probe for one to come from. That is a property of the code path and the
contract check measures it.

**CAP-10C0 added no category either.** `run` maps onto the same six, and the
mapping was ratified before a line of it was written:

| exit | `run` causes |
|---|---|
| 0 | the application exited 0, after a normal or a requested shutdown |
| 2 | a duplicated, unknown or foreign option (`--json`, `--verbose`, `--no-color`), an operand |
| 3 | the project was refused (every CAP-10A descriptor cause, `output_unresolved` when `output` itself did not resolve), or the layout beneath `output` is absent (`not_built`), reached through a link (`layout_link`), spelled in a different case (`layout_case`), outside the root (`layout_escape`), the wrong shape (`layout_shape`) or, where file modes exist, not executable (`layout_not_executable`) |
| 4 | supervision could not be established: the stop handler, the pipes, the Job Object, or process creation (`supervision_unavailable`); or this host is not one of the four ratified targets (`target_unsupported`) |
| 5 | the application exited nonzero, died by a signal, or had to be force-terminated after the grace interval — its real status is printed |
| 6 | a spawn refusal that no ratified layout can produce, a child the platform could not reap, or descendants that survived the drain — whatever the application's own status |

Human text never changes the category and the category never depends on
what the application printed: a host that refuses a tampered `app.pwb`
exits 1 on its own, and `run` reports `application exited 1` and answers 5.

**CAP-10D0 added no category either.** `build` answers with
`docs/pipeline-contract.md` §9 — the mapping CAP-10C1 ratified for the
pipeline, reused rather than re-decided — projected onto the same six:

| exit | `build` causes |
|---|---|
| 0 | every stage of the project's UI ran and the CAP-10C0 resolver accepted the committed layout |
| 2 | a duplicated, unknown or foreign option (`--json`, `--verbose`, `--no-color`, `--with-paths`, `--ui`, `--bundle-id`), an operand |
| 3 | the project was refused — every CAP-10A descriptor cause — or a package-manager configuration inside it would redirect the registry (`registry_override_present`), or its `output` cannot be written |
| 4 | the machine cannot build it: `doctor` refused with its own cause, or a tool is missing, unrunnable or the wrong target; or supervision could not be established |
| 5 | a stage's child failed, died by a signal or had to be force-terminated — its real typed status is printed — or the build was interrupted (`pipeline_interrupted`) |
| 6 | an invariant of the pipeline itself broke: the read-only tree moved under it (`pipeline_mutation`), an argument reached a spawn in the extended-length form (`arg_longpath_form`), or the layout could not be assembled, committed or verified |

---

## 5. The development-trust decision (ratified at CAP-10A, implemented at CAP-10C2 and CAP-10C3)

**The privileged application origin is `pweb://app` in development and in
production alike.**

`pweb dev` will serve the development frontend **behind the existing
`pweb://app` handler**. The privileged origin never becomes
`http://127.0.0.1:<port>` or `http://localhost:<port>`, in any mode, at any
time.

For React HMR only, the native development configuration may add **one** exact
CSP data-channel allowance:

```
ws://127.0.0.1:<native-selected-port>
```

with all of the following true: the port is selected natively and written
exactly, never as a wildcard; it is a WebSocket **data channel** and nothing
else; the privileged origin is unchanged; there is **no bridge access from the
Vite origin**; and **no production build** carries the allowance in any form.
It is a transport exception and **never an origin exception**. Pas2JS
development uses rebuild-and-reload and needs no WebSocket at all.

No frontend field — in `pweb.json`, in `app.pwb`, in a manifest, anywhere —
may select a security policy, relax a CSP, or nominate a trusted origin. The
build/run mode is native-controlled. A production artifact must mechanically
prove it carries no development proxy, no HMR URL, no `ws://127.0.0.1`
allowance and no dependency on a frontend development server.

`test/cap10a/check_dev_trust.ps1` pinned the production half of this from
CAP-10A onward, on every CI leg, before any development code existed —
because the rule dies the other way round: a dev mode is written, an
allowance is added "temporarily" to the shared profile, and by the time
anyone looks the production CSP has a localhost entry nobody can date. Since
CAP-10C2 the same gate also pins the development half.

### What CAP-10C shipped, and what it deliberately did not

**`pweb dev` is rebuild-and-reload for BOTH UIs**, and
[dev-contract.md](dev-contract.md) is the whole of its contract. Every
completed rebuild — a `vite build --watch` for React, one supervised `pas2js`
run plus the CAP-10C1 assembly for Pas2JS — is packed by the frozen CAP-6
bundler into an immutable generation, published by one directory rename,
discovered by a bounded forward-only poll and loaded by one native
re-navigation to `pweb://app`. There is no listener, no development server,
no proxy and no HMR transport anywhere in it, and `PWEB_NATIVE_CSP` is
byte-identical in the development binary and the release one — measured for a
React project at CAP-10C2 and for a Pas2JS project at CAP-10C3.

The two loops differ only in how the CLI learns a rebuild is due: Vite writes
a completion sentinel from `writeBundle`, and Pas2JS — which has neither a
watch mode nor a `writeBundle` — is answered by a bounded content
fingerprint of the ratified input set, walked by the CLI itself. No platform
file-watch API exists anywhere in the repository.

**The `ws://127.0.0.1:<native-selected-port>` allowance above stays
ratified, unused, and pinned absent from every profile — for both UIs.**
Nothing in either shipped loop needs it: rebuild-and-reload was chosen for
React on the model-A spike data below, and Pas2JS development needed no
WebSocket even in the CAP-10A ratification. A ratification is not an
implementation, and a reader must be able to tell the two apart, so
`test/cap10a/check_dev_trust.ps1` pins the absence on every leg exactly as it
did before any development code existed.

**A model-A shard — serving Vite's own module graph behind `pweb://app` —
was measured and refused**, and the evidence is
`_bmad-output/implementation-artifacts/cap10c2-model-a-spike.md`. Three
findings decided it, and each is a measurement rather than a preference:

1. **the query is load-bearing and the frozen URI layer cuts it.**
   `/src/app.css` is 2563 bytes of `text/javascript`; `/src/app.css?direct`
   is 1938 bytes of `text/css` — one path, two bodies. Model A would need
   `PWebParseAppUri` to preserve and forward the query, which is a grammar
   relaxation;
2. **the MIME type would have to come from the proxied response.** `.tsx`
   and `.css` modules are served `text/javascript`, while `PWebAssetMimeType`
   derives `application/octet-stream` from `.tsx`, which every engine's
   module MIME check refuses — a change to the frozen asset-serving path;
3. **HMR would not connect and has nothing to connect for.** The client
   derives its socket host from the page URL, giving `ws://app:/` under
   `pweb://app`; and with no `@vitejs/plugin-react` in the template there is
   no Fast Refresh, so a `.tsx` edit already ends in a full reload.

Findings 1 and 2 are each a grammar or handler relaxation beyond the single
ratified allowance, which is exactly the condition this rule refuses on.
Finding 3 is recorded because it is what an HMR shard would have to solve
first: **an HMR shard needs the spike's data**, and the spike is the record
it should start from rather than a fresh guess.

CAP-10C is closed. The consolidated evidence — the four hosted green runs,
every recorded digest supersession, a disposition for every deferred item and
the CAP-10D handoff — is
`_bmad-output/implementation-artifacts/cap10c-closure-artifact.md`.

---

## 6. The reusable runtime-command layer

`pweb.openExternal` is implemented **once**, in `src/rpc/pweb.rpc.command.pas`,
as an `IInvocationBridge` decorator:

```
invocation
  -> IInvocationSource.TryEnqueue        (frozen)
  -> scheduler worker                    (frozen)
  -> ICapabilityPolicy at the ONE call site (frozen; authoritative)
  -> TPWebRuntimeCommandBridge
       pweb.openExternal -> validate -> host opener -> envelope
       anything else     -> the inner bridge, verbatim
  -> the application/mORMot bridge
```

The capability mapping is unchanged: `pweb.openExternal` → `external.open`,
checked before the bridge, so an unauthorized principal is answered
`forbidden`/403 with **zero** opener activity. The decorator performs no
authorization of its own — a second copy of an authorization rule is a second
answer to one question.

The platform opener is **injected**: the layer carries no `{$ifdef}`, names no
operating system, constructs no command string and starts no process. A nil
inner bridge or a nil opener is refused at construction, so a host that
declares the capability and supplies no opener dies at startup rather than
answering something plausible at runtime.

CAP-10B's generated hosts install this layer. They do not reimplement it.

---

## 7. `pweb run` and the supervision engine (CAP-10C0)

```
pweb run [--project <path>]
pweb run --help
```

`run` launches what the project has **already built**, in production mode,
supervises it in the foreground, propagates its termination and leaves no
process of its behind. It compiles nothing, runs no package manager, no
Pas2JS, no FPC and no git, repacks no `app.pwb`, modifies neither the project
nor its layout, opens no listener and touches no network — each of those a
property of what the run path does not link, measured by
`test/cap10c0/check_cap10c0_contracts.ps1` and by the gates.

**Resolution.** The project is discovered exactly as `doctor` discovers it
(one reading of the working directory, at startup), `pweb.json` is
strict-parsed, and the built layout is resolved beneath `output` by the one
ratified rule — the same executable-relative release model the hosts
themselves resolve:

```
<root>/<output>/<os>-<arch>/release/
  windows, linux    <ident>[.exe] + app.pwb beside it
  macos             <ident>.app/Contents/MacOS/<ident>
                    <ident>.app/Contents/Resources/app.pwb
                    <ident>.app/Contents/Info.plist
```

`<os>-<arch>` is `windows-x86_64`, `linux-x86_64`, `macos-x86_64` or
`macos-arm64` — the CLI's own target name — and `<ident>` is the program
identifier schema 1 fixes as the basename of `native.program`. Every
component is walked by the CAP-10A confinement rule (exact on-disk spelling,
a reparse point anywhere refuses the whole path, the resolved directory
compared byte-exact with the root), so a layout reached through a link or a
case variant is refused under its own cause and never read as "not built".
CAP-10D produces exactly this layout and nothing else.

**The launch.** The application is started through the one execution engine
(`tools/pweb/pweb.cli.process.pas`, see
[supervision-contract.md](supervision-contract.md)) with **no argument**, the
executable's own directory as the working directory, and the supervisor's
environment inherited unchanged — nothing injected, no `.env` read, no
development flag. Its stdout and stderr are forwarded line by line; the
supervisor's own lines are `pweb: `-prefixed on stderr and carry no ANSI.
Nothing printed names an absolute path, the SDK, a home directory or an
unrelated process. Ctrl+C (Windows) or `SIGINT`/`SIGTERM`/`SIGHUP` (POSIX)
on `pweb` becomes a graceful close request to the application — `WM_CLOSE`
to its visible top-level windows, `SIGTERM` to its process group — and the
host runs its normal CAP-9 teardown; only after the grace interval is the
tree force-terminated, and that is reported as forced. When the application
is gone, whatever it left is drained by job / process-group membership and
reported.

**Runs from an unrelated working directory behave identically**, and the
gate runs every leg from one.

**Production trust holds.** `run` adds no `ws://`, `localhost` or
`127.0.0.1` allowance, no proxy, no watcher and no listener; the privileged
origin stays `pweb://app` and the production CSP is unchanged.
`test/cap10a/check_dev_trust.ps1` keeps running on every leg.
