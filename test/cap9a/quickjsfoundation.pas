program quickjsfoundation;

{ CAP-9A: the QuickJS engine + source-generic invocation foundation
  harness. Headless and deterministic on all four targets - every line it
  writes to build/cap9a/quickjs-corpus.txt is a pure decision, a pinned
  constant, or a deterministic counter, so the file bytes (and the sha256
  the CAP-7F emitters record as quickjs_corpus_digest) are identical on
  windows-x86_64 / linux-x86_64 / macos-x86_64 / macos-arm64 by
  construction.

  WHAT RUNS: the UNCHANGED production runtime - frozen scheduler + CAP-8A
  policy + a counting bridge wrapping the REAL TMormotInvocationBridge
  (TRestServer.Uri) for CalculatorService.Add - with two concurrent
  QuickJS plugin threads as invocation sources:

    plugin:calculator (pkQuickJS, PluginId=calculator) - calculator.add
    plugin:reporting  (pkQuickJS, PluginId=reporting)  - explicit empty set

  plus a short-lived limits plugin for the stack/memory containment legs
  and 5x engine churn on the main thread. Neither reference plugin holds
  external.open, so pweb.openExternal is forbidden for both and the
  opener ledger must stay zero (counted, not assumed).

  ABI SECTION: SizeOf/tag-constant facts written BOTH into the corpus and
  into build/cap9a/abi-pascal.txt; the runner compiles test/cap9a/
  abiprobe.c against the pinned headers where the CI toolchain exists and
  diffs its output line-by-line against abi-pascal.txt.

  Q1-Q30 matrix (the numbers referenced by the CAP-9A spec):
    q01 allowed Add -> 42 through scheduler/policy/mORMot
    q02 denied Add -> forbidden/403, zero bridge/SOA activity
    q03/q04 openExternal forbidden for both plugins
    q05 success-shaped-as-error stays success (no shape sniffing)
    q06 null success -> JS null, never undefined
    q07 service_error carries data verbatim
    q08 internal_error redacted (default message, null data)
    q09 malformed method -> invalid_request; No.SuchMethod -> 404
    q10 positional args -> invalid_request
    q11 handshake works for BOTH principals (zero-cap parity)
    q12 sandbox globals all undefined
    q13/q14 QuickJS syntax/runtime errors stay engine errors
    q15 method case variant -> forbidden (exact-match policy)
    q16 Close mid-invocation -> waiting plugin thread resolves cancelled
    q17 late worker completion dies at the exactly-once gate (measured)
    q18 closed source -> runtime_closed
    q19 engine destroyed on its owning thread; other plugin unaffected
    q20 infinite loop interrupted by TimeoutValue; other plugin fine
    q21 engine reusable after the interrupt
    q22 deep recursion -> safe JS error under the runtime-typed stack cap
    q23 over-allocation -> safe error under JS_SetMemoryLimit; disposable
    q24 5x create/evaluate/destroy churn clean
    q25 forged identity fields in Args change nothing
    q26 plugin A saturates its source; plugin B's bounds unaffected
    q27 overflow surfaces as a thrown busy PWebError; accepted complete
    q28 in-flight invocation keeps its captured snapshot across a revoke
    q29 next invocation after revoke forbidden; restore -> allowed again
    q30 final ledger: exact SOA count, zero denied-bridge/opener activity,
        every native callback on its owning thread

  Markers:
      quickjsfoundation: QUICKJS PASS
      quickjsfoundation: QUICKJS FAIL (<reason>)
  Writes build/cap9a/quickjsfoundation-<target>.json (schema 1, overall
  PASS|FAIL), build/cap9a/quickjs-corpus.txt, build/cap9a/abi-pascal.txt. }

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
  mormot.core.json,
  mormot.core.variants,
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  mormot.lib.quickjs,
  mormot.script.core,
  mormot.script.quickjs,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.script.quickjs;

const
  LOG_PREFIX = 'quickjsfoundation';
  MARKER_PASS = 'quickjsfoundation: QUICKJS PASS';
  MARKER_FAIL = 'quickjsfoundation: QUICKJS FAIL';
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

  NATIVE_WAIT_MS = 8000;   // per-invocation completion bound (barriered work)
  BARRIER_WAIT_MS = 8000;  // arrival-barrier bound; never a fixed sleep
  SCRIPT_WAIT_MS = 20000;  // plugin-thread script bound (loop leg included)

  PRIN_CALC = 0;
  PRIN_REP = 1;
  ID_CALC: RawUtf8 = 'plugin:calculator';
  ID_REP: RawUtf8 = 'plugin:reporting';

  CAP_CALC = 'calculator.add';
  CAP_OPEN = 'external.open';

  M_ADD = 'CalculatorService.Add';
  M_OPEN = 'pweb.openExternal';
  M_NULL = 'Probe.Null';
  M_SHAPED = 'Probe.Shaped';
  M_SERR = 'Probe.Error';
  M_ESC = 'Probe.Escaped';
  M_ECHO = 'Probe.Echo';
  { a service_error message that NEEDS every interesting JsonEscape branch:
    double quote, backslash and a control character (tab) }
  ESC_MESSAGE = 'He said "no" \ and'#9'tab';
  M_FAULT = 'fault.raise';
  M_NOSUCH = 'No.SuchMethod';

  CORPUS_FILE = 'build/cap9a/quickjs-corpus.txt';
  ABI_PASCAL_FILE = 'build/cap9a/abi-pascal.txt';

type
  ICalculatorService = interface(IInvokable)
    ['{4B0E2C31-58D9-4A0C-9B7E-6A1F0D3C82E4}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  TCountingBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge; // the REAL mORMot bridge for M_ADD
  public
    constructor Create(const AInner: IInvocationBridge);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { records one native invocation's terminal result and signals an event }
  TRecordingCompletion = class(TInterfacedObject, IInvocationCompletion)
  private
    FEvent: PRTLEvent;
    FResult: TPWebInvocationResult;
    FClaimed: LongInt;  // exactly-once claim of the right to write FResult
    FDone: LongInt;     // published only AFTER FResult is fully written
    FCalls: LongInt;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Complete(const AResult: TPWebInvocationResult);
    function WaitResult(out AResult: TPWebInvocationResult;
      ATimeoutMs: Integer): Boolean;
    function CompleteCalls: LongInt;
  end;

  { adapts the CAP-8A policy's SnapshotCapabilities to the plugin's
    per-invocation snapshot callback (the D9 shape: refreshed per
    invocation so runtime-grant changes hit the NEXT invocation) }
  TSnapshotAdapter = class
  public
    function Snapshot(const APrincipalId: Utf8String): TPWebCapabilities;
  end;

var
  // per-(principal,method) bridge ledgers
  CountAdd: array[0..1] of LongInt;
  CountHandshake: array[0..1] of LongInt;
  CountOpenReached: LongInt;  // pweb.openExternal reaching the bridge: MUST stay 0
  NativeServiceAdd: LongInt;  // the real TInterfacedObject service counter
  // concurrency barrier (cap8c pattern: explicit events, never sleeps)
  HeldCount: LongInt;
  ReleaseGate: PRTLEvent;
  ReleaseFlag: LongInt;
  ArrivalEvent: PRTLEvent;
  BarrierArmed: LongInt;
  // late-worker rendezvous: the counting bridge increments the counter and
  // sets the event AFTER the real bridge returned on a held M_ADD call, so
  // waiters synchronize on the fact itself, never on a timer alone
  HeldInnerReturned: LongInt;
  InnerReturnedEvent: PRTLEvent;
  // corpus + failure accumulation
  CorpusLines: RawUtf8;
  FailReasons: RawUtf8;
  // runtime under test
  gScheduler: TInvocationScheduler;
  gSchedulerRef: IInvocationScheduler;
  gPolicy: TPWebCapabilityPolicy;
  gPolicyRef: ICapabilityPolicy;
  gBridge: IInvocationBridge;
  gServer: TRestServerFullMemory;
  gRealBridge: IInvocationBridge;
  gSrcCalc, gSrcRep: IInvocationSource;
  gSnap: TSnapshotAdapter;
  gSnapCb: TPWebQuickJSSnapshotEvent;
  gCalcPlugin, gRepPlugin, gLimitsPlugin: TPWebQuickJSPlugin;
  root: TFileName;

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
  Result := Utf8String(IntToStr(AValue));
end;

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := AValue;
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or (Result[i] < #$20) then
      Result[i] := '''';
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

{ ---- dense-JSON field extractors (cap8c shapes) --------------------------- }

function DenseJson(const AJson: RawUtf8): RawUtf8;
var
  i: PtrInt;
  inStr, skipNext: Boolean;
  c: AnsiChar;
begin
  Result := '';
  inStr := False;
  skipNext := False;
  for i := 1 to Length(AJson) do
  begin
    c := AJson[i];
    if skipNext then
    begin
      skipNext := False;
      Result := Result + c;
      continue;
    end;
    if inStr and (c = '\') then
      skipNext := True
    else if c = '"' then
      inStr := not inStr;
    if (not inStr) and ((c = ' ') or (c = #9) or (c = #10) or (c = #13)) then
      continue;
    Result := Result + c;
  end;
end;

function JsonStrField(const ADense, AName: RawUtf8): RawUtf8;
var
  key: RawUtf8;
  p, q: PtrInt;
begin
  Result := '';
  key := '"' + AName + '":"';
  p := Pos(key, ADense);
  if p = 0 then
    exit;
  p := p + Length(key);
  q := p;
  while (q <= Length(ADense)) and (ADense[q] <> '"') do
    Inc(q);
  Result := copy(ADense, p, q - p);
end;

function JsonRawField(const ADense, AName: RawUtf8): RawUtf8;
var
  key: RawUtf8;
  p, q: PtrInt;
  depth: Integer;
begin
  Result := '';
  key := '"' + AName + '":';
  p := Pos(key, ADense);
  if p = 0 then
    exit;
  p := p + Length(key);
  q := p;
  depth := 0;
  while q <= Length(ADense) do
  begin
    case ADense[q] of
      '{', '[': Inc(depth);
      '}', ']':
        begin
          if depth = 0 then
            break;
          Dec(depth);
        end;
      ',':
        if depth = 0 then
          break;
    end;
    Inc(q);
  end;
  Result := copy(ADense, p, q - p);
end;

{ ---- service + barrier ---------------------------------------------------- }

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  InterlockedIncrement(NativeServiceAdd);
  Result := a + b;
end;

procedure BarrierParkIfArmed;
var
  deadline: QWord;
begin
  if InterlockedCompareExchange(BarrierArmed, 0, 0) = 0 then
    exit;
  InterlockedIncrement(HeldCount);
  RTLEventSetEvent(ArrivalEvent);
  deadline := GetTickCount64 + BARRIER_WAIT_MS;
  while (InterlockedCompareExchange(ReleaseFlag, 0, 0) = 0) and
        (GetTickCount64 < deadline) do
    RTLEventWaitFor(ReleaseGate, 200);
end;

function WaitHeld(ATarget: Integer): Boolean;
var
  deadline: QWord;
begin
  deadline := GetTickCount64 + BARRIER_WAIT_MS;
  while InterlockedCompareExchange(HeldCount, 0, 0) < ATarget do
  begin
    if GetTickCount64 > deadline then
      exit(False);
    RTLEventWaitFor(ArrivalEvent, 200);
    RTLEventResetEvent(ArrivalEvent);
  end;
  Result := True;
end;

procedure ArmBarrier;
begin
  InterlockedExchange(HeldCount, 0);
  InterlockedExchange(ReleaseFlag, 0);
  InterlockedExchange(BarrierArmed, 1);
  RTLEventResetEvent(ReleaseGate);
end;

procedure ReleaseBarrier;
begin
  InterlockedExchange(ReleaseFlag, 1);
  InterlockedExchange(BarrierArmed, 0);
  RTLEventSetEvent(ReleaseGate);
end;

{ deterministic rendezvous with a released held worker: True once the
  counting bridge has recorded ATarget held M_ADD calls RETURNING from the
  real bridge (so the corpus-pinned counters are final and the worker's
  terminal CompleteOnce is at most straight-line instructions away) }
function WaitInnerReturned(ATarget: Integer): Boolean;
var
  deadline: QWord;
begin
  deadline := GetTickCount64 + BARRIER_WAIT_MS;
  while InterlockedCompareExchange(HeldInnerReturned, 0, 0) < ATarget do
  begin
    if GetTickCount64 > deadline then
      exit(False);
    RTLEventWaitFor(InnerReturnedEvent, 200);
    RTLEventResetEvent(InnerReturnedEvent);
  end;
  Result := True;
end;

{ ---- the counting bridge -------------------------------------------------- }

constructor TCountingBridge.Create(const AInner: IInvocationBridge);
begin
  inherited Create;
  FInner := AInner;
end;

function PrincipalIndex(const AId: RawUtf8): Integer;
begin
  if AId = ID_CALC then
    Result := PRIN_CALC
  else if AId = ID_REP then
    Result := PRIN_REP
  else
    Result := -1;
end;

function CleanAddArgs(const Args: TPWebJson): TPWebJson;
var
  a, b, payload: RawUtf8;
begin
  // reconstruct {"a":..,"b":..} so the barrier sentinel (and any forged
  // field) never masquerades as a service argument - forged fields have
  // zero AUTHORIZATION effect regardless (policy ran before the bridge)
  payload := Args;
  UniqueRawUtf8(payload);
  a := JsonDecode(payload, 'a');
  payload := Args;
  UniqueRawUtf8(payload);
  b := JsonDecode(payload, 'b');
  if (a = '') or (b = '') then
    exit(Args);
  Result := '{"a":' + a + ',"b":' + b + '}';
end;

function TCountingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  p: Integer;
  held: Boolean;
begin
  p := PrincipalIndex(Context.PrincipalId);
  held := Pos('"hold":true', Args) > 0;
  if held then
    BarrierParkIfArmed;
  if Method = M_ADD then
  begin
    if p >= 0 then
      InterlockedIncrement(CountAdd[p]);
    Result := FInner.Invoke(Context, Method, CleanAddArgs(Args), Token);
    if held then
    begin
      // the rendezvous fact: this held call has fully RETURNED from the
      // real bridge; every counter it touches is final by now
      InterlockedIncrement(HeldInnerReturned);
      RTLEventSetEvent(InnerReturnedEvent);
    end;
    exit;
  end;
  if Method = M_OPEN then
  begin
    // no principal holds external.open: reaching this arm is itself the
    // failure the ledger counts
    InterlockedIncrement(CountOpenReached);
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  if Method = PWEB_METHOD_HANDSHAKE then
  begin
    if p >= 0 then
      InterlockedIncrement(CountHandshake[p]);
    exit(PWebSuccessResult('{"protocol":' +
      Utf8String(IntToStr(PWEB_PROTOCOL_VERSION)) + ',"runtime":"' +
      PWEB_RUNTIME_VERSION + '"}'));
  end;
  if Method = M_NULL then
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  if Method = M_SHAPED then
    exit(PWebSuccessResult('{"code":"forbidden"}'));
  if Method = M_SERR then
    exit(PWebErrorResult(pecServiceError, 'Insufficient funds',
      '{"domainCode":"insufficient_funds"}'));
  if Method = M_ESC then
    exit(PWebErrorResult(pecServiceError, ESC_MESSAGE, '{"k":"v"}'));
  if Method = M_ECHO then
    exit(PWebSuccessResult(Args));
  if Method = M_FAULT then
    raise Exception.Create('deliberate fault for the taxonomy matrix');
  // No.SuchMethod (zero-cap, no impl) and anything else -> 404
  Result := PWebDefaultErrorResult(pecMethodNotFound);
end;

{ ---- policy + contexts ---------------------------------------------------- }

function BuildCap9aPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum([CAP_CALC, CAP_OPEN]);
    b.SetPrincipalCapabilities(ID_CALC, [CAP_CALC]);
    b.SetPrincipalCapabilities(ID_REP, []); // explicit empty = no rights
    b.MapMethod(M_ADD, [CAP_CALC]);
    b.MapMethod(M_OPEN, [CAP_OPEN]);
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(M_NULL);
    b.RegisterZeroCapMethod(M_SHAPED);
    b.RegisterZeroCapMethod(M_SERR);
    b.RegisterZeroCapMethod(M_ESC);
    b.RegisterZeroCapMethod(M_ECHO);
    b.RegisterZeroCapMethod(M_FAULT);
    b.RegisterZeroCapMethod(M_NOSUCH);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

function TSnapshotAdapter.Snapshot(
  const APrincipalId: Utf8String): TPWebCapabilities;
begin
  Result := gPolicy.SnapshotCapabilities(APrincipalId);
end;

function MakeContext(APrincipal: Integer): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.PrincipalKind := pkQuickJS;
  Result.WindowId := '';
  Result.TrustedContent := True;
  if APrincipal = PRIN_CALC then
  begin
    Result.PrincipalId := ID_CALC;
    Result.PluginId := 'calculator';
  end
  else
  begin
    Result.PrincipalId := ID_REP;
    Result.PluginId := 'reporting';
  end;
  Result.Capabilities := gPolicy.SnapshotCapabilities(Result.PrincipalId);
end;

{ ---- recording completion (native direct-enqueue legs) -------------------- }

constructor TRecordingCompletion.Create;
begin
  inherited Create;
  FEvent := RTLEventCreate;
end;

destructor TRecordingCompletion.Destroy;
begin
  if FEvent <> nil then
    RTLEventDestroy(FEvent);
  inherited Destroy;
end;

procedure TRecordingCompletion.Complete(const AResult: TPWebInvocationResult);
begin
  InterlockedIncrement(FCalls);
  if InterlockedExchange(FClaimed, 1) <> 0 then
    exit;
  // FResult written fully BEFORE FDone publishes it, so a waiter that
  // timed out of the event never copies a torn managed record
  FResult := AResult;
  InterlockedExchange(FDone, 1);
  RTLEventSetEvent(FEvent);
end;

function TRecordingCompletion.CompleteCalls: LongInt;
begin
  Result := InterlockedCompareExchange(FCalls, 0, 0);
end;

function TRecordingCompletion.WaitResult(out AResult: TPWebInvocationResult;
  ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FEvent, ATimeoutMs);
  if InterlockedCompareExchange(FDone, 0, 0) <> 0 then
  begin
    AResult := FResult;
    Result := True;
  end
  else
  begin
    AResult := Default(TPWebInvocationResult);
    Result := False;
  end;
end;

{ ---- script helpers ------------------------------------------------------- }

{ wraps one pweb.invoke in a try/catch that returns a structured JSON
  string, so PWebError decisions come back as data (never as an engine
  error) and the corpus stays deterministic }
function InvokeScript(const AMethod, AArgsJs: RawUtf8): RawUtf8;
begin
  Result :=
    '(function(){try{var v=pweb.invoke("' + AMethod + '",' + AArgsJs + ');' +
    'return JSON.stringify({ok:true,value:(v===undefined?"__undef__":v),' +
    'isNull:v===null,isUndef:v===undefined});}' +
    'catch(e){return JSON.stringify({ok:false,name:e.name,code:e.code,' +
    'status:e.status,message:e.message,' +
    'data:(e.data===undefined?"__nodata__":e.data)});}})()';
end;

const
  RUNPLUGIN_TIMEOUT_ERR = 'script did not complete within the bound';

{ True only when a limit leg was contained SAFELY: either the engine
  raised (a real EQuickJSEngine error, never the RunPlugin bound timeout,
  which means the script is still running) or the script caught the limit
  failure itself }
function ContainedSafely(const AErr, ADense: RawUtf8): Boolean;
begin
  Result := ((AErr <> '') and (AErr <> RUNPLUGIN_TIMEOUT_ERR)) or
    (JsonRawField(ADense, 'caught') = 'true');
end;

{ runs one script on a plugin and returns the DENSE result JSON; engine
  errors surface through AEngineErr }
function RunPlugin(APlugin: TPWebQuickJSPlugin; const AScript: RawUtf8;
  out AEngineErr: RawUtf8; ATimeoutSec: Cardinal = 0): RawUtf8;
var
  json: RawUtf8;
begin
  Result := '';
  AEngineErr := '';
  if not APlugin.Eval(AScript, json, AEngineErr, ATimeoutSec, SCRIPT_WAIT_MS) then
  begin
    AEngineErr := RUNPLUGIN_TIMEOUT_ERR;
    exit;
  end;
  Result := DenseJson(json);
end;

{ decision helper: invoke AMethod with AArgsJs on APlugin, expect either
  success (AExpect='success') or an error code }
procedure Decision(APlugin: TPWebQuickJSPlugin; APrincipal: Integer;
  const ALabel, AMethod, AArgsJs, AExpect: RawUtf8);
var
  dense, err, code: RawUtf8;
const
  PRIN_NAME: array[0..1] of RawUtf8 = ('plugin:calculator', 'plugin:reporting');
begin
  dense := RunPlugin(APlugin, InvokeScript(AMethod, AArgsJs), err);
  if err <> '' then
  begin
    Emit(ALabel + ' principal=' + PRIN_NAME[APrincipal] + ' method=' + AMethod +
      ' code=engine_error');
    Fail(ALabel + ' ' + AMethod + ' raised an engine error');
    exit;
  end;
  if Pos('"ok":true', dense) > 0 then
    code := 'success'
  else
    code := JsonStrField(dense, 'code');
  Emit(ALabel + ' principal=' + PRIN_NAME[APrincipal] + ' method=' + AMethod +
    ' code=' + code);
  Expect(code = AExpect, ALabel + ' ' + PRIN_NAME[APrincipal] + '/' + AMethod +
    ' = ' + code + ' expected ' + AExpect);
end;

{ ---- ABI section ---------------------------------------------------------- }

procedure WriteAbiPascalFile;
var
  lines: RawUtf8;
  f: TFileStream;
  path: TFileName;
begin
  // the EXACT line set test/cap9a/abiprobe.c emits - the runner diffs the
  // two files byte-for-byte where the C toolchain exists
  lines :=
    'sizeof_jsvalue=' + IntStr(SizeOf(JSValueRaw)) + #10 +
    'tag_uninitialized=' + IntStr(JS_TAG_UNINITIALIZED) + #10 +
    'tag_int=' + IntStr(JS_TAG_INT) + #10 +
    'tag_bool=' + IntStr(JS_TAG_BOOL) + #10 +
    'tag_null=' + IntStr(JS_TAG_NULL) + #10 +
    'tag_undefined=' + IntStr(JS_TAG_UNDEFINED) + #10 +
    'tag_exception=' + IntStr(JS_TAG_EXCEPTION) + #10 +
    'tag_float64=' + IntStr(JS_TAG_FLOAT64) + #10 +
    'tag_object=' + IntStr(JS_TAG_OBJECT) + #10 +
    'tag_string=' + IntStr(JS_TAG_STRING) + #10 +
    'callback_int_bytes=' + IntStr(SizeOf(Integer)) + #10 +
    'callback_jsvalue_bytes=' + IntStr(SizeOf(JSValueRaw)) + #10 +
    'callback_ptr_bytes=' + IntStr(SizeOf(Pointer)) + #10;
  path := root + TFileName(StringReplace(ABI_PASCAL_FILE, '/', PathDelim,
    [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(path)) then
    raise Exception.Create('unable to create ' + string(ExtractFilePath(path)));
  f := TFileStream.Create(path, fmCreate);
  try
    f.WriteBuffer(lines[1], Length(lines));
  finally
    f.Free;
  end;
end;

procedure AbiSection;
var
  eng: TQuickJSEngine;
  v: variant;
  sv: JSValue;
  txt, big1, big2: RawUtf8;
  i: Integer;
  churnOk: Boolean;
begin
  // sizes + pinned tag constants (identical on all four targets under
  // JS_STRICT_NAN_BOXING - that identity is what the digest freezes)
  Emit('abi jsvalueraw_size=' + IntStr(SizeOf(JSValueRaw)) +
    ' jsvalue_size=' + IntStr(SizeOf(JSValue)));
  Expect(SizeOf(JSValueRaw) = 8, 'SizeOf(JSValueRaw) <> 8');
  Expect(SizeOf(JSValue) = 8, 'SizeOf(JSValue) <> 8');
  Emit('abi tags uninit=' + IntStr(JS_TAG_UNINITIALIZED) +
    ' int=' + IntStr(JS_TAG_INT) + ' bool=' + IntStr(JS_TAG_BOOL) +
    ' null=' + IntStr(JS_TAG_NULL) + ' undefined=' + IntStr(JS_TAG_UNDEFINED) +
    ' exception=' + IntStr(JS_TAG_EXCEPTION) +
    ' float64=' + IntStr(JS_TAG_FLOAT64) + ' object=' + IntStr(JS_TAG_OBJECT) +
    ' string=' + IntStr(JS_TAG_STRING));
  WriteAbiPascalFile;

  // caller-owned engine on the MAIN thread: 53-bit boundary round-trips,
  // string refcount round-trip, GC, then 5x churn
  eng := TQuickJSEngine(PWebQuickJSManager.NewEngine);
  try
    // engine-side String() so the corpus carries the ECMA-deterministic
    // spelling, not any Pascal float formatting
    v := eng.Evaluate('String(9007199254740991)'); // MAX_SAFE_INTEGER
    big1 := VariantToUtf8(v);
    v := eng.Evaluate('String(9007199254740993)'); // above the 53-bit boundary
    big2 := VariantToUtf8(v);
    Emit('abi int53 max_safe=' + big1 + ' above_boundary=' + big2);
    Expect(big1 = '9007199254740991', 'MAX_SAFE_INTEGER round-trip = ' + big1);
    Expect(big2 = '9007199254740992', '53-bit boundary collapse = ' + big2);
    sv := eng.cx^.From('cap9a-refcount');
    txt := eng.cx^.ToUtf8Free(sv);
    eng.GarbageCollect;
    v := eng.Evaluate('(function(){var s="";for(var i=0;i<64;i++){s+="x";}return s.length;})()');
    Emit('abi refcount roundtrip=' + txt + ' post_gc_len=' + VariantSaveJson(v));
    Expect(txt = 'cap9a-refcount', 'string refcount round-trip = ' + txt);
  finally
    eng.Free;
  end;

  churnOk := True;
  for i := 1 to 5 do
  begin
    eng := TQuickJSEngine(PWebQuickJSManager.NewEngine);
    try
      v := eng.Evaluate('21*2');
      if VariantSaveJson(v) <> '42' then
        churnOk := False;
    finally
      eng.Free;
    end;
  end;
  Emit('q24 churn cycles=5 ok=' + YesNo(churnOk));
  Expect(churnOk, 'engine churn produced a wrong result');
end;

{ ---- the Q matrix --------------------------------------------------------- }

procedure QDecisions;
var
  dense, err, sandbox: RawUtf8;
begin
  // q01/q02: the frozen chain, allowed vs denied, zero denied activity
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '{"a":20,"b":22}'), err);
  Emit('q01 allowed add value=' + JsonRawField(dense, 'value'));
  Expect((err = '') and (JsonRawField(dense, 'value') = '42'),
    'q01 calculator Add did not return 42');
  dense := RunPlugin(gRepPlugin, InvokeScript(M_ADD, '{"a":20,"b":22}'), err);
  Emit('q02 denied add code=' + JsonStrField(dense, 'code') +
    ' status=' + JsonRawField(dense, 'status') +
    ' name=' + JsonStrField(dense, 'name') +
    ' rep_bridge_add=' + IntStr(CountAdd[PRIN_REP]));
  Expect(JsonStrField(dense, 'code') = 'forbidden', 'q02 code not forbidden');
  Expect(JsonRawField(dense, 'status') = '403', 'q02 status not 403');
  Expect(JsonStrField(dense, 'name') = 'PWebError', 'q02 not a PWebError');
  Expect(CountAdd[PRIN_REP] = 0, 'q02 denied Add reached the bridge');

  // q03/q04: openExternal denied for BOTH (no external.open granted)
  Decision(gCalcPlugin, PRIN_CALC, 'q03', M_OPEN,
    '{"url":"https://example.invalid/cap9a"}', 'forbidden');
  Decision(gRepPlugin, PRIN_REP, 'q04', M_OPEN,
    '{"url":"https://example.invalid/cap9a"}', 'forbidden');

  // q05: a success value shaped like an error envelope stays a success
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_SHAPED, 'null'), err);
  Emit('q05 shaped ok=' + YesNo(Pos('"ok":true', dense) > 0) +
    ' value=' + JsonRawField(dense, 'value'));
  Expect(Pos('"ok":true', dense) > 0, 'q05 shaped success was not a success');
  Expect(JsonRawField(dense, 'value') = '{"code":"forbidden"}',
    'q05 shaped value mangled: ' + JsonRawField(dense, 'value'));

  // q06: null success is JS null, never undefined
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_NULL, 'null'), err);
  Emit('q06 null isNull=' + JsonRawField(dense, 'isNull') +
    ' isUndef=' + JsonRawField(dense, 'isUndef'));
  Expect(JsonRawField(dense, 'isNull') = 'true', 'q06 null success not null');
  Expect(JsonRawField(dense, 'isUndef') = 'false', 'q06 null became undefined');

  // q07: service_error carries data verbatim
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_SERR, 'null'), err);
  Emit('q07 service_error code=' + JsonStrField(dense, 'code') +
    ' status=' + JsonRawField(dense, 'status') +
    ' data=' + JsonRawField(dense, 'data'));
  Expect(JsonStrField(dense, 'code') = 'service_error', 'q07 code wrong');
  Expect(JsonRawField(dense, 'status') = '422', 'q07 status wrong');
  Expect(JsonRawField(dense, 'data') = '{"domainCode":"insufficient_funds"}',
    'q07 service_error data not verbatim');

  // q07b: the envelope's JSON escaping proven on a message that NEEDS it
  // (quote + backslash + tab); the script compares byte-exactly so the
  // corpus pins the round-trip without native escape-aware parsing
  dense := RunPlugin(gCalcPlugin,
    '(function(){try{pweb.invoke("Probe.Escaped",null);return ' +
    'JSON.stringify({thrown:false});}catch(e){return JSON.stringify({' +
    'thrown:true,code:e.code,' +
    'matches:e.message===''He said "no" \\ and\ttab'',' +
    'dataOk:JSON.stringify(e.data)===''{"k":"v"}''});}})()', err);
  Emit('q07b escaped thrown=' + JsonRawField(dense, 'thrown') +
    ' code=' + JsonStrField(dense, 'code') +
    ' matches=' + JsonRawField(dense, 'matches') +
    ' dataOk=' + JsonRawField(dense, 'dataOk'));
  Expect(JsonRawField(dense, 'thrown') = 'true', 'q07b did not throw');
  Expect(JsonStrField(dense, 'code') = 'service_error', 'q07b code wrong');
  Expect(JsonRawField(dense, 'matches') = 'true',
    'q07b escaped message did not round-trip byte-exactly');
  Expect(JsonRawField(dense, 'dataOk') = 'true', 'q07b data not verbatim');

  // q08: internal_error stays redacted (default message, null data)
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_FAULT, 'null'), err);
  Emit('q08 internal code=' + JsonStrField(dense, 'code') +
    ' status=' + JsonRawField(dense, 'status') +
    ' message=' + JsonStrField(dense, 'message') +
    ' data=' + JsonRawField(dense, 'data'));
  Expect(JsonStrField(dense, 'code') = 'internal_error', 'q08 code wrong');
  Expect(JsonStrField(dense, 'message') = 'Internal error',
    'q08 message not redacted: ' + JsonStrField(dense, 'message'));
  Expect(Pos('deliberate', dense) = 0, 'q08 leaked the exception text');
  Expect(JsonRawField(dense, 'data') = 'null', 'q08 data not null');

  // q09: malformed grammar pre-queue + registered-but-unimplemented 404
  dense := RunPlugin(gCalcPlugin, InvokeScript('not a method', 'null'), err);
  Emit('q09 malformed=' + JsonStrField(dense, 'code'));
  Expect(JsonStrField(dense, 'code') = 'invalid_request', 'q09 malformed');
  Decision(gCalcPlugin, PRIN_CALC, 'q09b', M_NOSUCH, 'null', 'method_not_found');

  // q10: positional args are not protocol v1
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '[20,22]'), err);
  Emit('q10 positional=' + JsonStrField(dense, 'code'));
  Expect(JsonStrField(dense, 'code') = 'invalid_request', 'q10 positional');

  // q11: pweb.handshake parity for both principals (zero-cap)
  dense := RunPlugin(gCalcPlugin,
    '(function(){try{var h=pweb.handshake();' +
    'return JSON.stringify({ok:true,protocol:h.protocol});}' +
    'catch(e){return JSON.stringify({ok:false,code:e.code});}})()', err);
  Emit('q11 handshake calc protocol=' + JsonRawField(dense, 'protocol'));
  Expect(JsonRawField(dense, 'protocol') = '1', 'q11 calc handshake protocol');
  dense := RunPlugin(gRepPlugin,
    '(function(){try{var h=pweb.handshake();' +
    'return JSON.stringify({ok:true,protocol:h.protocol});}' +
    'catch(e){return JSON.stringify({ok:false,code:e.code});}})()', err);
  Emit('q11 handshake rep protocol=' + JsonRawField(dense, 'protocol'));
  Expect(JsonRawField(dense, 'protocol') = '1', 'q11 rep handshake protocol');

  // q12: the sandbox - no fetch/XHR/sockets/require/process/std/os/
  // filesystem/spawn/DOM/timers
  sandbox := RunPlugin(gCalcPlugin,
    '(function(){return JSON.stringify({g:[typeof fetch,' +
    'typeof XMLHttpRequest,typeof WebSocket,typeof EventSource,' +
    'typeof require,typeof process,typeof std,typeof os,' +
    'typeof document,typeof window,typeof spawn,typeof setTimeout]' +
    '.join(",")});})()', err);
  Emit('q12 sandbox globals=' + JsonStrField(sandbox, 'g'));
  Expect(JsonStrField(sandbox, 'g') =
    'undefined,undefined,undefined,undefined,undefined,undefined,' +
    'undefined,undefined,undefined,undefined,undefined,undefined',
    'q12 a sandboxed global exists: ' + JsonStrField(sandbox, 'g'));

  // q13/q14: engine errors stay engine errors, distinct from invocation
  // errors (classification only - messages carry position info)
  dense := RunPlugin(gCalcPlugin, 'this is not js', err);
  Emit('q13 syntax=' + YesNo(err <> ''));
  Expect(err <> '', 'q13 a syntax error did not raise an engine error');
  dense := RunPlugin(gCalcPlugin, 'null.x', err);
  Emit('q14 runtime=' + YesNo(err <> ''));
  Expect(err <> '', 'q14 a runtime error did not raise an engine error');

  // q15: case variants are rejected by exact-match policy (unmapped=deny)
  Decision(gCalcPlugin, PRIN_CALC, 'q15', 'calculatorservice.add',
    '{"a":20,"b":22}', 'forbidden');

  // extra evidence: verbatim key case/order round-trip (P9 shape)
  dense := RunPlugin(gCalcPlugin,
    '(function(){var a={"B":1,"a":{"Zz":null,"aA":2}};' +
    'var v=pweb.invoke("Probe.Echo",a);' +
    'return JSON.stringify({same:JSON.stringify(v)===JSON.stringify(a)});})()',
    err);
  Emit('echo verbatim=' + JsonRawField(dense, 'same'));
  Expect(JsonRawField(dense, 'same') = 'true', 'echo round-trip not verbatim');

  // q25: forged identity fields in Args change nothing
  dense := RunPlugin(gRepPlugin, InvokeScript(M_ADD,
    '{"a":20,"b":22,"principal":"plugin:calculator",' +
    '"capabilities":["calculator.add"],"trusted":true}'), err);
  Emit('q25 forged code=' + JsonStrField(dense, 'code'));
  Expect(JsonStrField(dense, 'code') = 'forbidden', 'q25 forged args');
end;

procedure QLimits;
var
  dense, err, addDense, addErr: RawUtf8;
  json: RawUtf8;
  limits: TPWebQuickJSLimits;
  srcLimits2: IInvocationSource;
  lim: TPWebSourceLimits;
begin
  // q20/q21: infinite loop on the reporting plugin, interrupted by the
  // pinned TimeoutValue interrupt while the calculator plugin keeps
  // invoking through the shared runtime - then the SAME engine evaluates
  // again (reusable)
  Expect(gRepPlugin.PostScript('for(;;){}', {timeoutSec=}1),
    'q20 loop post refused');
  addDense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '{"a":40,"b":2}'),
    addErr);
  if not gRepPlugin.WaitScript(json, err, SCRIPT_WAIT_MS) then
  begin
    err := '';
    Fail('q20 the infinite loop was never interrupted');
  end;
  Emit('q20 loop interrupted=' + YesNo(err <> '') +
    ' aborted=' + YesNo(gRepPlugin.TimeoutAborted) +
    ' other_add=' + JsonRawField(addDense, 'value'));
  Expect(err <> '', 'q20 loop returned without an engine error');
  Expect(gRepPlugin.TimeoutAborted, 'q20 TimeoutAborted not set');
  Expect(JsonRawField(addDense, 'value') = '42',
    'q20 the other plugin was affected by the loop');
  dense := RunPlugin(gRepPlugin, '(function(){return JSON.stringify({v:1+1});})()', err);
  Emit('q21 reusable=' + YesNo((err = '') and (JsonRawField(dense, 'v') = '2')));
  Expect((err = '') and (JsonRawField(dense, 'v') = '2'),
    'q21 engine not reusable after the interrupt');

  // q22/q23: stack + memory containment on a dedicated disposable plugin
  lim := Default(TPWebSourceLimits);
  lim.MaxConcurrent := 1;
  lim.MaxQueueSize := 4;
  srcLimits2 := gScheduler.RegisterSource(lim);
  limits := PWEB_QUICKJS_DEFAULT_LIMITS;
  limits.MemoryLimitBytes := 16 shl 20; // 16 MB
  limits.StackLimitBytes := 256 * 1024; // 256 KB, runtime-typed call
  gLimitsPlugin := TPWebQuickJSPlugin.Create(srcLimits2,
    MakeContext(PRIN_REP), limits, gSnapCb);
  try
    Expect(gLimitsPlugin.WaitReady(15000),
      'limits plugin bootstrap failed: ' + gLimitsPlugin.InitError);
    // a bounded-wait timeout means the script NEVER finished: that is a
    // containment FAILURE, never counted as a safe engine error
    dense := RunPlugin(gLimitsPlugin,
      '(function(){try{var f=function(n){return f(n+1);};return String(f(0));}' +
      'catch(e){return JSON.stringify({caught:true});}})()', err, 5);
    Emit('q22 recursion safe=' + YesNo(ContainedSafely(err, dense)));
    Expect(ContainedSafely(err, dense),
      'q22 deep recursion neither threw nor errored (or hung)');
    dense := RunPlugin(gLimitsPlugin,
      '(function(){try{var a=[];for(;;){a.push(new Array(4096).fill(1));}}' +
      'catch(e){return JSON.stringify({caught:true});}return "unreached";})()',
      err, 8);
    Emit('q23 oom safe=' + YesNo(ContainedSafely(err, dense)));
    Expect(ContainedSafely(err, dense),
      'q23 over-allocation neither threw nor errored (or hung)');
  finally
    gLimitsPlugin.Unload;
    Emit('q23 disposable engine_destroyed_on_owner=' +
      YesNo(gLimitsPlugin.EngineDestroyedOnOwnThread));
    Expect(gLimitsPlugin.EngineDestroyedOnOwnThread,
      'q23 limits engine not destroyed on its own thread');
    FreeAndNil(gLimitsPlugin);
  end;
end;

procedure QBackpressure;
var
  c1, c2, c3: TRecordingCompletion;
  r1, r2, r3: IInvocationCompletion;
  e1, e2: TPWebEnqueueResult;
  res: TPWebInvocationResult;
  ctx: TInvocationContext;
  dense, err, hsDense: RawUtf8;
  code1, code2: RawUtf8;
begin
  // q26/q27: the calculator source was registered MaxConcurrent=1,
  // MaxQueueSize=1. A barriered native Add occupies the slot, a second
  // is queued, and the PLUGIN's own synchronous invoke then meets a full
  // queue: a thrown busy PWebError on the script side while the OTHER
  // plugin's source stays fully functional.
  ArmBarrier;
  ctx := MakeContext(PRIN_CALC);
  c1 := TRecordingCompletion.Create; r1 := c1;
  c2 := TRecordingCompletion.Create; r2 := c2;
  c3 := TRecordingCompletion.Create; r3 := c3;
  e1 := gSrcCalc.TryEnqueue(ctx, M_ADD, '{"a":1,"b":2,"hold":true}', r1);
  Expect(e1 = perAccepted, 'q26 first native Add not accepted');
  if not WaitHeld(1) then
    Fail('q26 the first native Add never parked');
  e2 := gSrcCalc.TryEnqueue(ctx, M_ADD, '{"a":3,"b":4}', r2);
  Expect(e2 = perAccepted, 'q26 second native Add not accepted (queued)');
  // the plugin's invoke now meets a full queue -> busy, synchronously
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '{"a":5,"b":6}'), err);
  Emit('q27 overflow code=' + JsonStrField(dense, 'code') +
    ' status=' + JsonRawField(dense, 'status') +
    ' name=' + JsonStrField(dense, 'name'));
  Expect(JsonStrField(dense, 'code') = 'busy', 'q27 overflow not busy');
  Expect(JsonRawField(dense, 'status') = '429', 'q27 status not 429');
  // plugin B's source is unaffected while A is saturated
  hsDense := RunPlugin(gRepPlugin,
    '(function(){try{var h=pweb.handshake();' +
    'return JSON.stringify({ok:true,protocol:h.protocol});}' +
    'catch(e){return JSON.stringify({ok:false,code:e.code});}})()', err);
  ReleaseBarrier;
  if c1.WaitResult(res, NATIVE_WAIT_MS) then
  begin
    if res.Kind = prkSuccess then
      code1 := 'success'
    else
      code1 := PWEB_ERROR_CODE_TEXT[res.Error.Code];
  end
  else
    code1 := 'timeout'; // and it STAYS timeout - never rewritten to success
  if c2.WaitResult(res, NATIVE_WAIT_MS) then
  begin
    if res.Kind = prkSuccess then
      code2 := 'success'
    else
      code2 := PWEB_ERROR_CODE_TEXT[res.Error.Code];
  end
  else
    code2 := 'timeout';
  Emit('q26 saturation first=' + code1 + ' queued=' + code2 +
    ' other_handshake=' + JsonRawField(hsDense, 'protocol') +
    ' overflow_sink_calls=' + IntStr(c3.CompleteCalls));
  Expect(code1 = 'success', 'q26 first native Add completed as ' + code1);
  Expect(code2 = 'success', 'q26 queued native Add completed as ' + code2);
  Expect(JsonRawField(hsDense, 'protocol') = '1',
    'q26 plugin B was affected by plugin A saturation');
  Expect(c3.CompleteCalls = 0, 'q26 an unused sink was invoked');
end;

procedure QGrants;
var
  dense, err, next, restored: RawUtf8;
  json: RawUtf8;
begin
  // q28/q29: revoke calculator.add for plugin:calculator WHILE an
  // invocation is in flight on its captured snapshot; the held one
  // completes 42, the NEXT one (fresh snapshot) is forbidden, restore
  // affects only later snapshots.
  ArmBarrier;
  Expect(gCalcPlugin.PostScript(
    InvokeScript(M_ADD, '{"a":20,"b":22,"hold":true}')),
    'q28 held post refused');
  if not WaitHeld(1) then
    Fail('q28 the held Add never parked at the barrier');
  gPolicy.RevokeRuntimeGrant(ID_CALC, CAP_CALC);
  ReleaseBarrier;
  if gCalcPlugin.WaitScript(json, err, SCRIPT_WAIT_MS) then
    dense := DenseJson(json)
  else
  begin
    dense := '';
    Fail('q28 the held Add script never completed');
  end;
  Emit('q28 inflight value=' + JsonRawField(dense, 'value'));
  Expect(JsonRawField(dense, 'value') = '42',
    'q28 in-flight snapshot was not honored');
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '{"a":20,"b":22}'), err);
  next := JsonStrField(dense, 'code');
  gPolicy.ClearRuntimeGrants(ID_CALC);
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '{"a":20,"b":22}'), err);
  if Pos('"ok":true', dense) > 0 then
    restored := 'success:' + JsonRawField(dense, 'value')
  else
    restored := JsonStrField(dense, 'code');
  Emit('q29 next=' + next + ' restored=' + restored);
  Expect(next = 'forbidden', 'q29 next Add after revoke = ' + next);
  Expect(restored = 'success:42', 'q29 restore = ' + restored);
end;

procedure QLifecycle;
var
  dense, err: RawUtf8;
  json: RawUtf8;
  sinkCalls: LongInt;
  innerBase: LongInt;
begin
  // q16-q19: Quiesce/Close during the plugin thread's bounded wait. The
  // held invocation is parked IN the bridge when the source closes:
  // Close completes it as cancelled through its sink (the waiting plugin
  // thread resolves), the released worker's LATE result then dies at the
  // frozen exactly-once gate - measured through the sink's attempt
  // counter after an explicit rendezvous, never assumed.
  ArmBarrier;
  innerBase := InterlockedCompareExchange(HeldInnerReturned, 0, 0);
  Expect(gCalcPlugin.PostScript(
    InvokeScript(M_ADD, '{"a":20,"b":22,"hold":true}')),
    'q16 held post refused');
  if not WaitHeld(1) then
    Fail('q16 the held Add never parked at the barrier');
  gSrcCalc.Close; // full Quiesce semantics first, then Closed (frozen)
  if gCalcPlugin.WaitScript(json, err, SCRIPT_WAIT_MS) then
    dense := DenseJson(json)
  else
  begin
    dense := '';
    Fail('q16 the waiting plugin thread never resolved after Close');
  end;
  Emit('q16 close_inflight code=' + JsonStrField(dense, 'code') +
    ' status=' + JsonRawField(dense, 'status'));
  Expect(JsonStrField(dense, 'code') = 'cancelled',
    'q16 in-flight resolution = ' + JsonStrField(dense, 'code'));
  // release the parked worker; DETERMINISTIC rendezvous with the fact
  // that its held call returned from the real bridge - past this wait
  // the late CountAdd increment (corpus-pinned in q30) has happened and
  // the worker's terminal CompleteOnce is straight-line instructions
  // away, covered by the bounded settle below
  ReleaseBarrier;
  if not WaitInnerReturned(innerBase + 1) then
    Fail('q17 the released late worker never returned from the bridge');
  RTLEventResetEvent(InnerReturnedEvent);
  RTLEventWaitFor(InnerReturnedEvent, 100); // bounded settle; never set again
  sinkCalls := gCalcPlugin.LastSinkDeliveries;
  Emit('q17 late_completion sink_deliveries=' + IntStr(sinkCalls));
  Expect(sinkCalls = 1, 'q17 sink deliveries = ' + IntStr(sinkCalls));
  // q18: the closed source refuses new work synchronously
  dense := RunPlugin(gCalcPlugin, InvokeScript(M_ADD, '{"a":20,"b":22}'), err);
  Emit('q18 closed code=' + JsonStrField(dense, 'code'));
  Expect(JsonStrField(dense, 'code') = 'runtime_closed',
    'q18 closed source = ' + JsonStrField(dense, 'code'));
  // q19: unload destroys the engine ON ITS OWNING THREAD; the other
  // plugin keeps working through the shared runtime
  gCalcPlugin.Unload;
  Emit('q19 unload engine_destroyed_on_owner=' +
    YesNo(gCalcPlugin.EngineDestroyedOnOwnThread));
  Expect(gCalcPlugin.EngineDestroyedOnOwnThread,
    'q19 engine not destroyed on its owning thread');
  dense := RunPlugin(gRepPlugin,
    '(function(){try{var h=pweb.handshake();' +
    'return JSON.stringify({ok:true,protocol:h.protocol});}' +
    'catch(e){return JSON.stringify({ok:false,code:e.code});}})()', err);
  Emit('q19 other_plugin handshake=' + JsonRawField(dense, 'protocol'));
  Expect(JsonRawField(dense, 'protocol') = '1',
    'q19 the other plugin was affected by the unload');
end;

procedure QLedger;
begin
  // q30: the exact activity ledger. Expected NativeServiceAdd:
  //   q01 (1) + q20 other_add (1) + q26 native pair (2) + q28 held (1)
  //   + q29 restored (1) = 6.
  // The q16 late worker RESUMED past the barrier, but the real bridge
  // observes the cancelled token (pweb.rpc.mormot.pas Invoke entry) and
  // returns cancelled WITHOUT reaching the service - cooperative
  // cancellation working as ratified. Its delivery then died at the
  // exactly-once gate (q17 pinned sink_deliveries=1). So the service
  // count stays 6 while calc_bridge_add includes the late bridge entry.
  Emit('q30 ledger service_add=' + IntStr(NativeServiceAdd) +
    ' calc_bridge_add=' + IntStr(CountAdd[PRIN_CALC]) +
    ' rep_bridge_add=' + IntStr(CountAdd[PRIN_REP]) +
    ' opener_reached=' + IntStr(CountOpenReached) +
    ' handshake_calc=' + IntStr(CountHandshake[PRIN_CALC]) +
    ' handshake_rep=' + IntStr(CountHandshake[PRIN_REP]) +
    ' calc_cb_wrong_thread=' + IntStr(gCalcPlugin.CallbackWrongThreadCalls) +
    ' rep_cb_wrong_thread=' + IntStr(gRepPlugin.CallbackWrongThreadCalls));
  Expect(NativeServiceAdd = 6, 'q30 service add count = ' +
    IntStr(NativeServiceAdd) + ' expected 6');
  Expect(CountAdd[PRIN_REP] = 0, 'q30 denied principal reached the bridge');
  Expect(CountOpenReached = 0, 'q30 pweb.openExternal reached the bridge');
  Expect(gCalcPlugin.CallbackWrongThreadCalls = 0,
    'q30 a calc callback ran off its owning thread');
  Expect(gRepPlugin.CallbackWrongThreadCalls = 0,
    'q30 a rep callback ran off its owning thread');
  Expect(gCalcPlugin.CallbackCalls > 0, 'q30 no calc callback ever ran');
end;

{ ---- main ----------------------------------------------------------------- }

var
  outFile, corpusFile: TFileName;
  json, overall: RawUtf8;
  stream: TFileStream;
  limits: TPWebQuickJSLimits;
  srcLim: TPWebSourceLimits;

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
  ReleaseGate := RTLEventCreate;
  ArrivalEvent := RTLEventCreate;
  InnerReturnedEvent := RTLEventCreate;
  try
    try
      root := RepoRootFromExecutable;
      if root = '' then
        raise Exception.Create('repository root (webview.lock) not found from ' +
          string(Executable.ProgramFilePath));
      outFile := root + 'build' + PathDelim + 'cap9a' + PathDelim +
        'quickjsfoundation-' + TARGET_ID + '.json';
      if not ForceDirectories(ExtractFilePath(outFile)) then
        raise Exception.Create('unable to create ' +
          string(ExtractFilePath(outFile)));

      // ---- the production runtime under test ----
      gServer := TRestServerFullMemory.CreateWithOwnModel([]);
      if gServer.ServiceRegister(TCalculatorService,
           [TypeInfo(ICalculatorService)], sicShared) = nil then
        raise Exception.Create('unable to register CalculatorService');
      gRealBridge := TMormotInvocationBridge.Create(gServer, True);
      gServer := nil; // owned by the bridge now
      gBridge := TCountingBridge.Create(gRealBridge);
      gPolicy := BuildCap9aPolicy;
      gPolicyRef := gPolicy;
      gScheduler := TInvocationScheduler.Create(gPolicyRef, gBridge, 4);
      gSchedulerRef := gScheduler;
      gSnap := TSnapshotAdapter.Create;
      gSnapCb := gSnap.Snapshot; // Delphi-mode event assignment (mormot.defines.inc)

      srcLim := Default(TPWebSourceLimits);
      srcLim.MaxConcurrent := 1; // tight, for the q26/q27 saturation proof
      srcLim.MaxQueueSize := 1;
      gSrcCalc := gScheduler.RegisterSource(srcLim);
      srcLim.MaxConcurrent := 4;
      srcLim.MaxQueueSize := 16;
      gSrcRep := gScheduler.RegisterSource(srcLim);

      limits := PWEB_QUICKJS_DEFAULT_LIMITS;
      gCalcPlugin := TPWebQuickJSPlugin.Create(gSrcCalc,
        MakeContext(PRIN_CALC), limits, gSnapCb);
      gRepPlugin := TPWebQuickJSPlugin.Create(gSrcRep,
        MakeContext(PRIN_REP), limits, gSnapCb);
      if not gCalcPlugin.WaitReady(15000) then
        raise Exception.Create('calculator plugin bootstrap failed: ' +
          string(gCalcPlugin.InitError));
      if not gRepPlugin.WaitReady(15000) then
        raise Exception.Create('reporting plugin bootstrap failed: ' +
          string(gRepPlugin.InitError));

      Emit('schema=1');
      Emit('pin quickjs=2021-03-27 nanboxing=strict libc=none');
      AbiSection;    // + q24 churn
      QDecisions;    // q01-q15, q25, echo
      QLimits;       // q20-q23
      QBackpressure; // q26/q27
      QGrants;       // q28/q29
      QLifecycle;    // q16-q19 (closes the calculator source, unloads A)
      QLedger;       // q30

      gRepPlugin.Unload;
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
        if Pos('verdict=', CorpusLines) = 0 then
          Emit('verdict=FAIL');
        WriteCorpusFile;
      end;
    end;
  finally
    try
      FreeAndNil(gCalcPlugin);
      FreeAndNil(gRepPlugin);
      gSrcCalc := nil; gSrcRep := nil;
      gSchedulerRef := nil; gScheduler := nil;
      gPolicyRef := nil; gPolicy := nil;
      gBridge := nil; gRealBridge := nil;
      FreeAndNil(gSnap);
    except
    end;
    if ReleaseGate <> nil then RTLEventDestroy(ReleaseGate);
    if ArrivalEvent <> nil then RTLEventDestroy(ArrivalEvent);
    if InnerReturnedEvent <> nil then RTLEventDestroy(InnerReturnedEvent);
  end;

  // ---- the per-target record ----
  json := '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "target": "' + TARGET_ID + '",' + #10 +
    '  "overall": "' + overall + '",' + #10 +
    '  "service_add_count": ' + IntStr(NativeServiceAdd) + ',' + #10 +
    '  "denied_bridge_add": ' + IntStr(CountAdd[PRIN_REP]) + ',' + #10 +
    '  "opener_reached": ' + IntStr(CountOpenReached) + ',' + #10;
  if FailReasons <> '' then
    json := json + '  "failures": "' + JsonSafeText(FailReasons) + '"' + #10
  else
    json := json + '  "failures": null' + #10;
  json := json + '}' + #10;
  try
    stream := TFileStream.Create(outFile, fmCreate);
    try
      stream.WriteBuffer(json[1], Length(json));
    finally
      stream.Free;
    end;
  except
    on E: Exception do
      WriteLn(StdErr, LOG_PREFIX, ': could not write ', string(outFile),
        ': ', E.Message);
  end;

  if FailReasons = '' then
    WriteLn(MARKER_PASS)
  else
  begin
    WriteLn(StdErr, MARKER_FAIL, ' (', FailReasons, ')');
    ExitCode := 1;
  end;
end.
