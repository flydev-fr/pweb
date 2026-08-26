program quickjsgui;

{ CAP-9C2 hostile-package harness, in a REAL GUI process.

  WHY THIS PROGRAM EXISTS, stated plainly so nobody has to infer it: the
  shipped acceptance application (examples/07-quickjs/quickjsapp) CANNOT
  reach the case below, and that is a property of the design rather than
  a gap in it. Its compiled registry pins one exact archive digest, so a
  substituted archive fails as a WHOLE before a thread exists; and the
  private packager refuses to build a plugin whose graph will not load,
  because it resolves every graph by running the production loader. A
  byte-valid, inventory-valid archive in which ONE plugin's code fails
  is therefore only reachable from a harness that builds both the
  archive and its matching registry - which is exactly what CAP-9C1's
  c27 leg did, and this is that mechanism reused in front of a real
  WebView.

  WHAT IS SHARED WITH PRODUCTION, and it is everything that matters:

    PWebWritePluginArchive     the deterministic archive writer
    PWebRegistryFrom           the registry record assembler
    PWebVerifyQuickJSPackage   the whole-package verifier
    TPWebQuickJSPackageLoader  the package manager
    TPWebQuickJSPluginHost     the CAP-9B2 lifecycle owner
    TInvocationScheduler       the frozen scheduler
    TPWebCapabilityPolicy      the CAP-8 policy
    TMormotInvocationBridge    the bridge, over a real mORMot server
    TPWebAssetHandler/Guard    the real platform WebView adapters

  There is NO second verifier and NO second registry generator here.
  What differs from the shipped host is only the fixture package bytes,
  the matching fixture registry, and the orchestration below.

  WHAT IT PROVES:
    H1  a byte-valid, inventory-valid archive in which one plugin's CODE
        fails: archive_valid = true, running_plugins = 1,
        failed_plugins = 1, the healthy plugin answers 42, the failed
        one is never published, its source is closed and its thread is
        gone - while the real WebView UI keeps answering 42.
    H2  a plugin that tries to import an app asset path: refused at the
        package root, never published, and the app store's read counter
        does not move while it is refused.

    quickjsgui [--pweb-verdict=<file>] [--pweb-corpus=<file>]
               [--pweb-autoclose-ms=<N>] }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.navigation.policy,
  pweb.webview.intf,
  pweb.webview.binding,
  pweb.assets.intf,
  pweb.assets.folder,
  pweb.script.package,
  pweb.script.quickjs,
  pweb.script.plugin,
  pweb.script.release,
  pweb.script.startup,
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2
  {$endif LINUX}
  {$endif DARWIN}
  ;

type
  {$ifdef DARWIN}
  TPWebAssetHandler = TCocoaAssetHandler;
  TPWebNavigationGuard = TCocoaNavigationGuard;
  {$else}
  {$ifdef LINUX}
  TPWebAssetHandler = TWebKitGtkAssetHandler;
  TPWebNavigationGuard = TWebKitGtkNavigationGuard;
  {$else}
  TPWebAssetHandler = TWebView2AssetHandler;
  TPWebNavigationGuard = TWebView2NavigationGuard;
  {$endif LINUX}
  {$endif DARWIN}

const
  MARKER_PASS = 'quickjsgui: QUICKJS HOSTILE GUI PASS';
  LOG_PREFIX = 'quickjsgui';
  APP_TITLE = 'PWeb CAP-9C2 hostile package';
  ARG_VERDICT = '--pweb-verdict=';
  ARG_CORPUS = '--pweb-corpus=';
  ARG_AUTOCLOSE = '--pweb-autoclose-ms=';
  MAX_AUTOCLOSE_MS = 300000;
  CLOSER_WAIT_MARGIN_MS = 15000;

  CAP_CALCULATOR_ADD = 'calculator.add';
  PRINCIPAL_WINDOW = 'window:main';
  PRINCIPAL_HEALTHY = 'plugin:healthy';
  PRINCIPAL_BROKEN = 'plugin:broken';
  PRINCIPAL_ESCAPE = 'plugin:escape';
  PLUGIN_HEALTHY = 'fixture.healthy';
  PLUGIN_BROKEN = 'fixture.broken';
  PLUGIN_ESCAPE = 'fixture.escape';

  READY_WAIT_MS = 20000;
  EXPORT_WAIT_MS = 30000;
  JOIN_MS = 20000;
  REPORT_WAIT_MS = 60000;
  UI_ROUND_WAIT_MS = 30000;
  FIXTURE_CPU_SEC = 5;

type
  ICalculatorService = interface(IInvokable)
    ['{F2D880F7-0EE4-4EBE-8371-FBB16467BE41}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Counting IAssetStore decorator - the same shape the shipped host
    uses, so "the app store did not move while a plugin was refused" is
    a number rather than an inference. }
  TCountingAssetStore = class(TInterfacedObject, IAssetStore)
  private
    FInner: IAssetStore;
    FReads: LongInt;
  public
    constructor Create(const AInner: IAssetStore);
    function TryRead(const Path: RawUtf8; out Asset: TAssetResponse): Boolean;
    function Reads: LongInt;
  end;

  TGuiBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  TPolicyContextHandler = class(TInterfacedObject, IWebViewInvocationHandler)
  private
    FInner: IWebViewInvocationHandler;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy;
  public
    constructor Create(const AInner: IWebViewInvocationHandler;
      const APolicy: TPWebCapabilityPolicy);
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

  TPluginWiring = class
  private
    FScheduler: TInvocationScheduler;
    FPolicy: TPWebCapabilityPolicy;
    FSources: array of IInvocationSource;
    FLock: TCriticalSection;
  public
    constructor Create(AScheduler: TInvocationScheduler;
      APolicy: TPWebCapabilityPolicy);
    destructor Destroy; override;
    function MintSource: IInvocationSource;
    function Snapshot(const APrincipalId: Utf8String): TPWebCapabilities;
    function Minted: Integer;
    { How many of the sources minted from AFrom onwards the scheduler
      STILL tracks. The scheduler stops tracking a source at pssClosed,
      so this is the scheduler's own answer to "which of these are still
      open" - which is what makes "the failed plugin's source was
      closed" a measurement instead of an inference from a nil host. }
    function StillOwned(AFrom: Integer): Integer;
  end;

  { ONE fixture file, and ONE fixture plugin. RawModules non-empty is
    the c27 escape: it packages exactly these files and declares exactly
    these modules, which is the only way an archive can be byte- and
    inventory-PERFECT while one plugin's code still fails at load. The
    production packager refuses to build such a thing, by design. }
  TPkgFile = record
    Name: RawUtf8;
    Content: RawByteString;
  end;
  TPkgFiles = array of TPkgFile;

  TFixturePlugin = record
    PluginId: RawUtf8;
    PrincipalId: RawUtf8;
    Files: TPkgFiles;
    RawModules: TRawUtf8DynArray;
  end;
  TFixturePlugins = array of TFixturePlugin;

var
  CorpusRows: RawUtf8;
  CorpusLock: TCriticalSection;
  GateFailures: LongInt;
  ShutdownFailures: LongInt;
  ServiceAddCalls: LongInt;
  ServiceThreadId, GuiThreadId: LongInt;
  ReportState: LongInt;
  ReportEvent: PRTLEvent;
  UiRoundEvent: PRTLEvent;
  UiRoundJson: RawUtf8;
  UiRoundLock: TCriticalSection;
  EvalScript: RawUtf8;
  EvalLock: TCriticalSection;
  WebViewHandle: Pointer;
  AppCounter: TCountingAssetStore;
  AppStore: IAssetStore;
  Scheduler: TInvocationScheduler;
  Wiring: TPluginWiring;
  UiSource: IInvocationSource;
  FixtureRoot: TFileName;
  WorkRoot: TFileName;

{ ---------------- corpus ---------------- }

function N(AValue: Int64): RawUtf8;
begin
  Result := Int64ToUtf8(AValue);
end;

function YesNo(AValue: Boolean): RawUtf8;
begin
  if AValue then
    Result := 'yes'
  else
    Result := 'no';
end;

{ Two streams, exactly as the shipped host: the corpus carries only what
  must be identical on all four targets, the log carries the detail. }
procedure Emit(const ACorpusLine, ADetail: RawUtf8);
begin
  CorpusLock.Acquire;
  try
    CorpusRows := CorpusRows + ACorpusLine + #10;
  finally
    CorpusLock.Release;
  end;
  if ADetail = '' then
    WriteLn(LOG_PREFIX, ' row: ', ACorpusLine)
  else
    WriteLn(LOG_PREFIX, ' row: ', ACorpusLine, ' | ', ADetail);
end;

procedure Require(const AName: RawUtf8; AOk: Boolean; const ADetail: RawUtf8);
begin
  Emit(AName + '=' + YesNo(AOk), ADetail);
  if not AOk then
  begin
    InterlockedIncrement(GateFailures);
    WriteLn(StdErr, LOG_PREFIX, ': GATE FAILED ', AName, ' ', ADetail);
  end;
end;

function JsonHas(const AJson, ASub: RawUtf8): Boolean;
begin
  Result := Pos(ASub, AJson) > 0;
end;

{ ---------------- service / stores / bridge ---------------- }

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedExchange(ServiceThreadId, LongInt(GetCurrentThreadId));
  InterlockedIncrement(ServiceAddCalls);
  Result := a + b;
end;

constructor TCountingAssetStore.Create(const AInner: IAssetStore);
begin
  inherited Create;
  if AInner = nil then
    raise Exception.Create('TCountingAssetStore requires an inner store');
  FInner := AInner;
end;

function TCountingAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
begin
  InterlockedIncrement(FReads);
  Result := FInner.TryRead(Path, Asset);
end;

function TCountingAssetStore.Reads: LongInt;
begin
  Result := InterlockedCompareExchange(FReads, 0, 0);
end;

constructor TGuiBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function TGuiBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = 'example.report' then
  begin
    WriteLn(LOG_PREFIX, ' report: ', Args);
    if JsonHas(Args, '"ok":true') and JsonHas(Args, '"handshake":true') and
       JsonHas(Args, '"secure":true') and JsonHas(Args, '"rpc":true') and
       (JsonHas(Args, '"value":42}') or JsonHas(Args, '"value":42,')) then
      InterlockedCompareExchange(ReportState, 1, 0)
    else
      InterlockedCompareExchange(ReportState, 2, 0);
    RTLEventSetEvent(ReportEvent);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else if Method = 'example.concurrent' then
  begin
    UiRoundLock.Acquire;
    try
      UiRoundJson := Args;
    finally
      UiRoundLock.Release;
    end;
    RTLEventSetEvent(UiRoundEvent);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

constructor TPolicyContextHandler.Create(
  const AInner: IWebViewInvocationHandler;
  const APolicy: TPWebCapabilityPolicy);
begin
  inherited Create;
  FInner := AInner;
  FPolicy := APolicy;
  FPolicyRef := APolicy;
end;

procedure TPolicyContextHandler.HandleInvocation(
  const Context: TInvocationContext; const Request: TPWebJson;
  const Completion: IInvocationCompletion);
var
  ctx: TInvocationContext;
begin
  ctx := Context;
  ctx.Capabilities := FPolicy.SnapshotCapabilities(ctx.PrincipalId, ctx.WindowId);
  FInner.HandleInvocation(ctx, Request, Completion);
end;

constructor TPluginWiring.Create(AScheduler: TInvocationScheduler;
  APolicy: TPWebCapabilityPolicy);
begin
  inherited Create;
  FScheduler := AScheduler;
  FPolicy := APolicy;
  FLock := TCriticalSection.Create;
end;

destructor TPluginWiring.Destroy;
begin
  SetLength(FSources, 0);
  FLock.Free;
  inherited Destroy;
end;

function TPluginWiring.MintSource: IInvocationSource;
var
  limits: TPWebSourceLimits;
begin
  limits := Default(TPWebSourceLimits);
  limits.MaxConcurrent := 2;
  limits.MaxQueueSize := 16;
  Result := FScheduler.RegisterSource(limits);
  FLock.Acquire;
  try
    SetLength(FSources, Length(FSources) + 1);
    FSources[High(FSources)] := Result;
  finally
    FLock.Release;
  end;
end;

function TPluginWiring.Minted: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FSources);
  finally
    FLock.Release;
  end;
end;

function TPluginWiring.StillOwned(AFrom: Integer): Integer;
var
  i, queued, active: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for i := AFrom to High(FSources) do
      if FScheduler.TryGetSourceCounts(FSources[i], queued, active) then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TPluginWiring.Snapshot(
  const APrincipalId: Utf8String): TPWebCapabilities;
begin
  Result := FPolicy.SnapshotCapabilities(APrincipalId, '');
end;

function BuildPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALCULATOR_ADD]);
    b.SetWindowCapabilities('main', [CAP_CALCULATOR_ADD]);
    b.SetPrincipalCapabilities(PRINCIPAL_WINDOW, [CAP_CALCULATOR_ADD]);
    b.SetPrincipalCapabilities(PRINCIPAL_HEALTHY, [CAP_CALCULATOR_ADD]);
    b.SetPrincipalCapabilities(PRINCIPAL_BROKEN, [CAP_CALCULATOR_ADD]);
    b.SetPrincipalCapabilities(PRINCIPAL_ESCAPE, [CAP_CALCULATOR_ADD]);
    b.MapMethod('CalculatorService.Add', [CAP_CALCULATOR_ADD]);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(PWEB_METHOD_ECHO);
    b.RegisterZeroCapMethod('example.report');
    b.RegisterZeroCapMethod('example.concurrent');
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ ---------------- fixture archive assembly (the c27 mechanism) ------------ }

procedure AddFile(var AFiles: TPkgFiles; const AName: RawUtf8;
  const AContent: RawByteString);
begin
  SetLength(AFiles, Length(AFiles) + 1);
  AFiles[High(AFiles)].Name := AName;
  AFiles[High(AFiles)].Content := AContent;
end;

function ManifestFor(const APluginId: RawUtf8): RawByteString;
begin
  Result := '{"schema":1,"id":"' + APluginId +
    '","version":"1.0.0","entry":"main.js"}';
end;

function FixtureContent(const AFiles: TPkgFiles;
  const AName: RawUtf8): RawByteString;
var
  i: Integer;
begin
  for i := 0 to High(AFiles) do
    if AFiles[i].Name = AName then
      exit(AFiles[i].Content);
  raise Exception.Create('fixture file not found: ' + Utf8ToString(AName));
end;

function FixtureFileNames(const AFiles: TPkgFiles): TRawUtf8DynArray;
var
  i: Integer;
begin
  SetLength(Result, Length(AFiles));
  for i := 0 to High(AFiles) do
    Result[i] := AFiles[i].Name;
end;

procedure WriteFixtureTree(const ARoot: TFileName; const APluginId: RawUtf8;
  const AFiles: TPkgFiles);
var
  i: Integer;
  full: TFileName;
  rel: string;
  s: TFileStream;
begin
  for i := 0 to High(AFiles) do
  begin
    rel := StringReplace(Utf8ToString(AFiles[i].Name), '/', PathDelim,
      [rfReplaceAll]);
    full := IncludeTrailingPathDelimiter(ARoot) +
      TFileName(Utf8ToString(APluginId)) + PathDelim + TFileName(rel);
    if not ForceDirectories(ExtractFilePath(full)) then
      raise Exception.Create('unable to create ' + string(ExtractFilePath(full)));
    s := TFileStream.Create(full, fmCreate);
    try
      if AFiles[i].Content <> '' then
        s.WriteBuffer(AFiles[i].Content[1], Length(AFiles[i].Content));
    finally
      s.Free;
    end;
  end;
end;

{ Assemble ONE fixture package + its matching registry through the
  PRODUCTION components only. Nothing here parses an archive, computes
  an inventory or emits a registry by hand. }
function BuildFixturePackage(const ADir: TFileName;
  const APlugins: TFixturePlugins;
  out ARegistry: TPWebPackageRegistry;
  out APcode: TPWebPackageLoadCode; out ARcode: TPWebReleaseCode;
  out ADetail: RawUtf8): Boolean;
var
  i, j, k: Integer;
  srcDir: TFileName;
  store: IAssetStore;
  build: TPWebPluginBuildResult;
  entries, all: TPWebReleaseEntries;
  roots, hashes: TRawUtf8DynArray;
  plugins: TPWebRegistryPlugins;
  inventory: TPWebInventory;
  sha: RawUtf8;
  bytes: Int64;
  content: RawByteString;
  factory: TPWebPluginSourceFactory;
  ordered: TFixturePlugins;
  swap: TFixturePlugin;
begin
  Result := False;
  ARegistry := Default(TPWebPackageRegistry);
  APcode := plcNone;
  ARcode := prcNone;
  ADetail := '';
  factory := Wiring.MintSource; // Delphi-mode event assignment
  { The production registry gate requires plugins sorted bytewise by
    PluginId, so the fixture sorts its own rows rather than making every
    caller remember - a fixture that has to be written in the right
    order is a fixture that will one day be written in the wrong one. }
  ordered := Copy(APlugins, 0, Length(APlugins));
  for i := 1 to High(ordered) do
    for j := 0 to High(ordered) - i do
      if ordered[j].PluginId > ordered[j + 1].PluginId then
      begin
        swap := ordered[j];
        ordered[j] := ordered[j + 1];
        ordered[j + 1] := swap;
      end;
  srcDir := IncludeTrailingPathDelimiter(ADir) + 'src';
  if not ForceDirectories(srcDir) then
    raise Exception.Create('unable to create the fixture source directory');
  all := nil;
  SetLength(plugins, Length(ordered));
  SetLength(roots, Length(ordered));
  for i := 0 to High(ordered) do
  begin
    WriteFixtureTree(srcDir, ordered[i].PluginId, ordered[i].Files);
    roots[i] := PWebPluginArchiveRoot(Utf8String(ordered[i].PluginId));
    plugins[i] := Default(TPWebRegistryPlugin);
    plugins[i].PluginId := Utf8String(ordered[i].PluginId);
    plugins[i].PrincipalId := Utf8String(ordered[i].PrincipalId);
    plugins[i].Root := roots[i];
    plugins[i].EntryPoint := 'main.js';
    plugins[i].PackageId := Utf8String(ordered[i].PluginId);
    plugins[i].TimeoutSeconds := FIXTURE_CPU_SEC;
    plugins[i].MemoryLimitBytes := PWEB_QUICKJS_DEFAULT_LIMITS.MemoryLimitBytes;
    plugins[i].StackLimitBytes := PWEB_QUICKJS_DEFAULT_LIMITS.StackLimitBytes;
    plugins[i].InvokeWaitMs := PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs;
    plugins[i].Package := PWEB_PACKAGE_DEFAULT_LIMITS;
    if Length(ordered[i].RawModules) = 0 then
    begin
      // the ordinary path: the PRODUCTION loader resolves the graph
      store := TFolderAssetStore.Create(IncludeTrailingPathDelimiter(srcDir) +
        TFileName(Utf8ToString(ordered[i].PluginId)));
      try
        if not PWebResolvePluginPackage(Utf8String(ordered[i].PluginId),
             'main.js', store, factory, build, APcode, ADetail,
             READY_WAIT_MS, JOIN_MS) then
          exit;
      finally
        store := nil;
      end;
      if not PWebPluginArchiveEntries(build,
           FixtureFileNames(ordered[i].Files), entries, ARcode, ADetail) then
        exit;
      plugins[i].GraphDigest := build.GraphDigest;
      plugins[i].ModuleCount := Length(build.Modules);
      plugins[i].SourceBytes := build.SourceBytes;
    end
    else
    begin
      // the c27 raw escape: package exactly these files and declare
      // exactly these modules, so the archive is perfect and the CODE
      // is not
      entries := nil;
      SetLength(entries, Length(ordered[i].Files));
      for j := 0 to High(ordered[i].Files) do
      begin
        entries[j].Name := roots[i] + ordered[i].Files[j].Name;
        entries[j].Content := ordered[i].Files[j].Content;
      end;
      SetLength(hashes, Length(ordered[i].RawModules));
      plugins[i].SourceBytes := 0;
      for j := 0 to High(ordered[i].RawModules) do
      begin
        content := FixtureContent(ordered[i].Files, ordered[i].RawModules[j]);
        hashes[j] := PWebSha256Hex(content);
        Inc(plugins[i].SourceBytes, Length(content));
      end;
      plugins[i].GraphDigest := PWebGraphDigest(
        Utf8String(ordered[i].PluginId), 'main.js',
        ordered[i].RawModules, hashes, nil);
      plugins[i].ModuleCount := Length(ordered[i].RawModules);
    end;
    k := Length(all);
    SetLength(all, k + Length(entries));
    for j := 0 to High(entries) do
      all[k + j] := entries[j];
  end;
  if not PWebWritePluginArchive(
       IncludeTrailingPathDelimiter(ADir) +
         TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)),
       all, roots, inventory, sha, bytes, ARcode, ADetail) then
    exit;
  ARegistry := PWebRegistryFrom(PWEB_RELEASE_PACKAGE, sha, bytes,
    PWebInventoryDigest(inventory), inventory, plugins);
  Result := True;
end;

{ ---- the two fixture corpora -------------------------------------------- }

function HealthyFiles: TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', ManifestFor(PLUGIN_HEALTHY));
  AddFile(Result, 'main.js',
    'import { two } from "./lib/num.js";' + #10 +
    'pwebExports.add = function (a) {' + #10 +
    '  return pweb.invoke("CalculatorService.Add", { a: a.a, b: a.b });' + #10 +
    '};' + #10 +
    'pwebExports.two = function () { return two(); };' + #10);
  AddFile(Result, 'lib/num.js', 'export function two() { return 2; }' + #10);
end;

{ Deliberately broken CODE inside a perfectly formed package: an
  unterminated function body. The archive that carries it is byte-valid
  and inventory-valid - only the evaluation fails. }
function BrokenFiles: TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', ManifestFor(PLUGIN_BROKEN));
  AddFile(Result, 'main.js',
    'pwebExports.add = function (a) {' + #10 +
    '  return a.a + a.b;' + #10 +
    '// the closing brace is missing on purpose' + #10);
end;

{ A plugin that reaches for an APP asset. Both spellings are refused by
  the frozen CAP-9B1 resolver at the package root - there is no
  cross-store fallback to fall back to. }
function EscapeFiles: TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', ManifestFor(PLUGIN_ESCAPE));
  AddFile(Result, 'main.js',
    'import "../../index.html";' + #10 +
    'pwebExports.add = function () { return 0; };' + #10);
end;

{ ---------------- GUI helpers ---------------- }

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
  end;
end;

procedure EvalOnGuiThread(w: webview_t; arg: Pointer); cdecl;
var
  js: RawUtf8;
begin
  try
    EvalLock.Acquire;
    try
      js := EvalScript;
    finally
      EvalLock.Release;
    end;
    if js <> '' then
      webview_eval(w, PAnsiChar(js));
  except
  end;
end;

function UiRoundJs(const ATag: RawUtf8): RawUtf8;
begin
  Result :=
    '(function(){var f=window.__pweb_invoke;' +
    'if(typeof f!=="function"){return;}' +
    'f("CalculatorService.Add",{a:20,b:22}).then(function(v){' +
    'f("example.concurrent",{tag:"' + ATag + '",value:v});},function(e){' +
    'f("example.concurrent",{tag:"' + ATag +
    '",error:String(e&&e.code||e)});});})();';
end;

{ Tag-matched, clock-bounded: a promise from an earlier round can settle
  late, and a round that accepted whatever it found would grade the
  wrong answer. }
function RunUiRound(const ATag: RawUtf8; out AJson: RawUtf8;
  ATimeoutMs: Integer): Boolean;
var
  handle: Pointer;
  started: Int64;
  want: RawUtf8;
begin
  Result := False;
  AJson := '';
  handle := WebViewHandle;
  if handle = nil then
    exit;
  want := '"tag":"' + ATag + '"';
  UiRoundLock.Acquire;
  try
    UiRoundJson := '';
  finally
    UiRoundLock.Release;
  end;
  RTLEventResetEvent(UiRoundEvent);
  EvalLock.Acquire;
  try
    EvalScript := UiRoundJs(ATag);
  finally
    EvalLock.Release;
  end;
  webview_dispatch(webview_t(handle), @EvalOnGuiThread, nil);
  started := GetTickCount64;
  while Int64(GetTickCount64) - started < ATimeoutMs do
  begin
    RTLEventWaitFor(UiRoundEvent, 50);
    UiRoundLock.Acquire;
    try
      AJson := UiRoundJson;
      if (AJson <> '') and (Pos(want, AJson) = 0) then
        UiRoundJson := '';
    finally
      UiRoundLock.Release;
    end;
    if (AJson <> '') and (Pos(want, AJson) > 0) then
      exit(True);
    AJson := '';
  end;
end;

function WaitReport(ATimeoutMs: Integer): LongInt;
var
  started: Int64;
begin
  started := GetTickCount64;
  repeat
    Result := InterlockedCompareExchange(ReportState, 0, 0);
    if Result <> 0 then
      exit;
    RTLEventWaitFor(ReportEvent, 100);
  until Int64(GetTickCount64) - started >= ATimeoutMs;
  Result := InterlockedCompareExchange(ReportState, 0, 0);
end;

function CallOf(AHost: TPWebQuickJSPluginHost; const AName: RawUtf8;
  const AArgs: TPWebJson): RawUtf8;
var
  json, detail: RawUtf8;
  code: TPWebExportCallCode;
begin
  if AHost = nil then
    exit('<no host>');
  code := AHost.CallExport(AName, AArgs, json, detail);
  if code = peccOk then
    Result := json
  else
    Result := 'code=' + PWEB_EXPORT_CALL_TEXT[code] + ' ' + detail;
end;

{ ---------------- the two hostile legs ---------------- }

function RunHostileLeg(const ATag: RawUtf8; const APlugins: TFixturePlugins;
  const AFailedPluginId: RawUtf8;
  AExpectRunning, AExpectFailed: Integer): Boolean;
var
  dir: TFileName;
  registry: TPWebPackageRegistry;
  pcode: TPWebPackageLoadCode;
  rcode: TPWebReleaseCode;
  detail, uiJson: RawUtf8;
  store: IAssetStore;
  loader: TPWebQuickJSPackageLoader;
  i, running, failed: Integer;
  sr: TPWebPluginStartResult;
  appBefore, appDelta: LongInt;
  healthy: TPWebQuickJSPluginHost;
  minted: Integer;
  queued, active: Integer;
  ok: Boolean;
  srcFactory: TPWebPluginSourceFactory;
  snapCb: TPWebQuickJSSnapshotEvent;
begin
  Result := False;
  loader := nil;
  dir := IncludeTrailingPathDelimiter(WorkRoot) + TFileName(Utf8ToString(ATag));
  if not BuildFixturePackage(dir, APlugins, registry, pcode, rcode, detail) then
  begin
    Require(ATag + '_fixture_built', False,
      'package=' + PWEB_PACKAGE_LOAD_TEXT[pcode] + ' release=' +
      PWebReleaseCodeText(rcode) + ' ' + detail);
    exit;
  end;
  Require(ATag + '_fixture_built', True, '');

  { the PRODUCTION verifier over the fixture bytes: a hostile PACKAGE is
    the point, a hostile ARCHIVE is not - this leg is about what happens
    AFTER the whole-archive gate has been passed honestly }
  appBefore := AppCounter.Reads;
  minted := Wiring.Minted;
  if not PWebVerifyQuickJSPackage(dir, registry, store, rcode, detail) then
  begin
    Require(ATag + '_archive_valid', False,
      'code=' + PWebReleaseCodeText(rcode) + ' ' + detail);
    exit;
  end;
  Require(ATag + '_archive_valid', True, '');

  srcFactory := Wiring.MintSource; // Delphi-mode event assignment
  snapCb := Wiring.Snapshot;
  loader := TPWebQuickJSPackageLoader.Create(registry, store,
    srcFactory, snapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, 0);
  try
    running := loader.StartAll;
    failed := 0;
    for i := 0 to loader.Count - 1 do
    begin
      sr := loader.StartResult(i);
      if not sr.Running then
        Inc(failed);
      Emit(ATag + ' plugin id=' + sr.PluginId + ' running=' +
        YesNo(sr.Running) + ' code=' + PWEB_PLUGIN_START_TEXT[sr.Code] +
        ' package=' + PWEB_PACKAGE_LOAD_TEXT[sr.PackageCode], sr.Detail);
    end;
    Require(ATag + '_running_plugins', running = AExpectRunning,
      'running=' + N(running) + ' expected=' + N(AExpectRunning));
    Require(ATag + '_failed_plugins', failed = AExpectFailed,
      'failed=' + N(failed) + ' expected=' + N(AExpectFailed));

    { a failed plugin is never published }
    Require(ATag + '_failed_not_published',
      loader.HostOf(AFailedPluginId) = nil, 'plugin=' + AFailedPluginId);

    { and its SOURCE is closed. The scheduler stops tracking a source at
      pssClosed, so asking it how many of the sources minted for THIS
      leg it still owns answers the question directly: exactly as many
      as there are running plugins, never one per load attempt. }
    ok := Wiring.StillOwned(minted) = AExpectRunning;
    Require(ATag + '_failed_source_closed', ok,
      'minted=' + N(Wiring.Minted - minted) + ' still_owned=' +
      N(Wiring.StillOwned(minted)) + ' running=' + N(AExpectRunning));

    { the APP store did not move while a plugin package was refused:
      there is no cross-store fallback to fall back to }
    appDelta := AppCounter.Reads - appBefore;
    Require(ATag + '_app_store_untouched', appDelta = 0,
      'delta=' + N(appDelta));

    if AExpectRunning > 0 then
    begin
      healthy := loader.HostOf(PLUGIN_HEALTHY);
      Require(ATag + '_healthy_running', healthy <> nil, '');
      detail := CallOf(healthy, 'add', '{"a":20,"b":22}');
      Require(ATag + '_healthy_add', detail = '42', 'result=' + detail);
    end;

    { and the REAL WebView UI, in this same process, is untouched by all
      of it - asked freshly over the real transport }
    ok := RunUiRound(ATag, uiJson, UI_ROUND_WAIT_MS) and
      JsonHas(uiJson, '"value":42');
    Require(ATag + '_ui_ok', ok, 'result=' + uiJson);
    Result := True;
  finally
    if loader <> nil then
      try
        loader.UnloadAll;
      except
        on E: Exception do
          WriteLn(StdErr, LOG_PREFIX, ': unload ', ATag, ': ', E.Message);
      end;
    FreeAndNil(loader);
    store := nil;
  end;
end;

procedure RunGate;
var
  plugins: TFixturePlugins;
  state: LongInt;
  uiJson: RawUtf8;
  ok: Boolean;
begin
  try
    state := WaitReport(REPORT_WAIT_MS);
    Require('gui_page_report', state = 1, 'state=' + N(state));
    ok := RunUiRound('warm', uiJson, UI_ROUND_WAIT_MS) and
      JsonHas(uiJson, '"value":42');
    Require('gui_ui_add', ok, 'result=' + uiJson);

    { H1: one valid plugin, one whose CODE fails, inside a byte-valid,
      inventory-valid archive }
    SetLength(plugins, 2);
    plugins[0].PluginId := PLUGIN_HEALTHY;
    plugins[0].PrincipalId := PRINCIPAL_HEALTHY;
    plugins[0].Files := HealthyFiles;
    plugins[0].RawModules := nil;
    plugins[1].PluginId := PLUGIN_BROKEN;
    plugins[1].PrincipalId := PRINCIPAL_BROKEN;
    plugins[1].Files := BrokenFiles;
    SetLength(plugins[1].RawModules, 1);
    plugins[1].RawModules[0] := 'main.js';
    RunHostileLeg('h1', plugins, PLUGIN_BROKEN, 1, 1);

    { H2: a plugin that imports an APP asset path - refused at the
      package root, with the app store's counter proving no fallback }
    SetLength(plugins, 2);
    plugins[0].PluginId := PLUGIN_HEALTHY;
    plugins[0].PrincipalId := PRINCIPAL_HEALTHY;
    plugins[0].Files := HealthyFiles;
    plugins[0].RawModules := nil;
    plugins[1].PluginId := PLUGIN_ESCAPE;
    plugins[1].PrincipalId := PRINCIPAL_ESCAPE;
    plugins[1].Files := EscapeFiles;
    SetLength(plugins[1].RawModules, 1);
    plugins[1].RawModules[0] := 'main.js';
    RunHostileLeg('h2', plugins, PLUGIN_ESCAPE, 1, 1);
  except
    on E: Exception do
    begin
      InterlockedIncrement(GateFailures);
      WriteLn(StdErr, LOG_PREFIX, ': GATE EXCEPTION ', E.ClassName, ': ',
        E.Message);
      Emit('gate_exception=' + RawUtf8(E.ClassName), E.Message);
    end;
  end;
  if WebViewHandle <> nil then
    webview_dispatch(webview_t(WebViewHandle), @TerminateOnGuiThread, nil);
end;

function GateThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  try
    RunGate;
  except
    on E: Exception do
    begin
      InterlockedIncrement(GateFailures);
      WriteLn(StdErr, LOG_PREFIX, ': GATE THREAD ', E.ClassName, ': ',
        E.Message);
    end;
  end;
end;

{ ---------------- arguments / evidence ---------------- }

function RepoRootFromExecutable: TFileName;
var
  dir: TFileName;
  i: Integer;
begin
  dir := Executable.ProgramFilePath;
  for i := 1 to 8 do
  begin
    if FileExists(dir + 'webview.lock') then
      exit(dir);
    dir := ExpandFileName(dir + '..' + PathDelim);
  end;
  Result := '';
end;

procedure ParseArguments(out AVerdictFile, ACorpusFile: TFileName;
  out AAutoCloseMs: Integer);
var
  i: Integer;
  arg, value: string;
begin
  AVerdictFile := '';
  ACorpusFile := '';
  AAutoCloseMs := -1;
  for i := 1 to ParamCount do
  begin
    arg := ParamStr(i);
    if Copy(arg, 1, Length(ARG_VERDICT)) = ARG_VERDICT then
    begin
      value := Copy(arg, Length(ARG_VERDICT) + 1, MaxInt);
      if value = '' then
        raise Exception.Create(ARG_VERDICT + ' requires a file path');
      AVerdictFile := ExpandFileName(value);
    end
    else if Copy(arg, 1, Length(ARG_CORPUS)) = ARG_CORPUS then
    begin
      value := Copy(arg, Length(ARG_CORPUS) + 1, MaxInt);
      if value = '' then
        raise Exception.Create(ARG_CORPUS + ' requires a file path');
      ACorpusFile := ExpandFileName(value);
    end
    else if Copy(arg, 1, Length(ARG_AUTOCLOSE)) = ARG_AUTOCLOSE then
    begin
      value := Copy(arg, Length(ARG_AUTOCLOSE) + 1, MaxInt);
      AAutoCloseMs := StrToIntDef(value, -1);
      if AAutoCloseMs < 0 then
        raise Exception.Create(ARG_AUTOCLOSE +
          ' requires a non-negative integer, got: ' + value);
    end
    else
      raise Exception.Create('usage: ' + LOG_PREFIX + ' [' + ARG_VERDICT +
        '<file>] [' + ARG_CORPUS + '<file>] [' + ARG_AUTOCLOSE +
        '<ms>] -- unknown argument: ' + arg);
  end;
end;

procedure WriteTextFileAtomic(const AFile: TFileName; const AText: RawUtf8);
var
  tmp: TFileName;
  s: TFileStream;
begin
  tmp := AFile + '.' + IntToStr(GetProcessID) + '.tmp';
  s := TFileStream.Create(tmp, fmCreate);
  try
    if AText <> '' then
      s.WriteBuffer(AText[1], Length(AText));
  finally
    s.Free;
  end;
  {$ifdef OSWINDOWS}
  if FileExists(AFile) then
    DeleteFile(AFile);
  {$endif OSWINDOWS}
  if not RenameFile(tmp, AFile) then
    raise Exception.Create('unable to move the evidence file into place: ' +
      string(AFile));
end;

{ ---------------- main ---------------- }

var
  w: webview_t;
  assetHandler: TPWebAssetHandler;
  navGuard: TPWebNavigationGuard;
  server: TRestServerFullMemory;
  factory: TServiceFactoryServerAbstract;
  realBridge, bridge: IInvocationBridge;
  policy: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  schedulerRef: IInvocationScheduler;
  binding: IWebViewBinding;
  limits: TPWebSourceLimits;
  opts: TPWebWebViewBindingOptions;
  context: TInvocationContext;
  root: TFileName;
  verdictFile, corpusFile: TFileName;
  autoCloseMs, argAutoCloseMs: Integer;
  gateId, gateHandle: system.TThreadID;
  gateStarted, safeToDestroy: Boolean;
begin
  ExitCode := 0;
  server := nil;
  Scheduler := nil;
  Wiring := nil;
  assetHandler := nil;
  navGuard := nil;
  gateStarted := False;
  safeToDestroy := True;
  argAutoCloseMs := -1;
  CorpusLock := TCriticalSection.Create;
  UiRoundLock := TCriticalSection.Create;
  EvalLock := TCriticalSection.Create;
  ReportEvent := RTLEventCreate;
  UiRoundEvent := RTLEventCreate;
  InterlockedExchange(GuiThreadId, LongInt(GetCurrentThreadId));
  try
    ParseArguments(verdictFile, corpusFile, argAutoCloseMs);
    root := RepoRootFromExecutable;
    if root = '' then
      raise Exception.Create('repository root (webview.lock) not found from ' +
        string(Executable.ProgramFilePath));
    FixtureRoot := root + 'test' + PathDelim + 'cap9c2' + PathDelim + 'fixture';
    if not FileExists(FixtureRoot + PathDelim + 'index.html') then
      raise Exception.Create('fixture corpus missing: ' + string(FixtureRoot));
    WorkRoot := root + 'build' + PathDelim + 'cap9c2' + PathDelim + 'hostile';
    if not ForceDirectories(WorkRoot) then
      raise Exception.Create('unable to create ' + string(WorkRoot));

    AppCounter := TCountingAssetStore.Create(
      TFolderAssetStore.Create(FixtureRoot));
    AppStore := AppCounter;

    server := TRestServerFullMemory.CreateWithOwnModel([]);
    factory := server.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register CalculatorService');
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    bridge := TGuiBridge.Create(realBridge);
    policy := BuildPolicy;
    policyRef := policy;
    Scheduler := TInvocationScheduler.Create(policyRef, bridge, 4);
    schedulerRef := Scheduler;
    Wiring := TPluginWiring.Create(Scheduler, policy);


    limits := Default(TPWebSourceLimits);
    limits.MaxConcurrent := 4;
    limits.MaxQueueSize := 32;
    UiSource := Scheduler.RegisterSource(limits);

    {$ifdef DARWIN}
    assetHandler := TCocoaAssetHandler.Create(AppStore);
    {$endif DARWIN}
    w := WebViewCheckCreated(webview_create(0, nil));
    try
      {$ifdef DARWIN}
      assetHandler.Attach(w);
      {$endif DARWIN}
      WebViewHandle := Pointer(w);
      context := Default(TInvocationContext);
      context.WindowId := 'main';
      context.PrincipalId := PRINCIPAL_WINDOW;
      context.PrincipalKind := pkWindow;
      context.TrustedContent := True;
      opts := PWebDefaultBindingOptions(context);
      binding := TWebViewBinding.Create(w, UiSource, opts);
      binding.Bind('__pweb_invoke', TPolicyContextHandler.Create(
        TPWebEnvelopeHandler.Create(UiSource), policy));
      WebViewCheck(webview_set_title(w, PAnsiChar(AnsiString(APP_TITLE))),
        'webview_set_title');
      WebViewCheck(webview_set_size(w, 820, 620, WEBVIEW_HINT_NONE),
        'webview_set_size');
      {$ifndef DARWIN}
      {$ifdef LINUX}
      assetHandler := TWebKitGtkAssetHandler.Create(w, AppStore);
      {$else}
      assetHandler := TWebView2AssetHandler.Create(w, AppStore);
      {$endif LINUX}
      {$endif DARWIN}
      {$ifdef DARWIN}
      navGuard := TPWebNavigationGuard.Create;
      navGuard.Attach(w);
      {$else}
      navGuard := TPWebNavigationGuard.Create(w);
      {$endif DARWIN}
      WebViewCheck(webview_navigate(w, 'pweb://app/'), 'webview_navigate');

      gateHandle := BeginThread(@GateThread, nil, gateId);
      gateStarted := gateHandle <> system.TThreadID(0);
      if not gateStarted then
        raise Exception.Create('unable to start the gate thread');

      if argAutoCloseMs >= 0 then
        autoCloseMs := argAutoCloseMs
      else
        autoCloseMs := StrToIntDef(
          GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if autoCloseMs > MAX_AUTOCLOSE_MS then
        autoCloseMs := MAX_AUTOCLOSE_MS;
      WebViewCheck(webview_run(w), 'webview_run');
    finally
      if gateStarted then
      begin
        if WaitForThreadTerminate(gateHandle,
             autoCloseMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          WriteLn(StdErr, LOG_PREFIX, ': FAIL gate thread did not terminate');
          safeToDestroy := False;
          InterlockedIncrement(ShutdownFailures);
        end;
        CloseThread(gateHandle);
      end;
      WebViewHandle := nil;
      if binding <> nil then
        try
          binding.Close;
        except
          on E: Exception do
            InterlockedIncrement(ShutdownFailures);
        end;
      if schedulerRef <> nil then
        try
          schedulerRef.Shutdown;
        except
          on E: Exception do
            InterlockedIncrement(ShutdownFailures);
        end;
      if navGuard <> nil then
        try
          navGuard.Detach;
        except
          on E: Exception do
            InterlockedIncrement(ShutdownFailures);
        end;
      try
        FreeAndNil(navGuard);
      except
        on E: Exception do
          InterlockedIncrement(ShutdownFailures);
      end;
      if assetHandler <> nil then
        try
          assetHandler.Detach;
        except
          on E: Exception do
            InterlockedIncrement(ShutdownFailures);
        end;
      FreeAndNil(assetHandler);
      if safeToDestroy then
        try
          WebViewCheck(webview_destroy(w), 'webview_destroy');
        except
          on E: Exception do
            InterlockedIncrement(ShutdownFailures);
        end;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  try
    FreeAndNil(Wiring);

    binding := nil;
    UiSource := nil;
    schedulerRef := nil;
    Scheduler := nil;
    policyRef := nil;
    policy := nil;
    bridge := nil;
    realBridge := nil;
    AppStore := nil;
    AppCounter := nil;
    server.Free;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: final teardown: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  Emit('hostile_clean_shutdown=' +
    YesNo(InterlockedCompareExchange(ShutdownFailures, 0, 0) = 0), '');
  if (InterlockedCompareExchange(GateFailures, 0, 0) <> 0) or
     (InterlockedCompareExchange(ShutdownFailures, 0, 0) <> 0) then
    ExitCode := 1;

  if corpusFile <> '' then
    try
      WriteTextFileAtomic(corpusFile, CorpusRows);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL corpus write: ', E.Message);
        ExitCode := 1;
      end;
    end;
  if verdictFile <> '' then
    try
      if ExitCode = 0 then
        WriteTextFileAtomic(verdictFile, MARKER_PASS + #10)
      else
        WriteTextFileAtomic(verdictFile, LOG_PREFIX + ': FAIL (exit=' +
          N(ExitCode) + ')' + #10);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, LOG_PREFIX, ': FAIL verdict write: ', E.Message);
        ExitCode := 1;
      end;
    end;

  RTLEventDestroy(UiRoundEvent);
  RTLEventDestroy(ReportEvent);
  EvalLock.Free;
  UiRoundLock.Free;
  CorpusLock.Free;

  if ExitCode = 0 then
    WriteLn(MARKER_PASS)
  else
    WriteLn(StdErr, LOG_PREFIX, ': FAIL');
end.
