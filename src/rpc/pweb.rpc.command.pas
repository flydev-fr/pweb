{
  pweb.rpc.command - the reusable PWeb runtime-command layer (CAP-10A).

  ONE implementation of the runtime-owned commands that the FROZEN bridge
  deliberately does not implement, shared by every host present and future.

  ---------------------------------------------------------------------------
  WHY THIS UNIT EXISTS
  ---------------------------------------------------------------------------

  CAP-8B placed `pweb.openExternal` in host-local interception as a staging
  solution, and by CAP-9C2 that staging had produced FOUR byte-similar private
  copies of the same twenty lines: the CAP-6 release host, the CAP-9 QuickJS
  host, the CAP-8B real-window navigation matrix and the CAP-8C multi-principal
  harness. Every one of them decided the same three things - is the argument a
  valid external URI, was the opener reached, what envelope comes back - and
  every one of them could drift from the others without a single gate turning
  red. CAP-10B is about to generate hosts, which would have multiplied the copy
  rather than the contract.

  So the DECISION moves here, exactly once, and the hosts keep only what is
  genuinely theirs: which platform opener to call, and what to count or log.

  ---------------------------------------------------------------------------
  THE SHAPE, AND WHAT IT DELIBERATELY IS NOT
  ---------------------------------------------------------------------------

    invocation
      -> IInvocationSource.TryEnqueue        (frozen)
      -> scheduler worker                    (frozen)
      -> ICapabilityPolicy at the ONE call site (frozen; authoritative)
      -> TPWebRuntimeCommandBridge           (this unit)
           pweb.openExternal -> validate -> host opener -> envelope
           anything else     -> FInner.Invoke, verbatim
      -> the application/mORMot bridge

  This is an IInvocationBridge DECORATOR and nothing else. There is no new
  interface, no eighth boundary, no second RPC path, no new scheduler hook and
  no change to IInvocationBridge - a host installs it in the same decorator
  chain it already builds. `pweb.rpc.mormot.pas` is untouched by construction:
  a runtime-owned method has no business inside the mORMot adapter.

  WHY NO CAPABILITY CHECK HERE. The CAP-8A policy already ran at the scheduler,
  BEFORE the bridge. A principal without `external.open` was answered
  forbidden/403 and never reached this code at all - the opener count for such
  a principal is zero because nothing ran, not because something declined. A
  second copy of an authorization rule is a second answer to one question.

  WHY NO NAVIGATION PATH REACHES THIS. CAP-8B MEASURED that user activation
  cannot be reported honestly by any of the four engines, so every raw external
  navigation inside a privileged WebView is cancelled and handing a URI to the
  operating system became an ordinary, explicitly authorized invocation. See
  pweb.navigation.policy's header for the measurements.

  ---------------------------------------------------------------------------
  ZERO PLATFORM DIVERGENCE, BY CONSTRUCTION
  ---------------------------------------------------------------------------

  The opener is INJECTED. This unit therefore carries no {$ifdef}, names no
  operating system, constructs no command string, and starts no process - and
  the CAP-7F divergence sweep can hold it at zero conditionals forever. The
  three-branch platform selection stays host-private, which is what "the host
  supplies the opener" means: the release host hands over ShellExecuteExW /
  g_app_info_launch_default_for_uri / -[NSWorkspace openURL:] through its own
  one-line selector, and this unit never learns which one it got.

  FAIL CLOSED. The constructor refuses a nil inner bridge and a nil opener. A
  host that has no opener does not install this decorator at all; a host that
  installs it with none is a construction error, loudly, at startup - never a
  runtime path that silently answers something plausible.

  Called on a scheduler WORKER thread, never the GUI thread: a bridge always
  is. Concurrent Invoke calls share no mutable state here.
}
unit pweb.rpc.command;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.json,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.navigation.policy;

const
  { The canonical external-open method, spelled ONCE for the whole
    repository. It lives in the reserved pweb.* namespace because it is
    runtime-owned, not application surface - which is also why the frozen
    bridge answers method_not_found for it and why it is intercepted here. }
  PWEB_METHOD_OPEN_EXTERNAL = 'pweb.openExternal';

  { The capability that authorizes it, spelled ONCE. The mapping
    pweb.openExternal -> external.open is the exact CAP-8 mapping and is
    applied by the host's policy configuration, never by this unit. }
  PWEB_CAP_EXTERNAL_OPEN = 'external.open';

type
  { Raised only for direct misuse of this API at construction time. The
    command path itself never raises across a bridge call. }
  EPWebRuntimeCommand = class(Exception);

  { The host's private platform opener. Hands ONE already-validated URI to
    the operating system as DATA through one public API - never a shell
    string, never a command line, never a subprocess. Returns False on any
    refusal or failure; must not raise (this unit contains it anyway). }
  TPWebExternalOpener = function(const Uri: RawUtf8): Boolean;

  { What one external-open attempt did, for the host's own accounting. }
  TPWebOpenOutcome = (
    /// the URI failed PWebValidExternalUri - no opener activity of any kind
    pooRefused,
    /// the opener was reached and reported failure (or raised)
    pooFailed,
    /// the opener was reached and reported success
    pooOpened);

  { The host's private observation hook: logging in the production hosts,
    counters in the gate harnesses. It DECIDES nothing - it is called after
    the outcome is already settled, and its result is ignored.

    UriBytes is the byte LENGTH of the requested URI, never the URI: the
    redaction contract is that neither the query string, nor a mailto body,
    nor even the host ever reaches a log or a counter. }
  TPWebOpenObserver = procedure(const Context: TInvocationContext;
    Outcome: TPWebOpenOutcome; UriBytes: PtrInt);

  { The reusable runtime-command decorator. }
  TPWebRuntimeCommandBridge = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    FOpener: TPWebExternalOpener;
    FObserver: TPWebOpenObserver;
    function OpenExternal(const Context: TInvocationContext;
      const Args: TPWebJson): TPWebInvocationResult;
  public
    { Fail closed: a nil inner bridge or a nil opener is refused here, at
      startup, rather than becoming a runtime surprise. }
    constructor Create(const AInner: IInvocationBridge;
      AOpener: TPWebExternalOpener; AObserver: TPWebOpenObserver = nil);
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

implementation

constructor TPWebRuntimeCommandBridge.Create(const AInner: IInvocationBridge;
  AOpener: TPWebExternalOpener; AObserver: TPWebOpenObserver);
begin
  inherited Create;
  if AInner = nil then
    raise EPWebRuntimeCommand.Create(
      'TPWebRuntimeCommandBridge requires an inner bridge');
  if not Assigned(AOpener) then
    raise EPWebRuntimeCommand.Create(
      'TPWebRuntimeCommandBridge requires a platform opener');
  FInner := AInner;
  FOpener := AOpener;
  FObserver := AObserver;
end;

function TPWebRuntimeCommandBridge.OpenExternal(
  const Context: TInvocationContext;
  const Args: TPWebJson): TPWebInvocationResult;
var
  payload, uri: RawUtf8;
  opened: Boolean;
begin
  // JsonDecode unescapes IN PLACE, so it must never walk the caller's
  // buffer: Args belongs to the invocation, not to this function
  payload := Args;
  UniqueRawUtf8(payload);
  uri := JsonDecode(payload, 'url');
  // the shared classifier owns the WHOLE allowlist - parsed scheme
  // (https/mailto only), bounded length, no control bytes, authority or
  // recipient present. Anything it refuses is invalid_request and never
  // reaches an opener; a missing, non-string or malformed argument
  // collapses to the empty string here and is refused by the same test.
  if not PWebValidExternalUri(uri) then
  begin
    if Assigned(FObserver) then
      FObserver(Context, pooRefused, Length(uri));
    exit(PWebDefaultErrorResult(pecInvalidRequest));
  end;
  opened := False;
  try
    opened := FOpener(uri);
  except
    // an opener that raised is a FAILURE, never a success - and the
    // exception dies here rather than travelling out of a bridge call
    opened := False;
  end;
  if not opened then
  begin
    if Assigned(FObserver) then
      FObserver(Context, pooFailed, Length(uri));
    // a category, never a native detail. The trusted page is exactly where
    // it was: there is no internal-navigation fallback anywhere on this path
    exit(PWebDefaultErrorResult(pecInternalError));
  end;
  if Assigned(FObserver) then
    FObserver(Context, pooOpened, Length(uri));
  Result := PWebSuccessResult(PWEB_JSON_NULL);
end;

function TPWebRuntimeCommandBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  // exact, case-sensitive match on the canonical method - the single
  // canonicalization point upstream already produced it
  if Method = PWEB_METHOD_OPEN_EXTERNAL then
    Result := OpenExternal(Context, Args)
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

end.
