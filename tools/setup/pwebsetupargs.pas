{
  pwebsetupargs - argv from the KERNEL for the two Windows setup helpers
  (CAP-10E).

  WHY IT EXISTS. `pwebwv2prov` and `pwebwv2fixed` receive their paths from
  Inno Setup on a command line: an ExpandConstant of the app constant for
  the install directory, the tmp constant for a downloaded installer, and
  the app constant again for the log copy. Note that those constants are
  spelled in the .iss files with the brace syntax this comment deliberately
  avoids: a brace inside a brace comment closes it early, which is a real
  hazard in this repository and not a hypothetical one - FPC answers it with
  a "Comment level 2 found" warning that is easy to scroll past, and the
  CAP-10E source gate reads what is left as if it were code.
  Inno is a Unicode application and hands over a UTF-16
  command line, but the FPC RTL's Windows argv is an ANSI conversion of it -
  and mORMot has already set DefaultSystemCodePage to CP_UTF8 for the whole
  process, so a `/DIR=` carrying a character outside the active code page
  reaches ParamStr as codepage bytes that are then read back as UTF-8 and
  collapse to U+FFFD. The helper then reports the runtime tree, the ACL
  target or the manifest missing about a directory that is plainly there,
  and the installation aborts.

  It is the SAME defect, at the same RTL layer, as ledger D2-12 (the CLI's
  image path), D2-13 (the CAP-6 bundler's argv) and CAP-10E's own shipped
  hosts. GetCommandLineW answers in UTF-16 and cannot lose a character;
  CommandLineToArgvW splits it with the C runtime's grammar, which is the
  grammar Inno's own quoting targets. It is the only shell32 import here and
  it PARSES rather than executes: nothing in either helper launches anything.

  ONE UNIT rather than the bundler's second copy, and the difference is
  layering rather than taste: `tools/bundler/pwebbundle.pas` may not depend
  on a `tools/pweb` unit because the CAP-6 gate exists to prove it does not,
  while these two programs already share `src/platform/windows` and live in
  the same directory, so a shared unit here costs nothing and removes the
  only argument for a third copy.

  NO CONDITIONAL, because there is nothing to condition on: both consumers
  are Windows-only programs that link the Win32 security APIs directly. An
  OSWINDOWS conditional here would be a platform region in a file that has
  only ever had one platform.

  ArgCount and ArgStr keep ParamCount and ParamStr semantics EXACTLY - index
  0 is the image, 1..ArgCount are the arguments, an out-of-range index is ''
  and never a range error - so every call site reads the way it always did
  and only the SOURCE of the bytes moved.
}

unit pwebsetupargs;

{$mode ObjFPC}{$H+}

interface

/// read this process's argv from the kernel; raises when it cannot
// - call it ONCE, first thing, before any argument is read
procedure PWebSetupReadArgs;

/// ParamCount, over the kernel's argv
function ArgCount: Integer;

/// ParamStr, over the kernel's argv
// - index 0 is the image as the command line spells it, which is NOT
// necessarily the module path; a caller wanting the image asks for the
// image (pweb.imagepath), never for args[0]
function ArgStr(Index: Integer): string;

implementation

uses
  sysutils,
  windows,
  mormot.core.base,
  mormot.core.unicode;

var
  Args: array of string;

function CommandLineToArgvW(lpCmdLine: PWideChar;
  var pNumArgs: Integer): PPWideChar;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

procedure PWebSetupReadArgs;
var
  argv, p: PPWideChar;
  n, i: Integer;
begin
  n := 0;
  argv := CommandLineToArgvW(GetCommandLineW, n);
  // NO FALLBACK TO ParamStr, for the reason the bundler's own reader states:
  // the RTL argv is the defect this routine exists to route around, so
  // quietly reverting to it would undo the fix in the one case nobody
  // watches and leave the same misleading "not found" behind.
  if (argv = nil) or
     (n <= 0) then
    raise Exception.CreateFmt(
      'cannot read the command line (Win32 error %d)', [GetLastError]);
  try
    SetLength(Args, n);
    for i := 0 to n - 1 do
    begin
      p := argv;
      Inc(p, i);
      // the explicit UTF-16 -> UTF-8 -> string round trip, lossless because
      // the process code page is CP_UTF8
      Args[i] := Utf8ToString(SynUnicodeToUtf8(SynUnicode(WideString(p^))));
    end;
  finally
    LocalFree(HLOCAL(argv));
  end;
end;

function ArgCount: Integer;
begin
  Result := Length(Args) - 1;
  if Result < 0 then
    Result := 0;
end;

function ArgStr(Index: Integer): string;
begin
  if (Index < 0) or
     (Index > High(Args)) then
    Result := ''
  else
    Result := Args[Index];
end;

end.
