{
  pweb.rpc.scheduler - IInvocationScheduler / IInvocationSource pool
  implementation (Phase 2 / CAP-2).

  RTL-only by ratified constraint: this unit uses classes/syncobjs and
  pweb.rpc.intf ONLY. It never references any pweb.webview.* unit - the
  scheduler is defined over invocation sources, and an embedding binding
  is only one source (threading-model.md "Invocation sources, not
  WebViews"). CI compiles this unit with no src/webview unit path to
  prove it.

  Semantics implemented here, all ratified before CAP-2:
  - TryEnqueue is the single RPC method validation/canonicalization
    gate (wire-semantics.md "One canonicalization point"): the method
    is validated exactly once, at enqueue, and the IDENTICAL canonical
    value is what ICapabilityPolicy and IInvocationBridge later
    receive. Canonical spelling is exact and case-sensitive, so
    canonicalization is validation - no case folding ever happens.
  - Enqueue is always non-blocking: full queue -> perBusy, source not
    Running -> perClosed, bad method/args grammar -> perInvalidRequest;
    the invocation never enters the queue on any of those.
  - Exactly-once completion: each accepted invocation carries a
    first-wins gate in front of its transport sink; later attempts are
    dropped silently, and the backpressure slot releases at completion
    - never at worker exit and never twice.
  - Worker order is policy THEN bridge: a policy exception is a DENY
    completed as internal_error (never fail open); a bridge exception
    completes as internal_error with no native detail leaked.
  - Lifecycle: pssRunning -> pssQuiescing -> pssClosed only. Quiesce
    refuses new invocations, cancels queued ones with a terminal
    cancelled completion, and signals cooperative cancellation to
    in-flight work which may finish. Close performs full Quiesce
    semantics first, then completes still-uncompleted in-flight
    invocations as cancelled (their late worker results die at the
    gate) and enters pssClosed. Both are non-blocking and idempotent.
  - Shutdown quiesces and closes every source, drains the worker pool
    (MAY BLOCK - never call it from the GUI thread) and is idempotent;
    a concurrent second call blocks until the first completes.

  The handle-use lease is deliberately NOT here: it protects a native
  transport handle and belongs to the embedding binding
  (pweb.webview.binding.pas), per the frozen contracts.
}
unit pweb.rpc.scheduler;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  pweb.rpc.intf;

const
  { Upper bound of the canonical method spelling, in bytes. The wire
    grammar mandates a bounded length (wire-semantics.md "Request
    grammar and limits"); the bound itself is an implementation choice
    of this gate, not wire protocol. }
  PWEB_METHOD_MAX_BYTES = 256;

  { Default number of pool workers when the caller does not choose. }
  PWEB_DEFAULT_WORKER_COUNT = 4;

  { Default human-readable message per error code. No native detail
    ever appears here (wire-semantics.md error contract). These are
    implementation defaults, not frozen wire data - the sole normative
    discriminator stays the `code` member. }
  PWEB_DEFAULT_ERROR_MESSAGE: array[TPWebErrorCode] of Utf8String = (
    'Invalid request',            // pecInvalidRequest
    'Method not found',           // pecMethodNotFound
    'Invocation is not allowed',  // pecForbidden
    'Runtime is busy',            // pecBusy
    'Invocation was cancelled',   // pecCancelled
    'Service error',              // pecServiceError
    'Internal error',             // pecInternalError
    'Runtime is closed',          // pecRuntimeClosed
    'Protocol mismatch'           // pecProtocolMismatch
  );

type
  /// raised at the RegisterSource call site for invalid limits, per the
  // frozen IInvocationScheduler contract
  EPWebSchedulerError = class(Exception);

  /// pool implementation of the frozen IInvocationScheduler contract
  TInvocationScheduler = class(TInterfacedObject, IInvocationScheduler)
  private
    FPolicy: ICapabilityPolicy;
    FBridge: IInvocationBridge;
    FLock: TCriticalSection;      // protects FSources
    FShutdownLock: TCriticalSection;
    { NOTE deliberately no syncobjs event class here: FPC 3.2.2's
      TEventObject/TSimpleEvent.WaitFor returns wrError immediately on
      this toolchain (measured); workers wake on per-worker PRTLEvents,
      which behave correctly. FWorkers is sized once at construction
      and worker OBJECTS stay alive until Destroy, so SignalWork can
      run lock-free concurrently with Shutdown. }
    FWorkers: array of TThread;
    FSources: array of TObject;   // of TSchedulerSource; interface refs held separately
    FSourceRefs: array of IInvocationSource;
    FNextSource: Integer;         // round-robin claim start index
    FShuttingDown: Integer;       // interlocked flag
    FShutdownDone: Boolean;
    procedure SignalWork;
    function ClaimNext(out AItem: TObject): Boolean;
    procedure ExecuteItem(AItem: TObject);
  public
    { APolicy and ABridge are the pipeline of every worker:
      policy -> bridge, with the identical canonical method. Both are
      required; AWorkerCount is clamped to >= 1. }
    constructor Create(const APolicy: ICapabilityPolicy;
      const ABridge: IInvocationBridge;
      AWorkerCount: Integer = PWEB_DEFAULT_WORKER_COUNT);
    destructor Destroy; override;
    // IInvocationScheduler
    function RegisterSource(const Limits: TPWebSourceLimits): IInvocationSource;
    procedure Shutdown;
    { Introspection for tests and owning runtimes - NOT part of the
      frozen contract. Returns False if ASource was not created by this
      scheduler. Counts are an instantaneous snapshot. }
    function TryGetSourceCounts(const ASource: IInvocationSource;
      out AQueued, AActive: Integer): Boolean;
  end;

{ Single canonicalization gate helpers (also used by tests). The
  canonical method grammar accepted here: 1..PWEB_METHOD_MAX_BYTES
  bytes, characters [A-Za-z0-9_.] only, at least two non-empty
  dot-separated segments (Service.Method application form; the
  runtime-reserved pweb.* form has the same shape). Case is preserved
  exactly - matching is case-sensitive downstream. }
function PWebValidMethod(const AMethod: Utf8String): Boolean;

{ Args grammar at the enqueue gate: a serialized JSON object or the
  PWEB_JSON_NULL literal - never the empty string, never an array
  (named arguments only in protocol v1). Structural check only: full
  JSON validation is the transport parser's duty. }
function PWebValidArgs(const AArgs: TPWebJson): Boolean;

{ Immutable deep-copy snapshot of a context: plain record assignment
  would share the Capabilities dynamic array reference (frozen
  TInvocationContext comment mandates Copy()). }
function PWebCopyContext(const AContext: TInvocationContext): TInvocationContext;

{ Frozen identity invariants of TInvocationContext: pkWindow implies
  WindowId <> ''; pkPlugin implies PluginId <> ''. }
function PWebValidContext(const AContext: TInvocationContext): Boolean;

{ Result constructors shared by scheduler, bridges and bindings. }
function PWebSuccessResult(const AValue: TPWebJson): TPWebInvocationResult;
function PWebErrorResult(ACode: TPWebErrorCode;
  const AMessage: Utf8String; const AData: TPWebJson = PWEB_JSON_NULL): TPWebInvocationResult;
function PWebDefaultErrorResult(ACode: TPWebErrorCode): TPWebInvocationResult;

implementation

const
  WORKER_POLL_MS = 50; // lost-wakeup safety net under the auto-reset event

{ ---------------- helpers ---------------- }

function PWebValidMethod(const AMethod: Utf8String): Boolean;
var
  i, len, dots: Integer;
  prevDot: Boolean;
  c: AnsiChar;
begin
  Result := False;
  len := Length(AMethod);
  if (len < 3) or (len > PWEB_METHOD_MAX_BYTES) then
    exit; // shortest possible Service.Method is 'a.b'
  dots := 0;
  prevDot := True; // a leading dot must fail like an empty segment
  for i := 1 to len do
  begin
    c := AnsiChar(AMethod[i]);
    if c = '.' then
    begin
      if prevDot then
        exit; // empty segment ('..' or leading '.')
      Inc(dots);
      prevDot := True;
    end
    else if c in ['A'..'Z', 'a'..'z', '0'..'9', '_'] then
      prevDot := False
    else
      exit; // NUL, slash, space, non-ASCII... - not canonical grammar
  end;
  if prevDot then
    exit; // trailing dot
  Result := dots >= 1; // at least Service.Method
end;

function PWebValidArgs(const AArgs: TPWebJson): Boolean;
var
  a, b: Integer;
begin
  if AArgs = PWEB_JSON_NULL then
    exit(True);
  a := 1;
  b := Length(AArgs);
  while (a <= b) and (AArgs[a] in [#9, #10, #13, ' ']) do
    Inc(a);
  while (b >= a) and (AArgs[b] in [#9, #10, #13, ' ']) do
    Dec(b);
  Result := (a < b) and (AArgs[a] = '{') and (AArgs[b] = '}');
end;

function PWebCopyContext(const AContext: TInvocationContext): TInvocationContext;
begin
  Result := AContext;
  Result.Capabilities := Copy(AContext.Capabilities);
  // force unique heap copies of the strings as well: the snapshot must
  // stay valid even if the caller mutates its own record afterwards
  UniqueString(Result.WindowId);
  UniqueString(Result.PrincipalId);
  UniqueString(Result.PluginId);
end;

function PWebValidContext(const AContext: TInvocationContext): Boolean;
begin
  case AContext.PrincipalKind of
    pkWindow:
      Result := AContext.WindowId <> '';
    pkPlugin:
      Result := AContext.PluginId <> '';
  else
    Result := True;
  end;
end;

function PWebSuccessResult(const AValue: TPWebJson): TPWebInvocationResult;
begin
  Result := Default(TPWebInvocationResult);
  Result.Kind := prkSuccess;
  if AValue = '' then
    Result.Value := PWEB_JSON_NULL // '' would surface as JS undefined
  else
    Result.Value := AValue;
end;

function PWebErrorResult(ACode: TPWebErrorCode;
  const AMessage: Utf8String; const AData: TPWebJson): TPWebInvocationResult;
begin
  Result := Default(TPWebInvocationResult);
  Result.Kind := prkError;
  Result.Error.Code := ACode;
  if AMessage = '' then
    Result.Error.Message := PWEB_DEFAULT_ERROR_MESSAGE[ACode]
  else
    Result.Error.Message := AMessage;
  if AData = '' then
    Result.Error.Data := PWEB_JSON_NULL
  else
    Result.Error.Data := AData;
end;

function PWebDefaultErrorResult(ACode: TPWebErrorCode): TPWebInvocationResult;
begin
  Result := PWebErrorResult(ACode, PWEB_DEFAULT_ERROR_MESSAGE[ACode]);
end;

{ ---------------- internal types ---------------- }

type
  TSchedulerToken = class(TInterfacedObject, ICancellationToken)
  private
    FCancelled: LongInt;
  public
    function IsCancelled: Boolean;
    procedure Cancel;
  end;

  TSchedulerSource = class;

  { One accepted invocation. Manually reference-counted because it is
    reachable from the pending list, the in-flight list and the
    executing worker at the same time, and any of them may be the last
    holder (e.g. Close fires the cancelled completion while a worker
    still executes the bridge call). }
  TSchedulerItem = class
  public
    Context: TInvocationContext; // immutable deep-copied snapshot
    Method: Utf8String;          // the canonical value - policy and bridge get THIS
    Args: TPWebJson;
    Completion: IInvocationCompletion;
    Token: ICancellationToken;
    Source: TSchedulerSource;    // object access; lifetime pinned via SourceRef
    SourceRef: IInvocationSource;
    FCompleted: LongInt;         // exactly-once gate
    FRefCount: LongInt;
    procedure Ref;
    procedure Unref;
    { The exactly-once completion gate: first call wins, delivers to the
      transport sink and releases the backpressure slot; later calls do
      nothing at all. }
    procedure CompleteOnce(const AResult: TPWebInvocationResult);
  end;

  TSchedulerSource = class(TInterfacedObject, IInvocationSource)
  private
    FScheduler: TInvocationScheduler; // object access; pinned via FSchedulerRef
    FSchedulerRef: IInvocationScheduler;
    FLock: TCriticalSection;
    FLimits: TPWebSourceLimits;
    FState: LongInt;                  // Ord(TPWebSourceState), interlocked reads
    FPending: TList;                  // of TSchedulerItem (list holds one ref each)
    FInFlight: TList;                 // of TSchedulerItem (list holds one ref each)
    FToken: TSchedulerToken;          // source-scoped cancellation
    FTokenRef: ICancellationToken;
    function TryClaim(out AItem: TSchedulerItem): Boolean;
    procedure ReleaseSlot(AItem: TSchedulerItem);
    procedure GetCounts(out AQueued, AActive: Integer);
  public
    constructor CreateSource(AScheduler: TInvocationScheduler;
      const ALimits: TPWebSourceLimits; AClosed: Boolean);
    destructor Destroy; override;
    // IInvocationSource
    function TryEnqueue(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Completion: IInvocationCompletion): TPWebEnqueueResult;
    procedure Quiesce;
    procedure Close;
    function State: TPWebSourceState;
  end;

  TSchedulerWorker = class(TThread)
  private
    FOwner: TInvocationScheduler;
    FWake: PRTLEvent; // single-waiter wake-up, owned by this worker
  public
    constructor Create(AOwner: TInvocationScheduler);
    destructor Destroy; override;
    procedure Execute; override;
    procedure Wake;
  end;

{ ---------------- TSchedulerToken ---------------- }

function TSchedulerToken.IsCancelled: Boolean;
begin
  Result := FCancelled <> 0;
end;

procedure TSchedulerToken.Cancel;
begin
  InterlockedExchange(FCancelled, 1);
end;

{ ---------------- TSchedulerItem ---------------- }

procedure TSchedulerItem.Ref;
begin
  InterlockedIncrement(FRefCount);
end;

procedure TSchedulerItem.Unref;
begin
  if InterlockedDecrement(FRefCount) = 0 then
    Free;
end;

procedure TSchedulerItem.CompleteOnce(const AResult: TPWebInvocationResult);
begin
  if InterlockedExchange(FCompleted, 1) <> 0 then
    exit; // a later attempt dies at the gate, silently
  try
    Completion.Complete(AResult); // sink performs its own transport-safe delivery
  except
    // the completion path must never raise into a worker or a canceller
  end;
  // the backpressure slot releases AT COMPLETION - not at worker exit -
  // and thanks to the gate above it can never release twice
  Source.ReleaseSlot(Self);
end;

{ ---------------- TSchedulerSource ---------------- }

constructor TSchedulerSource.CreateSource(AScheduler: TInvocationScheduler;
  const ALimits: TPWebSourceLimits; AClosed: Boolean);
begin
  inherited Create;
  FScheduler := AScheduler;
  FSchedulerRef := AScheduler; // pin the scheduler while any source lives
  FLimits := ALimits;
  FLock := TCriticalSection.Create;
  FPending := TList.Create;
  FInFlight := TList.Create;
  FToken := TSchedulerToken.Create;
  FTokenRef := FToken;
  if AClosed then
  begin
    FState := Ord(pssClosed); // fail-closed source after Shutdown began
    FToken.Cancel;
  end
  else
    FState := Ord(pssRunning);
end;

destructor TSchedulerSource.Destroy;
begin
  // by construction both lists are empty here: every accepted
  // invocation holds a SourceRef pinning this object until completion
  FPending.Free;
  FInFlight.Free;
  FLock.Free;
  FTokenRef := nil;
  inherited Destroy;
end;

function TSchedulerSource.TryEnqueue(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Completion: IInvocationCompletion): TPWebEnqueueResult;
var
  item: TSchedulerItem;
begin
  if FState <> Ord(pssRunning) then
    exit(perClosed);
  // the single method canonicalization/validation gate - shared by all
  // sources; the exact input spelling IS the canonical value
  if not PWebValidMethod(Method) then
    exit(perInvalidRequest);
  if not PWebValidArgs(Args) then
    exit(perInvalidRequest);
  if Completion = nil then
    exit(perInvalidRequest);
  if not PWebValidContext(Context) then
    exit(perInvalidRequest);
  item := TSchedulerItem.Create;
  item.FRefCount := 1; // owned by the pending list on success
  item.Context := PWebCopyContext(Context); // immutable snapshot, kept alive by the item
  item.Method := Method;
  UniqueString(item.Method); // the identical canonical value for policy AND bridge
  item.Args := Args;
  UniqueString(item.Args);
  item.Completion := Completion;
  item.Token := FTokenRef;
  item.Source := Self;
  item.SourceRef := Self; // pins this source until the item completes
  FLock.Enter;
  try
    if FState <> Ord(pssRunning) then
    begin
      FLock.Leave;
      item.SourceRef := nil; // break the pin before dropping
      item.Unref;
      exit(perClosed);
    end;
    if FPending.Count >= FLimits.MaxQueueSize then
    begin
      FLock.Leave;
      item.SourceRef := nil;
      item.Unref;
      exit(perBusy); // never blocks, never waits for capacity
    end;
    FPending.Add(item);
  except
    FLock.Leave;
    raise;
  end;
  FLock.Leave;
  FScheduler.SignalWork;
  Result := perAccepted;
end;

function TSchedulerSource.TryClaim(out AItem: TSchedulerItem): Boolean;
begin
  Result := False;
  AItem := nil;
  FLock.Enter;
  try
    if (FState = Ord(pssRunning)) and (FPending.Count > 0) and
       (FInFlight.Count < FLimits.MaxConcurrent) then
    begin
      AItem := TSchedulerItem(FPending[0]);
      FPending.Delete(0);       // list ref transfers to FInFlight
      FInFlight.Add(AItem);
      AItem.Ref;                // worker's own reference
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TSchedulerSource.ReleaseSlot(AItem: TSchedulerItem);
var
  idx: Integer;
  released: Boolean;
begin
  released := False;
  FLock.Enter;
  try
    idx := FInFlight.IndexOf(AItem);
    if idx >= 0 then
    begin
      FInFlight.Delete(idx);
      released := True;
    end
    else
    begin
      idx := FPending.IndexOf(AItem);
      if idx >= 0 then
      begin
        FPending.Delete(idx);
        released := True;
      end;
    end;
  finally
    FLock.Leave;
  end;
  if released then
  begin
    FScheduler.SignalWork; // a freed slot may let queued work start
    AItem.Unref;           // drop the list's reference
  end;
end;

procedure TSchedulerSource.GetCounts(out AQueued, AActive: Integer);
begin
  FLock.Enter;
  AQueued := FPending.Count;
  AActive := FInFlight.Count;
  FLock.Leave;
end;

procedure TSchedulerSource.Quiesce;
var
  cancelled: array of TSchedulerItem;
  i: Integer;
  r: TPWebInvocationResult;
begin
  FLock.Enter;
  if FState <> Ord(pssRunning) then
  begin
    FLock.Leave; // idempotent: no effect once past pssRunning
    exit;
  end;
  InterlockedExchange(FState, Ord(pssQuiescing)); // refuse new invocations now
  SetLength(cancelled, FPending.Count);
  for i := 0 to FPending.Count - 1 do
    cancelled[i] := TSchedulerItem(FPending[i]); // list ref transfers to the array
  FPending.Clear;
  FLock.Leave;
  FToken.Cancel; // cooperative cancellation for in-flight work, which may finish
  r := PWebDefaultErrorResult(pecCancelled);
  for i := 0 to High(cancelled) do
  begin
    cancelled[i].CompleteOnce(r); // terminal completion for every queued invocation
    cancelled[i].Unref;
  end;
end;

procedure TSchedulerSource.Close;
var
  inflight: array of TSchedulerItem;
  i: Integer;
  r: TPWebInvocationResult;
begin
  Quiesce; // Running -> Quiescing first; there is no direct Running -> Closed
  FLock.Enter;
  if FState = Ord(pssClosed) then
  begin
    FLock.Leave; // idempotent
    exit;
  end;
  SetLength(inflight, FInFlight.Count);
  for i := 0 to FInFlight.Count - 1 do
  begin
    inflight[i] := TSchedulerItem(FInFlight[i]);
    inflight[i].Ref; // extra ref: CompleteOnce->ReleaseSlot removes the list ref
  end;
  FLock.Leave;
  // complete still-uncompleted in-flight invocations as cancelled while
  // the transport can still deliver (state is pssQuiescing here); their
  // late worker results will die at the exactly-once gate
  r := PWebDefaultErrorResult(pecCancelled);
  for i := 0 to High(inflight) do
  begin
    inflight[i].CompleteOnce(r);
    inflight[i].Unref;
  end;
  InterlockedExchange(FState, Ord(pssClosed));
end;

function TSchedulerSource.State: TPWebSourceState;
begin
  Result := TPWebSourceState(FState); // advisory snapshot per contract
end;

{ ---------------- TSchedulerWorker ---------------- }

constructor TSchedulerWorker.Create(AOwner: TInvocationScheduler);
begin
  FOwner := AOwner;
  FWake := RTLEventCreate;
  inherited Create({suspended=}False);
end;

destructor TSchedulerWorker.Destroy;
begin
  inherited Destroy; // joins the thread first
  RTLEventDestroy(FWake);
end;

procedure TSchedulerWorker.Wake;
begin
  RTLEventSetEvent(FWake);
end;

procedure TSchedulerWorker.Execute;
var
  item: TObject;
begin
  while not Terminated do
    try
      if FOwner.ClaimNext(item) then
      begin
        try
          FOwner.ExecuteItem(item);
        finally
          TSchedulerItem(item).Unref;
        end;
      end
      else
        RTLEventWaitFor(FWake, WORKER_POLL_MS); // poll bound = lost-wakeup net
    except
      // worker threads never die on a stray exception; per-invocation
      // failures were already completed as internal_error downstream
    end;
end;

{ ---------------- TInvocationScheduler ---------------- }

constructor TInvocationScheduler.Create(const APolicy: ICapabilityPolicy;
  const ABridge: IInvocationBridge; AWorkerCount: Integer);
var
  i: Integer;
begin
  inherited Create;
  if APolicy = nil then
    raise EPWebSchedulerError.Create('TInvocationScheduler.Create: policy is required');
  if ABridge = nil then
    raise EPWebSchedulerError.Create('TInvocationScheduler.Create: bridge is required');
  FPolicy := APolicy;
  FBridge := ABridge;
  FLock := TCriticalSection.Create;
  FShutdownLock := TCriticalSection.Create;
  if AWorkerCount < 1 then
    AWorkerCount := 1;
  SetLength(FWorkers, AWorkerCount);
  for i := 0 to AWorkerCount - 1 do
    FWorkers[i] := TSchedulerWorker.Create(Self);
end;

destructor TInvocationScheduler.Destroy;
var
  i: Integer;
begin
  Shutdown; // safety net; normally the owner already called it off-GUI
  for i := 0 to High(FWorkers) do
    FWorkers[i].Free; // threads already joined by Shutdown
  SetLength(FWorkers, 0);
  FShutdownLock.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TInvocationScheduler.SignalWork;
var
  i: Integer;
begin
  // FWorkers is immutable after construction and its objects live until
  // Destroy, so this needs no lock even concurrently with Shutdown
  for i := 0 to High(FWorkers) do
    TSchedulerWorker(FWorkers[i]).Wake;
end;

function TInvocationScheduler.RegisterSource(
  const Limits: TPWebSourceLimits): IInvocationSource;
var
  src: TSchedulerSource;
  n: Integer;
begin
  if (Limits.MaxConcurrent < 1) or (Limits.MaxQueueSize < 1) then
    raise EPWebSchedulerError.CreateFmt(
      'RegisterSource: invalid limits (MaxConcurrent=%d, MaxQueueSize=%d); both must be >= 1',
      [Limits.MaxConcurrent, Limits.MaxQueueSize]);
  if FShuttingDown <> 0 then
  begin
    // fail-closed: a source already in pssClosed; its enqueues report
    // perClosed and nothing raises across threads
    Result := TSchedulerSource.CreateSource(Self, Limits, {closed=}True);
    exit;
  end;
  src := TSchedulerSource.CreateSource(Self, Limits, {closed=}False);
  Result := src;
  FLock.Enter;
  try
    if FShuttingDown <> 0 then
    begin
      // shutdown raced us: close the new source before handing it out
      FLock.Leave;
      src.Close;
      exit;
    end;
    n := Length(FSources);
    SetLength(FSources, n + 1);
    SetLength(FSourceRefs, n + 1);
    FSources[n] := src;
    FSourceRefs[n] := Result; // tracked until Shutdown
  except
    FLock.Leave;
    raise;
  end;
  FLock.Leave;
end;

function TInvocationScheduler.ClaimNext(out AItem: TObject): Boolean;
var
  i, n, start: Integer;
  item: TSchedulerItem;
begin
  Result := False;
  AItem := nil;
  FLock.Enter;
  try
    n := Length(FSources);
    if n = 0 then
      exit;
    start := FNextSource mod n;
    for i := 0 to n - 1 do
      if TSchedulerSource(FSources[(start + i) mod n]).TryClaim(item) then
      begin
        FNextSource := (start + i + 1) mod n; // round-robin fairness
        AItem := item;
        Result := True;
        exit;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TInvocationScheduler.ExecuteItem(AItem: TObject);
var
  item: TSchedulerItem;
  allowed: Boolean;
  r: TPWebInvocationResult;
begin
  item := TSchedulerItem(AItem);
  if item.Token.IsCancelled then
  begin
    // claimed after the source began quiescing/teardown: cancel early
    item.CompleteOnce(PWebDefaultErrorResult(pecCancelled));
    exit;
  end;
  // 1) capability policy - ALWAYS, with the canonical method from the
  //    single TryEnqueue gate; an exception is a DENY, never fail open
  try
    allowed := FPolicy.IsAllowed(item.Context, item.Method);
  except
    item.CompleteOnce(PWebDefaultErrorResult(pecInternalError));
    exit;
  end;
  if not allowed then
  begin
    // policy runs before routing: forbidden outranks method_not_found,
    // and the bridge is never reached
    item.CompleteOnce(PWebDefaultErrorResult(pecForbidden));
    exit;
  end;
  // 2) bridge, with the IDENTICAL canonical method value; a Pascal
  //    exception becomes internal_error with no native detail leaked
  try
    r := FBridge.Invoke(item.Context, item.Method, item.Args, item.Token);
    if (r.Kind = prkSuccess) and (r.Value = '') then
      r.Value := PWEB_JSON_NULL // '' would surface as JS undefined
    else if r.Kind = prkError then
    begin
      if r.Error.Message = '' then
        r.Error.Message := PWEB_DEFAULT_ERROR_MESSAGE[r.Error.Code];
      if r.Error.Data = '' then
        r.Error.Data := PWEB_JSON_NULL;
    end;
  except
    item.CompleteOnce(PWebDefaultErrorResult(pecInternalError));
    exit;
  end;
  item.CompleteOnce(r); // terminal completion; a cancelled invocation's
                        // late result dies at the gate inside
end;

procedure TInvocationScheduler.Shutdown;
var
  i: Integer;
  srcs: array of IInvocationSource;
begin
  InterlockedExchange(FShuttingDown, 1); // RegisterSource fails closed from here
  FShutdownLock.Enter; // a concurrent second call blocks until the first completes
  try
    if FShutdownDone then
      exit; // idempotent no-op
    FLock.Enter;
    try
      SetLength(srcs, Length(FSourceRefs));
      for i := 0 to High(FSourceRefs) do
        srcs[i] := FSourceRefs[i];
    finally
      FLock.Leave;
    end;
    // quiesce + close every source: queued invocations are completed as
    // cancelled by teardown and their captured contexts freed with them
    for i := 0 to High(srcs) do
      srcs[i].Close;
    // drain the worker pool - MAY BLOCK; never called from the GUI thread
    for i := 0 to High(FWorkers) do
      FWorkers[i].Terminate;
    for i := 0 to High(FWorkers) do
      TSchedulerWorker(FWorkers[i]).Wake;
    for i := 0 to High(FWorkers) do
      FWorkers[i].WaitFor;
    // worker objects are freed in Destroy, so a concurrent late
    // completion may still call SignalWork safely after this point
    FLock.Enter;
    try
      SetLength(FSources, 0);
      SetLength(FSourceRefs, 0);
    finally
      FLock.Leave;
    end;
    FShutdownDone := True;
    // only now may the caller release the service layer: no worker can
    // reach a freed service anymore
  finally
    FShutdownLock.Leave;
  end;
end;

function TInvocationScheduler.TryGetSourceCounts(
  const ASource: IInvocationSource; out AQueued, AActive: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  AQueued := 0;
  AActive := 0;
  FLock.Enter;
  try
    for i := 0 to High(FSourceRefs) do
      if FSourceRefs[i] = ASource then
      begin
        TSchedulerSource(FSources[i]).GetCounts(AQueued, AActive);
        exit(True);
      end;
  finally
    FLock.Leave;
  end;
end;

end.
