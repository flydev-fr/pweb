{
  pweb.webview.intf - PWeb WebView-side contracts (Phase 0 freeze).

  Engine-agnostic by ratified constraint: no browser-engine or platform
  identifier appears in these signatures (core-interfaces.md
  must-not-reference column). This unit may use pweb.rpc.intf; the
  reverse dependency is forbidden - the scheduler is defined over
  invocation sources, and the WebView binding is only one source
  (threading-model.md; conventions.md).

  Canonical sources for every semantic encoded here:
    - core-interfaces.md  : IWebView / IWebViewBinding responsibilities.
    - threading-model.md  : GUI-thread affinity, callback duties,
                            pre-queue rejection, dispatch direction,
                            bind/unbind userdata lifetime.
    - wire-semantics.md   : source lifecycle, exactly-once completion.

  The handle-use lease is deliberately ABSENT from these public
  contracts: it protects the native handle and is owned by the
  IWebViewBinding implementation internally (core-interfaces.md);
  only the cooperative cancellation token is public. Native-handle
  access is deliberately absent from IWebView for the same reason:
  platform resource-handler units access the concrete implementation,
  and the handle never enters the frozen contract.

  Native ownership - ratified: IWebView is the native-view lifetime
  OWNER. IWebViewBinding never independently owns or destroys the
  native WebView; its binding/completion lease state keeps the owner's
  lifetime state alive as long as a completion or native-handle use
  can still exist, and native destruction happens only after binding
  close AND handle-use lease drain.

  Boundary note: IWebViewInvocationHandler is a supporting interface
  belonging to the IWebViewBinding boundary - it is not an eighth
  top-level contract (see pweb.rpc.intf boundary note).
}
unit pweb.webview.intf;

{$mode ObjFPC}{$H+}

interface

uses
  pweb.rpc.intf;

type
  { Window size-hint vocabulary for IWebView.SetSize. Mirrors the
    upstream C library's hint semantics without naming it:
      pshNone  - width/height are the current size request
      pshMin   - width/height set the minimum size
      pshMax   - width/height set the maximum size
      pshFixed - the window may not be resized by the user }
  TPWebSizeHint = (
    pshNone,
    pshMin,
    pshMax,
    pshFixed
  );

  { Closure scheduled onto the GUI loop via IWebView.Dispatch. Executes
    on the GUI thread exactly once, or never if the runtime terminates
    first - a bare dispatched Proc has no completion sink, so it simply
    never runs in that case (the completed-as-cancelled rule belongs to
    invocations completing through their sink at the scheduler). The
    caller must keep Proc's target object alive until Proc has run or
    the runtime has terminated. }
  TPWebGuiProc = procedure of object;

  { Window lifecycle, navigation, title, size and script evaluation
    (core-interfaces.md responsibility table).

    Thread affinity - ratified default: ALL operations are
    GUI-thread-affine unless a method's contract documents otherwise
    (threading-model.md). In this method set only Dispatch documents
    otherwise. Cross-thread callers reach GUI-affine operations through
    Dispatch; the direction is worker -> Dispatch -> GUI operation.

    Ownership and lifetime: IWebView is the native-view lifetime
    OWNER - it owns the native window/view handle from creation until
    Terminate completes and destruction has been performed on the GUI
    loop. Destruction is deferred onto the GUI loop, runs only after
    the binding has closed and its handle-use leases have drained, and
    the GUI thread never waits synchronously for worker drain
    (wire-semantics.md hard rule). }
  IWebView = interface
    ['{C16D2B67-026F-4A86-9D94-50CD26A94E06}']
    { Set the native window title. GUI-thread-affine. }
    procedure SetTitle(const Title: Utf8String);

    { Set/constrain the window size per Hint. GUI-thread-affine. }
    procedure SetSize(Width, Height: Integer; Hint: TPWebSizeHint);

    { Navigate the view to Url. GUI-thread-affine. Policy reminder
      (enforced by implementations, not by this contract's shape): a
      privileged view navigates only within pweb://app/...; external
      links open in the system browser (security-model.md). }
    procedure Navigate(const Url: Utf8String);

    { Load Html directly as the view content. GUI-thread-affine. }
    procedure SetHtml(const Html: Utf8String);

    { Evaluate Script in the page context, fire-and-forget.
      GUI-thread-affine: a worker needing evaluation goes through
      Dispatch (threading-model.md "GUI-affine commands go the other
      way"). }
    procedure Eval(const Script: Utf8String);

    { Run the GUI event loop until Terminate. Blocks; the calling
      thread becomes THE GUI thread (threading-model.md "Basis in
      upstream"). GUI-thread-affine by definition. Single-shot: a
      second Run call is a contract violation; Terminate before Run
      is a no-op. }
    procedure Run;

    { Request the event loop to stop. GUI-thread-affine; cross-thread
      termination goes through Dispatch. }
    procedure Terminate;

    { The documented exception to GUI affinity in this interface:
      thread-safe. Schedules Proc onto the GUI loop thread and returns
      immediately - fire-and-forget from the caller's perspective
      (threading-model.md). Proc runs once on the GUI thread, or never
      if the runtime terminates first. A Proc dispatched before Run is
      queued and executes once the loop starts, or never if the
      runtime terminates first. Implementations wrap Proc in an
      exception barrier - a raise never unwinds the GUI event loop
      (the ratified no-Pascal-exception-across-a-C-callback rule: the
      closure runs inside a C dispatch callback). }
    procedure Dispatch(const Proc: TPWebGuiProc);
  end;

  { Receiver for one named JS-callable handler registered through
    IWebViewBinding.Bind.

    Callback-thread contract - ratified and binding
    (threading-model.md): invoked on the binding's callback thread,
    treated GUI-affine by internal convention. The implementation may
    do ONLY: validate size, copy the request, capture an immutable
    TInvocationContext snapshot, enqueue non-blocking, return.
    Explicitly forbidden inside the callback: database access, disk
    I/O, service calls, heavy crypto - anything that can block.

    The one ratified exception: the handler may synchronously complete
    an invocation that never enters the queue - invalid_request
    (oversize, malformed, bad grammar), busy (queue full),
    runtime_closed - through Completion on the callback thread.
    Everything successfully enqueued completes later through the
    scheduler's exactly-once sink, using this same Completion object.

    No Pascal exception may escape the handler: the binding's C
    callback body is an exception barrier that maps any failure to an
    internal_error completion (threading-model.md "Ownership at the C
    boundary"). }
  IWebViewInvocationHandler = interface
    ['{1845D339-E2CE-4D74-8EEC-6519E46C9615}']
    { Handle one incoming invocation request.
      Context   : native, immutable snapshot; built at the binding,
                  never from the JS payload (security-model.md).
      Request   : the raw serialized JSON request payload as received
                  from the page - method and arguments only.
      Completion: the per-invocation idempotent sink; first completion
                  wins, later attempts are dropped.

      Parsing split - ratified: this handler parses the
      transport-specific binding request envelope far enough to
      extract Method + Args; malformed envelope JSON is rejected HERE,
      pre-queue, as invalid_request - it never reaches TryEnqueue.
      RPC method validation/canonicalization is NOT this handler's
      job: that is IInvocationSource.TryEnqueue's single shared gate. }
    procedure HandleInvocation(const Context: TInvocationContext;
      const Request: TPWebJson; const Completion: IInvocationCompletion);
  end;

  { The WebView-flavoured invocation source (core-interfaces.md
    responsibility table): registers named handlers callable from JS
    and returns results to them. It owns its source lifecycle, its
    completion sink (the native return call), the handle-use lease,
    and the bind/unbind userdata lifetime - all internal; none of them
    appear in this signature.

    Ownership at the C boundary (threading-model.md): the object behind
    the native bind userdata is owned by this binding; its lifetime
    strictly encloses the interval from Bind through Unbind/destroy.
    Unbind happens on the GUI thread during Quiescing, before destroy.
    Completions performed by workers use the upstream-documented
    thread-safe native return path directly - never wrapped in a GUI
    dispatch - and each short native-handle operation is covered by an
    internal handle-use lease; no new leases once the close transition
    begins; destruction is deferred onto the GUI loop after leases
    drain.

    Linkage: the binding fronts exactly one scheduler-registered
    IInvocationSource; its Quiesce/Close drive both the JS-side
    unbinding and that source's lifecycle, and State reflects the
    single underlying source state - they cannot diverge. }
  IWebViewBinding = interface
    ['{E5B84DD4-3D1F-4C8D-9947-1446D28228DF}']
    { Register Handler under Name, making it callable from JS.
      GUI-thread-affine.

      Name is a JAVASCRIPT GLOBAL BINDING NAME - the identifier of the
      JS function injected into the page (nominally one generic
      runtime invoke endpoint). It is NOT a PWeb RPC Service.Method:
      RPC methods such as pweb.echo, pweb.handshake or UserService.Get
      exist inside the invocation request payload and are routed
      downstream - never as bind names. The Service.Method grammar and
      the pweb.* namespace reservation of wire-semantics.md govern the
      wire method, not this Name; binding-name validation is a
      separate, transport-local concern.

      Refusal - invalid/empty Name, nil handler, or already-bound Name
      (duplicates are refused, matching upstream) - surfaces as a
      Pascal exception at the Bind call site on the GUI thread, never
      silently and never across a C frame. Bind outside pssRunning is
      refused the same way. }
    procedure Bind(const Name: Utf8String;
      const Handler: IWebViewInvocationHandler);

    { Remove the handler registered under Name and release its
      userdata. GUI-thread-affine; during teardown it runs on the GUI
      thread while the source is Quiescing, before destroy. Unknown
      Name is a no-op. Legal in pssRunning and during pssQuiescing
      (the ratified teardown window); a no-op once pssClosed. }
    procedure Unbind(const Name: Utf8String);

    { Enter pssQuiescing for this source: refuse new invocations
      immediately, complete queued invocations as cancelled, signal
      cooperative cancellation to in-flight work. Non-blocking; the
      GUI thread never waits synchronously for the drain. Idempotent.
      Bounded by a configurable timeout that is an implementation
      detail (wire-semantics.md "Lifecycle and cancellation"). }
    procedure Quiesce;

    { Enter pssClosed: all use of the native handle is forbidden; late
      completion attempts die at the exactly-once gate without touching
      the handle. Calling Close while pssRunning implicitly performs
      the full Quiesce semantics first - the only lifecycle progression
      is pssRunning -> pssQuiescing -> pssClosed; there is no direct
      pssRunning -> pssClosed transition. Non-blocking and idempotent;
      actual native destruction is performed by the owning IWebView,
      deferred onto the GUI loop after internal handle-use leases
      drain - a quiesce timeout never destroys a handle while a lease
      is held. }
    procedure Close;

    { Current lifecycle state of this source. Advisory snapshot; may
      advance concurrently (see IInvocationSource.State). }
    function State: TPWebSourceState;
  end;

implementation

end.
