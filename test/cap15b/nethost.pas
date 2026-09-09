program nethost;

{ CAP-15B: the BUILT IMAGE under test.

  A console witness that links exactly what a generated application's
  network region links, and nothing a window would drag in. The gates use it
  for the four claims that are properties of a BINARY rather than of a run:

    B1  PWEB_NATIVE_CSP is in the image, byte-identical to the shipped
        constant. Door A's strongest claim is that it changes nothing here,
        and the image says so mechanically
    B2  the compiled allowlist digest EQUALS the one computed from
        pweb.json - declared == compiled, at the bytes
    B3  the image carries no relaxation. Compiled TWICE, once as a release
        (https origins) and once with the ratified development loopback
        origin, so the sweep is proven to FIRE as well as to pass
    B4  `mormot.net.client` is on this compiled unit set, and is absent from
        the same program compiled without PWEB_NET

  WHY NOT THE GENERATED HOST ITSELF. A generated program.lpr links
  pweb.webview.host, which needs the platform WebView library at link time
  and a display at run time; neither is part of any claim above. What makes
  this witness honest instead of convenient is that
  test/cap15b/check_cap15b_contracts.ps1 asserts the THREE constructs below
  appear in both shipped templates' program.lpr inside the same
  PWEB_NET region: the uses entry, the {$I app.network.inc}, and the
  TPWebFetchBridge construction. The witness cannot drift from the template
  without that check going red.

  Usage: nethost --print   (prints the two digests and the CSP length) }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.navigation.policy,
  {$ifdef PWEB_NET}
  pweb.rpc.fetch,
  {$ifdef DARWIN}
  pweb.platform.cocoa.fetch,
  {$else}
  pweb.rpc.fetch.mormot,
  {$endif DARWIN}
  {$endif PWEB_NET}
  pweb.rpc.bridge.dummy;

{$ifdef PWEB_NET}
{$I app.network.inc}
{$endif PWEB_NET}

var
  inner: IInvocationBridge;
  {$ifdef PWEB_NET}
  bridge: IInvocationBridge;
  {$endif PWEB_NET}

begin
  inner := TDummyInvocationBridge.Create;
  {$ifdef PWEB_NET}
  bridge := TPWebFetchBridge.Create(inner, @PWebFetchNativeTransport,
    APP_NETWORK_ORIGINS);
  // the allowlist this binary carries, RECOMPUTED from the compiled array,
  // beside the digest the build declared
  WriteLn('network ', PWebFetchDeclaredDigest(APP_NETWORK_ORIGINS), ' ',
    APP_NETWORK_ALLOWLIST_DIGEST);
  WriteLn('origins ', Length(APP_NETWORK_ORIGINS));
  bridge := nil;
  {$else}
  WriteLn('network none none');
  WriteLn('origins 0');
  {$endif PWEB_NET}
  WriteLn('csp ', Length(PWEB_NATIVE_CSP));
  inner := nil;
end.
