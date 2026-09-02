# CAP-10C0 — Final Artifact: one child-process supervision engine, and the public `pweb run`

CAP-10C0 closes on hosted run **33625058683** (2026-09-02, commit
`28349ef4bd8e42629512f33e606ebef29aa0a09f`, branch
`phase/cap-10/c0-run-supervision`, baseline `795e075`): all six jobs green on
the **first attempt**, no step re-run, `cap7 aggregate` recording
`supervision_corpus: PASS` and `run_corpus: PASS` on every target, ONE
`supervision_digest`
`120f6769c155c59b8bc0cbc8b96e7faee14091628a5af49833f5b4fb96db11c0` — 58
decisions — equal on windows-x86_64, linux-x86_64, macos-x86_64 and
macos-arm64, and `CalculatorService.Add(20, 22) = 42` reached through the
real `pweb run` on the built React project and on the built Pas2JS project on
all four — from an unrelated working directory, with zero listeners, zero
tool processes, zero connections, and zero descendants left after exit.

**Why the closure run is the fifth.** The first (33612547645, `af4b8b0`)
fell on a Linux guard because `build_cap10c0.sh` had been committed 100644
from the Windows checkout, and on three CAP-10B0 legs because the runner's
FPC `windows` unit declares no `PSIZE_T` and three closed-shard gates still
pinned `run` as an unknown command. The second (`63e5176`) carried the review
patches and was cancelled once the third (`82a3906`) fixed those gates; its
Linux and macOS arm64 legs then fell on the staged-tree digest, because
`Get-Item` on Unix refuses a dot file without `-Force` (fixed in `a5575bf`
by reading the files through .NET). The fourth (33622404228, `a5575bf`)
proved the whole engine on every target and fell only on the two stop
drivers on Linux and macOS: a generated host's stdout is block-buffered on a
POSIX pipe until exit, so the `demo: ready` line the drivers waited for could
not arrive while the host lived (ledgered). The drivers now arm on the pid
`pweb` names. Its Windows leg fell upstream on the CAP-6 release smoke's
"no report received" timing observation — a closed shard's own host, not
touched by this change, and green on the runs before and after.

`pweb --help` advertises `create doctor run`. `dev` and `build` are still
unknown commands.

## The claim this shard exists to make

**One execution path.** `pweb doctor` probes tools and `pweb run` supervises
an application through the same engine, `tools/pweb/pweb.cli.process.pas`,
over the same platform primitives, and `pweb dev` and `pweb build` will run
their toolchains through it. The CAP-10A probe semantics are unchanged and
re-measured: the CAP-10A probe cases D6–D9 pass against the re-based unit,
`doctor_schema_digest` is unchanged at `2dda57ba…c8fa7aa`, and FPC's
`process` and `pipes` units no longer exist in the CLI's compiled unit set —
which the contract gate now measures at the link on every leg.

| field | value | scope |
|---|---|---|
| `supervision_digest` | `120f6769c155c59b8bc0cbc8b96e7faee14091628a5af49833f5b4fb96db11c0` | four targets, 58 decisions |
| `advertised_commands` | `create,doctor,run` | absolute pin |
| `supervision_shell_used` / `global_name_kill_present` | `false` / `false` | absolute pins, measured at the link and in the source |
| `run_react_rpc_value` / `run_pas2js_rpc_value` | 42 / 42 | absolute pins |
| `run_listener_count` / `run_network_calls` / `run_tool_calls` | 0 / 0 / 0 | absolute pins, sampled live against the application pid |
| `descendants_after_exit` | 0 | absolute pin, membership report plus path-scoped re-count |
| `run_not_built` / `run_layout_link` / `run_tampered_bundle` | `exit3/not_built` / `exit3/layout_link` / `exit5/host_refused` | absolute pins carrying the category |
| `run_interrupt_clean` / `supervisor_terminated_tree_dies` | `true` / `true` | absolute pins |
| `cli_digest` | `1341221d…dfdd208` | **superseded** (was `97c7b846…d6cebbe6`), recorded below |
| `doctor_schema_digest` | `2dda57ba…c8fa7aa` | **unchanged**, re-measured |

## What shipped

```
  tools/pweb/pweb.cli.process.pas   the ONE engine: refusals, drain loop,
                                    escalation, outcomes, descendant drain
  tools/pweb/pweb.cli.run.pas       the run-mode layout rule and the launch
  tools/pweb/pweb.cli.platform.pas  CreateProcessW + Job Object; fork/execve
                                    + process group; WM_CLOSE / SIGTERM;
                                    job / pgid enumeration; stop handlers
  tools/pweb/pweb.cli.probe.pas     re-based on the engine, same signatures
  tools/pweb/pweb.cli.args.pas      pccRun
  tools/pweb/pweb.cli.report.pas    the banner and `pweb run --help`
  tools/pweb/pweb.cli.toolchain.pas the seven supervision bounds
  tools/pweb/pweb.pas               RunRun and the ratified exit mapping
  src/webview/pweb.webview.host.pas the POSIX graceful-stop helper
  docs/supervision-contract.md      the contract
  test/cap10c0/                     pwebchild, the suite, the gates
```

The production delta against the CAP-10B2 closure is nine units under
`tools/pweb/` and one unit under `src/webview/`. `git diff --name-status
795e075` reports nothing under `sdk/`, `examples/`, `deps/`,
`tools/templates/`, `src/rpc/`, `src/security/` or `src/assets/`.

## Two measurements that decided the design before it was written

**WebView2's browser processes join the Job Object.** Measured on the dev
host with a generated host placed in a job carrying
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`: the six `msedgewebview2.exe` processes
the host spawned were inside the job, the six unrelated Evergreen processes
on the machine were not, and the job was empty 254 ms after the host exited.
That is the whole tree-ownership claim on Windows, and it is what makes
membership — not the image path — the criterion for the descendant drain.

**`WM_CLOSE` is the graceful stop, and it needs no host change on Windows.**
The upstream Win32 backend turns it into `webview_terminate`
(`win32_edge.hh:557`); posted to the host's one visible top-level window it
produced `demo: clean exit`, exit 0, in 40 ms. POSIX needed one helper: a
`SIGTERM`/`SIGINT`/`SIGHUP` handler that writes one byte to a self-pipe and
a thread that performs the **same** `webview_dispatch(PWebHostTerminate)`
the auto-close thread performs. The contract gate pins that the two share
one dispatch and that the teardown order after `webview_run` is the CAP-9
order.

## The supervision engine

A spawn is (exact path, argument vector, explicit working directory). No
shell, no command string, no `.cmd`/`.bat` (refused on every platform before
anything is created), NUL or invalid UTF-8 refused, stdin from `NUL` /
`/dev/null`, both pipes read on every pass, inheritance limited to the three
stdio handles, environment inherited unchanged. Windows quotes the command
line by the msvcrt rule in one function proven by a golden table on four
targets and by an 18-argument round trip — spaces, quotes, backslash runs,
an empty argument, non-ASCII, `&`, `|`, `%PATH%`, `$HOME`, a newline and a
carriage return — against a child that echoes its argv through
`CommandLineToArgvW`.

Six typed outcomes: `spawn_refused`, `spawn_failed`, `exited` (exact:
`WEXITSTATUS`, never the raw wait status), `signaled`, `forced`, `unreaped`.
A death is never exit 0 — measured with a child that raises `SIGABRT`
against itself (typed `signaled`, signal 6, on POSIX). The escalation ladder
is graceful (5000 ms) then forced (3000 ms) then `unreaped`, with both
intervals measured into the result; a child that ignores `SIGTERM` is forced
inside the bound on every target, and a bound expiring in the probe profile
kills at once, as CAP-10A did.

The descendant drain enumerates by **membership** — the job's pid list, the
process group — and never by name; the image path is recorded, compared
against the application directory on a component boundary as an annotation,
and never a criterion. Path-only selection would kill an unrelated instance
of the same application the user launched by hand. The drain is written
over injectable verbs and its churn cases — a member vanishing between
passes, one appearing after the first, a survivor at the pass bound — are
proven against injected records, the way `check_wv2procdrain.ps1` proves the
CAP-6b3 teardown helper this design descends from. One rule, two languages,
recorded as a documented duplication.

## `pweb run`

```
<root>/<output>/<os>-<arch>/release/
  windows, linux    <ident>[.exe] + app.pwb
  macos             <ident>.app/Contents/{MacOS/<ident>, Resources/app.pwb, Info.plist}
```

Resolved by the CAP-10A confinement walk with no missing tail, so a link
on the chain (`layout_link`), a case variant (`layout_case`) and an escape
(`layout_escape`) are refused under their own causes and never read as
`not_built`. The B1/B2 proofs had assembled their releases in a work
directory rather than beneath `output`, so this is the first ratified
run-mode layout; CAP-10D produces exactly it. The gate stages the B1 and B2
releases beneath the generated projects **byte for byte** and records their
digests, so the aggregate can see `pweb run` measured the proofs' executables
and not a rebuild.

The application is launched with no argument, in its own directory, with
the supervisor's environment unchanged; stdout and stderr are forwarded
line by line; the supervisor's lines are `pweb: `-prefixed on stderr, carry
no ANSI, and name only logical paths. The exit mapping is the one ratified
at the checkpoint: 0 clean, 2 usage, 3 project or layout, 4 supervision
unavailable, 5 the application's own nonzero, signal or forced end, 6
internal. A tampered `app.pwb` is refused by the host (exit 1) and reported
as `application exited 1`, exit 5 — the category from the typed outcome,
never from the text.

## The two drivers nothing else could prove

**A stop signal reaches the application (R10).** The suite spawns the real
`pweb run` through the engine, waits for the page's ready report, and
delivers a real Ctrl+C (Windows: `CTRL_C_EVENT` to pweb's own console
through a helper that attaches to it; POSIX: `SIGINT`). pweb reports the
request, posts `WM_CLOSE` / `SIGTERM`, the host prints `demo: clean exit`,
pweb exits 0. Measured on the closure run, from signal to pweb's exit:

| target | R10 signal → exit | S11 tree gone after the supervisor ended | S11 after `SIGKILL` |
|---|---|---|---|
| windows-x86_64 | 594 ms | 266 ms (`KILL_ON_JOB_CLOSE`) | job close, same mechanism |
| linux-x86_64 | 127 ms | 129 ms (`SIGTERM` forwarded) | gone (`PR_SET_PDEATHSIG`, measured) |
| macos-x86_64 | 134 ms | 270 ms (`SIGTERM` forwarded) | not measured: no mechanism, ledgered |
| macos-arm64 | 255 ms | 146 ms (`SIGTERM` forwarded) | not measured: no mechanism, ledgered |

**A terminated supervisor takes its tree with it (S11).** `TerminateProcess`
on pweb (Windows) / `SIGTERM` (POSIX): the application pid is gone within
the bound on every target. Linux additionally proves the direct child dies
when the supervisor is `SIGKILL`ed, through `PR_SET_PDEATHSIG`; macOS after a
`SIGKILL` of the supervisor is the recorded exception (see the ledger).

**The forced and signal-death categories, through the real command.** The
fixture child stands in for a built application (`PWEBCHILD_MODE`, read only
when the vector is empty, which is how `run` starts it): told to ignore every
stop it is force-terminated after the grace interval and `pweb run` answers
5 with the forced line; told to die (SIGABRT on POSIX, exit 3 on Windows) it
is reported with its real status and `pweb run` answers 5, never 0; started
with no mode it exits 64 and the gate pins `exit5/64`.

## The adversarial review, and what it changed

All sixteen challenges were run. Two produced code changes before closure:

- **The drain's pass bound competed with its grace window.** One counter
  bounded both; at 20 passes of 250 ms the 5000 ms grace consumed every
  pass, the forced branch killed the tree and reported the survivor it had
  just ended. S10 — a grandchild `forever` under a parent that exits at
  once — caught it on Windows, where there is no window to close. The grace
  window is now time-bounded and the forced window pass-bounded from the
  kill.
- **The auto-close smoke bound delayed a requested stop.** While
  `PWEB_SMOKE_AUTOCLOSE_MS` is armed the host's closer thread sleeps for the
  whole bound and the teardown joins it, so the first R10 run saw five
  seconds of grace and a forced termination. `pweb run` never arms it; the
  drivers unset it; the limitation is ledgered for CAP-10C1.

Three independent reviewers over the diff (a blind hunter, an edge-case
hunter and a verification-gap reviewer) produced some forty-five findings,
of which fourteen became code changes and six new tests before closure, and
the rest were ledgered or rejected with the reason recorded. The ones worth
naming:

- **A POSIX stream at EOF stayed in the poll set** and answered HUP at once,
  so a child that closed its stdout but kept running would have spun the
  supervisor at full CPU and turned every drain sleep into a no-op. The seam
  now closes and forgets a descriptor the moment it reports EOF.
- **`SIGPIPE` ignored by the supervisor survived `execve`**, so the
  application was inheriting a signal table the contract said it would not.
  The forked child resets it and closes every descriptor above 2.
- **The host helper's flag could be read uninitialised**, a partial
  installation leaked its pipe, and removal reset dispositions to `SIG_DFL`
  rather than to what the embedding application had. All three fixed.
- **A member appearing after the single forced kill** was counted, marked
  and never ended; the tree is now killed on every forced pass.
- **A sink that raised unwound past a running tree**; forwarding now stops,
  the child is asked to stop, and any abnormal unwind kills a still-running
  child before release.
- **A Windows close / logoff / shutdown handler returned at once**, and
  Windows ends the process the moment such a handler returns; it now holds
  the process open, bounded, until the engine acknowledges.
- **Two evidence rows were literals**: `run_dev_allowance_present` is now the
  development-trust sweep's own verdict and `shutdown_order` the order the
  contract gate read out of the host's source.
- **Six branches had no test** — the probe's working directory and its typed
  death, the trailing fragment without a newline, a directory at the
  executable's path, the Linux `PR_SET_PDEATHSIG` guarantee, and the forced
  and signal-death categories through the real command — and have them now.

And one came from the machinery: the divergence sweep's platform-symbol
filter listed `OSWINDOWS` but none of mORMot's other OS spellings, so the
host's new `{$ifdef OSPOSIX}` regions were invisible to it. The filter now
carries them; `pweb.webview.host.pas` is re-ratified at 42 directives (was
30) and `pweb.cli.platform.pas` at 36 (was 24), both with new fingerprints.

## Superseded, and recorded as superseded

| field | before | CAP-10C0 |
|---|---|---|
| `cli_digest` | `97c7b846…d6cebbe6` | `1341221d…dfdd208` — the parser corpus records `run` as a command |
| `doctor_schema_digest` | `2dda57ba…c8fa7aa` | **unchanged** |
| divergence: `pweb.cli.platform.pas` | 24 | 36 |
| divergence: `pweb.webview.host.pas` | 30 | 42 |
| `pweb --help` | `create doctor` | `create doctor run` |

Three closed-shard gates that pinned `run` as unknown
(`run_cap10a_gates.ps1`, `check_cap10b0_contracts.ps1`,
`check_cap10b1_contracts.ps1`) and the CAP-10A parser test now pin `dev`
and `build` only, each with a comment naming this shard. npm-through-node is
**deferred to CAP-10C1 by decision**, with the resolution rule recorded in
the ledger; the doctor row is untouched.

## Evidence

New four-target fields: `supervision_corpus` and `run_corpus` (both
must-PASS) plus `supervision_digest`, `supervision_corpus_lines`,
`cli_run_available`, `advertised_commands`, `supervision_shell_used`,
`supervision_tree_model`, `argv_roundtrip`, `exit_propagation`,
`death_never_exit_zero`, `signal_outcome_typed`, `graceful_stop_mechanism`,
`forced_kill_required`, `grandchild_drained`, `zombie_left`,
`workdir_explicit`, `environment_policy`, `batch_file_refused`,
`run_interrupt_clean`, `supervisor_terminated_tree_dies`,
`descendants_after_exit`, `global_name_kill_present`, `run_react_rpc_value`,
`run_pas2js_rpc_value`, `run_secure_origin`, `run_error_mapping`,
`run_listener_count`, `run_network_calls`, `run_tool_calls`,
`run_dev_allowance_present`, `run_tree_unchanged`, `run_no_ansi`,
`run_not_built`, `run_layout_link`, `run_output_escape`,
`run_tampered_bundle`, `run_option_matrix`, `run_project_descriptor_form`,
`dev_build_unknown`, `shutdown_order`, `run_elapsed_ms`,
`run_descendants_drained`, `run_descendants_forced`, `run_drain_passes`,
`stage_react_release_digest`, `stage_pas2js_release_digest`.

Twenty-eight of them are **absolute pins**. Per-target observations,
recorded and never compared: `supervision_tree_model` (`job_object` on
Windows, `process_group` elsewhere — validated against the OS, so a Windows
leg reporting a process group is refused), `graceful_stop_mechanism`,
`signal_outcome_typed` (`true` on POSIX, `not_applicable` on Windows —
validated the same way), the drain counts and passes, the elapsed times.

Fourteen new negative self-test legs (c108–c121) bring the committed
self-test to **125 aggregator refusals + 2 divergence refusals** (111 + 2
before this shard), so every new refusal branch is proven red on fixtures
before the real aggregation is trusted. The divergence sweep re-ratifies at
**200 conditionals**.

Per-target facts from the closure run, recorded and never compared: the
React and Pas2JS runs drained 6 and 5 WebView2 members on Windows, 1 and 2
WebKit members on Linux and none on macOS (WebKit's XPC helpers are
launchd's, not the group's), all gracefully, none forced; each run measured
about 20.3–21.5 s against the 20 s auto-close bound the gate arms.

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler
and source lifecycle, the mORMot bridge, the nine-code taxonomy, protocol v1,
the SDK wire, `app.pwb`, `plugins.zip`, `pweb.json` schema 1, the CAP-10A
parser grammar, doctor and exit taxonomy, the CAP-10B0 engine, the CAP-10B1
and CAP-10B2 templates and their runtime semantics, the CAP-8A policy core,
the CAP-8B classifier and CSP, the CAP-9 runtime, package and lifecycle, the
platform adapters, the CAP-13 profiles and every dependency pin:
**unchanged**. `check_dev_trust.ps1` PASS on every leg: `pweb://app` is the
only privileged origin and the production profile carries no `ws://`,
`localhost` or `127.0.0.1` allowance. The divergence sweep re-ratifies at
198 conditionals.

## Known limitations / deferred

See `deferred-work.md` (CAP-10C0 entries): the `cli_digest` supersession;
npm-through-node deferred to C1 with its rule; Windows Ctrl+Break reaching
the application; macOS after a `SIGKILL` of the supervisor; the auto-close
smoke bound delaying a requested stop; a generated host's stdout
block-buffered on a POSIX pipe until exit; the divergence filter gap fixed
in passing; the drain pass-bound defect fixed before closure; the
review-driven fixes and the review findings deferred (long layout paths,
`Start-Process` quoting, the sampler's pid scope, the code-line sweep's
shape, group-wide `SIGTERM` beside WebKit helpers); the test-only
`SeparateConsole` spawn option; the `ci.yml` budget at 208.7 KB; and the
CAP-10C1 handoff.

**CAP-10C0 PASS — PROCESS SUPERVISION AND RUN COMMAND FROZEN**
