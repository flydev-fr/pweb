{
  PWeb CAP-5 Pas2JS acceptance app.

  A real Pas2JS-compiled browser program that talks to the backend
  EXCLUSIVELY through the pweb.native SDK - never through the raw CAP-2
  primitive. Flow: pweb.handshake (protocol gate) ->
  CalculatorService.Add {a:20,b:22} -> render the 42 into the DOM ->
  report the machine verdict to the host through the same SDK.

  The logical call is IDENTICAL to the React example's: same method
  spelling, same named argument keys and values, same 42.
}
program p2japp;

{$mode objfpc}

uses
  SysUtils, JS, Web, pweb.native;

var
  Display: TJSElement;

procedure SetDisplay(const AText: String);
begin
  if Display <> nil then
    Display.textContent := AText;
end;

function IsSecure: Boolean;
begin
  // window.isSecureContext, read dynamically (not surfaced by web.pas)
  Result := TJSObject(window)['isSecureContext'] = True;
end;

procedure Run; async;
var
  verdict: TJSObject;
  info, v: JSValue;
  ok: Boolean;
begin
  // rendered proves this pas2js-compiled code found and can drive the DOM
  verdict := New(['ok', False, 'handshake', False, 'secure', IsSecure,
    'rendered', Display <> nil, 'rpc', False, 'errmap', False]);
  try
    info := await(JSValue, PWebHandshake);
    verdict['handshake'] := (TPWebRuntimeInfo(info).Protocol = 1) and
      (TPWebRuntimeInfo(info).Runtime <> '');
    v := await(JSValue, PWebInvoke('CalculatorService.Add',
      New(['a', 20, 'b', 22])));
    verdict['value'] := v;
    verdict['rpc'] := v = 42;
    // real-rejection probe: an unregistered method must surface through
    // the REAL binding+shim as a typed method_not_found
    try
      await(JSValue, PWebInvoke('No.SuchMethod', nil));
    except
      on E2: EPWebError do
        verdict['errmap'] := (E2.Code = 'method_not_found') and
          (E2.Status = 404) and (E2.Data = JS.Null);
    end;
    ok := (verdict['handshake'] = True) and (verdict['secure'] = True) and
      (verdict['rendered'] = True) and (verdict['rpc'] = True) and
      (verdict['errmap'] = True);
    verdict['ok'] := ok;
    if ok then
      SetDisplay('CalculatorService.Add(20, 22) = ' +
        TJSJSON.stringify(v))
    else
      SetDisplay('FAILED');
  except
    on E: EPWebError do
    begin
      verdict['error'] := 'EPWebError:' + E.Code + ': ' + E.Message;
      SetDisplay('FAILED: ' + E.Code + ': ' + E.Message);
    end;
    on E: Exception do
    begin
      verdict['error'] := E.ClassName + ': ' + E.Message;
      SetDisplay('FAILED: ' + E.Message);
    end;
  end;
  try
    await(JSValue, PWebInvoke('example.report', verdict));
  except
    // the report channel itself failing is the host's problem to notice
  end;
end;

begin
  Display := document.getElementById('result');
  Run;
end.
