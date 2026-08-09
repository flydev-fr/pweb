program signature_pin;

{ Compile-level signature pin for ALL 17 entry points of the generated
  binding (CAP-1).

  Each typed procedural constant below spells the exact signature this
  project depends on and is initialized with the external function from
  pweb.lib.webview (deliberately WITHOUT @: mormot.defines.inc sets $T-
  and under it a Delphi-mode @proc is an untyped pointer that would skip
  the check). FPC only accepts the initialization when parameter types,
  modifiers, result type, and calling convention match -- so any drift in
  the generated binding breaks THIS COMPILE.

  This program is a compile-time gate: it references the external functions,
  so the produced executable needs webview.dll to start. CI therefore only
  COMPILES it (the paired probes and symbol_coverage cover runtime facts). }

{$I mormot.defines.inc}

uses
  {$I mormot.uses.inc}
  pweb.lib.webview;

type
  Tfn_create = function(debug: Integer; window: Pointer): webview_t; cdecl;
  Tfn_handle_to_err = function(w: webview_t): webview_error_t; cdecl;
  Tfn_dispatch = function(w: webview_t; fn: webview_dispatch_fn;
    arg: Pointer): webview_error_t; cdecl;
  Tfn_get_window = function(w: webview_t): Pointer; cdecl;
  Tfn_get_native_handle = function(w: webview_t;
    kind: webview_native_handle_kind_t): Pointer; cdecl;
  Tfn_str_to_err = function(w: webview_t;
    const s: PAnsiChar): webview_error_t; cdecl;
  Tfn_set_size = function(w: webview_t; width: Integer; height: Integer;
    hints: webview_hint_t): webview_error_t; cdecl;
  Tfn_bind = function(w: webview_t; const name: PAnsiChar;
    fn: webview_bind_fn; arg: Pointer): webview_error_t; cdecl;
  Tfn_return = function(w: webview_t; const id: PAnsiChar; status: Integer;
    const result: PAnsiChar): webview_error_t; cdecl;
  Tfn_version = function(): Pwebview_version_info_t; cdecl;

const
  Pin_create: Tfn_create = webview_create;
  Pin_destroy: Tfn_handle_to_err = webview_destroy;
  Pin_run: Tfn_handle_to_err = webview_run;
  Pin_terminate: Tfn_handle_to_err = webview_terminate;
  Pin_dispatch: Tfn_dispatch = webview_dispatch;
  Pin_get_window: Tfn_get_window = webview_get_window;
  Pin_get_native_handle: Tfn_get_native_handle = webview_get_native_handle;
  Pin_set_title: Tfn_str_to_err = webview_set_title;
  Pin_set_size: Tfn_set_size = webview_set_size;
  Pin_navigate: Tfn_str_to_err = webview_navigate;
  Pin_set_html: Tfn_str_to_err = webview_set_html;
  Pin_init: Tfn_str_to_err = webview_init;
  Pin_eval: Tfn_str_to_err = webview_eval;
  Pin_bind: Tfn_bind = webview_bind;
  Pin_unbind: Tfn_str_to_err = webview_unbind;
  Pin_return: Tfn_return = webview_return;
  Pin_version: Tfn_version = webview_version;

var
  Bound: Integer;
begin
  { reference every pin so none is optimized away or flagged unused }
  Bound := 0;
  if Assigned(Pin_create) then Inc(Bound);
  if Assigned(Pin_destroy) then Inc(Bound);
  if Assigned(Pin_run) then Inc(Bound);
  if Assigned(Pin_terminate) then Inc(Bound);
  if Assigned(Pin_dispatch) then Inc(Bound);
  if Assigned(Pin_get_window) then Inc(Bound);
  if Assigned(Pin_get_native_handle) then Inc(Bound);
  if Assigned(Pin_set_title) then Inc(Bound);
  if Assigned(Pin_set_size) then Inc(Bound);
  if Assigned(Pin_navigate) then Inc(Bound);
  if Assigned(Pin_set_html) then Inc(Bound);
  if Assigned(Pin_init) then Inc(Bound);
  if Assigned(Pin_eval) then Inc(Bound);
  if Assigned(Pin_bind) then Inc(Bound);
  if Assigned(Pin_unbind) then Inc(Bound);
  if Assigned(Pin_return) then Inc(Bound);
  if Assigned(Pin_version) then Inc(Bound);
  if Bound <> 17 then Halt(1);
  WriteLn('signature_pin: 17/17 signatures pinned at compile time');
end.
