# The development-loop contract (CAP-10C2)

`pweb dev` is the React development loop: it runs the CAP-10C1 prerequisites,
compiles a **separate** native development host, supervises `vite build
--watch` and that host concurrently through the one CAP-10C0 engine, and on
every completed rebuild packs an immutable **generation** with the frozen
CAP-6 bundler and publishes it by one directory rename. The running host
swaps its asset store and re-navigates to `pweb://app`.

Everything here is a **contract**. The human report may be reworded freely;
the command grammar, the layout, the generation rule, the acknowledgement
line, the bounds and the exit codes may not, except by a version bump.

---

## 1. The command

```
pweb dev [--project <path>]
pweb dev --help
```

`dev` takes `--project` and `--help` and nothing else. Every other refusal is
an existing CAP-10A cause — `option_not_for_command`, `duplicate_option`,
`extra_positional`, `unknown_option` — and this shard adds no usage code.
Nothing typed after `dev` reaches the application: the development host
receives exactly one argument, and that argument is the CLI's own.

**`ui = react` only in this build.** A `pas2js` project is refused with the
**project** cause `dev_ui_unsupported` and exit 3, before anything is
resolved, started or written. The command line was well formed and the
destination is a real project; what this build does not implement is the
declared frontend kind, which is a project fact rather than a usage one.

**`build` is still an unknown command** and exits 2. Linking the lifecycle
pipeline into the executable is not advertising a build.

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

## 6. Start-up stages

| stage | when | why |
|---|---|---|
| open + toolchain | every start | the CAP-10C1 rule verbatim, doctor verdict included — refuse before any write |
| `stage_sdk` | every start | C1 refuses a stale staged SDK; skipping it would compile against yesterday's runtime |
| `npm ci` | **conditionally** | absent `node_modules`, an absent or unreadable install record, a `package-lock.json` digest differing from it, or an unresolvable `vite` / `tsc` entry point; otherwise skipped. The record is `<frontend>/.pweb/dev/install-lock.sha256`, written only **after** a successful install. No new option |
| `tsc` | once, at start | Vite does not typecheck, and a typecheck per keystroke would cost seconds per generation; a type error is a start-up refusal |
| native dev compile | every start | bounded, units cached under `<dev>/units` |
| first generation | before the host | the watcher's own initial build; the host never opens on an empty store |

**Exactly one stage may reach the network, and it is the same one the
pipeline names**: `node <npm-cli.js> ci --no-audit --no-fund
--ignore-scripts`, with the same ratifications
([pipeline-contract.md](pipeline-contract.md) §5) and the same
`registry_override_present` refusal.

---

## 6b. The units

| unit | role |
|---|---|
| `pweb.cli.dev` | the loop: prerequisites, the two supervised threads, the sentinel watch, the pack, the publish, the ladder, the exits — and the **only** unit of the dev loop that runs a child |
| `pweb.cli.devlayout` | the development layout, the generation, the publish-by-rename and the bounded cleanup — a pure plan plus file operations, no spawn |
| `pweb.webview.devhost` | the swapping store, the `--pweb-dev-root=` parse and refusal, the poller, the reload, the one acknowledgement line |

`pweb.cli.devlayout` and `pweb.webview.devhost` carry **zero** platform
conditionals and zero environment reads: the target arrives as
`(TPWebCliOs, TPWebCliArch)` and every branch is ordinary runtime code, so
the whole four-target layout can be asserted from any single target — the
CAP-10C1 property, kept. `pweb.cli.dev` is the same, and none of the three is
on the CAP-7F divergence allowlist.

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

## 7. Supervision — two long-lived children, one ladder

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

**One stop flag** — set by the console / signal handler
(`PWebCliStopRequested`), by the host exiting, by the watcher exiting, or by
an internal failure — is the `StopCheck` of **both** long-lived executions, so
one request runs both CAP-10C0 ladders (graceful `WM_CLOSE` / `SIGTERM` to the
group, then forced, then drained by membership) concurrently and inside the
CAP-10C0 bounds. There is no second ladder anywhere in the dev loop.

Output is serialised through one critical section, prefixed `vite: `, `app: `
or `pack: `, with **ANSI stripped** — measured necessary, because Vite colours
its output whenever the inherited environment enables it and the supervisor
injects nothing to stop it.

### Failure semantics

| event | result |
|---|---|
| the host exits 0 by itself | the loop stops, exit 0 |
| the host exits any other way | the loop stops, **exit 5**, the real typed status |
| the watcher exits at all | the loop stops, **exit 5**, the real typed status |
| a build or a pack child fails | **the loop does not stop** — the previous generation stays live and the error is forwarded |
| a descendant survives the drain | exit 6, whatever the members' own statuses were |

"It died" and "we stopped it" are told apart at the one instant they can be:
each supervisor thread records whether anybody had asked the set to stop
**before** it sets the flag itself.

---

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

The start-up stages reuse the CAP-10C1 bounds unchanged
(`PWEB_CLI_PIPE_NPM_MS`, `_TSC_MS`, `_PACK_MS`, `_FPC_MS`).

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

Everything else in the project is read-only, and that is measured rather than
asserted: the tree minus those four prefixes is digested before the first
stage and after every start-up stage, and any change stops the loop with
`dev_mutation` (exit 6). Nothing outside the project root is written.

---

## 11. What the dev loop does not do

It exposes no `build`; starts no listener, development server, proxy or HMR
transport; proxies no HTTP through the host; makes the **production** host
accept no development argument, path or environment variable and link no
development unit; adds no folder-served asset path and no watcher to it;
writes nothing into `<output>/<os>-<arch>/release/`; lets `pweb run` resolve
nothing under `dev/`; lets no frontend file select a security policy, a CSP,
an origin or a mode; publishes no generation packed from a `dist/` the watcher
may have been writing; and injects no JavaScript and calls no
`location.reload()` to switch one.

Each of those is a property of what these units do not link or do not write,
and each is measured rather than promised.

---

## 12. Pas2JS, and what CAP-10C3 will need

`ui = pas2js` is refused with `dev_ui_unsupported`. The Pas2JS loop is
rebuild-and-reload by the same ratified model and needs no WebSocket at all;
what it does not yet have is a completion signal, because the Pas2JS compiler
has no `writeBundle` and the CAP-10C1 assembly step runs in the CLI rather
than in the build. CAP-10C3 owns that question. Everything else in this
document — the layout, the generation rule, the publish-by-rename, the poller,
the acknowledgement, the ladder and the exit mapping — is frontend-agnostic
and is what CAP-10C3 inherits.
