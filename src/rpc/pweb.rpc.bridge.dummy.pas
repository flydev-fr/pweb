{
  pweb.rpc.bridge.dummy - deterministic test/dummy IInvocationBridge
  (Phase 2 / CAP-2).

  Shared by the headless test suite and the runtime example; lives
  OUTSIDE the raw binding layer (src/lib stays mORMot-free and
  webview-only) and outside the scheduler. It exists so CAP-2 can prove
  the whole pipeline - scheduler, policy call site, completion,
  lifecycle - without any mORMot service routing, which is Phase 3.

  Scripted behavior, keyed by the canonical method:
    pweb.echo   - Success arm echoing Args verbatim (the ratified
                  Phase 2 runtime-reserved test method).
    test.fail   - scripted service_error with a domain data payload
                  (the sanctioned application error channel).
    test.raise  - raises a Pascal exception on demand; the scheduler
                  worker must map it to internal_error without leaking
                  any detail.
    test.delay  - sleeps DelayMs in small slices, observing the
                  cooperative cancellation token; cancelled -> Error
                  arm with pecCancelled, else Success echoing Args.
    test.block  - blocks until OpenGate or cancellation; used to hold
                  worker slots deterministically. If the 30s safety cap
                  expires without OpenGate it fails loudly with a
                  scripted service_error (domainCode block_timeout).
    anything else -> method_not_found (routing is the bridge's duty;
                  policy ran before it, so forbidden outranks this).

  All methods are Service.Method-grammar valid. Instances are safe for
  concurrent worker calls and record every invocation (method, args,
  thread id) plus a concurrency high-water mark for the tests.
}
unit pweb.rpc.bridge.dummy;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  pweb.rpc.intf,
  pweb.rpc.support; // neutral helpers only - no concrete-scheduler coupling

const
  PWEB_DUMMY_METHOD_ECHO  = PWEB_METHOD_ECHO; // 'pweb.echo'
  PWEB_DUMMY_METHOD_FAIL  = 'test.fail';
  PWEB_DUMMY_METHOD_RAISE = 'test.raise';
  PWEB_DUMMY_METHOD_DELAY = 'test.delay';
  PWEB_DUMMY_METHOD_BLOCK = 'test.block';

  { upper bound of a test.block wait so a broken test cannot hang a
    worker forever; cancellation or OpenGate normally ends it long
    before }
  PWEB_DUMMY_BLOCK_CAP_MS = 30000;

type
  /// one recorded bridge invocation, for test assertions
  // - Context is a deep copy of what the worker handed the bridge, so
  //   tests can verify the native snapshot travelled intact
  TPWebDummyInvokeRecord = record
    Method: Utf8String;
    Args: TPWebJson;
    ThreadId: TThreadID;
    Context: TInvocationContext;
  end;

  /// deterministic scripted IInvocationBridge for tests and examples
  TDummyInvocationBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FLock: TCriticalSection;
    { the test.block gate is a polled flag, NOT an FPC syncobjs event:
      TEventObject.WaitFor is broken (wrError) on the pinned FPC 3.2.2
      Windows toolchain, and a flag polled in short slices is fully
      deterministic for tests anyway }
    FGateOpen: LongInt;
    FRecords: array of TPWebDummyInvokeRecord;
    FDelayMs: Integer;
    FCurrent: LongInt;          // in-flight Invoke calls right now
    FPeak: LongInt;             // high-water mark of FCurrent
    function WaitObservingToken(const Token: ICancellationToken;
      ATotalMs: Integer; AGated: Boolean): Boolean; // True = cancelled
  public
    constructor Create;
    destructor Destroy; override;
    // IInvocationBridge
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    /// release every test.block invocation currently (or later) waiting
    procedure OpenGate;
    /// re-arm the gate so subsequent test.block invocations wait again
    procedure CloseGate;
    /// number of Invoke calls that reached this bridge so far
    function InvokeCount: Integer;
    /// snapshot of one recorded invocation (0-based, in arrival order)
    function RecordedInvoke(AIndex: Integer): TPWebDummyInvokeRecord;
    /// Invoke calls executing right now
    function CurrentConcurrent: Integer;
    /// highest number of simultaneous Invoke calls observed
    function PeakConcurrent: Integer;
    /// duration of test.delay, in milliseconds
    property DelayMs: Integer read FDelayMs write FDelayMs;
  end;

implementation

constructor TDummyInvocationBridge.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDelayMs := 50;
end;

destructor TDummyInvocationBridge.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TDummyInvocationBridge.OpenGate;
begin
  InterlockedExchange(FGateOpen, 1);
end;

procedure TDummyInvocationBridge.CloseGate;
begin
  InterlockedExchange(FGateOpen, 0);
end;

function TDummyInvocationBridge.InvokeCount: Integer;
begin
  FLock.Enter;
  Result := Length(FRecords);
  FLock.Leave;
end;

function TDummyInvocationBridge.RecordedInvoke(
  AIndex: Integer): TPWebDummyInvokeRecord;
begin
  FLock.Enter;
  try
    if (AIndex < 0) or (AIndex >= Length(FRecords)) then
    begin
      Result := Default(TPWebDummyInvokeRecord);
      exit;
    end;
    Result := FRecords[AIndex];
  finally
    FLock.Leave;
  end;
end;

function TDummyInvocationBridge.CurrentConcurrent: Integer;
begin
  Result := FCurrent;
end;

function TDummyInvocationBridge.PeakConcurrent: Integer;
begin
  Result := FPeak;
end;

function TDummyInvocationBridge.WaitObservingToken(
  const Token: ICancellationToken; ATotalMs: Integer;
  AGated: Boolean): Boolean;
var
  waited: Integer;
begin
  Result := False;
  waited := 0;
  while waited < ATotalMs do
  begin
    if (Token <> nil) and Token.IsCancelled then
      exit(True); // cooperative: stop early, nothing forcibly aborted
    // atomic read (Item-6 idiom): the gate is opened from another
    // thread; a stale plain load could stall the poll on weak targets
    if AGated and (PWebAtomicRead(FGateOpen) <> 0) then
      exit(False);
    Sleep(5);
    Inc(waited, 5);
  end;
  // timeout: for the gate flavor treat like release; for delay it is
  // simply the elapsed duration
  if (Token <> nil) and Token.IsCancelled then
    Result := True;
end;

function TDummyInvocationBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  cur: LongInt;
  n: Integer;
begin
  cur := InterlockedIncrement(FCurrent);
  FLock.Enter;
  try
    if cur > FPeak then
      FPeak := cur;
    n := Length(FRecords);
    SetLength(FRecords, n + 1);
    FRecords[n].Method := Method;
    FRecords[n].Args := Args;
    FRecords[n].ThreadId := GetCurrentThreadId;
    FRecords[n].Context := PWebCopyContext(Context);
  finally
    FLock.Leave;
  end;
  try
    if Method = PWEB_DUMMY_METHOD_ECHO then
      Result := PWebSuccessResult(Args)
    else if Method = PWEB_DUMMY_METHOD_FAIL then
      Result := PWebErrorResult(pecServiceError, 'Scripted service failure',
        '{"domainCode":"scripted"}')
    else if Method = PWEB_DUMMY_METHOD_RAISE then
      raise Exception.Create('dummy bridge raise-on-demand marker')
    else if Method = PWEB_DUMMY_METHOD_DELAY then
    begin
      if WaitObservingToken(Token, FDelayMs, {gated=}False) then
        Result := PWebDefaultErrorResult(pecCancelled)
      else
        Result := PWebSuccessResult(Args);
    end
    else if Method = PWEB_DUMMY_METHOD_BLOCK then
    begin
      if WaitObservingToken(Token, PWEB_DUMMY_BLOCK_CAP_MS, {gated=}True) then
        Result := PWebDefaultErrorResult(pecCancelled)
      else if PWebAtomicRead(FGateOpen) = 0 then // Item-6 atomic read
        // the 30s safety cap expired without OpenGate: fail LOUDLY so a
        // test that forgot to release the gate cannot pass slowly
        Result := PWebErrorResult(pecServiceError,
          'dummy bridge test.block cap expired without OpenGate',
          '{"domainCode":"block_timeout"}')
      else
        Result := PWebSuccessResult(Args);
    end
    else
      Result := PWebDefaultErrorResult(pecMethodNotFound);
  finally
    InterlockedDecrement(FCurrent);
  end;
end;

end.
