# The development-loop contract (CAP-10C2 React, CAP-10C3 Pas2JS)

`pweb dev` is the development loop for **both** ratified frontend kinds, and
the ratified model is **rebuild-and-reload**: it runs the CAP-10C1
prerequisites its UI has, compiles a **separate** native development host,
and on every completed rebuild packs an immutable **generation** with the
frozen CAP-6 bundler and publishes it by one directory rename. The running
host swaps its asset store and re-navigates to `pweb://app`.

The two loops differ in exactly one place — **how the CLI learns a rebuild is
due** — and in the stages that follow from it:

| | react | pas2js |
|---|---|---|
| the change source | `vite build --watch`, a supervised long-lived child that writes a sentinel from `writeBundle` | **none** — pas2js has no watch mode and no `writeBundle`, so this CLI walks the ratified input set itself |
| the supervised set | two long-lived members, the watcher and the host | **one**, the host |
| node stages | `stage_sdk`, a conditional `npm ci`, one `tsc` | none, at any point |
| the network | one stage may reach it (`npm ci`) | **no stage can** |

Everything else — the layout, the generation rule, the publish-by-rename, the
poller, the acknowledgement, the ladder, the bounds and the exit mapping — is
frontend-agnostic and is one mechanism serving both.

Everything here is a **contract**. The human report may be reworded freely;
the command grammar, the layout, the generation rule, the acknowledgement
line, the bounds and the exit codes may not, except by a version bump.

---

## The development unit directory is scoped by the network define (CAP-15B)

`pweb dev` compiles into `<output>/<target>/dev/units` and deliberately omits
`-B`, so units persist across runs and a development start does not rebuild
the whole mORMot surface before a window can open. FPC does **not** recompile
a unit merely because a conditional define changed, so a developer who added
their first `network.origins` entry would otherwise link yesterday's
`app.services.ppu` — the one compiled without the capability — and meet
`forbidden` from a door the descriptor says exists.

The unit directory therefore carries a `-net` suffix when the network region
is on: `dev/units` without declared origins, `dev/units-net` with them. Two
directories cost one rebuild on the run that changes the answer, and make "the
define never varies within one unit directory" a property rather than a hope.
The object directory is unchanged: a program is recompiled on every run
anyway.

The generated allowlist include is written into `<dev>/gen/app.network.inc`,
beside it, from the same production function a release build uses. A
development host may carry the ratified loopback origin; a release build
refuses it by name (`docs/build-contract.md` §6b).

## 1. The command

```
pweb dev [--project <path>]
pweb dev --help
```

`dev` takes `--project` and `--help` and nothing else. Every other refusal is
an existing CAP-10A cause — `option_not_for_command`, `duplicate_option`,
`extra_positional`, `unknown_option` — and neither shard adds a usage code.
Nothing typed after `dev` reaches the application: the development host
receives exactly one argument, and that argument is the CLI's own.

**Both ratified `ui` values are implemented**: `react` since CAP-10C2 and
`pas2js` since CAP-10C3. A project declaring any other kind is refused with
the **project** cause `dev_ui_unsupported` and exit 3, before anything is
resolved, started or written — the command line was well formed and the
destination is a real project; what this build does not implement is the
declared frontend kind, which is a project fact rather than a usage one.

Schema 1 ratifies exactly two kinds, so no descriptor a user can write
reaches that refusal today. **It stays anyway**, behind the one predicate
`PWebCliDevUiSupported`, and the headless suite reaches it with an
unratified ordinal — because the day a third kind is ratified the loop must
refuse it rather than start something it cannot finish, and an unreachable
branch nobody exercises is a branch nobody notices has rotted.

**`build` is a command since CAP-10D0** ([build-contract.md](build-contract.md)),
and it runs the same pipeline these start-up stages run. It changes nothing
in this document: the dev loop's host, generation, poller, acknowledgement
and ladder are untouched, and a development session still writes nothing
into `<output>/<os>-<arch>/release/`.

---

## 2. What development changes, and what it does not

It changes exactly one thing: **where the asset store comes from, and how
often it is replaced.**

| unchanged, in development and in production alike | why it matters |
|---|---|
| `pweb://app` is the only origin ever navigated | one privileged origin, one trust boundary |
| `PWEB_NATIVE_CSP`, byte-identical in both binaries | a development allowance nobody can date is how the production CSP rots |
| every generation is one `app.pwb`, opened through `PWebBundleLoadFile` | the production loader, with the production refusals; `loose_assets_used` is false in development too |
| the capability policy, the bridge chain, the navigation guard, the platform handler | the composition is the production one, called through the production entry point |

**No transport is added, in any form.** `pweb dev` starts no listener, no
development server, no proxy and no HMR transport; it opens no socket,
resolves no host and binds no port. The ratified
`ws://127.0.0.1:<native-selected-port>` CSP allowance of
[cli-contract.md](cli-contract.md) §5 stays **ratified, unused, and pinned
absent** from every profile by `test/cap10a/check_dev_trust.ps1`, and no
`ws://`, `wss://`, `localhost` or `127.0.0.1` literal exists anywhere in this
shard's source.

---

## 3. The development host is a different binary

```
fpc … -dPWEB_DEV -FU <dev>/units -FE <dev>/obj
```

Separate unit and object directories, so the release build's compiled unit
set is never polluted and "the release binary does not carry the development
unit" is a **directory listing** rather than an inference.

The generated `program.lpr` is the only place the mode is selected: under
`{$ifdef PWEB_DEV}` it uses `pweb.webview.devhost` and calls
`PWebDevHostRun`; otherwise it calls `PWebHostRun` exactly as before. The
define reaches a compiler from `pweb.cli.native`'s `PWEB_CLI_DEV_DEFINE` and
from nowhere else — not from `pweb.json`, not from a frontend file, not from
a manifest, not from an environment variable. **The build/run mode is
native-controlled**, and that is a mechanism rather than a sentence.

### The exact production seam

The reusable host (`src/webview/pweb.webview.host.pas`) gained three things
and no more:

1. **`TPWebHostOptions.ConsumedArgs: TRawUtf8DynArray`** — argv strings the
   composition has already consumed and validated, matched **byte-exactly**
   against the whole argument and skipped by both parser passes. The
   production template leaves it empty, so the refusal set is byte-for-byte
   what it was and an unknown argument still raises. It exists because "the
   host refuses every argument it does not own" has to be *composable* for a
   composition to own one, and an exact-string list is stricter than a prefix.
2. **A four-argument `PWebHostRun` overload** taking `const Store:
   IAssetStore`. `nil` means the production rule and nothing else:
   `PWebHostLoadBundle`, `app.pwb` beside the executable, never the working
   directory. The three-argument form delegates with `nil`.
3. **`function PWebHostRequestReload: Boolean`** — reads the existing
   `HostAutoCloseHandle` and `webview_dispatch`es a callback that calls
   `webview_navigate(w, PWEB_HOST_ORIGIN)`. It is `PWebHostTerminate` with
   `webview_terminate` replaced, it takes no parameter, and `PWEB_HOST_ORIGIN`
   is the only destination that exists. Production never calls it and gains
   no string from it.

**And one drain, which is what makes (3) safe.** The auto-close thread
dispatches the same way and is safe for a reason that does not transfer: the
teardown **joins** the closer before it disowns the handle and destroys the
view. A composition's poller is not a thread this unit owns — it is started
before `PWebHostRun` and joined after it returns — so a caller that read a
live handle one instruction before `InterlockedExchange(HostAutoCloseHandle,
nil)` could dispatch onto a view the teardown had already destroyed. The
narrow window is exactly DEV6's "Ctrl+C while a rebuild or pack is in
flight". `PWebHostRequestReload` therefore raises an interlocked busy count
**before** it reads the handle and lowers it after the dispatch returns, and
the teardown waits for that count to reach zero — bounded by
`PWEB_HOST_RELOAD_DRAIN_MS`, placed immediately after the disown and before
the first teardown step, so the CAP-9 shutdown order below it is reached
unchanged. A dispatch that never drains marks the view unsafe to destroy and
fails the run rather than destroying it underneath a caller. In production
nothing calls the function and the count is zero on the first look.

`IAssetStore` gained nothing. The swapping store is an **implementation** of
the frozen interface.

### The refusal that makes the split safe

```
--pweb-dev-root=<directory>
```

is **required**. A development binary started without it refuses and exits
nonzero *before* `PWebHostRun` is called, so it never reaches
`PWebHostLoadBundle` and can never load an `app.pwb` that happens to sit
beside it. It is parsed in the same two-pass, duplicate-refusing style the
two ratified host arguments are parsed in.

---

## 4. The layout, and the generation

```
<root>/<output>/<os>-<arch>/dev/
  app/            the dev binary + the webview library
                  (macOS: <ident>.app/Contents/MacOS + Info.plist, and NO
                  Contents/Resources — there is no app.pwb beside the host)
  units/  obj/    the DEV compiler outputs
  .gen.tmp/       ONE generation under construction — never published
  gen-1/ gen-2/ … app.pwb, immutable, published by ONE rename
```

`pweb run` resolves `release` and nothing else, so no development artifact is
reachable from the production command however this directory grows, and
`release/` is never written by a development session.

- **A generation is immutable and published by one rename.** Everything is
  assembled inside `.gen.tmp` and `PWebCliRenameDir` moves it onto `gen-N`,
  which **must not replace** — and does not, on any of the four targets.
  Nothing ever writes into a published generation.
- **There is no `current` pointer file**, deliberately. A pointer needs a
  replacing rename, which this repository does not have (the host's own
  verdict writer records that `RenameFile` does not replace on Windows and
  deletes first), and a pointer can be read torn, which a directory rename
  cannot be. The reader counts **forward** instead, which needs no pointer.
- **Discovery is a bounded poll.** The host's poller thread tests for
  `<root>/gen-<N+1>/app.pwb` every `PWEB_DEV_POLL_MS` and looks only forward.
  No listener, no socket, no IPC, no stdin protocol. A generation the frozen
  loader refuses is reported and skipped; the current one stays live.
- **The switch is a native re-navigation** through `PWebHostRequestReload`,
  the mechanism the auto-close and the CAP-10C0 POSIX stop helper already
  use. Never injected script, never `location.reload()`, never a restart.
- **The acknowledgement** is one ratified flushed line on the host's stdout:

  ```
  <prefix>: generation <N> loaded
  ```

  The CLI reads it from the supervision engine's own line sink. The host
  writes nothing to a disk to report a switch.
- **Cleanup is bounded and backwards only.** On generation N acknowledged the
  CLI removes `gen-M` for `M <= N - PWEB_CLI_DEV_KEEP_GENERATIONS` through the
  guarded `PWebCliPipeRemoveTree`. The host only looks forward, so a removed
  generation can never be the one it is about to open. A `.gen.tmp` left
  behind by an interrupted session is removed at the **start** of the next
  one, which is the only moment nothing can be using it.
- **A start reclaims the PREVIOUS session's generations too**, and for a
  reason stronger than tidiness. A session numbers from 1 and publishes by a
  rename that must not replace, so a surviving `gen-1` is not this session's
  stale generation — it is a different session's content under the name this
  one promises to write, and the dev host is told to open exactly that name.
  MEASURED: without the reclaim a second `pweb dev` on the same project
  refused at the first publish with `dev_publish_failed` and never opened a
  window. The reclaim ENUMERATES `<dev>` and removes only names that are
  exactly `gen-` followed by at least one digit, so it costs what is on the
  disk rather than a walk to the generation ceiling, and `app/`, `units/`,
  `obj/` and anything merely resembling a generation are never touched.

---

## 5. The completion signal — the sentinel

The template's `vite.config.ts` carries a `pweb-dev-sentinel` `writeBundle`
plugin that writes

```
<frontend>/.pweb/dev/build-id      "<watcher-start-ms>.<n>"
```

`writeBundle` fires once per completed write. `.pweb/` is already inside the
ratified project-mutation set and is already git-ignored by the template, so
the sentinel costs no new writable prefix; and it is written **outside**
`dist/`, so no byte of what the bundler packs moves and no `app.pwb` digest
changes.

**Line parsing was measured and refused.** Watch mode prints `built in 51ms.`
where a one-shot build prints `built in 52ms` behind a tick — two spellings of
one event — and the output carries ANSI whenever the inherited environment
enables colour, which a supervisor that injects nothing cannot turn off.

Two rules follow from the measurements and are ratified here:

- **Debounce, bounded.** After a sentinel change the CLI waits
  `PWEB_CLI_DEV_DEBOUNCE_MS` and re-reads; a further change restarts the wait,
  bounded by `PWEB_CLI_DEV_DEBOUNCE_MAX_MS`. Measured: Vite does **not**
  coalesce — five edits 50 ms apart produced five rebuilds — so five
  keystrokes become one or two generations rather than five.
- **The snapshot is proved consistent.** `dist/` is copied into
  `<dev>/.gen.tmp/dist` and the sentinel is then **re-read**: if it moved
  during the copy the snapshot is discarded and retaken, up to
  `PWEB_CLI_DEV_SNAPSHOT_TRIES`. Only a snapshot whose sentinel was stable
  across the whole copy is packed — the mechanical answer to "can a partial
  generation reach the host".

The CLI **deletes the sentinel before starting the watcher** and treats the
first one that appears as generation 1, so there is one build before the host
starts rather than a one-shot build plus the watcher's identical initial one.

---

## 5b. The Pas2JS completion signal: there isn't one, so the CLI decides

React is *told* when a build finished. Pas2JS is not — there is no watch mode
to report one, no `writeBundle` to hook, and the CAP-10C1 assembly runs in
the CLI rather than in the build. So the loop asks the question the other way
round: it watches the **inputs** instead of waiting for an output.
`tools/pweb/pweb.cli.devinputs.pas` is the whole of that rule, and
`PWebCliDevInputScan` is the whole of its entry point. The model is recorded
in the evidence as `cli_content_fingerprint_poll`, beside React's
`vite_sentinel`, so a target running a different detector is a divergence
rather than a diff nobody read.

### The input set

```
<frontend>/src/**        EVERY file, at any depth
<frontend>/index.html
<frontend>/app.css
<frontend>/pas2js.cfg
```

which is exactly what the CAP-10C1 Pas2JS plan reads. Nothing else is
watched: not the SDK root, not `<output>`, not `.pweb`, and **not the native
`src/`** — a native change still requires restarting `pweb dev`, exactly as
it does for React. Nothing outside the project root is walked or read, and
the walk is rooted at the frontend, so nothing above it can be reached.

`src/**` is deliberately **not** filtered by extension. An allowlist would be
a second place the compiler's real input set is written down, and the day
somebody includes a file whose extension is not on it the detector silently
stops detecting.

### The fingerprint is content, not `(size, mtime)`

```
sha256( sorted( "<logical path>|<size>|<sha256 of content>"\n ) )
```

The cheap fingerprint is the wrong one. FPC's portable timestamp layer is
**second-granular**, so two edits inside one second that leave the length
alone are one fingerprint and the change is never seen. Hashing the bytes
costs a few kilobytes of reads four times a second, is immune to that *and*
to a same-size edit, and buys a property worth having on its own: a `touch`,
a `git checkout` or a mode change that alters no byte costs no generation.

### Bounded, and fail-closed

A walk this loop repeats forever needs its own bounds rather than the C1
pipeline's, which are sized for a gate that runs once per stage:
`PWEB_CLI_DEV_MAX_INPUT_FILES`, `PWEB_CLI_DEV_MAX_INPUT_DEPTH`,
`PWEB_CLI_DEV_INPUT_FILE_MAX` and `PWEB_CLI_DEV_INPUT_PATH_MAX` (§9).

- **A symlink or reparse point anywhere inside the set is a refusal**
  (`dev_input_link`), never a followed path and never a recorded line:
  following one would let the compiler read outside the project root, and
  recording one would mean the detector had accepted a tree it does not own.
- A set past a bound is `dev_input_bound`; a frontend that does not carry the
  set at all is `dev_input_set_missing`; a directory nobody can enumerate is
  `dev_input_unreadable` — a check that answers "nothing changed" when it
  could not look is a check that disappears on exactly the trees worth
  checking.
- **At start-up all of these are refusals, exit 3, before the toolchain is
  resolved and before anything is written.** *Inside* the loop the same fact
  is reported **once** and the previous generation stays live — the treatment
  a compile error already gets, because a running window is not something to
  close over a link somebody just created.

### The consistency rule, and the debounce

The **debounce is the CAP-10C2 one, reused verbatim**
(`PWEB_CLI_DEV_DEBOUNCE_MS`, `PWEB_CLI_DEV_DEBOUNCE_MAX_MS`), over the
fingerprint instead of the sentinel.

The **consistency rule is the Pas2JS twin of the snapshot proof**: the
fingerprint is taken **before the compile** and re-taken **after the
assembly**; if it moved, the generation is discarded and rebuilt, bounded by
the same `PWEB_CLI_DEV_SNAPSHOT_TRIES`. Only a generation whose inputs were
stable across compile **and** assembly is packed — the mechanical answer to
"can a mixed generation reach the host", over the correct subject.

**A failed attempt records the input state it answered.** MEASURED on
windows-x86_64: without it, one broken `const` recompiled the whole frontend
every few seconds forever, printing the same failure each time. The value
recorded is the fingerprint taken *before* the compile, never a fresh one
taken after it — so a fix that landed *during* the failed build still looks
like a change on the next pass. React needs no equivalent, because Vite's
`writeBundle` does not fire on a failed build and a broken source produces no
new sentinel at all.

---

## 6. Start-up stages

| stage | react | pas2js | why |
|---|---|---|---|
| open + toolchain | every start | every start | the CAP-10C1 rule verbatim, doctor verdict included — refuse before any write. For pas2js the input set is walked here too, so a link or a bound refuses before the toolchain is even resolved |
| `stage_sdk` | every start | — | C1 refuses a stale staged SDK; skipping it would compile against yesterday's runtime. A Pas2JS build resolves `sdk/pas2js/pweb.native.pas` from the SDK root instead, and stages nothing into the project |
| `npm ci` | **conditionally** | — | absent `node_modules`, an absent or unreadable install record, a `package-lock.json` digest differing from it, or an unresolvable `vite` / `tsc` entry point; otherwise skipped. The record is `<frontend>/.pweb/dev/install-lock.sha256`, written only **after** a successful install. No new option |
| `tsc` | once, at start | — | Vite does not typecheck, and a typecheck per keystroke would cost seconds per generation; a type error is a start-up refusal. Pas2JS type-checks in the compiler that produces the output, on every generation |
| native dev compile | every start | every start | bounded, units cached under `<dev>/units` |
| first generation | before the host | before the host | react: the watcher's own initial build. pas2js: one compile + assembly + pack. Either way the host never opens on an empty store |

**For React, exactly one stage may reach the network, and it is the same one
the pipeline names**: `node <npm-cli.js> ci --no-audit --no-fund
--ignore-scripts`, with the same ratifications
([pipeline-contract.md](pipeline-contract.md) §5) and the same
`registry_override_present` refusal.

**A Pas2JS session declares no network stage at all**, and there is none to
declare: it resolves `pas2js` and `fpc`, reads the SDK root and writes under
`<output>`. `network_stages` is `none` by construction rather than by policy,
and the membership-scoped sampler measures it on every leg.

### The Pas2JS generation, in order

Each step is a supervised short-lived child or CLI code, and every one of
them is a CAP-10C1 function **called** rather than re-implemented — which is
what makes generation 1's `app.pwb` byte-identical to the pipeline's for the
same sources:

```
BeginGeneration              -> <dev>/.gen.tmp/dist[/assets]     (C2, unchanged)
fingerprint(before)
pas2js @<cfg> -Fu<sdk pas2js> -o<tmp>/dist/assets/app.js <src>/<ident>app.lpr
AssemblePas2jsDist(frontend, <tmp>/dist)                          (C1, unchanged)
fingerprint(after) <> before -> discard, retry                    (bounded)
pwebbundle <tmp>/dist <tmp>/app.pwb                               (frozen CAP-6)
TrimGeneration -> PublishGeneration(N)                            (ONE rename)
```

The compiler writes **straight into** the generation under construction.
React needs a copy because `vite --watch` owns `frontend/dist` and may be
writing it; Pas2JS has no concurrent writer, so the generation *is* the
output directory and the consistency question moves from "did `dist` move
while I copied it" to "did the inputs move while I compiled and assembled".

A compile error forwards the compiler's own output (prefixed `pas2js: `, ANSI
stripped), discards the generation, does **not** advance the counter, keeps
the previous generation live and lets the loop continue.

---

## 6b. The units

| unit | role |
|---|---|
| `pweb.cli.dev` | the loop: prerequisites, the supervised threads, the change watch, the pack, the publish, the ladder, the exits — and the **only** unit of the dev loop that runs a child |
| `pweb.cli.devlayout` | the development layout, the generation, the publish-by-rename and the bounded cleanup — a pure plan plus file operations, no spawn |
| `pweb.cli.devinputs` | the Pas2JS input set, the bounded content-fingerprint walk and its typed refusals — a pure plan plus file operations, no spawn, and it reaches no webview unit, no process unit and no pipeline unit |
| `pweb.webview.devhost` | the swapping store, the `--pweb-dev-root=` parse and refusal, the poller, the reload, the one acknowledgement line |
| `pweb.webview.devconsole` | the console surface (§7b): the page shim, the eight levels, the three bounds, the wire decode, the sanitiser and the writer thread |

`pweb.cli.devlayout`, `pweb.cli.devinputs` and `pweb.webview.devhost` carry
**zero** platform conditionals and zero environment reads: the target arrives
as `(TPWebCliOs, TPWebCliArch)` and every branch is ordinary runtime code, so
the whole four-target layout can be asserted from any single target — the
CAP-10C1 property, kept. `pweb.cli.dev` is the same, and none of the four is
on the CAP-7F divergence allowlist.

**No platform file-watch API exists anywhere in this repository.** Polling
was ratified at the CAP-10C3 checkpoint over `ReadDirectoryChangesW`,
`inotify` and `FSEvents`/`kqueue`, because three native APIs would be three
bodies in `pweb.cli.platform`, three semantics and three ways for one loop to
behave differently on four targets — for an input set of five files.
`test/cap10c3/check_cap10c3_contracts.ps1` sweeps `src/` and `tools/` for
those identifiers as code, so the decision cannot be quietly reopened.

Everything beneath them is CAP-10C1's, unchanged and re-measured:
`pweb.cli.sdkroot`, `pweb.cli.toolset`, `pweb.cli.stage`,
`pweb.cli.frontend`, `pweb.cli.pack`, `pweb.cli.native` and
`pweb.cli.layout`. `pweb.cli.native` gained one additive function,
`PWebCliFpcDevCommand`, over a shared private builder, and the release
function's output is re-measured unchanged (`pipeline_digest`) to prove it.
The dev vector is the release vector **in development mode**, which is
exactly two differences and no others:

| | | |
|---|---|---|
| `+` | `-dPWEB_DEV` | the mode, selected by the compiler and by nothing else |
| `−` | `-B` | a release must be a function of its sources alone and rebuilds everything (`build_deterministic` measures that over two real runs). A development compile runs on **every** `pweb dev` start into unit and object directories no release build reads, and the define never varies inside them — so there is nothing for a full rebuild to protect against, and minutes for it to cost before a window can open. |

---

## 7. Supervision — one ladder, over two long-lived children or one

`PWebCliExecute` runs one child to completion, so each long-lived member gets
a thread of its own; the engine is re-entrant (no unit-level mutable state,
the Windows spawn restricts inheritance with
`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, the POSIX spawn touches no heap between
`fork` and `execve` and closes every descriptor above 2), which is what makes
two concurrent supervised children legal without the engine moving.

```
main thread                         watcher thread          host thread
prerequisites
start watcher                    -> PWebCliExecute(vite --watch)
wait sentinel; pack gen-1
start host                                            -> PWebCliExecute(host)
loop: sentinel -> pack -> publish -> read `generation N loaded`
```

**A Pas2JS session has ONE long-lived member.** There is no watcher child to
supervise, so the watcher slot is simply empty; the stop flag, the
`StopCheck`, the CAP-10C0 ladder, the join, the drain and the exit categories
are the same code reached with one member instead of two. That is not a
second ladder and not a second supervisor — it is the same one over a smaller
set, and the detector is a loop on the main thread rather than a process, so
a Pas2JS session has nothing to leave behind.

```
main thread                                          host thread
prerequisites (toolchain + the dev compile)
scan the input set; compile + assemble + pack gen-1
start host                                       -> the dev binary
loop: fingerprint -> pas2js -> assembly -> pack -> publish -> ack
```

**One stop flag** — set by the console / signal handler
(`PWebCliStopRequested`), by the host exiting, by the watcher exiting where
there is one, or by an internal failure — is the `StopCheck` of **every**
long-lived execution, so one request runs the CAP-10C0 ladders (graceful
`WM_CLOSE` / `SIGTERM` to the group, then forced, then drained by membership)
concurrently and inside the CAP-10C0 bounds. There is no second ladder
anywhere in the dev loop.

Output is serialised through one critical section, prefixed `vite: `,
`pas2js: `, `app: ` or `pack: `, with **ANSI stripped** — measured necessary,
because Vite colours its output whenever the inherited environment enables it
and the supervisor injects nothing to stop it.

A tool's own forwarded bytes are the tool's: `pas2js` names the RTL sources
it compiled by absolute path, and the supervisor injects nothing to stop it.
The "no absolute path" claim is about the lines **this CLI** writes, which is
exactly the scope `pwebpipe`'s header already records for a build.

### Failure semantics

| event | result |
|---|---|
| the host exits 0 by itself | the loop stops, exit 0 |
| the host exits any other way | the loop stops, **exit 5**, the real typed status |
| the watcher exits at all (react) | the loop stops, **exit 5**, the real typed status |
| a build or a pack child fails | **the loop does not stop** — the previous generation stays live and the error is forwarded |
| the input set becomes unwalkable mid-session (pas2js) | **the loop does not stop** — it is reported once and the previous generation stays live. At start-up the same fact is a refusal, exit 3 |
| a descendant survives the drain | exit 6, whatever the members' own statuses were |

**CAP-14A changed nothing here and measured all of it.** A document the native
CSP would not run makes the pack child fail, which is the fourth row above:
the generation is **not** published, the previous generation stays live, the
bundler's typed cause (`bundle_inline_script` and its five siblings) is
forwarded with the `pack: ` prefix, and the loop keeps running until the
document is fixed — at which point the next generation publishes normally. At
start-up the same failure is a start-up stage failure and `dev` exits 5. The
rule is [pipeline-contract.md](pipeline-contract.md) §3;
`test/cap14a/run_cap14a_gates.ps1` drives a real session on a real generated
project and pins the host pid across the refusal, because "the previous
generation stays live" and "the host was restarted with the previous
generation" look identical from the outside.

"It died" and "we stopped it" are told apart at the one instant they can be:
each supervisor thread records whether anybody had asked the set to stop
**before** it sets the flag itself.

---

## 7b. The console surface (CAP-14B)

A frontend under `pweb dev` used to have no voice: every `console.*` call,
every uncaught throw and every unhandled rejection died inside the engine
while the supervisor forwarded the host's own lines and nothing else. Since
CAP-14B the **development host** — and only the development host — carries a
console channel, and its lines reach the supervisor through the CAP-10C0
engine like any other host line.

```
app: <prefix>: console <level>: <text>
app: <prefix>: console <level> @<source>:<line>:<col>: <text>
app: <prefix>: console dropped: <n> (page)
app: <prefix>: console dropped: <n> (host)
app: <prefix>: console armed
app: <prefix>: console unavailable: <cause>
```

**Eight levels, and no others** — `log,info,warn,error,debug,uncaught,rejection,dropped`.
The first five are console methods, mapped by a fixed table with `log` as the
default, so a method whose name is not its level (`trace`, `table`, `dir`,
`assert`) is named in the text instead. `uncaught` is `window.onerror` and
`rejection` is `unhandledrejection`; both carry the position the engine gave.
A record naming any other level is **dropped and counted**, never printed.

### The mechanism, one on four targets

A dev-only document-start user script through `webview_init`, delivering
through one dev-only `webview_bind` channel. It is a **one-way diagnostic
sink**: it carries no method, no arguments and no result, it reaches no
service — `pweb.webview.devconsole`'s unit list is closed and names no rpc
unit, no scheduler, no bridge and no capability policy — and the only effect
of a message is one bounded line on the host's stderr.

The three engine-native alternatives were **measured and refused**, and the
measurements are in the unit's own header: WebKitGTK's
`enable-write-console-messages-to-stdout` (no position for a rejection,
written by the web process, unbounded, and it lands on the stream the
acknowledgement protocol is read from), WebKitGTK's `console-message-sent`
(reachable only from a web-process extension library), and WebView2's
DevTools protocol (`Runtime.consoleAPICalled` hands the native side
`RemoteObject` previews to interpret, and the pinned `ICoreWebView2` vtables
live in a release-linked unit). WKWebView has no public console API at all,
so the shim is the only route there — and one mechanism everywhere is one
line shape, one bound and one gate.

### It is a development binary and nothing else

`pweb.webview.devconsole` is selected by `pweb.webview.devhost` and by
nothing else, and the ONE thing the shared host contributes — a proc type, an
option field and one call between the invocation bind and the first
navigation — is inside `{$ifdef PWEB_DEV}`. So a release compile sees an
identical token stream, and **the release host's emitted object is
byte-identical to one built from the pre-shard sources**, measured rather
than asserted. `test/cap10c2` adds the console unit to its release-unit
listing and `__pweb_dev_console` to its release byte scan.

### Bounded three times, and it says so

A page loop issuing 10 000 `console.log` calls was **measured at 59 ms** —
about 170 000 lines a second — so nothing downstream survives it unbounded.

- **In the page**: at most `PWEB_DEV_CONSOLE_MAX_BATCH` records every
  `PWEB_DEV_CONSOLE_FLUSH_MS`, over a pending queue of
  `PWEB_DEV_CONSOLE_MAX_PENDING`. Overflow drops, counts, and the count
  travels as a `dropped` record.
- **On the wire**: `PWEB_DEV_CONSOLE_MAX_PAYLOAD` base64 bytes per call,
  refused before a decode is attempted.
- **In the host**: `PWEB_DEV_CONSOLE_MAX_BATCHES` queued batches — the
  authoritative bound, because a page can call the binding directly and skip
  its own.

The GUI thread never writes to a pipe: the callback decodes, enqueues
non-blocking and returns, and one writer thread emits whole lines with a
single write to stderr.

### What a page cannot do

- **It cannot forge the acknowledgement.** `PWebCliDevParseAck` matches
  `: generation <N> loaded` anywhere in a line, so two independent barriers
  close it: the channel writes to **stderr**, and `pweb.cli.dev` parses the
  acknowledgement on **stdout** only.
- **It cannot produce a second line.** LF frames records, so an embedded one
  splits the record and the tail — carrying no separators — is refused; and
  every remaining byte below `$20` is replaced natively.
- **It cannot be interpreted.** One binding call carries base64 of a batch;
  the native side decodes, splits on two separators, looks the level up in
  the fixed table and sanitises. No general parser meets page bytes. The ONE
  digit it reads is a `dropped` count, and the `(page)`/`(host)` attribution
  beside it is written natively.
- **It cannot reach a service, or exist in a release.** Both are measured:
  the unit list, and the release binary's own bytes.

## 8. Exit codes

The CAP-10C0 mapping, with the two additions this shard ratifies.

| code | meaning |
|---|---|
| 0 | the loop stopped cleanly — a stop request, or the developer closed the window and the application exited 0 |
| 2 | usage |
| 3 | the project was refused, or its declared `ui` is one this build's dev loop does not implement (`dev_ui_unsupported`) |
| 4 | the machine cannot build it: the doctor refused, a tool is missing, unrunnable or the wrong target; or supervision could not be established |
| 5 | a start-up stage's child failed, or the **supervised set** failed — the application died, or the watcher exited |
| 6 | an invariant of the dev loop itself broke |

Human text never changes the category, and the category comes from the typed
outcomes rather than from anything a child printed.

---

## 9. The bounds

Stated once in `tools/pweb/pweb.cli.toolchain.pas` (and `PWEB_DEV_POLL_MS` in
`src/webview/pweb.webview.devhost.pas`); this table is cross-checked against
the constants by `test/cap10c2/check_cap10c2_contracts.ps1`.

| constant | value |
|---|---|
| `PWEB_CLI_DEV_DEBOUNCE_MS` | 250 |
| `PWEB_CLI_DEV_DEBOUNCE_MAX_MS` | 5000 |
| `PWEB_CLI_DEV_SENTINEL_POLL_MS` | 60 |
| `PWEB_CLI_DEV_FIRST_BUILD_MS` | 300000 |
| `PWEB_CLI_DEV_ACK_MS` | 30000 |
| `PWEB_CLI_DEV_SNAPSHOT_TRIES` | 5 |
| `PWEB_CLI_DEV_KEEP_GENERATIONS` | 3 |
| `PWEB_CLI_DEV_MAX_GENERATIONS` | 100000 |
| `PWEB_CLI_DEV_JOIN_MS` | 30000 |
| `PWEB_CLI_DEV_SMALL_FILE_MAX` | 4096 |
| `PWEB_DEV_POLL_MS` | 120 |

CAP-10C3 adds five, all of them limits on the Pas2JS input-set walk — a walk
this loop repeats forever, which is why it does not borrow the CAP-10C1
pipeline's bounds:

| constant | value |
|---|---|
| `PWEB_CLI_DEV_POLL_MS` | 250 |
| `PWEB_CLI_DEV_MAX_INPUT_FILES` | 512 |
| `PWEB_CLI_DEV_MAX_INPUT_DEPTH` | 16 |
| `PWEB_CLI_DEV_INPUT_FILE_MAX` | 4194304 |
| `PWEB_CLI_DEV_INPUT_PATH_MAX` | 512 |

CAP-14B adds nine, all of them bounds on the console surface, all of them in
`src/webview/pweb.webview.devconsole.pas`, and each sized from the measured
170 000 lines a second a page can produce:

| constant | value |
|---|---|
| `PWEB_DEV_CONSOLE_MAX_TEXT` | 1024 |
| `PWEB_DEV_CONSOLE_MAX_ORIGIN` | 512 |
| `PWEB_DEV_CONSOLE_MAX_METHOD` | 32 |
| `PWEB_DEV_CONSOLE_MAX_BATCH` | 32 |
| `PWEB_DEV_CONSOLE_FLUSH_MS` | 50 |
| `PWEB_DEV_CONSOLE_MAX_PENDING` | 256 |
| `PWEB_DEV_CONSOLE_MAX_PAYLOAD` | 98304 |
| `PWEB_DEV_CONSOLE_MAX_BATCHES` | 64 |
| `PWEB_DEV_CONSOLE_LINE_MAX` | 3072 |

`PWEB_DEV_CONSOLE_LINE_MAX` is deliberately 1024 bytes under the
supervisor's own `PWEB_CLI_RUN_LINE_MAX` of 4096, which is the room the
`app: ` prefix it prepends and the ` [truncated]` marker it may append need.

The start-up stages reuse the CAP-10C1 bounds unchanged
(`PWEB_CLI_PIPE_NPM_MS`, `_TSC_MS`, `_BUILD_MS`, `_PACK_MS`, `_FPC_MS`), and
the Pas2JS generation compile is bounded by `PWEB_CLI_PIPE_BUILD_MS` — the
same bound the pipeline's own `build` stage uses, because it is the same
compile.

---

## 10. The project-mutation set

**Unchanged from CAP-10C1.** A development session writes in exactly the four
ratified places:

```
<root>/frontend/.pweb/          the staged SDK, the sentinel, the install record
<root>/frontend/node_modules/   npm ci
<root>/frontend/dist/           vite build --watch
<root>/<output>/                the dev layout and every generation
```

A **Pas2JS** session writes in exactly one of them, `<root>/<output>/`: the
first three are React's, and the compiler is given an output path inside the
generation under construction rather than inside the frontend. The set is
unchanged rather than narrowed, because it is one ratified set for one
command and a per-UI set would be a second rule to keep in step.

Everything else in the project is read-only, and that is measured rather than
asserted: the tree minus those four prefixes is digested before the first
stage and after every start-up stage, and any change stops the loop with
`dev_mutation` (exit 6). Nothing outside the project root is written.

---

## 11. What the dev loop does not do

It writes nothing into the release layout `pweb build` owns; starts no
listener, development server, proxy or HMR
transport; proxies no HTTP through the host; makes the **production** host
accept no development argument, path or environment variable and link no
development unit; adds no folder-served asset path and no watcher to it;
adds no platform file-watch API, in `pweb.cli.platform` or anywhere else;
watches or reads nothing outside the project root, and follows no symlink or
reparse point inside the input set; writes nothing into
`<output>/<os>-<arch>/release/`; lets `pweb run` resolve nothing under
`dev/`; lets no frontend file select a security policy, a CSP, an origin or a
mode; publishes no generation packed from a `dist/` the watcher may have been
writing, nor one whose inputs moved across its own compile and assembly; and
calls no `location.reload()` and injects no JavaScript **to switch a
generation** — the switch is a native re-navigation and always was.

**CAP-14B amended exactly one clause of that list, and only that one.** The
development host injects one document-start script: the console shim of §7b.
It switches no generation, reaches no service, is selected by the development
composition alone, and exists in no release binary — which is measured three
ways (the release unit listing, a byte scan of the release executable for
`__pweb_dev_console`, and the release host's emitted object compared against
one built from the pre-shard sources). The **release** host still injects no
JavaScript at all.

Each of those is a property of what these units do not link or do not write,
and each is measured rather than promised.

---

## 12. What CAP-10D inherits, and what it must not touch

CAP-10C is **closed**
([cap10c-closure-artifact.md](../_bmad-output/implementation-artifacts/cap10c-closure-artifact.md)).
`pweb dev` implements both ratified frontend kinds, and the question §12 used
to hold — Pas2JS's missing completion signal — is answered in §5b.

**CAP-10D inherits verbatim** and may not renegotiate: the CAP-10C1 ten
stages, their bounds and the Pas2JS assembly; the CAP-10C0 run layout, its
resolver and its exit mapping; the release layout per platform; the ratified
project-mutation set; the supervision engine and its one ladder; and this
document's generation rule, publish-by-rename, poller, acknowledgement and
dev/release separation.

**CAP-10D owns** the public `build` grammar — `build` is still an unknown
command and exits 2 — together with the CAP-13 profiles, the Linux release,
the macOS bundle identity and signing posture, and how `pweb` plus
`share/pweb` are packaged for distribution.

**CAP-10D must not touch** the dev loop, the dev host, the change detector,
the seam, `PWEB_NATIVE_CSP`, the privileged origin, `pweb.json` schema 1, the
seven frozen interfaces, the adapters or any dependency pin.
