{
  pweb.platform.webview2.fixed - bundled WebView2 Fixed Version Runtime
  resolution, validation and selection for the Windows fixed-runtime
  install profile (CAP-6b3).

  CAP-6b1/6b2 both end at an Evergreen runtime the MACHINE owns and
  updates. Frozen/certified/kiosk deployments need the opposite: the
  application runs on a runtime THEY pin, deployed as ordinary
  application content beside the executable, with zero dependence on
  any installed Evergreen. This Windows-private unit is the whole of
  that mechanism on the app side:

    PWebWv2FixedPrepare
      -> resolve   (Executable.ProgramFilePath ONLY - never the CWD,
                    never an environment variable, never app.pwb,
                    never JS)
      -> validate  (path shape, local non-UNC drive, required files,
                    strict 4-part version == the ratified pin and
                    >= the CAP-4W minimum, PE machine AMD64, the
                    Windows 10 AppContainer ACL verified BY SID)
      -> select    (LoadLibraryW of the bundled loader by ABSOLUTE
                    path, module-identity assertion, then
                    SetEnvironmentVariableW of the documented
                    WEBVIEW2_BROWSER_EXECUTABLE_FOLDER override with a
                    mandatory read-back)

  Ratified at CAP-6b3 Checkpoint 1 (2026-08-13) after the
  env-var-only hypothesis was PROBED AND REFUTED: with only the
  environment variable set, the pinned webview's built-in loader
  ignores it and silently runs on the installed Evergreen. The loader
  preload is therefore not an optimisation - it is the selection. The
  order is fixed: preload, then variable, both strictly before
  webview_create, and zero change to webview/webview, the CAP-4W
  patch, the 17-export ABI or the raw Pascal binding.

  Fail closed at every step and NEVER fall back to Evergreen: a
  missing, partial, wrong-version, wrong-architecture, inaccessible,
  UNC or forbidden-shape tree, a loader that will not preload, a
  loader module identity that does not match the preloaded handle, or
  an environment variable that does not read back yields a typed
  diagnostic and a failed result BEFORE webview_create. A zeroed
  result record already reads as failure (ordinal 0 is the failure
  state on both enumerations). The presence of a usable Evergreen
  runtime never rescues any of these.

  Identity is OBSERVED, not inferred: after webview_create and before
  webview_navigate the caller must ask the environment that actually
  opened which browser version it is (see
  PWebWv2ObservedBrowserVersion in pweb.platform.webview2) and refuse
  unless PWebWv2FixedIdentityMatches accepts it against the pin. That
  is the deterministic answer to a registry-policy
  BrowserExecutableFolder redirection, which no pre-create check can
  see.

  This unit REUSES the CAP-6b1/6b2 primitives instead of forking them:
  PWebWv2FileSha256 (streamed, bounded memory) and
  PWebWv2AuthenticodeCheck from pweb.platform.webview2.provision, and
  the strict PWebWv2VersionParse plus the single PWEB_WV2_MIN_BUILD
  threshold from pweb.platform.webview2.runtime. It deliberately
  references NOTHING of the provisioning orchestration - no installer
  arguments, no bounded process runner, no provisioning run: the fixed
  profile executes no installer, downloads nothing and registers
  nothing, ever.

  Where each verification axis is enforced, exactly:
    - sha256 of the cabinet          BUILD time, against the ratified
                                     webview2-runtime.lock pin
    - deterministic tree manifest    BUILD time (written + verified)
                                     and GATE time, against the
                                     INSTALLED tree, via the streamed
                                     PWebWv2FileSha256 below
    - Authenticode of the critical   BUILD time (PowerShell) AND
      binaries                       INSTALL time, natively, through
                                     PWebWv2FixedVerifySigners below,
                                     which the fixed profile's setup
                                     runs before it grants the ACL
    - version / architecture / ACL   INSTALL time and on EVERY startup
    - observed runtime identity      EVERY startup, after
                                     webview_create, before any
                                     navigation
  Ordinary STARTUP deliberately does not re-run the signer or manifest
  axes: hashing a ~690 MB tree on every launch would be a per-launch
  cost with no attacker model behind it (an attacker who can rewrite
  the tree can equally rewrite the app binary that checks it).

  The impure primitives (drive type, file-version resource, library
  preload, module probe) sit behind the ratified seam style: plain
  procedural variables defaulting to the real implementations,
  public-mutable by design - production code never assigns them; only
  the platform test suite swaps fakes in (and must restore them).

  The ACL work is the first ACL code in this repository. It grants
  EXACTLY the two documented Windows 10 AppContainer SIDs -
  S-1-15-2-1 (ALL APPLICATION PACKAGES) and S-1-15-2-2 (ALL
  RESTRICTED APPLICATION PACKAGES) - Read+Execute with (OI)(CI) on
  the tree root, and verifies BY SID: identity display names are
  localized and are never parsed. No write or modify right is ever
  granted, and an ACE granting Everyone anything is a refusal.

  The tree manifest is a deterministic build/deployment artifact, not
  a startup cost: ordinary startup never hashes the ~690 MB tree. The
  writer/verifier live here so the same streamed digest primitive
  proves the tree at build time and at gate time.

  No URL exists anywhere here (they live in webview2-runtime.lock
  only) and nothing here touches any frozen interface.
}
unit pweb.platform.webview2.fixed;

{$mode ObjFPC}{$H+}

interface

uses
  windows,
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.os,
  pweb.platform.webview2.runtime,
  pweb.platform.webview2.provision;

const
  /// the ratified CAP-6b3 pin: the exact 4-part version of the bundled
  // Fixed Version Runtime, and the identity the running app must
  // OBSERVE from ICoreWebView2Environment.get_BrowserVersionString
  // - single source for the whole shard: webview2-runtime.lock's
  // `version` key and test/cap6b3/build_fixed_setup.ps1 cross-check
  // against THIS constant (the house 1587-cross-check idiom)
  PWEB_WV2_FIXED_VERSION = '151.0.4129.78';

  /// the runtime subtree, relative to the executable directory
  // - deployed as ordinary application content by the fixed profile;
  // the loader lives inside it so it can only ever be loaded by
  // explicit absolute path, never by DLL search order
  PWEB_WV2_FIXED_SUBDIR = 'runtime\webview2';

  /// how the Fixed Version Runtime cabinet names its one extracted
  // folder: <prefix><4-part version><suffix>
  PWEB_WV2_FIXED_TREE_PREFIX = 'Microsoft.WebView2.FixedVersionRuntime.';
  PWEB_WV2_FIXED_TREE_SUFFIX = '.x64';

  /// the bundled loader: taken from the pinned WebView2 SDK
  // 1.0.1587.40 (webview.lock, covered by its extracted-tree sha256)
  // because the Fixed Version Runtime package ships none
  PWEB_WV2_FIXED_LOADER = 'WebView2Loader.dll';

  /// the ONE documented override Microsoft defines for a fixed
  // runtime; this process owns it end to end (see PWebWv2FixedSelect)
  PWEB_WV2_FIXED_ENV = 'WEBVIEW2_BROWSER_EXECUTABLE_FOLDER';

  /// the browser image inside the tree - also the version/architecture
  // witness (its FileVersion resource IS the runtime version)
  PWEB_WV2_FIXED_BROWSER = 'msedgewebview2.exe';

  /// the other two versioned binaries every valid tree carries; all
  // three are held to the SAME pin, so a mixed tree is refused
  PWEB_WV2_FIXED_MSEDGE = 'msedge.dll';
  PWEB_WV2_FIXED_EMBEDDED = 'EBWebView\x64\EmbeddedBrowserWebView.dll';

  /// Microsoft's documented forbidden location for a fixed runtime
  // folder: it may never live under an Edge installation
  PWEB_WV2_FIXED_FORBIDDEN = '\Edge\Application\';

  /// the two Windows 10 AppContainer SIDs a Fixed Version Runtime
  // >= 120 needs on an unpackaged Win32 host (Microsoft distribution
  // doc); ALWAYS handled as SIDs - the display names are localized
  PWEB_WV2_SID_APP_PACKAGES = 'S-1-15-2-1';
  PWEB_WV2_SID_RESTRICTED_APP_PACKAGES = 'S-1-15-2-2';

  /// the BROAD trustees: an allow-ace giving ANY of these a
  // write/modify/delete right turns the bundled runtime into a
  // tamperable tree, whoever else the DACL also names
  // - Everyone, Authenticated Users, BUILTIN\Users, INTERACTIVE
  // - deliberately NOT here: the object owner, SYSTEM and
  // Administrators, which a per-user install needs in order to create,
  // update and remove the tree at all
  // - READ for a broad trustee is harmless and stays allowed: a benign
  // inherited Everyone-read ace is common on managed images and must
  // never brick startup
  PWEB_WV2_SID_EVERYONE = 'S-1-1-0';
  PWEB_WV2_SID_AUTHENTICATED_USERS = 'S-1-5-11';
  PWEB_WV2_SID_BUILTIN_USERS = 'S-1-5-32-545';
  PWEB_WV2_SID_INTERACTIVE = 'S-1-5-4';
  PWEB_WV2_BROAD_SIDS: array[0..3] of RawUtf8 = (
    PWEB_WV2_SID_EVERYONE,
    PWEB_WV2_SID_AUTHENTICATED_USERS,
    PWEB_WV2_SID_BUILTIN_USERS,
    PWEB_WV2_SID_INTERACTIVE);

  /// FILE_GENERIC_READ or FILE_GENERIC_EXECUTE - exactly what
  // icacls renders as (RX); every bit must be present
  PWEB_WV2_ACL_RX_MASK = $001200A9;

  /// no write/modify right may EVER appear in a granted mask:
  // FILE_WRITE_DATA, FILE_APPEND_DATA, FILE_WRITE_EA,
  // FILE_DELETE_CHILD, FILE_WRITE_ATTRIBUTES, DELETE, WRITE_DAC,
  // WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE
  PWEB_WV2_ACL_FORBIDDEN_MASK =
    $00000002 or $00000004 or $00000010 or $00000040 or $00000100 or
    $00010000 or $00040000 or $00080000 or $10000000 or $40000000;

  /// OBJECT_INHERIT_ACE or CONTAINER_INHERIT_ACE - the (OI)(CI) pair
  PWEB_WV2_ACE_INHERIT = $01 or $02;

  /// INHERIT_ONLY_ACE: the ace grants NOTHING on the object itself, so
  // it can never satisfy the AppContainer requirement on the tree root
  PWEB_WV2_ACE_INHERIT_ONLY = $08;

  /// INHERITED_ACE: evidence only - an inherited ace binds exactly as
  // hard as an explicit one, but a human fixing a refusal needs to
  // know which parent to look at
  PWEB_WV2_ACE_INHERITED = $10;

  /// first line of every deterministic tree manifest; the build
  // script cross-checks this literal (house single-source idiom)
  PWEB_WV2_FIXED_MANIFEST_TAG = 'pweb-wv2-fixed-tree-manifest v1';

  /// IMAGE_FILE_MACHINE_AMD64 - the only architecture this profile
  // ever accepts (no ARM64, no x86)
  PWEB_WV2_PE_MACHINE_AMD64 = $8664;

type
  /// overall verdict of one fixed-runtime preparation
  // - ordinal 0 is the failure state so a zeroed record fails closed
  TPWebWv2FixedStatus = (
    wv2fxFailed,
    wv2fxValidated,
    wv2fxSelected);

  /// which step refused (wv2fsNone only on success)
  TPWebWv2FixedStep = (
    wv2fsNone,
    wv2fsResolve,
    wv2fsPathShape,
    wv2fsDrive,
    wv2fsTreeMissing,
    wv2fsTreeIncomplete,
    wv2fsVersion,
    wv2fsArchitecture,
    wv2fsAcl,
    wv2fsLoaderPreload,
    wv2fsLoaderIdentity,
    wv2fsEnvironment,
    wv2fsIdentity);

  /// everything one preparation learned, for typed native diagnostics
  TPWebWv2FixedResult = record
    /// Failed | Validated | Selected
    Status: TPWebWv2FixedStatus;
    /// the step a failure happened on (wv2fsNone on success)
    FailedStep: TPWebWv2FixedStep;
    /// absolute bundled runtime root (…\runtime\webview2\)
    RuntimeRoot: TFileName;
    /// absolute extracted Fixed Runtime tree (the env-var value)
    TreeDir: TFileName;
    /// absolute bundled loader path (preloaded, never search-ordered)
    LoaderPath: TFileName;
    /// the tree's own 4-part version, read from the browser image
    TreeVersion: RawUtf8;
    /// human diagnostic naming paths/versions/masks on failure
    Diagnostic: RawUtf8;
  end;

  /// signature of the injectable drive-type seam
  // - returns a Win32 DRIVE_* code for the volume holding Path
  TPWebWv2DriveTypeFunc = function(const Path: TFileName): Cardinal;

  /// signature of the injectable file-version seam
  // - VersionText is the locale-free 4-part rendering of the binary's
  // VS_FIXEDFILEINFO file version; False (with ErrorText) on refusal
  TPWebWv2FileVersionFunc = function(const FileName: TFileName;
    out VersionText, ErrorText: RawUtf8): Boolean;

  /// signature of the injectable absolute-path library preload seam
  // - returns 0 on failure (GetLastError stays meaningful)
  TPWebWv2LoadLibraryFunc = function(const FileName: TFileName): THandle;

  /// signature of the injectable loaded-module probe seam
  TPWebWv2ModuleHandleFunc = function(const ModuleName: RawUtf8): THandle;

/// the ratified extracted-tree folder name for the pinned version
function PWebWv2FixedTreeName: TFileName;

/// the bundled runtime root beside the executable
// - Executable.ProgramFilePath ONLY: never the CWD, never an
// environment variable, never app.pwb, never JS
// - '' when the executable path is unknown (fail closed)
function PWebWv2FixedRuntimeRoot: TFileName;

/// pure path-shape policy - no disk access, no OS call
// - refuses empty, relative, device (\\?\ \\.\), UNC (\\host\share or
// //host/share) and Microsoft's forbidden \Edge\Application\ location,
// plus any '..' component; requires a drive-letter absolute path
function PWebWv2FixedPathShapeOk(const Path: TFileName;
  out Why: RawUtf8): Boolean;

/// pure identity policy over an OBSERVED browser version string
// - get_BrowserVersionString may append a channel name after a space
// (documented); the leading token must parse as a strict 4-part
// version, equal Expected exactly, and meet the CAP-4W minimum
function PWebWv2FixedIdentityMatches(const Observed, Expected: RawUtf8;
  out Normalized, Why: RawUtf8): Boolean;

/// the real drive-type probe behind the seam; never raises
function PWebWv2FixedDriveTypeOs(const Path: TFileName): Cardinal;

/// the real VS_FIXEDFILEINFO reader behind the seam; never raises
// - reads the NUMERIC file version, so no locale or string-table
// difference can ever change the verdict
function PWebWv2FixedFileVersionOs(const FileName: TFileName;
  out VersionText, ErrorText: RawUtf8): Boolean;

/// the real absolute-path preload behind the seam; never raises
function PWebWv2FixedLoadLibraryOs(const FileName: TFileName): THandle;

/// the real loaded-module probe behind the seam; never raises
function PWebWv2FixedModuleHandleOs(const ModuleName: RawUtf8): THandle;

/// PE machine word of one image; never raises
function PWebWv2FixedPeMachine(const FileName: TFileName;
  out Machine: Word; out Why: RawUtf8): Boolean;

var
  /// injectable drive-type seam (ratified seam style: plain procedural
  // variable, public-mutable; production never assigns it, ONLY the
  // platform test suite - which must restore the real function)
  PWebWv2FixedDriveType: TPWebWv2DriveTypeFunc = @PWebWv2FixedDriveTypeOs;

  /// injectable file-version seam (same rules as above)
  PWebWv2FixedFileVersion: TPWebWv2FileVersionFunc =
    @PWebWv2FixedFileVersionOs;

  /// injectable loader-preload seam (same rules as above)
  PWebWv2FixedLoadLibrary: TPWebWv2LoadLibraryFunc =
    @PWebWv2FixedLoadLibraryOs;

  /// injectable module-probe seam (same rules as above)
  PWebWv2FixedModuleHandle: TPWebWv2ModuleHandleFunc =
    @PWebWv2FixedModuleHandleOs;

/// validate one bundled runtime root, without selecting anything
// - RuntimeRoot is the folder holding PWEB_WV2_FIXED_LOADER and the
// extracted Fixed Runtime tree; every refusal is typed and named
// - Status is wv2fxValidated on success, never wv2fxSelected
function PWebWv2FixedValidate(
  const RuntimeRoot: TFileName): TPWebWv2FixedResult;

/// select an ALREADY VALIDATED tree for this process
// - LoadLibraryW(<abs loader>) FIRST, then assert
// GetModuleHandleW('WebView2Loader.dll') is that very handle, then
// SetEnvironmentVariableW + mandatory read-back - the ratified order
// - the variable is owned by this process: any inherited value is
// overwritten, it is set exactly once, and it is never changed while
// a WebView lives (a second call is refused)
procedure PWebWv2FixedSelect(var Prepared: TPWebWv2FixedResult);

/// the one app-side orchestration: resolve -> validate -> select
// - the ONLY function examples/08-release/releaseapp.pas calls before
// webview_create under {$ifdef PWEB_FIXED_RUNTIME}
function PWebWv2FixedPrepare: TPWebWv2FixedResult;

/// the post-create half: turn one OBSERVED browser version into the
/// same typed verdict shape the pre-create half produces
// - Prepared is the wv2fxSelected record PWebWv2FixedPrepare returned
// - on a match the record comes back unchanged (still wv2fxSelected)
// - on a mismatch it comes back Failed at wv2fsIdentity, with a
// Diagnostic naming the observed value and the pin, so the caller's
// refusal marker carries the SAME status=/step= grammar as every
// pre-create refusal
function PWebWv2FixedConfirmIdentity(const Prepared: TPWebWv2FixedResult;
  const Observed: RawUtf8): TPWebWv2FixedResult;

/// True once this process has selected a fixed runtime
function PWebWv2FixedSelected: Boolean;

/// test-only reset of the once-per-process selection latch
// - production code never calls this; the platform test suite does,
// so the fail-closed re-entry refusal can be proven repeatedly
procedure PWebWv2FixedResetSelection;

/// deterministic tree manifest: one tagged header line, then
// '<sha256>  <relative/path>' lines sorted ordinal by relative path,
// forward slashes, LF endings, UTF-8 without BOM
// - streams every file through the CAP-6b2 bounded digest
function PWebWv2FixedManifestBuild(const TreeRoot: TFileName;
  out Manifest: RawUtf8; out ErrorText: RawUtf8): Boolean;

/// write PWebWv2FixedManifestBuild output to a file
function PWebWv2FixedManifestWrite(const TreeRoot, ManifestFile: TFileName;
  out ErrorText: RawUtf8): Boolean;

/// verify a tree against a previously written manifest
// - a tampered byte, an extra file, a missing file or a drifted
// header all fail, naming the first offending relative path
function PWebWv2FixedManifestVerify(const TreeRoot, ManifestFile: TFileName;
  out ErrorText: RawUtf8): Boolean;

/// apply the ratified AppContainer ACL to one directory tree root
// - grants EXACTLY S-1-15-2-1 and S-1-15-2-2 Read+Execute with
// (OI)(CI) via SetEntriesInAclW/SetNamedSecurityInfoW, replacing any
// previous entry for those two trustees; never raises
function PWebWv2FixedAclApply(const Dir: TFileName;
  out Diag: RawUtf8): Boolean;

/// verify the embedded Authenticode signature of the five CRITICAL
/// binaries of one bundled runtime root against the ratified leaf
/// subject (CAP-6b3, install time)
// - RuntimeRoot holds PWEB_WV2_FIXED_LOADER and the extracted tree
// - the five are msedgewebview2.exe, msedge.dll, msedge_elf.dll,
// EBWebView\x64\EmbeddedBrowserWebView.dll and WebView2Loader.dll;
// the eleven non-critical redistributables (CRT, d3dcompiler_47,
// dxil, mspdf, widevinecdm) legitimately carry a SECOND Microsoft
// subject and are deliberately NOT enforced on this axis
// - each file must verify Valid with a leaf subject exactly equal to
// ExpectedSubject (the same rule and the same primitive the CAP-6b1
// bootstrapper and the CAP-6b2 standalone are held to); never raises
function PWebWv2FixedVerifySigners(const RuntimeRoot: TFileName;
  const ExpectedSubject: RawUtf8; out Diag: RawUtf8): Boolean;

/// verify the ratified AppContainer ACL BY SID; never raises
// - both SIDs must carry an ACCESS_ALLOWED ace with (OI)(CI), every
// PWEB_WV2_ACL_RX_MASK bit and no forbidden bit; an ACCESS_DENIED ace
// for either SID, or any ace granting Everyone, is a refusal
function PWebWv2FixedAclVerify(const Dir: TFileName;
  out Diag: RawUtf8): Boolean;

/// stable text for a fixed-runtime status (gates parse these)
function PWebWv2FixedStatusText(Status: TPWebWv2FixedStatus): RawUtf8;

/// stable text for a fixed-runtime step (gates parse these)
function PWebWv2FixedStepText(Step: TPWebWv2FixedStep): RawUtf8;

implementation

{ ---- small local helpers (locale-free, no RTL formatting) ---- }

function IntToUtf8Local(Value: Int64): RawUtf8;
var
  num: shortstring;
begin
  Str(Value, num); // locale-free ASCII digits
  Result := num;
end;

function HexU32(Value: LongWord): RawUtf8;
begin
  Result := RawUtf8(SysUtils.IntToHex(Value, 8));
end;

function U8(const FileName: TFileName): RawUtf8;
begin
  Result := StringToUtf8(FileName);
end;

// ordinal (byte-wise) comparison - never a locale collation
function OrdinalLess(const A, B: RawUtf8): Boolean;
var
  i, n: PtrInt;
begin
  n := Length(A);
  if Length(B) < n then
    n := Length(B);
  for i := 1 to n do
    if A[i] <> B[i] then
    begin
      Result := Ord(A[i]) < Ord(B[i]);
      exit;
    end;
  Result := Length(A) < Length(B);
end;

// ASCII-only lowercase: the shape checks below must never depend on
// the process locale (a Turkish dotless i can not change a verdict)
function AsciiLower(const Text: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := Text;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

function ContainsText(const Haystack, Needle: RawUtf8): Boolean;
begin
  Result := Pos(Needle, Haystack) > 0;
end;

{ ---- Win32 imports (declared here, never in the interface) ---- }

const
  DRIVE_UNKNOWN = 0;
  DRIVE_NO_ROOT_DIR = 1;
  DRIVE_REMOVABLE = 2;
  DRIVE_FIXED = 3;
  DRIVE_REMOTE = 4;
  DRIVE_CDROM = 5;
  DRIVE_RAMDISK = 6;

  SE_FILE_OBJECT = 1;
  DACL_SECURITY_INFORMATION = 4;
  TRUSTEE_IS_SID = 0;
  TRUSTEE_IS_WELL_KNOWN_GROUP = 5;
  NO_MULTIPLE_TRUSTEE = 0;
  SET_ACCESS = 2;
  ACCESS_ALLOWED_ACE_TYPE = 0;
  ACCESS_DENIED_ACE_TYPE = 1;
  VS_FFI_SIGNATURE = $FEEF04BD;

type
  TPWebFixedFileInfo = record
    dwSignature: DWord;
    dwStrucVersion: DWord;
    dwFileVersionMS: DWord;
    dwFileVersionLS: DWord;
    dwProductVersionMS: DWord;
    dwProductVersionLS: DWord;
    dwFileFlagsMask: DWord;
    dwFileFlags: DWord;
    dwFileOS: DWord;
    dwFileType: DWord;
    dwFileSubtype: DWord;
    dwFileDateMS: DWord;
    dwFileDateLS: DWord;
  end;
  PPWebFixedFileInfo = ^TPWebFixedFileInfo;

  TPWebTrusteeW = record
    pMultipleTrustee: Pointer;
    MultipleTrusteeOperation: DWord;
    TrusteeForm: DWord;
    TrusteeType: DWord;
    ptstrName: Pointer;
  end;

  TPWebExplicitAccessW = record
    grfAccessPermissions: DWord;
    grfAccessMode: DWord;
    grfInheritance: DWord;
    Trustee: TPWebTrusteeW;
  end;

  TPWebAceHeader = record
    AceType: Byte;
    AceFlags: Byte;
    AceSize: Word;
  end;
  PPWebAceHeader = ^TPWebAceHeader;

  TPWebAccessAce = record
    Header: TPWebAceHeader;
    Mask: DWord;
    SidStart: DWord;
  end;
  PPWebAccessAce = ^TPWebAccessAce;

  TPWebAclHeader = record
    AclRevision: Byte;
    Sbz1: Byte;
    AclSize: Word;
    AceCount: Word;
    Sbz2: Word;
  end;
  PPWebAclHeader = ^TPWebAclHeader;

function PWebGetDriveTypeW(lpRootPathName: PWideChar): UINT; stdcall;
  external 'kernel32.dll' name 'GetDriveTypeW';

function PWebGetFileAttributesW(lpFileName: PWideChar): DWord; stdcall;
  external 'kernel32.dll' name 'GetFileAttributesW';

function PWebLoadLibraryW(lpLibFileName: PWideChar): HMODULE; stdcall;
  external 'kernel32.dll' name 'LoadLibraryW';

function PWebGetModuleHandleW(lpModuleName: PWideChar): HMODULE; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleW';

function PWebSetEnvironmentVariableW(lpName, lpValue: PWideChar): BOOL;
  stdcall; external 'kernel32.dll' name 'SetEnvironmentVariableW';

function PWebGetEnvironmentVariableW(lpName: PWideChar; lpBuffer: PWideChar;
  nSize: DWord): DWord; stdcall;
  external 'kernel32.dll' name 'GetEnvironmentVariableW';

function PWebLocalFree(hMem: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'LocalFree';

function PWebGetFileVersionInfoSizeW(lptstrFilename: PWideChar;
  lpdwHandle: PDWord): DWord; stdcall;
  external 'version.dll' name 'GetFileVersionInfoSizeW';

function PWebGetFileVersionInfoW(lptstrFilename: PWideChar;
  dwHandle, dwLen: DWord; lpData: Pointer): BOOL; stdcall;
  external 'version.dll' name 'GetFileVersionInfoW';

function PWebVerQueryValueW(pBlock: Pointer; lpSubBlock: PWideChar;
  var lplpBuffer: Pointer; var puLen: UINT): BOOL; stdcall;
  external 'version.dll' name 'VerQueryValueW';

function PWebConvertStringSidToSidW(StringSid: PWideChar;
  var Sid: Pointer): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSidToSidW';

function PWebEqualSid(pSid1, pSid2: Pointer): BOOL; stdcall;
  external 'advapi32.dll' name 'EqualSid';

function PWebGetAce(pAcl: Pointer; dwAceIndex: DWord;
  var pAce: Pointer): BOOL; stdcall;
  external 'advapi32.dll' name 'GetAce';

function PWebGetNamedSecurityInfoW(pObjectName: PWideChar;
  ObjectType, SecurityInfo: DWord; ppsidOwner, ppsidGroup, ppDacl,
  ppSacl, ppSecurityDescriptor: PPointer): DWord; stdcall;
  external 'advapi32.dll' name 'GetNamedSecurityInfoW';

function PWebSetNamedSecurityInfoW(pObjectName: PWideChar;
  ObjectType, SecurityInfo: DWord;
  psidOwner, psidGroup, pDacl, pSacl: Pointer): DWord; stdcall;
  external 'advapi32.dll' name 'SetNamedSecurityInfoW';

function PWebSetEntriesInAclW(cCountOfExplicitEntries: DWord;
  pListOfExplicitEntries: Pointer; OldAcl: Pointer;
  var NewAcl: Pointer): DWord; stdcall;
  external 'advapi32.dll' name 'SetEntriesInAclW';

{ ---- resolution ---- }

function PWebWv2FixedTreeName: TFileName;
begin
  Result := PWEB_WV2_FIXED_TREE_PREFIX + PWEB_WV2_FIXED_VERSION +
            PWEB_WV2_FIXED_TREE_SUFFIX;
end;

function PWebWv2FixedRuntimeRoot: TFileName;
var
  exeDir: TFileName;
begin
  // the ONE resolution rule: beside the executable. Never
  // GetCurrentDir, never an environment variable, never app.pwb,
  // never anything a page could influence.
  Result := '';
  exeDir := Executable.ProgramFilePath;
  if exeDir = '' then
    exit;
  Result := IncludeTrailingPathDelimiter(
    IncludeTrailingPathDelimiter(exeDir) + PWEB_WV2_FIXED_SUBDIR);
end;

{ ---- pure path-shape policy ---- }

function PWebWv2FixedPathShapeOk(const Path: TFileName;
  out Why: RawUtf8): Boolean;
var
  text, lower: RawUtf8;
  i: PtrInt;
begin
  Result := False;
  Why := '';
  text := U8(Path);
  if text = '' then
  begin
    Why := 'empty path';
    exit;
  end;
  // device and UNC forms are refused before anything touches the disk
  if (Length(text) >= 2) and
     ((text[1] = '\') or (text[1] = '/')) and
     ((text[2] = '\') or (text[2] = '/')) then
  begin
    Why := 'UNC or device path form is never accepted: ' + text;
    exit;
  end;
  if (Length(text) < 3) or
     not (text[1] in ['A'..'Z', 'a'..'z']) or
     (text[2] <> ':') or
     not ((text[3] = '\') or (text[3] = '/')) then
  begin
    Why := 'not a drive-letter absolute path: ' + text;
    exit;
  end;
  for i := 1 to Length(text) do
    if text[i] = '/' then
    begin
      // one separator convention only: a mixed form could make two
      // different strings name the same tree and defeat comparisons
      Why := 'forward slash in a Windows path: ' + text;
      exit;
    end;
  if ContainsText(text, '\..\') or
     (Copy(text, Length(text) - 2, 3) = '\..') then
  begin
    Why := 'relative component in an absolute path: ' + text;
    exit;
  end;
  lower := AsciiLower(text);
  if ContainsText(lower, AsciiLower(PWEB_WV2_FIXED_FORBIDDEN)) then
  begin
    // Microsoft-documented restriction: a fixed runtime folder may
    // never live inside an Edge installation
    Why := 'forbidden location (' + PWEB_WV2_FIXED_FORBIDDEN + '): ' + text;
    exit;
  end;
  Result := True;
end;

{ ---- pure observed-identity policy ---- }

function PWebWv2FixedIdentityMatches(const Observed, Expected: RawUtf8;
  out Normalized, Why: RawUtf8): Boolean;
var
  parsed: TPWebWv2Version;
  space: PtrInt;
begin
  Result := False;
  Normalized := '';
  Why := '';
  if Observed = '' then
  begin
    Why := 'observed browser version is empty';
    exit;
  end;
  // get_BrowserVersionString may append a channel name after a space
  space := Pos(' ', Observed);
  if space > 0 then
    Normalized := Copy(Observed, 1, space - 1)
  else
    Normalized := Observed;
  if not PWebWv2VersionParse(Normalized, parsed) then
  begin
    Why := 'observed browser version is not a strict 4-part version: ' +
      Observed;
    exit;
  end;
  if not PWebWv2VersionUsable(parsed) then
  begin
    // one threshold only, the CAP-4W loader minimum
    Why := 'observed runtime build ' + IntToUtf8Local(parsed.Build) +
      ' is below the CAP-4W minimum ' +
      IntToUtf8Local(PWEB_WV2_MIN_BUILD);
    exit;
  end;
  if Normalized <> Expected then
  begin
    Why := 'observed runtime ' + Normalized + ' is NOT the pinned ' +
      Expected + ' (registry BrowserExecutableFolder policy? Evergreen?)';
    exit;
  end;
  Result := True;
end;

{ ---- real impure primitives behind the seams ---- }

function PWebWv2FixedDriveTypeOs(const Path: TFileName): Cardinal;
var
  drive: UnicodeString;
begin
  Result := DRIVE_UNKNOWN;
  try
    drive := UnicodeString(ExtractFileDrive(Path));
    if drive = '' then
      exit;
    if drive[Length(drive)] <> '\' then
      drive := drive + '\';
    Result := PWebGetDriveTypeW(PWideChar(drive));
  except
    Result := DRIVE_UNKNOWN;
  end;
end;

function PWebWv2FixedFileVersionOs(const FileName: TFileName;
  out VersionText, ErrorText: RawUtf8): Boolean;
var
  wide: UnicodeString;
  size, handle: DWord;
  block: Pointer;
  info: Pointer;
  len: UINT;
  fixed: PPWebFixedFileInfo;
begin
  Result := False;
  VersionText := '';
  ErrorText := '';
  try
    wide := UnicodeString(FileName);
    handle := 0;
    size := PWebGetFileVersionInfoSizeW(PWideChar(wide), @handle);
    if size = 0 then
    begin
      ErrorText := 'no version resource (error ' +
        HexU32(GetLastError) + '): ' + U8(FileName);
      exit;
    end;
    GetMem(block, size);
    try
      if not PWebGetFileVersionInfoW(PWideChar(wide), 0, size, block) then
      begin
        ErrorText := 'GetFileVersionInfoW error ' +
          HexU32(GetLastError) + ': ' + U8(FileName);
        exit;
      end;
      info := nil;
      len := 0;
      if not PWebVerQueryValueW(block, '\', info, len) or
         (info = nil) or
         (len < SizeOf(TPWebFixedFileInfo)) then
      begin
        ErrorText := 'VS_FIXEDFILEINFO unavailable: ' + U8(FileName);
        exit;
      end;
      fixed := PPWebFixedFileInfo(info);
      if fixed^.dwSignature <> VS_FFI_SIGNATURE then
      begin
        ErrorText := 'VS_FIXEDFILEINFO signature ' +
          HexU32(fixed^.dwSignature) + ' is not VS_FFI_SIGNATURE: ' +
          U8(FileName);
        exit;
      end;
      // NUMERIC version: no string table, no language, no locale can
      // ever change what this reports
      VersionText :=
        IntToUtf8Local(fixed^.dwFileVersionMS shr 16) + '.' +
        IntToUtf8Local(fixed^.dwFileVersionMS and $FFFF) + '.' +
        IntToUtf8Local(fixed^.dwFileVersionLS shr 16) + '.' +
        IntToUtf8Local(fixed^.dwFileVersionLS and $FFFF);
      Result := True;
    finally
      FreeMem(block);
    end;
  except
    on E: Exception do
    begin
      Result := False;
      VersionText := '';
      ErrorText := 'unexpected ' + RawUtf8(E.ClassName) +
        ' reading the version resource of ' + U8(FileName);
    end;
  end;
end;

function PWebWv2FixedLoadLibraryOs(const FileName: TFileName): THandle;
begin
  Result := 0;
  try
    // ABSOLUTE path only: the bundled loader can never be resolved by
    // DLL search order, so nothing on the machine can substitute it
    Result := PWebLoadLibraryW(PWideChar(UnicodeString(FileName)));
  except
    Result := 0;
  end;
end;

function PWebWv2FixedModuleHandleOs(const ModuleName: RawUtf8): THandle;
begin
  Result := 0;
  try
    Result := PWebGetModuleHandleW(
      PWideChar(Utf8ToSynUnicode(ModuleName)));
  except
    Result := 0;
  end;
end;

function PWebWv2FixedPeMachine(const FileName: TFileName;
  out Machine: Word; out Why: RawUtf8): Boolean;
var
  handle: THandle;
  mz: Word;
  lfanew: LongInt;
  sig: LongWord;
begin
  Result := False;
  Machine := 0;
  Why := '';
  try
    handle := FileOpen(FileName, fmOpenRead or fmShareDenyNone);
    if not ValidHandle(handle) then
    begin
      Why := 'cannot open for PE inspection: ' + U8(FileName);
      exit;
    end;
    try
      mz := 0;
      if (FileRead(handle, mz, SizeOf(mz)) <> SizeOf(mz)) or
         (mz <> $5A4D) then // 'MZ'
      begin
        Why := 'not a PE image (no MZ): ' + U8(FileName);
        exit;
      end;
      // origin 0 = from the beginning (sysutils.FileSeek; the classes
      // unit is deliberately not pulled in for one enumeration value)
      if FileSeek(handle, Int64($3C), 0) <> $3C then
      begin
        Why := 'truncated DOS header: ' + U8(FileName);
        exit;
      end;
      lfanew := 0;
      if (FileRead(handle, lfanew, SizeOf(lfanew)) <> SizeOf(lfanew)) or
         (lfanew <= 0) then
      begin
        Why := 'invalid e_lfanew: ' + U8(FileName);
        exit;
      end;
      if FileSeek(handle, Int64(lfanew), 0) <> lfanew then
      begin
        Why := 'e_lfanew points past the file: ' + U8(FileName);
        exit;
      end;
      sig := 0;
      if (FileRead(handle, sig, SizeOf(sig)) <> SizeOf(sig)) or
         (sig <> $00004550) then // 'PE\0\0'
      begin
        Why := 'not a PE image (no PE signature): ' + U8(FileName);
        exit;
      end;
      if FileRead(handle, Machine, SizeOf(Machine)) <> SizeOf(Machine) then
      begin
        Why := 'truncated COFF header: ' + U8(FileName);
        Machine := 0;
        exit;
      end;
      Result := True;
    finally
      FileClose(handle);
    end;
  except
    on E: Exception do
    begin
      Result := False;
      Machine := 0;
      Why := 'unexpected ' + RawUtf8(E.ClassName) +
        ' reading the PE header of ' + U8(FileName);
    end;
  end;
end;

{ ---- Authenticode over the critical binaries (install time) ---- }

function PWebWv2FixedVerifySigners(const RuntimeRoot: TFileName;
  const ExpectedSubject: RawUtf8; out Diag: RawUtf8): Boolean;
const
  // relative to the extracted tree; the loader is handled separately
  // because it lives BESIDE the tree, in the runtime root
  CRITICAL: array[0..3] of RawUtf8 = (
    PWEB_WV2_FIXED_BROWSER,
    PWEB_WV2_FIXED_MSEDGE,
    'msedge_elf.dll',
    PWEB_WV2_FIXED_EMBEDDED);
var
  root, tree, target: TFileName;
  i: PtrInt;
  sigDiag: RawUtf8;
begin
  Result := False;
  Diag := '';
  try
    if ExpectedSubject = '' then
    begin
      // a missing pin can never wave a payload through
      Diag := 'expected authenticode subject is empty';
      exit;
    end;
    if not DirectoryExists(RuntimeRoot) then
    begin
      Diag := 'runtime root missing: ' + U8(RuntimeRoot);
      exit;
    end;
    root := IncludeTrailingPathDelimiter(RuntimeRoot);
    tree := IncludeTrailingPathDelimiter(root + PWebWv2FixedTreeName);
    for i := 0 to High(CRITICAL) do
    begin
      target := tree + Utf8ToString(CRITICAL[i]);
      if not FileExists(target) then
      begin
        Diag := 'critical binary missing: ' + CRITICAL[i];
        exit;
      end;
      if not PWebWv2AuthenticodeCheck(target, ExpectedSubject, sigDiag) then
      begin
        Diag := 'critical binary ' + CRITICAL[i] + ' refused: ' + sigDiag;
        exit;
      end;
    end;
    target := root + PWEB_WV2_FIXED_LOADER;
    if not FileExists(target) then
    begin
      Diag := 'critical binary missing: ' + PWEB_WV2_FIXED_LOADER;
      exit;
    end;
    if not PWebWv2AuthenticodeCheck(target, ExpectedSubject, sigDiag) then
    begin
      Diag := 'critical binary ' + PWEB_WV2_FIXED_LOADER + ' refused: ' +
        sigDiag;
      exit;
    end;
    Diag := IntToUtf8Local(Length(CRITICAL) + 1) + ' critical binaries ' +
      'carry a Valid signature with leaf subject exactly ' +
      ExpectedSubject;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      Diag := 'unexpected ' + RawUtf8(E.ClassName) +
        ' verifying the critical-binary signatures';
    end;
  end;
end;

{ ---- ACL: apply and verify BY SID (never by display name) ---- }

// resolves both ratified AppContainer SIDs; caller LocalFrees them
function ResolveAppContainerSids(out SidPackages, SidRestricted: Pointer;
  out Diag: RawUtf8): Boolean;
begin
  Result := False;
  SidPackages := nil;
  SidRestricted := nil;
  Diag := '';
  if not PWebConvertStringSidToSidW(
       PWideChar(UnicodeString(PWEB_WV2_SID_APP_PACKAGES)), SidPackages) then
  begin
    Diag := 'ConvertStringSidToSidW(' + PWEB_WV2_SID_APP_PACKAGES +
      ') error ' + HexU32(GetLastError);
    exit;
  end;
  if not PWebConvertStringSidToSidW(
       PWideChar(UnicodeString(PWEB_WV2_SID_RESTRICTED_APP_PACKAGES)),
       SidRestricted) then
  begin
    Diag := 'ConvertStringSidToSidW(' +
      PWEB_WV2_SID_RESTRICTED_APP_PACKAGES + ') error ' +
      HexU32(GetLastError);
    PWebLocalFree(SidPackages);
    SidPackages := nil;
    exit;
  end;
  Result := True;
end;

function PWebWv2FixedAclApply(const Dir: TFileName;
  out Diag: RawUtf8): Boolean;
var
  sidPackages, sidRestricted: Pointer;
  entries: array[0..1] of TPWebExplicitAccessW;
  wide: UnicodeString;
  oldDacl, newDacl, sd: Pointer;
  status: DWord;
begin
  Result := False;
  Diag := '';
  sidPackages := nil;
  sidRestricted := nil;
  newDacl := nil;
  sd := nil;
  try
    if not DirectoryExists(Dir) then
    begin
      Diag := 'ACL target directory missing: ' + U8(Dir);
      exit;
    end;
    if not ResolveAppContainerSids(sidPackages, sidRestricted, Diag) then
      exit;
    try
      wide := UnicodeString(IncludeTrailingPathDelimiter(Dir));
      SetLength(wide, Length(wide) - 1); // security APIs want no trailing '\'
      UniqueString(wide); // SetNamedSecurityInfoW takes a writable LPWSTR
      oldDacl := nil;
      status := PWebGetNamedSecurityInfoW(PWideChar(wide), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION, nil, nil, @oldDacl, nil, @sd);
      if status <> ERROR_SUCCESS then
      begin
        Diag := 'GetNamedSecurityInfoW error ' + IntToUtf8Local(status) +
          ': ' + U8(Dir);
        exit;
      end;
      FillChar(entries, SizeOf(entries), 0);
      // SET_ACCESS (not GRANT_ACCESS): the new ace REPLACES any
      // previous entry for that trustee, so re-running the installer
      // is idempotent and the granted rights are exactly RX
      entries[0].grfAccessPermissions := PWEB_WV2_ACL_RX_MASK;
      entries[0].grfAccessMode := SET_ACCESS;
      entries[0].grfInheritance := PWEB_WV2_ACE_INHERIT;
      entries[0].Trustee.MultipleTrusteeOperation := NO_MULTIPLE_TRUSTEE;
      entries[0].Trustee.TrusteeForm := TRUSTEE_IS_SID;
      entries[0].Trustee.TrusteeType := TRUSTEE_IS_WELL_KNOWN_GROUP;
      entries[0].Trustee.ptstrName := sidPackages;
      entries[1] := entries[0];
      entries[1].Trustee.ptstrName := sidRestricted;
      status := PWebSetEntriesInAclW(2, @entries[0], oldDacl, newDacl);
      if (status <> ERROR_SUCCESS) or
         (newDacl = nil) then
      begin
        Diag := 'SetEntriesInAclW error ' + IntToUtf8Local(status);
        exit;
      end;
      status := PWebSetNamedSecurityInfoW(PWideChar(wide), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION, nil, nil, newDacl, nil);
      if status <> ERROR_SUCCESS then
      begin
        Diag := 'SetNamedSecurityInfoW error ' + IntToUtf8Local(status) +
          ' (elevation is NEVER attempted; the ratified per-user scope ' +
          'needs none): ' + U8(Dir);
        exit;
      end;
      Diag := 'granted ' + PWEB_WV2_SID_APP_PACKAGES + ' and ' +
        PWEB_WV2_SID_RESTRICTED_APP_PACKAGES + ' (OI)(CI) RX mask 0x' +
        HexU32(PWEB_WV2_ACL_RX_MASK) + ' on ' + U8(Dir);
      Result := True;
    finally
      if newDacl <> nil then
        PWebLocalFree(newDacl);
      if sd <> nil then
        PWebLocalFree(sd);
      if sidPackages <> nil then
        PWebLocalFree(sidPackages);
      if sidRestricted <> nil then
        PWebLocalFree(sidRestricted);
    end;
  except
    on E: Exception do
    begin
      Result := False;
      Diag := 'unexpected ' + RawUtf8(E.ClassName) + ' applying the ACL';
    end;
  end;
end;

function PWebWv2FixedAclVerify(const Dir: TFileName;
  out Diag: RawUtf8): Boolean;
var
  sidPackages, sidRestricted: Pointer;
  broadSids: array[0..High(PWEB_WV2_BROAD_SIDS)] of Pointer;
  wide: UnicodeString;
  dacl, sd, ace, aceSid: Pointer;
  status: DWord;
  i, aceCount: DWord;
  b: PtrInt;
  hdr: PPWebAceHeader;
  allow: PPWebAccessAce;
  seenPackages, seenRestricted, isBroad: Boolean;
  mask: DWord;
  broadName: RawUtf8;

  function AceOrigin(Flags: Byte): RawUtf8;
  begin
    // an inherited ace and an explicit one are equally binding, but a
    // human reading the refusal needs to know WHERE to fix it
    if (Flags and PWEB_WV2_ACE_INHERITED) <> 0 then
      Result := 'inherited'
    else
      Result := 'explicit';
  end;

begin
  Result := False;
  Diag := '';
  sidPackages := nil;
  sidRestricted := nil;
  FillChar(broadSids, SizeOf(broadSids), 0);
  sd := nil;
  try
    if not DirectoryExists(Dir) then
    begin
      Diag := 'ACL target directory missing: ' + U8(Dir);
      exit;
    end;
    if not ResolveAppContainerSids(sidPackages, sidRestricted, Diag) then
      exit;
    try
      for b := 0 to High(PWEB_WV2_BROAD_SIDS) do
        if not PWebConvertStringSidToSidW(PWideChar(
             UnicodeString(PWEB_WV2_BROAD_SIDS[b])), broadSids[b]) then
        begin
          Diag := 'ConvertStringSidToSidW(' + PWEB_WV2_BROAD_SIDS[b] +
            ') error ' + HexU32(GetLastError);
          exit;
        end;
      wide := UnicodeString(IncludeTrailingPathDelimiter(Dir));
      SetLength(wide, Length(wide) - 1);
      UniqueString(wide);
      dacl := nil;
      status := PWebGetNamedSecurityInfoW(PWideChar(wide), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION, nil, nil, @dacl, nil, @sd);
      if status <> ERROR_SUCCESS then
      begin
        Diag := 'GetNamedSecurityInfoW error ' + IntToUtf8Local(status) +
          ': ' + U8(Dir);
        exit;
      end;
      if dacl = nil then
      begin
        // a NULL DACL grants everyone everything: never acceptable
        Diag := 'NULL DACL (grants everyone everything): ' + U8(Dir);
        exit;
      end;
      seenPackages := False;
      seenRestricted := False;
      aceCount := PPWebAclHeader(dacl)^.AceCount;
      for i := 0 to aceCount - 1 do
      begin
        ace := nil;
        if not PWebGetAce(dacl, i, ace) or
           (ace = nil) then
        begin
          Diag := 'GetAce(' + IntToUtf8Local(i) + ') error ' +
            HexU32(GetLastError) + ': ' + U8(Dir);
          exit;
        end;
        hdr := PPWebAceHeader(ace);
        if (hdr^.AceType <> ACCESS_ALLOWED_ACE_TYPE) and
           (hdr^.AceType <> ACCESS_DENIED_ACE_TYPE) then
        begin
          // object/callback/conditional aces do not carry a SID at the
          // fixed offset this walk reads, so their grant is INVISIBLE
          // here: refuse rather than skip past an unknown grant
          Diag := 'unhandled ace type ' + IntToUtf8Local(hdr^.AceType) +
            ' at index ' + IntToUtf8Local(i) + ' (' +
            AceOrigin(hdr^.AceFlags) + ') - its grant cannot be read: ' +
            U8(Dir);
          exit;
        end;
        allow := PPWebAccessAce(ace);
        aceSid := @allow^.SidStart;
        mask := allow^.Mask;
        // (1) NO broad trustee may hold write/modify on the tree - a
        // world-, Users-, Authenticated-Users- or INTERACTIVE-writable
        // runtime is exactly the tampering surface the AppContainer
        // grant exists to close. Read-only for a broad trustee is
        // harmless and stays allowed (a benign inherited Everyone-read
        // ace is common on managed images and must not brick startup).
        // The owner, SYSTEM and Administrators keep write: a per-user
        // install could not be created, updated or removed otherwise.
        isBroad := False;
        broadName := '';
        for b := 0 to High(PWEB_WV2_BROAD_SIDS) do
          if PWebEqualSid(aceSid, broadSids[b]) then
          begin
            isBroad := True;
            broadName := PWEB_WV2_BROAD_SIDS[b];
            break;
          end;
        if isBroad and
           (hdr^.AceType = ACCESS_ALLOWED_ACE_TYPE) and
           ((mask and PWEB_WV2_ACL_FORBIDDEN_MASK) <> 0) then
        begin
          Diag := 'a broad trustee (' + broadName + ') holds write/modify ' +
            'rights (mask 0x' + HexU32(mask) + ' meets forbidden 0x' +
            HexU32(PWEB_WV2_ACL_FORBIDDEN_MASK) + ', ' +
            AceOrigin(hdr^.AceFlags) + ' ace) on ' + U8(Dir);
          exit;
        end;
        if not (PWebEqualSid(aceSid, sidPackages) or
                PWebEqualSid(aceSid, sidRestricted)) then
          continue;
        if hdr^.AceType = ACCESS_DENIED_ACE_TYPE then
        begin
          Diag := 'a DENY ace exists for an AppContainer SID (' +
            AceOrigin(hdr^.AceFlags) + ') on ' + U8(Dir);
          exit;
        end;
        if (hdr^.AceFlags and PWEB_WV2_ACE_INHERIT_ONLY) <> 0 then
          // INHERIT_ONLY grants nothing on the root itself: it can
          // never satisfy the requirement, so it is not counted
          continue;
        if (hdr^.AceFlags and PWEB_WV2_ACE_INHERIT) <>
           PWEB_WV2_ACE_INHERIT then
        begin
          Diag := 'AppContainer ace is not (OI)(CI): flags 0x' +
            HexU32(hdr^.AceFlags) + ' (' + AceOrigin(hdr^.AceFlags) +
            ') on ' + U8(Dir);
          exit;
        end;
        if (mask and PWEB_WV2_ACL_RX_MASK) <> PWEB_WV2_ACL_RX_MASK then
        begin
          Diag := 'AppContainer ace mask 0x' + HexU32(mask) +
            ' lacks Read+Execute 0x' + HexU32(PWEB_WV2_ACL_RX_MASK) +
            ' on ' + U8(Dir);
          exit;
        end;
        if (mask and PWEB_WV2_ACL_FORBIDDEN_MASK) <> 0 then
        begin
          Diag := 'AppContainer ace mask 0x' + HexU32(mask) +
            ' grants write/modify rights (forbidden 0x' +
            HexU32(PWEB_WV2_ACL_FORBIDDEN_MASK) + ') on ' + U8(Dir);
          exit;
        end;
        if PWebEqualSid(aceSid, sidPackages) then
          seenPackages := True
        else
          seenRestricted := True;
      end;
      // an EMPTY DACL (AceCount = 0) walks zero aces and lands here:
      // the ace count is named so the refusal reads truthfully rather
      // than suggesting some ace was inspected and rejected
      if not seenPackages then
      begin
        Diag := 'no (OI)(CI) RX ace for ' + PWEB_WV2_SID_APP_PACKAGES +
          ' among the ' + IntToUtf8Local(aceCount) + ' ace(s) on ' + U8(Dir);
        exit;
      end;
      if not seenRestricted then
      begin
        Diag := 'no (OI)(CI) RX ace for ' +
          PWEB_WV2_SID_RESTRICTED_APP_PACKAGES + ' among the ' +
          IntToUtf8Local(aceCount) + ' ace(s) on ' + U8(Dir);
        exit;
      end;
      Diag := 'verified BY SID over ' + IntToUtf8Local(aceCount) +
        ' ace(s): ' + PWEB_WV2_SID_APP_PACKAGES + ' and ' +
        PWEB_WV2_SID_RESTRICTED_APP_PACKAGES + ' carry (OI)(CI) RX mask 0x' +
        HexU32(PWEB_WV2_ACL_RX_MASK) + ' with no write right, and no broad ' +
        'trustee holds write on ' + U8(Dir);
      Result := True;
    finally
      if sd <> nil then
        PWebLocalFree(sd);
      for b := 0 to High(broadSids) do
        if broadSids[b] <> nil then
          PWebLocalFree(broadSids[b]);
      if sidPackages <> nil then
        PWebLocalFree(sidPackages);
      if sidRestricted <> nil then
        PWebLocalFree(sidRestricted);
    end;
  except
    on E: Exception do
    begin
      Result := False;
      Diag := 'unexpected ' + RawUtf8(E.ClassName) + ' verifying the ACL';
    end;
  end;
end;

{ ---- deterministic tree manifest ---- }

// The walk goes straight to the wide Win32 API over explicit
// UTF-8 <-> UTF-16 conversions, the ratified pwebbundle/
// TFolderAssetStore precedent: the RTL Ansi filesystem layer depends
// on runtime codepage state and mistranslates cross-unit
// concatenations, and a manifest whose bytes must be deterministic
// gets exactly one path to the kernel.
function CollectRelative(const Root: TFileName; const RelPrefix: RawUtf8;
  var Paths: TRawUtf8DynArray; var Count: PtrInt;
  out Why: RawUtf8): Boolean;
var
  h: THandle;
  fd: WIN32_FIND_DATAW;
  patternW, nameW: UnicodeString;
  nameU, rel: RawUtf8;
  native: TFileName;
begin
  Result := False;
  Why := '';
  native := Root; // always carries its trailing path delimiter
  if RelPrefix <> '' then
    native := native +
      Utf8ToString(StringReplaceAll(RelPrefix, '/', '\')) + '\';
  patternW := Utf8ToSynUnicode(U8(native)) + '*';
  h := FindFirstFileW(PWideChar(patternW), @fd);
  if h = INVALID_HANDLE_VALUE then
  begin
    Why := 'cannot enumerate ' + U8(native) + ' (Win32 error ' +
      IntToUtf8Local(GetLastError) + ')';
    exit;
  end;
  try
    repeat
      nameW := fd.cFileName; // up to the terminating NUL
      if (nameW = '.') or
         (nameW = '..') then
        continue;
      nameU := RawUnicodeToUtf8(PWideChar(nameW), Length(nameW));
      if RelPrefix = '' then
        rel := nameU
      else
        rel := RelPrefix + '/' + nameU;
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
      begin
        // a junction or symlink could point the "bundled" runtime
        // anywhere on (or off) the machine: never walk one
        Why := 'reparse point refused inside the runtime tree: ' + rel;
        exit;
      end;
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      begin
        if not CollectRelative(Root, rel, Paths, Count, Why) then
          exit;
      end
      else
      begin
        if Count = Length(Paths) then
          SetLength(Paths, Count + 256);
        Paths[Count] := rel;
        Inc(Count);
      end;
    until not FindNextFileW(h, fd);
    // a mid-enumeration failure must never silently truncate the
    // manifest: the only legitimate loop exit is "no more files"
    if GetLastError <> ERROR_NO_MORE_FILES then
    begin
      Why := 'enumeration of ' + U8(native) + ' failed (Win32 error ' +
        IntToUtf8Local(GetLastError) + ')';
      exit;
    end;
    Result := True;
  finally
    windows.FindClose(h);
  end;
end;

procedure SortOrdinal(var Paths: TRawUtf8DynArray; Count: PtrInt);
var
  i, j: PtrInt;
  pivot: RawUtf8;
begin
  // insertion sort: the tree is a few hundred entries and the ordering
  // must be ordinal (byte-wise), never a locale collation
  for i := 1 to Count - 1 do
  begin
    pivot := Paths[i];
    j := i - 1;
    while (j >= 0) and
          OrdinalLess(pivot, Paths[j]) do
    begin
      Paths[j + 1] := Paths[j];
      Dec(j);
    end;
    Paths[j + 1] := pivot;
  end;
end;

function PWebWv2FixedManifestBuild(const TreeRoot: TFileName;
  out Manifest: RawUtf8; out ErrorText: RawUtf8): Boolean;
var
  root: TFileName;
  paths: TRawUtf8DynArray;
  count, i: PtrInt;
  digest, hashErr: RawUtf8;
  lines: RawUtf8;
begin
  Result := False;
  Manifest := '';
  ErrorText := '';
  try
    if not DirectoryExists(TreeRoot) then
    begin
      ErrorText := 'tree root missing: ' + U8(TreeRoot);
      exit;
    end;
    root := IncludeTrailingPathDelimiter(TreeRoot);
    paths := nil;
    count := 0;
    if not CollectRelative(root, '', paths, count, ErrorText) then
      exit;
    if count = 0 then
    begin
      // an empty tree can never be the ratified runtime
      ErrorText := 'tree root holds no file: ' + U8(TreeRoot);
      exit;
    end;
    SortOrdinal(paths, count);
    lines := PWEB_WV2_FIXED_MANIFEST_TAG + #10;
    for i := 0 to count - 1 do
    begin
      if not PWebWv2FileSha256(
           root + Utf8ToString(StringReplaceAll(paths[i], '/', '\')),
           digest, hashErr) then
      begin
        ErrorText := 'cannot digest ' + paths[i] + ': ' + hashErr;
        exit;
      end;
      lines := lines + digest + '  ' + paths[i] + #10;
    end;
    Manifest := lines;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      Manifest := '';
      ErrorText := 'unexpected ' + RawUtf8(E.ClassName) +
        ' building the tree manifest of ' + U8(TreeRoot);
    end;
  end;
end;

function PWebWv2FixedManifestWrite(const TreeRoot, ManifestFile: TFileName;
  out ErrorText: RawUtf8): Boolean;
var
  manifest: RawUtf8;
begin
  Result := False;
  if not PWebWv2FixedManifestBuild(TreeRoot, manifest, ErrorText) then
    exit;
  try
    // UTF-8 without BOM, LF endings: byte-comparable across tools
    if not FileFromString(manifest, ManifestFile) then
    begin
      ErrorText := 'cannot write the manifest: ' + U8(ManifestFile);
      exit;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      ErrorText := 'unexpected ' + RawUtf8(E.ClassName) +
        ' writing ' + U8(ManifestFile);
    end;
  end;
end;

function PWebWv2FixedManifestVerify(const TreeRoot, ManifestFile: TFileName;
  out ErrorText: RawUtf8): Boolean;
var
  expected, actual: RawUtf8;
begin
  Result := False;
  ErrorText := '';
  try
    if not FileExists(ManifestFile) then
    begin
      ErrorText := 'manifest missing: ' + U8(ManifestFile);
      exit;
    end;
    expected := StringFromFile(ManifestFile);
    // tolerate a CRLF-normalising checkout without weakening anything:
    // the comparison is still byte-exact over the normalised text
    expected := StringReplaceAll(expected, #13#10, #10);
    if Copy(expected, 1, Length(PWEB_WV2_FIXED_MANIFEST_TAG)) <>
       PWEB_WV2_FIXED_MANIFEST_TAG then
    begin
      ErrorText := 'manifest header is not "' +
        PWEB_WV2_FIXED_MANIFEST_TAG + '": ' + U8(ManifestFile);
      exit;
    end;
    if not PWebWv2FixedManifestBuild(TreeRoot, actual, ErrorText) then
      exit;
    if actual <> expected then
    begin
      ErrorText := 'tree does not match the manifest (byte-exact ' +
        'comparison over ' + IntToUtf8Local(Length(expected)) +
        ' manifest bytes vs ' + IntToUtf8Local(Length(actual)) +
        ' recomputed): ' + U8(TreeRoot);
      exit;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      ErrorText := 'unexpected ' + RawUtf8(E.ClassName) +
        ' verifying ' + U8(TreeRoot) + ' against ' + U8(ManifestFile);
    end;
  end;
end;

{ ---- validation ---- }

// True when the path carries FILE_ATTRIBUTE_REPARSE_POINT (a junction
// or symlink). Never raises; an unreadable attribute set reads as
// "not a reparse point" - the caller's existence check runs first, so
// an unreadable path has already been refused.
function IsReparsePoint(const Path: TFileName): Boolean;
var
  attr: DWord;
begin
  Result := False;
  try
    attr := PWebGetFileAttributesW(
      PWideChar(Utf8ToSynUnicode(U8(Path))));
    Result := (attr <> INVALID_FILE_ATTRIBUTES) and
              ((attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
  except
    Result := False;
  end;
end;

// one binary of the tree, checked on BOTH pinned axes
function CheckPinnedBinary(const FileName: TFileName; const What: RawUtf8;
  out Version: RawUtf8; out FailedOnVersion: Boolean;
  out Why: RawUtf8): Boolean;
var
  parsed: TPWebWv2Version;
  machine: Word;
begin
  Result := False;
  FailedOnVersion := True;
  Version := '';
  Why := '';
  if not PWebWv2FixedFileVersion(FileName, Version, Why) then
  begin
    Why := What + ' version unreadable: ' + Why;
    exit;
  end;
  if not PWebWv2VersionParse(Version, parsed) then
  begin
    Why := What + ' version is not a strict 4-part version: ' + Version;
    exit;
  end;
  if not PWebWv2VersionUsable(parsed) then
  begin
    Why := What + ' build ' + IntToUtf8Local(parsed.Build) +
      ' is below the CAP-4W minimum ' +
      IntToUtf8Local(PWEB_WV2_MIN_BUILD) + ' (' + Version + ')';
    exit;
  end;
  if Version <> PWEB_WV2_FIXED_VERSION then
  begin
    // a MIXED tree - the pinned browser image beside a foreign
    // msedge.dll or EmbeddedBrowserWebView.dll - is refused here
    Why := What + ' is ' + Version + ', not the ratified pin ' +
      PWEB_WV2_FIXED_VERSION;
    exit;
  end;
  FailedOnVersion := False;
  if not PWebWv2FixedPeMachine(FileName, machine, Why) then
    exit;
  if machine <> PWEB_WV2_PE_MACHINE_AMD64 then
  begin
    Why := What + ' PE machine 0x' + HexU32(machine) +
      ' is not AMD64 (0x' + HexU32(PWEB_WV2_PE_MACHINE_AMD64) + '): ' +
      U8(FileName);
    exit;
  end;
  Result := True;
end;

function PWebWv2FixedValidate(
  const RuntimeRoot: TFileName): TPWebWv2FixedResult;
var
  root, tree, browser, embedded, msedge: TFileName;
  why, versionText: RawUtf8;
  drive: Cardinal;
  machine: Word;
  onVersion: Boolean;
begin
  // fail-closed defaults: a zeroed record already reads as a failure
  Result := Default(TPWebWv2FixedResult);
  Result.Status := wv2fxFailed;
  Result.FailedStep := wv2fsResolve;
  if RuntimeRoot = '' then
  begin
    Result.Diagnostic := 'bundled runtime root could not be resolved ' +
      'from the executable path';
    exit;
  end;
  root := IncludeTrailingPathDelimiter(RuntimeRoot);
  tree := root + PWebWv2FixedTreeName;
  browser := IncludeTrailingPathDelimiter(tree) + PWEB_WV2_FIXED_BROWSER;
  msedge := IncludeTrailingPathDelimiter(tree) + PWEB_WV2_FIXED_MSEDGE;
  embedded := IncludeTrailingPathDelimiter(tree) + PWEB_WV2_FIXED_EMBEDDED;
  Result.RuntimeRoot := root;
  Result.TreeDir := tree;
  Result.LoaderPath := root + PWEB_WV2_FIXED_LOADER;

  Result.FailedStep := wv2fsPathShape;
  if not PWebWv2FixedPathShapeOk(tree, why) then
  begin
    Result.Diagnostic := why;
    exit;
  end;

  // matrix priority: an ABSENT bundle is diagnosed as absent (F6),
  // whatever kind of volume its would-be location sits on (F10) - the
  // gates key on these step texts, so the order is contractual
  Result.FailedStep := wv2fsTreeMissing;
  if not DirectoryExists(tree) then
  begin
    Result.Diagnostic := 'bundled runtime tree missing: ' + U8(tree);
    exit;
  end;

  // a junction or symlink AT THE ROOT would redirect the entire
  // bundled runtime somewhere nothing here ever validated; the
  // manifest walk refuses reparse points below the root, and the root
  // itself is held to the same rule (reported as a path-shape refusal,
  // because that is exactly what it is)
  Result.FailedStep := wv2fsPathShape;
  if IsReparsePoint(tree) then
  begin
    Result.Diagnostic := 'bundled runtime tree root is a reparse point ' +
      '(junction or symlink): ' + U8(tree);
    exit;
  end;
  if IsReparsePoint(root) then
  begin
    Result.Diagnostic := 'bundled runtime root is a reparse point ' +
      '(junction or symlink): ' + U8(root);
    exit;
  end;

  Result.FailedStep := wv2fsDrive;
  drive := PWebWv2FixedDriveType(tree);
  if drive <> DRIVE_FIXED then
  begin
    // a network, removable, optical or RAM volume is never a frozen
    // deployment target: refuse rather than run off a moving surface
    Result.Diagnostic := 'bundled runtime is not on a local fixed drive ' +
      '(GetDriveTypeW = ' + IntToUtf8Local(drive) + '): ' + U8(tree);
    exit;
  end;

  Result.FailedStep := wv2fsTreeIncomplete;
  if not FileExists(Result.LoaderPath) then
  begin
    Result.Diagnostic := 'bundled loader missing: ' + U8(Result.LoaderPath);
    exit;
  end;
  if not FileExists(browser) then
  begin
    Result.Diagnostic := 'bundled runtime is partial, ' +
      PWEB_WV2_FIXED_BROWSER + ' missing: ' + U8(browser);
    exit;
  end;
  if not FileExists(msedge) then
  begin
    Result.Diagnostic := 'bundled runtime is partial, ' +
      PWEB_WV2_FIXED_MSEDGE + ' missing: ' + U8(tree);
    exit;
  end;
  if not FileExists(embedded) then
  begin
    Result.Diagnostic := 'bundled runtime is partial, ' +
      PWEB_WV2_FIXED_EMBEDDED + ' missing: ' + U8(tree);
    exit;
  end;

  // EVERY versioned binary of the tree is checked, not just the
  // browser image: a tree mixing the pinned msedgewebview2.exe with a
  // foreign msedge.dll or EmbeddedBrowserWebView.dll is not the
  // ratified runtime, and the loader is excluded on purpose (it is
  // pinned by the WebView2 SDK version, 1.0.1587.40, not by the
  // runtime version)
  Result.FailedStep := wv2fsVersion;
  if not CheckPinnedBinary(browser, 'bundled runtime ' +
       PWEB_WV2_FIXED_BROWSER, versionText, onVersion, why) then
  begin
    if not onVersion then
      Result.FailedStep := wv2fsArchitecture;
    Result.TreeVersion := versionText;
    Result.Diagnostic := why;
    exit;
  end;
  // the browser image IS the tree's identity: record it before the
  // companions, so a mixed-tree refusal still reports what was found
  Result.TreeVersion := versionText;
  Result.FailedStep := wv2fsVersion;
  if not CheckPinnedBinary(msedge, 'bundled runtime ' +
       PWEB_WV2_FIXED_MSEDGE, versionText, onVersion, why) then
  begin
    if not onVersion then
      Result.FailedStep := wv2fsArchitecture;
    Result.Diagnostic := why;
    exit;
  end;
  Result.FailedStep := wv2fsVersion;
  if not CheckPinnedBinary(embedded, 'bundled runtime ' +
       PWEB_WV2_FIXED_EMBEDDED, versionText, onVersion, why) then
  begin
    if not onVersion then
      Result.FailedStep := wv2fsArchitecture;
    Result.Diagnostic := why;
    exit;
  end;
  versionText := Result.TreeVersion;

  Result.FailedStep := wv2fsArchitecture;
  if not PWebWv2FixedPeMachine(Result.LoaderPath, machine, why) then
  begin
    Result.Diagnostic := why;
    exit;
  end;
  if machine <> PWEB_WV2_PE_MACHINE_AMD64 then
  begin
    Result.Diagnostic := 'bundled loader PE machine 0x' + HexU32(machine) +
      ' is not AMD64: ' + U8(Result.LoaderPath);
    exit;
  end;

  Result.FailedStep := wv2fsAcl;
  if not PWebWv2FixedAclVerify(tree, why) then
  begin
    Result.Diagnostic := 'AppContainer ACL refused: ' + why;
    exit;
  end;

  Result.FailedStep := wv2fsNone;
  Result.Status := wv2fxValidated;
  Result.Diagnostic := 'bundled runtime ' + versionText + ' validated at ' +
    U8(tree) + '; ' + why;
end;

{ ---- selection ---- }

var
  SelectionDone: Boolean = False;

function PWebWv2FixedSelected: Boolean;
begin
  Result := SelectionDone;
end;

procedure PWebWv2FixedResetSelection;
begin
  SelectionDone := False;
end;

procedure PWebWv2FixedSelect(var Prepared: TPWebWv2FixedResult);
var
  preloaded, module: THandle;
  nameW, valueW: UnicodeString;
  readBack: array[0..1023] of WideChar;
  chars: DWord;
  seen: RawUtf8;
begin
  if Prepared.Status <> wv2fxValidated then
  begin
    Prepared.Status := wv2fxFailed;
    if Prepared.FailedStep = wv2fsNone then
      Prepared.FailedStep := wv2fsResolve;
    if Prepared.Diagnostic = '' then
      Prepared.Diagnostic := 'selection refused: the tree was not validated';
    exit;
  end;
  Prepared.Status := wv2fxFailed;
  if SelectionDone then
  begin
    // the variable is owned for the whole process life and is never
    // changed while a WebView lives: one selection, once
    Prepared.FailedStep := wv2fsEnvironment;
    Prepared.Diagnostic :=
      'a fixed runtime was already selected by this process';
    exit;
  end;

  // 1) the loader FIRST, by absolute path. Ratified at Checkpoint 1
  // after the env-var-only hypothesis was probed and REFUTED: without
  // this preload the pinned webview's built-in loader ignores the
  // override and silently runs on the installed Evergreen.
  Prepared.FailedStep := wv2fsLoaderPreload;
  preloaded := PWebWv2FixedLoadLibrary(Prepared.LoaderPath);
  if preloaded = 0 then
  begin
    Prepared.Diagnostic := 'cannot preload the bundled loader (error ' +
      HexU32(GetLastError) + '): ' + U8(Prepared.LoaderPath);
    exit;
  end;
  Prepared.FailedStep := wv2fsLoaderIdentity;
  module := PWebWv2FixedModuleHandle(PWEB_WV2_FIXED_LOADER);
  if module <> preloaded then
  begin
    // a different WebView2Loader.dll is already resident: the bundled
    // one would not be the one webview links against - fail closed
    Prepared.Diagnostic := 'a foreign ' + PWEB_WV2_FIXED_LOADER +
      ' is loaded (module 0x' + HexU32(LongWord(module)) +
      ' vs preloaded 0x' + HexU32(LongWord(preloaded)) + ')';
    exit;
  end;

  // 2) the documented override, with a MANDATORY read-back: an
  // inherited hostile value is overwritten, and a variable that does
  // not read back exactly can never be trusted
  Prepared.FailedStep := wv2fsEnvironment;
  nameW := UnicodeString(PWEB_WV2_FIXED_ENV);
  valueW := UnicodeString(Prepared.TreeDir);
  if not PWebSetEnvironmentVariableW(PWideChar(nameW), PWideChar(valueW)) then
  begin
    Prepared.Diagnostic := 'SetEnvironmentVariableW(' +
      PWEB_WV2_FIXED_ENV + ') error ' + HexU32(GetLastError);
    exit;
  end;
  chars := PWebGetEnvironmentVariableW(PWideChar(nameW), @readBack[0],
    Length(readBack));
  if (chars = 0) or
     (chars >= Length(readBack)) then
  begin
    Prepared.Diagnostic := PWEB_WV2_FIXED_ENV +
      ' did not read back (chars=' + IntToUtf8Local(chars) + ', error ' +
      HexU32(GetLastError) + ')';
    exit;
  end;
  seen := RawUnicodeToUtf8(@readBack[0], chars);
  if seen <> U8(Prepared.TreeDir) then
  begin
    Prepared.Diagnostic := PWEB_WV2_FIXED_ENV + ' read back as ' + seen +
      ', expected ' + U8(Prepared.TreeDir);
    exit;
  end;

  SelectionDone := True;
  Prepared.FailedStep := wv2fsNone;
  Prepared.Status := wv2fxSelected;
  Prepared.Diagnostic := 'preloaded ' + U8(Prepared.LoaderPath) +
    ' (module 0x' + HexU32(LongWord(preloaded)) + ') and set ' +
    PWEB_WV2_FIXED_ENV + '=' + seen;
end;

function PWebWv2FixedPrepare: TPWebWv2FixedResult;
begin
  Result := PWebWv2FixedValidate(PWebWv2FixedRuntimeRoot);
  if Result.Status <> wv2fxValidated then
    exit;
  PWebWv2FixedSelect(Result);
end;

function PWebWv2FixedConfirmIdentity(const Prepared: TPWebWv2FixedResult;
  const Observed: RawUtf8): TPWebWv2FixedResult;
var
  normalized, why: RawUtf8;
begin
  Result := Prepared;
  if Result.Status <> wv2fxSelected then
  begin
    // nothing was ever selected: an identity verdict would be a lie
    Result.Status := wv2fxFailed;
    Result.FailedStep := wv2fsIdentity;
    Result.Diagnostic := 'identity cannot be confirmed: no fixed runtime ' +
      'was selected by this process';
    exit;
  end;
  if PWebWv2FixedIdentityMatches(Observed, PWEB_WV2_FIXED_VERSION,
       normalized, why) then
  begin
    Result.FailedStep := wv2fsNone;
    Result.Diagnostic := 'observed runtime ' + normalized +
      ' equals the ratified pin (raw observation: ' + Observed + ')';
    exit;
  end;
  Result.Status := wv2fxFailed;
  Result.FailedStep := wv2fsIdentity;
  Result.Diagnostic := why;
end;

{ ---- stable texts ---- }

function PWebWv2FixedStatusText(Status: TPWebWv2FixedStatus): RawUtf8;
begin
  case Status of
    wv2fxValidated:
      Result := 'Validated';
    wv2fxSelected:
      Result := 'Selected';
  else
    Result := 'Failed';
  end;
end;

function PWebWv2FixedStepText(Step: TPWebWv2FixedStep): RawUtf8;
begin
  case Step of
    wv2fsResolve:
      Result := 'resolve';
    wv2fsPathShape:
      Result := 'path_shape';
    wv2fsDrive:
      Result := 'drive';
    wv2fsTreeMissing:
      Result := 'tree_missing';
    wv2fsTreeIncomplete:
      Result := 'tree_incomplete';
    wv2fsVersion:
      Result := 'version';
    wv2fsArchitecture:
      Result := 'architecture';
    wv2fsAcl:
      Result := 'acl';
    wv2fsLoaderPreload:
      Result := 'loader_preload';
    wv2fsLoaderIdentity:
      Result := 'loader_identity';
    wv2fsEnvironment:
      Result := 'environment';
    wv2fsIdentity:
      Result := 'identity';
  else
    Result := 'none';
  end;
end;

end.
