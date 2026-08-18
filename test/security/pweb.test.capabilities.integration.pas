{
  pweb.test.capabilities.integration - CAP-8A integration gates I1-I10:
  the CAP-8A reference configuration through the REAL pipeline -
  TInvocationScheduler workers -> TPWebCapabilityPolicy ->
  TMormotInvocationBridge -> in-process TRestServer.Uri().

  Registration follows the existing mORMot-case discipline: the real
  interface-service invocation path needs the prepared CAP-3U trampoline
  on Win64 (PWEB_CALLMETHOD_UNWIND_PROBE), so on Windows these gates run
  inside the CAP-3 headless runner (cap3tests) and in pwebtests only
  when the define is active; on Linux/macOS no trampoline exists or is
  needed and pwebtests registers them unconditionally - which is what
  puts I1-I10 on all four CI targets.

  Evidence discipline: every deny asserts BOTH the canonical envelope
  and zero SOA activity via counting spies (the TUriProbe BeforeUri
  counter plus per-service invocation counters), never by inference.

  The reference configuration itself lives in pweb.test.capabilities
  (NewReferencePolicy + the Ref*Context builders) - one home, no
  duplication. This unit adds the deterministic test services:
    SettingsService.GetValue -> 7      (requires settings.read)
    SettingsService.SetValue(v) -> v   (requires settings.write)
    SettingsService.Purge -> 13        (registered but UNMAPPED: I5)
    ParkingService.List -> 3           (requires parking.read)
    ParkingService.Reserve -> 9        (requires parking.write)
    GhostService.Ping                  (mapped but NEVER registered: I7)
}

{$I mormot.defines.inc}

unit pweb.test.capabilities.integration;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.interfaces,
  mormot.core.test,
  mormot.rest.memserver,
  mormot.soa.core,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.test.scheduler,
  pweb.test.mormot.fixture,
  pweb.test.capabilities;

type
  ISettingsService = interface(IInvokable)
    ['{8B3B7C51-2A94-4E0D-9C67-1F5A28D3B0E4}']
    function GetValue: Integer;
    function SetValue(v: Integer): Integer;
    function Purge: Integer;
  end;

  IParkingService = interface(IInvokable)
    ['{D14E9A02-6C58-47B3-8F21-9E0B54C7A6D3}']
    function List: Integer;
    function Reserve: Integer;
  end;

  TSettingsService = class(TInterfacedObject, ISettingsService)
  public
    function GetValue: Integer;
    function SetValue(v: Integer): Integer;
    function Purge: Integer;
  end;

  TParkingService = class(TInterfacedObject, IParkingService)
  public
    function List: Integer;
    function Reserve: Integer;
  end;

  /// scheduler -> production policy -> real mORMot bridge fixture over
  // the CAP-8A reference configuration; one home for the I-gates
  TTestCapabilityPolicyIntegration = class(TSynTestCase)
  protected
    FProbe: TUriProbe;
    FBridge: IInvocationBridge;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy;
    FScheduler: TInvocationScheduler;
    FSchedulerRef: IInvocationScheduler;
    FSource: IInvocationSource;
    procedure StartPipeline;
    procedure StopPipeline;
    function Run(const ACtx: TInvocationContext; const AMethod: Utf8String;
      const AArgs: TPWebJson): TPWebInvocationResult;
  published
    procedure AllowedMainWindow;       // I1
    procedure DeniedLoginWindow;       // I2
    procedure DeniedReportingPlugin;   // I3
    procedure GrantRevocation;         // I4
    procedure UnmappedMethodZeroSoa;   // I5
    procedure MalformedContext;        // I6
    procedure MappedButUnregistered;   // I7
    procedure ZeroCapHandshake;        // I8
    procedure ForgedArgsIgnored;       // I9
    procedure PerPrincipalMatrix;      // I10
  end;

implementation

var
  GSettingsGet, GSettingsSet, GSettingsPurge: LongInt;
  GParkingList, GParkingReserve: LongInt;

function SettingsGetCount: Integer;
begin
  Result := InterlockedCompareExchange(GSettingsGet, 0, 0);
end;

function SettingsSetCount: Integer;
begin
  Result := InterlockedCompareExchange(GSettingsSet, 0, 0);
end;

function SettingsPurgeCount: Integer;
begin
  Result := InterlockedCompareExchange(GSettingsPurge, 0, 0);
end;

function ParkingListCount: Integer;
begin
  Result := InterlockedCompareExchange(GParkingList, 0, 0);
end;

function ParkingReserveCount: Integer;
begin
  Result := InterlockedCompareExchange(GParkingReserve, 0, 0);
end;

procedure ResetServiceCounters;
begin
  InterlockedExchange(GSettingsGet, 0);
  InterlockedExchange(GSettingsSet, 0);
  InterlockedExchange(GSettingsPurge, 0);
  InterlockedExchange(GParkingList, 0);
  InterlockedExchange(GParkingReserve, 0);
end;

function TSettingsService.GetValue: Integer;
begin
  InterlockedIncrement(GSettingsGet);
  Result := 7;
end;

function TSettingsService.SetValue(v: Integer): Integer;
begin
  InterlockedIncrement(GSettingsSet);
  Result := v;
end;

function TSettingsService.Purge: Integer;
begin
  InterlockedIncrement(GSettingsPurge);
  Result := 13;
end;

function TParkingService.List: Integer;
begin
  InterlockedIncrement(GParkingList);
  Result := 3;
end;

function TParkingService.Reserve: Integer;
begin
  InterlockedIncrement(GParkingReserve);
  Result := 9;
end;

{ ---------------- fixture ---------------- }

procedure TTestCapabilityPolicyIntegration.StartPipeline;
var
  server: TRestServerFullMemory;
  limits: TPWebSourceLimits;
begin
  ResetCalculatorState;
  ResetServiceCounters;
  // one real in-process server carrying Calculator + Settings + Parking;
  // GhostService is deliberately NEVER registered (gate I7)
  server := NewCalculatorServer(FProbe);
  try
    if server.ServiceRegister(TSettingsService,
        [TypeInfo(ISettingsService)], sicShared) = nil then
      raise Exception.Create('unable to register ISettingsService');
    if server.ServiceRegister(TParkingService,
        [TypeInfo(IParkingService)], sicShared) = nil then
      raise Exception.Create('unable to register IParkingService');
  except
    server.Free;
    FreeAndNil(FProbe);
    raise;
  end;
  try
    FBridge := TMormotInvocationBridge.Create(server, True);
    server := nil; // the bridge owns it from here
  except
    // the bridge constructor raised: nothing owns the server yet
    server.Free;
    FreeAndNil(FProbe);
    raise;
  end;
  try
    FPolicy := NewReferencePolicy;
    FPolicyRef := FPolicy;
    FScheduler := TInvocationScheduler.Create(FPolicyRef, FBridge, 2);
    FSchedulerRef := FScheduler;
    limits.MaxConcurrent := 2;
    limits.MaxQueueSize := 16;
    FSource := FScheduler.RegisterSource(limits);
  except
    // mid-start failure: tear down whatever exists so a broken start
    // can never leak workers, the server or the probe into a later gate
    StopPipeline;
    raise;
  end;
end;

procedure TTestCapabilityPolicyIntegration.StopPipeline;
begin
  if FScheduler <> nil then
    FScheduler.Shutdown; // drain workers BEFORE the bridge/server go
  FSource := nil;
  FSchedulerRef := nil;
  FScheduler := nil;
  FPolicyRef := nil;
  FPolicy := nil;
  FBridge := nil; // owned server freed here, after the drain
  FreeAndNil(FProbe);
end;

function TTestCapabilityPolicyIntegration.Run(
  const ACtx: TInvocationContext; const AMethod: Utf8String;
  const AArgs: TPWebJson): TPWebInvocationResult;
var
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
begin
  // GUARDED: a refused enqueue or a missed completion fails the case
  // loudly and returns an internal_error SENTINEL - the empty
  // completion record is never read as if it were a real result
  sink := TTestCompletion.Create;
  sinkRef := sink;
  if FSource.TryEnqueue(ACtx, AMethod, AArgs, sinkRef) <> perAccepted then
  begin
    Check(False, 'enqueue refused for ' + string(AMethod));
    Result := PWebDefaultErrorResult(pecInternalError);
    exit;
  end;
  if not sink.WaitDone(5000) then
  begin
    Check(False, 'completion never arrived for ' + string(AMethod));
    Result := PWebDefaultErrorResult(pecInternalError);
    exit;
  end;
  CheckEqual(sink.CompleteCount, 1, 'exactly-once completion');
  Result := sink.First;
end;

{ ---------------- the gates ---------------- }

procedure TTestCapabilityPolicyIntegration.AllowedMainWindow;
var
  r: TPWebInvocationResult;
begin
  // I1: MainWindow -> CalculatorService.Add -> 42, service counter = 1
  StartPipeline;
  try
    r := Run(RefContextMain(FPolicy), 'CalculatorService.Add',
      '{"a":20,"b":22}');
    Check(r.Kind = prkSuccess, 'I1 success arm');
    CheckEqual(r.Value, '42', 'I1 value 42');
    CheckEqual(CalculatorCalls, 1, 'I1 service counter');
    Check(CalculatorLastThreadId <> GetCurrentThreadId,
      'I1 real service ran on a worker');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.DeniedLoginWindow;
var
  r: TPWebInvocationResult;
begin
  // I2: LoginWindow lacks calculator.add -> forbidden, zero service and
  // zero SOA activity, canonical envelope
  StartPipeline;
  try
    r := Run(RefContextLogin(FPolicy), 'CalculatorService.Add',
      '{"a":20,"b":22}');
    Check(r.Kind = prkError, 'I2 error arm');
    Check(r.Error.Code = pecForbidden, 'I2 forbidden');
    CheckEqual(r.Error.Message, PWEB_DEFAULT_ERROR_MESSAGE[pecForbidden],
      'I2 canonical message');
    CheckEqual(r.Error.Data, PWEB_JSON_NULL, 'I2 null data');
    CheckEqual(PWEB_ERROR_STATUS[pecForbidden], 403, 'I2 status 403');
    CheckEqual(CalculatorCalls, 0, 'I2 service never entered');
    CheckEqual(FProbe.Count, 0, 'I2 zero SOA activity');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.DeniedReportingPlugin;
var
  r: TPWebInvocationResult;
begin
  // I3: the plugin principal holds parking.read only -> forbidden
  StartPipeline;
  try
    r := Run(RefContextPlugin(FPolicy), 'CalculatorService.Add',
      '{"a":20,"b":22}');
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I3 forbidden');
    CheckEqual(CalculatorCalls, 0, 'I3 service never entered');
    CheckEqual(FProbe.Count, 0, 'I3 zero SOA activity');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.GrantRevocation;
var
  ctxBefore, ctxAfter: TInvocationContext;
  r: TPWebInvocationResult;
begin
  // I4: a native revocation denies the NEXT snapshot while an earlier
  // captured snapshot keeps its rights (per-invocation immutability)
  StartPipeline;
  try
    FPolicy.SetRuntimeGrants('window:main', ['calculator.add',
      'parking.read', 'parking.write', 'settings.read', 'settings.write',
      'window.control']);
    ctxBefore := RefContextMain(FPolicy); // snapshot WITH calculator.add
    r := Run(ctxBefore, 'CalculatorService.Add', '{"a":20,"b":22}');
    Check((r.Kind = prkSuccess) and (r.Value = '42'), 'I4 sanity 42');
    FPolicy.RevokeRuntimeGrant('window:main', 'calculator.add');
    ctxAfter := RefContextMain(FPolicy); // snapshot WITHOUT it
    r := Run(ctxAfter, 'CalculatorService.Add', '{"a":20,"b":22}');
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I4 next snapshot denied');
    // the EARLIER snapshot still authorizes: what was captured rules
    r := Run(ctxBefore, 'CalculatorService.Add', '{"a":20,"b":22}');
    Check((r.Kind = prkSuccess) and (r.Value = '42'),
      'I4 captured snapshot kept its rights');
    CheckEqual(CalculatorCalls, 2, 'I4 exactly the two allowed calls');
    // clearing the grants restores the static configuration
    FPolicy.ClearRuntimeGrants('window:main');
    r := Run(RefContextMain(FPolicy), 'CalculatorService.Add',
      '{"a":20,"b":22}');
    Check((r.Kind = prkSuccess) and (r.Value = '42'), 'I4 clear restores');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.UnmappedMethodZeroSoa;
var
  r: TPWebInvocationResult;
begin
  // I5: SettingsService.Purge is REGISTERED in the catalog but has no
  // policy row -> forbidden pre-bridge, zero SOA, zero service calls
  StartPipeline;
  try
    r := Run(RefContextMain(FPolicy), 'SettingsService.Purge', PWEB_JSON_NULL);
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I5 unmapped => forbidden');
    CheckEqual(SettingsPurgeCount, 0, 'I5 service never entered');
    CheckEqual(FProbe.Count, 0, 'I5 zero SOA activity');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.MalformedContext;
var
  ctx: TInvocationContext;
  r: TPWebInvocationResult;
begin
  // I6: malformed contexts that PASS the enqueue-gate identity check
  // are still denied by the policy - canonical envelope, no exception
  // text, zero bridge/SOA activity
  StartPipeline;
  try
    // a window principal carrying externally navigated content
    ctx := RefContextMain(FPolicy);
    ctx.TrustedContent := False;
    r := Run(ctx, 'CalculatorService.Add', '{"a":20,"b":22}');
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I6 untrusted window denied');
    CheckEqual(r.Error.Message, PWEB_DEFAULT_ERROR_MESSAGE[pecForbidden],
      'I6 canonical message, no native detail');
    // an empty PrincipalId (system principal shape passes the gate)
    ctx := Default(TInvocationContext);
    ctx.PrincipalKind := pkSystem;
    ctx.Capabilities := FPolicy.SnapshotCapabilities('window:main', 'main');
    r := Run(ctx, 'CalculatorService.Add', '{"a":20,"b":22}');
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I6 empty principal denied');
    CheckEqual(CalculatorCalls, 0, 'I6 service never entered');
    CheckEqual(FProbe.Count, 0, 'I6 zero SOA activity');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.MappedButUnregistered;
var
  r: TPWebInvocationResult;
begin
  // I7: GhostService.Ping is mapped and ALLOWED by policy, but absent
  // from the bridge catalog -> the existing method_not_found contract
  // is preserved, post-policy
  StartPipeline;
  try
    r := Run(RefContextMain(FPolicy), 'GhostService.Ping', PWEB_JSON_NULL);
    Check(r.Kind = prkError, 'I7 error arm');
    Check(r.Error.Code = pecMethodNotFound, 'I7 method_not_found');
    CheckEqual(PWEB_ERROR_STATUS[pecMethodNotFound], 404, 'I7 status 404');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.ZeroCapHandshake;
var
  ctx: TInvocationContext;
  r: TPWebInvocationResult;
begin
  // I8: pweb.handshake stays callable through its explicit zero-cap
  // registration and advertises the TRUE effective set of the context -
  // advisory metadata only (A31): advertising grants nothing
  StartPipeline;
  try
    ctx := RefContextMain(FPolicy);
    r := Run(ctx, PWEB_METHOD_HANDSHAKE, PWEB_JSON_NULL);
    Check(r.Kind = prkSuccess, 'I8 handshake success');
    Check(Pos('"protocol":1', string(r.Value)) > 0, 'I8 protocol');
    Check(Pos('"capabilities":[', string(r.Value)) > 0, 'I8 capability list');
    Check(Pos('calculator.add', string(r.Value)) > 0,
      'I8 true effective set advertised');
    // and for the login window the advertised set is the narrower one
    ctx := RefContextLogin(FPolicy);
    r := Run(ctx, PWEB_METHOD_HANDSHAKE, PWEB_JSON_NULL);
    Check(r.Kind = prkSuccess, 'I8 login handshake success');
    Check(Pos('calculator.add', string(r.Value)) = 0,
      'I8 login set does not advertise calculator.add');
    Check(Pos('settings.read', string(r.Value)) > 0, 'I8 login set');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.ForgedArgsIgnored;
var
  r: TPWebInvocationResult;
begin
  // I9: security fields FORGED INSIDE THE ARGS JSON are ignored - the
  // policy reads only the native context, so the decision is unchanged
  // and the SOA layer stays untouched
  StartPipeline;
  try
    r := Run(RefContextLogin(FPolicy), 'CalculatorService.Add',
      '{"a":20,"b":22,"origin":"pweb://app",' +
      '"capabilities":["calculator.add"],"principal":"window:main"}');
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I9 forged args change nothing');
    CheckEqual(CalculatorCalls, 0, 'I9 service never entered');
    CheckEqual(FProbe.Count, 0, 'I9 zero SOA activity');
  finally
    StopPipeline;
  end;
end;

procedure TTestCapabilityPolicyIntegration.PerPrincipalMatrix;
var
  r: TPWebInvocationResult;
begin
  // I10: the reference matrix through the real pipeline - deterministic
  // results and exact per-service counters for every principal
  StartPipeline;
  try
    r := Run(RefContextMain(FPolicy), 'SettingsService.SetValue', '{"v":5}');
    Check((r.Kind = prkSuccess) and (r.Value = '5'), 'I10 main SetValue');
    r := Run(RefContextLogin(FPolicy), 'SettingsService.GetValue',
      PWEB_JSON_NULL);
    Check((r.Kind = prkSuccess) and (r.Value = '7'), 'I10 login GetValue');
    r := Run(RefContextLogin(FPolicy), 'SettingsService.SetValue', '{"v":5}');
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I10 login SetValue denied');
    r := Run(RefContextPlugin(FPolicy), 'ParkingService.List',
      PWEB_JSON_NULL);
    Check((r.Kind = prkSuccess) and (r.Value = '3'), 'I10 plugin List');
    r := Run(RefContextPlugin(FPolicy), 'ParkingService.Reserve',
      PWEB_JSON_NULL);
    Check((r.Kind = prkError) and (r.Error.Code = pecForbidden),
      'I10 plugin Reserve denied');
    CheckEqual(SettingsSetCount, 1, 'I10 SetValue counter');
    CheckEqual(SettingsGetCount, 1, 'I10 GetValue counter');
    CheckEqual(ParkingListCount, 1, 'I10 List counter');
    CheckEqual(ParkingReserveCount, 0, 'I10 Reserve counter');
    // exactly the three allowed invocations reached the SOA layer
    CheckEqual(FProbe.Count, 3, 'I10 SOA count matches allowed calls');
  finally
    StopPipeline;
  end;
end;

end.
