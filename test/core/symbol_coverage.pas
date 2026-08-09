program symbol_coverage;

{ Symbol coverage test (CAP-1).

  Loads the webview shared library dynamically and verifies that every one
  of the 17 public C entry points of the pinned upstream commit is exported.
  Dynamic loading (no import table) keeps the failure report complete: every
  missing symbol is listed, instead of the loader aborting on the first one.

  Usage: symbol_coverage [path\to\webview.dll]
  Default: webview.dll next to the executable / on the search path.

  Exit code 0 = all 17 exported; 1 = missing symbols or DLL not loadable. }

{$MODE OBJFPC}{$H+}

uses
  SysUtils, DynLibs;

const
  { The complete public C ABI of webview/webview at the pinned commit
    (cbbdee44afff22867de9fd88a9fc8350d9bdd399), core/include/webview/api.h.
    17 entry points -- keep in sync with the pinned header, which is the
    only authority. }
  PinnedEntryPoints: array[0..16] of string = (
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

var
  LibPath: string;
  Lib: TLibHandle;
  i, Missing: Integer;
  P: Pointer;

begin
  if ParamCount >= 1 then
    LibPath := ParamStr(1)
  else
    LibPath := 'webview.dll';

  Lib := LoadLibrary(LibPath);
  if Lib = NilHandle then
  begin
    WriteLn('FAIL: cannot load library: ', LibPath);
    Halt(1);
  end;

  Missing := 0;
  for i := Low(PinnedEntryPoints) to High(PinnedEntryPoints) do
  begin
    P := GetProcedureAddress(Lib, PinnedEntryPoints[i]);
    if P = nil then
    begin
      WriteLn('MISSING ', PinnedEntryPoints[i]);
      Inc(Missing);
    end
    else
      WriteLn('export.', PinnedEntryPoints[i], '=1');
  end;

  UnloadLibrary(Lib);

  if Missing > 0 then
  begin
    WriteLn('FAIL: ', Missing, ' of ', Length(PinnedEntryPoints),
      ' pinned entry points missing');
    Halt(1);
  end;
  WriteLn('OK: 17/17 pinned entry points exported');
end.
