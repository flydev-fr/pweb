{
  pweb.cli.dev - the development loop: rebuild, pack, publish, reload
  (CAP-10C2 React, CAP-10C3 Pas2JS).

  THE ONLY UNIT OF THE DEV LOOP THAT RUNS A CHILD, exactly as
  pweb.cli.pipeline is for the build. `npm`, `tsc`, `vite`, `pas2js`,
  `pwebbundle`, `fpc` and the dev host all go through PWebCliExecute in the
  CAP-10C0 supervise profile, with an exact executable path, an argument
  vector and an explicit working directory. There is no shell, no command
  string, no .cmd/.bat, no environment injection and no second execution
  path.

  ---------------------------------------------------------------------------
  WHAT THE LOOP IS, IN ONE PICTURE
  ---------------------------------------------------------------------------

  REACT - the build says when it finished, and a watcher lives beside the
  host:

    main thread                       watcher thread        host thread
    prerequisites (C1's, verbatim)
    compile the DEV binary
    start watcher                 --> vite build --watch
    wait for the sentinel; pack gen-1
    start host                                          --> the dev binary
    loop: sentinel -> snapshot -> pack -> publish -> read `generation N loaded`

  PAS2JS - the compiler has no watch mode and no writeBundle, so THE CLI
  OWNS DETECTION (pweb.cli.devinputs) and there is no watcher child at all:

    main thread                                           host thread
    prerequisites (toolchain and the dev compile; no npm, no tsc, no SDK
    staging - a Pas2JS project needs Node at no point)
    scan the input set; compile + assemble + pack gen-1
    start host                                        --> the dev binary
    loop: fingerprint -> pas2js -> C1 assembly -> pack -> publish -> ack

  So the SUPERVISED SET is two long-lived members for React and ONE for
  Pas2JS. That is not a second ladder and not a second supervisor: the stop
  flag, DevStopCheck, the C0 graceful-then-forced ladder, the join and the
  drain are the same code reached with an empty watcher slot.

  PWebCliExecute runs ONE child to completion, so each long-lived member
  gets a thread of its own. That is legal without touching the engine
  because the engine is re-entrant - no unit-level mutable state, the
  Windows spawn restricts inheritance with PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
  and the POSIX spawn touches no heap between fork and execve and closes
  every descriptor above 2.

  ONE STOP FLAG is the StopCheck of every long-lived execution. It is set by
  the console / signal handler, by the host exiting, by the watcher exiting,
  or by an internal failure - so one request runs the C0 ladders
  concurrently (graceful WM_CLOSE / SIGTERM to the group, then forced, then
  drained by membership), inside the C0 bounds, and there is no second
  ladder anywhere in this unit.

  ---------------------------------------------------------------------------
  NO TRANSPORT, NO LISTENER, NO ORIGIN CHANGE
  ---------------------------------------------------------------------------

  Nothing here opens a socket, listens on a port, proxies a request or
  speaks a protocol. The completion signal is a FILE the build itself
  writes; the generation switch is a directory RENAME the host discovers by
  a bounded forward-only poll; the reload is a native re-navigation to
  pweb://app. There is no ws://, no wss://, no localhost and no 127.0.0.1
  anywhere in this shard's source, and no CSP moves.

  ---------------------------------------------------------------------------
  THE PAS2JS COMPLETION SIGNAL: THERE ISN'T ONE, SO THE CLI DECIDES
  ---------------------------------------------------------------------------

  React is TOLD when a build finished. Pas2JS is not: there is no watch mode
  to report one and no writeBundle to hook, and the CAP-10C1 assembly runs
  in this CLI rather than in the build. So the loop asks the question the
  other way round - it watches the INPUTS instead of waiting for an output -
  and pweb.cli.devinputs is the whole of that rule: one bounded walk of the
  ratified input set every PWEB_CLI_DEV_POLL_MS, fingerprinted by CONTENT
  (never by mtime, which is second-granular through FPC's portable layer and
  would miss two edits inside one second).

  THE CONSISTENCY RULE IS THE PAS2JS TWIN OF THE SNAPSHOT PROOF. The
  fingerprint is taken BEFORE the compile and re-taken AFTER the assembly:
  if it moved, the generation is discarded and rebuilt, bounded by the same
  PWEB_CLI_DEV_SNAPSHOT_TRIES. Only a generation whose inputs were stable
  across compile AND assembly is packed - which is the mechanical answer to
  "can a mixed generation reach the host", over the correct subject.

  ---------------------------------------------------------------------------
  THE SENTINEL, AND WHY IT IS NOT LINE PARSING
  ---------------------------------------------------------------------------

  MEASURED against the pinned Vite: watch mode prints `built in 51ms.` where
  a one-shot build prints `built in 52ms` behind a tick - two spellings of
  one event - and the output carries ANSI whenever the inherited environment
  enables colour, which a supervisor that injects nothing cannot turn off.
  So the build states the fact: the template's vite.config.ts writes
  <frontend>/.pweb/dev/build-id from `writeBundle`, which fires once per
  completed write.

  TWO RULES FOLLOW FROM THE MEASUREMENTS, and both are here:

  DEBOUNCE, BOUNDED. Vite does not coalesce - five edits 50 ms apart
  produced five rebuilds - so after a sentinel change the CLI waits
  PWEB_CLI_DEV_DEBOUNCE_MS and re-reads; a further change restarts the wait,
  bounded by PWEB_CLI_DEV_DEBOUNCE_MAX_MS.

  THE SNAPSHOT IS PROVED CONSISTENT. dist/ is copied into
  <dev>/.gen.tmp/dist and the sentinel is then RE-READ: if it moved during
  the copy the snapshot is discarded and retaken. Only a snapshot whose
  sentinel was stable across the whole copy is packed - which is the
  mechanical answer to "can a partial generation reach the host", and it is
  a mechanism rather than a hope.

  ---------------------------------------------------------------------------
  FAILURE SEMANTICS
  ---------------------------------------------------------------------------

    the host exits 0 by itself             the loop stops, exit 0
    the host exits any other way           the loop stops, exit 5, real status
    the watcher exits at all               the loop stops, exit 5, real status
                                           (React only - Pas2JS has none)
    a build or a pack child fails          THE LOOP DOES NOT STOP - the
                                           previous generation stays live and
                                           the error is forwarded
    the input set becomes unwalkable       THE LOOP DOES NOT STOP either: it
    mid-session (a link, a bound)          is reported ONCE and the previous
                                           generation stays live. At START-UP
                                           the same fact is a refusal, exit 3

  The last one is the whole point of a development loop: a syntax error is
  something a developer fixes in the next keystroke, and a tool that closed
  the window on it would be a tool nobody could use.
}
unit pweb.cli.dev;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.process,
  pweb.cli.run,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.toolset,
  pweb.cli.frontend,
  pweb.cli.pack,
  pweb.cli.native,
  pweb.cli.layout,
  pweb.cli.devlayout,
  pweb.cli.devinputs,
  pweb.cli.pipeline;

type
  /// the ordered start-up stages, and then the loop
  TPWebCliDevStage = (
    /// the CAP-10A project, strict-parsed (done by the caller)
    pdvOpen,
    /// resolve everything and adopt the doctor's verdict - REFUSE BEFORE
    /// ANY WRITE, the C1 rule verbatim
    pdvToolchain,
    /// materialise the TypeScript SDK; C1 refuses a stale one, and so does
    /// this - skipping it would compile against yesterday's runtime
    pdvStageSdk,
    /// node <npm-cli.js> ci - CONDITIONAL, see PWebCliDevNeedsInstall
    pdvInstall,
    /// node tsc, ONCE, at start: Vite does not typecheck, and a typecheck
    /// per keystroke would cost seconds per generation
    pdvTypecheck,
    /// fpc -dPWEB_DEV into <dev>/units and <dev>/obj
    pdvCompile,
    /// vite build --watch, supervised for the whole session
    pdvWatch,
    /// the watcher's own first build, packed and published before the host
    /// starts - so the host never opens on an empty store
    pdvFirstGeneration,
    /// the dev binary, supervised for the whole session
    pdvHost,
    /// rebuild -> pack -> publish -> acknowledge, until a stop
    pdvLoop);

  /// the exit categories: the CAP-10C0 mapping, plus the two additions this
  /// shard ratifies
  // - ordinal 0 is the accepted state
  TPWebCliDevCode = (
    /// 0 - the loop ran and stopped cleanly
    pdcOk,
    /// 2 - the driver was invoked wrongly
    pdcUsage,
    /// 3 - the project, its descriptor, its paths, or a `ui` this build's
    /// dev loop does not implement
    pdcProject,
    /// 4 - the machine cannot build it: the doctor refused, a tool is
    /// missing, unrunnable or the wrong target
    pdcUnavailable,
    /// 5 - a start-up stage's child failed, or the SUPERVISED SET failed:
    /// the host died, or the watcher exited
    pdcSetFailed,
    /// 6 - an invariant of the dev loop itself broke
    pdcInternal);

  /// the driver's line sink - every line already prefixed, already free of
  /// ANSI and of any absolute path
  TPWebCliDevNotify = procedure(Opaque: Pointer; const Line: RawUtf8;
    FromChild: Boolean);

  /// everything one dev session learned
  TPWebCliDevResult = record
    Code: TPWebCliDevCode;
    FailedStage: TPWebCliDevStage;
    Cause: RawUtf8;
    Detail: RawUtf8;
    /// True when a stop was requested before the loop ended by itself
    Interrupted: Boolean;
    /// `npm_ci` when the install stage ran, `none` when it was skipped
    // - always `none` for a Pas2JS project: no stage of that loop reaches
    // the network, and there is no stage that could
    NetworkStages: RawUtf8;
    /// why the install ran, '' when it was skipped
    InstallReason: RawUtf8;
    /// the frontend kind this session developed
    Ui: TPWebCliUi;
    /// how this session learned that a rebuild was due - `vite_sentinel`
    /// for React, `cli_content_fingerprint_poll` for Pas2JS
    ChangeDetection: RawUtf8;
    /// how many files the ratified input set held (Pas2JS only, 0 for
    /// React, whose completion signal is the build's own)
    WatchedInputs: Integer;
    /// what the Pas2JS assembly had to normalise, recorded per target
    Normalisation: TPWebCliPas2jsNormalisation;
    /// pas2js children that failed - the previous generation stayed live
    BuildFailures: Integer;
    /// generations PUBLISHED, and generations the host ACKNOWLEDGED
    Published_: Integer;
    Acknowledged: Integer;
    /// how many generations the bounded cleanup removed
    Removed: Integer;
    /// generations discarded because the inputs moved underneath them -
    // React: the sentinel moved during the dist copy; Pas2JS: the input-set
    // fingerprint moved across the compile and the assembly. One counter,
    // because it is one rule measured over each loop's own subject
    RetakenSnapshots: Integer;
    /// rebuilds the watcher completed, from the sentinel
    Rebuilds: Integer;
    /// pack children that failed - the previous generation stayed live
    PackFailures: Integer;
    /// the two long-lived members
    WatcherPid: PtrInt;
    HostPid: PtrInt;
    WatcherOutcome: TPWebCliChildOutcome;
    WatcherExitCode: Integer;
    WatcherSignal: Integer;
    HostOutcome: TPWebCliChildOutcome;
    HostExitCode: Integer;
    HostSignal: Integer;
    /// True when the member ended while nobody had asked the set to stop
    HostEndedItself: Boolean;
    WatcherEndedItself: Boolean;
    /// descendants the two drains still saw after the members were gone
    DescendantsRemaining: Integer;
    DescendantsSeen: Integer;
    /// the redacted command projections, for the evidence
    WatcherCommand: RawUtf8;
    HostCommand: RawUtf8;
    CompileCommand: RawUtf8;
    PackCommand: RawUtf8;
    /// the Pas2JS generation command - '' for React, whose generation
    /// command is the watcher's and is recorded as WatcherCommand
    BuildCommand: RawUtf8;
    /// the read-only project tree, before the first stage and at the end
    TreeBefore: RawUtf8;
    TreeAfter: RawUtf8;
    /// the resolved toolchain and SDK, for the evidence
    Toolset: TPWebCliToolset;
    Sdk: TPWebSdkLayout;
    DevLayout: TPWebCliDevLayout;
  end;

/// stable lowercase name of a stage
function PWebCliDevStageName(Stage: TPWebCliDevStage): RawUtf8;

/// the ratified exit code of a category
function PWebCliDevExitCode(Code: TPWebCliDevCode): Integer;

/// does THIS BUILD's development loop implement that frontend kind
// - the ONE place the question is asked, so `dev_ui_unsupported` stays a
// live, tested path for the next UI kind rather than an unreachable branch
// nobody notices has rotted. CAP-10C2 implemented react, CAP-10C3 pas2js;
// anything else is refused with the PROJECT cause and exit 3, before
// anything is resolved, started or written
function PWebCliDevUiSupported(Ui: TPWebCliUi): Boolean;

/// how a session of that frontend kind learns a rebuild is due
// - `vite_sentinel` (the build writes it) or `cli_content_fingerprint_poll`
// (this CLI walks the ratified input set). Recorded per target and compared
// across the four, so a target running a different detector is a divergence
function PWebCliDevChangeDetection(Ui: TPWebCliUi): RawUtf8;

/// remove every ANSI escape sequence from a line
// - MEASURED necessary: Vite colours its output whenever the inherited
// environment enables it, and the supervisor injects nothing to stop it.
// "No ANSI reaches a redirected stream" therefore has to be enforced on the
// way OUT, over the child's own bytes as well as the supervisor's
function PWebCliDevStripAnsi(const Line: RawUtf8): RawUtf8;

/// True when Line is the host's one ratified acknowledgement,
/// `<prefix>: generation <N> loaded`
// - a pure function, so the shape is asserted by the headless suite rather
// than only observed in a running session
function PWebCliDevParseAck(const Line: RawUtf8;
  out Generation: Integer): Boolean;

/// the completion sentinel's native path beneath a frontend root
function PWebCliDevSentinelPath(const FrontendRoot: RawUtf8): RawUtf8;

/// the install record's native path beneath a frontend root
function PWebCliDevInstallRecordPath(const FrontendRoot: RawUtf8): RawUtf8;

/// does this frontend need `npm ci` before the loop can start
// - True when node_modules is absent, when the install record is absent or
// unreadable, when the lockfile's digest differs from the record, or when
// the `vite` / `tsc` entry point cannot be resolved. Reason names which
function PWebCliDevNeedsInstall(const NodePath, FrontendRoot: RawUtf8;
  out Reason: RawUtf8; out LockDigest: RawUtf8): Boolean;

/// run the whole development loop for an ALREADY OPENED project
// - Project.Refusal must be pcrNone; the caller owns discovery and parsing,
// exactly as `pweb run` and the C1 pipeline do
// - Notify receives every line; nil is allowed and means silence
function PWebCliRunDev(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Notify: TPWebCliDevNotify;
  Opaque: Pointer): TPWebCliDevResult;


implementation

function PWebCliDevStageName(Stage: TPWebCliDevStage): RawUtf8;
begin
  case Stage of
    pdvOpen:            Result := 'open';
    pdvToolchain:       Result := 'toolchain';
    pdvStageSdk:        Result := 'stage_sdk';
    pdvInstall:         Result := 'install';
    pdvTypecheck:       Result := 'typecheck';
    pdvCompile:         Result := 'compile';
    pdvWatch:           Result := 'watch';
    pdvFirstGeneration: Result := 'first_generation';
    pdvHost:            Result := 'host';
    pdvLoop:            Result := 'loop';
  else
    Result := 'stage';
  end;
end;

function PWebCliDevExitCode(Code: TPWebCliDevCode): Integer;
begin
  case Code of
    pdcOk:          Result := 0;
    pdcUsage:       Result := 2;
    pdcProject:     Result := 3;
    pdcUnavailable: Result := 4;
    pdcSetFailed:   Result := 5;
  else
    Result := 6;
  end;
end;

function PWebCliDevUiSupported(Ui: TPWebCliUi): Boolean;
begin
  // an explicit CASE over the ratified kinds with a refusing ELSE, rather
  // than `Ui in [puiReact, puiPas2js]`: the day schema 1 ratifies a third
  // kind, this answers False for it until a shard implements the loop, and
  // the refusal path stays exercised
  case Ui of
    puiReact,
    puiPas2js:
      Result := True;
  else
    Result := False;
  end;
end;

function PWebCliDevChangeDetection(Ui: TPWebCliUi): RawUtf8;
begin
  if Ui = puiPas2js then
    Result := 'cli_content_fingerprint_poll'
  else
    Result := 'vite_sentinel';
end;

function PWebCliDevStripAnsi(const Line: RawUtf8): RawUtf8;
var
  i, n: PtrInt;
  c: AnsiChar;
begin
  Result := '';
  i := 1;
  n := Length(Line);
  while i <= n do
  begin
    c := Line[i];
    if c = #27 then
    begin
      Inc(i);
      if i > n then
        break;
      case Line[i] of
        '[':
          begin
            // CSI: parameter and intermediate bytes, then ONE final byte in
            // 0x40..0x7E. An unterminated sequence consumes the rest of the
            // line, which is the fail-closed direction for this rule
            Inc(i);
            while (i <= n) and
                  (Line[i] >= #$20) and
                  (Line[i] <= #$3F) do
              Inc(i);
            if (i <= n) and
               (Line[i] >= #$40) and
               (Line[i] <= #$7E) then
              Inc(i);
          end;
        ']':
          begin
            // OSC: terminated by BEL or by ESC \
            Inc(i);
            while (i <= n) and
                  (Line[i] <> #7) do
            begin
              if (Line[i] = #27) and
                 (i < n) and
                 (Line[i + 1] = '\') then
              begin
                Inc(i, 2);
                break;
              end;
              Inc(i);
            end;
            if (i <= n) and
               (Line[i] = #7) then
              Inc(i);
          end;
      else
        // a two-byte escape: consume the one byte after ESC
        Inc(i);
      end;
      continue;
    end;
    // a bare control byte a terminal would act on has no business in a
    // forwarded line either; TAB and the printable range survive
    if (c < ' ') and
       (c <> #9) then
    begin
      Inc(i);
      continue;
    end;
    Result := Result + c;
    Inc(i);
  end;
end;

function PWebCliDevParseAck(const Line: RawUtf8;
  out Generation: Integer): Boolean;
var
  at, i, n: PtrInt;
  digits: RawUtf8;
begin
  Generation := 0;
  Result := False;
  // `<prefix>: generation <N> loaded`. The prefix is the application's own
  // name and is NEVER matched against: an acknowledgement is recognised by
  // its ratified shape, so a project called `generation` cannot break it
  at := PosEx(': generation ', Line);
  if at = 0 then
    exit;
  i := at + Length(': generation ');
  n := Length(Line);
  digits := '';
  while (i <= n) and
        (Line[i] >= '0') and
        (Line[i] <= '9') do
  begin
    digits := digits + Line[i];
    Inc(i);
  end;
  if (digits = '') or
     (Length(digits) > 9) then
    exit;
  if Copy(Line, i, MaxInt) <> ' loaded' then
    exit;
  Generation := StrToIntDef(string(digits), 0);
  Result := Generation > 0;
end;

function PWebCliDevSentinelPath(const FrontendRoot: RawUtf8): RawUtf8;
begin
  Result := PWebCliJoin(PWebCliJoin(PWebCliJoin(FrontendRoot,
    PWEB_FE_PWEB_DIR), PWEB_CLI_DEV_SENTINEL_DIR),
    PWEB_CLI_DEV_SENTINEL_FILE);
end;

function PWebCliDevInstallRecordPath(const FrontendRoot: RawUtf8): RawUtf8;
begin
  Result := PWebCliJoin(PWebCliJoin(PWebCliJoin(FrontendRoot,
    PWEB_FE_PWEB_DIR), PWEB_CLI_DEV_SENTINEL_DIR),
    PWEB_CLI_DEV_INSTALL_RECORD);
end;

// the sentinel's CONTENT, or '' when it is absent, unreadable or past its
// bound. '' is never equal to a written sentinel, so an unreadable one
// simply reads as "no build yet" rather than as a value
function ReadSmallText(const Path: RawUtf8): RawUtf8;
var
  content: RawByteString;
  tooBig: Boolean;
begin
  Result := '';
  if PWebCliNodeKind(Path) <> pcnFile then
    exit;
  if not PWebCliReadSmallFile(Path, PWEB_CLI_DEV_SMALL_FILE_MAX, content,
       tooBig) then
    exit;
  Result := TrimU(RawUtf8(content));
end;

function PWebCliDevNeedsInstall(const NodePath, FrontendRoot: RawUtf8;
  out Reason: RawUtf8; out LockDigest: RawUtf8): Boolean;
var
  lock: RawByteString;
  tooBig: Boolean;
  recorded: RawUtf8;
  cmd: TPWebCliCommand;
  refusal: TPWebCliFrontendRefusal;
begin
  Result := True;
  LockDigest := '';
  // the lockfile is the authority on WHAT should be installed, so its
  // digest is what the record records. An unreadable one forces the
  // install: a decision that cannot be made is made in the safe direction
  Reason := 'lockfile_unreadable';
  if not PWebCliReadSmallFile(
       PWebCliJoin(FrontendRoot, PWEB_CLI_DEV_LOCKFILE),
       PWEB_CLI_PIPE_MAX_FILE_BYTES, lock, tooBig) then
    exit;
  LockDigest := LowerCaseU(Sha256(lock));
  Reason := 'node_modules_absent';
  if PWebCliEntry(FrontendRoot, PWEB_FE_NODE_MODULES) <> pcnDirectory then
    exit;
  Reason := 'install_record_absent';
  recorded := ReadSmallText(PWebCliDevInstallRecordPath(FrontendRoot));
  if recorded = '' then
    exit;
  Reason := 'lockfile_changed';
  if recorded <> LockDigest then
    exit;
  // the record can be right and the tree still be unusable - a partial
  // removal, an interrupted install - so the two entry points this loop
  // actually runs are RESOLVED rather than assumed
  Reason := 'vite_absent';
  if not PWebCliViteCommand(NodePath, FrontendRoot, cmd, refusal) then
    exit;
  Reason := 'tsc_absent';
  if not PWebCliTypecheckCommand(NodePath, FrontendRoot, cmd, refusal) then
    exit;
  Reason := '';
  Result := False;
end;

type
  /// everything the two supervisor threads, the three sinks and the main
  // loop share. ONE record, passed by pointer, because the engine takes
  // plain procedures and an Opaque
  PDevShared = ^TDevShared;
  TDevShared = record
    Notify: TPWebCliDevNotify;
    Opaque: Pointer;
    /// every forwarded line goes through this, so two children writing at
    // once can never interleave inside one line
    OutLock: TOSLock;
    /// THE ONE STOP FLAG - see the unit header
    Stop: Boolean;
    /// how many generations the host has acknowledged
    Acked: Integer;
    /// the two long-lived members
    WatcherCmd: TPWebCliCommand;
    HostCmd: TPWebCliCommand;
    WatcherRes: TPWebCliExecResult;
    HostRes: TPWebCliExecResult;
    WatcherDone: Boolean;
    HostDone: Boolean;
    /// True when the member ended while NOBODY had asked the set to stop -
    // the whole difference between "it died" (DEV7 / DEV8, exit 5) and "we
    // stopped it" (DEV6, exit 0), recorded at the one instant it can be
    // told apart: immediately after the execution returned and BEFORE this
    // thread sets the flag itself
    WatcherSpontaneous: Boolean;
    HostSpontaneous: Boolean;
    WatcherPid: PtrInt;
    HostPid: PtrInt;
    HostTreeRoot: RawUtf8;
    WatcherTreeRoot: RawUtf8;
    /// the prefix the MAIN thread's short-lived child is forwarded under -
    // `npm: `, `tsc: `, `fpc: ` or `pack: `. One field rather than four
    // sinks, because only one such child runs at a time and it always runs
    // on the main thread
    StagePrefix: RawUtf8;
  end;

// the ONE stop question both long-lived executions are asked, on every
// pass: the installed console / signal handler, OR anything in this unit
// that decided the set must come down
function DevStopCheck(Opaque: Pointer): Boolean;
begin
  Result := PWebCliStopRequested;
  if (not Result) and
     (Opaque <> nil) then
    Result := PDevShared(Opaque)^.Stop;
end;

procedure DevSay(S: PDevShared; const Line: RawUtf8);
begin
  if not Assigned(S^.Notify) then
    exit;
  S^.OutLock.Lock;
  try
    S^.Notify(S^.Opaque, 'pweb: ' + Line, {FromChild=}False);
  finally
    S^.OutLock.UnLock;
  end;
end;

procedure DevForward(S: PDevShared; const Prefix, Line: RawUtf8;
  Truncated: Boolean);
var
  text: RawUtf8;
begin
  if not Assigned(S^.Notify) then
    exit;
  text := Prefix + PWebCliDevStripAnsi(Line);
  if Truncated then
    text := text + ' [truncated]';
  S^.OutLock.Lock;
  try
    S^.Notify(S^.Opaque, text, {FromChild=}True);
  finally
    S^.OutLock.UnLock;
  end;
end;

procedure DevWatcherSink(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
begin
  DevForward(PDevShared(Opaque), 'vite: ', Line, Truncated);
end;

procedure DevHostSink(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  s: PDevShared;
  gen: Integer;
begin
  s := PDevShared(Opaque);
  // THE ACKNOWLEDGEMENT, read from the engine's own line sink and from
  // nowhere else. The host writes nothing to a disk to report a switch
  if PWebCliDevParseAck(Line, gen) then
    if gen > s^.Acked then
      s^.Acked := gen;
  DevForward(s, 'app: ', Line, Truncated);
end;

procedure DevStageSink(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
begin
  DevForward(PDevShared(Opaque), PDevShared(Opaque)^.StagePrefix, Line,
    Truncated);
end;

procedure DevWatcherStarted(Opaque: Pointer; Pid: PtrInt);
begin
  PDevShared(Opaque)^.WatcherPid := Pid;
  // printed for the same reason the host's pid is, and in the same shape: a
  // supervisor of this supervisor has to be able to name the OTHER member
  // to prove what happens when it dies. Both members, or neither
  DevSay(PDevShared(Opaque), 'watch: started pid ' + RawUtf8(IntToStr(Pid)));
end;

procedure DevHostStarted(Opaque: Pointer; Pid: PtrInt);
begin
  PDevShared(Opaque)^.HostPid := Pid;
  // the pid, so a supervisor of the supervisor - the CAP-10C2 driver, a
  // script - can watch the APPLICATION itself and prove it did not restart
  // across a generation switch. `pweb run` prints the same line for the
  // same reason
  DevSay(PDevShared(Opaque), 'started pid ' + RawUtf8(IntToStr(Pid)));
end;

// ONE supervised member, run to completion on its own thread. Whatever
// happens, the stop flag is set on the way out: a member that ended is a
// set that has to come down, and the OTHER member's StopCheck reads this
// same flag on its very next pass
function DevWatcherThread(Param: Pointer): PtrInt;
var
  s: PDevShared;
  spec: TPWebCliExecSpec;
begin
  Result := 0;
  s := PDevShared(Param);
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := s^.WatcherCmd.Exe;
  spec.Args := s^.WatcherCmd.Args;
  spec.WorkDir := s^.WatcherCmd.WorkDir;
  spec.Profile := pepSupervise;
  spec.TimeoutMs := 0; // a watcher has no bound: it lives as long as the loop
  spec.Sink := @DevWatcherSink;
  spec.StopCheck := @DevStopCheck;
  spec.Started := @DevWatcherStarted;
  spec.Opaque := s;
  spec.TreeRoot := s^.WatcherTreeRoot;
  try
    s^.WatcherRes := PWebCliExecute(spec);
  finally
    // read BEFORE this thread sets the flag: after that instant nothing
    // can tell an external death from a requested stop
    s^.WatcherSpontaneous := not (PWebCliStopRequested or s^.Stop);
    s^.WatcherDone := True;
    s^.Stop := True;
  end;
end;

function DevHostThread(Param: Pointer): PtrInt;
var
  s: PDevShared;
  spec: TPWebCliExecSpec;
begin
  Result := 0;
  s := PDevShared(Param);
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := s^.HostCmd.Exe;
  spec.Args := s^.HostCmd.Args;
  spec.WorkDir := s^.HostCmd.WorkDir;
  spec.Profile := pepSupervise;
  spec.TimeoutMs := 0;
  spec.Sink := @DevHostSink;
  spec.StopCheck := @DevStopCheck;
  spec.Started := @DevHostStarted;
  spec.Opaque := s;
  spec.TreeRoot := s^.HostTreeRoot;
  try
    s^.HostRes := PWebCliExecute(spec);
  finally
    s^.HostSpontaneous := not (PWebCliStopRequested or s^.Stop);
    s^.HostDone := True;
    s^.Stop := True;
  end;
end;

function IntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

const
  /// the two words a Boolean observation is reported with, spelled once
  BOOL_TEXT: array[Boolean] of RawUtf8 = ('false', 'true');

function PWebCliRunDev(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Notify: TPWebCliDevNotify;
  Opaque: Pointer): TPWebCliDevResult;
var
  res: TPWebCliDevResult;
  shared: TDevShared;
  sharedInit: Boolean;
  excludes, prefixes, tokens: TRawUtf8DynArray;
  outputDir, targetDir, frontendRoot, sdkStageParent: RawUtf8;
  distDir, tmpDist, tmpAssets, sentinel, found: RawUtf8;
  lockDigest, installReason: RawUtf8;
  lastSentinel, seenSentinel: RawUtf8;
  // CAP-10C3: True for react - the branch that has a watcher child, a
  // sentinel, a Node toolchain and a staged TypeScript SDK. False is the
  // Pas2JS loop, which has none of those and owns its own detection
  isReact: Boolean;
  // the last input-set refusal REPORTED, so a set that stays unwalkable is
  // said once rather than four times a second
  lastInputRefusal: RawUtf8;
  stageRefusal: TPWebCliStageRefusal;
  devRefusal: TPWebCliDevLayoutRefusal;
  feRefusal: TPWebCliFrontendRefusal;
  cmd: TPWebCliCommand;
  layout: TPWebCliDevLayout;
  inputs: TPWebCliDevInputs;
  unreadable: Boolean;
  staged, files, i: Integer;
  digest: RawUtf8;
  watcherId, watcherHandle, hostId, hostHandle: system.TThreadID;
  watcherStarted, hostStarted: Boolean;
  watcherSpontaneous, hostSpontaneous: Boolean;
  deadline: Int64;

  function Refuse(Stage: TPWebCliDevStage; Code: TPWebCliDevCode;
    const Cause, Detail: RawUtf8): Boolean;
  begin
    res.Code := Code;
    res.FailedStage := Stage;
    res.Cause := Cause;
    res.Detail := Detail;
    if Assigned(Notify) then
      Notify(Opaque, 'pweb: ' + PWebCliDevStageName(Stage) + ': FAILED ' +
        Cause + ' ' + Detail, {FromChild=}False);
    Refuse := False;
  end;

  procedure Say(const Line: RawUtf8);
  begin
    if Assigned(Notify) then
      Notify(Opaque, 'pweb: ' + Line, {FromChild=}False);
  end;

  // ONE short-lived child, run synchronously on the MAIN thread, through
  // the one engine, in the supervise profile - the pack, and the start-up
  // stages before the loop exists
  function RunOnce(Stage: TPWebCliDevStage; const Command: TPWebCliCommand;
    TimeoutMs: Cardinal; const Prefix: RawUtf8;
    out ExecRes: TPWebCliExecResult): Boolean;
  var
    spec: TPWebCliExecSpec;
    a: PtrInt;
  begin
    ExecRes := Default(TPWebCliExecResult);
    // THE ARGUMENT FORM, checked where it cannot be forgotten - the C1
    // invariant, and it applies to a dev vector exactly as it applies to a
    // build one: `node \\?\C:\...` dies inside realpathSync
    for a := 0 to High(Command.Args) do
      if Copy(Command.Args[a], 1, 4) = '\\?\' then
      begin
        RunOnce := Refuse(Stage, pdcInternal, 'arg_longpath_form',
          IntText(a));
        exit;
      end;
    shared.StagePrefix := Prefix;
    spec := Default(TPWebCliExecSpec);
    spec.ExePath := Command.Exe;
    spec.Args := Command.Args;
    spec.WorkDir := Command.WorkDir;
    spec.Profile := pepSupervise;
    spec.TimeoutMs := TimeoutMs;
    spec.Sink := @DevStageSink;
    spec.StopCheck := @DevStopCheck;
    spec.Opaque := @shared;
    spec.TreeRoot := PWebCliDisplayPath(Command.WorkDir);
    ExecRes := PWebCliExecute(spec);
    RunOnce := (ExecRes.Outcome = pcoExited) and
      (ExecRes.ExitCode = 0);
  end;

  // the read-only half of the project, re-measured. Everything this loop
  // writes is already inside the C1 mutation set, and this is what proves it
  function TreeStillClean(Stage: TPWebCliDevStage): Boolean;
  begin
    TreeStillClean := False;
    if not PWebCliPipeTreeDigest(Project.Root, excludes, digest,
         stageRefusal) then
    begin
      Refuse(Stage, pdcInternal, 'dev_tree_unreadable',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    if digest <> res.TreeBefore then
    begin
      Refuse(Stage, pdcInternal, 'dev_mutation',
        PWebCliDevStageName(Stage));
      exit;
    end;
    res.TreeAfter := digest;
    TreeStillClean := True;
  end;

  function StillRunning(Stage: TPWebCliDevStage): Boolean;
  begin
    if PWebCliStopRequested then
    begin
      res.Interrupted := True;
      StillRunning := False;
      // an interrupt during the START-UP stages is a clean stop, not a
      // failure: nothing is running and nothing has been published
      res.Code := pdcOk;
      res.FailedStage := Stage;
      res.Cause := 'dev_interrupted';
      Say(PWebCliDevStageName(Stage) + ': interrupted');
      exit;
    end;
    StillRunning := True;
  end;

  // ONE generation: snapshot dist/, prove the snapshot consistent, pack it
  // with the frozen bundler, trim it, and publish it by ONE rename
  // - a failure here NEVER stops the loop; it is reported and the previous
  // generation stays live
  function MakeGeneration(N: Integer): Boolean;
  var
    packRes: TPWebCliExecResult;
    before, after: RawUtf8;
    attempt: Integer;
    t0: Int64;
  begin
    MakeGeneration := False;
    t0 := GetTickCount64();
    for attempt := 1 to PWEB_CLI_DEV_SNAPSHOT_TRIES do
    begin
      if not PWebCliDevBeginGeneration(layout, tmpDist, devRefusal) then
      begin
        Say('generation ' + IntText(N) + ' refused: ' +
          PWebCliDevLayoutRefusalText(devRefusal));
        exit;
      end;
      // THE SNAPSHOT IS PROVED CONSISTENT: the sentinel is read, the copy
      // is made, and the sentinel is read AGAIN. A value that moved means
      // the watcher rebuilt underneath the copy, so the copy is discarded
      // rather than packed
      before := ReadSmallText(sentinel);
      if not PWebCliDevSnapshotDist(layout, distDir, files, devRefusal) then
      begin
        Say('generation ' + IntText(N) + ' snapshot failed: ' +
          PWebCliDevLayoutRefusalText(devRefusal));
        PWebCliDevDiscardGeneration(layout, devRefusal);
        exit;
      end;
      after := ReadSmallText(sentinel);
      if after = before then
        break;
      Inc(res.RetakenSnapshots);
      PWebCliDevDiscardGeneration(layout, devRefusal);
      if attempt = PWEB_CLI_DEV_SNAPSHOT_TRIES then
      begin
        Say('generation ' + IntText(N) +
          ' abandoned: the frontend rebuilt faster than it could be copied');
        exit;
      end;
    end;
    seenSentinel := after;
    // THE FROZEN CAP-6 BUNDLER, with the whole of its argument contract
    // and nothing added. Every generation is an app.pwb, in development
    // exactly as in production, which is why loose_assets_used is false here
    cmd := PWebCliPackCommand(res.Sdk.Bundler, tmpDist,
      PWebCliDevTmpBundle(layout), Project.Root);
    res.PackCommand := PWebCliCommandText(cmd, prefixes, tokens);
    if not RunOnce(pdvLoop, cmd, PWEB_CLI_PIPE_PACK_MS, 'pack: ',
         packRes) then
    begin
      Inc(res.PackFailures);
      Say('generation ' + IntText(N) + ' pack failed (' +
        PWebCliChildOutcomeText(packRes.Outcome) + ' ' +
        IntText(packRes.ExitCode) + '); the previous generation stays live');
      PWebCliDevDiscardGeneration(layout, devRefusal);
      // reset the refusal the caller would otherwise inherit: a pack
      // failure is a fact, never this run's exit category
      res.Code := pdcOk;
      res.Cause := '';
      res.Detail := '';
      exit;
    end;
    if not PWebCliDevTrimGeneration(layout, devRefusal) then
    begin
      Say('generation ' + IntText(N) + ' trim failed: ' +
        PWebCliDevLayoutRefusalText(devRefusal));
      PWebCliDevDiscardGeneration(layout, devRefusal);
      exit;
    end;
    if not PWebCliDevPublishGeneration(layout, N, devRefusal) then
    begin
      Say('generation ' + IntText(N) + ' publish failed: ' +
        PWebCliDevLayoutRefusalText(devRefusal));
      PWebCliDevDiscardGeneration(layout, devRefusal);
      exit;
    end;
    res.Published_ := N;
    // EXACTLY ONE LINE PER GENERATION, in the ratified shape
    Say('generation ' + IntText(N) + ' ready (' +
      IntText(GetTickCount64() - t0) + ' ms)');
    MakeGeneration := True;
  end;

  // wait until the sentinel differs from Last, or the bound expires
  function WaitForSentinel(Last: RawUtf8; BoundMs: Int64;
    out Current: RawUtf8): Boolean;
  var
    limit: Int64;
  begin
    limit := GetTickCount64() + BoundMs;
    repeat
      Current := ReadSmallText(sentinel);
      if (Current <> '') and
         (Current <> Last) then
        exit(True);
      if DevStopCheck(@shared) then
        exit(False);
      Sleep(PWEB_CLI_DEV_SENTINEL_POLL_MS);
    until GetTickCount64() > limit;
    Current := ReadSmallText(sentinel);
    Result := (Current <> '') and
      (Current <> Last);
  end;

  // the DEBOUNCE: after a change, wait and re-read; a further change
  // restarts the wait, bounded so a continuously-written file cannot
  // postpone a generation forever
  function Settle(var Current: RawUtf8): RawUtf8;
  var
    hardLimit, quietUntil: Int64;
    latest: RawUtf8;
  begin
    hardLimit := GetTickCount64() + PWEB_CLI_DEV_DEBOUNCE_MAX_MS;
    quietUntil := GetTickCount64() + PWEB_CLI_DEV_DEBOUNCE_MS;
    while (GetTickCount64() < quietUntil) and
          (GetTickCount64() < hardLimit) do
    begin
      if DevStopCheck(@shared) then
        break;
      Sleep(PWEB_CLI_DEV_SENTINEL_POLL_MS);
      latest := ReadSmallText(sentinel);
      if (latest <> '') and
         (latest <> Current) then
      begin
        Current := latest;
        Inc(res.Rebuilds);
        quietUntil := GetTickCount64() + PWEB_CLI_DEV_DEBOUNCE_MS;
      end;
    end;
    Settle := Current;
  end;

  { --- CAP-10C3: the Pas2JS half ---------------------------------------- }

  // ONE walk of the ratified input set, answering the CONTENT fingerprint.
  // A refusal answers '' and is REPORTED once per distinct cause: at
  // start-up the caller turns that into exit 3, and inside the loop it means
  // "no change I can see", which keeps the previous generation live exactly
  // as a compile error does
  function ScanInputs: RawUtf8;
  var
    scan: TPWebCliDevInputs;
    text: RawUtf8;
  begin
    if PWebCliDevInputScan(frontendRoot, scan) then
    begin
      res.WatchedInputs := scan.Files;
      lastInputRefusal := '';
      ScanInputs := scan.Fingerprint;
      exit;
    end;
    text := PWebCliDevInputRefusalText(scan.Refusal) + ' ' + scan.Detail;
    if text <> lastInputRefusal then
    begin
      lastInputRefusal := text;
      Say('the input set could not be read: ' + text);
    end;
    ScanInputs := '';
  end;

  // wait until the input fingerprint differs from Last, or the bound expires
  function WaitForInputs(const Last: RawUtf8; BoundMs: Int64;
    out Current: RawUtf8): Boolean;
  var
    limit: Int64;
  begin
    limit := GetTickCount64() + BoundMs;
    repeat
      Current := ScanInputs;
      if (Current <> '') and
         (Current <> Last) then
        exit(True);
      if DevStopCheck(@shared) then
        exit(False);
      Sleep(PWEB_CLI_DEV_POLL_MS);
    until GetTickCount64() > limit;
    Current := ScanInputs;
    Result := (Current <> '') and
      (Current <> Last);
  end;

  // the DEBOUNCE, over the fingerprint instead of the sentinel: identical
  // rule, identical bounds, identical reason - an editor's save is not one
  // write, and a developer's five keystrokes are not five generations
  function SettleInputs(var Current: RawUtf8): RawUtf8;
  var
    hardLimit, quietUntil: Int64;
    latest: RawUtf8;
  begin
    hardLimit := GetTickCount64() + PWEB_CLI_DEV_DEBOUNCE_MAX_MS;
    quietUntil := GetTickCount64() + PWEB_CLI_DEV_DEBOUNCE_MS;
    while (GetTickCount64() < quietUntil) and
          (GetTickCount64() < hardLimit) do
    begin
      if DevStopCheck(@shared) then
        break;
      Sleep(PWEB_CLI_DEV_POLL_MS);
      latest := ScanInputs;
      if (latest <> '') and
         (latest <> Current) then
      begin
        Current := latest;
        Inc(res.Rebuilds);
        quietUntil := GetTickCount64() + PWEB_CLI_DEV_DEBOUNCE_MS;
      end;
    end;
    SettleInputs := Current;
  end;

  // ONE Pas2JS generation: fingerprint, compile with the EXACT CAP-10C1
  // argument vector, run the EXACT CAP-10C1 assembly, prove the inputs did
  // not move across either, pack with the frozen bundler and publish by ONE
  // rename
  // - a failure here NEVER stops the loop; it is reported and the previous
  // generation stays live
  function MakePas2jsGeneration(N: Integer): Boolean;
  var
    childRes: TPWebCliExecResult;
    before, after: RawUtf8;
    attempt: Integer;
    t0: Int64;
  begin
    MakePas2jsGeneration := False;
    after := '';
    t0 := GetTickCount64();
    for attempt := 1 to PWEB_CLI_DEV_SNAPSHOT_TRIES do
    begin
      if not PWebCliDevBeginGeneration(layout, tmpDist, devRefusal) then
      begin
        Say('generation ' + IntText(N) + ' refused: ' +
          PWebCliDevLayoutRefusalText(devRefusal));
        exit;
      end;
      // the compiler writes STRAIGHT INTO the generation under
      // construction. React needs a copy because `vite --watch` owns
      // frontend/dist and may be writing it; pas2js has no concurrent
      // writer, so the generation IS the output directory and the
      // consistency question is about the INPUTS instead
      if not PWebCliPipeEnsureDir(tmpDist, PWEB_FE_ASSETS, tmpAssets,
           stageRefusal) then
      begin
        Say('generation ' + IntText(N) + ' refused: ' +
          PWebCliStageRefusalText(stageRefusal));
        PWebCliDevDiscardGeneration(layout, devRefusal);
        exit;
      end;
      before := ScanInputs;
      if before = '' then
      begin
        PWebCliDevDiscardGeneration(layout, devRefusal);
        exit;
      end;
      // THE INPUT STATE THIS ATTEMPT ANSWERS, recorded before the attempt
      // rather than after it. Every failure path below leaves it standing,
      // and the loop treats it as consumed - so a source that does not
      // compile is answered ONCE and not rebuilt every few seconds forever.
      // MEASURED on windows-x86_64 before this line existed: one broken
      // `const` recompiled the whole frontend indefinitely, printing the
      // same failure each time. React needs no equivalent because Vite's
      // `writeBundle` does not fire on a failed build, so a broken source
      // produces no new sentinel at all.
      // It is `before` and never a fresh scan taken afterwards: a fix that
      // landed DURING the failed compile must still look like a change on
      // the next pass, and it does exactly because this value predates it
      seenSentinel := before;
      if not PWebCliPas2jsCommand(res.Toolset.Pas2js.Path, frontendRoot,
           res.Sdk.Pas2jsSdk, PWebCliJoin(tmpAssets, PWEB_FE_APP_JS),
           Project, cmd, feRefusal) then
      begin
        Say('generation ' + IntText(N) + ' refused: ' +
          PWebCliFrontendRefusalText(feRefusal));
        PWebCliDevDiscardGeneration(layout, devRefusal);
        exit;
      end;
      res.BuildCommand := PWebCliCommandText(cmd, prefixes, tokens);
      // A COMPILE ERROR IS SOMETHING A DEVELOPER FIXES IN THE NEXT
      // KEYSTROKE. The compiler's own output has already been forwarded,
      // prefixed and stripped of ANSI, by the sink
      if not RunOnce(pdvLoop, cmd, PWEB_CLI_PIPE_BUILD_MS, 'pas2js: ',
           childRes) then
      begin
        Inc(res.BuildFailures);
        Say('generation ' + IntText(N) + ' compile failed (' +
          PWebCliChildOutcomeText(childRes.Outcome) + ' ' +
          IntText(childRes.ExitCode) +
          '); the previous generation stays live');
        PWebCliDevDiscardGeneration(layout, devRefusal);
        // reset the refusal the caller would otherwise inherit: a compile
        // failure is a fact, never this run's exit category
        res.Code := pdcOk;
        res.Cause := '';
        res.Detail := '';
        exit;
      end;
      // THE CAP-10C1 ASSEMBLY, called and never re-implemented: strip the
      // BOM, strip EVERY CR, write assets/boot.js byte-exactly and place
      // index.html and assets/app.css. This is what makes generation 1's
      // archive byte-identical to the pipeline's for the same sources
      if not PWebCliAssemblePas2jsDist(frontendRoot, tmpDist,
           res.Normalisation, feRefusal) then
      begin
        Say('generation ' + IntText(N) + ' assembly failed: ' +
          PWebCliFrontendRefusalText(feRefusal));
        PWebCliDevDiscardGeneration(layout, devRefusal);
        exit;
      end;
      // WHAT THE ASSEMBLY HAD TO NORMALISE, said ONCE per session. CAP-10B2
      // measured that the compiler writes through the host's text layer -
      // BOM and CRLF on Windows, LF on POSIX - and this is the line that
      // says the development loop stripped the same bytes the pipeline
      // strips, on this target, rather than leaving it to be inferred from
      // an archive digest that happens to match
      if N = 1 then
        Say('assembly: bom=' + BOOL_TEXT[res.Normalisation.HadBom] +
          ' cr=' + BOOL_TEXT[res.Normalisation.HadCr]);
      // THE CONSISTENCY RULE: the fingerprint is re-taken AFTER the
      // assembly, so a generation is packed only when its inputs were
      // stable across the compile AND the assembly
      after := ScanInputs;
      if after = '' then
      begin
        PWebCliDevDiscardGeneration(layout, devRefusal);
        exit;
      end;
      if after = before then
        break;
      Inc(res.RetakenSnapshots);
      Say('generation ' + IntText(N) +
        ' discarded: the inputs moved during the build (' +
        IntText(attempt) + '/' + IntText(PWEB_CLI_DEV_SNAPSHOT_TRIES) + ')');
      PWebCliDevDiscardGeneration(layout, devRefusal);
      if attempt = PWEB_CLI_DEV_SNAPSHOT_TRIES then
      begin
        Say('generation ' + IntText(N) +
          ' abandoned: the sources changed faster than they could be built');
        exit;
      end;
    end;
    seenSentinel := after;
    // THE FROZEN CAP-6 BUNDLER, with the whole of its argument contract and
    // nothing added - the same call the React branch makes, over a dist the
    // compiler wrote instead of one that was copied
    cmd := PWebCliPackCommand(res.Sdk.Bundler, tmpDist,
      PWebCliDevTmpBundle(layout), Project.Root);
    res.PackCommand := PWebCliCommandText(cmd, prefixes, tokens);
    if not RunOnce(pdvLoop, cmd, PWEB_CLI_PIPE_PACK_MS, 'pack: ',
         childRes) then
    begin
      Inc(res.PackFailures);
      Say('generation ' + IntText(N) + ' pack failed (' +
        PWebCliChildOutcomeText(childRes.Outcome) + ' ' +
        IntText(childRes.ExitCode) + '); the previous generation stays live');
      PWebCliDevDiscardGeneration(layout, devRefusal);
      res.Code := pdcOk;
      res.Cause := '';
      res.Detail := '';
      exit;
    end;
    if not PWebCliDevTrimGeneration(layout, devRefusal) then
    begin
      Say('generation ' + IntText(N) + ' trim failed: ' +
        PWebCliDevLayoutRefusalText(devRefusal));
      PWebCliDevDiscardGeneration(layout, devRefusal);
      exit;
    end;
    if not PWebCliDevPublishGeneration(layout, N, devRefusal) then
    begin
      Say('generation ' + IntText(N) + ' publish failed: ' +
        PWebCliDevLayoutRefusalText(devRefusal));
      PWebCliDevDiscardGeneration(layout, devRefusal);
      exit;
    end;
    res.Published_ := N;
    // EXACTLY ONE LINE PER GENERATION, in the ratified shape - the same
    // line the React branch prints, because a developer reading it should
    // not have to know which frontend produced it
    Say('generation ' + IntText(N) + ' ready (' +
      IntText(GetTickCount64() - t0) + ' ms)');
    MakePas2jsGeneration := True;
  end;

  { --- the two branches, behind one loop -------------------------------- }

  function WaitForChange(const Last: RawUtf8; BoundMs: Int64;
    out Current: RawUtf8): Boolean;
  begin
    if isReact then
      WaitForChange := WaitForSentinel(Last, BoundMs, Current)
    else
      WaitForChange := WaitForInputs(Last, BoundMs, Current);
  end;

  function SettleChange(var Current: RawUtf8): RawUtf8;
  begin
    if isReact then
      SettleChange := Settle(Current)
    else
      SettleChange := SettleInputs(Current);
  end;

  function MakeAnyGeneration(N: Integer): Boolean;
  begin
    if isReact then
      MakeAnyGeneration := MakeGeneration(N)
    else
      MakeAnyGeneration := MakePas2jsGeneration(N);
  end;

begin
  res := Default(TPWebCliDevResult);
  res.Code := pdcOk;
  res.NetworkStages := 'none';
  Result := res;
  sharedInit := False;
  watcherStarted := False;
  hostStarted := False;
  watcherSpontaneous := False;
  hostSpontaneous := False;
  watcherHandle := system.TThreadID(0);
  hostHandle := system.TThreadID(0);
  layout := Default(TPWebCliDevLayout);
  try
    shared := Default(TDevShared);
    shared.Notify := Notify;
    shared.Opaque := Opaque;
    shared.OutLock.Init;
    sharedInit := True;

    { --- 1. open --------------------------------------------------------- }
    if Project.Refusal <> pcrNone then
    begin
      Refuse(pdvOpen, pdcProject,
        PWebCliProjectRefusalText(Project.Refusal), Project.Detail);
      exit;
    end;
    // THE UNSUPPORTED-UI REFUSAL, before anything is resolved, started or
    // written. The command line was well formed and the destination is a
    // real project: what this build's dev loop does not implement is the
    // declared `ui`, which is a PROJECT fact and exit 3. CAP-10C2
    // implemented react and CAP-10C3 pas2js, so no ratified kind reaches it
    // today - and it stays here, and under test, for the next one
    if not PWebCliDevUiSupported(Project.Ui) then
    begin
      Refuse(pdvOpen, pdcProject, 'dev_ui_unsupported',
        PWebCliUiText(Project.Ui));
      exit;
    end;
    res.Ui := Project.Ui;
    isReact := Project.Ui = puiReact;
    res.ChangeDetection := PWebCliDevChangeDetection(Project.Ui);
    excludes := PWebCliMutationSet(Project);
    if not PWebCliPipeTreeDigest(Project.Root, excludes, res.TreeBefore,
         stageRefusal) then
    begin
      Refuse(pdvOpen, pdcInternal, 'dev_tree_unreadable',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    res.TreeAfter := '';
    if PWebCliRegistryOverridePresent(Project.Root, excludes, found,
         unreadable) then
    begin
      Refuse(pdvOpen, pdcProject,
        PWebCliFrontendRefusalText(pfrRegistryOverride), found);
      exit;
    end;
    if unreadable then
    begin
      Refuse(pdvOpen, pdcInternal, 'dev_tree_unreadable', 'registry');
      exit;
    end;
    frontendRoot := Project.FrontendRootPath.Full;
    distDir := PWebCliJoin(frontendRoot, PWEB_FE_DIST);
    sentinel := PWebCliDevSentinelPath(frontendRoot);
    // THE INPUT SET IS WALKED ONCE, HERE, BEFORE ANYTHING IS RESOLVED,
    // STARTED OR WRITTEN. A link inside it, a set past its bounds or a
    // directory nobody can enumerate is a PROJECT fact and exit 3 - and it
    // is discovered before the toolchain, not four minutes into a compile
    if not isReact then
    begin
      if not PWebCliDevInputScan(frontendRoot, inputs) then
      begin
        Refuse(pdvOpen, pdcProject,
          PWebCliDevInputRefusalText(inputs.Refusal), inputs.Detail);
        exit;
      end;
      res.WatchedInputs := inputs.Files;
    end;

    { --- 2. toolchain: refuse before any write --------------------------- }
    Say(PWebCliDevStageName(pdvToolchain) + ': start');
    res.Toolset := PWebCliResolveToolset(Project, Os, Arch);
    if res.Toolset.Refusal <> ptrNone then
    begin
      if res.Toolset.Refusal = ptrDoctorRefused then
        Refuse(pdvToolchain, pdcUnavailable, res.Toolset.DoctorCause,
          res.Toolset.DoctorRow)
      else
        Refuse(pdvToolchain, pdcUnavailable,
          PWebCliToolRefusalText(res.Toolset.Refusal),
          PWebCliToolKindText(res.Toolset.Failed));
      exit;
    end;
    // the SDK a Pas2JS build needs is a DIFFERENT one: sdk/pas2js/
    // pweb.native.pas rather than the TypeScript tree, and the layout
    // resolver is told which by the descriptor's own `ui`
    if not PWebCliSdkLayout(Os, Arch, Project.Ui = puiPas2js, res.Sdk) then
    begin
      res.Sdk.Target := PWebCliRunTargetName(Os, Arch);
      Refuse(pdvToolchain, pdcUnavailable,
        PWebSdkLayoutRefusalText(res.Sdk.Refusal), res.Sdk.Detail);
      exit;
    end;
    PWebCliPipeRedactions(Project, res.Sdk, res.Toolset, prefixes, tokens);
    if not PWebCliPipeEnsurePath(Project.Root, Project.Output, outputDir,
         stageRefusal) or
       not PWebCliPipeEnsureDir(outputDir, res.Sdk.Target, targetDir,
         stageRefusal) then
    begin
      Refuse(pdvToolchain, pdcProject, 'output_unwritable', Project.Output);
      exit;
    end;
    Say(PWebCliDevStageName(pdvToolchain) + ': ok');
    if not StillRunning(pdvToolchain) then
      exit;

    { --- 3, 4 and 5 are the REACT prerequisites, and a Pas2JS project has
            none of them: no TypeScript SDK to stage, no lockfile to install
            from, no Node at any point, and therefore NO STAGE THAT COULD
            REACH THE NETWORK. `network_stages` stays `none` by construction
            rather than by policy -------------------------------------------}
    if not isReact then
      Say(PWebCliDevStageName(pdvStageSdk) + ', ' +
        PWebCliDevStageName(pdvInstall) + ' and ' +
        PWebCliDevStageName(pdvTypecheck) +
        ': not applicable (pas2js needs no node toolchain)');
    if isReact then
    begin

    { --- 3. the staged TypeScript SDK, on EVERY start --------------------- }
    Say(PWebCliDevStageName(pdvStageSdk) + ': start');
    if not PWebCliPipeEnsurePath(frontendRoot,
         PWEB_FE_PWEB_DIR + '/' + PWEB_FE_SDK_DIR, sdkStageParent,
         stageRefusal) then
    begin
      Refuse(pdvStageSdk, pdcInternal, 'stage_sdk_dir',
        PWebCliStageRefusalText(stageRefusal));
      exit;
    end;
    if not PWebCliStageTsSdk(res.Sdk.TypeScriptSdk, sdkStageParent,
         PWEB_FE_TS_DIR, staged, stageRefusal) then
    begin
      Refuse(pdvStageSdk, pdcInternal,
        PWebCliStageRefusalText(stageRefusal), IntText(staged));
      exit;
    end;
    Say(PWebCliDevStageName(pdvStageSdk) + ': ' + IntText(staged) +
      ' file(s)');
    if not TreeStillClean(pdvStageSdk) then
      exit;
    if not StillRunning(pdvStageSdk) then
      exit;

    { --- 4. install, CONDITIONALLY, and the ONE stage that may reach the
            network -------------------------------------------------------- }
    if PWebCliDevNeedsInstall(res.Toolset.Node.Path, frontendRoot,
         installReason, lockDigest) then
    begin
      res.InstallReason := installReason;
      res.NetworkStages := 'npm_ci';
      Say(PWebCliDevStageName(pdvInstall) + ': start (' + installReason +
        ')');
      cmd := PWebCliNpmCiCommand(res.Toolset.Node.Path,
        res.Toolset.Npm.Script, frontendRoot);
      if not RunOnce(pdvInstall, cmd, PWEB_CLI_PIPE_NPM_MS, 'npm: ',
           shared.WatcherRes) then
      begin
        Refuse(pdvInstall, pdcSetFailed, 'stage_exited',
          IntText(shared.WatcherRes.ExitCode));
        exit;
      end;
      // the record is written only AFTER a successful install, so an
      // interrupted one is re-run rather than remembered as done.
      // MEASURED: its directory is `<frontend>/.pweb/dev`, which the
      // template's sentinel plugin creates at BUILD time - and the install
      // stage runs before any build has happened, so on a first start the
      // parent did not exist and the exclusive writer refused. It is
      // ensured here, through the same one-level-at-a-time primitive every
      // other directory in this loop goes through
      if not PWebCliPipeEnsurePath(frontendRoot,
           PWEB_FE_PWEB_DIR + '/' + PWEB_CLI_DEV_SENTINEL_DIR, found,
           stageRefusal) then
        Say(PWebCliDevStageName(pdvInstall) +
          ': the install record directory could not be created');
      PWebCliDeleteFile(PWebCliDevInstallRecordPath(frontendRoot));
      if not PWebCliWriteNewFile(
           PWebCliDevInstallRecordPath(frontendRoot),
           RawByteString(lockDigest + #10), {SetExecBit=}False) then
        Say(PWebCliDevStageName(pdvInstall) +
          ': the install record could not be written; the next start ' +
          'will install again');
      if not TreeStillClean(pdvInstall) then
        exit;
    end
    else
      Say(PWebCliDevStageName(pdvInstall) +
        ': skipped (node_modules and the lockfile agree)');
    if not StillRunning(pdvInstall) then
      exit;

    { --- 5. typecheck, ONCE, at start ------------------------------------- }
    Say(PWebCliDevStageName(pdvTypecheck) + ': start');
    if not PWebCliTypecheckCommand(res.Toolset.Node.Path, frontendRoot,
         cmd, feRefusal) then
    begin
      Refuse(pdvTypecheck, pdcUnavailable,
        PWebCliFrontendRefusalText(feRefusal), '');
      exit;
    end;
    if not RunOnce(pdvTypecheck, cmd, PWEB_CLI_PIPE_TSC_MS, 'tsc: ',
         shared.WatcherRes) then
    begin
      Refuse(pdvTypecheck, pdcSetFailed, 'stage_exited',
        IntText(shared.WatcherRes.ExitCode));
      exit;
    end;
    if not TreeStillClean(pdvTypecheck) then
      exit;
    if not StillRunning(pdvTypecheck) then
      exit;

    end; { isReact }

    { --- 6. the DEV native compile, into its OWN directories -------------- }
    Say(PWebCliDevStageName(pdvCompile) + ': start');
    layout := PWebCliDevEnsureLayout(Project, Os, Arch, targetDir);
    if layout.Refusal <> pdlNone then
    begin
      Refuse(pdvCompile, pdcInternal,
        PWebCliDevLayoutRefusalText(layout.Refusal), layout.Detail);
      exit;
    end;
    cmd := PWebCliFpcDevCommand(res.Toolset.Fpc.Path, Project, res.Sdk,
      Os, Arch, layout.UnitDir, layout.ObjDir,
      Project.NativeProgramPath.Full);
    res.CompileCommand := PWebCliCommandText(cmd, prefixes, tokens);
    Say(PWebCliDevStageName(pdvCompile) + ': ' + res.CompileCommand);
    if not RunOnce(pdvCompile, cmd, PWEB_CLI_PIPE_FPC_MS, 'fpc: ',
         shared.WatcherRes) then
    begin
      Refuse(pdvCompile, pdcSetFailed, 'stage_exited',
        IntText(shared.WatcherRes.ExitCode));
      exit;
    end;
    if not PWebCliDevStageApp(Project, res.Sdk, Os, Arch, layout) then
    begin
      Refuse(pdvCompile, pdcInternal,
        PWebCliDevLayoutRefusalText(layout.Refusal), layout.Detail);
      exit;
    end;
    res.DevLayout := layout;
    if not TreeStillClean(pdvCompile) then
      exit;
    Say(PWebCliDevStageName(pdvCompile) + ': ' + layout.LaunchLogical);
    if not StillRunning(pdvCompile) then
      exit;

    { --- 7. the change source --------------------------------------------- }
    // REACT: a supervised watcher child, whose completed builds ARE the
    // signal. PAS2JS: no child at all - this CLI walks the ratified input
    // set itself, so the supervised set has ONE long-lived member and the
    // detector is a loop rather than a process
    if isReact then
    begin
      // the sentinel is REMOVED first, so the watcher's own initial build is
      // generation 1 rather than a one-shot build plus an identical rebuild
      PWebCliDeleteFile(sentinel);
      if not PWebCliViteCommand(res.Toolset.Node.Path, frontendRoot, cmd,
           feRefusal) then
      begin
        Refuse(pdvWatch, pdcUnavailable,
          PWebCliFrontendRefusalText(feRefusal), '');
        exit;
      end;
      // the RELEASE vector plus one element, so the watcher is provably the
      // same build the pipeline runs and not a second configuration
      SetLength(cmd.Args, Length(cmd.Args) + 1);
      cmd.Args[High(cmd.Args)] := '--watch';
      shared.WatcherCmd := cmd;
      shared.WatcherTreeRoot := PWebCliDisplayPath(frontendRoot);
      res.WatcherCommand := PWebCliCommandText(cmd, prefixes, tokens);
      Say(PWebCliDevStageName(pdvWatch) + ': ' + res.WatcherCommand);
      watcherHandle := BeginThread(@DevWatcherThread, @shared, watcherId);
      watcherStarted := watcherHandle <> system.TThreadID(0);
      if not watcherStarted then
      begin
        Refuse(pdvWatch, pdcUnavailable, 'dev_thread_unavailable',
          'watcher');
        exit;
      end;
    end
    else
      Say(PWebCliDevStageName(pdvWatch) + ': ' + res.ChangeDetection +
        ' over ' + IntText(res.WatchedInputs) + ' input(s)');

    { --- 8. the first generation, BEFORE the host ------------------------- }
    lastSentinel := '';
    if isReact then
    begin
      if not WaitForSentinel(lastSentinel, PWEB_CLI_DEV_FIRST_BUILD_MS,
           seenSentinel) then
      begin
        if PWebCliStopRequested then
        begin
          res.Interrupted := True;
          res.Cause := 'dev_interrupted';
          Say('interrupted before the first generation');
        end
        else
          Refuse(pdvFirstGeneration, pdcSetFailed, 'dev_first_build',
            IntText(PWEB_CLI_DEV_FIRST_BUILD_MS));
        shared.Stop := True;
        exit;
      end;
      Inc(res.Rebuilds);
      seenSentinel := Settle(seenSentinel);
    end
    else
      // PAS2JS: there is nothing to wait FOR. The first generation is
      // simply the first build, and it happens here - before the host
      // starts, so the host never opens on an empty store
      Inc(res.Rebuilds);
    if not MakeAnyGeneration(1) then
    begin
      Refuse(pdvFirstGeneration, pdcSetFailed, 'dev_first_generation', '');
      shared.Stop := True;
      exit;
    end;
    // CONSUMED MEANS PACKED. The generation builder sets seenSentinel to
    // the value its CONSISTENT snapshot corresponds to, and that - never
    // the value the debounce last saw - is what this loop may treat as
    // done. See the loop below for the race this closes.
    lastSentinel := seenSentinel;

    { --- 9. the host ------------------------------------------------------ }
    shared.HostCmd := Default(TPWebCliCommand);
    shared.HostCmd.Exe := layout.LaunchExe;
    SetLength(shared.HostCmd.Args, 1);
    // THE ONE ARGUMENT the dev host takes, and the one it refuses to start
    // without. Nothing else is passed: this is not a pass-through
    shared.HostCmd.Args[0] := '--pweb-dev-root=' +
      PWebCliArgPath(layout.DevDir);
    // the application's OWN directory, exactly as `pweb run` starts one
    if not PWebCliSplitLast(layout.LaunchExe, shared.HostCmd.WorkDir,
         found) then
      shared.HostCmd.WorkDir := layout.AppDir;
    shared.HostTreeRoot := PWebCliDisplayPath(shared.HostCmd.WorkDir);
    res.HostCommand := PWebCliCommandText(shared.HostCmd, prefixes, tokens);
    Say(PWebCliDevStageName(pdvHost) + ': ' + res.HostCommand);
    hostHandle := BeginThread(@DevHostThread, @shared, hostId);
    hostStarted := hostHandle <> system.TThreadID(0);
    if not hostStarted then
    begin
      Refuse(pdvHost, pdcUnavailable, 'dev_thread_unavailable', 'host');
      shared.Stop := True;
      exit;
    end;

    { --- 10. the loop ----------------------------------------------------- }
    Say('watching for changes; press Ctrl+C to stop');
    i := 1;
    while not DevStopCheck(@shared) do
    begin
      if WaitForChange(lastSentinel, PWEB_CLI_DEV_SENTINEL_POLL_MS * 4,
           seenSentinel) then
      begin
        Inc(res.Rebuilds);
        // THE DEBOUNCE DOES NOT CONSUME. It waits for quiet and reports the
        // newest sentinel it saw, and `lastSentinel` is deliberately NOT
        // advanced to it here: a value the debounce observed is not a value
        // this loop has PACKED.
        //
        // MEASURED on linux-x86_64, and intermittent, which is what made it
        // worth chasing: under five edits arriving faster than one rebuild,
        // the debounce would settle on the newest sentinel, the pack would
        // take a consistent snapshot of an EARLIER build, and the newest
        // build's output would then never be packed at all - the loop had
        // already recorded its sentinel as seen. The published generation
        // was whole and internally consistent; it simply was not the last
        // thing the developer wrote, which is the one property a
        // rebuild-and-reload loop cannot get wrong.
        seenSentinel := SettleChange(seenSentinel);
        if DevStopCheck(@shared) then
          break;
        Inc(i);
        if i > PWEB_CLI_DEV_MAX_GENERATIONS then
        begin
          Refuse(pdvLoop, pdcInternal, 'dev_generation_bound', IntText(i));
          break;
        end;
        if MakeAnyGeneration(i) then
        begin
          // CONSUMED MEANS PACKED: the value this generation's CONSISTENT
          // snapshot actually corresponds to - the sentinel Vite last wrote
          // for React, the input fingerprint proved stable across the
          // compile and the assembly for Pas2JS. A build or an edit that
          // landed after it leaves a NEWER value behind, and the next pass
          // sees that as a change and publishes it - which is how the
          // developer's last edit always reaches the window, however fast
          // the edits came
          lastSentinel := seenSentinel;
          // the acknowledgement, from the engine's own line sink. It is
          // BOUNDED and never fatal: a switch that was not acknowledged is
          // a fact worth printing, not a reason to stop a live application
          deadline := GetTickCount64() + PWEB_CLI_DEV_ACK_MS;
          while (shared.Acked < i) and
                (GetTickCount64() < deadline) and
                not DevStopCheck(@shared) do
            Sleep(PWEB_CLI_DEV_SENTINEL_POLL_MS);
          if shared.Acked >= i then
            Inc(res.Removed, PWebCliDevCleanGenerations(layout,
              shared.Acked))
          else
            Say('generation ' + IntText(i) +
              ' was published but not acknowledged inside the bound');
        end
        else
        begin
          // the publish did not happen, so the counter must not move: the
          // next rebuild reuses this number and the host still counts
          // forward from the generation it has
          Dec(i);
          // PAS2JS ONLY: the input state that failed is recorded as
          // ANSWERED, so the loop waits for the next edit instead of
          // rebuilding a broken source forever. See MakePas2jsGeneration
          if not isReact then
            lastSentinel := seenSentinel;
        end;
      end;
    end;
    res.Acknowledged := shared.Acked;
  finally
    // THE STOP, and there is only one. Setting the flag is what runs the C0
    // ladder for every long-lived member - graceful, then forced, then
    // drained by membership - concurrently and inside the C0 bounds. Two
    // members for React, ONE for Pas2JS, and the same code either way: this
    // unit has no ladder of its own and must never grow one
    if sharedInit then
      shared.Stop := True;
    if watcherStarted then
    begin
      if WaitForThreadTerminate(watcherHandle, PWEB_CLI_DEV_JOIN_MS) <> 0 then
      begin
        res.Code := pdcInternal;
        res.Cause := 'dev_watcher_unjoined';
      end;
      CloseThread(watcherHandle);
    end;
    if hostStarted then
    begin
      if WaitForThreadTerminate(hostHandle, PWEB_CLI_DEV_JOIN_MS) <> 0 then
      begin
        res.Code := pdcInternal;
        res.Cause := 'dev_host_unjoined';
      end;
      CloseThread(hostHandle);
    end;
    if sharedInit then
    begin
      res.WatcherPid := shared.WatcherPid;
      res.HostPid := shared.HostPid;
      res.Acknowledged := shared.Acked;
      if watcherStarted then
      begin
        res.WatcherOutcome := shared.WatcherRes.Outcome;
        res.WatcherExitCode := shared.WatcherRes.ExitCode;
        res.WatcherSignal := shared.WatcherRes.Signal;
        watcherSpontaneous := shared.WatcherSpontaneous;
        Inc(res.DescendantsRemaining, shared.WatcherRes.Drain.Remaining);
        Inc(res.DescendantsSeen, Length(shared.WatcherRes.Drain.Seen));
      end;
      if hostStarted then
      begin
        res.HostOutcome := shared.HostRes.Outcome;
        res.HostExitCode := shared.HostRes.ExitCode;
        res.HostSignal := shared.HostRes.Signal;
        hostSpontaneous := shared.HostSpontaneous;
        Inc(res.DescendantsRemaining, shared.HostRes.Drain.Remaining);
        Inc(res.DescendantsSeen, Length(shared.HostRes.Drain.Seen));
      end;
      res.HostEndedItself := hostSpontaneous;
      res.WatcherEndedItself := watcherSpontaneous;
      if PWebCliStopRequested then
        res.Interrupted := True;
      // NO PARTIAL GENERATION SURVIVES A STOP. `.gen.tmp` is never a
      // published name, and removing it here means the next session starts
      // with the disk in the state the counter describes
      if layout.DevDir <> '' then
        PWebCliDevDiscardGeneration(layout, devRefusal);
      shared.OutLock.Done;
    end;
    // THE CATEGORY, decided last and from the TYPED outcomes rather than
    // from anything a child printed. A stop we ASKED for is exit 0 however
    // the ladder ended the members; a member that ended while nobody had
    // asked is the failure of the supervised set, and it is 5
    if res.Code = pdcOk then
    begin
      if hostSpontaneous then
      begin
        // DEV7: the host went away by itself. Exiting 0 is the developer
        // closing the window and is a clean end; anything else is 5, with
        // the real typed status
        if (res.HostOutcome <> pcoExited) or
           (res.HostExitCode <> 0) then
        begin
          res.Code := pdcSetFailed;
          res.Cause := 'dev_host_' +
            PWebCliChildOutcomeText(res.HostOutcome);
          res.Detail := IntText(res.HostExitCode);
        end;
      end
      else if watcherSpontaneous then
      begin
        // DEV8: the watcher exiting AT ALL is a failure of the set. A
        // watcher is supposed to outlive the session
        res.Code := pdcSetFailed;
        res.Cause := 'dev_watcher_' +
          PWebCliChildOutcomeText(res.WatcherOutcome);
        res.Detail := IntText(res.WatcherExitCode);
      end;
      // a descendant that survived the drain is an invariant failure of the
      // supervisor, whatever the members' own statuses were
      if res.DescendantsRemaining > 0 then
      begin
        res.Code := pdcInternal;
        res.Cause := 'dev_descendants_survived';
        res.Detail := IntText(res.DescendantsRemaining);
      end;
    end;
    // ONE assignment, on every path including an exception nothing here
    // expects: a caller must never receive a zeroed record that reads as a
    // clean session
    Result := res;
  end;
end;

end.
