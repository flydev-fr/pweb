program abi_probe_gtk;

{ Pascal side of the paired ABI probe for the hand-declared WebKitGTK/GLib
  externals (CAP-7L).

  Emits the exact same "key=value" lines as test/cap7l/abi_probe_gtk.c, but
  measured from the types src/platform/linux/pweb.platform.webkitgtk.pas
  actually declares - which is why those aliases live in that unit's
  interface. Compare the two outputs with a plain diff; unlike the core
  webview probe pair, this one permits NO delta.

  CAP-8B widened the surface rather than adding a second one: the same
  pair now also covers the response-header API (WebKitURISchemeResponse +
  libsoup-3.0 SoupMessageHeaders), the decide-policy/create navigation
  signals and the private external opener. The two signal handlers matter
  most here, because g_signal_connect_data erases them to GCallback and
  nothing at the call site can check them.

  It also carries compile-level checks:
  - the callback typedefs are assigned from cdecl procedures with the exact
    parameter lists, so a convention or signature drift fails to compile;
  - referencing the unit at all proves it compiles for this target with its
    x86_64/Linux guards satisfied.

  This program deliberately calls NO external function, so it runs without a
  display and without GTK initialisation. Symbol presence in the distro .so
  files is a separate gate (test/cap7l/check_abi.sh, nm -D). }

{$mode ObjFPC}{$H+}

uses
  pweb.platform.webkitgtk;

{ --- compile-level callback convention checks ---------------------------- }

procedure ProbeDestroyCb(data: Pointer); cdecl;
begin
end;

procedure ProbeClosureNotifyCb(data: Pointer; closure: Pointer); cdecl;
begin
end;

procedure ProbeCallbackCb; cdecl;
begin
end;

procedure ProbeSchemeCb(request: Pointer; user_data: Pointer); cdecl;
begin
end;

{ CAP-8B. The two signal handlers the navigation guard connects:
  g_signal_connect_data erases both to GCallback, exactly as the
  G_CALLBACK() macro does in C, so nothing at the CALL site can check
  them - which is why the shapes are pinned here instead. }
function ProbeDecidePolicyCb(web_view: Pointer; decision: Pointer;
  decision_type: TWebKitPolicyDecisionType;
  user_data: Pointer): TGBoolean; cdecl;
begin
  Result := 0;
end;

function ProbeCreateCb(web_view: Pointer; navigation_action: Pointer;
  user_data: Pointer): Pointer; cdecl;
begin
  Result := nil;
end;

const
  { assignment fails to compile if the signature or calling convention
    drifts from what the unit declares }
  CheckDestroyFn: TGDestroyNotify = @ProbeDestroyCb;
  CheckClosureFn: TGClosureNotify = @ProbeClosureNotifyCb;
  CheckCallbackFn: TGCallback = @ProbeCallbackCb;
  CheckSchemeFn: TWebKitUriSchemeRequestCallback = @ProbeSchemeCb;
  CheckDecideFn: TWebKitDecidePolicyCallback = @ProbeDecidePolicyCb;
  CheckCreateFn: TWebKitCreateCallback = @ProbeCreateCb;

procedure PSize(const Name: string; const Size: SizeUInt);
begin
  WriteLn('sizeof.', Name, '=', Size);
end;

procedure PSigned(const Name: string; const IsSigned: Boolean);
begin
  if IsSigned then
    WriteLn('signed.', Name, '=1')
  else
    WriteLn('signed.', Name, '=0');
end;

var
  IntProbe: TGInt;
  Int64Probe: TGInt64;
  SizeProbe: TGSize;
  SSizeProbe: TGSSize;
  QuarkProbe: TGQuark;
  BooleanProbe: TGBoolean;
  UIntProbe: TGUInt;
  ULongProbe: TGULong;
  ConnectFlagsProbe: TGConnectFlags;
  DecisionTypeProbe: TWebKitPolicyDecisionType;
  NavTypeProbe: TWebKitNavigationType;
  HeadersTypeProbe: TSoupMessageHeadersType;

begin
  { silence "unused" hints without affecting output }
  if not Assigned(CheckDestroyFn) then
    Halt(100);
  if not Assigned(CheckClosureFn) then
    Halt(100);
  if not Assigned(CheckCallbackFn) then
    Halt(100);
  if not Assigned(CheckSchemeFn) then
    Halt(100);
  if not Assigned(CheckDecideFn) then
    Halt(100);
  if not Assigned(CheckCreateFn) then
    Halt(100);

  { signedness is MEASURED by storing -1 and comparing, exactly like the C
    side's (T)-1 < 0 }
  PSize('gint', SizeOf(TGInt));
  IntProbe := TGInt(-1);
  PSigned('gint', IntProbe < 0);

  PSize('gint64', SizeOf(TGInt64));
  Int64Probe := TGInt64(-1);
  PSigned('gint64', Int64Probe < 0);

  PSize('gsize', SizeOf(TGSize));
  SizeProbe := TGSize(-1);
  PSigned('gsize', SizeProbe < 0);

  PSize('gssize', SizeOf(TGSSize));
  SSizeProbe := TGSSize(-1);
  PSigned('gssize', SSizeProbe < 0);

  PSize('GQuark', SizeOf(TGQuark));
  QuarkProbe := TGQuark(-1);
  PSigned('GQuark', QuarkProbe < 0);

  PSize('gboolean', SizeOf(TGBoolean));
  BooleanProbe := TGBoolean(-1);
  PSigned('gboolean', BooleanProbe < 0);

  PSize('guint', SizeOf(TGUInt));
  UIntProbe := TGUInt(-1);
  PSigned('guint', UIntProbe < 0);

  PSize('gulong', SizeOf(TGULong));
  ULongProbe := TGULong(-1);
  PSigned('gulong', ULongProbe < 0);

  { The four C enums the CAP-8B signatures carry. The unit declares each of
    them LongWord because gcc types an enum with no negative enumerator as
    unsigned int; these lines are what turns that sentence into a measured
    fact, and what would fail loudly if a future header changed it. }
  PSize('GConnectFlags', SizeOf(TGConnectFlags));
  ConnectFlagsProbe := TGConnectFlags(-1);
  PSigned('GConnectFlags', ConnectFlagsProbe < 0);

  PSize('WebKitPolicyDecisionType', SizeOf(TWebKitPolicyDecisionType));
  DecisionTypeProbe := TWebKitPolicyDecisionType(-1);
  PSigned('WebKitPolicyDecisionType', DecisionTypeProbe < 0);

  PSize('WebKitNavigationType', SizeOf(TWebKitNavigationType));
  NavTypeProbe := TWebKitNavigationType(-1);
  PSigned('WebKitNavigationType', NavTypeProbe < 0);

  PSize('SoupMessageHeadersType', SizeOf(TSoupMessageHeadersType));
  HeadersTypeProbe := TSoupMessageHeadersType(-1);
  PSigned('SoupMessageHeadersType', HeadersTypeProbe < 0);

  { opaque handles and string elements. gchar signedness is deliberately not
    measured on either side: nothing crosses by value, only PAnsiChar. }
  PSize('gpointer', SizeOf(Pointer));
  PSize('gchar', SizeOf(AnsiChar));

  PSize('fnptr.GDestroyNotify', SizeOf(TGDestroyNotify));
  PSize('fnptr.GClosureNotify', SizeOf(TGClosureNotify));
  PSize('fnptr.GCallback', SizeOf(TGCallback));
  PSize('fnptr.WebKitURISchemeRequestCallback',
    SizeOf(TWebKitUriSchemeRequestCallback));
  PSize('fnptr.WebKitDecidePolicyCallback',
    SizeOf(TWebKitDecidePolicyCallback));
  PSize('fnptr.WebKitCreateCallback', SizeOf(TWebKitCreateCallback));
end.
