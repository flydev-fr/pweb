{
  pweb.platform.cocoa.socket - the Darwin transport behind the CAP-15C socket
  seam.

  PWebSocketNativeTransport over NSURLSessionWebSocketTask, for the reason
  pweb.platform.cocoa.fetch exists: macOS ships no libssl in a default
  install, and CAP-15A refused both bundling one and scoping macOS out. The
  Objective-C++ half is in pweb_cocoa_bridge.mm; this unit is the Pascal side
  of the seam and decides nothing.

  The URL, the origin, the header and subprotocol allowlists, every bound and
  the page's event queue belong to src/rpc/pweb.rpc.socket.pas. This unit
  hands the C side three callbacks into that queue - ROOM, DELIVER, CLOSED -
  over an opaque pointer to a Pascal object that outlives every call the C
  side can make: pweb_cocoa_socket_release promises that no callback begins
  after it returns, and the object is freed only then.

  It names NO `mormot.net.*` unit: on Darwin pweb.rpc.socket.mormot is not on
  the compiled unit set at all.

  WHAT IS STILL A MEASUREMENT here and not a claim: whether the framework
  stops reading the socket while no receive is armed. The receive is re-armed
  only when ROOM says yes; the Darwin leg of test/cap15c measures whether the
  server's writes then block, exactly as it does for the mORMot transport.
}
unit pweb.platform.cocoa.socket;

{$mode ObjFPC}{$H+}
{ Every record below crosses the private C seam. }
{$PACKRECORDS C}

{$ifndef DARWIN}
  {$MESSAGE Error 'pweb.platform.cocoa.socket is the macOS socket transport'}
{$endif DARWIN}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.rpc.intf,
  pweb.rpc.socket;

type
  /// the Darwin leg's evidence rows, read back from the task and its
  // configuration - never a decision
  TPWebCocoaSocketFacts = record
    Opens: LongInt;
    RedirectsOffered: LongInt;
    ProxyDictEmpty: LongInt;
    CookieStorageNil: LongInt;
    ShouldSetCookies: LongInt;
    OpenOnMainThread: LongInt;
    MaximumMessageSize: Int64;
  end;

/// the CAP-15C transport for Darwin - the same name the mORMot transport
// exports, so the generated program names one transport and no conditional
function PWebSocketNativeTransport: TPWebSocketTransport;

/// what the configuration and the task actually carried
function PWebCocoaSocketFacts: TPWebCocoaSocketFacts;

implementation

type
  TPWebCocoaSocketRequest = record
    Url: PAnsiChar;
    Headers: PAnsiChar;
    Protocols: PAnsiChar;
    ConnectDeadlineMs: Int64;
    SendDeadlineMs: Int64;
    MaxMessage: Int64;
  end;
  PPWebCocoaSocketRequest = ^TPWebCocoaSocketRequest;

  TPWebCocoaRoomFn = function(Opaque: Pointer; Size: Int64): LongInt; cdecl;
  TPWebCocoaDeliverFn = procedure(Opaque: Pointer; Binary: LongInt;
    Data: Pointer; Length: Int64); cdecl;
  TPWebCocoaClosedFn = procedure(Opaque: Pointer; Cause, Code: LongInt;
    Reason: PAnsiChar); cdecl;
  TPWebCocoaCancelFn = function(Opaque: Pointer): LongInt; cdecl;

  TPWebCocoaSocketSink = record
    Room: TPWebCocoaRoomFn;
    Deliver: TPWebCocoaDeliverFn;
    Closed: TPWebCocoaClosedFn;
    Opaque: Pointer;
  end;
  PPWebCocoaSocketSink = ^TPWebCocoaSocketSink;

  PTPWebCocoaSocketFacts = ^TPWebCocoaSocketFacts;

  { the Pascal half of one socket: the decorator's sink, and the C handle }
  TPWebCocoaSocketConn = class
  public
    Sink: TPWebSocketSink;
    Handle: QWord;
  end;

  TPWebCocoaCancelContext = record
    Token: ICancellationToken;
  end;
  PPWebCocoaCancelContext = ^TPWebCocoaCancelContext;

function pweb_cocoa_socket_open(request: PPWebCocoaSocketRequest;
  sink: PPWebCocoaSocketSink; cancel: TPWebCocoaCancelFn;
  cancel_opaque: Pointer; handle: PQWord; selected: PAnsiChar;
  selected_capacity: LongInt): LongInt; cdecl;
  external name 'pweb_cocoa_socket_open';
function pweb_cocoa_socket_send(handle: QWord; binary: LongInt;
  data: Pointer; length: Int64): LongInt; cdecl;
  external name 'pweb_cocoa_socket_send';
procedure pweb_cocoa_socket_close(handle: QWord; code: LongInt;
  reason: PAnsiChar); cdecl; external name 'pweb_cocoa_socket_close';
procedure pweb_cocoa_socket_release(handle: QWord); cdecl;
  external name 'pweb_cocoa_socket_release';
procedure pweb_cocoa_socket_facts(out_: PTPWebCocoaSocketFacts); cdecl;
  external name 'pweb_cocoa_socket_facts';

{ ---- the callbacks: no Pascal exception may leave any of them ---- }

function CocoaRoom(Opaque: Pointer; Size: Int64): LongInt; cdecl;
begin
  Result := 1;
  try
    if not TPWebCocoaSocketConn(Opaque).Sink.Room(Size) then
      Result := 0;
  except
    Result := 1; // a sink that raised cannot be asked again; do not wedge
  end;
end;

procedure CocoaDeliver(Opaque: Pointer; Binary: LongInt; Data: Pointer;
  Length: Int64); cdecl;
var
  payload: RawByteString;
begin
  try
    SetString(payload, PAnsiChar(Data), Length);
    TPWebCocoaSocketConn(Opaque).Sink.Deliver(Binary <> 0, payload);
  except
  end;
end;

procedure CocoaClosed(Opaque: Pointer; Cause, Code: LongInt;
  Reason: PAnsiChar); cdecl;
var
  reasonText: RawUtf8;
  c: TPWebSocketCloseCause;
begin
  try
    if (Cause < Ord(Low(TPWebSocketCloseCause))) or
       (Cause > Ord(High(TPWebSocketCloseCause))) then
      c := pscAbnormal
    else
      c := TPWebSocketCloseCause(Cause);
    reasonText := '';
    if Reason <> nil then
      FastSetString(reasonText, Reason, StrLen(Reason));
    TPWebCocoaSocketConn(Opaque).Sink.Closed(c, Code, reasonText);
  except
  end;
end;

function CocoaCancelled(Opaque: Pointer): LongInt; cdecl;
var
  ctx: PPWebCocoaCancelContext;
begin
  Result := 0;
  ctx := PPWebCocoaCancelContext(Opaque);
  try
    if (ctx <> nil) and
       (ctx^.Token <> nil) and
       ctx^.Token.IsCancelled then
      Result := 1;
  except
    Result := 0;
  end;
end;

function MapOutcome(Code: LongInt): TPWebSocketOutcome;
begin
  if (Code < Ord(Low(TPWebSocketOutcome))) or
     (Code > Ord(High(TPWebSocketOutcome))) then
    Result := psoConnectFailed
  else
    Result := TPWebSocketOutcome(Code);
end;

{ ---- the seam ---- }

function CocoaOpen(const Request: TPWebSocketRequest;
  const Sink: TPWebSocketSink; const Token: ICancellationToken;
  out Handle: Pointer; out Selected: RawUtf8): TPWebSocketOutcome;
var
  conn: TPWebCocoaSocketConn;
  req: TPWebCocoaSocketRequest;
  csink: TPWebCocoaSocketSink;
  ctx: TPWebCocoaCancelContext;
  url, headers, protocols: RawUtf8;
  chosen: array[0 .. 255] of AnsiChar;
  h: QWord;
  i: Integer;
begin
  Handle := nil;
  Selected := '';
  if (Token <> nil) and
     Token.IsCancelled then
    exit(psoCancelled);
  url := Request.Url;
  headers := Request.Headers;
  protocols := '';
  for i := 0 to High(Request.Protocols) do
  begin
    if i > 0 then
      protocols := protocols + ', ';
    protocols := protocols + Request.Protocols[i];
  end;
  conn := TPWebCocoaSocketConn.Create;
  conn.Sink := Sink;
  req := Default(TPWebCocoaSocketRequest);
  req.Url := PAnsiChar(url);
  if headers <> '' then
    req.Headers := PAnsiChar(headers);
  if protocols <> '' then
    req.Protocols := PAnsiChar(protocols);
  req.ConnectDeadlineMs := Request.ConnectDeadlineMs;
  req.SendDeadlineMs := Request.SendDeadlineMs;
  req.MaxMessage := Request.MaxMessage;
  csink.Room := @CocoaRoom;
  csink.Deliver := @CocoaDeliver;
  csink.Closed := @CocoaClosed;
  csink.Opaque := conn;
  ctx.Token := Token;
  h := 0;
  chosen[0] := #0;
  try
    Result := MapOutcome(pweb_cocoa_socket_open(@req, @csink, @CocoaCancelled,
      @ctx, @h, @chosen[0], SizeOf(chosen)));
  except
    Result := psoConnectFailed;
  end;
  if (Result <> psoOk) or
     (h = 0) then
  begin
    conn.Free;
    if Result = psoOk then
      Result := psoConnectFailed;
    exit;
  end;
  conn.Handle := h;
  FastSetString(Selected, @chosen[0], StrLen(@chosen[0]));
  Handle := conn;
end;

function CocoaSend(Handle: Pointer; Binary: Boolean;
  const Payload: RawByteString): TPWebSocketOutcome;
var
  b: LongInt;
begin
  if Binary then
    b := 1
  else
    b := 0;
  try
    Result := MapOutcome(pweb_cocoa_socket_send(
      TPWebCocoaSocketConn(Handle).Handle, b, pointer(Payload),
      Length(Payload)));
  except
    Result := psoSendFailed;
  end;
end;

procedure CocoaClose(Handle: Pointer; Code: Integer; const Reason: RawUtf8);
begin
  try
    pweb_cocoa_socket_close(TPWebCocoaSocketConn(Handle).Handle, Code,
      PAnsiChar(Reason));
  except
  end;
end;

procedure CocoaRelease(Handle: Pointer);
begin
  try
    pweb_cocoa_socket_release(TPWebCocoaSocketConn(Handle).Handle);
  except
  end;
  // freed only now: the C side promised no callback begins after release
  TPWebCocoaSocketConn(Handle).Free;
end;

function PWebSocketNativeTransport: TPWebSocketTransport;
begin
  Result.Open := @CocoaOpen;
  Result.Send := @CocoaSend;
  Result.Close := @CocoaClose;
  Result.Release := @CocoaRelease;
end;

function PWebCocoaSocketFacts: TPWebCocoaSocketFacts;
begin
  Result := Default(TPWebCocoaSocketFacts);
  pweb_cocoa_socket_facts(@Result);
end;


{ THE FPU TRAPS, masked by the unit that decides to run NSURLSession's
  WebSocket code in this process. MEASURED on macos-x64 of hosted run
  34941125057: with the traps live, a program that linked this adapter and
  not pweb.platform.cocoa died with `EInvalidOp: Invalid floating point
  operation` raised inside a system framework, after the transport had
  already opened, echoed and refused correctly. FPC leaves the FPU trapping
  on exceptional results; Apple's frameworks compute through them legally.

  pweb.platform.cocoa masks them in its initialization because linking that
  unit IS the decision to host WebKit; linking THIS unit is the decision to
  run the socket transport, so it calls the same bridge entry point -
  fesetenv(FE_DFL_ENV), which knows the register on both x86_64 and aarch64 -
  rather than relying on another unit having been linked. It is idempotent,
  so a host that links both adapters masks twice and loses nothing. Never
  math.SetExceptionMask, for the reason pweb.platform.cocoa records: math's
  finalization restores the traps under units that finalise later.

  Recorded rather than raised: a unit initialization that raises takes the
  process down with a message nobody can attribute. }
var
  PWebCocoaSocketFpuMasked: Boolean = False;

function pweb_cocoa_mask_fpu_traps: LongInt; cdecl;
  external name 'pweb_cocoa_mask_fpu_traps';

initialization
  PWebCocoaSocketFpuMasked := pweb_cocoa_mask_fpu_traps = 0;

end.
