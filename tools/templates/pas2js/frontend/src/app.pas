unit app;

{ {{PROJECT_NAME}} - the application shell, compiled to JavaScript by Pas2JS.

  It reaches the native backend through the pweb.native SDK and through
  nothing else. There is no fetch, no WebSocket, no localhost, no HTTP client
  and no raw native primitive anywhere in this project: PWebInvoke and
  PWebHandshake are the whole of the frontend's contract with the runtime.

  Three calls are worth reading, because between them they show the entire
  model:

    PWebHandshake               what runtime am I talking to
    CalculatorService.Add       an application method your policy MAPPED
    Denied.Probe                a method your policy did not map, which is
                                therefore refused before the bridge sees it

  The last one is not an error to fix. It is the capability policy working:
  an unmapped method is `forbidden`, never `method_not_found`, so a frontend
  can never learn which methods exist by asking.

  The report at the end is this page telling the native side what it
  observed. It is a REPORT and not a permission: nothing a page sends can
  change a principal, a window or a capability.

  Asynchrony is the platform's. Every SDK entry point returns a TJSPromise,
  rejections arrive as typed EPWebError, and `Code` is the sole normative
  discriminator - `Status` is informative and application logic never
  branches on it. }

{$mode objfpc}

interface

procedure RunApp;

implementation

uses
  SysUtils, JS, Web, pweb.native;

const
  { The shell element, and the three cards the page fills in. Spelled once
    each: index.html and this unit have to agree, and a second spelling is
    a second contract. }
  SHELL_ID = 'pweb-app';
  SUM_ID = 'pweb-sum';
  RUNTIME_ID = 'pweb-runtime';
  REFUSAL_ID = 'pweb-refusal';
  { The sample arithmetic, stated rather than derived, so the expected
    answer in the native log and the numbers on the wire are one decision. }
  SUM_A = 20;
  SUM_B = 22;
  METHOD_ADD = 'CalculatorService.Add';
  { A method the policy in src/app.services.pas deliberately does not map. }
  DENIED_PROBE = 'Denied.Probe';
  { The application's own report channel - a zero-capability method, which
    is a different thing from an unmapped one: it is allowed, and it is
    validated like any other invocation. }
  METHOD_READY = 'app.ready';
  { The custom property app.css declares. Reading it back is the cheapest
    honest proof that the stylesheet was fetched, parsed and applied rather
    than merely requested. }
  STYLE_PROBE = '--pweb-styled';
  STYLE_TOKEN = 'yes';

var
  Shell: TJSElement;

procedure SetText(const AId, AText: String);
var
  el: TJSElement;
begin
  el := document.getElementById(AId);
  if el <> nil then
    el.textContent := AText;
end;

function StylesApplied: Boolean;
begin
  Result := (Shell <> nil) and
    (Trim(window.getComputedStyle(Shell).getPropertyValue(STYLE_PROBE)) =
     STYLE_TOKEN);
end;

function IsSecure: Boolean;
begin
  // window.isSecureContext, read dynamically (not surfaced by web.pas)
  Result := TJSObject(window)['isSecureContext'] = True;
end;

procedure Run; async;
var
  report: TJSObject;
  info, sum: JSValue;
  refusal: String;
begin
  // `js` is true by construction: this line is running, and it is running
  // because a Pascal program was compiled into the JavaScript that loaded
  report := New(['html', False, 'css', False, 'js', True,
    'secure', IsSecure, 'handshake', False, 'rpc', False, 'value', 0,
    'errmap', False]);
  refusal := '';
  try
    info := await(JSValue, PWebHandshake);
    report['handshake'] := (TPWebRuntimeInfo(info).Protocol = 1) and
      (TPWebRuntimeInfo(info).Runtime <> '');

    sum := await(JSValue, PWebInvoke(METHOD_ADD,
      New(['a', SUM_A, 'b', SUM_B])));
    report['value'] := sum;
    report['rpc'] := sum = (SUM_A + SUM_B);

    try
      await(JSValue, PWebInvoke(DENIED_PROBE, nil));
    except
      on E: EPWebError do
      begin
        refusal := E.Code;
        report['errmap'] := (E.Code = 'forbidden') and (E.Status = 403) and
          (E.Data = JS.Null);
      end;
    end;

    report['html'] := Shell <> nil;
    report['css'] := StylesApplied;

    SetText(SUM_ID, String(TJSJSON.stringify(sum)));
    SetText(RUNTIME_ID, TPWebRuntimeInfo(info).Runtime);
    SetText(REFUSAL_ID, DENIED_PROBE + ' -> ' + refusal);
  except
    on E: EPWebError do
      SetText(SUM_ID, 'FAILED: ' + E.Code + ' (' + IntToStr(E.Status) + ')');
    on E: Exception do
      SetText(SUM_ID, 'FAILED: ' + E.Message);
  end;
  try
    await(JSValue, PWebInvoke(METHOD_READY, report));
  except
    // The report channel failing is the host's problem to notice; it must
    // never take the page down with it.
  end;
end;

procedure RunApp;
begin
  Shell := document.getElementById(SHELL_ID);
  Run;
end;

end.
