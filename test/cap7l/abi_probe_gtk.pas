program abi_probe_gtk;

{ Pascal side of the paired ABI probe for the hand-declared WebKitGTK/GLib
  externals (CAP-7L).

  Emits the exact same "key=value" lines as test/cap7l/abi_probe_gtk.c, but
  measured from the types src/platform/linux/pweb.platform.webkitgtk.pas
  actually declares - which is why those aliases live in that unit's
  interface. Compare the two outputs with a plain diff; unlike the core
  webview probe pair, this one permits NO delta.

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

procedure ProbeSchemeCb(request: Pointer; user_data: Pointer); cdecl;
begin
end;

const
  { assignment fails to compile if the signature or calling convention
    drifts from what the unit declares }
  CheckDestroyFn: TGDestroyNotify = @ProbeDestroyCb;
  CheckSchemeFn: TWebKitUriSchemeRequestCallback = @ProbeSchemeCb;

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

begin
  { silence "unused" hints without affecting output }
  if not Assigned(CheckDestroyFn) then
    Halt(100);
  if not Assigned(CheckSchemeFn) then
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

  { opaque handles and string elements. gchar signedness is deliberately not
    measured on either side: nothing crosses by value, only PAnsiChar. }
  PSize('gpointer', SizeOf(Pointer));
  PSize('gchar', SizeOf(AnsiChar));

  PSize('fnptr.GDestroyNotify', SizeOf(TGDestroyNotify));
  PSize('fnptr.WebKitURISchemeRequestCallback',
    SizeOf(TWebKitUriSchemeRequestCallback));
end.
