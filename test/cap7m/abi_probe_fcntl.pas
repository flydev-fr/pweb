program abi_probe_fcntl;

{ Pascal side of the paired fcntl probe (CAP-7M0, extended by CAP-7M1).

  Emits the exact same "key=value" lines as test/cap7m/abi_probe_fcntl.c, but
  measured from what src/assets/pweb.assets.folder.pas actually DECLARES and
  actually DOES for Darwin - which is why those constants, and the
  path-resolution routine itself, live in that unit's interface, the same
  reason CAP-7L put its hand-declared GTK aliases in pweb.platform.webkitgtk's
  interface.

  Compare the two outputs with a plain diff; unlike the core webview probe
  pair this one permits NO delta. A disagreement on O_NOFOLLOW means the
  declared value is not the O_NOFOLLOW the kernel will act on, and the folder
  store's symlink refusal would silently stop refusing symlinks.

  O_RDONLY is included even though BaseUnix supplies it on every POSIX
  target: it is the flag both call sites OR the other two into, so a probe
  that measured only the hand-declared constants would not be measuring the
  actual argument passed to FpOpen.

  THE LAST FACT IS NOT A CONSTANT, AND THAT IS THE POINT. macOS has no /proc,
  so the store's open-descriptor confinement re-proof is
  fcntl(fd, F_GETPATH, buf). fcntl is VARIADIC in C, and Apple's arm64 ABI
  passes variadic arguments on the STACK where its x86_64 ABI passes them in
  registers - so a declaration that is correct on one architecture can be
  wrong on the other, and no constant comparison would ever reveal it. The
  round trip below calls the PRODUCTION routine, PWebDarwinFinalPathOfFd, on
  a real descriptor, and the C side calls fcntl the way a C compiler knows
  how. They must agree, on each architecture separately.

  This program opens one file for reading and nothing else. }

{$mode ObjFPC}{$H+}

uses
  {$ifdef DARWIN}
  baseunix,        // O_RDONLY and FpOpen/FpClose, on Darwin as everywhere else
  {$endif DARWIN}
  sysutils,
  pweb.assets.folder;

{$ifndef DARWIN}
  {$fatal abi_probe_fcntl measures the Darwin-only constant block and is meaningless elsewhere}
{$endif DARWIN}

procedure PConst(const Name: string; const Value: QWord);
begin
  WriteLn('fcntl.', Name, '=', Value);
end;

var
  fd: cint;
  resolved: RawByteString;
begin
  { Emission ORDER is fixed and must match abi_probe_fcntl.c exactly: the
    comparison in check_abi.sh is line-by-line, not set-based. }
  PConst('O_RDONLY', QWord(O_RDONLY));
  PConst('O_NOFOLLOW', QWord(O_NOFOLLOW));
  PConst('O_DIRECTORY', QWord(O_DIRECTORY));
  PConst('F_GETPATH', QWord(F_GETPATH));
  PConst('PATH_BOUND', QWord(PWEB_DARWIN_PATH_MAX));

  if ParamCount <> 1 then
  begin
    WriteLn(StdErr, 'usage: abi_probe_fcntl <existing file>');
    Halt(2);
  end;
  fd := FpOpen(RawByteString(ParamStr(1)), O_RDONLY);
  if fd < 0 then
  begin
    WriteLn(StdErr, 'cannot open ', ParamStr(1));
    Halt(1);
  end;
  try
    resolved := PWebDarwinFinalPathOfFd(LongInt(fd));
  finally
    FpClose(fd);
  end;
  if resolved = '' then
  begin
    WriteLn(StdErr, 'PWebDarwinFinalPathOfFd returned nothing for ',
      ParamStr(1));
    Halt(1);
  end;
  WriteLn('fcntl.F_GETPATH_ROUNDTRIP=', resolved);
end.
