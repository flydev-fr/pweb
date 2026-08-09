program error_helper_test;

{ Headless runtime test for the raw-layer error helpers (CAP-1).

  Verifies against pweb.lib.webview.errors:
  - WebViewCheck raises EWebViewError for every negative pinned code, with
    Code and Operation preserved unmodified;
  - WebViewCheck passes 0 and the positive informational codes (DUPLICATE,
    NOT_FOUND) through unchanged, without raising;
  - WebViewSucceeded / WebViewFailed mirror the upstream macros;
  - WebViewCheckCreated(nil) raises; a non-nil handle passes through;
  - WebViewErrorName names all pinned codes and falls back numerically.

  No webview.dll required. Exit code 0 = all assertions hold; 1 otherwise. }

{$MODE OBJFPC}{$H+}

uses
  SysUtils,
  pweb.lib.webview,
  pweb.lib.webview.errors;

var
  FailCount: Integer = 0;

procedure Check(const Cond: Boolean; const What: string);
begin
  if Cond then
    WriteLn('ok   ', What)
  else
  begin
    WriteLn('FAIL ', What);
    Inc(FailCount);
  end;
end;

procedure CheckRaises(const Code: webview_error_t);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    WebViewCheck(Code, 'op_under_test');
  except
    on E: EWebViewError do
    begin
      Raised := True;
      Check(E.Code = Code,
        Format('raise preserves code %d (got %d)', [Code, E.Code]));
      Check(E.Operation = 'op_under_test',
        Format('raise preserves operation for code %d', [Code]));
    end;
  end;
  Check(Raised, Format('WebViewCheck(%d) raises EWebViewError', [Code]));
end;

procedure CheckPasses(const Code: webview_error_t);
var
  Got: webview_error_t;
begin
  try
    Got := WebViewCheck(Code, 'op_under_test');
    Check(Got = Code,
      Format('WebViewCheck(%d) returns the original code (got %d)', [Code, Got]));
  except
    on E: Exception do
    begin
      Check(False, Format('WebViewCheck(%d) must not raise (%s)', [Code, E.Message]));
    end;
  end;
end;

var
  Raised: Boolean;
  Dummy: Integer;
  H: webview_t;
begin
  { negative codes raise, code + operation preserved }
  CheckRaises(WEBVIEW_ERROR_MISSING_DEPENDENCY);
  CheckRaises(WEBVIEW_ERROR_CANCELED);
  CheckRaises(WEBVIEW_ERROR_INVALID_STATE);
  CheckRaises(WEBVIEW_ERROR_INVALID_ARGUMENT);
  CheckRaises(WEBVIEW_ERROR_UNSPECIFIED);

  { zero and positive informational codes pass through unchanged }
  CheckPasses(WEBVIEW_ERROR_OK);
  CheckPasses(WEBVIEW_ERROR_DUPLICATE);
  CheckPasses(WEBVIEW_ERROR_NOT_FOUND);

  { macro mirrors }
  Check(WebViewSucceeded(WEBVIEW_ERROR_OK), 'WebViewSucceeded(0)');
  Check(WebViewSucceeded(WEBVIEW_ERROR_DUPLICATE), 'WebViewSucceeded(1)');
  Check(WebViewSucceeded(WEBVIEW_ERROR_NOT_FOUND), 'WebViewSucceeded(2)');
  Check(not WebViewSucceeded(WEBVIEW_ERROR_UNSPECIFIED), 'not WebViewSucceeded(-1)');
  Check(WebViewFailed(WEBVIEW_ERROR_MISSING_DEPENDENCY), 'WebViewFailed(-5)');
  Check(not WebViewFailed(WEBVIEW_ERROR_OK), 'not WebViewFailed(0)');
  Check(not WebViewFailed(WEBVIEW_ERROR_DUPLICATE), 'not WebViewFailed(1)');

  { nil-handling for webview_create }
  Raised := False;
  try
    WebViewCheckCreated(nil);
  except
    on E: EWebViewError do
    begin
      Raised := True;
      Check(E.Code = WEBVIEW_ERROR_UNSPECIFIED,
        'WebViewCheckCreated(nil) carries WEBVIEW_ERROR_UNSPECIFIED');
    end;
  end;
  Check(Raised, 'WebViewCheckCreated(nil) raises');

  H := WebViewCheckCreated(webview_t(@Dummy));
  Check(H = webview_t(@Dummy), 'WebViewCheckCreated passes a non-nil handle through');

  { error names: all pinned codes covered, numeric fallback for unknowns }
  Check(WebViewErrorName(WEBVIEW_ERROR_MISSING_DEPENDENCY) = 'WEBVIEW_ERROR_MISSING_DEPENDENCY', 'name -5');
  Check(WebViewErrorName(WEBVIEW_ERROR_CANCELED) = 'WEBVIEW_ERROR_CANCELED', 'name -4');
  Check(WebViewErrorName(WEBVIEW_ERROR_INVALID_STATE) = 'WEBVIEW_ERROR_INVALID_STATE', 'name -3');
  Check(WebViewErrorName(WEBVIEW_ERROR_INVALID_ARGUMENT) = 'WEBVIEW_ERROR_INVALID_ARGUMENT', 'name -2');
  Check(WebViewErrorName(WEBVIEW_ERROR_UNSPECIFIED) = 'WEBVIEW_ERROR_UNSPECIFIED', 'name -1');
  Check(WebViewErrorName(WEBVIEW_ERROR_OK) = 'WEBVIEW_ERROR_OK', 'name 0');
  Check(WebViewErrorName(WEBVIEW_ERROR_DUPLICATE) = 'WEBVIEW_ERROR_DUPLICATE', 'name 1');
  Check(WebViewErrorName(WEBVIEW_ERROR_NOT_FOUND) = 'WEBVIEW_ERROR_NOT_FOUND', 'name 2');
  Check(WebViewErrorName(-999) = 'webview_error_t(-999)', 'numeric fallback');

  if FailCount > 0 then
  begin
    WriteLn('error_helper_test: FAIL (', FailCount, ' assertion(s))');
    Halt(1);
  end;
  WriteLn('error_helper_test: PASS');
end.
