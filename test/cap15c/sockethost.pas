program sockethost;

{ CAP-15C: the BUILT IMAGE under test.

  A console witness that links exactly what a generated application's
  network region links for the socket door, and nothing a window would drag
  in. The gates use it for the claims that are properties of a BINARY:

    B1  PWEB_NATIVE_CSP is in the image, byte-identical to the shipped
        constant - the socket door changed nothing there
    B2  the socket decorator, its capability and its method names are in
        the image IFF the network region was compiled
    B3  the release image carries no `ws://` loopback literal, and THE SWEEP
        IS PROVEN TO FIRE on a twin compiled with -dCAP15C_PLANT_WS. No
        other image can serve as that twin: the door derives a `ws://`
        authority from a declared `http://` loopback origin BY PARSED
        COMPONENTS, so not even a development image carries the literal
    B4  on Windows and Linux the compiled unit set carries mormot.net.sock
        and the socket transport and NO mormot.net.ws.* or mormot.net.server;
        on Darwin it carries the Cocoa adapter and no mORMot transport

  WHY NOT THE GENERATED HOST ITSELF - the CAP-15B reason, unchanged: a
  generated program links pweb.webview.host, which needs the platform
  WebView library to link and a display to run, and neither is part of any
  claim above. test/cap15c/check_cap15c_contracts.ps1 (K7) asserts this
  witness carries the template's constructs, so it cannot drift from what a
  real generated host compiles.

  Usage: sockethost   (prints the digests, the door line and the CSP length) }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  pweb.rpc.intf,
  pweb.navigation.policy,
  pweb.capabilities.policy,
  // CAP-16: every generated host composes the signal channel
  pweb.rpc.signal,
  {$ifdef PWEB_NET}
  pweb.rpc.fetch,
  pweb.rpc.socket,
  {$ifdef DARWIN}
  pweb.platform.cocoa.fetch,
  pweb.platform.cocoa.socket,
  {$else}
  pweb.rpc.fetch.mormot,
  pweb.rpc.socket.mormot,
  {$endif DARWIN}
  {$endif PWEB_NET}
  pweb.rpc.bridge.dummy;

{$ifdef PWEB_NET}
{$I app.network.inc}
{$endif PWEB_NET}

{$ifdef CAP15C_PLANT_WS}
const
  // THE FIRING TWIN: the one literal the release sweep exists to refuse,
  // planted so the sweep is observed to find it
  CAP15C_PLANTED_WS = 'ws://127.0.0.1:5173/';
{$endif CAP15C_PLANT_WS}

var
  inner, bridge: IInvocationBridge;
  signals: TPWebSignalChannel;
  builder: TPWebCapabilityPolicyBuilder;
  policy: TPWebCapabilityPolicy;
  {$ifdef PWEB_NET}
  socketBridge: TPWebSocketBridge;
  {$endif PWEB_NET}

begin
  inner := TDummyInvocationBridge.Create;
  bridge := inner;
  {$ifdef PWEB_NET}
  bridge := TPWebFetchBridge.Create(bridge, @PWebFetchNativeTransport,
    APP_NETWORK_ORIGINS);
  socketBridge := TPWebSocketBridge.Create(bridge,
    PWebSocketNativeTransport, APP_NETWORK_ORIGINS);
  bridge := socketBridge;
  {$endif PWEB_NET}
  signals := TPWebSignalChannel.Create(bridge, []);
  bridge := signals;
  {$ifdef PWEB_NET}
  socketBridge.AttachSignals(signals);
  {$endif PWEB_NET}
  builder := TPWebCapabilityPolicyBuilder.Create;
  try
    {$ifdef PWEB_NET}
    builder.SetAppMaximum([PWEB_CAP_NETWORK_SOCKET]);
    builder.MapMethod(PWEB_METHOD_SOCKET_OPEN, [PWEB_CAP_NETWORK_SOCKET]);
    builder.MapMethod(PWEB_METHOD_SOCKET_SEND, [PWEB_CAP_NETWORK_SOCKET]);
    builder.MapMethod(PWEB_METHOD_SOCKET_RECEIVE, [PWEB_CAP_NETWORK_SOCKET]);
    builder.MapMethod(PWEB_METHOD_SOCKET_CLOSE, [PWEB_CAP_NETWORK_SOCKET]);
    {$else}
    builder.SetAppMaximum([]);
    {$endif PWEB_NET}
    builder.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_SUBSCRIBE);
    builder.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_UNSUBSCRIBE);
    policy := builder.Build;
  finally
    builder.Free;
  end;
  // the host's own call, made here because this witness runs no host
  signals.AttachPolicy(policy);
  {$ifdef PWEB_NET}
  WriteLn('network ', PWebFetchDeclaredDigest(APP_NETWORK_ORIGINS), ' ',
    APP_NETWORK_ALLOWLIST_DIGEST);
  WriteLn('socket ', PWEB_CAP_NETWORK_SOCKET, ' ', PWEB_METHOD_SOCKET_OPEN,
    ' ', PWEB_SOCKET_MAX_SOCKETS, ' open=', socketBridge.OpenCount);
  {$else}
  WriteLn('network none none');
  WriteLn('socket none');
  {$endif PWEB_NET}
  WriteLn('signal ', PWEB_METHOD_SIGNAL_SUBSCRIBE, ' topics=',
    signals.TopicCount);
  // the host's drain seam: the channel first, then its door
  signals.BeforeDrain;
  bridge := nil;
  {$ifdef CAP15C_PLANT_WS}
  WriteLn('planted ', CAP15C_PLANTED_WS);
  {$endif CAP15C_PLANT_WS}
  WriteLn('csp ', Length(PWEB_NATIVE_CSP));
  inner := nil;
end.
