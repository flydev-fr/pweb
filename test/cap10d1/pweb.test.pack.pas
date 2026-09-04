{
  pweb.test.pack - the CAP-10D1 suite over `pweb build --profile`
  (mormot.core.test).

  Three subjects, one file, all four targets:

    PURE      the rules that are pure functions of their inputs - the
              profile allowlist and its per-target answer, the exit
              mapping packaging REUSES, the identity derivation and every
              metacharacter refusal, and the pinned table's own shape.

    ARCHIVE   THE DETERMINISTIC WRITER, measured rather than described:
              the ustar bytes for a known entry list, the modes, the
              absence of a timestamp anywhere, byte-equality across two
              writes - and the two REFUSED alternatives, measured rather
              than asserted, so the choice cannot decay into a preference.

    ROLLBACK  ledger item C1-11 (b). The `hadOld` rollback inside the
              layout's plrCommit refusal, reached through the test-only
              fault seam this shard adds, with the previous release
              required BACK IN PLACE and byte-identical afterwards.

  WHY THESE ARE HEADLESS AND STILL REAL. Not one of them needs a compiler, a
  display, a network or a pinned 212 MB artifact: the identity rules are
  arithmetic on a descriptor, the archive writer is a pure function, and the
  rollback is three renames over directories this suite creates. That is
  what lets a Linux runner assert the Windows AppId rule and the macOS
  bundle's archive modes, and what makes the four-target pack_digest a fact
  about the RULES rather than about four machines.

  What is NOT here, and belongs to the gate: the real `pweb build --profile`
  on a real generated project, the three real Inno Setup compiles, the real
  install/launch/uninstall, the extracted archive that answers 42, the
  network sampling, the real interrupt and the Windows long-path bisection.
  Those need real tools, a real signal and a real runner, and a suite that
  pretended to have them would be the vacuous measurement this repository
  refuses.

  It emits build/cap10d1/pack-corpus.txt: every DECISION this suite made,
  one LF line each, hashed into pack_digest and required equal on four
  targets. Anything legitimately platform-shaped goes to
  build/cap10d1/pack-observed.txt as key=value and is recorded per target,
  never compared.
}

{$I mormot.defines.inc}

unit pweb.test.pack;

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.zip,
  mormot.core.test,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.toolchain,
  pweb.cli.project,
  pweb.cli.run,
  pweb.cli.sdkroot,
  pweb.cli.stage,
  pweb.cli.native,
  pweb.cli.layout,
  pweb.cli.pipeline,
  pweb.cli.packpins,
  pweb.cli.tar,
  pweb.cli.package;

type
  TTestPWebPackPure = class(TSynTestCase)
  published
    procedure TheProfileAllowlistIsCompiledAndByteExact;
    procedure EachTargetHasItsOwnProfiles;
    procedure TheExitMappingIsTheSameSix;
    procedure TheIdentityRulesAreDeterministic;
    procedure AMetacharacterIsRefusedNeverEscaped;
    procedure TwoBundleIdsNeverCollide;
    procedure AStagingPathMetacharacterIsRefused;
    procedure ThePinnedTableCarriesNoUrl;
  end;

  TTestPWebPackArchive = class(TSynTestCase)
  published
    procedure TheUstarHeaderCarriesNoHostState;
    procedure ModesAreTheTwoRatifiedOnes;
    procedure TwoWritesAreByteIdentical;
    procedure ARefusedNameIsRefusedNotTruncated;
    procedure TheFrozenZipWriterCannotCarryModes;
  end;

  TTestPWebPackRollback = class(TSynTestCase)
  published
    procedure TheHadOldRollbackPutsThePreviousReleaseBack;
  end;

const
  PWEB_CAP10D1_CORPUS_FILE = 'build/cap10d1/pack-corpus.txt';
  PWEB_CAP10D1_OBSERVED_FILE = 'build/cap10d1/pack-observed.txt';
  PWEB_CAP10D1_FIXTURE = 'build/cap10d1/fixture';

/// write both evidence files
procedure PWebCap10d1Flush;


implementation

var
  Corpus: TRawUtf8DynArray;
  Observed: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

procedure Observe(const Key, Value: RawUtf8);
begin
  SetLength(Observed, Length(Observed) + 1);
  Observed[High(Observed)] := Key + '=' + Value;
end;

procedure PWebCap10d1Flush;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10D1 packaging decisions, one per line'#10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(ExpandFileName(PWEB_CAP10D1_CORPUS_FILE)));
  FileFromString(text, PWEB_CAP10D1_CORPUS_FILE);
  text := '';
  for i := 0 to High(Observed) do
    text := text + Observed[i] + #10;
  FileFromString(text, PWEB_CAP10D1_OBSERVED_FILE);
end;

function Bool(B: Boolean): RawUtf8;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

function IntText(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

// a descriptor with every schema-1 field set, so a case can move ONE value
// and measure what the identity rule does with it
function DescriptorWith(const Name, Version, BundleId: RawUtf8;
  const Root: RawUtf8): TPWebCliProject;
begin
  Result := Default(TPWebCliProject);
  Result.Refusal := pcrNone;
  Result.Root := Root;
  Result.Schema := PWEB_CLI_SCHEMA;
  Result.Name := Name;
  Result.Version := Version;
  Result.BundleId := BundleId;
  Result.Ui := puiPas2js;
  Result.NativeProgram := 'src/' + Name + '.lpr';
  Result.FrontendRoot := 'frontend';
  Result.Output := 'dist';
  Result.ProgramIdent := Name;
  Result.NativeProgramPath.Refusal := pprNone;
  Result.NativeProgramPath.Full :=
    PWebCliJoin(PWebCliJoin(Root, 'src'), Name + '.lpr');
  Result.FrontendRootPath.Refusal := pprNone;
  Result.FrontendRootPath.Full := PWebCliJoin(Root, 'frontend');
  Result.OutputPath.Refusal := pprNone;
  Result.OutputPath.Full := PWebCliJoin(Root, 'dist');
end;


{ ---------------------------------------------------------------------------
  the pure rules
  --------------------------------------------------------------------------- }

{ THE ALLOWLIST IS COMPILED AND BYTE-EXACT, exactly as --ui's is. `fixed` is
  refused like `msix`, and that is the whole point: `fixed-runtime` is the
  string written to a user's machine as the HKCU profile marker, and a CLI
  that accepted a shorter spelling would have two names for one mode. }
procedure TTestPWebPackPure.TheProfileAllowlistIsCompiledAndByteExact;
var
  p: TPWebCliProfile;
  names: RawUtf8;
begin
  Check(PWebCliParseProfile('normal', p) and (p = ppfNormal), 'normal');
  Check(PWebCliParseProfile('offline', p) and (p = ppfOffline), 'offline');
  Check(PWebCliParseProfile('fixed-runtime', p) and (p = ppfFixedRuntime),
    'fixed-runtime');
  Check(PWebCliParseProfile('archive', p) and (p = ppfArchive), 'archive');
  // every near miss, refused
  Check(not PWebCliParseProfile('fixed', p), 'fixed is not a profile name');
  Check(not PWebCliParseProfile('Normal', p), 'no case fold');
  Check(not PWebCliParseProfile('FIXED-RUNTIME', p), 'no case fold');
  Check(not PWebCliParseProfile('fixed_runtime', p), 'no separator fold');
  Check(not PWebCliParseProfile('archive ', p), 'no trim');
  Check(not PWebCliParseProfile('', p), 'no empty');
  Check(not PWebCliParseProfile('msix', p), 'no format this shard refuses');
  names := '';
  for p := Low(TPWebCliProfile) to High(TPWebCliProfile) do
    if p <> ppfNone then
    begin
      if names <> '' then
        names := names + ',';
      names := names + PWebCliProfileText(p);
    end;
  CheckEqual(names, 'normal,offline,fixed-runtime,archive',
    'the four ratified names, in order');
  Record_('profile|names|' + names);
  Check(ppfNone = Low(TPWebCliProfile), 'none is the zero ordinal');
  Record_('profile|none_is_zero_ordinal|true');
end;

{ The per-target answer is a separate question from the allowlist, and it is
  asked AFTER the line has parsed. That separation is why CAP-10D1 adds no
  usage cause: the parser is identical on four platforms, and the refusal a
  foreign profile earns is `profile_not_for_target`. }
procedure TTestPWebPackPure.EachTargetHasItsOwnProfiles;
begin
  CheckEqual(PWebCliProfilesForTarget(pcoWindows),
    'normal,offline,fixed-runtime', 'the three CAP-13 profiles');
  CheckEqual(PWebCliProfilesForTarget(pcoLinux), 'archive', 'linux');
  CheckEqual(PWebCliProfilesForTarget(pcoMacos), 'archive', 'macos');
  Record_('profile|windows|' + PWebCliProfilesForTarget(pcoWindows));
  Record_('profile|posix|' + PWebCliProfilesForTarget(pcoLinux));
  Check(PWebCliProfileForTarget(ppfNormal, pcoWindows), 'normal on windows');
  Check(not PWebCliProfileForTarget(ppfNormal, pcoLinux),
    'normal is not a linux profile');
  Check(not PWebCliProfileForTarget(ppfArchive, pcoWindows),
    'archive is not a windows profile');
  Check(PWebCliProfileForTarget(ppfArchive, pcoMacos), 'archive on macos');
  Record_('profile|cross_target_refused|true');
end;

{ Packaging answers with the SAME six categories, and this case is the
  freeze anchor: the day somebody proposes a seventh for "packaged with
  warnings", the corpus digest moves on four targets at once. }
procedure TTestPWebPackPure.TheExitMappingIsTheSameSix;
var
  r: TPWebCliPackRefusal;
  seen: RawUtf8;
  code: Integer;
begin
  CheckEqual(PWebCliPackExitCode(pkrNone), 0, 'packaged');
  CheckEqual(PWebCliPackExitCode(pkrProfileNotForTarget), 2, 'usage');
  CheckEqual(PWebCliPackExitCode(pkrIdentityRefused), 3, 'project');
  CheckEqual(PWebCliPackExitCode(pkrIdentityTooLong), 3, 'project');
  CheckEqual(PWebCliPackExitCode(pkrInputMissing), 4, 'cannot package');
  CheckEqual(PWebCliPackExitCode(pkrInputDigest), 4, 'cannot package');
  CheckEqual(PWebCliPackExitCode(pkrIsccIdentity), 4, 'cannot package');
  CheckEqual(PWebCliPackExitCode(pkrChildFailed), 5, 'a child failed');
  CheckEqual(PWebCliPackExitCode(pkrInterrupted), 5, 'stopped');
  CheckEqual(PWebCliPackExitCode(pkrMutation), 6, 'invariant');
  seen := '';
  for r := Low(TPWebCliPackRefusal) to High(TPWebCliPackRefusal) do
  begin
    code := PWebCliPackExitCode(r);
    Check((code >= 0) and (code <= 6) and (code <> 1),
      'every packaging refusal maps into the ratified six');
    if PosEx(',' + IntText(code) + ',', ',' + seen + ',') = 0 then
    begin
      if seen <> '' then
        seen := seen + ',';
      seen := seen + IntText(code);
    end;
  end;
  CheckEqual(seen, '0,2,3,4,6,5', 'the six categories and no seventh');
  Record_('pack_exit|categories|0,2,3,4,5,6');
  // every refusal has its own machine-stable text, and no two share one
  seen := '';
  for r := Low(TPWebCliPackRefusal) to High(TPWebCliPackRefusal) do
  begin
    Check(PWebCliPackRefusalText(r) <> 'pack_refused',
      'every refusal is named, none falls through');
    if seen <> '' then
      seen := seen + ',';
    seen := seen + PWebCliPackRefusalText(r);
  end;
  Record_('pack_exit|causes|' + seen);
end;

{ THE IDENTITY RULES, as arithmetic on a descriptor. Every value a Windows
  installer carries is derived here, on all four targets, so a Linux runner
  proves what a Windows AppId will be. }
procedure TTestPWebPackPure.TheIdentityRulesAreDeterministic;
var
  project: TPWebCliProject;
  id: TPWebPackIdentityInfo;
begin
  project := DescriptorWith('demo', '1.2.3', 'com.example.demo', '/p');
  Check(PWebCliPackIdentityOf(project, pcoWindows, ppfNormal, id),
    'the ordinary descriptor derives');
  CheckEqual(id.AppId, 'com.example.demo', 'AppId IS the bundleId');
  CheckEqual(id.AppName, 'demo', 'AppName is the descriptor name');
  CheckEqual(id.AppVersion, '1.2.3', 'AppVersion is the descriptor version');
  CheckEqual(id.Vendor, 'com.example', 'the vendor is everything up to the last dot');
  CheckEqual(id.App, 'demo', 'the app is the last label');
  CheckEqual(id.MarkerKey, 'Software\PWeb\Apps\com.example.demo',
    'one marker key per bundleId, in PWeb''s own namespace');
  CheckEqual(id.SetupBasename, 'demo-normal-setup', 'the artifact basename');
  CheckEqual(id.ExeName, 'demo.exe', 'the windows executable');
  Record_('identity|appid_rule|bundleid_literal');
  Record_('identity|marker|Software\PWeb\Apps\<bundleid>');
  Record_('identity|basename|<name>-<profile>-setup');
  // a five-label identifier still splits at the LAST dot, which is what
  // makes <vendor>\<app> a bijection rather than a heuristic
  project := DescriptorWith('notes', '0.1.0', 'io.github.acme.team.notes',
    '/p');
  Check(PWebCliPackIdentityOf(project, pcoWindows, ppfOffline, id),
    'five labels derive');
  CheckEqual(id.Vendor, 'io.github.acme.team', 'four labels of vendor');
  CheckEqual(id.App, 'notes', 'the last label');
  CheckEqual(id.SetupBasename, 'notes-offline-setup', 'the profile suffix');
  Record_('identity|five_label_split|io.github.acme.team+notes');
  // the POSIX side: no .exe, and the platform library name is the target's
  project := DescriptorWith('demo', '1.2.3', 'com.example.demo', '/p');
  Check(PWebCliPackIdentityOf(project, pcoLinux, ppfArchive, id), 'linux');
  CheckEqual(id.ExeName, 'demo', 'no extension on POSIX');
  Record_('identity|posix_exe|demo');
  // Inno's AppId ceiling is 127 and schema 1 allows 128: the ONE value that
  // can overflow is refused by name rather than truncated into somebody
  // else's identity
  project := DescriptorWith('demo', '1.2.3',
    'com.example.' + RawUtf8(StringOfChar('a', 116)), '/p');
  CheckEqual(Length(project.BundleId), 128, 'a schema-1 maximum bundleId');
  Check(not PWebCliPackIdentityOf(project, pcoWindows, ppfNormal, id),
    '128 characters exceeds Inno''s AppId ceiling');
  // and the one below it still derives, so the refusal is a CEILING rather
  // than an off-by-one that quietly rejects a legal descriptor
  project := DescriptorWith('demo', '1.2.3',
    'com.example.' + RawUtf8(StringOfChar('a', 115)), '/p');
  CheckEqual(Length(project.BundleId), 127, 'one below the ceiling');
  Check(PWebCliPackIdentityOf(project, pcoWindows, ppfNormal, id),
    '127 characters is Inno''s maximum and is accepted');
  Record_('identity|appid_max|127');
end;

{ REFUSED, NEVER ESCAPED. Schema 1's grammars already exclude every one of
  these, so this is defence in depth - and the reason it refuses rather than
  escaping is that an escaped identity is a DIFFERENT identity, and an
  installer that quietly installs a different application is worse than one
  that will not build. }
procedure TTestPWebPackPure.AMetacharacterIsRefusedNeverEscaped;
var
  id: TPWebPackIdentityInfo;
  i: PtrInt;
  refused: RawUtf8;

  function NameIsRefused(const Name: RawUtf8): Boolean;
  begin
    Result := not PWebCliPackIdentityOf(
      DescriptorWith(Name, '1.0.0', 'com.example.demo', '/p'),
      pcoWindows, ppfNormal, id);
  end;

begin
  refused := '';
  for i := 0 to 8 do
  begin
    Check(NameIsRefused('de' + RawUtf8(PWEB_PACK_FORBIDDEN[i]) + 'mo'),
      'a forbidden character in the display name is refused');
    if refused <> '' then
      refused := refused + ',';
    refused := refused + IntText(Ord(PWEB_PACK_FORBIDDEN[i]));
  end;
  CheckEqual(refused, '123,125,34,59,92,47,13,10,0',
    'the nine bytes an Inno define can never carry');
  Record_('identity|forbidden_bytes|' + refused);
  // and a control byte below space, which no schema-1 grammar admits either
  Check(NameIsRefused('de'#9'mo'), 'a tab is refused');
  Check(NameIsRefused('de'#1'mo'), 'a control byte is refused');
  Record_('identity|control_bytes_refused|true');
  // the CAP-6b4 ban, applied to the value this build would EMIT rather than
  // only to the manifest that validates it
  Check(not PWebCliPackIdentityOf(
    DescriptorWith('setup', '1.0.0', 'com.example.setup', '/p'),
    pcoWindows, ppfNormal, id) = False,
    'a project named `setup` still yields setup-normal-setup, which is not "setup"');
  Record_('identity|setup_basename_ban|emitted_value');
end;

{ THE COLLISION CLAIM, as arithmetic rather than as an install. Two
  descriptors differing ONLY in bundleId must differ in every identifier a
  machine keys on - which is what the hosted W4 leg then confirms by
  installing both at once. }
procedure TTestPWebPackPure.TwoBundleIdsNeverCollide;
var
  a, b: TPWebPackIdentityInfo;
begin
  Check(PWebCliPackIdentityOf(
    DescriptorWith('demo', '1.0.0', 'com.example.demo', '/p'),
    pcoWindows, ppfNormal, a), 'first');
  Check(PWebCliPackIdentityOf(
    DescriptorWith('demo', '1.0.0', 'org.other.demo', '/p'),
    pcoWindows, ppfNormal, b), 'second, same NAME');
  Check(a.AppId <> b.AppId, 'distinct AppId');
  Check(a.MarkerKey <> b.MarkerKey, 'distinct profile marker');
  Check((a.Vendor + '\' + a.App) <> (b.Vendor + '\' + b.App),
    'distinct install directory');
  // and the same bundleId derives the SAME identity, which is what makes a
  // rebuild replace itself rather than register a second product
  Check(PWebCliPackIdentityOf(
    DescriptorWith('demo', '9.9.9', 'com.example.demo', '/p'),
    pcoWindows, ppfNormal, b), 'same bundleId, later version');
  CheckEqual(a.AppId, b.AppId, 'the same bundleId is the same product');
  CheckEqual(a.MarkerKey, b.MarkerKey, 'and the same marker');
  Record_('identity|collision_free|true');
  Record_('identity|self_replacing|true');
end;

{ A PATH THIS CLI BUILT is checked like a descriptor value, because a
  DEVELOPER controls it. A Windows path may legally carry an Inno
  constant opener, and a define expanded into a [Files] Source would
  then put a CONSTANT where a directory name belongs. The separator and
  the drive colon are allowed - a path needs both - and the four bytes an
  Inno directive reads as syntax are not. Found by this shard's own
  adversarial review, before it shipped. }
procedure TTestPWebPackPure.AStagingPathMetacharacterIsRefused;
begin
  Check(PWebCliPackStagingPathAcceptable('C:\Users\dev\proj'),
    'an ordinary Windows path');
  Check(PWebCliPackStagingPathAcceptable('/home/dev/proj'),
    'an ordinary POSIX path');
  Check(PWebCliPackStagingPathAcceptable('C:\Users\dev one\proj'),
    'a path carrying a space');
  Check(not PWebCliPackStagingPathAcceptable('C:\my{dir}\proj'),
    'an Inno constant opener is refused');
  Check(not PWebCliPackStagingPathAcceptable('C:\my}dir\proj'),
    'and its closer');
  Check(not PWebCliPackStagingPathAcceptable('C:\my"dir\proj'),
    'a quote would end a define value');
  Check(not PWebCliPackStagingPathAcceptable('C:\my;dir\proj'),
    'a semicolon would start a comment');
  Check(not PWebCliPackStagingPathAcceptable('C:\my' + #13 + 'dir'),
    'a control byte would end a directive');
  Check(not PWebCliPackStagingPathAcceptable(''), 'and an empty path');
  Record_('identity|staging_path_refused|brace,quote,semicolon,control');
end;

{ THE PINNED TABLE, and the one thing it must never contain. A build path
  that cannot name a remote address cannot reach one, and that is a property
  of this file's contents rather than a promise. }
procedure TTestPWebPackPure.ThePinnedTableCarriesNoUrl;
begin
  CheckEqual(Length(PWEB_PACK_WV2_BOOTSTRAPPER_SHA), 64, 'a sha256');
  CheckEqual(Length(PWEB_PACK_WV2_STANDALONE_SHA), 64, 'a sha256');
  CheckEqual(Length(PWEB_PACK_WV2_FIXED_SHA), 64, 'a sha256');
  CheckEqual(Length(PWEB_PACK_WV2_LOADER_SHA), 64, 'a sha256');
  CheckEqual(Length(PWEB_PACK_ISCC_INSTALLER_SHA), 64, 'a sha256');
  Check(PWEB_PACK_WV2_BOOTSTRAPPER_BYTES > 0, 'a byte size');
  Check(PWEB_PACK_WV2_STANDALONE_BYTES > 0, 'a byte size');
  Check(PWEB_PACK_WV2_FIXED_BYTES > 0, 'a byte size');
  // the fixed tree name must be the version's own, or the expanded tree
  // would be looked for under a name Microsoft did not produce
  Check(PosEx(PWEB_PACK_WV2_FIXED_VERSION, PWEB_PACK_WV2_FIXED_TREE) > 0,
    'the tree name carries the pinned version');
  Check(PosEx(PWEB_PACK_WV2_FIXED_VERSION, PWEB_PACK_WV2_FIXED_CAB) > 0,
    'the cabinet name carries the pinned version');
  Record_('pins|sha_lengths|64');
  Record_('pins|fixed_version|' + PWEB_PACK_WV2_FIXED_VERSION);
  Record_('pins|iscc_version|' + PWEB_PACK_ISCC_VERSION);
  Record_('pins|timeout_ms|' + IntText(PWEB_PACK_WV2_TIMEOUT_MS));
end;


{ ---------------------------------------------------------------------------
  the deterministic archive writer
  --------------------------------------------------------------------------- }

// the fixture entry list: a macOS bundle's shape, which is the deepest and
// the only one with a directory below the top level
function BundleEntries: TPWebTarEntries;
begin
  Result := nil;
  SetLength(Result, 6);
  Result[0].Name := 'demo-1.0.0-macos-arm64';
  Result[0].Directory := True;
  Result[1].Name := 'demo-1.0.0-macos-arm64/demo.app';
  Result[1].Directory := True;
  Result[2].Name := 'demo-1.0.0-macos-arm64/demo.app/Contents';
  Result[2].Directory := True;
  Result[3].Name := 'demo-1.0.0-macos-arm64/demo.app/Contents/Info.plist';
  Result[3].Content := '<plist/>';
  Result[4].Name := 'demo-1.0.0-macos-arm64/demo.app/Contents/MacOS';
  Result[4].Directory := True;
  Result[5].Name := 'demo-1.0.0-macos-arm64/demo.app/Contents/MacOS/demo';
  Result[5].Content := 'MZ-not-really';
  Result[5].Executable := True;
end;

function OctalAt(const Data: RawByteString; Offset, Width: PtrInt): RawUtf8;
begin
  Result := Copy(Data, Offset + 1, Width - 1);
end;

{ EVERY FIELD THAT COULD CARRY HOST STATE, read back out of the bytes. mtime
  zero, uid and gid zero, uname and gname EMPTY - a login name is the most
  common way a "reproducible" archive quietly stops being one. }
procedure TTestPWebPackArchive.TheUstarHeaderCarriesNoHostState;
var
  entries: TPWebTarEntries;
  data: RawByteString;
  refusal: TPWebTarRefusal;
  i: PtrInt;
  allZero: Boolean;
begin
  entries := BundleEntries;
  PWebTarSort(entries);
  Check(PWebTarWrite(entries, data, refusal), 'the writer accepts a bundle');
  CheckEqual(Ord(refusal), Ord(patNone), 'no refusal');
  Check(Length(data) mod PWEB_TAR_BLOCK = 0, 'a whole number of blocks');
  CheckEqual(Copy(data, 258, 5), 'ustar', 'the ustar magic');
  CheckEqual(OctalAt(data, 108, 8), '0000000', 'uid is zero');
  CheckEqual(OctalAt(data, 116, 8), '0000000', 'gid is zero');
  CheckEqual(OctalAt(data, 136, 12), '00000000000', 'mtime is zero');
  allZero := True;
  for i := 266 to 329 do            // uname[32] then gname[32]
    if data[i] <> #0 then
      allZero := False;
  Check(allZero, 'uname and gname are empty');
  Record_('archive|mtime|0');
  Record_('archive|uid_gid|0');
  Record_('archive|uname_gname|empty');
  Record_('archive|magic|ustar');
  // the stream ends with two zero blocks, which is what makes it a tar
  allZero := True;
  for i := Length(data) - 2 * PWEB_TAR_BLOCK + 1 to Length(data) do
    if data[i] <> #0 then
      allZero := False;
  Check(allZero, 'two trailing zero blocks');
  Record_('archive|trailer|two_zero_blocks');
end;

{ TWO MODES AND NO OTHERS, and neither of them read from a filesystem: a
  developer's umask cannot reach a distributable artifact. }
procedure TTestPWebPackArchive.ModesAreTheTwoRatifiedOnes;
var
  entries: TPWebTarEntries;
  data: RawByteString;
  refusal: TPWebTarRefusal;
  block: PtrInt;
  modes, names: RawUtf8;
  i: PtrInt;
begin
  entries := BundleEntries;
  PWebTarSort(entries);
  Check(PWebTarWrite(entries, data, refusal), 'written');
  // walk the headers in order and read mode + typeflag out of each
  modes := '';
  names := '';
  block := 0;
  for i := 0 to High(entries) do
  begin
    modes := modes + OctalAt(data, block + 100, 8) + ':' +
      Copy(data, block + 157, 1) + ' ';
    names := names + Copy(data, block + 1, Length(entries[i].Name) + 1);
    Inc(block, PWEB_TAR_BLOCK);
    if not entries[i].Directory then
      Inc(block, ((Length(entries[i].Content) + PWEB_TAR_BLOCK - 1) div
        PWEB_TAR_BLOCK) * PWEB_TAR_BLOCK);
  end;
  CheckEqual(modes,
    '0000755:5 0000755:5 0000755:5 0000644:0 0000755:5 0000755:0 ',
    'directories and the program 0755, ordinary files 0644');
  Record_('archive|modes|dir_and_exec_0755_file_0644');
  // the SORT is bytewise and the writer trusts it: the entries come out in
  // the order a byte comparison puts them, which is the same order on four
  // targets and NOT the order a culture-aware comparer would produce
  CheckEqual(entries[0].Name, 'demo-1.0.0-macos-arm64', 'the top level first');
  CheckEqual(entries[High(entries)].Name,
    'demo-1.0.0-macos-arm64/demo.app/Contents/MacOS/demo', 'the deepest last');
  Record_('archive|order|bytewise');
end;

{ THE CLAIM THIS WRITER EXISTS FOR. Two writes of the same entry list
  produce the same bytes, through the ustar AND through the gzip - mORMot's
  GZHEAD is (GZ_MAGIC, 0, 0), so the container carries no timestamp and no
  stored filename either. }
procedure TTestPWebPackArchive.TwoWritesAreByteIdentical;
var
  entries: TPWebTarEntries;
  a, b, ga, gb: RawByteString;
  refusal: TPWebTarRefusal;
begin
  entries := BundleEntries;
  PWebTarSort(entries);
  Check(PWebTarWrite(entries, a, refusal), 'first write');
  Check(PWebTarWrite(entries, b, refusal), 'second write');
  CheckEqual(Sha256(a), Sha256(b), 'the ustar bytes are identical');
  Check(PWebTarGzip(a, ga), 'first gzip');
  Check(PWebTarGzip(b, gb), 'second gzip');
  CheckEqual(Sha256(ga), Sha256(gb), 'the gzip bytes are identical');
  Check(Length(ga) > 0, 'a non-empty archive');
  // the gzip header's MTIME field is bytes 5..8 and must be zero: that is
  // the one field a naive gzip puts the current time in
  CheckEqual(Copy(ga, 5, 4), #0#0#0#0, 'the gzip header carries no timestamp');
  Record_('archive|deterministic|true');
  Record_('archive|gzip_mtime|0');
  // recorded rather than compared: the compressed SIZE depends on which
  // deflate implementation mORMot bound on this host, which is a fact about
  // the machine and not about the rule
  Observe('archive_gzip_bytes', IntText(Length(ga)));
  Observe('archive_ustar_bytes', IntText(Length(a)));
end;

{ A NAME THAT DOES NOT FIT IS REFUSED, never truncated and never promoted to
  a GNU long-name entry: both of those embed either an implementation's
  choices or a second name for one file. }
procedure TTestPWebPackArchive.ARefusedNameIsRefusedNotTruncated;
var
  entries: TPWebTarEntries;
  data: RawByteString;
  refusal: TPWebTarRefusal;
begin
  SetLength(entries, 1);
  entries[0].Name := '../escape';
  Check(not PWebTarWrite(entries, data, refusal), 'a traversal is refused');
  CheckEqual(Ord(refusal), Ord(patName), 'named as a name refusal');
  entries[0].Name := '/absolute';
  Check(not PWebTarWrite(entries, data, refusal), 'an absolute name is refused');
  entries[0].Name := 'back\slash';
  Check(not PWebTarWrite(entries, data, refusal), 'a backslash is refused');
  entries[0].Name := '';
  Check(not PWebTarWrite(entries, data, refusal), 'an empty name is refused');
  SetLength(entries, 0);
  Check(not PWebTarWrite(entries, data, refusal), 'an empty archive is refused');
  CheckEqual(Ord(refusal), Ord(patEmpty), 'named as an empty refusal');
  // a duplicate, which a sorted list makes an immediate neighbour
  SetLength(entries, 2);
  entries[0].Name := 'a/b';
  entries[1].Name := 'a/b';
  Check(not PWebTarWrite(entries, data, refusal), 'a duplicate is refused');
  CheckEqual(Ord(refusal), Ord(patDuplicate), 'named as a duplicate');
  Record_('archive|refusals|name,empty,duplicate');
end;

{ THE MEASUREMENT BEHIND THE CHOICE, rather than the assertion. The frozen
  CAP-6 writer is mORMot's TZipWrite, whose external file attribute is the
  MS-DOS one: there is no Unix mode plane, so an extracted program would
  arrive without its execute bit. That is why this shard wrote a tar. }
procedure TTestPWebPackArchive.TheFrozenZipWriterCannotCarryModes;
var
  zip: TZipWrite;
  fn: TFileName;
  data: RawByteString;
  read: TZipRead;
  attr: Cardinal;
begin
  fn := TFileName(ExpandFileName(PWEB_CAP10D1_FIXTURE + '/modes.zip'));
  ForceDirectories(ExtractFilePath(fn));
  DeleteFile(fn);
  data := 'MZ-not-really';
  zip := TZipWrite.Create(fn);
  try
    zip.AddDeflated('program', pointer(data), Length(data));
  finally
    zip.Free;
  end;
  attr := 0;
  read := TZipRead.Create(fn);
  try
    CheckEqual(read.Count, 1, 'one entry');
    attr := read.Entry[0].dir^.extFileAttr;
  finally
    read.Free;
  end;
  // the high sixteen bits are where a Unix mode would live in a zip written
  // by Info-ZIP; mORMot writes MS-DOS attributes only, so they are zero and
  // an extracted program has no mode of its own
  CheckEqual(attr shr 16, 0,
    'the frozen ZIP writer carries no Unix mode plane');
  Record_('archive|zip_writer_mode_plane|absent');
  Record_('archive|writer_choice|ustar_gzip');
end;


{ ---------------------------------------------------------------------------
  ledger C1-11 (b): the hadOld rollback
  --------------------------------------------------------------------------- }

{ THE HALF CAP-10D0 COULD NOT REACH. Its suite seeded `release` as a FILE,
  which makes the committing rename fail - but only when there was no
  previous release to move aside, so `hadOld` was False and the rollback
  branch stayed unexercised. Reaching it needs the commit to fail AFTER the
  aside rename has succeeded, which is a fault nothing on a healthy
  filesystem produces.

  This is that fault, injected through the test-only seam CAP-10D1 adds to
  pweb.cli.layout, and the assertion is the one a user cares about: the
  previous release is BACK, in its own directory, byte-identical. }
procedure TTestPWebPackRollback.TheHadOldRollbackPutsThePreviousReleaseBack;
var
  parent, root, outDir, targetDir, inputs, exePath, bundlePath: RawUtf8;
  releaseDir, before, after: RawUtf8;
  project: TPWebCliProject;
  sdk: TPWebSdkLayout;
  stage: TPWebCliStageRefusal;
  first, second: TPWebCliLayoutResult;
  files: Integer;

  function Seed(const Mark: RawUtf8): Boolean;
  begin
    PWebCliDeleteFile(exePath);
    PWebCliDeleteFile(bundlePath);
    PWebCliDeleteFile(sdk.WebviewLib);
    Result := PWebCliWriteNewFile(exePath, RawByteString('exe-' + Mark),
                PWebCliHasFileModes) and
              PWebCliWriteNewFile(bundlePath, RawByteString('pwb-' + Mark),
                False) and
              PWebCliWriteNewFile(sdk.WebviewLib, RawByteString('lib-' + Mark),
                False);
  end;

begin
  ForceDirectories(ExpandFileName(PWEB_CAP10D1_FIXTURE));
  Check(PWebCliCanonicalDir(RawUtf8(ExpandFileName(PWEB_CAP10D1_FIXTURE)),
    parent), 'the fixture parent');
  Check(PWebCliPipeRemoveTree(parent, 'rollback', stage), 'reclaimed');
  Check(PWebCliPipeEnsureDir(parent, 'rollback', root, stage), 'created');
  project := DescriptorWith('demo', '0.1.0', 'com.example.demo', root);
  Check(PWebCliPipeEnsureDir(root, 'dist', outDir, stage), 'dist');
  Check(PWebCliPipeEnsureDir(outDir,
    PWebCliRunTargetName(PWebCliHostOs, PWebCliHostArch), targetDir, stage),
    'the target directory');
  Check(PWebCliPipeEnsureDir(root, 'inputs', inputs, stage), 'inputs');
  exePath := PWebCliJoin(inputs,
    PWebCliNativeExeName('demo', PWebCliHostOs));
  bundlePath := PWebCliJoin(inputs, PWEB_CLI_RUN_BUNDLE);
  sdk := Default(TPWebSdkLayout);
  sdk.WebviewLib := PWebCliJoin(inputs,
    PWebCliWebviewLibName(PWebCliHostOs));

  // the FIRST release, committed normally, is what the rollback must
  // restore
  Check(Seed('one'), 'the first inputs');
  first := PWebCliAssembleRelease(project, sdk, PWebCliHostOs,
    PWebCliHostArch, targetDir, exePath, bundlePath);
  CheckEqual(Ord(first.Refusal), Ord(plrNone), 'the first commit');
  releaseDir := PWebCliJoin(targetDir, PWEB_CLI_RUN_RELEASE);
  Check(PWebCliPipeTreeLines(releaseDir, nil, before, files, stage),
    'the first release is readable');
  Check(files > 0, 'and holds files');

  // the SECOND assembly, with the commit failed BETWEEN the two renames
  Check(Seed('two'), 'the second inputs, deliberately different');
  {$ifdef PWEB_LAYOUT_FAULTS}
  PWebCliLayoutFailCommit := True;
  {$endif}
  second := PWebCliAssembleRelease(project, sdk, PWebCliHostOs,
    PWebCliHostArch, targetDir, exePath, bundlePath);
  {$ifdef PWEB_LAYOUT_FAULTS}
  PWebCliLayoutFailCommit := False;
  {$endif}
  CheckEqual(Ord(second.Refusal), Ord(plrCommit),
    'the commit refuses with plrCommit');
  CheckEqual(second.Detail, PWEB_CLI_RUN_RELEASE, 'and names the release');

  // THE CLAIM: the previous release is back, in its own directory, and
  // byte-identical to what it was before the failed attempt
  Check(PWebCliEntry(targetDir, PWEB_CLI_RUN_RELEASE) = pcnDirectory,
    'the previous release is back in place');
  Check(PWebCliPipeTreeLines(releaseDir, nil, after, files, stage),
    'and readable');
  CheckEqual(after, before, 'and BYTE-IDENTICAL to what it was');
  // and nothing is left behind: neither the staged tree nor the aside one
  Check(PWebCliEntry(targetDir, PWEB_LAYOUT_STAGE) = pcnMissing,
    'no staging tree survives');
  Check(PWebCliEntry(targetDir, PWEB_LAYOUT_OLD) = pcnMissing,
    'no aside tree survives');
  Record_('rollback|cause|layout_commit_failed');
  Record_('rollback|previous_release_restored|true');
  Record_('rollback|byte_identical|true');
  Record_('rollback|siblings_left|none');
end;

end.
