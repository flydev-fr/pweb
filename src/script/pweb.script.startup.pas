{
  pweb.script.startup - CAP-9C1 trusted release startup: turn ONE
  verified plugin package plus the compiled native registry into
  running CAP-9B2 plugin hosts.

  This is the engine-facing half of the CAP-9C1 pair. pweb.script.release
  owns bytes, grammars and digests and knows nothing about QuickJS; this
  unit owns the step after verification and knows nothing about ZIP,
  SHA-256 or the filesystem. Between them there is exactly one hand-over:
  a verified IAssetStore over the whole archive and the registry that
  proved it.

  THE ORDER, and why nothing may be reordered:

    verify the whole package         (pweb.script.release - bytes gate)
        -> validate the registry against the package
        -> reserve one plugin identity per registry row
        -> start each generation transactionally (CAP-9B1 atomic load)
        -> compare the graph we got with the graph the registry pinned
        -> publish each Running plugin

  A plugin becomes visible ONLY at the CAP-9B2 commit point inside
  TPWebQuickJSPluginHost.Load. Nothing here publishes anything earlier,
  and a plugin that fails any step above is never published at all.

  RATIFIED STARTUP SEMANTICS - independent publication after whole-
  package verification:
  - archive corruption, a digest mismatch or an inventory mismatch
    rejects the COMPLETE package: no thread, no engine, no source, no
    descriptor and no partial availability (that gate lives entirely in
    pweb.script.release and runs before this unit is constructed);
  - past that gate, one plugin's script or runtime failure fails THAT
    plugin; another valid plugin may still run;
  - the loader reports an exact per-plugin startup result either way.

  CAPABILITIES ARE NOT IN THE REGISTRY. They are obtained per plugin
  from the host's CAP-8 snapshot callback keyed by the registry's native
  PrincipalId, so the packaging path never sees a capability and cannot
  grant one. A nil callback means the empty set - fail closed.

  WHAT A PACKAGE CANNOT DO, restated because it is the whole point: no
  archive content reaches PluginId, PrincipalId, PrincipalKind (always
  pkQuickJS), AppMaximum, principal capabilities, runtime grants, the
  entry-point declaration, any resource bound or the expected package
  digest. Script fields carrying those names stay inert. Package
  integrity is not authorization: every invocation still traverses the
  frozen CAP-8 policy on its way to the bridge.

  NO DISCOVERY, NO WATCHING, NO UPDATE. Nothing here scans a directory,
  watches a file, notices an mtime, or accepts a different archive
  digest. A different production package is a new build artifact, and
  B2 reload stays the explicit native operation it already was.

  Canonical sources: security-model.md (native trust anchor),
  threading-model.md (ownership), deployment.md (release layout).
}
unit pweb.script.startup;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  mormot.core.base,
  pweb.assets.intf,
  pweb.rpc.intf,
  pweb.script.package,
  pweb.script.quickjs,
  pweb.script.plugin,
  pweb.script.release;

type
  EPWebPackageStartup = class(Exception);

  { Why one registered plugin did not start. Private native codes: a
    startup is not an invocation, so the frozen nine-code RPC taxonomy
    is neither reused nor extended. }
  TPWebPluginStartCode = (
    pscOk,
    pscScope,         // the plugin's scoped store could not be built
    pscSource,        // the host's source factory produced no source
    pscLoad,          // the package failed to load (PackageCode says why)
    pscGraphDigest);  // the graph loaded is not the graph the registry pinned

  TPWebPluginStartResult = record
    PluginId: Utf8String;
    PrincipalId: Utf8String;
    Code: TPWebPluginStartCode;
    LifecycleCode: TPWebPluginLifecycleCode;
    PackageCode: TPWebPackageLoadCode;
    Detail: RawUtf8;         // short, sanitized, never a host path
    GraphDigest: RawUtf8;    // as MEASURED; '' when never loaded
    Running: Boolean;
  end;

const
  PWEB_PLUGIN_START_TEXT: array[TPWebPluginStartCode] of RawUtf8 = (
    'ok',
    'scope',
    'source',
    'load',
    'graph_digest');

type
  { Owns the verified package store and one CAP-9B2 host per registry
    row. It creates no thread and no engine itself: every generation is
    minted by TPWebQuickJSPluginHost, unchanged. }
  TPWebQuickJSPackageLoader = class
  private
    FRegistry: TPWebPackageRegistry;
    FStore: IAssetStore;
    FFactory: TPWebPluginSourceFactory;
    FOnSnapshot: TPWebQuickJSSnapshotEvent;
    FReadyWaitMs: Integer;
    FExportWaitMs: Integer;
    FUnloadJoinMs: Integer;
    FDrainMs: Integer;
    FHosts: array of TPWebQuickJSPluginHost;   // nil unless Running
    FScoped: array of IAssetStore;
    FResults: array of TPWebPluginStartResult;
    FStarted: Boolean;
    function MeasureGraphDigest(AHost: TPWebQuickJSPluginHost;
      const APlugin: TPWebRegistryPlugin;
      out AModules: Integer; out ADetail: RawUtf8): RawUtf8;
  public
    { ARegistry must already have verified AStore (that is what
      PWebVerifyQuickJSPackage returns). AStore is the WHOLE archive;
      one confined TPWebScopedAssetStore per plugin is built here, so a
      plugin can never name a sibling plugin's module namespace. }
    constructor Create(const ARegistry: TPWebPackageRegistry;
      const AStore: IAssetStore;
      const AFactory: TPWebPluginSourceFactory;
      const AOnSnapshot: TPWebQuickJSSnapshotEvent;
      AReadyWaitMs: Integer = 0; AExportWaitMs: Integer = 0;
      AUnloadJoinMs: Integer = 0; ADrainMs: Integer = 0);
    { Unloads every started plugin, bounded and idempotent. A generation
      that had to be quarantined is never freed - TPWebQuickJSPluginHost
      keeps it in the process-level ledger. }
    destructor Destroy; override;

    { Start every registered plugin, in registry order. Returns how many
      are Running. Callable once; a second call is a no-op returning the
      same count. }
    function StartAll: Integer;

    function Count: Integer;
    function StartResult(AIndex: Integer): TPWebPluginStartResult;
    { The Running host for a PluginId, or nil. }
    function HostOf(const APluginId: Utf8String): TPWebQuickJSPluginHost;
    { The confined store one plugin sees as its package root, or nil. }
    function ScopedStoreOf(const APluginId: Utf8String): IAssetStore;
    function RunningCount: Integer;
    { Bounded, idempotent teardown. }
    procedure UnloadAll;

    property PackageStore: IAssetStore read FStore;
  end;

type
  { BUILD-TIME result for ONE plugin: the authoritative module graph as
    the PRODUCTION loader resolved it, plus the exact bytes of every
    node. There is no second import scanner anywhere in PWeb - the
    frozen CAP-9B1 normalize/loader callbacks ARE the resolver, so
    cross-plugin edges, missing nodes, dynamic/bare/URL imports and
    every depth, count and size bound are refused at build time by the
    same code that will refuse them at run time. }
  TPWebPluginBuildResult = record
    PluginId: Utf8String;
    EntryPoint: Utf8String;
    ManifestBytes: RawByteString;
    Modules: TRawUtf8DynArray;         // loader order, package-relative
    Hashes: TRawUtf8DynArray;          // parallel to Modules
    Contents: TRawByteStringDynArray;  // parallel to Modules
    Edges: TRawUtf8DynArray;           // 'importer>imported', loader order
    SourceBytes: Int64;
    GraphDigest: RawUtf8;
  end;

/// BUILD-TIME: resolve ONE plugin's complete module graph by loading it
// through the unchanged production path over ASourceStore
// - ASourceStore is the plugin's own root (a folder store in the tool,
// any IAssetStore in a test); the descriptor is built with the EMPTY
// capability set, so a packaging run is structurally incapable of
// producing a backend effect even before the frozen Loading gate
// refuses pweb.invoke
// - the manifest id must equal APluginId: the archive sub-tree, the
// native PluginId and the descriptive manifest id are one name
function PWebResolvePluginPackage(const APluginId, AEntryPoint: Utf8String;
  const ASourceStore: IAssetStore;
  const AFactory: TPWebPluginSourceFactory;
  out ABuild: TPWebPluginBuildResult;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8;
  AReadyWaitMs: Integer = 0; AUnloadJoinMs: Integer = 0): Boolean;

/// BUILD-TIME: turn one resolved plugin into its archive entries, and
// prove the source tree holds NOTHING ELSE
// - ASourceFiles is the package-relative file list the caller walked.
// {plugin.json} union {graph modules} must equal it EXACTLY: an
// unreferenced source file is prcSourceUnreferenced and a graph node
// the walk never saw is prcSourceMissing. Fail-closed by ratified
// decision - the archive inventory is exactly the graph plus the
// manifests, so nothing unexplained can ship
function PWebPluginArchiveEntries(const ABuild: TPWebPluginBuildResult;
  const ASourceFiles: TRawUtf8DynArray;
  out AEntries: TPWebReleaseEntries;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;

/// THE production entry point: verify the package sitting beside the
// running executable, then start every registered plugin
// - on False no package was accepted, ALoader is nil and not one plugin
// thread, engine, scheduler source or native descriptor was created
// - on True ALoader is owned by the caller; individual plugins may
// still have failed to start (see StartResult), by ratified design
function PWebStartQuickJSPackage(const ADirectory: TFileName;
  const ARegistry: TPWebPackageRegistry;
  const AFactory: TPWebPluginSourceFactory;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent;
  out ALoader: TPWebQuickJSPackageLoader;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8;
  AReadyWaitMs: Integer = 0; AExportWaitMs: Integer = 0;
  AUnloadJoinMs: Integer = 0; ADrainMs: Integer = 0): Boolean;


implementation

function IntStr(AValue: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(AValue));
end;

{ split a 'key=value'#10 projection into the values of one key }
function ProjectionValues(const AText, AKey: RawUtf8): TRawUtf8DynArray;
var
  i, start, n, count: PtrInt;
  line: RawUtf8;
  prefix: RawUtf8;
begin
  Result := nil;
  count := 0;
  prefix := AKey + '=';
  n := Length(AText);
  start := 1;
  for i := 1 to n do
    if AText[i] = #10 then
    begin
      line := Copy(AText, start, i - start);
      start := i + 1;
      if (Length(line) > Length(prefix)) and
         (CompareMem(pointer(line), pointer(prefix), Length(prefix))) then
      begin
        if count = Length(Result) then
          SetLength(Result, count * 2 + 8);
        Result[count] := Copy(line, Length(prefix) + 1,
          Length(line) - Length(prefix));
        Inc(count);
      end;
    end;
  SetLength(Result, count);
end;

{ ---------------- TPWebQuickJSPackageLoader ------------------------------ }

constructor TPWebQuickJSPackageLoader.Create(
  const ARegistry: TPWebPackageRegistry;
  const AStore: IAssetStore;
  const AFactory: TPWebPluginSourceFactory;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent;
  AReadyWaitMs, AExportWaitMs, AUnloadJoinMs, ADrainMs: Integer);
var
  code: TPWebReleaseCode;
  detail: RawUtf8;
  i: PtrInt;
begin
  inherited Create;
  if AStore = nil then
    raise EPWebPackageStartup.Create(
      'TPWebQuickJSPackageLoader requires a verified package store');
  if not Assigned(AFactory) then
    raise EPWebPackageStartup.Create(
      'TPWebQuickJSPackageLoader requires an invocation-source factory');
  // the registry is re-validated here even though the verifier already
  // did it: a caller that assembled one by hand must not be able to
  // reach the descriptor path with an inconsistent trust anchor
  if not PWebValidateRegistry(ARegistry, code, detail) then
    raise EPWebPackageStartup.CreateFmt(
      'TPWebQuickJSPackageLoader: invalid registry (%s: %s)',
      [PWebReleaseCodeText(code), detail]);
  FRegistry := ARegistry;
  FStore := AStore;
  FFactory := AFactory;
  FOnSnapshot := AOnSnapshot;
  FReadyWaitMs := AReadyWaitMs;
  FExportWaitMs := AExportWaitMs;
  FUnloadJoinMs := AUnloadJoinMs;
  FDrainMs := ADrainMs;
  SetLength(FHosts, Length(FRegistry.Plugins));
  SetLength(FScoped, Length(FRegistry.Plugins));
  SetLength(FResults, Length(FRegistry.Plugins));
  for i := 0 to High(FRegistry.Plugins) do
  begin
    FResults[i] := Default(TPWebPluginStartResult);
    FResults[i].PluginId := FRegistry.Plugins[i].PluginId;
    FResults[i].PrincipalId := FRegistry.Plugins[i].PrincipalId;
    FResults[i].Code := pscOk;
  end;
end;

destructor TPWebQuickJSPackageLoader.Destroy;
begin
  UnloadAll;
  FStore := nil;
  inherited Destroy;
end;

function TPWebQuickJSPackageLoader.MeasureGraphDigest(
  AHost: TPWebQuickJSPluginHost; const APlugin: TPWebRegistryPlugin;
  out AModules: Integer; out ADetail: RawUtf8): RawUtf8;
var
  projection: RawUtf8;
  modules, edges, hashes: TRawUtf8DynArray;
  i, j: PtrInt;
  full: RawUtf8;
  found: Boolean;
begin
  Result := '';
  ADetail := '';
  AModules := 0;
  projection := AHost.GraphProjection;
  modules := ProjectionValues(projection, 'module');
  edges := ProjectionValues(projection, 'edge');
  AModules := Length(modules);
  if AModules = 0 then
  begin
    ADetail := 'empty module graph';
    exit;
  end;
  SetLength(hashes, Length(modules));
  for i := 0 to High(modules) do
  begin
    // the hash comes from the ALREADY VERIFIED inventory, never from a
    // fresh read: the inventory is the archive's proven meaning, so a
    // second read here could only weaken the chain
    full := APlugin.Root + modules[i];
    found := False;
    for j := 0 to High(FRegistry.Inventory) do
      if FRegistry.Inventory[j].Name = full then
      begin
        hashes[i] := FRegistry.Inventory[j].Sha256;
        found := True;
        break;
      end;
    if not found then
    begin
      ADetail := 'module absent from the inventory';
      exit;
    end;
  end;
  Result := PWebGraphDigest(APlugin.PluginId, APlugin.EntryPoint,
    modules, hashes, edges);
end;

function TPWebQuickJSPackageLoader.StartAll: Integer;
var
  i: PtrInt;
  p: TPWebRegistryPlugin;
  scoped: IAssetStore;
  reg: TPWebPluginRegistration;
  host: TPWebQuickJSPluginHost;
  life: TPWebPluginLifecycleCode;
  code: TPWebPackageLoadCode;
  detail, measured: RawUtf8;
  modules: Integer;
begin
  Result := 0;
  if FStarted then
    exit(RunningCount);
  FStarted := True;
  for i := 0 to High(FRegistry.Plugins) do
  begin
    p := FRegistry.Plugins[i];
    // 1. confine the plugin to its own archive sub-tree. A sibling
    //    plugin's modules are unreachable from inside it, and the
    //    prefix is native and never echoed back to script.
    scoped := nil;
    try
      scoped := TPWebScopedAssetStore.Create(FStore, p.Root);
    except
      on E: Exception do
      begin
        FResults[i].Code := pscScope;
        FResults[i].Detail := RawUtf8(E.ClassName);
        continue;
      end;
    end;
    FScoped[i] := scoped;
    // 2. build the NATIVE descriptor. Every field is a compiled
    //    constant or CAP-8 configuration; nothing comes from the archive.
    reg := Default(TPWebPluginRegistration);
    reg.Descriptor.PrincipalId := p.PrincipalId;
    reg.Descriptor.PluginId := p.PluginId;
    reg.Descriptor.PackageStore := scoped;
    reg.Descriptor.ExpectedPackageId := p.PackageId;
    reg.Descriptor.ExpectedEntryPoint := p.EntryPoint;
    if Assigned(FOnSnapshot) then
      reg.Descriptor.Capabilities := FOnSnapshot(p.PrincipalId)
    else
      reg.Descriptor.Capabilities := nil;   // fail closed: no rights
    reg.Descriptor.Engine.TimeoutSeconds := p.TimeoutSeconds;
    reg.Descriptor.Engine.MemoryLimitBytes := p.MemoryLimitBytes;
    reg.Descriptor.Engine.StackLimitBytes := p.StackLimitBytes;
    reg.Descriptor.Engine.InvokeWaitMs := p.InvokeWaitMs;
    reg.Descriptor.Package := p.Package;
    reg.OnSnapshot := FOnSnapshot;
    reg.SourceFactory := FFactory;
    reg.ReadyWaitMs := FReadyWaitMs;
    reg.ExportWaitMs := FExportWaitMs;
    reg.UnloadJoinMs := FUnloadJoinMs;
    reg.DrainMs := FDrainMs;
    host := nil;
    try
      host := TPWebQuickJSPluginHost.Create(reg);
    except
      on E: Exception do
      begin
        FResults[i].Code := pscLoad;
        FResults[i].Detail := RawUtf8(E.ClassName);
        FScoped[i] := nil;
        continue;
      end;
    end;
    // 3. the CAP-9B1 atomic load through the CAP-9B2 state machine,
    //    unchanged. On failure nothing was published and no thread
    //    survived - that guarantee is B1's, re-used rather than re-made.
    life := host.Load(code, detail);
    if life <> plfOk then
    begin
      if life = plfSource then
        FResults[i].Code := pscSource
      else
        FResults[i].Code := pscLoad;
      FResults[i].LifecycleCode := life;
      FResults[i].PackageCode := code;
      FResults[i].Detail := detail;
      host.Free;
      FScoped[i] := nil;
      continue;
    end;
    // 4. the graph we got must be the graph the compiled registry
    //    pinned. The bytes were already proven by the whole-archive
    //    digest, so a mismatch here means the REGISTRY row is wrong for
    //    this plugin - loud, and this plugin never publishes.
    measured := MeasureGraphDigest(host, p, modules, detail);
    if (measured = '') or
       (measured <> p.GraphDigest) or
       (modules <> p.ModuleCount) then
    begin
      FResults[i].Code := pscGraphDigest;
      FResults[i].LifecycleCode := plfOk;
      FResults[i].GraphDigest := measured;
      if detail <> '' then
        FResults[i].Detail := detail
      else if modules <> p.ModuleCount then
        FResults[i].Detail := 'module count ' + IntStr(modules) + ' <> ' +
          IntStr(p.ModuleCount)
      else
        FResults[i].Detail := 'graph digest mismatch';
      host.Unload;
      host.Free;
      FScoped[i] := nil;
      continue;
    end;
    // 5. publish
    FHosts[i] := host;
    FResults[i].Code := pscOk;
    FResults[i].LifecycleCode := plfOk;
    FResults[i].PackageCode := plcNone;
    FResults[i].GraphDigest := measured;
    FResults[i].Running := True;
    Inc(Result);
  end;
end;

function TPWebQuickJSPackageLoader.Count: Integer;
begin
  Result := Length(FResults);
end;

function TPWebQuickJSPackageLoader.StartResult(
  AIndex: Integer): TPWebPluginStartResult;
begin
  if (AIndex < 0) or
     (AIndex > High(FResults)) then
    Result := Default(TPWebPluginStartResult)
  else
    Result := FResults[AIndex];
end;

function TPWebQuickJSPackageLoader.HostOf(
  const APluginId: Utf8String): TPWebQuickJSPluginHost;
var
  i: PtrInt;
begin
  for i := 0 to High(FResults) do
    if FResults[i].PluginId = APluginId then
      exit(FHosts[i]);
  Result := nil;
end;

function TPWebQuickJSPackageLoader.ScopedStoreOf(
  const APluginId: Utf8String): IAssetStore;
var
  i: PtrInt;
begin
  for i := 0 to High(FResults) do
    if FResults[i].PluginId = APluginId then
      exit(FScoped[i]);
  Result := nil;
end;

function TPWebQuickJSPackageLoader.RunningCount: Integer;
var
  i: PtrInt;
begin
  Result := 0;
  for i := 0 to High(FResults) do
    if FResults[i].Running then
      Inc(Result);
end;

procedure TPWebQuickJSPackageLoader.UnloadAll;
var
  i: PtrInt;
begin
  for i := 0 to High(FHosts) do
    if FHosts[i] <> nil then
    begin
      try
        FHosts[i].Unload;
      except
      end;
      try
        // Destroy unloads again (bounded, idempotent) and refuses to
        // free a quarantined generation - that is B2's rule, not ours
        FHosts[i].Free;
      except
      end;
      FHosts[i] := nil;
      FResults[i].Running := False;
    end;
  for i := 0 to High(FScoped) do
    FScoped[i] := nil;
end;

{ ---------------- BUILD-TIME graph resolution ---------------------------- }

function PWebResolvePluginPackage(const APluginId, AEntryPoint: Utf8String;
  const ASourceStore: IAssetStore;
  const AFactory: TPWebPluginSourceFactory;
  out ABuild: TPWebPluginBuildResult;
  out ACode: TPWebPackageLoadCode; out ADetail: RawUtf8;
  AReadyWaitMs, AUnloadJoinMs: Integer): Boolean;
var
  reg: TPWebPluginRegistration;
  host: TPWebQuickJSPluginHost;
  life: TPWebPluginLifecycleCode;
  projection: RawUtf8;
  manifest: TAssetResponse;
  asset: TAssetResponse;
  i: PtrInt;
begin
  Result := False;
  ABuild := Default(TPWebPluginBuildResult);
  ACode := plcNone;
  ADetail := '';
  if ASourceStore = nil then
  begin
    ACode := plcDescriptor;
    ADetail := 'no source store';
    exit;
  end;
  if not ASourceStore.TryRead(PWEB_PACKAGE_MANIFEST, manifest) then
  begin
    ACode := plcManifestMissing;
    ADetail := PWEB_PACKAGE_MANIFEST;
    exit;
  end;
  ABuild.PluginId := APluginId;
  ABuild.EntryPoint := AEntryPoint;
  ABuild.ManifestBytes := manifest.Content;
  reg := Default(TPWebPluginRegistration);
  reg.Descriptor.PrincipalId := APluginId;   // build-time only, never shipped
  reg.Descriptor.PluginId := APluginId;
  reg.Descriptor.PackageStore := ASourceStore;
  reg.Descriptor.ExpectedPackageId := APluginId;
  reg.Descriptor.ExpectedEntryPoint := AEntryPoint;
  reg.Descriptor.Capabilities := nil;        // the empty set: grants nothing
  reg.Descriptor.Engine := PWEB_QUICKJS_DEFAULT_LIMITS;
  reg.Descriptor.Package := PWEB_PACKAGE_DEFAULT_LIMITS;
  reg.OnSnapshot := nil;
  reg.SourceFactory := AFactory;
  reg.ReadyWaitMs := AReadyWaitMs;
  reg.UnloadJoinMs := AUnloadJoinMs;
  host := nil;
  try
    try
      host := TPWebQuickJSPluginHost.Create(reg);
    except
      on E: Exception do
      begin
        ACode := plcDescriptor;
        ADetail := RawUtf8(E.ClassName);
        exit;
      end;
    end;
    life := host.Load(ACode, ADetail);
    if life <> plfOk then
    begin
      if ACode = plcNone then
        ACode := plcDescriptor;
      if ADetail = '' then
        ADetail := PWEB_PLUGIN_LIFECYCLE_TEXT[life];
      exit;
    end;
    projection := host.GraphProjection;
    ABuild.Modules := ProjectionValues(projection, 'module');
    ABuild.Edges := ProjectionValues(projection, 'edge');
    if Length(ABuild.Modules) = 0 then
    begin
      ACode := plcModuleMissing;
      ADetail := 'empty module graph';
      exit;
    end;
    SetLength(ABuild.Hashes, Length(ABuild.Modules));
    SetLength(ABuild.Contents, Length(ABuild.Modules));
    for i := 0 to High(ABuild.Modules) do
    begin
      if not ASourceStore.TryRead(ABuild.Modules[i], asset) then
      begin
        ACode := plcModuleMissing;
        ADetail := ABuild.Modules[i];
        exit;
      end;
      ABuild.Contents[i] := asset.Content;
      ABuild.Hashes[i] := PWebSha256Hex(asset.Content);
      Inc(ABuild.SourceBytes, Length(asset.Content));
    end;
    ABuild.GraphDigest := PWebGraphDigest(APluginId, AEntryPoint,
      ABuild.Modules, ABuild.Hashes, ABuild.Edges);
    Result := True;
  finally
    if host <> nil then
    begin
      try
        host.Unload;
      except
      end;
      try
        host.Free;
      except
      end;
    end;
    if not Result then
      ABuild := Default(TPWebPluginBuildResult);
  end;
end;

function PWebPluginArchiveEntries(const ABuild: TPWebPluginBuildResult;
  const ASourceFiles: TRawUtf8DynArray;
  out AEntries: TPWebReleaseEntries;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8): Boolean;
var
  i, j: PtrInt;
  root: RawUtf8;
  seen: Boolean;
begin
  Result := False;
  AEntries := nil;
  ACode := prcNone;
  ADetail := '';
  root := PWebPluginArchiveRoot(ABuild.PluginId);
  // every graph node must be a file the caller actually walked
  for i := 0 to High(ABuild.Modules) do
  begin
    seen := False;
    for j := 0 to High(ASourceFiles) do
      if ASourceFiles[j] = ABuild.Modules[i] then
      begin
        seen := True;
        break;
      end;
    if not seen then
    begin
      ACode := prcSourceMissing;
      ADetail := ABuild.Modules[i];
      exit;
    end;
  end;
  // and every walked file must be the manifest or a graph node: an
  // unreferenced source file is a BUILD ERROR naming the exact path,
  // never a silent inclusion and never a silent exclusion
  for j := 0 to High(ASourceFiles) do
  begin
    if ASourceFiles[j] = PWEB_PACKAGE_MANIFEST then
      continue;
    seen := False;
    for i := 0 to High(ABuild.Modules) do
      if ABuild.Modules[i] = ASourceFiles[j] then
      begin
        seen := True;
        break;
      end;
    if not seen then
    begin
      ACode := prcSourceUnreferenced;
      ADetail := root + ASourceFiles[j];
      exit;
    end;
  end;
  SetLength(AEntries, Length(ABuild.Modules) + 1);
  AEntries[0].Name := root + PWEB_PACKAGE_MANIFEST;
  AEntries[0].Content := ABuild.ManifestBytes;
  for i := 0 to High(ABuild.Modules) do
  begin
    AEntries[i + 1].Name := root + ABuild.Modules[i];
    AEntries[i + 1].Content := ABuild.Contents[i];
  end;
  Result := True;
end;

{ ---------------- the production entry point ----------------------------- }

function PWebStartQuickJSPackage(const ADirectory: TFileName;
  const ARegistry: TPWebPackageRegistry;
  const AFactory: TPWebPluginSourceFactory;
  const AOnSnapshot: TPWebQuickJSSnapshotEvent;
  out ALoader: TPWebQuickJSPackageLoader;
  out ACode: TPWebReleaseCode; out ADetail: RawUtf8;
  AReadyWaitMs, AExportWaitMs, AUnloadJoinMs, ADrainMs: Integer): Boolean;
var
  store: IAssetStore;
  dir: TFileName;
begin
  Result := False;
  ALoader := nil;
  dir := ADirectory;
  if dir = '' then
    dir := PWebReleaseDirectory;
  if not PWebVerifyQuickJSPackage(dir, ARegistry, store, ACode, ADetail) then
    exit;
  try
    ALoader := TPWebQuickJSPackageLoader.Create(ARegistry, store, AFactory,
      AOnSnapshot, AReadyWaitMs, AExportWaitMs, AUnloadJoinMs, ADrainMs);
  except
    on E: Exception do
    begin
      ALoader := nil;
      ACode := prcRegistry;
      ADetail := RawUtf8(E.ClassName);
      exit;
    end;
  end;
  ALoader.StartAll;
  Result := True;
end;

end.
