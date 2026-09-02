---
title: 'CAP-10C0 — portable child-process supervision and the public `pweb run`'
type: 'feature'
created: '2026-09-01'
status: 'in-review'
baseline_commit: '795e07553ac737461d3fb8e9350420e0d1d2c1cf'
review_loop_iteration: 0
context:
  - '{project-root}/docs/cli-contract.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10a-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap10b2-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The CLI can create a project and diagnose a machine but cannot
launch what a project builds. Its only process path (`pweb.cli.probe`, CAP-10A)
is a bounded capture over FPC's `TProcess`, which builds its own Windows command
line with a quoting rule that cannot round-trip an embedded quote, owns no
Job Object or process group, and reaps nothing but the direct child — the shape
that left WebView2 browser images holding a tree in the CAP-6b3 race. `pweb dev`
(C1/C2) and `pweb build` (D) will each need a long-running, signal-forwarding,
tree-owning supervisor, and writing it three times is how it drifts.

**Approach:** Replace the `TProcess` body with ONE private spawn engine
(`pweb.cli.process`) over raw platform primitives in `pweb.cli.platform`
(CreateProcessW + Job Object with KILL_ON_JOB_CLOSE + msvcrt-exact quoting;
fork/execve + own process group + SIGTERM/SIGKILL to the group), with two usage
profiles — `probe` (CAP-10A semantics, unchanged) and `supervise` (foreground,
stream forwarding, stop propagation, bounded graceful-then-forced shutdown,
membership-scoped descendant drain). Expose it through the public
`pweb run [--project <path>]`, which resolves an ALREADY-BUILT layout beneath
`output` by the same executable-relative release model the hosts resolve, and
never builds. Add the smallest semantics-neutral POSIX helper to the reusable
host so SIGTERM enters the existing terminate dispatch and the CAP-9 shutdown
order runs.

## Boundaries & Constraints

**Always:** pweb.json schema 1, the CAP-10A parser grammar, doctor schema and
digest, the exit taxonomy 0/2/3/4/5/6, the B0 engine, the B1/B2 templates and
their runtime behaviour, the seven interfaces, scheduler, bridge, protocol v1,
CAP-8 policy/navigation/CSP, CAP-9 runtime/package/lifecycle, `app.pwb`,
`plugins.zip`, release layouts, CAP-13 profiles, adapters and every pin stay
unchanged. Exactly one process-execution path in the CLI, used by probe and
supervise alike: exact executable path, argument array, explicit working
directory, `/dev/null`/`NUL` stdin, both streams drained concurrently, exact
exit status (POSIX `WEXITSTATUS`, never the raw wait status), death by signal
and forced termination typed, never reported as exit 0. Every spawned child is
waited. Descendants are selected by job/group MEMBERSHIP only; image paths are
recorded, never matched by name, and an unreadable path is never a match.
`pweb run` inherits the environment unchanged, injects nothing, passes no
argument to the application, reads no `.env`, opens no listener, touches no
network, runs no npm/pas2js/FPC/git and mutates neither project nor layout.
Supervisor lines are `pweb: `-prefixed and carry no ANSI; application output is
forwarded verbatim. No SDK absolute path, home directory, environment content
or unrelated command line is ever printed. `dev` and `build` stay unknown.
check_dev_trust keeps running on every leg; all conditionals stay in
`pweb.cli.platform` and the divergence allowlist is re-ratified in the same
commit that changes it.

**Ask First:** any change to the exit mapping in Design Notes; any environment
variable the supervisor would inject; any WM_CLOSE target beyond the child pid's
visible top-level windows; any `GenerateConsoleCtrlEvent` scope beyond the
supervisor's own test-driven CTRL_BREAK to a group it created; any host change
beyond the POSIX signal-to-terminate helper; any layout rule other than
`<output>/<os>-<arch>/release/` (see Design Notes); reopening the npm decision.

**Never:** `pweb dev`, `pweb build`, Vite/pas2js/FPC/npm launched by `run`,
HMR, a dev proxy, a file watcher, any `ws://`/`http://localhost`/`127.0.0.1`
allowance, a change to the privileged origin, a global process-name kill,
`taskkill /IM`, `Stop-Process -Name`, `killall`, `pkill`, a shell-mediated
path, a command string in any unit, `.cmd`/`.bat` execution, a second layout
model, a second scheduler/bridge path, unsafe thread termination inside the
host, an example-host migration, a `--json` mode for `run`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Built React project | `pweb run` from an unrelated CWD, `--project` at dir or descriptor | app spawned from its release dir, `demo: ready {...value:42}` forwarded, `demo: clean exit`, exit 0, job/group empty afterwards | N/A |
| Built Pas2JS project | same | identical decisions, 42 | N/A |
| Not built | `output/<target>/release/` absent or executable/app.pwb missing | `pweb: run refused: not_built` (+ which entry), no build, no mutation | exit 3 |
| Layout escape | link/junction or case variant on the layout chain, or `output` outside root | refused by the CAP-10A walk, cause named | exit 3 |
| Tampered app.pwb | host prints `app.pwb REFUSED (...)`, exits 1 | forwarded verbatim; `pweb: application exited 1` | exit 5 |
| App exit nonzero / crash | exit N≠0, or signal S | `pweb: application exited N` / `terminated by signal S` (POSIX) | exit 5 |
| Ctrl+C / SIGINT on supervisor | app live | graceful stop: WM_CLOSE (Win) / SIGTERM group (POSIX) → host runs CAP-9 shutdown → `clean exit` within 5 s | 0 if app exited 0, 5 if forced |
| Child ignores stop | fixture `stubborn` | forced kill after 5 s grace, reaped within 3 s, outcome `forced` | typed, never hangs |
| Grandchild | fixture `spawn` | grandchild dies with the job/group; membership empty after drain | N/A |
| Supervisor killed | SIGKILL/TerminateProcess on supervisor | tree dies (KILL_ON_JOB_CLOSE / group is signalled by the test, not by us) | measured |
| Bad argument | NUL or invalid UTF-8 in an argv element; `.cmd`/`.bat` executable | refused before spawn, typed cause | probe: spawn_refused |
| Stream saturation | fixture floods stdout or stderr | no deadlock; probe capture bounded 64 KiB; supervise line bound 4096 | N/A |
| Duplicate/unknown option | `pweb run --project a --project b`, `pweb run --json` | `duplicate_option` / `option_not_for_command` | exit 2 |
| Job Object refused | CreateJobObject/Assign fails | `pweb: run refused: supervision_unavailable` | exit 4 |

</frozen-after-approval>

## Code Map

- `tools/pweb/pweb.cli.probe.pas` -- CAP-10A resolver + `PWebCliRunProbe`/`PWebCliProbeTool` (public signatures FROZEN, used by `pweb.cli.doctor.pas:187-210` through `TPWebCliDoctorEnv.ProbeTool`). Its `TProcess` body is replaced by a call into the engine; `DrainPipe` and the `uses process, pipes` go away.
- `tools/pweb/pweb.cli.platform.pas` -- the ONLY conditional unit (allowlist 24 directives, `test/cap7f/check_divergence.ps1:110`). Windows body `:395-1044` (W/U helpers, `CommandLineToArgvW`, `EnvW`, `PWebCliFindExecutable`), POSIX body `:1045+` (`FinalPathOfFd`, `isatty` external pattern). New primitives go INSIDE those bodies; Darwin-only libproc externals add directives → re-ratify the row.
- `tools/pweb/pweb.cli.toolchain.pas` -- constants home (`PWEB_CLI_PROBE_TIMEOUT_MS`, `PWEB_CLI_PROBE_MAX_BYTES`); add the supervision bounds here.
- `tools/pweb/pweb.cli.args.pas` -- `TPWebCliCommand`, per-command option refusals (`:395-460`); add `pccRun`, allow `--project`, refuse everything else.
- `tools/pweb/pweb.cli.report.pas` -- `PWebCliUsageBanner`, `PWebCliCreateHelp`; add `run` line and `PWebCliRunHelp`.
- `tools/pweb/pweb.cli.project.pas` -- `TPWebCliProject` (`Root`, `ProgramIdent`, `OutputPath: TPWebCliResolved`, `Ui`); `PWebCliOpenProject(ExplicitPath, StartDir)` is the single discovery seam.
- `tools/pweb/pweb.cli.paths.pas` -- `PWebCliResolveUnder(Root, Logical, AllowMissingTail)`: exact-case, link-refusing walk; reuse for the layout chain with `AllowMissingTail=False`.
- `tools/pweb/pweb.pas` -- dispatch and exit constants; `RunCreate`/`RunDoctor` pattern; the one `PWebCliCwd` call.
- `src/webview/pweb.webview.host.pas` -- `PWebHostRun` (`:560-760`): `HostAutoCloseHandle`, `PWebHostTerminate` dispatch, `PWebHostAutoCloseThread` (`BeginThread` + `webview_dispatch`) — the mechanism the POSIX signal helper reuses; teardown order after `webview_run` returns is the CAP-9 order and is untouched. Allowlist row 30 directives (`check_divergence.ps1:135`).
- `deps/webview/core/include/webview/detail/backends/win32_edge.hh:557` -- `WM_CLOSE → DestroyWindow → WM_DESTROY → terminate`: the Windows graceful path needs no host change (measured on the dev host: clean exit in 40 ms).
- `test/cap10a/probechild.pas`, `test/cap10a/pweb.test.cli.pas:1319-1420`, `clitests.pas` -- D6–D9 pattern (fixture beside the suite, `Record_` corpus lines, mormot.core.test). Untouched; the C0 suite is a sibling.
- `test/cap10a/check_cap10a_contracts.ps1:148-160` -- shell-spelling sweep over `tools/pweb/*.pas` (incl. `CommandLine :=`, `ExecuteProcess`): the new units are swept automatically; name variables accordingly.
- `test/cap6b3/wv2procdrain.ps1` -- the path-scoped drain rule (`Test-PWebPathUnderRoot`, component boundary, unreadable → never matches, fresh record at kill time) and `check_wv2procdrain.ps1` T1–T11: DOCUMENTED DUPLICATION in Pascal (different language, same rule, same injected cases).
- `test/cap10b1/prove_cap10b1.ps1|.sh`, `test/cap10b2/prove_cap10b2.ps1|.sh` -- leave `build/cap10b{1,2}/release/` (Win/Linux: `demo[.exe] app.pwb webview lib`; macOS: `Demo.app/Contents/{MacOS/demo,Resources/app.pwb,Info.plist}`) and `build/cap10b{1,2}/project/demo` (the created project). The run harness COPIES these into C0 project stages; the B proofs are not edited.
- `test/cap7f/emit_evidence.ps1:865-1150`, `emit_evidence.sh:956-1360`, `check_cap7f_aggregate.ps1:117-160,719-745,914-965,1049`, `check_cap7f_selftest.ps1:1261+` -- the B2 field pattern (must-PASS corpus, absolute pins, numeric rows, negative legs c85–c107).
- `.github/workflows/ci.yml` -- B2 steps at `:1938-1981` (windows), `:2643-2678` (linux, `xvfb-run -a`), macOS x64 `:3375+`, arm64 mirror; C0 steps follow B2 and precede `CAP-7F emit`.
- `docs/cli-contract.md` -- §1 surface, §4 exit codes, §5 dev trust (phrases pinned by `check_dev_trust.ps1`); add `run` and link the new supervision contract.

## Tasks & Acceptance

**Execution:**
- [x] `tools/pweb/pweb.cli.toolchain.pas` -- add `PWEB_CLI_RUN_GRACE_MS=5000`, `PWEB_CLI_RUN_KILL_MS=3000`, `PWEB_CLI_RUN_LINE_MAX=4096`, `PWEB_CLI_RUN_DIAG_MAX=65536`, `PWEB_CLI_RUN_DRAIN_PASSES=20`, `PWEB_CLI_RUN_DRAIN_POLL_MS=250`, `PWEB_CLI_RUN_STOP_RETRY_MS=250` -- one constants home, cross-checked by the contract gate.
- [x] `tools/pweb/pweb.cli.platform.pas` -- inside the existing bodies: `TPWebCliChild` (handles/pid/pgid/job, two read ends), `PWebCliChildSpawn(exe, argv, workdir, out child, out cause)` (Windows: `STARTUPINFOEXW` + `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` limited to the three stdio handles, `CREATE_NEW_PROCESS_GROUP or CREATE_SUSPENDED or EXTENDED_STARTUPINFO_PRESENT`, assign to a fresh job with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resume; POSIX: `FpFork`, child `setpgid(0,0)`, dup2 pipes, `/dev/null` stdin, `FpChDir`, `FpExecve(path, argv, environ)`, exec-failure reported through a CLOEXEC status pipe), `PWebCliChildRead(child, stream, buf)` non-blocking, `PWebCliChildWait(child, ms) → running|exited(code)|signaled(sig)`, `PWebCliChildStop(child)` (Windows: `EnumWindows`+`GetWindowThreadProcessId`+`IsWindowVisible` → `PostMessageW WM_CLOSE`; POSIX: `FpKill(-pgid, SIGTERM)`), `PWebCliChildKill(child)` (`TerminateJobObject` / `SIGKILL` to group), `PWebCliChildMembers(child) → pid,ppid,image[]` (`QueryInformationJobObject(JobObjectBasicProcessIdList)` + `QueryFullProcessImageNameW`; Linux `/proc/*/stat` pgrp + `readlink exe`; Darwin `proc_listpids`/`proc_pidinfo`/`proc_pidpath`), `PWebCliChildRelease` (waitpid reap, CloseHandle), `PWebCliInstallStopHandler`/`PWebCliStopRequested` (`SetConsoleCtrlHandler` re-enabled via `SetConsoleCtrlHandler(nil, False)` first, CTRL_C and CTRL_BREAK → flag; POSIX `sigaction` SIGINT/SIGTERM/SIGHUP → `sig_atomic` flag) -- the only platform code.
- [x] `tools/pweb/pweb.cli.process.pas` (NEW, zero conditionals) -- `PWebCliWindowsCommandLine(exe, argv)` (msvcrt rule: quote when empty or containing space/tab/quote; double backslash runs before a quote and at the end; `\"`), `PWebCliArgvAcceptable` (NUL, strict UTF-8, refuse `.cmd`/`.bat`/`.com`-less rule: executable suffix `.cmd`/`.bat` refused everywhere), the ONE drain loop (both streams, line assembly with the bound, probe-capture or forward sink), `TPWebCliChildOutcome = (pcoExited, pcoSignaled, pcoForced, pcoSpawnRefused, pcoSpawnFailed)`, `PWebCliExecute(spec, profile)`; `PWebCliDrainDescendants(enumerate, terminate, sleep)` injectable like the 6b3 helper, records `pid ppid image graceful|forced` -- one execution path, two profiles.
- [x] `tools/pweb/pweb.cli.probe.pas` -- `PWebCliRunProbe` becomes a thin call into `PWebCliExecute(..., pepProbe)`; outcomes/fields unchanged; header rewritten -- doctor behaviour and `doctor_schema_digest` unchanged.
- [x] `tools/pweb/pweb.cli.run.pas` (NEW, zero conditionals) -- `PWebCliResolveRunLayout(project, os, arch) → TPWebCliRunLayout{ExeDir, ExePath, BundlePath, Refusal}` walking `output/<os>-<arch>/release/[<ident>.app/Contents/MacOS/]<ident>[.exe]` and `app.pwb` (macOS: `Contents/Resources/app.pwb`, `Contents/Info.plist` present) through `PWebCliResolveUnder`; `PWebCliRunProject(layout, sink) → TPWebCliRunResult` (spawn in `ExeDir`, no args, forward, stop on request, drain, report) -- run-mode layout contract, single owner.
- [x] `tools/pweb/pweb.cli.args.pas`, `pweb.cli.report.pas`, `pweb.pas` -- `pccRun`, `pweb run --help`, banner `create doctor run`, exit mapping (Design Notes), `RunRun` beside `RunCreate`/`RunDoctor` -- public surface.
- [x] `src/webview/pweb.webview.host.pas` -- POSIX-only: around `webview_run`, `sigaction` SIGTERM/SIGINT/SIGHUP → async-signal-safe `write` to a self-pipe; a `BeginThread` waiter blocks on the pipe and performs the identical `InterlockedExchange(HostAutoCloseHandle,nil)` + `webview_dispatch(@PWebHostTerminate)`; teardown writes a sentinel, joins with the closer margin, restores dispositions. Windows: no change. Re-ratify the allowlist row -- SIGTERM reaches the existing terminate path; the shutdown order after `webview_run` is untouched.
- [x] `test/cap10c0/pwebchild.pas` (NEW, RTL-only) -- modes `exit N`, `argv` (JSON array, escaped), `flood`/`floodstderr N`, `lines N LEN`, `sleep MS`, `forever`, `stubborn` (SIG_IGN SIGTERM / no window, loops), `spawn` (spawns `pwebchild forever`, exits 0), `cwd`, `env NAME`, `ppid` -- the S-matrix fixture.
- [x] `test/cap10c0/pweb.test.supervise.pas` + `c0tests.pas` (NEW) -- S1–S18 against the fixture plus a pure table test of the quoting function and of the drain selector (6b3 T-cases in Pascal: sibling prefix, unreadable, vanished pid, late member); R10 driver: spawn `pweb run` through the layer and send `GenerateConsoleCtrlEvent(CTRL_BREAK, pid)` / `kill(pid, SIGINT)`; emits `build/cap10c0/supervise-corpus.txt` -- decisions, digested.
- [x] `test/cap10c0/build_cap10c0.ps1|.sh`, `run_cap10c0_gates.ps1`, `check_cap10c0_contracts.ps1` (NEW) -- compile fixture + suite (isolation compiles: `pweb.cli.process` and `pweb.cli.run` webview-free); stage `build/cap10c0/stage/{react,pas2js}/demo` from `build/cap10b{1,2}/project/demo` + `dist/<target>/release/` from `build/cap10b{1,2}/release` (bytes unchanged, macOS bundle renamed `demo.app`); run R1–R14 and T1–T4 with the real CLI (env `PWEB_SMOKE_AUTOCLOSE_MS` bounds R1/R2; listener sampled live; membership enumerated after exit; tree digest before/after); contracts: no `process`/`pipes` ppu linked, no shell spelling, no name-kill primitive (`Process32`, `EnumProcesses`, `pgrep`, `pkill`, `killall`, `taskkill`, `Stop-Process -Name`, `Name=`), bounds cross-checked, env reads in `src/security src/rpc src/webview src/assets` limited to the ratified autoclose one; emit `build/cap10c0/cli-<target>.json` -- four-target evidence.
- [x] `test/cap7f/emit_evidence.ps1|.sh`, `check_cap7f_aggregate.ps1`, `check_cap7f_selftest.ps1`, `check_divergence.ps1`, `.github/workflows/ci.yml` -- C0 fields (below), must-PASS `supervision_corpus`/`run_corpus`, absolute pins, refusals (missing target, shell used, descendants>0, dev allowance, listener>0, rpc≠42, exit divergence, name-kill present, SKIP→PASS), negative legs c108+, allowlist re-ratification, four job blocks after B2 -- aggregation.
- [x] `docs/supervision-contract.md` (NEW), `docs/cli-contract.md` -- the supervision contract, `run` grammar/help/exit mapping/layout, npm debt left open by decision -- documentation.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md`, `cap10c0-final-artifact.md` -- ledger and closure -- closure ritual.

**Acceptance Criteria:**
- Given the CLI links `pweb.cli.process`, when contracts run, then no `process.ppu`/`pipes.ppu` is linked and no shell spelling or name-kill primitive exists in `tools/pweb`.
- Given the fixture, when S1–S18 run on the four targets, then `supervision_digest` (the decision corpus) is equal on all four and `supervision_tree_model` reads `job_object` on Windows and `process_group` elsewhere.
- Given the built B1 and B2 layouts staged beneath a project's `output`, when `pweb run` executes from an unrelated CWD, then `run_react_rpc_value = run_pas2js_rpc_value = 42`, `run_listener_count = 0`, `descendants_after_exit = 0`, exit 0, and the project and layout tree digests are unchanged.
- Given `pweb --help`, when parsed, then it advertises exactly `create doctor run`; `pweb dev`/`pweb build` answer `unknown_command`, exit 2.
- Given the CAP-10A, B0, B1, B2, CAP-6b3/6b4, CAP-7/8/9 gates on the final HEAD, when hosted CI runs, then every job is green and `cli_digest`, `doctor_schema_digest`, `navigation_policy_digest`, `security_corpus_digest`, `quickjs_gui_digest` equal their recorded values.

## Spec Change Log

## Design Notes

**Ratified at Checkpoint 1 (human-owned once approved):**

Exit mapping for `run`: `0` application exited 0 (normal or requested stop);
`2` usage; `3` project refused, layout absent/incomplete/non-confined
(`not_built`, `layout_link`, `layout_case`, `layout_escape`, `bundle_shape`);
`4` supervision prerequisites (`job_object`, `stop_handler`, `pipes`,
`spawn_failed`); `5` application exited nonzero, died by signal, or was
force-killed (real status printed as `pweb: application exited N` /
`terminated by signal S` / `force-killed after Nms`); `6` internal.

Layout: `<root>/<output>/<os>-<arch>/release/` with the CLI's own
`PWebCliHostOsText-PWebCliHostArchText` (`windows-x86_64`, `linux-x86_64`,
`macos-x86_64`, `macos-arm64`); Windows/Linux `<ident>[.exe]` + `app.pwb`
beside it; macOS `<ident>.app/Contents/MacOS/<ident>` + `Contents/Resources/app.pwb`
+ `Contents/Info.plist`. Working directory = the executable's directory.
CAP-10D produces exactly this.

Descendant drain: membership (job / pgid) is the sole termination criterion —
path-only selection would kill an unrelated instance of the same application
launched by the user; image paths are recorded (unreadable → empty, recorded,
never a criterion), graceful window then `TerminateJobObject`/`SIGKILL` to the
group, re-enumeration up to 20 passes. Measured on the dev host: six WebView2
processes inside the job, six unrelated Evergreen processes outside it, job
empty 254 ms after host exit.

Environment: inherit unchanged, nothing injected, `.env` never read. Known,
recorded: WebView2's own documented overrides (`WEBVIEW2_*`) and
`PWEB_SMOKE_AUTOCLOSE_MS` apply through `run` exactly as through a
double-click; none selects a security policy.

npm debt: DEFERRED to C1 by decision; rule recorded for C1: canonical `node`
→ dir D → Windows `D\node_modules\npm\bin\npm-cli.js`, POSIX
`parent(D)/lib/node_modules/npm/bin/npm-cli.js`, probe `node npm-cli.js
--version`, fallback presence with cause `npm_cli_unresolved`; doctor row and
digest untouched in C0.

Windows Ctrl+Break at a real console still reaches the application (it is
never disabled for a new group) and is not graceful: recorded limitation.

Quoting golden rows (argv → command-line token, the msvcrt rule: quote when
empty or carrying space/tab/quote): `a b` → `"a b"`; `` → `""`; `a"b` →
`"a\"b"`; `a\` → `a\`; `a\"` → `"a\\\""`; `\\x` → `\\x`; `"` → `"\""`;
`x y\` → `"x y\\"`.

## Verification

**Commands:**
- `pwsh test/cap10b1/build_cap10b1.ps1; pwsh test/cap10a/build_cap10a.ps1; pwsh test/cap10c0/build_cap10c0.ps1` -- expected: `pweb.exe`, `c0tests.exe`, `pwebchild.exe` built, isolation compiles clean.
- `pwsh test/cap10c0/check_cap10c0_contracts.ps1` -- expected: `PASS`, no shell/name-kill/network, no process.ppu linked.
- `pwsh test/cap10a/run_cap10a_gates.ps1` -- expected: `cli_digest` and `doctor_schema_digest` unchanged from CAP-10B2 closure.
- `pwsh test/cap10c0/run_cap10c0_gates.ps1` -- expected: S1–S18, R1–R14, T1–T4 PASS, `build/cap10c0/cli-windows-x86_64.json` with `run_react_rpc_value=42`, `run_pas2js_rpc_value=42`, `descendants_after_exit=0`.
- `pwsh test/cap7f/check_divergence.ps1; pwsh test/cap10a/check_dev_trust.ps1; pwsh test/cap7f/check_cap7f_selftest.ps1` -- expected: allowlist re-ratified, dev trust PASS, self-test refusals grow by the C0 legs.
- `gh run list --branch phase/cap-10/c0-run-supervision` -- expected: all six jobs green on the final HEAD.

## Suggested Review Order

**The one execution engine**

- Entry point: profiles, escalation ladder, typed outcomes, the finally that never leaves a tree
  [`pweb.cli.process.pas:711`](../../tools/pweb/pweb.cli.process.pas#L711)

- Pre-spawn refusals: NUL, strict UTF-8, batch files on every platform
  [`pweb.cli.process.pas:289`](../../tools/pweb/pweb.cli.process.pas#L289)

- Line forwarding with the bound, CR-aware, sink failure never unwinds
  [`pweb.cli.process.pas:582`](../../tools/pweb/pweb.cli.process.pas#L582)

- The descendant drain: grace by time, forced by passes, kill on every pass
  [`pweb.cli.process.pas:384`](../../tools/pweb/pweb.cli.process.pas#L384)

- The probe re-based on the engine, signatures frozen, tool directory explicit
  [`pweb.cli.probe.pas:212`](../../tools/pweb/pweb.cli.probe.pas#L212)

**Windows tree ownership**

- CreateProcessW suspended, handle list of three, Job Object with KILL_ON_JOB_CLOSE, then resume
  [`pweb.cli.platform.pas:1338`](../../tools/pweb/pweb.cli.platform.pas#L1338)

- The msvcrt quoting rule, platform-free and golden-tabled on four targets
  [`pweb.cli.platform.pas:3096`](../../tools/pweb/pweb.cli.platform.pas#L3096)

- WM_CLOSE to visible top-level windows of the child pid only
  [`pweb.cli.platform.pas:1632`](../../tools/pweb/pweb.cli.platform.pas#L1632)

- Membership enumeration through the job pid list, image paths recorded
  [`pweb.cli.platform.pas:1684`](../../tools/pweb/pweb.cli.platform.pas#L1684)

- Console control events: Ctrl+C returns, close/logoff/shutdown wait for the engine
  [`pweb.cli.platform.pas:1756`](../../tools/pweb/pweb.cli.platform.pas#L1756)

**POSIX tree ownership**

- fork, own group, SIGPIPE default, descriptors closed, execve with live environ, exec failure typed
  [`pweb.cli.platform.pas:2570`](../../tools/pweb/pweb.cli.platform.pas#L2570)

- EOF closes the descriptor so poll never spins on HUP
  [`pweb.cli.platform.pas:2736`](../../tools/pweb/pweb.cli.platform.pas#L2736)

- Group SIGTERM, then SIGKILL; a probe is signalled by pid
  [`pweb.cli.platform.pas:2834`](../../tools/pweb/pweb.cli.platform.pas#L2834)

- Linux /proc pgrp scan and Darwin libproc scan, both by membership
  [`pweb.cli.platform.pas:2912`](../../tools/pweb/pweb.cli.platform.pas#L2912)

- Release kills the group last: the POSIX twin of closing the job
  [`pweb.cli.platform.pas:3008`](../../tools/pweb/pweb.cli.platform.pas#L3008)

**`pweb run`**

- The layout rule, a pure function of the descriptor for every OS
  [`pweb.cli.run.pas:186`](../../tools/pweb/pweb.cli.run.pas#L186)

- Resolution through the CAP-10A walk: link, case, escape, shape, execute bit
  [`pweb.cli.run.pas:270`](../../tools/pweb/pweb.cli.run.pas#L270)

- The ratified exit mapping and the supervisor's own lines
  [`pweb.pas:413`](../../tools/pweb/pweb.pas#L413)

- Lines flushed on every write, so a pipe sees them as they happen
  [`pweb.pas:108`](../../tools/pweb/pweb.pas#L108)

**The host helper**

- Signal to self-pipe to the same terminate dispatch as auto-close
  [`pweb.webview.host.pas:399`](../../src/webview/pweb.webview.host.pas#L399)

- Installed last before webview_run, previous dispositions saved and restored
  [`pweb.webview.host.pas:449`](../../src/webview/pweb.webview.host.pas#L449)

- The call site, flags defined before the try
  [`pweb.webview.host.pas:837`](../../src/webview/pweb.webview.host.pas#L837)

**The bounds and the contract**

- Seven limits, stated once
  [`pweb.cli.toolchain.pas:85`](../../tools/pweb/pweb.cli.toolchain.pas#L85)

- Tree ownership, per platform, with the measured WebView2 job membership
  [`supervision-contract.md:54`](../../docs/supervision-contract.md#L54)

- Why membership decides and the path only annotates
  [`supervision-contract.md:107`](../../docs/supervision-contract.md#L107)

- The public grammar, layout and trust statement
  [`cli-contract.md:512`](../../docs/cli-contract.md#L512)

**Tests and gates**

- The quoting golden table and the drain over injected records
  [`pweb.test.supervise.pas:533`](../../test/cap10c0/pweb.test.supervise.pas#L533)

- Graceful-then-forced, both intervals measured
  [`pweb.test.supervise.pas:973`](../../test/cap10c0/pweb.test.supervise.pas#L973)

- The grandchild owned by the tree
  [`pweb.test.supervise.pas:1050`](../../test/cap10c0/pweb.test.supervise.pas#L1050)

- The driver that delivers a real Ctrl+C to a live `pweb run`
  [`pweb.test.supervise.pas:1390`](../../test/cap10c0/pweb.test.supervise.pas#L1390)

- A terminated supervisor takes its tree, SIGKILL variant on Linux
  [`pweb.test.supervise.pas:1522`](../../test/cap10c0/pweb.test.supervise.pas#L1522)

- The fixture's Ctrl+C helper and PWEBCHILD_MODE stand-in
  [`pwebchild.pas:351`](../../test/cap10c0/pwebchild.pas#L351)

- Staging the B1/B2 releases byte for byte beneath `output`
  [`run_cap10c0_gates.ps1:102`](../../test/cap10c0/run_cap10c0_gates.ps1#L102)

- One real run leg: 42, listeners, tools, descendants, digests, no ANSI
  [`run_cap10c0_gates.ps1:331`](../../test/cap10c0/run_cap10c0_gates.ps1#L331)

- No FPC process unit at the link; no name-based kill in the source
  [`check_cap10c0_contracts.ps1:126`](../../test/cap10c0/check_cap10c0_contracts.ps1#L126)

- The shutdown order and the shared dispatch, pinned in the host's source
  [`check_cap10c0_contracts.ps1:237`](../../test/cap10c0/check_cap10c0_contracts.ps1#L237)

**Evidence plumbing**

- Absolute pins the four targets could agree on and still be wrong about
  [`check_cap7f_aggregate.ps1:188`](../../test/cap7f/check_cap7f_aggregate.ps1#L188)

- Per-OS validation of the tree model, stop mechanism and typed signal death
  [`check_cap7f_aggregate.ps1:836`](../../test/cap7f/check_cap7f_aggregate.ps1#L836)

- Fourteen negative legs proving each refusal red on fixtures
  [`check_cap7f_selftest.ps1:1503`](../../test/cap7f/check_cap7f_selftest.ps1#L1503)

- The mORMot OS spellings the divergence filter had missed, and the two re-ratified rows
  [`check_divergence.ps1:52`](../../test/cap7f/check_divergence.ps1#L52)
