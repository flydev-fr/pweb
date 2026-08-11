unit pweb.test.mormot.integration;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.test,
  mormot.rest.memserver,
  pweb.rpc.intf,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities,
  pweb.test.scheduler,
  pweb.test.mormot.fixture;

type
  TTestMormotIntegration = class(TSynTestCase)
  published
    procedure SchedulerWorkerPipeline;
    procedure PolicyRemainsOutsideBridge;
    procedure ConcurrentWorkerDispatch;
    procedure ShutdownDrainsServerLifetime;
    procedure BridgeServerOwnership;
  end;

implementation

procedure TTestMormotIntegration.SchedulerWorkerPipeline;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  policyObj: TRecordingAllowPolicy;
  policy: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
begin
  ResetCalculatorState;
  server := NewCalculatorServer(probe);
  scheduler := nil;
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    policyObj := TRecordingAllowPolicy.Create;
    policy := policyObj;
    scheduler := TInvocationScheduler.Create(policy, bridge, 2);
    schedulerRef := scheduler;
    limits.MaxConcurrent := 2;
    limits.MaxQueueSize := 8;
    source := scheduler.RegisterSource(limits);
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(TestContext, 'CalculatorService.Add',
      '{"a":20,"b":22}', sinkRef) = perAccepted);
    Check(sink.WaitDone(5000));
    Check((sink.First.Kind = prkSuccess) and (sink.First.Value = '42'));
    CheckEqual(policyObj.Seen(0), 'CalculatorService.Add');
    Check(CalculatorLastThreadId <> GetCurrentThreadId,
      'real service ran on the test/GUI thread');
    scheduler.Shutdown;
  finally
    if scheduler <> nil then
      scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    scheduler := nil;
    policy := nil;
    bridge := nil;
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotIntegration.ShutdownDrainsServerLifetime;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
  waited: Integer;
begin
  ResetCalculatorState;
  server := NewCalculatorServer(probe);
  scheduler := nil;
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    scheduler := TInvocationScheduler.Create(
      TAllowAllCapabilityPolicy.Create, bridge, 1);
    schedulerRef := scheduler;
    limits.MaxConcurrent := 1;
    limits.MaxQueueSize := 2;
    source := scheduler.RegisterSource(limits);
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(TestContext, 'CalculatorService.SlowAdd',
      '{"a":20,"b":22,"delayMs":200}', sinkRef) = perAccepted);
    waited := 0;
    while (CalculatorActive = 0) and (waited < 5000) do
    begin
      Sleep(5);
      Inc(waited, 5);
    end;
    Check(CalculatorActive = 1, 'SlowAdd never entered service');
    scheduler.Shutdown; // must wait for Uri() before bridge/server release
    CheckEqual(CalculatorActive, 0);
    CheckEqual(CalculatorCalls, 1);
    Check(sink.WaitDone(1000));
    Check((sink.First.Kind = prkError) and
      (sink.First.Error.Code = pecCancelled));
    CheckEqual(sink.CompleteCount, 1);
    bridge := nil; // owned server is freed only after the drain above
  finally
    if scheduler <> nil then
      scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    scheduler := nil;
    bridge := nil;
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotIntegration.BridgeServerOwnership;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  before: Integer;
begin
  before := CalculatorServerDestroyCount;
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, False);
    bridge := nil;
    CheckEqual(CalculatorServerDestroyCount, before,
      'non-owned server was destroyed by bridge');
    server.Free;
    server := nil;
    CheckEqual(CalculatorServerDestroyCount, before + 1);
  finally
    bridge := nil;
    server.Free;
    probe.Free;
  end;

  before := CalculatorServerDestroyCount;
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    bridge := nil;
    CheckEqual(CalculatorServerDestroyCount, before + 1,
      'owned server was not destroyed with bridge');
  finally
    bridge := nil;
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotIntegration.PolicyRemainsOutsideBridge;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
begin
  ResetCalculatorState;
  server := NewCalculatorServer(probe);
  scheduler := nil;
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    scheduler := TInvocationScheduler.Create(TDenyAllPolicy.Create, bridge, 1);
    schedulerRef := scheduler;
    limits.MaxConcurrent := 1;
    limits.MaxQueueSize := 2;
    source := scheduler.RegisterSource(limits);
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(TestContext, 'CalculatorService.Add',
      '{"a":20,"b":22}', sinkRef) = perAccepted);
    Check(sink.WaitDone(5000));
    Check((sink.First.Kind = prkError) and
      (sink.First.Error.Code = pecForbidden));
    CheckEqual(CalculatorCalls, 0);
    CheckEqual(probe.Count, 0);
  finally
    if scheduler <> nil then
      scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    scheduler := nil;
    bridge := nil;
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotIntegration.ConcurrentWorkerDispatch;
const
  N = 8;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sinks: array[0..N - 1] of TTestCompletion;
  sinkRefs: array[0..N - 1] of IInvocationCompletion;
  limits: TPWebSourceLimits;
  i: Integer;
begin
  ResetCalculatorState;
  server := NewCalculatorServer(probe);
  scheduler := nil;
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    scheduler := TInvocationScheduler.Create(
      TAllowAllCapabilityPolicy.Create, bridge, 4);
    schedulerRef := scheduler;
    limits.MaxConcurrent := N;
    limits.MaxQueueSize := N;
    source := scheduler.RegisterSource(limits);
    for i := 0 to N - 1 do
    begin
      sinks[i] := TTestCompletion.Create;
      sinkRefs[i] := sinks[i];
      Check(source.TryEnqueue(TestContext, 'CalculatorService.SlowAdd',
        '{"a":20,"b":22,"delayMs":50}', sinkRefs[i]) = perAccepted);
    end;
    for i := 0 to N - 1 do
    begin
      Check(sinks[i].WaitDone(5000));
      Check((sinks[i].First.Kind = prkSuccess) and
        (sinks[i].First.Value = '42'));
    end;
    Check(CalculatorPeakConcurrent >= 2, 'real Uri calls did not overlap');
    Check(CalculatorLastThreadId <> GetCurrentThreadId);
  finally
    if scheduler <> nil then
      scheduler.Shutdown;
    source := nil;
    for i := 0 to N - 1 do
      sinkRefs[i] := nil;
    schedulerRef := nil;
    scheduler := nil;
    bridge := nil;
    server.Free;
    probe.Free;
  end;
end;

end.
