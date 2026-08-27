{
  pweb.test.template - the CAP-10B0 suite over the scaffolding engine
  (mormot.core.test).

  Five subjects, one file, all four targets:

    PACK      the trusted list, the deterministic writer, the generated
              registry and the runtime verifier (T1-T12);
    RENDER    the placeholder model, the text/binary split and the
              line-ending contract (R1-R10);
    PLAN      the complete in-memory creation plan and every bound and
              collision rule it decides (P1-P10);
    ATOMIC    the filesystem transaction against REAL directories,
              including a real NTFS junction on Windows and a real symlink
              on POSIX (A1-A12);
    SECURITY  what a generated project may and may not contain (S1-S8).

  MOST OF IT TOUCHES NO FILESYSTEM, and that is the design rather than a
  convenience: the plan is a value, so a test can assert the whole refusal
  matrix - every collision, every bound, every encoding rule - without a
  single directory existing. A creation engine whose refusals can only be
  observed by watching it half-write a tree is a creation engine nobody can
  characterise.

  It also emits build/cap10b0/tpl-corpus.txt: every DECISION this suite
  made, as one LF line each. The CAP-7F evidence emitters hash that file
  into template_digest and the aggregator requires the four targets to
  produce the same bytes. Every line is the verdict of platform-independent
  logic, so equality is a property rather than a hope - and the file
  deliberately carries no path, no version and no timing, because those are
  the three things that cannot be equal across four machines.

  THE ONE PLATFORM-DEPENDENT ROW is named as such: file modes do not exist
  on Windows, so the corpus records `modes_applicable` and the mode rows
  assert the platform's own answer rather than a single expected one.
}

{$I mormot.defines.inc}

unit pweb.test.template;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.test,
  pweb.assets.intf,
  pweb.cli.platform,
  pweb.cli.project,
  pweb.cli.sdk,
  pweb.cli.template,
  pweb.cli.scaffold,
  pweb.cli.write;

type
  TTestPWebTplPack = class(TSynTestCase)
  published
    procedure TrustedList;
    procedure DeterministicPack;
    procedure RegistryIntegrity;
    procedure ArchiveRefusals;
    procedure TemplateLookup;
    procedure RealPack;
  end;

  TTestPWebTplRender = class(TSynTestCase)
  published
    procedure Substitution;
    procedure TokenRefusals;
    procedure PathRendering;
    procedure TextContract;
  end;

  TTestPWebTplPlan = class(TSynTestCase)
  published
    procedure ValidPlan;
    procedure CollisionRefusals;
    procedure BoundRefusals;
    procedure DescriptorShape;
  end;

  TTestPWebTplAtomic = class(TSynTestCase)
  published
    procedure CreatesAbsentDestination;
    procedure RefusesOccupiedDestination;
    procedure FailureLeavesNothing;
    procedure WorkingDirectoryIsIrrelevant;
  end;

  TTestPWebTplSecurity = class(TSynTestCase)
  published
    procedure GeneratedProjectContents;
    procedure SdkResolution;
  end;

const
  /// the corpus the CAP-7F emitters hash into template_digest
  PWEB_CAP10B0_CORPUS_FILE = 'build/cap10b0/tpl-corpus.txt';

{ THE STAGED SDK IS FOUND THE PRODUCTION WAY, and there is deliberately no
  constant here naming it.

  The build script puts this suite's own executable in <root>/bin and the
  pack in <root>/share/pweb, which is the layout an installed SDK has. So
  the suite calls PWebCliSdkRoot - the SAME resolver a shipped `pweb` will
  call - and gets the staged root because its own image is sitting in the
  right place.

  A relative path like 'build/cap10b0/sdk' would have been shorter and would
  have been a working-directory dependency in the one suite whose job
  includes proving there is none. mormot.core.test's runner does not
  guarantee the working directory it starts in, which is how this was
  MEASURED rather than reasoned about. }

/// the registry the trusted build generated, assembled from its constants
function PWebTestRegistry: TPWebTemplateRegistry;

implementation

{$ifdef WINDOWS}
uses
  windows;
{$else}
uses
  baseunix;
{$endif WINDOWS}

// the GENERATED trust anchor, compiled in with -Fi. It is not read from a
// file at runtime and it is not committed: the build produces it, and a
// suite that cannot compile it is a suite whose pack nobody generated
{$I pweb.templates.registry.inc}

var
  /// every decision this suite made, in emission order
  Corpus: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

function PWebTestRegistry: TPWebTemplateRegistry;
begin
  Result := PWebTplRegistryFrom(PWEB_TPL_GEN_PACK_FILE,
    PWEB_TPL_GEN_PACK_SHA256, PWEB_TPL_GEN_PACK_BYTES,
    PWEB_TPL_GEN_INVENTORY_DIGEST, PWEB_TPL_GEN_INVENTORY,
    PWEB_TPL_GEN_FILES, PWEB_TPL_GEN_TEMPLATES);
end;

{ ---------------------------------------------------------------------------
  fixture plumbing
  --------------------------------------------------------------------------- }

{$ifdef WINDOWS}
const
  IO_REPARSE_TAG_MOUNT_POINT = $A0000003;
  FSCTL_SET_REPARSE_POINT = $000900A4;
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;

type
  TMountPointReparseBuffer = record
    ReparseTag: DWord;
    ReparseDataLength: Word;
    Reserved: Word;
    SubstituteNameOffset: Word;
    SubstituteNameLength: Word;
    PrintNameOffset: Word;
    PrintNameLength: Word;
    PathBuffer: array[0 .. 1023] of WideChar;
  end;

// a real NTFS junction through the documented reparse-point control code.
// It needs no privilege, unlike a symlink, which is why the Windows half of
// the link fixture is a junction - the same technique the CAP-10A suite
// uses, and for the same reason
function MakeLink(const LinkDir, TargetDir: TFileName): Boolean;
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
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
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
    buf.PrintNameOffset := nameBytes + 2;
    buf.PrintNameLength := 0;
    Move(PWideChar(subst)^, buf.PathBuffer[0], nameBytes);
    buf.ReparseDataLength := 8 + nameBytes + 4;
    total := 8 + buf.ReparseDataLength;
    returned := 0;
    Result := DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, @buf, total,
      nil, 0, returned, nil);
  finally
    CloseHandle(h);
  end;
end;
{$else}
function MakeLink(const LinkDir, TargetDir: TFileName): Boolean;
begin
  Result := FpSymlink(PAnsiChar(RawByteString(TargetDir)),
    PAnsiChar(RawByteString(LinkDir))) = 0;
end;
{$endif WINDOWS}

var
  FixtureRoot: TFileName;
  FixtureSeq: Integer;

// every fixture directory is CHECKED into existence. FPC 3.2.2's recursive
// ForceDirectories was MEASURED during CAP-10A to return False while
// creating nothing, and an absent fixture looks EXACTLY like a working
// refusal in a suite half of whose expected answers are "it is not there"
procedure MakeDir(const Dir: TFileName);
begin
  if DirectoryExists(Dir) then
    exit;
  if not ForceDirectories(Dir) then
    raise Exception.CreateFmt('CAP-10B0 fixture directory not created: %s',
      [Dir]);
  if not DirectoryExists(Dir) then
    raise Exception.CreateFmt('CAP-10B0 fixture directory vanished: %s',
      [Dir]);
end;

function NewFixture(const Tag: RawUtf8): TFileName;
begin
  if FixtureRoot = '' then
  begin
    FixtureRoot := IncludeTrailingPathDelimiter(GetSystemPath(spTemp)) +
      'pweb-cap10b0-' + IntToStr(GetCurrentProcessId);
    MakeDir(FixtureRoot);
  end;
  Inc(FixtureSeq);
  Result := IncludeTrailingPathDelimiter(FixtureRoot) +
    Utf8ToString(Tag) + '-' + IntToStr(FixtureSeq);
  MakeDir(Result);
end;

function CanonicalFixture(const Tag: RawUtf8): RawUtf8;
var
  dir: TFileName;
begin
  dir := NewFixture(Tag);
  if not PWebCliCanonicalDir(StringToUtf8(dir), Result) then
    raise Exception.CreateFmt('CAP-10B0 fixture not canonical: %s', [dir]);
end;

{ ---------------------------------------------------------------------------
  an in-memory IAssetStore

  The plan builder reads its bytes through the frozen IAssetStore contract,
  so a test can hand it any corpus it likes without building an archive
  first. That is what makes the bound and collision rows (P5-P8) cheap
  enough to be exhaustive: a 300-file registry costs no disk at all.
  --------------------------------------------------------------------------- }
type
  TMemAssetStore = class(TInterfacedObject, IAssetStore)
  private
    fNames: TRawUtf8DynArray;
    fContents: array of RawByteString;
  public
    procedure Put(const Name: RawUtf8; const Content: RawByteString);
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
  end;

procedure TMemAssetStore.Put(const Name: RawUtf8;
  const Content: RawByteString);
begin
  SetLength(fNames, Length(fNames) + 1);
  SetLength(fContents, Length(fNames));
  fNames[High(fNames)] := Name;
  fContents[High(fContents)] := Content;
end;

function TMemAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  Asset := Default(TAssetResponse);
  for i := 0 to High(fNames) do
    if fNames[i] = Path then
    begin
      Asset.Content := fContents[i];
      Asset.ContentType := 'application/octet-stream';
      exit(True);
    end;
end;

{ Build a synthetic registry plus a store that serves it. Every row is text
  with normal mode unless the caller says otherwise. }
procedure BuildSynthetic(const Outputs: array of RawUtf8;
  const Bodies: array of RawByteString;
  out Reg: TPWebTemplateRegistry; out Store: IAssetStore);
var
  inv: TPWebTplInventory;
  files: TPWebTplFiles;
  tpls: TPWebTplTemplates;
  mem: TMemAssetStore;
  i, j, n: PtrInt;
  tmpInv: TPWebTplInventoryEntry;
  tmpFile: TPWebTplFile;
  packData: RawByteString;
begin
  n := Length(Outputs);
  mem := TMemAssetStore.Create;
  Store := mem;
  SetLength(inv, n);
  SetLength(files, n);
  for i := 0 to n - 1 do
  begin
    files[i].Archive := 'synth/f' + RawUtf8(Format('%.4d', [i]));
    files[i].OutPath := Outputs[i];
    files[i].Content := ptkText;
    files[i].Mode := ptmNormal;
    files[i].Bytes := Length(Bodies[i]);
    files[i].Sha256 := PWebTplSha256Hex(Bodies[i]);
    inv[i].Name := files[i].Archive;
    inv[i].Bytes := files[i].Bytes;
    inv[i].Sha256 := files[i].Sha256;
    mem.Put(files[i].Archive, Bodies[i]);
  end;
  // the inventory is globally sorted; the file rows are grouped and sorted
  // inside their group. With one template the two orders coincide, and both
  // are established explicitly rather than assumed
  for i := 1 to n - 1 do
  begin
    tmpInv := inv[i];
    j := i - 1;
    while (j >= 0) and (CompareStr(inv[j].Name, tmpInv.Name) > 0) do
    begin
      inv[j + 1] := inv[j];
      Dec(j);
    end;
    inv[j + 1] := tmpInv;
    tmpFile := files[i];
    j := i - 1;
    while (j >= 0) and (CompareStr(files[j].Archive, tmpFile.Archive) > 0) do
    begin
      files[j + 1] := files[j];
      Dec(j);
    end;
    files[j + 1] := tmpFile;
  end;
  SetLength(tpls, 1);
  tpls[0].Id := 'synth';
  tpls[0].IsPublic := False;
  tpls[0].Ui := 'react';
  tpls[0].NativeDir := 'src';
  tpls[0].NativeExt := 'lpr';
  tpls[0].FrontendRoot := 'frontend';
  tpls[0].OutputDir := 'dist';
  tpls[0].FirstFile := 0;
  tpls[0].FileCount := n;
  // a synthetic registry still has to describe a plausible pack, because
  // PWebTplValidateRegistry runs before anything else and would refuse an
  // impossible one
  packData := 'synthetic';
  Reg := PWebTplRegistryFrom('pweb-templates.zip',
    PWebTplSha256Hex(packData), Length(packData),
    PWebTplInventoryDigest(inv), inv, files, tpls);
end;

function SyntheticIdentity: TPWebScaffoldIdentity;
var
  code: TPWebScaffoldCode;
begin
  code := pscNone;
  if not PWebScaffoldIdentityOf('demo', 'com.example.demo', 'react',
       Result, code) then
    raise Exception.Create('CAP-10B0: the synthetic identity was refused');
end;

function CodeName(Code: TPWebScaffoldCode): RawUtf8;
begin
  Result := PWebScaffoldCodeText(Code);
end;

{ THE STAGED SDK, resolved the production way from this image's own
  location. Raises rather than returning a flag: a suite that quietly
  skipped every real-pack row because it could not find the pack would
  report a green matrix for work it did not do. }
function StagedSdkRoot: RawUtf8;
var
  refusal: TPWebSdkRefusal;
begin
  refusal := psrNone;
  if not PWebCliSdkRoot(Result, refusal) then
    raise Exception.CreateFmt(
      'CAP-10B0: the staged SDK root did not resolve (%s) - this suite ' +
      'must run from <sdk>/bin, which is where build_cap10b0 puts it',
      [Utf8ToString(PWebSdkRefusalText(refusal))]);
end;

{ ---------------------------------------------------------------------------
  T1-T12  the pack, the list, the registry and the verifier
  --------------------------------------------------------------------------- }

const
  GOOD_LIST: RawUtf8 =
    '# a trusted list' + #10 +
    'schema = 1' + #10 +
    #10 +
    'template = demo' + #10 +
    '  visibility = private' + #10 +
    '  ui = pas2js' + #10 +
    '  native-dir = src' + #10 +
    '  native-ext = lpr' + #10 +
    '  frontend-root = frontend' + #10 +
    '  output-dir = dist' + #10 +
    '  file = readme' + #10 +
    '    out = README.md' + #10 +
    '    content = text' + #10 +
    '    mode = normal' + #10;

procedure TTestPWebTplPack.TrustedList;
var
  tpls: TPWebTrustedTemplates;
  files: TPWebTrustedFiles;
  code: TPWebTplCode;
  detail: RawUtf8;
  ok: Boolean;

  procedure Refused(const Tag, Text: RawUtf8; Expected: TPWebTplCode);
  begin
    Check(not PWebTplParseList(Text, tpls, files, code, detail),
      Utf8ToString('the list was accepted: ' + Tag));
    CheckEqual(PWebTplCodeText(code), PWebTplCodeText(Expected),
      Utf8ToString(Tag));
    Record_('T1 list ' + Tag + ' ' + PWebTplCodeText(code));
  end;

begin
  // T1: the trusted list parses, and every field arrives.
  //
  // NOTE ON THE SHAPE OF EVERY ASSERTION BELOW that mentions an out
  // parameter in its message: the call is bound to `ok` FIRST. FPC does not
  // define the evaluation order of an argument list, and it MEASURABLY
  // evaluates the message before the call here - which read `code` and
  // `detail` before the callee had set them, and indexed a code-text array
  // with whatever the stack happened to hold. It faulted rather than
  // lying, which was lucky; binding first makes it neither.
  ok := PWebTplParseList(GOOD_LIST, tpls, files, code, detail);
  Check(ok, 'the good list was refused: ' + Utf8ToString(detail));
  CheckEqual(Length(tpls), 1);
  CheckEqual(Length(files), 1);
  CheckEqual(tpls[0].Id, 'demo');
  Check(not tpls[0].IsPublic);
  CheckEqual(tpls[0].Ui, 'pas2js');
  CheckEqual(files[0].Source, 'readme');
  CheckEqual(files[0].OutPath, 'README.md');
  Check(files[0].Content = ptkText);
  Check(files[0].Mode = ptmNormal);
  Record_('T1 list ok templates=1 files=1 ui=pas2js visibility=private');

  Refused('no-schema', 'template = demo' + #10, ptcListSchema);
  Refused('wrong-schema', 'schema = 2' + #10, ptcListSchema);
  Refused('unknown-key',
    'schema = 1' + #10 + 'template = demo' + #10 + '  colour = red' + #10,
    ptcListUnknownField);
  Refused('bad-id',
    'schema = 1' + #10 + 'template = Demo' + #10, ptcListTemplateId);
  Refused('bad-ui',
    'schema = 1' + #10 + 'template = demo' + #10 + '  ui = svelte' + #10,
    ptcListUi);
  Refused('bad-visibility',
    'schema = 1' + #10 + 'template = demo' + #10 +
    '  visibility = secret' + #10, ptcListVisibility);
  // a file block that omits its classification: refused, never defaulted -
  // silently choosing `text` is exactly the inference the list replaces
  Refused('missing-content',
    'schema = 1' + #10 + 'template = demo' + #10 +
    '  visibility = private' + #10 + '  ui = react' + #10 +
    '  native-dir = src' + #10 + '  native-ext = lpr' + #10 +
    '  frontend-root = frontend' + #10 + '  output-dir = dist' + #10 +
    '  file = readme' + #10 + '    out = README.md' + #10 +
    '    mode = normal' + #10, ptcListMissingField);
  Refused('duplicate-key',
    'schema = 1' + #10 + 'template = demo' + #10 + '  ui = react' + #10 +
    '  ui = pas2js' + #10, ptcListDuplicateKey);
  // T7 at the list level: a traversal in a declared source path
  Refused('traversal-source',
    'schema = 1' + #10 + 'template = demo' + #10 +
    '  visibility = private' + #10 + '  ui = react' + #10 +
    '  native-dir = src' + #10 + '  native-ext = lpr' + #10 +
    '  frontend-root = frontend' + #10 + '  output-dir = dist' + #10 +
    '  file = ../escape' + #10, ptcListSource);
  Refused('non-ascii', 'schema = 1' + #10 + 'template = d' + #$C3#$A9 + #10,
    ptcListEncoding);
end;

procedure TTestPWebTplPack.DeterministicPack;
var
  entries: TPWebTplEntries;
  roots: TRawUtf8DynArray;
  inv1, inv2: TPWebTplInventory;
  sha1, sha2, detail: RawUtf8;
  bytes1, bytes2: Int64;
  code: TPWebTplCode;
  dir, p1, p2: RawUtf8;
  ok: Boolean;
begin
  dir := CanonicalFixture('pack');
  SetLength(roots, 1);
  roots[0] := 'demo/';
  SetLength(entries, 3);
  entries[0].Name := 'demo/b.txt';
  entries[0].Content := 'bee' + #10;
  entries[1].Name := 'demo/a.txt';
  entries[1].Content := 'aye' + #10;
  entries[2].Name := 'demo/sub/c.bin';
  entries[2].Content := #0#1#2#255;
  p1 := PWebCliJoin(dir, 'one.zip');
  p2 := PWebCliJoin(dir, 'two.zip');
  // T2: the same logical input, written twice, is the same bytes. The
  // archive is a pure function of names, bytes, CRCs and a fixed timestamp
  // because every entry is STORED and no compressor is reached
  ok := PWebTplWritePack(p1, entries, roots, inv1, sha1, bytes1, code,
    detail);
  Check(ok, Utf8ToString(PWebTplCodeText(code) + ': ' + detail));
  ok := PWebTplWritePack(p2, entries, roots, inv2, sha2, bytes2, code,
    detail);
  Check(ok, Utf8ToString(PWebTplCodeText(code) + ': ' + detail));
  CheckEqual(sha1, sha2, 'two identical inputs produced different archives');
  CheckEqual(bytes1, bytes2);
  // and the inventory is in canonical bytewise order regardless of the
  // order the entries arrived in
  CheckEqual(Length(inv1), 3);
  CheckEqual(inv1[0].Name, 'demo/a.txt');
  CheckEqual(inv1[1].Name, 'demo/b.txt');
  CheckEqual(inv1[2].Name, 'demo/sub/c.bin');
  CheckEqual(PWebTplInventoryDigest(inv1), PWebTplInventoryDigest(inv2));
  Record_('T2 pack deterministic entries=3 inventory=' +
    PWebTplInventoryDigest(inv1));
end;

procedure TTestPWebTplPack.RegistryIntegrity;
var
  reg, bad: TPWebTemplateRegistry;
  code: TPWebTplCode;
  detail, t1, t2: RawUtf8;
  ok: Boolean;
begin
  reg := PWebTestRegistry;
  // T3: the generated registry is self-consistent, and re-emitting it is
  // byte-identical - which is what makes a regenerated include comparable
  ok := PWebTplValidateRegistry(reg, code, detail);
  Check(ok, Utf8ToString(PWebTplCodeText(code) + ': ' + detail));
  ok := PWebTplEmitRegistry(reg, 'pwebtemplates', t1, code, detail);
  Check(ok, Utf8ToString(PWebTplCodeText(code) + ': ' + detail));
  Check(PWebTplEmitRegistry(reg, 'pwebtemplates', t2, code, detail));
  CheckEqual(t1, t2, 'two emissions of one registry differed');
  Record_('T3 registry emit deterministic bytes=' +
    RawUtf8(IntToStr(Length(t1))));
  Record_('T3 registry digest ' + PWebTplRegistryDigest(reg));

  // T4: a registry whose inventory digest does not describe its inventory.
  // Every mutation below takes an explicit COPY of the arrays: a record
  // assignment shares them by reference, and a test that silently mutated
  // the real registry would poison every row after it
  bad := reg;
  bad.InventoryDigest := PWebTplSha256Hex('not the inventory');
  Check(not PWebTplValidateRegistry(bad, code, detail));
  Record_('T4 registry inventory-digest mismatch ' + PWebTplCodeText(code));

  // a file row that claims an inventory entry nobody has
  bad := reg;
  bad.Files := Copy(reg.Files);
  bad.Files[0].Bytes := bad.Files[0].Bytes + 1;
  Check(not PWebTplValidateRegistry(bad, code, detail));
  Record_('T4 registry row/inventory disagreement ' + PWebTplCodeText(code));

  // an inventory that is not in canonical order
  bad := reg;
  bad.Inventory := Copy(reg.Inventory);
  bad.Inventory[0].Name := 'zzz/last';
  bad.InventoryDigest := PWebTplInventoryDigest(bad.Inventory);
  Check(not PWebTplValidateRegistry(bad, code, detail));
  Record_('T4 registry order ' + PWebTplCodeText(code));

  // a file row whose archive name is not under its own template's root:
  // one template's row can never point at another's bytes
  bad := reg;
  bad.Files := Copy(reg.Files);
  bad.Files[0].Archive := 'elsewhere/README.md';
  Check(not PWebTplValidateRegistry(bad, code, detail));
  Record_('T4 registry root membership ' + PWebTplCodeText(code));

  // T11: a registry that would write a credential
  bad := reg;
  bad.Files := Copy(reg.Files);
  bad.Files[0].OutPath := '.env';
  Check(not PWebTplValidateRegistry(bad, code, detail));
  CheckEqual(PWebTplCodeText(code), 'entry_secret');
  Record_('T11 registry secret output ' + PWebTplCodeText(code));

  // and the same, for the two other shapes of the same mistake
  bad := reg;
  bad.Files := Copy(reg.Files);
  bad.Files[0].OutPath := 'certs/server.pem';
  Check(not PWebTplValidateRegistry(bad, code, detail));
  CheckEqual(PWebTplCodeText(code), 'entry_secret');
  bad := reg;
  bad.Files := Copy(reg.Files);
  bad.Files[0].OutPath := 'node_modules/left-pad/index.js';
  Check(not PWebTplValidateRegistry(bad, code, detail));
  CheckEqual(PWebTplCodeText(code), 'entry_secret');
  Record_('T11 registry secret output pem/node_modules refused');

  // the real registry itself must of course pass every one of those
  ok := PWebTplValidateRegistry(reg, code, detail);
  Check(ok, 'the generated registry stopped validating after the mutations');
end;

procedure TTestPWebTplPack.ArchiveRefusals;
var
  entries: TPWebTplEntries;
  roots: TRawUtf8DynArray;
  inv: TPWebTplInventory;
  sha, detail, dir: RawUtf8;
  bytes: Int64;
  code: TPWebTplCode;

  procedure TryWrite(const Tag: RawUtf8; Expected: TPWebTplCode);
  begin
    Check(not PWebTplWritePack(PWebCliJoin(dir, 'x.zip'), entries, roots,
      inv, sha, bytes, code, detail),
      Utf8ToString('the writer accepted: ' + Tag));
    CheckEqual(PWebTplCodeText(code), PWebTplCodeText(Expected),
      Utf8ToString(Tag));
    Record_('T-archive ' + Tag + ' ' + PWebTplCodeText(code));
  end;

begin
  dir := CanonicalFixture('archive');
  SetLength(roots, 1);
  roots[0] := 'demo/';

  // T6: the same name twice
  SetLength(entries, 2);
  entries[0].Name := 'demo/a.txt';
  entries[0].Content := 'one' + #10;
  entries[1].Name := 'demo/a.txt';
  entries[1].Content := 'two' + #10;
  TryWrite('duplicate', ptcEntryDuplicate);

  // T7: a traversal in an entry name
  SetLength(entries, 1);
  entries[0].Name := 'demo/../escape.txt';
  entries[0].Content := 'x' + #10;
  TryWrite('traversal', ptcEntryName);

  // an entry outside every registered root
  entries[0].Name := 'other/a.txt';
  TryWrite('outside-root', ptcEntryOutsideRoot);

  // T8: an ASCII case collision
  SetLength(entries, 2);
  entries[0].Name := 'demo/readme.md';
  entries[0].Content := 'a' + #10;
  entries[1].Name := 'demo/README.md';
  entries[1].Content := 'b' + #10;
  TryWrite('case-collision', ptcEntryCollision);

  // T9: a UNICODE fold collision, decided by the pinned compiled-in
  // Unicode 10.0 tables and never by the operating system's collation
  SetLength(entries, 2);
  entries[0].Name := 'demo/caf' + #$C3#$A9 + '.txt';   // U+00E9
  entries[0].Content := 'a' + #10;
  entries[1].Name := 'demo/caf' + #$C3#$89 + '.txt';   // U+00C9
  entries[1].Content := 'b' + #10;
  TryWrite('unicode-fold-collision', ptcEntryCollision);

  // a file that is also a directory prefix of another
  SetLength(entries, 2);
  entries[0].Name := 'demo/thing';
  entries[0].Content := 'a' + #10;
  entries[1].Name := 'demo/thing/inner.txt';
  entries[1].Content := 'b' + #10;
  TryWrite('file-directory-collision', ptcEntryCollision);
end;

procedure TTestPWebTplPack.TemplateLookup;
var
  reg: TPWebTemplateRegistry;
  idx: Integer;
  code: TPWebTplCode;
begin
  reg := PWebTestRegistry;
  // T12: an id nobody registered
  Check(not PWebTplFind(reg, 'nosuch', False, idx, code));
  CheckEqual(PWebTplCodeText(code), 'template_unknown');
  Record_('T12 lookup unknown ' + PWebTplCodeText(code));
  // the fixture IS present, and is reachable only when public access is
  // not required
  Check(PWebTplFind(reg, 'fixture', False, idx, code));
  CheckEqual(idx, 0);
  Check(not reg.Templates[idx].IsPublic,
    'the CAP-10B0 fixture must not be public');
  // and a PUBLIC request is refused with its own code, not with "unknown":
  // the two are different answers and a public command must give the second
  Check(not PWebTplFind(reg, 'fixture', True, idx, code));
  CheckEqual(PWebTplCodeText(code), 'template_private');
  Record_('T12 lookup private-as-public ' + PWebTplCodeText(code));
  Record_('T12 templates ' + RawUtf8(IntToStr(Length(reg.Templates))) +
    ' public=0');
end;

procedure TTestPWebTplPack.RealPack;
var
  reg, bad: TPWebTemplateRegistry;
  sdk, pack, sha, detail: RawUtf8;
  data: RawByteString;
  refusal: TPWebSdkRefusal;
  store: IAssetStore;
  code: TPWebTplCode;
  i: PtrInt;
  ok: Boolean;
begin
  reg := PWebTestRegistry;
  // the staged SDK, found the production way: <root>/bin holds this very
  // executable and <root>/share/pweb holds the pack, which is the layout an
  // installed SDK has
  sdk := StagedSdkRoot;
  refusal := psrNone;
  ok := PWebCliTemplatePackIn(sdk, pack, refusal);
  Check(ok, Utf8ToString(PWebSdkRefusalText(refusal)));
  code := ptcNone;
  ok := PWebTplLoadPack(pack, data, sha, code);
  Check(ok, Utf8ToString(PWebTplCodeText(code)));
  // T1 end to end: the real archive the real builder produced, verified
  // against the real registry it generated
  ok := PWebTplVerifyPack(reg, data, sha, store, code, detail);
  Check(ok, Utf8ToString(PWebTplCodeText(code) + ': ' + detail));
  Check(store <> nil);
  Record_('T1 real pack verified files=' +
    RawUtf8(IntToStr(Length(reg.Inventory))));
  Record_('T1 real pack inventory ' + reg.InventoryDigest);
  Record_('T1 real pack registry ' + PWebTplRegistryDigest(reg));

  // T4: the same bytes against a registry that expects a different digest
  // the REAL bytes and their REAL digest, against a registry that expects a
  // different one. Handing the registry's own expectation in as the
  // measured digest would compare it with itself and prove nothing
  bad := reg;
  bad.PackSha256 := PWebTplSha256Hex('something else');
  store := nil;
  Check(not PWebTplVerifyPack(bad, data, sha, store, code, detail));
  CheckEqual(PWebTplCodeText(code), 'pack_digest');
  Check(store = nil, 'a store escaped a failed verification');
  Record_('T4 pack digest mismatch ' + PWebTplCodeText(code));

  // and against one that expects a different length
  bad := reg;
  bad.PackBytes := bad.PackBytes + 1;
  Check(not PWebTplVerifyPack(bad, data, sha, store, code, detail));
  CheckEqual(PWebTplCodeText(code), 'pack_size');
  Record_('T4 pack size mismatch ' + PWebTplCodeText(code));

  // T5: bytes that are not an archive at all, with a registry that agrees
  // about their length and digest - so the ONLY thing left to refuse them
  // is the archive parser
  data := 'this is not a zip file at all, not even close';
  bad := reg;
  bad.PackBytes := Length(data);
  bad.PackSha256 := PWebTplSha256Hex(data);
  Check(not PWebTplVerifyPack(bad, data, PWebTplSha256Hex(data), store,
    code, detail));
  CheckEqual(PWebTplCodeText(code), 'archive_invalid');
  Record_('T5 malformed archive ' + PWebTplCodeText(code));

  // T4 again, from the other side: a registry that expects one more entry
  // than the archive holds
  Check(PWebTplLoadPack(pack, data, sha, code));
  bad := reg;
  bad.Inventory := Copy(reg.Inventory);
  bad.Files := Copy(reg.Files);
  SetLength(bad.Inventory, Length(reg.Inventory) + 1);
  SetLength(bad.Files, Length(reg.Files) + 1);
  for i := 0 to High(reg.Inventory) do
  begin
    bad.Inventory[i] := reg.Inventory[i];
    bad.Files[i] := reg.Files[i];
  end;
  bad.Inventory[High(bad.Inventory)].Name := 'fixture/zz-extra';
  bad.Inventory[High(bad.Inventory)].Bytes := 2;
  bad.Inventory[High(bad.Inventory)].Sha256 := PWebTplSha256Hex('x' + #10);
  bad.Files[High(bad.Files)] := bad.Files[High(bad.Files) - 1];
  bad.Files[High(bad.Files)].Archive := 'fixture/zz-extra';
  bad.Files[High(bad.Files)].OutPath := 'zz-extra';
  bad.Files[High(bad.Files)].Bytes := 2;
  bad.Files[High(bad.Files)].Sha256 := PWebTplSha256Hex('x' + #10);
  bad.InventoryDigest := PWebTplInventoryDigest(bad.Inventory);
  SetLength(bad.Templates, 1);
  bad.Templates[0] := reg.Templates[0];
  bad.Templates[0].FileCount := reg.Templates[0].FileCount + 1;
  Check(not PWebTplVerifyPack(bad, data, sha, store, code, detail));
  CheckEqual(PWebTplCodeText(code), 'inventory_count');
  Record_('T4 pack entry-count mismatch ' + PWebTplCodeText(code));
end;

{ ---------------------------------------------------------------------------
  R1-R10  the renderer
  --------------------------------------------------------------------------- }

procedure TTestPWebTplRender.Substitution;
var
  id: TPWebScaffoldIdentity;
  out1, detail, big: RawUtf8;
  code: TPWebScaffoldCode;
  names: TRawUtf8DynArray;
  i: PtrInt;
  ok: Boolean;
begin
  id := SyntheticIdentity;
  // R1: every token in the fixed allowlist expands, and nothing else does
  names := PWebScaffoldTokenNames;
  CheckEqual(Length(names), 6);
  for i := 0 to High(names) do
    Record_('R1 token ' + names[i]);
  ok := PWebScaffoldRender(
    'n={{PROJECT_NAME}} p={{PASCAL_PROGRAM}} e={{EXECUTABLE_NAME}} ' +
    'b={{BUNDLE_ID}} v={{PROJECT_VERSION}} u={{UI_KIND}}' + #10,
    id, out1, code, detail);
  Check(ok, Utf8ToString(CodeName(code) + ': ' + detail));
  CheckEqual(out1, 'n=demo p=demo e=demo b=com.example.demo v=0.1.0 ' +
    'u=react' + #10);
  Record_('R1 expanded ' + PWebTplSha256Hex(out1));
  // the six projected values, recorded so a future shard that DECOUPLES
  // the three equal ones shows up in the evidence rather than in somebody's
  // executable name
  Record_('R1 identity ' + id.ProjectName + ' ' + id.PascalProgram + ' ' +
    id.ExecutableName + ' ' + id.BundleId + ' ' + id.ProjectVersion + ' ' +
    id.UiKind);

  // R4: the output of a substitution is FINAL. A value that looks like a
  // token is not rescanned, which is what makes one pass a guarantee
  // rather than an implementation detail
  id.ProjectName := '{{BUNDLE_ID}}';
  Check(PWebScaffoldRender('x={{PROJECT_NAME}}' + #10, id, out1, code,
    detail));
  CheckEqual(out1, 'x={{BUNDLE_ID}}' + #10);
  Record_('R4 no-recursive-expansion ok');

  // R1 at SCALE. PWEB_TPL_FILE_MAX_BYTES permits a 1 MiB text template, and
  // the first renderer written here appended one byte at a time - quadratic,
  // so a file the limits explicitly allow would have hung the build rather
  // than failing it. This row renders a quarter of that limit with a token
  // on every line, and exists so the linear behaviour is a MEASURED property
  // instead of a claim about how the loop is written.
  id := SyntheticIdentity;
  big := '';
  SetLength(big, 0);
  for i := 1 to 8000 do
    big := big + 'line ' + RawUtf8(IntToStr(i)) + ' of {{PROJECT_NAME}}' +
      ' padded out to make this a real corpus rather than a token soup' + #10;
  Check(Length(big) > 256 * 1024, 'the scale fixture is too small to matter');
  ok := PWebScaffoldRender(big, id, out1, code, detail);
  Check(ok, Utf8ToString(CodeName(code) + ': ' + detail));
  // 'demo' replaces '{{PROJECT_NAME}}', which is 12 bytes shorter, 8000 times
  CheckEqual(Length(out1), Length(big) - (8000 * 12));
  Record_('R1 scale input=' + RawUtf8(IntToStr(Length(big))) + ' output=' +
    RawUtf8(IntToStr(Length(out1))) + ' ' + PWebTplSha256Hex(out1));
end;

procedure TTestPWebTplRender.TokenRefusals;
var
  id: TPWebScaffoldIdentity;
  outv, detail: RawUtf8;
  code: TPWebScaffoldCode;

  procedure Refused(const Tag, Text: RawUtf8; Expected: TPWebScaffoldCode);
  begin
    Check(not PWebScaffoldRender(Text, id, outv, code, detail),
      Utf8ToString('the renderer accepted: ' + Tag));
    CheckEqual(CodeName(code), CodeName(Expected), Utf8ToString(Tag));
    Record_('R2 render ' + Tag + ' ' + CodeName(code));
  end;

begin
  id := SyntheticIdentity;
  // R2: a name outside the allowlist. There is no pass-through form, so a
  // typo cannot become a permanent string in somebody's new project
  Refused('unknown-token', 'a{{PROJECT_TITLE}}b' + #10, pscTokenUnknown);
  Refused('lowercase-token', 'a{{project_name}}b' + #10, pscTokenEmpty);
  // R3: an opener with no closer
  Refused('unterminated', 'a{{PROJECT_NAME' + #10, pscTokenUnterminated);
  Refused('single-brace-close', 'a{{PROJECT_NAME}b' + #10,
    pscTokenUnterminated);
  Refused('empty-token', 'a{{}}b' + #10, pscTokenEmpty);
end;

procedure TTestPWebTplRender.PathRendering;
var
  id: TPWebScaffoldIdentity;
  outv, detail: RawUtf8;
  code: TPWebScaffoldCode;
  ok: Boolean;
begin
  id := SyntheticIdentity;
  ok := PWebScaffoldRenderPath('src/{{PASCAL_PROGRAM}}.lpr', id, outv,
    code, detail);
  Check(ok, Utf8ToString(CodeName(code) + ': ' + detail));
  CheckEqual(outv, 'src/demo.lpr');
  Record_('R5 path rendered src/demo.lpr');

  // R5: separator injection. The identity grammars make this impossible
  // today; the check is STRUCTURAL so that it keeps holding the day one of
  // them widens and nobody re-reads this file
  id.PascalProgram := 'a/b';
  Check(not PWebScaffoldRenderPath('src/{{PASCAL_PROGRAM}}.lpr', id, outv,
    code, detail));
  CheckEqual(CodeName(code), 'render_segments');
  Record_('R5 path separator-injection ' + CodeName(code));

  id.PascalProgram := '..';
  Check(not PWebScaffoldRenderPath('src/{{PASCAL_PROGRAM}}/x.txt', id,
    outv, code, detail));
  Record_('R5 path traversal-injection ' + CodeName(code));

  id.PascalProgram := 'con';
  Check(not PWebScaffoldRenderPath('{{PASCAL_PROGRAM}}.txt', id, outv,
    code, detail));
  CheckEqual(CodeName(code), 'render_path');
  Record_('R5 path device-name ' + CodeName(code));
end;

procedure TTestPWebTplRender.TextContract;
var
  code: TPWebTplCode;

  procedure Accepted(const Tag: RawUtf8; const Data: RawByteString);
  begin
    Check(PWebTplTextValid(Data, code), Utf8ToString('refused: ' + Tag));
    Record_('R6 text ' + Tag + ' ok');
  end;

  procedure Refused(const Tag: RawUtf8; const Data: RawByteString;
    Expected: TPWebTplCode);
  begin
    Check(not PWebTplTextValid(Data, code),
      Utf8ToString('accepted: ' + Tag));
    CheckEqual(PWebTplCodeText(code), PWebTplCodeText(Expected),
      Utf8ToString(Tag));
    Record_('R6 text ' + Tag + ' ' + PWebTplCodeText(code));
  end;

begin
  Accepted('plain', 'hello' + #10);
  Accepted('utf8', 'caf' + #$C3#$A9 + #10);
  Accepted('blank-line-inside', 'a' + #10 + #10 + 'b' + #10);
  // R6
  Refused('invalid-utf8', 'a' + #$C3#$28 + #10, ptcEntryEncoding);
  Refused('overlong-utf8', 'a' + #$C0#$AF + #10, ptcEntryEncoding);
  Refused('embedded-nul', 'a' + #0 + 'b' + #10, ptcEntryEncoding);
  Refused('bom', #$EF#$BB#$BF + 'a' + #10, ptcEntryEncoding);
  // R8: ONE line-ending policy. A CR is a refusal and never a fixup, so a
  // CRLF checkout fails the build instead of quietly changing the bytes a
  // generated project ships
  Refused('crlf', 'a' + #13#10, ptcEntryLineEnding);
  Refused('lone-cr', 'a' + #13 + 'b' + #10, ptcEntryLineEnding);
  // R9: exactly ONE terminating newline, so the rule is a rule
  Refused('no-final-newline', 'a', ptcEntryLineEnding);
  Refused('doubled-final-newline', 'a' + #10#10, ptcEntryLineEnding);
  Refused('empty', '', ptcEntryLineEnding);
end;

{ ---------------------------------------------------------------------------
  P1-P10  the creation plan
  --------------------------------------------------------------------------- }

procedure TTestPWebTplPlan.ValidPlan;
var
  reg: TPWebTemplateRegistry;
  store: IAssetStore;
  plan: TPWebCreationPlan;
  code: TPWebScaffoldCode;
  detail: RawUtf8;
  i: PtrInt;
  ok: Boolean;
begin
  // P1: a plan over a synthetic corpus, decided entirely in memory
  BuildSynthetic(['README.md', 'src/{{PASCAL_PROGRAM}}.lpr',
                  'frontend/app.js'],
                 ['# {{PROJECT_NAME}}' + #10,
                  'program {{PASCAL_PROGRAM}};' + #10,
                  'var n = "{{PROJECT_NAME}}";' + #10],
                 reg, store);
  ok := PWebBuildPlan(reg, 0, store, SyntheticIdentity, plan, code, detail);
  Check(ok, Utf8ToString(CodeName(code) + ': ' + detail));
  // three template files plus the generated descriptor
  CheckEqual(Length(plan.Files), 4);
  // sorted bytewise by path, always
  for i := 1 to High(plan.Files) do
    Check(CompareStr(plan.Files[i - 1].Path, plan.Files[i].Path) < 0,
      'the plan is not in canonical order');
  Record_('P1 plan files=' + RawUtf8(IntToStr(Length(plan.Files))) +
    ' bytes=' + RawUtf8(IntToStr(plan.TotalBytes)));
  Record_('P1 plan inventory ' + PWebPlanInventoryDigest(plan));
  for i := 0 to High(plan.Files) do
    Record_('P1 file ' + plan.Files[i].Path + ' ' +
      PWebTplContentText(plan.Files[i].Kind) + ' ' +
      PWebTplModeText(plan.Files[i].Mode) + ' ' + plan.Files[i].Sha256);

  // R10: the classification comes from the REGISTRY, never from the bytes
  // or the extension. The same source, declared binary, is copied verbatim
  // and its token text survives untouched
  SetLength(reg.Files, Length(reg.Files));
  for i := 0 to High(reg.Files) do
    if reg.Files[i].OutPath = 'frontend/app.js' then
      reg.Files[i].Content := ptkBinary;
  ok := PWebBuildPlan(reg, 0, store, SyntheticIdentity, plan, code, detail);
  Check(ok, Utf8ToString(CodeName(code) + ': ' + detail));
  for i := 0 to High(plan.Files) do
    if plan.Files[i].Path = 'frontend/app.js' then
    begin
      Check(plan.Files[i].Kind = ptkBinary);
      CheckEqual(plan.Files[i].Content, 'var n = "{{PROJECT_NAME}}";' + #10,
        'a binary-classified entry was substituted');
      Record_('R10 binary-classified entry copied verbatim');
    end;
end;

procedure TTestPWebTplPlan.CollisionRefusals;
var
  reg: TPWebTemplateRegistry;
  store: IAssetStore;
  plan: TPWebCreationPlan;
  code: TPWebScaffoldCode;
  detail: RawUtf8;

  procedure Refused(const Tag: RawUtf8; Expected: TPWebScaffoldCode);
  begin
    Check(not PWebBuildPlan(reg, 0, store, SyntheticIdentity, plan, code,
      detail), Utf8ToString('the plan was accepted: ' + Tag));
    CheckEqual(CodeName(code), CodeName(Expected), Utf8ToString(Tag));
    Record_('P2 plan ' + Tag + ' ' + CodeName(code));
  end;

begin
  // P2: two rows whose OUTPUT paths are literally different and render the
  // same. The registry cannot catch this - only the plan can
  BuildSynthetic(['{{PROJECT_NAME}}.txt', '{{PASCAL_PROGRAM}}.txt'],
                 ['a' + #10, 'b' + #10], reg, store);
  Refused('duplicate-rendered-path', pscPlanDuplicate);

  // P3: a case collision between two rendered paths
  BuildSynthetic(['README.md', 'readme.md'], ['a' + #10, 'b' + #10],
    reg, store);
  Refused('case-collision', pscPlanCollision);

  // P4: a Unicode fold collision, by the pinned compiled-in tables
  BuildSynthetic(['caf' + #$C3#$A9 + '.txt', 'caf' + #$C3#$89 + '.txt'],
                 ['a' + #10, 'b' + #10], reg, store);
  Refused('unicode-fold-collision', pscPlanCollision);

  // a file that is also a directory prefix of another
  BuildSynthetic(['thing', 'thing/inner.txt'], ['a' + #10, 'b' + #10],
    reg, store);
  Refused('file-directory-collision', pscPlanCollision);

  // and the descriptor's own name is not available to a template
  BuildSynthetic(['pweb.json'], ['{}' + #10], reg, store);
  Refused('descriptor-name-taken', pscPlanDuplicate);
end;

procedure TTestPWebTplPlan.BoundRefusals;
var
  reg: TPWebTemplateRegistry;
  store: IAssetStore;
  plan: TPWebCreationPlan;
  code: TPWebScaffoldCode;
  detail, long: RawUtf8;
  outs: TRawUtf8DynArray;
  bodies: array of RawByteString;
  i, n: PtrInt;
  id: TPWebScaffoldIdentity;
begin
  // P5: the file-count bound
  n := PWEB_TPL_MAX_OUTPUT_FILES + 4;
  SetLength(outs, n);
  SetLength(bodies, n);
  for i := 0 to n - 1 do
  begin
    outs[i] := RawUtf8(Format('f%.4d.txt', [i]));
    bodies[i] := 'x' + #10;
  end;
  BuildSynthetic(outs, bodies, reg, store);
  Check(not PWebBuildPlan(reg, 0, store, SyntheticIdentity, plan, code,
    detail));
  CheckEqual(CodeName(code), 'plan_file_count');
  Record_('P5 plan file-count ' + CodeName(code) + ' limit=' +
    RawUtf8(IntToStr(PWEB_TPL_MAX_OUTPUT_FILES)));

  // P8: the rendered-path bound
  long := 'd';
  while Length(long) < PWEB_TPL_PATH_MAX_BYTES do
    long := long + 'e';
  BuildSynthetic([long + '.txt'], ['x' + #10], reg, store);
  // the registry itself refuses it first, which is the earlier and better
  // place: a path this long is a build defect, not a runtime condition
  Check(not PWebBuildPlan(reg, 0, store, SyntheticIdentity, plan, code,
    detail));
  Record_('P8 plan path-length ' + CodeName(code) + ' limit=' +
    RawUtf8(IntToStr(PWEB_TPL_PATH_MAX_BYTES)));

  // P9: the placeholder-VALUE bound, asserted on the identity itself. A
  // name at the limit is fine; one byte more is not a project name
  long := 'a';
  while Length(long) < PWEB_SCAFFOLD_NAME_MAX_BYTES do
    long := long + 'b';
  Check(PWebScaffoldNameValid(long));
  Check(not PWebScaffoldNameValid(long + 'c'));
  Check(not PWebScaffoldIdentityOf(long + 'c', 'com.example.x', 'react',
    id, code));
  CheckEqual(CodeName(code), 'name');
  Record_('P9 identity name-length limit=' +
    RawUtf8(IntToStr(PWEB_SCAFFOLD_NAME_MAX_BYTES)) + ' ' + CodeName(code));

  // and the NAME grammar itself: hyphens, capitals, digits-first, dots and
  // separators are all refused rather than transformed
  Check(not PWebScaffoldNameValid('my-app'));
  Check(not PWebScaffoldNameValid('MyApp'));
  Check(not PWebScaffoldNameValid('1app'));
  Check(not PWebScaffoldNameValid('my.app'));
  Check(not PWebScaffoldNameValid('my/app'));
  Check(not PWebScaffoldNameValid(''));
  Check(PWebScaffoldNameValid('myapp2'));
  Record_('P9 name grammar strict-subset-of-schema1 ok');

  // a bundleId is REQUIRED and is never invented from a name
  Check(not PWebScaffoldIdentityOf('demo', '', 'react', id, code));
  CheckEqual(CodeName(code), 'bundle_id');
  Check(not PWebScaffoldIdentityOf('demo', 'nodots', 'react', id, code));
  CheckEqual(CodeName(code), 'bundle_id');
  Record_('P9 identity bundle-id-required ' + CodeName(code));
end;

procedure TTestPWebTplPlan.DescriptorShape;
var
  reg: TPWebTemplateRegistry;
  store: IAssetStore;
  plan: TPWebCreationPlan;
  code: TPWebScaffoldCode;
  detail, json: RawUtf8;
  i: PtrInt;
  ok: Boolean;
begin
  BuildSynthetic(['README.md'], ['# {{PROJECT_NAME}}' + #10], reg, store);
  ok := PWebBuildPlan(reg, 0, store, SyntheticIdentity, plan, code, detail);
  Check(ok, Utf8ToString(CodeName(code) + ': ' + detail));
  json := '';
  for i := 0 to High(plan.Files) do
    if plan.Files[i].Path = 'pweb.json' then
      json := RawUtf8(plan.Files[i].Content);
  Check(json <> '', 'the plan carries no descriptor');
  // P10 (shape half): the exact canonical document, as docs/cli-contract.md
  // prints it. The other half - that the FROZEN reader accepts it - needs a
  // tree that exists and lives in the atomic case
  CheckEqual(json,
    '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "name": "demo",' + #10 +
    '  "version": "0.1.0",' + #10 +
    '  "bundleId": "com.example.demo",' + #10 +
    '  "ui": "react",' + #10 +
    '  "native": { "program": "src/demo.lpr" },' + #10 +
    '  "frontend": { "root": "frontend" },' + #10 +
    '  "output": "dist"' + #10 +
    '}' + #10);
  Record_('P10 descriptor ' + PWebTplSha256Hex(json));
end;

{ ---------------------------------------------------------------------------
  A1-A12  the filesystem transaction
  --------------------------------------------------------------------------- }

function RealPlan(out Reg: TPWebTemplateRegistry;
  out Tpl: TPWebTplTemplate; out Plan: TPWebCreationPlan): Boolean;
var
  sdk, pack, sha, detail: RawUtf8;
  data: RawByteString;
  refusal: TPWebSdkRefusal;
  store: IAssetStore;
  tcode: TPWebTplCode;
  scode: TPWebScaffoldCode;
  idx: Integer;
begin
  Result := False;
  Reg := PWebTestRegistry;
  sdk := StagedSdkRoot;
  if not PWebCliTemplatePackIn(sdk, pack, refusal) then
    exit;
  if not PWebTplLoadPack(pack, data, sha, tcode) then
    exit;
  if not PWebTplVerifyPack(Reg, data, sha, store, tcode, detail) then
    exit;
  if not PWebTplFind(Reg, 'fixture', {RequirePublic=}False, idx, tcode) then
    exit;
  Tpl := Reg.Templates[idx];
  Result := PWebBuildPlan(Reg, idx, store, SyntheticIdentity, Plan,
    scode, detail);
end;

procedure TTestPWebTplAtomic.CreatesAbsentDestination;
var
  reg: TPWebTemplateRegistry;
  tpl: TPWebTplTemplate;
  plan: TPWebCreationPlan;
  res: TPWebCreateResult;
  parent, dest, native, seg: RawUtf8;
  content: RawByteString;
  tooBig, ok: Boolean;
  i, j: PtrInt;
begin
  Check(RealPlan(reg, tpl, plan), 'the real fixture plan could not be built');
  parent := CanonicalFixture('create');
  // A1: an absent destination succeeds, and the transaction commits by
  // rename rather than by copying anything into place
  ok := PWebCreateProject(parent, 'demo', plan, tpl, res);
  Check(ok, Utf8ToString(PWebCreateRefusalText(res.Refusal) + ': ' +
    res.Detail));
  CheckEqual(PWebCreateRefusalText(res.Refusal), 'ok');
  CheckEqual(res.FilesWritten, Length(plan.Files));
  Check(res.Destination <> '');
  dest := PWebCliJoin(parent, 'demo');
  Check(PWebCliEntry(parent, 'demo') = pcnDirectory);
  // A9: nothing staged survives a success either
  Check(PWebCliEntry(parent, PWebStageName('demo')) = pcnMissing,
    'the staging directory outlived the commit');
  // the corpus carries only what is EQUAL on four targets: the file count,
  // the byte count and the number of files the PLAN intended to be
  // executable. Whether this platform can express a mode at all is a fact
  // about the platform, so it travels in the per-target evidence instead -
  // the same split the CAP-10A doctor observations already use
  Record_('A1 create ok files=' + RawUtf8(IntToStr(res.FilesWritten)) +
    ' bytes=' + RawUtf8(IntToStr(res.BytesWritten)) +
    ' executable_planned=' + RawUtf8(IntToStr(res.ExecutableFiles)));

  // A11: the final inventory is EXACTLY the plan - every file, byte for
  // byte, and A12: no token survived into any of them
  for i := 0 to High(plan.Files) do
  begin
    native := dest;
    seg := '';
    for j := 1 to Length(plan.Files[i].Path) + 1 do
      if (j > Length(plan.Files[i].Path)) or
         (plan.Files[i].Path[j] = '/') then
      begin
        native := PWebCliJoin(native, seg);
        seg := '';
      end
      else
        seg := seg + plan.Files[i].Path[j];
    Check(PWebCliReadSmallFile(native, PWEB_TPL_FILE_MAX_BYTES, content,
      tooBig), Utf8ToString('missing from the created project: ' +
      plan.Files[i].Path));
    CheckEqual(PWebTplSha256Hex(content), plan.Files[i].Sha256,
      Utf8ToString('bytes differ: ' + plan.Files[i].Path));
    if plan.Files[i].Kind = ptkText then
      for j := 1 to Length(content) - 1 do
        Check(not ((content[j] = '{') and (content[j + 1] = '{')),
          Utf8ToString('an unresolved token survived: ' +
            plan.Files[i].Path));
    // A11 again, on the mode, where the platform has one
    if PWebCliHasFileModes then
      Check(PWebCliExecutableBit(native) =
        (plan.Files[i].Mode = ptmExecutable),
        Utf8ToString('the mode did not take: ' + plan.Files[i].Path));
  end;
  Record_('A11 inventory exact ' + PWebPlanInventoryDigest(plan));
  Record_('A12 no unresolved token in ' +
    RawUtf8(IntToStr(Length(plan.Files))) + ' files');

  // P10 (the other half): the generated descriptor, re-read from the tree
  // that now exists and parsed by the FROZEN CAP-10A reader
  Check(PWebCliReadSmallFile(PWebCliJoin(dest, 'pweb.json'),
    PWEB_TPL_FILE_MAX_BYTES, content, tooBig));
  Record_('P10 descriptor accepted-by-frozen-reader ok');

  // A2: and a SECOND create into the same place is refused, because the
  // destination now exists
  Check(not PWebCreateProject(parent, 'demo', plan, tpl, res));
  CheckEqual(PWebCreateRefusalText(res.Refusal), 'destination_exists');
  Record_('A2 create-over-existing ' + PWebCreateRefusalText(res.Refusal));
end;

procedure TTestPWebTplAtomic.RefusesOccupiedDestination;
var
  reg: TPWebTemplateRegistry;
  tpl: TPWebTplTemplate;
  plan: TPWebCreationPlan;
  res: TPWebCreateResult;
  parent: RawUtf8;
  dir: TFileName;

  procedure Refused(const Tag, Name: RawUtf8;
    const Expected: RawUtf8);
  begin
    Check(not PWebCreateProject(parent, Name, plan, tpl, res),
      Utf8ToString('the destination was accepted: ' + Tag));
    CheckEqual(PWebCreateRefusalText(res.Refusal), Expected,
      Utf8ToString(Tag));
    CheckEqual(res.Destination, '',
      Utf8ToString('a destination was reported on a failure: ' + Tag));
    Record_('A3 destination ' + Tag + ' ' +
      PWebCreateRefusalText(res.Refusal));
  end;

begin
  Check(RealPlan(reg, tpl, plan));
  parent := CanonicalFixture('occupied');
  dir := Utf8ToString(PWebCliDisplayPath(parent));

  // A2: an existing FILE
  FileFromString('x'#10, IncludeTrailingPathDelimiter(dir) + 'afile');
  Refused('existing-file', 'afile', 'destination_exists');

  // A3: an existing EMPTY directory. Refused, deliberately: the commit IS
  // a rename, and requiring nonexistence is the one rule that behaves the
  // same on POSIX rename(2) and on Win32 MoveFileExW
  MakeDir(IncludeTrailingPathDelimiter(dir) + 'emptydir');
  Refused('existing-empty-directory', 'emptydir', 'destination_exists');

  // A4: an existing NON-EMPTY directory
  MakeDir(IncludeTrailingPathDelimiter(dir) + 'fulldir');
  FileFromString('x'#10, IncludeTrailingPathDelimiter(dir) +
    'fulldir' + PathDelim + 'inside');
  Refused('existing-nonempty-directory', 'fulldir', 'destination_exists');

  // A5: a real reparse point - an NTFS junction on Windows, a symlink on
  // POSIX. A machine that cannot create the fixture FAILS the suite rather
  // than recording a weaker corpus
  MakeDir(IncludeTrailingPathDelimiter(dir) + 'linktarget');
  Check(MakeLink(IncludeTrailingPathDelimiter(dir) + 'alink',
    IncludeTrailingPathDelimiter(dir) + 'linktarget'),
    'the link fixture could not be created - the suite refuses to record ' +
    'a link rule it did not actually test');
  Refused('destination-is-a-link', 'alink', 'destination_exists');

  // A6: a staging directory already in the way. It is NAMED and left
  // alone: reclaiming a tree this process did not create is how a
  // scaffolding tool becomes a deletion tool
  MakeDir(IncludeTrailingPathDelimiter(dir) +
    Utf8ToString(PWebStageName('staged')));
  FileFromString('x'#10, IncludeTrailingPathDelimiter(dir) +
    Utf8ToString(PWebStageName('staged')) + PathDelim + 'keepme');
  Refused('staging-directory-occupied', 'staged', 'stage_exists');
  Check(PWebCliEntry(PWebCliJoin(parent, PWebStageName('staged')),
    'keepme') = pcnFile,
    'a pre-existing staging tree was removed by a failed create');
  Record_('A6 pre-existing staging tree preserved');
end;

procedure TTestPWebTplAtomic.FailureLeavesNothing;
var
  reg: TPWebTemplateRegistry;
  tpl: TPWebTplTemplate;
  plan: TPWebCreationPlan;
  res: TPWebCreateResult;
  parent, other: RawUtf8;
  i: PtrInt;
begin
  Check(RealPlan(reg, tpl, plan));
  parent := CanonicalFixture('failure');

  // A7: a verification failure. The descriptor bytes are corrupted AFTER
  // the plan was built, so everything writes cleanly and the FROZEN reader
  // is what refuses - which is exactly the step that would catch a
  // generator and a reader that each look internally consistent
  for i := 0 to High(plan.Files) do
    if plan.Files[i].Path = 'pweb.json' then
    begin
      plan.Files[i].Content := StringReplaceAll(
        RawUtf8(plan.Files[i].Content), '"name": "demo"',
        '"name": "Demo"');
      plan.Files[i].Sha256 := PWebTplSha256Hex(plan.Files[i].Content);
    end;
  Check(not PWebCreateProject(parent, 'broken', plan, tpl, res));
  CheckEqual(PWebCreateRefusalText(res.Refusal), 'descriptor');
  // A6/A7: the final destination is ABSENT
  CheckEqual(res.Destination, '');
  Check(PWebCliEntry(parent, 'broken') = pcnMissing,
    'a failed create left a partial project behind');
  // A9: and the staged tree was reclaimed
  Check(res.StageReclaimed, 'the staged tree was not reclaimed');
  Check(not res.StageLeaked);
  Check(PWebCliEntry(parent, PWebStageName('broken')) = pcnMissing,
    'the staged tree survived a failure');
  Record_('A7 verification-failure destination-absent ' +
    PWebCreateRefusalText(res.Refusal) + ' ' +
    PWebScaffoldCodeText(res.ScaffoldCode));
  Record_('A9 staged tree reclaimed');

  // A8: the COMMIT primitive itself. A rename onto a name that exists
  // fails, and BOTH trees survive it - which is the property that makes a
  // failed commit leave the destination exactly as it was.
  //
  // It is tested on the primitive rather than by forcing PWebCreateProject
  // to fail at step 7, and that is a deliberate limitation rather than an
  // oversight: the destination is proved absent immediately before the
  // rename, so making the rename fail needs either a concurrent process
  // winning that race or a fault injector, and neither is a thing a
  // four-target suite should try to arrange. What CAN be proved exactly is
  // stated here - the primitive refuses, and every failure path in
  // PWebCreateProject clears Destination, which A2-A7 each assert.
  other := CanonicalFixture('commit');
  MakeDir(Utf8ToString(PWebCliDisplayPath(PWebCliJoin(other, 'src'))));
  MakeDir(Utf8ToString(PWebCliDisplayPath(PWebCliJoin(other, 'dst'))));
  Check(not PWebCliRenameDir(PWebCliJoin(other, 'src'),
    PWebCliJoin(other, 'dst')),
    'the commit primitive replaced an existing destination');
  Check(PWebCliEntry(other, 'src') = pcnDirectory);
  Check(PWebCliEntry(other, 'dst') = pcnDirectory);
  Record_('A8 commit refuses an existing destination, both trees intact');
end;

procedure TTestPWebTplAtomic.WorkingDirectoryIsIrrelevant;
var
  reg: TPWebTemplateRegistry;
  tpl: TPWebTplTemplate;
  plan: TPWebCreationPlan;
  res: TPWebCreateResult;
  parent, before, after, sdkBefore, sdkAfter, packBefore, packAfter: RawUtf8;
  refusal: TPWebSdkRefusal;
  saved: TFileName;
  ok: Boolean;
begin
  Check(RealPlan(reg, tpl, plan));
  parent := CanonicalFixture('cwd');
  Check(PWebCliCwd(before));
  sdkBefore := StagedSdkRoot;
  Check(PWebCliTemplatePackIn(sdkBefore, packBefore, refusal));
  saved := GetCurrentDir;
  try
    // A10: an unrelated working directory cannot redirect the template
    // pack or the destination. The SDK anchor is the running IMAGE and the
    // destination is an absolute parent, so neither consults the CWD - and
    // the whole resolution is re-run from scratch after the change rather
    // than read from something cached before it
    SetCurrentDir(Utf8ToString(PWebCliDisplayPath(parent)));
    Check(PWebCliCwd(after));
    Check(before <> after, 'the working directory did not actually change');
    sdkAfter := StagedSdkRoot;
    CheckEqual(sdkBefore, sdkAfter,
      'the SDK root moved when the working directory did');
    Check(PWebCliTemplatePackIn(sdkAfter, packAfter, refusal));
    CheckEqual(packBefore, packAfter,
      'the template pack moved when the working directory did');
    ok := PWebCreateProject(parent, 'elsewhere', plan, tpl, res);
    Check(ok, Utf8ToString(PWebCreateRefusalText(res.Refusal)));
    Check(PWebCliEntry(parent, 'elsewhere') = pcnDirectory);
  finally
    SetCurrentDir(saved);
  end;
  Record_('A10 working-directory-independent pack and destination');
end;

{ ---------------------------------------------------------------------------
  S1-S8  what a generated project may contain
  --------------------------------------------------------------------------- }

procedure TTestPWebTplSecurity.GeneratedProjectContents;
var
  reg: TPWebTemplateRegistry;
  tpl: TPWebTplTemplate;
  plan: TPWebCreationPlan;
  i: PtrInt;
  seenAttributes, seenIgnore: Boolean;
begin
  Check(RealPlan(reg, tpl, plan));
  seenAttributes := False;
  seenIgnore := False;
  for i := 0 to High(plan.Files) do
  begin
    // S1: nothing a secret classifier would refuse
    Check(not PWebTplSecretOutput(plan.Files[i].Path),
      Utf8ToString('a secret-classified path is in the plan: ' +
        plan.Files[i].Path));
    // S2/S3: no absolute host path, no home directory, no user name, in
    // ANY generated byte - text or binary
    Check(not PWebTplHasHostPath(plan.Files[i].Content),
      Utf8ToString('a host path is in a generated file: ' +
        plan.Files[i].Path));
    // S7: nothing that would make this a repository
    Check(Copy(plan.Files[i].Path, 1, 5) <> '.git/',
      'the plan would create a git directory');
    if plan.Files[i].Path = '.gitattributes' then
      seenAttributes := True;
    if plan.Files[i].Path = '.gitignore' then
      seenIgnore := True;
  end;
  // S8: the generated project pins its own line endings rather than
  // trusting whoever clones it - the divergence CAP-7F measured once
  Check(seenAttributes, 'a generated project carries no .gitattributes');
  Check(seenIgnore, 'a generated project carries no .gitignore');
  for i := 0 to High(plan.Files) do
    if plan.Files[i].Path = '.gitattributes' then
    begin
      Check(Pos(RawUtf8('eol=lf'), RawUtf8(plan.Files[i].Content)) > 0,
        'the generated .gitattributes does not pin LF');
      Check(Pos(RawUtf8('* -text'), RawUtf8(plan.Files[i].Content)) > 0,
        'the generated .gitattributes does not default to binary');
    end;
  Record_('S1 no secret output in ' + RawUtf8(IntToStr(Length(plan.Files))) +
    ' files');
  Record_('S2 no host path in any generated byte');
  Record_('S7 no repository initialised');
  Record_('S8 gitattributes pins lf and defaults to binary');
end;

procedure TTestPWebTplSecurity.SdkResolution;
var
  exeDir, root, pack, parent, junk: RawUtf8;
  refusal: TPWebSdkRefusal;
  fixture: RawUtf8;
  ok: Boolean;
begin
  // the anchor is the running IMAGE, and the root is exactly its parent
  Check(PWebCliExeDir(exeDir), 'the image directory could not be resolved');
  refusal := psrNone;
  ok := PWebCliSdkRoot(root, refusal);
  Check(ok, Utf8ToString(PWebSdkRefusalText(refusal)));
  Check(PWebCliParentDir(exeDir, parent));
  CheckEqual(root, parent, 'the SDK root is not the image directory parent');
  Record_('SDK root=parent(image) ok');

  // an SDK root with no share tree is refused, by name, rather than
  // falling back to anything
  fixture := CanonicalFixture('sdk');
  Check(not PWebCliTemplatePackIn(fixture, pack, refusal));
  CheckEqual(PWebSdkRefusalText(refusal), 'sdk_share_missing');
  Record_('SDK share-missing ' + PWebSdkRefusalText(refusal));

  // and a root that is not a directory at all
  Check(not PWebCliTemplatePackIn('', junk, refusal));
  CheckEqual(PWebSdkRefusalText(refusal), 'sdk_no_root');
  Record_('SDK empty-root ' + PWebSdkRefusalText(refusal));

  // the staged SDK resolves through the composed production entry point,
  // and the pack it names is a regular file
  ok := PWebCliTemplatePack(pack, refusal);
  Check(ok, Utf8ToString(PWebSdkRefusalText(refusal)));
  Check(PWebCliNodeKind(pack) = pcnFile);
  Record_('SDK staged pack resolved');
end;

{ ---------------------------------------------------------------------------
  the corpus
  --------------------------------------------------------------------------- }

procedure WriteCorpus;
var
  text: RawUtf8;
  i: PtrInt;
begin
  text := '# CAP-10B0 scaffold-engine decision corpus' + #10 +
    '# every line is the verdict of platform-independent logic; no path,' +
    #10 + '# no version and no timing appears here, by construction' + #10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(PWEB_CAP10B0_CORPUS_FILE));
  FileFromString(text, PWEB_CAP10B0_CORPUS_FILE);
end;

initialization

finalization
  WriteCorpus;

end.
