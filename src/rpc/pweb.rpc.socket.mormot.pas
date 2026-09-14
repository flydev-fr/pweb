{
  pweb.rpc.socket.mormot - the Windows/Linux transport behind the CAP-15C
  socket seam.

  RFC 6455 - the handshake and the framing - written HERE, over
  `mormot.net.sock`'s TCrtSocket: the connect, the TLS (SChannel on Windows,
  `mormot.lib.openssl11` on Linux) and the absence of any proxy logic are
  mORMot's, and nothing above the socket is.

  ---------------------------------------------------------------------------
  WHY NOT mormot.net.ws.client
  ---------------------------------------------------------------------------

  It was measured first, against a server that is not mORMot, on both targets
  (cap15c-checkpoint1.md §1), and it fails the contract in two places nothing
  outside the library can reach:

    - its reassembly has NO TOTAL. WebSocketsMaxFrameMB bounds one frame; a
      64 MiB message sent as 16 KiB frames was delivered whole, and the
      process grew by 132 MiB. A flood exhausts memory.
    - a control frame BETWEEN TWO FRAGMENTS - which RFC 6455 §5.4 permits -
      kills the connection with 1006.

  It also ignores a handshake deadline (a 1000 ms bound, a 101 held 5 s,
  upgraded at 5000 ms), links `mormot.net.server` into the image, and
  publishes the platform, the library and the executable name in its
  User-Agent. The alternative below was measured on the same rows and is green
  on every one of them.

  ---------------------------------------------------------------------------
  ONE I/O THREAD PER SOCKET
  ---------------------------------------------------------------------------

  A TLS session is not safe to read and write from two threads: OpenSSL's
  SSL_read and SSL_write on one SSL object must not run concurrently, and
  mORMot's SChannel layer shares one context between DecryptMessage and
  EncryptMessage. So each connection has exactly one thread that touches its
  socket. Sends are JOBS handed to that thread; the page's worker waits for
  its job under a WALL-CLOCK deadline and, past it, shuts the socket down -
  which is the only thing that can stop mORMot's SChannel Send, a loop that
  spins until the whole record is out.

  The thread asks the decorator's Room before it reads a message's payload.
  While there is no room it stops READING, and carries on WRITING.

  ---------------------------------------------------------------------------
  WHAT IS ENFORCED WHERE THE BYTES ARRIVE
  ---------------------------------------------------------------------------

    - the message bound, on every frame HEADER, against the REASSEMBLED total,
      before one payload byte is read                          -> close 1009
    - a masked server frame, a reserved bit, a reserved opcode, a fragmented
      or oversized control frame, an orphan continuation       -> close 1002
    - invalid UTF-8 in a text message                          -> close 1007
    - a PING is answered here; the page never sees one, and cannot send one
    - fragments are reassembled here; the page never sees one

  TLS: certificate validation is ON and nothing - descriptor, environment,
  argument or Pascal - can turn it off: the TNetTlsContext is zeroed and this
  unit assigns nothing in it. No cookie is kept or sent: nothing here reads a
  Set-Cookie and the handshake carries only the allowlisted headers. A 3xx is
  answered psoHandshakeRedirect and never followed.
}
unit pweb.rpc.socket.mormot;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.crypt.core,
  mormot.net.sock,
  {$ifdef UNIX}
  // POSIX has NO TLS layer unless this unit is LINKED: its initialization
  // assigns NewNetTls and loads the system's libssl at first use. `UNIX`,
  // never mORMot's `OSPOSIX`, which no unit under src/ defines
  mormot.lib.openssl11,
  {$endif UNIX}
  pweb.rpc.intf,
  pweb.rpc.socket;

const
  /// what a server sees of the client, and the whole of it
  PWEB_SOCKET_USER_AGENT = 'PWeb';

/// the CAP-15C transport for Windows and Linux
// - the NAME is platform-neutral on purpose: the Darwin adapter exports the
// same one, and the two units are never on one compiled unit set
function PWebSocketNativeTransport: TPWebSocketTransport;

implementation

const
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  /// how often the I/O thread observes Stopping, a deadline or free room
  IO_SLICE_MS = 20;
  /// the OS-level send/receive timeout once the socket is upgraded: short,
  // so a blocking call returns to the loop rather than holding it
  IO_SOCKET_TIMEOUT_MS = 100;
  WRITE_CHUNK = 16384;
  READ_CHUNK = 65536;
  MAX_HEAD = 16384;
  CLOSE_FLUSH_MS = 1000;
  RELEASE_GRACE_MS = 300;

type
  { TCrtSocket with its raw layer reachable: every call below is made by ONE
    thread at a time, and none of them waits. }
  TWsSocket = class(TCrtSocket)
  public
    function RawSend(P: pointer; var Len: integer): TNetResult;
    function RawRecv(P: pointer; var Len: integer): TNetResult;
    function TlsPending: integer;
    function WaitIo(Ms: integer; Events: TNetEvents): TNetEvents;
    procedure ForceShutdown;
    procedure Forget;
    function GoAsync: Boolean;
  end;

  TWsJob = class
  public
    Data: RawByteString;
    Sent: PtrInt;
    Done: TEvent;
    Outcome: TPWebSocketOutcome;
    /// nobody waits: the I/O thread frees it once written or failed
    Detached: Boolean;
    Finished: Boolean;
    constructor Create(const AData: RawByteString; ADetached: Boolean);
    destructor Destroy; override;
  end;

  TWsParse = (wpNeedData, wpBlockedOnRoom, wpStop);
  TWsWrite = (wwIdle, wwProgress, wwBlocked, wwError);

  TWsConn = class;

  TWsIoThread = class(TThread)
  protected
    FConn: TWsConn;
    procedure Execute; override;
  public
    Ended: LongInt;
    constructor CreateFor(AConn: TWsConn);
  end;

  TWsConn = class
  public
    Sock: TWsSocket;
    Sink: TPWebSocketSink;
    Io: TWsIoThread;
    OutLock: TRTLCriticalSection;
    Jobs: array of TWsJob;
    Stopping: LongInt;
    Forced: LongInt;
    CloseSent: LongInt;
    ClosedReported: Boolean;
    MaxMessage: PtrInt;
    SendDeadlineMs: Integer;
    InBuf: RawByteString;
    InPos, InLen: PtrInt;
    MsgOp: Integer;
    Msg: RawByteString;
    constructor Create;
    destructor Destroy; override;
    procedure Enqueue(Job: TWsJob; Front: Boolean);
    function ServiceWrites: TWsWrite;
    procedure FailJobs(Outcome: TPWebSocketOutcome);
    procedure FlushWrites(Ms: Integer);
    function FillInput(WaitMs: Integer; Events: TNetEvents): Integer;
    function ProcessInput: TWsParse;
    procedure ReportClosed(Cause: TPWebSocketCloseCause; Code: Integer;
      const Reason: RawUtf8);
    function Fail(Code: Integer; Cause: TPWebSocketCloseCause): TWsParse;
    procedure IoLoop;
  end;

{ ---------------------------------------------------------------------------
  TWsSocket
  --------------------------------------------------------------------------- }

function TWsSocket.RawSend(P: pointer; var Len: integer): TNetResult;
begin
  if fSecure <> nil then
    Result := fSecure.Send(P, Len)
  else
    Result := fSock^.Send(P, Len);
end;

function TWsSocket.RawRecv(P: pointer; var Len: integer): TNetResult;
begin
  if fSecure <> nil then
    Result := fSecure.Receive(P, Len)
  else
    Result := fSock^.Recv(P, Len);
end;

function TWsSocket.TlsPending: integer;
begin
  if fSecure <> nil then
    Result := fSecure.ReceivePending
  else
    Result := 0;
end;

function TWsSocket.WaitIo(Ms: integer; Events: TNetEvents): TNetEvents;
begin
  Result := fSock^.WaitFor(Ms, Events);
end;

procedure TWsSocket.ForceShutdown;
begin
  // the one call that ends a send spinning inside the TLS layer
  fSock^.ShutdownAndClose({rdwr=}true);
end;

function TWsSocket.GoAsync: Boolean;
begin
  // NON-BLOCKING from here on: every send and receive - plaintext, OpenSSL or
  // SChannel - returns at once with data or nrRetry, and the ONLY waits are
  // WaitIo's explicit slices. MEASURED before this: OpenBind leaves the
  // socket blocking with a 10 s receive timeout, and one spurious readiness
  // parked the I/O thread in recv for exactly that long - every send after
  // the first reached the server 10 s late
  Result := fSock^.MakeAsync = nrOk;
end;

procedure TWsSocket.Forget;
begin
  // after a forced shutdown the handle is already closed: Destroy must not
  // close a number the operating system may have handed to someone else
  fSock := NO_SOCKET;
  fSecure := nil;
end;

{ ---------------------------------------------------------------------------
  helpers
  --------------------------------------------------------------------------- }

function AsciiLower(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A' .. 'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function AsciiTrim(const S: RawUtf8): RawUtf8;
var
  a, b: PtrInt;
begin
  a := 1;
  b := Length(S);
  while (a <= b) and (S[a] in [' ', #9]) do
    Inc(a);
  while (b >= a) and (S[b] in [' ', #9]) do
    Dec(b);
  Result := Copy(S, a, b - a + 1);
end;

function EncodeFrame(Op: Byte; const Payload: RawByteString): RawByteString;
var
  hdr: array[0 .. 13] of Byte;
  mask: THash128;
  n, i, len: PtrInt;
  src, dst: PByte;
begin
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
  // RFC 6455 §10.3: the masking key MUST be unpredictable - the AES-PRNG,
  // never a counter or a fast non-cryptographic source
  Random128(@mask);
  Move(mask, hdr[n], 4);
  Inc(n, 4);
  SetLength(Result, n + len);
  dst := pointer(Result);
  Move(hdr, dst^, n);
  src := pointer(Payload);
  for i := 0 to len - 1 do
    dst[n + i] := src[i] xor mask[i and 3];
end;

function CloseFrame(Code: Integer; const Reason: RawUtf8): RawByteString;
begin
  Result := EncodeFrame(8, AnsiChar(Code shr 8) + AnsiChar(Code and 255) +
    Reason);
end;

{ ---------------------------------------------------------------------------
  TWsJob / TWsIoThread
  --------------------------------------------------------------------------- }

constructor TWsJob.Create(const AData: RawByteString; ADetached: Boolean);
begin
  inherited Create;
  Data := AData;
  Detached := ADetached;
  Outcome := psoSendFailed;
  if not ADetached then
    Done := TEvent.Create(nil, True, False, '');
end;

destructor TWsJob.Destroy;
begin
  Done.Free;
  inherited Destroy;
end;

constructor TWsIoThread.CreateFor(AConn: TWsConn);
begin
  FConn := AConn;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TWsIoThread.Execute;
begin
  try
    FConn.IoLoop;
  except
    // a socket-layer exception ends this connection and never escapes a
    // thread; the loop has already reported what it could
  end;
  InterlockedExchange(Ended, 1);
end;

{ ---------------------------------------------------------------------------
  TWsConn
  --------------------------------------------------------------------------- }

constructor TWsConn.Create;
begin
  inherited Create;
  InitCriticalSection(OutLock);
  MsgOp := -1;
end;

destructor TWsConn.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Jobs) do
    Jobs[i].Free;
  Jobs := nil;
  Sock.Free;
  DoneCriticalSection(OutLock);
  inherited Destroy;
end;

procedure TWsConn.Enqueue(Job: TWsJob; Front: Boolean);
var
  i: Integer;
begin
  EnterCriticalSection(OutLock);
  try
    SetLength(Jobs, Length(Jobs) + 1);
    if Front and
       (Length(Jobs) > 1) then
    begin
      // never in front of a job already partly on the wire: a control frame
      // may sit BETWEEN messages, never inside one
      i := High(Jobs);
      while (i > 0) and
            not ((i = 1) and (Jobs[0].Sent > 0)) do
      begin
        Jobs[i] := Jobs[i - 1];
        Dec(i);
      end;
      Jobs[i] := Job;
    end
    else
      Jobs[High(Jobs)] := Job;
  finally
    LeaveCriticalSection(OutLock);
  end;
end;

procedure TWsConn.FailJobs(Outcome: TPWebSocketOutcome);
var
  i: Integer;
  pending: array of TWsJob;
begin
  EnterCriticalSection(OutLock);
  try
    pending := Jobs;
    Jobs := nil;
  finally
    LeaveCriticalSection(OutLock);
  end;
  for i := 0 to High(pending) do
    if pending[i].Detached then
      pending[i].Free
    else
    begin
      pending[i].Outcome := Outcome;
      pending[i].Finished := True;
      pending[i].Done.SetEvent;
    end;
end;

function TWsConn.ServiceWrites: TWsWrite;
var
  job: TWsJob;
  n, i: integer;
  res: TNetResult;
begin
  EnterCriticalSection(OutLock);
  try
    if Length(Jobs) = 0 then
      exit(wwIdle);
    job := Jobs[0];
  finally
    LeaveCriticalSection(OutLock);
  end;
  n := Length(job.Data) - job.Sent;
  if n > WRITE_CHUNK then
    n := WRITE_CHUNK;
  if n > 0 then
  begin
    res := Sock.RawSend(PAnsiChar(pointer(job.Data)) + job.Sent, n);
    case res of
      nrOk:
        Inc(job.Sent, n);
      nrRetry:
        exit(wwBlocked);
    else
      exit(wwError);
    end;
  end;
  if job.Sent < Length(job.Data) then
    exit(wwProgress);
  // the whole frame is on the wire
  EnterCriticalSection(OutLock);
  try
    for i := 1 to High(Jobs) do
      Jobs[i - 1] := Jobs[i];
    SetLength(Jobs, Length(Jobs) - 1);
  finally
    LeaveCriticalSection(OutLock);
  end;
  if job.Detached then
    job.Free
  else
  begin
    job.Outcome := psoOk;
    job.Finished := True;
    job.Done.SetEvent;
  end;
  Result := wwProgress;
end;

procedure TWsConn.FlushWrites(Ms: Integer);
var
  deadline: Int64;
begin
  deadline := GetTickCount64() + Ms;
  repeat
    case ServiceWrites of
      wwIdle, wwError:
        exit;
      wwBlocked:
        Sock.WaitIo(IO_SLICE_MS, [neWrite, neError]);
    end;
  until GetTickCount64() >= deadline;
end;

// -1 the connection ended, 0 nothing read, >0 bytes appended to InBuf
function TWsConn.FillInput(WaitMs: Integer; Events: TNetEvents): Integer;
var
  ev: TNetEvents;
  len: integer;
  res: TNetResult;
begin
  Result := 0;
  if Sock.TlsPending <= 0 then
  begin
    ev := Sock.WaitIo(WaitMs, Events);
    if neError in ev then
      exit(-1);
    if not (neRead in ev) then
    begin
      if neClosed in ev then
        exit(-1);
      exit(0);
    end;
  end;
  // compact what has been consumed, then make room for one read
  if InPos > 0 then
  begin
    if InPos < InLen then
      Move(PAnsiChar(pointer(InBuf))[InPos], pointer(InBuf)^, InLen - InPos);
    Dec(InLen, InPos);
    InPos := 0;
  end;
  if Length(InBuf) < InLen + READ_CHUNK then
    SetLength(InBuf, InLen + READ_CHUNK);
  len := READ_CHUNK;
  res := Sock.RawRecv(PAnsiChar(pointer(InBuf)) + InLen, len);
  case res of
    nrOk:
      if len <= 0 then
        Result := -1 // an orderly end of stream
      else
      begin
        Inc(InLen, len);
        Result := len;
      end;
    nrRetry:
      Result := 0; // an incomplete TLS record, or a spurious wake
  else
    Result := -1;
  end;
end;

procedure TWsConn.ReportClosed(Cause: TPWebSocketCloseCause; Code: Integer;
  const Reason: RawUtf8);
begin
  // never after Release began, and at most once
  if ClosedReported or
     (InterlockedCompareExchange(Stopping, 0, 0) <> 0) then
    exit;
  ClosedReported := True;
  try
    Sink.Closed(Cause, Code, Reason);
  except
  end;
end;

function TWsConn.Fail(Code: Integer; Cause: TPWebSocketCloseCause): TWsParse;
begin
  if InterlockedExchange(CloseSent, 1) = 0 then
  begin
    Enqueue(TWsJob.Create(CloseFrame(Code, ''), True), True);
    FlushWrites(CLOSE_FLUSH_MS);
  end;
  ReportClosed(Cause, Code, '');
  Result := wpStop;
end;

function TWsConn.ProcessInput: TWsParse;
var
  p: PByte;
  avail, hlen, i: PtrInt;
  len: QWord;
  fin: Boolean;
  op, code: Integer;
  ctl: RawByteString;
  reason: RawUtf8;
begin
  repeat
    avail := InLen - InPos;
    if avail < 2 then
      exit(wpNeedData);
    p := pointer(PAnsiChar(pointer(InBuf)) + InPos);
    fin := (p[0] and $80) <> 0;
    op := p[0] and $0f;
    // no extension was negotiated, so every reserved bit must be clear
    if (p[0] and $70) <> 0 then
      exit(Fail(1002, pscProtocolError));
    // RFC 6455 §5.1: a server MUST NOT mask what it sends
    if (p[1] and $80) <> 0 then
      exit(Fail(1002, pscProtocolError));
    len := p[1] and $7f;
    hlen := 2;
    if len = 126 then
    begin
      hlen := 4;
      if avail < hlen then
        exit(wpNeedData);
      len := (QWord(p[2]) shl 8) or p[3];
    end
    else if len = 127 then
    begin
      hlen := 10;
      if avail < hlen then
        exit(wpNeedData);
      len := 0;
      for i := 2 to 9 do
        len := (len shl 8) or p[i];
      if (len shr 63) <> 0 then
        exit(Fail(1002, pscProtocolError));
    end;
    if op >= 8 then
    begin
      // control frames: never fragmented, at most 125 bytes, and PERMITTED
      // between the fragments of a data message (RFC 6455 §5.4)
      if (not fin) or
         (len > 125) then
        exit(Fail(1002, pscProtocolError));
      if QWord(avail) < QWord(hlen) + len then
        exit(wpNeedData);
      SetString(ctl, PAnsiChar(p) + hlen, len);
      Inc(InPos, hlen + PtrInt(len));
      case op of
        9:
          // answered here; the page never sees a ping, and cannot send one
          Enqueue(TWsJob.Create(EncodeFrame($A, ctl), True), True);
        $A:
          ;
        8:
          begin
            if Length(ctl) = 1 then
              exit(Fail(1002, pscProtocolError));
            code := 1005;
            reason := '';
            if Length(ctl) >= 2 then
            begin
              code := (Byte(ctl[1]) shl 8) or Byte(ctl[2]);
              reason := Copy(ctl, 3, 123);
              if not IsValidUtf8(reason) then
                reason := '';
            end;
            if InterlockedExchange(CloseSent, 1) = 0 then
            begin
              // the echo of the peer's own code, as §5.5.1 asks
              Enqueue(TWsJob.Create(EncodeFrame(8, Copy(ctl, 1, 2)), True), True);
              FlushWrites(CLOSE_FLUSH_MS);
            end;
            ReportClosed(pscRemote, code, reason);
            exit(wpStop);
          end;
      else
        exit(Fail(1002, pscProtocolError));
      end;
      continue;
    end;
    case op of
      1, 2:
        if MsgOp >= 0 then
          exit(Fail(1002, pscProtocolError)) // a new message inside one
        else
          MsgOp := op;
      0:
        if MsgOp < 0 then
          exit(Fail(1002, pscProtocolError)); // a continuation of nothing
    else
      exit(Fail(1002, pscProtocolError));
    end;
    // THE BOUND, on the HEADER, against the REASSEMBLED total, before a byte
    // of this payload is read
    if (len > QWord(MaxMessage)) or
       (QWord(Length(Msg)) + len > QWord(MaxMessage)) then
      exit(Fail(1009, pscMessageTooLarge));
    // THE BACKPRESSURE: no room for this message, no more reading
    if not Sink.Room(Length(Msg) + PtrInt(len)) then
    begin
      if Length(Msg) = 0 then
        MsgOp := -1; // this header is parsed again when there is room
      exit(wpBlockedOnRoom);
    end;
    if QWord(avail) < QWord(hlen) + len then
    begin
      if Length(Msg) = 0 then
        MsgOp := -1;
      exit(wpNeedData);
    end;
    i := Length(Msg);
    SetLength(Msg, i + PtrInt(len));
    if len > 0 then
      Move((PAnsiChar(p) + hlen)^, PAnsiChar(pointer(Msg))[i], len);
    Inc(InPos, hlen + PtrInt(len));
    if fin then
    begin
      if (MsgOp = 1) and
         not IsValidUtf8(Msg) then
        exit(Fail(1007, pscProtocolError));
      try
        Sink.Deliver(MsgOp = 2, Msg);
      except
      end;
      Msg := '';
      MsgOp := -1;
    end;
  until False;
end;

procedure TWsConn.IoLoop;
var
  w: TWsWrite;
  st: TWsParse;
  n: Integer;
  events: TNetEvents;
begin
  while InterlockedCompareExchange(Stopping, 0, 0) = 0 do
  begin
    w := ServiceWrites;
    if w = wwError then
    begin
      ReportClosed(pscAbnormal, 1006, '');
      break;
    end;
    st := ProcessInput;
    if st = wpStop then
      break;
    if st = wpNeedData then
    begin
      events := [neRead, neError];
      if w = wwBlocked then
        Include(events, neWrite);
      if w = wwProgress then
        n := FillInput(0, events)
      else
        n := FillInput(IO_SLICE_MS, events);
      if n < 0 then
      begin
        ReportClosed(pscAbnormal, 1006, '');
        break;
      end;
    end
    else if w = wwBlocked then
      Sock.WaitIo(IO_SLICE_MS, [neWrite, neError])
    else if w <> wwProgress then
      SleepHiRes(IO_SLICE_MS);
  end;
  // RELEASE ASKED US TO STOP: what is already queued - the 1001 a native
  // close owes the peer - still reaches the wire, within a bound. MEASURED:
  // without this, idle, revocation, navigation and shutdown all released the
  // socket with the close frame still in the queue
  if InterlockedCompareExchange(Stopping, 0, 0) <> 0 then
    FlushWrites(RELEASE_GRACE_MS - 50);
  FailJobs(psoClosed);
end;

{ ---------------------------------------------------------------------------
  the seam
  --------------------------------------------------------------------------- }

// the handshake's write, on the caller's thread, before any I/O thread exists
function WriteAll(S: TWsSocket; const Data: RawByteString;
  Deadline: Int64): TPWebSocketOutcome;
var
  sent, n: integer;
  res: TNetResult;
begin
  sent := 0;
  while sent < Length(Data) do
  begin
    if GetTickCount64() >= Deadline then
      exit(psoDeadline);
    n := Length(Data) - sent;
    res := S.RawSend(PAnsiChar(pointer(Data)) + sent, n);
    case res of
      nrOk:
        Inc(sent, n);
      nrRetry:
        S.WaitIo(IO_SLICE_MS, [neWrite, neError]);
    else
      exit(psoConnectFailed);
    end;
  end;
  Result := psoOk;
end;

function WsOpen(const Request: TPWebSocketRequest;
  const Sink: TPWebSocketSink; const Token: ICancellationToken;
  out Handle: Pointer; out Selected: RawUtf8): TPWebSocketOutcome;
var
  conn: TWsConn;
  deadline: Int64;
  key: THash128;
  keyB64, expect, req, head, statusLine, line, name, value, proto, ext,
    offered, s: RawUtf8;
  sha: TSha1;
  digest: TSha1Digest;
  i, start, colon, headEnd, n: PtrInt;
  upgradeOk, connOk, acceptOk, known: Boolean;
begin
  Handle := nil;
  Selected := '';
  // THE HANDSHAKE DEADLINE IS WALL-CLOCK: every read and write below is
  // sliced against it, so a server holding the 101 cannot hold the caller
  deadline := GetTickCount64() + Request.ConnectDeadlineMs;
  conn := TWsConn.Create;
  try
    conn.Sock := TWsSocket.Create(Request.ConnectDeadlineMs);
    // certificate validation stays ON: the context is zeroed, and the ONE
    // field assigned is the name the certificate must carry. MEASURED on
    // Linux: OpenSSL checks the chain but checks a NAME only when mORMot is
    // handed one (SSL_set1_host), so a zeroed context accepted a trusted
    // certificate issued for another host. SChannel checks the target name
    // it is given regardless; on UNIX this line is the check
    conn.Sock.TLS := Default(TNetTlsContext);
    conn.Sock.TLS.HostNamesCsv := Request.Host;
    try
      conn.Sock.OpenBind(Request.Host, RawUtf8(IntToStr(Request.Port)),
        {doBind=}false, Request.Tls);
    except
      on E: Exception do
      begin
        if GetTickCount64() >= deadline then
          Result := psoDeadline
        else if Pos('TLS', E.Message) > 0 then
          Result := psoTlsFailed
        else
          Result := psoConnectFailed;
        conn.Free;
        exit;
      end;
    end;
    if (Token <> nil) and
       Token.IsCancelled then
    begin
      conn.Free;
      exit(psoCancelled);
    end;
    if not conn.Sock.GoAsync then
    begin
      conn.Free;
      exit(psoConnectFailed);
    end;

    Random128(@key);
    keyB64 := BinToBase64(@key, SizeOf(key));
    offered := '';
    for i := 0 to High(Request.Protocols) do
    begin
      if i > 0 then
        offered := offered + ', ';
      offered := offered + Request.Protocols[i];
    end;
    req := 'GET ' + Request.Target + ' HTTP/1.1'#13#10'Host: ' + Request.Host;
    if (Request.Tls and (Request.Port <> 443)) or
       ((not Request.Tls) and (Request.Port <> 80)) then
      req := req + ':' + RawUtf8(IntToStr(Request.Port));
    req := req + #13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
      'Sec-WebSocket-Key: ' + keyB64 + #13#10 +
      'Sec-WebSocket-Version: 13'#13#10 +
      'User-Agent: ' + PWEB_SOCKET_USER_AGENT + #13#10;
    if offered <> '' then
      req := req + 'Sec-WebSocket-Protocol: ' + offered + #13#10;
    // the decorator's allowlisted block, already CRLF-terminated
    req := req + Request.Headers + #13#10;
    Result := WriteAll(conn.Sock, req, deadline);
    if Result <> psoOk then
    begin
      conn.Free;
      exit;
    end;

    // the response head; bytes after it stay in InBuf for the frame parser,
    // because a server may send its first frame in the packet of its 101
    headEnd := 0;
    repeat
      for i := 4 to conn.InLen do
        if (conn.InBuf[i - 3] = #13) and (conn.InBuf[i - 2] = #10) and
           (conn.InBuf[i - 1] = #13) and (conn.InBuf[i] = #10) then
        begin
          headEnd := i;
          break;
        end;
      if headEnd > 0 then
        break;
      if conn.InLen > MAX_HEAD then
      begin
        conn.Free;
        exit(psoHandshakeStatus);
      end;
      if GetTickCount64() >= deadline then
      begin
        conn.Free;
        exit(psoDeadline);
      end;
      if (Token <> nil) and
         Token.IsCancelled then
      begin
        conn.Free;
        exit(psoCancelled);
      end;
      n := conn.FillInput(IO_SLICE_MS, [neRead, neError]);
      if n < 0 then
      begin
        conn.Free;
        exit(psoConnectFailed);
      end;
    until False;
    SetString(head, PAnsiChar(pointer(conn.InBuf)), headEnd);
    conn.InPos := headEnd;

    statusLine := '';
    upgradeOk := False;
    connOk := False;
    acceptOk := False;
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
        // Set-Cookie is not read: there is nothing here to keep one in
      end;
    if Copy(statusLine, 1, 12) <> 'HTTP/1.1 101' then
    begin
      // anything but 101 is a refusal, and a 3xx is NEVER followed
      if (Length(statusLine) >= 10) and
         (Copy(statusLine, 1, 5) = 'HTTP/') and
         (statusLine[10] = '3') then
        Result := psoHandshakeRedirect
      else
        Result := psoHandshakeStatus;
      conn.Free;
      exit;
    end;
    if not upgradeOk or
       not connOk or
       not acceptOk or
       (ext <> '') then
    begin
      conn.Free;
      exit(psoHandshakeUpgrade);
    end;
    if proto <> '' then
    begin
      known := False;
      for i := 0 to High(Request.Protocols) do
        if Request.Protocols[i] = proto then
          known := True;
      if not known then
      begin
        conn.Free;
        exit(psoHandshakeSubprotocol);
      end;
    end
    else if Length(Request.Protocols) > 0 then
    begin
      // offered, and none selected: refused, as a browser refuses it
      conn.Free;
      exit(psoHandshakeSubprotocol);
    end;

    conn.Sink := Sink;
    conn.MaxMessage := Request.MaxMessage;
    conn.SendDeadlineMs := Request.SendDeadlineMs;
    conn.Io := TWsIoThread.CreateFor(conn);
    Handle := conn;
    Selected := proto;
    Result := psoOk;
  except
    conn.Free;
    Result := psoConnectFailed;
  end;
end;

function WsSend(Handle: Pointer; Binary: Boolean;
  const Payload: RawByteString): TPWebSocketOutcome;
var
  conn: TWsConn;
  job: TWsJob;
  deadline: Int64;
  op: Byte;
begin
  conn := TWsConn(Handle);
  if (InterlockedCompareExchange(conn.CloseSent, 0, 0) <> 0) or
     (InterlockedCompareExchange(conn.Io.Ended, 0, 0) <> 0) then
    exit(psoClosed);
  if Binary then
    op := 2
  else
    op := 1;
  job := TWsJob.Create(EncodeFrame(op, Payload), False);
  deadline := GetTickCount64() + conn.SendDeadlineMs;
  conn.Enqueue(job, False);
  repeat
    // the flag, not only the signal: MEASURED on Windows, a waiter that
    // trusted the event alone saw its 1 MiB job finish only at the deadline
    // check, 10 000 ms after the bytes had reached the server
    job.Done.WaitFor(IO_SLICE_MS);
    if job.Finished then
    begin
      Result := job.Outcome;
      job.Free;
      exit;
    end;
    if InterlockedCompareExchange(conn.Io.Ended, 0, 0) <> 0 then
      break;
  until GetTickCount64() >= deadline;
  // THE SEND DEADLINE IS WALL-CLOCK. Past it, the frame may be half on the
  // wire, so the connection is unusable: the socket is shut down, which ends
  // a send spinning inside the TLS layer, and the I/O thread fails the job
  EnterCriticalSection(conn.OutLock);
  try
    if job.Finished then
    begin
      Result := job.Outcome;
      job.Free;
      exit;
    end;
    job.Detached := True; // the I/O thread frees it now
  finally
    LeaveCriticalSection(conn.OutLock);
  end;
  if InterlockedExchange(conn.Forced, 1) = 0 then
    conn.Sock.ForceShutdown;
  if GetTickCount64() >= deadline then
    Result := psoDeadline
  else
    Result := psoSendFailed;
end;

procedure WsClose(Handle: Pointer; Code: Integer; const Reason: RawUtf8);
var
  conn: TWsConn;
begin
  conn := TWsConn(Handle);
  if InterlockedExchange(conn.CloseSent, 1) <> 0 then
    exit;
  // sent, never waited for: the peer's echo comes back through the reader
  conn.Enqueue(TWsJob.Create(CloseFrame(Code, Reason), True), True);
end;

procedure WsRelease(Handle: Pointer);
var
  conn: TWsConn;
  waited: Integer;
begin
  conn := TWsConn(Handle);
  InterlockedExchange(conn.Stopping, 1);
  waited := 0;
  // a close frame queued just before this call gets one grace period to
  // reach the wire; a thread stuck in a send gets its socket shut down
  while (InterlockedCompareExchange(conn.Io.Ended, 0, 0) = 0) and
        (waited < RELEASE_GRACE_MS) do
  begin
    SleepHiRes(5);
    Inc(waited, 5);
  end;
  if (InterlockedCompareExchange(conn.Io.Ended, 0, 0) = 0) and
     (InterlockedExchange(conn.Forced, 1) = 0) then
    conn.Sock.ForceShutdown;
  conn.Io.WaitFor;
  FreeAndNil(conn.Io);
  conn.FailJobs(psoClosed);
  if InterlockedCompareExchange(conn.Forced, 0, 0) <> 0 then
    conn.Sock.Forget;
  conn.Free;
end;

function PWebSocketNativeTransport: TPWebSocketTransport;
begin
  Result.Open := @WsOpen;
  Result.Send := @WsSend;
  Result.Close := @WsClose;
  Result.Release := @WsRelease;
end;

end.
