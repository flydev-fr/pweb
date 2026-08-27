{
  pweb.cli.write - CAP-10B0 atomic project creation.

  THE ONLY UNIT IN THE SCAFFOLD ENGINE THAT CAN CREATE ANYTHING. Everything
  it writes has already been decided: pweb.cli.scaffold produced a complete
  plan in memory, every collision and every bound was resolved there, and
  this unit's whole job is to put that plan on a disk without ever leaving a
  half-made project behind.

  ---------------------------------------------------------------------------
  THE TRANSACTION
  ---------------------------------------------------------------------------

      the parent must exist, be canonical, carry no reparse point, and be
      writable                       (a permission question, not a probe file)
        -> the destination must NOT exist, by exact spelling AND by the
           case-folding volume's own answer
        -> a sibling staging directory, created EXCLUSIVELY
        -> every file written into it, directories one level at a time
        -> the staged tree re-read from disk and compared to the plan,
           byte for byte, path for path, mode for mode - with NO extra file
        -> the generated pweb.json re-parsed by the FROZEN CAP-10A reader
           against the tree that now exists
        -> rename(staging -> destination), which is the commit

  On ANY failure the final destination remains absent, the staged tree is
  reclaimed, and nothing that already existed was touched. There is no
  copy-then-validate-then-commit step, because a commit that copies is a
  commit that can half-succeed.

  ---------------------------------------------------------------------------
  WHY THE STAGING NAME IS DETERMINISTIC, AND WHY A COLLISION IS A REFUSAL
  ---------------------------------------------------------------------------

  The staging directory is '.pweb-create-<NAME>.tmp' beside the destination.
  No randomness: the directory is created with an EXCLUSIVE primitive, so a
  name that is already taken fails in the kernel rather than in a check, and
  a random suffix would buy nothing that exclusivity has not already bought.

  When it IS taken - a killed earlier run, or a concurrent one - this unit
  REFUSES and names the directory. It does not remove it. Reclaiming a
  directory this process did not create is exactly the behaviour that turns
  a scaffolding tool into a deletion tool, and the failure it protects
  against (a developer losing a tree they were in the middle of something
  with) is worse than the failure it would fix.

  ---------------------------------------------------------------------------
  WHAT THE VERIFICATION IS FOR
  ---------------------------------------------------------------------------

  Re-reading a tree this process just wrote sounds redundant. It is not: it
  is the only thing that can catch a filesystem that normalised a name, a
  volume that folded a case, a mode that did not take, a short write, or a
  file that some other process dropped into the staging directory while it
  was open. The comparison is in BOTH directions - every planned file must
  be there with the exact bytes, and NOTHING else may be.
}
unit pweb.cli.write;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.template,
  pweb.cli.scaffold;

const
  /// the staging directory's fixed prefix and suffix. A dot-leading name
  // so it is unobtrusive on POSIX, and a name no project of ours can have
  PWEB_STAGE_PREFIX = '.pweb-create-';
  PWEB_STAGE_SUFFIX = '.tmp';
  /// how deep the verification walk will go before refusing. The plan's
  // own path bound makes anything deeper impossible for a tree we wrote
  PWEB_STAGE_MAX_DEPTH = 16;

type
  /// why a creation failed - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebCreateRefusal = (
    pcwNone,
    /// the destination parent is missing, not a directory, or a link
    pcwParent,
    /// the destination parent refused write access
    pcwParentNotWritable,
    /// something already carries the destination name
    pcwDestinationExists,
    /// nothing carries it by exact spelling, but the volume resolves it
    /// anyway - a case-colliding sibling
    pcwDestinationCase,
    /// a staging directory of that name is already there
    pcwStageExists,
    /// the staging directory could not be created
    pcwStageCreate,
    /// a directory or a file could not be written
    pcwWrite,
    /// the staged tree is not what the plan said
    pcwVerify,
    /// an intended file mode did not survive the write
    pcwMode,
    /// the generated descriptor did not survive the frozen reader
    pcwDescriptor,
    /// the rename that commits the transaction failed
    pcwCommit);

  /// everything one creation attempt learned
  TPWebCreateResult = record
    /// pcwNone only when the destination now exists and holds the plan
    Refusal: TPWebCreateRefusal;
    /// set when Refusal is pcwDescriptor or pcwVerify carried a scaffold
    /// verdict; pscNone otherwise
    ScaffoldCode: TPWebScaffoldCode;
    /// which path or field caused it - machine-stable, never prose
    Detail: RawUtf8;
    /// the destination that was attempted (absent on every failure)
    Destination: RawUtf8;
    /// the staging directory that was used
    StagePath: RawUtf8;
    /// True when a staged tree was created AND fully reclaimed
    StageReclaimed: Boolean;
    /// True when a staged tree was created and could NOT be reclaimed -
    /// recorded rather than hidden, because a leftover directory is
    /// something a human has to be told about
    StageLeaked: Boolean;
    FilesWritten: Integer;
    BytesWritten: Int64;
    /// how many files carried an intended executable mode, and whether
    /// this platform could express it at all
    ExecutableFiles: Integer;
    ModesApplicable: Boolean;
  end;

/// fixed diagnostic text for a refusal - the machine authority
function PWebCreateRefusalText(Refusal: TPWebCreateRefusal): RawUtf8;

/// the staging directory name for one destination name
function PWebStageName(const Name: RawUtf8): RawUtf8;

/// execute the whole transaction
// - ParentDir MUST already be canonical (PWebCliCanonicalDir); this unit
// re-proves it rather than establishing it, so a caller that skipped the
// step cannot be granted a confinement it never had
// - Name is the destination directory name, which is also the project name
// - on False the final destination is ABSENT and nothing that existed
// before the call was modified
function PWebCreateProject(const ParentDir, Name: RawUtf8;
  const Plan: TPWebCreationPlan; const Tpl: TPWebTplTemplate;
  out Res: TPWebCreateResult): Boolean;


implementation

const
  PWEB_CREATE_REFUSAL_TEXT: array[TPWebCreateRefusal] of RawUtf8 = (
    'ok',
    'parent',
    'parent_not_writable',
    'destination_exists',
    'destination_case',
    'stage_exists',
    'stage_create',
    'write',
    'verify',
    'mode',
    'descriptor',
    'commit');

function PWebCreateRefusalText(Refusal: TPWebCreateRefusal): RawUtf8;
begin
  Result := PWEB_CREATE_REFUSAL_TEXT[Refusal];
end;

function PWebStageName(const Name: RawUtf8): RawUtf8;
begin
  Result := PWEB_STAGE_PREFIX + Name + PWEB_STAGE_SUFFIX;
end;

function IntStr(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

{ Split a project-relative logical path into its segments. The plan already
  guarantees the grammar, so this is a split and not a parse. }
function Segments(const Path: RawUtf8): TRawUtf8DynArray;
var
  i, start, n: PtrInt;
begin
  Result := nil;
  n := 0;
  start := 1;
  for i := 1 to Length(Path) + 1 do
    if (i > Length(Path)) or
       (Path[i] = '/') then
    begin
      SetLength(Result, n + 1);
      Result[n] := Copy(Path, start, i - start);
      Inc(n);
      start := i + 1;
    end;
end;

function Known(const List: TRawUtf8DynArray; const Item: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := True;
  for i := 0 to High(List) do
    if List[i] = Item then
      exit;
  Result := False;
end;

{ Collect the ACTUAL contents of a written tree, as logical paths relative
  to Root. Used for the both-directions comparison: a file nobody planned
  is as much a failure as a planned file that is missing. }
function CollectTree(const Root, Prefix: RawUtf8; Depth: Integer;
  var Paths: TRawUtf8DynArray; var Detail: RawUtf8): Boolean;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  child, logical: RawUtf8;
begin
  Result := False;
  if Depth > PWEB_STAGE_MAX_DEPTH then
  begin
    Detail := 'staged tree deeper than the plan can be';
    exit;
  end;
  if not PWebCliListDir(Root, names) then
  begin
    Detail := 'the staged tree could not be enumerated';
    exit;
  end;
  for i := 0 to High(names) do
  begin
    child := PWebCliJoin(Root, names[i]);
    if Prefix = '' then
      logical := names[i]
    else
      logical := Prefix + '/' + names[i];
    case PWebCliNodeKind(child) of
      pcnFile:
        begin
          SetLength(Paths, Length(Paths) + 1);
          Paths[High(Paths)] := logical;
        end;
      pcnDirectory:
        if not CollectTree(child, logical, Depth + 1, Paths, Detail) then
          exit;
    else
      // a link or a device inside a tree this process just wrote is not
      // something to reconcile: it is something to refuse
      Detail := 'unexpected entry: ' + logical;
      exit;
    end;
  end;
  Result := True;
end;

function PWebCreateProject(const ParentDir, Name: RawUtf8;
  const Plan: TPWebCreationPlan; const Tpl: TPWebTplTemplate;
  out Res: TPWebCreateResult): Boolean;
var
  reproof, stageName, stage, dest, native, dir, rel: RawUtf8;
  created, seg, actual: TRawUtf8DynArray;
  content: RawByteString;
  i, j: PtrInt;
  tooBig, staged: Boolean;
  scode: TPWebScaffoldCode;
  detail: RawUtf8;

  function Fail(R: TPWebCreateRefusal; const D: RawUtf8): Boolean;
  begin
    Res.Refusal := R;
    Res.Detail := D;
    // the destination is ABSENT on every failure path, so it is never
    // reported as though something had been made
    Res.Destination := '';
    if staged then
    begin
      if PWebCliRemoveStagedTree(ParentDir, stageName) then
        Res.StageReclaimed := True
      else
        Res.StageLeaked := True;
    end;
    Result := False;
  end;

begin
  Res := Default(TPWebCreateResult);
  Res.ScaffoldCode := pscNone;
  Res.ModesApplicable := PWebCliHasFileModes;
  staged := False;
  stageName := PWebStageName(Name);
  stage := '';
  dest := '';
  // ---- 1. the parent. Re-proved through the kernel rather than trusted:
  // a caller that handed us a spelled path must not thereby be granted a
  // confinement it never established ----
  if (ParentDir = '') or
     not PWebCliCanonicalDir(ParentDir, reproof) or
     (reproof <> ParentDir) then
    exit(Fail(pcwParent, 'the destination parent is not a canonical directory'));
  if not PWebCliDirWritable(ParentDir) then
    exit(Fail(pcwParentNotWritable, ''));
  // ---- 2. the destination must not exist. Twice, because the two
  // questions are genuinely different: PWebCliEntry reads the directory and
  // compares byte-exactly, PWebCliNodeKind asks the volume - and on NTFS or
  // a default APFS volume the second can resolve what the first could not
  // find ----
  dest := PWebCliJoin(ParentDir, Name);
  if PWebCliEntry(ParentDir, Name) <> pcnMissing then
    exit(Fail(pcwDestinationExists, Name));
  if PWebCliNodeKind(dest) <> pcnMissing then
    exit(Fail(pcwDestinationCase, Name));
  // ---- 3. the staging directory, in the SAME parent so the commit is a
  // same-filesystem rename ----
  stage := PWebCliJoin(ParentDir, stageName);
  Res.StagePath := stage;
  if (PWebCliEntry(ParentDir, stageName) <> pcnMissing) or
     (PWebCliNodeKind(stage) <> pcnMissing) then
    // NOT removed: see the unit header. A stale staging tree is named and
    // left alone
    exit(Fail(pcwStageExists, stageName));
  if not PWebCliCreateDir(stage) then
    exit(Fail(pcwStageCreate, stageName));
  staged := True;
  // ---- 4. write. Directories ONE LEVEL AT A TIME through a primitive
  // that fails loudly: FPC 3.2.2's recursive ForceDirectories was MEASURED
  // during CAP-10A to return False while creating nothing, and a fixture
  // that silently fails to exist looks exactly like a working refusal ----
  created := nil;
  for i := 0 to High(Plan.Files) do
  begin
    seg := Segments(Plan.Files[i].Path);
    dir := stage;
    rel := '';
    for j := 0 to High(seg) - 1 do
    begin
      if rel = '' then
        rel := seg[j]
      else
        rel := rel + '/' + seg[j];
      dir := PWebCliJoin(dir, seg[j]);
      if not Known(created, rel) then
      begin
        if not PWebCliCreateDir(dir) then
          exit(Fail(pcwWrite, rel));
        SetLength(created, Length(created) + 1);
        created[High(created)] := rel;
      end;
    end;
    native := PWebCliJoin(dir, seg[High(seg)]);
    if not PWebCliWriteNewFile(native, Plan.Files[i].Content,
         Plan.Files[i].Mode = ptmExecutable) then
      exit(Fail(pcwWrite, Plan.Files[i].Path));
    Inc(Res.FilesWritten);
    Inc(Res.BytesWritten, Length(Plan.Files[i].Content));
    if Plan.Files[i].Mode = ptmExecutable then
      Inc(Res.ExecutableFiles);
  end;
  // ---- 5. read the tree back. Both directions ----
  actual := nil;
  detail := '';
  if not CollectTree(stage, '', 0, actual, detail) then
    exit(Fail(pcwVerify, detail));
  if Length(actual) <> Length(Plan.Files) then
    exit(Fail(pcwVerify, IntStr(Length(actual)) + ' files on disk vs ' +
      IntStr(Length(Plan.Files)) + ' planned'));
  for i := 0 to High(Plan.Files) do
  begin
    if not Known(actual, Plan.Files[i].Path) then
      exit(Fail(pcwVerify, 'missing: ' + Plan.Files[i].Path));
    seg := Segments(Plan.Files[i].Path);
    native := stage;
    for j := 0 to High(seg) do
      native := PWebCliJoin(native, seg[j]);
    if not PWebCliReadSmallFile(native, PWEB_TPL_FILE_MAX_BYTES,
         content, tooBig) then
      exit(Fail(pcwVerify, 'unreadable: ' + Plan.Files[i].Path));
    if content <> Plan.Files[i].Content then
      exit(Fail(pcwVerify, 'bytes: ' + Plan.Files[i].Path));
    // the mode, where the platform has one. On Windows the question is not
    // asked at all, and ModesApplicable records that it was not
    if Res.ModesApplicable and
       (PWebCliExecutableBit(native) <>
          (Plan.Files[i].Mode = ptmExecutable)) then
      exit(Fail(pcwMode, Plan.Files[i].Path));
  end;
  // ---- 6. the descriptor, re-parsed by the FROZEN reader against the
  // tree that now exists. This is the step that would catch a generator
  // and a reader that are each internally consistent and still disagree ----
  native := PWebCliJoin(stage, PWEB_SCAFFOLD_DESCRIPTOR);
  if not PWebCliReadSmallFile(native, PWEB_TPL_FILE_MAX_BYTES,
       content, tooBig) then
    exit(Fail(pcwDescriptor, 'unreadable'));
  if not PWebVerifyDescriptor(stage, RawUtf8(content), Plan.Identity, Tpl,
       scode, detail) then
  begin
    Res.ScaffoldCode := scode;
    exit(Fail(pcwDescriptor, PWebScaffoldCodeText(scode) + ':' + detail));
  end;
  // ---- 7. THE COMMIT. Same parent, one filesystem, and a primitive that
  // must not replace ----
  if not PWebCliRenameDir(stage, dest) then
    exit(Fail(pcwCommit, Name));
  staged := False;
  Res.Destination := dest;
  Res.Refusal := pcwNone;
  Result := True;
end;

end.
