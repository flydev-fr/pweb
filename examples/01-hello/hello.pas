program hello;

{ CAP-1 Windows x64 smoke: drive the raw generated binding end to end.

  create -> nil check -> set_title 'PWeb' -> set_size -> set_html (Hello
  marker) -> run -> terminate -> destroy -> clean exit. Every
  error-returning call goes through WebViewCheck; webview_create nil is
  handled explicitly by WebViewCheckCreated.

  Raw layer only: no mORMot, no IWebView, no scheduler. This example proves
  the ABI, nothing more.

  PWEB_SMOKE_AUTOCLOSE_MS=<n> closes the window automatically after n
  milliseconds. The close request travels background thread ->
  webview_dispatch -> webview_terminate on the GUI thread: at the pinned
  commit, Windows terminate_impl() is PostQuitMessage(0), which only affects
  the CALLING thread's message queue -- so webview_terminate called directly
  from a background thread does NOT stop the loop on Windows, despite the
  api.h thread-safety remark (measured; see
  docs/webview-upstream-semantics.md). webview_dispatch is a PostMessageW and
  is genuinely cross-thread. Unset, the window stays until the user closes it
  (human gate). }

{$MODE OBJFPC}{$H+}

uses
  SysUtils,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors;

const
  HELLO_HTML: AnsiString =
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<title>PWeb</title></head><body style="font-family:sans-serif">' +
    '<h1 id="pweb-hello">Hello Pascal/PWeb</h1>' +
    '<p>CAP-1 smoke: raw webview/webview binding driven from FPC.</p>' +
    '</body></html>';

const
  { keep unattended runs bounded: cap the requested auto-close delay }
  MAX_AUTOCLOSE_MS = 60000;
  { wait margin for the closer thread beyond its own sleep }
  CLOSER_WAIT_MARGIN_MS = 10000;

var
  { written once before the closer starts; claimed exactly once via
    InterlockedExchange (fetch-and-clear) so nil-check and use cannot race }
  AutoCloseHandle: Pointer = nil;

{ Runs on the GUI thread (scheduled by webview_dispatch). Exception barrier:
  nothing may escape into the C frame. }
procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    if WebViewFailed(webview_terminate(w)) then
      WriteLn(StdErr, 'warning: webview_terminate failed in auto-close');
  except
    { swallow: a Pascal exception must never cross the C callback frame }
  end;
end;

function AutoCloseThread(Param: Pointer): PtrInt;
var
  Ms: Integer;
  H: Pointer;
begin
  Result := 0;
  Ms := PtrInt(Param);
  Sleep(Ms);
  { atomically claim the handle; the main thread clears it the same way
    before destroy, so a dispatch on a dying handle is impossible }
  H := InterlockedExchange(AutoCloseHandle, nil);
  { error deliberately only logged -- the run loop may already have ended }
  if H <> nil then
    if WebViewFailed(webview_dispatch(webview_t(H),
        @TerminateOnGuiThread, nil)) then
      WriteLn(StdErr, 'warning: webview_dispatch failed in auto-close');
end;

var
  W: webview_t;
  AutoCloseMs: Integer;
  CloserId: TThreadID;
  CloserHandle: TThreadID; { BeginThread return: the waitable value on Windows }
  CloserStarted: Boolean;
  SafeToDestroy: Boolean;
begin
  ExitCode := 0;
  CloserStarted := False;
  CloserId := TThreadID(0);
  CloserHandle := TThreadID(0);
  SafeToDestroy := True;
  try
    W := WebViewCheckCreated(webview_create(0, nil));
    try
      AutoCloseHandle := Pointer(W);

      WebViewCheck(webview_set_title(W, 'PWeb'), 'webview_set_title');
      WebViewCheck(webview_set_size(W, 800, 600, WEBVIEW_HINT_NONE),
        'webview_set_size');
      WebViewCheck(webview_set_html(W, PAnsiChar(HELLO_HTML)),
        'webview_set_html');

      AutoCloseMs := StrToIntDef(GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if AutoCloseMs > MAX_AUTOCLOSE_MS then
        AutoCloseMs := MAX_AUTOCLOSE_MS;
      if AutoCloseMs > 0 then
      begin
        CloserHandle := BeginThread(@AutoCloseThread,
          Pointer(PtrInt(AutoCloseMs)), CloserId);
        CloserStarted := CloserHandle <> TThreadID(0);
        if not CloserStarted then
          WriteLn(StdErr, 'warning: BeginThread failed; auto-close disabled');
      end;

      WebViewCheck(webview_run(W), 'webview_run');
    finally
      { the closer thread may still hold the handle: it must finish (or the
        handle must be reclaimed) before destroy. Wait is bounded relative to
        the closer's own sleep. }
      if CloserStarted then
      begin
        if WaitForThreadTerminate(CloserHandle,
             AutoCloseMs + CLOSER_WAIT_MARGIN_MS) <> 0 then
        begin
          { closer did not finish: it could still dispatch on the handle.
            Destroying now would risk use-after-free -- fail loudly instead. }
          WriteLn(StdErr,
            'FAIL: auto-close thread did not terminate in time; ' +
            'skipping webview_destroy to avoid use-after-free');
          SafeToDestroy := False;
          ExitCode := 1;
        end;
        CloseThread(CloserHandle);
      end;
      InterlockedExchange(AutoCloseHandle, nil);
      if SafeToDestroy then
        try
          WebViewCheck(webview_destroy(W), 'webview_destroy');
        except
          { do not mask an in-flight exception with a destroy failure }
          on E: Exception do
          begin
            WriteLn(StdErr, 'FAIL: webview_destroy: ', E.Message);
            ExitCode := 1;
          end;
        end;
    end;
    if ExitCode = 0 then
      WriteLn('hello: clean exit');
  except
    on E: EWebViewError do
    begin
      WriteLn(StdErr, 'FAIL: ', E.Message);
      ExitCode := 1;
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
