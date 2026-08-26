program quickjsrelease;

{ CAP-9C1 headless release-package matrix, C1-C30.

  It drives the REAL production path end to end:

    the archive pwebqjspack staged
        -> the GENERATED registry, compiled into this executable
        -> whole-package verification (digest first, then inventory)
        -> TZipAssetStore
        -> one confined TPWebScopedAssetStore per plugin
        -> CAP-9B1 descriptor / source validation
        -> CAP-9B2 module graph and lifecycle
        -> pweb.invoke
        -> the UNCHANGED scheduler
        -> the CAP-8A capability policy
        -> the real mORMot SOA bridge
        -> 42

  Two kinds of fixture, and the difference matters:

  - the PRODUCTION package is the one this repository ships. It is built
    by tools/quickjs/pwebqjspack.pas from examples/07-quickjs and read
    here through the registry include that same tool generated. Nothing
    about it is synthesised here;
  - every HOSTILE fixture is generated in process from byte constants
    into a temp directory, so no checkout's core.autocrlf can change
    what is hashed and no fixture file is ever read from the repository.

  The registry reaches the verifier as a PARAMETER, which is what makes
  every refusal row provable: a mutated copy exercises the exact branch
  a tampered release would hit, without regenerating an include.

  WHAT IS DELIBERATELY NOT IN THE CORPUS: the archive's SHA-256, its
  byte length and the registry include's digest. CAP-6/CAP-7L MEASURED
  that the mORMot static DEFLATE object emits different bytes for
  x86_64-win64 and x86_64-linux, so those three are per-target facts.
  They go into the JSON record, which the aggregate REPORTS but does not
  compare; the corpus carries the SEMANTIC inventory, which is
  toolchain-independent and must be identical on all four targets.

  NO conditional SKIP: the whole matrix is headless, so any failure
  gates (exit 1). }

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
  pweb.assets.bundle,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.script.package,
  pweb.script.quickjs,
  pweb.script.plugin,
  pweb.script.release,
  pweb.script.startup;

const
  LOG_PREFIX = 'quickjsrelease';
  MARKER_PASS = 'quickjsrelease: QUICKJS RELEASE PASS';
  MARKER_FAIL = 'quickjsrelease: QUICKJS RELEASE FAIL';
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

  CORPUS_FILE = 'build/cap9c1/quickjs-release-corpus.txt';
  STAGING_REL = 'build/quickjs-release';
  READY_WAIT_MS = 30000;
  EXPORT_WAIT_MS = 30000;
  JOIN_MS = 30000;
  DRAIN_MS = 25000;
  FIXTURE_CPU_SEC = 2;   // fixture engines: a short, real CPU bound

  ID_CALC: Utf8String = 'plugin:calculator';
  ID_REP: Utf8String = 'plugin:reporting';
  PID_CALC: Utf8String = 'quickjs.calculator';
  PID_REP: Utf8String = 'quickjs.reporting';

  CAP_CALC = 'calculator.add';
  CAP_OPEN = 'external.open';
  M_ADD = 'CalculatorService.Add';
  M_OPEN = 'pweb.openExternal';

  { the exact MIT permission sentence the pinned sources carry - the
    license artifact must reproduce it verbatim or the row fails }
  MIT_SENTENCE = 'Permission is hereby granted, free of charge, to any ' +
    'person obtaining a copy';

{ The generated native registry, produced by pwebqjspack from the trusted
  build-time list and compiled INTO this executable. Compiling it here is
  itself an acceptance criterion: the registry must compile on every
  target, and the runtime must never recover this data from a file. }
{$I pweb.quickjs.registry.inc}

type
  ICalculatorService = interface(IInvokable)
    ['{4B0E2C31-58D9-4A0C-9B7E-6A1F0D3C82E4}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { Counts what actually reaches the bridge. The denied principal must
    reach it ZERO times: a package that passed every integrity check is
    still authorized by CAP-8, or the whole model is decorative. }
  TCountingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { Counts every arrival at the plugin package store. The CAP-8B audit
    established that a missing public shim is not an isolation test;
    what must be zero is how many times the browser side actually
    reaches these bytes. }
  TCountingAssetStore = class(TInterfacedObject, IAssetStore)
  private
    FInner: IAssetStore;
    FHits: LongInt;
  public
    constructor Create(const AInner: IAssetStore);
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
    function Hits: LongInt;
  end;

  TSnapshotAdapter = class
  public
    function Snapshot(const APrincipalId: Utf8String): TPWebCapabilities;
  end;

  TSourceFactory = class
  public
    function Make: IInvocationSource;
  end;

  TPkgFile = record
    Name: RawUtf8;
    Content: RawByteString;
  end;
  TPkgFiles = array of TPkgFile;

  { One fixture plugin. RawModules non-empty skips graph resolution and
    packages the files as given - the only way to build an archive that
    is byte- and inventory-perfect while one plugin's CODE still fails
    at load time, which is what the ratified startup semantics need. }
  TFixturePlugin = record
    PluginId: RawUtf8;
    PrincipalId: RawUtf8;
    Files: TPkgFiles;
    RawModules: TRawUtf8DynArray;
  end;
  TFixturePlugins = array of TFixturePlugin;

  { C29: verifies, starts, calls and unloads a whole package on its own
    thread, so two of them can be proven to agree concurrently. }
  TLoaderThread = class(TThread)
  private
    FDir: TFileName;
    FStart: PRTLEvent;
    FDoneEv: PRTLEvent;
    FToken: RawUtf8;
  public
    constructor Create(const ADir: TFileName);
    destructor Destroy; override;
    procedure Execute; override;
    procedure Go;
    function WaitToken: RawUtf8;
  end;

var
  CorpusLines: RawUtf8;
  FailReasons: RawUtf8;
  // ledgers the aggregator cross-checks
  BrowserStoreArrivals: LongInt;   // MUST stay 0
  DeniedBridgeAdd: LongInt;        // MUST stay 0
  OpenerReached: LongInt;          // MUST stay 0
  TamperStarted: LongInt;          // MUST stay 0
  CwdDependency: LongInt;          // MUST stay 0
  NativeServiceAdd: LongInt;
  // per-target facts: reported, never four-way compared
  PackageSha: RawUtf8;
  PackageBytes: Int64;
  RegistrySha: RawUtf8;
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
  gFactory: TSourceFactory;
  gMakeSource: TPWebPluginSourceFactory;
  root: TFileName;
  workDir: TFileName;
  stagingDir: TFileName;
  fixtureSeq: Integer;
  Registry: TPWebPackageRegistry;

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
  Result := RawUtf8(IntToStr(AValue));
end;

function Rep(AChar: AnsiChar; ACount: Integer): RawUtf8;
var
  i: PtrInt;
begin
  SetLength(Result, ACount);
  for i := 1 to ACount do
    Result[i] := AChar;
end;

{ A registry copy that can be mutated without touching the compiled one.
  Assigning the record copies dynamic-array REFERENCES, so both halves
  are explicitly unshared: SetLength on an array whose refcount is above
  one makes a private copy, contents preserved. }
function MutatedRegistry: TPWebPackageRegistry;
begin
  Result := Registry;
  SetLength(Result.Inventory, Length(Result.Inventory));
  SetLength(Result.Plugins, Length(Result.Plugins));
end;

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := '';
  for i := 1 to Length(AValue) do
    if AValue[i] in ['"', '\', #0..#31] then
      Result := Result + '?'
    else
      Result := Result + AValue[i];
end;

procedure RmTree(const Dir: TFileName);
var
  sr: TSearchRec;
begin
  if not DirectoryExists(Dir) then
    exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*',
       faAnyFile{%H-}, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') then
        continue;
      if (sr.Attr and faDirectory{%H-}) <> 0 then
        RmTree(IncludeTrailingPathDelimiter(Dir) + sr.Name)
      else
        SysUtils.DeleteFile(IncludeTrailingPathDelimiter(Dir) + sr.Name);
    until FindNext(sr) <> 0;
  finally
    SysUtils.FindClose(sr);
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

function NewWorkDir(const AName: RawUtf8): TFileName;
begin
  Inc(fixtureSeq);
  Result := IncludeTrailingPathDelimiter(workDir) +
    TFileName(Utf8ToString(AName + '-' + IntStr(fixtureSeq)));
  RmTree(Result);
  if not ForceDirectories(Result) then
    raise Exception.Create('unable to create a fixture directory');
  Result := IncludeTrailingPathDelimiter(Result);
end;

function NativeOf(const ALogical: RawUtf8): TFileName;
begin
  Result := TFileName(StringReplace(Utf8ToString(ALogical), '/', PathDelim,
    [rfReplaceAll]));
end;

{ ---- service, bridge, policy (CAP-9A/B1/B2 shapes, unchanged) ------------ }

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
  if Method = M_OPEN then
  begin
    // neither principal holds external.open, so the CAP-8A policy must
    // refuse before routing: arriving here at all IS the finding
    InterlockedIncrement(OpenerReached);
    exit(PWebDefaultErrorResult(pecMethodNotFound));
  end;
  if (Method = M_ADD) and
     (Context.PrincipalId = ID_REP) then
    InterlockedIncrement(DeniedBridgeAdd);
  Result := FInner.Invoke(Context, Method, Args, Token);
end;

constructor TCountingAssetStore.Create(const AInner: IAssetStore);
begin
  inherited Create;
  FInner := AInner;
end;

function TCountingAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
begin
  InterlockedIncrement(FHits);
  Result := FInner.TryRead(Path, Asset);
end;

function TCountingAssetStore.Hits: LongInt;
begin
  Result := InterlockedCompareExchange(FHits, 0, 0);
end;

function TSnapshotAdapter.Snapshot(
  const APrincipalId: Utf8String): TPWebCapabilities;
begin
  Result := gPolicy.SnapshotCapabilities(APrincipalId);
end;

function TSourceFactory.Make: IInvocationSource;
var
  lim: TPWebSourceLimits;
begin
  lim := Default(TPWebSourceLimits);
  lim.MaxConcurrent := 4;
  lim.MaxQueueSize := 16;
  Result := gScheduler.RegisterSource(lim);
end;

function BuildPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALC, CAP_OPEN]);
    b.SetPrincipalCapabilities(ID_CALC, [CAP_CALC]);
    b.SetPrincipalCapabilities(ID_REP, []);   // explicit empty = no rights
    // the fixture principals hold the calculator right, so a fixture row
    // failing tells us about PACKAGING, never about policy
    b.SetPrincipalCapabilities('plugin:alpha', [CAP_CALC]);
    b.SetPrincipalCapabilities('plugin:beta', [CAP_CALC]);
    b.SetPrincipalCapabilities('plugin:broken', [CAP_CALC]);
    b.SetPrincipalCapabilities('plugin:spin', [CAP_CALC]);
    b.MapMethod(M_ADD, [CAP_CALC]);
    b.MapMethod(M_OPEN, [CAP_OPEN]);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

{ ---- fixture helpers ----------------------------------------------------- }

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

function ManifestFor(const AId: RawUtf8): RawByteString;
begin
  Result := '{"schema":1,"id":"' + AId +
    '","version":"1.0.0","entry":"main.js"}';
end;

procedure WriteFixtureTree(const ARootDir: TFileName;
  const APluginId: RawUtf8; const AFiles: TPkgFiles);
var
  i: PtrInt;
  full: TFileName;
begin
  for i := 0 to High(AFiles) do
  begin
    full := IncludeTrailingPathDelimiter(ARootDir) +
      NativeOf(APluginId) + PathDelim + NativeOf(AFiles[i].Name);
    if not ForceDirectories(ExtractFilePath(full)) then
      raise Exception.Create('unable to create a fixture subdirectory');
    if not FileFromString(AFiles[i].Content, full) then
      raise Exception.Create('unable to write a fixture file');
  end;
end;

function FixtureFileNames(const AFiles: TPkgFiles): TRawUtf8DynArray;
var
  i: PtrInt;
begin
  SetLength(Result, Length(AFiles));
  for i := 0 to High(AFiles) do
    Result[i] := AFiles[i].Name;
end;

function FixtureContent(const AFiles: TPkgFiles;
  const AName: RawUtf8): RawByteString;
var
  i: PtrInt;
begin
  for i := 0 to High(AFiles) do
    if AFiles[i].Name = AName then
      exit(AFiles[i].Content);
  Result := '';
end;

{ Stage one complete fixture package: write the trees, resolve or accept
  each graph, write the archive and build the matching registry. The
  same two library calls pwebqjspack makes, plus the raw-module escape
  the startup-semantics rows need. }
function StageFixture(const ADir: TFileName;
  const APlugins: TFixturePlugins;
  out ARegistry: TPWebPackageRegistry;
  out APcode: TPWebPackageLoadCode; out ARcode: TPWebReleaseCode;
  out ADetail: RawUtf8): Boolean;
var
  i, j, k: PtrInt;
  srcDir: TFileName;
  store: IAssetStore;
  build: TPWebPluginBuildResult;
  entries, all: TPWebReleaseEntries;
  roots: TRawUtf8DynArray;
  inventory: TPWebInventory;
  plugins: TPWebRegistryPlugins;
  hashes: TRawUtf8DynArray;
  sha: RawUtf8;
  bytes: Int64;
  content: RawByteString;
begin
  Result := False;
  ARegistry := Default(TPWebPackageRegistry);
  APcode := plcNone;
  ARcode := prcNone;
  ADetail := '';
  srcDir := IncludeTrailingPathDelimiter(ADir) + 'src';
  if not ForceDirectories(srcDir) then
    raise Exception.Create('unable to create the fixture source directory');
  all := nil;
  SetLength(plugins, Length(APlugins));
  SetLength(roots, Length(APlugins));
  for i := 0 to High(APlugins) do
  begin
    WriteFixtureTree(srcDir, APlugins[i].PluginId, APlugins[i].Files);
    roots[i] := PWebPluginArchiveRoot(Utf8String(APlugins[i].PluginId));
    plugins[i] := Default(TPWebRegistryPlugin);
    plugins[i].PluginId := Utf8String(APlugins[i].PluginId);
    plugins[i].PrincipalId := Utf8String(APlugins[i].PrincipalId);
    plugins[i].Root := roots[i];
    plugins[i].EntryPoint := 'main.js';
    plugins[i].PackageId := Utf8String(APlugins[i].PluginId);
    plugins[i].TimeoutSeconds := FIXTURE_CPU_SEC;
    plugins[i].MemoryLimitBytes := PWEB_QUICKJS_DEFAULT_LIMITS.MemoryLimitBytes;
    plugins[i].StackLimitBytes := PWEB_QUICKJS_DEFAULT_LIMITS.StackLimitBytes;
    plugins[i].InvokeWaitMs := PWEB_QUICKJS_DEFAULT_LIMITS.InvokeWaitMs;
    plugins[i].Package := PWEB_PACKAGE_DEFAULT_LIMITS;
    if Length(APlugins[i].RawModules) = 0 then
    begin
      // the ordinary path: the PRODUCTION loader resolves the graph
      store := TFolderAssetStore.Create(IncludeTrailingPathDelimiter(srcDir) +
        NativeOf(APlugins[i].PluginId));
      try
        if not PWebResolvePluginPackage(Utf8String(APlugins[i].PluginId),
             'main.js', store, gMakeSource, build, APcode, ADetail,
             READY_WAIT_MS, JOIN_MS) then
          exit;
      finally
        store := nil;
      end;
      if not PWebPluginArchiveEntries(build, FixtureFileNames(APlugins[i].Files),
           entries, ARcode, ADetail) then
        exit;
      plugins[i].GraphDigest := build.GraphDigest;
      plugins[i].ModuleCount := Length(build.Modules);
      plugins[i].SourceBytes := build.SourceBytes;
    end
    else
    begin
      // the raw escape: package exactly these files and declare exactly
      // these modules, so the archive can be perfect while the CODE is not
      entries := nil;
      SetLength(entries, Length(APlugins[i].Files));
      for j := 0 to High(APlugins[i].Files) do
      begin
        entries[j].Name := roots[i] + APlugins[i].Files[j].Name;
        entries[j].Content := APlugins[i].Files[j].Content;
      end;
      SetLength(hashes, Length(APlugins[i].RawModules));
      plugins[i].SourceBytes := 0;
      for j := 0 to High(APlugins[i].RawModules) do
      begin
        content := FixtureContent(APlugins[i].Files, APlugins[i].RawModules[j]);
        hashes[j] := PWebSha256Hex(content);
        Inc(plugins[i].SourceBytes, Length(content));
      end;
      plugins[i].GraphDigest := PWebGraphDigest(
        Utf8String(APlugins[i].PluginId), 'main.js',
        APlugins[i].RawModules, hashes, nil);
      plugins[i].ModuleCount := Length(APlugins[i].RawModules);
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

{ ---- the standard fixture corpus ---------------------------------------- }

function AlphaFiles: TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', ManifestFor('fixture.alpha'));
  AddFile(Result, 'main.js',
    'import { two } from "./lib/num.js";' + #10 +
    'pwebExports.add = function (a) {' + #10 +
    '  return pweb.invoke("CalculatorService.Add", { a: a.a, b: a.b });' + #10 +
    '};' + #10 +
    'pwebExports.two = function () { return two(); };' + #10);
  AddFile(Result, 'lib/num.js',
    'export function two() { return 2; }' + #10);
end;

function BetaFiles: TPkgFiles;
begin
  Result := nil;
  AddFile(Result, 'plugin.json', ManifestFor('fixture.beta'));
  AddFile(Result, 'main.js',
    'pwebExports.ping = function () { return "beta"; };' + #10);
end;

function OnePlugin(const AId, APrincipal: RawUtf8;
  const AFiles: TPkgFiles): TFixturePlugins;
begin
  SetLength(Result, 1);
  Result[0].PluginId := AId;
  Result[0].PrincipalId := APrincipal;
  Result[0].Files := AFiles;
  Result[0].RawModules := nil;
end;

{ ---- C1-C4: the deterministic builder ------------------------------------ }

procedure CBuilder;
var
  d1, d2: TFileName;
  r1, r2: TPWebPackageRegistry;
  pcode: TPWebPackageLoadCode;
  rcode: TPWebReleaseCode;
  detail, inc1, inc2: RawUtf8;
  b1, b2: RawByteString;
  i: PtrInt;
  ok: Boolean;
begin
  d1 := NewWorkDir('build-a');
  d2 := NewWorkDir('build-b');
  ok := StageFixture(d1, OnePlugin('fixture.alpha', 'plugin:alpha',
    AlphaFiles), r1, pcode, rcode, detail);
  Emit('c1 create=' + YesNo(ok) + ' entries=' +
    IntStr(Length(r1.Inventory)) + ' plugins=' + IntStr(Length(r1.Plugins)));
  Expect(ok, 'C1 deterministic package creation failed: ' + detail);
  if not ok then
    exit;
  for i := 0 to High(r1.Inventory) do
    Emit('c1 entry=' + r1.Inventory[i].Name + ' bytes=' +
      IntStr(r1.Inventory[i].Bytes) + ' sha=' + r1.Inventory[i].Sha256);
  Emit('c1 inventory_digest=' + r1.InventoryDigest);
  Emit('c1 graph=' + r1.Plugins[0].GraphDigest +
    ' modules=' + IntStr(r1.Plugins[0].ModuleCount) +
    ' source_bytes=' + IntStr(r1.Plugins[0].SourceBytes));

  // C2: the SAME logical input, a second directory, a later wall clock
  ok := StageFixture(d2, OnePlugin('fixture.alpha', 'plugin:alpha',
    AlphaFiles), r2, pcode, rcode, detail);
  Expect(ok, 'C2 rebuild failed: ' + detail);
  if not ok then
    exit;
  b1 := StringFromFile(d1 + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));
  b2 := StringFromFile(d2 + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));
  Emit('c2 rebuild_byte_identical=' + YesNo((b1 <> '') and (b1 = b2)));
  Expect((b1 <> '') and (b1 = b2), 'C2 rebuild is not byte-identical');

  // C3: the semantic inventory is the toolchain-independent identity
  Emit('c3 inventory_identical=' +
    YesNo(PWebInventoryText(r1.Inventory) = PWebInventoryText(r2.Inventory)) +
    ' digest_identical=' + YesNo(r1.InventoryDigest = r2.InventoryDigest));
  Expect(PWebInventoryText(r1.Inventory) = PWebInventoryText(r2.Inventory),
    'C3 inventory drifted between rebuilds');

  // C4: the generated registry regenerates byte-identically
  Expect(PWebEmitRegistryInclude(r1, 'pwebqjspack', inc1, rcode, detail),
    'C4 first registry emission refused: ' + detail);
  Expect(PWebEmitRegistryInclude(r1, 'pwebqjspack', inc2, rcode, detail),
    'C4 second registry emission refused: ' + detail);
  Emit('c4 registry_byte_identical=' + YesNo((inc1 <> '') and (inc1 = inc2)));
  Expect((inc1 <> '') and (inc1 = inc2), 'C4 registry emission is not stable');
  Emit('c4 registry_has_no_capability=' +
    YesNo(PosEx('Capabilities:', inc1, 1) = 0));
  Expect(PosEx('Capabilities:', inc1, 1) = 0,
    'C4 the generated registry carries capabilities');
end;

{ ---- C13, C14: module-graph package rules -------------------------------- }

procedure CGraphRules;
var
  d: TFileName;
  reg: TPWebPackageRegistry;
  pcode: TPWebPackageLoadCode;
  rcode: TPWebReleaseCode;
  detail: RawUtf8;
  files: TPkgFiles;
  plugins: TFixturePlugins;
  build: TPWebPluginBuildResult;
  entries: TPWebReleaseEntries;
  short: TRawUtf8DynArray;
  ok: Boolean;
begin
  // C13: an import that leaves the plugin root. The FROZEN CAP-9B1
  // resolver refuses it, at build time, through the same code that
  // refuses it at run time - there is no second scanner to disagree.
  files := nil;
  AddFile(files, 'plugin.json', ManifestFor('fixture.alpha'));
  AddFile(files, 'main.js',
    'import { x } from "../fixture.beta/main.js";' + #10 +
    'pwebExports.a = function () { return x; };' + #10);
  d := NewWorkDir('cross-import');
  ok := StageFixture(d, OnePlugin('fixture.alpha', 'plugin:alpha', files),
    reg, pcode, rcode, detail);
  Emit('c13 cross_plugin_import=' + YesNo(not ok) +
    ' code=' + PWEB_PACKAGE_LOAD_TEXT[pcode]);
  Expect((not ok) and (pcode = plcSpecifier),
    'C13 a cross-plugin import was packaged');

  // C14: a source file the graph never reaches. Ratified: REJECT, and
  // name the exact path - never a silent inclusion or exclusion.
  files := AlphaFiles;
  AddFile(files, 'lib/orphan.js', 'export const dead = 1;' + #10);
  d := NewWorkDir('orphan');
  ok := StageFixture(d, OnePlugin('fixture.alpha', 'plugin:alpha', files),
    reg, pcode, rcode, detail);
  Emit('c14 unreferenced_source=' + YesNo(not ok) +
    ' code=' + PWEB_RELEASE_CODE_TEXT[rcode] + ' detail=' + detail);
  Expect((not ok) and (rcode = prcSourceUnreferenced),
    'C14 an unreferenced source file was packaged');

  // a module the graph names but the walk never saw
  SetLength(plugins, 1);
  plugins[0].PluginId := 'fixture.alpha';
  plugins[0].PrincipalId := 'plugin:alpha';
  plugins[0].Files := BetaFiles;
  plugins[0].RawModules := nil;
  d := NewWorkDir('graph-ok');
  ok := StageFixture(d, plugins, reg, pcode, rcode, detail);
  Emit('c14 manifest_id_mismatch=' + YesNo(not ok) +
    ' code=' + PWEB_PACKAGE_LOAD_TEXT[pcode]);
  Expect((not ok) and (pcode = plcManifestId),
    'C14 a manifest id that is not the plugin id was packaged');

  // the mirror of C14: a graph node the caller's walk never produced.
  // Unreachable through the tool (both come from the same tree) but it is
  // the branch that would fire if a future walk ever filtered, so it gets
  // its own leg rather than sitting untested behind an assumption.
  d := NewWorkDir('graph-missing');
  files := AlphaFiles;
  if StageFixture(d, OnePlugin('fixture.alpha', 'plugin:alpha', files),
       reg, pcode, rcode, detail) then
  begin
    build := Default(TPWebPluginBuildResult);
    build.PluginId := 'fixture.alpha';
    build.EntryPoint := 'main.js';
    build.ManifestBytes := ManifestFor('fixture.alpha');
    SetLength(build.Modules, 1);
    build.Modules[0] := 'main.js';
    SetLength(build.Contents, 1);
    build.Contents[0] := 'x';
    SetLength(short, 1);
    short[0] := PWEB_PACKAGE_MANIFEST;   // the walk saw only the manifest
    ok := PWebPluginArchiveEntries(build, short, entries, rcode, detail);
    Emit('c14 graph_node_not_walked=' + YesNo(not ok) + ' code=' +
      PWEB_RELEASE_CODE_TEXT[rcode]);
    Expect((not ok) and (rcode = prcSourceMissing),
      'C14 a graph node absent from the source set was packaged');
  end;
end;

{ ---- C15, C16: hostile paths and Unicode collisions ---------------------- }

procedure CPaths;
var
  entries: TPWebReleaseEntries;
  roots: TRawUtf8DynArray;
  inv: TPWebInventory;
  sha, detail: RawUtf8;
  bytes: Int64;
  rcode: TPWebReleaseCode;
  d: TFileName;
  i: PtrInt;
  ok: Boolean;

  function TryNames(const AName1, AName2: RawUtf8): Boolean;
  begin
    SetLength(entries, 2);
    entries[0].Name := AName1;
    entries[0].Content := 'a';
    entries[1].Name := AName2;
    entries[1].Content := 'b';
    Result := PWebWritePluginArchive(
      d + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)), entries, roots,
      inv, sha, bytes, rcode, detail);
  end;

  procedure Hostile(const AWhat, AName: RawUtf8;
    AExpected: TPWebReleaseCode);
  begin
    SetLength(entries, 1);
    entries[0].Name := AName;
    entries[0].Content := 'x';
    ok := PWebWritePluginArchive(
      d + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)), entries, roots,
      inv, sha, bytes, rcode, detail);
    Emit('c15 ' + AWhat + '=' + YesNo(not ok) + ' code=' +
      PWEB_RELEASE_CODE_TEXT[rcode]);
    Expect((not ok) and (rcode = AExpected),
      'C15 ' + AWhat + ' was accepted or gave ' +
      PWEB_RELEASE_CODE_TEXT[rcode]);
  end;

begin
  d := NewWorkDir('paths');
  roots := nil;
  SetLength(roots, 1);
  roots[0] := 'fixture.alpha/';
  // C15 - the frozen CAP-4/CAP-6 validator, reused verbatim. No
  // QuickJS-specific weaker parser exists to disagree with it.
  Hostile('traversal', 'fixture.alpha/../secret.js', prcEntryName);
  Hostile('backslash', 'fixture.alpha\lib.js', prcEntryName);
  Hostile('absolute', '/fixture.alpha/main.js', prcEntryName);
  Hostile('drive', 'C:/fixture.alpha/main.js', prcEntryName);
  Hostile('unc', '//host/fixture.alpha/main.js', prcEntryName);
  Hostile('ads', 'fixture.alpha/main.js:stream', prcEntryName);
  Hostile('nul', 'fixture.alpha/ma' + #0 + 'in.js', prcEntryName);
  Hostile('control', 'fixture.alpha/ma' + #1 + 'in.js', prcEntryName);
  Hostile('empty_segment', 'fixture.alpha//main.js', prcEntryName);
  Hostile('trailing_dot', 'fixture.alpha/main.js.', prcEntryName);
  Hostile('trailing_space', 'fixture.alpha/main.js ', prcEntryName);
  Hostile('percent', 'fixture.alpha/ma%2Fin.js', prcEntryName);
  Hostile('device', 'fixture.alpha/NUL.js', prcEntryName);
  Hostile('directory_form', 'fixture.alpha/lib/', prcEntryName);
  Hostile('unregistered_root', 'other.plugin/main.js', prcEntryOutsideRoot);
  Hostile('bare_root', 'fixture.alpha', prcEntryOutsideRoot);

  // C16 - the ratified CAP-6 D1 fold, the exact-duplicate rule and the
  // file/directory ambiguity rule, all over the pinned Unicode tables
  ok := TryNames('fixture.alpha/App.js', 'fixture.alpha/app.js');
  Emit('c16 ascii_case=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  Expect((not ok) and (rcode = prcEntryCollision),
    'C16 ASCII case collision accepted');
  ok := TryNames('fixture.alpha/caf' + #$C3#$A9 + '.js',
                 'fixture.alpha/CAF' + #$C3#$89 + '.js');
  Emit('c16 unicode_fold=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  Expect((not ok) and (rcode = prcEntryCollision),
    'C16 Unicode fold collision accepted');
  ok := TryNames('fixture.alpha/main.js', 'fixture.alpha/main.js');
  Emit('c16 exact_duplicate=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  Expect((not ok) and (rcode = prcEntryDuplicate),
    'C16 exact duplicate accepted');
  ok := TryNames('fixture.alpha/lib', 'fixture.alpha/lib/x.js');
  Emit('c16 file_dir=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  Expect((not ok) and (rcode = prcEntryCollision),
    'C16 file/directory collision accepted');
  // and a non-ASCII pair that does NOT fold equal must still be accepted:
  // the rule rejects ambiguity, it does not ban Unicode
  ok := TryNames('fixture.alpha/caf' + #$C3#$A9 + '.js',
                 'fixture.alpha/cafe.js');
  Emit('c16 distinct_unicode_accepted=' + YesNo(ok));
  Expect(ok, 'C16 distinct non-ASCII names were refused: ' + detail);
  i := Length(inv);
  Emit('c16 accepted_entries=' + IntStr(i));
end;

{ ---- registry emitter safety --------------------------------------------- }

procedure CRegistrySafety;
var
  reg: TPWebPackageRegistry;
  rcode: TPWebReleaseCode;
  detail, text: RawUtf8;
  d: TFileName;
  pcode: TPWebPackageLoadCode;
  ok: Boolean;
begin
  d := NewWorkDir('emit');
  if not StageFixture(d, OnePlugin('fixture.alpha', 'plugin:alpha',
       AlphaFiles), reg, pcode, rcode, detail) then
  begin
    Fail('registry-safety fixture could not be staged: ' + detail);
    exit;
  end;
  // a quote, a newline and a non-ASCII byte in a field that reaches the
  // emitter must REFUSE, never escape: no arbitrary text becomes Pascal
  // TWO gates stand between a field and the generated Pascal, and the
  // FIRST one is what actually fires: PWebEmitRegistryInclude re-runs the
  // whole registry gate before it emits a byte, and every registry string
  // is already a constrained grammar (ids, canonical paths, 64-hex
  // digests). The printable-ASCII literal writer behind it is therefore
  // unreachable through this API by construction - defence in depth of
  // the same kind CAP-9B1 recorded for plcThread/plcEngine, and the rows
  // below say which gate refused rather than pretending otherwise.
  reg.Plugins[0].GraphDigest := '''+ Halt(1) +''';
  ok := PWebEmitRegistryInclude(reg, 'pwebqjspack', text, rcode, detail);
  Emit('c4 emit_quote_injection=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  Expect((not ok) and (rcode = prcRegistry) and (text = ''),
    'C4 a quoted injection reached the generated Pascal');
  reg.Plugins[0].GraphDigest := Rep('a', 64);
  reg.Plugins[0].PluginId := Utf8String('fixture.alpha' + #10 + 'const x = 1;');
  ok := PWebEmitRegistryInclude(reg, 'pwebqjspack', text, rcode, detail);
  Emit('c4 emit_newline_injection=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  Expect((not ok) and (rcode = prcRegistry) and (text = ''),
    'C4 a newline injection reached the generated Pascal');
  // the emitted registry must PIN its own writeability: in Delphi mode a
  // typed constant is writeable by default, and a trust anchor that a
  // stray write can edit at run time is not an anchor
  reg := MutatedRegistry;
  Expect(PWebEmitRegistryInclude(reg, 'pwebqjspack', text, rcode, detail),
    'C4 the production registry could not be re-emitted: ' + detail);
  Emit('c4 registry_readonly_pin=' +
    YesNo((PosEx('{$J-}', text, 1) > 0) and (PosEx('{$POP}', text, 1) > 0)));
  Expect((PosEx('{$J-}', text, 1) > 0) and (PosEx('{$POP}', text, 1) > 0),
    'C4 the generated registry does not pin its constants read-only');
end;

{ ---- runtime verification: C5-C12, C18 ----------------------------------- }

procedure CVerification;
var
  store: IAssetStore;
  code: TPWebReleaseCode;
  detail, sha: RawUtf8;
  reg: TPWebPackageRegistry;
  d: TFileName;
  zip, decoy: TFileName;
  data: RawByteString;
  ok: Boolean;
  saveCwd: TFileName;
begin
  zip := stagingDir + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE));

  // C5: the compiled digest IS the archive's digest
  data := StringFromFile(zip);
  sha := PWebSha256Hex(data);
  Emit('c5 package_digest_matches_registry=' +
    YesNo(sha = Registry.PackageSha256) +
    ' bytes_match=' + YesNo(Int64(Length(data)) = Registry.PackageBytes));
  Expect(sha = Registry.PackageSha256,
    'C5 the compiled registry does not describe the staged archive');
  Emit('c5 inventory_digest_matches=' +
    YesNo(PWebInventoryDigest(Registry.Inventory) = Registry.InventoryDigest));
  Expect(PWebInventoryDigest(Registry.Inventory) = Registry.InventoryDigest,
    'C5 the registry inventory digest does not describe its inventory');

  // the happy path
  ok := PWebVerifyQuickJSPackage(stagingDir, Registry, store, code, detail);
  Emit('c5 verify=' + YesNo(ok) + ' code=' + PWEB_RELEASE_CODE_TEXT[code]);
  Expect(ok, 'C5 the staged package did not verify: ' +
    PWEB_RELEASE_CODE_TEXT[code] + ' ' + detail);
  store := nil;

  // C6: absent
  d := NewWorkDir('absent');
  ok := PWebVerifyQuickJSPackage(d, Registry, store, code, detail);
  Emit('c6 missing=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code] + ' store=' + YesNo(store <> nil));
  Expect((not ok) and (code = prcPackageMissing) and (store = nil),
    'C6 a missing package did not refuse cleanly');

  // C7: the archive is untouched, the expected digest is not
  reg := MutatedRegistry;
  reg.PackageSha256 := Rep('0', 64);
  ok := PWebVerifyQuickJSPackage(stagingDir, reg, store, code, detail);
  Emit('c7 digest_mismatch=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code] + ' store=' + YesNo(store <> nil));
  Expect((not ok) and (code = prcPackageDigest) and (store = nil),
    'C7 a digest mismatch did not refuse');

  // C8: truncated
  d := NewWorkDir('truncated');
  FileFromString(Copy(data, 1, Length(data) - 32),
    d + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));
  ok := PWebVerifyQuickJSPackage(d, Registry, store, code, detail);
  Emit('c8 truncated=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code] + ' store=' + YesNo(store <> nil));
  Expect((not ok) and (code = prcPackageSize) and (store = nil),
    'C8 a truncated archive did not refuse');
  // and longer than declared
  d := NewWorkDir('appended');
  FileFromString(data + 'AAAA',
    d + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));
  ok := PWebVerifyQuickJSPackage(d, Registry, store, code, detail);
  Emit('c8 appended=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code]);
  Expect((not ok) and (code = prcPackageSize),
    'C8 an over-long archive did not refuse');

  // C9: structurally invalid, but with a registry that matches its bytes
  // exactly - so the ARCHIVE parser is what has to refuse, not the digest
  d := NewWorkDir('notazip');
  data := Rep('Z', 512);
  FileFromString(data, d + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));
  reg := MutatedRegistry;
  reg.PackageSha256 := PWebSha256Hex(data);
  reg.PackageBytes := Length(data);
  ok := PWebVerifyQuickJSPackage(d, reg, store, code, detail);
  Emit('c9 invalid_zip=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code] + ' store=' + YesNo(store <> nil));
  Expect((not ok) and (code = prcArchiveInvalid) and (store = nil),
    'C9 a structurally invalid archive did not refuse');

  // C10: a valid archive whose registry describes it wrongly. The whole
  // archive digest still matches, so ONLY the inventory check can catch
  // this - which is exactly why both exist.
  reg := MutatedRegistry;
  reg.Inventory[0].Sha256 := Rep('b', 64);
  reg.InventoryDigest := PWebInventoryDigest(reg.Inventory);
  ok := PWebVerifyQuickJSPackage(stagingDir, reg, store, code, detail);
  Emit('c10 inventory_mismatch=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code] + ' store=' + YesNo(store <> nil));
  Expect((not ok) and (code = prcInventoryMismatch) and (store = nil),
    'C10 an inventory mismatch did not refuse');
  // an inventory row removed: the count check fires first
  reg := MutatedRegistry;
  SetLength(reg.Inventory, Length(reg.Inventory) - 1);
  reg.InventoryDigest := PWebInventoryDigest(reg.Inventory);
  ok := PWebVerifyQuickJSPackage(stagingDir, reg, store, code, detail);
  Emit('c10 inventory_count=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code]);
  Expect(not ok, 'C10 a short inventory did not refuse');

  // C12: a registered entry point the inventory does not carry. Refused
  // by the registry gate itself, before any file is opened.
  reg := MutatedRegistry;
  reg.Plugins[0].EntryPoint := 'absent.js';
  ok := PWebVerifyQuickJSPackage(stagingDir, reg, store, code, detail);
  Emit('c12 entry_missing=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code]);
  Expect((not ok) and (code = prcRegistry),
    'C12 a missing registered entry point did not refuse');

  // C18: the package is located from an ABSOLUTE directory or not at
  // all, and a decoy sitting in the current working directory changes
  // nothing.
  ok := PWebVerifyQuickJSPackage('build', Registry, store, code, detail);
  Emit('c18 relative_dir_refused=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code]);
  Expect((not ok) and (code = prcPackageMissing),
    'C18 a relative package directory was accepted');
  // and the PRODUCTION rule itself: the archive is found beside the
  // running executable, through PWebReleaseDirectory, with no path from
  // any caller and no environment variable involved. The runner stages a
  // copy there precisely so this row is real rather than notional.
  ok := PWebVerifyQuickJSPackage(PWebReleaseDirectory, Registry, store,
    code, detail);
  Emit('c18 exe_relative=' + YesNo(ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[code]);
  Expect(ok, 'C18 the package was not found beside the executable: ' +
    PWEB_RELEASE_CODE_TEXT[code]);
  store := nil;

  decoy := NewWorkDir('decoy');
  FileFromString(Rep('X', 4096),
    decoy + TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));
  saveCwd := GetCurrentDir;
  try
    SetCurrentDir(decoy);
    ok := PWebVerifyQuickJSPackage(stagingDir, Registry, store, code, detail);
    if not ok then
      InterlockedIncrement(CwdDependency);
    Emit('c18 decoy_cwd_ignored=' + YesNo(ok) + ' code=' +
      PWEB_RELEASE_CODE_TEXT[code]);
    Expect(ok, 'C18 a decoy archive in the CWD changed the outcome');
    store := nil;
  finally
    SetCurrentDir(saveCwd);
  end;
end;

{ ---- C19-C24, C26-C28: the production package at run time ---------------- }

function StartProduction(out ALoader: TPWebQuickJSPackageLoader;
  out ACounter: TCountingAssetStore; out ACode: TPWebReleaseCode;
  out ADetail: RawUtf8): Boolean;
var
  store, counted: IAssetStore;
begin
  Result := False;
  ALoader := nil;
  ACounter := nil;
  if not PWebVerifyQuickJSPackage(stagingDir, Registry, store, ACode,
       ADetail) then
    exit;
  ACounter := TCountingAssetStore.Create(store);
  counted := ACounter;
  ALoader := TPWebQuickJSPackageLoader.Create(Registry, counted, gMakeSource,
    gSnapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, DRAIN_MS);
  ALoader.StartAll;
  Result := True;
end;

function CallOf(AHost: TPWebQuickJSPluginHost; const AName: RawUtf8;
  const AArgs: TPWebJson): RawUtf8;
var
  res, detail: RawUtf8;
  code: TPWebExportCallCode;
begin
  if AHost = nil then
    exit('no_host');
  code := AHost.CallExport(AName, AArgs, res, detail);
  if code = peccOk then
    Result := 'ok:' + res
  else
    Result := PWEB_EXPORT_CALL_TEXT[code];
end;

procedure CRuntime;
var
  loader: TPWebQuickJSPackageLoader;
  counter: TCountingAssetStore;
  code: TPWebReleaseCode;
  detail: RawUtf8;
  i: PtrInt;
  r: TPWebPluginStartResult;
  calc, rep: TPWebQuickJSPluginHost;
  before: LongInt;
begin
  if not StartProduction(loader, counter, code, detail) then
  begin
    Fail('the production package did not verify: ' +
      PWEB_RELEASE_CODE_TEXT[code] + ' ' + detail);
    exit;
  end;
  try
    Emit('c19 plugins=' + IntStr(loader.Count) + ' running=' +
      IntStr(loader.RunningCount));
    Expect(loader.RunningCount = Length(Registry.Plugins),
      'C19 not every registered plugin started');
    for i := 0 to loader.Count - 1 do
    begin
      r := loader.StartResult(i);
      Emit('c19 start plugin=' + RawUtf8(r.PluginId) +
        ' principal=' + RawUtf8(r.PrincipalId) +
        ' code=' + PWEB_PLUGIN_START_TEXT[r.Code] +
        ' running=' + YesNo(r.Running) +
        ' graph=' + r.GraphDigest);
      Expect(r.Code = pscOk, 'C19 plugin ' + RawUtf8(r.PluginId) +
        ' did not start: ' + PWEB_PLUGIN_START_TEXT[r.Code] + ' ' + r.Detail);
    end;
    calc := loader.HostOf(PID_CALC);
    rep := loader.HostOf(PID_REP);
    Expect(calc <> nil, 'C19 the calculator plugin is not published');
    Expect(rep <> nil, 'C19 the reporting plugin is not published');

    // C19 + C24: the packaged module graph answers, and 42 comes back
    // through the REAL bridge
    Emit('c19 add=' + CallOf(calc, 'add', '{"a":20,"b":22}'));
    Expect(CallOf(calc, 'add', '{"a":20,"b":22}') =
      'ok:{"sum":42,"local":42}', 'C19 Add did not return 42');
    Emit('c24 describe=' + CallOf(calc, 'describe', 'null'));
    Expect(CallOf(calc, 'describe', 'null') =
      'ok:"quickjs.calculator/lib/arith.js -> ok"',
      'C24 a packaged non-entry module was not reachable');

    // C20 + C21: the SAME archive, the SAME integrity, a different
    // principal - and the bridge is never reached
    before := DeniedBridgeAdd;
    Emit('c20 denied_add=' + CallOf(rep, 'add', '{"a":20,"b":22}'));
    Expect(CallOf(rep, 'add', '{"a":20,"b":22}') = 'ok:"forbidden"',
      'C20 the denied principal was not refused with forbidden');
    Emit('c21 denied_bridge_delta=' + IntStr(DeniedBridgeAdd - before));
    Expect(DeniedBridgeAdd = before,
      'C21 a denied invocation reached the bridge');
    Emit('c20 reporting_label=' + CallOf(rep, 'label', 'null'));

    // C23: script fields named after native concepts are inert
    Emit('c23 claim=' + CallOf(calc, 'claim', 'null'));
    Expect(CallOf(calc, 'add', '{"a":1,"b":2}') = 'ok:{"sum":3,"local":3}',
      'C23 identity claims changed what the plugin may do');
    Expect(CallOf(rep, 'add', '{"a":1,"b":2}') = 'ok:"forbidden"',
      'C23 the denied plugin became allowed');
    Emit('c23 opener=' + CallOf(calc, 'openExternal', 'null'));
    Expect(CallOf(calc, 'openExternal', 'null') = 'ok:"forbidden"',
      'C23 pweb.openExternal was not refused');
    Emit('c23 opener_reached=' + IntStr(OpenerReached));

    Emit('c19 store_arrivals_positive=' + YesNo(counter.Hits > 0));
    Expect(counter.Hits > 0,
      'C19 the package store was never read - the fixture is not real');
  finally
    loader.UnloadAll;
    loader.Free;
  end;
end;

{ ---- C22: no browser visibility ------------------------------------------ }

procedure CBrowserInvisibility;
var
  loader: TPWebQuickJSPackageLoader;
  counter: TCountingAssetStore;
  code: TPWebReleaseCode;
  detail: RawUtf8;
  d: TFileName;
  bundle: TFileName;
  entries: array of TPWebBundleEntry;
  man: TPWebBundleManifest;
  err, logical: RawUtf8;
  appStore: IAssetStore;
  reason: TPWebBundleRefusal;
  asset: TAssetResponse;
  i: PtrInt;
  before: LongInt;
  probes: TRawUtf8DynArray;
  found: Boolean;
begin
  if not StartProduction(loader, counter, code, detail) then
  begin
    Fail('C22 the production package did not verify: ' +
      PWEB_RELEASE_CODE_TEXT[code]);
    exit;
  end;
  try
    // an ordinary app.pwb, built by the UNCHANGED CAP-6 writer
    d := NewWorkDir('appbundle');
    SetLength(entries, 2);
    entries[0].Name := 'index.html';
    entries[0].Content := '<!doctype html><title>t</title>';
    entries[1].Name := 'assets/app.js';
    entries[1].Content := 'export const a = 1;';
    man.Protocol := PWEB_PROTOCOL_VERSION;
    man.MinRuntime := PWEB_RUNTIME_VERSION;
    bundle := d + 'app.pwb';
    Expect(PWebBundleWrite(bundle, entries, man, 0, err),
      'C22 the app bundle could not be built: ' + err);
    Expect(PWebBundleLoadFile(bundle, PWEB_SUPPORTED_PROTOCOLS,
      PWEB_RUNTIME_VERSION, appStore, reason),
      'C22 the app bundle did not load');
    if appStore = nil then
      exit;
    // C17: the CAP-6 writer still round-trips. Its GOLDEN bytes are
    // pinned per toolchain inside pwebtests, which runs on every target;
    // this row proves the shared deterministic-ZIP constants were not
    // disturbed, and deliberately keeps the toolchain-dependent hash out
    // of a four-way corpus.
    Expect(appStore.TryRead('index.html', asset) and (asset.Content <>
      ''), 'C17 the app bundle did not serve its index');
    Emit('c17 bundle_roundtrip=yes');

    // every path a browser could ask for, through the FROZEN CAP-4 URI
    // layer and into the app store - the exact route a platform
    // resource handler takes
    probes := nil;
    SetLength(probes, 7);
    probes[0] := 'pweb://app/quickjs.calculator/main.js';
    probes[1] := 'pweb://app/quickjs.calculator/lib/arith.js';
    probes[2] := 'pweb://app/quickjs.calculator/plugin.json';
    probes[3] := 'pweb://app/quickjs.reporting/main.js';
    probes[4] := 'pweb://app/plugins.zip';
    probes[5] := 'pweb://app/quickjs.calculator%2Fmain.js';
    probes[6] := 'pweb://app/../plugins.zip';
    before := counter.Hits;
    for i := 0 to High(probes) do
    begin
      found := False;
      if PWebParseAppUri(probes[i], logical) then
        found := appStore.TryRead(logical, asset);
      Emit('c22 probe=' + probes[i] + ' served=' + YesNo(found));
      Expect(not found, 'C22 a plugin path was served through pweb://app: ' +
        probes[i]);
    end;
    // the CAP-8B lesson: count actual arrivals, do not infer isolation
    // from an absent shim
    InterlockedExchange(BrowserStoreArrivals, counter.Hits - before);
    Emit('c22 browser_store_arrivals=' + IntStr(counter.Hits - before));
    Expect(counter.Hits = before,
      'C22 a browser probe reached the plugin package store');
    // the app bundle carries no plugin entry at all
    Expect(not appStore.TryRead('plugins.zip', asset),
      'C22 app.pwb carries plugins.zip');
    for i := 0 to High(Registry.Inventory) do
      Expect(not appStore.TryRead(Registry.Inventory[i].Name, asset),
        'C22 app.pwb carries a plugin source entry: ' +
        Registry.Inventory[i].Name);
    Emit('c22 app_bundle_disjoint=yes');
    // and the native loader can still read the very same bytes
    Expect(loader.PackageStore.TryRead(Registry.Inventory[0].Name, asset) and
      (Int64(Length(asset.Content)) = Registry.Inventory[0].Bytes),
      'C22 the native loader lost access to the package bytes');
    Emit('c22 native_read_ok=yes');
    appStore := nil;
  finally
    loader.UnloadAll;
    loader.Free;
  end;
end;

{ ---- C11, C26, C27: startup semantics and containment -------------------- }

procedure CStartupSemantics;
var
  d: TFileName;
  reg: TPWebPackageRegistry;
  pcode: TPWebPackageLoadCode;
  rcode: TPWebReleaseCode;
  detail, token: RawUtf8;
  store: IAssetStore;
  loader: TPWebQuickJSPackageLoader;
  plugins: TFixturePlugins;
  broken, spin: TPkgFiles;
  i: PtrInt;
  r: TPWebPluginStartResult;
  host: TPWebQuickJSPluginHost;
  ok: Boolean;
begin
  // ---- C11: the archive is perfect, the registry's graph digest is not
  d := NewWorkDir('graphdigest');
  if not StageFixture(d, OnePlugin('fixture.alpha', 'plugin:alpha',
       AlphaFiles), reg, pcode, rcode, detail) then
  begin
    Fail('C11 fixture could not be staged: ' + detail);
    exit;
  end;
  reg.Plugins[0].GraphDigest := Rep('c', 64);
  ok := PWebVerifyQuickJSPackage(d, reg, store, rcode, detail);
  Expect(ok, 'C11 the fixture package did not verify');
  if ok then
  begin
    loader := TPWebQuickJSPackageLoader.Create(reg, store, gMakeSource,
      gSnapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, DRAIN_MS);
    try
      loader.StartAll;
      r := loader.StartResult(0);
      Emit('c11 graph_digest_mismatch code=' +
        PWEB_PLUGIN_START_TEXT[r.Code] + ' running=' + YesNo(r.Running));
      Expect((r.Code = pscGraphDigest) and (not r.Running),
        'C11 a graph-digest mismatch still published a plugin');
      if r.Running then
        InterlockedIncrement(TamperStarted);
    finally
      loader.UnloadAll;
      loader.Free;
    end;
  end;
  store := nil;

  // ---- C27: a byte-perfect archive in which ONE plugin's CODE fails.
  // Ratified semantics: whole-package verification passes, that plugin
  // fails, the other keeps running.
  broken := nil;
  AddFile(broken, 'plugin.json', ManifestFor('fixture.broken'));
  AddFile(broken, 'main.js', 'throw new Error("boom");' + #10);
  SetLength(plugins, 2);
  plugins[0].PluginId := 'fixture.alpha';
  plugins[0].PrincipalId := 'plugin:alpha';
  plugins[0].Files := AlphaFiles;
  plugins[0].RawModules := nil;
  plugins[1].PluginId := 'fixture.broken';
  plugins[1].PrincipalId := 'plugin:broken';
  plugins[1].Files := broken;
  SetLength(plugins[1].RawModules, 1);
  plugins[1].RawModules[0] := 'main.js';
  d := NewWorkDir('onebroken');
  if not StageFixture(d, plugins, reg, pcode, rcode, detail) then
  begin
    Fail('C27 fixture could not be staged: ' + detail);
    exit;
  end;
  ok := PWebVerifyQuickJSPackage(d, reg, store, rcode, detail);
  Emit('c27 package_verified=' + YesNo(ok));
  Expect(ok, 'C27 the two-plugin fixture did not verify: ' +
    PWEB_RELEASE_CODE_TEXT[rcode]);
  if ok then
  begin
    loader := TPWebQuickJSPackageLoader.Create(reg, store, gMakeSource,
      gSnapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, DRAIN_MS);
    try
      loader.StartAll;
      for i := 0 to loader.Count - 1 do
      begin
        r := loader.StartResult(i);
        Emit('c27 plugin=' + RawUtf8(r.PluginId) + ' code=' +
          PWEB_PLUGIN_START_TEXT[r.Code] + ' package=' +
          PWEB_PACKAGE_LOAD_TEXT[r.PackageCode] +
          ' running=' + YesNo(r.Running));
      end;
      Emit('c27 running=' + IntStr(loader.RunningCount));
      Expect(loader.RunningCount = 1,
        'C27 exactly one plugin should be running');
      Expect(loader.StartResult(1).Code = pscLoad,
        'C27 the broken plugin did not report a load failure');
      Expect(loader.StartResult(1).PackageCode = plcEvaluate,
        'C27 the broken plugin failed for the wrong reason');
      host := loader.HostOf('fixture.alpha');
      Emit('c27 healthy_add=' + CallOf(host, 'add', '{"a":20,"b":22}'));
      Expect(CallOf(host, 'add', '{"a":20,"b":22}') =
        'ok:42', 'C27 the healthy plugin stopped working');
    finally
      loader.UnloadAll;
      loader.Free;
    end;
  end;
  store := nil;

  // ---- Q8: a hand-built archive whose module imports a SIBLING plugin.
  // The tool cannot produce this (C13 refuses it at build time), so it is
  // built raw - which is exactly the shape an attacker with archive
  // control would have. The frozen CAP-9B1 resolver refuses the specifier
  // at run time too, and the sibling keeps running.
  broken := nil;
  AddFile(broken, 'plugin.json', ManifestFor('fixture.reach'));
  AddFile(broken, 'main.js',
    'import { two } from "../fixture.alpha/lib/num.js";' + #10 +
    'pwebExports.a = function () { return two(); };' + #10);
  SetLength(plugins, 2);
  plugins[0].PluginId := 'fixture.alpha';
  plugins[0].PrincipalId := 'plugin:alpha';
  plugins[0].Files := AlphaFiles;
  plugins[0].RawModules := nil;
  plugins[1].PluginId := 'fixture.reach';
  plugins[1].PrincipalId := 'plugin:broken';
  plugins[1].Files := broken;
  SetLength(plugins[1].RawModules, 1);
  plugins[1].RawModules[0] := 'main.js';
  d := NewWorkDir('crossreach');
  if StageFixture(d, plugins, reg, pcode, rcode, detail) and
     PWebVerifyQuickJSPackage(d, reg, store, rcode, detail) then
  begin
    loader := TPWebQuickJSPackageLoader.Create(reg, store, gMakeSource,
      gSnapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, DRAIN_MS);
    try
      loader.StartAll;
      r := loader.StartResult(1);
      Emit('q8 cross_plugin_runtime code=' + PWEB_PLUGIN_START_TEXT[r.Code] +
        ' package=' + PWEB_PACKAGE_LOAD_TEXT[r.PackageCode] +
        ' running=' + YesNo(r.Running));
      Expect((r.Code = pscLoad) and (r.PackageCode = plcSpecifier) and
        (not r.Running),
        'Q8 a packaged plugin reached a sibling plugin module');
      host := loader.HostOf('fixture.alpha');
      Emit('q8 neighbour_add=' + CallOf(host, 'add', '{"a":20,"b":22}'));
      Expect(CallOf(host, 'add', '{"a":20,"b":22}') = 'ok:42',
        'Q8 the sibling plugin stopped working');
    finally
      loader.UnloadAll;
      loader.Free;
    end;
  end
  else
    Fail('Q8 fixture could not be staged or verified: ' + detail);
  store := nil;

  // ---- Q9: an archive carrying a root the compiled registry never
  // registered. Nothing in the archive can add a registry row, so the
  // package is refused as a whole BEFORE any file is opened.
  d := NewWorkDir('unregistered');
  SetLength(plugins, 2);
  plugins[0].PluginId := 'fixture.alpha';
  plugins[0].PrincipalId := 'plugin:alpha';
  plugins[0].Files := AlphaFiles;
  plugins[0].RawModules := nil;
  plugins[1].PluginId := 'fixture.beta';
  plugins[1].PrincipalId := 'plugin:beta';
  plugins[1].Files := BetaFiles;
  plugins[1].RawModules := nil;
  if StageFixture(d, plugins, reg, pcode, rcode, detail) then
  begin
    SetLength(reg.Plugins, 1);      // the registry knows only fixture.alpha
    ok := PWebVerifyQuickJSPackage(d, reg, store, rcode, detail);
    Emit('q9 unregistered_root=' + YesNo(not ok) + ' code=' +
      PWEB_RELEASE_CODE_TEXT[rcode] + ' store=' + YesNo(store <> nil));
    Expect((not ok) and (rcode = prcRegistry) and (store = nil),
      'Q9 an archive root the registry never registered was accepted');
  end
  else
    Fail('Q9 fixture could not be staged: ' + detail);
  store := nil;

  // ---- Q11: a DIFFERENT, perfectly valid production archive is still a
  // different build artifact. Nothing watches the file and nothing accepts
  // a new digest silently.
  ok := PWebVerifyQuickJSPackage(d, Registry, store, rcode, detail);
  Emit('q11 other_valid_archive=' + YesNo(not ok) + ' code=' +
    PWEB_RELEASE_CODE_TEXT[rcode] + ' store=' + YesNo(store <> nil));
  Expect((not ok) and (store = nil) and
    ((rcode = prcPackageDigest) or (rcode = prcPackageSize)),
    'Q11 a different valid archive was accepted against the compiled pin');
  store := nil;

  // ---- C26: a resource-limit failure stays contained in its plugin
  spin := nil;
  AddFile(spin, 'plugin.json', ManifestFor('fixture.spin'));
  AddFile(spin, 'main.js',
    'pwebExports.spin = function () { for (;;) {} };' + #10 +
    'pwebExports.ok = function () { return 1; };' + #10);
  SetLength(plugins, 2);
  plugins[0].PluginId := 'fixture.alpha';
  plugins[0].PrincipalId := 'plugin:alpha';
  plugins[0].Files := AlphaFiles;
  plugins[0].RawModules := nil;
  plugins[1].PluginId := 'fixture.spin';
  plugins[1].PrincipalId := 'plugin:spin';
  plugins[1].Files := spin;
  plugins[1].RawModules := nil;
  d := NewWorkDir('spin');
  if not StageFixture(d, plugins, reg, pcode, rcode, detail) then
  begin
    Fail('C26 fixture could not be staged: ' + detail);
    exit;
  end;
  ok := PWebVerifyQuickJSPackage(d, reg, store, rcode, detail);
  Expect(ok, 'C26 the spin fixture did not verify');
  if ok then
  begin
    loader := TPWebQuickJSPackageLoader.Create(reg, store, gMakeSource,
      gSnapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, DRAIN_MS);
    try
      loader.StartAll;
      host := loader.HostOf('fixture.spin');
      // the FIRST call is the one the CPU bound ends; the SECOND proves
      // the tainted generation is closed rather than merely slow
      token := CallOf(host, 'spin', 'null');
      Emit('c26 spin=' + token);
      Expect(token = 'resource_limit',
        'C26 a runaway export was not ended by the CPU bound');
      token := CallOf(host, 'ok', 'null');
      Emit('c26 after_taint=' + token);
      Expect(token = 'unavailable',
        'C26 a tainted generation still accepted a call');
      Emit('c26 spin_state=' + PWEB_PLUGIN_STATE_TEXT[host.State]);
      Expect(host.State = ppsFailed,
        'C26 the runaway plugin did not land in Failed');
      host := loader.HostOf('fixture.alpha');
      Emit('c26 neighbour_add=' + CallOf(host, 'add', '{"a":20,"b":22}'));
      Expect(CallOf(host, 'add', '{"a":20,"b":22}') = 'ok:42',
        'C26 a neighbour plugin was affected by the CPU bound');
    finally
      loader.UnloadAll;
      loader.Free;
    end;
  end;
  store := nil;
end;

{ ---- C28: repeated cycles ------------------------------------------------ }

procedure CCycles;
var
  loader: TPWebQuickJSPackageLoader;
  counter: TCountingAssetStore;
  code: TPWebReleaseCode;
  detail, token, first: RawUtf8;
  cycle: Integer;
begin
  first := '';
  for cycle := 1 to 3 do
  begin
    if not StartProduction(loader, counter, code, detail) then
    begin
      Fail('C28 cycle ' + IntStr(cycle) + ' did not verify');
      exit;
    end;
    try
      token := IntStr(loader.RunningCount) + '|' +
        CallOf(loader.HostOf(PID_CALC), 'add', '{"a":20,"b":22}') + '|' +
        CallOf(loader.HostOf(PID_REP), 'add', '{"a":20,"b":22}');
    finally
      loader.UnloadAll;
      loader.Free;
    end;
    if cycle = 1 then
      first := token;
    Expect(token = first, 'C28 cycle ' + IntStr(cycle) + ' diverged');
  end;
  Emit('c28 cycles=3 token=' + first);
end;

{ ---- C29: concurrent package-loader use ---------------------------------- }

constructor TLoaderThread.Create(const ADir: TFileName);
begin
  FDir := ADir;
  FStart := RTLEventCreate;
  FDoneEv := RTLEventCreate;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TLoaderThread.Destroy;
begin
  inherited Destroy;
  RTLEventDestroy(FStart);
  RTLEventDestroy(FDoneEv);
end;

procedure TLoaderThread.Execute;
var
  store: IAssetStore;
  loader: TPWebQuickJSPackageLoader;
  code: TPWebReleaseCode;
  detail: RawUtf8;
begin
  RTLEventWaitFor(FStart, 60000);
  try
    if not PWebVerifyQuickJSPackage(FDir, Registry, store, code, detail) then
      FToken := 'verify:' + PWEB_RELEASE_CODE_TEXT[code]
    else
    begin
      loader := TPWebQuickJSPackageLoader.Create(Registry, store, gMakeSource,
        gSnapCb, READY_WAIT_MS, EXPORT_WAIT_MS, JOIN_MS, DRAIN_MS);
      try
        loader.StartAll;
        FToken := IntStr(loader.RunningCount) + '|' +
          CallOf(loader.HostOf(PID_CALC), 'add', '{"a":20,"b":22}') + '|' +
          CallOf(loader.HostOf(PID_REP), 'add', '{"a":20,"b":22}');
      finally
        loader.UnloadAll;
        loader.Free;
      end;
    end;
  except
    on E: Exception do
      FToken := 'raised:' + RawUtf8(E.ClassName);
  end;
  RTLEventSetEvent(FDoneEv);
end;

procedure TLoaderThread.Go;
begin
  RTLEventSetEvent(FStart);
end;

function TLoaderThread.WaitToken: RawUtf8;
begin
  RTLEventWaitFor(FDoneEv, 120000);
  Result := FToken;
end;

procedure CConcurrency;
var
  a, b: TLoaderThread;
  ta, tb: RawUtf8;
begin
  a := TLoaderThread.Create(stagingDir);
  b := TLoaderThread.Create(stagingDir);
  try
    a.Go;
    b.Go;
    ta := a.WaitToken;
    tb := b.WaitToken;
    a.WaitFor;
    b.WaitFor;
  finally
    a.Free;
    b.Free;
  end;
  Emit('c29 concurrent_identical=' + YesNo(ta = tb) + ' token=' + ta);
  Expect(ta = tb, 'C29 two concurrent package loaders disagreed: ' +
    ta + ' vs ' + tb);
  Expect(PosEx('42', ta, 1) > 0, 'C29 the concurrent loaders did not reach 42');
end;

{ ---- C30: the license artifact ------------------------------------------- }

function NormalizeLf(const AText: RawByteString): RawByteString;
var
  i, n: PtrInt;
begin
  SetLength(Result, Length(AText));
  n := 0;
  for i := 1 to Length(AText) do
    if AText[i] <> #13 then
    begin
      Inc(n);
      Result[n] := AText[i];
    end;
  SetLength(Result, n);
end;

procedure CLicense;
var
  text, path, sha: RawByteString;
  i, p, q, sections, verified: PtrInt;
  srcDir: TFileName;
  pinned: RawByteString;
begin
  text := StringFromFile(stagingDir + TFileName(Utf8ToString(
    PWEB_RELEASE_LICENSE)));
  Emit('c30 present=' + YesNo(text <> '') + ' bytes=' + IntStr(Length(text)));
  Expect(text <> '', 'C30 LICENSE.quickjs is absent from the staging output');
  if text = '' then
    exit;
  Expect(PosEx(#13, RawUtf8(text), 1) = 0,
    'C30 the license artifact is not LF-only');
  Emit('c30 lf_only=' + YesNo(PosEx(#13, RawUtf8(text), 1) = 0));
  Expect(PosEx(MIT_SENTENCE, RawUtf8(text), 1) > 0,
    'C30 the MIT permission sentence is missing');
  Emit('c30 mit_sentence=' + YesNo(PosEx(MIT_SENTENCE, RawUtf8(text), 1) > 0));
  Expect(PosEx('mORMot2 commit  : b1a129b0', RawUtf8(text), 1) > 0,
    'C30 the license artifact does not record the mORMot pin');
  // every recorded digest must be the digest of the pinned file
  srcDir := root + 'deps' + PathDelim + 'mormot2' + PathDelim + 'res' +
    PathDelim + 'static' + PathDelim + 'libquickjs' + PathDelim;
  sections := 0;
  verified := 0;
  p := 1;
  repeat
    p := PosEx('file   : res/static/libquickjs/', RawUtf8(text), p);
    if p = 0 then
      break;
    Inc(sections);
    Inc(p, Length('file   : res/static/libquickjs/'));
    q := PosEx(#10, RawUtf8(text), p);
    if q = 0 then
      break;
    path := Copy(text, p, q - p);
    p := PosEx('sha256 : ', RawUtf8(text), q);
    if p = 0 then
      break;
    Inc(p, Length('sha256 : '));
    sha := Copy(text, p, 64);
    pinned := StringFromFile(srcDir + TFileName(Utf8ToString(RawUtf8(path))));
    if (pinned <> '') and
       (PWebSha256Hex(NormalizeLf(pinned)) = RawUtf8(sha)) then
      Inc(verified);
  until False;
  Emit('c30 sections=' + IntStr(sections) + ' digests_verified=' +
    IntStr(verified));
  Expect(sections = 17, 'C30 the license artifact does not carry the ' +
    'expected 17 pinned sections');
  Expect(verified = sections,
    'C30 a recorded digest does not match its pinned source');
end;

{ ---- the ledger ---------------------------------------------------------- }

procedure CLedger;
begin
  Emit('ledger browser_store_arrivals=' + IntStr(BrowserStoreArrivals));
  Emit('ledger denied_bridge_add=' + IntStr(DeniedBridgeAdd));
  Emit('ledger opener_reached=' + IntStr(OpenerReached));
  Emit('ledger tamper_started=' + IntStr(TamperStarted));
  Emit('ledger cwd_dependency=' + IntStr(CwdDependency));
  Emit('ledger service_reached=' + YesNo(NativeServiceAdd > 0));
  Emit('registry plugins=' + IntStr(Length(Registry.Plugins)) +
    ' entries=' + IntStr(Length(Registry.Inventory)) +
    ' file=' + Registry.PackageFile);
  Emit('registry inventory_digest=' + Registry.InventoryDigest);
end;

{ ---- main ---------------------------------------------------------------- }

var
  corpusFile, outFile: TFileName;
  overall: RawUtf8;
  json: RawUtf8;
  i: PtrInt;

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
      stagingDir := root + TFileName(StringReplace(STAGING_REL, '/', PathDelim,
        [rfReplaceAll])) + PathDelim;
      outFile := root + 'build' + PathDelim + 'cap9c1' + PathDelim +
        'quickjsrelease-' + TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));
      workDir := GetTempDir + 'pweb-cap9c1-' +
        TFileName(IntToStr(GetCurrentProcessId));
      RmTree(workDir);
      if not ForceDirectories(workDir) then
        raise Exception.Create('unable to create the fixture work directory');

      Registry := PWebRegistryFrom(PWEB_QUICKJS_PACKAGE_FILE,
        PWEB_QUICKJS_PACKAGE_SHA256, PWEB_QUICKJS_PACKAGE_BYTES,
        PWEB_QUICKJS_INVENTORY_DIGEST, PWEB_QUICKJS_INVENTORY,
        PWEB_QUICKJS_PLUGINS);
      // the per-target facts are recorded HERE, before any row can fail:
      // a FAIL record still has to name which archive it was judging
      RegistrySha := PWebSha256Hex(StringFromFile(stagingDir +
        TFileName(Utf8ToString(PWEB_RELEASE_REGISTRY_INC))));
      PackageSha := PWebSha256Hex(StringFromFile(stagingDir +
        TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE))));
      PackageBytes := FileSize(stagingDir +
        TFileName(Utf8ToString(PWEB_RELEASE_PACKAGE)));

      gServer := TRestServerFullMemory.CreateWithOwnModel([]);
      if gServer.ServiceRegister(TCalculatorService,
           [TypeInfo(ICalculatorService)], sicShared) = nil then
        raise Exception.Create('unable to register CalculatorService');
      gRealBridge := TMormotInvocationBridge.Create(gServer, True);
      gServer := nil;  // owned by the bridge now
      gBridge := TCountingBridge.Create(gRealBridge);
      gPolicy := BuildPolicy;
      gPolicyRef := gPolicy;
      gScheduler := TInvocationScheduler.Create(gPolicyRef, gBridge, 4);
      gSchedulerRef := gScheduler;
      gSnap := TSnapshotAdapter.Create;
      gSnapCb := gSnap.Snapshot;
      gFactory := TSourceFactory.Create;
      gMakeSource := gFactory.Make;   // Delphi-mode event assignment

      Emit('schema=1');
      Emit('pin quickjs=2021-03-27 nanboxing=strict libc=none');
      Emit('package file=' + PWEB_RELEASE_PACKAGE +
        ' registry=' + PWEB_RELEASE_REGISTRY_INC +
        ' license=' + PWEB_RELEASE_LICENSE);
      Emit('registry tool=' + PWEB_QUICKJS_REGISTRY_TOOL);
      for i := 0 to High(Registry.Inventory) do
        Emit('inventory ' + Registry.Inventory[i].Name + ' ' +
          IntStr(Registry.Inventory[i].Bytes) + ' ' +
          Registry.Inventory[i].Sha256);
      for i := 0 to High(Registry.Plugins) do
        Emit('plugin id=' + RawUtf8(Registry.Plugins[i].PluginId) +
          ' principal=' + RawUtf8(Registry.Plugins[i].PrincipalId) +
          ' root=' + Registry.Plugins[i].Root +
          ' entry=' + RawUtf8(Registry.Plugins[i].EntryPoint) +
          ' modules=' + IntStr(Registry.Plugins[i].ModuleCount) +
          ' source_bytes=' + IntStr(Registry.Plugins[i].SourceBytes) +
          ' graph=' + Registry.Plugins[i].GraphDigest +
          ' cpu=' + IntStr(Registry.Plugins[i].TimeoutSeconds) +
          ' mem=' + IntStr(Registry.Plugins[i].MemoryLimitBytes) +
          ' stack=' + IntStr(Registry.Plugins[i].StackLimitBytes));

      CBuilder;
      CGraphRules;
      CPaths;
      CRegistrySafety;
      CVerification;
      CRuntime;
      CBrowserInvisibility;
      CStartupSemantics;
      CCycles;
      CConcurrency;
      CLicense;
      CLedger;

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
        // a corpus already carrying verdict=PASS must be REWRITTEN: a
        // PASS line beside overall=FAIL would be hashed into the digest
        // and sail through the emitters (the CAP-9B1 finding)
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
      FreeAndNil(gFactory);
      if workDir <> '' then
        RmTree(workDir);
    except
    end;
  end;

  json := '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "target": "' + TARGET_ID + '",' + #10 +
    '  "overall": "' + overall + '",' + #10 +
    '  "package_sha256": "' + PackageSha + '",' + #10 +
    '  "package_bytes": ' + IntStr(PackageBytes) + ',' + #10 +
    '  "registry_sha256": "' + RegistrySha + '",' + #10 +
    '  "inventory_digest": "' + Registry.InventoryDigest + '",' + #10 +
    '  "browser_store_arrivals": ' + IntStr(BrowserStoreArrivals) + ',' + #10 +
    '  "denied_bridge_add": ' + IntStr(DeniedBridgeAdd) + ',' + #10 +
    '  "opener_reached": ' + IntStr(OpenerReached) + ',' + #10 +
    '  "tamper_started": ' + IntStr(TamperStarted) + ',' + #10 +
    '  "cwd_dependency": ' + IntStr(CwdDependency) + ',' + #10 +
    '  "service_add_count": ' + IntStr(NativeServiceAdd) + ',' + #10;
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
