unit spikegtk;

{ CAP-12A: the Linux/WebKitGTK measurement handler. A SPIKE, not product
  code, and it is deliberately NOT a copy of the production adapter.

  WHY IT IS A SECOND HANDLER AND NOT THE PRODUCTION ONE. The question M1
  asks is "can this engine deliver a body in chunks?". The production
  adapter answers every request with
  g_memory_input_stream_new_from_data over a whole, already-materialised
  RawByteString, because that is all the frozen IAssetStore.TryRead can
  give it. Measuring streaming through it would measure the adapter, not
  the engine. So this unit reproduces the production SEAM - the same
  borrowed BROWSER_CONTROLLER handle, the same security-manager
  classification, the same webkit_web_context_register_uri_scheme, the
  same PWebParseAppUri, the same PWebNativeSecurityHeaders on every
  response - and changes exactly one thing: what it may put in the body.

  IT IS ALSO THE ONLY HANDLER IN THE PROCESS, and that is forced rather
  than chosen: MEASURED and recorded in docs/webkitgtk-linux-semantics.md,
  "a URI scheme can be registered ONCE per context and never removed", and
  the production adapter refuses outright when a second live handler
  appears on one context. So this one serves BOTH planes - ordinary assets
  through the real IAssetStore, and the reserved _pweb/blob/ prefix from
  the throwaway store - which is exactly the shape CAP-12B would ship.

  Streaming is a pipe. webkit_uri_scheme_response_new takes a GInputStream
  and WebKit pulls from it, so a pipe whose write end a worker thread feeds
  on a timer is a lazy producer with no GObject subclassing at all: the
  read end goes to g_unix_input_stream_new and the main thread finishes the
  request immediately, never blocking the GUI. }

{$mode ObjFPC}{$H+}

{$ifndef LINUX}
  {$MESSAGE Error 'spikegtk is the Linux measurement handler'}
{$endif LINUX}

interface

uses
  sysutils,
  baseunix,
  unix,
  mormot.core.base,
  mormot.core.os,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.navigation.policy,
  // linked for its initialization, which masks the six FPU exceptions FPC
  // leaves unmasked and GTK/Cairo/WebKit cannot survive (CAP-7L constraint
  // 3), and for the C scalar aliases its interface publishes
  pweb.platform.webkitgtk,
  blobsource;

type
  ESpikeGtk = class(Exception);

  { Serves pweb://app for one webview: the real store for ordinary assets,
    the throwaway blob plane for the reserved prefix. Create on the GUI
    thread after webview_create and before webview_navigate. }
  TSpikeGtkHandler = class
  private
    fStore: IAssetStore;
    fContext: Pointer; // borrowed WebKitWebContext - never unref'd
    fAttached: Boolean;
  public
    constructor Create(AWebView: webview_t; const AStore: IAssetStore);
    destructor Destroy; override;
    procedure Detach;
  end;

/// what this engine leg can report about itself, as JSON object members
function SpikeFactsJson: RawUtf8;

implementation

const
  WEBKITGTK_LIB = 'libwebkit2gtk-4.1.so.0';
  GIO_LIB = 'libgio-2.0.so.0';
  GOBJECT_LIB = 'libgobject-2.0.so.0';
  GLIB_LIB = 'libglib-2.0.so.0';
  SOUP_LIB = 'libsoup-3.0.so.0';

  PWEB_SCHEME: PAnsiChar = 'pweb';
  SPIKE_ERROR_DOMAIN: PAnsiChar = 'cap12a';
  SPIKE_REFUSED: PAnsiChar = 'cap12a blob unavailable';
  SPIKE_ERROR_CODE = 1;
  SOUP_MESSAGE_HEADERS_RESPONSE = 1;
  G_PRIORITY_DEFAULT = 0;
  /// a producer that cannot hand its bytes to the engine within this
  // window has told us what we wanted to know (the engine stopped
  // reading); it abandons rather than pinning a thread to process exit
  PRODUCER_DEADLINE_MS = 30000;

// --- libwebkit2gtk-4.1.so.0 ---

function webkit_web_view_get_context(web_view: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_web_view_get_context';

function webkit_web_context_get_security_manager(
  context: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_web_context_get_security_manager';

procedure webkit_security_manager_register_uri_scheme_as_secure(
  security_manager: Pointer; scheme: PAnsiChar); cdecl;
  external WEBKITGTK_LIB
  name 'webkit_security_manager_register_uri_scheme_as_secure';

procedure webkit_security_manager_register_uri_scheme_as_cors_enabled(
  security_manager: Pointer; scheme: PAnsiChar); cdecl;
  external WEBKITGTK_LIB
  name 'webkit_security_manager_register_uri_scheme_as_cors_enabled';

procedure webkit_web_context_register_uri_scheme(context: Pointer;
  scheme: PAnsiChar; callback: TWebKitUriSchemeRequestCallback;
  user_data: Pointer; user_data_destroy_func: TGDestroyNotify); cdecl;
  external WEBKITGTK_LIB name 'webkit_web_context_register_uri_scheme';

function webkit_uri_scheme_request_get_uri(
  request: Pointer): PAnsiChar; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_get_uri';

/// M2/M3: the request surface the production adapter never reads. Present
// since WebKitGTK 2.36 (method, headers) and 2.40 (body); the pinned
// baseline is 2.52, so the DECLARATIONS are safe and only the VALUES are
// the measurement.
function webkit_uri_scheme_request_get_http_method(
  request: Pointer): PAnsiChar; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_get_http_method';

function webkit_uri_scheme_request_get_http_headers(
  request: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_get_http_headers';

/// transfer full: the caller owns a reference to the returned GInputStream
function webkit_uri_scheme_request_get_http_body(
  request: Pointer): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_get_http_body';

procedure webkit_uri_scheme_request_finish_error(request: Pointer;
  error: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_request_finish_error';

function webkit_uri_scheme_response_new(stream: Pointer;
  stream_length: TGInt64): Pointer; cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_new';

procedure webkit_uri_scheme_response_set_content_type(response: Pointer;
  content_type: PAnsiChar); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_set_content_type';

procedure webkit_uri_scheme_response_set_status(response: Pointer;
  status_code: TGUInt; reason_phrase: PAnsiChar); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_set_status';

procedure webkit_uri_scheme_response_set_http_headers(response: Pointer;
  headers: Pointer); cdecl;
  external WEBKITGTK_LIB name 'webkit_uri_scheme_response_set_http_headers';

procedure webkit_uri_scheme_request_finish_with_response(request: Pointer;
  response: Pointer); cdecl;
  external WEBKITGTK_LIB
  name 'webkit_uri_scheme_request_finish_with_response';

// --- libgio-2.0.so.0 ---

function g_memory_input_stream_new_from_data(data: Pointer; len: TGSSize;
  destroy: TGDestroyNotify): Pointer; cdecl;
  external GIO_LIB name 'g_memory_input_stream_new_from_data';

/// the whole lazy-producer mechanism, in one call: a GInputStream over a
// file descriptor. close_fd TRUE hands the read end to GIO for good.
function g_unix_input_stream_new(fd: TGInt;
  close_fd: TGBoolean): Pointer; cdecl;
  external GIO_LIB name 'g_unix_input_stream_new';

function g_input_stream_read(stream: Pointer; buffer: Pointer;
  count: TGSize; cancellable: Pointer; error: PPointer): TGSSize; cdecl;
  external GIO_LIB name 'g_input_stream_read';

function g_input_stream_close(stream: Pointer; cancellable: Pointer;
  error: PPointer): TGBoolean; cdecl;
  external GIO_LIB name 'g_input_stream_close';

// --- libgobject-2.0.so.0 ---

procedure g_object_unref(obj: Pointer); cdecl;
  external GOBJECT_LIB name 'g_object_unref';

function g_object_ref(obj: Pointer): Pointer; cdecl;
  external GOBJECT_LIB name 'g_object_ref';

// --- libsoup-3.0.so.0 ---

function soup_message_headers_new(
  htype: TSoupMessageHeadersType): Pointer; cdecl;
  external SOUP_LIB name 'soup_message_headers_new';

procedure soup_message_headers_append(hdrs: Pointer;
  header_name: PAnsiChar; header_value: PAnsiChar); cdecl;
  external SOUP_LIB name 'soup_message_headers_append';

function soup_message_headers_get_one(hdrs: Pointer;
  header_name: PAnsiChar): PAnsiChar; cdecl;
  external SOUP_LIB name 'soup_message_headers_get_one';

// --- libglib-2.0.so.0 ---

procedure g_free(mem: Pointer); cdecl;
  external GLIB_LIB name 'g_free';

function g_try_malloc(n_bytes: TGSize): Pointer; cdecl;
  external GLIB_LIB name 'g_try_malloc';

function g_quark_from_static_string(s: PAnsiChar): TGQuark; cdecl;
  external GLIB_LIB name 'g_quark_from_static_string';

function g_error_new_literal(domain: TGQuark; code: TGInt;
  message: PAnsiChar): Pointer; cdecl;
  external GLIB_LIB name 'g_error_new_literal';

procedure g_error_free(error: Pointer); cdecl;
  external GLIB_LIB name 'g_error_free';

type
  TGSourceFunc = function(data: Pointer): TGBoolean; cdecl;

function g_idle_add_full(priority: TGInt; func: TGSourceFunc;
  data: Pointer; notify: TGDestroyNotify): TGUInt; cdecl;
  external GLIB_LIB name 'g_idle_add_full';

{ ---- state ---- }

type
  PProducerJob = ^TProducerJob;
  TProducerJob = record
    Fd: Integer;            // write end of the pipe, owned by the thread
    Plan: TBlobPlan;
    Tag: RawUtf8;           // event prefix for the timeline
    Seq: Integer;
  end;

  PEchoJob = ^TEchoJob;
  TEchoJob = record
    Request: Pointer;       // reffed WebKitURISchemeRequest
    Body: Pointer;          // reffed GInputStream, or nil
    Seq: Integer;
    Received: Int64;
    Chunks: Integer;
    FirstByte: Integer;
    PatternOk: Boolean;
    ReadMicros: Int64;
  end;

var
  SpikeOwner: PtrInt;       // TSpikeGtkHandler, or 0 once detached
  SpikeSeq: Integer;
  SpikeRegistered: Boolean;
  FactMethodSeen: RawUtf8;
  FactHeadersNonNil: Integer;
  FactBodyNonNil: Integer;
  FactBlobAuthority: Integer;
  FactLock: TRTLCriticalSection;

function NextSeq: Integer;
begin
  Result := InterlockedIncrement(SpikeSeq);
end;

procedure NoteFact(const MethodSeen: RawUtf8; HeadersNonNil, BodyNonNil: Boolean);
begin
  EnterCriticalSection(FactLock);
  try
    if (MethodSeen <> '') and (Pos(MethodSeen + ',', FactMethodSeen) = 0) then
      FactMethodSeen := FactMethodSeen + MethodSeen + ',';
    if HeadersNonNil then
      Inc(FactHeadersNonNil);
    if BodyNonNil then
      Inc(FactBodyNonNil);
  finally
    LeaveCriticalSection(FactLock);
  end;
end;

function SpikeFactsJson: RawUtf8;
begin
  EnterCriticalSection(FactLock);
  try
    Result :=
      '"methods_seen": ' + JsonQuote(FactMethodSeen) + ',' + #10 +
      '    "requests_with_headers": ' + RawUtf8(IntToStr(FactHeadersNonNil)) +
      ',' + #10 +
      '    "requests_with_body": ' + RawUtf8(IntToStr(FactBodyNonNil)) +
      ',' + #10 +
      '    "second_authority_requests": ' +
      RawUtf8(IntToStr(FactBlobAuthority));
  finally
    LeaveCriticalSection(FactLock);
  end;
end;

{ ---- refusal ---- }

procedure FinishRefused(request: Pointer);
var
  err: Pointer;
begin
  if request = nil then
    exit;
  err := g_error_new_literal(g_quark_from_static_string(SPIKE_ERROR_DOMAIN),
    SPIKE_ERROR_CODE, SPIKE_REFUSED);
  if err = nil then
    exit;
  // finish_error COPIES the error into the request, so ours is ours to free
  webkit_uri_scheme_request_finish_error(request, err);
  g_error_free(err);
end;

{ ---- the lazy producer ---- }

// A bounded, non-blocking write. The engine may stop reading at any time
// (the page aborted, the media element seeked away); a blocking write would
// then pin this thread until process exit and hang teardown.
function WriteAll(Fd: Integer; Buf: PByte; Count: PtrInt;
  DeadlineMicros: Int64): PtrInt;
var
  n: PtrInt;
begin
  Result := 0;
  while Result < Count do
  begin
    n := FpWrite(Fd, Buf[Result], Count - Result);
    if n > 0 then
    begin
      Inc(Result, n);
      continue;
    end;
    if (n < 0) and ((fpgeterrno = ESysEAGAIN) or (fpgeterrno = ESysEINTR)) then
    begin
      if NowMicros > DeadlineMicros then
        exit;
      Sleep(2);
      continue;
    end;
    exit; // EPIPE and friends: the engine is gone
  end;
end;

function ProducerThread(p: Pointer): PtrInt;
var
  job: PProducerJob;
  buf: PByte;
  i, written: PtrInt;
  frame: RawUtf8;
  deadline: Int64;
  tag: RawUtf8;
begin
  Result := 0;
  job := PProducerJob(p);
  tag := job^.Tag;
  buf := nil;
  deadline := NowMicros + Int64(PRODUCER_DEADLINE_MS) * 1000;
  try
    if job^.Plan.Kind = bpkSse then
    begin
      for i := 0 to job^.Plan.Chunks - 1 do
      begin
        if (i > 0) and (job^.Plan.DelayMs > 0) then
          Sleep(job^.Plan.DelayMs);
        frame := SseFrame(i, NowMicros);
        Mark(tag + '.produce', '', i);
        written := WriteAll(job^.Fd, PByte(frame), Length(frame), deadline);
        Mark(tag + '.written', '', written);
        if written < Length(frame) then
        begin
          Mark(tag + '.abandoned', '', i);
          break;
        end;
      end;
    end
    else
    begin
      GetMem(buf, job^.Plan.ChunkBytes);
      for i := 0 to job^.Plan.Chunks - 1 do
      begin
        if (i > 0) and (job^.Plan.DelayMs > 0) then
          Sleep(job^.Plan.DelayMs);
        FillPlanRange(job^.Plan, buf,
          Int64(i) * job^.Plan.ChunkBytes, job^.Plan.ChunkBytes);
        // PRODUCE IS MARKED BEFORE THE WRITE, and that ordering is the
        // whole M1 verdict: "the page saw chunk 0 before chunk N-1 was
        // produced" must compare against the earliest instant this process
        // could possibly have had chunk N-1's bytes.
        Mark(tag + '.produce', '', i);
        written := WriteAll(job^.Fd, buf, job^.Plan.ChunkBytes, deadline);
        Mark(tag + '.written', '', written);
        if written < job^.Plan.ChunkBytes then
        begin
          Mark(tag + '.abandoned', '', i);
          break;
        end;
      end;
    end;
  except
    on E: Exception do
      Mark(tag + '.producer_error', RawUtf8(E.Message));
  end;
  if buf <> nil then
    FreeMem(buf);
  FpClose(job^.Fd); // EOF for the engine: the body ends here
  Mark(tag + '.eof');
  Dispose(job);
end;

{ ---- the echo (M3) worker ---- }

function EchoFinishOnMain(data: Pointer): TGBoolean; cdecl;
var
  job: PEchoJob;
  json: RawUtf8;
  body: Pointer;
  stream, response, hdrs: Pointer;
  copy: PByte;
begin
  Result := 0; // G_SOURCE_REMOVE
  job := PEchoJob(data);
  try
    json := '{"received":' + RawUtf8(IntToStr(job^.Received)) +
      ',"chunks":' + RawUtf8(IntToStr(job^.Chunks)) +
      ',"first_byte":' + RawUtf8(IntToStr(job^.FirstByte)) +
      ',"pattern_ok":' + JsonBool(job^.PatternOk) +
      ',"read_us":' + RawUtf8(IntToStr(job^.ReadMicros)) + '}';
    copy := PByte(g_try_malloc(TGSize(Length(json))));
    if copy = nil then
    begin
      FinishRefused(job^.Request);
      exit;
    end;
    Move(PByte(json)^, copy^, Length(json));
    stream := g_memory_input_stream_new_from_data(copy, TGSSize(Length(json)),
      TGDestroyNotify(@g_free));
    if stream = nil then
    begin
      g_free(copy);
      FinishRefused(job^.Request);
      exit;
    end;
    response := webkit_uri_scheme_response_new(stream, TGInt64(Length(json)));
    if response = nil then
    begin
      g_object_unref(stream);
      FinishRefused(job^.Request);
      exit;
    end;
    webkit_uri_scheme_response_set_content_type(response, 'application/json');
    webkit_uri_scheme_response_set_status(response, 200, 'OK');
    hdrs := soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    if hdrs <> nil then
    begin
      soup_message_headers_append(hdrs, 'Content-Type', 'application/json');
      soup_message_headers_append(hdrs, 'Cache-Control', 'no-store');
      webkit_uri_scheme_response_set_http_headers(response, hdrs);
    end;
    webkit_uri_scheme_request_finish_with_response(job^.Request, response);
    g_object_unref(response);
    g_object_unref(stream);
    body := job^.Request;
    g_object_unref(body);
    Mark('m3.finished', '', job^.Received);
  except
    on E: Exception do
      Mark('m3.finish_error', RawUtf8(E.Message));
  end;
  Dispose(job);
end;

function EchoReadThread(p: Pointer): PtrInt;
const
  ECHO_BUF = 256 * 1024;
var
  job: PEchoJob;
  buf: PByte;
  n: TGSSize;
  started: Int64;
  expect: Int64;
  i: PtrInt;
begin
  Result := 0;
  job := PEchoJob(p);
  started := NowMicros;
  job^.PatternOk := True;
  job^.FirstByte := -1;
  expect := 0;
  GetMem(buf, ECHO_BUF);
  try
    if job^.Body <> nil then
      repeat
        n := g_input_stream_read(job^.Body, buf, TGSize(ECHO_BUF), nil, nil);
        if n <= 0 then
          break;
        Inc(job^.Chunks);
        if job^.Received = 0 then
          job^.FirstByte := buf[0];
        // the body is the deterministic pattern, so a truncated or
        // reordered upload is caught here rather than trusted
        for i := 0 to n - 1 do
        begin
          if buf[i] <> BlobByte(expect + i) then
          begin
            job^.PatternOk := False;
            break;
          end;
        end;
        Inc(expect, n);
        Inc(job^.Received, n);
        Mark('m3.read', '', job^.Received);
      until False;
  except
    on E: Exception do
      Mark('m3.read_error', RawUtf8(E.Message));
  end;
  FreeMem(buf);
  if job^.Body <> nil then
  begin
    g_input_stream_close(job^.Body, nil, nil);
    g_object_unref(job^.Body);
    job^.Body := nil;
  end;
  job^.ReadMicros := NowMicros - started;
  // back to the GUI thread to finish: webkit_uri_scheme_request_* is
  // main-thread work, and deferring it this way is itself the measurement
  // that this engine CAN complete a scheme request asynchronously
  g_idle_add_full(G_PRIORITY_DEFAULT, @EchoFinishOnMain, job, nil);
end;

{ ---- response helpers ---- }

// PWebNativeSecurityHeaders returns ONE CRLF-separated block, and libsoup
// wants name/value pairs. The production adapter has a private splitter for
// exactly this; duplicating that shape here keeps the spike's responses
// byte-comparable with the product's without touching the product.
procedure AppendSplitHeaders(hdrs: Pointer; const Block: RawUtf8);
var
  i, lineStart, colon: PtrInt;
  line, name, value: RawUtf8;
begin
  lineStart := 1;
  for i := 1 to Length(Block) + 1 do
    if (i > Length(Block)) or (Block[i] = #13) or (Block[i] = #10) then
    begin
      line := Copy(Block, lineStart, i - lineStart);
      lineStart := i + 1;
      if line = '' then
        continue;
      colon := Pos(':', line);
      if colon <= 1 then
        continue;
      name := Copy(line, 1, colon - 1);
      value := Copy(line, colon + 1, Length(line) - colon);
      while (value <> '') and (value[1] = ' ') do
        value := Copy(value, 2, Length(value) - 1);
      if (name <> '') and (value <> '') then
        soup_message_headers_append(hdrs, PAnsiChar(name), PAnsiChar(value));
    end;
end;

function BuildResponseHeaders(const ContentType: RawUtf8;
  BodyLen, Total, First, Last: Int64; Partial, Ranged: Boolean): Pointer;
var
  hdrs: Pointer;
begin
  Result := nil;
  hdrs := soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
  if hdrs = nil then
    exit;
  soup_message_headers_append(hdrs, 'Content-Type', PAnsiChar(ContentType));
  soup_message_headers_append(hdrs, 'Cache-Control', 'no-store');
  // Content-Length IS SENT AS A HEADER and not merely as the response
  // object's stream length. The production GTK adapter relies on the
  // stream length alone, which fetch() is happy with; the macOS adapter
  // already sends the header. It is in the header set here because a media
  // element is a different consumer from fetch() and the row that asks
  // whether it can play must not be answered by a missing header.
  if BodyLen >= 0 then
    soup_message_headers_append(hdrs, 'Content-Length',
      PAnsiChar(RawUtf8(IntToStr(BodyLen))));
  if Ranged then
    soup_message_headers_append(hdrs, 'Accept-Ranges', 'bytes');
  if Partial then
    soup_message_headers_append(hdrs, 'Content-Range',
      PAnsiChar('bytes ' + RawUtf8(IntToStr(First)) + '-' +
        RawUtf8(IntToStr(Last)) + '/' + RawUtf8(IntToStr(Total))));
  // the production policy block rides every response of this spike too,
  // because the CSP is the premise of the whole shard and a row measured
  // without it would be measuring a different product
  AppendSplitHeaders(hdrs, PWebNativeSecurityHeaders);
  Result := hdrs;
end;

procedure FinishWithStream(request, stream: Pointer; DeclaredLen: Int64;
  const ContentType: RawUtf8; Status: Integer; Reason: PAnsiChar;
  Total, First, Last: Int64; Partial, Ranged: Boolean);
var
  response, hdrs: Pointer;
begin
  response := webkit_uri_scheme_response_new(stream, TGInt64(DeclaredLen));
  if response = nil then
  begin
    g_object_unref(stream);
    FinishRefused(request);
    exit;
  end;
  webkit_uri_scheme_response_set_content_type(response,
    PAnsiChar(ContentType));
  webkit_uri_scheme_response_set_status(response, TGUInt(Status), Reason);
  hdrs := BuildResponseHeaders(ContentType, DeclaredLen, Total, First, Last,
    Partial, Ranged);
  if hdrs = nil then
  begin
    g_object_unref(response);
    g_object_unref(stream);
    FinishRefused(request);
    exit;
  end;
  webkit_uri_scheme_response_set_http_headers(response, hdrs);
  webkit_uri_scheme_request_finish_with_response(request, response);
  g_object_unref(response);
  g_object_unref(stream);
end;

function ServeMemory(request: Pointer; const Bytes: RawByteString;
  const ContentType: RawUtf8; Status: Integer; Reason: PAnsiChar;
  Total, First, Last: Int64; Partial, Ranged: Boolean): Boolean;
var
  copy: PByte;
  stream: Pointer;
  n: PtrInt;
begin
  Result := False;
  n := Length(Bytes);
  copy := nil;
  if n > 0 then
  begin
    copy := PByte(g_try_malloc(TGSize(n)));
    if copy = nil then
    begin
      FinishRefused(request);
      exit;
    end;
    Move(PByte(Bytes)^, copy^, n);
  end;
  stream := g_memory_input_stream_new_from_data(copy, TGSSize(n),
    TGDestroyNotify(@g_free));
  if stream = nil then
  begin
    if copy <> nil then
      g_free(copy);
    FinishRefused(request);
    exit;
  end;
  FinishWithStream(request, stream, n, ContentType, Status, Reason,
    Total, First, Last, Partial, Ranged);
  Result := True;
end;

{ ---- the blob plane ---- }

function ServeBlob(request: Pointer; const Plan: TBlobPlan;
  const RangeHeader: RawUtf8; Seq: Integer): Boolean;
var
  fds: TFilDes;
  flags: Integer;
  job: PProducerJob;
  id: TThreadID;
  h: TThreadID;
  stream: Pointer;
  first, last, count: Int64;
  body: RawByteString;
  tag: RawUtf8;
begin
  Result := False;
  tag := 'blob' + RawUtf8(IntToStr(Seq));
  case Plan.Kind of
    bpkStream, bpkSse:
      begin
        if FpPipe(fds) <> 0 then
        begin
          FinishRefused(request);
          exit;
        end;
        // non-blocking WRITE end only: the read end stays blocking because
        // GIO owns it and expects ordinary semantics
        flags := FpFcntl(fds[1], F_GetFl, 0);
        FpFcntl(fds[1], F_SetFl, flags or O_NONBLOCK);
        stream := g_unix_input_stream_new(TGInt(fds[0]), 1);
        if stream = nil then
        begin
          FpClose(fds[0]);
          FpClose(fds[1]);
          FinishRefused(request);
          exit;
        end;
        // WHAT THE HANDLER ITSELF HAS TO HOLD to answer this request, in
        // bytes, counted rather than inferred from RSS. The process-level
        // figure cannot separate the handler's allocation from pages the
        // engine maps, and it moves between runs as the allocator reuses
        // freed pages; this number does not.
        Mark(tag + '.materialised', 'producer chunk buffer',
          Plan.ChunkBytes);
        New(job);
        job^.Fd := fds[1];
        job^.Plan := Plan;
        job^.Tag := tag;
        job^.Seq := Seq;
        h := BeginThread(@ProducerThread, job, id);
        if h = TThreadID(0) then
        begin
          Dispose(job);
          g_object_unref(stream);
          FpClose(fds[1]);
          FinishRefused(request);
          exit;
        end;
        CloseThread(h);
        Mark(tag + '.respond', Plan.Id, Plan.Total);
        // Plan.Total = -1 means "no declared length", which is a distinct
        // row: an engine may buffer a body whose size it knows and stream
        // one it does not
        FinishWithStream(request, stream, Plan.Total, Plan.ContentType,
          200, 'OK', Plan.Total, 0, 0, False, False);
        Result := True;
      end;
    bpkWhole, bpkWav, bpkPng:
      begin
        first := 0;
        last := Plan.Total - 1;
        if Plan.Ranged and (RangeHeader <> '') and
           ParseSingleRange(RangeHeader, Plan.Total, first, last) then
        begin
          count := last - first + 1;
          SetLength(body, count);
          FillPlanRange(Plan, PByte(body), first, count);
          // the window, twice: once as the Pascal string and once as the
          // GLib copy the input stream takes ownership of
          Mark(tag + '.materialised', 'window + GLib copy', 2 * count);
          Mark(tag + '.respond206', RangeHeader, count);
          Result := ServeMemory(request, body, Plan.ContentType, 206,
            'Partial Content', Plan.Total, first, last, True, True);
        end
        else
        begin
          body := BuildWholeBody(Plan);
          // the WHOLE body, twice, and that doubling is the frozen seam's
          // own doing: TryRead materialises into TAssetResponse.Content and
          // the adapter must then hand GIO a buffer it owns
          Mark(tag + '.materialised', 'whole body + GLib copy',
            2 * Int64(Length(body)));
          Mark(tag + '.respond200', Plan.Id, Plan.Total);
          Result := ServeMemory(request, body, Plan.ContentType, 200, 'OK',
            Plan.Total, 0, Plan.Total - 1, False, Plan.Ranged);
        end;
      end;
  else
    FinishRefused(request);
  end;
end;

{ ---- the one scheme callback ---- }

procedure SpikeSchemeRequest(request: Pointer;
  user_data: Pointer); cdecl;
var
  owner: TSpikeGtkHandler;
  rawUri, rawMethod, rawRange: PAnsiChar;
  uri, logical, id, method, rangeHeader: RawUtf8;
  plan: TBlobPlan;
  asset: TAssetResponse;
  hdrs, bodyStream: Pointer;
  seq: Integer;
  job: PEchoJob;
  tid: TThreadID;
  h: TThreadID;
begin
  seq := NextSeq;
  try
    owner := TSpikeGtkHandler(Pointer(SpikeOwner));
    if (owner = nil) or (request = nil) then
    begin
      FinishRefused(request);
      exit;
    end;
    // THE FOUR NATIVE READS ARE BRACKETED ONE BY ONE. They were not, at
    // first, and the run reported four "Load failed" upload rows that read
    // exactly like an engine limitation; the timeline said only
    // `req.exception Access violation` with no `req.open` before it, which
    // is a fault in ONE of these calls and not a fact about uploads. A
    // measurement instrument whose own crash is indistinguishable from the
    // finding is worse than no instrument.
    Mark('req.enter', '', seq);
    // (the URI is not known yet at req.enter; req.got_uri below carries it,
    // and the two are the same instant for every practical purpose)
    rawUri := webkit_uri_scheme_request_get_uri(request);
    if rawUri = nil then
    begin
      FinishRefused(request);
      exit;
    end;
    FastSetString(uri, rawUri, StrLen(rawUri));
    Mark('req.got_uri', uri, seq);

    method := '';
    rawMethod := webkit_uri_scheme_request_get_http_method(request);
    if rawMethod <> nil then
      FastSetString(method, rawMethod, StrLen(rawMethod));
    Mark('req.got_method', method, seq);

    rangeHeader := '';
    hdrs := webkit_uri_scheme_request_get_http_headers(request);
    Mark('req.got_headers', '', seq);
    if hdrs <> nil then
    begin
      rawRange := soup_message_headers_get_one(hdrs, 'Range');
      if rawRange <> nil then
        FastSetString(rangeHeader, rawRange, StrLen(rawRange));
    end;
    Mark('req.read_range', rangeHeader, seq);

    bodyStream := webkit_uri_scheme_request_get_http_body(request);
    Mark('req.got_body', '', seq);
    NoteFact(method, hdrs <> nil, bodyStream <> nil);

    Mark('req.open', uri, seq);
    if method <> '' then
      Mark('req.method', method, seq);
    if rangeHeader <> '' then
      Mark('req.range', rangeHeader, seq);
    if bodyStream <> nil then
      Mark('req.body_stream', method, seq);

    if not PWebParseAppUri(uri, logical) then
    begin
      if bodyStream <> nil then
        g_object_unref(bodyStream);
      // a pweb scheme is registered CONTEXT-WIDE on this engine, so a
      // request for a second authority really would arrive here. Counting
      // them is what makes "the CSP refused it before any request existed" a
      // discriminating negative rather than an absence nobody looked for.
      InterlockedIncrement(FactBlobAuthority);
      Mark('req.refused', uri, seq);
      FinishRefused(request);
      exit;
    end;

    if BlobPathId(logical, id) and ParseBlobPlan(id, plan) then
    begin
      if plan.Kind = bpkEcho then
      begin
        // M3: the body is read off the GUI thread and the request finished
        // from an idle source, so a 256 MiB upload cannot be mistaken for
        // an engine that blocks
        New(job);
        FillChar(job^, SizeOf(job^), 0);
        job^.Request := g_object_ref(request);
        job^.Body := bodyStream; // already a full reference
        job^.Seq := seq;
        h := BeginThread(@EchoReadThread, job, tid);
        if h = TThreadID(0) then
        begin
          if job^.Body <> nil then
            g_object_unref(job^.Body);
          g_object_unref(job^.Request);
          Dispose(job);
          FinishRefused(request);
        end
        else
          CloseThread(h);
        Mark('req.close', logical, seq);
        exit;
      end;
      if bodyStream <> nil then
        g_object_unref(bodyStream);
      ServeBlob(request, plan, rangeHeader, seq);
      Mark('req.close', logical, seq);
      exit;
    end;

    if bodyStream <> nil then
      g_object_unref(bodyStream);
    // the ordinary asset plane, through the real frozen store
    if owner.fStore.TryRead(logical, asset) then
      ServeMemory(request, asset.Content, asset.ContentType, 200, 'OK',
        Length(asset.Content), 0, Length(asset.Content) - 1, False, False)
    else
    begin
      Mark('req.notfound', logical, seq);
      FinishRefused(request);
    end;
    Mark('req.close', logical, seq);
  except
    on E: Exception do
    begin
      Mark('req.exception', RawUtf8(E.Message), seq);
      try
        FinishRefused(request);
      except
      end;
    end;
  end;
end;

procedure SpikeRegistrationDestroyed(data: Pointer); cdecl;
begin
  // nothing to free: the spike registers once with a nil user_data and
  // lives for the process. Declared so the registration call has the same
  // shape as the production one.
end;

{ ---- TSpikeGtkHandler ---- }

constructor TSpikeGtkHandler.Create(AWebView: webview_t;
  const AStore: IAssetStore);
var
  controller, security: Pointer;
begin
  inherited Create;
  if AWebView = nil then
    raise ESpikeGtk.Create('webview handle is nil');
  if AStore = nil then
    raise ESpikeGtk.Create('asset store is nil');
  fStore := AStore;
  controller := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if controller = nil then
    raise ESpikeGtk.Create('borrowed browser controller is unavailable');
  fContext := webkit_web_view_get_context(controller);
  if fContext = nil then
    raise ESpikeGtk.Create('WebKitWebContext is unavailable');
  security := webkit_web_context_get_security_manager(fContext);
  if security = nil then
    raise ESpikeGtk.Create('WebKitSecurityManager is unavailable');
  webkit_security_manager_register_uri_scheme_as_secure(security,
    PWEB_SCHEME);
  webkit_security_manager_register_uri_scheme_as_cors_enabled(security,
    PWEB_SCHEME);
  InterLockedExchange64(PInt64(@SpikeOwner)^, Int64(PtrInt(Pointer(Self))));
  if not SpikeRegistered then
  begin
    // ONE registration per process, as CAP-7L measured: this spike runs a
    // single window and never re-registers
    webkit_web_context_register_uri_scheme(fContext, PWEB_SCHEME,
      @SpikeSchemeRequest, nil, @SpikeRegistrationDestroyed);
    SpikeRegistered := True;
  end;
  fAttached := True;
end;

destructor TSpikeGtkHandler.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TSpikeGtkHandler.Detach;
begin
  InterLockedExchange64(PInt64(@SpikeOwner)^, 0);
  fAttached := False;
  fContext := nil;
  fStore := nil;
end;

initialization
  InitCriticalSection(FactLock);

finalization
  DoneCriticalSection(FactLock);

end.
