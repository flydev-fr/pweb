{
  pweb.cli.package - `pweb build --profile <name>`, the distributable
  artifact (CAP-10D1).

  It takes the release directory CAP-10D0 committed and turns it into one
  thing somebody else can install or unpack:

    windows-x86_64   normal | offline | fixed-runtime   an Inno Setup
                     installer built from the pinned, offline-verified
                     WebView2 artifacts, with the CAP-13 mechanics unchanged
    linux, macos     archive                            one deterministic
                     .tar.gz of the committed release

  under <output>/<os>-<arch>/artifacts/<profile>/ - beside the release and
  never inside it, and never under `dist`, which the CAP-10C1 pipeline
  already owns as the Pas2JS static assembly directory.

  and writes a `release-index.json` beside it in the CAP-6b4 shape - the
  one seam that shard deliberately left for this one.

  ---------------------------------------------------------------------------
  THE FIFTH CALLER OF THE ENGINE, AND WHY THAT IS THE HONEST SHAPE
  ---------------------------------------------------------------------------

  CAP-10D0 measured the set of units that call PWebCliExecute and found four,
  one per command family. This unit is the fifth, and the supersession is
  recorded rather than avoided.

  The invariant was never the number. It is: ONE child-process engine, an
  ENUMERATED set of callers, and a build driver that spawns nothing. All
  three still hold and all three are re-measured - pweb.cli.build still names
  no process API by any of the thirteen swept spellings, and this unit runs
  every child in pepSupervise with the same sink, the same stop check, the
  same descendant drain and the same typed outcome mapping the pipeline uses.

  The alternative - exporting pweb.cli.pipeline's nested RunStage so
  packaging could borrow it - was considered and refused: it closes over the
  run result, the notify context and the redaction tables, and refactoring a
  frozen unit's spine to keep a count at four is the worse trade.

  Packaging is deliberately NOT an eleventh stage. The ten stages, their
  order and their bounds are inherited verbatim, and a pipeline that knew
  about profiles would be a pipeline this shard had renegotiated.

  ---------------------------------------------------------------------------
  ZERO NETWORK, AND HOW THAT IS A PROPERTY RATHER THAN A PROMISE
  ---------------------------------------------------------------------------

  This unit links no HTTP client, names no URL and has no fetch call site.
  The locks that carry Microsoft's and jrsoftware's download addresses are
  repository build metadata and are never shipped into an SDK; what travels
  is pweb.cli.packpins, a table of digests cross-checked against those locks
  on every CI leg.

  So an absent input is a REFUSAL that names the provisioning script, never a
  download: `pweb build` is a build tool, and a build tool that reaches the
  network to repair its own inputs is a build tool whose output depends on
  what a CDN served that afternoon.

  ---------------------------------------------------------------------------
  IDENTITY
  ---------------------------------------------------------------------------

  Every platform identifier is a deterministic function of pweb.json, and
  docs/distribution-contract.md is where the rules live. Two of them decide
  whether two generated applications can collide on one machine:

    AppId            the bundleId LITERAL. No GUID generation, no hashing,
                     nothing to reproduce - the identifier the developer
                     stated IS the identity. Refused above 127 bytes, which
                     is Inno's own ceiling and one byte below what schema 1
                     allows
    install dir      the local-appdata Programs folder, then <vendor> then
                     <app>, where <vendor> is the bundleId up to its LAST dot
                     and <app> is the last label. The split is unique, so the
                     pair is a bijection with the bundleId and two products
                     can never land in one directory - which is exactly what
                     makes the CAP-6b4 stale-tree reclaim safe to inherit

  And every value is re-checked against the Inno metacharacter set
  immediately before it becomes a /D define. Schema 1's grammars already
  exclude all of them, so this is defence in depth - and it REFUSES rather
  than escaping, because an escaped identity is a different identity and an
  installer that quietly installs a different application is worse than one
  that will not build.
}
unit pweb.cli.package;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.process,
  pweb.cli.probe,
  pweb.cli.run,
  pweb.cli.sdk,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.packpins,
  pweb.cli.tar,
  pweb.cli.pipeline;

const
  /// the four ratified profile names, spelled ONCE
  // - `fixed-runtime`, never `fixed`: it is the value written to the machine
  // as the HKCU profile marker, tools/setup/pwebappsetup.issi validates that
  // exact spelling case-sensitively and _bmad-output/specs/spec-pweb/
  // deployment.md names it. A shorter CLI spelling would be a second name
  // for one thing, and the CAP-6b4 marker gate exists to forbid exactly that
  PWEB_PACK_NORMAL = 'normal';
  PWEB_PACK_OFFLINE = 'offline';
  PWEB_PACK_FIXED = 'fixed-runtime';
  PWEB_PACK_ARCHIVE = 'archive';

  /// the system utility the fixed profile expands its cabinet with,
  // named with its extension because it is resolved from the SYSTEM
  // DIRECTORY by exact on-disk spelling rather than through PATHEXT
  PWEB_PACK_TOOL_EXPAND = 'expand.exe';

  /// the Inno metacharacter set. `{` and `}` open and close a constant,
  // `"` ends a define's value, `;` starts a comment, CR and LF end a
  // directive, and a separator would change a path's meaning. None of them
  // can occur in a schema-1 value; this is the check that makes that a
  // measured fact rather than a reading of the grammar
  PWEB_PACK_FORBIDDEN: array[0 .. 8] of AnsiChar = (
    '{', '}', '"', ';', '\', '/', #13, #10, #0);

type
  /// which distributable artifact was asked for
  // - ordinal 0 means none was: `pweb build` without --profile
  TPWebCliProfile = (
    ppfNone, ppfNormal, ppfOffline, ppfFixedRuntime, ppfArchive);

  /// why packaging refused - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebCliPackRefusal = (
    pkrNone,
    /// this profile is not one this target has (exit 2)
    pkrProfileNotForTarget,
    /// a descriptor value carries a character an Inno define cannot (exit 3)
    pkrIdentityRefused,
    /// the derived AppId exceeds Inno's 127-character ceiling (exit 3)
    pkrIdentityTooLong,
    /// the SDK root itself could not be resolved (exit 4)
    pkrSdkUnresolved,
    /// the packaging kit is not staged in this SDK (exit 4)
    pkrKitMissing,
    /// no Inno Setup compiler (exit 4)
    pkrIsccMissing,
    /// a compiler whose pin stamp or banner is not the ratified one (exit 4)
    pkrIsccIdentity,
    /// a pinned input is absent (exit 4)
    pkrInputMissing,
    /// a pinned input is present and is not the ratified bytes (exit 4)
    pkrInputDigest,
    /// the cabinet expander is missing (exit 4)
    pkrExpandMissing,
    /// the project root leaves the fixed profile's staging tree past
    /// MAX_PATH (exit 3)
    pkrFixedRootTooLong,
    /// a staging file operation failed (exit 6)
    pkrStage,
    /// a packaging child failed, died or was stopped (exit 5)
    pkrChildFailed,
    /// a stop was requested during packaging (exit 5)
    pkrInterrupted,
    /// the child reported success and produced no artifact (exit 6)
    pkrArtifactMissing,
    /// the deterministic archive writer refused (exit 6)
    pkrArchive,
    /// the committed artifact directory could not be replaced (exit 6)
    pkrCommit,
    /// packaging changed the release it was told to package (exit 6)
    pkrReleaseAltered,
    /// packaging wrote outside the ratified mutation set (exit 6)
    pkrMutation);

  /// what one packaging run produced
  TPWebCliPackResult = record
    Refusal: TPWebCliPackRefusal;
    /// machine-stable cause, '' when Refusal is pkrNone
    Cause: RawUtf8;
    /// a logical detail, never an absolute path
    Detail: RawUtf8;
    /// True when a stop was requested before packaging finished
    Interrupted: Boolean;
    /// the child's typed outcome, meaningful for pkrChildFailed
    Outcome: TPWebCliChildOutcome;
    ExitCode: Integer;
    Signal: Integer;
    /// the ratified profile name
    Profile: RawUtf8;
    /// the artifact, PROJECT-RELATIVE and forward-slashed; '' on failure
    ArtifactLogical: RawUtf8;
    ArtifactBytes: Int64;
    ArtifactSha256: RawUtf8;
    /// the index beside it, project-relative
    IndexLogical: RawUtf8;
  end;

  /// every platform identifier one packaging run derives, and nothing else
  // - PUBLIC because it is the whole of the identity contract, and the
  // CAP-10D1 suite asserts every rule of it on four targets: a Linux runner
  // proving what a Windows AppId will be is exactly the property the pure
  // plan builders of the pipeline already have
  TPWebPackIdentityInfo = record
    /// the Inno AppId: the pweb.json bundleId, literally
    AppId: RawUtf8;
    /// the display name and version, from the descriptor
    AppName: RawUtf8;
    AppVersion: RawUtf8;
    /// the bundleId up to its LAST dot, and the last label
    Vendor: RawUtf8;
    App: RawUtf8;
    /// Software\PWeb\Apps\<bundleId>
    MarkerKey: RawUtf8;
    /// <name>-<profile>-setup, and never "setup"
    SetupBasename: RawUtf8;
    /// the release triple's two per-target names
    ExeName: RawUtf8;
    LibName: RawUtf8;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliPackRefusalText(Refusal: TPWebCliPackRefusal): RawUtf8;

/// True when a PATH this CLI built may be handed to ISCC as a define value
// - the separator and the drive colon are allowed, because a path needs
// both; the four bytes an Inno directive reads as syntax, and every control
// byte, are not
function PWebCliPackStagingPathAcceptable(const Path: RawUtf8): Boolean;

/// derive every platform identifier from ONE descriptor
// - a pure function: no filesystem, no environment, no host state, so the
// same descriptor derives the same identity on every target
// - False when a value carries a character an Inno define cannot, or when
// the AppId would exceed Inno's 127-character ceiling. REFUSED, never
// escaped: an escaped identity is a DIFFERENT identity
function PWebCliPackIdentityOf(const Project: TPWebCliProject;
  Os: TPWebCliOs; Profile: TPWebCliProfile;
  out Id: TPWebPackIdentityInfo): Boolean;

/// the ratified name of a profile, and the reverse
function PWebCliProfileText(Profile: TPWebCliProfile): RawUtf8;

/// the COMPILED allowlist. It accepts all four names on EVERY target, so
/// one grammar is identical on four platforms - a parser whose accepted set
/// differed per platform is precisely the divergence CAP-10A forbids. Which
/// of them this host can actually build is a separate question, asked by
/// PWebCliProfileForTarget and answered with its own typed refusal
function PWebCliParseProfile(const Text: RawUtf8;
  out Profile: TPWebCliProfile): Boolean;

/// the profiles this target has, comma-separated, in ratified order
function PWebCliProfilesForTarget(Os: TPWebCliOs): RawUtf8;

/// True when this target can build this profile
function PWebCliProfileForTarget(Profile: TPWebCliProfile;
  Os: TPWebCliOs): Boolean;

/// the ratified exit code of a packaging refusal
function PWebCliPackExitCode(Refusal: TPWebCliPackRefusal): Integer;

/// resolve and verify every packaging input WITHOUT building anything
// - runs BEFORE the pipeline, so a developer whose machine lacks a pinned
// input learns it in one second rather than after a full build. It resolves,
// probes, reads and hashes; it writes nothing and spawns nothing but the
// bounded identity probe
function PWebCliPackPreflight(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch;
  Profile: TPWebCliProfile): TPWebCliPackResult;

/// build the distributable artifact for an ALREADY BUILT release
// - the caller owns the pipeline; this runs after it and never re-runs it
function PWebCliRunPackage(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Profile: TPWebCliProfile;
  Notify: TPWebCliPipeNotify; Opaque: Pointer): TPWebCliPackResult;


implementation

function PackIntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

function PWebCliPackRefusalText(Refusal: TPWebCliPackRefusal): RawUtf8;
begin
  case Refusal of
    pkrNone:                Result := 'ok';
    pkrProfileNotForTarget: Result := 'profile_not_for_target';
    pkrIdentityRefused:     Result := 'pack_identity_refused';
    pkrIdentityTooLong:     Result := 'pack_identity_too_long';
    pkrSdkUnresolved:       Result := 'pack_sdk_unresolved';
    pkrKitMissing:          Result := 'pack_kit_missing';
    pkrIsccMissing:         Result := 'pack_iscc_missing';
    pkrIsccIdentity:        Result := 'pack_iscc_identity';
    pkrInputMissing:        Result := 'pack_input_missing';
    pkrInputDigest:         Result := 'pack_input_digest';
    pkrExpandMissing:       Result := 'pack_expand_missing';
    pkrFixedRootTooLong:    Result := 'pack_root_too_long_for_fixed';
    pkrStage:               Result := 'pack_stage_failed';
    pkrChildFailed:         Result := 'pack_child_failed';
    pkrInterrupted:         Result := 'pack_interrupted';
    pkrArtifactMissing:     Result := 'pack_artifact_missing';
    pkrArchive:             Result := 'pack_archive_refused';
    pkrCommit:              Result := 'pack_commit_failed';
    pkrReleaseAltered:      Result := 'pack_release_altered';
    pkrMutation:            Result := 'pack_mutation';
  else
    Result := 'pack_refused';
  end;
end;

function PWebCliProfileText(Profile: TPWebCliProfile): RawUtf8;
begin
  case Profile of
    ppfNormal:       Result := PWEB_PACK_NORMAL;
    ppfOffline:      Result := PWEB_PACK_OFFLINE;
    ppfFixedRuntime: Result := PWEB_PACK_FIXED;
    ppfArchive:      Result := PWEB_PACK_ARCHIVE;
  else
    Result := '';
  end;
end;

function PWebCliParseProfile(const Text: RawUtf8;
  out Profile: TPWebCliProfile): Boolean;
begin
  Profile := ppfNone;
  // BYTE-EXACT, exactly as the --ui allowlist is: `Normal`, `FIXED-RUNTIME`
  // and `fixed` are refused like `msix`, because the accepted spelling is
  // the one written to the machine
  if Text = PWEB_PACK_NORMAL then
    Profile := ppfNormal
  else if Text = PWEB_PACK_OFFLINE then
    Profile := ppfOffline
  else if Text = PWEB_PACK_FIXED then
    Profile := ppfFixedRuntime
  else if Text = PWEB_PACK_ARCHIVE then
    Profile := ppfArchive;
  Result := Profile <> ppfNone;
end;

function PWebCliProfilesForTarget(Os: TPWebCliOs): RawUtf8;
begin
  if Os = pcoWindows then
    Result := PWEB_PACK_NORMAL + ',' + PWEB_PACK_OFFLINE + ',' +
      PWEB_PACK_FIXED
  else
    Result := PWEB_PACK_ARCHIVE;
end;

function PWebCliProfileForTarget(Profile: TPWebCliProfile;
  Os: TPWebCliOs): Boolean;
begin
  if Os = pcoWindows then
    Result := Profile in [ppfNormal, ppfOffline, ppfFixedRuntime]
  else
    Result := Profile = ppfArchive;
end;

function PWebCliPackExitCode(Refusal: TPWebCliPackRefusal): Integer;
begin
  // the CAP-10A taxonomy, reused rather than extended: this shard adds no
  // exit category and no seventh code. The numbers are literals for the
  // same reason PWebCliPipeExitCode's are - the named constants live in the
  // PROGRAM, and a unit that could not be linked without it would not be a
  // unit
  case Refusal of
    pkrNone:
      Result := 0;
    pkrProfileNotForTarget:
      Result := 2;                    // the command line was refused
    pkrIdentityRefused,
    pkrIdentityTooLong,
    pkrFixedRootTooLong:
      Result := 3;                    // the project or its descriptor
    pkrSdkUnresolved,
    pkrKitMissing,
    pkrIsccMissing,
    pkrIsccIdentity,
    pkrInputMissing,
    pkrInputDigest,
    pkrExpandMissing:
      Result := 4;                    // this machine cannot package it
    pkrChildFailed,
    pkrInterrupted:
      Result := 5;                    // a child failed, died or was stopped
  else
    Result := 6;                      // an invariant of packaging broke
  end;
end;


{ ---------------------------------------------------------------------------
  IDENTITY
  --------------------------------------------------------------------------- }

// no value that becomes a /D define may carry a character an Inno directive
// reads as syntax. REFUSED, never escaped
function IdentityAcceptable(const Value: RawUtf8): Boolean;
var
  i, j: PtrInt;
begin
  Result := False;
  if Value = '' then
    exit;
  for i := 1 to Length(Value) do
  begin
    if Value[i] < ' ' then
      exit;
    for j := Low(PWEB_PACK_FORBIDDEN) to High(PWEB_PACK_FORBIDDEN) do
      if Value[i] = PWEB_PACK_FORBIDDEN[j] then
        exit;
  end;
  Result := True;
end;

// A PATH THIS CLI BUILT is not a descriptor value, and it is checked all the
// same. PWEB_PAYLOAD_DIR and PWEB_RUNTIME_DIR are absolute paths under the
// project root, which a DEVELOPER controls: `C:\my{dir}\proj` is a perfectly
// legal Windows path, and `{#PWEB_PAYLOAD_DIR}` expanded into a [Files]
// Source would put `{dir}` where Inno reads a CONSTANT. So the separator and
// the drive colon are allowed here - a path needs both - and the four bytes
// an Inno directive reads as syntax are not. REFUSED, never escaped, for the
// same reason a descriptor value is: a path that quietly became a different
// path is an installer that embeds something else.
function PWebCliPackStagingPathAcceptable(const Path: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if Path = '' then
    exit;
  for i := 1 to Length(Path) do
    if (Path[i] < ' ') or
       (Path[i] = '{') or
       (Path[i] = '}') or
       (Path[i] = '"') or
       (Path[i] = ';') then
      exit;
  Result := True;
end;

// the bundleId split at its LAST dot. A reverse-DNS identifier always has
// at least two labels (schema 1 requires two to five), so both halves are
// non-empty by construction - and the split being at the LAST dot is what
// makes <vendor>\<app> a bijection with the identifier
function SplitBundleId(const BundleId: RawUtf8;
  out Vendor, App: RawUtf8): Boolean;
var
  i, dot: PtrInt;
begin
  dot := 0;
  for i := 1 to Length(BundleId) do
    if BundleId[i] = '.' then
      dot := i;
  Result := (dot > 1) and (dot < Length(BundleId));
  if not Result then
    exit;
  Vendor := Copy(BundleId, 1, dot - 1);
  App := Copy(BundleId, dot + 1, MaxInt);
end;

function DeriveIdentity(const Project: TPWebCliProject; Os: TPWebCliOs;
  Profile: TPWebCliProfile; out Id: TPWebPackIdentityInfo;
  out Refusal: TPWebCliPackRefusal; out Detail: RawUtf8): Boolean;
begin
  Result := False;
  Id := Default(TPWebPackIdentityInfo);
  Refusal := pkrNone;
  Detail := '';
  // the bundleId IS the AppId. Inno's ceiling is 127 characters and schema
  // 1 allows 128, so the one value that could overflow is refused by name
  // rather than truncated into somebody else's identity
  if Length(Project.BundleId) > 127 then
  begin
    Refusal := pkrIdentityTooLong;
    Detail := 'bundleId';
    exit;
  end;
  Id.AppId := Project.BundleId;
  Id.AppName := Project.Name;
  Id.AppVersion := Project.Version;
  if not SplitBundleId(Project.BundleId, Id.Vendor, Id.App) then
  begin
    Refusal := pkrIdentityRefused;
    Detail := 'bundleId';
    exit;
  end;
  Id.MarkerKey := 'Software\PWeb\Apps\' + Project.BundleId;
  Id.SetupBasename := Project.Name + '-' + PWebCliProfileText(Profile) +
    '-setup';
  Id.ExeName := Project.ProgramIdent;
  if Os = pcoWindows then
    Id.ExeName := Id.ExeName + PWEB_CLI_RUN_WINDOWS_EXT;
  Id.LibName := PWebCliWebviewLibName(Os);
  // the metacharacter re-check, on every value that becomes a define. The
  // marker key is exempt from the separator rule because a registry path is
  // written with one, and it is built HERE from a value already checked
  if not IdentityAcceptable(Id.AppId) or
     not IdentityAcceptable(Id.AppName) or
     not IdentityAcceptable(Id.AppVersion) or
     not IdentityAcceptable(Id.Vendor) or
     not IdentityAcceptable(Id.App) or
     not IdentityAcceptable(Id.SetupBasename) or
     not IdentityAcceptable(Id.ExeName) or
     not IdentityAcceptable(Id.LibName) then
  begin
    Refusal := pkrIdentityRefused;
    Detail := 'descriptor_value';
    exit;
  end;
  // and the CAP-6b4 ban, applied to the value this build would emit rather
  // than to the manifest that validates it: a setup.exe is appcompat-shimmed
  // into loading DLLs from its own directory, and the include's #error is
  // the second line of that defence, not the first
  if LowerCaseU(Id.SetupBasename) = 'setup' then
  begin
    Refusal := pkrIdentityRefused;
    Detail := 'setup_basename';
    exit;
  end;
  Result := True;
end;

function PWebCliPackIdentityOf(const Project: TPWebCliProject;
  Os: TPWebCliOs; Profile: TPWebCliProfile;
  out Id: TPWebPackIdentityInfo): Boolean;
var
  refusal: TPWebCliPackRefusal;
  detail: RawUtf8;
begin
  Result := DeriveIdentity(Project, Os, Profile, Id, refusal, detail);
end;


{ ---------------------------------------------------------------------------
  THE PACKAGING KIT INSIDE AN INSTALLED SDK
  --------------------------------------------------------------------------- }

type
  /// where every packaging input lives, resolved one component at a time
  // through PWebCliEntry - so a junction cannot redirect the pinned
  // installer and a case variant cannot resolve, exactly as the SDK-root
  // resolver already requires of every build input
  TPWebPackKit = record
    Root: RawUtf8;
    ShareTree: RawUtf8;
    /// <share>/deps/innosetup and the compiler inside it
    Iscc: RawUtf8;
    IsccStamp: RawUtf8;
    /// <share>/deps/webview2-runtime
    Wv2Dir: RawUtf8;
    /// <share>/pack/{setup,bin,lib}
    SetupDir: RawUtf8;
    BinDir: RawUtf8;
    LibDir: RawUtf8;
  end;

// one component, by its exact on-disk spelling; a reparse point refuses
function KitStep(const Parent, Name: RawUtf8; Dir: Boolean;
  out Full: RawUtf8): Boolean;
var
  want: TPWebCliNodeKind;
begin
  if Dir then
    want := pcnDirectory
  else
    want := pcnFile;
  Result := PWebCliEntry(Parent, Name) = want;
  if Result then
    Full := PWebCliJoin(Parent, Name);
end;

function ResolveKit(Os: TPWebCliOs; out Kit: TPWebPackKit;
  out Refusal: TPWebCliPackRefusal; out Detail: RawUtf8): Boolean;
var
  sdkRefusal: TPWebSdkRefusal;
  share, packDir: RawUtf8;
begin
  Result := False;
  Kit := Default(TPWebPackKit);
  Detail := '';
  if not PWebCliSdkRoot(Kit.Root, sdkRefusal) then
  begin
    Refusal := pkrSdkUnresolved;
    Detail := PWebSdkRefusalText(sdkRefusal);
    exit;
  end;
  if not KitStep(Kit.Root, PWEB_SDK_SHARE, True, share) or
     not KitStep(share, PWEB_SDK_SHARE_PWEB, True, Kit.ShareTree) then
  begin
    Refusal := pkrSdkUnresolved;
    Detail := PWEB_SDK_SHARE;
    exit;
  end;
  // THE POSIX ARCHIVE NEEDS NO KIT AT ALL, and that is the point of having
  // written the writer: pweb.cli.tar is a pure function and mORMot is the
  // compressor, so there is no manifest to find, no compiler to resolve and
  // no pinned artifact to verify. An SDK that ships no packaging kit still
  // produces a Linux or macOS archive - and requiring one would have been a
  // coupling invented to make two targets look alike
  if Os <> pcoWindows then
  begin
    Refusal := pkrNone;
    Result := True;
    exit;
  end;
  if not KitStep(Kit.ShareTree, PWEB_PACK_DIR, True, packDir) or
     not KitStep(packDir, PWEB_PACK_SETUP, True, Kit.SetupDir) or
     not KitStep(packDir, PWEB_PACK_BIN, True, Kit.BinDir) then
  begin
    Refusal := pkrKitMissing;
    Detail := PWEB_PACK_DIR;
    exit;
  end;
  if not KitStep(packDir, PWEB_PACK_LIB, True, Kit.LibDir) then
  begin
    Refusal := pkrKitMissing;
    Detail := PWEB_PACK_LIB;
    exit;
  end;
  if not KitStep(Kit.ShareTree, PWEB_SDK_DEPS, True, share) then
  begin
    Refusal := pkrKitMissing;
    Detail := PWEB_SDK_DEPS;
    exit;
  end;
  // the compiler is resolved but NOT judged here: its two identity axes are
  // VerifyIscc's, so an absent one and a wrong one earn different causes
  if KitStep(share, PWEB_PACK_DEPS_INNOSETUP, True, packDir) then
    if KitStep(packDir, PWEB_PACK_ISCC_EXE, False, Kit.Iscc) then
      KitStep(packDir, PWEB_PACK_ISCC_STAMP, False, Kit.IsccStamp);
  if not KitStep(share, PWEB_PACK_DEPS_WV2, True, Kit.Wv2Dir) then
  begin
    Refusal := pkrInputMissing;
    Detail := PWEB_PACK_DEPS_WV2;
    exit;
  end;
  Refusal := pkrNone;
  Result := True;
end;

// a pinned artifact: present, the ratified size, the ratified digest. The
// tools/get-webview2-runtime.ps1 verification with its transfer half
// removed - sha256 first, size second, and any mismatch is a refusal that
// names the provisioning script rather than a fetch that "repairs" it
function VerifyPinned(const Dir, FileName, Sha: RawUtf8; Bytes: Int64;
  out Full: RawUtf8; out Refusal: TPWebCliPackRefusal): Boolean;
var
  content: RawByteString;
  tooBig: Boolean;
begin
  Result := False;
  Full := '';
  if not KitStep(Dir, FileName, False, Full) then
  begin
    Refusal := pkrInputMissing;
    exit;
  end;
  if not PWebCliReadSmallFile(Full, PWEB_PACK_MAX_ARCHIVE_BYTES * 2, content,
       tooBig) then
  begin
    Refusal := pkrInputMissing;
    exit;
  end;
  if (Length(content) <> Bytes) or
     (LowerCaseU(Sha256(content)) <> Sha) then
  begin
    Refusal := pkrInputDigest;
    exit;
  end;
  Refusal := pkrNone;
  Result := True;
end;

// the compiler's identity, on the two axes tools/get-innosetup.ps1 uses:
// the stamp it wrote beside ISCC.exe carrying the verified INSTALLER digest
// (ISCC publishes no machine-readable version resource, so that digest IS
// the toolchain identity) and the banner the binary itself announces
function VerifyIscc(const Iscc, Stamp: RawUtf8;
  out Refusal: TPWebCliPackRefusal; out Detail: RawUtf8): Boolean;
var
  content: RawByteString;
  tooBig: Boolean;
  probe: TPWebCliProbe;
  text: RawUtf8;
begin
  Result := False;
  Detail := '';
  if Iscc = '' then
  begin
    Refusal := pkrIsccMissing;
    exit;
  end;
  if (Stamp = '') or
     not PWebCliReadSmallFile(Stamp, PWEB_CLI_DEV_SMALL_FILE_MAX, content,
       tooBig) then
  begin
    Refusal := pkrIsccIdentity;
    Detail := 'stamp';
    exit;
  end;
  text := TrimU(RawUtf8(content));
  if text <> PWEB_PACK_ISCC_INSTALLER_SHA then
  begin
    Refusal := pkrIsccIdentity;
    Detail := 'pin';
    exit;
  end;
  // ISCC exits nonzero with no arguments and prints its banner; only the
  // banner is read, exactly as the provisioning script reads it - and both
  // streams are searched, because that script merges them with 2>&1 and a
  // banner on the wrong stream is not a different compiler
  probe := PWebCliRunProbe(Iscc, [], PWEB_CLI_PROBE_TIMEOUT_MS);
  if (PosEx(PWEB_PACK_ISCC_BANNER, probe.Output) = 0) and
     (PosEx(PWEB_PACK_ISCC_BANNER, probe.ErrorText) = 0) then
  begin
    Refusal := pkrIsccIdentity;
    Detail := 'banner';
    exit;
  end;
  Refusal := pkrNone;
  Result := True;
end;


{ THE FIXED PROFILE'S OWN PATH CEILING, and why it is a separate rule from
  the pipeline's.

  The pipeline's PWEB_CLI_PIPE_MAX_ROOT_CHARS bounds what the COMPILERS can
  take. This bounds what ISCC can take, and it is stricter for one measured
  reason: the fixed profile expands a Microsoft cabinet whose deepest entry
  is PWEB_PACK_FIXED_TREE_MAX_REL characters, under a staging directory this
  CLI builds inside the project's own output tree. ISCC is not
  extended-length aware, so the whole of that has to fit inside MAX_PATH.

  MEASURED, and it is not a theoretical limit: a project at
  ...uild\cap10d1\spaced work\demopack - 97 characters, an ordinary
  developer path - put the deepest entry at exactly 260 and ISCC failed with
  `the specified path could not be found` AFTER compressing 690 MB. This
  refusal turns that into one second and a cause. }
function FixedRootBound(const Project: TPWebCliProject;
  const Target: RawUtf8): Integer;
begin
  // <root>\<output>\<target>\<stage>\<rt>\<deepest entry>
  Result := PWEB_PACK_MAX_PATH - PWEB_PACK_FIXED_TREE_MAX_REL - 1 -
    (Length(Project.Output) + 1) - (Length(Target) + 1) -
    (Length(PWEB_PACK_STAGE) + 1) - (Length(PWEB_PACK_RUNTIME) + 1);
end;

// the cabinet expander, by the ONE rule that cannot be changed by a shell
// profile: the kernel's own system directory, walked one component at a time
// like every other input this unit resolves
function ResolveExpand(out Full: RawUtf8): Boolean;
var
  systemDir: RawUtf8;
begin
  Full := '';
  Result := PWebCliSystemDir(systemDir) and
            KitStep(systemDir, PWEB_PACK_TOOL_EXPAND, False, Full);
end;


{ ---------------------------------------------------------------------------
  PREFLIGHT
  --------------------------------------------------------------------------- }

function PWebCliPackPreflight(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch;
  Profile: TPWebCliProfile): TPWebCliPackResult;
var
  kit: TPWebPackKit;
  id: TPWebPackIdentityInfo;
  refusal: TPWebCliPackRefusal;
  detail, full, dups: RawUtf8;
  outcome: TPWebCliProbeOutcome;
  duplicates: Integer;

  function Fail(R: TPWebCliPackRefusal;
    const D: RawUtf8): TPWebCliPackResult;
  begin
    Result := Default(TPWebCliPackResult);
    Result.Profile := PWebCliProfileText(Profile);
    Result.Refusal := R;
    Result.Cause := PWebCliPackRefusalText(R);
    Result.Detail := D;
  end;

begin
  Result := Default(TPWebCliPackResult);
  Result.Profile := PWebCliProfileText(Profile);
  if Profile = ppfNone then
    exit;
  if not PWebCliProfileForTarget(Profile, Os) then
  begin
    Result := Fail(pkrProfileNotForTarget, PWebCliProfilesForTarget(Os));
    exit;
  end;
  if not DeriveIdentity(Project, Os, Profile, id, refusal, detail) then
  begin
    Result := Fail(refusal, detail);
    exit;
  end;
  // the paths this run will hand ISCC are built under the project root, so
  // the root itself is checked HERE - before the pipeline, like every other
  // preflight refusal, and on every target so the rule is not a Windows
  // special case a POSIX reader has to discover
  if not PWebCliPackStagingPathAcceptable(PWebCliDisplayPath(Project.Root)) then
  begin
    Result := Fail(pkrIdentityRefused, 'project_path');
    exit;
  end;
  if not ResolveKit(Os, kit, refusal, detail) then
  begin
    Result := Fail(refusal, detail);
    exit;
  end;
  if Os <> pcoWindows then
    // the POSIX archive needs no external tool at all: the writer is
    // pweb.cli.tar and the compressor is mORMot. There is nothing left to
    // preflight, which is the point of choosing that writer
    exit;
  if not VerifyIscc(kit.Iscc, kit.IsccStamp, refusal, detail) then
  begin
    Result := Fail(refusal, detail);
    exit;
  end;
  // the compiled setup helper every Windows profile embeds
  if not KitStep(kit.BinDir, PWEB_PACK_HELPER_PROV, False, full) then
  begin
    Result := Fail(pkrKitMissing, PWEB_PACK_HELPER_PROV);
    exit;
  end;
  case Profile of
    ppfNormal:
      if not VerifyPinned(kit.Wv2Dir, PWEB_PACK_WV2_BOOTSTRAPPER,
           PWEB_PACK_WV2_BOOTSTRAPPER_SHA, PWEB_PACK_WV2_BOOTSTRAPPER_BYTES,
           full, refusal) then
      begin
        Result := Fail(refusal, PWEB_PACK_WV2_BOOTSTRAPPER);
        exit;
      end;
    ppfOffline:
      if not VerifyPinned(kit.Wv2Dir, PWEB_PACK_WV2_STANDALONE,
           PWEB_PACK_WV2_STANDALONE_SHA, PWEB_PACK_WV2_STANDALONE_BYTES,
           full, refusal) then
      begin
        Result := Fail(refusal, PWEB_PACK_WV2_STANDALONE);
        exit;
      end;
    ppfFixedRuntime:
      begin
        if not VerifyPinned(kit.Wv2Dir, PWEB_PACK_WV2_FIXED_CAB,
             PWEB_PACK_WV2_FIXED_SHA, PWEB_PACK_WV2_FIXED_BYTES, full,
             refusal) then
        begin
          Result := Fail(refusal, PWEB_PACK_WV2_FIXED_CAB);
          exit;
        end;
        if not VerifyPinned(kit.LibDir, PWEB_PACK_WV2_LOADER,
             PWEB_PACK_WV2_LOADER_SHA, PWEB_PACK_WV2_LOADER_BYTES, full,
             refusal) then
        begin
          Result := Fail(refusal, PWEB_PACK_WV2_LOADER);
          exit;
        end;
        if not KitStep(kit.BinDir, PWEB_PACK_HELPER_FIXED, False, full) then
        begin
          Result := Fail(pkrKitMissing, PWEB_PACK_HELPER_FIXED);
          exit;
        end;
        // THE CABINET EXPANDER, FROM THE SYSTEM DIRECTORY AND NOT FROM
        // PATH. MEASURED: `expand` on a developer machine resolves to Git
        // for Windows' GNU coreutils `expand.exe` - the tab expander -
        // because its usr/bin precedes System32, and the cabinet tool never
        // runs at all. The CAP-10A resolver is for TOOLCHAIN tools a
        // developer installs and may legitimately shadow; an OS component
        // is not one of them
        if not ResolveExpand(dups) then
        begin
          Result := Fail(pkrExpandMissing, PWEB_PACK_TOOL_EXPAND);
          exit;
        end;
        // the ceiling, BEFORE the pipeline: a ten-minute build that ends in
        // an opaque Windows error is the outcome this refusal exists to
        // replace
        if Length(PWebCliDisplayPath(Project.Root)) >
             FixedRootBound(Project, PWebCliRunTargetName(Os, Arch)) then
        begin
          Result := Fail(pkrFixedRootTooLong,
            PackIntText(Length(PWebCliDisplayPath(Project.Root))));
          exit;
        end;
      end;
  end;
end;


{ ---------------------------------------------------------------------------
  THE RUN
  --------------------------------------------------------------------------- }

type
  /// the sink context, the pipeline's shape reused so a forwarded packaging
  // line and a forwarded stage line are indistinguishable to a reader
  TPackContext = record
    Notify: TPWebCliPipeNotify;
    Opaque: Pointer;
    Prefix: RawUtf8;
  end;
  PPackContext = ^TPackContext;

procedure PackSink(Opaque: Pointer; Stream: TPWebCliChildStream;
  const Line: RawUtf8; Truncated: Boolean);
var
  ctx: PPackContext;
  text: RawUtf8;
begin
  ctx := PPackContext(Opaque);
  if (ctx = nil) or
     not Assigned(ctx^.Notify) then
    exit;
  text := ctx^.Prefix + Line;
  if Truncated then
    text := text + ' [truncated]';
  ctx^.Notify(ctx^.Opaque, text, {FromChild=}True);
end;

procedure PackSay(Notify: TPWebCliPipeNotify; Opaque: Pointer;
  const Line: RawUtf8);
begin
  if Assigned(Notify) then
    Notify(Opaque, 'pweb: ' + Line, {FromChild=}False);
end;

// one JSON string value, escaped by the two rules a schema-1 value can
// possibly need. Every field written here is a filename, a profile name or
// a lowercase hex digest, so the alphabet is already narrow; the escape
// exists so the writer is correct rather than merely correct today
function JsonText(const Value: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := '"';
  for i := 1 to Length(Value) do
    if (Value[i] = '"') or
       (Value[i] = '\') then
      Result := Result + '\' + Value[i]
    else
      Result := Result + Value[i];
  Result := Result + '"';
end;

// the CAP-6b4 release index, in the shape tools/build-windows-profiles.ps1
// froze as schema 1 and deliberately kept minimal - profile, filename,
// bytes, sha256 and nothing else. No path, no version, no timestamp and no
// build metadata: anything richer would be a private tool's interface
// leaking into the one artifact a consumer is meant to read
function IndexDocument(const Profile, FileName, Sha: RawUtf8;
  Bytes: Int64): RawUtf8;
begin
  Result :=
    '{'#10 +
    '  "schema": ' + PackIntText(PWEB_PACK_INDEX_SCHEMA) + ','#10 +
    '  "profiles": ['#10 +
    '    {'#10 +
    '      "profile": ' + JsonText(Profile) + ','#10 +
    '      "filename": ' + JsonText(FileName) + ','#10 +
    '      "bytes": ' + PackIntText(Bytes) + ','#10 +
    '      "sha256": ' + JsonText(Sha) + #10 +
    '    }'#10 +
    '  ]'#10 +
    '}'#10;
end;

// the release tree, as tar entries: every regular file with its content and
// its real execute bit, plus an explicit directory entry for every level.
// Explicit directories rather than implied ones, because an implied
// directory's mode is whatever the extracting tar decides and a .app whose
// Contents/MacOS arrived at 0700 is a bundle nobody else can launch
function CollectRelease(const Root, Stem: RawUtf8;
  var Entries: TPWebTarEntries; out Refusal: TPWebCliStageRefusal): Boolean;

  function Walk(const Dir, Logical: RawUtf8; Depth: Integer): Boolean;
  var
    names: TRawUtf8DynArray;
    i: PtrInt;
    full, rel: RawUtf8;
    kind: TPWebCliNodeKind;
    content: RawByteString;
    tooBig: Boolean;
  begin
    Walk := False;
    if Depth > PWEB_CLI_PIPE_MAX_TREE_DEPTH then
    begin
      Refusal := pstTreeTooLarge;
      exit;
    end;
    if not PWebCliListDir(Dir, names) then
    begin
      Refusal := pstSourceUnreadable;
      exit;
    end;
    PWebCliSortBytewise(names);
    for i := 0 to High(names) do
    begin
      full := PWebCliJoin(Dir, names[i]);
      rel := Logical + '/' + names[i];
      kind := PWebCliNodeKind(full);
      if Length(Entries) >= PWEB_CLI_PIPE_MAX_TREE_FILES then
      begin
        Refusal := pstTreeTooLarge;
        exit;
      end;
      SetLength(Entries, Length(Entries) + 1);
      Entries[High(Entries)].Name := rel;
      case kind of
        pcnDirectory:
          begin
            Entries[High(Entries)].Directory := True;
            Entries[High(Entries)].Executable := True;
            if not Walk(full, rel, Depth + 1) then
              exit;
          end;
        pcnFile:
          begin
            if not PWebCliReadSmallFile(full, PWEB_CLI_PIPE_MAX_FILE_BYTES,
                 content, tooBig) then
            begin
              if tooBig then
                Refusal := pstSourceTooBig
              else
                Refusal := pstSourceMissing;
              exit;
            end;
            Entries[High(Entries)].Content := content;
            Entries[High(Entries)].Executable := PWebCliExecutableBit(full);
          end;
      else
        // a link or a device in a release the CAP-10C0 resolver accepted is
        // an invariant failure, not something to archive
        Refusal := pstSourceMissing;
        exit;
      end;
    end;
    Walk := True;
  end;

begin
  Refusal := pstNone;
  Entries := nil;
  // the single top-level directory, so an extraction can never scatter a
  // release into somebody's current directory
  SetLength(Entries, 1);
  Entries[0].Name := Stem;
  Entries[0].Directory := True;
  Entries[0].Executable := True;
  Result := Walk(Root, Stem, 1);
end;

function PWebCliRunPackage(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; Profile: TPWebCliProfile;
  Notify: TPWebCliPipeNotify; Opaque: Pointer): TPWebCliPackResult;
var
  res: TPWebCliPackResult;
  ctx: TPackContext;
  kit: TPWebPackKit;
  id: TPWebPackIdentityInfo;
  refusal: TPWebCliPackRefusal;
  stageRefusal: TPWebCliStageRefusal;
  tarRefusal: TPWebTarRefusal;
  detail, target, outputDir, targetDir, releaseDir: RawUtf8;
  stageDir, payloadDir, runtimeDir, outDir, distDir, profileDir: RawUtf8;
  installer, helper, aclHelper, loader, pinned, issFile, expandExe: RawUtf8;
  stem, fileName, artifact, sha, treeBefore, treeAfter: RawUtf8;
  releaseBefore, releaseAfter: RawUtf8;
  excludes: TRawUtf8DynArray;
  prefixes, tokens: TRawUtf8DynArray;
  entries: TPWebTarEntries;
  cmd: TPWebCliCommand;
  raw, gz, content: RawByteString;
  bytes: Int64;
  tooBig, hadOld: Boolean;
  duplicates: Integer;

  function Fail(R: TPWebCliPackRefusal; const D: RawUtf8): Boolean;
  begin
    res.Refusal := R;
    res.Cause := PWebCliPackRefusalText(R);
    res.Detail := D;
    res.ArtifactLogical := '';
    res.IndexLogical := '';
    PackSay(Notify, Opaque, 'package: FAILED ' + res.Cause + ' ' + D);
    // whatever was staged is reclaimed: a failed packaging run leaves no
    // half-written directory anywhere, and never touches the artifacts a
    // previous one committed
    if (targetDir <> '') and (stageDir <> '') then
      PWebCliPipeRemoveTree(targetDir, PWEB_PACK_STAGE, stageRefusal);
    Fail := False;
  end;

  // one packaging child, through THE engine, in the supervise profile -
  // the same sink, the same installed stop handler, the same descendant
  // drain and the same typed outcome mapping every pipeline stage gets
  function RunChild(const Cmd: TPWebCliCommand; TimeoutMs: Cardinal;
    const What: RawUtf8): Boolean;
  var
    spec: TPWebCliExecSpec;
    r: TPWebCliExecResult;
    a: PtrInt;
  begin
    RunChild := False;
    // the CAP-10C1 argument-form invariant, restated where it cannot be
    // forgotten: this CLI canonicalizes Windows paths into the extended
    // form and pweb.cli.platform strips it for the executable, argv[0] and
    // the working directory - never for the other arguments, which are the
    // caller's. A vector still carrying it is an invariant failure
    for a := 0 to High(Cmd.Args) do
      if Copy(Cmd.Args[a], 1, 4) = '\\?\' then
      begin
        Fail(pkrStage, 'arg_longpath_form');
        exit;
      end;
    ctx.Prefix := What + '| ';
    PackSay(Notify, Opaque, What + ': ' +
      PWebCliCommandText(Cmd, prefixes, tokens));
    spec := Default(TPWebCliExecSpec);
    spec.ExePath := Cmd.Exe;
    spec.Args := Cmd.Args;
    spec.WorkDir := Cmd.WorkDir;
    spec.Profile := pepSupervise;
    spec.TimeoutMs := TimeoutMs;
    spec.Sink := @PackSink;
    spec.StopCheck := nil;    // the installed console / signal handler
    spec.Opaque := @ctx;
    spec.TreeRoot := PWebCliDisplayPath(Cmd.WorkDir);
    r := PWebCliExecute(spec);
    res.Outcome := r.Outcome;
    res.ExitCode := r.ExitCode;
    res.Signal := r.Signal;
    if r.StopRequested then
      res.Interrupted := True;
    if (r.Outcome = pcoExited) and
       (r.ExitCode = 0) then
    begin
      RunChild := True;
      exit;
    end;
    if res.Interrupted then
      Fail(pkrInterrupted, What)
    else
      Fail(pkrChildFailed, What + ':' + PWebCliChildOutcomeText(r.Outcome));
  end;

  // a define, in the exact `/DNAME=value` form ISCC reads. It is ONE argv
  // element: there is no shell anywhere on this path, so nothing quotes,
  // splits or re-interprets it
  procedure Define(var Cmd: TPWebCliCommand; const Name, Value: RawUtf8);
  begin
    SetLength(Cmd.Args, Length(Cmd.Args) + 1);
    Cmd.Args[High(Cmd.Args)] := '/D' + Name + '=' + Value;
  end;

  function StageFile(const FromPath, ToDir, ToName: RawUtf8): Boolean;
  begin
    StageFile := PWebCliPipeCopyFile(FromPath, PWebCliJoin(ToDir, ToName),
      stageRefusal);
    if not StageFile then
      Fail(pkrStage, ToName);
  end;

  // THE ARGUMENT VECTOR ISCC IS GIVEN. Every element is one argv entry -
  // there is no shell, no response file and no command string anywhere on
  // this path, so there is no grammar for a value to escape from. Each
  // define is either a pinned constant or a descriptor value that
  // DeriveIdentity has already refused if it carried an Inno metacharacter
  procedure BuildIscc;
  begin
    cmd := Default(TPWebCliCommand);
    cmd.Exe := kit.Iscc;
    cmd.WorkDir := kit.SetupDir;
    Define(cmd, 'PWEB_PAYLOAD_DIR', PWebCliArgPath(payloadDir));
    // the second half of the staging-path rule, at the point of use: the
    // preflight checked the project ROOT, and these are the paths actually
    // handed to the compiler
    if not PWebCliPackStagingPathAcceptable(PWebCliArgPath(payloadDir)) or
       not PWebCliPackStagingPathAcceptable(PWebCliArgPath(outDir)) or
       ((Profile = ppfFixedRuntime) and
        not PWebCliPackStagingPathAcceptable(PWebCliArgPath(runtimeDir))) then
    begin
      Fail(pkrIdentityRefused, 'staging_path');
      cmd := Default(TPWebCliCommand);
      exit;
    end;
    Define(cmd, 'PWEB_APP_ID', id.AppId);
    Define(cmd, 'PWEB_APP_NAME', id.AppName);
    Define(cmd, 'PWEB_APP_VERSION', id.AppVersion);
    Define(cmd, 'PWEB_INSTALL_VENDOR', id.Vendor);
    Define(cmd, 'PWEB_INSTALL_APP', id.App);
    Define(cmd, 'PWEB_MARKER_KEY', id.MarkerKey);
    Define(cmd, 'PWEB_SETUP_BASENAME', id.SetupBasename);
    Define(cmd, 'PWEB_APP_EXE', id.ExeName);
    Define(cmd, 'PWEB_APP_BUNDLE', PWEB_CLI_RUN_BUNDLE);
    Define(cmd, 'PWEB_APP_LIB', id.LibName);
    case Profile of
      ppfNormal:
        begin
          Define(cmd, 'PWEB_WV2_BOOTSTRAPPER', PWEB_PACK_WV2_BOOTSTRAPPER);
          Define(cmd, 'PWEB_WV2_SHA256', PWEB_PACK_WV2_BOOTSTRAPPER_SHA);
        end;
      ppfOffline:
        begin
          Define(cmd, 'PWEB_WV2_STANDALONE', PWEB_PACK_WV2_STANDALONE);
          Define(cmd, 'PWEB_WV2_SHA256', PWEB_PACK_WV2_STANDALONE_SHA);
        end;
      ppfFixedRuntime:
        begin
          Define(cmd, 'PWEB_RUNTIME_DIR', PWebCliArgPath(runtimeDir));
          Define(cmd, 'PWEB_FIXED_TREE', PWEB_PACK_WV2_FIXED_TREE);
          Define(cmd, 'PWEB_FIXED_SUBJECT', PWEB_PACK_WV2_SUBJECT);
          // the two overrides CAP-6b3 ratified, and for its reason: the
          // ratified normal/offline settings turn a ~690 MB tree into an
          // unbounded wall-clock cost. Only a profile that explicitly
          // overrides them gets anything but the historical values
          Define(cmd, 'PWEB_COMPRESSION', 'lzma2/fast');
          Define(cmd, 'PWEB_SOLID', 'no');
        end;
    end;
    if Profile <> ppfFixedRuntime then
    begin
      Define(cmd, 'PWEB_WV2_SUBJECT', PWEB_PACK_WV2_SUBJECT);
      Define(cmd, 'PWEB_WV2_TIMEOUT_MS', PackIntText(PWEB_PACK_WV2_TIMEOUT_MS));
    end;
    SetLength(cmd.Args, Length(cmd.Args) + 2);
    cmd.Args[High(cmd.Args) - 1] := '/O' + PWebCliArgPath(outDir);
    cmd.Args[High(cmd.Args)] := issFile;
  end;

begin
  res := Default(TPWebCliPackResult);
  res.Profile := PWebCliProfileText(Profile);
  Result := res;
  stageDir := '';
  targetDir := '';
  if Profile = ppfNone then
    exit;
  ctx.Notify := Notify;
  ctx.Opaque := Opaque;
  ctx.Prefix := '';
  target := PWebCliRunTargetName(Os, Arch);

  if not PWebCliProfileForTarget(Profile, Os) then
  begin
    Fail(pkrProfileNotForTarget, PWebCliProfilesForTarget(Os));
    Result := res;
    exit;
  end;
  if not DeriveIdentity(Project, Os, Profile, id, refusal, detail) then
  begin
    Fail(refusal, detail);
    Result := res;
    exit;
  end;
  if not ResolveKit(Os, kit, refusal, detail) then
  begin
    Fail(refusal, detail);
    Result := res;
    exit;
  end;

  // the two trees this run must not change, digested BEFORE anything is
  // written. The release is the input it is packaging and the project minus
  // its four writable prefixes is the invariant every stage already keeps
  outputDir := Project.OutputPath.Full;
  targetDir := PWebCliJoin(outputDir, target);
  releaseDir := PWebCliJoin(targetDir, PWEB_CLI_RUN_RELEASE);
  if PWebCliNodeKind(releaseDir) <> pcnDirectory then
  begin
    Fail(pkrStage, PWEB_CLI_RUN_RELEASE);
    Result := res;
    exit;
  end;
  if not PWebCliPipeTreeDigest(releaseDir, nil, releaseBefore,
       stageRefusal) then
  begin
    Fail(pkrStage, PWEB_CLI_RUN_RELEASE);
    Result := res;
    exit;
  end;
  excludes := PWebCliMutationSet(Project);
  if not PWebCliPipeTreeDigest(Project.Root, excludes, treeBefore,
       stageRefusal) then
  begin
    Fail(pkrStage, 'project_tree');
    Result := res;
    exit;
  end;
  // the recorded vocabulary: the two absolute roots this run can name, and
  // the logical token each becomes. Longest first, so a nested root can
  // never be masked by its parent
  SetLength(prefixes, 2);
  SetLength(tokens, 2);
  prefixes[0] := PWebCliDisplayPath(Project.Root);
  tokens[0] := '<project>';
  prefixes[1] := PWebCliDisplayPath(kit.Root);
  tokens[1] := '<sdk>';

  PackSay(Notify, Opaque, 'package: start ' + res.Profile);

  // a fresh staging sibling under <output>/<target>, dot-leading exactly as
  // the release layout's two are
  if not PWebCliPipeRemoveTree(targetDir, PWEB_PACK_STAGE, stageRefusal) or
     not PWebCliPipeEnsureDir(targetDir, PWEB_PACK_STAGE, stageDir,
       stageRefusal) or
     not PWebCliPipeEnsureDir(stageDir, 'out', outDir, stageRefusal) then
  begin
    Fail(pkrStage, PWEB_PACK_STAGE);
    Result := res;
    exit;
  end;

  if Os = pcoWindows then
  begin
    { --- the three CAP-13 profiles, for a generated application --------- }
    if not PWebCliPipeEnsureDir(stageDir, 'payload', payloadDir,
         stageRefusal) then
    begin
      Fail(pkrStage, 'payload');
      Result := res;
      exit;
    end;
    // the release triple, unchanged bytes: what the installer embeds is
    // exactly what `pweb run` would launch
    if not StageFile(PWebCliJoin(releaseDir, id.ExeName), payloadDir,
         id.ExeName) or
       not StageFile(PWebCliJoin(releaseDir, PWEB_CLI_RUN_BUNDLE),
         payloadDir, PWEB_CLI_RUN_BUNDLE) or
       not StageFile(PWebCliJoin(releaseDir, id.LibName), payloadDir,
         id.LibName) then
    begin
      Result := res;
      exit;
    end;
    if not KitStep(kit.BinDir, PWEB_PACK_HELPER_PROV, False, helper) then
    begin
      Fail(pkrKitMissing, PWEB_PACK_HELPER_PROV);
      Result := res;
      exit;
    end;
    if not StageFile(helper, payloadDir, PWEB_PACK_HELPER_PROV) then
    begin
      Result := res;
      exit;
    end;

    installer := '';
    case Profile of
      ppfNormal:
        begin
          if not VerifyPinned(kit.Wv2Dir, PWEB_PACK_WV2_BOOTSTRAPPER,
               PWEB_PACK_WV2_BOOTSTRAPPER_SHA,
               PWEB_PACK_WV2_BOOTSTRAPPER_BYTES, pinned, refusal) then
          begin
            Fail(refusal, PWEB_PACK_WV2_BOOTSTRAPPER);
            Result := res;
            exit;
          end;
          installer := PWEB_PACK_WV2_BOOTSTRAPPER;
          issFile := PWEB_PACK_ISS_NORMAL;
        end;
      ppfOffline:
        begin
          if not VerifyPinned(kit.Wv2Dir, PWEB_PACK_WV2_STANDALONE,
               PWEB_PACK_WV2_STANDALONE_SHA, PWEB_PACK_WV2_STANDALONE_BYTES,
               pinned, refusal) then
          begin
            Fail(refusal, PWEB_PACK_WV2_STANDALONE);
            Result := res;
            exit;
          end;
          installer := PWEB_PACK_WV2_STANDALONE;
          issFile := PWEB_PACK_ISS_OFFLINE;
        end;
      ppfFixedRuntime:
        begin
          if not VerifyPinned(kit.Wv2Dir, PWEB_PACK_WV2_FIXED_CAB,
               PWEB_PACK_WV2_FIXED_SHA, PWEB_PACK_WV2_FIXED_BYTES, pinned,
               refusal) then
          begin
            Fail(refusal, PWEB_PACK_WV2_FIXED_CAB);
            Result := res;
            exit;
          end;
          issFile := PWEB_PACK_ISS_FIXED;
        end;
    end;
    if installer <> '' then
      if not StageFile(PWebCliJoin(kit.Wv2Dir, installer), payloadDir,
           installer) then
      begin
        Result := res;
        exit;
      end;

    if Profile = ppfFixedRuntime then
    begin
      // the ACL helper the verdict gate runs, and the bundled runtime tree
      if not KitStep(kit.BinDir, PWEB_PACK_HELPER_FIXED, False,
           aclHelper) or
         not StageFile(aclHelper, payloadDir, PWEB_PACK_HELPER_FIXED) then
      begin
        if res.Refusal = pkrNone then
          Fail(pkrKitMissing, PWEB_PACK_HELPER_FIXED);
        Result := res;
        exit;
      end;
      if not PWebCliPipeEnsureDir(stageDir, PWEB_PACK_RUNTIME, runtimeDir,
           stageRefusal) then
      begin
        Fail(pkrStage, PWEB_PACK_RUNTIME);
        Result := res;
        exit;
      end;
      if not ResolveExpand(expandExe) then
      begin
        Fail(pkrExpandMissing, PWEB_PACK_TOOL_EXPAND);
        Result := res;
        exit;
      end;
      // EXPANDED FROM BYTES ALREADY VERIFIED. VerifyPinned above hashed the
      // cabinet byte-exactly against the pin, and expanding a cabinet is
      // deterministic - so the tree that lands is the ratified tree, and the
      // build-time signer axis CAP-6b3's script applies (to a cabinet it had
      // just re-fetched) would be re-deriving what the digest settled. The
      // axis that protects a USER is the one over the DEPLOYED bytes, and
      // that is the unchanged FixedRuntimeGate inside the installer
      cmd := Default(TPWebCliCommand);
      cmd.Exe := expandExe;
      SetLength(cmd.Args, 3);
      cmd.Args[0] := '-F:*';
      cmd.Args[1] := PWebCliArgPath(pinned);
      cmd.Args[2] := PWebCliArgPath(runtimeDir);
      cmd.WorkDir := stageDir;
      if not RunChild(cmd, PWEB_PACK_EXPAND_MS, 'expand') then
      begin
        Result := res;
        exit;
      end;
      if PWebCliEntry(runtimeDir, PWEB_PACK_WV2_FIXED_TREE) <>
           pcnDirectory then
      begin
        Fail(pkrArtifactMissing, PWEB_PACK_WV2_FIXED_TREE);
        Result := res;
        exit;
      end;
      // the Fixed Runtime package ships no loader; the pinned SDK's one
      // goes INSIDE the tree root so the application can only ever load it
      // by absolute path, never by DLL search order
      if not KitStep(kit.LibDir, PWEB_PACK_WV2_LOADER, False, loader) or
         not StageFile(loader, runtimeDir, PWEB_PACK_WV2_LOADER) then
      begin
        if res.Refusal = pkrNone then
          Fail(pkrKitMissing, PWEB_PACK_WV2_LOADER);
        Result := res;
        exit;
      end;
    end;

    fileName := id.SetupBasename + PWEB_CLI_RUN_WINDOWS_EXT;
    BuildIscc;
    if not RunChild(cmd, PWEB_PACK_ISCC_MS, 'iscc') then
    begin
      Result := res;
      exit;
    end;
  end
  else
  begin
    { --- the POSIX archive --------------------------------------------- }
    stem := PWebTarStem(Project.Name, Project.Version, target);
    fileName := stem + '.tar.gz';
    if not CollectRelease(releaseDir, stem, entries, stageRefusal) then
    begin
      Fail(pkrStage, PWebCliStageRefusalText(stageRefusal));
      Result := res;
      exit;
    end;
    PWebTarSort(entries);
    if not PWebTarWrite(entries, raw, tarRefusal) or
       not PWebTarGzip(raw, gz) then
    begin
      if tarRefusal = patNone then
        tarRefusal := patCompress;
      Fail(pkrArchive, PWebTarRefusalText(tarRefusal));
      Result := res;
      exit;
    end;
    if not PWebCliWriteNewFile(PWebCliJoin(outDir, fileName), gz,
         {SetExecBit=}False) then
    begin
      Fail(pkrStage, fileName);
      Result := res;
      exit;
    end;
    PackSay(Notify, Opaque, 'archive: ' + PackIntText(Length(entries)) +
      ' entries, ' + PackIntText(Length(gz)) + ' bytes');
  end;

  { --- measure what actually landed, then publish it ------------------- }
  artifact := PWebCliJoin(outDir, fileName);
  if not PWebCliReadSmallFile(artifact, PWEB_PACK_MAX_ARCHIVE_BYTES * 2,
       content, tooBig) then
  begin
    Fail(pkrArtifactMissing, fileName);
    Result := res;
    exit;
  end;
  bytes := Length(content);
  sha := LowerCaseU(Sha256(content));
  content := '';
  // PUBLISH ONLY WHAT THIS RUN PRODUCED - the CAP-6b4 rule, kept: the index
  // is written from the artifact this run just measured, never from
  // whatever happens to be on disk
  if not PWebCliWriteNewFile(PWebCliJoin(outDir, PWEB_PACK_INDEX),
       RawByteString(IndexDocument(res.Profile, fileName, sha, bytes)),
       {SetExecBit=}False) then
  begin
    Fail(pkrStage, PWEB_PACK_INDEX);
    Result := res;
    exit;
  end;

  // THE COMMIT, by the CAP-10D0 rule, unchanged: stage aside, rename,
  // reclaim. A rename that would replace an existing path is never used
  if not PWebCliPipeEnsureDir(targetDir, PWEB_PACK_ARTIFACTS, distDir,
       stageRefusal) then
  begin
    Fail(pkrStage, PWEB_PACK_ARTIFACTS);
    Result := res;
    exit;
  end;
  profileDir := PWebCliJoin(distDir, res.Profile);
  hadOld := PWebCliEntry(distDir, res.Profile) = pcnDirectory;
  if hadOld then
  begin
    if not PWebCliPipeRemoveTree(targetDir, PWEB_PACK_OLD, stageRefusal) or
       not PWebCliRenameDir(profileDir,
         PWebCliJoin(targetDir, PWEB_PACK_OLD)) then
    begin
      Fail(pkrCommit, PWEB_PACK_OLD);
      Result := res;
      exit;
    end;
  end;
  if not PWebCliRenameDir(outDir, profileDir) then
  begin
    // put the previous artifacts back rather than leave the project with
    // neither, exactly as the release commit does
    if hadOld then
      PWebCliRenameDir(PWebCliJoin(targetDir, PWEB_PACK_OLD), profileDir);
    Fail(pkrCommit, res.Profile);
    Result := res;
    exit;
  end;
  if hadOld then
    PWebCliPipeRemoveTree(targetDir, PWEB_PACK_OLD, stageRefusal);
  PWebCliPipeRemoveTree(targetDir, PWEB_PACK_STAGE, stageRefusal);

  { --- and the two trees this run promised not to change ---------------- }
  if not PWebCliPipeTreeDigest(releaseDir, nil, releaseAfter,
       stageRefusal) or
     (releaseAfter <> releaseBefore) then
  begin
    Fail(pkrReleaseAltered, PWEB_CLI_RUN_RELEASE);
    Result := res;
    exit;
  end;
  if not PWebCliPipeTreeDigest(Project.Root, excludes, treeAfter,
       stageRefusal) or
     (treeAfter <> treeBefore) then
  begin
    Fail(pkrMutation, 'project_tree');
    Result := res;
    exit;
  end;

  res.ArtifactLogical := Project.Output + '/' + target + '/' +
    PWEB_PACK_ARTIFACTS + '/' + res.Profile + '/' + fileName;
  res.IndexLogical := Project.Output + '/' + target + '/' + PWEB_PACK_ARTIFACTS +
    '/' + res.Profile + '/' + PWEB_PACK_INDEX;
  res.ArtifactBytes := bytes;
  res.ArtifactSha256 := sha;
  PackSay(Notify, Opaque, 'package: ok');
  Result := res;
end;

end.
