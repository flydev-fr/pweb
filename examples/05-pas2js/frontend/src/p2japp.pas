{
  PWeb CAP-5 Pas2JS acceptance app.

  A real Pas2JS-compiled browser program that talks to the backend
  EXCLUSIVELY through the pweb.native SDK - never through the raw CAP-2
  primitive. Flow: pweb.handshake (protocol gate) ->
  CalculatorService.Add {a:20,b:22} -> render the 42 into the DOM ->
  report the machine verdict to the host through the same SDK.

  The logical call is IDENTICAL to the React example's: same method
  spelling, same named argument keys and values, same 42.

  CAP-8B adds the navigation-security block, and it too is identical to
  the React page's: the same five probe targets, in the same order,
  reported under the same member names. Every fact in it is OBSERVED by
  this page; none of it is inferred from "the page still works". The
  release host REQUIRES the block before it latches PASS, while this
  page's own `ok` deliberately excludes it - the same bundle also runs
  under the allow-all example hosts, which install no navigation guard,
  exactly as `denied` already works.
}
program p2japp;

{$mode objfpc}

uses
  SysUtils, JS, Web, pweb.native;

const
  { CAP-8B probe targets. `.invalid` is reserved by RFC 6761 and can
    never resolve, so a regression that let one of these through would
    still reach nothing - the failure is recorded, never acted on. }
  CSP_SCRIPT_PROBE = 'https://blocked.invalid/pweb-csp-probe.js'; // cap8b-navsec-probe
  WRONG_AUTHORITY_PROBE = 'pweb://evil/index.html';
  SAME_ORIGIN_CONTROL = '/index.html';
  EXTERNAL_NAV_PROBE = 'https://blocked.invalid/pweb-nav-probe'; // cap8b-navsec-probe
  { http: is NOT in the ratified external allowlist (https and mailto
    only), so this is a URI the native validator must refuse. }
  REFUSED_SCHEME_PROBE = 'http://blocked.invalid/pweb-open-probe'; // cap8b-navsec-probe
  EXTERNAL_OPEN_CAPABILITY = 'external.open';
  METHOD_OPEN_EXTERNAL = 'pweb.openExternal';
  METHOD_ECHO = 'pweb.echo';
  CSP_SCRIPT_DIRECTIVE = 'script-src';

var
  Display: TJSElement;
  { CAP-8B: the trusted document's own address, captured BEFORE anything
    can navigate away from it - "the page is still on pweb://app" is only
    a fact if the address it is compared against was recorded first. }
  StartHref: String;
  { Set by the policy-violation listener below, armed before anything can
    violate the policy and read once at the end. }
  CspBlocked: Boolean;

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

{ CAP-8B: a blocked external script is NOT provable from an error event -
  a script from an unresolvable host errors either way - so the only
  honest evidence is the policy-violation report itself. }
function OnCspViolation(Event: TEventListenerEvent): Boolean;
var
  directive: JSValue;
begin
  Result := True;
  directive := TJSObject(Event)['violatedDirective'];
  // Chromium names the effective directive (script-src-elem), WebKit
  // names script-src; both were MEASURED naming one of them, so match
  // the family rather than a single spelling.
  if isString(directive) and
     (Copy(String(directive), 1, Length(CSP_SCRIPT_DIRECTIVE)) =
      CSP_SCRIPT_DIRECTIVE) then
    CspBlocked := True;
end;

procedure ArmCspProbe;
var
  probe: TJSElement;
begin
  CspBlocked := False;
  document.addEventListener('securitypolicyviolation', @OnCspViolation);
  probe := document.createElement('script');
  TJSObject(probe)['src'] := CSP_SCRIPT_PROBE;
  document.head.appendChild(probe);
end;

function HasExternalOpen(AInfo: JSValue): Boolean;
var
  caps: JSValue;
begin
  // capabilities is ADVISORY metadata, and it is used here as exactly
  // that: not as an authorization, but as the page's only way to tell
  // that it is running under the release host - the one host that
  // installs a navigation guard - before attempting a navigation that
  // would otherwise destroy its own report channel.
  caps := TJSObject(AInfo)['capabilities'];
  Result := isArray(caps) and
    (TJSArray(caps).indexOf(EXTERNAL_OPEN_CAPABILITY) >= 0);
end;

procedure Run; async;
var
  verdict, fetchInit: TJSObject;
  info, v: JSValue;
  res: TJSResponse;
  opened: JSValue;
  ok, sameOriginServed, wrongAuthorityRefused: Boolean;
  openReturnedNull, yielded: Boolean;
begin
  // rendered proves this pas2js-compiled code found and can drive the DOM
  verdict := New(['ok', False, 'handshake', False, 'secure', IsSecure,
    'rendered', Display <> nil, 'rpc', False, 'errmap', False,
    'denied', False, 'navExternalBlocked', False,
    'navAuthorityBlocked', False, 'navCspBlocked', False,
    'navOpenExternal', False]);
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
    // CAP-8A deny probe: an UNMAPPED method through the production
    // contextual policy must come back as typed forbidden/403. The fact
    // is REPORTED here and REQUIRED only by the release-side gates:
    // under the deliberate allow-all hosts (examples 02-06) the same
    // probe reaches the bridge and 404s, so `denied` stays False
    // WITHOUT failing this page's own ok verdict. Same probe, same
    // reporting shape as the React page - the two SDKs prove the same
    // forbidden mapping.
    try
      await(JSValue, PWebInvoke('Denied.Probe', nil));
    except
      on E2: EPWebError do
        verdict['denied'] := (E2.Code = 'forbidden') and
          (E2.Status = 403) and (E2.Data = JS.Null);
    end;
    // CAP-8B wrong-authority SUBRESOURCE probe. The control comes first
    // and is load-bearing: `connect-src 'self'` was ratified over
    // `'none'` precisely because same-origin fetch has to keep working,
    // so a refusal only means something once the same request shape is
    // shown to succeed on the trusted authority.
    fetchInit := New(['cache', 'no-store']);
    sameOriginServed := False;
    try
      res := TJSResponse(await(JSValue,
        window.fetch(SAME_ORIGIN_CONTROL, fetchInit))); // cap8b-navsec-probe
      sameOriginServed := res.ok;
    except
      sameOriginServed := False;
    end;
    wrongAuthorityRefused := False;
    try
      // refused either by CSP (pweb://evil is a different origin) or by
      // the asset handler's constant refusal - both are "no bytes were
      // served", which is the property being asserted
      res := TJSResponse(await(JSValue,
        window.fetch(WRONG_AUTHORITY_PROBE, fetchInit))); // cap8b-navsec-probe
      wrongAuthorityRefused := not res.ok;
    except
      wrongAuthorityRefused := True;
    end;
    verdict['navAuthorityBlocked'] :=
      sameOriginServed and wrongAuthorityRefused;
    // CAP-8B external-open probe: pweb.openExternal is reachable and
    // capability-checked. invalid_request/400 is the ONLY answer that
    // proves both halves at once - the CAP-8A policy allowed the call
    // (an absent external.open would have been forbidden/403 before the
    // host ever saw it) and the native validator then refused a
    // non-allowlisted scheme. No browser is ever launched here: a
    // successful open is a side effect on the machine running the
    // smoke, and a gate must not need one.
    try
      await(JSValue, PWebInvoke(METHOD_OPEN_EXTERNAL,
        New(['url', REFUSED_SCHEME_PROBE])));
    except
      on E2: EPWebError do
        verdict['navOpenExternal'] := (E2.Code = 'invalid_request') and
          (E2.Status = 400) and (E2.Data = JS.Null);
    end;
    // CAP-8B external-NAVIGATION probe, attempted only where the runtime
    // advertises external.open - which is exactly the release host, the
    // only host that installs a navigation guard. Under the allow-all
    // example hosts the same attempt would succeed, replace this
    // document and destroy the report channel, so the probe is gated on
    // the advertised capability rather than on a build flag the page
    // cannot have.
    if HasExternalOpen(info) then
    begin
      // new window first: on Linux and macOS an opened window was
      // MEASURED to inherit the whole native transport, so this path has
      // to be exercised, not just the top-level one - and its RETURN
      // VALUE is evidence: a denied window.open comes back null on every
      // engine here, so a non-null return is a real window proxy the
      // deny failed to prevent
      openReturnedNull := False;
      try
        opened := window.open(EXTERNAL_NAV_PROBE, '_blank');
        openReturnedNull := (opened = JS.Null) or isUndefined(opened);
      except
        // a refusal that throws is still a refusal, and no window
        openReturnedNull := True;
      end;
      try
        window.location.href := EXTERNAL_NAV_PROBE;
      except
        // idem
      end;
      // a navigation assignment is asynchronous, so the page has to
      // yield before its own address means anything; a real native
      // round trip is a yield the page can actually prove happened
      yielded := False;
      try
        await(JSValue, PWebInvoke(METHOD_ECHO, New(['navprobe', 1])));
        yielded := True;
      except
        // a failed yield keeps navExternalBlocked False: without a
        // proven round-trip, "the address survived" would be a claim
        // racing the very navigation it is supposed to disprove
      end;
      verdict['navExternalBlocked'] := yielded and openReturnedNull and
        (window.location.href = StartHref) and
        (window.location.protocol = 'pweb:');
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
  // read as late as possible, and outside the try: the violation report
  // is queued by the engine, and every await above has since let the
  // task queue drain
  verdict['navCspBlocked'] := CspBlocked;
  document.removeEventListener('securitypolicyviolation', @OnCspViolation);
  try
    await(JSValue, PWebInvoke('example.report', verdict));
  except
    // the report channel itself failing is the host's problem to notice
  end;
end;

begin
  Display := document.getElementById('result');
  // CAP-8B: the address is captured and the policy-violation listener is
  // armed BEFORE any probe can move the page or violate the policy.
  StartHref := window.location.href;
  ArmCspProbe;
  Run;
end.
