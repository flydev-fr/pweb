{
  pweb.webview.host - the reusable PWeb release-host composition (CAP-10B1).

  ONE place where a WebView, its platform handler, the privileged-navigation
  guard, the binding, the scheduler and the capability policy are wired
  together, so that an APPLICATION does not have to be wired together at all.

  ---------------------------------------------------------------------------
  WHY THIS UNIT EXISTS
  ---------------------------------------------------------------------------

  CAP-10B1 generates hosts. Before it, every PWeb host in this repository was
  a hand-written program that repeated the same four hundred lines: the
  platform alias block, the pre-create check, Cocoa's two-phase seam, the
  bundle resolved from the executable, the binding plus the CAP-8A
  per-invocation snapshot, and a teardown whose ORDER is load-bearing
  (guard, then handler, then webview_destroy, with the scheduler drained
  between the binding closing and the bridge releasing).

  Copying that into every scaffolded project would be the exact defect
  CAP-10A removed when it promoted `pweb.openExternal` out of four private
  copies - only worse, because the copies would be in other people's
  repositories where no gate of ours can ever see them again.

  So the composition moves here, once, and a generated application keeps
  only what is genuinely its own: its services, its capability policy, and
  its own bridge decorator.

  ---------------------------------------------------------------------------
  WHAT IT DELIBERATELY IS NOT
  ---------------------------------------------------------------------------

  It is NOT a new interface. No eighth boundary, no second scheduler, no
  second bridge, no second permission system: it CONSTRUCTS the frozen
  pieces in the frozen order and owns nothing the seven interfaces do not
  already describe.

  It is NOT a policy. Every authorization decision belongs to the
  ICapabilityPolicy the caller hands in, which runs at the scheduler before
  this unit's bridge chain is reached.

  It does NOT branch on frontend kind. A React project and a Pas2JS project
  produce the identical host behaviour; only `app.pwb` differs. That is the
  property `examples/08-release/README.md` has asserted since CAP-6, and
  hosting it in shared source is how it stops being a claim.

  THE EXISTING EXAMPLE HOSTS ARE NOT MIGRATED ONTO THIS UNIT. CAP-6's
  release host, CAP-9's QuickJS host and the CAP-8 harnesses each carry
  measured, digested behaviour (navigation_policy_digest,
  security_corpus_digest, quickjs_gui_digest), and rewriting their
  composition to prove a CAP-10B1 point would re-baseline three frozen
  values for no CAP-10B1 gate. This unit is purely additive.

  ---------------------------------------------------------------------------
  THE HOST ARGUMENTS
  ---------------------------------------------------------------------------

  Two, both ratified by CAP-7M2 and executed by the CAP-7F host-argument
  gate on the real release triple:

    --pweb-verdict=<file>     write the canonical verdict line atomically on
                              every exit path. LaunchServices forwards
                              neither stdout nor the exit code, so a path in
                              argv is the only deterministic evidence channel
                              a bundled launch leaves behind.
    --pweb-autoclose-ms=<N>   auto-close bound. The ARGUMENT wins over
                              PWEB_SMOKE_AUTOCLOSE_MS, because LaunchServices
                              delivers argv and not an environment.

  Parsed in TWO PASSES, for the reason CAP-7M2 measured: pass 1 captures the
  verdict path wherever it appears and raises nothing, so that even a REFUSED
  command line still writes a FAIL verdict; pass 2 validates and refuses.
  Unknown, malformed, empty and REPEATED options all refuse alike - an option
  silently resolved last-one-wins is an argument the host half-ignores.

  ---------------------------------------------------------------------------
  THE PLATFORM SEAM
  ---------------------------------------------------------------------------

  Note for editors: a compiler directive may NOT be written inside a brace
  comment. FPC reads the nested brace as a directive and ends the comment at
  the next closing brace, which silently mangles whatever follows on the
  platform where that block is ACTIVE - so every conditional named in prose
  here is spelled without its braces.

  Every $ifdef in this file selects a NAME or a whole platform body; not
  one of them decides anything. The asset handler and the navigation guard
  are aliases, the pre-create check is one call with three bodies, and the
  external opener is injected into the frozen pweb.rpc.command decorator
  which never learns which one it got. The classifier, the CSP and the
  capability model are shared source with no conditional at all.

  Cocoa is two-phase and that is the platform's shape rather than a branch:
  upstream builds the WKWebViewConfiguration inside webview_create, so the
  handler is CONSTRUCTED before it and Attach - which raises unless the seam
  actually ran for THIS view - immediately after.
}
unit pweb.webview.host;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.command,
  pweb.capabilities.policy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.bundle,
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2,
  pweb.platform.webview2.runtime
  {$endif LINUX}
  {$endif DARWIN}
  ;

const
  /// the release bundle, always beside the executable and never in the CWD
  PWEB_HOST_BUNDLE = 'app.pwb';
  /// the privileged application origin, in development and production alike
  PWEB_HOST_ORIGIN = 'pweb://app/';
  /// the two ratified host arguments (CAP-7M2, gated by CAP-7F)
  PWEB_HOST_ARG_VERDICT = '--pweb-verdict=';
  PWEB_HOST_ARG_AUTOCLOSE = '--pweb-autoclose-ms=';
  /// the environment fallback for the auto-close bound; argv wins over it
  PWEB_HOST_AUTOCLOSE_ENV = 'PWEB_SMOKE_AUTOCLOSE_MS';
  /// ceiling on the auto-close bound, so a typo cannot park a CI runner
  PWEB_HOST_MAX_AUTOCLOSE_MS = 60000;
  /// how much longer than its own bound the closer thread may take
  PWEB_HOST_CLOSER_MARGIN_MS = 10000;
  /// CAP-10C2: how long the teardown waits for a reload dispatch that had
  // already read the handle, and the interval it re-checks on
  // - the closer thread is JOINED before the handle is disowned, which is
  // what makes its dispatch safe. A composition's reload caller is not a
  // thread this unit owns, so the same guarantee has to be a DRAIN: after
  // the handle is nil no new dispatch can start, and this is the bounded
  // wait for the ones already past the read
  PWEB_HOST_RELOAD_DRAIN_MS = 2000;
  PWEB_HOST_RELOAD_POLL_MS = 5;
  /// the verdict line a clean run writes
  PWEB_HOST_VERDICT_OK = 'ok';

type
  /// everything a host needs that is not a service, a policy or a bridge
  // - Title, Width and Height are the window; WindowId and PrincipalId are
  // the native trust identity the binding stamps into every context and
  // that the capability policy is keyed by
  TPWebHostOptions = record
    Title: RawUtf8;
    Width: Integer;
    Height: Integer;
    WindowId: RawUtf8;
    PrincipalId: RawUtf8;
    Workers: Integer;
    MaxConcurrent: Integer;
    MaxQueueSize: Integer;
    /// prefix for this host's own diagnostic lines - never a decision
    LogPrefix: RawUtf8;
    /// CAP-10C2: argv strings a COMPOSITION has already consumed and
    // validated, matched BYTE-EXACTLY and skipped by the argument parser
    // - the production template leaves this empty, so the refusal set is
    // byte-for-byte what it always was and an unknown argument still
    // raises. It exists because "the host refuses every argument it does
    // not own" has to be composable for a composition to own one, and an
    // exact-string list is stricter than a prefix: a composition declares
    // the argv strings it actually saw, never a shape a future argument
    // might also match
    ConsumedArgs: TRawUtf8DynArray;
  end;

/// the ratified defaults: one 900x650 window, principal `window:main`,
/// four workers, four simultaneous invocations and a queue of 32
function PWebDefaultHostOptions(const Title, LogPrefix: RawUtf8):
  TPWebHostOptions;

/// wrap a bridge with the FROZEN runtime-command layer and THIS platform's
/// external opener
// - the caller decorates the result with its own application bridge, so the
// arrival order stays visible at the call site: application -> runtime
// command -> the real bridge, which is the order every PWeb host uses
// - installing the layer is not a grant. `pweb.openExternal` still has to
// be MAPPED by the capability policy, and an application that does not map
// it is answered forbidden/403 at the scheduler with the opener never
// reached, because the policy runs before the bridge
function PWebHostRuntimeBridge(const Inner: IInvocationBridge):
  IInvocationBridge;

/// run one PWeb application to completion and return its exit code
// - Policy is authoritative and is installed at the ONE frozen call site;
// Bridge is the fully decorated application chain
// - 0 only on a clean run: the bundle loaded, the window opened, the
// message loop returned and every teardown step succeeded
function PWebHostRun(const Options: TPWebHostOptions;
  const Policy: TPWebCapabilityPolicy;
  const Bridge: IInvocationBridge): Integer; overload;

/// the same run, with the asset store supplied by the composition
// - CAP-10C2. Store = nil means the PRODUCTION rule and nothing else:
// PWebHostLoadBundle, app.pwb beside the executable, never the working
// directory. The three-argument form above delegates here with nil, so a
// production host reaches byte-for-byte the same code it always did
// - a non-nil store is still an IAssetStore and nothing more: it is read
// through the frozen interface by the frozen platform handler, and no
// serving rule, MIME derivation, path grammar or CSP moves because of it
function PWebHostRun(const Options: TPWebHostOptions;
  const Policy: TPWebCapabilityPolicy;
  const Bridge: IInvocationBridge;
  const Store: IAssetStore): Integer; overload;

/// ask the running host to re-navigate to the privileged origin
// - CAP-10C2, and the mirror image of the auto-close thread's terminate:
// one webview_dispatch of a callback that calls webview_navigate with
// PWEB_HOST_ORIGIN, which is the ONLY destination that exists. It takes no
// parameter, injects no script and calls no location.reload()
// - False when there is no live webview to ask (before it is created, or
// after the teardown has disowned it). PRODUCTION NEVER CALLS THIS and
// gains no string from it
function PWebHostRequestReload: Boolean;


implementation

{$ifdef OSPOSIX}
uses
  baseunix; // CAP-10C0: the graceful-stop helper's pipe and sigaction
{$endif OSPOSIX}

type
  { The platform-selected NAMES of this unit, and the only ones. Windows and
    Linux expose the identical surface - Create(webview_t, IAssetStore),
    Detach, Destroy - and Cocoa is that same surface split in two, because
    upstream builds the WKWebViewConfiguration inside webview_create and
    leaves no post-create seam.

    The guards mirror their handlers. What no guard exposes is a DECISION:
    each translates its native event into a TPWebNavRequest and hands it to
    PWebClassifyNavigation, the one classifier in src/security. }
  {$ifdef DARWIN}
  TPWebHostAssetHandler = TCocoaAssetHandler;
  TPWebHostNavGuard = TCocoaNavigationGuard;
  {$else}
  {$ifdef LINUX}
  TPWebHostAssetHandler = TWebKitGtkAssetHandler;
  TPWebHostNavGuard = TWebKitGtkNavigationGuard;
  {$else}
  TPWebHostAssetHandler = TWebView2AssetHandler;
  TPWebHostNavGuard = TWebView2NavigationGuard;
  {$endif LINUX}
  {$endif DARWIN}

  { CAP-8A (ratified D9): populates Context.Capabilities with the policy's
    PER-INVOCATION effective snapshot (AppMaximum INTERSECT Principal
    INTERSECT Window INTERSECT RuntimeGrants) before delegating to the
    standard envelope handler. Computed on the callback thread - a cheap
    lock plus a copy, within the ratified callback duties - so every
    enqueued invocation captures the set that was true AT ENQUEUE and a
    later grant change never mutates an in-flight context. }
  TPWebHostPolicyContext = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FInner: IWebViewInvocationHandler;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy; // keeps the policy object alive
  public
    constructor Create(const AInner: IWebViewInvocationHandler;
      const APolicy: TPWebCapabilityPolicy);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

var
  /// the live webview handle the auto-close thread may terminate, or nil
  HostAutoCloseHandle: Pointer;
  /// CAP-10C2: reload dispatches that have read the handle and not yet
  // returned from webview_dispatch
  // - the teardown disowns the handle FIRST, so this can only ever fall to
  // zero afterwards, and it is what the destroy waits on. Without it a
  // caller that read a live handle one instruction before the disown could
  // dispatch onto a webview this teardown had already destroyed
  HostReloadBusy: LongInt;
  /// CAP-10C1: how the teardown tells the auto-close thread it is no longer
  // needed, or nil when the bound is not armed
  // - MEASURED at CAP-10C0: while PWEB_SMOKE_AUTOCLOSE_MS is armed the
  // closer slept for the WHOLE bound and the teardown joined it, so a stop
  // requested meanwhile completed only when the bound expired - five
  // seconds of grace and then a forced termination in the first CAP-10C0
  // stop-driver run. A bounded WAIT instead of a Sleep is semantics-neutral
  // by construction: the event is only ever set AFTER webview_run has
  // returned, so no auto-close that would have happened stops happening,
  // and InterlockedExchange still guarantees exactly one terminate dispatch
  HostAutoCloseStop: TSynEvent;
  /// this run's diagnostic prefix, for the two callbacks that cannot carry
  // an argument through the C boundary
  HostLogPrefix: RawUtf8;

constructor TPWebHostPolicyContext.Create(
  const AInner: IWebViewInvocationHandler;
  const APolicy: TPWebCapabilityPolicy);
begin
  inherited Create;
  if (AInner = nil) or
     (APolicy = nil) then
    raise Exception.Create('PWebHost: a policy context needs both halves');
  FInner := AInner;
  FPolicy := APolicy;
  FPolicyRef := APolicy;
end;

procedure TPWebHostPolicyContext.HandleInvocation(
  const Context: TInvocationContext; const Request: TPWebJson;
  const Completion: IInvocationCompletion);
var
  ctx: TInvocationContext;
begin
  // the ONLY field this wrapper touches. Everything else stays the
  // binding-built native context, and nothing here ever reads the payload
  ctx := Context;
  ctx.Capabilities := FPolicy.SnapshotCapabilities(
    ctx.PrincipalId, ctx.WindowId);
  FInner.HandleInvocation(ctx, Request, Completion);
end;

function PWebDefaultHostOptions(const Title, LogPrefix: RawUtf8):
  TPWebHostOptions;
begin
  Result := Default(TPWebHostOptions);
  Result.Title := Title;
  Result.Width := 900;
  Result.Height := 650;
  Result.WindowId := 'main';
  Result.PrincipalId := 'window:main';
  Result.Workers := 4;
  Result.MaxConcurrent := 4;
  Result.MaxQueueSize := 32;
  Result.LogPrefix := LogPrefix;
end;

{ Hands a URI to the operating system as DATA through one public API -
  ShellExecuteExW on Windows, g_app_info_launch_default_for_uri on Linux,
  -[NSWorkspace openURL:] on macOS - with no shell string, no cmd.exe, no
  /bin/sh and no subprocess interpolation anywhere. None of them decides
  anything: the scheme allowlist, the length bound and the control-byte
  rejection all live in PWebValidExternalUri, which pweb.rpc.command has
  already run by the time this is called.

  Called on a scheduler WORKER thread, never the GUI thread. Each adapter
  satisfies its own OS affinity requirement internally. }
function PWebHostOpenExternal(const AUri: RawUtf8): Boolean;
begin
  {$ifdef DARWIN}
  Result := PWebCocoaOpenExternal(AUri);
  {$else}
  {$ifdef LINUX}
  Result := PWebGtkOpenExternalUri(AUri);
  {$else}
  Result := PWebWv2OpenExternal(AUri);
  {$endif LINUX}
  {$endif DARWIN}
end;

{ The host's OBSERVATION of an external open, and the whole of what a host
  still owns about the command since CAP-10A.

  REDACTION: the URI is never written to the log - not the query string, not
  a mailto body, not even the host. Only its byte length and the outcome
  category, which is exactly what the decorator hands over. }
procedure PWebHostObserveOpen(const Context: TInvocationContext;
  Outcome: TPWebOpenOutcome; UriBytes: PtrInt);
begin
  case Outcome of
    pooRefused:
      WriteLn(HostLogPrefix, ': openExternal REFUSED (uri bytes=',
        UriBytes, ')');
    pooFailed:
      WriteLn(StdErr, HostLogPrefix, ': openExternal FAILED (uri bytes=',
        UriBytes, ')');
    pooOpened:
      WriteLn(HostLogPrefix, ': openExternal OK (uri bytes=', UriBytes, ')');
  end;
  // CAP-10C1: MEASURED under `pweb run` (hosted run 33622404228) - FPC's
  // text layer flushes a pipe per line on Windows but BLOCK-BUFFERS it on
  // Linux and macOS, so a diagnostic written to stdout reaches a supervisor
  // only when the host exits. StdErr flushes on every write and needs
  // nothing; Output does. A line that arrives after the process it was
  // describing has ended is not a diagnostic
  Flush(Output);
end;

function PWebHostRuntimeBridge(const Inner: IInvocationBridge):
  IInvocationBridge;
begin
  Result := TPWebRuntimeCommandBridge.Create(Inner, @PWebHostOpenExternal,
    @PWebHostObserveOpen);
end;

procedure PWebHostTerminate(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

{ CAP-10C2: PWebHostTerminate with webview_terminate replaced, and nothing
  else. It carries no parameter and no destination of its own because
  PWEB_HOST_ORIGIN is the only origin this host has ever navigated to - in
  development and in production alike - so a re-navigation cannot become an
  origin change however it is called. }
procedure PWebHostReNavigate(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_navigate(w, PWEB_HOST_ORIGIN);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

function PWebHostRequestReload: Boolean;
var
  handle: Pointer;
begin
  // the busy count is raised BEFORE the handle is read and lowered after
  // the dispatch returns, so the teardown's drain cannot complete around a
  // caller that is between the two. Unlike the terminate path this does NOT
  // exchange the handle away: a reload leaves the host running, and the
  // next one has to find the same handle
  InterlockedIncrement(HostReloadBusy);
  try
    handle := HostAutoCloseHandle;
    Result := handle <> nil;
    if Result then
      webview_dispatch(webview_t(handle), @PWebHostReNavigate, nil);
  finally
    InterlockedDecrement(HostReloadBusy);
  end;
end;

function PWebHostAutoCloseThread(Param: Pointer): PtrInt;
var
  handle: Pointer;
  stop: TSynEvent;
  stopped: Boolean;
begin
  Result := 0;
  // WaitFor answers True when the teardown signalled and False on timeout.
  // A signal means webview_run has already returned and there is nothing
  // left to terminate; a timeout means the bound expired and this is the
  // auto-close doing its job. Same two outcomes the Sleep had, minus the
  // wait nobody could shorten
  // ONE read of the global, into a local: the teardown nils and frees it
  // after the join, and two reads of it are two different answers
  stop := HostAutoCloseStop;
  stopped := False;
  if stop <> nil then
    stopped := stop.WaitFor(Cardinal(PtrInt(Param)))
  else
    Sleep(PtrInt(Param));
  if stopped then
    exit;
  handle := InterlockedExchange(HostAutoCloseHandle, nil);
  if handle <> nil then
    webview_dispatch(webview_t(handle), @PWebHostTerminate, nil);
end;

{$ifdef OSPOSIX}
{ CAP-10C0: the graceful-stop helper, POSIX only.

  A supervisor (`pweb run`) asks a host to close by sending SIGTERM to its
  process group; a terminal sends SIGINT or SIGHUP. Without a handler the
  default action ends the process at once and the orderly teardown after
  webview_run - binding closed, scheduler drained, guard and handler
  detached, webview destroyed - never runs. On Windows the same request
  arrives as WM_CLOSE on the top-level window and the upstream backend
  already turns it into webview_terminate, so nothing is needed there.

  This helper is SEMANTICS-NEUTRAL by construction: it translates the signal
  into the very same call the auto-close thread makes - one
  InterlockedExchange on HostAutoCloseHandle and one webview_dispatch of
  PWebHostTerminate - so a signalled host exits through exactly the path a
  timed one does, and the CAP-9 shutdown order below is untouched.

  The signal handler itself does one async-signal-safe thing: it writes a
  byte to a self-pipe. A dedicated thread blocks on that pipe and performs
  the dispatch, because webview_dispatch is not something a signal handler
  may call. Teardown writes a different byte so the thread returns, joins
  it inside the same margin the closer thread gets, restores the default
  dispositions and closes the pipe - so a signal arriving after the run has
  ended behaves exactly as it did before this helper existed. }
var
  HostStopPipe: TFilDes = (-1, -1);
  /// the dispositions found in place, restored on removal - never SIG_DFL
  // assumed, because this unit is reused by every generated application
  HostStopPrevious: array[0 .. 2] of SigActionRec;
  HostStopPreviousValid: Boolean = False;

const
  HOST_STOP_BYTE_SIGNAL = 1;
  HOST_STOP_BYTE_TEARDOWN = 2;
  HOST_STOP_SIGNALS: array[0 .. 2] of cint = (SIGTERM, SIGINT, SIGHUP);

procedure PWebHostStopSignal(Sig: LongInt; Info: PSigInfo;
  Context: PSigContext); cdecl;
var
  b: Byte;
begin
  b := HOST_STOP_BYTE_SIGNAL;
  FpWrite(HostStopPipe[1], b, 1);
end;

function PWebHostStopThread(Param: Pointer): PtrInt;
var
  b: Byte;
  n: PtrInt;
  handle: Pointer;
begin
  Result := 0;
  b := 0;
  repeat
    n := FpRead(HostStopPipe[0], b, 1);
  until (n > 0) or
        ((n < 0) and (fpgeterrno <> ESysEINTR));
  if (n > 0) and
     (b = HOST_STOP_BYTE_SIGNAL) then
  begin
    handle := InterlockedExchange(HostAutoCloseHandle, nil);
    if handle <> nil then
      webview_dispatch(webview_t(handle), @PWebHostTerminate, nil);
  end;
end;

// put back exactly what was there, and close the pipe: used by removal, and
// by a partial installation so nothing armed or open is ever left behind
procedure PWebHostRestoreSignals(Installed: Integer);
var
  i: Integer;
begin
  // only the slots that were actually replaced go back: a slot whose
  // sigaction failed was never changed and has no saved value to restore
  if HostStopPreviousValid then
    for i := 0 to Installed - 1 do
      FpSigaction(HOST_STOP_SIGNALS[i], @HostStopPrevious[i], nil);
  HostStopPreviousValid := False;
  if HostStopPipe[0] >= 0 then
    FpClose(HostStopPipe[0]);
  if HostStopPipe[1] >= 0 then
    FpClose(HostStopPipe[1]);
  HostStopPipe[0] := -1;
  HostStopPipe[1] := -1;
end;

function PWebHostInstallStopHelper(out AThread: system.TThreadID): Boolean;
var
  act: SigActionRec;
  id: system.TThreadID;
  i: Integer;
begin
  Result := False;
  AThread := system.TThreadID(0);
  if FpPipe(HostStopPipe) <> 0 then
  begin
    HostStopPipe[0] := -1;
    HostStopPipe[1] := -1;
    exit;
  end;
  FillChar(act, SizeOf(act), 0);
  act.sa_handler := SigActionHandler(@PWebHostStopSignal);
  FpSigEmptySet(act.sa_mask);
  FillChar(HostStopPrevious, SizeOf(HostStopPrevious), 0);
  HostStopPreviousValid := True;
  for i := 0 to High(HOST_STOP_SIGNALS) do
    if FpSigaction(HOST_STOP_SIGNALS[i], @act, @HostStopPrevious[i]) <> 0 then
    begin
      // a partial installation is no installation: the signals already
      // taken go back to what they were and the pipe is closed, so no
      // signal can ever be written into a pipe nobody reads
      PWebHostRestoreSignals(i);
      exit;
    end;
  AThread := BeginThread(@PWebHostStopThread, nil, id);
  Result := AThread <> system.TThreadID(0);
  if not Result then
    PWebHostRestoreSignals(Length(HOST_STOP_SIGNALS));
end;

procedure PWebHostRemoveStopHelper(AThread: system.TThreadID);
var
  b: Byte;
  i: Integer;
begin
  // the previous dispositions first, so a late signal behaves as before
  if HostStopPreviousValid then
  begin
    for i := 0 to High(HOST_STOP_SIGNALS) do
      FpSigaction(HOST_STOP_SIGNALS[i], @HostStopPrevious[i], nil);
    HostStopPreviousValid := False;
  end;
  if AThread <> system.TThreadID(0) then
  begin
    b := HOST_STOP_BYTE_TEARDOWN;
    FpWrite(HostStopPipe[1], b, 1);
    if WaitForThreadTerminate(AThread, PWEB_HOST_CLOSER_MARGIN_MS) <> 0 then
      WriteLn(StdErr, HostLogPrefix,
        ': FAIL the stop helper thread did not terminate');
    CloseThread(AThread);
  end;
  if HostStopPipe[0] >= 0 then
    FpClose(HostStopPipe[0]);
  if HostStopPipe[1] >= 0 then
    FpClose(HostStopPipe[1]);
  HostStopPipe[0] := -1;
  HostStopPipe[1] := -1;
end;
{$endif OSPOSIX}

{ The pre-create check: one cause per platform that is knowable BEFORE
  webview_create collapses every bad state into a single nil, refused with
  a typed marker instead of dying mid-render or naming the wrong runtime. }
procedure PWebHostPreCreateCheck;
{$ifdef DARWIN}
begin
  // FPC starts every process with the invalid-operation/divide-by-zero/
  // overflow FPU traps ENABLED, and WebKit, CoreGraphics and AppKit compute
  // with NaNs as ordinary intermediates - the first such computation would
  // kill the process with EInvalidOp from inside a C frame.
  // pweb.platform.cocoa masks the traps in its unit initialization and
  // RECORDS whether that worked; this turns the record into a refusal
  // before any window can exist.
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, HostLogPrefix,
    ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create(
    'the FPU could not be put in its non-trapping default state - WebKit ' +
    'would kill this process on its first NaN; no WebView was created');
end;
{$else}
{$ifdef LINUX}
var
  reason: RawUtf8;
begin
  // There is nothing to PROVISION on Linux - WebKitGTK is a distro package
  // whose absence is a loader failure naming the exact soname before main()
  // runs - but a host with no display is the ordinary Linux failure, and
  // MEASURED it collapses into webview_create returning nil, which the
  // frozen raw layer reports as a missing WebView2 runtime. Naming a
  // Windows runtime on a machine that never had one is a false lead.
  reason := PWebGtkDisplayUnavailableReason;
  if reason = '' then
    exit;
  WriteLn(StdErr, HostLogPrefix, ': GTK DISPLAY UNAVAILABLE (', reason, ')');
  raise Exception.Create(
    'no usable display - no WebView was created; a GTK/WebKitGTK WebView ' +
    'needs an X or Wayland session');
end;
{$else}
var
  detection: TPWebWv2DetectionResult;
begin
  // CAP-6b0 detection runs BEFORE webview_create so an absent, too-old or
  // undetectable runtime produces a diagnosable marker and a nonzero exit
  // instead of the collapsed nil. A PWeb application NEVER downloads or
  // installs anything: provisioning belongs to the setup, and this is
  // diagnosis rather than remediation.
  detection := PWebWv2Detect;
  if PWebWv2ProvisioningDecide(detection) = wv2pdAlreadyUsable then
    exit;
  WriteLn(StdErr, HostLogPrefix, ': WEBVIEW2 RUNTIME UNUSABLE (status=',
    PWebWv2StatusText(detection.Status), ', raw=', detection.RawVersion,
    ', minbuild=', PWEB_WV2_MIN_BUILD, ')');
  WriteLn(StdErr, HostLogPrefix, ': WEBVIEW2 DIAG ', detection.Diagnostic);
  raise Exception.Create(
    'WebView2 runtime unusable - no WebView was created; install the ' +
    'runtime via the application setup');
end;
{$endif LINUX}
{$endif DARWIN}

{ Locate app.pwb from the EXECUTABLE location - never the CWD - and run the
  full production gate BEFORE anything webview-related exists. On refusal a
  typed marker goes to stderr and the raised exception makes the process
  exit nonzero, so zero bundle JS can ever execute. }
function PWebHostLoadBundle: IAssetStore;
var
  bundleFile: TFileName;
  refusal: TPWebBundleRefusal;
begin
  {$ifdef DARWIN}
  // inside a .app the executable lives in Contents/MacOS and the bundle in
  // Contents/Resources. ExpandFileName only folds the '..' out of an
  // already-absolute path here - ProgramFilePath is absolute - so the
  // resolution never consults the working directory.
  bundleFile := ExpandFileName(Executable.ProgramFilePath + '..' +
    PathDelim + 'Resources' + PathDelim + PWEB_HOST_BUNDLE);
  {$else}
  bundleFile := Executable.ProgramFilePath + PWEB_HOST_BUNDLE;
  {$endif DARWIN}
  if not PWebBundleLoadFile(bundleFile, PWEB_SUPPORTED_PROTOCOLS,
       PWEB_RUNTIME_VERSION, Result, refusal) then
  begin
    // reason category only: no parser internals, and never any content
    // from the rejected bundle
    WriteLn(StdErr, HostLogPrefix, ': ', PWEB_HOST_BUNDLE, ' REFUSED (',
      PWebBundleRefusalText(refusal), ')');
    raise Exception.Create('bundle refused - no WebView was created');
  end;
end;

{ CAP-10C2: an argv string the COMPOSITION declared it had already consumed
  and validated. The comparison is BYTE-EXACT against the whole argument -
  never a prefix - so a composition can own `--pweb-dev-root=/x` without
  also owning every future `--pweb-dev-*` somebody adds. An empty list (the
  production template's) makes this function answer False for everything,
  which is the behaviour that existed before it did. }
function PWebHostArgConsumed(const Consumed: TRawUtf8DynArray;
  const Arg: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Consumed) do
    if string(Consumed[i]) = Arg then
      exit(True);
  Result := False;
end;

{ The two ratified arguments, parsed strictly in TWO PASSES - see the unit
  header for why pass 1 raises nothing. AAutoCloseMs stays -1 when the
  argument is absent, so a caller can tell "not given" from "given as 0". }
procedure PWebHostParseArguments(const Consumed: TRawUtf8DynArray;
  out AVerdictFile: TFileName; out AAutoCloseMs: Integer);
var
  i: Integer;
  arg, value: string;
  verdictSeen, autoCloseSeen: Boolean;
begin
  AVerdictFile := '';
  AAutoCloseMs := -1;
  verdictSeen := False;
  autoCloseSeen := False;
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if PWebHostArgConsumed(Consumed, arg) then
      continue;
    if Copy(arg, 1, Length(PWEB_HOST_ARG_VERDICT)) =
         string(PWEB_HOST_ARG_VERDICT) then
    begin
      value := Copy(arg, Length(PWEB_HOST_ARG_VERDICT) + 1, MaxInt);
      if value <> '' then
        // expanded ONCE, here, before anything can change the working
        // directory, so a relative path stays anchored to the CWD the
        // process was started with
        AVerdictFile := ExpandFileName(value);
    end;
  end;
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if PWebHostArgConsumed(Consumed, arg) then
      continue;
    if Copy(arg, 1, Length(PWEB_HOST_ARG_VERDICT)) =
         string(PWEB_HOST_ARG_VERDICT) then
    begin
      if verdictSeen then
        raise Exception.Create('duplicate argument refused: ' +
          string(PWEB_HOST_ARG_VERDICT));
      verdictSeen := True;
      value := Copy(arg, Length(PWEB_HOST_ARG_VERDICT) + 1, MaxInt);
      if value = '' then
        raise Exception.Create(string(PWEB_HOST_ARG_VERDICT) +
          ' requires a file path');
    end
    else if Copy(arg, 1, Length(PWEB_HOST_ARG_AUTOCLOSE)) =
              string(PWEB_HOST_ARG_AUTOCLOSE) then
    begin
      if autoCloseSeen then
        raise Exception.Create('duplicate argument refused: ' +
          string(PWEB_HOST_ARG_AUTOCLOSE));
      autoCloseSeen := True;
      value := Copy(arg, Length(PWEB_HOST_ARG_AUTOCLOSE) + 1, MaxInt);
      AAutoCloseMs := StrToIntDef(value, -1);
      if AAutoCloseMs < 0 then
        raise Exception.Create(string(PWEB_HOST_ARG_AUTOCLOSE) +
          ' requires a non-negative integer, got: ' + value);
    end
    else
      raise Exception.Create('usage: ' + string(HostLogPrefix) + ' [' +
        string(PWEB_HOST_ARG_VERDICT) + '<file>] [' +
        string(PWEB_HOST_ARG_AUTOCLOSE) + '<ms>] -- unknown argument: ' +
        arg);
  end;
end;

{ The verdict FILE. The line goes to a per-process temp sibling first and is
  then moved into place. On POSIX the move is rename(), which replaces
  atomically: a reader sees the previous state or the complete line, never a
  half-written one. On Windows RenameFile does not replace, so an existing
  file is deleted first - a short no-file window that exists on Windows
  only, accepted and stated rather than dressed up as atomicity. }
procedure PWebHostWriteVerdict(const AFile: TFileName; const ALine: string);
var
  tmp: TFileName;
  t: Text;
begin
  // per-process unique: two concurrent instances aimed at one verdict path
  // must never share a temp sibling
  tmp := AFile + '.' + IntToStr(GetProcessID) + '.tmp';
  AssignFile(t, tmp);
  Rewrite(t);
  try
    WriteLn(t, ALine);
  finally
    CloseFile(t);
  end;
  {$ifdef OSWINDOWS}
  if FileExists(AFile) then
    DeleteFile(AFile);
  {$endif OSWINDOWS}
  if not RenameFile(tmp, AFile) then
    raise Exception.Create('unable to move the verdict file into place: ' +
      string(AFile));
end;

function PWebHostRun(const Options: TPWebHostOptions;
  const Policy: TPWebCapabilityPolicy;
  const Bridge: IInvocationBridge): Integer;
begin
  // the production form, and the ONE place nil means "the production rule":
  // app.pwb beside the executable, through PWebHostLoadBundle
  Result := PWebHostRun(Options, Policy, Bridge, nil);
end;

function PWebHostRun(const Options: TPWebHostOptions;
  const Policy: TPWebCapabilityPolicy;
  const Bridge: IInvocationBridge;
  const Store: IAssetStore): Integer;
var
  w: webview_t;
  assets: IAssetStore;
  assetHandler: TPWebHostAssetHandler;
  navGuard: TPWebHostNavGuard;
  policyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  autoCloseMs, argAutoCloseMs: Integer;
  verdictFile: TFileName;
  closerId, closerHandle: system.TThreadID; // mormot.core.os shadows it
  closerStarted, safeToDestroy, schedulerDrained: Boolean;
  reloadWaited: Integer; // CAP-10C2: the reload drain's bounded wait
  {$ifdef OSPOSIX}
  stopHelper: system.TThreadID;
  stopHelperInstalled: Boolean;
  {$endif OSPOSIX}
begin
  Result := 0;
  if Policy = nil then
    raise Exception.Create('PWebHostRun requires a capability policy');
  if Bridge = nil then
    raise Exception.Create('PWebHostRun requires a bridge');
  HostLogPrefix := Options.LogPrefix;
  scheduler := nil;
  assetHandler := nil;
  navGuard := nil;
  closerStarted := False;
  safeToDestroy := True;
  schedulerDrained := False;
  verdictFile := '';
  argAutoCloseMs := -1;
  {$ifdef OSPOSIX}
  // read in the finally below, so they must be defined before anything in
  // the try can raise
  stopHelperInstalled := False;
  stopHelper := system.TThreadID(0);
  {$endif OSPOSIX}
  try
    // parsed FIRST, so the verdict file is known before anything can fail:
    // a refused bundle still leaves a FAIL verdict when one was asked for
    PWebHostParseArguments(Options.ConsumedArgs, verdictFile,
      argAutoCloseMs);
    // nil is the PRODUCTION rule and the only rule this unit knows: the
    // bundle beside the executable, through the frozen loader with the
    // frozen refusals. A composition that supplies a store has already
    // opened it through that same loader; nothing here serves a folder,
    // a directory or a path of any kind
    if Store <> nil then
      assets := Store
    else
      assets := PWebHostLoadBundle;

    // the policy is installed at the ONE frozen call site; the plumbing
    // below is the Phase-2 plumbing, untouched
    policyRef := Policy;
    scheduler := TInvocationScheduler.Create(policyRef, Bridge,
      Options.Workers);
    schedulerRef := scheduler;
    limits := Default(TPWebSourceLimits);
    limits.MaxConcurrent := Options.MaxConcurrent;
    limits.MaxQueueSize := Options.MaxQueueSize;
    source := scheduler.RegisterSource(limits);

    PWebHostPreCreateCheck;
    {$ifdef DARWIN}
    // THE ONE FORCED ORDERING DIFFERENCE: Cocoa's pweb://app seam is armed
    // by CONSTRUCTION, and only a webview created after it can be served.
    // Attach below proves the seam actually ran for the view that came back.
    assetHandler := TCocoaAssetHandler.Create(assets);
    {$endif DARWIN}

    w := WebViewCheckCreated(webview_create(0, nil));
    try
      {$ifdef DARWIN}
      // raises unless the pre-create seam RAN and THIS view's own
      // configuration reports OUR handler for pweb://
      assetHandler.Attach(w);
      {$endif DARWIN}
      HostAutoCloseHandle := Pointer(w);
      // the native context TEMPLATE deliberately carries NO capability
      // list: the wrapper below computes the per-invocation effective
      // snapshot, so a template list could only ever go stale
      context := Default(TInvocationContext);
      context.WindowId := Options.WindowId;
      context.PrincipalId := Options.PrincipalId;
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, source, opts);
      binding.Bind('__pweb_invoke', TPWebHostPolicyContext.Create(
        TPWebEnvelopeHandler.Create(source), Policy));
      WebViewCheck(webview_set_title(w,
        PAnsiChar(AnsiString(Options.Title))), 'webview_set_title');
      WebViewCheck(webview_set_size(w, Options.Width, Options.Height,
        WEBVIEW_HINT_NONE), 'webview_set_size');
      // production asset path: attach the pweb://app handler on the proven
      // native seam, then navigate - never any injected HTML
      {$ifndef DARWIN}
      {$ifdef LINUX}
      assetHandler := TWebKitGtkAssetHandler.Create(w, assets);
      {$else}
      assetHandler := TWebView2AssetHandler.Create(w, assets);
      {$endif LINUX}
      {$endif DARWIN}
      // CAP-8B: the guard is installed AFTER the handler that can serve
      // trusted content and BEFORE the first navigation that could load
      // any, so no document ever commits unclassified
      {$ifdef DARWIN}
      navGuard := TPWebHostNavGuard.Create;
      navGuard.Attach(w);
      {$else}
      navGuard := TPWebHostNavGuard.Create(w);
      {$endif DARWIN}
      WebViewCheck(webview_navigate(w, PWEB_HOST_ORIGIN),
        'webview_navigate');

      // the argument WINS over the environment: LaunchServices delivers
      // argv but no environment, so argv is the channel a machine-checked
      // launch actually controls
      if argAutoCloseMs >= 0 then
        autoCloseMs := argAutoCloseMs
      else
        autoCloseMs := StrToIntDef(
          GetEnvironmentVariable(PWEB_HOST_AUTOCLOSE_ENV), 0);
      if autoCloseMs > PWEB_HOST_MAX_AUTOCLOSE_MS then
        autoCloseMs := PWEB_HOST_MAX_AUTOCLOSE_MS;
      if autoCloseMs > 0 then
      begin
        // created BEFORE the thread that waits on it, so the closer can
        // never observe a nil it would fall back to sleeping on
        HostAutoCloseStop := TSynEvent.Create;
        closerHandle := BeginThread(@PWebHostAutoCloseThread,
          Pointer(PtrInt(autoCloseMs)), closerId);
        closerStarted := closerHandle <> system.TThreadID(0);
        if not closerStarted then
          raise Exception.Create('unable to start the auto-close thread');
      end;
      {$ifdef OSPOSIX}
      // CAP-10C0: SIGTERM / SIGINT / SIGHUP become the same terminate
      // dispatch the auto-close thread uses - installed last, removed
      // first, so it exists exactly while webview_run does
      stopHelperInstalled := PWebHostInstallStopHelper(stopHelper);
      if not stopHelperInstalled then
        raise Exception.Create('unable to install the stop helper');
      {$endif OSPOSIX}
      WebViewCheck(webview_run(w), 'webview_run');
    finally
      {$ifdef OSPOSIX}
      if stopHelperInstalled then
        PWebHostRemoveStopHelper(stopHelper);
      {$endif OSPOSIX}
      // webview_run has returned, so the auto-close has nothing left to
      // terminate: the closer is released HERE, before the join, and the
      // teardown below no longer waits out a bound nobody is using
      if HostAutoCloseStop <> nil then
        HostAutoCloseStop.SetEvent;
      if closerStarted then
      begin
        if WaitForThreadTerminate(closerHandle,
             autoCloseMs + PWEB_HOST_CLOSER_MARGIN_MS) <> 0 then
        begin
          WriteLn(StdErr, HostLogPrefix,
            ': FAIL the auto-close thread did not terminate');
          safeToDestroy := False;
          Result := 1;
        end;
        CloseThread(closerHandle);
      end;
      // only after the join: the closer holds a reference to this event
      // until it returns, and a thread that did not terminate (the branch
      // above) still holds one - so it is freed only when nothing can be
      // waiting on it
      if safeToDestroy then
        FreeAndNil(HostAutoCloseStop)
      else
        HostAutoCloseStop := nil;
      InterlockedExchange(HostAutoCloseHandle, nil);
      // CAP-10C2: the handle is disowned, so no NEW reload dispatch can
      // start; this drains the ones already past their read. It is placed
      // HERE - immediately after the disown and before the first teardown
      // step - so the CAP-9 shutdown order below is reached unchanged, and
      // it is bounded so a caller that never returns cannot park a host.
      // In production nothing calls PWebHostRequestReload and the count is
      // zero on the first look
      reloadWaited := 0;
      while (InterlockedExchangeAdd(HostReloadBusy, 0) <> 0) and
            (reloadWaited < PWEB_HOST_RELOAD_DRAIN_MS) do
      begin
        Sleep(PWEB_HOST_RELOAD_POLL_MS);
        Inc(reloadWaited, PWEB_HOST_RELOAD_POLL_MS);
      end;
      if InterlockedExchangeAdd(HostReloadBusy, 0) <> 0 then
      begin
        // a dispatch that never returned: destroying the webview under it
        // is the one thing this drain exists to prevent
        WriteLn(StdErr, HostLogPrefix,
          ': FAIL a reload dispatch did not drain');
        safeToDestroy := False;
        Result := 1;
      end;
      if binding <> nil then
        try
          binding.Close;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, HostLogPrefix, ': FAIL binding Close: ',
              E.Message);
            Result := 1;
          end;
        end;
      if schedulerRef <> nil then
        try
          schedulerRef.Shutdown; // drain before the bridge is released
          schedulerDrained := True;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, HostLogPrefix, ': FAIL scheduler Shutdown: ',
              E.Message);
            Result := 1;
          end;
        end;
      // CAP-8B ordering: teardown is the exact reverse of construction, so
      // the guard stops deciding before the handler stops serving and both
      // are disowned before webview_destroy. A Detach that raises must not
      // skip the ones after it.
      if navGuard <> nil then
        try
          navGuard.Detach;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, HostLogPrefix, ': FAIL guard Detach: ',
              E.Message);
            Result := 1;
          end;
        end;
      // guarded separately: Destroy calls Detach again as a safety net, and
      // an exception escaping here would abort THIS finally block, skipping
      // the handler Detach and webview_destroy below
      try
        FreeAndNil(navGuard);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, HostLogPrefix, ': FAIL guard Free: ', E.Message);
          Result := 1;
        end;
      end;
      if assetHandler <> nil then
        try
          assetHandler.Detach;
        except
          on E: Exception do
          begin
            WriteLn(StdErr, HostLogPrefix, ': FAIL handler Detach: ',
              E.Message);
            Result := 1;
          end;
        end;
      FreeAndNil(assetHandler);
      if safeToDestroy then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
        except
          on E: Exception do
          begin
            WriteLn(StdErr, HostLogPrefix, ': FAIL webview_destroy: ',
              E.Message);
            Result := 1;
          end;
        end;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, HostLogPrefix, ': FAIL ', E.ClassName, ': ',
        E.Message);
      Result := 1;
    end;
  end;
  if (scheduler <> nil) and
     not schedulerDrained then
    try
      scheduler.Shutdown;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, HostLogPrefix, ': FAIL final scheduler Shutdown: ',
          E.Message);
        Result := 1;
      end;
    end;
  // the trailing release chain runs under its own guard so control ALWAYS
  // reaches the verdict write below: an exception raised by an interface
  // release must become a FAIL verdict, not a missing file a gate cannot
  // tell from a crash
  try
    binding := nil;
    source := nil;
    schedulerRef := nil;
    scheduler := nil;
    policyRef := nil;
    assets := nil;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, HostLogPrefix, ': FAIL final teardown: ', E.ClassName,
        ': ', E.Message);
      Result := 1;
    end;
  end;
  // EVERY exit path ends here, so a requested verdict file always exists
  // when the process is gone. The one shape no user code can write a
  // verdict for is death by SIGNAL, where the file is simply absent - which
  // a gate reads as failure, fail-closed in the only direction available.
  if verdictFile <> '' then
    try
      if Result = 0 then
        PWebHostWriteVerdict(verdictFile,
          string(HostLogPrefix) + ': ' + string(PWEB_HOST_VERDICT_OK))
      else
        PWebHostWriteVerdict(verdictFile, string(HostLogPrefix) +
          ': FAIL (exit=' + IntToStr(Result) + ')');
    except
      on E: Exception do
      begin
        WriteLn(StdErr, HostLogPrefix, ': FAIL verdict file write: ',
          E.Message);
        Result := 1;
      end;
    end;
end;

end.
