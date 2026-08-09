unit pweb.test.core;

{ mormot.core.test cases for the CAP-1 raw binding layer.

  Tests may use mORMot freely; the binding under src/lib itself stays
  mORMot-free (enforced by check_binding_surface.ps1).

  Covered here:
  - ErrorHelpers: runtime contract of WebViewCheck / WebViewCheckCreated /
    WebViewSucceeded / WebViewFailed / WebViewErrorName (no webview.dll
    required -- only types and helpers are referenced);
  - SymbolCoverage: every one of the 17 public C entry points of the pinned
    upstream commit is exported by webview.dll. The DLL is resolved from the
    PWEB_WEBVIEW_DLL environment variable, defaulting to 'webview.dll'.
    Dynamic loading (no import table) keeps the failure report complete:
    every missing symbol is listed instead of the loader aborting.

  The compile-level gates stay in their dedicated programs: abi_probe.pas
  (paired byte-diff with the C probe) and signature_pin.pas (all 17
  prototypes). }

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.test,
  pweb.lib.webview,
  pweb.lib.webview.errors;

type
  /// test cases for the raw webview binding support layer
  TTestPWebCoreBinding = class(TSynTestCase)
  published
    /// WebViewCheck/WebViewCheckCreated/succeeded/failed/name helpers
    procedure ErrorHelpers;
    /// all 17 pinned C entry points are exported by webview.dll
    procedure SymbolCoverage;
  end;

implementation

const
  { The complete public C ABI of webview/webview at the pinned commit
    (cbbdee44afff22867de9fd88a9fc8350d9bdd399), core/include/webview/api.h.
    Keep in sync with the pinned header, which is the only authority
    (check_binding_surface.ps1 diffs this surface mechanically). }
  PinnedEntryPoints: array[0..16] of RawUtf8 = (
    'webview_bind',
    'webview_create',
    'webview_destroy',
    'webview_dispatch',
    'webview_eval',
    'webview_get_native_handle',
    'webview_get_window',
    'webview_init',
    'webview_navigate',
    'webview_return',
    'webview_run',
    'webview_set_html',
    'webview_set_size',
    'webview_set_title',
    'webview_terminate',
    'webview_unbind',
    'webview_version'
  );

procedure TTestPWebCoreBinding.ErrorHelpers;

  procedure CheckRaises(const Code: webview_error_t);
  var
    raised: boolean;
  begin
    raised := false;
    try
      WebViewCheck(Code, 'op_under_test');
    except
      on E: EWebViewError do
      begin
        raised := true;
        CheckEqual(E.Code, Code, 'raise preserves code');
        CheckEqual(E.Operation, 'op_under_test', 'raise preserves operation');
      end;
    end;
    CheckUtf8(raised, 'WebViewCheck(%) raises EWebViewError', [Code]);
  end;

  procedure CheckPasses(const Code: webview_error_t);
  var
    got: webview_error_t;
  begin
    try
      got := WebViewCheck(Code, 'op_under_test');
      CheckEqual(got, Code, 'WebViewCheck returns the original code');
    except
      on E: Exception do
        CheckUtf8(false, 'WebViewCheck(%) must not raise (%)', [Code, E.Message]);
    end;
  end;

var
  raised: boolean;
  dummy: integer;
  h: webview_t;
begin
  // negative codes raise, code + operation preserved
  CheckRaises(WEBVIEW_ERROR_MISSING_DEPENDENCY);
  CheckRaises(WEBVIEW_ERROR_CANCELED);
  CheckRaises(WEBVIEW_ERROR_INVALID_STATE);
  CheckRaises(WEBVIEW_ERROR_INVALID_ARGUMENT);
  CheckRaises(WEBVIEW_ERROR_UNSPECIFIED);
  // zero and positive informational codes pass through unchanged
  CheckPasses(WEBVIEW_ERROR_OK);
  CheckPasses(WEBVIEW_ERROR_DUPLICATE);
  CheckPasses(WEBVIEW_ERROR_NOT_FOUND);
  // macro mirrors
  Check(WebViewSucceeded(WEBVIEW_ERROR_OK), 'WebViewSucceeded(0)');
  Check(WebViewSucceeded(WEBVIEW_ERROR_DUPLICATE), 'WebViewSucceeded(1)');
  Check(WebViewSucceeded(WEBVIEW_ERROR_NOT_FOUND), 'WebViewSucceeded(2)');
  Check(not WebViewSucceeded(WEBVIEW_ERROR_UNSPECIFIED), 'not WebViewSucceeded(-1)');
  Check(WebViewFailed(WEBVIEW_ERROR_MISSING_DEPENDENCY), 'WebViewFailed(-5)');
  Check(not WebViewFailed(WEBVIEW_ERROR_OK), 'not WebViewFailed(0)');
  Check(not WebViewFailed(WEBVIEW_ERROR_DUPLICATE), 'not WebViewFailed(1)');
  // nil-handling for webview_create
  raised := false;
  try
    WebViewCheckCreated(nil);
  except
    on E: EWebViewError do
    begin
      raised := true;
      CheckEqual(E.Code, WEBVIEW_ERROR_UNSPECIFIED,
        'WebViewCheckCreated(nil) carries WEBVIEW_ERROR_UNSPECIFIED');
    end;
  end;
  Check(raised, 'WebViewCheckCreated(nil) raises');
  h := WebViewCheckCreated(webview_t(@dummy));
  Check(h = webview_t(@dummy), 'WebViewCheckCreated passes a non-nil handle through');
  // error names: all pinned codes covered, numeric fallback for unknowns
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_MISSING_DEPENDENCY),
    'WEBVIEW_ERROR_MISSING_DEPENDENCY');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_CANCELED), 'WEBVIEW_ERROR_CANCELED');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_INVALID_STATE),
    'WEBVIEW_ERROR_INVALID_STATE');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_INVALID_ARGUMENT),
    'WEBVIEW_ERROR_INVALID_ARGUMENT');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_UNSPECIFIED), 'WEBVIEW_ERROR_UNSPECIFIED');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_OK), 'WEBVIEW_ERROR_OK');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_DUPLICATE), 'WEBVIEW_ERROR_DUPLICATE');
  CheckEqual(WebViewErrorName(WEBVIEW_ERROR_NOT_FOUND), 'WEBVIEW_ERROR_NOT_FOUND');
  CheckEqual(WebViewErrorName(-999), 'webview_error_t(-999)', 'numeric fallback');
end;

procedure TTestPWebCoreBinding.SymbolCoverage;
var
  path: TFileName;
  lib: TLibHandle;
  p: pointer;
  i, found: PtrInt;
begin
  path := TFileName(GetEnvironmentVariable('PWEB_WEBVIEW_DLL'));
  if path = '' then
    path := 'webview.dll';
  lib := LibraryOpen(path);
  CheckUtf8(lib <> 0,
    'load % (build it with tools/build-webview-dll.ps1 or point ' +
    'PWEB_WEBVIEW_DLL at it)', [path]);
  if lib = 0 then
    exit;
  try
    found := 0;
    for i := low(PinnedEntryPoints) to high(PinnedEntryPoints) do
    begin
      p := LibraryResolve(lib, pointer(PinnedEntryPoints[i]));
      CheckUtf8(p <> nil, 'export %', [PinnedEntryPoints[i]]);
      if p <> nil then
        inc(found);
    end;
    CheckEqual(found, length(PinnedEntryPoints), 'pinned entry points exported');
  finally
    LibraryClose(lib);
  end;
end;

end.
