unit pweb.test.mormot.bridge;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.test,
  mormot.rest.memserver,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.mormot,
  pweb.test.scheduler,
  pweb.test.mormot.fixture;

type
  TTestMormotBridge = class(TSynTestCase)
  published
    procedure AddAndResultNormalization;
    procedure StrictArgumentsAndNull;
    procedure DomainAndUnexpectedErrors;
    procedure CancellationAndRuntimeMethods;
  end;

implementation

function InvokeNew(const AMethod, AArgs: Utf8String;
  const AToken: ICancellationToken = nil): TPWebInvocationResult;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
begin
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    Result := bridge.Invoke(TestContext, AMethod, AArgs, AToken);
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotBridge.AddAndResultNormalization;
var
  r: TPWebInvocationResult;
begin
  ResetCalculatorState;
  r := InvokeNew('CalculatorService.Add', '{"a":20,"b":22}');
  Check(r.Kind = prkSuccess);
  CheckEqual(r.Value, '42');
  Check(Pos('result', r.Value) = 0, 'mORMot wrapper must not escape');
  r := InvokeNew('CalculatorService.Add', '{"b":22,"a":20}');
  Check(r.Kind = prkSuccess);
  CheckEqual(r.Value, '42');
end;

procedure TTestMormotBridge.StrictArgumentsAndNull;
const
  BAD: array[0..6] of Utf8String = (
    '{"a":20}', '{"a":20,"b":22,"c":1}',
    '{"A":20,"b":22}', '{"a":"20","b":22}',
    '{"a":20,"a":21,"b":22}', '{"a":20,"b":22,}', 'not-json');
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  i, before, beforeUri: Integer;
  r: TPWebInvocationResult;
begin
  ResetCalculatorState;
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    for i := 0 to High(BAD) do
    begin
      before := CalculatorCalls;
      beforeUri := probe.Count;
      r := bridge.Invoke(TestContext, 'CalculatorService.Add', BAD[i], nil);
      Check(r.Kind = prkError);
      Check(r.Error.Code = pecInvalidRequest);
      CheckEqual(CalculatorCalls, before, 'invalid args reached service');
      CheckEqual(probe.Count, beforeUri, 'invalid args reached Uri');
    end;
    beforeUri := probe.Count;
    r := bridge.Invoke(TestContext, 'CalculatorService.Add',
      '{"a":2147483648,"b":22}', nil);
    Check((r.Kind = prkError) and (r.Error.Code = pecInvalidRequest));
    CheckEqual(probe.Count, beforeUri, 'out-of-range integer reached Uri');
    r := bridge.Invoke(TestContext, 'CalculatorService.Add', PWEB_JSON_NULL, nil);
    Check((r.Kind = prkError) and (r.Error.Code = pecInvalidRequest));
    r := bridge.Invoke(TestContext, 'CalculatorService.NoArgs', PWEB_JSON_NULL, nil);
    Check((r.Kind = prkSuccess) and (r.Value = '7'));
    r := bridge.Invoke(TestContext, 'CalculatorService.NullValue', PWEB_JSON_NULL, nil);
    Check((r.Kind = prkSuccess) and (r.Value = PWEB_JSON_NULL));
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotBridge.DomainAndUnexpectedErrors;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
begin
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    r := bridge.Invoke(TestContext, 'CalculatorService.DomainFailure',
      PWEB_JSON_NULL, nil);
    Check((r.Kind = prkError) and (r.Error.Code = pecServiceError));
    Check(Pos('calculator_rejected', r.Error.Data) > 0);
    r := bridge.Invoke(TestContext, 'CalculatorService.Boom', PWEB_JSON_NULL, nil);
    Check((r.Kind = prkError) and (r.Error.Code = pecInternalError));
    CheckEqual(r.Error.Message,
      PWEB_DEFAULT_ERROR_MESSAGE[pecInternalError]);
    CheckEqual(r.Error.Data, PWEB_JSON_NULL);
    Check(Pos('CAP3-Boom', r.Error.Message) = 0);
    Check(Pos('private', r.Error.Message) = 0);
    Check(Pos('Exception', r.Error.Message) = 0);
    r := bridge.Invoke(TestContext, 'CalculatorService.Add',
      '{"a":1,"b":2}', nil);
    Check((r.Kind = prkSuccess) and (r.Value = '3'),
      'same service/bridge did not survive Boom');
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotBridge.CancellationAndRuntimeMethods;
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  context: TInvocationContext;
  r: TPWebInvocationResult;
begin
  ResetCalculatorState;
  r := InvokeNew('CalculatorService.Add', '{"a":20,"b":22}',
    TFixedCancellationToken.Create(True));
  Check((r.Kind = prkError) and (r.Error.Code = pecCancelled));
  CheckEqual(CalculatorCalls, 0);
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    r := bridge.Invoke(TestContext, 'CalculatorService.Add',
      '{"a":20,"b":22}', TSecondReadCancellationToken.Create);
    Check((r.Kind = prkError) and (r.Error.Code = pecCancelled));
    CheckEqual(CalculatorCalls, 0);
    CheckEqual(probe.Count, 0);
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
  r := InvokeNew(PWEB_METHOD_ECHO, PWEB_JSON_NULL);
  Check((r.Kind = prkSuccess) and (r.Value = PWEB_JSON_NULL));
  r := InvokeNew(PWEB_METHOD_ECHO, '{"a":1,"a":2}');
  Check((r.Kind = prkError) and (r.Error.Code = pecInvalidRequest));
  r := InvokeNew(PWEB_METHOD_HANDSHAKE, '{}');
  Check(r.Kind = prkSuccess);
  CheckEqual(r.Value,
    '{"protocol":1,"runtime":"0.1.0","capabilities":[]}');
  context := TestContext;
  SetLength(context.Capabilities, 2);
  context.Capabilities[0] := 'files.read';
  context.Capabilities[1] := 'rpc.invoke';
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    r := bridge.Invoke(context, PWEB_METHOD_HANDSHAKE, '{}', nil);
    CheckEqual(r.Value,
      '{"protocol":1,"runtime":"0.1.0","capabilities":["files.read","rpc.invoke"]}');
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
  r := InvokeNew(PWEB_METHOD_HANDSHAKE, '[]');
  Check((r.Kind = prkError) and (r.Error.Code = pecInvalidRequest));
end;

end.
