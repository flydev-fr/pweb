unit pweb.test.mormot.routing;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.test,
  mormot.rest.memserver,
  pweb.rpc.intf,
  pweb.rpc.mormot,
  pweb.test.scheduler,
  pweb.test.mormot.fixture;

type
  TTestMormotRouting = class(TSynTestCase)
  published
    procedure ExactCaseCatalog;
    procedure ReservedNamespace;
    procedure InvalidMethodShape;
  end;

implementation

procedure TTestMormotRouting.ExactCaseCatalog;
const
  BAD: array[0..4] of Utf8String = (
    'calculatorservice.Add', 'CalculatorService.add',
    'CALCULATORSERVICE.ADD', 'NoSuchService.Add', 'CalculatorService.Nope');
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
  i: Integer;
begin
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    for i := 0 to High(BAD) do
    begin
      r := bridge.Invoke(TestContext, BAD[i], '{"a":20,"b":22}', nil);
      Check((r.Kind = prkError) and (r.Error.Code = pecMethodNotFound));
      CheckEqual(probe.Count, 0, 'catalog rejection reached Uri');
    end;
    r := bridge.Invoke(TestContext, 'CalculatorService.Add',
      '{"a":20,"b":22}', nil);
    Check((r.Kind = prkSuccess) and (r.Value = '42'));
    CheckEqual(probe.Count, 1);
    r := bridge.Invoke(TestContext, 'pweb.nope', '{}', nil);
    Check((r.Kind = prkError) and (r.Error.Code = pecMethodNotFound));
    CheckEqual(probe.Count, 1, 'reserved runtime method reached Uri');
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
end;

procedure TTestMormotRouting.ReservedNamespace;
var
  server: TRestServerFullMemory;
  bridge: IInvocationBridge;
  raised: Boolean;
begin
  server := NewPwebShadowServer;
  raised := False;
  try
    try
      bridge := TMormotInvocationBridge.Create(server, True);
      server := nil;
    except
      raised := True;
    end;
    Check(raised, 'application pweb namespace was not refused');
  finally
    bridge := nil;
    server.Free;
  end;
end;

procedure TTestMormotRouting.InvalidMethodShape;
const
  BAD: array[0..3] of Utf8String = ('CalculatorService/Add',
    'CalculatorService.Add.More', '.Add', 'CalculatorService.');
var
  server: TRestServerFullMemory;
  probe: TUriProbe;
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
  i: Integer;
begin
  server := NewCalculatorServer(probe);
  try
    bridge := TMormotInvocationBridge.Create(server, True);
    server := nil;
    for i := 0 to High(BAD) do
    begin
      r := bridge.Invoke(TestContext, BAD[i], '{}', nil);
      Check((r.Kind = prkError) and (r.Error.Code = pecInvalidRequest));
    end;
    CheckEqual(probe.Count, 0);
    bridge := nil;
  finally
    server.Free;
    probe.Free;
  end;
end;

end.
