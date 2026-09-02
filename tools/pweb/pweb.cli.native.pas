{
  pweb.cli.native - the native compile, as one pure function (CAP-10C1).

  THE ARGUMENT VECTOR IS A PURE FUNCTION of the target, the project, the SDK
  layout and the output directories. Nothing here reads the filesystem, the
  environment or the clock, and nothing here is selected by a compiler
  conditional: the target comes in as (TPWebCliOs, TPWebCliArch) and the
  branch is ordinary runtime code.

  That is not a style preference. It means the WHOLE four-target matrix can
  be asserted from any single target - the same property that let CAP-10C0
  prove its Windows quoting rule with a golden table running on Linux and
  macOS - and it keeps this unit off the CAP-7F divergence allowlist, which
  refuses a platform conditional in any file not explicitly ratified.

  ---------------------------------------------------------------------------
  WHERE EVERY PATH COMES FROM
  ---------------------------------------------------------------------------

    <root>/src              the project's own sources (the directory holding
                            native.program, derived from the descriptor)
    <sdk>/share/pweb/src    the six PWeb unit directories, the last of which
                            is platform/<os> - resolved by pweb.cli.sdkroot,
                            never by a string built here
    <sdk>/share/pweb/deps/mormot2/src[/...]      mORMot, from the INSTALLATION
    <sdk>/share/pweb/deps/mormot2/static/<t>     its statics, likewise
    <sdk>/share/pweb/lib/<os>-<arch>             the webview library, and on
                                                 macOS the Cocoa bridge object
    <root>/<output>/<os>-<arch>/units and /obj   everything the compiler emits

  NO COMPILER FLAG COMES FROM pweb.json. Schema 1 has no toolchain model and
  deliberately no place to put one: a descriptor that could add a `-k` would
  be a descriptor that could add a linker argument, and the descriptor is
  developer-controlled build metadata rather than a command line.

  ---------------------------------------------------------------------------
  THE THREE TARGET-SPECIFIC FACTS, AND WHY EACH ONE IS THERE
  ---------------------------------------------------------------------------

  Windows: -Px86_64 -Twin64 selects the target explicitly rather than
  inheriting the compiler's default, and -Xm emits the link map the CAP-3U
  work reads. The mORMot this compiles against is the SDK's, which on
  Windows is the CAP-3U-PATCHED source staged at install time - so the
  patch's semantics are preserved without this pipeline ever editing a
  framework checkout (see pweb.cli.sdkroot).

  Linux: -k'-rpath=$ORIGIN' makes the executable find libwebview beside
  itself rather than through a system path or the working directory, and
  -k-lgcc_s NAMES a DSO that is findable but never referenced, which
  --as-needed will not do on a caller's behalf (the CAP-9C2 measurement,
  reused verbatim).

  macOS: -WM<deployment target> is passed on EVERY compile so no produced
  Mach-O inherits the runner SDK's idea of a minimum; the dylib is reached
  through -Fl plus an explicit -k-L/-k-lwebview, because -Fl is a search
  path only and something has to put the library on the link line (MEASURED,
  CAP-7M1 run 31909456486); LC_RPATH @executable_path is what makes a
  bundle resolve it from its own location; the production Objective-C++
  bridge is an OBJECT linked into each binary, with the two frameworks and
  the two runtimes clang++ would otherwise have supplied. And on aarch64
  only, -k-no_fixup_chains: Apple turns chained fixups on for every binary
  targeting macOS 12+, chained fixups need 8-byte-aligned pointer data, and
  FPC 3.2.2 emits FPC_THREADVARTABLES 4-byte aligned - which under every
  linker from Xcode 15 onward is a hard error rather than a warning. x86_64
  links cleanly without it and does not get it, because passing an
  architecture a workaround for the other one's defect contaminates its
  measurement.
}
unit pweb.cli.native;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.project,
  pweb.cli.run,
  pweb.cli.stage,
  pweb.cli.sdkroot;

const
  /// the mORMot source sub-directories handed to the compiler, in order
  // - spelled ONCE; the harness this replaces spelled them in four scripts
  PWEB_MORMOT_UNIT_DIRS: array[0 .. 7] of RawUtf8 = (
    'core', 'lib', 'crypt', 'net', 'db', 'orm', 'rest', 'soa');

  /// the two output directories beneath <output>/<os>-<arch>
  PWEB_NATIVE_UNIT_DIR = 'units';
  PWEB_NATIVE_BIN_DIR = 'obj';

/// the native compile of ONE project, for ONE target
// - UnitDir and BinDir are the native paths -FU and -FE will name
// - NativeProgram is the native path of the .lpr; its directory becomes the
// project's own -Fu, exactly as the harness derived it
function PWebCliFpcCommand(const FpcPath: RawUtf8;
  const Project: TPWebCliProject; const Sdk: TPWebSdkLayout;
  Os: TPWebCliOs; Arch: TPWebCliArch;
  const UnitDir, BinDir, NativeProgram: RawUtf8): TPWebCliCommand;

/// the native path of the executable an fpc run leaves in BinDir
function PWebCliNativeExeName(const Ident: RawUtf8;
  Os: TPWebCliOs): RawUtf8;


implementation

procedure Push(var Args: TRawUtf8DynArray; const Value: RawUtf8);
begin
  SetLength(Args, Length(Args) + 1);
  Args[High(Args)] := Value;
end;

function PWebCliNativeExeName(const Ident: RawUtf8;
  Os: TPWebCliOs): RawUtf8;
begin
  Result := Ident;
  if Os = pcoWindows then
    Result := Result + PWEB_CLI_RUN_WINDOWS_EXT;
end;

function PWebCliFpcCommand(const FpcPath: RawUtf8;
  const Project: TPWebCliProject; const Sdk: TPWebSdkLayout;
  Os: TPWebCliOs; Arch: TPWebCliArch;
  const UnitDir, BinDir, NativeProgram: RawUtf8): TPWebCliCommand;
var
  args: TRawUtf8DynArray;
  srcDir, name: RawUtf8;
  i: PtrInt;
begin
  Result := Default(TPWebCliCommand);
  Result.Exe := FpcPath;
  args := nil;

  // the explicit target, on the one platform whose compiler ships more than
  // one and whose default is not necessarily this one
  if Os = pcoWindows then
  begin
    Push(args, '-Px86_64');
    Push(args, '-Twin64');
  end;
  Push(args, '-MObjFPC');
  Push(args, '-Sh');
  Push(args, '-B');
  if Os = pcoWindows then
    Push(args, '-Xm');
  if Os = pcoMacos then
    // the ratified support floor, on every compile - never left to the SDK
    Push(args, '-WM' + PWEB_CLI_MACOS_MIN);

  Push(args, '-FU' + PWebCliArgPath(UnitDir));
  Push(args, '-FE' + PWebCliArgPath(BinDir));

  // the project's own sources: the directory holding native.program
  if PWebCliSplitLast(NativeProgram, srcDir, name) then
    Push(args, '-Fu' + PWebCliArgPath(srcDir));

  // the six PWeb unit directories, resolved out of the SDK root
  for i := 0 to High(Sdk.UnitDirs) do
    Push(args, '-Fu' + PWebCliArgPath(Sdk.UnitDirs[i]));

  // mORMot, from the INSTALLATION and never from the project
  Push(args, '-Fi' + PWebCliArgPath(Sdk.MormotSource));
  for i := 0 to High(PWEB_MORMOT_UNIT_DIRS) do
    Push(args, '-Fu' + PWebCliArgPath(PWebCliJoin(Sdk.MormotSource,
      PWEB_MORMOT_UNIT_DIRS[i])));
  Push(args, '-Fl' + PWebCliArgPath(Sdk.MormotStatic));

  case Os of
    pcoWindows:
      ; // the DLL is found beside the executable by the loader's own rule
    pcoLinux:
      begin
        Push(args, '-Fl' + PWebCliArgPath(Sdk.PlatformLib));
        Push(args, '-k-rpath=$ORIGIN');
        Push(args, '-k-lgcc_s');
      end;
    pcoMacos:
      begin
        Push(args, '-Fl' + PWebCliArgPath(Sdk.PlatformLib));
        Push(args, '-k-rpath');
        Push(args, '-k@executable_path');
        Push(args, '-k-L' + PWebCliArgPath(Sdk.PlatformLib));
        Push(args, '-k-lwebview');
        Push(args, '-k' + PWebCliArgPath(Sdk.MacosBridge));
        Push(args, '-k-framework');
        Push(args, '-kCocoa');
        Push(args, '-k-framework');
        Push(args, '-kWebKit');
        Push(args, '-k-lc++');
        Push(args, '-k-lobjc');
        if Arch = pcaArm64 then
          Push(args, '-k-no_fixup_chains');
      end;
  end;

  Push(args, PWebCliArgPath(NativeProgram));
  Result.Args := args;
  // the compiler runs in the project root: every path it is handed is
  // absolute, so the working directory decides nothing - and stating it
  // explicitly is what the supervision contract requires of every spawn
  Result.WorkDir := Project.Root;
end;

end.
