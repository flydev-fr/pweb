{
  pweb.test.signal - the CAP-16 suite over the native signal channel, the
  socket door sitting on it, and the caller principal (mormot.core.test).

  HEADLESS, AND EVERY DECISION ASSERTED AS A NUMBER. The channel is driven
  through a FAKE VIEW - a dispatch that records who asked and an eval that
  records every script - so each refusal asserts how many scripts were
  issued rather than the absence of an observation. The engines are measured
  live by test/cap16/evalprobe.pas and test/cap16/signallive.pas.

    SCRIPT     the one template, the printable-ASCII encoder over every byte
               value, the hostile set and random UTF-8, round-tripped
               through a JSON parser
    CHANNEL    declaration, subscription and its capability, coalescing,
               pacing, the flood, revocation racing a flood, document
               replacement, two windows, the drain seam, the hooks, the
               handshake feature, the running host's PWebSignal
    SOCKET     the socket door on the channel: its topic, its window, the
               signal that replaced the long-poll, revocation and document
               replacement heard through the channel, and N quiet sockets
               leaving the real scheduler with nothing in flight
    CALLER     12-5: a real mORMot service returning a 2 MiB log as a blob
               owned by its caller, read back by that caller only

  It emits build/cap16/signal-corpus.txt, one LF line per decision, which
  the gates hash into signal_corpus_digest. A separate program from
  test/core/pwebtests.pas for 15B's reason: the CAP-8A corpus gains no row,
  so capability_policy_digest cannot move.
}

{$I mormot.defines.inc}

unit pweb.test.signal;

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.json,
  mormot.core.variants,
  mormot.core.interfaces,
  mormot.core.test,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.mormot,
  pweb.rpc.caller,
  pweb.rpc.signal,
  pweb.rpc.socket,
  pweb.blobs.intf,
  pweb.blobs.memory,
  pweb.blobs.protocol,
  pweb.capabilities.policy;

type
  TTestPWebSignalScript = class(TSynTestCase)
  published
    procedure TemplateShape;
    procedure EncoderIsPrintableAscii;
    procedure EncoderRoundTrips;
    procedure HostileTopics;
    procedure SequencesAreDecimal;
  end;

  TTestPWebSignalChannel = class(TSynTestCase)
  published
    procedure DeclarationRules;
    procedure SubscribeContract;
    procedure Coalescing;
    procedure PacingAndIsolatedLatency;
    procedure FloodIsBounded;
    procedure RevocationRacesAFlood;
    procedure DocumentReplacementDropsSubscriptions;
    procedure TwoWindowsAreIsolated;
    procedure BeforeDrainStopsEverything;
    procedure DoorIsCalledOutsideTheLock;
    procedure StalledViewDoesNotSpin;
    procedure HandshakeAdvertisesTheFeature;
    procedure RunningHostSignal;
  end;

  TTestPWebSignalSocket = class(TSynTestCase)
  published
    procedure DoorSitsOnTheChannel;
    procedure QueuedEventSignalsItsWindow;
    procedure RevocationAndReplacementThroughTheChannel;
    procedure QuietSocketsParkNothing;
  end;

  TTestPWebCallerPrincipal = class(TSynTestCase)
  published
    procedure ServiceBlobBelongsToTheCaller;
    procedure NoCallerNoBlob;
  end;

const
  /// the file the gates hash into signal_corpus_digest
  PWEB_CAP16_CORPUS_FILE = 'build/cap16/signal-corpus.txt';

implementation

var
  Corpus: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

{ ---------------------------------------------------------------------------
  the fake view: a dispatch that records, an eval that records
  --------------------------------------------------------------------------- }

var
  ViewLock: TRTLCriticalSection;
  ViewDispatches: LongInt;
  ViewUp: Boolean = True;
  ViewWindows: TRawUtf8DynArray; // one per dispatch, in order
  ViewScripts: TRawUtf8DynArray; // 'window|script', in order
  ViewEvals: LongInt;

procedure ViewReset;
begin
  EnterCriticalSection(ViewLock);
  try
    ViewDispatches := 0;
    ViewEvals := 0;
    ViewUp := True;
    ViewWindows := nil;
    ViewScripts := nil;
  finally
    LeaveCriticalSection(ViewLock);
  end;
end;

function FakeDispatch(const Window: RawUtf8): Boolean;
begin
  EnterCriticalSection(ViewLock);
  try
    Result := ViewUp;
    if not Result then
      exit;
    Inc(ViewDispatches);
    SetLength(ViewWindows, Length(ViewWindows) + 1);
    ViewWindows[High(ViewWindows)] := Window;
  finally
    LeaveCriticalSection(ViewLock);
  end;
end;

procedure FakeEval(const Window: RawUtf8; const Script: RawUtf8);
begin
  EnterCriticalSection(ViewLock);
  try
    Inc(ViewEvals);
    SetLength(ViewScripts, Length(ViewScripts) + 1);
    ViewScripts[High(ViewScripts)] := Window + '|' + Script;
  finally
    LeaveCriticalSection(ViewLock);
  end;
end;

function FakeView: TPWebSignalView;
begin
  Result.Dispatch := @FakeDispatch;
  Result.Eval := @FakeEval;
end;

function Dispatched: Integer;
begin
  EnterCriticalSection(ViewLock);
  try
    Result := ViewDispatches;
  finally
    LeaveCriticalSection(ViewLock);
  end;
end;

function Evals: Integer;
begin
  EnterCriticalSection(ViewLock);
  try
    Result := ViewEvals;
  finally
    LeaveCriticalSection(ViewLock);
  end;
end;

function ScriptAt(Index: Integer): RawUtf8;
begin
  EnterCriticalSection(ViewLock);
  try
    if (Index < 0) or (Index > High(ViewScripts)) then
      Result := ''
    else
      Result := ViewScripts[Index];
  finally
    LeaveCriticalSection(ViewLock);
  end;
end;

{ the GUI thread, played by the test: drain every window a dispatch named }
function PumpDrains(Channel: TPWebSignalChannel; var Seen: Integer): Integer;
var
  windows: TRawUtf8DynArray;
  i: Integer;
begin
  EnterCriticalSection(ViewLock);
  try
    windows := Copy(ViewWindows, Seen, MaxInt);
    Seen := Length(ViewWindows);
  finally
    LeaveCriticalSection(ViewLock);
  end;
  for i := 0 to High(windows) do
    Channel.Drain(windows[i]);
  Result := Length(windows);
end;

function WaitDispatches(Expected: Integer; Ms: Integer): Boolean;
var
  t: Int64;
begin
  t := GetTickCount64 + Ms;
  repeat
    if Dispatched >= Expected then
      exit(True);
    Sleep(1);
  until GetTickCount64 > t;
  Result := Dispatched >= Expected;
end;

{ ---------------------------------------------------------------------------
  invocation helpers
  --------------------------------------------------------------------------- }

type
  TInner = class(TInterfacedObject, IInvocationBridge)
  public
    Calls: LongInt;
    Answer: RawUtf8;
    constructor Create;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

constructor TInner.Create;
begin
  inherited Create;
  Answer := '"inner"';
end;

function TInner.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  InterlockedIncrement(Calls);
  if Answer = 'error' then
    Result := PWebDefaultErrorResult(pecInternalError)
  else
    Result := PWebSuccessResult(TPWebJson(Answer));
end;

function Ctx(const Window: Utf8String = 'main'): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := Window;
  Result.PrincipalId := 'window:' + Window;
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
end;

function ErrorCodeOf(const R: TPWebInvocationResult): RawUtf8;
begin
  if R.Kind = prkSuccess then
    Result := 'success'
  else
    Result := RawUtf8(PWEB_ERROR_CODE_TEXT[R.Error.Code]);
end;

function Verdict(const R: TPWebInvocationResult): RawUtf8;
var
  v: variant;
begin
  Result := ErrorCodeOf(R);
  if (R.Kind = prkError) and
     (R.Error.Code = pecServiceError) then
  begin
    v := _JsonFast(RawUtf8(R.Error.Data));
    Result := Result + ':' + _Safe(v)^.U['category'];
  end;
end;

function Call(const B: IInvocationBridge; const Method: RawUtf8;
  const Args: RawUtf8; const C: TInvocationContext): TPWebInvocationResult;
begin
  Result := B.Invoke(C, Method, TPWebJson(Args), nil);
end;

function Sub(Ch: TPWebSignalChannel; const Topic: RawUtf8;
  const Window: Utf8String = 'main'): TPWebInvocationResult;
begin
  Result := Call(Ch, PWEB_METHOD_SIGNAL_SUBSCRIBE,
    '{"topic":' + QuotedStrJson(Topic) + '}', Ctx(Window));
end;

function SeqOf(const R: TPWebInvocationResult): Int64;
var
  v: variant;
begin
  Result := -1;
  if R.Kind <> prkSuccess then
    exit;
  v := _JsonFast(RawUtf8(R.Value));
  Result := _Safe(v)^.I['seq'];
end;

// the detail array of a recorded 'window|script' entry, parsed
function DetailOf(const Entry: RawUtf8; out Window: RawUtf8): variant;
var
  bar, open_, close_: PtrInt;
  script: RawUtf8;
begin
  bar := Pos('|', Entry);
  Window := Copy(Entry, 1, bar - 1);
  script := Copy(Entry, bar + 1, MaxInt);
  open_ := Pos('{detail:', script) + Length('{detail:');
  close_ := Length(script) - Length('}))');
  Result := _JsonFast(Copy(script, open_, close_ - open_ + 1));
end;

function Policy(const Caps: array of Utf8String;
  const WindowCaps: array of Utf8String): TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum(Caps);
    b.SetWindowCapabilities('main', WindowCaps);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_SUBSCRIBE);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_UNSUBSCRIBE);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

function StdPolicy: TPWebCapabilityPolicy;
begin
  Result := Policy(['signal.jobs', 'signal.logs', 'signal.pwnd',
    'network.socket'],
    ['signal.jobs', 'signal.logs', 'network.socket']);
end;

function NewChannel(const Topics: array of RawUtf8;
  const Bounds: TPWebSignalBounds): TPWebSignalChannel; overload;
begin
  Result := TPWebSignalChannel.Create(TInner.Create, Topics, Bounds);
end;

function NewChannel(const Topics: array of RawUtf8): TPWebSignalChannel; overload;
begin
  Result := NewChannel(Topics, PWebSignalDefaultBounds);
end;

function Raises(Proc: TThreadMethod): Boolean;
begin
  try
    Proc;
    Result := False;
  except
    on EPWebSignal do
      Result := True;
  end;
end;

{ ---------------------------------------------------------------------------
  SCRIPT
  --------------------------------------------------------------------------- }

function Pairs1(const Topic: RawUtf8; Seq: Int64): TPWebSignalPairs;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Topic := Topic;
  Result[0].Seq := Seq;
end;

procedure TTestPWebSignalScript.TemplateShape;
var
  p: TPWebSignalPairs;
begin
  CheckEqual(PWEB_SIGNAL_EVAL_TEMPLATE,
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:%}))');
  CheckEqual(PosEx('%', PWEB_SIGNAL_EVAL_TEMPLATE,
    Pos('%', PWEB_SIGNAL_EVAL_TEMPLATE) + 1), 0, 'the template has two placeholders');
  Check(Pos('"' + PWEB_SIGNAL_EVENT + '"', PWEB_SIGNAL_EVAL_TEMPLATE) > 0,
    'the template does not dispatch PWEB_SIGNAL_EVENT');
  p := nil;
  CheckEqual(PWebSignalScript(p),
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[]}))');
  CheckEqual(PWebSignalScript(Pairs1('jobs', 7)),
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[["jobs",7]]}))');
  SetLength(p, 2);
  p[0].Topic := 'a';
  p[0].Seq := 1;
  p[1].Topic := 'b.c';
  p[1].Seq := 22;
  CheckEqual(PWebSignalScript(p),
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[["a",1],["b.c",22]]}))');
  Record_('script|template|one-literal|one-placeholder|event=' + PWEB_SIGNAL_EVENT);
end;

function PrintableAscii(const S: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  for i := 1 to Length(S) do
    if (S[i] < ' ') or (S[i] > '~') then
      exit;
  Result := True;
end;

// the encoder's own contract, byte by byte: only the delimiting quotes are
// quotes, and a backslash only ever starts an escape
function WellFormedLiteral(const S: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if (Length(S) < 2) or (S[1] <> '"') or (S[Length(S)] <> '"') then
    exit;
  i := 2;
  while i < Length(S) do
  begin
    case S[i] of
      '"', '<', '>', '&', '''':
        exit;
      '\':
        begin
          if (i + 5 >= Length(S) + 0) and (i + 5 > Length(S) - 1) then
            exit;
          if S[i + 1] <> 'u' then
            exit;
          Inc(i, 6);
          continue;
        end;
    end;
    Inc(i);
  end;
  Result := PrintableAscii(S);
end;

// what a JSON parser makes of the literal
function Decoded(const Literal: RawUtf8): RawUtf8;
var
  v: variant;
begin
  v := _JsonFast('[' + Literal + ']');
  Result := VariantToUtf8(_Safe(v)^.Values[0]);
end;

procedure TTestPWebSignalScript.EncoderIsPrintableAscii;
var
  b: Integer;
  s, lit: RawUtf8;
  bad: Integer;
begin
  bad := 0;
  for b := 0 to 255 do
  begin
    s := AnsiChar(b);
    lit := PWebSignalJsonString(s);
    if not WellFormedLiteral(lit) then
      Inc(bad);
    // every byte a string literal could be broken by is ESCAPED
    if (b < 32) or (b >= 127) or (AnsiChar(b) in ['"', '\', '<', '>', '&', '''']) then
      if Pos(#92'u', lit) <> 2 then
        Inc(bad);
  end;
  CheckEqual(bad, 0, 'a single byte broke the printable-ASCII literal');
  CheckEqual(PWebSignalJsonString(#$E2#$80#$A8), '"' + #92'u2028"');
  CheckEqual(PWebSignalJsonString(#$E2#$80#$A9), '"' + #92'u2029"');
  CheckEqual(PWebSignalJsonString(#$F0#$9F#$98#$80), '"' + #92'ud83d' + #92'ude00"');
  CheckEqual(PWebSignalJsonString(#$C3#$28), '"' + #92'ufffd(' + '"');
  CheckEqual(PWebSignalJsonString(#$ED#$A0#$80'x'),
    '"' + #92'ufffd' + #92'ufffd' + #92'ufffdx"');
  CheckEqual(PWebSignalJsonString('a.b9'), '"a.b9"');
  Record_('script|encoder|256-single-bytes|printable-ascii|u2028-u2029-escaped|invalid-utf8-replaced');
end;

procedure TTestPWebSignalScript.EncoderRoundTrips;
var
  i, n, k: Integer;
  s: RawUtf8;
  cp: Cardinal;
  w: WideString;
  mismatches: Integer;
begin
  mismatches := 0;
  RandSeed := 16;
  for i := 1 to 2000 do
  begin
    // random VALID UTF-8, across every plane
    w := '';
    n := 1 + Random(12);
    for k := 1 to n do
    begin
      case Random(4) of
        // U+0000 is left out HERE only: mORMot's parser decodes an escaped
        // NUL as '?' (see pweb.rpc.socket's HasEscapedNul), which is the
        // test's decoder failing, not the encoder - HostileTopics and
        // EncoderIsPrintableAscii cover the NUL
        0: cp := 1 + Random($7F);
        1: cp := $80 + Random($800 - $80);
        2: begin
             cp := $800 + Random($10000 - $800);
             if (cp >= $D800) and (cp <= $DFFF) then
               cp := $2028;
           end;
      else
        cp := $10000 + Random($100000);
      end;
      if cp >= $10000 then
      begin
        w := w + WideChar($D800 + ((cp - $10000) shr 10)) +
          WideChar($DC00 + ((cp - $10000) and $3FF));
      end
      else
        w := w + WideChar(cp);
    end;
    s := WideStringToUtf8(w);
    if not WellFormedLiteral(PWebSignalJsonString(s)) then
      Inc(mismatches)
    else if Decoded(PWebSignalJsonString(s)) <> s then
      Inc(mismatches);
  end;
  CheckEqual(mismatches, 0, 'a valid UTF-8 string did not round-trip exactly');
  Record_('script|encoder|2000-random-utf8|round-trip-exact');
end;

procedure TTestPWebSignalScript.HostileTopics;
const
  HOSTILE: array[0 .. 9] of RawUtf8 = (
    '"', '\', '</script><script>x=1</script>', '"]);x=1;//', #10,
    '${x=1}', '<!--', '-->', '`);x=1;`', #13#10);
var
  i: Integer;
  script, detail: RawUtf8;
  v: variant;
begin
  for i := 0 to High(HOSTILE) do
  begin
    script := PWebSignalScript(Pairs1(HOSTILE[i], i));
    Check(PrintableAscii(script), 'a hostile topic put a non-printable byte in the script');
    CheckEqual(Copy(script, 1, Length('window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[[')),
      'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[[');
    Check(Pos('</', script) = 0, 'a closing tag survived');
    Check(Pos('<!', script) = 0, 'a comment opener survived');
    // exactly the template's structure around exactly one encoded string
    detail := Copy(script, Length('window.dispatchEvent(new CustomEvent("pweb:signal",{detail:') + 1,
      MaxInt);
    SetLength(detail, Length(detail) - 3);
    v := _JsonFast(detail);
    CheckEqual(_Safe(v)^.Count, 1);
    CheckEqual(VariantToUtf8(_Safe(_Safe(v)^.Values[0])^.Values[0]), HOSTILE[i]);
    CheckEqual(_Safe(_Safe(v)^.Values[0])^.Values[1], i);
  end;
  // a NUL survives as an escape, so the C string the engine gets is whole
  script := PWebSignalScript(Pairs1(#0, 1));
  CheckEqual(StrLen(PAnsiChar(pointer(script))), Length(script),
    'a NUL topic truncated the script');
  Record_('script|hostile|10-cases-plus-nul|structure-intact|value-exact');
end;

procedure TTestPWebSignalScript.SequencesAreDecimal;
begin
  CheckEqual(PWebSignalScript(Pairs1('a', 0)),
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[["a",0]]}))');
  CheckEqual(PWebSignalScript(Pairs1('a', High(Int64))),
    'window.dispatchEvent(new CustomEvent("pweb:signal",{detail:[["a",9223372036854775807]]}))');
  Record_('script|seq|decimal-integer');
end;

{ ---------------------------------------------------------------------------
  CHANNEL
  --------------------------------------------------------------------------- }

type
  { one composition-time call per method, so Raises can run it }
  TDeclare = class
  public
    Channel: TPWebSignalChannel;
    procedure BadGrammar;
    procedure Reserved;
    procedure Duplicate;
    procedure TooMany;
    procedure RuntimeOutsideReserve;
    procedure RuntimeTwice;
    procedure AfterView;
    procedure ViewWithoutEval;
    procedure SecondDoor;
    procedure TakenPolicySlot;
    procedure LongTopic;
  end;

  TFakeDoor = class
  public
    Channel: TPWebSignalChannel;
    Replaced, Granted, Drained, Gone: LongInt;
    LastWindow: RawUtf8;
    LastPrincipal: RawUtf8;
    /// did a probe thread get the channel's lock while this door ran
    LockFree: LongInt;
    SubsSeen: Integer;
    procedure OnReplacing(const WindowId: RawUtf8);
    procedure OnGrants(const APrincipalId: Utf8String);
    procedure OnDrain;
    procedure OnGone;
    function Door: TPWebSignalDoor;
    procedure ProbeLock;
  end;

  TLockProbe = class(TThread)
  protected
    procedure Execute; override;
  public
    Channel: TPWebSignalChannel;
    Got: LongInt;
  end;

procedure TLockProbe.Execute;
begin
  Channel.PendingCount('main'); // takes the channel lock
  InterlockedIncrement(Got);
end;

procedure TFakeDoor.ProbeLock;
var
  p: TLockProbe;
  t: Int64;
begin
  p := TLockProbe.Create(True);
  p.Channel := Channel;
  p.FreeOnTerminate := False;
  p.Start;
  t := GetTickCount64 + 2000;
  while (PWebAtomicRead(p.Got) = 0) and (GetTickCount64 < t) do
    Sleep(1);
  if PWebAtomicRead(p.Got) > 0 then
    InterlockedIncrement(LockFree);
  p.WaitFor;
  p.Free;
end;

procedure TFakeDoor.OnReplacing(const WindowId: RawUtf8);
begin
  InterlockedIncrement(Replaced);
  LastWindow := WindowId;
  SubsSeen := Channel.SubscriptionCount(WindowId);
  ProbeLock;
end;

procedure TFakeDoor.OnGrants(const APrincipalId: Utf8String);
begin
  InterlockedIncrement(Granted);
  LastPrincipal := RawUtf8(APrincipalId);
  SubsSeen := Channel.SubscriptionCount('main');
  ProbeLock;
end;

procedure TFakeDoor.OnDrain;
begin
  InterlockedIncrement(Drained);
  ProbeLock;
end;

procedure TFakeDoor.OnGone;
begin
  InterlockedIncrement(Gone);
end;

function TFakeDoor.Door: TPWebSignalDoor;
begin
  Result.DocumentReplacing := OnReplacing;
  Result.GrantsChanged := OnGrants;
  Result.BeforeDrain := OnDrain;
  Result.ChannelGone := OnGone;
end;

procedure TDeclare.BadGrammar;
begin
  NewChannel(['Jobs']).Free;
end;

procedure TDeclare.Reserved;
begin
  NewChannel(['pweb.jobs']).Free;
end;

procedure TDeclare.Duplicate;
begin
  NewChannel(['jobs', 'jobs']).Free;
end;

procedure TDeclare.TooMany;
var
  b: TPWebSignalBounds;
begin
  b := PWebSignalDefaultBounds;
  b.MaxTopics := 2;
  NewChannel(['a', 'b', 'c'], b).Free;
end;

procedure TDeclare.LongTopic;
begin
  NewChannel([RawUtf8(StringOfChar('a', PWEB_SIGNAL_MAX_TOPIC_BYTES + 1))]).Free;
end;

procedure TDeclare.RuntimeOutsideReserve;
begin
  Channel.DeclareWindowTopic('sockets', 'network.socket');
end;

procedure TDeclare.RuntimeTwice;
begin
  Channel.DeclareWindowTopic('pweb.test', 'network.socket');
end;

procedure TDeclare.AfterView;
begin
  Channel.DeclareWindowTopic('pweb.late', 'network.socket');
end;

procedure TDeclare.ViewWithoutEval;
var
  v: TPWebSignalView;
begin
  v := FakeView;
  v.Eval := nil;
  Channel.AttachView(v);
end;

procedure TDeclare.SecondDoor;
var
  d: TPWebSignalDoor;
begin
  d := Default(TPWebSignalDoor);
  Channel.AttachDoor(d);
end;

procedure TDeclare.TakenPolicySlot;
var
  p: TPWebCapabilityPolicy;
  keep: ICapabilityPolicy;
  other: TPWebSignalChannel;
  otherRef: IInvocationBridge;
begin
  p := StdPolicy;
  keep := p;
  other := NewChannel([]);
  otherRef := other;
  other.AttachPolicy(p);
  Channel.AttachPolicy(p);
end;

procedure TTestPWebSignalChannel.DeclarationRules;
var
  d: TDeclare;
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  door: TFakeDoor;
begin
  ViewReset;
  d := TDeclare.Create;
  door := TFakeDoor.Create;
  ch := NewChannel(['jobs', 'logs']);
  keep := ch;
  try
    d.Channel := ch;
    door.Channel := ch;
    Check(Raises(d.BadGrammar), 'an uppercase topic was declared');
    Check(Raises(d.LongTopic), 'a 65-byte topic was declared');
    Check(Raises(d.Reserved), 'an application declared a pweb. topic');
    Check(Raises(d.Duplicate), 'a topic was declared twice');
    Check(Raises(d.TooMany), 'the topic bound was not enforced');
    Check(Raises(d.RuntimeOutsideReserve), 'a runtime topic outside pweb. was declared');
    ch.DeclareWindowTopic('pweb.test', 'network.socket');
    Check(Raises(d.RuntimeTwice), 'a runtime topic was declared twice');
    CheckEqual(ch.TopicCount, 3);
    ch.AttachDoor(door.Door);
    Check(Raises(d.SecondDoor), 'a second door was attached');
    Check(Raises(d.TakenPolicySlot), 'a taken grants slot was overwritten');
    Check(Raises(d.ViewWithoutEval), 'a view without an eval was attached');
    ch.AttachView(FakeView);
    Check(Raises(d.AfterView), 'a topic was declared after the view attached');
    Record_('channel|declaration|grammar|64-bytes|reserved|duplicate|bound|runtime-prefix|frozen-at-view|one-door|one-grants-slot');
    ch.BeforeDrain;
  finally
    keep := nil;
    d.Free;
    door.Free;
  end;
end;

procedure TTestPWebSignalChannel.SubscribeContract;
var
  ch, ch2: TPWebSignalChannel;
  keep, keep2: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  c: TInvocationContext;
  bounds: TPWebSignalBounds;
  r: TPWebInvocationResult;

  procedure Invalid(const Args, Why: RawUtf8);
  begin
    CheckEqual(ErrorCodeOf(Call(ch, PWEB_METHOD_SIGNAL_SUBSCRIBE, Args, Ctx)),
      'invalid_request', Why);
  end;

begin
  ViewReset;
  ch := NewChannel(['jobs', 'logs', 'pwnd']);
  keep := ch;
  p := StdPolicy;
  pRef := p;
  try
    ch.AttachView(FakeView);
    // no policy: nothing can be read
    CheckEqual(ErrorCodeOf(Sub(ch, 'jobs')), 'forbidden');
    ch.AttachPolicy(p);
    r := Sub(ch, 'jobs');
    CheckEqual(ErrorCodeOf(r), 'success');
    CheckEqual(RawUtf8(r.Value), '{"topic":"jobs","seq":0}');
    CheckEqual(ch.SubscriptionCount('main'), 1);
    // idempotent
    CheckEqual(RawUtf8(Sub(ch, 'jobs').Value), '{"topic":"jobs","seq":0}');
    CheckEqual(ch.SubscriptionCount('main'), 1);
    Record_('subscribe|granted|topic+seq|idempotent');
    // the ceiling holds signal.pwnd, the window does not: forbidden, and
    // not one script
    CheckEqual(ErrorCodeOf(Sub(ch, 'pwnd')), 'forbidden');
    // undeclared: the same answer
    CheckEqual(ErrorCodeOf(Sub(ch, 'nope')), 'forbidden');
    ch.Signal('pwnd');
    ch.Signal('nope');
    Sleep(100);
    CheckEqual(Evals, 0, 'a script was issued for a topic nobody may read');
    CheckEqual(Dispatched, 0);
    Record_('subscribe|not-granted|forbidden|undeclared|forbidden|0-scripts');
    // not a trusted window principal
    c := Ctx;
    c.PrincipalKind := pkQuickJS;
    CheckEqual(ErrorCodeOf(Call(ch, PWEB_METHOD_SIGNAL_SUBSCRIBE, '{"topic":"jobs"}', c)),
      'forbidden');
    c := Ctx;
    c.TrustedContent := False;
    CheckEqual(ErrorCodeOf(Call(ch, PWEB_METHOD_SIGNAL_SUBSCRIBE, '{"topic":"jobs"}', c)),
      'forbidden');
    c := Ctx;
    c.PrincipalId := 'window:intruder';
    CheckEqual(ErrorCodeOf(Call(ch, PWEB_METHOD_SIGNAL_SUBSCRIBE, '{"topic":"jobs"}', c)),
      'forbidden', 'a second principal subscribed on another principal''s window');
    Record_('subscribe|quickjs|untrusted|foreign-principal-same-window|forbidden');
    // the argument shape
    Invalid('null', 'null');
    Invalid('{}', 'empty');
    Invalid('{"topic":5}', 'number');
    Invalid('{"topic":null}', 'json-null');
    Invalid('{"topic":["jobs"]}', 'array');
    Invalid('{"topic":"jobs","x":1}', 'extra-member');
    Invalid('{"topic":"jobs","topic":"logs"}', 'repeated');
    Invalid('{"topic":"Jobs"}', 'uppercase');
    Invalid('{"topic":"jobs."}', 'trailing-dot');
    Invalid('{"topic":"jo' + #92'u0000bs"}', 'escaped-nul');
    Record_('subscribe|arguments|null|empty|number|json-null|array|extra|repeated|grammar|invalid_request');
    // unsubscribe: always allowed, idempotent
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_SIGNAL_UNSUBSCRIBE, '{"topic":"jobs"}', Ctx).Value), '{}');
    CheckEqual(ch.SubscriptionCount('main'), 0);
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_SIGNAL_UNSUBSCRIBE, '{"topic":"jobs"}', Ctx).Value), '{}');
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_SIGNAL_UNSUBSCRIBE, '{"topic":"never"}', Ctx).Value), '{}');
    CheckEqual(ErrorCodeOf(Call(ch, PWEB_METHOD_SIGNAL_UNSUBSCRIBE, '{"topic":"Never"}', Ctx)),
      'invalid_request');
    Record_('unsubscribe|idempotent|undeclared-ok|grammar-refused');
    // the other methods pass through, untouched
    CheckEqual(RawUtf8(Call(ch, 'CalculatorService.Add', '{"a":1,"b":2}', Ctx).Value), '"inner"');
    Record_('channel|other-methods|pass-through');
    ch.BeforeDrain;
    CheckEqual(ErrorCodeOf(Sub(ch, 'logs')), 'runtime_closed');
    Record_('subscribe|after-drain|runtime_closed');
  finally
    keep := nil;
  end;
  // the bounds, refused BY NAME
  bounds := PWebSignalDefaultBounds;
  bounds.MaxSubscriptions := 1;
  bounds.MaxWindows := 1;
  ch2 := NewChannel(['jobs', 'logs'], bounds);
  keep2 := ch2;
  p := Policy(['signal.jobs', 'signal.logs'], ['signal.jobs', 'signal.logs']);
  pRef := p;
  try
    ch2.AttachPolicy(p);
    CheckEqual(ErrorCodeOf(Sub(ch2, 'jobs')), 'success');
    CheckEqual(Verdict(Sub(ch2, 'logs')), 'service_error:' + PWEB_SIGNAL_CAT_LIMIT);
    CheckEqual(Verdict(Sub(ch2, 'jobs', 'other')), 'service_error:' + PWEB_SIGNAL_CAT_LIMIT);
    Record_('subscribe|bounds|subscriptions|windows|service_error:signal_limit');
    ch2.BeforeDrain;
  finally
    keep2 := nil;
    pRef := nil;
  end;
end;

procedure TTestPWebSignalChannel.Coalescing;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  i, seen: Integer;
  w: RawUtf8;
  d: variant;
begin
  ViewReset;
  ch := NewChannel(['jobs', 'logs']);
  keep := ch;
  p := StdPolicy;
  pRef := p;
  try
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'logs');
    Sub(ch, 'jobs');
    // a thousand signals on one topic, nobody draining
    for i := 1 to 1000 do
      Check(ch.Signal('jobs'));
    ch.Signal('logs');
    CheckEqual(ch.PendingCount('main'), 2, 'the queue was not coalesced');
    Check(WaitDispatches(1, 2000), 'no drain was asked for');
    Sleep(150);
    CheckEqual(Dispatched, 1, 'more than one dispatch was outstanding');
    seen := 0;
    PumpDrains(ch, seen);
    CheckEqual(Evals, 1);
    d := DetailOf(ScriptAt(0), w);
    CheckEqual(w, 'main');
    // ONE pair per topic, the last sequence, in DECLARATION order
    CheckEqual(_Safe(d)^.Count, 2);
    CheckEqual(VariantToUtf8(_Safe(_Safe(d)^.Values[0])^.Values[0]), 'jobs');
    CheckEqual(_Safe(_Safe(d)^.Values[0])^.Values[1], 1000);
    CheckEqual(VariantToUtf8(_Safe(_Safe(d)^.Values[1])^.Values[0]), 'logs');
    CheckEqual(_Safe(_Safe(d)^.Values[1])^.Values[1], 1);
    CheckEqual(ch.PendingCount('main'), 0);
    CheckEqual(ch.TopicSeq('jobs'), 1000);
    // a subscriber learns the current sequence
    CheckEqual(SeqOf(Sub(ch, 'jobs', 'main')), 1000);
    Record_('coalescing|1000-signals|one-dispatch|one-script|one-pair-per-topic|last-seq|declaration-order');
    // a drain with nothing pending issues nothing
    ch.Drain('main');
    CheckEqual(Evals, 1);
    Record_('coalescing|empty-drain|no-script');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
  end;
end;

type
  TSignaller = class(TThread)
  protected
    procedure Execute; override;
  public
    Channel: TPWebSignalChannel;
    Topic: RawUtf8;
    PerSecond: Integer;
    DurationMs: Integer;
    Sent: LongInt;
    Stop: LongInt;
    /// scripts recorded by the fake view when the flood began and ended
    EvalsAtStart, EvalsAtEnd: Integer;
  end;

procedure TSignaller.Execute;
var
  start, now, due: Int64;
begin
  EvalsAtStart := Evals;
  QueryPerformanceMicroSeconds(start);
  repeat
    QueryPerformanceMicroSeconds(now);
    if now - start >= Int64(DurationMs) * 1000 then
      break;
    // PerSecond signals a second, evenly
    due := (Int64(Sent) * 1000000) div PerSecond;
    if now - start >= due then
    begin
      Channel.Signal(Topic);
      InterlockedIncrement(Sent);
    end
    else
      SleepHiRes(0);
  until PWebAtomicRead(Stop) <> 0;
  EvalsAtEnd := Evals;
end;

procedure TTestPWebSignalChannel.PacingAndIsolatedLatency;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  seen: Integer;
  t0, lat: Int64;
begin
  ViewReset;
  ch := NewChannel(['jobs']);
  keep := ch;
  p := StdPolicy;
  pRef := p;
  try
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'jobs');
    // an ISOLATED signal is dispatched at once, not at the next tick
    seen := 0;
    ch.Signal('jobs');
    t0 := GetTickCount64;
    Check(WaitDispatches(1, 2000));
    lat := GetTickCount64 - t0;
    Check(lat < PWEB_SIGNAL_TICK_MS, 'an isolated signal waited for a tick');
    PumpDrains(ch, seen);
    // the next one, right after a drain, waits for the tick
    ch.Signal('jobs');
    t0 := GetTickCount64;
    Check(WaitDispatches(2, 2000));
    lat := GetTickCount64 - t0;
    Check(lat >= PWEB_SIGNAL_TICK_MS - 15, 'a second drain inside one tick');
    PumpDrains(ch, seen);
    CheckEqual(Evals, 2);
    Record_('pacing|isolated-signal-dispatched-at-once|next-one-paced-by-the-tick');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
  end;
end;

procedure TTestPWebSignalChannel.FloodIsBounded;
const
  FLOOD_MS = 3000;
  RATE = 10000;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  th: TSignaller;
  seen, pending, maxPending: Integer;
  heapBefore, heapAfter: PtrUInt;
  perSecond: Double;
  t: Int64;
begin
  ViewReset;
  ch := NewChannel(['jobs', 'logs']);
  keep := ch;
  p := StdPolicy;
  pRef := p;
  try
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'jobs');
    Sub(ch, 'logs');
    heapBefore := GetFPCHeapStatus.CurrHeapUsed;
    th := TSignaller.Create(True);
    th.Channel := ch;
    th.Topic := 'jobs';
    th.PerSecond := RATE;
    th.DurationMs := FLOOD_MS;
    th.FreeOnTerminate := False;
    th.Start;
    seen := 0;
    maxPending := 0;
    t := GetTickCount64 + FLOOD_MS + 1000;
    // the GUI thread, draining as fast as it is asked
    while not th.Finished and (GetTickCount64 < t) do
    begin
      PumpDrains(ch, seen);
      pending := ch.PendingCount('main');
      if pending > maxPending then
        maxPending := pending;
      Sleep(1);
    end;
    th.WaitFor;
    Sleep(PWEB_SIGNAL_TICK_MS * 3);
    PumpDrains(ch, seen);
    heapAfter := GetFPCHeapStatus.CurrHeapUsed;
    perSecond := Evals / (FLOOD_MS / 1000);
    Check(th.Sent >= RATE * (FLOOD_MS div 1000) div 2,
      'the flood never reached half its rate - the proof is vacuous');
    Check(Evals <= PWEB_SIGNAL_TICKS_PER_SECOND * (FLOOD_MS div 1000) + 2,
      FormatUtf8('% scripts for % signals over % ms', [Evals, th.Sent, FLOOD_MS]));
    Check(Evals >= 2, 'the flood produced no script at all');
    // THE BOUND, over the flood's own half-open window: R a second
    Check(th.EvalsAtEnd - th.EvalsAtStart <= PWEB_SIGNAL_TICKS_PER_SECOND * (FLOOD_MS div 1000),
      FormatUtf8('% scripts while the flood ran for % ms',
      [th.EvalsAtEnd - th.EvalsAtStart, FLOOD_MS]));
    Check(maxPending <= 2, 'the pending queue grew past the subscriptions');
    Check(Abs(Int64(heapAfter) - Int64(heapBefore)) < 256 * 1024,
      FormatUtf8('heap moved by % bytes under the flood', [Int64(heapAfter) - Int64(heapBefore)]));
    // the LAST sequence arrived
    CheckEqual(ch.TopicSeq('jobs'), th.Sent);
    Check(Pos(',' + RawUtf8(IntToStr(th.Sent)) + ']', ScriptAt(Evals - 1)) > 0,
      'the last script did not carry the last sequence');
    AddConsole(FormatUtf8('flood: % signals, % scripts (%/s), pending <= %',
      [th.Sent, Evals, perSecond, maxPending]));
    th.Free;
    Record_('flood|10000-per-second-3s|scripts-during<=3R|pending<=subscriptions|heap-flat|last-seq-delivered');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
  end;
end;

procedure TTestPWebSignalChannel.RevocationRacesAFlood;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  th: TSignaller;
  seen, i, cut, leaked: Integer;
  t: Int64;
begin
  ViewReset;
  ch := NewChannel(['jobs', 'logs']);
  keep := ch;
  p := Policy(['signal.jobs', 'signal.logs'], ['signal.jobs', 'signal.logs']);
  pRef := p;
  try
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'jobs');
    Sub(ch, 'logs');
    th := TSignaller.Create(True);
    th.Channel := ch;
    th.Topic := 'jobs';
    th.PerSecond := 20000;
    th.DurationMs := 1500;
    th.FreeOnTerminate := False;
    th.Start;
    seen := 0;
    t := GetTickCount64 + 500;
    while GetTickCount64 < t do
    begin
      PumpDrains(ch, seen);
      Sleep(1);
    end;
    // THE REVOCATION, from this thread, while the GUI side keeps draining
    p.SetRuntimeGrants('window:main', ['signal.logs']);
    cut := Evals;
    CheckEqual(ch.SubscriptionCount('main'), 1, 'the revoked subscription survived the call');
    ch.Signal('logs');
    t := GetTickCount64 + 800;
    while GetTickCount64 < t do
    begin
      PumpDrains(ch, seen);
      Sleep(1);
    end;
    th.WaitFor;
    th.Free;
    PumpDrains(ch, seen);
    leaked := 0;
    for i := cut to Evals - 1 do
      if Pos('"jobs"', ScriptAt(i)) > 0 then
        Inc(leaked);
    CheckEqual(leaked, 0, 'a script carried a revoked topic after the revoking call returned');
    Check(Evals > cut, 'the surviving topic was not delivered after the revocation');
    Check(cut > 0, 'nothing was delivered before the revocation - the race is vacuous');
    // a grant restored does not restore a subscription
    p.ClearRuntimeGrants('window:main');
    ch.Signal('jobs');
    Sleep(150);
    PumpDrains(ch, seen);
    CheckEqual(ch.PendingCount('main'), 0);
    Record_('revoke|mid-flood|0-scripts-after-return|other-topic-kept|regrant-needs-resubscribe');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
  end;
end;

procedure TTestPWebSignalChannel.DocumentReplacementDropsSubscriptions;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  door: TFakeDoor;
  seen: Integer;
  other: TInvocationContext;
begin
  ViewReset;
  ch := NewChannel(['jobs']);
  keep := ch;
  p := Policy(['signal.jobs'], ['signal.jobs']);
  pRef := p;
  door := TFakeDoor.Create;
  try
    door.Channel := ch;
    ch.AttachDoor(door.Door);
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'jobs');
    Sub(ch, 'jobs', 'other');
    ch.Signal('jobs');
    CheckEqual(ch.PendingCount('main'), 1);
    ch.DocumentReplacing('main');
    CheckEqual(ch.SubscriptionCount('main'), 0);
    CheckEqual(ch.PendingCount('main'), 0);
    CheckEqual(ch.SubscriptionCount('other'), 1, 'another window lost its subscription');
    CheckEqual(door.Replaced, 1);
    CheckEqual(door.LastWindow, 'main');
    CheckEqual(door.SubsSeen, 0, 'the door was told before the channel dropped');
    Sleep(100);
    seen := 0;
    PumpDrains(ch, seen);
    Check(Pos('main|', ScriptAt(0)) = 0, 'a replaced document was sent a script');
    // the new document subscribes again and reads the current sequence
    CheckEqual(SeqOf(Sub(ch, 'jobs')), 1);
    // AND THE PRINCIPAL BINDING WENT WITH THE SUBSCRIPTIONS. A window whose
    // next document belongs to another principal is answered by the POLICY,
    // not refused for the life of the process by a name the channel kept
    ch.DocumentReplacing('main');
    CheckEqual(ch.SubscriptionCount('main'), 0);
    other := Ctx('main');
    other.PrincipalId := 'window:main-after-navigation';
    CheckEqual(SeqOf(Call(ch, PWEB_METHOD_SIGNAL_SUBSCRIBE,
      '{"topic":"jobs"}', other)), 1,
      'a replaced document could not rebind its window to another principal');
    // and while THAT one holds it, the first principal is refused again
    CheckEqual(ErrorCodeOf(Sub(ch, 'jobs')), 'forbidden',
      'two principals shared one window');
    Record_('document-replacing|subscriptions-and-queue-gone|other-window-kept|door-told-after|' +
      'principal-rebinds-on-the-next-document');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
    door.Free;
  end;
end;

procedure TTestPWebSignalChannel.TwoWindowsAreIsolated;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  seen, i: Integer;
  w, s: RawUtf8;
  mainJobs, mainLogs, otherJobs, otherLogs, mainWin, otherWin: Integer;
begin
  ViewReset;
  ch := NewChannel(['jobs', 'logs']);
  keep := ch;
  p := Policy(['signal.jobs', 'signal.logs', 'network.socket'], []);
  pRef := p;
  try
    ch.DeclareWindowTopic('pweb.test', 'network.socket');
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    // 'main' holds a window factor of NOTHING: it may subscribe to nothing
    CheckEqual(ErrorCodeOf(Sub(ch, 'jobs')), 'forbidden');
    Record_('isolation|window-factor-empty|forbidden');
    // 'a' and 'b' have no window factor: unrestricted inside the ceiling
    Sub(ch, 'jobs', 'a');
    Sub(ch, 'pweb.test', 'a');
    Sub(ch, 'logs', 'b');
    Sub(ch, 'pweb.test', 'b');
    ch.Signal('jobs');
    ch.Signal('logs');
    Check(ch.SignalWindow('a', 'pweb.test'));
    Check(not ch.Signal('pweb.test'), 'a window topic was signalled host-wide');
    Check(not ch.SignalWindow('a', 'jobs'), 'a host topic was signalled to one window');
    Check(WaitDispatches(2, 2000));
    Sleep(100);
    seen := 0;
    PumpDrains(ch, seen);
    mainJobs := 0;
    mainLogs := 0;
    otherJobs := 0;
    otherLogs := 0;
    mainWin := 0;
    otherWin := 0;
    for i := 0 to Evals - 1 do
    begin
      s := ScriptAt(i);
      w := Copy(s, 1, Pos('|', s) - 1);
      if w = 'a' then
      begin
        if Pos('"jobs"', s) > 0 then Inc(mainJobs);
        if Pos('"logs"', s) > 0 then Inc(mainLogs);
        if Pos('"pweb.test",1]', s) > 0 then Inc(mainWin);
      end
      else if w = 'b' then
      begin
        if Pos('"jobs"', s) > 0 then Inc(otherJobs);
        if Pos('"logs"', s) > 0 then Inc(otherLogs);
        if Pos('"pweb.test"', s) > 0 then Inc(otherWin);
      end;
    end;
    CheckEqual(mainJobs, 1);
    CheckEqual(mainLogs, 0, 'a window heard a topic it did not subscribe to');
    CheckEqual(otherLogs, 1);
    CheckEqual(otherJobs, 0, 'a window heard a topic it did not subscribe to');
    CheckEqual(mainWin, 1);
    CheckEqual(otherWin, 0, 'a window-scoped signal reached another window');
    // per-window sequences
    CheckEqual(SeqOf(Sub(ch, 'pweb.test', 'a')), 1);
    CheckEqual(SeqOf(Sub(ch, 'pweb.test', 'b')), 0);
    Record_('isolation|two-windows|own-topics-only|window-topic-one-window|per-window-seq');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
  end;
end;

procedure TTestPWebSignalChannel.BeforeDrainStopsEverything;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  door: TFakeDoor;
begin
  ViewReset;
  ch := NewChannel(['jobs']);
  keep := ch;
  p := Policy(['signal.jobs'], ['signal.jobs']);
  pRef := p;
  door := TFakeDoor.Create;
  try
    door.Channel := ch;
    ch.AttachDoor(door.Door);
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'jobs');
    ch.BeforeDrain;
    CheckEqual(door.Drained, 1);
    Check(not ch.Signal('jobs'), 'a signal was accepted after the drain');
    CheckEqual(ch.SubscriptionCount('main'), 0);
    Check(not Assigned(p.OnGrantsChanged), 'the grants slot was not given back');
    Sleep(100);
    CheckEqual(Dispatched, 0);
    Record_('before-drain|door-told|signals-refused|subscriptions-gone|grants-slot-returned|no-dispatch');
    // a drained channel that is released still tells its door it went: the
    // door holds an uncounted pointer to it and must forget it
    keep := nil;
    CheckEqual(door.Gone, 1, 'a released channel did not tell its door');
    Record_('before-drain|then-released|door-told-channel-gone');
  finally
    keep := nil;
    pRef := nil;
    door.Free;
  end;
end;

procedure TTestPWebSignalChannel.DoorIsCalledOutsideTheLock;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  door: TFakeDoor;
begin
  ViewReset;
  ch := NewChannel(['jobs']);
  keep := ch;
  p := Policy(['signal.jobs'], ['signal.jobs']);
  pRef := p;
  door := TFakeDoor.Create;
  try
    door.Channel := ch;
    ch.AttachDoor(door.Door);
    ch.AttachPolicy(p);
    Sub(ch, 'jobs');
    p.SetRuntimeGrants('window:main', []);
    CheckEqual(door.Granted, 1);
    CheckEqual(door.LastPrincipal, 'window:main');
    CheckEqual(door.SubsSeen, 0, 'the door was told before the channel dropped');
    ch.DocumentReplacing('main');
    ch.BeforeDrain;
    // every one of the three calls: ANOTHER thread took the channel lock
    // while the door was running, so the channel was not holding it
    CheckEqual(door.LockFree, 3, 'a door was called under the channel lock');
    Record_('hooks|grants-document-drain|door-called-after-and-outside-the-lock');
    keep := nil;
    CheckEqual(door.Gone, 1, 'the door was not told its channel went');
    Record_('hooks|channel-gone|door-told');
  finally
    keep := nil;
    pRef := nil;
    door.Free;
  end;
end;

procedure TTestPWebSignalChannel.StalledViewDoesNotSpin;
var
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
begin
  ViewReset;
  ch := NewChannel(['jobs']);
  keep := ch;
  p := Policy(['signal.jobs'], ['signal.jobs']);
  pRef := p;
  try
    ch.AttachPolicy(p);
    ch.AttachView(FakeView);
    Sub(ch, 'jobs');
    EnterCriticalSection(ViewLock);
    ViewUp := False;
    LeaveCriticalSection(ViewLock);
    ch.Signal('jobs');
    Sleep(300);
    CheckEqual(ch.DispatchCount, 0);
    CheckEqual(ch.PendingCount('main'), 1, 'a pair was lost when the view could not be asked');
    // the view is back: the next change is delivered with the last sequence
    EnterCriticalSection(ViewLock);
    ViewUp := True;
    LeaveCriticalSection(ViewLock);
    ch.Signal('jobs');
    Check(WaitDispatches(1, 2000));
    ch.Drain('main');
    Check(Pos('["jobs",2]', ScriptAt(0)) > 0);
    Record_('view|refused-dispatch|stalled-not-spinning|pair-kept|next-change-delivers');
    ch.DetachView;
    ch.Signal('jobs');
    Sleep(200);
    CheckEqual(Dispatched, 1, 'a detached view was asked for a drain');
    ch.Drain('main');
    CheckEqual(Evals, 1, 'a detached view was sent a script');
    Record_('view|detached|no-dispatch|no-script');
    ch.BeforeDrain;
  finally
    keep := nil;
    pRef := nil;
  end;
end;

procedure TTestPWebSignalChannel.HandshakeAdvertisesTheFeature;
var
  inner: TInner;
  ch: TPWebSignalChannel;
  keep: IInvocationBridge;
begin
  inner := TInner.Create;
  inner.Answer := '{"protocol":1,"runtime":"0.1.0","capabilities":["a"]}';
  ch := TPWebSignalChannel.Create(inner, []);
  keep := ch;
  try
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx).Value),
      '{"protocol":1,"runtime":"0.1.0","capabilities":["a"],"features":["signal"]}');
    inner.Answer := '{ }';
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx).Value),
      '{ "features":["signal"]}');
    inner.Answer := 'error';
    CheckEqual(ErrorCodeOf(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx)), 'internal_error');
    inner.Answer := '"not-an-object"';
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx).Value), '"not-an-object"');
    // ONE features MEMBER, EVER: an answer that already carries the name is
    // MERGED rather than given a second member, because a reader keeps
    // whichever it saw last
    inner.Answer := '{"protocol":1,"features":["console"]}';
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx).Value),
      '{"protocol":1,"features":["signal","console"]}');
    inner.Answer := '{"protocol":1,"features":[]}';
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx).Value),
      '{"protocol":1,"features":["signal"]}');
    inner.Answer := '{"protocol":1,"features":["signal"]}';
    CheckEqual(RawUtf8(Call(ch, PWEB_METHOD_HANDSHAKE, 'null', Ctx).Value),
      '{"protocol":1,"features":["signal"]}');
    Record_('handshake|features-signal-appended|merged-into-an-existing-array|never-twice|' +
      'error-and-non-object-untouched|protocol-unchanged');
    ch.BeforeDrain;
  finally
    keep := nil;
  end;
end;

procedure TTestPWebSignalChannel.RunningHostSignal;
var
  ch, other: TPWebSignalChannel;
  keep, otherRef: IInvocationBridge;
  raised: Boolean;
begin
  ch := NewChannel(['jobs']);
  keep := ch;
  other := NewChannel(['jobs']);
  otherRef := other;
  try
    Check(not PWebSignal('jobs'), 'PWebSignal reached a channel nobody installed');
    PWebSignalInstall(ch);
    Check(PWebSignal('jobs'));
    Check(not PWebSignal('nope'));
    CheckEqual(ch.TopicSeq('jobs'), 1);
    raised := False;
    try
      PWebSignalInstall(other);
    except
      on EPWebSignal do
        raised := True;
    end;
    Check(raised, 'a second channel was installed over the running one');
    PWebSignalUninstall(other);
    Check(PWebSignal('jobs'), 'uninstalling another channel removed the running one');
    PWebSignalUninstall(ch);
    Check(not PWebSignal('jobs'));
    // a channel that is released uninstalls itself
    PWebSignalInstall(other);
    otherRef := nil;
    Check(not PWebSignal('jobs'), 'a released channel was still reachable');
    Record_('pwebsignal|install|one-channel|uninstall|released-channel-unreachable');
  finally
    keep := nil;
    otherRef := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  SOCKET - the door on the channel, over a minimal injected transport
  --------------------------------------------------------------------------- }

type
  TMiniConn = class
  public
    Sink: TPWebSocketSink;
    Closes: Integer;
  end;

var
  MiniConns: array of TMiniConn;
  MiniLock: TRTLCriticalSection;

function MiniOpen(const Request: TPWebSocketRequest;
  const Sink: TPWebSocketSink; const Token: ICancellationToken;
  out Handle: Pointer; out Selected: RawUtf8): TPWebSocketOutcome;
var
  c: TMiniConn;
begin
  c := TMiniConn.Create;
  c.Sink := Sink;
  EnterCriticalSection(MiniLock);
  SetLength(MiniConns, Length(MiniConns) + 1);
  MiniConns[High(MiniConns)] := c;
  LeaveCriticalSection(MiniLock);
  Handle := c;
  Selected := '';
  Result := psoOk;
end;

function MiniSend(Handle: Pointer; Binary: Boolean;
  const Payload: RawByteString): TPWebSocketOutcome;
begin
  Result := psoOk;
end;

procedure MiniClose(Handle: Pointer; Code: Integer; const Reason: RawUtf8);
begin
  Inc(TMiniConn(Handle).Closes);
end;

procedure MiniRelease(Handle: Pointer);
begin
end;

function MiniTransport: TPWebSocketTransport;
begin
  Result.Open := MiniOpen;
  Result.Send := MiniSend;
  Result.Close := MiniClose;
  Result.Release := MiniRelease;
end;

procedure MiniReset;
var
  i: Integer;
begin
  EnterCriticalSection(MiniLock);
  try
    for i := 0 to High(MiniConns) do
      MiniConns[i].Free;
    MiniConns := nil;
  finally
    LeaveCriticalSection(MiniLock);
  end;
end;

function IdOf(const R: TPWebInvocationResult): RawUtf8;
var
  v: variant;
begin
  Result := '';
  if R.Kind <> prkSuccess then
    exit;
  v := _JsonFast(RawUtf8(R.Value));
  Result := _Safe(v)^.U['id'];
end;

function OpenSock(const B: IInvocationBridge;
  const Window: Utf8String = 'main'): RawUtf8;
begin
  Result := IdOf(Call(B, PWEB_METHOD_SOCKET_OPEN,
    '{"url":"wss://api.example.com/"}', Ctx(Window)));
end;

function RecvTypes(const B: IInvocationBridge; const Id: RawUtf8;
  const Window: Utf8String = 'main'): RawUtf8;
var
  r: TPWebInvocationResult;
  v: variant;
  list: PDocVariantData;
  i: Integer;
begin
  Result := '';
  r := Call(B, PWEB_METHOD_SOCKET_RECEIVE, '{"id":' + QuotedStrJson(Id) + '}',
    Ctx(Window));
  if r.Kind <> prkSuccess then
    exit(Verdict(r));
  v := _JsonFast(RawUtf8(r.Value));
  list := _Safe(v)^.A['events'];
  for i := 0 to list^.Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + _Safe(list^.Values[i])^.U['type'];
  end;
end;

type
  { the host's composition, headless: the channel over the door }
  TSocketRig = class
  public
    Door: TPWebSocketBridge;
    Channel: TPWebSignalChannel;
    Chain: IInvocationBridge;
    Policy: TPWebCapabilityPolicy;
    PolicyRef: ICapabilityPolicy;
    constructor Create(const Bounds: TPWebSocketBounds);
    destructor Destroy; override;
  end;

constructor TSocketRig.Create(const Bounds: TPWebSocketBounds);
var
  doorRef: IInvocationBridge;
begin
  MiniReset;
  Door := TPWebSocketBridge.Create(TInner.Create, MiniTransport,
    ['https://api.example.com'], Bounds);
  doorRef := Door;
  Channel := TPWebSignalChannel.Create(doorRef, ['jobs']);
  Chain := Channel;
  Door.AttachSignals(Channel);
  Policy := pweb.test.signal.Policy(['network.socket', 'signal.jobs'],
    ['network.socket', 'signal.jobs']);
  PolicyRef := Policy;
  Channel.AttachPolicy(Policy);
  Channel.AttachView(FakeView);
end;

destructor TSocketRig.Destroy;
begin
  Channel.BeforeDrain;
  Channel.DetachView;
  Chain := nil; // the channel goes, and takes the door with it
  PolicyRef := nil;
  inherited Destroy;
end;

procedure TTestPWebSignalSocket.DoorSitsOnTheChannel;
var
  rig: TSocketRig;
  raised: Boolean;
begin
  ViewReset;
  rig := TSocketRig.Create(PWebSocketDefaultBounds);
  try
    CheckEqual(rig.Channel.TopicCount, 2);
    CheckEqual(rig.Channel.TopicSeq(PWEB_SIGNAL_TOPIC_SOCKET), 0);
    Check(TMethod(rig.Policy.OnGrantsChanged).Data = Pointer(rig.Channel),
      'the channel does not own the grants slot');
    raised := False;
    try
      rig.Door.AttachSignals(rig.Channel);
    except
      on EPWebSocket do
        raised := True;
    end;
    Check(raised, 'a door sat on a channel twice');
    // the socket topic is read under network.socket, not signal.pweb.socket
    CheckEqual(ErrorCodeOf(Sub(rig.Channel, PWEB_SIGNAL_TOPIC_SOCKET)), 'success');
    rig.Policy.SetRuntimeGrants('window:main', ['signal.jobs']);
    CheckEqual(rig.Channel.SubscriptionCount('main'), 0);
    CheckEqual(ErrorCodeOf(Sub(rig.Channel, PWEB_SIGNAL_TOPIC_SOCKET)), 'forbidden');
    Record_('socket|door-on-channel|topic-pweb.socket|read-under-network.socket|once');
  finally
    rig.Free;
  end;
end;

procedure TTestPWebSignalSocket.QueuedEventSignalsItsWindow;
var
  rig: TSocketRig;
  mine, theirs: RawUtf8;
  seen: Integer;
begin
  ViewReset;
  rig := TSocketRig.Create(PWebSocketDefaultBounds);
  try
    mine := OpenSock(rig.Chain);
    theirs := OpenSock(rig.Chain, 'other');
    CheckEqual(RecvTypes(rig.Chain, mine), 'open');
    CheckEqual(RecvTypes(rig.Chain, theirs, 'other'), 'open');
    Sub(rig.Channel, PWEB_SIGNAL_TOPIC_SOCKET);
    Sub(rig.Channel, PWEB_SIGNAL_TOPIC_SOCKET, 'other');
    // quiet: nothing pending anywhere, and a receive answers empty at once
    CheckEqual(rig.Channel.PendingCount('main'), 0);
    CheckEqual(RecvTypes(rig.Chain, mine), '');
    // a message for MY socket signals MY window only
    MiniConns[0].Sink.Deliver(False, 'one');
    MiniConns[0].Sink.Deliver(False, 'two');
    CheckEqual(rig.Channel.PendingCount('main'), 1);
    CheckEqual(rig.Channel.PendingCount('other'), 0,
      'a socket event signalled another window');
    Check(WaitDispatches(1, 2000));
    seen := 0;
    PumpDrains(rig.Channel, seen);
    Check(Pos('main|', ScriptAt(0)) = 1);
    Check(Pos('["pweb.socket",2]', ScriptAt(0)) > 0, ScriptAt(0));
    // the page's side: the signal, then the receive
    CheckEqual(RecvTypes(rig.Chain, mine), 'message,message');
    Record_('socket|queued-event|signals-own-window-only|coalesced|receive-takes-all');
    // a native close is an event too, and it is signalled
    rig.Door.CloseForIdleNow(mine);
    CheckEqual(rig.Channel.PendingCount('main'), 1);
    CheckEqual(RecvTypes(rig.Chain, mine), 'close');
    Record_('socket|native-close|signalled');
  finally
    rig.Free;
  end;
end;

procedure TTestPWebSignalSocket.RevocationAndReplacementThroughTheChannel;
var
  rig: TSocketRig;
  a, b: RawUtf8;
  seqBefore: Int64;
begin
  ViewReset;
  rig := TSocketRig.Create(PWebSocketDefaultBounds);
  try
    rig.Policy.SetRuntimeGrants('window:main', ['network.socket', 'signal.jobs']);
    a := OpenSock(rig.Chain);
    Sub(rig.Channel, PWEB_SIGNAL_TOPIC_SOCKET);
    Sub(rig.Channel, 'jobs');
    CheckEqual(rig.Door.OpenCount, 1);
    // revoke network.socket: the socket AND its topic go before the call returns
    seqBefore := rig.Channel.TopicSeq(PWEB_SIGNAL_TOPIC_SOCKET);
    rig.Policy.SetRuntimeGrants('window:main', ['signal.jobs']);
    CheckEqual(rig.Door.OpenCount, 0, 'a revoked socket survived the revoking call');
    CheckEqual(rig.Channel.SubscriptionCount('main'), 1, 'the wrong subscription went');
    CheckEqual(Verdict(Call(rig.Chain, PWEB_METHOD_SOCKET_SEND,
      '{"id":' + QuotedStrJson(a) + ',"text":"x"}', Ctx)), 'service_error:socket_not_found');
    // AND NOTHING IS DELIVERED AFTERWARDS, which is the whole of the
    // revocation rule: the subscription went with the capability, so no
    // later pair for this topic can reach this window. The page's loop
    // therefore learns on its next keepalive receive, which answers
    // socket_not_found - the one latency the migration adds (ledger 16-10)
    CheckEqual(rig.Channel.PendingCount('main'), 0);
    CheckEqual(rig.Channel.TopicSeq(PWEB_SIGNAL_TOPIC_SOCKET), seqBefore,
      'a revoked window was still signalled');
    Record_('socket|revoke|socket-closed|topic-dropped|other-topic-kept|before-return|' +
      'nothing-delivered-after|page-learns-on-its-next-receive');
    // document replacement through the host's seam - the channel's
    rig.Policy.ClearRuntimeGrants('window:main');
    b := OpenSock(rig.Chain);
    CheckEqual(rig.Door.OpenCount, 1);
    rig.Channel.DocumentReplacing('main');
    CheckEqual(rig.Door.OpenCount, 0, 'a replaced document kept its socket');
    CheckEqual(rig.Channel.SubscriptionCount('main'), 0);
    Record_('socket|document-replacing|through-channel|socket-closed|subscriptions-gone');
  finally
    rig.Free;
  end;
end;

type
  TSink = class(TInterfacedObject, IInvocationCompletion)
  public
    Done: LongInt;
    AtUs: Int64;
    Res: TPWebInvocationResult;
    procedure Complete(const AResult: TPWebInvocationResult);
  end;

procedure TSink.Complete(const AResult: TPWebInvocationResult);
begin
  QueryPerformanceMicroSeconds(AtUs);
  Res := AResult;
  InterlockedExchange(Done, 1);
end;

// the host's policy for the scheduler proof: the socket door's four
// methods, the two signal methods and one unrelated application method
function SchedulerPolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum(['network.socket', 'signal.jobs']);
    b.MapMethod(PWEB_METHOD_SOCKET_OPEN, ['network.socket']);
    b.MapMethod(PWEB_METHOD_SOCKET_SEND, ['network.socket']);
    b.MapMethod(PWEB_METHOD_SOCKET_RECEIVE, ['network.socket']);
    b.MapMethod(PWEB_METHOD_SOCKET_CLOSE, ['network.socket']);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_SUBSCRIBE);
    b.RegisterZeroCapMethod(PWEB_METHOD_SIGNAL_UNSUBSCRIBE);
    b.RegisterZeroCapMethod('Test.Add');
    Result := b.Build;
  finally
    b.Free;
  end;
end;

procedure TTestPWebSignalSocket.QuietSocketsParkNothing;
var
  bounds: TPWebSocketBounds;
  door: TPWebSocketBridge;
  doorRef, chain: IInvocationBridge;
  channel: TPWebSignalChannel;
  policy: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  limits: TPWebSourceLimits;
  i, queued, active: Integer;
  ids: TRawUtf8DynArray;
  sink: TSink;
  sinkRef: IInvocationCompletion;
  c: TInvocationContext;
  t0: Int64;
  deadline: Int64;
  latencyUs: Int64;

  function Run(const Method, Args: RawUtf8): TPWebInvocationResult;
  var
    s: TSink;
    sRef: IInvocationCompletion;
    until_: Int64;
  begin
    s := TSink.Create;
    sRef := s;
    Result := PWebDefaultErrorResult(pecInternalError);
    if source.TryEnqueue(c, Method, TPWebJson(Args), sRef) <> perAccepted then
      exit;
    until_ := GetTickCount64 + 5000;
    while (PWebAtomicRead(s.Done) = 0) and (GetTickCount64 < until_) do
      Sleep(1);
    if PWebAtomicRead(s.Done) <> 0 then
      Result := s.Res;
  end;

begin
  ViewReset;
  MiniReset;
  bounds := PWebSocketDefaultBounds;
  bounds.MaxSockets := 8;
  door := TPWebSocketBridge.Create(TInner.Create, MiniTransport,
    ['https://api.example.com'], bounds);
  doorRef := door;
  channel := TPWebSignalChannel.Create(doorRef, ['jobs']);
  chain := channel;
  door.AttachSignals(channel);
  policy := SchedulerPolicy;
  policyRef := policy;
  channel.AttachPolicy(policy);
  channel.AttachView(FakeView);
  // THE HOST DEFAULTS: four workers, four slots, a queue of 32
  scheduler := TInvocationScheduler.Create(policyRef, chain, 4);
  schedulerRef := scheduler;
  try
    limits := Default(TPWebSourceLimits);
    limits.MaxConcurrent := 4;
    limits.MaxQueueSize := 32;
    source := scheduler.RegisterSource(limits);
    c := Ctx;
    c.Capabilities := policy.SnapshotCapabilities('window:main', 'main');
    ids := nil;
    for i := 1 to 8 do
    begin
      SetLength(ids, i);
      ids[i - 1] := IdOf(Run(PWEB_METHOD_SOCKET_OPEN,
        '{"url":"wss://api.example.com/"}'));
      Check(ids[i - 1] <> '', 'a socket did not open');
    end;
    CheckEqual(door.OpenCount, 8);
    for i := 0 to High(ids) do
      Check(Pos('"open"', RawUtf8(Run(PWEB_METHOD_SOCKET_RECEIVE,
        '{"id":' + QuotedStrJson(ids[i]) + '}').Value)) > 0);
    CheckEqual(ErrorCodeOf(Run(PWEB_METHOD_SIGNAL_SUBSCRIBE,
      '{"topic":"' + PWEB_SIGNAL_TOPIC_SOCKET + '"}')), 'success');
    // EIGHT QUIET SOCKETS, AND NOTHING IN FLIGHT
    deadline := GetTickCount64 + 2000;
    repeat
      if scheduler.TryGetSourceCounts(source, queued, active) and
         (queued + active = 0) then
        break;
      Sleep(1);
    until GetTickCount64 > deadline;
    CheckEqual(queued + active, 0, 'a quiet socket holds an invocation');
    // an unrelated invocation, timed from its enqueue
    sink := TSink.Create;
    sinkRef := sink;
    QueryPerformanceMicroSeconds(t0);
    CheckEqual(Ord(source.TryEnqueue(c, 'Test.Add', '{"a":20,"b":22}', sinkRef)),
      Ord(perAccepted));
    deadline := GetTickCount64 + 5000;
    while (PWebAtomicRead(sink.Done) = 0) and (GetTickCount64 < deadline) do
      Sleep(1);
    Check(PWebAtomicRead(sink.Done) <> 0, 'the unrelated invocation was never answered');
    latencyUs := sink.AtUs - t0;
    Check(latencyUs < 5000, FormatUtf8('an unrelated invoke took % us beside eight quiet sockets',
      [latencyUs]));
    AddConsole(FormatUtf8('eight quiet sockets: unrelated invoke in % us', [latencyUs]));
    Record_('socket|8-quiet-sockets|host-defaults-4-4-32|0-in-flight|unrelated-invoke-under-5ms');
    // the retired wait, through the scheduler, is refused
    CheckEqual(ErrorCodeOf(Run(PWEB_METHOD_SOCKET_RECEIVE,
      '{"id":' + QuotedStrJson(ids[0]) + ',"waitMs":25000}')), 'invalid_request');
    Record_('socket|waitMs-25000|invalid_request|through-the-scheduler');
  finally
    // the host's order: the channel's drain seam, then the pool
    channel.BeforeDrain;
    source := nil;
    schedulerRef.Shutdown;
    schedulerRef := nil;
    channel.DetachView;
    chain := nil;
    doorRef := nil;
    policyRef := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  CALLER - 12-5: a service that owns a blob FOR ITS CALLER
  --------------------------------------------------------------------------- }

const
  JOB_LOG_BYTES = 2 * 1024 * 1024;
  JOB_LOG_TYPE = 'text/plain; charset=utf-8';

type
  IJobs = interface(IInvokable)
    ['{6C2E8D41-9B3F-4A57-8E1D-2F0C7B5A9E36}']
    function Snapshot(since: Int64): RawJson;
    function Principal: RawUtf8;
    function FromThread: RawUtf8;
  end;

  TJobs = class(TInterfacedObject, IJobs)
  public
    function Snapshot(since: Int64): RawJson;
    function Principal: RawUtf8;
    function FromThread: RawUtf8;
  end;

  TPrincipalProbe = class(TThread)
  protected
    procedure Execute; override;
  public
    Seen: RawUtf8;
  end;

var
  JobsStore: IBlobStore;

function JobLog: RawByteString;
var
  line: RawUtf8;
  n: Integer;
begin
  // a deterministic log of EXACTLY two mebibytes, so every byte is checked
  Result := '';
  SetLength(Result, JOB_LOG_BYTES);
  n := 0;
  while n < JOB_LOG_BYTES do
  begin
    line := FormatUtf8('job 16 line % of a long-running native job'#10, [n]);
    if n + Length(line) > JOB_LOG_BYTES then
      SetLength(line, JOB_LOG_BYTES - n);
    Move(pointer(line)^, PByteArray(pointer(Result))[n], Length(line));
    Inc(n, Length(line));
  end;
end;

function TJobs.Snapshot(since: Int64): RawJson;
var
  handle: RawUtf8;
  ceiling: TPWebBlobCeiling;
begin
  if PWebCallerBlobPut(JobsStore, JobLog, JOB_LOG_TYPE, handle, ceiling) then
    Result := RawJson(handle)
  else
    Result := RawJson('{"refused":"' + PWebBlobCeilingCategory(ceiling) + '"}');
end;

function TJobs.Principal: RawUtf8;
begin
  if not PWebCallerPrincipal(Result) then
    Result := 'none';
end;

procedure TPrincipalProbe.Execute;
begin
  if not PWebCallerPrincipal(Seen) then
    Seen := 'none';
end;

function TJobs.FromThread: RawUtf8;
var
  p: TPrincipalProbe;
begin
  p := TPrincipalProbe.Create(True);
  try
    p.FreeOnTerminate := False;
    p.Start;
    p.WaitFor;
    Result := p.Seen;
  finally
    p.Free;
  end;
end;

function JobsBridge: IInvocationBridge;
var
  server: TRestServerFullMemory;
begin
  server := TRestServerFullMemory.CreateWithOwnModel([]);
  if server.ServiceRegister(TJobs, [TypeInfo(IJobs)], sicShared) = nil then
    raise Exception.Create('unable to register Jobs');
  Result := TMormotInvocationBridge.Create(server, True);
end;

procedure TTestPWebCallerPrincipal.ServiceBlobBelongsToTheCaller;
var
  bridge: IInvocationBridge;
  r: TPWebInvocationResult;
  v: variant;
  token, url, typ: RawUtf8;
  size: Int64;
  reader: IBlobReader;
  info: TBlobInfo;
  bytes, expected: RawByteString;
  limits: TPWebBlobLimits;
begin
  JobsStore := TPWebMemoryBlobStore.Create;
  bridge := JobsBridge;
  try
    r := bridge.Invoke(Ctx, 'Jobs.Snapshot', '{"since":0}', nil);
    CheckEqual(ErrorCodeOf(r), 'success');
    v := _JsonFast(RawUtf8(r.Value));
    token := _Safe(v)^.U['token'];
    url := _Safe(v)^.U['url'];
    size := _Safe(v)^.I['size'];
    typ := _Safe(v)^.U['type'];
    Check(PWebBlobValidToken(token), 'the handle carries no token');
    CheckEqual(url, PWebBlobUrl(token));
    CheckEqual(size, JOB_LOG_BYTES);
    CheckEqual(typ, JOB_LOG_TYPE);
    // THE CALLER reads it, byte for byte
    Check(JobsStore.OpenBlob('window:main', token, reader),
      'the caller cannot read the blob its service created');
    Check(reader.Info(info));
    CheckEqual(info.Size, JOB_LOG_BYTES);
    CheckEqual(info.Owner, 'window:main');
    CheckEqual(info.ContentType, JOB_LOG_TYPE);
    SetLength(bytes, JOB_LOG_BYTES);
    CheckEqual(reader.ReadAt(0, pointer(bytes), JOB_LOG_BYTES), JOB_LOG_BYTES);
    expected := JobLog;
    Check(bytes = expected, 'the blob is not the log the service wrote');
    reader := nil;
    Record_('caller|jobs-snapshot|2mib-log|blob-owned-by-caller|handle=token+url+size+type|bytes-exact');
    // ANOTHER principal: answered exactly as an unknown token is
    Check(not JobsStore.OpenBlob('window:other', token, reader),
      'another principal read the caller''s blob');
    Check(not JobsStore.OpenBlob('window:main', '0123456789abcdef0123456789abcdef', reader));
    Record_('caller|other-principal|same-answer-as-unknown');
    // the service sees the principal of EACH call, and only during it
    CheckEqual(RawUtf8(bridge.Invoke(Ctx('other'), 'Jobs.Principal', 'null', nil).Value),
      '"window:other"');
    CheckEqual(RawUtf8(bridge.Invoke(Ctx, 'Jobs.Principal', 'null', nil).Value),
      '"window:main"');
    CheckEqual(RawUtf8(bridge.Invoke(Ctx, 'Jobs.FromThread', 'null', nil).Value),
      '"none"', 'a thread the service started saw a caller');
    Check(not PWebCallerPrincipal(token), 'the caller outlived its call');
    Record_('caller|principal-per-call|none-on-a-service-thread|none-after-the-call');
  finally
    bridge := nil;
    JobsStore := nil;
  end;
  // a ceiling is answered BY NAME
  limits := PWebBlobDefaultLimits;
  limits.MaxBlobBytes := JOB_LOG_BYTES - 1;
  JobsStore := TPWebMemoryBlobStore.Create(limits);
  bridge := JobsBridge;
  try
    r := bridge.Invoke(Ctx, 'Jobs.Snapshot', '{"since":0}', nil);
    CheckEqual(RawUtf8(r.Value), '{"refused":"' + PWEB_BLOB_CAT_BLOB_BYTES + '"}');
    Record_('caller|over-the-blob-bound|refused-by-name');
  finally
    bridge := nil;
    JobsStore := nil;
  end;
end;

procedure TTestPWebCallerPrincipal.NoCallerNoBlob;
var
  store: IBlobStore;
  handle, who: RawUtf8;
  ceiling: TPWebBlobCeiling;
  count: Integer;
  bytes: Int64;
begin
  store := TPWebMemoryBlobStore.Create;
  Check(not PWebCallerPrincipal(who), 'a caller exists outside any call');
  CheckEqual(who, '');
  Check(not PWebCallerBlobPut(store, 'x', '', handle, ceiling),
    'a blob was created with no caller');
  CheckEqual(Ord(ceiling), Ord(pbcInvalidOwner));
  CheckEqual(handle, '');
  Check(store.Stats(count, bytes));
  CheckEqual(count, 0, 'a refused put left a blob behind');
  Record_('caller|outside-a-call|refused|invalid-owner|nothing-created');
end;

initialization
  InitCriticalSection(ViewLock);
  InitCriticalSection(MiniLock);

finalization
  MiniReset;
  if Length(Corpus) > 0 then
  begin
    ForceDirectories('build/cap16');
    FileFromString(RawUtf8ArrayToCsv(Corpus, #10) + #10,
      PWEB_CAP16_CORPUS_FILE);
  end;
  DoneCriticalSection(MiniLock);
  DoneCriticalSection(ViewLock);

end.
