# The child-process supervision contract (CAP-10C0)

The `pweb` CLI runs child processes through **one** execution engine,
`tools/pweb/pweb.cli.process.pas`, over the raw platform primitives in
`tools/pweb/pweb.cli.platform.pas`. `pweb doctor` (CAP-10A) probes tools
through it, `pweb run` (CAP-10C0) supervises the built application through
it, and `pweb dev` (CAP-10C1/C2) and `pweb build` (CAP-10D) will run their
toolchains through it. There is no second execution path, and this document
is the contract every caller gets.

## 1. What a spawn is

A spawn is `(exact executable path, argument vector, explicit working
directory)`, and nothing else:

- **No shell.** No `cmd.exe /c`, no `/bin/sh -c`, no `system()`, no `popen`,
  no command string anywhere. On Windows the command line handed to
  `CreateProcessW` is built by exactly one function,
  `PWebCliWindowsCommandLine`, implementing the C runtime's parsing rules in
  reverse (an argument is quoted when empty or when it carries a space, tab
  or quote; `N` backslashes before a quote become `2N+1` backslashes and an
  escaped quote; `N` backslashes at the end of a quoted argument become
  `2N`; every other backslash is literal). The rule is proven by a golden
  table on all four targets and by a round trip against a child that echoes
  its argv on Windows.
- **Refused before creation:** an empty path; an argument or path carrying
  a NUL or not strict UTF-8; an executable whose final extension is `.cmd`
  or `.bat`, on every platform - a batch file is interpreted by a shell and
  is therefore never run at all.
- **Explicit working directory**, always. A probe runs in the tool's own
  directory; `pweb run` runs the application in the executable's directory.
  The directory `pweb` was started from is read once, at startup, and never
  becomes a child's working directory.
- **stdin** is `NUL` / `/dev/null`. **stdout and stderr** are pipes to the
  supervisor, drained together on every pass: a child that fills one while
  the supervisor waits on the other cannot deadlock it.
- **Handle / descriptor hygiene.** Windows: inheritance is restricted to the
  three stdio handles through `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`. POSIX:
  the supervisor's read ends and the exec-status pipe are close-on-exec.
- **Environment: inherited unchanged.** The supervisor injects nothing - no
  `PWEB_*` variable, no mode flag - and reads no `.env`. This is safe only
  because the runtime consults the environment for no security decision;
  `test/cap10c0/check_cap10c0_contracts.ps1` limits every environment read
  under `src/security`, `src/rpc`, `src/webview` and `src/assets` to the
  host's `PWEB_SMOKE_AUTOCLOSE_MS` auto-close bound.

## 2. Tree ownership

| platform | mechanism |
|---|---|
| Windows | the child is created suspended, placed in a fresh Job Object carrying `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resumed; every descendant is a job member; the tree dies with the supervisor's last handle whether it exits, crashes or is killed. Created with `CREATE_NEW_PROCESS_GROUP`, so a terminal's Ctrl+C reaches the supervisor and not the application. |
| Linux, macOS | `fork` + `setpgid(0,0)` + `execve`; the child leads a process group of its own and the group is what `SIGTERM` and `SIGKILL` are sent to. Exec failure travels back through a close-on-exec pipe and is a typed spawn failure, never an exit code that looks like the application's. Linux additionally sets `PR_SET_PDEATHSIG(SIGKILL)` on the direct child. |

Measured on the dev host before the shard was planned: six WebView2
processes spawned by a generated host were inside the job, the six unrelated
Evergreen processes on the machine were not, and the job was empty 254 ms
after the host exited.

## 3. Outcomes

Every execution ends in exactly one typed outcome:

| outcome | meaning |
|---|---|
| `spawn_refused` | refused before anything was created (see 1) |
| `spawn_failed` | the platform could not start it: pipes, Job Object, `CreateProcessW`/`fork`, exec, working directory |
| `exited` | exited by itself; `ExitCode` is exact - `WEXITSTATUS` on POSIX, never the raw wait status; the process exit code on Windows |
| `signaled` | POSIX: died by a signal; `Signal` is set |
| `forced` | the supervisor had to terminate the tree after the grace interval |
| `unreaped` | terminated but not reaped inside the forced bound - an invariant failure, reported rather than waited on |

A death by signal and a forced termination are never reported as an exit
code, and neither can ever read as `0`.

## 4. The two profiles

**probe** (CAP-10A, unchanged): both streams captured up to
`PWEB_CLI_PROBE_MAX_BYTES` each and read-and-discarded past it; the bound
expiring means the tool is broken and the tree is terminated at once.

**supervise** (CAP-10C0): both streams forwarded line by line through a
sink, each line re-terminated with one LF and cut at `PWEB_CLI_RUN_LINE_MAX`
with the remainder discarded and the line marked; the last
`PWEB_CLI_RUN_DIAG_MAX` bytes of stderr retained for the exit report. A stop
request - Ctrl+C / Ctrl+Break on Windows, `SIGINT` / `SIGTERM` / `SIGHUP` on
POSIX, or an optional bound - starts the escalation ladder:

1. **graceful**: Windows posts `WM_CLOSE` to every *visible* top-level window
   owned by the child pid (re-posted every `PWEB_CLI_RUN_STOP_RETRY_MS` while
   none exists yet); POSIX sends `SIGTERM` to the group;
2. after `PWEB_CLI_RUN_GRACE_MS` without an exit: **forced** -
   `TerminateJobObject` / `SIGKILL` to the group;
3. after `PWEB_CLI_RUN_KILL_MS` without a reap: `unreaped`.

Both intervals are measured into the result (`StopToExitMs`,
`KillToReapMs`).

## 5. The descendant drain

After the child is gone, whatever it left is enumerated **by membership** -
the Job Object's pid list, or every process whose pgid is the group - through
the platform seam; never by name, never by command line. Members are given
the grace interval (POSIX: `SIGTERM` to the group; Windows: nothing to send,
browser trees unwind by themselves), then the tree is terminated and
re-enumerated for up to `PWEB_CLI_RUN_DRAIN_PASSES` passes at
`PWEB_CLI_RUN_DRAIN_POLL_MS`. Every member seen is recorded with pid, parent
pid, image path and whether it went gracefully or was forced. The image path
is an **annotation** (it is compared against the application directory on a
component boundary, and an unreadable path is recorded as empty and never
treated as matching); it is never how a process is selected. Path-only
selection would kill an unrelated instance of the same application the user
launched by hand.

The drain is written over injectable verbs and its churn cases - a member
that vanishes between passes, a member that appears after the first pass, a
survivor at the pass bound - are proven against injected records in
`test/cap10c0/pweb.test.supervise.pas`, the way
`test/cap6b3/check_wv2procdrain.ps1` proves the CI teardown helper this
design descends from. The two are a documented duplication of one rule in
two languages.

## 6. The bounds

Stated once in `tools/pweb/pweb.cli.toolchain.pas`; this table is
cross-checked against the constants by `check_cap10c0_contracts.ps1`.

| constant | value |
|---|---|
| `PWEB_CLI_RUN_GRACE_MS` | 5000 |
| `PWEB_CLI_RUN_KILL_MS` | 3000 |
| `PWEB_CLI_RUN_STOP_RETRY_MS` | 250 |
| `PWEB_CLI_RUN_LINE_MAX` | 4096 |
| `PWEB_CLI_RUN_DIAG_MAX` | 65536 |
| `PWEB_CLI_RUN_DRAIN_PASSES` | 20 |
| `PWEB_CLI_RUN_DRAIN_POLL_MS` | 250 |
| `PWEB_CLI_PROBE_TIMEOUT_MS` | 15000 |
| `PWEB_CLI_PROBE_MAX_BYTES` | 65536 |

## 7. The supervisor's own signals

`pweb run` installs a stop handler before it spawns: on Windows it re-enables
Ctrl+C for itself (a parent may have created it in a new process group) and
handles `CTRL_C`, `CTRL_BREAK` and `CTRL_CLOSE`; on POSIX it handles
`SIGINT`, `SIGTERM` and `SIGHUP` and ignores `SIGPIPE` so a closed
forwarding target is an error the engine sees rather than a signal that kills
the supervisor under a running tree. Every one of them becomes the graceful
stop of section 4, and the supervisor exits with the ratified category once
the tree is gone.

Known, recorded: a Ctrl+Break typed at a real Windows console also reaches
the application (Windows never disables Ctrl+Break for a new group) and ends
it through the C runtime's default handler rather than gracefully. On macOS
a supervisor ended by `SIGKILL` cannot forward anything and the application
outlives it; `SIGTERM`, `SIGINT` and `SIGHUP` are forwarded. Linux covers the
direct child through `PR_SET_PDEATHSIG`; Windows covers the whole tree
through `KILL_ON_JOB_CLOSE`.

## 8. The graceful stop of a generated host

Windows: the upstream webview backend already turns `WM_CLOSE` into
`webview_terminate`, so the host runs its normal teardown. Linux and macOS:
CAP-10C0 added one POSIX-only helper to the reusable host
(`src/webview/pweb.webview.host.pas`): `SIGTERM` / `SIGINT` / `SIGHUP` write
one byte to a self-pipe from the signal handler, and a dedicated thread
performs the **same** `webview_dispatch(PWebHostTerminate)` the auto-close
thread performs. The teardown after `webview_run` - binding closed,
scheduler drained, guard detached, handler detached, webview destroyed - is
untouched, and the contract gate pins that order in the source. The helper
exists exactly while `webview_run` does: it is installed last before it and
removed first after it, with the default dispositions restored.

Known, recorded: while the host's auto-close smoke bound
(`PWEB_SMOKE_AUTOCLOSE_MS`, or the `--pweb-autoclose-ms` argument) is armed,
the closer thread sleeps for the whole bound and the teardown joins it, so a
stop requested meanwhile completes only when the bound expires. That knob is
a test bound and `pweb run` never arms it; the CAP-10C0 stop-signal drivers
run without it.
