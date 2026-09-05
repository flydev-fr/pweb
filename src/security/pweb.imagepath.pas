{
  pweb.imagepath - the running executable's own location, asked of the
  KERNEL (CAP-10E).

  THE ONE READER of the running image's path in shipped PWeb code. Every
  trusted file a PWeb host loads - app.pwb, plugins.zip, the bundled
  WebView2 Fixed Runtime tree - is resolved from the directory this unit
  reports, and from nowhere else: never the current working directory,
  never an environment variable, never anything app.pwb or a page could
  influence. That rule is older than this unit; what this unit changes is
  WHO IS ASKED.

  WHY IT EXISTS, and it is a measured defect rather than a preference.
  Until CAP-10E every site read mORMot's Executable.ProgramFilePath, which
  mormot.core.os fills from ExpandFileName(ParamStr(0)). On Windows the
  RTL's argv is an ANSI conversion of the command line, so a path carrying
  a character outside the active code page arrives mangled: with the
  process code page at 1252 the accented byte survives the conversion as
  $E9, mORMot has already set DefaultSystemCodePage to CP_UTF8 for the
  whole process, and the RTL's own UTF-8 to UTF-16 step therefore yields
  U+FFFD. The application then looks for its bundle in a directory the
  filesystem does not have. MEASURED on hosted run 33955241980: a React
  application at `<temp>\<e-acute>tude apps\demoreact` answered
  `app.pwb REFUSED (bundle file missing)` and exited 1 while its Pas2JS
  twin at a spaced ASCII root answered 42 in the same leg, from the same
  build. An installation under `C:\Users\<accented name>\...` refuses at
  launch, which is why this is a user-facing defect and not a build-tool
  inconvenience.

  It is the third instance of ONE class. CAP-10D2 closed it in the CLI
  (ledger D2-12, PWebCliImageDir) and CAP-6 closed it in the frozen
  bundler's argv (ledger D2-13); this unit closes it in the shipped hosts
  and is now the single implementation all three reach.

  THE THREE KERNEL QUESTIONS, one whole body each:

    Windows   GetModuleFileNameW(nil, ...) - UTF-16 from the loader, over
              a 32767-wide buffer so a long path is never truncated, then
              ONE conversion to the process's UTF-8 string type. The image
              path the loader used is FINAL: nothing here follows a link
              and nothing here adds a \\?\ prefix, which the CAP-6b3 path
              shape policy refuses by name.
    Linux     readlink('/proc/self/exe')
    macOS     _NSGetExecutablePath + realpath

  POSIX SYMLINK SEMANTICS, RATIFIED AT CAP-10E AND STRICTER THAN WHAT IT
  REPLACES: /proc/self/exe and realpath resolve links, ExpandFileName does
  not. A host launched through `/tmp/x/host -> /opt/app/host` therefore
  loads `/opt/app/app.pwb` where it used to load `/tmp/x/app.pwb`. A
  writable directory can no longer decide which bundle a trusted binary
  reads, and test/cap10e measures exactly that with a decoy app.pwb beside
  the link.

  FAIL CLOSED. When the kernel will not answer, both functions return ''
  and every call site refuses with a typed diagnostic and a nonzero exit.
  Returning a relative path would hand the decision back to the working
  directory, which is the one input this whole model exists to exclude.

  NO CACHE and no global state: a trust primitive whose answer lives in a
  mutable variable is a trust primitive somebody can write to, and the
  kernel call costs nothing at the handful of sites that make it.

  Layer: a LEAF. It uses the RTL and mormot.core.base/.unicode and no PWeb
  unit at all, so src/webview, src/script, src/platform/<os>, both
  acceptance hosts and the CLI can each reach it without any of them
  reaching each other. It lives in src/security because it is the root of
  the CAP-9C1 startup trust chain, and because src/security is one of the
  five unit directories the SDK already stages and hands to the compiler -
  so a generated application gets this unit with no change to the SDK
  layout at all.
}

unit pweb.imagepath;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode;

/// the running executable's own file, exactly as the KERNEL reports it
// - NEVER ParamStr(0): see the unit header for the measurement
// - the path is absolute and independent of the current working directory
// - on POSIX it is the REAL image, with every symlink resolved; on Windows
// it is the path the loader used, followed no further
// - '' when the kernel will not answer - fail closed, never a relative path
function PWebImageFile: TFileName;

/// the directory holding the running executable, WITH its trailing delimiter
// - the exact shape Executable.ProgramFilePath used to hand out, so a call
// site changes its SOURCE and not its concatenation
// - '' when PWebImageFile is ''
function PWebImageDir: TFileName;

implementation

uses
  {$ifdef WINDOWS}
  windows;
  {$else}
  baseunix;
  {$endif WINDOWS}

{$ifdef WINDOWS}

{ The loader's own answer, in UTF-16, over a buffer sized for the Windows
  long-path maximum so the result is never a silent truncation. A return of
  0 is a failure and a return equal to the buffer size is a truncation that
  ERROR_INSUFFICIENT_BUFFER reports on newer Windows: both refuse.

  The conversion happens ONCE, here: UTF-16 -> UTF-8 -> the process string
  type, whose code page mormot.core.os has set to CP_UTF8. That is the same
  route the CAP-6 bundler's kernel argv takes, and it is what makes the
  bytes handed back convert losslessly again inside the RTL's own W-API
  wrappers. }
function PWebImageFile: TFileName;
var
  wide: array[0 .. 32767] of WideChar;
  got: DWORD;
begin
  Result := '';
  got := GetModuleFileNameW(0, @wide[0], Length(wide));
  if (got = 0) or
     (got >= Length(wide)) then
    exit;
  wide[got] := #0;
  Result := TFileName(Utf8ToString(
    SynUnicodeToUtf8(SynUnicode(PWideChar(@wide[0])))));
end;

{$else}

{$ifdef DARWIN}

const
  { Darwin's PATH_MAX, which is also the minimum buffer realpath(3) is
    documented to require. Declared here rather than assumed from the RTL,
    exactly as pweb.cli.platform declares the Darwin fcntl constants FPC
    3.2.2 does not carry. }
  PWEB_IMAGE_PATH_MAX = 1024;

// _NSGetExecutablePath answers the path the process was STARTED with, which
// may be relative and may be a symlink; realpath is what turns it into the
// real image. Both live in libSystem, which is what 'c' resolves to here.
// The widths are spelled as plain Pascal integers rather than through
// ctypes: uint32_t and int are 32 bits on both Darwin ABIs, and one fewer
// unit in a leaf trust primitive is one fewer thing to be wrong about.
function pweb_NSGetExecutablePath(buf: PAnsiChar;
  var bufsize: LongWord): LongInt; cdecl;
  external 'c' name '_NSGetExecutablePath';

function pweb_realpath(path: PAnsiChar; resolved: PAnsiChar): PAnsiChar;
  cdecl; external 'c' name 'realpath';

function PWebImageFile: TFileName;
var
  started: array[0 .. PWEB_IMAGE_PATH_MAX - 1] of AnsiChar;
  real_: array[0 .. PWEB_IMAGE_PATH_MAX - 1] of AnsiChar;
  size: LongWord;
  n: PtrInt;
begin
  Result := '';
  FillChar(started{%H-}, SizeOf(started), 0);
  FillChar(real_{%H-}, SizeOf(real_), 0);
  size := SizeOf(started);
  // a nonzero return means "the buffer was too small", and this buffer is
  // Darwin's PATH_MAX: refusing is the honest answer, not a retry loop
  if pweb_NSGetExecutablePath(@started[0], size) <> 0 then
    exit;
  if pweb_realpath(@started[0], @real_[0]) = nil then
    exit;
  n := 0;
  while (n < PWEB_IMAGE_PATH_MAX) and
        (real_[n] <> #0) do
    Inc(n);
  if (n = 0) or
     (n >= PWEB_IMAGE_PATH_MAX) or
     (real_[0] <> '/') then
    exit;
  SetString(Result, PAnsiChar(@real_[0]), n);
end;

{$else}

{ Linux: /proc/self/exe is the kernel's own symlink to the real image, so
  one readlink answers both questions this unit asks - which file, and
  which file REALLY. A kernel that will not answer (no /proc mounted)
  refuses, because a guess here is a trusted directory nobody chose. }
function PWebImageFile: TFileName;
var
  link: RawByteString;
begin
  Result := '';
  link := FpReadLink('/proc/self/exe');
  if (link = '') or
     (link[1] <> '/') then
    exit;
  Result := TFileName(link);
end;

{$endif DARWIN}

{$endif WINDOWS}

{ ExtractFilePath is byte-safe on both string shapes this unit produces: on
  POSIX a path is bytes already, and on Windows every UTF-8 continuation
  byte is >= $80 and can therefore never be mistaken for a separator. }
function PWebImageDir: TFileName;
var
  full: TFileName;
begin
  Result := '';
  full := PWebImageFile;
  if full = '' then
    exit;
  Result := ExtractFilePath(full);
end;

end.
