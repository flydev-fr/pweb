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

var
  AutoCloseHandle: webview_t = nil;

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
begin
  Result := 0;
  Ms := PtrInt(Param);
  Sleep(Ms);
  { error deliberately only logged -- the run loop may already have ended }
  if AutoCloseHandle <> nil then
    if WebViewFailed(webview_dispatch(AutoCloseHandle,
        @TerminateOnGuiThread, nil)) then
      WriteLn(StdErr, 'warning: webview_dispatch failed in auto-close');
end;

var
  W: webview_t;
  AutoCloseMs: Integer;
  CloserId: TThreadID;
  CloserStarted: Boolean;
begin
  ExitCode := 0;
  CloserStarted := False;
  CloserId := TThreadID(0);
  try
    W := WebViewCheckCreated(webview_create(0, nil));
    try
      AutoCloseHandle := W;

      WebViewCheck(webview_set_title(W, 'PWeb'), 'webview_set_title');
      WebViewCheck(webview_set_size(W, 800, 600, WEBVIEW_HINT_NONE),
        'webview_set_size');
      WebViewCheck(webview_set_html(W, PAnsiChar(HELLO_HTML)),
        'webview_set_html');

      AutoCloseMs := StrToIntDef(GetEnvironmentVariable('PWEB_SMOKE_AUTOCLOSE_MS'), 0);
      if AutoCloseMs > 0 then
      begin
        BeginThread(@AutoCloseThread, Pointer(PtrInt(AutoCloseMs)), CloserId);
        CloserStarted := True;
      end;

      WebViewCheck(webview_run(W), 'webview_run');
    finally
      { the closer thread holds the handle: let it finish before destroy }
      if CloserStarted then
        WaitForThreadTerminate(CloserId, 30000);
      AutoCloseHandle := nil;
      WebViewCheck(webview_destroy(W), 'webview_destroy');
    end;
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
