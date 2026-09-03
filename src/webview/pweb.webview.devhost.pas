{
  pweb.webview.devhost - the DEV-ONLY composition of a generated host
  (CAP-10C2).

  Note for editors, the rule pweb.webview.host's own header states: a
  compiler directive may NOT be written inside a brace comment. FPC reads
  the nested brace as a directive and ends the comment at the next closing
  brace, so every conditional named in prose here is spelled without braces.

  THIS UNIT IS NEVER LINKED INTO A RELEASE. The generated program.lpr selects
  it under $ifdef PWEB_DEV and nothing else selects it, so the release
  binary's compiled unit set does not contain it and its bytes carry neither
  the dev argument nor the dev marker. test/cap10c2 measures both rather than
  asserting them: a directory listing of the release -FU output, and a byte
  scan of the release executable.

  ---------------------------------------------------------------------------
  WHAT DEVELOPMENT CHANGES, AND WHAT IT DOES NOT
  ---------------------------------------------------------------------------

  It changes exactly one thing: WHERE THE ASSET STORE COMES FROM, and how
  often it is replaced. Everything else is the production host, called
  through the production entry point with the production policy, the
  production bridge, the production platform handler, the production
  navigation guard and the production CSP.

  It does NOT change:

    the privileged origin      pweb://app, the only URI this process ever
                               navigates to, in development and in
                               production alike;
    the content security policy PWEB_NATIVE_CSP, byte-identical in both
                               binaries - no ws://, no wss://, no localhost,
                               no 127.0.0.1, no http:;
    what is served             every generation is ONE app.pwb, packed by
                               the frozen CAP-6 bundler and opened through
                               PWebBundleLoadFile with the production
                               refusals. There is no folder store, no
                               loose-asset path and no proxy anywhere in
                               this unit;
    how a switch happens       one webview_dispatch of the host's own
                               PWebHostRequestReload. Never injected
                               JavaScript, never location.reload(), never a
                               restart of the process.

  It starts no listener, opens no socket, resolves no host and speaks no
  protocol. Discovery of the next generation is a BOUNDED POLL of the
  filesystem: the poller tests for <root>/gen-<N+1>/app.pwb every
  PWEB_DEV_POLL_MS and looks only FORWARD. No socket, no pipe, no stdin
  protocol, no IPC of any kind.

  ---------------------------------------------------------------------------
  THE ARGUMENT, AND THE REFUSAL
  ---------------------------------------------------------------------------

      --pweb-dev-root=<directory>

  parsed in the SAME two-pass, duplicate-refusing style the two ratified
  host arguments are parsed in, and REQUIRED: a dev binary started without
  it refuses and exits nonzero BEFORE PWebHostRun is called, so it never
  reaches PWebHostLoadBundle and can never load an app.pwb that happens to
  sit beside it. That is the fail-closed direction, and it is the whole of
  why the dev host is a different binary rather than a flag on the real one.

  The argument string is then declared to the production host through
  TPWebHostOptions.ConsumedArgs, matched byte-exactly, so the host's own
  refusal of every argument it does not own is unchanged for everything
  else.

  ---------------------------------------------------------------------------
  THE SWAPPING STORE
  ---------------------------------------------------------------------------

  TPWebDevGenerationStore is a TInterfacedObject implementing IAssetStore. It
  holds ONE TZipAssetStore reference behind a TOSLock - the very lock
  discipline TZipAssetStore itself uses, because TZipRead's shared reads are
  not reentrant - and Swap replaces the reference. A read already in flight
  completes against the store IT took: the interface reference it holds keeps
  that store alive until the read returns, so a generation can be swapped out
  from under a running request without any read ever seeing a half-open
  archive.

  IAssetStore GAINS NOTHING. This is an implementation of the frozen
  interface, not a change to it.

  ---------------------------------------------------------------------------
  NO PLATFORM CONDITIONAL
  ---------------------------------------------------------------------------

  There is not one $ifdef in this unit and there must never be: everything
  platform-shaped - the handler, the guard, the pre-create check, the
  graceful stop - belongs to pweb.webview.host, which is the ONE allowlisted
  file in src/webview. The CAP-7F divergence sweep keeps this unit at zero.
}
unit pweb.webview.devhost;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.capabilities.policy,
  pweb.assets.intf,
  pweb.assets.bundle,
  pweb.webview.host;

const
  /// the ONE dev-only argument, and the marker that proves a binary is a
  // dev binary - test/cap10c2 scans the RELEASE bytes for it and requires
  // it absent
  PWEB_DEV_ARG_ROOT = '--pweb-dev-root=';

  /// how often the poller asks the filesystem whether the NEXT generation
  // has appeared
  // - a bound on latency, never a tuning knob. There is no listener to make
  // this an event, and inventing one would be inventing a transport
  PWEB_DEV_POLL_MS = 120;

  /// the immutable per-generation directory name prefix beneath the dev root
  PWEB_DEV_GEN_PREFIX = 'gen-';

  /// the ONE archive a generation holds
  PWEB_DEV_BUNDLE = 'app.pwb';

  /// how far forward the poller may count before it treats the sequence as
  // broken - a bound, not a policy: a dev session that has published four
  // thousand generations has other problems
  PWEB_DEV_MAX_GENERATION = 100000;

  /// the ONE ratified acknowledgement line, flushed, on stdout
  // - the CLI reads it from the engine's own line sink. The host writes
  // NOTHING to disk to report a switch
  PWEB_DEV_LOADED = ' loaded';
  PWEB_DEV_GENERATION = ': generation ';

type
  /// the swapping asset store - an IMPLEMENTATION of the frozen interface
  // - see the unit header for the lock discipline and why a read in flight
  // is safe across a Swap
  TPWebDevGenerationStore = class(TInterfacedObject, IAssetStore)
  private
    fCurrent: IAssetStore;
    fLock: TOSLock;
    fGeneration: Integer;
  public
    constructor Create(const AInitial: IAssetStore; AGeneration: Integer);
    destructor Destroy; override;
    /// replace the served archive; the previous one is released when the
    // last read holding it returns
    procedure Swap(const ANext: IAssetStore; AGeneration: Integer);
    /// the generation currently served
    function Generation: Integer;
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
  end;

/// the value of --pweb-dev-root=, and the exact argv string it came from
// - two passes, duplicate-refusing, exactly as PWebHostParseArguments does
// it: False means the argument is absent or refused, and Detail says which
function PWebDevParseRoot(out Root: TFileName; out ArgvString: RawUtf8;
  out Detail: RawUtf8): Boolean;

/// the directory name of one generation
function PWebDevGenerationDir(N: Integer): RawUtf8;

/// run a generated application in DEVELOPMENT mode
// - requires --pweb-dev-root=<dir> holding gen-1/app.pwb, opens that
// archive through the frozen production loader, wraps it in the swapping
// store, starts the forward-only poller and hands the store to the
// production PWebHostRun
// - the return value is the production host's, unchanged; a refusal before
// the host runs is 2 (the argument) or 3 (the root or the first generation)
function PWebDevHostRun(const Options: TPWebHostOptions;
  const Policy: TPWebCapabilityPolicy;
  const Bridge: IInvocationBridge): Integer;


implementation

{ TPWebDevGenerationStore }

constructor TPWebDevGenerationStore.Create(const AInitial: IAssetStore;
  AGeneration: Integer);
begin
  inherited Create;
  if AInitial = nil then
    raise Exception.Create('PWebDevGenerationStore needs an initial store');
  fLock.Init;
  fCurrent := AInitial;
  fGeneration := AGeneration;
end;

destructor TPWebDevGenerationStore.Destroy;
begin
  fCurrent := nil;
  fLock.Done;
  inherited Destroy;
end;

procedure TPWebDevGenerationStore.Swap(const ANext: IAssetStore;
  AGeneration: Integer);
begin
  if ANext = nil then
    exit;
  fLock.Lock;
  try
    fCurrent := ANext;
    fGeneration := AGeneration;
  finally
    fLock.UnLock;
  end;
end;

function TPWebDevGenerationStore.Generation: Integer;
begin
  fLock.Lock;
  try
    Result := fGeneration;
  finally
    fLock.UnLock;
  end;
end;

function TPWebDevGenerationStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  serving: IAssetStore;
begin
  // ONE short critical section that takes a REFERENCE, and the read itself
  // outside it. The reference keeps the archive alive for the whole read,
  // so a Swap concurrent with this call cannot free what is being read -
  // and a slow read cannot block the swap
  fLock.Lock;
  try
    serving := fCurrent;
  finally
    fLock.UnLock;
  end;
  if serving = nil then
    exit(False);
  // the frozen store's own fail-closed path grammar decides; this wrapper
  // validates nothing and relaxes nothing
  Result := serving.TryRead(Path, Asset);
end;

{ the argument }

function PWebDevGenerationDir(N: Integer): RawUtf8;
begin
  Result := PWEB_DEV_GEN_PREFIX + RawUtf8(IntToStr(N));
end;

function PWebDevParseRoot(out Root: TFileName; out ArgvString: RawUtf8;
  out Detail: RawUtf8): Boolean;
var
  i: Integer;
  arg, value: string;
  seen: Boolean;
begin
  Root := '';
  ArgvString := '';
  Detail := 'dev_root_absent';
  Result := False;
  seen := False;
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, Length(PWEB_DEV_ARG_ROOT)) <>
         string(PWEB_DEV_ARG_ROOT) then
      continue;
    if seen then
    begin
      // last-one-wins is an argument the host half-ignores; the ratified
      // discipline is to refuse
      Detail := 'dev_root_duplicate';
      Root := '';
      ArgvString := '';
      exit(False);
    end;
    seen := True;
    value := Copy(arg, Length(PWEB_DEV_ARG_ROOT) + 1, MaxInt);
    if value = '' then
    begin
      Detail := 'dev_root_empty';
      exit(False);
    end;
    // expanded ONCE, here, before anything can change the working
    // directory - the same rule the verdict path follows
    Root := ExpandFileName(value);
    ArgvString := RawUtf8(arg);
  end;
  if not seen then
    exit(False);
  Detail := '';
  Result := True;
end;

{ the poller }

var
  /// the dev root this process was started with - set once, before the
  // poller exists, and never written again
  DevRoot: TFileName;
  /// the swapping store, as a plain object reference for the poller. The
  // interface reference below is what keeps it alive
  DevStore: TPWebDevGenerationStore;
  DevStoreRef: IAssetStore;
  /// the generation the poller is looking FORWARD from
  DevGeneration: Integer;
  /// how the teardown tells the poller to return
  DevStop: TSynEvent;
  DevPrefix: RawUtf8;

// one flushed line, on stdout, in the ratified shape. The CLI reads it from
// the supervision engine's own line sink; nothing is written to a disk
procedure DevSay(const Text: RawUtf8);
begin
  WriteLn(string(DevPrefix), string(Text));
  // MEASURED at CAP-10C1: FPC block-buffers stdout on a POSIX pipe, so a
  // line that is not flushed reaches a supervisor only at exit - and an
  // acknowledgement that arrives after the switch it acknowledges is not
  // an acknowledgement
  Flush(Output);
end;

function PWebDevPollThread(Param: Pointer): PtrInt;
var
  next: Integer;
  candidate: TFileName;
  store: IAssetStore;
  refusal: TPWebBundleRefusal;
begin
  Result := 0;
  while True do
  begin
    if DevStop <> nil then
    begin
      // a bounded WAIT rather than a sleep: the teardown sets the event and
      // the poller returns at once instead of burning its interval
      if DevStop.WaitFor(PWEB_DEV_POLL_MS) then
        exit;
    end
    else
      Sleep(PWEB_DEV_POLL_MS);
    next := DevGeneration + 1;
    if next > PWEB_DEV_MAX_GENERATION then
      exit;
    candidate := DevRoot + PathDelim + string(PWebDevGenerationDir(next)) +
      PathDelim + string(PWEB_DEV_BUNDLE);
    if not FileExists(candidate) then
      continue;
    // THE PRODUCTION LOADER, with the production refusals. A generation the
    // frozen loader refuses is reported and SKIPPED: the current one stays
    // live, because a development loop that blanks the window on a bad
    // archive is a development loop that hides the archive
    if PWebBundleLoadFile(candidate, PWEB_SUPPORTED_PROTOCOLS,
         PWEB_RUNTIME_VERSION, store, refusal) then
    begin
      DevStore.Swap(store, next);
      DevGeneration := next;
      // the switch is a NATIVE re-navigation to the one origin that
      // exists. Never injected script, never location.reload()
      PWebHostRequestReload;
      DevSay(PWEB_DEV_GENERATION + RawUtf8(IntToStr(next)) +
        PWEB_DEV_LOADED);
    end
    else
    begin
      // reason category only, exactly as the production loader's caller
      // reports one: no parser internals and no content from the archive
      WriteLn(StdErr, string(DevPrefix), ': generation ', next,
        ' REFUSED (', string(PWebBundleRefusalText(refusal)), ')');
      Flush(StdErr);
      // counted as seen, so one bad generation does not wedge the poller
      // on it forever while later ones publish behind it
      DevGeneration := next;
    end;
  end;
end;

function PWebDevHostRun(const Options: TPWebHostOptions;
  const Policy: TPWebCapabilityPolicy;
  const Bridge: IInvocationBridge): Integer;
var
  root: TFileName;
  argv, detail: RawUtf8;
  first: TFileName;
  initial: IAssetStore;
  refusal: TPWebBundleRefusal;
  opts: TPWebHostOptions;
  pollId, pollHandle: system.TThreadID;
  pollStarted: Boolean;
begin
  DevPrefix := Options.LogPrefix;
  pollStarted := False;
  pollHandle := system.TThreadID(0);
  // 1. THE ARGUMENT IS REQUIRED, and it is refused BEFORE anything else.
  // Nothing below this point can be reached without a dev root, so the
  // production bundle-beside-the-executable rule is never consulted
  if not PWebDevParseRoot(root, argv, detail) then
  begin
    WriteLn(StdErr, string(DevPrefix), ': DEV REFUSED (', string(detail),
      ') -- this is a development binary and requires ',
      string(PWEB_DEV_ARG_ROOT), '<directory>');
    Flush(StdErr);
    exit(2);
  end;
  if not DirectoryExists(root) then
  begin
    WriteLn(StdErr, string(DevPrefix), ': DEV REFUSED (dev_root_missing)');
    Flush(StdErr);
    exit(3);
  end;
  // 2. generation 1 must already be there. The CLI packs it before it
  // starts this process, so the host never opens on an empty store
  first := root + PathDelim + string(PWebDevGenerationDir(1)) + PathDelim +
    string(PWEB_DEV_BUNDLE);
  if not PWebBundleLoadFile(first, PWEB_SUPPORTED_PROTOCOLS,
       PWEB_RUNTIME_VERSION, initial, refusal) then
  begin
    WriteLn(StdErr, string(DevPrefix), ': DEV REFUSED (generation 1: ',
      string(PWebBundleRefusalText(refusal)), ')');
    Flush(StdErr);
    exit(3);
  end;
  DevRoot := root;
  DevGeneration := 1;
  DevStore := TPWebDevGenerationStore.Create(initial, 1);
  DevStoreRef := DevStore;
  DevStop := TSynEvent.Create;
  try
    // created BEFORE the host runs, so a generation published while the
    // window is still opening is picked up rather than missed
    pollHandle := BeginThread(@PWebDevPollThread, nil, pollId);
    pollStarted := pollHandle <> system.TThreadID(0);
    if not pollStarted then
    begin
      WriteLn(StdErr, string(DevPrefix),
        ': DEV REFUSED (poll_thread_unavailable)');
      Flush(StdErr);
      exit(3);
    end;
    DevSay(PWEB_DEV_GENERATION + '1' + PWEB_DEV_LOADED);
    opts := Options;
    // the ONE argument this composition owns, declared byte-exactly so the
    // production host's refusal of every other argument is unchanged
    SetLength(opts.ConsumedArgs, 1);
    opts.ConsumedArgs[0] := argv;
    // THE PRODUCTION ENTRY POINT, with the production policy, the
    // production bridge and a store this composition opened through the
    // production loader
    Result := PWebHostRun(opts, Policy, Bridge, DevStoreRef);
  finally
    if DevStop <> nil then
      DevStop.SetEvent;
    if pollStarted then
    begin
      if WaitForThreadTerminate(pollHandle,
           PWEB_HOST_CLOSER_MARGIN_MS) <> 0 then
        WriteLn(StdErr, string(DevPrefix),
          ': FAIL the generation poller did not terminate');
      CloseThread(pollHandle);
    end;
    // only after the join: the poller holds a reference to the event until
    // it returns
    FreeAndNil(DevStop);
    DevStoreRef := nil;
    DevStore := nil;
  end;
end;

end.
