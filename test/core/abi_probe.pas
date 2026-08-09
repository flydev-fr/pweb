program abi_probe;

{ Pascal side of the paired ABI probe (CAP-1).

  Emits the exact same "key=value" lines as test/core/abi_probe.c, but
  measured from the chet-cli-generated binding units instead of the C
  headers. Compare the two outputs with a plain diff; any difference is a
  CAP-1 blocker.

  This program deliberately references NO external function from the
  binding, so it runs without webview.dll present (headless CI). Symbol
  coverage against the real DLL is a separate test (symbol_coverage.pas).

  It also carries compile-level checks:
  - callback typedef conventions: cdecl procedures with the exact parameter
    lists are assigned to webview_dispatch_fn / webview_bind_fn variables;
    a convention or signature drift makes this program fail to compile;
  - the split view units re-export the same types (type identity, not
    lookalikes). }

{$MODE OBJFPC}{$H+}

uses
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors;

{ --- compile-level callback convention checks ------------------------------ }

procedure ProbeDispatchCb(w: webview_t; arg: Pointer); cdecl;
begin
end;

procedure ProbeBindCb(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
begin
end;

const
  { assignment fails to compile if signature or calling convention drifts }
  CheckDispatchFn: webview_dispatch_fn = @ProbeDispatchCb;
  CheckBindFn: webview_bind_fn = @ProbeBindCb;

  { type identity between core unit and split views: these initializations
    only compile if the aliases resolve to the very same types/values }
  CheckErrType: pweb.lib.webview.webview_error_t =
    pweb.lib.webview.errors.WEBVIEW_ERROR_OK;
  CheckHintType: pweb.lib.webview.webview_hint_t =
    pweb.lib.webview.types.WEBVIEW_HINT_NONE;

procedure PSize(const Name: string; const Size: SizeUInt);
begin
  WriteLn('sizeof.', Name, '=', Size);
end;

procedure PEnum(const Name: string; const Value: LongInt);
begin
  WriteLn('enum.', Name, '=', Value);
end;

procedure PSigned(const Name: string; const IsSigned: Boolean);
begin
  if IsSigned then
    WriteLn('signed.', Name, '=1')
  else
    WriteLn('signed.', Name, '=0');
end;

var
  VersionRec: webview_version_t;
  InfoRec: webview_version_info_t;
  ErrProbe: webview_error_t;
  HintProbe: webview_hint_t;
  KindProbe: webview_native_handle_kind_t;

begin
  { silence "unused" hints without affecting output }
  if CheckDispatchFn = nil then Halt(100);
  if CheckBindFn = nil then Halt(100);
  if CheckErrType <> WEBVIEW_ERROR_OK then Halt(100);
  if CheckHintType <> WEBVIEW_HINT_NONE then Halt(100);

  { error enum: signedness is MEASURED by storing -1 and comparing, same as
    the C side's (T)-1 < 0 }
  PSize('webview_error_t', SizeOf(webview_error_t));
  ErrProbe := webview_error_t(-1);
  PSigned('webview_error_t', ErrProbe < 0);
  PEnum('WEBVIEW_ERROR_MISSING_DEPENDENCY', WEBVIEW_ERROR_MISSING_DEPENDENCY);
  PEnum('WEBVIEW_ERROR_CANCELED', WEBVIEW_ERROR_CANCELED);
  PEnum('WEBVIEW_ERROR_INVALID_STATE', WEBVIEW_ERROR_INVALID_STATE);
  PEnum('WEBVIEW_ERROR_INVALID_ARGUMENT', WEBVIEW_ERROR_INVALID_ARGUMENT);
  PEnum('WEBVIEW_ERROR_UNSPECIFIED', WEBVIEW_ERROR_UNSPECIFIED);
  PEnum('WEBVIEW_ERROR_OK', WEBVIEW_ERROR_OK);
  PEnum('WEBVIEW_ERROR_DUPLICATE', WEBVIEW_ERROR_DUPLICATE);
  PEnum('WEBVIEW_ERROR_NOT_FOUND', WEBVIEW_ERROR_NOT_FOUND);

  PSize('webview_hint_t', SizeOf(webview_hint_t));
  HintProbe := webview_hint_t(-1);
  PSigned('webview_hint_t', HintProbe < 0);
  PEnum('WEBVIEW_HINT_NONE', WEBVIEW_HINT_NONE);
  PEnum('WEBVIEW_HINT_MIN', WEBVIEW_HINT_MIN);
  PEnum('WEBVIEW_HINT_MAX', WEBVIEW_HINT_MAX);
  PEnum('WEBVIEW_HINT_FIXED', WEBVIEW_HINT_FIXED);

  PSize('webview_native_handle_kind_t', SizeOf(webview_native_handle_kind_t));
  KindProbe := webview_native_handle_kind_t(-1);
  PSigned('webview_native_handle_kind_t', KindProbe < 0);
  PEnum('WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW',
    WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW);
  PEnum('WEBVIEW_NATIVE_HANDLE_KIND_UI_WIDGET',
    WEBVIEW_NATIVE_HANDLE_KIND_UI_WIDGET);
  PEnum('WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER',
    WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);

  PSize('webview_t', SizeOf(webview_t));

  PSize('webview_version_t', SizeOf(webview_version_t));
  WriteLn('offset.webview_version_t.major=',
    PtrUInt(@VersionRec.major) - PtrUInt(@VersionRec));
  WriteLn('offset.webview_version_t.minor=',
    PtrUInt(@VersionRec.minor) - PtrUInt(@VersionRec));
  WriteLn('offset.webview_version_t.patch=',
    PtrUInt(@VersionRec.patch) - PtrUInt(@VersionRec));

  { per-field signedness, measured identically to the C side: fill the
    record with $FF, then an unsigned field reads as a huge positive value
    while a signed one reads negative }
  FillChar(VersionRec, SizeOf(VersionRec), $FF);
  if VersionRec.major > 0 then
    WriteLn('signed.webview_version_t.major=0')
  else
    WriteLn('signed.webview_version_t.major=1');
  if VersionRec.minor > 0 then
    WriteLn('signed.webview_version_t.minor=0')
  else
    WriteLn('signed.webview_version_t.minor=1');
  if VersionRec.patch > 0 then
    WriteLn('signed.webview_version_t.patch=0')
  else
    WriteLn('signed.webview_version_t.patch=1');

  PSize('webview_version_info_t', SizeOf(webview_version_info_t));
  WriteLn('offset.webview_version_info_t.version=',
    PtrUInt(@InfoRec.version) - PtrUInt(@InfoRec));
  WriteLn('offset.webview_version_info_t.version_number=',
    PtrUInt(@InfoRec.version_number) - PtrUInt(@InfoRec));
  WriteLn('offset.webview_version_info_t.pre_release=',
    PtrUInt(@InfoRec.pre_release) - PtrUInt(@InfoRec));
  WriteLn('offset.webview_version_info_t.build_metadata=',
    PtrUInt(@InfoRec.build_metadata) - PtrUInt(@InfoRec));

  PSize('fnptr.webview_dispatch_fn', SizeOf(webview_dispatch_fn));
  PSize('fnptr.webview_bind_fn', SizeOf(webview_bind_fn));
end.
