unit pweb.lib.webview.errors;

{ Error view over the generated raw binding (pweb.lib.webview.pas), plus the
  raw-layer error helper.

  The type and constants are pure aliases of identifiers in the
  chet-cli-generated core unit -- no ABI fact is restated here. WebViewSucceeded
  / WebViewFailed mirror upstream's WEBVIEW_SUCCEEDED / WEBVIEW_FAILED
  function-like macros (macros.h), which chet-cli cannot translate.

  Raw layer rules apply: RTL only -- no framework type from any higher layer
  may appear here. EWebViewError derives from the plain RTL Exception and
  preserves the original webview_error_t code untouched. }

{$MODE OBJFPC}{$H+}

interface

uses
  SysUtils,
  pweb.lib.webview;

type
  /// 4-byte signed error code (negative codes are failures at the pinned ABI).
  webview_error_t = pweb.lib.webview.webview_error_t;
  Pwebview_error_t = pweb.lib.webview.Pwebview_error_t;

const
  WEBVIEW_ERROR_MISSING_DEPENDENCY = pweb.lib.webview.WEBVIEW_ERROR_MISSING_DEPENDENCY;
  WEBVIEW_ERROR_CANCELED           = pweb.lib.webview.WEBVIEW_ERROR_CANCELED;
  WEBVIEW_ERROR_INVALID_STATE      = pweb.lib.webview.WEBVIEW_ERROR_INVALID_STATE;
  WEBVIEW_ERROR_INVALID_ARGUMENT   = pweb.lib.webview.WEBVIEW_ERROR_INVALID_ARGUMENT;
  WEBVIEW_ERROR_UNSPECIFIED        = pweb.lib.webview.WEBVIEW_ERROR_UNSPECIFIED;
  WEBVIEW_ERROR_OK                 = pweb.lib.webview.WEBVIEW_ERROR_OK;
  WEBVIEW_ERROR_DUPLICATE          = pweb.lib.webview.WEBVIEW_ERROR_DUPLICATE;
  WEBVIEW_ERROR_NOT_FOUND          = pweb.lib.webview.WEBVIEW_ERROR_NOT_FOUND;

type
  /// Raised by WebViewCheck / WebViewCheckCreated. Carries the original
  /// upstream error code unmodified.
  EWebViewError = class(Exception)
  private
    FCode: webview_error_t;
    FOperation: string;
  public
    constructor Create(ACode: webview_error_t; const AOperation: string);
    /// The unmodified webview_error_t returned by the C entry point.
    property Code: webview_error_t read FCode;
    /// Name of the C entry point that failed (e.g. 'webview_set_title').
    property Operation: string read FOperation;
  end;

/// Pascal equivalent of upstream WEBVIEW_SUCCEEDED(error): success or
/// additional information (code >= 0).
function WebViewSucceeded(const Code: webview_error_t): Boolean; inline;

/// Pascal equivalent of upstream WEBVIEW_FAILED(error): failure (code < 0).
function WebViewFailed(const Code: webview_error_t): Boolean; inline;

/// Central raw-layer check. Raises EWebViewError when Code indicates failure
/// (Code < 0, upstream WEBVIEW_FAILED semantics) and otherwise returns the
/// ORIGINAL code unchanged, so informational non-zero codes such as
/// WEBVIEW_ERROR_DUPLICATE / WEBVIEW_ERROR_NOT_FOUND stay visible to callers
/// that want to inspect them.
function WebViewCheck(const Code: webview_error_t;
  const Operation: string): webview_error_t;

/// Explicit nil-handling for webview_create: upstream signals creation
/// failure by returning NULL (e.g. WebView2 runtime missing, window creation
/// failure), not through an error code. Raises EWebViewError when Handle is
/// nil, carrying WEBVIEW_ERROR_UNSPECIFIED -- upstream does not report which
/// failure occurred, so no more specific code is invented. Otherwise returns
/// Handle unchanged.
function WebViewCheckCreated(const Handle: webview_t): webview_t;

/// Human-readable name for a webview_error_t (falls back to the number).
function WebViewErrorName(const Code: webview_error_t): string;

implementation

function WebViewSucceeded(const Code: webview_error_t): Boolean;
begin
  Result := Code >= 0;
end;

function WebViewFailed(const Code: webview_error_t): Boolean;
begin
  Result := Code < 0;
end;

function WebViewErrorName(const Code: webview_error_t): string;
begin
  case Code of
    WEBVIEW_ERROR_MISSING_DEPENDENCY: Result := 'WEBVIEW_ERROR_MISSING_DEPENDENCY';
    WEBVIEW_ERROR_CANCELED:           Result := 'WEBVIEW_ERROR_CANCELED';
    WEBVIEW_ERROR_INVALID_STATE:      Result := 'WEBVIEW_ERROR_INVALID_STATE';
    WEBVIEW_ERROR_INVALID_ARGUMENT:   Result := 'WEBVIEW_ERROR_INVALID_ARGUMENT';
    WEBVIEW_ERROR_UNSPECIFIED:        Result := 'WEBVIEW_ERROR_UNSPECIFIED';
    WEBVIEW_ERROR_OK:                 Result := 'WEBVIEW_ERROR_OK';
    WEBVIEW_ERROR_DUPLICATE:          Result := 'WEBVIEW_ERROR_DUPLICATE';
    WEBVIEW_ERROR_NOT_FOUND:          Result := 'WEBVIEW_ERROR_NOT_FOUND';
  else
    Result := 'webview_error_t(' + IntToStr(Code) + ')';
  end;
end;

constructor EWebViewError.Create(ACode: webview_error_t;
  const AOperation: string);
begin
  inherited CreateFmt('%s failed: %s (%d)',
    [AOperation, WebViewErrorName(ACode), ACode]);
  FCode := ACode;
  FOperation := AOperation;
end;

function WebViewCheck(const Code: webview_error_t;
  const Operation: string): webview_error_t;
begin
  if WebViewFailed(Code) then
    raise EWebViewError.Create(Code, Operation);
  Result := Code;
end;

function WebViewCheckCreated(const Handle: webview_t): webview_t;
begin
  if Handle = nil then
    raise EWebViewError.Create(WEBVIEW_ERROR_UNSPECIFIED,
      'webview_create (returned nil: missing WebView2 runtime or window creation failure)');
  Result := Handle;
end;

end.
