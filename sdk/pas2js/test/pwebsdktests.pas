{
  pwebsdktests - deterministic Pas2JS SDK semantic suite (CAP-5).

  Compiled by the PINNED pas2js (deps/pas2js) to a Node.js program and
  executed under node against a capturing fake of the native primitive -
  the same technique as the TypeScript suite, so Pas2JS parity is proven
  by execution, never by source inspection. Covers every row of the
  CAP-5 I/O & edge-case matrix, then emits the canonical wire captures
  between PWEBSDK_CAPTURE_BEGIN/END markers for the cross-SDK parity
  gate.

  Output contract: one line per case (PASS/FAIL name), a final
  'PWEBSDK: <pass>/<total> PASS' summary, nonzero exit code on any
  failure.
}
program pwebsdktests;

{$mode objfpc}

uses
  SysUtils, JS, pweb.native;

type
  TFakePrimitive = reference to function(AMethod: String;
    AArgs: JSValue): TJSPromise;

var
  TotalCount: NativeInt = 0;
  FailCount: NativeInt = 0;
  Captured: TJSArray;

function GlobalObject: TJSObject; assembler;
asm
  return globalThis;
end;

procedure Check(const AName: String; ACond: Boolean);
begin
  Inc(TotalCount);
  if ACond then
    writeln('PASS ', AName)
  else
  begin
    Inc(FailCount);
    writeln('FAIL ', AName);
  end;
end;

procedure RemoveFake;
begin
  asm
    delete globalThis['__pweb_invoke'];
  end;
  Captured := TJSArray.new;
end;

procedure InstallFake(AHandler: TFakePrimitive);
var
  g: TJSObject;
  capturing: TFakePrimitive;
begin
  g := GlobalObject;
  capturing := function(AMethod: String; AArgs: JSValue): TJSPromise
    begin
      Captured.push(New(['method', AMethod, 'args', AArgs]));
      Result := AHandler(AMethod, AArgs);
    end;
  g[PWEB_NATIVE_BINDING_NAME] := JSValue(capturing);
end;

{ Installs an arbitrary raw value as the global, bypassing capture - for
  runtime-boundary probes (non-function, synchronously-throwing). }
procedure InstallRaw(AValue: JSValue);
var
  g: TJSObject;
begin
  g := GlobalObject;
  g[PWEB_NATIVE_BINDING_NAME] := AValue;
end;

function Resolving(AValue: JSValue): TFakePrimitive;
begin
  Result := function(AMethod: String; AArgs: JSValue): TJSPromise
    begin
      Result := TJSPromise.resolve(AValue);
    end;
end;

function Rejecting(AReason: JSValue): TFakePrimitive;
begin
  Result := function(AMethod: String; AArgs: JSValue): TJSPromise
    begin
      Result := TJSPromise.reject(AReason);
    end;
end;

function Envelope(const ACode, AMessage: String; AStatus: NativeInt;
  AData: JSValue): TJSObject;
begin
  Result := New(['code', ACode, 'message', AMessage, 'status', AStatus,
    'data', AData]);
end;

function MakeTypedBusy: EPWebError;
begin
  Result := EPWebError.CreateEnvelope('busy', 'custom', 429,
    New(['retryAfterMs', 9]));
end;

{ Settles APromise and resolves with the rejection reason, or JS.Null
  when the promise resolved (JS.Null never being a rejection reason from
  the SDK, which always rejects with EPWebError instances). }
function CaughtReason(APromise: TJSPromise): TJSPromise;
begin
  Result := APromise._then(
    function(AValue: JSValue): JSValue
    begin
      Result := JS.Null;
    end,
    function(AReason: JSValue): JSValue
    begin
      Result := AReason;
    end);
end;

function IsError(AReason: JSValue; const ACode: String): Boolean;
begin
  Result := (AReason <> JS.Null) and (TObject(AReason) is EPWebError) and
    (EPWebError(TObject(AReason)).Code = ACode);
end;

function Json(AValue: JSValue): String;
begin
  Result := TJSJSON.stringify(AValue);
end;

procedure RunAll; async;
var
  v, reason, marker: JSValue;
  args, suspicious: TJSObject;
  err: EPWebError;
  shapes, malformed, payloads: TJSArray;
  i: NativeInt;
  codes: array[0..8] of String;
  statuses: array[0..8] of NativeInt;
  throwing: TFakePrimitive;
  preTyped: EPWebError;
begin
  // --- integer success -------------------------------------------------
  InstallFake(Resolving(42));
  v := await(JSValue, PWebInvoke('CalculatorService.Add',
    New(['a', 20, 'b', 22])));
  Check('integer success resolves 42', Json(v) = '42');
  RemoveFake;

  // --- all JSON success shapes ----------------------------------------
  shapes := TJSArray._of(
    New(['user', 'ada', 'roles', TJSArray._of('admin')]),
    TJSArray._of(1, 'two', JS.Null, New(['three', 3])),
    'plain string', True, False, 0, 3.5, JS.Null);
  for i := 0 to shapes.length - 1 do
  begin
    InstallFake(Resolving(shapes[i]));
    v := await(JSValue, PWebInvoke('Any.Method', nil));
    Check('shape ' + IntToStr(i) + ' passes through unchanged',
      Json(v) = Json(shapes[i]));
    RemoveFake;
  end;

  // --- null success is distinct from an error -------------------------
  InstallFake(Resolving(JS.Null));
  v := await(JSValue, PWebInvoke('Void.Method', TJSObject.new));
  Check('null success resolves null', v = JS.Null);
  RemoveFake;

  // --- error-shaped success stays a success ---------------------------
  suspicious := Envelope('forbidden', 'Invocation is not allowed', 403,
    JS.Null);
  InstallFake(Resolving(suspicious));
  v := await(JSValue, PWebInvoke('Metadata.ErrorTable', nil));
  Check('error-shaped success is still a success', Json(v) = Json(suspicious));
  RemoveFake;

  // --- method identity byte-exact -------------------------------------
  InstallFake(Resolving(JS.Null));
  await(JSValue, PWebInvoke('calculatorService.add', nil));
  await(JSValue, PWebInvoke('CalculatorService.Add', nil));
  Check('method case preserved exactly',
    (String(TJSObject(Captured[0])['method']) = 'calculatorService.add') and
    (String(TJSObject(Captured[1])['method']) = 'CalculatorService.Add'));
  RemoveFake;

  // --- argument keys, casing, null values preserved; same reference ---
  InstallFake(Resolving(JS.Null));
  args := New(['A', 1, 'a', 2, 'Weird_KEY', JS.Null,
    'nested', New(['Inner', TJSArray._of(1, 2)])]);
  await(JSValue, PWebInvoke('Svc.Method', args));
  Check('argument keys and null values preserved',
    Json(TJSObject(Captured[0])['args']) =
    '{"A":1,"a":2,"Weird_KEY":null,"nested":{"Inner":[1,2]}}');
  // mutate the original AFTER the call: the capture must see it, proving
  // the SDK handed over the same object, not a clone
  marker := 12345;
  args['__marker'] := marker;
  Check('args passed by reference, not cloned',
    TJSObject(TJSObject(Captured[0])['args'])['__marker'] = marker);
  RemoveFake;

  // --- nil args sent as null ------------------------------------------
  InstallFake(Resolving(JS.Null));
  await(JSValue, PWebInvoke('Svc.NoArgs', nil));
  Check('nil args cross as JSON null',
    TJSObject(Captured[0])['args'] = JS.Null);
  RemoveFake;

  // --- service_error preserves structured data ------------------------
  InstallFake(Rejecting(Envelope('service_error', 'Insufficient funds',
    422, New(['domainCode', 'insufficient_funds', 'balance', 12.5]))));
  reason := await(JSValue, CaughtReason(
    PWebInvoke('Bank.Withdraw', New(['amount', 100]))));
  Check('service_error code+data preserved', IsError(reason, 'service_error'));
  if IsError(reason, 'service_error') then
  begin
    err := EPWebError(TObject(reason));
    Check('service_error fields intact',
      (err.Message = 'Insufficient funds') and (err.Status = 422) and
      (Json(err.Data) = '{"domainCode":"insufficient_funds","balance":12.5}'));
  end
  else
    Check('service_error fields intact', False);
  RemoveFake;

  // --- internal_error stays redacted ----------------------------------
  InstallFake(Rejecting(Envelope('internal_error', 'Internal error', 500,
    JS.Null)));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Blows', nil)));
  Check('internal_error redaction preserved',
    IsError(reason, 'internal_error') and
    (EPWebError(TObject(reason)).Message = 'Internal error') and
    (EPWebError(TObject(reason)).Data = JS.Null));
  RemoveFake;

  // --- busy metadata preserved ----------------------------------------
  InstallFake(Rejecting(Envelope('busy', 'Runtime is busy', 429,
    New(['retryAfterMs', 250]))));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Busy', nil)));
  Check('busy retry metadata preserved',
    IsError(reason, 'busy') and
    (Json(EPWebError(TObject(reason)).Data) = '{"retryAfterMs":250}'));
  RemoveFake;

  // --- every frozen code maps through ---------------------------------
  codes[0] := 'invalid_request'; statuses[0] := 400;
  codes[1] := 'method_not_found'; statuses[1] := 404;
  codes[2] := 'forbidden'; statuses[2] := 403;
  codes[3] := 'busy'; statuses[3] := 429;
  codes[4] := 'cancelled'; statuses[4] := 499;
  codes[5] := 'service_error'; statuses[5] := 422;
  codes[6] := 'internal_error'; statuses[6] := 500;
  codes[7] := 'runtime_closed'; statuses[7] := 503;
  codes[8] := 'protocol_mismatch'; statuses[8] := 426;
  for i := 0 to 8 do
  begin
    InstallFake(Rejecting(Envelope(codes[i], 'msg ' + codes[i],
      statuses[i], JS.Null)));
    reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
    Check('code ' + codes[i] + ' maps with fields',
      IsError(reason, codes[i]) and
      (EPWebError(TObject(reason)).Message = 'msg ' + codes[i]) and
      (EPWebError(TObject(reason)).Status = statuses[i]));
    RemoveFake;
  end;

  // --- status informative only: absent status falls back per code -----
  InstallFake(Rejecting(New(['code', 'forbidden', 'message', 'no',
    'data', JS.Null])));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('absent status falls back to frozen table',
    IsError(reason, 'forbidden') and
    (EPWebError(TObject(reason)).Status = 403));
  RemoveFake;

  // --- status presence rule: integers preserved, non-integers default -
  InstallFake(Rejecting(New(['code', 'forbidden', 'message', 'no',
    'status', 418, 'data', JS.Null])));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('integer status 418 preserved',
    IsError(reason, 'forbidden') and
    (EPWebError(TObject(reason)).Status = 418));
  RemoveFake;
  InstallFake(Rejecting(New(['code', 'forbidden', 'message', 'no',
    'status', -7, 'data', JS.Null])));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('negative integer status preserved',
    IsError(reason, 'forbidden') and
    (EPWebError(TObject(reason)).Status = -7));
  RemoveFake;
  InstallFake(Rejecting(New(['code', 'forbidden', 'message', 'no',
    'status', '500', 'data', JS.Null])));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('mistyped status falls back to frozen table',
    IsError(reason, 'forbidden') and
    (EPWebError(TObject(reason)).Status = 403));
  RemoveFake;
  InstallFake(Rejecting(New(['code', 'forbidden', 'message', 'no',
    'status', 1.5, 'data', JS.Null])));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('non-integer status falls back to frozen table',
    IsError(reason, 'forbidden') and
    (EPWebError(TObject(reason)).Status = 403));
  RemoveFake;

  // --- already-typed EPWebError rejection passes through unchanged ----
  preTyped := MakeTypedBusy;
  InstallFake(Rejecting(JSValue(preTyped)));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('typed EPWebError rejection passes through as the same instance',
    (TObject(reason) = TObject(preTyped)) and IsError(reason, 'busy'));
  RemoveFake;

  // --- undefined resolution normalized to null ------------------------
  InstallFake(Resolving(JS.Undefined));
  v := await(JSValue, PWebInvoke('Svc.Method', nil));
  Check('undefined resolution normalized to null', v = JS.Null);
  RemoveFake;

  // --- runtime detection reports presence truthfully ------------------
  InstallFake(Resolving(JS.Null));
  Check('binding reported present', PWebIsRuntime);
  RemoveFake;

  // --- malformed rejections map to generic internal_error -------------
  malformed := TJSArray._of(
    JSValue(TJSError.new('Failed to parse binding result as JSON')),
    'raw string reason', 12345, JS.Null, JS.Undefined,
    New(['notAnEnvelope', True]),
    New(['code', 'unauthorized', 'message', 'not a v1 code', 'status', 401]),
    New(['code', 42]),
    TJSArray._of('array', 'reason'));
  for i := 0 to malformed.length - 1 do
  begin
    InstallFake(Rejecting(malformed[i]));
    reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
    Check('malformed rejection ' + IntToStr(i) + ' maps to internal_error',
      IsError(reason, 'internal_error') and
      (EPWebError(TObject(reason)).Message = 'Internal error') and
      (EPWebError(TObject(reason)).Data = JS.Null));
    RemoveFake;
  end;

  // --- absent binding: immediate runtime_closed -----------------------
  RemoveFake;
  Check('binding reported absent', not PWebIsRuntime);
  reason := await(JSValue, CaughtReason(
    PWebInvoke('CalculatorService.Add', New(['a', 20, 'b', 22]))));
  Check('absent binding rejects runtime_closed',
    IsError(reason, 'runtime_closed'));

  // --- non-function global is not the primitive -----------------------
  InstallRaw(New(['invoke', 'not callable']));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('non-function global rejects runtime_closed',
    IsError(reason, 'runtime_closed'));
  RemoveFake;

  // --- synchronously-throwing primitive settles -----------------------
  throwing := function(AMethod: String; AArgs: JSValue): TJSPromise
    begin
      raise Exception.Create('native blew up synchronously');
      Result := nil; // unreachable
    end;
  InstallRaw(JSValue(throwing));
  reason := await(JSValue, CaughtReason(PWebInvoke('Svc.Method', nil)));
  Check('sync-throwing primitive maps to internal_error',
    IsError(reason, 'internal_error'));
  RemoveFake;

  // --- local input rejection before the wire --------------------------
  InstallFake(Resolving(1));
  reason := await(JSValue, CaughtReason(PWebInvoke('', nil)));
  Check('empty method rejected locally as invalid_request',
    IsError(reason, 'invalid_request'));
  reason := await(JSValue, CaughtReason(
    PWebInvoke('Svc.Method', TJSObject(JSValue(TJSArray._of(1, 2))))));
  Check('array args rejected locally as invalid_request',
    IsError(reason, 'invalid_request'));
  reason := await(JSValue, CaughtReason(
    PWebInvoke('Svc.Method', TJSObject(JSValue('a string')))));
  Check('primitive args rejected locally as invalid_request',
    IsError(reason, 'invalid_request'));
  Check('nothing crossed the wire on local rejection', Captured.length = 0);
  RemoveFake;

  // --- no capability-authority logic ----------------------------------
  InstallFake(Rejecting(Envelope('forbidden', 'Invocation is not allowed',
    403, JS.Null)));
  reason := await(JSValue, CaughtReason(
    PWebInvoke('secrets.read', TJSObject.new)));
  Check('call crosses; backend forbidden surfaces',
    IsError(reason, 'forbidden') and (Captured.length = 1) and
    (String(TJSObject(Captured[0])['method']) = 'secrets.read'));
  RemoveFake;

  // --- handshake: compatible ------------------------------------------
  InstallFake(Resolving(New(['protocol', 1, 'runtime', '0.1.0',
    'capabilities', TJSArray._of('settings.read')])));
  v := await(JSValue, PWebHandshake);
  Check('compatible handshake resolves info',
    (TPWebRuntimeInfo(v).Protocol = 1) and
    (TPWebRuntimeInfo(v).Runtime = '0.1.0') and
    (Json(JSValue(TPWebRuntimeInfo(v).Capabilities)) = '["settings.read"]'));
  Check('handshake crossed as pweb.handshake with null args',
    (String(TJSObject(Captured[0])['method']) = 'pweb.handshake') and
    (TJSObject(Captured[0])['args'] = JS.Null));
  RemoveFake;

  // --- handshake: capabilities absent still compatible ----------------
  InstallFake(Resolving(New(['protocol', 1, 'runtime', '0.1.0'])));
  v := await(JSValue, PWebHandshake);
  Check('handshake without capabilities resolves',
    TPWebRuntimeInfo(v).Protocol = 1);
  RemoveFake;

  // --- handshake: unknown members stripped from the projection --------
  InstallFake(Resolving(New(['protocol', 1, 'runtime', '0.1.0',
    'capabilities', TJSArray.new, 'extra', 'sneaky'])));
  v := await(JSValue, PWebHandshake);
  Check('handshake unknown members stripped',
    isUndefined(TJSObject(v)['extra']) and
    (TPWebRuntimeInfo(v).Protocol = 1) and
    (TPWebRuntimeInfo(v).Runtime = '0.1.0'));
  RemoveFake;

  // --- handshake: unsupported protocol --------------------------------
  InstallFake(Resolving(New(['protocol', 2, 'runtime', '9.9.9',
    'capabilities', TJSArray.new])));
  reason := await(JSValue, CaughtReason(PWebHandshake));
  Check('unsupported protocol rejects protocol_mismatch',
    IsError(reason, 'protocol_mismatch'));
  RemoveFake;

  // --- handshake: malformed payloads ----------------------------------
  payloads := TJSArray._of(
    JS.Null, 42, 'not an object', TJSArray._of(1), TJSObject.new,
    New(['protocol', '1', 'runtime', '0.1.0']),
    New(['protocol', 1.5, 'runtime', '0.1.0']),
    New(['protocol', 1]),
    New(['protocol', 1, 'runtime', '']),
    New(['protocol', 1, 'runtime', '0.1.0', 'capabilities', 'all']),
    New(['protocol', 1, 'runtime', '0.1.0',
      'capabilities', TJSArray._of(1, 2)]));
  for i := 0 to payloads.length - 1 do
  begin
    InstallFake(Resolving(payloads[i]));
    reason := await(JSValue, CaughtReason(PWebHandshake));
    Check('malformed handshake ' + IntToStr(i) + ' rejects protocol_mismatch',
      IsError(reason, 'protocol_mismatch'));
    RemoveFake;
  end;

  // --- handshake: native rejection passes untranslated ----------------
  InstallFake(Rejecting(Envelope('runtime_closed', 'Runtime is closed',
    503, JS.Null)));
  reason := await(JSValue, CaughtReason(PWebHandshake));
  Check('native rejection during handshake stays its own code',
    IsError(reason, 'runtime_closed'));
  RemoveFake;

  // --- handshake capabilities advisory: calls still cross -------------
  InstallFake(function(AMethod: String; AArgs: JSValue): TJSPromise
    begin
      if AMethod = PWEB_METHOD_HANDSHAKE then
        Result := TJSPromise.resolve(New(['protocol', 1,
          'runtime', '0.1.0', 'capabilities', TJSArray.new]))
      else
        Result := TJSPromise.resolve(42);
    end);
  await(JSValue, PWebHandshake);
  v := await(JSValue, PWebInvoke('CalculatorService.Add',
    New(['a', 20, 'b', 22])));
  Check('empty advisory capability list never blocks a call client-side',
    (Json(v) = '42') and (Captured.length = 2));
  RemoveFake;

  // --- canonical wire captures for the cross-SDK parity gate ----------
  InstallFake(function(AMethod: String; AArgs: JSValue): TJSPromise
    begin
      if AMethod = PWEB_METHOD_HANDSHAKE then
        Result := TJSPromise.resolve(New(['protocol', 1,
          'runtime', '0.1.0', 'capabilities', TJSArray.new]))
      else
        Result := TJSPromise.resolve(42);
    end);
  await(JSValue, PWebHandshake);
  await(JSValue, PWebInvoke('CalculatorService.Add', New(['a', 20, 'b', 22])));
  await(JSValue, PWebInvoke('CalculatorService.Add', New(['b', 22, 'a', 20])));
  await(JSValue, PWebInvoke('CaseSensitive.MiXeD', New([
    'Weird_KEY', JS.Null,
    'list', TJSArray._of(1, 'two', False, JS.Null),
    'nested', New(['Inner', New(['deep', 3.5])])])));
  await(JSValue, PWebInvoke('Svc.NoArgs', nil));
  writeln('PWEBSDK_CAPTURE_BEGIN');
  for i := 0 to Captured.length - 1 do
    writeln(Json(Captured[i]));
  writeln('PWEBSDK_CAPTURE_END');
  RemoveFake;

  // --- summary ---------------------------------------------------------
  writeln('PWEBSDK: ', TotalCount - FailCount, '/', TotalCount, ' PASS');
  if FailCount > 0 then
    asm
      process.exitCode = 1;
    end;
end;

begin
  Captured := TJSArray.new;
  RunAll;
end.
