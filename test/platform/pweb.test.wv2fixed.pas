unit pweb.test.wv2fixed;

{ mormot.core.test cases for CAP-6b3: the Windows fixed-runtime
  profile's resolution, validation and selection unit
  (pweb.platform.webview2.fixed).

  Everything below is headless: no WebView2 runtime, no Microsoft
  binary, no window, no network and no installer are ever involved.
  The pure policies run in memory; the tree matrix runs over a
  FABRICATED on-disk fixture (hand-built minimal PE images plus empty
  stand-ins) with the impure drive-type and file-version primitives
  swapped for fakes; the ACL legs run against REAL Windows security
  APIs on a REAL temp directory whose DACL the test first isolates
  (protected, inheritance removed) so both directions are
  deterministic on any machine.

  Mapped to the ratified CAP-6b3 I/O matrix:

    F4  hostile inherited WEBVIEW2_BROWSER_EXECUTABLE_FOLDER
        -> overwritten, and the read-back proves it
    F6  tree missing                     -> tree_missing, fail closed
    F7  tree partial (browser, msedge.dll, EBWebView\x64\..., loader)
        -> tree_incomplete, fail closed
    F8  version != pin / below the CAP-4W minimum / malformed
        -> version, fail closed (strict 4-part parse)
    F9  PE machine != AMD64              -> architecture, fail closed
    F10 UNC / device / non-fixed drive   -> path_shape or drive
    F11 forbidden shape (\Edge\Application\, relative, mixed slashes)
        -> path_shape
    F13 AppContainer SIDs absent from the DACL, an Everyone ace, or a
        write-granting mask                            -> acl
    F14 the applied (OI)(CI) RX grant verifies BY SID  -> Validated

  Plus the selection seam (the CAP-6b3 Checkpoint 1 ratification): the
  loader is preloaded by ABSOLUTE path FIRST, the loaded-module
  identity must be that very handle, and only then is the documented
  override set - with a mandatory read-back. A failure at any of the
  three points is fatal, and a second selection in one process is
  refused (the variable is owned for the process life).

  The tree manifest is proven as a deterministic artifact: the exact
  documented format, ordinal path ordering, and detection of a
  tampered byte, an added file, a removed file and a drifted header.

  Every seam is restored in a finally block and the environment
  variable is cleared again, mirroring the ratified CAP-6b0 seam
  discipline. }

{$I mormot.defines.inc}

interface

uses
  windows,
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.os,
  mormot.core.test,
  pweb.lib.webview,
  pweb.platform.webview2,
  pweb.platform.webview2.runtime,
  pweb.platform.webview2.provision,
  pweb.platform.webview2.fixed;

type
  /// CAP-6b3 fixed-runtime cases - headless, no WebView2 runtime and
  // no Microsoft binary required
  TTestWv2Fixed = class(TSynTestCase)
  published
    /// pure path-shape policy: UNC, device, relative, mixed slashes,
    // '..' and Microsoft's forbidden \Edge\Application\ location
    procedure PathShapePolicy;
    /// exe-directory-only resolution and the observation markers
    procedure ResolutionAndObservation;
    /// pure observed-identity policy over get_BrowserVersionString
    procedure ObservedIdentityPolicy;
    /// the full validation matrix over a fabricated on-disk tree
    procedure TreeValidationMatrix;
    /// real Windows ACL apply + verify BY SID, both directions
    procedure AppContainerAcl;
    /// deterministic tree manifest: format, ordering, tamper detection
    procedure TreeManifest;
    /// loader preload -> module identity -> env var, in that order
    procedure SelectionSeam;
  end;

implementation

{ ---- fixture helpers ---- }

const
  PIN = PWEB_WV2_FIXED_VERSION;
  // SDDL baselines: protected DACL, inheritance removed. OW (OWNER
  // RIGHTS, S-1-3-4) gives the test process - which owns everything it
  // just created - enough to apply the grant and clean up, WITHOUT
  // handing any BROAD trustee a write right. That matters: a baseline
  // granting Authenticated Users or Users full control would make the
  // ratified verification pass for the wrong reason, and the
  // broad-write refusal below could never be observed.
  SDDL_ISOLATED = 'D:P(A;OICI;FA;;;OW)';
  // a benign READ-only Everyone ace, as managed images commonly leave
  // behind: must NOT refuse the tree
  SDDL_EVERYONE_READ = 'D:P(A;OICI;FA;;;OW)(A;OICI;FR;;;WD)';
  // broad trustees holding WRITE: each must refuse the tree
  SDDL_EVERYONE_WRITE = 'D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;WD)';
  SDDL_AUTH_USERS_WRITE = 'D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;AU)';
  SDDL_REVISION_1 = 1;
  PROTECTED_DACL_SECURITY_INFORMATION = DWord($80000000);
  SE_FILE_OBJECT_TEST = 1;
  DACL_SECURITY_INFORMATION_TEST = 4;
  IMAGE_FILE_MACHINE_ARM64 = $AA64;
  FSCTL_SET_REPARSE_POINT = $000900A4;
  IO_REPARSE_TAG_MOUNT_POINT = DWord($A0000003);
  // winbase.h; not declared by the FPC RTL's windows unit
  PWEB_FILE_FLAG_OPEN_REPARSE_POINT = $00200000;

function TestConvertStringSecurityDescriptorToSecurityDescriptorW(
  StringSecurityDescriptor: PWideChar; StringSDRevision: DWord;
  var SecurityDescriptor: Pointer;
  SecurityDescriptorSize: PDWord): BOOL; stdcall;
  external 'advapi32.dll'
  name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

function TestGetSecurityDescriptorDacl(pSecurityDescriptor: Pointer;
  var lpbDaclPresent: BOOL; var pDacl: Pointer;
  var lpbDaclDefaulted: BOOL): BOOL; stdcall;
  external 'advapi32.dll' name 'GetSecurityDescriptorDacl';

function TestSetNamedSecurityInfoW(pObjectName: PWideChar;
  ObjectType, SecurityInfo: DWord;
  psidOwner, psidGroup, pDacl, pSacl: Pointer): DWord; stdcall;
  external 'advapi32.dll' name 'SetNamedSecurityInfoW';

function TestLocalFree(hMem: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'LocalFree';

// replaces one directory's DACL with a PROTECTED one built from SDDL,
// so neither an inherited AppContainer grant nor an inherited Everyone
// ace can decide the outcome of an ACL leg on a stranger's machine
function IsolateDacl(const Dir: TFileName; const Sddl: RawUtf8): Boolean;
var
  sd, dacl: Pointer;
  present, defaulted: BOOL;
  wide: UnicodeString;
begin
  Result := False;
  sd := nil;
  if not TestConvertStringSecurityDescriptorToSecurityDescriptorW(
       PWideChar(Utf8ToSynUnicode(Sddl)), SDDL_REVISION_1, sd, nil) then
    exit;
  try
    present := False;
    defaulted := False;
    dacl := nil;
    if not TestGetSecurityDescriptorDacl(sd, present, dacl, defaulted) or
       not present then
      exit;
    wide := UnicodeString(ExcludeTrailingPathDelimiter(Dir));
    UniqueString(wide);
    Result := TestSetNamedSecurityInfoW(PWideChar(wide),
      SE_FILE_OBJECT_TEST,
      DACL_SECURITY_INFORMATION_TEST or PROTECTED_DACL_SECURITY_INFORMATION,
      nil, nil, dacl, nil) = ERROR_SUCCESS;
  finally
    TestLocalFree(sd);
  end;
end;

// ordinal (byte-wise) less-than, never a locale collation
function OrdLess(const A, B: RawUtf8): Boolean;
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

// LF split without pulling a CSV parser into a byte-shape assertion
procedure SplitLf(const Text: RawUtf8; out Lines: TRawUtf8DynArray);
var
  i, start, count: PtrInt;
begin
  Lines := nil;
  SetLength(Lines, 64);
  count := 0;
  start := 1;
  for i := 1 to Length(Text) do
    if Text[i] = #10 then
    begin
      if count = Length(Lines) then
        SetLength(Lines, count + 64);
      Lines[count] := Copy(Text, start, i - start);
      Inc(count);
      start := i + 1;
    end;
  if start <= Length(Text) then
  begin
    if count = Length(Lines) then
      SetLength(Lines, count + 1);
    Lines[count] := Copy(Text, start, MaxInt);
    Inc(count);
  end;
  SetLength(Lines, count);
end;

procedure SetEnvW(const Name, Value: RawUtf8);
begin
  if Value = '' then
    SetEnvironmentVariableW(PWideChar(Utf8ToSynUnicode(Name)), nil)
  else
    SetEnvironmentVariableW(PWideChar(Utf8ToSynUnicode(Name)),
      PWideChar(Utf8ToSynUnicode(Value)));
end;

// a minimal but genuinely parseable PE image: MZ, e_lfanew, PE\0\0
// and the COFF machine word - exactly what PWebWv2FixedPeMachine reads
function PeBytes(Machine: Word): RawByteString;
begin
  SetLength(Result, $86);
  FillChar(pointer(Result)^, $86, 0);
  PWord(@Result[1])^ := $5A4D;                // 'MZ'
  PLongWord(@Result[1 + $3C])^ := $80;        // e_lfanew
  PLongWord(@Result[1 + $80])^ := $00004550;  // 'PE\0\0'
  PWord(@Result[1 + $84])^ := Machine;
end;

procedure WritePe(const FileName: TFileName; Machine: Word);
begin
  FileFromString(PeBytes(Machine), FileName);
end;

function TestGetFileAttributesW(lpFileName: PWideChar): DWord; stdcall;
  external 'kernel32.dll' name 'GetFileAttributesW';

function IsReparse(const Path: TFileName): Boolean;
var
  attr: DWord;
begin
  attr := TestGetFileAttributesW(
    PWideChar(Utf8ToSynUnicode(StringToUtf8(Path))));
  Result := (attr <> INVALID_FILE_ATTRIBUTES) and
            ((attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0);
end;

procedure DeleteTree(const Dir: TFileName);
var
  sr: TSearchRec;
  root: TFileName;
begin
  if not DirectoryExists(Dir) then
    exit;
  if IsReparse(Dir) then
  begin
    // NEVER descend into a junction: that would delete the TARGET's
    // contents. Removing the link itself is what is wanted.
    RemoveDir(Dir);
    exit;
  end;
  root := IncludeTrailingPathDelimiter(Dir);
  if FindFirst(root + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or
         (sr.Name = '..') then
        continue;
      if (sr.Attr and faDirectory) <> 0 then
        DeleteTree(root + sr.Name)
      else
        DeleteFile(root + sr.Name);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  RemoveDir(Dir);
end;

type
  TMountPointReparseBuffer = record
    ReparseTag: DWord;
    ReparseDataLength: Word;
    Reserved: Word;
    SubstituteNameOffset: Word;
    SubstituteNameLength: Word;
    PrintNameOffset: Word;
    PrintNameLength: Word;
    PathBuffer: array[0..1023] of WideChar;
  end;

// a real NTFS junction, created through the documented reparse-point
// control code (no privilege required, unlike a symlink) - the fixture
// for both reparse refusals: the tree ROOT and the manifest walk
function CreateJunction(const LinkDir, TargetDir: TFileName): Boolean;
var
  h: THandle;
  buf: TMountPointReparseBuffer;
  subst: UnicodeString;
  nameBytes: Word;
  returned, total: DWord;
begin
  Result := False;
  if not ForceDirectories(LinkDir) then
    exit;
  h := CreateFileW(PWideChar(Utf8ToSynUnicode(StringToUtf8(LinkDir))),
    GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or PWEB_FILE_FLAG_OPEN_REPARSE_POINT, 0);
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    subst := '\??\' + Utf8ToSynUnicode(StringToUtf8(
      ExcludeTrailingPathDelimiter(TargetDir)));
    FillChar(buf, SizeOf(buf), 0);
    buf.ReparseTag := IO_REPARSE_TAG_MOUNT_POINT;
    nameBytes := Length(subst) * 2;
    buf.SubstituteNameOffset := 0;
    buf.SubstituteNameLength := nameBytes;
    buf.PrintNameOffset := nameBytes + 2; // past the substitute NUL
    buf.PrintNameLength := 0;
    Move(PWideChar(subst)^, buf.PathBuffer[0], nameBytes);
    // 8 bytes of name offsets/lengths + both NUL-terminated names
    buf.ReparseDataLength := 8 + nameBytes + 4;
    total := 8 + buf.ReparseDataLength; // + tag/length/reserved header
    returned := 0;
    Result := DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, @buf, total,
      nil, 0, returned, nil);
  finally
    CloseHandle(h);
  end;
end;

function NewTempDir(const Tag: RawUtf8): TFileName;
begin
  Result := TemporaryFileName + '-' + Utf8ToString(Tag) + '.dir';
  DeleteTree(Result);
  ForceDirectories(Result);
end;

// builds a COMPLETE, valid-shaped bundled runtime root:
//   <root>\WebView2Loader.dll
//   <root>\<tree>\msedgewebview2.exe
//   <root>\<tree>\msedge.dll
//   <root>\<tree>\EBWebView\x64\EmbeddedBrowserWebView.dll
function BuildFixture(const Root: TFileName): TFileName;
var
  tree: TFileName;
begin
  tree := IncludeTrailingPathDelimiter(
    IncludeTrailingPathDelimiter(Root) + PWebWv2FixedTreeName);
  ForceDirectories(tree + 'EBWebView\x64');
  WritePe(IncludeTrailingPathDelimiter(Root) + 'WebView2Loader.dll', $8664);
  WritePe(tree + 'msedgewebview2.exe', $8664);
  WritePe(tree + 'msedge.dll', $8664);
  WritePe(tree + 'EBWebView\x64\EmbeddedBrowserWebView.dll', $8664);
  Result := ExcludeTrailingPathDelimiter(tree);
end;

{ ---- injected seams ---- }

var
  FakeDriveType: Cardinal;
  FakeVersionText: RawUtf8;
  FakeVersionOk: Boolean;
  // a per-file override, so a MIXED tree (pinned browser image beside a
  // foreign companion binary) can be fabricated
  FakeVersionOnlyFor: RawUtf8;
  FakeVersionOverride: RawUtf8;
  FakeLoadHandle: THandle;
  FakeModuleHandle: THandle;
  FakeLoadPath: TFileName;
  FakeLoadCalls: PtrInt;
  FakeModuleCalls: PtrInt;

function DriveTypeFake(const Path: TFileName): Cardinal;
begin
  Result := FakeDriveType;
end;

function FileVersionFake(const FileName: TFileName;
  out VersionText, ErrorText: RawUtf8): Boolean;
begin
  VersionText := '';
  ErrorText := '';
  Result := FakeVersionOk;
  if not Result then
  begin
    ErrorText := 'injected version-resource failure';
    exit;
  end;
  if (FakeVersionOnlyFor <> '') and
     (Pos(FakeVersionOnlyFor, StringToUtf8(FileName)) > 0) then
    VersionText := FakeVersionOverride
  else
    VersionText := FakeVersionText;
end;

function LoadLibraryFake(const FileName: TFileName): THandle;
begin
  FakeLoadPath := FileName;
  Inc(FakeLoadCalls);
  Result := FakeLoadHandle;
end;

function ModuleHandleFake(const ModuleName: RawUtf8): THandle;
begin
  Inc(FakeModuleCalls);
  Result := FakeModuleHandle;
end;

{ ---- pure path-shape policy ---- }

procedure TTestWv2Fixed.PathShapePolicy;
var
  why: RawUtf8;

  procedure Accept(const Path: TFileName; const What: RawUtf8);
  begin
    CheckUtf8(PWebWv2FixedPathShapeOk(Path, why),
      'must accept % (%)', [What, why]);
  end;

  procedure Refuse(const Path: TFileName; const What: RawUtf8);
  begin
    CheckUtf8(not PWebWv2FixedPathShapeOk(Path, why),
      'must refuse %', [What]);
    CheckUtf8(why <> '', 'refusal of % carries no reason', [What]);
  end;

begin
  Accept('C:\Apps\PWeb\runtime\webview2\' + PWebWv2FixedTreeName,
    'a plain per-user deployment path');
  Accept('D:\PWebRelease\runtime\webview2', 'another fixed volume');
  // F10: UNC and device forms never reach the disk at all
  Refuse('', 'the empty path');
  Refuse('\\fileserver\share\pweb\runtime', 'a UNC path');
  Refuse('//fileserver/share/pweb/runtime', 'a forward-slash UNC path');
  Refuse('\\?\C:\pweb\runtime', 'the \\?\ device form');
  Refuse('\\.\C:\pweb\runtime', 'the \\.\ device form');
  // F11: everything that is not an unambiguous absolute local path
  Refuse('runtime\webview2', 'a relative path');
  Refuse('C:runtime\webview2', 'a drive-relative path');
  Refuse('C:/Apps/PWeb/runtime', 'a forward-slash absolute path');
  Refuse('C:\Apps\..\Windows\runtime', 'a path with a .. component');
  Refuse('C:\Apps\runtime\..', 'a path ending in ..');
  // F11: the Microsoft-documented forbidden location, case-folded
  // with ASCII rules only (no locale can change this verdict)
  Refuse('C:\Program Files (x86)\Microsoft\Edge\Application\rt',
    'a path inside an Edge installation');
  Refuse('C:\x\edge\application\rt', 'the same path in lower case');
end;

{ ---- exe-directory-only resolution, and the observation markers ---- }

procedure TTestWv2Fixed.ResolutionAndObservation;
var
  root, savedCwd: TFileName;
  expected, norm, why: RawUtf8;
begin
  root := PWebWv2FixedRuntimeRoot;
  Check(root <> '', 'the bundled runtime root must resolve');
  // the ONE ratified rule: the executable's own directory + the fixed
  // subdirectory, with a trailing delimiter
  expected := StringToUtf8(IncludeTrailingPathDelimiter(
    IncludeTrailingPathDelimiter(Executable.ProgramFilePath) +
    PWEB_WV2_FIXED_SUBDIR));
  CheckEqual(StringToUtf8(root), expected, 'runtime root shape');
  // the CWD can never move it: a shortcut, a service or a hostile
  // parent choosing the working directory must not choose the runtime
  savedCwd := GetCurrentDir;
  try
    Check(SetCurrentDir(GetSystemPath(spTempFolder)),
      'the test needs to change the CWD to prove independence');
    CheckEqual(StringToUtf8(PWebWv2FixedRuntimeRoot), expected,
      'the CWD must never move the bundled runtime root');
  finally
    SetCurrentDir(savedCwd);
  end;
  // and neither may the documented override variable: it is an OUTPUT
  // of the selection, never an input to the resolution
  SetEnvW(PWEB_WV2_FIXED_ENV, 'C:\attacker\runtime');
  try
    CheckEqual(StringToUtf8(PWebWv2FixedRuntimeRoot), expected,
      'the override variable must never move the bundled runtime root');
  finally
    SetEnvW(PWEB_WV2_FIXED_ENV, '');
  end;

  // the observation helper never raises and never returns something a
  // version comparison could accept
  CheckEqual(PWebWv2ObservedBrowserVersion(nil), '<no-webview>',
    'a nil webview must observe the typed marker');
  Check(not PWebWv2FixedIdentityMatches(
    PWebWv2ObservedBrowserVersion(nil), PIN, norm, why),
    'an observation marker can never satisfy the identity check');
  Check(why <> '', 'the marker refusal carries a reason');
end;

{ ---- pure observed-identity policy ---- }

procedure TTestWv2Fixed.ObservedIdentityPolicy;
var
  normalized, why: RawUtf8;
  selected, verdict: TPWebWv2FixedResult;
begin
  Check(PWebWv2FixedIdentityMatches(PIN, PIN, normalized, why),
    'the pinned version must be accepted');
  CheckEqual(normalized, PIN, 'normalized pin');
  // documented: get_BrowserVersionString may append a channel name
  Check(PWebWv2FixedIdentityMatches(PIN + ' stable', PIN, normalized, why),
    'a channel suffix must not defeat the identity check');
  CheckEqual(normalized, PIN, 'normalized channel-suffixed version');
  // F3/F5: a DIFFERENT runtime (Evergreen, or a registry
  // BrowserExecutableFolder redirection) is refused, both named
  Check(not PWebWv2FixedIdentityMatches('150.0.4078.105', PIN,
    normalized, why), 'a non-pinned runtime must be refused');
  CheckUtf8(Pos('150.0.4078.105', why) > 0,
    'refusal must name the observed version: %', [why]);
  CheckUtf8(Pos(PIN, why) > 0, 'refusal must name the pin: %', [why]);
  // the observation helper's failure markers can never be a version
  Check(not PWebWv2FixedIdentityMatches('', PIN, normalized, why),
    'an empty observation must be refused');
  Check(not PWebWv2FixedIdentityMatches('<no-controller>', PIN,
    normalized, why), 'an observation marker must be refused');
  Check(not PWebWv2FixedIdentityMatches('<observation failed>', PIN,
    normalized, why), 'a failed observation must be refused');
  Check(not PWebWv2FixedIdentityMatches('151.0.4129', PIN,
    normalized, why), 'a 3-part version must be refused');
  Check(not PWebWv2FixedIdentityMatches('151.0.4129.78.1', PIN,
    normalized, why), 'a 5-part version must be refused');
  // one threshold only: the CAP-4W loader minimum, build component
  Check(not PWebWv2FixedIdentityMatches('1.0.1586.99', '1.0.1586.99',
    normalized, why), 'a build below the CAP-4W minimum must be refused');
  CheckUtf8(Pos('1587', why) > 0,
    'the minimum refusal must name the threshold: %', [why]);

  // the post-create half reports through the SAME typed verdict shape
  // as every pre-create refusal, so the marker grammar never forks
  selected := Default(TPWebWv2FixedResult);
  selected.Status := wv2fxSelected;
  selected.FailedStep := wv2fsNone;
  verdict := PWebWv2FixedConfirmIdentity(selected, PIN);
  Check(verdict.Status = wv2fxSelected, 'a matching identity stays selected');
  Check(verdict.FailedStep = wv2fsNone, 'a matching identity has no step');
  verdict := PWebWv2FixedConfirmIdentity(selected, '150.0.4078.105');
  Check(verdict.Status = wv2fxFailed, 'a foreign identity fails');
  Check(verdict.FailedStep = wv2fsIdentity,
    'a foreign identity must fail AT the identity step');
  CheckEqual(PWebWv2FixedStepText(verdict.FailedStep), 'identity',
    'the identity step must have its stable text');
  CheckUtf8(Pos('150.0.4078.105', verdict.Diagnostic) > 0,
    'the identity verdict names the observation: %', [verdict.Diagnostic]);
  // and it can never pronounce on something that was never selected
  verdict := PWebWv2FixedConfirmIdentity(
    Default(TPWebWv2FixedResult), PIN);
  Check(verdict.Status = wv2fxFailed, 'an unselected runtime has no identity');
  Check(verdict.FailedStep = wv2fsIdentity, 'unselected identity step');
end;

{ ---- the validation matrix over a fabricated tree ---- }

procedure TTestWv2Fixed.TreeValidationMatrix;
var
  root, tree, realRoot, realTree: TFileName;
  r: TPWebWv2FixedResult;
  diag, manifest: RawUtf8;

  function Validate: TPWebWv2FixedResult;
  begin
    Result := PWebWv2FixedValidate(root);
  end;

begin
  realRoot := '';
  root := NewTempDir('validate');
  PWebWv2FixedDriveType := @DriveTypeFake;
  PWebWv2FixedFileVersion := @FileVersionFake;
  try
    FakeDriveType := 3; // DRIVE_FIXED
    FakeVersionOk := True;
    FakeVersionText := PIN;
    FakeVersionOnlyFor := '';
    FakeVersionOverride := '';

    // ---- F6: the tree is absent (the root exists, nothing else)
    r := Validate;
    Check(r.Status = wv2fxFailed, 'F6 status');
    Check(r.FailedStep = wv2fsTreeMissing, 'F6 step');
    CheckUtf8(r.Diagnostic <> '', 'F6 diagnostic');
    // matrix priority: an ABSENT bundle is diagnosed as ABSENT even on
    // a volume that would also have been refused - the gates key on
    // these step texts, so F6 must outrank F10
    FakeDriveType := 4; // DRIVE_REMOTE
    r := Validate;
    Check(r.FailedStep = wv2fsTreeMissing,
      'an absent tree must report tree_missing, never drive');
    FakeDriveType := 3;

    tree := BuildFixture(root);
    Check(IsolateDacl(tree, SDDL_ISOLATED), 'fixture DACL isolation');

    // ---- F13: a complete, correct tree WITHOUT the AppContainer
    // grant is refused - the ACL is a validation input, not a nicety
    r := Validate;
    Check(r.Status = wv2fxFailed, 'F13 status');
    Check(r.FailedStep = wv2fsAcl, 'F13 step');

    // ---- F14: the ratified grant makes the SAME tree acceptable
    Check(PWebWv2FixedAclApply(tree, r.Diagnostic),
      'ACL apply on the fixture tree');
    r := Validate;
    CheckUtf8(r.Status = wv2fxValidated, 'F14 status (%)', [r.Diagnostic]);
    Check(r.FailedStep = wv2fsNone, 'F14 step');
    CheckEqual(r.TreeVersion, PIN, 'F14 version');
    CheckEqual(RawUtf8(r.TreeDir), RawUtf8(tree), 'F14 tree dir');
    Check(r.Status <> wv2fxSelected,
      'validation must never select anything by itself');

    // ---- F10: a non-fixed volume is refused even when everything
    // else is perfect (a network or removable deployment surface)
    FakeDriveType := 4; // DRIVE_REMOTE
    r := Validate;
    Check(r.Status = wv2fxFailed, 'F10 status');
    Check(r.FailedStep = wv2fsDrive, 'F10 step');
    FakeDriveType := 2; // DRIVE_REMOVABLE
    r := Validate;
    Check(r.FailedStep = wv2fsDrive, 'F10 removable step');
    FakeDriveType := 3;

    // ---- F8: version drift in every direction
    FakeVersionText := '150.0.4078.105';
    r := Validate;
    Check(r.FailedStep = wv2fsVersion, 'F8 wrong-version step');
    CheckUtf8(Pos(PIN, r.Diagnostic) > 0,
      'F8 must name the pin: %', [r.Diagnostic]);
    FakeVersionText := '1.0.1586.99'; // below the CAP-4W minimum
    r := Validate;
    Check(r.FailedStep = wv2fsVersion, 'F8 below-minimum step');
    CheckUtf8(Pos('1587', r.Diagnostic) > 0,
      'F8 must name the minimum: %', [r.Diagnostic]);
    FakeVersionText := '151.0.4129'; // not a strict 4-part version
    r := Validate;
    Check(r.FailedStep = wv2fsVersion, 'F8 malformed step');
    FakeVersionOk := False;
    r := Validate;
    Check(r.FailedStep = wv2fsVersion, 'F8 unreadable step');
    FakeVersionOk := True;
    FakeVersionText := PIN;

    // ---- F8b: a MIXED tree - the pinned browser image beside a
    // foreign companion binary - is refused on the companion, so a
    // partial swap can never ride in behind a correct exe
    FakeVersionOnlyFor := 'EmbeddedBrowserWebView.dll';
    FakeVersionOverride := '150.0.4078.105';
    r := Validate;
    Check(r.FailedStep = wv2fsVersion, 'F8b EmbeddedBrowserWebView step');
    CheckUtf8(Pos('EmbeddedBrowserWebView.dll', r.Diagnostic) > 0,
      'F8b must name the offending companion: %', [r.Diagnostic]);
    CheckEqual(r.TreeVersion, PIN,
      'F8b must still report what the browser image said');
    FakeVersionOnlyFor := 'msedge.dll';
    r := Validate;
    Check(r.FailedStep = wv2fsVersion, 'F8b msedge.dll step');
    CheckUtf8(Pos('msedge.dll', r.Diagnostic) > 0,
      'F8b must name msedge.dll: %', [r.Diagnostic]);
    FakeVersionOnlyFor := '';
    FakeVersionOverride := '';

    // ---- F9: a non-AMD64 image is refused (no ARM64, no x86)
    WritePe(IncludeTrailingPathDelimiter(tree) + 'msedgewebview2.exe',
      IMAGE_FILE_MACHINE_ARM64);
    r := Validate;
    Check(r.FailedStep = wv2fsArchitecture, 'F9 browser step');
    CheckUtf8(Pos('AA64', UpperCase(Utf8ToString(r.Diagnostic))) > 0,
      'F9 must name the offending machine: %', [r.Diagnostic]);
    WritePe(IncludeTrailingPathDelimiter(tree) + 'msedgewebview2.exe', $8664);
    WritePe(IncludeTrailingPathDelimiter(root) + 'WebView2Loader.dll', $014C);
    r := Validate;
    Check(r.FailedStep = wv2fsArchitecture, 'F9 loader step');
    WritePe(IncludeTrailingPathDelimiter(root) + 'WebView2Loader.dll', $8664);
    r := Validate;
    Check(r.Status = wv2fxValidated, 'the tree must be valid again');

    // ---- F7: every required member, removed one at a time
    DeleteFile(IncludeTrailingPathDelimiter(tree) + 'msedge.dll');
    r := Validate;
    Check(r.FailedStep = wv2fsTreeIncomplete, 'F7 msedge.dll step');
    WritePe(IncludeTrailingPathDelimiter(tree) + 'msedge.dll', $8664);
    DeleteFile(IncludeTrailingPathDelimiter(tree) +
      'EBWebView\x64\EmbeddedBrowserWebView.dll');
    r := Validate;
    Check(r.FailedStep = wv2fsTreeIncomplete, 'F7 EBWebView step');
    WritePe(IncludeTrailingPathDelimiter(tree) +
      'EBWebView\x64\EmbeddedBrowserWebView.dll', $8664);
    DeleteFile(IncludeTrailingPathDelimiter(root) + 'WebView2Loader.dll');
    r := Validate;
    Check(r.FailedStep = wv2fsTreeIncomplete, 'F7 loader step');
    WritePe(IncludeTrailingPathDelimiter(root) + 'WebView2Loader.dll', $8664);
    DeleteFile(IncludeTrailingPathDelimiter(tree) + 'msedgewebview2.exe');
    r := Validate;
    Check(r.FailedStep = wv2fsTreeIncomplete, 'F7 browser step');

    // ---- an unresolvable root fails closed at the first step
    r := PWebWv2FixedValidate('');
    Check(r.Status = wv2fxFailed, 'empty root status');
    Check(r.FailedStep = wv2fsResolve, 'empty root step');
  finally
    PWebWv2FixedDriveType := @PWebWv2FixedDriveTypeOs;
    PWebWv2FixedFileVersion := @PWebWv2FixedFileVersionOs;
    DeleteTree(root);
  end;

  // ---- a REPARSE POINT at the tree root redirects the whole bundled
  // runtime somewhere nothing here ever validated: refused as a
  // path-shape defect, exactly like the manifest walk refuses one below
  root := NewTempDir('reparse');
  PWebWv2FixedDriveType := @DriveTypeFake;
  PWebWv2FixedFileVersion := @FileVersionFake;
  try
    FakeDriveType := 3;
    FakeVersionOk := True;
    FakeVersionText := PIN;
    FakeVersionOnlyFor := '';
    // a genuine, complete tree lives at 'real'; the runtime root's tree
    // entry is a junction pointing at it
    realRoot := NewTempDir('reparse-target');
    realTree := BuildFixture(realRoot);
    Check(IsolateDacl(realTree, SDDL_ISOLATED), 'target DACL isolation');
    Check(PWebWv2FixedAclApply(realTree, diag), 'target ACL apply');
    WritePe(IncludeTrailingPathDelimiter(root) + 'WebView2Loader.dll', $8664);
    tree := IncludeTrailingPathDelimiter(root) + PWebWv2FixedTreeName;
    Check(CreateJunction(tree, realTree),
      'the fixture needs a real NTFS junction (error ' +
      IntToStr(GetLastError) + ')');
    r := PWebWv2FixedValidate(root);
    Check(r.Status = wv2fxFailed, 'reparse root status');
    Check(r.FailedStep = wv2fsPathShape, 'reparse root step');
    CheckUtf8(Pos('reparse point', r.Diagnostic) > 0,
      'the reparse refusal must say so: %', [r.Diagnostic]);
    // the manifest walk refuses one below the root for the same reason
    DeleteTree(tree);
    tree := ExcludeTrailingPathDelimiter(BuildFixture(root));
    Check(CreateJunction(IncludeTrailingPathDelimiter(tree) + 'sneaky',
      realTree), 'nested junction fixture');
    Check(not PWebWv2FixedManifestBuild(tree, manifest, diag),
      'the manifest walk must refuse a reparse point');
    CheckUtf8(Pos('reparse point', diag) > 0,
      'the walk refusal must say so: %', [diag]);
    DeleteTree(IncludeTrailingPathDelimiter(tree) + 'sneaky');
  finally
    PWebWv2FixedDriveType := @PWebWv2FixedDriveTypeOs;
    PWebWv2FixedFileVersion := @PWebWv2FixedFileVersionOs;
    DeleteTree(root);
    DeleteTree(realRoot);
  end;

  root := NewTempDir('texts');
  try

    // ---- the step/status texts the gates parse
    CheckEqual(PWebWv2FixedStatusText(wv2fxFailed), 'Failed', 'text Failed');
    CheckEqual(PWebWv2FixedStatusText(wv2fxValidated), 'Validated',
      'text Validated');
    CheckEqual(PWebWv2FixedStatusText(wv2fxSelected), 'Selected',
      'text Selected');
    CheckEqual(PWebWv2FixedStepText(wv2fsNone), 'none', 'text none');
    CheckEqual(PWebWv2FixedStepText(wv2fsTreeMissing), 'tree_missing',
      'text tree_missing');
    CheckEqual(PWebWv2FixedStepText(wv2fsAcl), 'acl', 'text acl');
    CheckEqual(PWebWv2FixedStepText(wv2fsIdentity), 'identity',
      'text identity');
    // a zeroed record must read as a failure (fail closed by ordinal)
    r := Default(TPWebWv2FixedResult);
    Check(r.Status = wv2fxFailed, 'a zeroed result must be a failure');
  finally
    PWebWv2FixedDriveType := @PWebWv2FixedDriveTypeOs;
    PWebWv2FixedFileVersion := @PWebWv2FixedFileVersionOs;
    DeleteTree(root);
  end;
end;

{ ---- real Windows ACL, both directions, always BY SID ---- }

procedure TTestWv2Fixed.AppContainerAcl;
var
  root, tree: TFileName;
  diag: RawUtf8;

  procedure BroadWriteLeg(const Sddl, Sid, What: RawUtf8);
  var
    legRoot, legTree: TFileName;
    legDiag: RawUtf8;
    verified: Boolean;
  begin
    legRoot := NewTempDir('acl-broad');
    try
      legTree := BuildFixture(legRoot);
      CheckUtf8(IsolateDacl(legTree, Sddl), 'DACL isolation for %', [What]);
      CheckUtf8(PWebWv2FixedAclApply(legTree, legDiag),
        'ACL apply beside %', [What]);
      verified := PWebWv2FixedAclVerify(legTree, legDiag);
      CheckUtf8(not verified,
        'a write-holding % must refuse the tree even with both SIDs granted',
        [What]);
      CheckUtf8(Pos(Sid, legDiag) > 0,
        'the refusal must name the % SID (%): %', [What, Sid, legDiag]);
    finally
      DeleteTree(legRoot);
    end;
  end;

begin
  root := NewTempDir('acl');
  try
    tree := BuildFixture(root);
    Check(IsolateDacl(tree, SDDL_ISOLATED), 'DACL isolation');
    // F13: neither SID present -> refused, and the refusal names the
    // SID it looked for (never a localized display name)
    Check(not PWebWv2FixedAclVerify(tree, diag),
      'an un-granted tree must be refused');
    CheckUtf8(Pos(PWEB_WV2_SID_APP_PACKAGES, diag) > 0,
      'the refusal must name the missing SID: %', [diag]);
    // F14: the ratified grant, verified BY SID
    Check(PWebWv2FixedAclApply(tree, diag), 'ACL apply');
    CheckUtf8(Pos(PWEB_WV2_SID_APP_PACKAGES, diag) > 0,
      'the apply diagnostic must name the SIDs: %', [diag]);
    Check(PWebWv2FixedAclVerify(tree, diag), 'ACL verify after apply');
    CheckUtf8(Pos(PWEB_WV2_SID_RESTRICTED_APP_PACKAGES, diag) > 0,
      'the verify diagnostic must name both SIDs: %', [diag]);
    // idempotence: SET_ACCESS replaces, so a second apply is a no-op
    Check(PWebWv2FixedAclApply(tree, diag), 'second ACL apply');
    Check(PWebWv2FixedAclVerify(tree, diag), 'verify after second apply');
    // a missing directory can never verify
    Check(not PWebWv2FixedAclVerify(tree + '\nope', diag),
      'a missing directory must be refused');
    Check(not PWebWv2FixedAclApply(tree + '\nope', diag),
      'applying to a missing directory must be refused');
  finally
    DeleteTree(root);
  end;

  // a BROAD trustee holding WRITE defeats the whole point of the grant:
  // whoever else the DACL names, the tree would still be tamperable.
  // Each broad trustee is proven separately, and each refusal must name
  // the SID it tripped on (never a localized display name).
  BroadWriteLeg(SDDL_EVERYONE_WRITE, PWEB_WV2_SID_EVERYONE, 'Everyone');
  BroadWriteLeg(SDDL_AUTH_USERS_WRITE, PWEB_WV2_SID_AUTHENTICATED_USERS,
    'Authenticated Users');

  // ...but a benign READ-only ace for a broad trustee is NOT a defect:
  // managed images commonly leave an inherited Everyone-read behind,
  // and refusing it would brick every startup on those machines
  root := NewTempDir('acl-everyone-read');
  try
    tree := BuildFixture(root);
    Check(IsolateDacl(tree, SDDL_EVERYONE_READ),
      'DACL isolation with a read-only Everyone');
    Check(PWebWv2FixedAclApply(tree, diag),
      'ACL apply beside a read-only Everyone');
    CheckUtf8(PWebWv2FixedAclVerify(tree, diag),
      'a READ-only Everyone ace must not refuse the tree: %', [diag]);
  finally
    DeleteTree(root);
  end;
end;

{ ---- the deterministic tree manifest ---- }

procedure TTestWv2Fixed.TreeManifest;
var
  root, tree, manifestFile: TFileName;
  manifest, err, first: RawUtf8;
  lines: TRawUtf8DynArray;
  i: PtrInt;
  ok: Boolean;
begin
  root := NewTempDir('manifest');
  try
    tree := BuildFixture(root);
    manifestFile := IncludeTrailingPathDelimiter(root) + 'tree.manifest';

    // the call is a STATEMENT of its own: an open-array message
    // argument may be evaluated before the call that fills it
    ok := PWebWv2FixedManifestBuild(tree, manifest, err);
    CheckUtf8(ok, 'manifest build: %', [err]);
    SplitLf(manifest, lines);
    // the tree holds three files (the loader lives beside it, in the
    // runtime ROOT, so it is never part of the tree manifest)
    CheckUtf8(Length(lines) = 4,
      'manifest must carry a header + 3 tree files, got % line(s)',
      [Length(lines)]);
    if Length(lines) = 0 then
      exit; // never index an empty split: the failure above says why
    CheckEqual(lines[0], PWEB_WV2_FIXED_MANIFEST_TAG, 'manifest header');
    // every body line is '<64 lowercase hex>  <relative/path>', sorted
    // ordinal, with forward slashes - the exact shape the build script
    // reproduces and the gates compare against
    first := '';
    for i := 1 to High(lines) do
    begin
      if lines[i] = '' then
        continue;
      CheckUtf8(Length(lines[i]) > 66, 'manifest line too short: %',
        [lines[i]]);
      CheckEqual(Copy(lines[i], 65, 2), '  ', 'manifest separator');
      CheckUtf8(Pos('\', lines[i]) = 0,
        'manifest must use forward slashes: %', [lines[i]]);
      if first <> '' then
        CheckUtf8(OrdLess(first, Copy(lines[i], 67, MaxInt)),
          'manifest is not ordinal-sorted at %', [lines[i]]);
      first := Copy(lines[i], 67, MaxInt);
    end;

    Check(PWebWv2FixedManifestWrite(tree, manifestFile, err),
      'manifest write');
    Check(PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'manifest verify of the untouched tree');

    // a single tampered byte is caught
    WritePe(IncludeTrailingPathDelimiter(tree) + 'msedge.dll', $8664);
    FileFromString(PeBytes($8664) + 'x',
      IncludeTrailingPathDelimiter(tree) + 'msedge.dll');
    Check(not PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'a tampered file must fail verification');
    WritePe(IncludeTrailingPathDelimiter(tree) + 'msedge.dll', $8664);
    Check(PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'restoring the byte must restore the verdict');

    // an ADDED file is caught (a manifest is an exact set, not a floor)
    FileFromString('smuggled',
      IncludeTrailingPathDelimiter(tree) + 'extra.dll');
    Check(not PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'an added file must fail verification');
    DeleteFile(IncludeTrailingPathDelimiter(tree) + 'extra.dll');

    // a REMOVED file is caught
    DeleteFile(IncludeTrailingPathDelimiter(tree) +
      'EBWebView\x64\EmbeddedBrowserWebView.dll');
    Check(not PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'a removed file must fail verification');
    WritePe(IncludeTrailingPathDelimiter(tree) +
      'EBWebView\x64\EmbeddedBrowserWebView.dll', $8664);

    // a drifted header is caught before any hashing happens
    FileFromString('pweb-wv2-fixed-tree-manifest v0'#10, manifestFile);
    Check(not PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'a drifted manifest header must fail verification');
    CheckUtf8(Pos(PWEB_WV2_FIXED_MANIFEST_TAG, err) > 0,
      'the header refusal must name the expected tag: %', [err]);
    // a missing manifest, and an empty tree, both fail closed
    DeleteFile(manifestFile);
    Check(not PWebWv2FixedManifestVerify(tree, manifestFile, err),
      'a missing manifest must fail verification');
    Check(not PWebWv2FixedManifestBuild(root + '\nope', manifest, err),
      'a missing tree root must fail the build');
  finally
    DeleteTree(root);
  end;
end;

{ ---- the ratified selection order ---- }

procedure TTestWv2Fixed.SelectionSeam;
var
  prepared: TPWebWv2FixedResult;
  buf: array[0..1023] of WideChar;
  n: DWord;

  function Validated: TPWebWv2FixedResult;
  begin
    Result := Default(TPWebWv2FixedResult);
    Result.Status := wv2fxValidated;
    Result.FailedStep := wv2fsNone;
    Result.RuntimeRoot := 'C:\Apps\PWeb\runtime\webview2\';
    Result.TreeDir := 'C:\Apps\PWeb\runtime\webview2\' +
      PWebWv2FixedTreeName;
    Result.LoaderPath := 'C:\Apps\PWeb\runtime\webview2\WebView2Loader.dll';
  end;

begin
  PWebWv2FixedLoadLibrary := @LoadLibraryFake;
  PWebWv2FixedModuleHandle := @ModuleHandleFake;
  PWebWv2FixedResetSelection;
  // F4: a HOSTILE inherited value is planted before selection
  SetEnvW(PWEB_WV2_FIXED_ENV, 'C:\attacker\runtime');
  try
    // an un-validated result can never be selected
    prepared := Default(TPWebWv2FixedResult);
    PWebWv2FixedSelect(prepared);
    Check(prepared.Status = wv2fxFailed, 'unvalidated selection status');
    Check(not PWebWv2FixedSelected, 'nothing may be selected yet');

    // the loader preload is the FIRST step and a hard gate
    FakeLoadCalls := 0;
    FakeModuleCalls := 0;
    FakeLoadHandle := 0;
    FakeModuleHandle := 0;
    prepared := Validated;
    PWebWv2FixedSelect(prepared);
    Check(prepared.Status = wv2fxFailed, 'preload failure status');
    Check(prepared.FailedStep = wv2fsLoaderPreload, 'preload failure step');
    CheckEqual(FakeLoadCalls, 1, 'the loader must be preloaded once');
    CheckEqual(FakeModuleCalls, 0,
      'the module probe must never run after a failed preload');
    CheckEqual(RawUtf8(FakeLoadPath), RawUtf8(prepared.LoaderPath),
      'the loader must be preloaded by its ABSOLUTE path');
    Check(not PWebWv2FixedSelected, 'a failed preload must not select');

    // a foreign WebView2Loader.dll already resident is equally fatal
    FakeLoadCalls := 0;
    FakeModuleCalls := 0;
    FakeLoadHandle := THandle(1234);
    FakeModuleHandle := THandle(5678);
    prepared := Validated;
    PWebWv2FixedSelect(prepared);
    Check(prepared.Status = wv2fxFailed, 'module identity status');
    Check(prepared.FailedStep = wv2fsLoaderIdentity, 'module identity step');
    CheckEqual(FakeModuleCalls, 1, 'the module identity must be probed');
    Check(not PWebWv2FixedSelected, 'a foreign loader must not select');
    // the hostile inherited value is still untouched at this point
    n := GetEnvironmentVariableW(PWideChar(UnicodeString(
      PWEB_WV2_FIXED_ENV)), @buf[0], Length(buf));
    CheckEqual(RawUnicodeToUtf8(@buf[0], n), 'C:\attacker\runtime',
      'a refused selection must never touch the variable');

    // the happy path: preload, identity, then the override + read-back
    FakeModuleHandle := THandle(1234);
    prepared := Validated;
    PWebWv2FixedSelect(prepared);
    CheckUtf8(prepared.Status = wv2fxSelected, 'selection status (%)',
      [prepared.Diagnostic]);
    Check(prepared.FailedStep = wv2fsNone, 'selection step');
    Check(PWebWv2FixedSelected, 'the process must record the selection');
    n := GetEnvironmentVariableW(PWideChar(UnicodeString(
      PWEB_WV2_FIXED_ENV)), @buf[0], Length(buf));
    // F4: the inherited hostile path is GONE, the pinned tree is in
    CheckEqual(RawUnicodeToUtf8(@buf[0], n),
      StringToUtf8(prepared.TreeDir),
      'the process must own the variable outright');

    // the variable is set exactly once per process
    prepared := Validated;
    PWebWv2FixedSelect(prepared);
    Check(prepared.Status = wv2fxFailed, 'second selection status');
    Check(prepared.FailedStep = wv2fsEnvironment, 'second selection step');
  finally
    PWebWv2FixedLoadLibrary := @PWebWv2FixedLoadLibraryOs;
    PWebWv2FixedModuleHandle := @PWebWv2FixedModuleHandleOs;
    PWebWv2FixedResetSelection;
    SetEnvW(PWEB_WV2_FIXED_ENV, '');
  end;
end;

end.
