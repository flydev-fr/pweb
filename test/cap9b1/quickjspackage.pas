program quickjspackage;

{ CAP-9B1: the QuickJS plugin-package + deterministic module-loader
  harness. Headless and deterministic on all four targets - every line
  it writes to build/cap9b1/quickjs-package-corpus.txt is a pure
  decision, a canonical name, a sha256 of bytes this program itself
  produced, or a deterministic counter, so the file bytes (and the
  sha256 the CAP-7F emitters record as quickjs_package_digest) are
  identical on windows-x86_64 / linux-x86_64 / macos-x86_64 /
  macos-arm64 by construction.

  WHAT RUNS: the UNCHANGED production runtime - frozen scheduler +
  CAP-8A policy + the REAL TMormotInvocationBridge (TRestServer.Uri)
  behind a counting decorator - with CAP-9B1 package plugins as
  invocation sources.

  FIXTURES ARE GENERATED, NEVER COMMITTED. The hostile corpus contains
  invalid UTF-8, an embedded NUL, oversized and CRLF modules; committed
  files would be at the mercy of core.autocrlf and would break module-
  hash parity between a Windows and a POSIX checkout. Every package is
  written from in-source byte constants into a temp folder AND built
  into an in-memory ZIP from the SAME bytes, so both carriers are
  byte-identical by construction - the discipline CAP-9A used for its
  scripts.

  High bytes are always built through Bytes([...]): a '#$EF' string
  literal in Pascal source is re-encoded through the unit's code page
  on assignment (measured - it silently turns a 3-byte BOM into 6).

  P1-P40 matrix (the numbers referenced by the CAP-9B1 spec):
    P1  valid manifest                     P21 module executes once
    P2  malformed manifest                 P22 isolated module caches
    P3  duplicate manifest key             P23 missing module rejected
    P4  package id mismatch                P24 syntax error is a load failure
    P5  security-authority fields          P25 invalid UTF-8 rejected
    P6  canonical entry loads              P26 NUL rejected
    P7  missing entry rejected             P27 empty module accepted
    P8  folder package loads               P28 module-size limit
    P9  ZIP package loads                  P29 total-source limit
    P10 folder/ZIP corpus parity           P30 module-count limit
    P11 static relative import             P31 resolution-depth limit
    P12 nested relative import             P32 load-time invocation rule
    P13 parent-relative inside root        P33 failed load leaves nothing
    P14 root escape rejected               P34 no worker touches the loader
    P15 bare specifier rejected            P35 package cannot raise caps
    P16 absolute specifier rejected        P36 package cannot forge identity
    P17 URL specifier rejected             P37 CAP-9A Add -> 42 still green
    P18 query/fragment rejected            P38 denied plugin still forbidden
    P19 backslash rejected                 P39 std/os/fs/net globals absent
    P20 exact-case mismatch rejected       P40 repeated load/destroy cycles

  Markers:
      quickjspackage: QUICKJS PACKAGE PASS
      quickjspackage: QUICKJS PACKAGE FAIL (<reason>)
  Writes build/cap9b1/quickjspackage-<target>.json (schema 1, overall
  PASS|FAIL) and build/cap9b1/quickjs-package-corpus.txt. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.zip,
  mormot.lib.z,
  mormot.core.unicode,
  mormot.core.json,
  mormot.core.variants,
  mormot.core.interfaces,
  mormot.crypt.core,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  mormot.script.core,
  mormot.script.quickjs,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.assets.folder,
  pweb.assets.zip,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.script.package,
  pweb.script.quickjs;

const
  LOG_PREFIX = 'quickjspackage';
  MARKER_PASS = 'quickjspackage: QUICKJS PACKAGE PASS';
  MARKER_FAIL = 'quickjspackage: QUICKJS PACKAGE FAIL';
  {$ifdef OSDARWIN}
    {$ifdef CPUAARCH64}
    TARGET_ID = 'macos-arm64';
    {$else}
    TARGET_ID = 'macos-x86_64';
    {$endif CPUAARCH64}
  {$else}
  {$ifdef OSLINUX}
  TARGET_ID = 'linux-x86_64';
  {$else}
  TARGET_ID = 'windows-x86_64';
  {$endif OSLINUX}
  {$endif OSDARWIN}

  CORPUS_FILE = 'build/cap9b1/quickjs-package-corpus.txt';
  READY_WAIT_MS = 20000;
  SCRIPT_WAIT_MS = 20000;
  FIXED_FILE_AGE = $2E210000; // deterministic ZIP timestamps

  ID_CALC: RawUtf8 = 'plugin:calculator';
  ID_REP: RawUtf8 = 'plugin:reporting';
  PKG_ID: RawUtf8 = 'quickjs.calculator';
  ENTRY: RawUtf8 = 'main.js';

  CAP_CALC = 'calculator.add';
  CAP_OPEN = 'external.open';
  M_ADD = 'CalculatorService.Add';
  M_OPEN = 'pweb.openExternal';

type
  ICalculatorService = interface(IInvokable)
    ['{4B0E2C31-58D9-4A0C-9B7E-6A1F0D3C82E4}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  TCountingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TSnapshotAdapter = class
  public
    function Snapshot(const APrincipalId: Utf8String): TPWebCapabilities;
  end;

  { A sink for the P33 post-failure probe only. A CLOSED source rejects
    pre-queue and never invokes the sink (frozen contract), so this
    body must never run - it counts calls so that "never" is measured. }
  TNullCompletion = class(TInterfacedObject, IInvocationCompletion)
  public
    procedure Complete(const AResult: TPWebInvocationResult);
  end;

  { One package file, held as raw bytes: the SAME bytes go to the folder
    fixture, into the ZIP and into the corpus hash. }
  TPkgFile = record
    Name: RawUtf8;
    Content: RawByteString;
  end;
  TPkgFiles = array of TPkgFile;

  { Wraps a real store to prove WHICH THREAD read plugin source. Every
    read must come from the one owning plugin thread; a scheduler worker
    touching the package store would show up as a second thread here,
    and the corpus refuses a nonzero count. The first reader is recorded
    rather than supplied, because the plugin's thread id does not exist
    until after the store has been handed to it. }
  TCountingStore = class(TInterfacedObject, IAssetStore)
  private
    FInner: IAssetStore;
    FFirst: LongInt; // LongInt so the winner publishes with one CAS
    FOther: LongInt;
    FReads: LongInt;
  public
    constructor Create(const AInner: IAssetStore);
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
    function FirstThread: LongInt;
    function OtherThreadReads: LongInt;
    function Reads: LongInt;
  end;

var
  // corpus + failure accumulation
  CorpusLines: RawUtf8;
  FailReasons: RawUtf8;
  // ledgers
  CountAddByPrincipal: array[0..1] of LongInt;
  CountOpenReached: LongInt;      // MUST stay 0
  NativeServiceAdd: LongInt;
  StoreReads: LongInt;
  StoreWrongThread: LongInt;      // MUST stay 0
  LoaderWrongThread: LongInt;     // MUST stay 0
  LoadTimeBridge: LongInt;        // bridge hits during Loading: MUST stay 0
  BridgeDuringLoad: LongInt;      // armed while a package is loading
  NullSinkCalls: LongInt;         // MUST stay 0 (a closed source never sinks)
  SourceOpenAfterFailure: LongInt;// MUST stay 0 (P33)
  StoreNeverRead: LongInt;        // MUST stay 0 (a load that read nothing)
  StoreForeignFirstReader: LongInt; // MUST stay 0 (first reader != plugin)
  LoadTimeInvokeGate: LongInt;    // times the Loading gate actually FIRED
  BridgePluginId: RawUtf8;        // PluginId as the BRIDGE received it
  BridgeTrusted: RawUtf8;         // TrustedContent as the bridge saw it
  // runtime under test
  gScheduler: TInvocationScheduler;
  gSchedulerRef: IInvocationScheduler;
  gPolicy: TPWebCapabilityPolicy;
  gPolicyRef: ICapabilityPolicy;
  gBridge: IInvocationBridge;
  gServer: TRestServerFullMemory;
  gRealBridge: IInvocationBridge;
  gSnap: TSnapshotAdapter;
  gSnapCb: TPWebQuickJSSnapshotEvent;
  root: TFileName;
  workDir: TFileName;
  fixtureSeq: Integer;
  // when set, RunPackage evaluates it on the loaded plugin and records the
  // answer plus the loader-call count that followed
  gProbeScript: RawUtf8;
  // per-fixture engine bounds; reset to the defaults after every use
  gEngineLimits: TPWebQuickJSLimits;

{ ---- corpus + failure helpers ------------------------------------------- }

procedure Emit(const ALine: RawUtf8);
begin
  CorpusLines := CorpusLines + ALine + #10;
end;

procedure Fail(const AReason: RawUtf8);
begin
  if FailReasons <> '' then
    FailReasons := FailReasons + '; ';
  FailReasons := FailReasons + AReason;
end;

procedure Expect(ACond: Boolean; const AReason: RawUtf8);
begin
  if not ACond then
    Fail(AReason);
end;

function YesNo(ACond: Boolean): RawUtf8;
begin
  if ACond then
    Result := 'yes'
  else
    Result := 'no';
end;

function IntStr(AValue: Int64): RawUtf8;
begin
  Result := Utf8String(IntToStr(AValue));
end;

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := AValue;
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or (Result[i] < #$20) then
      Result[i] := '''';
end;

// high bytes MUST be built explicitly - a '#$EF' string literal is
// re-encoded through the unit's code page on assignment
function Bytes(const AValues: array of Byte): RawByteString;
var
  i: PtrInt;
begin
  SetLength(Result, Length(AValues));
  for i := 0 to High(AValues) do
    Result[i + 1] := AnsiChar(AValues[i]);
end;

function Repeated(const AText: RawByteString; ATimes: Integer): RawByteString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to ATimes do
    Result := Result + AText;
end;

// the CAP-4 harness's tree remover, verbatim in behaviour: a junction is
// removed, never recursed into, so a fixture directory can never take a
// delete outside itself
procedure RmTree(const Dir: TFileName);
var
  sr: TSearchRec;
begin
  if (Dir = '') or
     not DirectoryExists(Dir) then
    exit;
  if FindFirst(Dir + PathDelim + '*', faAnyFile{%H-}, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') then
        continue;
      if (sr.Attr and faDirectory{%H-}) <> 0 then
      begin
        if (sr.Attr and $00000400) <> 0 then // junction: do not recurse
          RemoveDir(Dir + PathDelim + sr.Name)
        else
          RmTree(Dir + PathDelim + sr.Name);
      end
      else
        SysUtils.DeleteFile(Dir + PathDelim + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  RemoveDir(Dir);
end;

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
  dir := Executable.ProgramFilePath;
  for i := 1 to 8 do
  begin
    if FileExists(dir + 'webview.lock') then
      exit(dir);
    parent := ExtractFilePath(ExcludeTrailingPathDelimiter(dir));
    if (parent = '') or (parent = dir) then
      break;
    dir := parent;
  end;
  Result := '';
end;

{ ---- the service, bridge, policy (CAP-9A shapes, unchanged) -------------- }

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedIncrement(NativeServiceAdd);
  Result := a + b;
end;

constructor TCountingBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function TCountingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if InterlockedCompareExchange(BridgeDuringLoad, 0, 0) <> 0 then
    // any bridge activity while a package is Loading breaks the ratified
    // load-time rule - counted, never assumed
    InterlockedIncrement(LoadTimeBridge);
  if Method = M_OPEN then
  begin
    // must never be reached: neither reference principal holds
    // external.open, so the policy refuses before routing
    InterlockedIncrement(CountOpenReached);
    exit(PWebDefaultErrorResult(pecMethodNotFound));
  end;
  if Method = M_ADD then
  begin
    if Context.PrincipalId = ID_CALC then
    begin
      InterlockedIncrement(CountAddByPrincipal[0]);
      // record the two context fields CreatePackage builds NATIVELY, as
      // the bridge actually received them: the CAP-8A policy makes no
      // identity check on either for a pkQuickJS principal, so without
      // this nothing in the suite would ever observe them and a
      // regression that mis-set them would pass every gate
      BridgePluginId := Context.PluginId;
      if Context.TrustedContent then
        BridgeTrusted := 'true'
      else
        BridgeTrusted := 'false';
    end
    else if Context.PrincipalId = ID_REP then
      InterlockedIncrement(CountAddByPrincipal[1]);
    exit(FInner.Invoke(Context, Method, Args, Token));
  end;
  Result := FInner.Invoke(Context, Method, Args, Token);
end;

function TSnapshotAdapter.Snapshot(
  const APrincipalId: Utf8String): TPWebCapabilities;
begin
  Result := gPolicy.SnapshotCapabilities(APrincipalId);
end;

procedure TNullCompletion.Complete(const AResult: TPWebInvocationResult);
begin
  InterlockedIncrement(NullSinkCalls);
end;

function BuildPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALC, CAP_OPEN]);
    b.SetPrincipalCapabilities(ID_CALC, [CAP_CALC]);
    b.SetPrincipalCapabilities(ID_REP, []); // explicit empty = no rights
    b.MapMethod(M_ADD, [CAP_CALC]);
    b.MapMethod(M_OPEN, [CAP_OPEN]);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ ---- the counting store -------------------------------------------------- }

constructor TCountingStore.Create(const AInner: IAssetStore);
begin
  inherited Create;
  FInner := AInner;
end;

function TCountingStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  tid: LongInt;
begin
  InterlockedIncrement(StoreReads);
  InterlockedIncrement(FReads);
  // publish the winner ATOMICALLY: with a separate flag and assignment a
  // second thread could read FFirst in the window between them, and this
  // counter has to be trustworthy at exactly 0
  tid := LongInt(PtrUInt(GetCurrentThreadId()));
  if InterlockedCompareExchange(FFirst, tid, 0) <> 0 then
    if FFirst <> tid then
    begin
      InterlockedIncrement(FOther);
      InterlockedIncrement(StoreWrongThread);
    end;
  Result := FInner.TryRead(Path, Asset);
end;

function TCountingStore.FirstThread: LongInt;
begin
  Result := InterlockedCompareExchange(FFirst, 0, 0);
end;

function TCountingStore.OtherThreadReads: LongInt;
begin
  Result := InterlockedCompareExchange(FOther, 0, 0);
end;

function TCountingStore.Reads: LongInt;
begin
  Result := InterlockedCompareExchange(FReads, 0, 0);
end;

{ ---- fixture corpus ------------------------------------------------------ }

procedure AddFile(var AFiles: TPkgFiles; const AName: RawUtf8;
  const AContent: RawByteString);
var
  n: PtrInt;
begin
  n := Length(AFiles);
  SetLength(AFiles, n + 1);
  AFiles[n].Name := AName;
  AFiles[n].Content := AContent;
end;

procedure ReplaceFile(var AFiles: TPkgFiles; const AName: RawUtf8;
  const AContent: RawByteString);
var
  i: PtrInt;
begin
  for i := 0 to High(AFiles) do
    if AFiles[i].Name = AName then
    begin
      AFiles[i].Content := AContent;
      exit;
    end;
  AddFile(AFiles, AName, AContent);
end;

procedure RemoveFile(var AFiles: TPkgFiles; const AName: RawUtf8);
var
  i, j: PtrInt;
begin
  for i := 0 to High(AFiles) do
    if AFiles[i].Name = AName then
    begin
      for j := i to High(AFiles) - 1 do
        AFiles[j] := AFiles[j + 1];
      SetLength(AFiles, Length(AFiles) - 1);
      exit;
    end;
end;

const
  MANIFEST_OK: RawUtf8 =
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js"}';

  { The entry imports two relative modules, imports lib/state.js a
    SECOND time (proving one execution), probes the ratified load-time
    invocation rule, and exports its callable surface onto globalThis so
    the host can drive it after the package is accepted. }
  MAIN_JS: RawUtf8 =
    'import { add, who } from "./lib/calculator.js";'#10 +
    'import { tag } from "./lib/state.js";'#10 +
    'globalThis.__tag = tag;'#10 +
    'globalThis.__who = who;'#10 +
    'globalThis.__loadInvoke = "none";'#10 +
    'try {'#10 +
    '  pweb.invoke("CalculatorService.Add", { a: 1, b: 1 });'#10 +
    '  globalThis.__loadInvoke = "allowed";'#10 +
    '} catch (e) { globalThis.__loadInvoke = String(e.code); }'#10 +
    'globalThis.pluginAdd = function (a, b) { return add(a, b); };'#10 +
    'globalThis.pluginOpen = function () {'#10 +
    '  return pweb.invoke("pweb.openExternal", { url: "https://x" });'#10 +
    '};'#10;

  CALC_JS: RawUtf8 =
    'import { tag } from "./state.js";'#10 +
    'import { unit } from "../shared/unit.js";'#10 +
    'export const who = tag;'#10 +
    'export function add(a, b) {'#10 +
    '  return pweb.invoke("CalculatorService.Add", { a: a, b: b }) * unit;'#10 +
    '}'#10;

  STATE_JS: RawUtf8 =
    'globalThis.__stateRuns = (globalThis.__stateRuns || 0) + 1;'#10 +
    'export const tag = "state" + globalThis.__stateRuns;'#10;

  UNIT_JS: RawUtf8 = 'export const unit = 1;'#10;

function ReferencePackage: TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', MANIFEST_OK);
  AddFile(Result, 'main.js', MAIN_JS);
  AddFile(Result, 'lib/calculator.js', CALC_JS);
  AddFile(Result, 'lib/state.js', STATE_JS);
  AddFile(Result, 'shared/unit.js', UNIT_JS);
end;

{ ---- carriers ------------------------------------------------------------ }

procedure WriteFolderPackage(const ADir: TFileName; const AFiles: TPkgFiles);
var
  i, j: PtrInt;
  full: TFileName;
begin
  if not ForceDirectories(ADir) then
    raise Exception.CreateFmt('cannot create %s', [ADir]);
  for i := 0 to High(AFiles) do
  begin
    full := IncludeTrailingPathDelimiter(ADir);
    for j := 1 to Length(AFiles[i].Name) do
      if AFiles[i].Name[j] = '/' then
        full := full + PathDelim
      else
        full := full + AFiles[i].Name[j];
    ForceDirectories(ExtractFileDir(full));
    if not FileFromString(AFiles[i].Content, full) then
      raise Exception.CreateFmt('cannot write %s', [full]);
  end;
end;

function BuildZipPackage(const AFiles: TPkgFiles): RawByteString;
var
  mem: TMemoryStream;
  zw: TZipWrite;
  i: PtrInt;
  empty: AnsiChar;
begin
  empty := #0;
  mem := TMemoryStream.Create;
  try
    zw := TZipWrite.Create(mem);
    try
      for i := 0 to High(AFiles) do
        if AFiles[i].Content = '' then
          zw.AddDeflated(Utf8ToString(AFiles[i].Name), @empty, 0,
            Z_USUAL_COMPRESSION, FIXED_FILE_AGE)
        else
          zw.AddDeflated(Utf8ToString(AFiles[i].Name),
            pointer(AFiles[i].Content), Length(AFiles[i].Content),
            Z_USUAL_COMPRESSION, FIXED_FILE_AGE);
    finally
      zw.Free;
    end;
    SetString(Result, PAnsiChar(mem.Memory), mem.Size);
  finally
    mem.Free;
  end;
end;

function NextFixtureDir: TFileName;
begin
  Inc(fixtureSeq);
  Result := IncludeTrailingPathDelimiter(workDir) +
    TFileName('pkg' + IntToStr(fixtureSeq));
end;

{ ---- one load attempt ---------------------------------------------------- }

type
  TLoadOutcome = record
    Ok: Boolean;
    Code: TPWebPackageLoadCode;
    Detail: RawUtf8;
    Result42: RawUtf8;
    LoadInvoke: RawUtf8;
    StateRuns: RawUtf8;
    Sandbox: RawUtf8;
    Manifest: RawUtf8;       // the PARSED projection, not our constants
    LoadTimeInvokes: Integer;// times the Loading gate refused an invoke
    Probe: RawUtf8;          // gProbeScript's answer, when one is set
    ProbeLoaderCalls: Integer; // loader calls AFTER the probe ran
    StoreThreadOk: Boolean;
    SourceClosed: Boolean;   // failed loads only: the source reports perClosed
    Modules: RawUtf8;   // canonical names in load order, '|' separated
    Edges: RawUtf8;     // sorted 'importer>imported', '|' separated
    Hashes: RawUtf8;    // sha256 of each loaded module, in load order
    LoaderCalls: Integer;
    NormalizeCalls: Integer;
  end;

function SortedEdges(AGraph: TPWebModuleGraph): RawUtf8;
var
  a: TRawUtf8DynArray;
  i, j: PtrInt;
  t: RawUtf8;
begin
  SetLength(a, AGraph.EdgeCount);
  for i := 0 to AGraph.EdgeCount - 1 do
    a[i] := AGraph.Edge(i);
  // insertion sort: the edge set is tiny and a fixed comparison keeps
  // the corpus independent of resolution order on every target
  for i := 1 to High(a) do
  begin
    t := a[i];
    j := i - 1;
    while (j >= 0) and (a[j] > t) do
    begin
      a[j + 1] := a[j];
      Dec(j);
    end;
    a[j + 1] := t;
  end;
  Result := '';
  for i := 0 to High(a) do
  begin
    if i > 0 then
      Result := Result + '|';
    Result := Result + a[i];
  end;
end;

function ModuleHashes(AGraph: TPWebModuleGraph;
  const AStore: IAssetStore): RawUtf8;
var
  i: Integer;
  asset: TAssetResponse;
  src: RawUtf8;
  code: TPWebPackageLoadCode;
begin
  Result := '';
  for i := 0 to AGraph.LoadedCount - 1 do
  begin
    if i > 0 then
      Result := Result + '|';
    if AStore.TryRead(AGraph.LoadedName(i), asset) and
       PWebPrepareModuleSource(asset.Content, src, code) then
      // the PREPARED bytes - exactly what was handed to JS_Eval
      Result := Result + Copy(Sha256(src), 1, 16)
    else
      Result := Result + 'unreadable';
  end;
end;

function ModuleList(AGraph: TPWebModuleGraph): RawUtf8;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to AGraph.LoadedCount - 1 do
  begin
    if i > 0 then
      Result := Result + '|';
    Result := Result + AGraph.LoadedName(i);
  end;
end;

{ Evaluate on the loaded plugin and return the answer, or ONE fixed token
  on any failure. Never the engine's own text: corpus bytes must be a
  function of the decisions, not of how a particular target's engine
  phrased a timeout. }
function EvalToken(APlugin: TPWebQuickJSPlugin;
  const AScript: RawUtf8): RawUtf8;
var
  js, err: RawUtf8;
begin
  if APlugin.Eval(AScript, js, err, 0, SCRIPT_WAIT_MS) then
    Result := js
  else
  begin
    Result := 'evalfail';
    Fail('a post-load Eval did not complete (corpus token: evalfail)');
  end;
end;

{ Load one package through one store and, on success, exercise it.
  Always tears the plugin and its source down before returning, so no
  fixture can leak a live engine into the next one. }
function RunPackage(const AStore: IAssetStore; APrincipal: Integer;
  const AExpectedEntry: RawUtf8;
  const ALimits: TPWebPackageLimits): TLoadOutcome;
var
  desc: TPWebQuickJSPackageDescriptor;
  src: IInvocationSource;
  srcLim: TPWebSourceLimits;
  plugin: TPWebQuickJSPlugin;
  counting: TCountingStore;
  countingRef: IAssetStore;
  probeCtx: TInvocationContext;
  js, err: RawUtf8;
begin
  Result := Default(TLoadOutcome);
  Result.Code := plcNone;
  counting := TCountingStore.Create(AStore);
  countingRef := counting;
  srcLim := Default(TPWebSourceLimits);
  srcLim.MaxConcurrent := 4;
  srcLim.MaxQueueSize := 16;
  src := gScheduler.RegisterSource(srcLim);
  desc := Default(TPWebQuickJSPackageDescriptor);
  if APrincipal = 0 then
  begin
    desc.PrincipalId := ID_CALC;
    desc.PluginId := 'calculator';
    desc.Capabilities := gPolicy.SnapshotCapabilities(ID_CALC);
  end
  else
  begin
    desc.PrincipalId := ID_REP;
    desc.PluginId := 'reporting';
    desc.Capabilities := gPolicy.SnapshotCapabilities(ID_REP);
  end;
  desc.PackageStore := countingRef;
  desc.ExpectedPackageId := PKG_ID;
  desc.ExpectedEntryPoint := AExpectedEntry;
  desc.Engine := gEngineLimits;
  desc.Package := ALimits;
  InterlockedExchange(BridgeDuringLoad, 1);
  plugin := nil;
  try
    Result.Ok := PWebLoadQuickJSPackage(desc, src, gSnapCb, READY_WAIT_MS,
      plugin, Result.Code, Result.Detail);
    InterlockedExchange(BridgeDuringLoad, 0);
    if not Result.Ok then
    begin
      // P33: an atomic failure leaves NOTHING live - the plugin handle is
      // nil and the source has already been Quiesced and Closed, so the
      // very next enqueue on it must report perClosed. Measured on every
      // hostile fixture, not asserted once.
      probeCtx := Default(TInvocationContext);
      probeCtx.PrincipalKind := pkQuickJS;
      probeCtx.PrincipalId := desc.PrincipalId;
      probeCtx.PluginId := desc.PluginId;
      probeCtx.Capabilities := desc.Capabilities;
      Result.SourceClosed := src.TryEnqueue(probeCtx, M_ADD,
        '{"a":1,"b":1}', TNullCompletion.Create) = perClosed;
      exit;
    end;
    // the loader AND every package store read must have happened on the
    // plugin's own thread - measured, never assumed. (On the FAILURE
    // path PWebLoadQuickJSPackage forces ACode := plcThread when its own
    // counter is nonzero, so the gate is not reachable only through a
    // successful load.)
    InterlockedExchangeAdd(LoaderWrongThread, plugin.LoaderWrongThreadCalls);
    // three DISTINCT conditions, reported separately: TryRead already
    // counts an off-thread read into StoreWrongThread, so re-counting it
    // here would double it and conflate "read by two threads" with
    // "never read" and "first reader was not the plugin thread"
    if counting.Reads = 0 then
      InterlockedIncrement(StoreNeverRead);
    if counting.FirstThread <> LongInt(PtrUInt(plugin.ThreadID)) then
      InterlockedIncrement(StoreForeignFirstReader);
    Result.StoreThreadOk := (counting.OtherThreadReads = 0) and
      (counting.Reads > 0) and
      (counting.FirstThread = LongInt(PtrUInt(plugin.ThreadID)));
    Result.LoaderCalls := plugin.LoaderCalls;
    Result.NormalizeCalls := plugin.NormalizeCalls;
    // the counter that proves the P32 gate FIRED, as opposed to the
    // fixture simply never reaching pweb.invoke - __loadInvoke alone
    // cannot tell those two apart
    Result.LoadTimeInvokes := plugin.LoadTimeInvokes;
    InterlockedExchangeAdd(LoadTimeInvokeGate, plugin.LoadTimeInvokes);
    // the PARSED manifest, not the harness's own constants: without this
    // a regression that dropped or mis-parsed "version" would pass every
    // gate on all four targets
    Result.Manifest := plugin.Manifest.Id + '@' + plugin.Manifest.Version +
      ' schema=' + IntStr(plugin.Manifest.Schema) +
      ' entry=' + plugin.Manifest.Entry;
    Result.Modules := ModuleList(plugin.ModuleGraph);
    Result.Edges := SortedEdges(plugin.ModuleGraph);
    Result.Hashes := ModuleHashes(plugin.ModuleGraph, AStore);
    // EVERY corpus-bound field carries a FIXED token on failure, never
    // engine text: an Eval that times out or errors would otherwise put
    // QuickJS's own message into a corpus line, so a hiccup on one
    // target would surface as an opaque quickjs_package_digest mismatch
    // instead of a named failure. The Fail() also makes the run red, so
    // divergent bytes can never be what CI notices first.
    Result.LoadInvoke := EvalToken(plugin, 'String(globalThis.__loadInvoke)');
    Result.StateRuns := EvalToken(plugin, 'String(globalThis.__stateRuns)');
    Result.Sandbox := EvalToken(plugin, 'String(globalThis.__sandbox)');
    Result.Result42 := EvalToken(plugin,
      'try { String(globalThis.pluginAdd(40, 2)) } ' +
      'catch (e) { "throw:" + e.code }');
    if gProbeScript <> '' then
    begin
      Result.Probe := EvalToken(plugin, gProbeScript);
      // read AFTER the probe: a post-load import that reached the loader
      // would show up here as a call the load itself did not make
      Result.ProbeLoaderCalls := plugin.LoaderCalls;
    end;
  finally
    InterlockedExchange(BridgeDuringLoad, 0);
    if plugin <> nil then
    begin
      plugin.Unload;
      plugin.Free;
    end;
    src := nil;
  end;
end;

{ ---- P-matrix ------------------------------------------------------------ }

var
  refFolderDigest, refZipDigest: RawUtf8;

procedure EmitOutcome(const ATag: RawUtf8; const AOut: TLoadOutcome);
begin
  Emit(ATag + ' ok=' + YesNo(AOut.Ok) +
    ' code=' + PWEB_PACKAGE_LOAD_TEXT[AOut.Code]);
  if AOut.Ok then
  begin
    Emit(ATag + ' manifest=' + AOut.Manifest);
    Emit(ATag + ' modules=' + AOut.Modules);
    Emit(ATag + ' hashes=' + AOut.Hashes);
    Emit(ATag + ' graph=' + AOut.Edges);
    Emit(ATag + ' loadinvoke=' + AOut.LoadInvoke +
      ' stateruns=' + AOut.StateRuns + ' add=' + AOut.Result42);
    Emit(ATag + ' loader=' + IntStr(AOut.LoaderCalls) +
      ' normalize=' + IntStr(AOut.NormalizeCalls) +
      ' storethread=' + YesNo(AOut.StoreThreadOk));
  end;
end;

function OutcomeDigest(const AOut: TLoadOutcome): RawUtf8;
begin
  Result := YesNo(AOut.Ok) + ';' + AOut.Manifest + ';' + AOut.Modules + ';' +
    AOut.Hashes + ';' + AOut.Edges + ';' + AOut.LoadInvoke + ';' +
    AOut.StateRuns + ';' + AOut.Result42 + ';' + AOut.Sandbox + ';' +
    IntStr(AOut.LoaderCalls) + ';' + IntStr(AOut.NormalizeCalls) + ';' +
    IntStr(AOut.LoadTimeInvokes);
end;

{ Build both carriers over the SAME bytes and hand each to ARun. }
procedure WithBothCarriers(const AFiles: TPkgFiles;
  out AFolder: IAssetStore; out AZip: IAssetStore);
var
  dir: TFileName;
begin
  dir := NextFixtureDir;
  WriteFolderPackage(dir, AFiles);
  AFolder := TFolderAssetStore.Create(dir);
  AZip := TZipAssetStore.CreateFromBuffer(BuildZipPackage(AFiles));
end;

{ One hostile fixture: load it through BOTH carriers and require the
  same refusal code from each. }
procedure HostileCase(const ATag: RawUtf8; const AFiles: TPkgFiles;
  AExpect: TPWebPackageLoadCode; const AExpectedEntry: RawUtf8;
  const ALimits: TPWebPackageLimits);
var
  fs, zs: IAssetStore;
  f, z: TLoadOutcome;
  zipOk: Boolean;
begin
  WithBothCarriers(AFiles, fs, zs);
  f := RunPackage(fs, 0, AExpectedEntry, ALimits);
  z := RunPackage(zs, 0, AExpectedEntry, ALimits);
  zipOk := (z.Ok = f.Ok) and (z.Code = f.Code);
  Emit('hostile ' + ATag + ' folder=' + PWEB_PACKAGE_LOAD_TEXT[f.Code] +
    ' zip=' + PWEB_PACKAGE_LOAD_TEXT[z.Code] + ' parity=' + YesNo(zipOk));
  Expect(not f.Ok, ATag + ' loaded (folder) but must be refused');
  Expect(f.Code = AExpect, ATag + ' folder code ' +
    PWEB_PACKAGE_LOAD_TEXT[f.Code] + ' <> ' + PWEB_PACKAGE_LOAD_TEXT[AExpect]);
  Expect(zipOk, ATag + ' folder/ZIP decision differs');
  // P33 on EVERY hostile fixture, not once: the source of a failed load
  // must already be closed by the time the loader returns
  if not f.SourceClosed then
    InterlockedIncrement(SourceOpenAfterFailure);
  if not z.SourceClosed then
    InterlockedIncrement(SourceOpenAfterFailure);
  Expect(f.SourceClosed and z.SourceClosed,
    ATag + ' left an OPEN invocation source after a failed load');
end;

procedure LegalCase(const ATag: RawUtf8; const AFiles: TPkgFiles;
  const AExpectedEntry: RawUtf8; const ALimits: TPWebPackageLimits);
var
  fs, zs: IAssetStore;
  f, z: TLoadOutcome;
begin
  WithBothCarriers(AFiles, fs, zs);
  f := RunPackage(fs, 0, AExpectedEntry, ALimits);
  z := RunPackage(zs, 0, AExpectedEntry, ALimits);
  Emit('legal ' + ATag + ' folder=' + YesNo(f.Ok) + ' zip=' + YesNo(z.Ok) +
    ' parity=' + YesNo(OutcomeDigest(f) = OutcomeDigest(z)));
  Expect(f.Ok, ATag + ' folder load failed: ' +
    PWEB_PACKAGE_LOAD_TEXT[f.Code] + ' ' + f.Detail);
  Expect(z.Ok, ATag + ' ZIP load failed: ' +
    PWEB_PACKAGE_LOAD_TEXT[z.Code] + ' ' + z.Detail);
  Expect(OutcomeDigest(f) = OutcomeDigest(z), ATag + ' folder/ZIP divergence');
end;

procedure PReference;
var
  files: TPkgFiles;
  fs, zs: IAssetStore;
  f, z: TLoadOutcome;
begin
  files := ReferencePackage;
  WithBothCarriers(files, fs, zs);
  // P1/P6/P8/P11/P12/P13/P21/P32/P37
  f := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  EmitOutcome('ref folder', f);
  Expect(f.Ok, 'P8 reference package did not load from a folder: ' +
    PWEB_PACKAGE_LOAD_TEXT[f.Code] + ' ' + f.Detail);
  Expect(f.Modules = 'main.js|lib/calculator.js|lib/state.js|shared/unit.js',
    'P11/P12/P13 unexpected module list: ' + f.Modules);
  Expect(f.Edges = 'lib/calculator.js>lib/state.js|' +
    'lib/calculator.js>shared/unit.js|main.js>lib/calculator.js|' +
    'main.js>lib/state.js', 'P12 unexpected import graph: ' + f.Edges);
  Expect(f.StateRuns = '1',
    'P21 lib/state.js executed ' + f.StateRuns + ' times, expected 1');
  Expect(f.LoaderCalls = 3,
    'P21 loader called ' + IntStr(f.LoaderCalls) + ' times, expected 3');
  Expect(f.NormalizeCalls = 4,
    'P21 normalize called ' + IntStr(f.NormalizeCalls) + ', expected 4');
  Expect(f.LoadInvoke = 'runtime_closed',
    'P32 load-time invocation was ' + f.LoadInvoke +
    ', ratified rule is runtime_closed');
  Expect(f.Result42 = '42', 'P37 pluginAdd(40,2) = ' + f.Result42);
  // P9/P10
  z := RunPackage(zs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  EmitOutcome('ref zip', z);
  Expect(z.Ok, 'P9 reference package did not load from a ZIP: ' +
    PWEB_PACKAGE_LOAD_TEXT[z.Code] + ' ' + z.Detail);
  refFolderDigest := OutcomeDigest(f);
  refZipDigest := OutcomeDigest(z);
  Emit('parity folder_zip=' + YesNo(refFolderDigest = refZipDigest));
  Expect(refFolderDigest = refZipDigest,
    'P10 folder/ZIP corpus divergence');
  // P38: the SAME package under the denied principal
  z := RunPackage(zs, 1, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  Emit('denied ok=' + YesNo(z.Ok) + ' add=' + z.Result42);
  Expect(z.Ok, 'P38 the denied plugin must still LOAD (rights are runtime)');
  Expect(z.Result42 = 'throw:forbidden',
    'P38 denied principal got ' + z.Result42 + ', expected throw:forbidden');
end;

procedure PManifest;
var
  files: TPkgFiles;
  lim: TPWebPackageLimits;

  function Mutated(const AManifest: RawByteString): TPkgFiles;
  begin
    Result := ReferencePackage;
    ReplaceFile(Result, 'plugin.json', AManifest);
  end;

begin
  // P2
  HostileCase('manifest_malformed', Mutated('{oops'), plcManifestSyntax,
    ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // P3
  HostileCase('manifest_duplicate_key', Mutated(
    '{"schema":1,"id":"quickjs.calculator","id":"quickjs.calculator",' +
    '"version":"1.0.0","entry":"main.js"}'),
    plcManifestDuplicateKey, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // P4
  HostileCase('manifest_id_mismatch', Mutated(
    '{"schema":1,"id":"quickjs.other","version":"1.0.0",' +
    '"entry":"main.js"}'), plcManifestId, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // P5 - the four security-authority shapes named in the spec
  HostileCase('manifest_capabilities', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js","capabilities":["calculator.add"]}'),
    plcManifestForbiddenField, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_allow', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js","allow":["external.open"]}'),
    plcManifestForbiddenField, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_principalid', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js","principalId":"window:main"}'),
    plcManifestForbiddenField, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_trustedcontent', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js","trustedContent":true}'),
    plcManifestForbiddenField, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_unknown_field', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js","extra":"x"}'),
    plcManifestUnknownField, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_entry_traversal', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"../main.js"}'), plcManifestEntry, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_entry_mismatch', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"other.js"}'), plcEntryMismatch, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // a package with no manifest at all (plcManifestMissing is a
  // first-class code; it is not one of the numbered P1-P40 rows)
  files := ReferencePackage;
  RemoveFile(files, 'plugin.json');
  HostileCase('manifest_missing', files, plcManifestMissing, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // P7
  files := ReferencePackage;
  RemoveFile(files, 'main.js');
  HostileCase('entry_missing', files, plcEntryMissing, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // the manifest SIZE bound, refused before a byte of it is parsed
  lim := PWEB_PACKAGE_DEFAULT_LIMITS;
  lim.ManifestMaxBytes := 64;
  HostileCase('limit_manifest_size', ReferencePackage, plcManifestTooLarge,
    ENTRY, lim);
  // the two terminal manifest validations. Without these legs the schema
  // check and the whole SemVer grammar can be deleted with the matrix
  // still green - the package would then load a "schema":2 manifest
  // under schema-1 semantics.
  HostileCase('manifest_schema_2', Mutated(
    '{"schema":2,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js"}'), plcManifestSchema, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_schema_leading_zero', Mutated(
    '{"schema":01,"id":"quickjs.calculator","version":"1.0.0",' +
    '"entry":"main.js"}'), plcManifestSyntax, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_version_two_parts', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0",' +
    '"entry":"main.js"}'), plcManifestVersion, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_version_leading_zero', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"01.0.0",' +
    '"entry":"main.js"}'), plcManifestVersion, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('manifest_version_prerelease', Mutated(
    '{"schema":1,"id":"quickjs.calculator","version":"1.0.0-rc1",' +
    '"entry":"main.js"}'), plcManifestVersion, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // a doubled BOM must NOT be stripped twice - the stray U+FEFF makes it
  // a syntax error, which is the loud, correct outcome
  files := ReferencePackage;
  ReplaceFile(files, 'plugin.json',
    Bytes([$EF, $BB, $BF, $EF, $BB, $BF]) + RawByteString(MANIFEST_OK));
  HostileCase('manifest_double_bom', files, plcManifestSyntax, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // ...while a SINGLE manifest BOM is accepted
  files := ReferencePackage;
  ReplaceFile(files, 'plugin.json',
    Bytes([$EF, $BB, $BF]) + RawByteString(MANIFEST_OK));
  LegalCase('manifest_single_bom', files, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
end;

procedure PResolution;

  function Importing(const ASpecifier: RawUtf8): TPkgFiles;
  begin
    Result := ReferencePackage;
    ReplaceFile(Result, 'main.js',
      'import "' + ASpecifier + '";'#10'globalThis.__x = 1;'#10);
  end;

var
  files: TPkgFiles;
begin
  HostileCase('spec_root_escape', Importing('../../outside.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P14
  HostileCase('spec_parent_escape', Importing('../outside.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P14
  HostileCase('spec_bare', Importing('lodash'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P15
  HostileCase('spec_absolute', Importing('/lib/state.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P16
  HostileCase('spec_url', Importing('https://evil.example/x.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P17
  HostileCase('spec_file_url', Importing('file:///etc/passwd'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P17
  HostileCase('spec_protocol_relative', Importing('//host/x.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P17
  HostileCase('spec_query', Importing('./lib/state.js?x=1'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P18
  HostileCase('spec_fragment', Importing('./lib/state.js#a'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P18
  HostileCase('spec_backslash', Importing('.\\lib\\state.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);            // P19
  HostileCase('spec_directory', Importing('./lib/'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('spec_no_extension', Importing('./lib/state'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  HostileCase('spec_encoded_traversal', Importing('./%2e%2e/x.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // P20: exact case - resolution keeps the case, the store misses
  HostileCase('spec_wrong_case', Importing('./lib/State.js'),
    plcModuleMissing, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // P23
  HostileCase('module_missing', Importing('./lib/nope.js'),
    plcModuleMissing, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // P24: a syntax error inside an imported module is a LOAD failure
  files := ReferencePackage;
  ReplaceFile(files, 'lib/state.js', 'export const q = ;;;'#10);
  HostileCase('module_syntax_error', files, plcCompile, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // the ONE failure mode where attacker code has already RUN: a module
  // that throws at top level. Without this leg CaptureEngineError, the
  // first-failure-wins fallback and the whole atomic-teardown guarantee
  // are proven only for refusals that happen before evaluation.
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    'globalThis.__ranBeforeThrow = 1;'#10 +
    'throw new Error("package says no");'#10 +
    'export const unit = 1;'#10);
  HostileCase('module_throws_at_top_level', files, plcEvaluate, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // an over-long specifier that FOLDS to a short valid path: without the
  // pre-fold bound this resolves cleanly, so the only ratified limit
  // with no leg gets one
  files := ReferencePackage;
  ReplaceFile(files, 'main.js',
    RawByteString('import ".') + Repeated('/x/..', 120) +
    RawByteString('/lib/state.js";'#10'globalThis.__x = 1;'#10));
  HostileCase('limit_specifier_length', files, plcSpecifier, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // a raw C1 control byte in module source: refused, because the one
  // shared UTF-8 validator carries the asset-path portability rule.
  // Pinned so the inherited strictness cannot change silently.
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    RawByteString('export const unit = 1; // ') + Bytes([$C2, $85]) +
    RawByteString(#10));
  HostileCase('module_c1_control', files, plcModuleEncoding, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // a dotfile is not a module
  HostileCase('spec_dotfile', Importing('./lib/.js'),
    plcSpecifier, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // legal: a cycle is valid ES and must LOAD
  files := ReferencePackage;
  ReplaceFile(files, 'main.js',
    'import { b } from "./lib/cyc_b.js";'#10 +
    'import { readB } from "./lib/cyc_a.js";'#10 +
    'globalThis.__cycle = b + readB();'#10 +
    'globalThis.pluginAdd = function (a, c) { return a + c; };'#10 +
    'globalThis.__loadInvoke = "runtime_closed";'#10 +
    'globalThis.__stateRuns = 1;'#10);
  // a legal ES cycle: neither module reads the OTHER module's binding at
  // top level (that would be a TDZ ReferenceError by specification, not
  // a loader defect), so evaluation completes in dependency order
  AddFile(files, 'lib/cyc_a.js',
    'import { b } from "./cyc_b.js";'#10 +
    'export const a = 1;'#10 +
    'export function readB() { return b; }'#10);
  AddFile(files, 'lib/cyc_b.js',
    'import { a } from "./cyc_a.js";'#10 +
    'export const b = 1 + a;'#10);
  RemoveFile(files, 'lib/calculator.js');
  RemoveFile(files, 'lib/state.js');
  RemoveFile(files, 'shared/unit.js');
  LegalCase('import_cycle', files, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  // legal: a deep but legal parent-relative chain that stays in root
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    'import { deep } from "../lib/deep/leaf.js";'#10 +
    'export const unit = deep;'#10);
  AddFile(files, 'lib/deep/leaf.js', 'export const deep = 1;'#10);
  LegalCase('deep_parent_relative', files, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
end;

procedure PEncoding;
var
  files: TPkgFiles;
begin
  // P25
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    RawByteString('export const unit = 1; // ') + Bytes([$FF, $FE]) +
    RawByteString(#10));
  HostileCase('module_invalid_utf8', files, plcModuleEncoding, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // overlong (non-shortest-form) UTF-8 must die with the same code
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    RawByteString('export const unit = 1; // ') + Bytes([$C0, $AE]) +
    RawByteString(#10));
  HostileCase('module_overlong_utf8', files, plcModuleEncoding, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // P26
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    RawByteString('export const unit = 1;') + Bytes([0]) +
    RawByteString(#10));
  HostileCase('module_embedded_nul', files, plcModuleEncoding, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // manifest encoding
  files := ReferencePackage;
  ReplaceFile(files, 'plugin.json',
    RawByteString('{"schema":1,"id":"quickjs.calculator","version":"1.0.0",') +
    RawByteString('"entry":"main.js"}') + Bytes([$FF]));
  HostileCase('manifest_invalid_utf8', files, plcManifestEncoding, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  // P27: an EMPTY module is legal, and a BOM is stripped exactly once
  files := ReferencePackage;
  AddFile(files, 'lib/empty.js', '');
  ReplaceFile(files, 'shared/unit.js',
    Bytes([$EF, $BB, $BF]) +
    RawByteString('import "./../lib/empty.js";'#13#10'export const unit = 1;'#13#10));
  LegalCase('empty_module_and_bom', files, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
end;

{ Dedicated minimal fixtures, so each bound is the ONLY one that can
  trigger: a bound proved by a fixture that also violates a second bound
  proves nothing about which one fired. }
function ChainPackage(ADepth: Integer; APadBytes: Integer): TPkgFiles;
var
  i: Integer;
  body: RawByteString;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', MANIFEST_OK);
  AddFile(Result, 'main.js', 'import "./d1.js";'#10);
  for i := 1 to ADepth do
  begin
    if i < ADepth then
      body := RawByteString('import "./d' + IntStr(i + 1) + '.js";'#10)
    else
      body := RawByteString('globalThis.__deep = 1;'#10);
    if APadBytes > 0 then
      body := body + RawByteString('// ') + Repeated('x', APadBytes) +
        RawByteString(#10);
    AddFile(Result, 'd' + IntStr(i) + '.js', body);
  end;
end;

{ A flat fan-out: the entry imports ACount siblings, so the graph is
  WIDE at depth 1. Reaching the module-count bound with a chain would
  trip the depth bound first, which proves the wrong thing. }
function FanOutPackage(ACount: Integer): TPkgFiles;
var
  i: Integer;
  entry: RawByteString;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', MANIFEST_OK);
  entry := '';
  for i := 1 to ACount do
  begin
    entry := entry + RawByteString('import "./f' + IntStr(i) + '.js";'#10);
    AddFile(Result, 'f' + IntStr(i) + '.js',
      'globalThis.__f' + IntStr(i) + ' = 1;'#10);
  end;
  AddFile(Result, 'main.js', entry + RawByteString('globalThis.__fan = 1;'#10));
end;

procedure PLimits;
var
  files: TPkgFiles;
  lim: TPWebPackageLimits;
begin
  // P28: per-module size. Two modules, one of them oversized; the total
  // stays far below the total-source bound so only the module cap fires.
  lim := PWEB_PACKAGE_DEFAULT_LIMITS;
  lim.ModuleMaxBytes := 512;
  files := ChainPackage(2, 0);
  ReplaceFile(files, 'd2.js', RawByteString('// ') + Repeated('x', 900) +
    RawByteString(#10'globalThis.__deep = 1;'#10));
  HostileCase('limit_module_size', files, plcModuleTooLarge, ENTRY, lim);
  // P29: total source. Every module is under the per-module cap; only
  // their SUM crosses the total bound.
  lim := PWEB_PACKAGE_DEFAULT_LIMITS;
  lim.ModuleMaxBytes := 600;
  lim.TotalSourceMaxBytes := 900;
  HostileCase('limit_total_source', ChainPackage(3, 400), plcTotalSource,
    ENTRY, lim);
  // P30: module count (entry + d1 + d2 + d3 = 4 distinct modules)
  lim := PWEB_PACKAGE_DEFAULT_LIMITS;
  lim.MaxModules := 3;
  HostileCase('limit_module_count', ChainPackage(3, 0), plcModuleCount,
    ENTRY, lim);
  // P31: graph depth - a small, legal chain that is simply too deep
  lim := PWEB_PACKAGE_DEFAULT_LIMITS;
  lim.MaxGraphDepth := 3;
  HostileCase('limit_graph_depth', ChainPackage(6, 0), plcDepth, ENTRY, lim);
  // and the same chain UNDER every bound must load, so the refusals
  // above are the bounds firing, not the fixture being broken
  lim := PWEB_PACKAGE_DEFAULT_LIMITS;
  files := ChainPackage(3, 0);
  ReplaceFile(files, 'd3.js',
    'globalThis.__deep = 1;'#10 +
    'globalThis.__loadInvoke = "runtime_closed";'#10 +
    'globalThis.__stateRuns = 1;'#10 +
    'globalThis.pluginAdd = function (a, b) { return a + b; };'#10);
  LegalCase('chain_within_limits', files, ENTRY, lim);
end;

procedure PIsolation;
var
  files: TPkgFiles;
  fs: IAssetStore;
  zs: IAssetStore;
  a, b: TLoadOutcome;
  i: Integer;
  ok: Boolean;
begin
  files := ReferencePackage;
  WithBothCarriers(files, fs, zs);
  // P22: two plugins over the SAME logical paths get isolated module
  // instances - each engine runs lib/state.js exactly once for itself
  a := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  b := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  Emit('isolation a_stateruns=' + a.StateRuns +
    ' b_stateruns=' + b.StateRuns);
  Expect(a.Ok and b.Ok, 'P22 both plugins must load');
  Expect((a.StateRuns = '1') and (b.StateRuns = '1'),
    'P22 module caches are not isolated (' + a.StateRuns + '/' +
    b.StateRuns + ')');
  Expect(a.LoaderCalls = b.LoaderCalls,
    'P22 loader call counts differ between engines');
  // P40: repeated load/destroy cycles stay clean
  ok := True;
  for i := 1 to 5 do
  begin
    a := RunPackage(zs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
    if not (a.Ok and (a.Result42 = '42') and (a.StateRuns = '1')) then
      ok := False;
  end;
  Emit('cycles clean=' + YesNo(ok));
  Expect(ok, 'P40 repeated load/destroy cycles were not clean');
end;

procedure PSecurity;
var
  files, sibling: TPkgFiles;
  fs, zs, scoped: IAssetStore;
  inner: IAssetStore;
  dir: TFileName;
  o: TLoadOutcome;
  asset: TAssetResponse;
begin
  // P35/P36: a package whose manifest is clean but whose CODE tries to
  // forge identity and to reach a capability it was never granted.
  // pluginAdd returns "<clean>|<opener code>|<forged-args code>" so all
  // three answers land in the corpus together.
  files := ReferencePackage;
  ReplaceFile(files, 'main.js',
    'import { add } from "./lib/calculator.js";'#10 +
    'import { tag } from "./lib/state.js";'#10 +
    'globalThis.__tag = tag;'#10 +
    'globalThis.__loadInvoke = "runtime_closed";'#10 +
    'globalThis.pluginAdd = function (a, b) {'#10 +
    '  var opener = "none";'#10 +
    '  try { pweb.invoke("pweb.openExternal", { url: "https://x" }); }'#10 +
    '  catch (e) { opener = String(e.code); }'#10 +
    '  var forged = "none";'#10 +
    '  try {'#10 +
    '    pweb.invoke("CalculatorService.Add",'#10 +
    '      { a: a, b: b, principalId: "window:main", pluginId: "other",'#10 +
    '        capabilities: ["external.open"], trustedContent: true });'#10 +
    '  } catch (e) { forged = String(e.code); }'#10 +
    '  return String(add(a, b)) + "|" + opener + "|" + forged;'#10 +
    '};'#10);
  WithBothCarriers(files, fs, zs);
  o := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  Emit('forge ok=' + YesNo(o.Ok) + ' add=' + o.Result42 +
    ' opener_reached=' + IntStr(CountOpenReached));
  Expect(o.Ok, 'P36 the forging package must still load (code is code)');
  // EXACT, not a prefix plus a not-equals: with only those two, any
  // outcome shaped '42|forbidden|<anything else>' passed, so a change in
  // where the forged call died would go unnoticed. The forged fields are
  // refused by the wire grammar before they could reach the policy at
  // all - which is the finding, and it should be pinned as such.
  Expect(o.Result42 = '42|forbidden|invalid_request',
    'P36/P35 forged identity or capability changed the outcome: ' +
    o.Result42);
  Expect(CountOpenReached = 0,
    'P35 pweb.openExternal reached the bridge ' +
    IntStr(CountOpenReached) + ' times');
  // store scoping: the package lives under a prefix in a SHARED store
  // and must not be able to name a sibling package's namespace
  dir := NextFixtureDir;
  files := ReferencePackage;
  WriteFolderPackage(IncludeTrailingPathDelimiter(dir) + 'plugins' +
    PathDelim + 'quickjs.calculator', files);
  // a SIBLING package in the same backing store, which the scoped
  // adapter must make unreachable
  sibling := nil;
  AddFile(sibling, 'plugins/other.plugin/secret.js',
    'export const secret = 1;'#10);
  WriteFolderPackage(dir, sibling);
  inner := TFolderAssetStore.Create(dir);
  scoped := TPWebScopedAssetStore.Create(inner,
    'plugins/quickjs.calculator/');
  o := RunPackage(scoped, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  Emit('scoped ok=' + YesNo(o.Ok) + ' add=' + o.Result42);
  Expect(o.Ok, 'scoped store package did not load: ' +
    PWEB_PACKAGE_LOAD_TEXT[o.Code] + ' ' + o.Detail);
  Expect(o.Result42 = '42', 'scoped store package add=' + o.Result42);
  Expect(not scoped.TryRead('../other.plugin/secret.js', asset),
    'the scoped store served a sibling package through a traversal');
  Expect(not scoped.TryRead('/plugins/other.plugin/secret.js', asset),
    'the scoped store served an absolute-looking sibling path');
  Expect(scoped.TryRead('lib/state.js', asset),
    'the scoped store cannot read its own package');
  Expect(inner.TryRead('plugins/other.plugin/secret.js', asset),
    'fixture error: the sibling package is not in the backing store');
end;

procedure PSandbox;
var
  files: TPkgFiles;
  fs, zs: IAssetStore;
  o: TLoadOutcome;
begin
  // P39: the CAP-9A sandbox is intact after a package load, and a
  // module-scope `import "std"` is refused like any other bare form
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    'export const unit = 1;'#10 +
    'globalThis.__sandbox = ['#10 +
    '  typeof fetch, typeof XMLHttpRequest, typeof WebSocket,'#10 +
    '  typeof require, typeof process, typeof std, typeof os,'#10 +
    '  typeof document, typeof window, typeof setTimeout'#10 +
    '].join(",");'#10);
  WithBothCarriers(files, fs, zs);
  o := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  Expect(o.Ok, 'P39 sandbox probe package did not load');
  Emit('sandbox load_ok=' + YesNo(o.Ok) + ' typeof=' + o.Sandbox);
  Expect(o.Sandbox = 'undefined,undefined,undefined,undefined,undefined,' +
    'undefined,undefined,undefined,undefined,undefined',
    'P39 a sandbox global is present after a package load: ' + o.Sandbox);
  // a module-scope `import "std"` is a bare specifier like any other -
  // there is no std/os module registered anywhere to reach
  files := ReferencePackage;
  ReplaceFile(files, 'main.js', 'import * as std from "std";'#10);
  HostileCase('spec_std_module', files, plcSpecifier, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
  files := ReferencePackage;
  ReplaceFile(files, 'main.js', 'import * as os from "os";'#10);
  HostileCase('spec_os_module', files, plcSpecifier, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);
end;

{ Adversarial review, items 11 and 13: dynamic import must not reach the
  scoped resolver's store, and a hostile scoping prefix must be refused at
  construction without ever echoing itself. }
procedure PAdversarial;
var
  files: TPkgFiles;
  fs, zs, scoped: IAssetStore;
  o: TLoadOutcome;
  refused: RawUtf8;
  cl, hard: TPWebPackageLimits;
begin
  files := ReferencePackage;
  ReplaceFile(files, 'main.js',
    'import { add } from "./lib/calculator.js";'#10 +
    'import { tag } from "./lib/state.js";'#10 +
    'globalThis.__tag = tag;'#10 +
    'globalThis.__loadInvoke = "runtime_closed";'#10 +
    'globalThis.pluginAdd = function (a, b) { return add(a, b); };'#10 +
    'globalThis.tryDynamic = function () {'#10 +
    '  globalThis.__dyn = "pending";'#10 +
    '  var p = import("./lib/state.js");'#10 +
    '  p.then(function () { globalThis.__dyn = "resolved"; },'#10 +
    '         function (e) { globalThis.__dyn = "rejected"; });'#10 +
    '  return typeof p;'#10 +
    '};'#10);
  WithBothCarriers(files, fs, zs);
  // the probe drives import() and then reports what actually happened
  gProbeScript := 'String(globalThis.tryDynamic()) + "|" + ' +
    'String(globalThis.__dyn) + "|" + String(globalThis.__stateRuns)';
  try
    o := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  finally
    gProbeScript := '';
  end;
  Emit('dynamic_import ok=' + YesNo(o.Ok) + ' probe=' + o.Probe +
    ' loader_before=' + IntStr(o.LoaderCalls) +
    ' loader_after=' + IntStr(o.ProbeLoaderCalls));
  Expect(o.Ok, 'dynamic-import probe package did not load');
  // nothing pumps the QuickJS job queue, so import() yields a promise that
  // NEVER settles and the loader is never called; the module therefore
  // never executes a second time either
  Expect(o.Probe = 'object|pending|1',
    'import() did not stay inert: ' + o.Probe);
  Expect(o.ProbeLoaderCalls = o.LoaderCalls,
    'import() reached the module loader (' + IntStr(o.LoaderCalls) +
    ' -> ' + IntStr(o.ProbeLoaderCalls) + ')');
  // a hostile scoping prefix is a CONSTRUCTION-time refusal, and the
  // message never echoes the prefix back
  refused := 'accepted';
  try
    // held in an interface reference: if the constructor ever stopped
    // raising, a bare object reference here would leak
    scoped := TPWebScopedAssetStore.Create(fs, '../escape/');
  except
    on E: EPWebPackage do
      if Pos('escape', RawUtf8(E.Message)) > 0 then
        refused := 'echoed'
      else
        refused := 'refused';
  end;
  scoped := nil;
  Emit('scoped_prefix_traversal=' + refused);
  Expect(refused = 'refused',
    'a traversing scope prefix was ' + refused);
  refused := 'accepted';
  try
    scoped := TPWebScopedAssetStore.Create(fs, 'plugins/../other/');
  except
    on E: EPWebPackage do
      refused := 'refused';
  end;
  scoped := nil;
  Emit('scoped_prefix_embedded_traversal=' + refused);
  Expect(refused = 'refused', 'an embedded-traversal scope prefix was accepted');
  // a prefix long enough to crowd out a module path is a CONFIGURATION
  // refusal, not a runtime miss
  refused := 'accepted';
  try
    scoped := TPWebScopedAssetStore.Create(fs,
      Repeated('abcdefgh/', 250) + 'x/');
  except
    on E: EPWebPackage do
      refused := 'refused';
  end;
  Emit('scoped_prefix_no_headroom=' + refused);
  Expect(refused = 'refused',
    'a scope prefix leaving no room for a module path was accepted');

  { The clamp is the ONLY thing standing between a host that leaves
    TPWebQuickJSPackageDescriptor.Package at its all-zero record default
    and a load with no bounds at all. Every fixture above supplies
    explicit in-range limits, so the clamp is the identity function
    throughout the matrix and its three behaviours are never observed -
    "zero means the default" could be inverted to "zero means unlimited"
    with the whole suite still green. Observe it directly. }
  cl := PWebClampPackageLimits(Default(TPWebPackageLimits));
  Emit('clamp zeros module=' + IntStr(cl.ModuleMaxBytes) +
    ' total=' + IntStr(cl.TotalSourceMaxBytes) +
    ' count=' + IntStr(cl.MaxModules) +
    ' depth=' + IntStr(cl.MaxGraphDepth) +
    ' specifier=' + IntStr(cl.MaxSpecifierBytes) +
    ' manifest=' + IntStr(cl.ManifestMaxBytes));
  Expect((cl.ModuleMaxBytes = PWEB_PACKAGE_DEFAULT_LIMITS.ModuleMaxBytes) and
    (cl.TotalSourceMaxBytes = PWEB_PACKAGE_DEFAULT_LIMITS.TotalSourceMaxBytes) and
    (cl.MaxModules = PWEB_PACKAGE_DEFAULT_LIMITS.MaxModules) and
    (cl.MaxGraphDepth = PWEB_PACKAGE_DEFAULT_LIMITS.MaxGraphDepth) and
    (cl.MaxSpecifierBytes = PWEB_PACKAGE_DEFAULT_LIMITS.MaxSpecifierBytes) and
    (cl.ManifestMaxBytes = PWEB_PACKAGE_DEFAULT_LIMITS.ManifestMaxBytes),
    'a zero-valued limits record did not clamp to the ratified defaults');
  hard := Default(TPWebPackageLimits);
  hard.ModuleMaxBytes := High(PtrUInt) div 2;
  hard.TotalSourceMaxBytes := High(PtrUInt) div 2;
  hard.ManifestMaxBytes := High(PtrUInt) div 2;
  hard.MaxModules := High(Integer);
  hard.MaxGraphDepth := High(Integer);
  hard.MaxSpecifierBytes := High(Integer);
  cl := PWebClampPackageLimits(hard);
  Emit('clamp overhard module=' + IntStr(cl.ModuleMaxBytes) +
    ' count=' + IntStr(cl.MaxModules) + ' depth=' + IntStr(cl.MaxGraphDepth));
  Expect((cl.MaxModules = PWEB_PACKAGE_HARD_LIMITS.MaxModules) and
    (cl.MaxGraphDepth = PWEB_PACKAGE_HARD_LIMITS.MaxGraphDepth) and
    (cl.MaxSpecifierBytes = PWEB_PACKAGE_HARD_LIMITS.MaxSpecifierBytes) and
    (cl.TotalSourceMaxBytes = PWEB_PACKAGE_HARD_LIMITS.TotalSourceMaxBytes) and
    (cl.ManifestMaxBytes = PWEB_PACKAGE_HARD_LIMITS.ManifestMaxBytes) and
    (cl.ModuleMaxBytes <= cl.TotalSourceMaxBytes),
    'an over-hard limits record was not clamped to the hard maxima');
  // and end to end: a package that exceeds a DEFAULT bound must be
  // refused when the descriptor carries the all-zero record
  // a WIDE graph (depth 1 throughout) so the module-COUNT default is the
  // only bound that can fire - a deep chain would trip plcDepth first and
  // prove nothing about the count
  HostileCase('limit_zero_record_uses_defaults', FanOutPackage(300),
    plcModuleCount, ENTRY, Default(TPWebPackageLimits));
end;

{ The three paths no fixture reached: a descriptor rejected before any
  thread exists (and its source teardown), a package that queues work
  nothing will ever drain, and the CPU bound firing during the load. }
procedure PDescriptorAndRuntime;
var
  files: TPkgFiles;
  fs, zs: IAssetStore;
  o: TLoadOutcome;

  { Drive PWebLoadQuickJSPackage directly with a deliberately bad
    descriptor, and prove the source it was handed is closed - the arm
    whose whole promise is "a rejected descriptor leaves nothing open",
    and which the load-failure probe in RunPackage never reaches. }
  procedure BadDescriptor(const ATag, AEntry, APrincipal: RawUtf8);
  var
    desc: TPWebQuickJSPackageDescriptor;
    src: IInvocationSource;
    srcLim: TPWebSourceLimits;
    plugin: TPWebQuickJSPlugin;
    code: TPWebPackageLoadCode;
    detail: RawUtf8;
    ctx: TInvocationContext;
    closed: Boolean;
  begin
    srcLim := Default(TPWebSourceLimits);
    srcLim.MaxConcurrent := 1;
    srcLim.MaxQueueSize := 1;
    src := gScheduler.RegisterSource(srcLim);
    desc := Default(TPWebQuickJSPackageDescriptor);
    desc.PrincipalId := APrincipal;
    desc.PluginId := 'calculator';
    desc.PackageStore := fs;
    desc.ExpectedPackageId := PKG_ID;
    desc.ExpectedEntryPoint := AEntry;
    desc.Engine := PWEB_QUICKJS_DEFAULT_LIMITS;
    desc.Package := PWEB_PACKAGE_DEFAULT_LIMITS;
    plugin := nil;
    if PWebLoadQuickJSPackage(desc, src, gSnapCb, READY_WAIT_MS,
        plugin, code, detail) then
    begin
      Fail(ATag + ' a malformed descriptor was ACCEPTED');
      if plugin <> nil then
      begin
        plugin.Unload;
        plugin.Free;
      end;
      exit;
    end;
    ctx := Default(TInvocationContext);
    ctx.PrincipalKind := pkQuickJS;
    ctx.PrincipalId := ID_CALC;
    ctx.PluginId := 'calculator';
    closed := src.TryEnqueue(ctx, M_ADD, '{"a":1,"b":1}',
      TNullCompletion.Create) = perClosed;
    Emit('descriptor ' + ATag + ' code=' + PWEB_PACKAGE_LOAD_TEXT[code] +
      ' plugin=' + YesNo(plugin <> nil) + ' source_closed=' + YesNo(closed));
    Expect(plugin = nil, ATag + ' returned a plugin on a rejected descriptor');
    Expect(code = plcDescriptor, ATag + ' code was ' +
      PWEB_PACKAGE_LOAD_TEXT[code] + ', expected descriptor');
    Expect(closed, ATag + ' left the supplied source OPEN');
    if not closed then
      InterlockedIncrement(SourceOpenAfterFailure);
    src := nil;
  end;

begin
  files := ReferencePackage;
  WithBothCarriers(files, fs, zs);
  BadDescriptor('entry_traversal', '../main.js', ID_CALC);
  BadDescriptor('empty_principal', ENTRY, '');

  // a zero CPU bound would let a runaway top-level loop block the join
  // in the atomic-failure path forever, so a package descriptor must
  // refuse it outright
  gEngineLimits := PWEB_QUICKJS_DEFAULT_LIMITS;
  gEngineLimits.TimeoutSeconds := 0;
  try
    o := RunPackage(fs, 0, ENTRY, PWEB_PACKAGE_DEFAULT_LIMITS);
  finally
    gEngineLimits := PWEB_QUICKJS_DEFAULT_LIMITS;
  end;
  Emit('descriptor zero_timeout code=' + PWEB_PACKAGE_LOAD_TEXT[o.Code]);
  Expect((not o.Ok) and (o.Code = plcDescriptor),
    'a descriptor with TimeoutSeconds=0 was accepted for a package load');

  // top-level code that queues work nothing drains must be REFUSED, not
  // silently accepted with a dead asynchronous half
  files := ReferencePackage;
  ReplaceFile(files, 'shared/unit.js',
    'Promise.resolve(1).then(function () { globalThis.__late = 1; });'#10 +
    'export const unit = 1;'#10);
  HostileCase('pending_jobs_at_load', files, plcPendingJobs, ENTRY,
    PWEB_PACKAGE_DEFAULT_LIMITS);

  // the armed CPU window really does cover the WHOLE graph evaluation,
  // and a runaway load is diagnosed as a timeout rather than as a
  // compile or evaluate error
  gEngineLimits := PWEB_QUICKJS_DEFAULT_LIMITS;
  gEngineLimits.TimeoutSeconds := 1;
  try
    files := ReferencePackage;
    ReplaceFile(files, 'shared/unit.js',
      'while (true) { }'#10'export const unit = 1;'#10);
    HostileCase('load_time_infinite_loop', files, plcTimeout, ENTRY,
      PWEB_PACKAGE_DEFAULT_LIMITS);
  finally
    gEngineLimits := PWEB_QUICKJS_DEFAULT_LIMITS;
  end;
end;

procedure PLedger;
begin
  Emit('ledger service_add=' + IntStr(NativeServiceAdd));
  Emit('ledger denied_bridge=' + IntStr(CountAddByPrincipal[1]));
  Emit('ledger opener_reached=' + IntStr(CountOpenReached));
  Emit('ledger loadtime_bridge=' + IntStr(LoadTimeBridge));
  Emit('ledger loader_wrong_thread=' + IntStr(LoaderWrongThread));
  Emit('ledger store_wrong_thread=' + IntStr(StoreWrongThread));
  Emit('ledger source_open_after_failure=' + IntStr(SourceOpenAfterFailure));
  Emit('ledger null_sink_calls=' + IntStr(NullSinkCalls));
  Emit('ledger store_never_read=' + IntStr(StoreNeverRead));
  Emit('ledger store_foreign_first_reader=' + IntStr(StoreForeignFirstReader));
  Emit('ledger loadtime_invoke_gate=' + IntStr(LoadTimeInvokeGate));
  Emit('ledger context_pluginid=' + BridgePluginId +
    ' trusted=' + BridgeTrusted);
  Expect(StoreNeverRead = 0,
    'a package loaded without ever reading its store');
  Expect(StoreForeignFirstReader = 0,
    'the first package-store reader was not the owning plugin thread');
  // the gate must have FIRED, not merely "not been reached": the
  // reference package calls pweb.invoke at top level on every load
  Expect(LoadTimeInvokeGate > 0,
    'the Loading gate never refused an invocation - P32 is unproven');
  // the two context fields CreatePackage sets natively, as the BRIDGE
  // saw them: without this nothing in the suite observes either
  Expect(BridgePluginId = 'calculator',
    'the bridge saw PluginId ' + BridgePluginId + ', expected calculator');
  Expect(BridgeTrusted = 'false',
    'the bridge saw TrustedContent ' + BridgeTrusted + ', expected false');
  Expect(SourceOpenAfterFailure = 0,
    'P33 ' + IntStr(SourceOpenAfterFailure) +
    ' failed load(s) left an open invocation source');
  Expect(NullSinkCalls = 0,
    'P33 a closed source invoked the completion sink ' +
    IntStr(NullSinkCalls) + ' times');
  Expect(CountAddByPrincipal[1] = 0,
    'P38 the denied principal reached the bridge ' +
    IntStr(CountAddByPrincipal[1]) + ' times');
  Expect(CountOpenReached = 0, 'P35 opener ledger is nonzero');
  Expect(LoadTimeBridge = 0,
    'P32 the bridge was reached ' + IntStr(LoadTimeBridge) +
    ' times while a package was Loading');
  Expect(LoaderWrongThread = 0,
    'P34 the module loader ran off the owning thread ' +
    IntStr(LoaderWrongThread) + ' times');
  Expect(StoreWrongThread = 0,
    'P34 the package store was read off the owning thread ' +
    IntStr(StoreWrongThread) + ' times');
end;

{ ---- output -------------------------------------------------------------- }

var
  corpusFile, outFile: TFileName;
  overall: RawUtf8;
  json: RawUtf8;

procedure WriteCorpusFile;
var
  s: TFileStream;
begin
  if root = '' then
    exit;
  corpusFile := root + TFileName(StringReplace(CORPUS_FILE, '/', PathDelim,
    [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(corpusFile)) then
    exit;
  s := TFileStream.Create(corpusFile, fmCreate);
  try
    if CorpusLines <> '' then
      s.WriteBuffer(CorpusLines[1], Length(CorpusLines));
  finally
    s.Free;
  end;
end;

begin
  ExitCode := 0;
  CorpusLines := '';
  FailReasons := '';
  overall := 'FAIL';
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock) not found from ' +
          string(Executable.ProgramFilePath));
      outFile := root + 'build' + PathDelim + 'cap9b1' + PathDelim +
        'quickjspackage-' + TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));
      workDir := GetTempDir + 'pweb-cap9b1-' +
        TFileName(IntToStr(GetCurrentProcessId));
      RmTree(workDir);
      if not ForceDirectories(workDir) then
        raise Exception.Create('unable to create the fixture work directory');

      gServer := TRestServerFullMemory.CreateWithOwnModel([]);
      if gServer.ServiceRegister(TCalculatorService,
           [TypeInfo(ICalculatorService)], sicShared) = nil then
        raise Exception.Create('unable to register CalculatorService');
      gRealBridge := TMormotInvocationBridge.Create(gServer, True);
      gServer := nil; // owned by the bridge now
      gBridge := TCountingBridge.Create(gRealBridge);
      gPolicy := BuildPolicy;
      gPolicyRef := gPolicy;
      gScheduler := TInvocationScheduler.Create(gPolicyRef, gBridge, 4);
      gSchedulerRef := gScheduler;
      gSnap := TSnapshotAdapter.Create;
      gSnapCb := gSnap.Snapshot; // Delphi-mode event assignment
      gEngineLimits := PWEB_QUICKJS_DEFAULT_LIMITS;

      Emit('schema=1');
      Emit('pin quickjs=2021-03-27 nanboxing=strict libc=none');
      Emit('manifest schema=' + IntStr(PWEB_PACKAGE_SCHEMA) +
        ' id=' + PKG_ID + ' entry=' + ENTRY);
      Emit('limits manifest=' + IntStr(PWEB_PACKAGE_DEFAULT_LIMITS.ManifestMaxBytes) +
        ' module=' + IntStr(PWEB_PACKAGE_DEFAULT_LIMITS.ModuleMaxBytes) +
        ' total=' + IntStr(PWEB_PACKAGE_DEFAULT_LIMITS.TotalSourceMaxBytes) +
        ' count=' + IntStr(PWEB_PACKAGE_DEFAULT_LIMITS.MaxModules) +
        ' specifier=' + IntStr(PWEB_PACKAGE_DEFAULT_LIMITS.MaxSpecifierBytes) +
        ' depth=' + IntStr(PWEB_PACKAGE_DEFAULT_LIMITS.MaxGraphDepth));

      PReference;
      PManifest;
      PResolution;
      PEncoding;
      PLimits;
      PIsolation;
      PSecurity;
      PSandbox;
      PAdversarial;
      PDescriptorAndRuntime;
      PLedger;

      gSchedulerRef.Shutdown;

      if FailReasons = '' then
      begin
        Emit('verdict=PASS');
        overall := 'PASS';
      end
      else
      begin
        Emit('verdict=FAIL');
        overall := 'FAIL';
      end;
      WriteCorpusFile;
    except
      on E: Exception do
      begin
        Fail(RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message));
        overall := 'FAIL';
        WriteLn(StdErr, LOG_PREFIX, ': FATAL ', E.ClassName, ': ', E.Message);
        // a corpus that already carries verdict=PASS must be REWRITTEN,
        // not left alone: shipping verdict=PASS beside overall=FAIL was
        // a mismatch the emitters (which only check the PASS direction)
        // would have hashed into quickjs_package_digest and passed
        CorpusLines := StringReplaceAll(CorpusLines,
          'verdict=PASS'#10, 'verdict=FAIL'#10);
        if Pos('verdict=', CorpusLines) = 0 then
          Emit('verdict=FAIL');
        WriteCorpusFile;
      end;
    end;
  finally
    try
      gSchedulerRef := nil; gScheduler := nil;
      gPolicyRef := nil; gPolicy := nil;
      gBridge := nil; gRealBridge := nil;
      FreeAndNil(gSnap);
      if workDir <> '' then
        RmTree(workDir);
    except
    end;
  end;

  json := '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "target": "' + TARGET_ID + '",' + #10 +
    '  "overall": "' + overall + '",' + #10 +
    '  "service_add_count": ' + IntStr(NativeServiceAdd) + ',' + #10 +
    '  "denied_bridge_add": ' + IntStr(CountAddByPrincipal[1]) + ',' + #10 +
    '  "opener_reached": ' + IntStr(CountOpenReached) + ',' + #10 +
    '  "loadtime_bridge": ' + IntStr(LoadTimeBridge) + ',' + #10 +
    '  "loader_wrong_thread": ' + IntStr(LoaderWrongThread) + ',' + #10 +
    '  "store_wrong_thread": ' + IntStr(StoreWrongThread) + ',' + #10 +
    '  "source_open_after_failure": ' + IntStr(SourceOpenAfterFailure) + ',' + #10 +
    '  "store_never_read": ' + IntStr(StoreNeverRead) + ',' + #10 +
    '  "store_foreign_first_reader": ' + IntStr(StoreForeignFirstReader) + ',' + #10;
  if FailReasons <> '' then
    json := json + '  "failures": "' + JsonSafeText(FailReasons) + '"' + #10
  else
    json := json + '  "failures": null' + #10;
  json := json + '}' + #10;
  if outFile <> '' then
    FileFromString(json, outFile);

  if FailReasons = '' then
    WriteLn(MARKER_PASS)
  else
  begin
    WriteLn(MARKER_FAIL, ' (', FailReasons, ')');
    ExitCode := 1;
  end;
end.
