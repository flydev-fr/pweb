{
  pweb.test.command - headless CAP-10A suite over the reusable runtime-command
  layer and the ratified development-trust invariants (mormot.core.test).

  Two subjects, both of which every target must agree on, and neither of which
  needs a window, a WebView, an engine or a bridge:

  1. THE RUNTIME-COMMAND DECORATOR (R1-R4). CAP-8B left pweb.openExternal as
     host-local interception; by the close of CAP-9 that had become four
     byte-similar private copies, and CAP-10B was about to generate more. The
     decision now lives once, in pweb.rpc.command, and this suite is what
     holds its semantics still:
       R1  an allowed https/mailto URI reaches the injected opener EXACTLY
           once and returns the success envelope;
       R2  a URI the shared validator refuses never reaches the opener at all
           (the opener counter reads zero, which is a measurement, not the
           absence of a code path);
       R3  an opener that answers false, or that raises, is a FAILURE -
           internal_error - and never a success and never an exception
           crossing a bridge call;
       R4  every other method is delegated to the inner bridge with its
           context, arguments and token unchanged.
     Plus the fail-closed construction rule: a nil inner bridge or a nil
     opener is refused at construction, so a host that declares the capability
     and supplies no opener dies at startup rather than answering something
     plausible at runtime.

  2. THE DEVELOPMENT-TRUST INVARIANT (T2-T3), mechanically, before any dev
     code exists. The ratified model keeps the privileged origin at pweb://app
     in development and production alike, and permits exactly one dev-only
     CSP data-channel allowance for React HMR - never an origin change, never
     in a production build. What this suite pins is the PRODUCTION half: the
     native CSP carries no ws:, no wss:, no localhost and no 127.0.0.1, and
     nothing but pweb://app is a trusted origin. If a future dev mode ever
     leaks its allowance into the production profile, this is where it turns
     red, on all four targets.
}

{$I mormot.defines.inc}

unit pweb.test.command;

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.command,
  pweb.navigation.policy;

type
  TTestRuntimeCommand = class(TSynTestCase)
  published
    procedure AllowedUriReachesOpenerOnce;
    procedure RefusedUriNeverReachesOpener;
    procedure OpenerFailureIsInternalError;
    procedure OtherMethodsDelegateUnchanged;
    procedure ConstructionFailsClosed;
    procedure ProductionTrustProfile;
  end;

implementation

var
  // the injected opener's ledger - a NUMBER this process measured, so
  // "never reached" is an observation and not an unread zero
  OpenerCalls: LongInt;
  OpenerLastUri: RawUtf8;
  OpenerAnswer: Boolean;
  OpenerRaises: Boolean;
  // the inner bridge's ledger
  InnerCalls: LongInt;
  InnerLastMethod: Utf8String;
  InnerLastArgs: TPWebJson;
  InnerLastPrincipal: RawUtf8;
  InnerSawToken: Boolean;
  // the observer's ledger
  ObservedRefused: LongInt;
  ObservedFailed: LongInt;
  ObservedOpened: LongInt;
  ObservedBytes: PtrInt;

function TestOpener(const Uri: RawUtf8): Boolean;
begin
  InterlockedIncrement(OpenerCalls);
  OpenerLastUri := Uri;
  if OpenerRaises then
    raise Exception.Create('deliberate opener failure');
  Result := OpenerAnswer;
end;

procedure TestObserver(const Context: TInvocationContext;
  Outcome: TPWebOpenOutcome; UriBytes: PtrInt);
begin
  ObservedBytes := UriBytes;
  case Outcome of
    pooRefused: InterlockedIncrement(ObservedRefused);
    pooFailed:  InterlockedIncrement(ObservedFailed);
    pooOpened:  InterlockedIncrement(ObservedOpened);
  end;
end;

type
  { the inner bridge: it records what it was handed and answers a value the
    decorator could not have produced, so "delegated unchanged" is checked
    on the payload rather than on the absence of a branch }
  TRecordingBridge = class(TInterfacedObject, IInvocationBridge)
  public
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

function TRecordingBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  InterlockedIncrement(InnerCalls);
  InnerLastMethod := Method;
  InnerLastArgs := Args;
  InnerLastPrincipal := RawUtf8(Context.PrincipalId);
  InnerSawToken := Token <> nil;
  Result := PWebSuccessResult('{"inner":true}');
end;

procedure ResetLedgers;
begin
  OpenerCalls := 0;
  OpenerLastUri := '';
  OpenerAnswer := True;
  OpenerRaises := False;
  InnerCalls := 0;
  InnerLastMethod := '';
  InnerLastArgs := '';
  InnerLastPrincipal := '';
  InnerSawToken := False;
  ObservedRefused := 0;
  ObservedFailed := 0;
  ObservedOpened := 0;
  ObservedBytes := -1;
end;

function MakeContext: TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.PrincipalKind := pkWindow;
  Result.PrincipalId := 'window:main';
  Result.WindowId := 'main';
  Result.TrustedContent := True;
end;

function MakeBridge: IInvocationBridge;
begin
  Result := TPWebRuntimeCommandBridge.Create(TRecordingBridge.Create,
    @TestOpener, @TestObserver);
end;

procedure TTestRuntimeCommand.AllowedUriReachesOpenerOnce;
var
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
begin
  ResetLedgers;
  bridge := MakeBridge;
  r := bridge.Invoke(MakeContext, PWEB_METHOD_OPEN_EXTERNAL,
    '{"url":"https://example.invalid/cap10a"}', nil);
  Check(r.Kind = prkSuccess, 'R1: https open succeeds');
  CheckEqual(r.Value, PWEB_JSON_NULL, 'R1: success carries JSON null');
  CheckEqual(OpenerCalls, 1, 'R1: the opener was reached exactly once');
  CheckEqual(OpenerLastUri, 'https://example.invalid/cap10a',
    'R1: the opener saw the exact authorized URI');
  CheckEqual(InnerCalls, 0, 'R1: the inner bridge never saw the command');
  CheckEqual(ObservedOpened, 1, 'R1: the host observed one open');
  CheckEqual(ObservedBytes, 30, 'R1: the observer is told the LENGTH only');

  ResetLedgers;
  bridge := MakeBridge;
  r := bridge.Invoke(MakeContext, PWEB_METHOD_OPEN_EXTERNAL,
    '{"url":"mailto:cap10a@example.invalid"}', nil);
  Check(r.Kind = prkSuccess, 'R1: mailto open succeeds');
  CheckEqual(OpenerCalls, 1, 'R1: mailto reached the opener exactly once');
end;

procedure TTestRuntimeCommand.RefusedUriNeverReachesOpener;
const
  REFUSED: array[0 .. 8] of RawUtf8 = (
    '{"url":"http://example.invalid/plain"}',      // wrong scheme
    '{"url":"file:///etc/passwd"}',                // wrong scheme
    '{"url":"javascript:alert(1)"}',               // wrong scheme
    '{"url":"ws://127.0.0.1:5173/"}',              // the dev channel is NOT
                                                   // an openable URI
    '{"url":"https://"}',                          // no authority
    '{"url":"mailto:"}',                           // no recipient
    '{"url":""}',                                  // empty
    '{}',                                          // absent argument
    'null');                                       // no arguments at all
var
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
  i: PtrInt;
begin
  for i := 0 to High(REFUSED) do
  begin
    ResetLedgers;
    bridge := MakeBridge;
    r := bridge.Invoke(MakeContext, PWEB_METHOD_OPEN_EXTERNAL, REFUSED[i],
      nil);
    Check(r.Kind = prkError, 'R2: refused vector ' + string(REFUSED[i]));
    Check(r.Error.Code = pecInvalidRequest,
      'R2: invalid_request for ' + string(REFUSED[i]));
    CheckEqual(OpenerCalls, 0,
      'R2: OPENER COUNT ZERO for ' + string(REFUSED[i]));
    CheckEqual(ObservedRefused, 1, 'R2: the host observed the refusal');
    CheckEqual(InnerCalls, 0, 'R2: the inner bridge saw nothing');
  end;
end;

procedure TTestRuntimeCommand.OpenerFailureIsInternalError;
var
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
begin
  // an opener that answers false
  ResetLedgers;
  OpenerAnswer := False;
  bridge := MakeBridge;
  r := bridge.Invoke(MakeContext, PWEB_METHOD_OPEN_EXTERNAL,
    '{"url":"https://example.invalid/x"}', nil);
  Check(r.Kind = prkError, 'R3: a refusing opener is an error');
  Check(r.Error.Code = pecInternalError, 'R3: internal_error');
  CheckEqual(OpenerCalls, 1, 'R3: the opener was still reached once');
  CheckEqual(ObservedFailed, 1, 'R3: the host observed the failure');

  // an opener that RAISES - the exception must die inside the decorator
  ResetLedgers;
  OpenerRaises := True;
  bridge := MakeBridge;
  r := bridge.Invoke(MakeContext, PWEB_METHOD_OPEN_EXTERNAL,
    '{"url":"https://example.invalid/x"}', nil);
  Check(r.Kind = prkError, 'R3: a raising opener is an error');
  Check(r.Error.Code = pecInternalError,
    'R3: a raising opener maps to internal_error, never crosses the bridge');
  CheckEqual(ObservedFailed, 1, 'R3: a raise is observed as a failure');
end;

procedure TTestRuntimeCommand.OtherMethodsDelegateUnchanged;
var
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
  ctx: TInvocationContext;
begin
  ResetLedgers;
  bridge := MakeBridge;
  ctx := MakeContext;
  r := bridge.Invoke(ctx, 'CalculatorService.Add', '{"a":20,"b":22}', nil);
  Check(r.Kind = prkSuccess, 'R4: the inner bridge answered');
  CheckEqual(r.Value, '{"inner":true}', 'R4: the inner value is verbatim');
  CheckEqual(InnerCalls, 1, 'R4: delegated exactly once');
  CheckEqual(InnerLastMethod, 'CalculatorService.Add',
    'R4: the method is unchanged');
  CheckEqual(InnerLastArgs, '{"a":20,"b":22}',
    'R4: the arguments are unchanged');
  CheckEqual(InnerLastPrincipal, 'window:main',
    'R4: the context is unchanged');
  CheckEqual(OpenerCalls, 0, 'R4: an ordinary method reaches no opener');
  // the runtime namespace is not swallowed either: only the ONE method this
  // layer implements is intercepted, and pweb.handshake still travels on
  ResetLedgers;
  bridge := MakeBridge;
  r := bridge.Invoke(ctx, PWEB_METHOD_HANDSHAKE, 'null', nil);
  CheckEqual(InnerCalls, 1, 'R4: pweb.handshake is delegated, not consumed');
  // exact, case-sensitive matching: a case variant is a different method
  ResetLedgers;
  bridge := MakeBridge;
  r := bridge.Invoke(ctx, 'pweb.OpenExternal',
    '{"url":"https://example.invalid/x"}', nil);
  CheckEqual(OpenerCalls, 0, 'R4: a case variant is NOT the command');
  CheckEqual(InnerCalls, 1, 'R4: a case variant is delegated like any other');
end;

procedure TTestRuntimeCommand.ConstructionFailsClosed;
var
  raised: Boolean;
  b: IInvocationBridge;
begin
  raised := False;
  try
    b := TPWebRuntimeCommandBridge.Create(nil, @TestOpener, nil);
  except
    on E: EPWebRuntimeCommand do
      raised := True;
  end;
  Check(raised, 'a nil inner bridge is refused at construction');
  raised := False;
  try
    b := TPWebRuntimeCommandBridge.Create(TRecordingBridge.Create, nil, nil);
  except
    on E: EPWebRuntimeCommand do
      raised := True;
  end;
  Check(raised,
    'a host with no platform opener is refused at construction, not at the '
    + 'first invocation');
  b := nil;
end;

procedure TTestRuntimeCommand.ProductionTrustProfile;
const
  FORBIDDEN: array[0 .. 4] of RawUtf8 = (
    'ws:', 'wss:', 'localhost', '127.0.0.1', 'http:');
var
  i: PtrInt;
begin
  // T2: the PRODUCTION security profile carries no development allowance of
  // any kind. The ratified dev exception is ONE ws://127.0.0.1:<port> CSP
  // data-channel entry added by a future dev configuration; it may never
  // appear here, and this is the row that says so.
  for i := 0 to High(FORBIDDEN) do
    Check(Pos(FORBIDDEN[i], PWEB_NATIVE_CSP) = 0,
      'T2: the production CSP must not contain ' + string(FORBIDDEN[i]));
  Check(Pos('connect-src ''self''', PWEB_NATIVE_CSP) > 0,
    'T2: connect-src stays self');
  // T3: the privileged origin is pweb://app, and a dev server URL is not a
  // trusted origin however plausible it looks
  Check(PWebNavTrustedUri('pweb://app/index.html'),
    'T3: pweb://app is the privileged origin');
  Check(not PWebNavTrustedUri('http://127.0.0.1:5173/index.html'),
    'T3: a Vite dev origin is never privileged');
  Check(not PWebNavTrustedUri('http://localhost:5173/index.html'),
    'T3: localhost is never privileged');
  // and the dev data channel is not an openable external URI either
  Check(not PWebValidExternalUri('ws://127.0.0.1:5173/'),
    'T2: the HMR channel is not something the OS may be handed');
end;

end.
