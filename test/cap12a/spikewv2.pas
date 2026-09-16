unit spikewv2;

{ CAP-12A: the Windows/WebView2 measurement handler. A SPIKE, not product
  code, and deliberately NOT a copy of the production adapter.

  WHY A SECOND HANDLER. The production adapter answers every request with
  SHCreateMemStream over a whole, already-materialised RawByteString,
  because that is all the frozen IAssetStore.TryRead can give it. M1 asks
  whether the ENGINE reads a response body incrementally; measuring that
  through a handler that can only ever hand over a finished buffer would
  measure the adapter. So this unit reproduces the production SEAM - the
  same borrowed ICoreWebView2Controller native handle, the same
  add_WebResourceRequested with a pweb://app/* filter, the same
  PWebParseAppUri, the same PWebNativeSecurityHeaders on every response -
  and changes exactly one thing: what it may put in the body.

  THE ONE MECHANISM THIS LEG ADDS is a LAZY IStream. WebView2 is the only
  one of the three engines whose response body is PULL-based: it takes an
  IStream* and reads from it. Whether it reads incrementally or drains the
  whole thing before the page sees a byte is not documented and is exactly
  M1's question, so the stream here produces on Read, records every Read
  call with its thread, its requested size and its timestamp, and blocks
  when the next chunk is not due yet.

  Blocking is not a design choice. IStream::Read has no "would block"
  answer - a short read of zero bytes IS end of stream - so a producer
  that is not ready has only one legal move, and WHICH THREAD it blocks is
  therefore a load-bearing measurement rather than a curiosity.

  Three vtable slots the production adapter declares as never-called stubs
  are declared for real here - get_Method, get_Content and get_Headers -
  at the SAME slot indices. The slot layout is untouched; only this
  spike's copy of the declaration knows what is in them. }

{$mode ObjFPC}{$H+}

{$ifndef MSWINDOWS}
  {$MESSAGE Error 'spikewv2 is the Windows measurement handler'}
{$endif MSWINDOWS}

interface

uses
  sysutils,
  windows,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.navigation.policy,
  blobsource;

type
  ESpikeWv2 = class(Exception);

  { Serves pweb://app for one webview: the real store for ordinary assets,
    the throwaway blob plane for the reserved prefix. Create on the GUI
    thread after webview_create; Detach on the GUI thread before
    webview_destroy. }
  TSpikeWv2Handler = class
  private
    fStore: IAssetStore;
    fController: Pointer; // borrowed - never AddRef/Release
    fCore: IInterface;
    fEnvironment: IInterface;
    fHandler: IInterface;
    fToken: Int64;
    fThreadId: DWord;
    fAttached: Boolean;
    fFilters: Integer;
  public
    constructor Create(AWebView: webview_t; const AStore: IAssetStore);
    destructor Destroy; override;
    procedure Detach;
  end;

function SpikeFactsJson: RawUtf8;

implementation

const
  PWEB_APP_FILTER: WideString = 'pweb://app/*';
  /// a SECOND filter on a SECOND authority. The CSP is expected to refuse a
  // fetch to pweb://blob/... before any request exists, and "the handler
  // was never asked" is a much stronger negative than "the handler refused
  // it" - but only if the handler would have been asked had the fetch got
  // that far. This filter is what makes the negative discriminating.
  PWEB_BLOB_FILTER: WideString = 'pweb://blob/*';
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0;

  STREAM_SEEK_SET = 0;
  STREAM_SEEK_CUR = 1;
  STREAM_SEEK_END = 2;

  /// a Read that waits longer than this has told us the engine stopped
  // consuming; it returns short rather than pinning the calling thread
  READ_DEADLINE_MS = 30000;

type
  { ---- the minimal IStream surface, by exact vtable order ---- }

  IPWebSeqStream = interface(IUnknown)
    ['{0c733a30-2a1c-11ce-ade5-00aa0044773d}']
    function Read(pv: Pointer; cb: LongWord;
      pcbRead: PLongWord): HRESULT; stdcall;
    function Write(pv: Pointer; cb: LongWord;
      pcbWritten: PLongWord): HRESULT; stdcall;
  end;

  TPWebStatStg = record
    pwcsName: PWideChar;
    dwType: LongWord;
    cbSize: Int64;
    mtime, ctime, atime: TFileTime;
    grfMode: LongWord;
    grfLocksSupported: LongWord;
    clsid: TGUID;
    grfStateBits: LongWord;
    reserved: LongWord;
  end;
  PPWebStatStg = ^TPWebStatStg;

  IPWebStream = interface(IPWebSeqStream)
    ['{0000000c-0000-0000-c000-000000000046}']
    function Seek(dlibMove: Int64; dwOrigin: LongWord;
      plibNewPosition: PInt64): HRESULT; stdcall;
    function SetSize(libNewSize: Int64): HRESULT; stdcall;
    function CopyTo(stm: IPWebStream; cb: Int64; pcbRead: PInt64;
      pcbWritten: PInt64): HRESULT; stdcall;
    function Commit(grfCommitFlags: LongWord): HRESULT; stdcall;
    function Revert: HRESULT; stdcall;
    function LockRegion(libOffset: Int64; cb: Int64;
      dwLockType: LongWord): HRESULT; stdcall;
    function UnlockRegion(libOffset: Int64; cb: Int64;
      dwLockType: LongWord): HRESULT; stdcall;
    function Stat(pstatstg: PPWebStatStg;
      grfStatFlag: LongWord): HRESULT; stdcall;
    function Clone(out stm: IPWebStream): HRESULT; stdcall;
  end;

  { ---- the WebView2 surface, transcribed at the pinned slot order ---- }

  ICoreWebView2HttpRequestHeaders = interface(IUnknown)
    ['{e86cac0e-5523-465c-b536-8fb9fc8c8c60}']
    function GetHeader(name: PWideChar;
      out value: PWideChar): HRESULT; stdcall;
    function Stub_GetHeaders: HRESULT; stdcall;
    function Contains(name: PWideChar; out contains: Integer): HRESULT; stdcall;
    function Stub_SetHeader: HRESULT; stdcall;
    function Stub_RemoveHeader: HRESULT; stdcall;
    function Stub_GetIterator: HRESULT; stdcall;
  end;

  ICoreWebView2WebResourceResponse = interface(IUnknown)
    ['{aafcc94f-fa27-48fd-97df-830ef75aaec9}']
  end;

  ICoreWebView2WebResourceRequest = interface(IUnknown)
    ['{97055cd4-512c-4264-8b5f-e3f446cea6a5}']
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;
    function Stub_put_Uri: HRESULT; stdcall;
    // three slots the production adapter declares as never-called stubs.
    // Same indices, real declarations - the measurement is what is in them.
    function get_Method(out method: PWideChar): HRESULT; stdcall;
    function Stub_put_Method: HRESULT; stdcall;
    function get_Content(out content: IPWebStream): HRESULT; stdcall;
    function Stub_put_Content: HRESULT; stdcall;
    function get_Headers(
      out headers: ICoreWebView2HttpRequestHeaders): HRESULT; stdcall;
  end;

  ICoreWebView2WebResourceRequestedEventArgs = interface(IUnknown)
    ['{453e667f-12c7-49d4-be6d-ddbe7956f57a}']
    function get_Request(
      out request: ICoreWebView2WebResourceRequest): HRESULT; stdcall;
    function Stub_get_Response: HRESULT; stdcall;
    function put_Response(
      response: ICoreWebView2WebResourceResponse): HRESULT; stdcall;
    function Stub_GetDeferral: HRESULT; stdcall;
    function Stub_get_ResourceContext: HRESULT; stdcall;
  end;

  ICoreWebView2WebResourceRequestedEventHandler = interface(IUnknown)
    ['{ab00b74c-15f1-4646-80e8-e76341d25d71}']
    function Invoke(sender: IUnknown;
      args: ICoreWebView2WebResourceRequestedEventArgs): HRESULT; stdcall;
  end;

  ICoreWebView2Environment = interface(IUnknown)
    ['{b96d755e-0319-4e92-a296-23436f46a1fc}']
    function Stub_CreateCoreWebView2Controller: HRESULT; stdcall;
    function CreateWebResourceResponse(content: Pointer;
      statusCode: Integer; reasonPhrase: PWideChar; headers: PWideChar;
      out response: ICoreWebView2WebResourceResponse): HRESULT; stdcall;
    function Stub_get_BrowserVersionString: HRESULT; stdcall;
    function Stub_add_NewBrowserVersionAvailable: HRESULT; stdcall;
    function Stub_remove_NewBrowserVersionAvailable: HRESULT; stdcall;
  end;

  ICoreWebView2 = interface(IUnknown)
    ['{76eceacb-0462-4d94-ac83-423a6793775e}']
    function Stub_get_Settings: HRESULT; stdcall;
    function Stub_get_Source: HRESULT; stdcall;
    function Stub_Navigate: HRESULT; stdcall;
    function Stub_NavigateToString: HRESULT; stdcall;
    function Stub_add_NavigationStarting: HRESULT; stdcall;
    function Stub_remove_NavigationStarting: HRESULT; stdcall;
    function Stub_add_ContentLoading: HRESULT; stdcall;
    function Stub_remove_ContentLoading: HRESULT; stdcall;
    function Stub_add_SourceChanged: HRESULT; stdcall;
    function Stub_remove_SourceChanged: HRESULT; stdcall;
    function Stub_add_HistoryChanged: HRESULT; stdcall;
    function Stub_remove_HistoryChanged: HRESULT; stdcall;
    function Stub_add_NavigationCompleted: HRESULT; stdcall;
    function Stub_remove_NavigationCompleted: HRESULT; stdcall;
    function Stub_add_FrameNavigationStarting: HRESULT; stdcall;
    function Stub_remove_FrameNavigationStarting: HRESULT; stdcall;
    function Stub_add_FrameNavigationCompleted: HRESULT; stdcall;
    function Stub_remove_FrameNavigationCompleted: HRESULT; stdcall;
    function Stub_add_ScriptDialogOpening: HRESULT; stdcall;
    function Stub_remove_ScriptDialogOpening: HRESULT; stdcall;
    function Stub_add_PermissionRequested: HRESULT; stdcall;
    function Stub_remove_PermissionRequested: HRESULT; stdcall;
    function Stub_add_ProcessFailed: HRESULT; stdcall;
    function Stub_remove_ProcessFailed: HRESULT; stdcall;
    function Stub_AddScriptToExecuteOnDocumentCreated: HRESULT; stdcall;
    function Stub_RemoveScriptToExecuteOnDocumentCreated: HRESULT; stdcall;
    function Stub_ExecuteScript: HRESULT; stdcall;
    function Stub_CapturePreview: HRESULT; stdcall;
    function Stub_Reload: HRESULT; stdcall;
    function Stub_PostWebMessageAsJson: HRESULT; stdcall;
    function Stub_PostWebMessageAsString: HRESULT; stdcall;
    function Stub_add_WebMessageReceived: HRESULT; stdcall;
    function Stub_remove_WebMessageReceived: HRESULT; stdcall;
    function Stub_CallDevToolsProtocolMethod: HRESULT; stdcall;
    function Stub_get_BrowserProcessId: HRESULT; stdcall;
    function Stub_get_CanGoBack: HRESULT; stdcall;
    function Stub_get_CanGoForward: HRESULT; stdcall;
    function Stub_GoBack: HRESULT; stdcall;
    function Stub_GoForward: HRESULT; stdcall;
    function Stub_GetDevToolsProtocolEventReceiver: HRESULT; stdcall;
    function Stub_Stop: HRESULT; stdcall;
    function Stub_add_NewWindowRequested: HRESULT; stdcall;
    function Stub_remove_NewWindowRequested: HRESULT; stdcall;
    function Stub_add_DocumentTitleChanged: HRESULT; stdcall;
    function Stub_remove_DocumentTitleChanged: HRESULT; stdcall;
    function Stub_get_DocumentTitle: HRESULT; stdcall;
    function Stub_AddHostObjectToScript: HRESULT; stdcall;
    function Stub_RemoveHostObjectFromScript: HRESULT; stdcall;
    function Stub_OpenDevToolsWindow: HRESULT; stdcall;
    function Stub_add_ContainsFullScreenElementChanged: HRESULT; stdcall;
    function Stub_remove_ContainsFullScreenElementChanged: HRESULT; stdcall;
    function Stub_get_ContainsFullScreenElement: HRESULT; stdcall;
    function add_WebResourceRequested(
      eventHandler: ICoreWebView2WebResourceRequestedEventHandler;
      token: PInt64): HRESULT; stdcall;
    function remove_WebResourceRequested(token: Int64): HRESULT; stdcall;
    function AddWebResourceRequestedFilter(uri: PWideChar;
      resourceContext: Integer): HRESULT; stdcall;
    function RemoveWebResourceRequestedFilter(uri: PWideChar;
      resourceContext: Integer): HRESULT; stdcall;
    // THE LAST TWO SLOTS MATTER EVEN THOUGH NOTHING CALLS THEM: _2 inherits
    // this interface, so every slot missing here shifts get_Environment by
    // one. Leaving them out returned a non-S_OK from what was actually
    // get_ContainsFullScreenElement's neighbour, two slots early.
    function Stub_add_WindowCloseRequested: HRESULT; stdcall;
    function Stub_remove_WindowCloseRequested: HRESULT; stdcall;
  end;

  // the borrowed native handle's interface, at the pinned slot order: the
  // spike reaches ICoreWebView2 exactly as the production adapter does
  ICoreWebView2Controller = interface(IUnknown)
    ['{4d00c0d1-9434-4eb6-8078-8697a560334f}']
    function Stub_get_IsVisible: HRESULT; stdcall;
    function Stub_put_IsVisible: HRESULT; stdcall;
    function Stub_get_Bounds: HRESULT; stdcall;
    function Stub_put_Bounds: HRESULT; stdcall;
    function Stub_get_ZoomFactor: HRESULT; stdcall;
    function Stub_put_ZoomFactor: HRESULT; stdcall;
    function Stub_add_ZoomFactorChanged: HRESULT; stdcall;
    function Stub_remove_ZoomFactorChanged: HRESULT; stdcall;
    function Stub_SetBoundsAndZoomFactor: HRESULT; stdcall;
    function Stub_MoveFocus: HRESULT; stdcall;
    function Stub_add_MoveFocusRequested: HRESULT; stdcall;
    function Stub_remove_MoveFocusRequested: HRESULT; stdcall;
    function Stub_add_GotFocus: HRESULT; stdcall;
    function Stub_remove_GotFocus: HRESULT; stdcall;
    function Stub_add_LostFocus: HRESULT; stdcall;
    function Stub_remove_LostFocus: HRESULT; stdcall;
    function Stub_add_AcceleratorKeyPressed: HRESULT; stdcall;
    function Stub_remove_AcceleratorKeyPressed: HRESULT; stdcall;
    function Stub_get_ParentWindow: HRESULT; stdcall;
    function Stub_put_ParentWindow: HRESULT; stdcall;
    function Stub_NotifyParentWindowPositionChanged: HRESULT; stdcall;
    function Stub_Close: HRESULT; stdcall;
    function get_CoreWebView2(out core: ICoreWebView2): HRESULT; stdcall;
  end;

  // INHERITS ICoreWebView2, and that is not cosmetic: _2 extends _1, so its
  // own slots begin AFTER all 56 of them. Declared over IUnknown instead,
  // get_Environment lands at slot 9 and the first call is an access
  // violation - which is what the first run of this spike measured.
  ICoreWebView2_2 = interface(ICoreWebView2)
    ['{9e8f0cf8-e670-4b5e-b2bc-73e061e3184c}']
    function Stub_add_WebResourceResponseReceived: HRESULT; stdcall;
    function Stub_remove_WebResourceResponseReceived: HRESULT; stdcall;
    function Stub_NavigateWithWebResourceRequest: HRESULT; stdcall;
    function Stub_add_DOMContentLoaded: HRESULT; stdcall;
    function Stub_remove_DOMContentLoaded: HRESULT; stdcall;
    function Stub_get_CookieManager: HRESULT; stdcall;
    function get_Environment(
      out environment: ICoreWebView2Environment): HRESULT; stdcall;
  end;

function SHCreateMemStream(pInit: PByte; cbInit: LongWord): Pointer;
  stdcall; external 'shlwapi.dll' name 'SHCreateMemStream';

type
  { ---- the lazy response body ---- }

  TLazyStream = class(TInterfacedObject, IPWebSeqStream, IPWebStream)
  private
    fPlan: TBlobPlan;
    fTag: RawUtf8;
    fPos: Int64;
    fTotal: Int64;      // -1 when the plan declares no length
    fStartMicros: Int64;
    fLock: TRTLCriticalSection;
    fReads: Integer;
    fProduced: Integer;
    fSse: RawByteString; // materialised SSE frames, produced on schedule
    function ChunkDueMicros(Index: Integer): Int64;
  public
    constructor Create(const APlan: TBlobPlan; const ATag: RawUtf8);
    destructor Destroy; override;
    function Read(pv: Pointer; cb: LongWord;
      pcbRead: PLongWord): HRESULT; stdcall;
    function Write(pv: Pointer; cb: LongWord;
      pcbWritten: PLongWord): HRESULT; stdcall;
    function Seek(dlibMove: Int64; dwOrigin: LongWord;
      plibNewPosition: PInt64): HRESULT; stdcall;
    function SetSize(libNewSize: Int64): HRESULT; stdcall;
    function CopyTo(stm: IPWebStream; cb: Int64; pcbRead: PInt64;
      pcbWritten: PInt64): HRESULT; stdcall;
    function Commit(grfCommitFlags: LongWord): HRESULT; stdcall;
    function Revert: HRESULT; stdcall;
    function LockRegion(libOffset: Int64; cb: Int64;
      dwLockType: LongWord): HRESULT; stdcall;
    function UnlockRegion(libOffset: Int64; cb: Int64;
      dwLockType: LongWord): HRESULT; stdcall;
    function Stat(pstatstg: PPWebStatStg;
      grfStatFlag: LongWord): HRESULT; stdcall;
    function Clone(out stm: IPWebStream): HRESULT; stdcall;
  end;

var
  SpikeSeq: Integer;
  GuiThreadId: DWord;
  FactLock: TRTLCriticalSection;
  FactMethods: RawUtf8;
  FactHeaderObjects: Integer;
  FactContentStreams: Integer;
  FactReadThreads: RawUtf8;
  FactBlobAuthorityRequests: Integer;

procedure NoteThread(Id: DWord);
var
  s: RawUtf8;
begin
  if Id = GuiThreadId then
    s := 'gui,'
  else
    s := 'worker:' + RawUtf8(IntToStr(Id)) + ',';
  EnterCriticalSection(FactLock);
  try
    if Pos(s, FactReadThreads) = 0 then
      FactReadThreads := FactReadThreads + s;
  finally
    LeaveCriticalSection(FactLock);
  end;
end;

procedure NoteMethod(const M: RawUtf8; Headers, Content: Boolean);
begin
  EnterCriticalSection(FactLock);
  try
    if (M <> '') and (Pos(M + ',', FactMethods) = 0) then
      FactMethods := FactMethods + M + ',';
    if Headers then
      Inc(FactHeaderObjects);
    if Content then
      Inc(FactContentStreams);
  finally
    LeaveCriticalSection(FactLock);
  end;
end;

function SpikeFactsJson: RawUtf8;
begin
  EnterCriticalSection(FactLock);
  try
    Result :=
      '"methods_seen": ' + JsonQuote(FactMethods) + ',' + #10 +
      '    "requests_with_headers": ' + RawUtf8(IntToStr(FactHeaderObjects)) +
      ',' + #10 +
      '    "requests_with_body": ' + RawUtf8(IntToStr(FactContentStreams)) +
      ',' + #10 +
      '    "istream_read_threads": ' + JsonQuote(FactReadThreads) + ',' + #10 +
      '    "second_authority_requests": ' +
      RawUtf8(IntToStr(FactBlobAuthorityRequests));
  finally
    LeaveCriticalSection(FactLock);
  end;
end;

{ ---- TLazyStream ---- }

constructor TLazyStream.Create(const APlan: TBlobPlan; const ATag: RawUtf8);
var
  i: Integer;
begin
  inherited Create;
  InitCriticalSection(fLock);
  fPlan := APlan;
  fTag := ATag;
  fPos := 0;
  fTotal := APlan.Total;
  fStartMicros := NowMicros;
  if APlan.Kind = bpkSse then
  begin
    // the frames are built once and released on schedule; the schedule, not
    // the buffer, is what makes the row a streaming measurement
    fSse := '';
    for i := 0 to APlan.Chunks - 1 do
      fSse := fSse + RawByteString(SseFrame(i, 0));
    fTotal := -1;
  end;
end;

destructor TLazyStream.Destroy;
begin
  Mark(fTag + '.stream_release', '', fReads);
  DoneCriticalSection(fLock);
  inherited Destroy;
end;

function TLazyStream.ChunkDueMicros(Index: Integer): Int64;
begin
  Result := fStartMicros + Int64(Index) * Int64(fPlan.DelayMs) * 1000;
end;

function TLazyStream.Read(pv: Pointer; cb: LongWord;
  pcbRead: PLongWord): HRESULT; stdcall;
var
  chunkIndex: Integer;
  available, want: Int64;
  due, deadline: Int64;
  total: Int64;
begin
  Result := S_OK;
  if pcbRead <> nil then
    pcbRead^ := 0;
  if (pv = nil) or (cb = 0) then
    exit;
  NoteThread(GetCurrentThreadId);
  EnterCriticalSection(fLock);
  try
    Inc(fReads);
    if fPlan.Kind = bpkSse then
      total := Length(fSse)
    else
      total := Int64(fPlan.Chunks) * fPlan.ChunkBytes;
    if fPos >= total then
    begin
      Mark(fTag + '.read_eof', '', fReads);
      exit; // zero bytes with S_OK IS end of stream
    end;
    // which produced chunk does the current position fall in, and is it due?
    if fPlan.Kind = bpkSse then
      chunkIndex := Integer((fPos * fPlan.Chunks) div total)
    else
      chunkIndex := Integer(fPos div fPlan.ChunkBytes);
    due := ChunkDueMicros(chunkIndex);
    deadline := NowMicros + Int64(READ_DEADLINE_MS) * 1000;
    if NowMicros < due then
    begin
      Mark(fTag + '.read_wait', '', chunkIndex);
      // IStream::Read has no "would block": a producer that is not ready
      // can only block the calling thread, and WHICH thread that is has
      // been recorded above
      while (NowMicros < due) and (NowMicros < deadline) do
        Sleep(2);
    end;
    if fProduced <= chunkIndex then
    begin
      fProduced := chunkIndex + 1;
      Mark(fTag + '.produce', '', chunkIndex);
    end;
    // never hand over more than the current chunk in one Read: that is what
    // makes "the engine drained everything before the page saw a byte"
    // distinguishable from "the engine read as the page read"
    if fPlan.Kind = bpkSse then
      available := ((Int64(chunkIndex) + 1) * total) div fPlan.Chunks - fPos
    else
      available := Int64(chunkIndex + 1) * fPlan.ChunkBytes - fPos;
    want := cb;
    if want > available then
      want := available;
    if want > total - fPos then
      want := total - fPos;
    if fPlan.Kind = bpkSse then
      Move(PByte(fSse)[fPos], pv^, want)
    else
      FillPlanRange(fPlan, PByte(pv), fPos, want);
    Inc(fPos, want);
    if pcbRead <> nil then
      pcbRead^ := LongWord(want);
    Mark(fTag + '.read', '', want);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TLazyStream.Write(pv: Pointer; cb: LongWord;
  pcbWritten: PLongWord): HRESULT; stdcall;
begin
  if pcbWritten <> nil then
    pcbWritten^ := 0;
  Result := HRESULT($80070005); // E_ACCESSDENIED: a response body is read-only
end;

function TLazyStream.Seek(dlibMove: Int64; dwOrigin: LongWord;
  plibNewPosition: PInt64): HRESULT; stdcall;
var
  total, target: Int64;
begin
  Result := S_OK;
  EnterCriticalSection(fLock);
  try
    if fPlan.Kind = bpkSse then
      total := Length(fSse)
    else
      total := Int64(fPlan.Chunks) * fPlan.ChunkBytes;
    case dwOrigin of
      STREAM_SEEK_SET: target := dlibMove;
      STREAM_SEEK_CUR: target := fPos + dlibMove;
      STREAM_SEEK_END: target := total + dlibMove;
    else
      begin
        Result := E_INVALIDARG;
        exit;
      end;
    end;
    if (target < 0) or (target > total) then
    begin
      Result := E_INVALIDARG;
      exit;
    end;
    fPos := target;
    if plibNewPosition <> nil then
      plibNewPosition^ := fPos;
    // a Seek on the RESPONSE body is itself a finding: an engine that seeks
    // is an engine that will not accept a non-seekable producer
    Mark(fTag + '.seek', '', target);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TLazyStream.SetSize(libNewSize: Int64): HRESULT; stdcall;
begin
  Result := HRESULT($80070005);
end;

function TLazyStream.CopyTo(stm: IPWebStream; cb: Int64; pcbRead: PInt64;
  pcbWritten: PInt64): HRESULT; stdcall;
begin
  Mark(fTag + '.copyto', '', cb);
  Result := E_NOTIMPL;
end;

function TLazyStream.Commit(grfCommitFlags: LongWord): HRESULT; stdcall;
begin
  Result := S_OK;
end;

function TLazyStream.Revert: HRESULT; stdcall;
begin
  Result := S_OK;
end;

function TLazyStream.LockRegion(libOffset: Int64; cb: Int64;
  dwLockType: LongWord): HRESULT; stdcall;
begin
  Result := E_NOTIMPL;
end;

function TLazyStream.UnlockRegion(libOffset: Int64; cb: Int64;
  dwLockType: LongWord): HRESULT; stdcall;
begin
  Result := E_NOTIMPL;
end;

function TLazyStream.Stat(pstatstg: PPWebStatStg;
  grfStatFlag: LongWord): HRESULT; stdcall;
begin
  if pstatstg = nil then
  begin
    Result := E_INVALIDARG;
    exit;
  end;
  FillChar(pstatstg^, SizeOf(pstatstg^), 0);
  pstatstg^.dwType := 2; // STGTY_STREAM
  if fPlan.Kind = bpkSse then
    pstatstg^.cbSize := Length(fSse)
  else
    pstatstg^.cbSize := Int64(fPlan.Chunks) * fPlan.ChunkBytes;
  Mark(fTag + '.stat', '', pstatstg^.cbSize);
  Result := S_OK;
end;

function TLazyStream.Clone(out stm: IPWebStream): HRESULT; stdcall;
begin
  stm := nil;
  Mark(fTag + '.clone');
  Result := E_NOTIMPL;
end;

{ ---- the event handler ---- }

type
  TSpikeRequestedHandler = class(TInterfacedObject,
    ICoreWebView2WebResourceRequestedEventHandler)
  private
    fOwner: TSpikeWv2Handler;
  public
    constructor Create(AOwner: TSpikeWv2Handler);
    function Invoke(sender: IUnknown;
      args: ICoreWebView2WebResourceRequestedEventArgs): HRESULT; stdcall;
  end;

procedure CoTaskFree(p: Pointer); stdcall;
  external 'ole32.dll' name 'CoTaskMemFree';

constructor TSpikeRequestedHandler.Create(AOwner: TSpikeWv2Handler);
begin
  inherited Create;
  fOwner := AOwner;
end;

function BuildHeaderBlock(const ContentType: RawUtf8; BodyLen: Int64;
  Partial, Ranged: Boolean; First, Last, Total: Int64): WideString;
var
  s: RawUtf8;
begin
  s := 'Content-Type: ' + ContentType + #13#10 +
       'Cache-Control: no-store' + #13#10;
  if BodyLen >= 0 then
    s := s + 'Content-Length: ' + RawUtf8(IntToStr(BodyLen)) + #13#10;
  if Ranged then
    s := s + 'Accept-Ranges: bytes' + #13#10;
  if Partial then
    s := s + 'Content-Range: bytes ' + RawUtf8(IntToStr(First)) + '-' +
      RawUtf8(IntToStr(Last)) + '/' + RawUtf8(IntToStr(Total)) + #13#10;
  // the production policy block rides every response of this spike too
  s := s + PWebNativeSecurityHeaders;
  Result := WideString(Utf8ToSynUnicode(s));
end;

function ReadRequestBody(const content: IPWebStream; out Received: Int64;
  out Chunks: Integer; out PatternOk: Boolean; out FirstByte: Integer): Boolean;
const
  BODY_BUF = 256 * 1024;
var
  buf: PByte;
  got: LongWord;
  hr: HRESULT;
  i: LongWord;
begin
  Received := 0;
  Chunks := 0;
  PatternOk := True;
  FirstByte := -1;
  Result := content <> nil;
  if not Result then
    exit;
  GetMem(buf, BODY_BUF);
  try
    repeat
      got := 0;
      hr := content.Read(buf, BODY_BUF, @got);
      if (hr <> S_OK) and (hr <> HRESULT(1)) then // S_FALSE == 1
        break;
      if got = 0 then
        break;
      Inc(Chunks);
      if (Received = 0) and (got > 0) then
        FirstByte := buf[0];
      for i := 0 to got - 1 do
        if buf[i] <> BlobByte(Received + i) then
        begin
          PatternOk := False;
          break;
        end;
      Inc(Received, got);
      Mark('m3.read', '', Received);
    until False;
  finally
    FreeMem(buf);
  end;
end;

function TSpikeRequestedHandler.Invoke(sender: IUnknown;
  args: ICoreWebView2WebResourceRequestedEventArgs): HRESULT; stdcall;
var
  request: ICoreWebView2WebResourceRequest;
  headers: ICoreWebView2HttpRequestHeaders;
  content: IPWebStream;
  response: ICoreWebView2WebResourceResponse;
  lazy: IPWebStream;
  uriW, methodW, rangeW: PWideChar;
  uri, logical, id, method, rangeHeader, contentType, tag: RawUtf8;
  plan: TBlobPlan;
  asset: TAssetResponse;
  body: RawByteString;
  stream: Pointer;
  headerBlock: WideString;
  status, seq, chunks, firstByte: Integer;
  first, last, count, total, received, declared: Int64;
  patternOk, partial, ranged, served: Boolean;
  json: RawUtf8;
begin
  Result := S_OK; // never a Pascal exception across the COM boundary
  seq := InterlockedIncrement(SpikeSeq);
  served := False;
  try
    if (fOwner = nil) or (fOwner.fStore = nil) or
       (fOwner.fEnvironment = nil) or (args = nil) then
      exit;
    if (args.get_Request(request) <> S_OK) or (request = nil) then
      exit;
    uriW := nil;
    if (request.get_Uri(uriW) <> S_OK) or (uriW = nil) then
      exit;
    uri := RawUnicodeToUtf8(uriW, StrLenW(uriW));
    CoTaskFree(uriW);
    Mark('req.enter', uri, seq);

    method := '';
    methodW := nil;
    if (request.get_Method(methodW) = S_OK) and (methodW <> nil) then
    begin
      method := RawUnicodeToUtf8(methodW, StrLenW(methodW));
      CoTaskFree(methodW);
    end;
    Mark('req.got_method', method, seq);

    rangeHeader := '';
    headers := nil;
    if (request.get_Headers(headers) = S_OK) and (headers <> nil) then
    begin
      rangeW := nil;
      if (headers.GetHeader('Range', rangeW) = S_OK) and (rangeW <> nil) then
      begin
        rangeHeader := RawUnicodeToUtf8(rangeW, StrLenW(rangeW));
        CoTaskFree(rangeW);
      end;
    end;
    Mark('req.read_range', rangeHeader, seq);

    content := nil;
    request.get_Content(content);
    Mark('req.got_body', '', seq);
    NoteMethod(method, headers <> nil, content <> nil);

    Mark('req.open', uri, seq);
    if rangeHeader <> '' then
      Mark('req.range', rangeHeader, seq);

    if not PWebParseAppUri(uri, logical) then
    begin
      // the SECOND-AUTHORITY filter is why this branch exists at all: a
      // request that reached here for pweb://blob/... would mean the CSP
      // did NOT refuse it
      InterlockedIncrement(FactBlobAuthorityRequests);
      Mark('req.refused', uri, seq);
      exit;
    end;

    status := 200;
    partial := False;
    ranged := False;
    first := 0;
    last := 0;
    total := 0;
    declared := -1;
    body := '';
    contentType := 'application/octet-stream';
    tag := 'blob' + RawUtf8(IntToStr(seq));

    if BlobPathId(logical, id) and ParseBlobPlan(id, plan) then
    begin
      contentType := plan.ContentType;
      case plan.Kind of
        bpkEcho:
          begin
            ReadRequestBody(content, received, chunks, patternOk, firstByte);
            json := '{"received":' + RawUtf8(IntToStr(received)) +
              ',"chunks":' + RawUtf8(IntToStr(chunks)) +
              ',"first_byte":' + RawUtf8(IntToStr(firstByte)) +
              ',"pattern_ok":' + JsonBool(patternOk) +
              ',"read_us":0}';
            body := RawByteString(json);
            contentType := 'application/json';
            declared := Length(body);
            Mark('m3.finished', '', received);
          end;
        bpkStream, bpkSse:
          begin
            // THE LAZY STREAM. The response is set immediately; the engine
            // then pulls, and every pull is on the timeline.
            lazy := TLazyStream.Create(plan, tag);
            declared := plan.Total; // -1 for the no-length row
            // WHAT THE HANDLER ITSELF HOLDS to answer this request, counted
            // rather than inferred from RSS: the lazy stream fills the
            // engine's own Read buffer, so it holds nothing at all. (The SSE
            // plan is the exception and says so with its own figure.)
            if plan.Kind = bpkSse then
              Mark(tag + '.materialised', 'sse frames', plan.Chunks * 96)
            else
              Mark(tag + '.materialised', 'lazy stream, no body buffer', 0);
            Mark(tag + '.respond_lazy', plan.Id, plan.Total);
            headerBlock := BuildHeaderBlock(contentType, declared,
              False, False, 0, 0, 0);
            if ICoreWebView2Environment(fOwner.fEnvironment).
                 CreateWebResourceResponse(Pointer(lazy), 200, 'OK',
                   PWideChar(headerBlock), response) <> S_OK then
              exit;
            if args.put_Response(response) <> S_OK then
              exit;
            served := True;
            Mark('req.close', logical, seq);
            exit;
          end;
        bpkWhole, bpkWav, bpkPng:
          begin
            total := plan.Total;
            ranged := plan.Ranged;
            if plan.Ranged and (rangeHeader <> '') and
               ParseSingleRange(rangeHeader, plan.Total, first, last) then
            begin
              count := last - first + 1;
              SetLength(body, count);
              FillPlanRange(plan, PByte(body), first, count);
              status := 206;
              partial := True;
              Mark(tag + '.materialised', 'window + SHCreateMemStream copy',
                2 * count);
              Mark(tag + '.respond206', rangeHeader, count);
            end
            else
            begin
              body := BuildWholeBody(plan);
              first := 0;
              last := plan.Total - 1;
              // the whole body twice: the Pascal string, and the copy
              // SHCreateMemStream takes - the frozen seam's own doubling
              Mark(tag + '.materialised', 'whole body + SHCreateMemStream copy',
                2 * Int64(Length(body)));
              Mark(tag + '.respond200', plan.Id, plan.Total);
            end;
            declared := Length(body);
          end;
      else
        begin
          Mark('req.notfound', logical, seq);
          exit;
        end;
      end;
    end
    else if fOwner.fStore.TryRead(logical, asset) then
    begin
      body := asset.Content;
      contentType := asset.ContentType;
      declared := Length(body);
    end
    else
    begin
      Mark('req.notfound', logical, seq);
      exit;
    end;

    stream := SHCreateMemStream(PByte(body), Length(body));
    if stream = nil then
      exit;
    try
      headerBlock := BuildHeaderBlock(contentType, declared, partial, ranged,
        first, last, total);
      if ICoreWebView2Environment(fOwner.fEnvironment).
           CreateWebResourceResponse(stream, status,
             PWideChar(WideString(IntToStr(status))), PWideChar(headerBlock),
             response) <> S_OK then
        exit;
      if args.put_Response(response) <> S_OK then
        exit;
      served := True;
    finally
      IUnknown(stream)._Release;
    end;
    Mark('req.close', logical, seq);
  except
    on E: Exception do
      try
        Mark('req.exception', RawUtf8(E.Message), seq);
      except
      end;
  end;
  if not served then
    try
      Mark('req.unhandled', '', seq);
    except
    end;
end;

{ ---- TSpikeWv2Handler ---- }

constructor TSpikeWv2Handler.Create(AWebView: webview_t;
  const AStore: IAssetStore);
var
  core: ICoreWebView2;
  core2: ICoreWebView2_2;
  env: ICoreWebView2Environment;
  handlerObj: TSpikeRequestedHandler;
  handlerIntf: ICoreWebView2WebResourceRequestedEventHandler;
  hr: HRESULT;
begin
  inherited Create;
  if AWebView = nil then
    raise ESpikeWv2.Create('webview handle is nil');
  if AStore = nil then
    raise ESpikeWv2.Create('asset store is nil');
  fThreadId := GetCurrentThreadId;
  GuiThreadId := fThreadId;
  fStore := AStore;
  fController := webview_get_native_handle(AWebView,
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if fController = nil then
    raise ESpikeWv2.Create('borrowed browser controller is unavailable');
  // the controller stays borrowed: method calls only, no AddRef
  hr := ICoreWebView2Controller(fController).get_CoreWebView2(core);
  if (hr <> S_OK) or (core = nil) then
    raise ESpikeWv2.CreateFmt('get_CoreWebView2 failed: 0x%x', [hr]);
  fCore := core;
  if core.QueryInterface(ICoreWebView2_2, core2) <> S_OK then
    raise ESpikeWv2.Create('ICoreWebView2_2 is unavailable');
  if (core2.get_Environment(env) <> S_OK) or (env = nil) then
    raise ESpikeWv2.Create('ICoreWebView2Environment is unavailable');
  fEnvironment := env;

  hr := core.AddWebResourceRequestedFilter(PWideChar(PWEB_APP_FILTER),
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  if hr <> S_OK then
    raise ESpikeWv2.CreateFmt('AddWebResourceRequestedFilter failed: 0x%x',
      [hr]);
  Inc(fFilters);
  if core.AddWebResourceRequestedFilter(PWideChar(PWEB_BLOB_FILTER),
       COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL) = S_OK then
    Inc(fFilters);

  // THE ASSIGNMENT IS AN IMPLICIT CONVERSION, NOT A CAST. An earlier
  // revision wrote ICoreWebView2...EventHandler(handlerObj), which is a
  // hard typecast of an OBJECT reference to an interface type: it hands
  // WebView2 the object pointer instead of the interface pointer, and the
  // first vtable call through it is an access violation before one row
  // has run.
  handlerObj := TSpikeRequestedHandler.Create(Self);
  handlerIntf := handlerObj;
  fHandler := handlerIntf;
  hr := core.add_WebResourceRequested(handlerIntf, @fToken);
  if hr <> S_OK then
    raise ESpikeWv2.CreateFmt('add_WebResourceRequested failed: 0x%x', [hr]);
  fAttached := True;
end;

destructor TSpikeWv2Handler.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TSpikeWv2Handler.Detach;
var
  core: ICoreWebView2;
begin
  if not fAttached then
    exit;
  fAttached := False;
  if GetCurrentThreadId = fThreadId then
  begin
    core := ICoreWebView2(fCore);
    if core <> nil then
    begin
      core.remove_WebResourceRequested(fToken);
      core.RemoveWebResourceRequestedFilter(PWideChar(PWEB_APP_FILTER),
        COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
      if fFilters > 1 then
        core.RemoveWebResourceRequestedFilter(PWideChar(PWEB_BLOB_FILTER),
          COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    end;
  end;
  fHandler := nil;
  fEnvironment := nil;
  fCore := nil;
  fController := nil;
  fStore := nil;
end;

initialization
  InitCriticalSection(FactLock);

finalization
  DoneCriticalSection(FactLock);

end.
