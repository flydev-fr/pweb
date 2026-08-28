unit app.services;

{ {{PROJECT_NAME}} - the application half of a PWeb project.

  Everything in this unit is YOURS. The scaffold puts three things here and
  nothing else:

    the service      one mORMot interface and its implementation, reached
                     in-process through TRestServer.Uri - never over HTTP,
                     never over a socket, never over a port;
    the policy       what this application is allowed to do, stated in
                     native Pascal at the trust level of the executable;
    the bridge       one decorator over the frozen invocation bridge, for
                     the methods the application answers itself.

  The PWeb runtime is NOT here. It is not copied into this project and it is
  not vendored: the host composition, the scheduler, the binding, the
  WebView, the asset handler and the navigation guard all come from the PWeb
  SDK this project was created by, so a framework fix reaches this project
  without anyone editing it.

  THE POLICY IS THE INTERESTING PART, so read it before you extend it. A
  method that is not MAPPED is DENIED - `forbidden`, before the bridge is
  ever reached - and that is deliberate: adding a service method to the
  catalogue does not publish it. You publish it by naming its capability
  here, which is one visible act in one file. }

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.interfaces,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.capabilities.policy;

const
  /// the capability that authorizes the sample service. A capability is a
  // name in the frozen grammar [a-z0-9]+(.[a-z0-9]+)* and is matched
  // EXACTLY - there are no wildcards and no inheritance
  APP_CAP_CALCULATOR_ADD = 'calculator.add';
  /// the sample application method, spelled once
  APP_METHOD_ADD = 'CalculatorService.Add';
  /// the page reports what it observed through this method. It is
  // capability-FREE rather than unmapped, which is a different thing: an
  // unmapped method is denied, and a zero-capability method is allowed
  // while still being validated like any other invocation
  APP_METHOD_READY = 'app.ready';
  /// the one line this application prints when its frontend has reported.
  // A single spelling, so a script that watches for it can never watch for
  // a line nobody emits
  APP_READY_MARKER = ': ready ';

type
  /// the sample service. Parameter NAMES are public API: renaming `a` or
  // `b` is a breaking change for every frontend that calls this method
  ICalculatorService = interface(IInvokable)
    ['{3F1B6C42-7A55-4E0D-9C31-2D8E4B0A6F17}']
    function Add(a, b: Integer): Integer;
  end;

  TCalculatorService = class(TInterfacedObject, ICalculatorService)
  public
    function Add(a, b: Integer): Integer;
  end;

  { The application's own decorator over the frozen bridge. Everything it
    does not implement passes straight through, unchanged, to the inner
    bridge on a scheduler worker thread. }
  TAppBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    FPrefix: RawUtf8;
  public
    constructor Create(const AInner: IInvocationBridge;
      const APrefix: RawUtf8);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

/// the production capability policy of this application
// - built ONLY from native Pascal at the trust level of the executable:
// never from app.pwb, a manifest, JavaScript, the environment or any file
// - any malformed row raises and the application refuses to start, which is
// fail-closed construction rather than a runtime surprise
function BuildAppPolicy: TPWebCapabilityPolicy;


implementation

function TCalculatorService.Add(a, b: Integer): Integer;
begin
  Result := a + b;
end;

constructor TAppBridge.Create(const AInner: IInvocationBridge;
  const APrefix: RawUtf8);
begin
  inherited Create;
  if AInner = nil then
    raise Exception.Create('TAppBridge requires an inner bridge');
  FInner := AInner;
  FPrefix := APrefix;
end;

function TAppBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  if Method = APP_METHOD_READY then
  begin
    // the frontend's own observation of the wiring, printed verbatim. It
    // is a REPORT and never an authorization: nothing in this payload can
    // change a principal, a window or a capability
    WriteLn(FPrefix, APP_READY_MARKER, Args);
    Result := PWebSuccessResult(PWEB_JSON_NULL);
  end
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

function BuildAppPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    // the explicit ceiling of this application. It is a NATIVE trust
    // anchor: app.pwb can never enlarge it, and an empty set would mean no
    // rights at all rather than unrestricted ones
    b.SetAppMaximum([APP_CAP_CALCULATOR_ADD]);
    // the one window and its principal
    b.SetWindowCapabilities('main', [APP_CAP_CALCULATOR_ADD]);
    b.SetPrincipalCapabilities('window:main', [APP_CAP_CALCULATOR_ADD]);
    // the one application method. Add yours the same way: a method that is
    // not named here is denied before the bridge sees it
    b.MapMethod(APP_METHOD_ADD, [APP_CAP_CALCULATOR_ADD]);
    // runtime-owned and application-owned methods that need no capability
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(APP_METHOD_READY);
    // DELIBERATELY ABSENT: pweb.openExternal. The runtime command layer is
    // installed, as it is in every PWeb host, but this application does not
    // authorize it - so handing a URI to the operating system is answered
    // forbidden at the policy and the opener is never reached. Map it here
    // when your application genuinely needs to open a link.
    Result := b.Build;
  finally
    b.Free;
  end;
end;

end.
