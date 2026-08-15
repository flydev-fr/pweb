program abi_probe_fcntl;

{ Pascal side of the paired fcntl-constant probe (CAP-7M0).

  Emits the exact same "key=value" lines as test/cap7m/abi_probe_fcntl.c, but
  measured from what src/assets/pweb.assets.folder.pas actually DECLARES for
  Darwin - which is why those constants live in that unit's interface, the
  same reason CAP-7L put its hand-declared GTK aliases in
  pweb.platform.webkitgtk's interface.

  Compare the two outputs with a plain diff; unlike the core webview probe
  pair this one permits NO delta. A disagreement means the declared
  O_NOFOLLOW is not the O_NOFOLLOW the kernel will act on, and the folder
  store's symlink refusal would silently stop refusing symlinks.

  O_RDONLY is included even though BaseUnix supplies it on every POSIX
  target: it is the flag both call sites OR the other two into, so a probe
  that measured only the two hand-declared constants would not be measuring
  the actual argument passed to FpOpen.

  This program calls no external function and touches no filesystem. }

{$mode ObjFPC}{$H+}

uses
  {$ifdef DARWIN}
  baseunix,        // O_RDONLY, on Darwin as everywhere else
  {$endif DARWIN}
  pweb.assets.folder;

{$ifndef DARWIN}
  {$fatal abi_probe_fcntl measures the Darwin-only constant block and is meaningless elsewhere}
{$endif DARWIN}

procedure PConst(const Name: string; const Value: QWord);
begin
  WriteLn('fcntl.', Name, '=', Value);
end;

begin
  { Emission ORDER is fixed and must match abi_probe_fcntl.c exactly: the
    comparison in check_abi.sh is line-by-line, not set-based. }
  PConst('O_RDONLY', QWord(O_RDONLY));
  PConst('O_NOFOLLOW', QWord(O_NOFOLLOW));
  PConst('O_DIRECTORY', QWord(O_DIRECTORY));
end.
