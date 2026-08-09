{
  pweb.rpc.intf - PWeb invocation pipeline contracts (Phase 0 freeze).

  RTL-only by ratified constraint: this unit references no mORMot, no
  browser-engine and no platform identifier, and never uses any
  pweb.webview.* unit. The scheduler and bridge are defined over
  *invocation sources*, not over any particular embedding
  (threading-model.md "Invocation sources, not WebViews";
  conventions.md unit-dependency rule).

  Canonical sources for every semantic encoded here:
    - wire-semantics.md   : protocol version, request grammar, error
                            contract, discriminated result, lifecycle.
    - threading-model.md  : callback duties, non-blocking enqueue,
                            exactly-once completion, token vs lease,
                            backpressure, ordering.
    - security-model.md   : TInvocationContext, principals, policy input.
    - core-interfaces.md  : responsibility table and must-not-reference
                            column for the seven core contracts.

  Compatibility promise: source-level only (conventions.md). Records may
  grow additively at source level; no binary ABI claim is made.

  Naming note: TInvocationContext deliberately keeps its spec-verbatim
  unprefixed name from security-model.md (as TAssetResponse does from
  core-interfaces.md in the assets unit). Not an oversight - do not
  rename after freeze.
}
unit pweb.rpc.intf;

{$mode ObjFPC}{$H+}

interface

const
  { Wire protocol version. The wire is versioned from day one because
    app.pwb updates independently of the native runtime
    (wire-semantics.md "Protocol version"). }
  PWEB_PROTOCOL_VERSION = 1;

  { The runtime exposes a SET of supported protocols - only version 1
    today - so the bundle load predicate is set membership, never an
    ordering comparison (wire-semantics.md "Protocol version"). }
  PWEB_SUPPORTED_PROTOCOLS: array[0..0] of Integer = (PWEB_PROTOCOL_VERSION);

  { Runtime-reserved first segment of the method grammar. Methods whose
    first segment is this namespace are runtime-owned; application
    registration of such methods is refused at startup
    (wire-semantics.md "Request grammar and limits"). }
  PWEB_RESERVED_NAMESPACE = 'pweb';

  { Runtime-owned methods on the existing bridge - deliberately no
    eighth interface (wire-semantics.md "Protocol version").
    pweb.handshake returns at minimum protocol, runtime, capabilities;
    its capabilities are advisory UI metadata only - an SDK must never
    enforce, cache-then-trust, or grant from this snapshot. }
  PWEB_METHOD_HANDSHAKE = 'pweb.handshake';
  PWEB_METHOD_ECHO = 'pweb.echo';

type
  { JSON payload carrier on the Pascal side of the wire: a UTF-8 RTL
    string alias holding either a serialized JSON value or, where a
    contract documents it, the empty string standing for JSON null.
    Arguments on the wire are a named-argument JSON object or null -
    never a positional array (wire-semantics.md, protocol v1). }
  TPWebJson = Utf8String;

  { The nine-code stable error set for protocol v1, in the exact order
    of the ratified code/status table (wire-semantics.md "Error
    contract"). `code` is the only normative discriminator; `status`
    is informative/derived. Deliberately without `unauthorized`. }
  TPWebErrorCode = (
    pecInvalidRequest,   // invalid_request    / 400
    pecMethodNotFound,   // method_not_found   / 404
    pecForbidden,        // forbidden          / 403
    pecBusy,             // busy               / 429
    pecCancelled,        // cancelled          / 499
    pecServiceError,     // service_error      / 422
    pecInternalError,    // internal_error     / 500
    pecRuntimeClosed,    // runtime_closed     / 503
    pecProtocolMismatch  // protocol_mismatch  / 505
  );

  { Canonical error envelope, native-side shape of the wire members
    "code", "message", "status", "data" (wire-semantics.md).
    Status is not stored: it is derived from PWEB_ERROR_STATUS, frozen
    with protocol v1. Data is the serialized JSON `data` member; empty
    means null. service_error.data is the only sanctioned
    application-defined domain-error channel; busy may carry
    data.retryAfterMs; every other code carries null data in release
    builds. Release builds never place exception class names, stack
    traces, SQL or filesystem paths in Message or Data.

    The ratified debug-builds-only `debug` envelope block is
    deliberately absent from this frozen record - it is never part of
    the stable public contract, and debug builds attach it at
    serialization time; the record may grow additively if that ever
    changes. }
  TPWebError = record
    Code: TPWebErrorCode;
    Message: Utf8String;  // human-readable message, no native detail leak
    Data: TPWebJson;      // serialized JSON value; '' = null
  end;

  { Discriminator of the ratified bridge result: Success | Error and
    nothing else (wire-semantics.md "The bridge result is
    discriminated"). }
  TPWebResultKind = (
    prkSuccess,
    prkError
  );

  { The discriminated invocation result. Never an ambiguous raw JSON
    string whose meaning depends on transport status: a Success value
    that happens to look like an error envelope is still a success.
    Value is meaningful only when Kind = prkSuccess and holds any valid
    serialized JSON value; Error is meaningful only when
    Kind = prkError. Each source maps the two arms onto its own
    transport semantics (wire-semantics.md). }
  TPWebInvocationResult = record
    Kind: TPWebResultKind;
    Value: TPWebJson;   // valid iff Kind = prkSuccess; '' stands for JSON null
    Error: TPWebError;  // valid iff Kind = prkError
  end;

  { Principal kinds, ratified in security-model.md "Principals".
    Plugins and embedded script hosts are first-class principals so a
    later script source reuses this system unchanged - no second
    permission system. }
  TPWebPrincipalKind = (
    pkWindow,
    pkPlugin,
    pkSystem,
    pkQuickJS
  );

  { Capability identifier list of a principal. Each identifier matches
    [a-z0-9]+(\.[a-z0-9]+)* and is compared exactly - no wildcards, no
    regex, no implicit inheritance in v1 (security-model.md
    "Capability grammar"). }
  TPWebCapabilities = array of Utf8String;

  { The native invocation context (security-model.md "The context is
    built natively"). Built natively at the binding - authorization
    never trusts a JS-supplied field; the payload carries method and
    arguments only.

    Ownership and lifetime: each enqueued invocation captures an
    IMMUTABLE snapshot of this record that stays alive until the
    invocation completes; a worker never reads window-owned mutable
    state (threading-model.md "Ownership at the C boundary"). After
    capture, no field - including the Capabilities array - may be
    mutated. The snapshot capturer MUST deep-copy: Capabilities is a
    dynamic array, and plain record assignment shares its reference -
    the capturer calls Copy() on it, otherwise immutability breaks
    silently.

    Identity invariants: PrincipalKind = pkWindow implies
    WindowId <> ''; PrincipalKind = pkPlugin implies PluginId <> ''.
    A context violating them is rejected as invalid_request before
    policy. }
  TInvocationContext = record
    WindowId: Utf8String;             // '' when not applicable (non-window principals)
    PrincipalId: Utf8String;          // never taken from the JS payload
    PrincipalKind: TPWebPrincipalKind;
    Capabilities: TPWebCapabilities;  // effective-set input; immutable after capture
    PluginId: Utf8String;             // '' unless the principal is a plugin
    TrustedContent: Boolean;          // False for externally navigated content
  end;

  { Invocation-source lifecycle, ratified in wire-semantics.md
    "Lifecycle and cancellation". The lifecycle belongs to the source -
    a window binding is one source, an embedded script host a future
    other.
      pssRunning   : accepts invocations normally.
      pssQuiescing : refuses new invocations immediately; queued
                     invocations complete as cancelled; in-flight work
                     receives cooperative cancellation and may finish.
      pssClosed    : all use of the source's native handle is
                     forbidden; a late completion attempt is swallowed
                     by the exactly-once gate. }
  TPWebSourceState = (
    pssRunning,
    pssQuiescing,
    pssClosed
  );

  { Per-source backpressure bounds, present from Phase 0
    (threading-model.md "Backpressure"). The mechanism is fixed; the
    numbers are chosen at implementation time and are configurable.
    Both values must be >= 1; IInvocationScheduler.RegisterSource
    refuses invalid limits with a Pascal exception at the call site.

    Note: the wire's configurable request-size cap is NOT backpressure
    and does not live here - size validation is the transport
    callback's ratified duty ("validate size"), its bound configured
    on the source implementation in v1. This record may grow
    additively. }
  TPWebSourceLimits = record
    MaxConcurrent: Integer;  // maximum simultaneous in-flight invocations
    MaxQueueSize: Integer;   // maximum queued, not yet executing, invocations
  end;

  { Synchronous outcome of a non-blocking enqueue attempt. Enqueue is
    always non-blocking: the caller never waits for queue capacity
    (threading-model.md "Synchronous pre-queue rejection").
    A non-accepted outcome is returned synchronously to the enqueuing
    thread and the invocation NEVER enters the queue nor completes
    through the completion sink; the transport maps it to the ratified
    pre-queue rejection codes:
      perInvalidRequest -> invalid_request (oversize, malformed, bad grammar)
      perBusy           -> busy            (queue full)
      perClosed         -> runtime_closed  (source not pssRunning)
    Only perAccepted transfers completion responsibility to the
    scheduler's exactly-once sink. }
  TPWebEnqueueResult = (
    perAccepted,
    perInvalidRequest,
    perBusy,
    perClosed
  );

  { Cooperative cancellation token - protects invocation/work lifetime,
    one of the two ratified mechanisms (the handle-use lease is the
    other and is deliberately NOT part of the public contracts: it is
    an internal concern of the embedding binding, per
    core-interfaces.md). Cooperative only: in-flight work observes it;
    nothing is forcibly aborted (threading-model.md "Leases and
    tokens").

    Thread affinity: none - may be read from any thread. Lifetime: held
    by the worker for the duration of the invocation it scopes. }
  ICancellationToken = interface
    ['{787412FF-1D2C-42FE-A89D-58B36A708FAC}']
    { True once cancellation of the owning invocation has been
      requested (source quiesce or teardown - no per-invocation cancel
      exists in v1). Work that observes True should stop early; its
      eventual completion attempt is dropped by the exactly-once
      gate. }
    function IsCancelled: Boolean;
  end;

  { Idempotent per-invocation completion sink - the delivery end of the
    ratified exactly-once rule (wire-semantics.md "Exactly-once
    completion"). The transport supplies one instance per invocation at
    enqueue time; it encapsulates whatever transport-specific reply
    mechanism exists, keeping every transport out of the bridge.

    Semantics: the FIRST Complete wins; any second or later Complete on
    the same sink is dropped silently (documented idempotency - a late
    worker result dies at this gate and never touches a closed native
    handle). Backpressure slots release at completion, not at worker
    exit. Cancellation completes the invocation with pecCancelled
    through this same sink.

    Thread affinity: callable from any thread; implementations perform
    their own transport-safe delivery. }
  IInvocationCompletion = interface
    ['{6D9578E3-E12B-419F-BCE3-9844B552B261}']
    { Deliver the discriminated result. Idempotent: only the first call
      has any effect. }
    procedure Complete(const AResult: TPWebInvocationResult);
  end;

  { Decides whether a principal may invoke a canonical method
    (core-interfaces.md responsibility table; security-model.md "What
    the policy receives"). Input is the native invocation context plus
    the canonical method - the identical canonical value the router
    receives, produced by the single parse/validate/canonicalize point.
    The method-to-capability mapping lives inside the implementation
    and its trusted configuration; it never appears on the wire.

    Rules (ratified): unknown/unmapped method => deny - fail closed,
    always; the policy runs before routing, so forbidden outranks
    method_not_found. Every invocation from every caller traverses this
    policy from the first bridge onward - no second permission system.

    Thread affinity: called on worker threads; implementations must be
    safe for concurrent calls. Must not reference any concrete policy
    source (file, manifest format) in this signature.

    Failure semantics: an exception escaping IsAllowed is treated as
    DENY and the invocation completes as internal_error - it never
    escapes the worker and never fails open. }
  ICapabilityPolicy = interface
    ['{850D5B3E-C442-43F9-A81C-4D365E5FD5F5}']
    { True iff Context's effective capabilities allow the canonical
      Method. False for any unknown or unmapped method. }
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;
  end;

  { Turns one invocation - context + canonical method + named JSON
    arguments - into a service call and its outcome into the
    discriminated Success/Error result (core-interfaces.md
    responsibility table). Correlation-free and caller-agnostic: no
    request ids, no transport knowledge, no completion routing - those
    stay scheduler- and source-side. No mORMot type appears in this
    signature (ratified must-not-reference rule).

    Thread affinity: executes synchronously on a worker thread, never
    on the GUI thread (threading-model.md "Nominal path"). The bridge
    returns; it does not complete sinks. A failure inside the bridge
    surfaces as the prkError arm - it never escapes as an exception
    across the pipeline. }
  IInvocationBridge = interface
    ['{CE7DE477-20EB-4973-AB3E-22C13F83EF93}']
    { Execute Method with named Args under Context, observing Token
      cooperatively. Method is the canonical, case-sensitive,
      exact-match spelling from the single canonicalization point;
      Args is a serialized JSON object or '' for null - named
      arguments only in protocol v1. }
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

  { One registered invocation source, as handed out by
    IInvocationScheduler.RegisterSource. A source owns its lifecycle
    state, its completion sinks, its backpressure limits and its
    cancellation scope (threading-model.md "Invocation sources, not
    WebViews"). Every caller travels
      source -> scheduler -> bridge -> policy -> service;
    nothing calls the bridge directly.

    Ownership and lifetime: the transport (an embedding binding, a
    script host) holds this reference and drives Quiesce/Close for its
    own teardown; the scheduler owns the queue and worker delivery
    behind it. Closing one source affects that source only; whole
    runtime shutdown is IInvocationScheduler.Shutdown. }
  IInvocationSource = interface
    ['{3F5046C6-F9D0-44B8-A1CE-21EDA84B9256}']
    { Non-blocking enqueue of one invocation. NEVER blocks and never
      waits for queue capacity - it is callable from a GUI-affine
      transport callback whose only duties are: validate size, copy
      the request, capture an immutable Context snapshot, enqueue,
      return (threading-model.md).

      Canonicalization ownership: TryEnqueue is the single
      parse/validate/canonicalize point of wire-semantics.md. Method
      is validated and canonicalized exactly once here, at enqueue,
      and the identical canonical value is what ICapabilityPolicy and
      the IInvocationBridge router later receive. perInvalidRequest is
      this gate's grammar/size verdict - every source shares one
      canonicalization point instead of one per transport.

      Completion is the per-invocation transport sink. On perAccepted
      the scheduler guarantees exactly one eventual
      Completion.Complete - result, error, or cancelled. On any other
      outcome the sink is NOT invoked; the caller performs the ratified
      synchronous pre-queue rejection itself on the calling thread.

      Context is captured by snapshot: the scheduler keeps it alive,
      unchanged, until the invocation completes. No ordering guarantee
      exists between concurrently enqueued invocations. }
    function TryEnqueue(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Completion: IInvocationCompletion): TPWebEnqueueResult;

    { Transition pssRunning -> pssQuiescing: refuse new invocations
      immediately, complete queued invocations as cancelled, signal
      cooperative cancellation to in-flight work which may finish.
      Bounded by a configurable quiesce timeout that is an
      implementation detail, not wire protocol. Idempotent; no effect
      once past pssQuiescing. Non-blocking: never waits for drain -
      in particular a GUI thread calling this never waits
      synchronously (wire-semantics.md hard rule). }
    procedure Quiesce;

    { Transition to pssClosed: all use of the source's native handle
      becomes forbidden; late completion attempts are swallowed by the
      exactly-once gate. Idempotent and non-blocking - actual native
      teardown is the transport's deferred concern, after its internal
      handle-use leases drain. }
    procedure Close;

    { Current lifecycle state. Advisory snapshot: the state may advance
      concurrently; correctness never depends on reading it, because
      TryEnqueue reports perClosed synchronously and completions are
      gated exactly-once regardless. }
    function State: TPWebSourceState;
  end;

  { Enqueues invocations from ANY invocation source onto the worker
    pool; per-source backpressure with non-blocking enqueue;
    exactly-once completion routing to each invocation's sink;
    cancellation signalling (core-interfaces.md responsibility table).
    Must not reference any specific thread-pool implementation nor any
    pweb.webview.* unit - it is defined over sources, and an embedding
    binding is only one source.

    Pipeline position: workers obtained here call the bridge and route
    the returned discriminated result to the invocation's completion
    sink - completion routing stays scheduler-side, keeping every
    transport out of the bridge. }
  IInvocationScheduler = interface
    ['{65B23D3E-04DF-4234-9C36-A45E2D3C9E1E}']
    { Create and register a new invocation source with the given
      backpressure bounds. The returned source starts in pssRunning.
      Lifetime: the caller owns the reference and drives the source's
      lifecycle; the scheduler tracks it until Closed.
      Refuses invalid Limits (either bound < 1) with a Pascal
      exception at the call site. Once Shutdown has begun, returns a
      source already in pssClosed - fail-closed: its enqueues report
      perClosed; nothing raises across threads. }
    function RegisterSource(const Limits: TPWebSourceLimits): IInvocationSource;

    { Whole-runtime shutdown, distinct from single-source teardown but
      reusing the same primitives (wire-semantics.md): quiesces every
      registered source, drains the worker pool, and only then may the
      caller release the service layer - so no worker can reach a
      freed service. Invocations that will never run are completed as
      cancelled by teardown and their captured contexts are freed by
      the scheduler. Must not be called from, nor block, a GUI-affine
      transport thread waiting on its own drain. Idempotent: a
      concurrent second call is a no-op that may block until the
      first completes. }
    procedure Shutdown;
  end;

const
  { The normative pre-queue rejection mapping - one table shared by
    every transport: a non-accepted TryEnqueue outcome maps to exactly
    this error code in the synchronous rejection the transport
    performs itself (threading-model.md "Synchronous pre-queue
    rejection"). }
  PWEB_ENQUEUE_ERROR: array[perInvalidRequest..perClosed] of TPWebErrorCode = (
    pecInvalidRequest,  // perInvalidRequest -> invalid_request
    pecBusy,            // perBusy           -> busy
    pecRuntimeClosed    // perClosed         -> runtime_closed
  );

  { Wire `code` member text for each error code - the sole normative
    discriminator, frozen for protocol v1 (wire-semantics.md). }
  PWEB_ERROR_CODE_TEXT: array[TPWebErrorCode] of Utf8String = (
    'invalid_request',
    'method_not_found',
    'forbidden',
    'busy',
    'cancelled',
    'service_error',
    'internal_error',
    'runtime_closed',
    'protocol_mismatch'
  );

  { Informative/derived `status` member for each error code, frozen
    with protocol v1 (wire-semantics.md status table). SDK and
    application logic switch on `code`, never on `status`. }
  PWEB_ERROR_STATUS: array[TPWebErrorCode] of Integer = (
    400,  // invalid_request
    404,  // method_not_found
    403,  // forbidden
    429,  // busy
    499,  // cancelled
    422,  // service_error
    500,  // internal_error
    503,  // runtime_closed
    505   // protocol_mismatch
  );

implementation

end.
