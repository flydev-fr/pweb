# The `pweb` CLI contract (CAP-10A)

The public surface frozen by CAP-10A: what the executable accepts, what
`pweb.json` means, what `pweb doctor --json` emits, what each exit code
promises, and the development-trust decision CAP-10C will implement.

Everything here is a **contract**. The human report may be reworded freely;
the command grammar, the descriptor schema, the JSON document, the status
vocabulary and the exit codes may not, except by a version bump.

---

## 1. The command surface

```
pweb --help
pweb --version
pweb doctor [--json] [--with-paths] [--project <path>] [--no-color] [--verbose]
```

That is the whole of it in this build. `create`, `dev`, `run` and `build` are
**unknown commands** — not stubs, not "not implemented" placeholders, and not
listed in `--help`. A command that parses is a promise, and a lifecycle CLI
that promises a scaffold it cannot produce is worse than one that has not got
there yet.

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
| 3 | project error — no usable `pweb.json` |
| 4 | environment error — a required check failed |
| 5 | probe error — a required probe could not be run or bounded |
| 6 | internal error |

Precedence is 6 > 5 > 4 > 3 > 2 > 0. Human diagnostic text never changes the
category, and there is no stack trace by default: an internal failure is a
category, and the CLI is not a debugger.

---

## 5. The development-trust decision (ratified, implemented at CAP-10C)

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

`test/cap10a/check_dev_trust.ps1` pins the production half of this today, on
every CI leg, before any development code exists — because the rule dies the
other way round: a dev mode is written, an allowance is added "temporarily" to
the shared profile, and by the time anyone looks the production CSP has a
localhost entry nobody can date.

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
