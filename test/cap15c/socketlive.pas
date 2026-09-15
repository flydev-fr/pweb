program socketlive;

{ CAP-15C: the SHIPPED transport, through the REAL decorator, against a server
  that is not mORMot.

  test/cap15c/cap15ctests.pas drives the whole decision through an injected
  transport and never opens a socket. This program is the other half: the
  door exactly as a generated host composes it - TPWebSocketBridge over
  PWebSocketNativeTransport - opened, fed, starved, closed and revoked
  against test/cap15c/ws_server.js, whose JSONL log is the independent
  witness for everything a client cannot see about itself.

  Every row lands in --out as JSON; test/cap15c/run_cap15c_gates.ps1 joins
  them with the wire and gates both.

  Usage:
    socketlive --port=<plain ws port> --tls-port=<self-signed wss port>
               --out=<json> [--public=<wss url>]

  --public is RECORDED and NEVER GATES: a real certificate chain cannot come
  from a local server, because TLS validation is not disableable anywhere in
  this product. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  {$ifdef OSWINDOWS}
  windows,
  {$endif OSWINDOWS}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.json,
  mormot.core.variants,
  mormot.crypt.core,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.socket,
  {$ifdef DARWIN}
  pweb.platform.cocoa.socket,
  {$else}
  pweb.rpc.socket.mormot,
  {$endif DARWIN}
  pweb.capabilities.policy;

type
  TInner = class(TInterfacedObject, IInvocationBridge)
  public
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

function TInner.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  Result := PWebSuccessResult('42');
end;

var
  Port: Integer = 0;
  TlsPort: Integer = 0;
  OutPath: RawUtf8 = '';
  PublicUrl: RawUtf8 = '';
  Rows: TRawUtf8DynArray;
  Failures: Integer = 0;

procedure Row(const Name, Value: RawUtf8);
begin
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)] := '  ' + QuotedStrJson(Name) + ': ' + QuotedStrJson(Value);
  WriteLn('[CAP-15C] ', Name, ' = ', Value);
  Flush(Output);
end;

procedure RowInt(const Name: RawUtf8; Value: Int64);
begin
  Row(Name, RawUtf8(IntToStr(Value)));
end;

procedure RowBool(const Name: RawUtf8; Value: Boolean);
begin
  if Value then
    Row(Name, 'true')
  else
    Row(Name, 'false');
end;

procedure Require(Ok: Boolean; const Why: RawUtf8);
begin
  if Ok then
    exit;
  Inc(Failures);
  WriteLn(StdErr, '[CAP-15C] FAIL: ', Why);
  Flush(StdErr);
end;

{ ---------------- process memory, from the OS ---------------- }

{$ifdef OSWINDOWS}
type
  TProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: PtrUInt;
    WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage: PtrUInt;
    QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage: PtrUInt;
    QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage: PtrUInt;
    PeakPagefileUsage: PtrUInt;
  end;

function GetProcessMemoryInfo(Process: THandle;
  var Counters: TProcessMemoryCounters; cb: DWORD): BOOL; stdcall;
  external 'psapi.dll';

function MemPeak: Int64;
var
  c: TProcessMemoryCounters;
begin
  c := Default(TProcessMemoryCounters);
  c.cb := SizeOf(c);
  if GetProcessMemoryInfo(GetCurrentProcess, c, c.cb) then
    Result := c.PeakPagefileUsage
  else
    Result := -1;
end;
{$else}
function MemPeak: Int64;
var
  f: TextFile;
  line: string;
begin
  Result := -1;
  AssignFile(f, '/proc/self/status');
  {$I-} Reset(f); {$I+}
  if IOResult <> 0 then
    exit;
  try
    while not Eof(f) do
    begin
      ReadLn(f, line);
      if Copy(line, 1, 6) = 'VmHWM:' then
      begin
        line := Trim(Copy(line, 7, 64));
        if Pos(' ', line) > 0 then
          line := Copy(line, 1, Pos(' ', line) - 1);
        Result := StrToInt64Def(line, -1) * 1024;
        break;
      end;
    end;
  finally
    CloseFile(f);
  end;
end;
{$endif OSWINDOWS}

{ ---------------- the door, as a host composes it ---------------- }

function Ctx: TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := 'main';
  Result.PrincipalId := 'window:main';
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
end;

function Origins: TRawUtf8DynArray;
begin
  // the development loopback origin under which every must-PASS row runs,
  // and the TLS witness's https origin for the refused-certificate row
  SetLength(Result, 2);
  Result[0] := 'http://127.0.0.1:' + RawUtf8(IntToStr(Port));
  Result[1] := 'https://127.0.0.1:' + RawUtf8(IntToStr(TlsPort));
end;

function NewDoor(const Bounds: TPWebSocketBounds): TPWebSocketBridge;
begin
  Result := TPWebSocketBridge.Create(TInner.Create, PWebSocketNativeTransport,
    Origins, Bounds);
end;

function Invoke(D: TPWebSocketBridge; const Method, Args: RawUtf8): TPWebInvocationResult;
begin
  Result := (D as IInvocationBridge).Invoke(Ctx, Method, TPWebJson(Args), nil);
end;

function Verdict(const R: TPWebInvocationResult): RawUtf8;
var
  doc: variant;
begin
  if R.Kind = prkSuccess then
    exit('success');
  Result := RawUtf8(PWEB_ERROR_CODE_TEXT[R.Error.Code]);
  if R.Error.Code = pecServiceError then
  begin
    doc := _JsonFast(RawUtf8(R.Error.Data));
    Result := Result + ':' + _Safe(doc)^.U['category'];
    if _Safe(doc)^.U['reason'] <> '' then
      Result := Result + ':' + _Safe(doc)^.U['reason'];
  end;
end;

function Ws(const Route: RawUtf8): RawUtf8;
begin
  Result := 'ws://127.0.0.1:' + RawUtf8(IntToStr(Port)) + Route;
end;

function Open(D: TPWebSocketBridge; const Url: RawUtf8;
  const Extra: RawUtf8 = ''): TPWebInvocationResult;
begin
  Result := Invoke(D, PWEB_METHOD_SOCKET_OPEN,
    '{"url":' + QuotedStrJson(Url) + Extra + '}');
end;

function IdOf(const R: TPWebInvocationResult): RawUtf8;
var
  doc: variant;
begin
  Result := '';
  if R.Kind <> prkSuccess then
    exit;
  doc := _JsonFast(RawUtf8(R.Value));
  Result := _Safe(doc)^.U['id'];
end;

function SendText(D: TPWebSocketBridge; const Id, Text: RawUtf8): TPWebInvocationResult;
begin
  Result := Invoke(D, PWEB_METHOD_SOCKET_SEND,
    '{"id":' + QuotedStrJson(Id) + ',"text":' + QuotedStrJson(Text) + '}');
end;

function SendBinary(D: TPWebSocketBridge; const Id: RawUtf8;
  const Bin: RawByteString): TPWebInvocationResult;
begin
  Result := Invoke(D, PWEB_METHOD_SOCKET_SEND,
    '{"id":' + QuotedStrJson(Id) + ',"base64":"' + BinToBase64(Bin) + '"}');
end;

function CloseSock(D: TPWebSocketBridge; const Id: RawUtf8;
  const Extra: RawUtf8 = ''): TPWebInvocationResult;
begin
  Result := Invoke(D, PWEB_METHOD_SOCKET_CLOSE,
    '{"id":' + QuotedStrJson(Id) + Extra + '}');
end;

type
  { one event, as the page receives it }
  TLiveEvent = record
    Kind: RawUtf8;         // open | message | error | close
    Text: RawUtf8;
    Binary: RawByteString;
    IsBinary: Boolean;
    Code: Integer;
    Reason, Category, Protocol: RawUtf8;
    WasClean: Boolean;
    Undelivered: Integer;
  end;
  TLiveEvents = array of TLiveEvent;

// one receive; appends what it got, answers the verdict
function ReceiveInto(D: TPWebSocketBridge; const Id: RawUtf8; WaitMs: Integer;
  var Events: TLiveEvents): RawUtf8;
var
  r: TPWebInvocationResult;
  doc: variant;
  list, item: PDocVariantData;
  i: Integer;
  ev: TLiveEvent;
begin
  r := Invoke(D, PWEB_METHOD_SOCKET_RECEIVE,
    '{"id":' + QuotedStrJson(Id) + ',"waitMs":' + RawUtf8(IntToStr(WaitMs)) + '}');
  Result := Verdict(r);
  if r.Kind <> prkSuccess then
    exit;
  doc := _JsonFast(RawUtf8(r.Value));
  list := _Safe(doc)^.A['events'];
  for i := 0 to list^.Count - 1 do
  begin
    item := _Safe(list^.Values[i]);
    ev := Default(TLiveEvent);
    ev.Kind := item^.U['type'];
    ev.Protocol := item^.U['protocol'];
    if item^.Exists('base64') then
    begin
      ev.IsBinary := True;
      ev.Binary := Base64ToBin(item^.U['base64']);
    end
    else
      ev.Text := item^.U['text'];
    ev.Code := item^.I['code'];
    ev.Reason := item^.U['reason'];
    ev.Category := item^.U['category'];
    ev.WasClean := item^.B['wasClean'];
    ev.Undelivered := item^.I['undelivered'];
    SetLength(Events, Length(Events) + 1);
    Events[High(Events)] := ev;
  end;
end;

var
  // what one receive returned beyond the event a caller was waiting for,
  // per socket. MEASURED on Linux: a text, a binary and a sha message came
  // back in ONE receive, and a helper that kept only the first match read
  // the fragment row as a failure the door had not made
  PendIds: TRawUtf8DynArray;
  PendEvents: array of TLiveEvents;

function PendIndex(const Id: RawUtf8): Integer;
var
  i: Integer;
begin
  for i := 0 to High(PendIds) do
    if PendIds[i] = Id then
      exit(i);
  Result := Length(PendIds);
  SetLength(PendIds, Result + 1);
  SetLength(PendEvents, Result + 1);
  PendIds[Result] := Id;
end;

// receive until an event of Kind arrives (or a close ends the socket); the
// events before it are consumed, the events after it are kept for the next call
function WaitEvent(D: TPWebSocketBridge; const Id, Kind: RawUtf8;
  Ms: Integer; out Ev: TLiveEvent): Boolean;
var
  deadline: Int64;
  i, p: Integer;
begin
  Result := False;
  Ev := Default(TLiveEvent);
  p := PendIndex(Id);
  deadline := GetTickCount64 + Ms;
  repeat
    for i := 0 to High(PendEvents[p]) do
      if (PendEvents[p][i].Kind = Kind) or
         (PendEvents[p][i].Kind = 'close') then
      begin
        Ev := PendEvents[p][i];
        Delete(PendEvents[p], 0, i + 1);
        exit(Ev.Kind = Kind);
      end;
    PendEvents[p] := nil;
    if GetTickCount64 >= deadline then
      exit;
    if ReceiveInto(D, Id, 200, PendEvents[p]) <> 'success' then
      exit;
  until False;
end;

function Pattern(Size, Seed: Integer): RawByteString;
var
  i: Integer;
  p: PByte;
begin
  SetLength(Result, Size);
  p := pointer(Result);
  for i := 0 to Size - 1 do
    p[i] := Byte((i * 31 + Seed) and 255);
end;

function Bounds: TPWebSocketBounds;
begin
  Result := PWebSocketDefaultBounds;
end;

{ ---------------- the rows ---------------- }

procedure Step(const AName: RawUtf8);
begin
  // printed and flushed BEFORE the operation, so a process that dies inside
  // one names the row it died in - on Darwin two hosted runs died in this
  // stretch with no row to point at
  WriteLn('[CAP-15C] step ', AName);
  Flush(Output);
end;

procedure RowsInterop;
var
  d: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  id: RawUtf8;
  ev: TLiveEvent;
  txt: RawUtf8;
  bin, big: RawByteString;
  t0: Int64;
begin
  d := NewDoor(Bounds);
  keep := d;
  // L1 the handshake
  r := Open(d, Ws('/echo?row=l_handshake'),
    ',"protocols":["chat.v1","json.v2"],"headers":{"Authorization":"Bearer live","x-live":"1"}');
  Row('live_open', Verdict(r));
  id := IdOf(r);
  Require(id <> '', 'L1: the door did not open against a standard server');
  RowBool('live_open_event', WaitEvent(d, id, 'open', 3000, ev));
  Row('live_selected_protocol', ev.Protocol);
  Require(ev.Protocol = 'json.v2', 'L1: the selected subprotocol was not surfaced');
  // L2 text, binary and 1 MiB, both directions
  txt := 'h'#$C3#$A9'llo w'#$C3#$B6'rld '#$E2#$9C#$93;
  Row('live_send_text', Verdict(SendText(d, id, txt)));
  RowBool('live_echo_text', WaitEvent(d, id, 'message', 3000, ev) and (ev.Text = txt));
  Require(ev.Text = txt, 'L2: the text echo differed');
  bin := Pattern(256, 0);
  Row('live_send_binary', Verdict(SendBinary(d, id, bin)));
  RowBool('live_echo_binary', WaitEvent(d, id, 'message', 3000, ev) and ev.IsBinary and (ev.Binary = bin));
  Require(ev.Binary = bin, 'L2: the binary echo differed');
  big := Pattern(PWEB_SOCKET_MAX_MESSAGE, 11);
  t0 := GetTickCount64;
  Row('live_send_1mib', Verdict(SendBinary(d, id, big)));
  RowInt('live_send_1mib_ms', GetTickCount64 - t0);
  t0 := GetTickCount64;
  RowBool('live_echo_1mib', WaitEvent(d, id, 'message', 10000, ev) and (ev.Binary = big));
  RowInt('live_echo_1mib_wait_ms', GetTickCount64 - t0);
  Require(ev.Binary = big, 'L2: 1 MiB did not cross both ways intact');
  // L6 the page's close, and the server's echo as its close event
  Row('live_client_close', Verdict(CloseSock(d, id, ',"code":4000,"reason":"done"')));
  RowBool('live_client_close_event', WaitEvent(d, id, 'close', 3000, ev));
  RowInt('live_client_close_code', ev.Code);
  Row('live_client_close_category', ev.Category);
  Require((ev.Code = 4000) and (ev.Category = 'page'),
    'L6: the page close did not come back as a page close event');

  // L3 fragments, with a PING between two of them
  r := Open(d, Ws('/fragment?size=100000&parts=7&ping=1&row=l_fragment'));
  id := IdOf(r);
  WaitEvent(d, id, 'open', 3000, ev);
  WaitEvent(d, id, 'message', 5000, ev);
  txt := ev.Text;
  WaitEvent(d, id, 'message', 5000, ev);
  bin := ev.Binary;
  WaitEvent(d, id, 'message', 5000, ev);
  RowBool('live_fragment_text_sha', Copy(ev.Text, 5, 64) = Sha256(txt));
  RowBool('live_fragment_binary_sha', Copy(ev.Text, 70, 64) = Sha256(bin));
  Require((Copy(ev.Text, 5, 64) = Sha256(txt)) and (Copy(ev.Text, 70, 64) = Sha256(bin)),
    'L3: a fragmented message with an interleaved ping was not reassembled intact');
  CloseSock(d, id);

  // L4 a server PING, answered natively
  r := Open(d, Ws('/ping?row=l_ping'));
  id := IdOf(r);
  WaitEvent(d, id, 'message', 3000, ev);
  RowBool('live_ping_answered', Copy(ev.Text, 1, 13) = 'pong:probe-1:');
  Require(Copy(ev.Text, 1, 13) = 'pong:probe-1:', 'L4: a server ping was not answered');
  CloseSock(d, id);

  // L5 the server closes with a code
  r := Open(d, Ws('/close?code=4001&reason=bye&row=l_server_close'));
  id := IdOf(r);
  WaitEvent(d, id, 'close', 3000, ev);
  RowInt('live_server_close_code', ev.Code);
  Row('live_server_close_reason', ev.Reason);
  Row('live_server_close_category', ev.Category);
  Require((ev.Code = 4001) and (ev.Reason = 'bye') and (ev.Category = 'remote'),
    'L5: a server close with a code was not surfaced');

  // L7-L9 handshakes that must be refused
  Row('live_redirect', Verdict(Open(d, Ws('/redirect?row=l_redirect'))));
  Row('live_notws', Verdict(Open(d, Ws('/notws?row=l_notws'))));
  Row('live_badproto', Verdict(Open(d, Ws('/badproto?row=l_badproto'), ',"protocols":["chat.v1"]')));
  Row('live_noproto', Verdict(Open(d, Ws('/noproto?row=l_noproto'), ',"protocols":["chat.v1"]')));
  Step('l_redirect2');
  Require(Verdict(Open(d, Ws('/redirect?row=l_redirect2'))) =
    'service_error:handshake_refused:redirect', 'L7: a 3xx was not refused as a redirect');

  // L21 no cookie is kept
  Step('l_setcookie');
  Open(d, Ws('/setcookie?row=l_setcookie'));
  r := Open(d, Ws('/echo?row=l_after_cookie'));
  CloseSock(d, IdOf(r));

  // L11 TLS validation cannot be turned off: a self-signed loopback chain
  Step('l_tls');
  r := Invoke(d, PWEB_METHOD_SOCKET_OPEN, '{"url":"wss://127.0.0.1:' +
    RawUtf8(IntToStr(TlsPort)) + '/echo?row=l_tls"}');
  Row('live_tls_untrusted', Verdict(r));
  Require(Verdict(r) = 'service_error:tls_failed', 'L11: an untrusted certificate was not refused');

  // L12 the message bound
  r := Open(d, Ws('/bigframe?size=1048576&row=l_bigframe_at'));
  id := IdOf(r);
  RowBool('live_bigframe_at_bound', WaitEvent(d, id, 'message', 5000, ev) and
    (Length(ev.Binary) = 1048576));
  CloseSock(d, id);
  r := Open(d, Ws('/bigframe?size=1048577&row=l_bigframe_over'));
  id := IdOf(r);
  WaitEvent(d, id, 'close', 5000, ev);
  RowInt('live_bigframe_over_code', ev.Code);
  Row('live_bigframe_over_category', ev.Category);
  Require((ev.Code = 1009) and (ev.Category = 'message_too_large'),
    'L12: a message over the bound was not closed 1009');
  d.BeforeDrain;
  keep := nil;
end;

procedure RowsBoundsAndDeadlines;
var
  d: TPWebSocketBridge;
  keep: IInvocationBridge;
  b: TPWebSocketBounds;
  r: TPWebInvocationResult;
  id: RawUtf8;
  ev: TLiveEvent;
  t0, peak0: Int64;
  i, sent: Integer;
  big: RawByteString;
  verdict_: RawUtf8;
begin
  b := Bounds;
  b.ConnectDeadlineMs := 1000;
  b.SendDeadlineMs := 2000;
  d := NewDoor(b);
  keep := d;
  // L10 the handshake deadline is wall-clock
  t0 := GetTickCount64;
  r := Open(d, Ws('/slow?ms=5000&row=l_slow'));
  RowInt('live_handshake_deadline_ms_for_1000', GetTickCount64 - t0);
  Row('live_handshake_deadline', Verdict(r));
  Require((Verdict(r) = 'service_error:deadline') and (GetTickCount64 - t0 < 2000),
    'L10: a held handshake outlived its wall-clock deadline');
  // L13 one 64 MiB message in 16 KiB frames: the reassembled bound
  peak0 := MemPeak;
  r := Open(d, Ws('/contflood?frames=4096&size=16384&row=l_contflood'));
  id := IdOf(r);
  WaitEvent(d, id, 'close', 30000, ev);
  RowInt('live_contflood_code', ev.Code);
  RowInt('live_contflood_mem_peak_delta', MemPeak - peak0);
  Require(ev.Code = 1009, 'L13: an over-bound reassembly was not closed 1009');
  // L15 the send deadline is wall-clock, against a peer that stops reading
  r := Open(d, Ws('/noread?row=l_noread'));
  id := IdOf(r);
  big := Pattern(PWEB_SOCKET_MAX_MESSAGE, 1);
  sent := 0;
  verdict_ := 'success';
  t0 := 0;
  for i := 1 to 256 do
  begin
    t0 := GetTickCount64;
    verdict_ := Verdict(SendBinary(d, id, big));
    if verdict_ <> 'success' then
      break;
    Inc(sent);
  end;
  RowInt('live_noread_mib_accepted', sent);
  Row('live_noread_refused', verdict_);
  RowInt('live_noread_refused_send_ms_for_2000', GetTickCount64 - t0);
  Require((verdict_ = 'service_error:deadline') and (GetTickCount64 - t0 < 3000),
    'L15: a send to a peer that stopped reading outlived its wall-clock deadline');
  d.BeforeDrain;
  keep := nil;
end;

procedure RowsBackpressure;
var
  d: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  id: RawUtf8;
  events: TLiveEvents;
  i, got, gaps, corrupt: Integer;
  seq: Cardinal;
  p: PByte;
  done: Boolean;
  peak0, t0: Int64;
  ev: TLiveEvent;
begin
  d := NewDoor(Bounds);
  keep := d;
  r := Open(d, Ws('/flood?count=1024&size=65536&row=l_flood'));
  id := IdOf(r);
  WaitEvent(d, id, 'open', 3000, ev);
  peak0 := MemPeak;
  // THE PAGE DOES NOT POLL for five seconds. SIZED FROM MEASUREMENTS, not
  // widened after a failure: the gate needs the server's writes blocked for
  // at least 2000 ms, and the kernel's socket buffers absorb part of the flood
  // before any write blocks. Hosted windows-x86_64 run 34908218839 took about
  // 1.2 s to fill them - its longest block was 1801 ms of a 3000 ms stall -
  // against 2678-3074 ms of blocking on the other targets measured. Five
  // seconds covers that fill plus the required block with 1.8 s to spare
  Sleep(5000);
  RowInt('live_bp_stall_queue_bytes', d.QueuedBytes(id));
  RowInt('live_bp_stall_queue_events', d.QueuedEvents(id));
  RowInt('live_bp_stall_mem_peak_delta', MemPeak - peak0);
  Require(d.QueuedBytes(id) <= PWEB_SOCKET_QUEUE_BYTES, 'L14: the queue passed its byte bound');
  // a send while reading has stopped still reaches the wire
  Row('live_bp_send_while_stalled', Verdict(SendText(d, id, 'while-stalled')));
  // drain, checking every sequence number and every fill byte
  got := 0;
  gaps := 0;
  corrupt := 0;
  done := False;
  t0 := GetTickCount64;
  while (not done) and (GetTickCount64 - t0 < 60000) do
  begin
    events := nil;
    if ReceiveInto(d, id, 1000, events) <> 'success' then
      break;
    for i := 0 to High(events) do
      if events[i].IsBinary then
      begin
        p := pointer(events[i].Binary);
        seq := (Cardinal(p[0]) shl 24) or (Cardinal(p[1]) shl 16) or
               (Cardinal(p[2]) shl 8) or Cardinal(p[3]);
        if seq <> Cardinal(got) then
          Inc(gaps);
        if (Length(events[i].Binary) <> 65536) or
           (p[4] <> Byte(seq and 255)) or
           (p[65535] <> Byte(seq and 255)) then
          Inc(corrupt);
        Inc(got);
      end
      else if Copy(events[i].Text, 1, 11) = 'flood-done:' then
        done := True;
  end;
  RowInt('live_bp_received', got);
  RowInt('live_bp_gaps', gaps);
  RowInt('live_bp_corrupt', corrupt);
  RowBool('live_bp_done', done);
  RowInt('live_bp_drain_ms', GetTickCount64 - t0);
  Require((got = 1024) and (gaps = 0) and (corrupt = 0) and done,
    'L14: backpressure dropped, reordered or corrupted a message');
  d.BeforeDrain;
  keep := nil;
end;

procedure RowsLifecycle;
var
  d: TPWebSocketBridge;
  keep: IInvocationBridge;
  b: TPWebSocketBounds;
  r: TPWebInvocationResult;
  id, id2: RawUtf8;
  ev: TLiveEvent;
  t0: Int64;
  policy: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  builder: TPWebCapabilityPolicyBuilder;
  events: TLiveEvents;
begin
  // L16 the idle bound, as the keeper enforces it
  b := Bounds;
  b.IdleMs := 1500;
  d := NewDoor(b);
  keep := d;
  r := Open(d, Ws('/idle?row=l_idle'));
  id := IdOf(r);
  Sleep(2500);
  events := nil;
  ReceiveInto(d, id, 0, events);
  if Length(events) > 0 then
    ev := events[High(events)];
  Row('live_idle_category', ev.Category);
  RowInt('live_idle_code', ev.Code);
  Require(ev.Category = 'idle', 'L16: an unpolled socket was not closed as idle');
  d.BeforeDrain;
  keep := nil;

  // L17 revocation, with the real policy
  builder := TPWebCapabilityPolicyBuilder.Create;
  try
    builder.SetAppMaximum([PWEB_CAP_NETWORK_SOCKET]);
    builder.SetWindowCapabilities('main', [PWEB_CAP_NETWORK_SOCKET]);
    builder.SetPrincipalCapabilities('window:main', [PWEB_CAP_NETWORK_SOCKET]);
    builder.MapMethod(PWEB_METHOD_SOCKET_OPEN, [PWEB_CAP_NETWORK_SOCKET]);
    policy := builder.Build;
  finally
    builder.Free;
  end;
  policyRef := policy;
  d := NewDoor(Bounds);
  keep := d;
  d.AttachPolicy(policy);
  r := Open(d, Ws('/echo?row=l_revoke'));
  id := IdOf(r);
  WaitEvent(d, id, 'open', 3000, ev);
  t0 := GetTickCount64;
  policy.SetRuntimeGrants('window:main', []);
  RowInt('live_revoke_open_after_call', d.OpenCount);
  Row('live_revoke_send_after', Verdict(SendText(d, id, 'after-revoke')));
  Require(d.OpenCount = 0, 'L17: a revoked socket survived the revoking call');
  // L18 document replacement
  policy.ClearRuntimeGrants('window:main');
  r := Open(d, Ws('/echo?row=l_navigation'));
  id := IdOf(r);
  WaitEvent(d, id, 'open', 3000, ev);
  d.DocumentReplacing('main');
  Row('live_navigation_send_after', Verdict(SendText(d, id, 'after-navigation')));
  // L19 shutdown before the drain releases every transport before it returns
  r := Open(d, Ws('/echo?row=l_drain_a'));
  id := IdOf(r);
  r := Open(d, Ws('/echo?row=l_drain_b'));
  id2 := IdOf(r);
  t0 := GetTickCount64;
  d.BeforeDrain;
  RowInt('live_before_drain_ms', GetTickCount64 - t0);
  RowInt('live_before_drain_open_after', d.OpenCount);
  Require(d.OpenCount = 0, 'L19: a socket survived BeforeDrain');
  keep := nil;
  policyRef := nil;

  // L20 latency after an idle socket
  d := NewDoor(Bounds);
  keep := d;
  r := Open(d, Ws('/delayed?ms=2000&row=l_latency'));
  id := IdOf(r);
  WaitEvent(d, id, 'open', 3000, ev);
  if WaitEvent(d, id, 'message', 8000, ev) then
    RowInt('live_latency_after_2000ms_idle', UnixMSTimeUtcFast -
      StrToInt64Def(Copy(ev.Text, 6, Length(ev.Text) - 6), 0));
  d.BeforeDrain;
  keep := nil;
end;

var
  // CAP-15C: two TLS witnesses whose certificates the RUNNER trusts for this
  // process only (OpenSSL's SSL_CERT_FILE, set by the gate): one names
  // 127.0.0.1, the other names another host. The right name is the CONTROL
  // that proves the trust really reached the transport - without it a
  // refusal of the wrong name would prove nothing
  TrustedRightPort: Integer = 0;
  TrustedWrongPort: Integer = 0;

procedure RowTrusted(APort: Integer; const ARow: RawUtf8);
var
  d: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  origins: TRawUtf8DynArray;
  host: RawUtf8;
begin
  host := '127.0.0.1:' + RawUtf8(IntToStr(APort));
  SetLength(origins, 1);
  origins[0] := 'https://' + host;
  d := TPWebSocketBridge.Create(TInner.Create, PWebSocketNativeTransport,
    origins, Bounds);
  keep := d;
  r := Open(d, 'wss://' + host + '/echo?row=' + ARow);
  Row(ARow, Verdict(r));
  d.BeforeDrain;
  keep := nil;
end;

procedure RowsTlsName;
begin
  if (TrustedRightPort <= 0) or
     (TrustedWrongPort <= 0) then
  begin
    Row('live_tls_trusted_right_name', 'not_run');
    Row('live_tls_trusted_wrong_name', 'not_run');
    exit;
  end;
  RowTrusted(TrustedRightPort, 'live_tls_trusted_right_name');
  RowTrusted(TrustedWrongPort, 'live_tls_trusted_wrong_name');
end;

procedure RowsPublic;
var
  d: TPWebSocketBridge;
  keep: IInvocationBridge;
  r: TPWebInvocationResult;
  id, host: RawUtf8;
  ev: TLiveEvent;
  echoed: Boolean;
  deadline: Int64;
  origins: TRawUtf8DynArray;
begin
  if PublicUrl = '' then
  begin
    Row('live_public_wss', 'not_run');
    exit;
  end;
  host := Copy(PublicUrl, 7, MaxInt);
  if Pos('/', host) > 0 then
    host := Copy(host, 1, Pos('/', host) - 1);
  SetLength(origins, 1);
  origins[0] := 'https://' + host;
  d := TPWebSocketBridge.Create(TInner.Create, PWebSocketNativeTransport,
    origins, Bounds);
  keep := d;
  r := Open(d, PublicUrl);
  Row('live_public_wss_open', Verdict(r));
  id := IdOf(r);
  echoed := False;
  if id <> '' then
  begin
    SendText(d, id, 'pweb-cap15c-observation');
    deadline := GetTickCount64 + 10000;
    while (not echoed) and (GetTickCount64 < deadline) do
      if WaitEvent(d, id, 'message', 2000, ev) and
         (ev.Text = 'pweb-cap15c-observation') then
        echoed := True;
  end;
  RowBool('live_public_wss_echoed', echoed);
  d.BeforeDrain;
  keep := nil;
end;

{$ifdef DARWIN}
// the Darwin leg's configuration rows, READ BACK from the task and its
// configuration: the behaviour rows above are the same ones every target
// runs, and these say what the NSURLSession side actually carried
procedure RowsDarwin;
var
  f: TPWebCocoaSocketFacts;
begin
  f := PWebCocoaSocketFacts;
  RowInt('darwin_socket_opens', f.Opens);
  RowInt('darwin_socket_redirects_offered', f.RedirectsOffered);
  RowInt('darwin_socket_proxy_dict_empty', f.ProxyDictEmpty);
  RowInt('darwin_socket_cookie_storage_nil', f.CookieStorageNil);
  RowInt('darwin_socket_should_set_cookies', f.ShouldSetCookies);
  RowInt('darwin_socket_open_on_main_thread', f.OpenOnMainThread);
  RowInt('darwin_socket_maximum_message_size', f.MaximumMessageSize);
  Require(f.ProxyDictEmpty = 1, 'D: the socket configuration inherited a proxy dictionary');
  Require(f.CookieStorageNil = 1, 'D: the socket configuration kept a cookie storage');
  Require(f.ShouldSetCookies = 0, 'D: the socket configuration sets cookies');
  Require(f.OpenOnMainThread = 0, 'D: a socket was opened on the main thread');
  Require(f.MaximumMessageSize = PWEB_SOCKET_MAX_MESSAGE,
    'D: maximumMessageSize is not the message bound');
end;
{$endif DARWIN}

procedure ParseArgs;
var
  i: Integer;
  a: string;
begin
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if Copy(a, 1, 7) = '--port=' then
      Port := StrToIntDef(Copy(a, 8, 16), 0)
    else if Copy(a, 1, 11) = '--tls-port=' then
      TlsPort := StrToIntDef(Copy(a, 12, 16), 0)
    else if Copy(a, 1, 6) = '--out=' then
      OutPath := RawUtf8(Copy(a, 7, MaxInt))
    else if Copy(a, 1, 21) = '--trusted-right-port=' then
      TrustedRightPort := StrToIntDef(Copy(a, 22, 16), 0)
    else if Copy(a, 1, 21) = '--trusted-wrong-port=' then
      TrustedWrongPort := StrToIntDef(Copy(a, 22, 16), 0)
    else if Copy(a, 1, 9) = '--public=' then
      PublicUrl := RawUtf8(Copy(a, 10, MaxInt));
  end;
end;

procedure WriteOut;
var
  i: Integer;
  json: RawUtf8;
begin
  json := '{'#10;
  for i := 0 to High(Rows) do
  begin
    json := json + Rows[i];
    if i < High(Rows) then
      json := json + ','#10
    else
      json := json + #10;
  end;
  json := json + '}'#10;
  if OutPath <> '' then
    FileFromString(json, TFileName(OutPath));
end;

begin
  ParseArgs;
  if (Port <= 0) or (TlsPort <= 0) then
  begin
    WriteLn(StdErr, 'socketlive: --port=<n> and --tls-port=<n> are required');
    Halt(2);
  end;
  RowsInterop;
  RowsBoundsAndDeadlines;
  RowsBackpressure;
  RowsLifecycle;
  RowsPublic;
  RowsTlsName;
  {$ifdef DARWIN}
  RowsDarwin;
  {$endif DARWIN}
  RowInt('live_failures', Failures);
  WriteOut;
  if Failures > 0 then
    Halt(1);
end.
