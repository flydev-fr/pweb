unit pweb.test.mormot.fixture;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.interfaces,
  mormot.orm.core,
  mormot.rest.core,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.rpc.intf;

const
  BOOM_MARKER = 'CAP3-Boom-secret-path-C:\private\service.pas';

type
  ICalculatorService = interface(IInvokable)
    ['{5F289F72-8F30-4E51-91C7-7DB602905A4B}']
    function Add(a, b: Integer): Integer;
    function NoArgs: Integer;
    function NullValue: RawJson;
    function DomainFailure: TServiceCustomAnswer;
    function Boom: Integer;
    function SlowAdd(a, b, delayMs: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
    function NoArgs: Integer;
    function NullValue: RawJson;
    function DomainFailure: TServiceCustomAnswer;
    function Boom: Integer;
    function SlowAdd(a, b, delayMs: Integer): Integer;
  end;

  Ipweb = interface(IInvokable)
    ['{1F4A1711-B3B1-45F0-8C43-F06E40979C25}']
    function Hidden: Integer;
  end;

  TPwebShadow = class(TInterfacedObject, Ipweb)
  public
    function Hidden: Integer;
  end;

  TUriProbe = class
  private
    FCount: LongInt;
  public
    function BeforeUri(Ctxt: TRestServerUriContext): Boolean;
    function Count: Integer;
  end;

  TFixedCancellationToken = class(TInterfacedObject, ICancellationToken)
  private
    FCancelled: Boolean;
  public
    constructor Create(ACancelled: Boolean);
    function IsCancelled: Boolean;
  end;

  TSecondReadCancellationToken = class(TInterfacedObject, ICancellationToken)
  private
    FReads: LongInt;
  public
    function IsCancelled: Boolean;
  end;

function NewCalculatorServer(out AProbe: TUriProbe): TRestServerFullMemory;
function NewPwebShadowServer: TRestServerFullMemory;
procedure ResetCalculatorState;
function CalculatorCalls: Integer;
function CalculatorLastThreadId: Cardinal;
function CalculatorPeakConcurrent: Integer;
function CalculatorActive: Integer;
function CalculatorServerDestroyCount: Integer;

implementation

var
  GCalls: LongInt;
  GLastThreadId: LongInt;
  GActive: LongInt;
  GPeak: LongInt;
  GServerDestroyCount: LongInt;

type
  TTrackedCalculatorServer = class(TRestServerFullMemory)
  public
    destructor Destroy; override;
  end;

destructor TTrackedCalculatorServer.Destroy;
begin
  InterlockedIncrement(GServerDestroyCount);
  inherited Destroy;
end;

procedure RecordCall;
begin
  InterlockedIncrement(GCalls);
  InterlockedExchange(GLastThreadId, LongInt(GetCurrentThreadId));
end;

procedure RecordPeak(AValue: LongInt);
var
  old: LongInt;
begin
  repeat
    old := InterlockedCompareExchange(GPeak, 0, 0);
    if AValue <= old then
      exit;
  until InterlockedCompareExchange(GPeak, AValue, old) = old;
end;

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  RecordCall;
  Result := a + b;
end;

function TCalculatorService.NoArgs: Integer;
begin
  RecordCall;
  Result := 7;
end;

function TCalculatorService.NullValue: RawJson;
begin
  RecordCall;
  Result := 'null';
end;

function TCalculatorService.DomainFailure: TServiceCustomAnswer;
begin
  RecordCall;
  Result.Header := JSON_CONTENT_TYPE_HEADER;
  Result.Content := '{"domainCode":"calculator_rejected","retryable":false}';
  Result.Status := HTTP_UNPROCESSABLE_CONTENT;
end;

function TCalculatorService.Boom: Integer;
begin
  RecordCall;
  Result := 0;
  raise Exception.Create(BOOM_MARKER);
end;

function TCalculatorService.SlowAdd(a, b, delayMs: Integer): Integer;
var
  active: LongInt;
begin
  RecordCall;
  active := InterlockedIncrement(GActive);
  RecordPeak(active);
  try
    Sleep(delayMs);
    Result := a + b;
  finally
    InterlockedDecrement(GActive);
  end;
end;

function TPwebShadow.Hidden: Integer;
begin
  Result := 1;
end;

function TUriProbe.BeforeUri(Ctxt: TRestServerUriContext): Boolean;
begin
  InterlockedIncrement(FCount);
  Result := True;
end;

function TUriProbe.Count: Integer;
begin
  Result := InterlockedCompareExchange(FCount, 0, 0);
end;

constructor TFixedCancellationToken.Create(ACancelled: Boolean);
begin
  inherited Create;
  FCancelled := ACancelled;
end;

function TFixedCancellationToken.IsCancelled: Boolean;
begin
  Result := FCancelled;
end;

function TSecondReadCancellationToken.IsCancelled: Boolean;
begin
  Result := InterlockedIncrement(FReads) >= 2;
end;

function NewCalculatorServer(out AProbe: TUriProbe): TRestServerFullMemory;
var
  factory: TServiceFactoryServerAbstract;
  probe: TUriProbe;
  server: TRestServerFullMemory;
begin
  AProbe := TUriProbe.Create;
  probe := AProbe;
  Result := TTrackedCalculatorServer.CreateWithOwnModel([]);
  server := Result;
  try
    factory := Result.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register ICalculatorService');
    server.OnBeforeUri := probe.BeforeUri;
  except
    Result.Free;
    AProbe.Free;
    raise;
  end;
end;

function NewPwebShadowServer: TRestServerFullMemory;
begin
  Result := TRestServerFullMemory.CreateWithOwnModel([]);
  try
    if Result.ServiceRegister(TPwebShadow, [TypeInfo(Ipweb)], sicShared) = nil then
      raise Exception.Create('unable to register Ipweb');
  except
    Result.Free;
    raise;
  end;
end;

procedure ResetCalculatorState;
begin
  GCalls := 0;
  GLastThreadId := 0;
  GActive := 0;
  GPeak := 0;
end;

function CalculatorCalls: Integer;
begin
  Result := InterlockedCompareExchange(GCalls, 0, 0);
end;

function CalculatorLastThreadId: Cardinal;
begin
  Result := Cardinal(InterlockedCompareExchange(GLastThreadId, 0, 0));
end;

function CalculatorPeakConcurrent: Integer;
begin
  Result := InterlockedCompareExchange(GPeak, 0, 0);
end;

function CalculatorActive: Integer;
begin
  Result := InterlockedCompareExchange(GActive, 0, 0);
end;

function CalculatorServerDestroyCount: Integer;
begin
  Result := InterlockedCompareExchange(GServerDestroyCount, 0, 0);
end;

end.
