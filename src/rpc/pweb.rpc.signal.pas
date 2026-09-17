{
  pweb.rpc.signal - the native -> page signal channel (CAP-16).

  SIGNAL, THEN PULL. Native state changes on its own schedule - a process
  exits, a socket receives, a job logs a line - and the page has to learn
  that WITHOUT holding a scheduler worker open to wait for it. This unit is
  how: native code bumps a per-topic sequence number, and the page is told
  "topic T is at N" and then reads whatever it needs through an ordinary
  invocation. Data never rides the channel.

    native   Signal(topic): seq[topic] += 1, from ANY thread, coalesced per
             topic - the last sequence wins
    drain    one GUI dispatch per tick, at most PWEB_SIGNAL_TICKS_PER_SECOND
             ticks a second per window, and ONE script per tick carrying
             every pending (topic, seq) pair as a JSON array
    page     the SDK hears `pweb:signal` and invokes whatever it reads
             `since` its own cursor. A lost signal costs latency, never
             correctness: on load and after any navigation the SDK re-reads

  Two runtime-owned methods, and no capability of their own:

    pweb.signalSubscribe     topic   ->  (topic, seq)
    pweb.signalUnsubscribe   topic   ->  an empty object

  ---------------------------------------------------------------------------
  THE ONE INJECTED SCRIPT
  ---------------------------------------------------------------------------

  Every other native -> page call in PWeb is the upstream promise
  resolution. This channel adds the first script the RUNTIME writes, and
  its whole shape is PWEB_SIGNAL_EVAL_TEMPLATE below: one literal, one
  placeholder, and the placeholder is a JSON array built by
  PWebSignalScript from topic strings encoded to PRINTABLE ASCII (every
  quote, backslash, angle bracket, ampersand, apostrophe, control byte and
  non-ASCII code point - U+2028 and U+2029 included - becomes a \uXXXX
  escape) and sequence numbers written as decimal integers. A topic is
  grammar-restricted before it is ever declared, and it is encoded anyway.

  It carries NO AUTHORITY. The page is told a topic name it subscribed to
  and a counter; neither grants, names or reaches anything, because every
  read the signal prompts is an invocation the capability policy decides
  from the native context. A page that dispatches the same event to itself
  gains nothing: the signal only ever prompts a read the page was already
  allowed to make.

  The script is evaluated by the HOST, through the injected Eval seam, and
  nowhere else: pweb.webview.host carries the product's one webview_eval
  call site (test/cap16 pins the count at one).

  ---------------------------------------------------------------------------
  SUBSCRIPTIONS
  ---------------------------------------------------------------------------

  Topics are DECLARED at composition, like services: application topics by
  the constructor, runtime topics (the socket door's `pweb.socket`) by
  DeclareWindowTopic before the host runs. Subscribing needs the capability
  `signal.<topic>` - or, for a runtime topic, the capability its door
  declared - in the policy's EFFECTIVE set for the calling (principal,
  window), decided here from the CAP-8A policy's own answer at the moment
  of the call. An undeclared topic is answered exactly as a topic the
  caller may not read: `forbidden`.

  A subscription belongs to the (window, principal) of the native context.
  It ends when the page unsubscribes, when its document is replaced, when
  its capability is revoked - and no script carrying the topic is issued
  after the revoking call returns, because the drain evaluates UNDER the
  same lock the revocation takes - and when the host drains.

  ---------------------------------------------------------------------------
  THE HOOKS - single slot, owned here
  ---------------------------------------------------------------------------

  The capability policy has ONE grants subscriber and the host has ONE
  document seam and ONE drain seam. This channel owns all three and hands
  each on to the ONE door that attached to it (the socket door), after its
  own work and outside its own lock. There is no fan-out.

  Lock order: a door's lock may be held while calling Signal/SignalWindow;
  this channel never calls a door while holding its own lock.

  Platform-free, like the other doors: no mormot.net.*, no webview unit, no
  compiler conditional, no operating system.
}
unit pweb.rpc.signal;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.json,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.capabilities.policy;

const
  { The two runtime-owned methods, spelled ONCE for the whole repository.
    Both are registered capability-FREE by a host's policy: the authority
    is the per-topic capability this unit reads from the policy. }
  PWEB_METHOD_SIGNAL_SUBSCRIBE = 'pweb.signalSubscribe';
  PWEB_METHOD_SIGNAL_UNSUBSCRIBE = 'pweb.signalUnsubscribe';

  /// the feature name pweb.handshake advertises when this channel is
  // installed - an ADDITIVE member, protocol v1 unchanged
  PWEB_SIGNAL_FEATURE = 'signal';

  /// the DOM event the page hears, on `window`
  PWEB_SIGNAL_EVENT = 'pweb:signal';

  /// an application topic T is read under the capability `signal.T`
  PWEB_SIGNAL_CAP_PREFIX = 'signal.';

  /// the runtime-reserved topic prefix, refused for application topics
  PWEB_SIGNAL_RESERVED_PREFIX = 'pweb.';

  /// the socket door's topic: window-scoped, read under network.socket
  PWEB_SIGNAL_TOPIC_SOCKET = 'pweb.socket';

  /// THE ONE SCRIPT. One literal; `%` is the only variable part and is
  // replaced by the JSON array PWebSignalScript builds
  PWEB_SIGNAL_EVAL_TEMPLATE =
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:%}))';

  { --- the ratified bounds (cap16-checkpoint1.md) - ONE constants home;
    test/cap16 cross-checks them against both SDKs ------------------------ }

  /// R: the most scripts one window is sent per second
  PWEB_SIGNAL_TICKS_PER_SECOND = 20;
  /// the pacing interval that follows from R
  PWEB_SIGNAL_TICK_MS = 1000 div PWEB_SIGNAL_TICKS_PER_SECOND;
  /// topics per host, runtime topics included
  PWEB_SIGNAL_MAX_TOPICS = 64;
  /// subscriptions per window - and so the most pairs one script carries
  PWEB_SIGNAL_MAX_SUBSCRIPTIONS = 32;
  /// windows one channel tracks
  PWEB_SIGNAL_MAX_WINDOWS = 8;
  /// one topic, in bytes; `signal.` + 64 stays inside the capability bound
  PWEB_SIGNAL_MAX_TOPIC_BYTES = 64;

  /// the typed service_error category of a subscription bound
  PWEB_SIGNAL_CAT_LIMIT = 'signal_limit';

type
  /// raised only for direct misuse of this API at composition time
  EPWebSignal = class(Exception);

  TPWebSignalPair = record
    Topic: RawUtf8;
    Seq: Int64;
  end;
  TPWebSignalPairs = array of TPWebSignalPair;

  /// schedule ONE Drain(Window) on the GUI thread and return at once
  // - thread-safe; False when there is no live view to ask
  TPWebSignalDispatchFn = function(const Window: RawUtf8): Boolean;
  /// evaluate Script in Window's document; GUI thread only
  // - the channel calls it from Drain, under its lock, with a script
  // PWebSignalScript built and nothing else
  TPWebSignalEvalFn = procedure(const Window: RawUtf8; const Script: RawUtf8);

  /// the host's side of the channel
  TPWebSignalView = record
    Dispatch: TPWebSignalDispatchFn;
    Eval: TPWebSignalEvalFn;
  end;

  TPWebSignalDocumentProc = procedure(const WindowId: RawUtf8) of object;
  TPWebSignalNotifyProc = procedure of object;

  /// the ONE door that subscribes to this channel's lifecycle
  // - ChannelGone: this channel is being destroyed and the door must forget
  // it. A door holds NO counted reference to its channel - the channel
  // usually wraps the door as its inner bridge, and a counted reference
  // back would be a cycle neither side could ever release
  TPWebSignalDoor = record
    DocumentReplacing: TPWebSignalDocumentProc;
    GrantsChanged: TPWebGrantsChangedEvent;
    BeforeDrain: TPWebSignalNotifyProc;
    ChannelGone: TPWebSignalNotifyProc;
  end;

  /// the bounds a channel runs with - the constants above, except in a
  // test harness that measures a different rate
  TPWebSignalBounds = record
    TicksPerSecond: Integer;
    MaxTopics: Integer;
    MaxSubscriptions: Integer;
    MaxWindows: Integer;
  end;

  TPWebSignalTopic = record
    Name: RawUtf8;
    Capability: RawUtf8;
    WindowScoped: Boolean;
    Seq: Int64;
  end;

  { One window's subscriptions and its coalesced queue. Guarded by the
    channel's lock. Subscribed[i], Pending[i] and WindowSeq[i] are indexed
    by topic. }
  TPWebSignalTarget = class
  public
    WindowId: RawUtf8;
    PrincipalId: RawUtf8;
    Subscribed: array of Boolean;
    SubscriptionCount: Integer;
    PendingSeq: array of Int64;
    Pending: array of Boolean;
    PendingCount: Integer;
    WindowSeq: array of Int64;
    Outstanding: Boolean;
    Stalled: Boolean;
    /// when the last drain ran, in MICROseconds - a tick is measured with the
    // high-resolution clock, because a coarse one (about 16 ms on Windows)
    // would let two scripts land closer than the tick
    LastDrainUs: Int64;
    Evals: Int64;
    LastScript: RawUtf8;
  end;

  TPWebSignalChannel = class;

  TPWebSignalPacer = class(TThread)
  private
    FChannel: TPWebSignalChannel;
  protected
    procedure Execute; override;
  public
    constructor CreateFor(AChannel: TPWebSignalChannel);
  end;

  { The native signal channel: an IInvocationBridge decorator for the two
    subscription methods and the handshake feature, the coalescing queue,
    the pacer, and the owner of the three single-slot hooks. }
  TPWebSignalChannel = class(TInterfacedObject, IInvocationBridge)
  private
    FInner: IInvocationBridge;
    FBounds: TPWebSignalBounds;
    FLock: TCriticalSection;
    FWake: PRTLEvent;
    FTopics: array of TPWebSignalTopic;
    FTargets: array of TPWebSignalTarget;
    FView: TPWebSignalView;
    FViewAttached: Boolean;
    FDoor: TPWebSignalDoor;
    FDoorAttached: Boolean;
    FPolicy: TPWebCapabilityPolicy;
    FPolicyRef: ICapabilityPolicy;
    FPacer: TPWebSignalPacer;
    FDraining: Boolean;
    FEvals: Int64;
    FDispatches: Int64;
    FSignals: Int64;
    procedure AddTopic(const Topic, Capability: RawUtf8;
      WindowScoped: Boolean);
    function TopicIndexLocked(const Topic: RawUtf8): Integer;
    function TargetLocked(const WindowId: RawUtf8): TPWebSignalTarget;
    function NewTargetLocked(const WindowId,
      PrincipalId: RawUtf8): TPWebSignalTarget;
    procedure MarkLocked(T: TPWebSignalTarget; Topic: Integer; Seq: Int64);
    procedure DropLocked(T: TPWebSignalTarget; Topic: Integer);
    function Subscribe(const Context: TInvocationContext;
      const Args: TPWebJson): TPWebInvocationResult;
    function Unsubscribe(const Context: TInvocationContext;
      const Args: TPWebJson): TPWebInvocationResult;
    function Handshake(const Context: TInvocationContext;
      const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
    procedure GrantsChanged(const APrincipalId: Utf8String);
    /// the pacer's one step: returns how long it may sleep
    function PaceStep: Integer;
  public
    { Fail closed at startup: a nil inner bridge or an application topic
      the grammar refuses, reserved, duplicated or over a bound raises. }
    constructor Create(const AInner: IInvocationBridge;
      const ATopics: array of RawUtf8); overload;
    constructor Create(const AInner: IInvocationBridge;
      const ATopics: array of RawUtf8;
      const ABounds: TPWebSignalBounds); overload;
    destructor Destroy; override;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;

    { --- composition: before the host runs --------------------------- }

    /// declare a RUNTIME topic (a `pweb.` name), window-scoped, read under
    // ACapability - the socket door declares `pweb.socket` / network.socket
    procedure DeclareWindowTopic(const ATopic, ACapability: RawUtf8);
    /// the one door; a second raises
    procedure AttachDoor(const ADoor: TPWebSignalDoor);
    /// a door that is going away gives its slot back; any other is ignored
    procedure DetachDoor(const ADoor: TPWebSignalDoor);
    /// take the policy's single grants slot; a taken slot raises
    procedure AttachPolicy(APolicy: TPWebCapabilityPolicy);
    /// the host's view seam; freezes the topic set and starts the pacer
    procedure AttachView(const AView: TPWebSignalView);
    /// the host's view is going away: no further dispatch or script.
    // Called on the GUI thread before the view is destroyed
    procedure DetachView;

    { --- emission: any thread ----------------------------------------- }

    /// an application topic changed; False for an unknown or runtime topic
    // or after the drain began
    function Signal(const ATopic: RawUtf8): Boolean;
    /// a window-scoped runtime topic changed for ONE window
    function SignalWindow(const AWindowId, ATopic: RawUtf8): Boolean;

    { --- the GUI thread ------------------------------------------------- }

    /// the dispatched tick: one script, every pending pair, then clear
    procedure Drain(const AWindowId: RawUtf8);

    { --- lifecycle ------------------------------------------------------ }

    /// the document of this window is being replaced: its subscriptions
    // and its queue go NOW. GUI thread; never blocks on a worker
    procedure DocumentReplacing(const AWindowId: RawUtf8);
    /// the host is about to drain its scheduler: everything stops, the
    // pacer is joined, and the door is told
    procedure BeforeDrain;
    /// the attached policy's effective set for a (principal, window) -
    // what a door asks when it is told grants changed
    function SnapshotCapabilities(const APrincipalId,
      AWindowId: Utf8String): TPWebCapabilities;

    { --- observation, for the host's accounting and the gates --------- }

    function EvalCount: Int64;
    function DispatchCount: Int64;
    function SignalCount: Int64;
    function WindowEvalCount(const AWindowId: RawUtf8): Int64;
    function WindowLastScript(const AWindowId: RawUtf8): RawUtf8;
    function PendingCount(const AWindowId: RawUtf8): Integer;
    function SubscriptionCount(const AWindowId: RawUtf8): Integer;
    function TopicCount: Integer;
    function TopicSeq(const ATopic: RawUtf8): Int64;
    function Bounds: TPWebSignalBounds;
  end;

/// the ratified bounds
function PWebSignalDefaultBounds: TPWebSignalBounds;

/// is ATopic an acceptable topic name: the capability grammar, at most
/// PWEB_SIGNAL_MAX_TOPIC_BYTES bytes
function PWebSignalValidTopic(const ATopic: RawUtf8): Boolean;

/// S as a JSON string literal made of PRINTABLE ASCII only
// - `"`, `\`, `<`, `>`, `&`, `'`, every byte below $20, $7F, and every code
// point above U+007E (U+2028/U+2029 included) are \uXXXX escapes; a byte
// that is not valid UTF-8 becomes the escape of U+FFFD
function PWebSignalJsonString(const S: RawUtf8): RawUtf8;

/// THE SCRIPT: PWEB_SIGNAL_EVAL_TEMPLATE with its one placeholder replaced
/// by `[["topic",seq],...]`
function PWebSignalScript(const APairs: TPWebSignalPairs): RawUtf8;

/// signal an application topic on the channel of the RUNNING host
// - False when no host is running with a channel, or the topic is unknown
function PWebSignal(const ATopic: RawUtf8): Boolean;

/// the host's registration of its channel for PWebSignal - host only
procedure PWebSignalInstall(AChannel: TPWebSignalChannel);
procedure PWebSignalUninstall(AChannel: TPWebSignalChannel);

implementation

const
  /// how long the pacer sleeps with nothing to pace
  PACER_IDLE_MS = 1000;

var
  GlobalLock: TCriticalSection;
  GlobalChannel: TPWebSignalChannel;

function PWebSignalDefaultBounds: TPWebSignalBounds;
begin
  Result.TicksPerSecond := PWEB_SIGNAL_TICKS_PER_SECOND;
  Result.MaxTopics := PWEB_SIGNAL_MAX_TOPICS;
  Result.MaxSubscriptions := PWEB_SIGNAL_MAX_SUBSCRIPTIONS;
  Result.MaxWindows := PWEB_SIGNAL_MAX_WINDOWS;
end;

function PWebSignalValidTopic(const ATopic: RawUtf8): Boolean;
begin
  Result := (Length(ATopic) >= 1) and
            (Length(ATopic) <= PWEB_SIGNAL_MAX_TOPIC_BYTES) and
            PWebValidCapability(Utf8String(ATopic));
end;

{ ---------------------------------------------------------------------------
  the script
  --------------------------------------------------------------------------- }

procedure AppendEscape(var Dest: RawUtf8; CodeUnit: Cardinal);
const
  HEX: array[0 .. 15] of AnsiChar = '0123456789abcdef';
var
  s: string[6];
begin
  s := #92'u0000';
  s[3] := HEX[(CodeUnit shr 12) and 15];
  s[4] := HEX[(CodeUnit shr 8) and 15];
  s[5] := HEX[(CodeUnit shr 4) and 15];
  s[6] := HEX[CodeUnit and 15];
  Dest := Dest + RawUtf8(s);
end;

// one code point from S at I (1-based), or $FFFD for a byte that does not
// start a valid, shortest-form sequence; I advances past what was read
function NextCodePoint(const S: RawUtf8; var I: PtrInt): Cardinal;
var
  b0, b: Byte;
  need, k: Integer;
  cp, minimum: Cardinal;
begin
  b0 := Ord(S[I]);
  Inc(I);
  if b0 < $80 then
    exit(b0);
  if (b0 and $E0) = $C0 then
  begin
    need := 1;
    cp := b0 and $1F;
    minimum := $80;
  end
  else if (b0 and $F0) = $E0 then
  begin
    need := 2;
    cp := b0 and $0F;
    minimum := $800;
  end
  else if (b0 and $F8) = $F0 then
  begin
    need := 3;
    cp := b0 and $07;
    minimum := $10000;
  end
  else
    exit($FFFD);
  if I + need - 1 > Length(S) then
    exit($FFFD);
  for k := 0 to need - 1 do
  begin
    b := Ord(S[I + k]);
    if (b and $C0) <> $80 then
      exit($FFFD);
    cp := (cp shl 6) or (b and $3F);
  end;
  if (cp < minimum) or
     (cp > $10FFFF) or
     ((cp >= $D800) and (cp <= $DFFF)) then
    exit($FFFD);
  Inc(I, need);
  Result := cp;
end;

function PWebSignalJsonString(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
  cp: Cardinal;
  c: AnsiChar;
begin
  Result := '"';
  i := 1;
  while i <= Length(S) do
  begin
    c := S[i];
    if (c >= ' ') and
       (c <= '~') and
       not (c in ['"', '\', '<', '>', '&', '''']) then
    begin
      Result := Result + c;
      Inc(i);
      continue;
    end;
    cp := NextCodePoint(S, i);
    if cp >= $10000 then
    begin
      Dec(cp, $10000);
      AppendEscape(Result, $D800 + (cp shr 10));
      AppendEscape(Result, $DC00 + (cp and $3FF));
    end
    else
      AppendEscape(Result, cp);
  end;
  Result := Result + '"';
end;

function PWebSignalScript(const APairs: TPWebSignalPairs): RawUtf8;
var
  detail: RawUtf8;
  i, at: PtrInt;
begin
  detail := '[';
  for i := 0 to High(APairs) do
  begin
    if i > 0 then
      detail := detail + ',';
    detail := detail + '[' + PWebSignalJsonString(APairs[i].Topic) + ',' +
      RawUtf8(IntToStr(APairs[i].Seq)) + ']';
  end;
  detail := detail + ']';
  at := Pos('%', PWEB_SIGNAL_EVAL_TEMPLATE);
  Result := Copy(PWEB_SIGNAL_EVAL_TEMPLATE, 1, at - 1) + detail +
    Copy(PWEB_SIGNAL_EVAL_TEMPLATE, at + 1, MaxInt);
end;

{ ---------------------------------------------------------------------------
  arguments - one member, `topic`, a string, and nothing else
  --------------------------------------------------------------------------- }

procedure SkipBlanks(var P: PUtf8Char);
begin
  while (P <> nil) and
        (P^ <= ' ') and
        (P^ <> #0) do
    Inc(P);
end;

function DecodeTopicArg(const Args: TPWebJson; out Topic: RawUtf8): Boolean;
var
  payload, name: RawUtf8;
  field: TGetJsonField;
  seen: Boolean;
begin
  Result := False;
  Topic := '';
  // mORMot's parser unescapes IN PLACE: never walk the caller's buffer
  payload := RawUtf8(Args);
  UniqueRawUtf8(payload);
  if (payload = '') or
     (payload = PWEB_JSON_NULL) then
    exit;
  field.Json := pointer(payload);
  SkipBlanks(field.Json);
  if (field.Json = nil) or
     (field.Json^ <> '{') then
    exit;
  Inc(field.Json);
  SkipBlanks(field.Json);
  if (field.Json <> nil) and
     (field.Json^ = '}') then
    exit;
  seen := False;
  repeat
    if not field.GetJsonFieldName then
      exit;
    FastSetString(name, field.Value, field.ValueLen);
    field.GetJsonFieldOrObjectOrArray({HandleValuesAsObjectOrArray=}true);
    if field.Json = nil then
      exit;
    if (name <> 'topic') or
       seen then
      exit;
    seen := True;
    if (field.Value = nil) or
       not field.WasString then
      exit;
    FastSetString(Topic, field.Value, field.ValueLen);
  until field.EndOfObject <> ',';
  Result := seen and
            (field.EndOfObject = '}');
end;

function Refused: TPWebInvocationResult;
begin
  // an undeclared topic, a topic the caller may not read and a caller that
  // is not a window are ONE answer: this door is not an oracle for topics
  Result := PWebDefaultErrorResult(pecForbidden);
end;

function LimitError(const Bound: RawUtf8; Max: Integer): TPWebInvocationResult;
begin
  Result := PWebErrorResult(pecServiceError, PWEB_SIGNAL_CAT_LIMIT,
    TPWebJson('{"category":"' + PWEB_SIGNAL_CAT_LIMIT + '","bound":"' +
      Bound + '","max":' + RawUtf8(IntToStr(Max)) + '}'));
end;

{ ---------------------------------------------------------------------------
  TPWebSignalPacer - at most R dispatches a second per window
  --------------------------------------------------------------------------- }

constructor TPWebSignalPacer.CreateFor(AChannel: TPWebSignalChannel);
begin
  FChannel := AChannel;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPWebSignalPacer.Execute;
var
  sleepMs: Integer;
begin
  while not Terminated do
  begin
    try
      sleepMs := FChannel.PaceStep;
    except
      // the pacer never dies of one window
      sleepMs := PWEB_SIGNAL_TICK_MS;
    end;
    if Terminated then
      break;
    if sleepMs > 0 then
      RTLEventWaitFor(FChannel.FWake, sleepMs);
  end;
end;

{ ---------------------------------------------------------------------------
  TPWebSignalChannel
  --------------------------------------------------------------------------- }

constructor TPWebSignalChannel.Create(const AInner: IInvocationBridge;
  const ATopics: array of RawUtf8);
begin
  Create(AInner, ATopics, PWebSignalDefaultBounds);
end;

constructor TPWebSignalChannel.Create(const AInner: IInvocationBridge;
  const ATopics: array of RawUtf8; const ABounds: TPWebSignalBounds);
var
  i: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := RTLEventCreate;
  if AInner = nil then
    raise EPWebSignal.Create('TPWebSignalChannel requires an inner bridge');
  if (ABounds.TicksPerSecond < 1) or
     (ABounds.TicksPerSecond > 1000) or
     (ABounds.MaxTopics < 1) or
     (ABounds.MaxSubscriptions < 1) or
     (ABounds.MaxWindows < 1) then
    raise EPWebSignal.Create('TPWebSignalChannel refuses its bounds');
  FInner := AInner;
  FBounds := ABounds;
  for i := 0 to High(ATopics) do
  begin
    if Copy(ATopics[i], 1, Length(PWEB_SIGNAL_RESERVED_PREFIX)) =
       PWEB_SIGNAL_RESERVED_PREFIX then
      raise EPWebSignal.CreateFmt(
        'the application topic "%s" is in the runtime-reserved namespace',
        [ATopics[i]]);
    AddTopic(ATopics[i], PWEB_SIGNAL_CAP_PREFIX + ATopics[i], False);
  end;
end;

destructor TPWebSignalChannel.Destroy;
var
  i: Integer;
  policy: TPWebCapabilityPolicy;
  gone: TPWebSignalNotifyProc;
begin
  PWebSignalUninstall(Self);
  // NOT BeforeDrain - that is the host's call, made in its order. What the
  // door is told here is only that this channel no longer exists
  FLock.Enter;
  try
    FDraining := True;
    gone := nil;
    if FDoorAttached then
      gone := FDoor.ChannelGone;
    FDoorAttached := False;
    FDoor := Default(TPWebSignalDoor);
    policy := FPolicy;
  finally
    FLock.Leave;
  end;
  if Assigned(gone) then
    gone();
  if (policy <> nil) and
     (TMethod(policy.OnGrantsChanged).Data = Pointer(Self)) then
    policy.OnGrantsChanged := nil;
  if FPacer <> nil then
  begin
    FPacer.Terminate;
    RTLEventSetEvent(FWake);
    FPacer.WaitFor;
    FreeAndNil(FPacer);
  end;
  // the inner bridge goes while this channel's lock still exists: a door
  // wrapped by this channel is released here, and may still call DetachDoor
  FInner := nil;
  for i := 0 to High(FTargets) do
    FTargets[i].Free;
  FTargets := nil;
  RTLEventDestroy(FWake);
  FLock.Free;
  inherited Destroy;
end;

procedure TPWebSignalChannel.AddTopic(const Topic, Capability: RawUtf8;
  WindowScoped: Boolean);
var
  n: Integer;
begin
  if not PWebSignalValidTopic(Topic) then
    raise EPWebSignal.CreateFmt('the topic "%s" is not a valid topic', [Topic]);
  if not PWebValidCapability(Utf8String(Capability)) then
    raise EPWebSignal.CreateFmt(
      'the topic "%s" names an invalid capability "%s"', [Topic, Capability]);
  if TopicIndexLocked(Topic) >= 0 then
    raise EPWebSignal.CreateFmt('the topic "%s" is declared twice', [Topic]);
  if Length(FTopics) >= FBounds.MaxTopics then
    raise EPWebSignal.CreateFmt('more than %d topics', [FBounds.MaxTopics]);
  if FViewAttached or
     (Length(FTargets) > 0) then
    raise EPWebSignal.Create(
      'topics are declared at composition, before the host runs');
  n := Length(FTopics);
  SetLength(FTopics, n + 1);
  FTopics[n].Name := Topic;
  UniqueString(FTopics[n].Name);
  FTopics[n].Capability := Capability;
  UniqueString(FTopics[n].Capability);
  FTopics[n].WindowScoped := WindowScoped;
  FTopics[n].Seq := 0;
end;

procedure TPWebSignalChannel.DeclareWindowTopic(const ATopic,
  ACapability: RawUtf8);
begin
  FLock.Enter;
  try
    if Copy(ATopic, 1, Length(PWEB_SIGNAL_RESERVED_PREFIX)) <>
       PWEB_SIGNAL_RESERVED_PREFIX then
      raise EPWebSignal.CreateFmt(
        'the runtime topic "%s" is outside the reserved namespace', [ATopic]);
    AddTopic(ATopic, ACapability, True);
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSignalChannel.AttachDoor(const ADoor: TPWebSignalDoor);
begin
  FLock.Enter;
  try
    if FDoorAttached then
      raise EPWebSignal.Create('the signal channel already has a door');
    FDoor := ADoor;
    FDoorAttached := True;
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSignalChannel.DetachDoor(const ADoor: TPWebSignalDoor);
begin
  FLock.Enter;
  try
    if FDoorAttached and
       (TMethod(FDoor.BeforeDrain).Data = TMethod(ADoor.BeforeDrain).Data) then
    begin
      FDoorAttached := False;
      FDoor := Default(TPWebSignalDoor);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPWebSignalChannel.AttachPolicy(APolicy: TPWebCapabilityPolicy);
begin
  if APolicy = nil then
    raise EPWebSignal.Create('AttachPolicy requires a policy');
  if Assigned(APolicy.OnGrantsChanged) then
    raise EPWebSignal.Create('the policy already has a grants subscriber');
  FLock.Enter;
  try
    if FPolicy <> nil then
      raise EPWebSignal.Create('the signal channel already has a policy');
    FPolicy := APolicy;
    FPolicyRef := APolicy;
  finally
    FLock.Leave;
  end;
  APolicy.OnGrantsChanged := @GrantsChanged;
end;

procedure TPWebSignalChannel.AttachView(const AView: TPWebSignalView);
var
  i: Integer;
begin
  if not Assigned(AView.Dispatch) or
     not Assigned(AView.Eval) then
    raise EPWebSignal.Create('AttachView requires a dispatch and an eval');
  FLock.Enter;
  try
    if FDraining then
      raise EPWebSignal.Create('the signal channel has drained');
    if FViewAttached then
      raise EPWebSignal.Create('the signal channel already has a view');
    FView := AView;
    FViewAttached := True;
    for i := 0 to High(FTargets) do
      FTargets[i].Stalled := False;
  finally
    FLock.Leave;
  end;
  if FPacer = nil then
    FPacer := TPWebSignalPacer.CreateFor(Self);
  RTLEventSetEvent(FWake);
end;

procedure TPWebSignalChannel.DetachView;
begin
  FLock.Enter;
  try
    FView := Default(TPWebSignalView);
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.TopicIndexLocked(const Topic: RawUtf8): Integer;
begin
  for Result := 0 to High(FTopics) do
    if FTopics[Result].Name = Topic then
      exit;
  Result := -1;
end;

function TPWebSignalChannel.TargetLocked(
  const WindowId: RawUtf8): TPWebSignalTarget;
var
  i: Integer;
begin
  for i := 0 to High(FTargets) do
    if FTargets[i].WindowId = WindowId then
      exit(FTargets[i]);
  Result := nil;
end;

function TPWebSignalChannel.NewTargetLocked(const WindowId,
  PrincipalId: RawUtf8): TPWebSignalTarget;
var
  n: Integer;
begin
  Result := TPWebSignalTarget.Create;
  Result.WindowId := WindowId;
  UniqueString(Result.WindowId);
  Result.PrincipalId := PrincipalId;
  UniqueString(Result.PrincipalId);
  // sized ONCE for the frozen topic set: a signal never allocates
  SetLength(Result.Subscribed, Length(FTopics));
  SetLength(Result.PendingSeq, Length(FTopics));
  SetLength(Result.Pending, Length(FTopics));
  SetLength(Result.WindowSeq, Length(FTopics));
  n := Length(FTargets);
  SetLength(FTargets, n + 1);
  FTargets[n] := Result;
end;

procedure TPWebSignalChannel.MarkLocked(T: TPWebSignalTarget; Topic: Integer;
  Seq: Int64);
begin
  if not T.Subscribed[Topic] then
    exit;
  // COALESCED: one entry per topic, and the last sequence wins
  T.PendingSeq[Topic] := Seq;
  if not T.Pending[Topic] then
  begin
    T.Pending[Topic] := True;
    Inc(T.PendingCount);
  end;
  // a view that refused a dispatch is asked again on the next change - at
  // the tick's pace, because the refusal counted as one
  T.Stalled := False;
  if not T.Outstanding then
    RTLEventSetEvent(FWake);
end;

procedure TPWebSignalChannel.DropLocked(T: TPWebSignalTarget; Topic: Integer);
begin
  if T.Pending[Topic] then
  begin
    T.Pending[Topic] := False;
    Dec(T.PendingCount);
  end;
  if T.Subscribed[Topic] then
  begin
    T.Subscribed[Topic] := False;
    Dec(T.SubscriptionCount);
  end;
end;

function TPWebSignalChannel.Signal(const ATopic: RawUtf8): Boolean;
var
  k, i: Integer;
  seq: Int64;
begin
  Result := False;
  FLock.Enter;
  try
    if FDraining then
      exit;
    k := TopicIndexLocked(ATopic);
    if (k < 0) or
       FTopics[k].WindowScoped then
      exit;
    Inc(FTopics[k].Seq);
    seq := FTopics[k].Seq;
    Inc(FSignals);
    for i := 0 to High(FTargets) do
      MarkLocked(FTargets[i], k, seq);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.SignalWindow(const AWindowId,
  ATopic: RawUtf8): Boolean;
var
  k: Integer;
  t: TPWebSignalTarget;
begin
  Result := False;
  FLock.Enter;
  try
    if FDraining then
      exit;
    k := TopicIndexLocked(ATopic);
    if (k < 0) or
       not FTopics[k].WindowScoped then
      exit;
    Inc(FSignals);
    Result := True;
    // a window that never subscribed has no sequence to move: its SDK reads
    // everything when it subscribes, which is the documented recovery
    t := TargetLocked(AWindowId);
    if t = nil then
      exit;
    Inc(t.WindowSeq[k]);
    MarkLocked(t, k, t.WindowSeq[k]);
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.PaceStep: Integer;
var
  work: array of RawUtf8;
  i, n: Integer;
  nowUs, due, tickUs, waitMs: Int64;
  ok: Boolean;
  t: TPWebSignalTarget;
  dispatchFn: TPWebSignalDispatchFn;
begin
  Result := PACER_IDLE_MS;
  tickUs := 1000000 div FBounds.TicksPerSecond;
  work := nil;
  n := 0;
  FLock.Enter;
  try
    dispatchFn := FView.Dispatch;
    if FDraining or
       not FViewAttached or
       not Assigned(dispatchFn) then
      exit;
    QueryPerformanceMicroSeconds(nowUs);
    for i := 0 to High(FTargets) do
    begin
      t := FTargets[i];
      if (t.PendingCount = 0) or
         t.Outstanding or
         t.Stalled then
        continue;
      due := t.LastDrainUs + tickUs;
      if (t.LastDrainUs = 0) or
         (nowUs >= due) then
      begin
        // ONE dispatch outstanding per window, until its drain runs
        t.Outstanding := True;
        SetLength(work, n + 1);
        work[n] := t.WindowId;
        Inc(n);
      end
      else
      begin
        // rounded UP: a wait of zero would be a spin
        waitMs := (due - nowUs + 999) div 1000;
        if waitMs < Result then
          Result := waitMs;
      end;
    end;
  finally
    FLock.Leave;
  end;
  for i := 0 to n - 1 do
  begin
    try
      ok := dispatchFn(work[i]);
    except
      ok := False;
    end;
    FLock.Enter;
    try
      if ok then
        Inc(FDispatches)
      else
      begin
        // no view to ask: nothing is retried until something changes, and
        // the refusal takes the tick, so a flood against a view that is
        // gone asks at most R times a second rather than once per signal
        t := TargetLocked(work[i]);
        if t <> nil then
        begin
          t.Outstanding := False;
          t.Stalled := True;
          QueryPerformanceMicroSeconds(t.LastDrainUs);
        end;
      end;
    finally
      FLock.Leave;
    end;
  end;
  if n > 0 then
    Result := 0; // look again at once: another window may be due
end;

procedure TPWebSignalChannel.Drain(const AWindowId: RawUtf8);
var
  t: TPWebSignalTarget;
  pairs: TPWebSignalPairs;
  k, n: Integer;
  script: RawUtf8;
begin
  FLock.Enter;
  try
    t := TargetLocked(AWindowId);
    if t = nil then
      exit;
    t.Outstanding := False;
    QueryPerformanceMicroSeconds(t.LastDrainUs);
    if FDraining or
       (t.PendingCount = 0) or
       not Assigned(FView.Eval) then
      exit;
    SetLength(pairs, t.PendingCount);
    n := 0;
    // declaration order, so one state has one script
    for k := 0 to High(t.Pending) do
      if t.Pending[k] and
         t.Subscribed[k] then
      begin
        pairs[n].Topic := FTopics[k].Name;
        pairs[n].Seq := t.PendingSeq[k];
        Inc(n);
      end;
    SetLength(pairs, n);
    for k := 0 to High(t.Pending) do
      t.Pending[k] := False;
    t.PendingCount := 0;
    if n = 0 then
      exit;
    script := PWebSignalScript(pairs);
    Inc(t.Evals);
    Inc(FEvals);
    t.LastScript := script;
    // UNDER THE LOCK, deliberately: a revocation or a document replacement
    // waits for this call, so nothing it removed can be evaluated after it
    // returns. The seam is the host's webview_eval, which queues the script
    // and returns
    FView.Eval(AWindowId, script);
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.Subscribe(const Context: TInvocationContext;
  const Args: TPWebJson): TPWebInvocationResult;
var
  topic: RawUtf8;
  k: Integer;
  caps: TPWebCapabilities;
  t: TPWebSignalTarget;
  seq: Int64;
begin
  if not DecodeTopicArg(Args, topic) then
    exit(PWebErrorResult(pecInvalidRequest,
      'arguments must be exactly {"topic": <string>}'));
  if not PWebSignalValidTopic(topic) then
    exit(PWebErrorResult(pecInvalidRequest, 'topic is not a valid topic'));
  // a subscription belongs to a WINDOW principal: nothing else has a page
  if (Context.PrincipalKind <> pkWindow) or
     (Context.WindowId = '') or
     (Context.PrincipalId = '') or
     not Context.TrustedContent then
    exit(Refused);
  FLock.Enter;
  try
    if FDraining then
      exit(PWebDefaultErrorResult(pecRuntimeClosed));
    k := TopicIndexLocked(topic);
    if (k < 0) or
       (FPolicy = nil) then
      exit(Refused);
    // THE POLICY ANSWERS, now, under this lock - so a revocation that lands
    // after this read finds the subscription and removes it
    caps := FPolicy.SnapshotCapabilities(Context.PrincipalId,
      Context.WindowId);
    if not PWebCapabilityIn(caps, Utf8String(FTopics[k].Capability)) then
      exit(Refused);
    t := TargetLocked(RawUtf8(Context.WindowId));
    if t = nil then
    begin
      if Length(FTargets) >= FBounds.MaxWindows then
        exit(LimitError('windows', FBounds.MaxWindows));
      t := NewTargetLocked(RawUtf8(Context.WindowId),
        RawUtf8(Context.PrincipalId));
    end
    else if t.PrincipalId <> RawUtf8(Context.PrincipalId) then
      exit(Refused);
    if not t.Subscribed[k] then
    begin
      if t.SubscriptionCount >= FBounds.MaxSubscriptions then
        exit(LimitError('subscriptions', FBounds.MaxSubscriptions));
      t.Subscribed[k] := True;
      Inc(t.SubscriptionCount);
    end;
    if FTopics[k].WindowScoped then
      seq := t.WindowSeq[k]
    else
      seq := FTopics[k].Seq;
  finally
    FLock.Leave;
  end;
  Result := PWebSuccessResult(TPWebJson('{"topic":' +
    PWebSignalJsonString(topic) + ',"seq":' + RawUtf8(IntToStr(seq)) + '}'));
end;

function TPWebSignalChannel.Unsubscribe(const Context: TInvocationContext;
  const Args: TPWebJson): TPWebInvocationResult;
var
  topic: RawUtf8;
  k: Integer;
  t: TPWebSignalTarget;
begin
  if not DecodeTopicArg(Args, topic) then
    exit(PWebErrorResult(pecInvalidRequest,
      'arguments must be exactly {"topic": <string>}'));
  if not PWebSignalValidTopic(topic) then
    exit(PWebErrorResult(pecInvalidRequest, 'topic is not a valid topic'));
  // REMOVING IS ALWAYS SAFE and IDEMPOTENT: no capability, and the same
  // answer for a topic nobody subscribed to
  FLock.Enter;
  try
    k := TopicIndexLocked(topic);
    t := TargetLocked(RawUtf8(Context.WindowId));
    if (k >= 0) and
       (t <> nil) and
       (t.PrincipalId = RawUtf8(Context.PrincipalId)) then
      DropLocked(t, k);
  finally
    FLock.Leave;
  end;
  Result := PWebSuccessResult('{}');
end;

function TPWebSignalChannel.Handshake(const Context: TInvocationContext;
  const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  value: RawUtf8;
  i: PtrInt;
begin
  Result := FInner.Invoke(Context, PWEB_METHOD_HANDSHAKE, Args, Token);
  if Result.Kind <> prkSuccess then
    exit;
  // ADDITIVE: the one member this channel adds, before the closing brace of
  // the object the runtime answered. Protocol v1 is unchanged
  value := RawUtf8(Result.Value);
  i := Length(value);
  while (i > 0) and
        (value[i] <= ' ') do
    Dec(i);
  if (i < 2) or
     (value[i] <> '}') then
    exit;
  if value[1] <> '{' then
    exit;
  SetLength(value, i - 1);
  if Trim(Copy(value, 2, MaxInt)) <> '' then
    value := value + ',';
  Result.Value := TPWebJson(value + '"features":["' + PWEB_SIGNAL_FEATURE +
    '"]}');
end;

function TPWebSignalChannel.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  // exact, case-sensitive matches on the canonical method
  if Method = PWEB_METHOD_SIGNAL_SUBSCRIBE then
    Result := Subscribe(Context, Args)
  else if Method = PWEB_METHOD_SIGNAL_UNSUBSCRIBE then
    Result := Unsubscribe(Context, Args)
  else if Method = PWEB_METHOD_HANDSHAKE then
    Result := Handshake(Context, Args, Token)
  else
    Result := FInner.Invoke(Context, Method, Args, Token);
end;

procedure TPWebSignalChannel.GrantsChanged(const APrincipalId: Utf8String);
var
  i, k: Integer;
  t: TPWebSignalTarget;
  caps: TPWebCapabilities;
  door: TPWebGrantsChangedEvent;
begin
  FLock.Enter;
  try
    door := nil;
    if FDoorAttached then
      door := FDoor.GrantsChanged;
    if FPolicy <> nil then
      for i := 0 to High(FTargets) do
      begin
        t := FTargets[i];
        if (t.PrincipalId <> RawUtf8(APrincipalId)) or
           (t.SubscriptionCount = 0) then
          continue;
        // THE POLICY answers what survived; this channel only acts on it
        caps := FPolicy.SnapshotCapabilities(APrincipalId,
          Utf8String(t.WindowId));
        for k := 0 to High(FTopics) do
          if t.Subscribed[k] and
             not PWebCapabilityIn(caps, Utf8String(FTopics[k].Capability)) then
            DropLocked(t, k);
      end;
  finally
    FLock.Leave;
  end;
  // the door AFTER this channel's own work, and outside its lock
  if Assigned(door) then
    door(APrincipalId);
end;

procedure TPWebSignalChannel.DocumentReplacing(const AWindowId: RawUtf8);
var
  t: TPWebSignalTarget;
  k: Integer;
  door: TPWebSignalDocumentProc;
begin
  FLock.Enter;
  try
    door := nil;
    if FDoorAttached then
      door := FDoor.DocumentReplacing;
    t := TargetLocked(AWindowId);
    if t <> nil then
      for k := 0 to High(FTopics) do
        DropLocked(t, k);
  finally
    FLock.Leave;
  end;
  if Assigned(door) then
    door(AWindowId);
end;

procedure TPWebSignalChannel.BeforeDrain;
var
  i, k: Integer;
  door: TPWebSignalNotifyProc;
  policy: TPWebCapabilityPolicy;
begin
  FLock.Enter;
  try
    FDraining := True;
    door := nil;
    if FDoorAttached then
      door := FDoor.BeforeDrain;
    policy := FPolicy;
    for i := 0 to High(FTargets) do
      for k := 0 to High(FTopics) do
        DropLocked(FTargets[i], k);
  finally
    FLock.Leave;
  end;
  // the grants slot is given back, and only if it is still ours
  if (policy <> nil) and
     (TMethod(policy.OnGrantsChanged).Data = Pointer(Self)) then
    policy.OnGrantsChanged := nil;
  if FPacer <> nil then
  begin
    FPacer.Terminate;
    RTLEventSetEvent(FWake);
    FPacer.WaitFor;
    FreeAndNil(FPacer);
  end;
  if Assigned(door) then
    door();
end;

function TPWebSignalChannel.SnapshotCapabilities(const APrincipalId,
  AWindowId: Utf8String): TPWebCapabilities;
var
  policy: TPWebCapabilityPolicy;
begin
  FLock.Enter;
  try
    policy := FPolicy;
  finally
    FLock.Leave;
  end;
  if policy = nil then
    Result := nil // fail closed: no policy, no capability
  else
    Result := policy.SnapshotCapabilities(APrincipalId, AWindowId);
end;

function TPWebSignalChannel.EvalCount: Int64;
begin
  FLock.Enter;
  try
    Result := FEvals;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.DispatchCount: Int64;
begin
  FLock.Enter;
  try
    Result := FDispatches;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.SignalCount: Int64;
begin
  FLock.Enter;
  try
    Result := FSignals;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.WindowEvalCount(const AWindowId: RawUtf8): Int64;
var
  t: TPWebSignalTarget;
begin
  FLock.Enter;
  try
    t := TargetLocked(AWindowId);
    if t = nil then
      Result := 0
    else
      Result := t.Evals;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.WindowLastScript(
  const AWindowId: RawUtf8): RawUtf8;
var
  t: TPWebSignalTarget;
begin
  FLock.Enter;
  try
    t := TargetLocked(AWindowId);
    if t = nil then
      Result := ''
    else
      Result := t.LastScript;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.PendingCount(const AWindowId: RawUtf8): Integer;
var
  t: TPWebSignalTarget;
begin
  FLock.Enter;
  try
    t := TargetLocked(AWindowId);
    if t = nil then
      Result := 0
    else
      Result := t.PendingCount;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.SubscriptionCount(
  const AWindowId: RawUtf8): Integer;
var
  t: TPWebSignalTarget;
begin
  FLock.Enter;
  try
    t := TargetLocked(AWindowId);
    if t = nil then
      Result := 0
    else
      Result := t.SubscriptionCount;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.TopicCount: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FTopics);
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.TopicSeq(const ATopic: RawUtf8): Int64;
var
  k: Integer;
begin
  FLock.Enter;
  try
    k := TopicIndexLocked(ATopic);
    if k < 0 then
      Result := -1
    else
      Result := FTopics[k].Seq;
  finally
    FLock.Leave;
  end;
end;

function TPWebSignalChannel.Bounds: TPWebSignalBounds;
begin
  Result := FBounds;
end;

{ ---------------------------------------------------------------------------
  the running host's channel
  --------------------------------------------------------------------------- }

// NO REFERENCE is held here - the composition owns the channel, and the host
// installs it only for the length of its run. PWebSignal signals UNDER the
// global lock, so an uninstall that returned has no signal still running on
// the channel it removed. Lock order: this lock, then the channel's.
procedure PWebSignalInstall(AChannel: TPWebSignalChannel);
begin
  GlobalLock.Enter;
  try
    if (GlobalChannel <> nil) and
       (GlobalChannel <> AChannel) then
      raise EPWebSignal.Create('another signal channel is installed');
    GlobalChannel := AChannel;
  finally
    GlobalLock.Leave;
  end;
end;

procedure PWebSignalUninstall(AChannel: TPWebSignalChannel);
begin
  GlobalLock.Enter;
  try
    if (AChannel <> nil) and
       (GlobalChannel = AChannel) then
      GlobalChannel := nil;
  finally
    GlobalLock.Leave;
  end;
end;

function PWebSignal(const ATopic: RawUtf8): Boolean;
begin
  GlobalLock.Enter;
  try
    Result := (GlobalChannel <> nil) and
              GlobalChannel.Signal(ATopic);
  finally
    GlobalLock.Leave;
  end;
end;

initialization
  GlobalLock := TCriticalSection.Create;

finalization
  GlobalChannel := nil;
  GlobalLock.Free;

end.
