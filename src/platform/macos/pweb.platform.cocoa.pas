{
  pweb.platform.cocoa - production pweb://app resource handler for the
  macOS/Cocoa/WKWebView engine (CAP-7M1).

  The third sibling of pweb.platform.webview2 and pweb.platform.webkitgtk:
  same surface, same request flow, same fail-closed rules - a different
  engine underneath, and ONE forced difference in shape.

  ---------------------------------------------------------------------------
  WHY THIS ADAPTER IS TWO-PHASE AND ITS SIBLINGS ARE NOT
  ---------------------------------------------------------------------------

  Windows and Linux construct their handler AFTER webview_create, because both
  engines expose a post-create seam. Cocoa does not: upstream builds the
  WKWebViewConfiguration and the WKWebView both inside webview_create
  (cocoa_webkit.hh:450,486), and CAP-7M0 MEASURED (run 31909938201) that the
  post-create route is ACCEPTED, compares EQUAL, and is then NEVER CONSULTED
  (postcreate_hits=0). An adapter written against it would look correct, log
  nothing, and simply never serve - the worst shape a wrong seam can take.

  So the seam is armed BEFORE the webview exists:

    handler := TCocoaAssetHandler.Create(store);   // arms the pre-create seam
    w := WebViewCheckCreated(webview_create(0, nil));
    handler.Attach(w);                             // raises unless the seam RAN
    ...
    handler.Detach;                                // disown, then webview_destroy

  Attach answers "is THIS WebView served by us?" in two steps, and the second
  is the one that matters:

    1. the bridge's seam-invocation counter must have moved across
       webview_create. Cheap, and safe on a handle that is not really a
       webview - but process-global and monotonic, so ANY unrelated
       +[WKWebViewConfiguration new] would satisfy it;
    2. the view's own configuration must report OUR handler for the pweb
       scheme (public -[WKWebViewConfiguration urlSchemeHandlerForURLScheme:],
       reached through webview_get_native_handle).

  Step 1 alone would be close to vacuous, which is why step 2 exists: a seam
  that silently stopped running, or a view someone else constructed, can never
  again present as success. Both raise; neither is a warning.

  ---------------------------------------------------------------------------
  OWNERSHIP CROSSES AS A HANDLE, NEVER AS A POINTER
  ---------------------------------------------------------------------------

  The bridge stores a 64-bit handle packing a slot index and a generation
  counter. The registry below bumps the generation on BOTH claim and release,
  so a handle from a freed handler resolves to nothing rather than to whatever
  now occupies the slot. That is strictly stronger than the Linux adapter's
  interlocked owner pointer, and it is what makes "no callback after handler
  destruction" a property of the REPRESENTATION rather than of the teardown
  order.

  Detach disowns first (the bridge stops calling out), then claims and fails
  every live task, then releases the slot - and only then may webview_destroy
  run.

  ---------------------------------------------------------------------------
  THE URI IS THE WHOLE URI
  ---------------------------------------------------------------------------

  Every request feeds [[task request] URL] absoluteString - the complete
  absolute URL - to the shared, portable, frozen PWebParseAppUri. No path
  accessor, no last component, no filesystem path is ever built here. A
  path-only view of pweb://evil/x reads as /x and would hand a wrong-authority
  request through as a legitimate asset; only PWebParseAppUri checks the
  authority, and it is given the untouched URI.

  ---------------------------------------------------------------------------
  RESPONSES AND REFUSALS
  ---------------------------------------------------------------------------

  Served assets get an NSHTTPURLResponse 200 with a deterministic Content-Type
  and an honest Content-Length; refusals get didFailWithError:. CAP-7M0's
  constraint 12 is the reason: a bare NSURLResponse loads the resource
  perfectly while fetch() reports status 0 and ok === false. Refusal carries
  no reason, no path and no native text - one outcome for wrong authority,
  non-canonical path, missing asset and internal failure alike, exactly as
  Windows answers a constant 404 and Linux a constant GError.

  No Pascal exception ever crosses the C callback boundary, and no Objective-C
  exception ever crosses back: the bridge's @try/@catch is an Objective-C
  frame, which Pascal cannot express, and that is most of why the bridge
  exists at all.
}
unit pweb.platform.cocoa;

{$mode ObjFPC}{$H+}
{ Every record below crosses the private C seam. }
{$PACKRECORDS C}

{$ifndef DARWIN}
  {$MESSAGE Error 'pweb.platform.cocoa is the macOS engine adapter'}
{$endif DARWIN}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.assets.intf,
  pweb.assets.support;

const
  /// longest Content-Type the private seam carries, INCLUDING the NUL
  // - must equal PWEB_COCOA_CONTENT_TYPE_MAX in pweb_cocoa_bridge.h; a type
  // that does not fit is a REFUSAL here, never a truncation on the wire
  PWEB_COCOA_CONTENT_TYPE_MAX = 256;

  /// distinct live pweb://app handlers this process can register
  // - one is the realistic case (the seam is process-wide); the ceiling only
  // exists so that overflowing it refuses loudly
  PWEB_COCOA_MAX_HANDLERS = 8;

  /// bound on the absolute URL scanned out of WebKit's storage
  // - the URL is attacker-influenced, so it gets the same bounded-scan
  // discipline the binding gives the request payload: never an unbounded
  // StrLen over a pointer this unit did not allocate
  PWEB_COCOA_MAX_URI_BYTES = 65536;

  /// entries in the diagnostic URI ring (see PWebCocoaObserveUris)
  PWEB_COCOA_OBSERVED_RING = 512;

type
  { The C scalar contract of the private bridge seam declared in the
    implementation section.

    These live in the INTERFACE for one reason: the gates must measure the
    very types this unit declares, not a copy of them - the same placement,
    for the same reason, that CAP-7L used for its hand-declared GTK aliases
    and CAP-7M0 used for the Darwin fcntl constants. Nothing else may use
    them; the engine surface itself stays private. }

  /// uint64_t - the generation-checked handler handle
  TPWebCocoaHandle = QWord;

  { What THIS WebView's configuration says about the pweb:// scheme handler.

    pcrOurs    - our handler; the per-view proof Attach wants.
    pcrAbsent  - nothing visible. AMBIGUOUS by construction: a configuration
                 copy that does not carry the scheme-handler map is
                 indistinguishable from a view that genuinely has no handler,
                 and this project has not measured which one Cocoa does.
    pcrForeign - a DIFFERENT handler owns pweb:// here. Never ambiguous,
                 never acceptable, and the only value Attach refuses on. }
  TPWebCocoaReadback = (
    pcrAbsent,
    pcrOurs,
    pcrForeign
  );

  /// pweb_cocoa_asset_t
  PPWebCocoaAsset = ^TPWebCocoaAsset;
  TPWebCocoaAsset = record
    Bytes: Pointer;  // a pweb_cocoa_alloc block the BRIDGE owns on success
    Length: Int64;   // 0 is a legitimate asset, never a miss
    ContentType: array[0 .. PWEB_COCOA_CONTENT_TYPE_MAX - 1] of AnsiChar;
  end;

  /// pweb_cocoa_stats_t
  // - every field is process CUMULATIVE except LiveTasks; a caller reporting
  // per cycle must take deltas, which is deliberate: a task that leaked in
  // cycle 1 must still be visible in cycle 3
  PPWebCocoaStats = ^TPWebCocoaStats;
  TPWebCocoaStats = record
    SeamInvocations: QWord;
    TasksStarted: QWord;
    TasksServed: QWord;
    TasksRefused: QWord;
    TasksStopped: QWord;
    StopsWhileServing: QWord;
    StopsIgnored: QWord;
    SuppressedTerminals: QWord;
    CaughtExceptions: QWord;
    UnresolvedHandles: QWord;
    LiveTasks: QWord;
  end;

  /// pweb_cocoa_stub_outcome_t - the deterministic proof surface
  PPWebCocoaStubOutcome = ^TPWebCocoaStubOutcome;
  TPWebCocoaStubOutcome = record
    ResponseStatus: LongInt;
    ResponseLength: Int64;
    ReceivedBytes: Int64;
    Finished: LongInt;
    Failed: LongInt;
    MisuseRaised: LongInt;
    BodyHash: LongWord;
  end;

  /// pweb_cocoa_resolve_fn
  // - 1 serve, 0 refuse, -1 the handle did not resolve
  TPWebCocoaResolveFn = function(AHandle: TPWebCocoaHandle;
    AUrl: PAnsiChar; AAsset: PPWebCocoaAsset): LongInt; cdecl;

  EPWebCocoaAssetHandler = class(Exception);

  { Serves IAssetStore content on pweb://app/* for one webview.

    Create on the GUI thread BEFORE webview_create - construction is what arms
    the pre-create seam. Attach immediately after webview_create; it raises
    unless the seam actually ran. Detach before webview_destroy (Destroy calls
    Detach as a guard). }
  TCocoaAssetHandler = class
  private
    fStore: IAssetStore;
    fHandle: TPWebCocoaHandle;
    fWebView: webview_t;      // borrowed - never destroyed here
    fThreadId: TThreadID;     // GUI thread that created us
    fSeamBefore: QWord;       // seam invocations sampled at Create
    fReadback: TPWebCocoaReadback; // what Attach saw on THIS view
    fAttached: Boolean;
  public
    constructor Create(const AStore: IAssetStore);
    destructor Destroy; override;
    /// prove the pre-create seam RAN for this webview, or raise
    procedure Attach(AWebView: webview_t);
    /// idempotent: disown, fail every live task, then make the handle
    // unresolvable - in that order
    procedure Detach;
    property Attached: Boolean read fAttached;
    property Handle: TPWebCocoaHandle read fHandle;
    /// the per-view read-back Attach observed - RECORDED, not gated, except
    // for pcrForeign which Attach refuses outright (see
    // PWebCocoaHandlerInstalledOn)
    property Readback: TPWebCocoaReadback read fReadback;
  end;

/// the adapter's ENTIRE request decision, in one place.
// The bridge's resolve callback calls exactly this, and so do the gates - so
// "the macOS adapter reaches the same verdict as Windows and Linux through
// the same routine" is a property the tests actually exercise rather than one
// they restate. Full-URI validation through PWebParseAppUri (never a path
// fragment, never a rebuilt URI), then exactly one IAssetStore.TryRead.
// Fail-closed and never raises.
function PWebCocoaResolveAssetUri(const AUri: RawUtf8;
  const AStore: IAssetStore; out Asset: TAssetResponse): Boolean;

/// the Content-Type the adapter serves for a resolved asset
// - the store's deterministic type, with a fallback that can never be the
// empty string (an empty Content-Type would let the engine sniff)
function PWebCocoaContentType(const Asset: TAssetResponse): RawUtf8;

/// copy an asset body into a block the BRIDGE owns, exactly the way the
/// resolve callback does
// - nothing the page receives may point at a RawByteString, a Pascal
// temporary or callback stack memory; this is the copy that makes that true
// - a zero-byte asset still gets a real, non-nil allocation with an honest
// length of 0, so "empty" and "failed" can never be confused
// - returns False only on allocation failure, leaving ABody nil
function PWebCocoaCopyBody(const AContent: RawByteString;
  out ABody: Pointer; out ASize: PtrInt): Boolean;

/// release a body from PWebCocoaCopyBody that was never handed over
procedure PWebCocoaReleaseBody(ABody: Pointer);

/// how many times the pre-create seam has installed the handler in this
/// process - the CHEAP guard Attach checks first
// - process-global and monotonic: on its own it says only that SOMETHING went
// through +[WKWebViewConfiguration new]. What settles it per view is
// PWebCocoaHandlerInstalledOn.
function PWebCocoaSeamInvocations: QWord;

/// does THIS WebView's live configuration route pweb:// to our handler?
// - the positive, per-view half of Attach's proof; AWebView is the
// BROWSER_CONTROLLER native handle (on Cocoa, the WKWebView itself)
// - THREE-VALUED, and only pcrForeign refuses. pcrAbsent cannot tell "nothing
// is installed" from "the configuration copy this view hands back does not
// carry the scheme-handler map", and which of those it is has never been
// measured here - CAP-7M0 measured only that WRITING to that copy is silently
// ineffective. Refusing on an unverified assumption would report a correct
// adapter as broken; pcrAbsent is therefore RECORDED, and promoted to a
// refusal once a hosted run has reported pcrOurs on both architectures.
function PWebCocoaHandlerInstalledOn(AWebView: Pointer): TPWebCocoaReadback;

/// 'ours' | 'absent' | 'foreign', for the measurement record
function PWebCocoaReadbackName(AValue: TPWebCocoaReadback): RawUtf8;

/// did unit initialization put the FPU in its non-trapping default state?
// - MEASURED: with the traps left as FPC sets them, every runtime cycle dies
// with EInvalidOp the moment WebKit does arithmetic on a NaN. This reports
// that the remedy ran, so the gate can STATE it rather than infer it from the
// absence of a crash - see the initialization section and
// pweb_cocoa_mask_fpu_traps in the bridge.
function PWebCocoaFpuTrapsMasked: Boolean;

/// is the +new override confined to WKWebViewConfiguration's own metaclass?
// - asserts the one line in this whole shard that could quietly swizzle +new
// for EVERY class in the process: WKWebViewConfiguration's metaclass +new is
// ours, NSObject's is not, and constructing unrelated objects with +new does
// not reach the seam. Deterministic, and needs no window.
function PWebCocoaSeamIsConfined: Boolean;

/// snapshot of every bridge counter
function PWebCocoaStats: TPWebCocoaStats;

/// resident size of THIS process in KiB, or 0 if the kernel would not say
// - measured through task_info() in the bridge rather than a hand-laid
// `struct rusage` here: a wrong ru_maxrss offset would not fail, it would
// return a plausible number, which is exactly how a leak bound stops
// measuring anything without anyone noticing
function PWebCocoaResidentKb: QWord;

/// does this handle still resolve to a live handler?
// - the registry property the "released handle is unresolvable" gate asserts
function PWebCocoaHandleResolves(AHandle: TPWebCocoaHandle): Boolean;

/// live entries in the handler registry
function PWebCocoaRegistryCount: Integer;

{ ---- diagnostic URI ring: OFF by default, zero cost when off ----

  The runtime gate has to cross-check every URI the PRODUCTION handler
  observed against the shared PWebParseAppUri, the same way CAP-7M0's probe
  did - and the probe could do that only because it printed what it saw. A
  production adapter must not print anything, so instead it can be asked to
  remember, into a bounded ring, what it was handed and what it decided.

  It is DISABLED unless a caller enables it, it holds at most
  PWEB_COCOA_OBSERVED_RING entries, it never affects a verdict, and nothing
  the page can do reaches it. It is diagnostics, not security. }

/// enable/disable the bounded diagnostic URI ring (disabled at startup)
procedure PWebCocoaObserveUris(AEnabled: Boolean);
/// discard everything the ring holds
procedure PWebCocoaResetObserved;
/// entries currently held (never more than PWEB_COCOA_OBSERVED_RING)
function PWebCocoaObservedCount: Integer;
/// observations the ring OVERWROTE because it was full
// - a ring that silently drops is a gate that silently stops checking, so the
// count is published and the runtime gate requires it to be zero
function PWebCocoaObservedDropped: QWord;
/// requests whose URL could not be observed at all - a nil pointer, an empty
/// string, or one longer than PWEB_COCOA_MAX_URI_BYTES
// - counted rather than recorded, because an empty row is not a URI and
// feeding one to the oracle would corrupt the join; the runtime gate requires
// this to be zero and requires observed + nonconforming to equal the number
// of tasks the bridge started
function PWebCocoaObservedNonconforming: QWord;
/// the AIndex-th observed absolute URI, oldest first
function PWebCocoaObservedUri(AIndex: Integer): RawUtf8;
/// 'serve' or 'refuse' for the AIndex-th observation
function PWebCocoaObservedVerdict(AIndex: Integer): RawUtf8;

{ ---- the deterministic proof surface (see pweb_cocoa_bridge.h) ----

  Drives the SAME task state machine the real WKURLSchemeHandler uses, over a
  bridge-internal stub task, so that double-terminal suppression, post-stop
  suppression, idempotent cancel, teardown drain and the disowned-handler
  refusal are provable WITHOUT a window. }

function PWebCocoaStubCreate(const AUri: RawUtf8): QWord;
procedure PWebCocoaStubRelease(ATask: QWord);
procedure PWebCocoaStubStart(ATask: QWord);
procedure PWebCocoaStubStop(ATask: QWord);
procedure PWebCocoaStubLeaveLive(ATask: QWord);
procedure PWebCocoaStubDeliverAgain(ATask: QWord);
function PWebCocoaStubOutcome(ATask: QWord): TPWebCocoaStubOutcome;

implementation

{ ---- the private C seam (src/platform/macos/pweb_cocoa_bridge.h) ----

  Declared without a library name: the bridge is ONE object file linked into
  each binary that hosts a macOS WebView (tools/build-macos-bridge.sh), never
  a second shipped dylib. None of these names is a webview_* symbol, and the
  public export surface stays at exactly 17. }

function pweb_cocoa_alloc(n: PtrUInt): Pointer; cdecl;
  external name 'pweb_cocoa_alloc';
procedure pweb_cocoa_free(p: Pointer); cdecl;
  external name 'pweb_cocoa_free';
function pweb_cocoa_install(resolve: TPWebCocoaResolveFn): LongInt; cdecl;
  external name 'pweb_cocoa_install';
function pweb_cocoa_arm(handle: QWord): LongInt; cdecl;
  external name 'pweb_cocoa_arm';
procedure pweb_cocoa_disown(handle: QWord); cdecl;
  external name 'pweb_cocoa_disown';
function pweb_cocoa_fail_live_tasks: PtrUInt; cdecl;
  external name 'pweb_cocoa_fail_live_tasks';
function pweb_cocoa_seam_invocations: QWord; cdecl;
  external name 'pweb_cocoa_seam_invocations';
procedure pweb_cocoa_get_stats(out stats: TPWebCocoaStats); cdecl;
  external name 'pweb_cocoa_get_stats';
function pweb_cocoa_handler_installed_on(view: Pointer): LongInt; cdecl;
  external name 'pweb_cocoa_handler_installed_on';
function pweb_cocoa_seam_is_confined: LongInt; cdecl;
  external name 'pweb_cocoa_seam_is_confined';
function pweb_cocoa_rss_kb: QWord; cdecl;
  external name 'pweb_cocoa_rss_kb';
function pweb_cocoa_mask_fpu_traps: LongInt; cdecl;
  external name 'pweb_cocoa_mask_fpu_traps';

function pweb_cocoa_stub_task_create(url: PAnsiChar): QWord; cdecl;
  external name 'pweb_cocoa_stub_task_create';
procedure pweb_cocoa_stub_task_release(task: QWord); cdecl;
  external name 'pweb_cocoa_stub_task_release';
procedure pweb_cocoa_stub_task_start(task: QWord); cdecl;
  external name 'pweb_cocoa_stub_task_start';
procedure pweb_cocoa_stub_task_stop(task: QWord); cdecl;
  external name 'pweb_cocoa_stub_task_stop';
procedure pweb_cocoa_stub_task_leave_live(task: QWord); cdecl;
  external name 'pweb_cocoa_stub_task_leave_live';
procedure pweb_cocoa_stub_task_deliver_again(task: QWord); cdecl;
  external name 'pweb_cocoa_stub_task_deliver_again';
procedure pweb_cocoa_stub_task_outcome(task: QWord;
  out outcome: TPWebCocoaStubOutcome); cdecl;
  external name 'pweb_cocoa_stub_task_outcome';

{ ---- constants ---- }

const
  PWEB_COCOA_VERDICT_SERVE = 1;
  PWEB_COCOA_VERDICT_REFUSE = 0;
  PWEB_COCOA_VERDICT_UNRESOLVED = -1;
  /// the low bits of a handle hold slot+1; everything above is the generation
  PWEB_COCOA_SLOT_BITS = 8;
  PWEB_COCOA_SLOT_MASK = (QWord(1) shl PWEB_COCOA_SLOT_BITS) - 1;

type
  TPWebCocoaSlot = record
    Handler: TCocoaAssetHandler; // nil when free
    Store: IAssetStore;          // held so the callback never touches Handler
    Generation: QWord;           // bumped on BOTH claim and release
  end;

  TPWebCocoaObservation = record
    Uri: RawUtf8;
    Verdict: RawUtf8;
  end;

var
  { STATIC storage, deliberately, and a fixed capacity rather than a dynamic
    array - the same reasoning CAP-7L recorded for its GTK registration table.
    A WebKit callback can in principle still arrive while the process is
    tearing down, after FPC has finalised its units; a global in the data
    segment is valid for the entire process lifetime, while a dynamic array's
    backing store is not. For the same reason the critical section below is
    initialised and NEVER destroyed. }
  PWebCocoaRegistry: array[0 .. PWEB_COCOA_MAX_HANDLERS - 1] of TPWebCocoaSlot;
  PWebCocoaLock: TRTLCriticalSection;
  PWebCocoaNextGeneration: QWord;

  /// set by unit initialization: did the FPU reach its non-trapping default?
  // - read through PWebCocoaFpuTrapsMasked; see the initialization section
  PWebCocoaFpuMasked: Boolean;

  PWebCocoaObserving: Boolean;
  PWebCocoaObserved: array[0 .. PWEB_COCOA_OBSERVED_RING - 1] of TPWebCocoaObservation;
  PWebCocoaObservedHead: Integer;  // next write position
  PWebCocoaObservedFilled: Integer;
  PWebCocoaObservedDrops: QWord;   // overwritten because the ring was full
  PWebCocoaObservedBadUri: QWord;  // nil / empty / over-long URL

{ ---- the shared request decision (see the interface comments) ---- }

function PWebCocoaResolveAssetUri(const AUri: RawUtf8;
  const AStore: IAssetStore; out Asset: TAssetResponse): Boolean;
var
  logical: RawUtf8;
begin
  Result := False;
  Asset.Content := '';
  Asset.ContentType := '';
  if AStore = nil then
    exit;
  try
    // ONE validation truth, shared byte-for-byte with Windows and Linux: a
    // wrong scheme or authority never reaches IAssetStore, and no filesystem
    // path is ever built from an unvalidated URI
    if not PWebParseAppUri(AUri, logical) then
      exit;
    Result := AStore.TryRead(logical, Asset);
    if not Result then
    begin
      Asset.Content := '';
      Asset.ContentType := '';
    end;
  except
    // a store is contractually fail-closed rather than raising, but the
    // callback boundary above must never depend on that
    Asset.Content := '';
    Asset.ContentType := '';
    Result := False;
  end;
end;

function PWebCocoaContentType(const Asset: TAssetResponse): RawUtf8;
begin
  Result := Asset.ContentType;
  if Result = '' then
    Result := PWEB_ASSET_FALLBACK_MIME; // never an empty Content-Type
end;

function PWebCocoaCopyBody(const AContent: RawByteString;
  out ABody: Pointer; out ASize: PtrInt): Boolean;
begin
  ASize := Length(AContent);
  // pweb_cocoa_alloc(0) still returns a real block, so a zero-byte asset can
  // never be confused with an allocation failure on either side of the seam
  ABody := pweb_cocoa_alloc(PtrUInt(ASize));
  if ABody = nil then
  begin
    Result := False;
    exit;
  end;
  if ASize > 0 then
    Move(pointer(AContent)^, ABody^, ASize);
  Result := True;
end;

procedure PWebCocoaReleaseBody(ABody: Pointer);
begin
  if ABody <> nil then
    pweb_cocoa_free(ABody);
end;

{ ---- the generation-checked handle registry ---- }

function PWebCocoaClaimSlot(AHandler: TCocoaAssetHandler;
  const AStore: IAssetStore): TPWebCocoaHandle;
var
  i: PtrInt;
begin
  Result := 0;
  EnterCriticalSection(PWebCocoaLock);
  try
    for i := 0 to High(PWebCocoaRegistry) do
      if PWebCocoaRegistry[i].Handler = nil then
      begin
        // bumped on CLAIM as well as on release: a handle minted for a
        // previous occupant of this slot can never resolve to the new one
        Inc(PWebCocoaNextGeneration);
        PWebCocoaRegistry[i].Generation := PWebCocoaNextGeneration;
        PWebCocoaRegistry[i].Handler := AHandler;
        PWebCocoaRegistry[i].Store := AStore;
        Result := (PWebCocoaNextGeneration shl PWEB_COCOA_SLOT_BITS) or
                  QWord(i + 1);
        exit;
      end;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

// resolves a handle to its slot index, or -1. Caller holds the lock.
function PWebCocoaSlotOfLocked(AHandle: TPWebCocoaHandle): PtrInt;
var
  slot: PtrInt;
begin
  Result := -1;
  slot := PtrInt(AHandle and PWEB_COCOA_SLOT_MASK) - 1;
  if (slot < 0) or
     (slot > High(PWebCocoaRegistry)) then
    exit;
  if PWebCocoaRegistry[slot].Handler = nil then
    exit;
  if PWebCocoaRegistry[slot].Generation <>
     (AHandle shr PWEB_COCOA_SLOT_BITS) then
    exit; // a stale handle is UNRESOLVABLE, never merely stale
  Result := slot;
end;

procedure PWebCocoaReleaseSlot(AHandle: TPWebCocoaHandle);
var
  slot: PtrInt;
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    slot := PWebCocoaSlotOfLocked(AHandle);
    if slot < 0 then
      exit;
    // bumped on release too, so the handle just retired cannot resolve even
    // if the slot is re-claimed before the generation counter wraps
    Inc(PWebCocoaNextGeneration);
    PWebCocoaRegistry[slot].Generation := PWebCocoaNextGeneration;
    PWebCocoaRegistry[slot].Handler := nil;
    PWebCocoaRegistry[slot].Store := nil;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

// the store behind a handle, or nil if the handle does not resolve. The
// interface reference is taken under the lock and keeps the store alive for
// the duration of the read even if the handler is detached meanwhile.
function PWebCocoaStoreOf(AHandle: TPWebCocoaHandle): IAssetStore;
var
  slot: PtrInt;
begin
  Result := nil;
  EnterCriticalSection(PWebCocoaLock);
  try
    slot := PWebCocoaSlotOfLocked(AHandle);
    if slot >= 0 then
      Result := PWebCocoaRegistry[slot].Store;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

function PWebCocoaHandleResolves(AHandle: TPWebCocoaHandle): Boolean;
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    Result := PWebCocoaSlotOfLocked(AHandle) >= 0;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

function PWebCocoaRegistryCount: Integer;
var
  i: PtrInt;
begin
  Result := 0;
  EnterCriticalSection(PWebCocoaLock);
  try
    for i := 0 to High(PWebCocoaRegistry) do
      if PWebCocoaRegistry[i].Handler <> nil then
        Inc(Result);
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

{ ---- the diagnostic URI ring ---- }

procedure PWebCocoaObserveUris(AEnabled: Boolean);
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    PWebCocoaObserving := AEnabled;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

procedure PWebCocoaResetObserved;
var
  i: PtrInt;
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    for i := 0 to High(PWebCocoaObserved) do
    begin
      PWebCocoaObserved[i].Uri := '';
      PWebCocoaObserved[i].Verdict := '';
    end;
    PWebCocoaObservedHead := 0;
    PWebCocoaObservedFilled := 0;
    PWebCocoaObservedDrops := 0;
    PWebCocoaObservedBadUri := 0;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

procedure PWebCocoaRecordObservation(const AUri, AVerdict: RawUtf8);
begin
  // The flag is read BEFORE the lock, deliberately: the interface promises
  // zero cost when observation is off, and taking a critical section on every
  // served asset is not zero. The read is advisory - a Boolean written once
  // by the harness at startup - and a torn read cannot occur for a byte.
  if not PWebCocoaObserving then
    exit;
  EnterCriticalSection(PWebCocoaLock);
  try
    if not PWebCocoaObserving then
      exit;
    // A FULL RING DROPS THE OLDEST, and a drop that nobody counts is a gate
    // that quietly stops checking the requests it can no longer see.
    if PWebCocoaObservedFilled >= PWEB_COCOA_OBSERVED_RING then
      Inc(PWebCocoaObservedDrops);
    PWebCocoaObserved[PWebCocoaObservedHead].Uri := AUri;
    PWebCocoaObserved[PWebCocoaObservedHead].Verdict := AVerdict;
    PWebCocoaObservedHead :=
      (PWebCocoaObservedHead + 1) mod PWEB_COCOA_OBSERVED_RING;
    if PWebCocoaObservedFilled < PWEB_COCOA_OBSERVED_RING then
      Inc(PWebCocoaObservedFilled);
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

// A URL that is nil, empty or longer than the bound is COUNTED, never
// recorded: an empty row is not a URI, and feeding one to the oracle would
// put a blank line into a positional join.
procedure PWebCocoaRecordNonconforming;
begin
  if not PWebCocoaObserving then
    exit;
  EnterCriticalSection(PWebCocoaLock);
  try
    if PWebCocoaObserving then
      Inc(PWebCocoaObservedBadUri);
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

function PWebCocoaObservedCount: Integer;
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    Result := PWebCocoaObservedFilled;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

function PWebCocoaObservedDropped: QWord;
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    Result := PWebCocoaObservedDrops;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

function PWebCocoaObservedNonconforming: QWord;
begin
  EnterCriticalSection(PWebCocoaLock);
  try
    Result := PWebCocoaObservedBadUri;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

// oldest first, so a caller walking 0..Count-1 sees arrival order
function PWebCocoaObservedIndex(AIndex: Integer): Integer;
begin
  if PWebCocoaObservedFilled < PWEB_COCOA_OBSERVED_RING then
    Result := AIndex
  else
    Result := (PWebCocoaObservedHead + AIndex) mod PWEB_COCOA_OBSERVED_RING;
end;

function PWebCocoaObservedUri(AIndex: Integer): RawUtf8;
begin
  Result := '';
  EnterCriticalSection(PWebCocoaLock);
  try
    if (AIndex >= 0) and
       (AIndex < PWebCocoaObservedFilled) then
      Result := PWebCocoaObserved[PWebCocoaObservedIndex(AIndex)].Uri;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

function PWebCocoaObservedVerdict(AIndex: Integer): RawUtf8;
begin
  Result := '';
  EnterCriticalSection(PWebCocoaLock);
  try
    if (AIndex >= 0) and
       (AIndex < PWebCocoaObservedFilled) then
      Result := PWebCocoaObserved[PWebCocoaObservedIndex(AIndex)].Verdict;
  finally
    LeaveCriticalSection(PWebCocoaLock);
  end;
end;

{ ---- the resolve callback (no Pascal exception may leave it) ---- }

// bounded scan of an attacker-influenced C string: never an unbounded StrLen
// over a pointer this unit did not allocate
function PWebCocoaBoundedLen(P: PAnsiChar): PtrInt;
begin
  Result := 0;
  if P = nil then
    exit;
  while (Result < PWEB_COCOA_MAX_URI_BYTES) and
        (P[Result] <> #0) do
    Inc(Result);
  if Result >= PWEB_COCOA_MAX_URI_BYTES then
    Result := -1; // longer than anything canonical can be: refuse
end;

function PWebCocoaResolveCallback(AHandle: TPWebCocoaHandle;
  AUrl: PAnsiChar; AAsset: PPWebCocoaAsset): LongInt; cdecl;
var
  store: IAssetStore;
  uri, mime: RawUtf8;
  asset: TAssetResponse;
  body: Pointer;
  size, len: PtrInt;
begin
  Result := PWEB_COCOA_VERDICT_REFUSE;
  body := nil;
  try
    if AAsset = nil then
      exit;
    AAsset^.Bytes := nil;
    AAsset^.Length := 0;
    AAsset^.ContentType[0] := #0;
    // THE URL IS READ FIRST, before the handle is resolved, so that every
    // task the bridge started produces exactly one accounting row: an
    // observation, or a nonconforming tick. The runtime gate asserts
    // observed + nonconforming = tasks_started, which is only a real
    // assertion if no path can return without contributing to one of them.
    len := PWebCocoaBoundedLen(AUrl);
    if len <= 0 then
    begin
      PWebCocoaRecordNonconforming;
      // an unresolved handle still has to be reported AS one, so the bridge
      // can count it separately even when the URL was unusable
      if PWebCocoaStoreOf(AHandle) = nil then
        Result := PWEB_COCOA_VERDICT_UNRESOLVED;
      exit;
    end;
    // the WHOLE URI, copied out of WebKit's storage immediately
    FastSetString(uri, AUrl, len);
    store := PWebCocoaStoreOf(AHandle);
    if store = nil then
    begin
      // a released or never-claimed handle: no store is consulted, no
      // verdict is rendered, and the bridge counts the attempt
      PWebCocoaRecordObservation(uri, 'refuse');
      Result := PWEB_COCOA_VERDICT_UNRESOLVED;
      exit;
    end;
    if not PWebCocoaResolveAssetUri(uri, store, asset) then
    begin
      PWebCocoaRecordObservation(uri, 'refuse');
      exit;
    end;
    mime := PWebCocoaContentType(asset);
    if Length(mime) >= PWEB_COCOA_CONTENT_TYPE_MAX then
    begin
      // fail closed rather than truncate: a truncated Content-Type is a
      // different Content-Type, and the engine would sniff around it
      PWebCocoaRecordObservation(uri, 'refuse');
      exit;
    end;
    // RECORDED BEFORE THE HAND-OVER, deliberately. Recording afterwards put
    // two RawUtf8 assignments and a critical section between "the bridge owns
    // this block" and "we returned 1", and an exception in that window
    // returned REFUSE with AAsset^.Bytes still pointing at a live allocation:
    // a leak, and a violation of the seam contract that *asset is zeroed for
    // every outcome but 1.
    PWebCocoaRecordObservation(uri, 'serve');
    if not PWebCocoaCopyBody(asset.Content, body, size) then
      exit;
    AAsset^.Bytes := body;   // the bridge owns it from here
    AAsset^.Length := size;
    if Length(mime) > 0 then
      Move(pointer(mime)^, AAsset^.ContentType[0], Length(mime));
    AAsset^.ContentType[Length(mime)] := #0;
    body := nil;             // handed over: no longer ours to release
    Result := PWEB_COCOA_VERDICT_SERVE;
  except
    // Fail closed: a constant refusal beats letting an exception cross the C
    // frame. Anything allocated but not yet handed over is released here, and
    // the asset is zeroed, because the seam contract says *asset is zeroed
    // for every outcome other than 1 and a leak is not an acceptable way to
    // keep that promise.
    if body <> nil then
    begin
      PWebCocoaReleaseBody(body);
      body := nil;
    end;
    if AAsset <> nil then
    begin
      AAsset^.Bytes := nil;
      AAsset^.Length := 0;
      AAsset^.ContentType[0] := #0;
    end;
    Result := PWEB_COCOA_VERDICT_REFUSE;
  end;
end;

{ ---- bridge accessors ---- }

function PWebCocoaSeamInvocations: QWord;
begin
  Result := pweb_cocoa_seam_invocations;
end;

function PWebCocoaStats: TPWebCocoaStats;
begin
  pweb_cocoa_get_stats(Result);
end;

function PWebCocoaHandlerInstalledOn(AWebView: Pointer): TPWebCocoaReadback;
var
  raw: LongInt;
begin
  raw := pweb_cocoa_handler_installed_on(AWebView);
  if raw > 0 then
    Result := pcrOurs
  else if raw < 0 then
    Result := pcrForeign
  else
    Result := pcrAbsent;
end;

function PWebCocoaReadbackName(AValue: TPWebCocoaReadback): RawUtf8;
begin
  case AValue of
    pcrOurs: Result := 'ours';
    pcrForeign: Result := 'foreign';
  else
    Result := 'absent';
  end;
end;

function PWebCocoaSeamIsConfined: Boolean;
begin
  Result := pweb_cocoa_seam_is_confined <> 0;
end;

function PWebCocoaFpuTrapsMasked: Boolean;
begin
  Result := PWebCocoaFpuMasked;
end;

function PWebCocoaResidentKb: QWord;
begin
  Result := pweb_cocoa_rss_kb;
end;

function PWebCocoaStubCreate(const AUri: RawUtf8): QWord;
begin
  Result := pweb_cocoa_stub_task_create(PAnsiChar(AUri));
end;

procedure PWebCocoaStubRelease(ATask: QWord);
begin
  pweb_cocoa_stub_task_release(ATask);
end;

procedure PWebCocoaStubStart(ATask: QWord);
begin
  pweb_cocoa_stub_task_start(ATask);
end;

procedure PWebCocoaStubStop(ATask: QWord);
begin
  pweb_cocoa_stub_task_stop(ATask);
end;

procedure PWebCocoaStubLeaveLive(ATask: QWord);
begin
  pweb_cocoa_stub_task_leave_live(ATask);
end;

procedure PWebCocoaStubDeliverAgain(ATask: QWord);
begin
  pweb_cocoa_stub_task_deliver_again(ATask);
end;

function PWebCocoaStubOutcome(ATask: QWord): TPWebCocoaStubOutcome;
begin
  pweb_cocoa_stub_task_outcome(ATask, Result);
end;

{ ---- TCocoaAssetHandler ---- }

constructor TCocoaAssetHandler.Create(const AStore: IAssetStore);
begin
  inherited Create;
  if AStore = nil then
    raise EPWebCocoaAssetHandler.Create('asset store is nil');
  fThreadId := GetCurrentThreadId; // Cocoa/WebKit calls are GUI-affine
  // AGAIN, on the thread that will actually host WebKit. The initialization
  // block below masks the traps on whichever thread loads the unit - normally
  // the main thread, which is also the GUI thread - but FPU control is PER
  // THREAD and nothing in the contract says the handler must be constructed
  // on the same thread the unit initialised on. Idempotent and free.
  if pweb_cocoa_mask_fpu_traps <> 0 then
    raise EPWebCocoaAssetHandler.Create(
      'could not put the FPU in its non-trapping default state - WebKit ' +
      'would kill this process on its first NaN');
  fStore := AStore;
  fReadback := pcrAbsent; // nothing observed until Attach looks
  // the seam is installed once per process and never removed; teardown
  // DISOWNS it. A refusal here means the Objective-C runtime would not let us
  // own +[WKWebViewConfiguration new], which must be loud: an adapter that
  // proceeded would create a webview no handler is installed on.
  if pweb_cocoa_install(@PWebCocoaResolveCallback) = 0 then
    raise EPWebCocoaAssetHandler.Create(
      'the pre-create pweb://app seam could not be installed');
  fHandle := PWebCocoaClaimSlot(Self, AStore);
  if fHandle = 0 then
    raise EPWebCocoaAssetHandler.CreateFmt(
      'more than %d live pweb://app handlers in one process',
      [PWEB_COCOA_MAX_HANDLERS]);
  if pweb_cocoa_arm(fHandle) = 0 then
  begin
    PWebCocoaReleaseSlot(fHandle);
    fHandle := 0;
    raise EPWebCocoaAssetHandler.Create(
      'a pweb://app handler is already armed in this process');
  end;
  // sampled AFTER arming: Attach compares against this, and the only
  // invocations that count are the ones this handler is responsible for
  fSeamBefore := pweb_cocoa_seam_invocations;
end;

destructor TCocoaAssetHandler.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TCocoaAssetHandler.Attach(AWebView: webview_t);
var
  controller: Pointer;
begin
  if AWebView = nil then
    raise EPWebCocoaAssetHandler.Create('webview handle is nil');
  // WKURLSchemeTask is main-thread-only, and Detach messages live tasks, so
  // every argument this class makes rests on Create/Attach/Detach happening
  // on the GUI thread. An off-thread call is refused rather than trusted.
  if GetCurrentThreadId <> fThreadId then
    raise EPWebCocoaAssetHandler.Create(
      'Attach must run on the thread that created the handler (Cocoa and ' +
      'WKURLSchemeTask are GUI-affine)');
  if fHandle = 0 then
    raise EPWebCocoaAssetHandler.Create(
      'this pweb://app handler has already been detached');
  if fAttached then
    raise EPWebCocoaAssetHandler.Create(
      'this pweb://app handler is already attached');
  // STEP 1, the cheap guard: did ANYTHING go through the seam since Create?
  // It is checked FIRST because it costs nothing and because it is safe on a
  // handle that is not really a webview - which is exactly the case the
  // headless suite drives, and which must not reach the native accessor
  // below.
  //
  // On its own this proves little: the counter is process-global and
  // monotonic, so any unrelated +[WKWebViewConfiguration new] anywhere would
  // move it.
  if pweb_cocoa_seam_invocations <= fSeamBefore then
    raise EPWebCocoaAssetHandler.Create(
      'the pre-create seam did not run: webview_create did not go through ' +
      '+[WKWebViewConfiguration new], so no pweb://app handler is installed ' +
      'on this WebView');
  // STEP 2, the one that actually answers the question: does THIS view route
  // pweb:// to OUR handler? Read positively, through public API, from the
  // configuration the view itself hands back. CAP-7M0 measured that WRITING
  // there is silently ineffective; that is a statement about mutation, and
  // reading back a registration the configuration was copied with is a
  // different operation. Without this step, "the seam ran" and "this webview
  // is served" are two different claims and only the weaker one was made.
  controller := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if controller = nil then
    raise EPWebCocoaAssetHandler.Create(
      'borrowed browser controller is unavailable');
  // NOW A HARD GATE, and it was not always one. This started as
  // refuse-on-pcrForeign-only, because pcrAbsent could not distinguish
  // "nothing is installed" from "the configuration copy this view hands back
  // does not carry the scheme-handler map" - CAP-7M0 measured only that
  // WRITING to that copy is ineffective, which says nothing about reading it.
  // Gating an unmeasured assumption would have failed a correct adapter, so
  // the first runs RECORDED the answer instead.
  //
  // MEASURED, run 31952514083: `readback=ours` on every cycle, on x86_64 AND
  // aarch64. The copy does carry the registration, the ambiguity is gone, and
  // the promotion the ledger described is taken here. Attach now proves what
  // its name claims - that THIS view routes pweb:// to THIS handler - rather
  // than that a process-global counter moved.
  fReadback := PWebCocoaHandlerInstalledOn(controller);
  if fReadback = pcrForeign then
    raise EPWebCocoaAssetHandler.Create(
      'another pweb:// scheme handler is installed on THIS WebView - ' +
      'something else constructed its configuration');
  if fReadback <> pcrOurs then
    raise EPWebCocoaAssetHandler.Create(
      'the pre-create seam ran, but THIS WebView does not report our ' +
      'pweb:// handler - measured as reachable on both architectures, so ' +
      'an absent read-back is drift, not the platform being coy');
  fWebView := AWebView; // borrowed - never destroyed here
  fAttached := True;
end;

procedure TCocoaAssetHandler.Detach;
begin
  // Same affinity rule as Attach, and here it is load-bearing rather than
  // defensive: the claim-and-fail below sends didFailWithError: to live
  // WKURLSchemeTasks, which is main-thread-only. Destroy calls Detach, so a
  // handler released on a worker raises from its destructor - loud, and
  // better than undefined behaviour inside WebKit.
  if (fHandle <> 0) and
     (GetCurrentThreadId <> fThreadId) then
    raise EPWebCocoaAssetHandler.Create(
      'Detach must run on the thread that created the handler (it completes ' +
      'live WKURLSchemeTasks, which are GUI-affine)');
  if fHandle <> 0 then
  begin
    // ORDER IS THE WHOLE POINT.
    //   1. disown: the bridge stops calling out at all;
    //   2. claim and fail every live task, so teardown never leaves a
    //      request WebKit waits on forever;
    //   3. release the slot, which makes the handle UNRESOLVABLE - a
    //      callback that somehow still arrives finds nothing rather than
    //      finding a freed object.
    // Only after all three may webview_destroy run.
    pweb_cocoa_disown(fHandle);
    pweb_cocoa_fail_live_tasks;
    PWebCocoaReleaseSlot(fHandle);
    fHandle := 0;
  end;
  fAttached := False;
  fWebView := nil; // borrowed
  fStore := nil;
end;

initialization
  { MEASURED, run 31951505821, and not optional: without this EVERY cycle of
    the production runtime harness died with 'EInvalidOp: Invalid floating
    point operation' before one asset was served.

    FPC starts a process with the invalid-operation, divide-by-zero and
    overflow traps ENABLED - on x86_64 and on aarch64 alike. WebKit,
    CoreGraphics and AppKit compute with NaNs, infinities and denormals as
    ordinary intermediate values, so the first such computation traps inside a
    C frame with no handler and the process dies.

    This is CAP-7L's Linux finding on a second backend, and the reason it was
    not simply copied is that CAP-7L's remedy - Set8087CW + SetSSECSR - is
    x86-only and would not compile for aarch64-darwin, where the same state
    lives in FPCR with the OPPOSITE polarity. The masking therefore happens in
    the bridge through fesetenv(FE_DFL_ENV), where libc knows which register
    it is; see pweb_cocoa_mask_fpu_traps.

    It belongs HERE, in the engine adapter's initialization, for exactly the
    reason CAP-7L gives: linking this unit IS the decision to host WebKit in
    this process. An application that never uses the macOS WebView never pays
    for it, and one that does cannot forget it. It runs before any application
    code, so no window can be created ahead of it, and before any worker
    thread exists, so workers inherit the masked state.

    Deliberately NOT math.SetExceptionMask - the CAP-7L measurement that made
    that choice applies unchanged here: math's finalization restores the FPU
    control words, and mORMot's units initialise earlier and therefore
    finalise LATER, performing floating point with the traps live again. That
    produced a completely successful run that then exited 217. Going through
    libc leaves nothing to unwind. }
  // RECORDED rather than raised. A unit initialization that raises takes the
  // process down with a message nobody can attribute to a cause;
  // TCocoaAssetHandler.Create re-applies and DOES raise, which is where a
  // caller can actually see it. The flag exists so the runtime gate can state
  // the fix ran rather than infer it from the absence of a crash.
  PWebCocoaFpuMasked := pweb_cocoa_mask_fpu_traps = 0;
  // Initialised and never destroyed, deliberately: a WebKit callback can in
  // principle still arrive while the process is tearing down, and a critical
  // section finalised out from under it would be worse than one leaked for a
  // few microseconds of process lifetime. The registry is static storage for
  // the same reason.
  InitCriticalSection(PWebCocoaLock);

end.
