{
  pweb.cli.sdkroot - what an installed PWeb SDK holds, and where (CAP-10C1).

  pweb.cli.sdk answers ONE question - "given the executable running right
  now, where is the SDK root, and where inside it is the trusted template
  pack?" - and it is deliberately not extended here. This unit answers the
  NEXT question, which only a build pipeline asks:

      given that root, where are the six things a generated project has to
      be compiled and packed AGAINST, and is every one of them really there?

  It is NOT a second resolver. The root still comes from PWebCliSdkRoot, and
  every component below it is walked one at a time through PWebCliEntry -
  the same primitive pweb.cli.sdk uses, which reads the directory and
  compares the name byte-exactly and reports a junction or a symlink as
  pcnLink. So a `deps` junction cannot redirect mORMot, a case variant
  cannot resolve on NTFS or APFS, and the answer is the kernel's rather than
  a string's.

  ---------------------------------------------------------------------------
  THE LAYOUT (ratified at the CAP-10C1 checkpoint)
  ---------------------------------------------------------------------------

    <root>/bin/pweb[.exe]                        the anchor (pweb.cli.sdk)
    <root>/bin/pwebbundle[.exe]                  the frozen CAP-6 bundler
    <root>/share/pweb/pweb-templates.zip         the trusted pack (CAP-10B0)
    <root>/share/pweb/src/                       the PWeb Pascal source root
          lib rpc security webview assets platform/<os>
    <root>/share/pweb/sdk/typescript/            the pinned TypeScript SDK
    <root>/share/pweb/sdk/pas2js/                pweb.native.pas
    <root>/share/pweb/deps/mormot2/src/          mORMot sources
    <root>/share/pweb/deps/mormot2/static/<fpc-target>/
    <root>/share/pweb/lib/<os>-<arch>/           the platform artifacts

  WHY mORMot AND THE WEBVIEW LIBRARY LIVE HERE AND NOT IN THE PROJECT. A
  generated project holds application sources and nothing else - no runtime,
  no mORMot, no binding, no adapter, no SDK. Schema 1 carries no dependency
  model, so the ONLY honest place for the framework a project compiles
  against is the installation that created it. CAP-10B1 recorded resolving
  them from this repository's deps/ as a known limitation; this unit is
  where that limitation closes, and test/cap10c1/build_cap10c1 is what
  stages them.

  WHY WINDOWS SHIPS A PATCHED mORMot. tools/patch-cap3u.ps1 needs MSVC's
  ml64 and a mORMot GIT CHECKOUT, and it edits the checkout in place. A
  pipeline that ran it would be mutating its own framework's working tree on
  every build. The CAP-3U SEMANTICS are preserved by staging the patched
  source and its x64callmethod.obj into the SDK root ONCE, at install time -
  which is what a shipped SDK must do anyway - so the build path has no
  patch window at all.

  NOTHING HERE IS AN AMBIENT INPUT. There is no PWEB_SDK, no PWEB_HOME and
  no PWEB_MORMOT: the root is a parameter, resolved from the running image
  by its caller, and test/cap10c1/check_cap10c1_contracts.ps1 sweeps this
  unit for every spelling of an environment read.
}
unit pweb.cli.sdkroot;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.sdk,
  pweb.cli.run;

const
  /// the second component of the SDK's data tree, below share/pweb
  PWEB_SDK_SRC = 'src';
  PWEB_SDK_SDK = 'sdk';
  PWEB_SDK_TYPESCRIPT = 'typescript';
  PWEB_SDK_PAS2JS = 'pas2js';
  PWEB_SDK_DEPS = 'deps';
  PWEB_SDK_MORMOT = 'mormot2';
  PWEB_SDK_STATIC = 'static';
  PWEB_SDK_LIB = 'lib';
  PWEB_SDK_PLATFORM = 'platform';
  /// the frozen CAP-6 bundler, beside the CLI in bin/
  PWEB_SDK_BUNDLER = 'pwebbundle';
  /// the ONE Pas2JS SDK unit a generated frontend compiles against
  PWEB_SDK_PAS2JS_UNIT = 'pweb.native.pas';
  /// the TypeScript SDK's manifest, the file whose presence proves it was
  // staged rather than merely mkdir'ed
  PWEB_SDK_TS_MANIFEST = 'package.json';

  /// the five portable PWeb unit directories, in the order the compiler is
  // handed them - spelled ONCE, because the harness this replaces spelled
  // them in four scripts and one of them silently drifted (CAP-10B2)
  PWEB_SDK_UNIT_DIRS: array[0 .. 4] of RawUtf8 = (
    'lib', 'rpc', 'security', 'webview', 'assets');

type
  /// why an SDK root cannot drive a build - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebSdkLayoutRefusal = (
    pslNone,
    /// share/ or share/pweb/ is absent, not a directory, or a reparse point
    pslShareTree,
    /// share/pweb/src or one of its ratified unit directories
    pslSourceRoot,
    /// share/pweb/src/platform/<os>
    pslPlatformUnits,
    /// share/pweb/sdk/typescript (react only)
    pslTypeScriptSdk,
    /// share/pweb/sdk/pas2js/pweb.native.pas (pas2js only)
    pslPas2jsSdk,
    /// share/pweb/deps/mormot2/src
    pslMormotSource,
    /// share/pweb/deps/mormot2/static/<fpc-target>
    pslMormotStatic,
    /// share/pweb/lib/<os>-<arch>
    pslPlatformLib,
    /// the webview library inside it
    pslWebviewLib,
    /// the compiled Cocoa bridge object (macOS only)
    pslMacosBridge,
    /// bin/pwebbundle[.exe]
    pslBundler,
    /// this host is not one of the four ratified targets
    pslTargetUnsupported);

  /// every path a build reads out of one SDK root - canonical, walked, real
  TPWebSdkLayout = record
    /// pslNone when every path below exists with its exact on-disk spelling
    Refusal: TPWebSdkLayoutRefusal;
    /// which component caused the refusal - logical, never an absolute path
    Detail: RawUtf8;
    /// the canonical root this layout was resolved under
    Root: RawUtf8;
    /// <os>-<arch>, the CAP-10C0 target name
    Target: RawUtf8;
    /// the mORMot static directory name for this target
    FpcTarget: RawUtf8;
    /// <root>/share/pweb
    ShareTree: RawUtf8;
    /// <root>/share/pweb/src, and the six directories handed to the compiler
    SourceRoot: RawUtf8;
    UnitDirs: TRawUtf8DynArray;
    /// <root>/share/pweb/sdk/typescript ('' for a pas2js project)
    TypeScriptSdk: RawUtf8;
    /// <root>/share/pweb/sdk/pas2js ('' for a react project)
    Pas2jsSdk: RawUtf8;
    /// <root>/share/pweb/deps/mormot2/{src, static/<fpc-target>}
    MormotSource: RawUtf8;
    MormotStatic: RawUtf8;
    /// <root>/share/pweb/lib/<os>-<arch> and what it must contain
    PlatformLib: RawUtf8;
    WebviewLib: RawUtf8;
    /// '' off macOS
    MacosBridge: RawUtf8;
    /// <root>/bin/pwebbundle[.exe]
    Bundler: RawUtf8;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebSdkLayoutRefusalText(Refusal: TPWebSdkLayoutRefusal): RawUtf8;

/// the mORMot static directory name for a ratified target
// - the map that existed twice in the shell harness, stated once here
// - '' for an unratified target
function PWebCliFpcTargetName(Os: TPWebCliOs; Arch: TPWebCliArch): RawUtf8;

/// the webview library a release of this target ships
function PWebCliWebviewLibName(Os: TPWebCliOs): RawUtf8;

/// resolve every build input of ONE SDK root, for ONE target and ONE UI
// - Root must already be canonical (PWebCliCanonicalDir); this function
// never canonicalizes it, so a caller that skipped that step cannot be
// granted a confinement it did not establish - the identical rule
// PWebCliTemplatePackIn applies
// - Pas2js selects which of the two frontend SDKs is required: a react
// project has no reason to need the Pas2JS unit, and demanding both would
// make an installation that ships one of them unusable for either
function PWebCliSdkLayoutIn(const Root: RawUtf8; Os: TPWebCliOs;
  Arch: TPWebCliArch; Pas2js: Boolean): TPWebSdkLayout;

/// the layout of the RUNNING executable's own SDK - the form a command uses
function PWebCliSdkLayout(Os: TPWebCliOs; Arch: TPWebCliArch;
  Pas2js: Boolean; out Layout: TPWebSdkLayout): Boolean;


implementation

function PWebSdkLayoutRefusalText(Refusal: TPWebSdkLayoutRefusal): RawUtf8;
begin
  case Refusal of
    pslNone:              Result := 'ok';
    pslShareTree:         Result := 'sdk_share_tree_missing';
    pslSourceRoot:        Result := 'sdk_source_root_missing';
    pslPlatformUnits:     Result := 'sdk_platform_units_missing';
    pslTypeScriptSdk:     Result := 'sdk_typescript_missing';
    pslPas2jsSdk:         Result := 'sdk_pas2js_missing';
    pslMormotSource:      Result := 'sdk_mormot_source_missing';
    pslMormotStatic:      Result := 'sdk_mormot_static_missing';
    pslPlatformLib:       Result := 'sdk_platform_lib_missing';
    pslWebviewLib:        Result := 'sdk_webview_lib_missing';
    pslMacosBridge:       Result := 'sdk_macos_bridge_missing';
    pslBundler:           Result := 'sdk_bundler_missing';
    pslTargetUnsupported: Result := 'sdk_target_unsupported';
  else
    Result := 'sdk_layout_refused';
  end;
end;

function PWebCliFpcTargetName(Os: TPWebCliOs; Arch: TPWebCliArch): RawUtf8;
begin
  // mORMot's own static-directory naming, which is NOT the CAP-10C0 target
  // name: it is <fpc-cpu>-<fpc-os>, with win64 rather than windows and
  // aarch64 rather than arm64. Two names for one target is a fact about the
  // dependency, not a choice, and it is spelled here exactly once
  Result := '';
  if Arch = pcaOther then
    exit;
  case Os of
    pcoWindows:
      if Arch = pcaX86_64 then
        Result := 'x86_64-win64';
    pcoLinux:
      if Arch = pcaX86_64 then
        Result := 'x86_64-linux';
    pcoMacos:
      if Arch = pcaX86_64 then
        Result := 'x86_64-darwin'
      else
        Result := 'aarch64-darwin';
  end;
end;

function PWebCliWebviewLibName(Os: TPWebCliOs): RawUtf8;
begin
  case Os of
    pcoWindows: Result := PWEB_CLI_WEBVIEW_LIB_WINDOWS;
    pcoMacos:   Result := PWEB_CLI_WEBVIEW_LIB_MACOS;
  else
    Result := PWEB_CLI_WEBVIEW_LIB_LINUX;
  end;
end;

// the platform unit directory name below share/pweb/src/platform
function PlatformDirName(Os: TPWebCliOs): RawUtf8;
begin
  case Os of
    pcoWindows: Result := 'windows';
    pcoMacos:   Result := 'macos';
  else
    Result := 'linux';
  end;
end;

// ONE component, walked and confined: it must exist in its parent with its
// exact on-disk spelling and be of the demanded kind. A reparse point is
// pcnLink and therefore never matches, which is how a junction called
// `deps` is refused rather than followed
function Step(const Parent, Name: RawUtf8; Kind: TPWebCliNodeKind;
  out Full: RawUtf8): Boolean;
begin
  Full := '';
  Result := PWebCliEntry(Parent, Name) = Kind;
  if Result then
    Full := PWebCliJoin(Parent, Name);
end;

function Refuse(var Layout: TPWebSdkLayout;
  Refusal: TPWebSdkLayoutRefusal; const Detail: RawUtf8): Boolean;
begin
  Layout.Refusal := Refusal;
  Layout.Detail := Detail;
  Result := False;
end;

function PWebCliSdkLayoutIn(const Root: RawUtf8; Os: TPWebCliOs;
  Arch: TPWebCliArch; Pas2js: Boolean): TPWebSdkLayout;
var
  share, sdkDir, deps, mormot, statics, platformDir, binDir, full: RawUtf8;
  i: PtrInt;
  bundlerName: RawUtf8;
begin
  Result := Default(TPWebSdkLayout);
  Result.Root := Root;
  Result.Target := PWebCliRunTargetName(Os, Arch);
  Result.FpcTarget := PWebCliFpcTargetName(Os, Arch);
  if (Root = '') or
     (Result.FpcTarget = '') then
  begin
    Refuse(Result, pslTargetUnsupported, Result.Target);
    exit;
  end;

  // share/pweb
  if not Step(Root, PWEB_SDK_SHARE, pcnDirectory, share) then
  begin
    Refuse(Result, pslShareTree, PWEB_SDK_SHARE);
    exit;
  end;
  if not Step(share, PWEB_SDK_SHARE_PWEB, pcnDirectory, Result.ShareTree) then
  begin
    Refuse(Result, pslShareTree,
      PWEB_SDK_SHARE + '/' + PWEB_SDK_SHARE_PWEB);
    exit;
  end;

  // share/pweb/src and the five portable unit directories
  if not Step(Result.ShareTree, PWEB_SDK_SRC, pcnDirectory,
       Result.SourceRoot) then
  begin
    Refuse(Result, pslSourceRoot, PWEB_SDK_SRC);
    exit;
  end;
  SetLength(Result.UnitDirs, Length(PWEB_SDK_UNIT_DIRS) + 1);
  for i := 0 to High(PWEB_SDK_UNIT_DIRS) do
    if Step(Result.SourceRoot, PWEB_SDK_UNIT_DIRS[i], pcnDirectory, full) then
      Result.UnitDirs[i] := full
    else
    begin
      Refuse(Result, pslSourceRoot,
        PWEB_SDK_SRC + '/' + PWEB_SDK_UNIT_DIRS[i]);
      exit;
    end;
  // src/platform/<os> - the sixth, and the one the CAP-10B2 audit found had
  // silently been repo-relative in the POSIX harness while its header
  // claimed otherwise
  if not Step(Result.SourceRoot, PWEB_SDK_PLATFORM, pcnDirectory,
       platformDir) then
  begin
    Refuse(Result, pslPlatformUnits, PWEB_SDK_SRC + '/' + PWEB_SDK_PLATFORM);
    exit;
  end;
  if not Step(platformDir, PlatformDirName(Os), pcnDirectory, full) then
  begin
    Refuse(Result, pslPlatformUnits, PWEB_SDK_SRC + '/' + PWEB_SDK_PLATFORM +
      '/' + PlatformDirName(Os));
    exit;
  end;
  Result.UnitDirs[High(Result.UnitDirs)] := full;

  // share/pweb/sdk/<the ONE frontend SDK this UI needs>
  if not Step(Result.ShareTree, PWEB_SDK_SDK, pcnDirectory, sdkDir) then
  begin
    if Pas2js then
      Refuse(Result, pslPas2jsSdk, PWEB_SDK_SDK)
    else
      Refuse(Result, pslTypeScriptSdk, PWEB_SDK_SDK);
    exit;
  end;
  if Pas2js then
  begin
    if not Step(sdkDir, PWEB_SDK_PAS2JS, pcnDirectory, Result.Pas2jsSdk) then
    begin
      Refuse(Result, pslPas2jsSdk, PWEB_SDK_SDK + '/' + PWEB_SDK_PAS2JS);
      exit;
    end;
    if PWebCliEntry(Result.Pas2jsSdk, PWEB_SDK_PAS2JS_UNIT) <> pcnFile then
    begin
      Refuse(Result, pslPas2jsSdk, PWEB_SDK_SDK + '/' + PWEB_SDK_PAS2JS +
        '/' + PWEB_SDK_PAS2JS_UNIT);
      exit;
    end;
  end
  else
  begin
    if not Step(sdkDir, PWEB_SDK_TYPESCRIPT, pcnDirectory,
         Result.TypeScriptSdk) then
    begin
      Refuse(Result, pslTypeScriptSdk,
        PWEB_SDK_SDK + '/' + PWEB_SDK_TYPESCRIPT);
      exit;
    end;
    if PWebCliEntry(Result.TypeScriptSdk, PWEB_SDK_TS_MANIFEST) <> pcnFile then
    begin
      Refuse(Result, pslTypeScriptSdk, PWEB_SDK_SDK + '/' +
        PWEB_SDK_TYPESCRIPT + '/' + PWEB_SDK_TS_MANIFEST);
      exit;
    end;
  end;

  // share/pweb/deps/mormot2/{src, static/<fpc-target>}
  if not Step(Result.ShareTree, PWEB_SDK_DEPS, pcnDirectory, deps) then
  begin
    Refuse(Result, pslMormotSource, PWEB_SDK_DEPS);
    exit;
  end;
  if not Step(deps, PWEB_SDK_MORMOT, pcnDirectory, mormot) then
  begin
    Refuse(Result, pslMormotSource, PWEB_SDK_DEPS + '/' + PWEB_SDK_MORMOT);
    exit;
  end;
  if not Step(mormot, PWEB_SDK_SRC, pcnDirectory, Result.MormotSource) then
  begin
    Refuse(Result, pslMormotSource,
      PWEB_SDK_DEPS + '/' + PWEB_SDK_MORMOT + '/' + PWEB_SDK_SRC);
    exit;
  end;
  if not Step(mormot, PWEB_SDK_STATIC, pcnDirectory, statics) then
  begin
    Refuse(Result, pslMormotStatic,
      PWEB_SDK_DEPS + '/' + PWEB_SDK_MORMOT + '/' + PWEB_SDK_STATIC);
    exit;
  end;
  if not Step(statics, Result.FpcTarget, pcnDirectory,
       Result.MormotStatic) then
  begin
    Refuse(Result, pslMormotStatic, PWEB_SDK_DEPS + '/' + PWEB_SDK_MORMOT +
      '/' + PWEB_SDK_STATIC + '/' + Result.FpcTarget);
    exit;
  end;

  // share/pweb/lib/<os>-<arch>, and the artifacts inside it
  if not Step(Result.ShareTree, PWEB_SDK_LIB, pcnDirectory, full) then
  begin
    Refuse(Result, pslPlatformLib, PWEB_SDK_LIB);
    exit;
  end;
  if not Step(full, Result.Target, pcnDirectory, Result.PlatformLib) then
  begin
    Refuse(Result, pslPlatformLib, PWEB_SDK_LIB + '/' + Result.Target);
    exit;
  end;
  if not Step(Result.PlatformLib, PWebCliWebviewLibName(Os), pcnFile,
       Result.WebviewLib) then
  begin
    Refuse(Result, pslWebviewLib, PWEB_SDK_LIB + '/' + Result.Target + '/' +
      PWebCliWebviewLibName(Os));
    exit;
  end;
  if Os = pcoMacos then
    if not Step(Result.PlatformLib, PWEB_CLI_MACOS_BRIDGE_OBJ, pcnFile,
         Result.MacosBridge) then
    begin
      Refuse(Result, pslMacosBridge, PWEB_SDK_LIB + '/' + Result.Target +
        '/' + PWEB_CLI_MACOS_BRIDGE_OBJ);
      exit;
    end;

  // bin/pwebbundle[.exe] - the frozen CAP-6 bundler, beside the CLI
  bundlerName := PWEB_SDK_BUNDLER;
  if Os = pcoWindows then
    bundlerName := bundlerName + PWEB_CLI_RUN_WINDOWS_EXT;
  if not Step(Root, PWEB_SDK_BIN, pcnDirectory, binDir) then
  begin
    Refuse(Result, pslBundler, PWEB_SDK_BIN);
    exit;
  end;
  if not Step(binDir, bundlerName, pcnFile, Result.Bundler) then
  begin
    Refuse(Result, pslBundler, PWEB_SDK_BIN + '/' + bundlerName);
    exit;
  end;

  Result.Refusal := pslNone;
  Result.Detail := '';
end;

function PWebCliSdkLayout(Os: TPWebCliOs; Arch: TPWebCliArch;
  Pas2js: Boolean; out Layout: TPWebSdkLayout): Boolean;
var
  root: RawUtf8;
  sdkRefusal: TPWebSdkRefusal;
begin
  Layout := Default(TPWebSdkLayout);
  // the root is the RUNNING IMAGE's, resolved by the one anchor rule - never
  // the working directory, never an argument, never an environment variable
  if not PWebCliSdkRoot(root, sdkRefusal) then
  begin
    Layout.Refusal := pslShareTree;
    Layout.Detail := PWebSdkRefusalText(sdkRefusal);
    Result := False;
    exit;
  end;
  Layout := PWebCliSdkLayoutIn(root, Os, Arch, Pas2js);
  Result := Layout.Refusal = pslNone;
end;

end.
