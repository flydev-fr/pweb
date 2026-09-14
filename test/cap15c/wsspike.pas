program wsspike;

{ CAP-15C Checkpoint 1: two candidate WebSocket transports, one row suite,
  one server that is not mORMot.

  This is an INSTRUMENT, not the implementation. The brief names the row that
  must be measured first: mORMot's `THttpClientWebSockets` also speaks
  mORMot's own binary REST-over-WebSockets protocol, so before a transport is
  written on it, somebody has to see it talk plain RFC 6455 to a peer that
  has never heard of mORMot - test/cap15c/ws_server.js, whose JSONL log is
  the independent witness for everything this program cannot see about
  itself.

  --transport=mormot   THttpClientWebSockets.Create + OpenBind, then
                       WebSocketsUpgrade with a TWebSocketProtocolChat
                       subclass (raw text and binary frames), with
                       Settings.NotifyAllFrames so a CLOSE frame's code and
                       reason reach the callback. The shape the brief names.

  --transport=raw      the SAME socket layer - mormot.net.sock's TCrtSocket,
                       which is what gives THttpClientWebSockets its connect,
                       its TLS and its absence of any proxy - with the RFC
                       6455 handshake and framing written here instead of
                       taken from mormot.net.ws.*. It exists because the first
                       run of the mormot transport measured defects that live
                       inside a record method nothing overridable reaches
                       (unbounded reassembly; a control frame between two
                       fragments kills the connection), and a recommendation
                       to replace a measured transport is only worth making
                       against a MEASURED alternative.

  Both put every text and binary message into the same bounded per-socket
  event queue, and a FULL queue parks the thread that reads the socket: the
  "stop reading" half of TCP backpressure.

  Every row prints `<t>.name = value` and lands in --out as JSON. Nothing
  here gates: test/cap15c/run_cap15c_spike.ps1 joins these rows with the
  server's log and the checkpoint artifact reads both.

  Usage:
    wsspike --transport=mormot|raw --port=<plain ws port>
            --tls-port=<self-signed wss port> --out=<json>
            [--public=<wss url>]

  --public is an OBSERVATION: one live round trip to a public echo endpoint,
  never a gate, because TLS validation is not disableable in this product
  and a local server cannot present a chain the system trusts. }

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
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.json,
  mormot.crypt.core,
  mormot.net.sock,
  mormot.net.http,
  mormot.net.client,
  {$ifdef OSPOSIX}
  mormot.lib.openssl11,
  {$endif OSPOSIX}
  mormot.net.ws.core,
  mormot.net.ws.client;

const
  // the spike's own queue bounds - small on purpose, so the flood row reaches
  // them in milliseconds. The contract's numbers are ratified separately
  SPIKE_QUEUE_COUNT = 64;
  SPIKE_QUEUE_BYTES = 1 shl 20;
  SPIKE_FRAME_MAX = 1 shl 20;
  // the raw reader observes its closing flag and any deadline this often
  RAW_SLICE_MS = 20;
  RAW_MAX_HEAD = 16384;
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TSpikeEventKind = (sekOpen, sekText, sekBinary, sekClose);

  TSpikeEvent = record
    Kind: TSpikeEventKind;
    Data: RawByteString;
    Code: Integer;
    Reason: RawUtf8;
  end;

  { The page's view of one socket: a bounded event queue, and nothing about
    how frames reach it. }
  TSpikeSocket = class
  public
    Lock: TRTLCriticalSection;
    Arrived, Room: TEvent;
    Events: array of TSpikeEvent;
    Count: Integer;
    QBytes: Int64;
    MaxCount: Integer;
    MaxBytes: Int64;
    PeakCount: Integer;
    PeakBytes: Int64;
    Closing: Boolean;
    CloseSeen: Boolean;
    PingsSeen, PongsSeen: LongInt;
    ParkCount: Integer;
    ParkedMs: Int64;
    DiscardedAtClose: Integer;
    LastPollTix: Int64;
    constructor Create(AMaxCount: Integer; AMaxBytes: Int64); virtual;
    destructor Destroy; override;
    procedure Push(const E: TSpikeEvent; Bounded: Boolean);
    procedure PushClose(Code: Integer; const Reason: RawUtf8);
    function Pop(out E: TSpikeEvent; WaitMs: Integer): Boolean;
    procedure MarkClosing;
    function Open(const Host: RawUtf8; APort: Integer; Tls: Boolean;
      const Target: RawUtf8; const Offered: array of RawUtf8;
      const Headers: RawUtf8; TimeoutMs: Integer; Stock: Boolean;
      out Error: RawUtf8): Boolean; virtual; abstract;
    function SendData(Op: TWebSocketFrameOpCode;
      const Payload: RawByteString): Boolean; virtual; abstract;
    function SendClose(Code: Integer; const Reason: RawUtf8): Boolean;
      virtual; abstract;
    function Release: Int64; virtual; abstract;
    function Selected: RawUtf8; virtual; abstract;
  end;

  TSpikeSocketClass = class of TSpikeSocket;

  { mORMot raw frames, and an OFFERED LIST of subprotocols. mORMot's base
    class compares the server's choice against ONE name with PropNameEquals,
    so a client that offers two can never accept either - measured below as
    the stock row. }
  TSpikeProtocol = class(TWebSocketProtocolChat)
  protected
    FOffered: TRawUtf8DynArray;
    FOfferedText: RawUtf8;
    procedure SetName(const aProtocolName: RawUtf8); override;
  public
    Chosen: RawUtf8;
    constructor CreateOffer(const aUri: RawUtf8;
      const Offered: array of RawUtf8;
      const aOnFrame: TOnWebSocketProtocolChatIncomingFrame);
    function GetSubprotocols: RawUtf8; override;
    function IsSubprotocol(const aProtocolName: RawUtf8): boolean; override;
  end;

  TMormotSocket = class(TSpikeSocket)
  public
    Client: THttpClientWebSockets;
    Proto: TWebSocketProtocolChat;
    destructor Destroy; override;
    procedure OnFrame(Sender: TWebSocketProcess; const Frame: TWebSocketFrame);
    function Open(const Host: RawUtf8; APort: Integer; Tls: Boolean;
      const Target: RawUtf8; const Offered: array of RawUtf8;
      const Headers: RawUtf8; TimeoutMs: Integer; Stock: Boolean;
      out Error: RawUtf8): Boolean; override;
    function SendData(Op: TWebSocketFrameOpCode;
      const Payload: RawByteString): Boolean; override;
    function SendClose(Code: Integer; const Reason: RawUtf8): Boolean; override;
    function Release: Int64; override;
    function Selected: RawUtf8; override;
  end;

  TRawSocket = class;

  TRawReader = class(TThread)
  protected
    FOwner: TRawSocket;
    procedure Execute; override;
  public
    constructor CreateFor(AOwner: TRawSocket);
  end;

  { RFC 6455 over mormot.net.sock.TCrtSocket, with every bound checked where
    the bytes arrive rather than after they have been collected. }
  TRawSocket = class(TSpikeSocket)
  public
    Sock: TCrtSocket;
    Reader: TRawReader;
    WriteLock: TRTLCriticalSection;
    FSelected: RawUtf8;
    CloseSent: Boolean;
    constructor Create(AMaxCount: Integer; AMaxBytes: Int64); override;
    destructor Destroy; override;
    function ReadExact(P: PAnsiChar; Len: PtrInt; DeadlineTix: Int64;
      out Err: RawUtf8): Boolean;
    function WriteFrame(Op: Byte; const Payload: RawByteString): Boolean;
    procedure FailProtocol(Code: Integer; const Why: RawUtf8);
    procedure ReaderLoop;
    function Open(const Host: RawUtf8; APort: Integer; Tls: Boolean;
      const Target: RawUtf8; const Offered: array of RawUtf8;
      const Headers: RawUtf8; TimeoutMs: Integer; Stock: Boolean;
      out Error: RawUtf8): Boolean; override;
    function SendData(Op: TWebSocketFrameOpCode;
      const Payload: RawByteString): Boolean; override;
    function SendClose(Code: Integer; const Reason: RawUtf8): Boolean; override;
    function Release: Int64; override;
    function Selected: RawUtf8; override;
  end;

var
  Port: Integer = 0;
  TlsPort: Integer = 0;
  OutPath: RawUtf8 = '';
  PublicUrl: RawUtf8 = '';
  TransportName: RawUtf8 = '';
  SocketClass: TSpikeSocketClass;
  RowPrefix: RawUtf8 = '';
  TagPrefix: RawUtf8 = '';
  Rows: TRawUtf8DynArray;

{ ---------------- rows ---------------- }

procedure Row(const Name, Value: RawUtf8);
begin
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)] := '  ' + QuotedStrJson(RowPrefix + Name) + ': ' +
    QuotedStrJson(Value);
  WriteLn('[CAP-15C] ', RowPrefix, Name, ' = ', Value);
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

function FirstLine(const S: RawUtf8): RawUtf8;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(S) do
    if S[i] in [#13, #10] then
    begin
      Result := Copy(S, 1, i - 1);
      exit;
    end;
end;

function AsciiLower(const S: RawUtf8): RawUtf8;
var
  i: Integer;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function AsciiTrim(const S: RawUtf8): RawUtf8;
var
  a, b: Integer;
begin
  a := 1;
  b := Length(S);
  while (a <= b) and (S[a] in [' ', #9]) do
    Inc(a);
  while (b >= a) and (S[b] in [' ', #9]) do
    Dec(b);
  Result := Copy(S, a, b - a + 1);
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

// private commit charge: what the heap actually holds, not what is paged in
function MemNow: Int64;
var
  c: TProcessMemoryCounters;
begin
  c := Default(TProcessMemoryCounters);
  c.cb := SizeOf(c);
  if GetProcessMemoryInfo(GetCurrentProcess, c, c.cb) then
    Result := c.PagefileUsage
  else
    Result := -1;
end;

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
function ProcStatusKb(const Key: string): Int64;
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
      if Copy(line, 1, Length(Key) + 1) = Key + ':' then
      begin
        line := Trim(Copy(line, Length(Key) + 2, 64));
        if Pos(' ', line) > 0 then
          line := Copy(line, 1, Pos(' ', line) - 1);
        Result := StrToInt64Def(line, -1);
        break;
      end;
    end;
  finally
    CloseFile(f);
  end;
end;

function MemNow: Int64;
begin
  Result := ProcStatusKb('VmRSS') * 1024;
end;

function MemPeak: Int64;
begin
  Result := ProcStatusKb('VmHWM') * 1024;
end;
{$endif OSWINDOWS}

{ ---------------- TSpikeSocket: the queue ---------------- }

constructor TSpikeSocket.Create(AMaxCount: Integer; AMaxBytes: Int64);
begin
  inherited Create;
  InitCriticalSection(Lock);
  Arrived := TEvent.Create(nil, false, false, '');
  Room := TEvent.Create(nil, false, false, '');
  MaxCount := AMaxCount;
  MaxBytes := AMaxBytes;
  LastPollTix := GetTickCount64;
end;

destructor TSpikeSocket.Destroy;
begin
  Arrived.Free;
  Room.Free;
  DoneCriticalSection(Lock);
  inherited Destroy;
end;

procedure TSpikeSocket.MarkClosing;
begin
  EnterCriticalSection(Lock);
  Closing := true;
  LeaveCriticalSection(Lock);
  Room.SetEvent; // wakes a reader thread parked in Push
end;

procedure TSpikeSocket.Push(const E: TSpikeEvent; Bounded: Boolean);
var
  t0: Int64;
  parked: Boolean;
  n: Int64;
begin
  n := Length(E.Data);
  parked := false;
  t0 := 0;
  EnterCriticalSection(Lock);
  try
    // THE BACKPRESSURE: while the queue is full this is the READER THREAD
    // waiting here, so no further frame is read from the socket, the kernel
    // receive buffer fills, the TCP window closes, and the server's write()
    // starts refusing - which ws_server.js logs as a block.
    // The Count > 0 clause lets one frame no larger than the byte bound into
    // an empty queue, so a bound can never deadlock a legal frame
    if Bounded then
      while (not Closing) and
            (Count > 0) and
            ((Count >= MaxCount) or (QBytes + n > MaxBytes)) do
      begin
        if not parked then
        begin
          parked := true;
          t0 := GetTickCount64;
          Inc(ParkCount);
        end;
        LeaveCriticalSection(Lock);
        Room.WaitFor(20);
        EnterCriticalSection(Lock);
      end;
    if Closing and Bounded then
    begin
      Inc(DiscardedAtClose);
      exit;
    end;
    SetLength(Events, Count + 1);
    Events[Count] := E;
    Inc(Count);
    Inc(QBytes, n);
    if Count > PeakCount then
      PeakCount := Count;
    if QBytes > PeakBytes then
      PeakBytes := QBytes;
  finally
    if parked then
      Inc(ParkedMs, GetTickCount64 - t0);
    LeaveCriticalSection(Lock);
  end;
  Arrived.SetEvent;
end;

procedure TSpikeSocket.PushClose(Code: Integer; const Reason: RawUtf8);
var
  e: TSpikeEvent;
  first: Boolean;
begin
  EnterCriticalSection(Lock);
  first := not CloseSeen;
  CloseSeen := true;
  LeaveCriticalSection(Lock);
  if not first then
    exit;
  e := Default(TSpikeEvent);
  e.Kind := sekClose;
  e.Code := Code;
  e.Reason := Reason;
  Push(e, false);
end;

function TSpikeSocket.Pop(out E: TSpikeEvent; WaitMs: Integer): Boolean;
var
  deadline: Int64;
begin
  Result := false;
  E := Default(TSpikeEvent);
  deadline := GetTickCount64 + WaitMs;
  repeat
    EnterCriticalSection(Lock);
    try
      LastPollTix := GetTickCount64;
      if Count > 0 then
      begin
        E := Events[0];
        Delete(Events, 0, 1);
        Dec(Count);
        Dec(QBytes, Length(E.Data));
        Result := true;
      end;
    finally
      LeaveCriticalSection(Lock);
    end;
    if Result then
    begin
      Room.SetEvent;
      exit;
    end;
    if GetTickCount64 >= deadline then
      exit;
    Arrived.WaitFor(20);
  until false;
end;

{ ---------------- TSpikeProtocol ---------------- }

constructor TSpikeProtocol.CreateOffer(const aUri: RawUtf8;
  const Offered: array of RawUtf8;
  const aOnFrame: TOnWebSocketProtocolChatIncomingFrame);
var
  i: Integer;
begin
  inherited Create('', aUri, aOnFrame);
  SetLength(FOffered, Length(Offered));
  FOfferedText := '';
  for i := 0 to High(Offered) do
  begin
    FOffered[i] := Offered[i];
    if i > 0 then
      FOfferedText := FOfferedText + ', ';
    FOfferedText := FOfferedText + Offered[i];
  end;
end;

procedure TSpikeProtocol.SetName(const aProtocolName: RawUtf8);
begin
  inherited SetName(aProtocolName);
  Chosen := aProtocolName;
end;

function TSpikeProtocol.GetSubprotocols: RawUtf8;
begin
  Result := FOfferedText;
end;

function TSpikeProtocol.IsSubprotocol(const aProtocolName: RawUtf8): boolean;
var
  i: Integer;
begin
  Result := false;
  for i := 0 to High(FOffered) do
    if FOffered[i] = aProtocolName then
      exit(true);
end;

{ ---------------- TMormotSocket ---------------- }

destructor TMormotSocket.Destroy;
begin
  if Client <> nil then
    Release;
  inherited Destroy;
end;

procedure TMormotSocket.OnFrame(Sender: TWebSocketProcess;
  const Frame: TWebSocketFrame);
var
  e: TSpikeEvent;
  p: PAnsiChar;
begin
  e := Default(TSpikeEvent);
  case Frame.opcode of
    focContinuation:
      begin
        // ProcessStart's notification that the upgrade completed
        e.Kind := sekOpen;
        Push(e, false);
      end;
    focText:
      begin
        e.Kind := sekText;
        e.Data := Frame.payload;
        Push(e, true);
      end;
    focBinary:
      begin
        e.Kind := sekBinary;
        e.Data := Frame.payload;
        Push(e, true);
      end;
    focPing:
      InterlockedIncrement(PingsSeen);
    focPong:
      InterlockedIncrement(PongsSeen);
    focConnectionClose:
      if Length(Frame.payload) >= 2 then
      begin
        // the REAL close frame, delivered because NotifyAllFrames is on
        p := pointer(Frame.payload);
        PushClose((ord(p[0]) shl 8) or ord(p[1]), Copy(Frame.payload, 3, 123));
      end
      else
        // ProcessStop's synthetic empty frame with no real close before it:
        // the connection ended without a close handshake
        PushClose(1006, '');
  end;
end;

function TMormotSocket.Open(const Host: RawUtf8; APort: Integer; Tls: Boolean;
  const Target: RawUtf8; const Offered: array of RawUtf8;
  const Headers: RawUtf8; TimeoutMs: Integer; Stock: Boolean;
  out Error: RawUtf8): Boolean;
var
  i: Integer;
  names: RawUtf8;
begin
  Result := false;
  Error := '';
  Proto := nil;
  Client := THttpClientWebSockets.Create(TimeoutMs);
  try
    // Create + OpenBind consult no proxy; the TLS context is zeroed, so
    // certificate validation stays ON
    Client.TLS := Default(TNetTlsContext);
    Client.Settings^.NotifyAllFrames := true;
    Client.OpenBind(Host, RawUtf8(IntToStr(APort)), {doBind=}false, Tls);
    if Stock then
    begin
      names := '';
      for i := 0 to High(Offered) do
      begin
        if i > 0 then
          names := names + ', ';
        names := names + Offered[i];
      end;
      // mormot.defines.inc selects {$mode Delphi}: a method reference is
      // passed bare, never with @
      Proto := TWebSocketProtocolChat.Create(names, Target, OnFrame);
    end
    else
      Proto := TSpikeProtocol.CreateOffer(Target, Offered, OnFrame);
    Error := Client.WebSocketsUpgrade(Target, '', false, [], Proto, Headers);
    if Error <> '' then
    begin
      Proto := nil; // released by WebSocketsUpgrade on failure
      FreeAndNil(Client);
      exit;
    end;
    Result := true;
  except
    on E: Exception do
    begin
      Error := RawUtf8(E.ClassName + ': ' + E.Message);
      Proto := nil;
      FreeAndNil(Client);
    end;
  end;
end;

function TMormotSocket.Selected: RawUtf8;
begin
  Result := '';
  if (Client <> nil) and
     (Client.WebSockets <> nil) then
    if Client.WebSockets.Protocol is TSpikeProtocol then
      Result := TSpikeProtocol(Client.WebSockets.Protocol).Chosen
    else
      Result := Client.WebSockets.Protocol.Name;
end;

function TMormotSocket.SendData(Op: TWebSocketFrameOpCode;
  const Payload: RawByteString): Boolean;
var
  f: TWebSocketFrame;
begin
  Result := false;
  if (Client = nil) or
     (Client.WebSockets = nil) then
    exit;
  f.opcode := Op;
  f.content := [];
  f.tix := 0;
  f.payload := Payload;
  Result := TWebSocketProtocolChat(Client.WebSockets.Protocol).SendFrame(
    Client.WebSockets, f);
end;

function TMormotSocket.SendClose(Code: Integer; const Reason: RawUtf8): Boolean;
var
  f: TWebSocketFrame;
begin
  Result := false;
  if (Client = nil) or
     (Client.WebSockets = nil) then
    exit;
  f.opcode := focConnectionClose;
  f.content := [];
  f.tix := 0;
  f.payload := AnsiChar(Code shr 8) + AnsiChar(Code and 255) + Reason;
  Result := Client.WebSockets.SendFrame(f);
end;

function TMormotSocket.Release: Int64;
var
  t0: Int64;
begin
  t0 := GetTickCount64;
  MarkClosing;
  FreeAndNil(Client);
  Result := GetTickCount64 - t0;
end;

{ ---------------- TRawSocket ---------------- }

constructor TRawReader.CreateFor(AOwner: TRawSocket);
begin
  FOwner := AOwner;
  FreeOnTerminate := false;
  inherited Create(false);
end;

procedure TRawReader.Execute;
begin
  FOwner.ReaderLoop;
end;

constructor TRawSocket.Create(AMaxCount: Integer; AMaxBytes: Int64);
begin
  inherited Create(AMaxCount, AMaxBytes);
  InitCriticalSection(WriteLock);
end;

destructor TRawSocket.Destroy;
begin
  if (Sock <> nil) or
     (Reader <> nil) then
    Release;
  DoneCriticalSection(WriteLock);
  inherited Destroy;
end;

function TRawSocket.ReadExact(P: PAnsiChar; Len: PtrInt; DeadlineTix: Int64;
  out Err: RawUtf8): Boolean;
var
  pending, k: Integer;
begin
  Result := false;
  Err := '';
  while Len > 0 do
  begin
    if Closing then
    begin
      Err := 'closing';
      exit;
    end;
    if (DeadlineTix > 0) and
       (GetTickCount64 >= DeadlineTix) then
    begin
      Err := 'deadline';
      exit;
    end;
    // bounded wait for ANY input, then a read that cannot block: the slice
    // is what lets a closing flag and a wall-clock deadline be observed
    // DURING a transfer rather than only between messages
    pending := Sock.SockInPending(RAW_SLICE_MS);
    if pending < 0 then
    begin
      Err := 'socket_closed';
      exit;
    end;
    if pending = 0 then
      continue;
    k := pending;
    if k > Len then
      k := Len;
    k := Sock.SockInRead(P, k, {UseOnlySockIn=}true);
    if k <= 0 then
    begin
      Err := 'read_failed';
      exit;
    end;
    Inc(P, k);
    Dec(Len, k);
  end;
  Result := true;
end;

function TRawSocket.WriteFrame(Op: Byte; const Payload: RawByteString): Boolean;
var
  hdr: array[0..13] of Byte;
  mask: THash128;
  n, i, len: PtrInt;
  buf: RawByteString;
  src, dst: PByte;
begin
  Result := false;
  len := Length(Payload);
  hdr[0] := $80 or Op; // FIN: this client never fragments what it sends
  if len < 126 then
  begin
    hdr[1] := $80 or len;
    n := 2;
  end
  else if len < 65536 then
  begin
    hdr[1] := $80 or 126;
    hdr[2] := len shr 8;
    hdr[3] := len and 255;
    n := 4;
  end
  else
  begin
    hdr[1] := $80 or 127;
    for i := 0 to 7 do
      hdr[2 + i] := (Int64(len) shr ((7 - i) * 8)) and 255;
    n := 10;
  end;
  // RFC 6455 section 10.3: the masking key MUST be unpredictable, so it comes
  // from the AES-PRNG and never from a counter or a fast non-crypto source
  Random128(@mask);
  Move(mask, hdr[n], 4);
  Inc(n, 4);
  SetLength(buf, n + len);
  dst := pointer(buf);
  Move(hdr, dst^, n);
  src := pointer(Payload);
  for i := 0 to len - 1 do
    dst[n + i] := src[i] xor mask[i and 3];
  EnterCriticalSection(WriteLock);
  try
    if Sock <> nil then
      Result := Sock.TrySndLow(pointer(buf), Length(buf));
  finally
    LeaveCriticalSection(WriteLock);
  end;
end;

procedure TRawSocket.FailProtocol(Code: Integer; const Why: RawUtf8);
begin
  if not CloseSent then
  begin
    CloseSent := true;
    WriteFrame(8, AnsiChar(Code shr 8) + AnsiChar(Code and 255));
  end;
  PushClose(Code, Why);
end;

procedure TRawSocket.ReaderLoop;
var
  h: array[0..9] of Byte;
  fin, stop: Boolean;
  op, i, old: Integer;
  len: QWord;
  msg, ctl: RawByteString;
  msgOp: Integer;
  err: RawUtf8;
  e: TSpikeEvent;
begin
  msgOp := -1;
  msg := '';
  stop := false;
  try
    repeat
      if not ReadExact(@h[0], 2, 0, err) then
        break;
      fin := (h[0] and $80) <> 0;
      op := h[0] and $0f;
      // no extension was negotiated, so every RSV bit must be clear
      if (h[0] and $70) <> 0 then
      begin
        FailProtocol(1002, 'rsv');
        break;
      end;
      // RFC 6455 section 5.1: a server MUST NOT mask what it sends
      if (h[1] and $80) <> 0 then
      begin
        FailProtocol(1002, 'masked');
        break;
      end;
      len := h[1] and $7f;
      if len = 126 then
      begin
        if not ReadExact(@h[2], 2, 0, err) then
          break;
        len := (QWord(h[2]) shl 8) or h[3];
      end
      else if len = 127 then
      begin
        if not ReadExact(@h[2], 8, 0, err) then
          break;
        len := 0;
        for i := 2 to 9 do
          len := (len shl 8) or h[i];
        if (len shr 63) <> 0 then
        begin
          FailProtocol(1002, 'length');
          break;
        end;
      end;
      if op >= 8 then
      begin
        // control frames: never fragmented, at most 125 bytes, and PERMITTED
        // BETWEEN THE FRAGMENTS OF A DATA MESSAGE (RFC 6455 section 5.4)
        if (not fin) or
           (len > 125) then
        begin
          FailProtocol(1002, 'control');
          break;
        end;
        SetLength(ctl, len);
        if (len > 0) and
           not ReadExact(pointer(ctl), len, 0, err) then
          break;
        case op of
          9:
            begin
              InterlockedIncrement(PingsSeen);
              WriteFrame($A, ctl); // answered natively, never by the page
            end;
          $A:
            InterlockedIncrement(PongsSeen);
          8:
            begin
              if len = 1 then
              begin
                FailProtocol(1002, 'close');
                break;
              end;
              if not CloseSent then
              begin
                CloseSent := true;
                WriteFrame(8, Copy(ctl, 1, 2)); // echo the code
              end;
              if len >= 2 then
                PushClose((Byte(ctl[1]) shl 8) or Byte(ctl[2]),
                  Copy(ctl, 3, 123))
              else
                PushClose(1005, '');
              stop := true;
            end;
        else
          begin
            FailProtocol(1002, 'opcode');
            break;
          end;
        end;
        continue;
      end;
      case op of
        1, 2:
          if msgOp >= 0 then
          begin
            FailProtocol(1002, 'interleaved message');
            break;
          end
          else
            msgOp := op;
        0:
          if msgOp < 0 then
          begin
            FailProtocol(1002, 'orphan continuation');
            break;
          end;
      else
        begin
          FailProtocol(1002, 'opcode');
          break;
        end;
      end;
      // THE BOUND, on the frame HEADER, before one payload byte is read, and
      // against the REASSEMBLED total rather than the frame alone - which is
      // the whole of what the mORMot transport's reassembly could not do
      if (len > SPIKE_FRAME_MAX) or
         (QWord(Length(msg)) + len > SPIKE_FRAME_MAX) then
      begin
        FailProtocol(1009, 'message_too_big');
        break;
      end;
      old := Length(msg);
      SetLength(msg, old + Integer(len));
      if (len > 0) and
         not ReadExact(PAnsiChar(pointer(msg)) + old, len, 0, err) then
        break;
      if fin then
      begin
        if (msgOp = 1) and
           not IsValidUtf8(msg) then
        begin
          FailProtocol(1007, 'utf8');
          break;
        end;
        e := Default(TSpikeEvent);
        if msgOp = 1 then
          e.Kind := sekText
        else
          e.Kind := sekBinary;
        e.Data := msg;
        msg := '';
        msgOp := -1;
        Push(e, true); // may PARK this thread: backpressure
      end;
    until stop or Closing;
  except
    // a socket layer exception ends the connection; it never escapes a thread
  end;
  PushClose(1006, '');
end;

function TRawSocket.Open(const Host: RawUtf8; APort: Integer; Tls: Boolean;
  const Target: RawUtf8; const Offered: array of RawUtf8;
  const Headers: RawUtf8; TimeoutMs: Integer; Stock: Boolean;
  out Error: RawUtf8): Boolean;
var
  deadline: Int64;
  key: THash128;
  keyB64, expect, req, head, statusLine, line, name, value, proto, ext,
    offeredText, s: RawUtf8;
  sha: TSha1;
  digest: TSha1Digest;
  c: AnsiChar;
  i, start, colon: Integer;
  upgradeOk, connOk, acceptOk, known: Boolean;
  e: TSpikeEvent;
begin
  Result := false;
  Error := '';
  // THE HANDSHAKE DEADLINE IS WALL-CLOCK and owned here: every read below is
  // sliced against it, so a server that holds the 101 cannot hold the caller
  deadline := GetTickCount64 + TimeoutMs;
  try
    Sock := TCrtSocket.Create(TimeoutMs);
    Sock.TLS := Default(TNetTlsContext);
    Sock.OpenBind(Host, RawUtf8(IntToStr(APort)), {doBind=}false, Tls);
    Sock.CreateSockIn(tlbsCRLF, 65536);
    Random128(@key);
    keyB64 := BinToBase64(@key, SizeOf(key));
    offeredText := '';
    for i := 0 to High(Offered) do
    begin
      if i > 0 then
        offeredText := offeredText + ', ';
      offeredText := offeredText + Offered[i];
    end;
    req := 'GET ' + Target + ' HTTP/1.1'#13#10'Host: ' + Host;
    if (Tls and (APort <> 443)) or
       ((not Tls) and (APort <> 80)) then
      req := req + ':' + RawUtf8(IntToStr(APort));
    req := req + #13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
      'Sec-WebSocket-Key: ' + keyB64 + #13#10 +
      'Sec-WebSocket-Version: 13'#13#10'User-Agent: PWeb'#13#10;
    if offeredText <> '' then
      req := req + 'Sec-WebSocket-Protocol: ' + offeredText + #13#10;
    if Headers <> '' then
      req := req + Headers + #13#10;
    req := req + #13#10;
    Sock.SndLow(req);
    // the response head, one buffered byte at a time: a server may send its
    // first frame in the same packet as the 101, and those bytes must stay
    // in the socket buffer for the reader rather than be swallowed here
    head := '';
    repeat
      if not ReadExact(@c, 1, deadline, Error) then
      begin
        Error := 'handshake ' + Error;
        FreeAndNil(Sock);
        exit;
      end;
      head := head + c;
      if Length(head) > RAW_MAX_HEAD then
      begin
        Error := 'handshake head too large';
        FreeAndNil(Sock);
        exit;
      end;
    until (Length(head) >= 4) and
          (Copy(head, Length(head) - 3, 4) = #13#10#13#10);
    statusLine := '';
    upgradeOk := false;
    connOk := false;
    acceptOk := false;
    proto := '';
    ext := '';
    s := keyB64 + WS_GUID;
    sha.Full(pointer(s), Length(s), digest);
    expect := BinToBase64(@digest, SizeOf(digest));
    start := 1;
    for i := 1 to Length(head) - 1 do
      if (head[i] = #13) and
         (head[i + 1] = #10) then
      begin
        line := Copy(head, start, i - start);
        start := i + 2;
        if line = '' then
          continue;
        if statusLine = '' then
        begin
          statusLine := line;
          continue;
        end;
        colon := Pos(':', line);
        if colon = 0 then
          continue;
        name := AsciiLower(AsciiTrim(Copy(line, 1, colon - 1)));
        value := AsciiTrim(Copy(line, colon + 1, MaxInt));
        if name = 'upgrade' then
          upgradeOk := AsciiLower(value) = 'websocket'
        else if name = 'connection' then
          connOk := Pos('upgrade', AsciiLower(value)) > 0
        else if name = 'sec-websocket-accept' then
          acceptOk := value = expect
        else if name = 'sec-websocket-protocol' then
          proto := value
        else if name = 'sec-websocket-extensions' then
          ext := value;
      end;
    // anything but 101 is a refusal, and a 3xx is never followed
    if Copy(statusLine, 1, 12) <> 'HTTP/1.1 101' then
      Error := statusLine
    else if not upgradeOk then
      Error := 'Invalid Upgrade header'
    else if not connOk then
      Error := 'Invalid Connection header'
    else if not acceptOk then
      Error := 'Invalid Sec-WebSocket-Accept'
    else if ext <> '' then
      Error := 'Unrequested extension'
    else if proto <> '' then
    begin
      known := false;
      for i := 0 to High(Offered) do
        if Offered[i] = proto then
          known := true;
      if not known then
        Error := 'Subprotocol not offered';
    end
    else if Length(Offered) > 0 then
      Error := 'No subprotocol selected';
    if Error <> '' then
    begin
      FreeAndNil(Sock);
      exit;
    end;
    FSelected := proto;
    e := Default(TSpikeEvent);
    e.Kind := sekOpen;
    Push(e, false);
    Reader := TRawReader.CreateFor(self);
    Result := true;
  except
    on E: Exception do
    begin
      Error := RawUtf8(E.ClassName + ': ' + E.Message);
      FreeAndNil(Sock);
    end;
  end;
end;

function TRawSocket.SendData(Op: TWebSocketFrameOpCode;
  const Payload: RawByteString): Boolean;
begin
  Result := (Sock <> nil) and
            not CloseSent and
            WriteFrame(Ord(Op), Payload);
end;

function TRawSocket.SendClose(Code: Integer; const Reason: RawUtf8): Boolean;
begin
  Result := false;
  if (Sock = nil) or
     CloseSent then
    exit;
  CloseSent := true;
  Result := WriteFrame(8, AnsiChar(Code shr 8) + AnsiChar(Code and 255) +
    Reason);
end;

function TRawSocket.Release: Int64;
var
  t0: Int64;
begin
  t0 := GetTickCount64;
  MarkClosing;
  if Reader <> nil then
  begin
    Reader.WaitFor; // at most one read slice, or one parked queue wait
    FreeAndNil(Reader);
  end;
  if Sock <> nil then
  begin
    Sock.Close;
    FreeAndNil(Sock);
  end;
  Result := GetTickCount64 - t0;
end;

function TRawSocket.Selected: RawUtf8;
begin
  Result := FSelected;
end;

{ ---------------- helpers for the rows ---------------- }

function NewSock(ACount: Integer = SPIKE_QUEUE_COUNT;
  ABytes: Int64 = SPIKE_QUEUE_BYTES): TSpikeSocket;
begin
  Result := SocketClass.Create(ACount, ABytes);
end;

function WaitKind(S: TSpikeSocket; Kind: TSpikeEventKind; WaitMs: Integer;
  out E: TSpikeEvent): Boolean;
var
  deadline: Int64;
begin
  Result := false;
  deadline := GetTickCount64 + WaitMs;
  while GetTickCount64 < deadline do
    if S.Pop(E, 50) then
    begin
      if E.Kind = Kind then
        exit(true);
      if E.Kind = sekClose then
        exit(false);
    end;
end;

function CloseCodeOf(S: TSpikeSocket; WaitMs: Integer): Integer;
var
  e: TSpikeEvent;
begin
  if WaitKind(S, sekClose, WaitMs, e) or
     (e.Kind = sekClose) then
    Result := e.Code
  else
    Result := -1;
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

function Target(const Route, RowName: RawUtf8): RawUtf8;
begin
  if Pos('?', Route) > 0 then
    Result := Route + '&row=' + TagPrefix + RowName
  else
    Result := Route + '?row=' + TagPrefix + RowName;
end;

{ ---------------- the measurements ---------------- }

procedure RowsHandshakeAndEcho;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  t0: Int64;
  ok: Boolean;
  txt, bin, big: RawByteString;
begin
  s := NewSock;
  try
    t0 := GetTickCount64;
    ok := s.Open('127.0.0.1', Port, false, Target('/echo', 'handshake'),
      ['chat.v1', 'json.v2'],
      'Authorization: Bearer spike-token'#13#10'X-Spike-Row: handshake',
      5000, false, err);
    RowBool('hs_upgraded', ok);
    Row('hs_error', err);
    RowInt('hs_ms', GetTickCount64 - t0);
    if not ok then
      exit;
    Row('hs_selected_protocol', s.Selected);
    RowBool('hs_open_event', WaitKind(s, sekOpen, 2000, e));

    // text, carrying non-ASCII UTF-8 so a codepage mistake cannot hide
    txt := 'h'#$C3#$A9'llo w'#$C3#$B6'rld '#$E2#$9C#$93;
    RowBool('echo_text_sent', s.SendData(focText, txt));
    RowBool('echo_text_ok', WaitKind(s, sekText, 3000, e) and (e.Data = txt));

    bin := Pattern(256, 0);
    RowBool('echo_binary_sent', s.SendData(focBinary, bin));
    RowBool('echo_binary_ok', WaitKind(s, sekBinary, 3000, e) and
      (e.Data = bin));

    // 1 MiB both directions: client -> server -> client
    big := Pattern(SPIKE_FRAME_MAX, 11);
    t0 := GetTickCount64;
    RowBool('echo_1mib_sent', s.SendData(focBinary, big));
    ok := WaitKind(s, sekBinary, 10000, e);
    RowBool('echo_1mib_ok', ok and (Length(e.Data) = SPIKE_FRAME_MAX) and
      (Sha256(e.Data) = Sha256(big)));
    RowInt('echo_1mib_ms', GetTickCount64 - t0);

    // the page-facing close: a code and a reason on the wire, the server's
    // echo surfaced as an event
    RowBool('client_close_sent', s.SendClose(4000, 'done'));
    RowInt('client_close_echo_code', CloseCodeOf(s, 2000));
    RowInt('client_close_release_ms', s.Release);
  finally
    s.Free;
  end;
end;

procedure RowsSubprotocols;
var
  s: TSpikeSocket;
  err: RawUtf8;
  ok: Boolean;
begin
  if SocketClass = TMormotSocket then
  begin
    // mORMot's own comparison, offering two: can it accept either?
    s := NewSock;
    try
      ok := s.Open('127.0.0.1', Port, false, Target('/echo', 'stock_multi'),
        ['chat.v1', 'json.v2'], '', 5000, {stock=}true, err);
      RowBool('proto_stock_multi_upgraded', ok);
      Row('proto_stock_multi_error', err);
    finally
      s.Free;
    end;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/badproto', 'badproto'),
      ['chat.v1'], '', 5000, false, err);
    RowBool('proto_not_offered_upgraded', ok);
    Row('proto_not_offered_error', err);
  finally
    s.Free;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/noproto', 'noproto_one'),
      ['chat.v1'], '', 5000, false, err);
    RowBool('proto_none_selected_of_one_upgraded', ok);
    Row('proto_none_selected_of_one_error', err);
  finally
    s.Free;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/noproto', 'noproto_two'),
      ['chat.v1', 'json.v2'], '', 5000, false, err);
    RowBool('proto_none_selected_of_two_upgraded', ok);
    Row('proto_none_selected_of_two_error', err);
  finally
    s.Free;
  end;
end;

procedure RowsFragmentation;
var
  s: TSpikeSocket;
  err, shaText: RawUtf8;
  e: TSpikeEvent;
  textMsg, binMsg: RawByteString;
  events: Integer;
  ok: Boolean;
  code: Integer;

  procedure One(const RowName, Route: RawUtf8);
  begin
    s := NewSock;
    try
      textMsg := '';
      binMsg := '';
      shaText := '';
      events := 0;
      code := 0;
      ok := s.Open('127.0.0.1', Port, false, Target(Route, RowName), [], '',
        5000, false, err);
      RowBool(RowName + '_upgraded', ok);
      if not ok then
      begin
        Row(RowName + '_error', err);
        exit;
      end;
      while s.Pop(e, 3000) do
        case e.Kind of
          sekText:
            if Copy(e.Data, 1, 4) = 'sha:' then
            begin
              shaText := e.Data;
              break;
            end
            else
            begin
              textMsg := e.Data;
              Inc(events);
            end;
          sekBinary:
            begin
              binMsg := e.Data;
              Inc(events);
            end;
          sekClose:
            begin
              code := e.Code;
              break;
            end;
        end;
      RowInt(RowName + '_messages_before_sha', events);
      RowInt(RowName + '_text_bytes', Length(textMsg));
      RowInt(RowName + '_binary_bytes', Length(binMsg));
      RowBool(RowName + '_sha_received', shaText <> '');
      RowBool(RowName + '_text_sha_ok', (shaText <> '') and
        (Copy(shaText, 5, 64) = Sha256(textMsg)));
      RowBool(RowName + '_binary_sha_ok', (shaText <> '') and
        (Copy(shaText, 70, 64) = Sha256(binMsg)));
      RowInt(RowName + '_close_code', code);
      RowInt(RowName + '_pings_seen_natively', s.PingsSeen);
    finally
      s.Free;
    end;
  end;

begin
  One('fragment', '/fragment?size=100000&parts=7');
  // RFC 6455 section 5.4: "Control frames MAY be injected in the middle of a
  // fragmented message". A conformant client must survive this
  One('fragment_ping', '/fragment?size=100000&parts=7&ping=1');
end;

procedure RowsPingAndClose;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  ok: Boolean;
begin
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/ping', 'ping'), [], '',
      5000, false, err);
    RowBool('ping_upgraded', ok);
    if ok then
    begin
      ok := WaitKind(s, sekText, 3000, e);
      Row('ping_server_reply', e.Data);
      RowBool('ping_pong_answered_natively', ok and
        (Copy(e.Data, 1, 13) = 'pong:probe-1:'));
      RowInt('ping_frames_seen_natively', s.PingsSeen);
    end;
  finally
    s.Free;
  end;

  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false,
      Target('/close?code=4001&reason=bye', 'server_close'), [], '', 5000,
      false, err);
    RowBool('server_close_upgraded', ok);
    if ok then
    begin
      RowBool('server_close_hello', WaitKind(s, sekText, 3000, e) and
        (e.Data = 'hello'));
      ok := WaitKind(s, sekClose, 3000, e);
      RowInt('server_close_code', e.Code);
      Row('server_close_reason', e.Reason);
      RowBool('server_close_surfaced', ok and (e.Code = 4001) and
        (e.Reason = 'bye'));
      RowInt('server_close_release_ms', s.Release);
    end;
  finally
    s.Free;
  end;

  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/drop', 'drop'), [], '',
      5000, false, err);
    RowBool('drop_upgraded', ok);
    if ok then
      RowInt('drop_close_code', CloseCodeOf(s, 3000));
  finally
    s.Free;
  end;
end;

procedure RowsHandshakeRefusals;
var
  s: TSpikeSocket;
  err: RawUtf8;
  ok: Boolean;
  t0: Int64;
begin
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/redirect', 'redirect'),
      [], '', 5000, false, err);
    RowBool('redirect_upgraded', ok);
    Row('redirect_error', FirstLine(err));
  finally
    s.Free;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/notws', 'notws'), [], '',
      5000, false, err);
    RowBool('notws_upgraded', ok);
    Row('notws_error', FirstLine(err));
  finally
    s.Free;
  end;
  // a handshake the server holds for 5 s, against a 1 s bound
  s := NewSock;
  try
    t0 := GetTickCount64;
    ok := s.Open('127.0.0.1', Port, false, Target('/slow?ms=5000', 'slow'),
      [], '', 1000, false, err);
    RowBool('slow_handshake_upgraded', ok);
    Row('slow_handshake_error', FirstLine(err));
    RowInt('slow_handshake_ms_for_1000ms_timeout', GetTickCount64 - t0);
  finally
    s.Free;
  end;
  // a connect that never completes (RFC 5737 TEST-NET-1 is unroutable)
  s := NewSock;
  try
    t0 := GetTickCount64;
    ok := s.Open('192.0.2.1', 9, false, '/', [], '', 1000, false, err);
    RowBool('connect_unroutable_upgraded', ok);
    Row('connect_unroutable_error', FirstLine(err));
    RowInt('connect_unroutable_ms_for_1000ms_timeout', GetTickCount64 - t0);
  finally
    s.Free;
  end;
  // TLS validation: a self-signed loopback certificate MUST be refused
  if TlsPort > 0 then
  begin
    s := NewSock;
    try
      ok := s.Open('127.0.0.1', TlsPort, true, Target('/echo', 'tls_untrusted'),
        [], '', 5000, false, err);
      RowBool('tls_untrusted_upgraded', ok);
      Row('tls_untrusted_error', FirstLine(err));
    finally
      s.Free;
    end;
  end;
  // cookies: a Set-Cookie on one handshake, then a second handshake
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/setcookie', 'setcookie'),
      [], '', 5000, false, err);
    RowBool('setcookie_upgraded', ok);
  finally
    s.Free;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/echo', 'after_cookie'),
      [], '', 5000, false, err);
    RowBool('after_cookie_upgraded', ok);
  finally
    s.Free;
  end;
end;

procedure RowsFrameBound;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  ok: Boolean;
begin
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false,
      Target('/bigframe?size=1048576', 'bigframe_at_bound'), [], '', 5000,
      false, err);
    RowBool('bigframe_at_bound_upgraded', ok);
    if ok then
    begin
      ok := WaitKind(s, sekBinary, 5000, e);
      RowInt('bigframe_at_bound_bytes', Length(e.Data));
      RowBool('bigframe_at_bound_ok', ok and (Length(e.Data) = 1048576) and
        (e.Data = Pattern(1048576, 3)));
    end;
  finally
    s.Free;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false,
      Target('/bigframe?size=1048577', 'bigframe_over_bound'), [], '', 5000,
      false, err);
    RowBool('bigframe_over_bound_upgraded', ok);
    if ok then
    begin
      ok := WaitKind(s, sekBinary, 3000, e);
      RowBool('bigframe_over_bound_delivered', ok);
      if e.Kind = sekClose then
        RowInt('bigframe_over_bound_close_code', e.Code)
      else
        RowInt('bigframe_over_bound_close_code', CloseCodeOf(s, 2000));
    end;
  finally
    s.Free;
  end;
end;

procedure RowsBackpressure;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  ok, done: Boolean;
  expected, gaps, corrupt, got: Integer;
  seq: Cardinal;
  p: PByte;
  memBase, memPeakBase, t0: Int64;
begin
  s := NewSock;
  try
    memBase := MemNow;
    memPeakBase := MemPeak;
    ok := s.Open('127.0.0.1', Port, false,
      Target('/flood?count=1024&size=65536', 'flood'), [], '', 5000, false,
      err);
    RowBool('bp_upgraded', ok);
    if not ok then
      exit;
    WaitKind(s, sekOpen, 2000, e);
    // THE PAGE DOES NOT POLL for three seconds
    Sleep(3000);
    EnterCriticalSection(s.Lock);
    try
      RowInt('bp_stall_queue_count', s.Count);
      RowInt('bp_stall_queue_bytes', s.QBytes);
    finally
      LeaveCriticalSection(s.Lock);
    end;
    RowInt('bp_stall_peak_count', s.PeakCount);
    RowInt('bp_stall_peak_bytes', s.PeakBytes);
    RowInt('bp_stall_reader_parks', s.ParkCount);
    RowInt('bp_stall_mem_now_delta', MemNow - memBase);
    RowInt('bp_stall_mem_peak_delta', MemPeak - memPeakBase);
    // a send while the reader is parked must still reach the wire
    RowBool('bp_send_while_parked', s.SendData(focText, 'while-parked'));
    Sleep(300);
    // now drain, checking every sequence number and every fill byte
    expected := 0;
    gaps := 0;
    corrupt := 0;
    got := 0;
    done := false;
    t0 := GetTickCount64;
    while (not done) and
          (GetTickCount64 - t0 < 60000) do
      if s.Pop(e, 1000) then
        case e.Kind of
          sekBinary:
            begin
              p := pointer(e.Data);
              seq := (Cardinal(p[0]) shl 24) or (Cardinal(p[1]) shl 16) or
                     (Cardinal(p[2]) shl 8) or Cardinal(p[3]);
              if seq <> Cardinal(expected) then
                Inc(gaps);
              expected := seq + 1;
              if (Length(e.Data) <> 65536) or
                 (p[4] <> Byte(seq and 255)) or
                 (p[65535] <> Byte(seq and 255)) then
                Inc(corrupt);
              Inc(got);
            end;
          sekText:
            if Copy(e.Data, 1, 11) = 'flood-done:' then
              done := true;
          sekClose:
            break;
        end;
    RowInt('bp_received', got);
    RowInt('bp_gaps', gaps);
    RowInt('bp_corrupt', corrupt);
    RowBool('bp_done_marker', done);
    RowInt('bp_drain_ms', GetTickCount64 - t0);
    RowInt('bp_peak_count', s.PeakCount);
    RowInt('bp_peak_bytes', s.PeakBytes);
    RowInt('bp_reader_parked_ms', s.ParkedMs);
    RowInt('bp_mem_peak_delta', MemPeak - memPeakBase);
    RowInt('bp_release_ms', s.Release);
  finally
    s.Free;
  end;

  // a socket released WHILE its reader is parked on a full queue
  s := NewSock(4, SPIKE_QUEUE_BYTES);
  try
    ok := s.Open('127.0.0.1', Port, false,
      Target('/flood?count=256&size=65536', 'flood_release_parked'), [], '',
      5000, false, err);
    RowBool('bp_parked_release_upgraded', ok);
    if ok then
    begin
      Sleep(1000);
      RowInt('bp_parked_release_parks', s.ParkCount);
      RowInt('bp_parked_release_ms', s.Release);
      RowInt('bp_parked_release_discarded', s.DiscardedAtClose);
    end;
  finally
    s.Free;
  end;
end;

procedure RowsOutboundBackpressure;
var
  s: TSpikeSocket;
  err: RawUtf8;
  ok: Boolean;
  big: RawByteString;
  sent: Integer;
  t0, t1, last: Int64;
begin
  // the server stops READING: how much does a send accept, and how long does
  // the send that finally cannot complete hold its caller?
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/noread', 'noread'), [],
      '', 2000, false, err);
    RowBool('noread_upgraded', ok);
    if not ok then
      exit;
    big := Pattern(SPIKE_FRAME_MAX, 1);
    sent := 0;
    last := 0;
    t0 := GetTickCount64;
    while sent < 256 do
    begin
      t1 := GetTickCount64;
      ok := s.SendData(focBinary, big);
      last := GetTickCount64 - t1;
      if not ok then
        break;
      Inc(sent);
    end;
    RowInt('noread_mib_accepted_before_refusal', sent);
    RowBool('noread_send_refused', not ok);
    RowInt('noread_refused_send_ms_for_2000ms_timeout', last);
    RowInt('noread_total_ms', GetTickCount64 - t0);
    RowInt('noread_release_ms', s.Release);
  finally
    s.Free;
  end;
end;

procedure RowsIdleAndRelease;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  ok: Boolean;
  t0: Int64;
begin
  // the idle bound as a MECHANISM: the page polls once, then never again;
  // a watchdog closes with 1001 at the bound (1500 ms here)
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/idle', 'idle'), [], '',
      5000, false, err);
    RowBool('idle_upgraded', ok);
    if ok then
    begin
      s.Pop(e, 1000);
      t0 := s.LastPollTix;
      while GetTickCount64 - s.LastPollTix < 1500 do
        Sleep(10);
      RowBool('idle_close_sent', s.SendClose(1001, ''));
      RowInt('idle_close_after_ms', GetTickCount64 - t0);
      RowInt('idle_release_ms', s.Release);
    end;
  finally
    s.Free;
  end;

  // what a native close costs when the server never answers the CLOSE
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/noack', 'noack_explicit'),
      [], '', 5000, false, err);
    RowBool('noack_explicit_upgraded', ok);
    if ok then
    begin
      s.SendClose(1001, '');
      RowInt('noack_explicit_release_ms', s.Release);
    end;
  finally
    s.Free;
  end;
  s := NewSock;
  try
    ok := s.Open('127.0.0.1', Port, false, Target('/noack', 'noack_implicit'),
      [], '', 5000, false, err);
    RowBool('noack_implicit_upgraded', ok);
    if ok then
      RowInt('noack_implicit_release_ms', s.Release);
  finally
    s.Free;
  end;
end;

procedure RowsLatency;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  ok: Boolean;
  delays: array[0..2] of Integer = (500, 2000, 5000);
  i, at: Integer;
  t, sent: Int64;
begin
  for i := 0 to High(delays) do
  begin
    s := NewSock;
    try
      ok := s.Open('127.0.0.1', Port, false,
        Target('/delayed?ms=' + RawUtf8(IntToStr(delays[i])),
          'latency_' + RawUtf8(IntToStr(delays[i]))), [], '', 5000, false, err);
      if not ok then
        continue;
      if WaitKind(s, sekText, delays[i] + 5000, e) then
      begin
        t := UnixMSTimeUtcFast;
        // the server sends exactly {"t":<ms>} - read the digits, no parser
        at := Pos('"t":', e.Data);
        sent := StrToInt64Def(Copy(e.Data, at + 4,
          Length(e.Data) - at - 4), -1);
        RowInt('latency_after_' + RawUtf8(IntToStr(delays[i])) + 'ms_idle',
          t - sent);
      end;
    finally
      s.Free;
    end;
  end;
end;

procedure RowsContinuationFlood;
var
  s: TSpikeSocket;
  err: RawUtf8;
  e: TSpikeEvent;
  ok: Boolean;
  memPeakBase: Int64;
begin
  // ONE message of 64 MiB, sent as 4096 frames of 16 KiB. No single frame is
  // over the 1 MiB frame bound; the question is whether REASSEMBLY is bounded
  s := NewSock;
  try
    memPeakBase := MemPeak;
    ok := s.Open('127.0.0.1', Port, false,
      Target('/contflood?frames=4096&size=16384', 'contflood'), [], '', 5000,
      false, err);
    RowBool('contflood_upgraded', ok);
    if ok then
    begin
      ok := WaitKind(s, sekBinary, 30000, e);
      RowBool('contflood_delivered', ok);
      RowInt('contflood_delivered_bytes', Length(e.Data));
      if not ok then
        RowInt('contflood_close_code', e.Code);
      e.Data := '';
      RowInt('contflood_mem_peak_delta', MemPeak - memPeakBase);
    end;
  finally
    s.Free;
  end;
end;

procedure RowsPublic;
var
  s: TSpikeSocket;
  err, host, path, rest: RawUtf8;
  e: TSpikeEvent;
  ok, echoed: Boolean;
  slash: Integer;
  deadline: Int64;
begin
  if PublicUrl = '' then
  begin
    Row('public_wss', 'not_run');
    exit;
  end;
  Row('public_wss_url', PublicUrl);
  if Copy(PublicUrl, 1, 6) <> 'wss://' then
  begin
    Row('public_wss', 'bad_url');
    exit;
  end;
  rest := Copy(PublicUrl, 7, MaxInt);
  slash := Pos('/', rest);
  if slash = 0 then
  begin
    host := rest;
    path := '/';
  end
  else
  begin
    host := Copy(rest, 1, slash - 1);
    path := Copy(rest, slash, MaxInt);
  end;
  s := NewSock;
  try
    ok := s.Open(host, 443, true, path, [], '', 10000, false, err);
    RowBool('public_wss_upgraded', ok);
    Row('public_wss_error', FirstLine(err));
    if not ok then
      exit;
    s.SendData(focText, 'pweb-cap15c-observation');
    echoed := false;
    deadline := GetTickCount64 + 10000;
    while (not echoed) and
          (GetTickCount64 < deadline) do
      if s.Pop(e, 500) and
         (e.Kind = sekText) and
         (e.Data = 'pweb-cap15c-observation') then
        echoed := true;
    RowBool('public_wss_echoed', echoed);
    s.SendClose(1000, '');
    RowInt('public_wss_close_echo_code', CloseCodeOf(s, 3000));
  finally
    s.Free;
  end;
end;

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
    else if Copy(a, 1, 9) = '--public=' then
      PublicUrl := RawUtf8(Copy(a, 10, MaxInt))
    else if Copy(a, 1, 12) = '--transport=' then
      TransportName := RawUtf8(Copy(a, 13, 16));
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
  if Port <= 0 then
  begin
    WriteLn(StdErr, 'wsspike: --port=<n> is required');
    Halt(2);
  end;
  if TransportName = 'mormot' then
  begin
    SocketClass := TMormotSocket;
    RowPrefix := 'm.';
    TagPrefix := 'm_';
  end
  else if TransportName = 'raw' then
  begin
    SocketClass := TRawSocket;
    RowPrefix := 'r.';
    TagPrefix := 'r_';
  end
  else
  begin
    WriteLn(StdErr, 'wsspike: --transport=mormot|raw is required');
    Halt(2);
  end;
  // the mORMot frame bound, as mORMot exposes it: a PROCESS-WIDE global in MB
  // (the raw transport ignores it and enforces SPIKE_FRAME_MAX itself)
  WebSocketsMaxFrameMB := 1;
  Row('transport', TransportName);
  Row('mormot_frame_bound_global_mb', RawUtf8(IntToStr(WebSocketsMaxFrameMB)));
  RowsHandshakeAndEcho;
  RowsSubprotocols;
  RowsFragmentation;
  RowsPingAndClose;
  RowsHandshakeRefusals;
  RowsFrameBound;
  RowsBackpressure;
  RowsOutboundBackpressure;
  RowsIdleAndRelease;
  RowsLatency;
  RowsContinuationFlood;
  RowsPublic;
  WriteOut;
  WriteLn('[CAP-15C] spike complete (', TransportName, '): ', Length(Rows),
    ' rows');
end.
