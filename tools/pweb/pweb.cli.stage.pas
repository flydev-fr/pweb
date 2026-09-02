{
  pweb.cli.stage - the pipeline's file operations, and the TypeScript SDK
  materialisation (CAP-10C1).

  THE ONLY PLACE THE PIPELINE ITSELF WRITES A BYTE. Every stage that runs a
  tool writes through that tool; everything the pipeline puts on a disk by
  itself - the staged SDK, the assembled Pas2JS static set, the release
  layout - goes through this unit, over the CAP-10B0 write primitives in
  pweb.cli.platform:

    PWebCliCreateDir       one level, EXCLUSIVELY, never recursively
    PWebCliWriteNewFile    create-or-fail, never opens, truncates, appends
                           to or follows an existing name
    PWebCliRemoveStagedTree  a guarded recursive removal that refuses a link,
                           a device or anything unremovable anywhere in the
                           tree, and leaves the rest alone

  There is no delete primitive here that can be aimed at a path this process
  did not build, and no write primitive that can replace something it did
  not create. That is the whole of the safety argument, and it is inherited
  rather than restated.

  ---------------------------------------------------------------------------
  THE COPY IS BOUNDED, AND THAT IS DELIBERATE
  ---------------------------------------------------------------------------

  A file is copied by reading it whole through PWebCliReadSmallFile with
  PWEB_CLI_PIPE_MAX_FILE_BYTES and writing it back through
  PWebCliWriteNewFile. Two consequences, both wanted: the read refuses a
  symlink on the final component (so a staged tree can never be made to copy
  something from outside itself), and a file past the bound is a TYPED
  REFUSAL rather than a partial copy. The bound covers a native executable
  and a mORMot static archive with room to spare; a build artifact larger
  than a quarter of a gigabyte is a fact somebody should look at.

  The POSIX execute bit is carried across, because a release executable that
  arrived without it is a layout `pweb run` refuses (prrLayoutNotExecutable)
  three stages later, for a reason nothing would name.

  ---------------------------------------------------------------------------
  THE TREE DIGEST IS THE MUTATION GATE
  ---------------------------------------------------------------------------

  PWebCliPipeTreeDigest projects a tree to `<rel>|<size>|<sha256>` lines,
  BYTEWISE-sorted and joined by LF, and digests that. Bytewise, never a
  culture-aware or case-insensitive comparison: CAP-10B1 MEASURED (hosted run
  33126638202) the same generated tree digesting differently on Windows and
  Linux because `App.tsx` and `app.css` order one way under a culture
  comparison and the other way under a byte comparison, and a four-target
  equality field cannot survive a comparer that disagrees with itself.

  Exclusions are root-relative LOGICAL prefixes matched on a component
  boundary, so `frontend/dist` excludes that directory and everything under
  it and never `frontend/dist-backup`.

  ---------------------------------------------------------------------------
  THE TYPESCRIPT SDK: THE stage-ts-sdk.mjs RULE, IN PASCAL
  ---------------------------------------------------------------------------

  A generated project declares @pweb/runtime as a project-relative `file:`
  specifier. Something has to put a package where that specifier points, and
  until now that something was `node tools/stage-ts-sdk.mjs`. The rule is
  ported rather than driven, so a Pas2JS project needs no Node at any point
  of its pipeline and the React pipeline has one fewer script to trust.

  What is emitted is byte-for-byte what the script emits, and
  test/cap10c1 proves that against the script on all four targets:

    package.json   the canonical distribution manifest - name, version,
                   license, type, main, types, exports, IN THAT ORDER, taken
                   from the development manifest rather than restated, with
                   two-space indent, LF, and exactly one trailing newline
                   (JSON.stringify(value, null, 2) + "\n");
    dist/src/**    the built JavaScript and its declarations, verbatim, in
                   bytewise name order. dist/test is excluded: a `file:`
                   dependency is LINKED rather than packed, so the package's
                   own `files` field filters nothing.

  ONLY STRINGS AND OBJECTS OF STRINGS ARE ACCEPTED in those seven values. A
  number, an array, a boolean or a null is refused with sdk_manifest_shape
  rather than re-serialised, because re-emitting a JSON number the way
  JavaScript would is a guess, and a manifest that grew one is a change to
  the SDK that deserves a review rather than a silent re-encoding.

  The destination is REMOVED first and never merged. A stale file surviving
  into a staged SDK is the one failure this rule exists to prevent, and it
  is the failure that would otherwise be invisible: the frontend would
  typecheck against a declaration nothing produces any more.
}
unit pweb.cli.stage;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.toolchain;

type
  /// ONE child the pipeline will run: an exact executable, an argument
  // vector, an explicit working directory - and nothing else, ever
  // - every stage unit produces one of these as a PURE FUNCTION of the
  // project, the SDK layout and the toolset, which is what lets the whole
  // four-target command matrix be asserted from any single target
  TPWebCliCommand = record
    Exe: RawUtf8;
    Args: TRawUtf8DynArray;
    WorkDir: RawUtf8;
  end;

  /// why a file operation or a staging failed - one cause each
  // - ordinal 0 is the accepted state
  TPWebCliStageRefusal = (
    pstNone,
    /// a source file is absent, is a link, or is not a regular file
    pstSourceMissing,
    /// a source file exceeds PWEB_CLI_PIPE_MAX_FILE_BYTES
    pstSourceTooBig,
    /// a source directory could not be enumerated
    pstSourceUnreadable,
    /// a directory could not be created (the name is taken, or refused)
    pstCreateDir,
    /// a file could not be written (the name is taken, or refused)
    pstWriteFile,
    /// an existing tree could not be reclaimed
    pstRemoveTree,
    /// the walk exceeded PWEB_CLI_PIPE_MAX_TREE_FILES or _MAX_TREE_DEPTH
    pstTreeTooLarge,
    /// the SDK manifest is absent or unreadable
    pstManifestMissing,
    /// the SDK manifest is not one well-formed JSON object
    pstManifestMalformed,
    /// the SDK manifest lacks one of the seven canonical keys
    pstManifestField,
    /// a canonical value is neither a string nor an object of strings
    pstManifestShape,
    /// the SDK is not built: dist/src/index.js is absent
    pstSdkNotBuilt);

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliStageRefusalText(Refusal: TPWebCliStageRefusal): RawUtf8;

/// bytewise ascending sort of a name list, in place
// - ORDINAL, never a culture comparison: see the unit header
procedure PWebCliSortBytewise(var Names: TRawUtf8DynArray);

/// the form of a path that is handed to a TOOL as an ARGUMENT
// - MEASURED: this CLI canonicalizes Windows paths into the extended-length
// form (\\?\C:\...) because that is the headroom the confinement walk needs,
// and pweb.cli.platform strips it again for the executable, for argv[0] and
// for the working directory. It does NOT strip it from the other arguments,
// because those are the caller's strings - and a tool handed one does not
// necessarily understand it: `node \\?\C:\...\npm-cli.js --version` dies in
// realpathSync with `EISDIR: illegal operation on a directory, lstat 'C:'`,
// because Node splits the prefixed path and asks the filesystem about `C:`.
// - so EVERY path this pipeline puts INTO an argument goes through here, and
// pweb.cli.pipeline refuses to spawn a vector that still carries the prefix
// - identity on POSIX, which has no such form
function PWebCliArgPath(const Path: RawUtf8): RawUtf8;

/// replace every absolute prefix by its logical token, and both path
/// separators by '/'
// - Prefixes are tried in the order given, so a caller lists the longest
// first and a nested root can never be masked by its parent
function PWebCliRedact(const Text: RawUtf8;
  const Prefixes, Tokens: TRawUtf8DynArray): RawUtf8;

/// the logical projection of ONE command: `<exe> <arg> ...` with every
/// absolute path replaced by its token
// - this, and never the raw vector, is what reaches an evidence file: it
// carries no absolute path, no home directory and no SDK location, and it
// is byte-comparable across four targets whose real paths differ entirely
function PWebCliCommandText(const Cmd: TPWebCliCommand;
  const Prefixes, Tokens: TRawUtf8DynArray): RawUtf8;

/// True when Logical equals one of Prefixes or lies under one of them on a
/// component boundary
function PWebCliUnderAnyPrefix(const Logical: RawUtf8;
  const Prefixes: TRawUtf8DynArray): Boolean;

/// copy ONE regular file, bounded, carrying the POSIX execute bit across
function PWebCliPipeCopyFile(const FromPath, ToPath: RawUtf8;
  out Refusal: TPWebCliStageRefusal): Boolean;

/// create one directory if it is not already there, and answer its path
// - an existing DIRECTORY of that exact name is success; anything else
// (a file, a link) is pstCreateDir, because this never replaces
function PWebCliPipeEnsureDir(const Parent, Name: RawUtf8;
  out Full: RawUtf8; out Refusal: TPWebCliStageRefusal): Boolean;

/// create a nested chain of directories beneath a canonical root, one level
/// at a time, and answer the deepest one
// - Logical is forward-slash and root-relative; empty means Root itself
function PWebCliPipeEnsurePath(const Root, Logical: RawUtf8;
  out Full: RawUtf8; out Refusal: TPWebCliStageRefusal): Boolean;

/// reclaim a tree this pipeline built - Parent canonical, Name one component
// - absent is success: the caller wants the name free, not a removal
function PWebCliPipeRemoveTree(const Parent, Name: RawUtf8;
  out Refusal: TPWebCliStageRefusal): Boolean;

/// copy a whole directory tree, bytewise-ordered, bounded
// - ToDir must already exist and should be empty; nothing is replaced
function PWebCliPipeCopyTree(const FromDir, ToDir: RawUtf8;
  out Files: Integer; out Refusal: TPWebCliStageRefusal): Boolean;

/// the `<rel>|<size>|<sha256>` projection of a tree, bytewise-sorted
// - Excludes are root-relative logical prefixes; a link is recorded as
// `<rel>|link` and never followed
function PWebCliPipeTreeLines(const Root: RawUtf8;
  const Excludes: TRawUtf8DynArray; out Lines: RawUtf8; out Files: Integer;
  out Refusal: TPWebCliStageRefusal): Boolean;

/// lowercase hexadecimal SHA-256 of the projection above
function PWebCliPipeTreeDigest(const Root: RawUtf8;
  const Excludes: TRawUtf8DynArray; out Digest: RawUtf8;
  out Refusal: TPWebCliStageRefusal): Boolean;

/// the canonical distribution manifest for a development SDK manifest
// - the exact bytes tools/stage-ts-sdk.mjs writes, newline included
function PWebCliSdkManifest(const DevManifest: RawUtf8;
  out Canonical: RawUtf8; out Refusal: TPWebCliStageRefusal): Boolean;

/// materialise the pinned TypeScript SDK from SrcDir into DestParent/DestName
// - the destination is removed first and never merged
function PWebCliStageTsSdk(const SrcDir, DestParent, DestName: RawUtf8;
  out Files: Integer; out Refusal: TPWebCliStageRefusal): Boolean;


implementation

function PWebCliStageRefusalText(Refusal: TPWebCliStageRefusal): RawUtf8;
begin
  case Refusal of
    pstNone:               Result := 'ok';
    pstSourceMissing:      Result := 'source_missing';
    pstSourceTooBig:       Result := 'source_too_big';
    pstSourceUnreadable:   Result := 'source_unreadable';
    pstCreateDir:          Result := 'create_dir_failed';
    pstWriteFile:          Result := 'write_file_failed';
    pstRemoveTree:         Result := 'remove_tree_failed';
    pstTreeTooLarge:       Result := 'tree_too_large';
    pstManifestMissing:    Result := 'sdk_manifest_missing';
    pstManifestMalformed:  Result := 'sdk_manifest_malformed';
    pstManifestField:      Result := 'sdk_manifest_field';
    pstManifestShape:      Result := 'sdk_manifest_shape';
    pstSdkNotBuilt:        Result := 'sdk_not_built';
  else
    Result := 'stage_refused';
  end;
end;

// bytewise, and therefore identical to `LC_ALL=C sort` and to
// StringComparer.Ordinal - see the unit header for what happens otherwise
function CompareBytewise(const A, B: RawUtf8): Integer;
var
  i, n: PtrInt;
begin
  n := Length(A);
  if Length(B) < n then
    n := Length(B);
  for i := 1 to n do
  begin
    Result := Ord(A[i]) - Ord(B[i]);
    if Result <> 0 then
      exit;
  end;
  Result := Length(A) - Length(B);
end;

procedure PWebCliSortBytewise(var Names: TRawUtf8DynArray);
var
  i, j: PtrInt;
  tmp: RawUtf8;
begin
  // insertion sort: these lists are directory entries and project files,
  // never large, and one obvious comparison beats a clever one nobody reads
  for i := 1 to High(Names) do
  begin
    tmp := Names[i];
    j := i - 1;
    while (j >= 0) and
          (CompareBytewise(Names[j], tmp) > 0) do
    begin
      Names[j + 1] := Names[j];
      Dec(j);
    end;
    Names[j + 1] := tmp;
  end;
end;

function PWebCliArgPath(const Path: RawUtf8): RawUtf8;
begin
  Result := PWebCliDisplayPath(Path);
end;

// replace every occurrence of From by ToText, without a regex and without
// re-scanning what was just substituted
function ReplaceAll(const Text, From, ToText: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := '';
  if (From = '') or
     (Text = '') then
  begin
    Result := Text;
    exit;
  end;
  i := 1;
  while i <= Length(Text) do
    if (i + Length(From) - 1 <= Length(Text)) and
       (Copy(Text, i, Length(From)) = From) then
    begin
      Result := Result + ToText;
      Inc(i, Length(From));
    end
    else
    begin
      Result := Result + Text[i];
      Inc(i);
    end;
end;

function PWebCliRedact(const Text: RawUtf8;
  const Prefixes, Tokens: TRawUtf8DynArray): RawUtf8;
var
  i: PtrInt;
begin
  Result := Text;
  for i := 0 to High(Prefixes) do
    if (Prefixes[i] <> '') and
       (i <= High(Tokens)) then
      Result := ReplaceAll(Result, Prefixes[i], Tokens[i]);
  // one separator in the projection, so a Windows vector and a POSIX one
  // that say the same thing digest the same
  for i := 1 to Length(Result) do
    if Result[i] = '\' then
      Result[i] := '/';
end;

function PWebCliCommandText(const Cmd: TPWebCliCommand;
  const Prefixes, Tokens: TRawUtf8DynArray): RawUtf8;
var
  i: PtrInt;
begin
  Result := PWebCliRedact(Cmd.Exe, Prefixes, Tokens);
  for i := 0 to High(Cmd.Args) do
    Result := Result + ' ' + PWebCliRedact(Cmd.Args[i], Prefixes, Tokens);
end;

function PWebCliUnderAnyPrefix(const Logical: RawUtf8;
  const Prefixes: TRawUtf8DynArray): Boolean;
var
  i: PtrInt;
begin
  Result := True;
  for i := 0 to High(Prefixes) do
    if Prefixes[i] <> '' then
      if (Logical = Prefixes[i]) or
         ((Length(Logical) > Length(Prefixes[i])) and
          (Logical[Length(Prefixes[i]) + 1] = '/') and
          (Copy(Logical, 1, Length(Prefixes[i])) = Prefixes[i])) then
        exit;
  Result := False;
end;

function PWebCliPipeCopyFile(const FromPath, ToPath: RawUtf8;
  out Refusal: TPWebCliStageRefusal): Boolean;
var
  content: RawByteString;
  tooBig, execBit: Boolean;
begin
  Result := False;
  Refusal := pstSourceMissing;
  // the execute bit is read BEFORE the copy, from the source, because the
  // destination cannot answer for it and a release executable that lost it
  // is refused by the run layout three stages later
  execBit := PWebCliHasFileModes and PWebCliExecutableBit(FromPath);
  if not PWebCliReadSmallFile(FromPath, PWEB_CLI_PIPE_MAX_FILE_BYTES,
       content, tooBig) then
  begin
    if tooBig then
      Refusal := pstSourceTooBig;
    exit;
  end;
  if not PWebCliWriteNewFile(ToPath, content, execBit) then
  begin
    Refusal := pstWriteFile;
    exit;
  end;
  Refusal := pstNone;
  Result := True;
end;

function PWebCliPipeEnsureDir(const Parent, Name: RawUtf8;
  out Full: RawUtf8; out Refusal: TPWebCliStageRefusal): Boolean;
var
  kind: TPWebCliNodeKind;
begin
  Full := '';
  Refusal := pstCreateDir;
  Result := False;
  kind := PWebCliEntry(Parent, Name);
  if kind = pcnDirectory then
  begin
    Full := PWebCliJoin(Parent, Name);
    Refusal := pstNone;
    Result := True;
    exit;
  end;
  // anything else already carrying that name - a file, a link, a device -
  // is refused rather than removed: this unit never replaces
  if kind <> pcnMissing then
    exit;
  if not PWebCliCreateDir(PWebCliJoin(Parent, Name)) then
    exit;
  Full := PWebCliJoin(Parent, Name);
  Refusal := pstNone;
  Result := True;
end;

function PWebCliPipeEnsurePath(const Root, Logical: RawUtf8;
  out Full: RawUtf8; out Refusal: TPWebCliStageRefusal): Boolean;
var
  i, start: PtrInt;
  segment, cur, next: RawUtf8;
begin
  Full := Root;
  Refusal := pstNone;
  Result := True;
  cur := Root;
  start := 1;
  for i := 1 to Length(Logical) + 1 do
    if (i > Length(Logical)) or
       (Logical[i] = '/') then
    begin
      segment := Copy(Logical, start, i - start);
      start := i + 1;
      if segment = '' then
        continue;
      if not PWebCliPipeEnsureDir(cur, segment, next, Refusal) then
      begin
        Full := '';
        Result := False;
        exit;
      end;
      cur := next;
    end;
  Full := cur;
end;

function PWebCliPipeRemoveTree(const Parent, Name: RawUtf8;
  out Refusal: TPWebCliStageRefusal): Boolean;
begin
  Refusal := pstNone;
  Result := True;
  case PWebCliEntry(Parent, Name) of
    pcnMissing:
      exit; // the caller wants the name free, and it is
    pcnDirectory:
      if PWebCliRemoveStagedTree(Parent, Name) then
        exit;
  end;
  Refusal := pstRemoveTree;
  Result := False;
end;

// the recursive half of PWebCliPipeCopyTree
function CopyInto(const FromDir, ToDir: RawUtf8; Depth: Integer;
  var Files: Integer; out Refusal: TPWebCliStageRefusal): Boolean;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  child, src, dst: RawUtf8;
begin
  Result := False;
  Refusal := pstTreeTooLarge;
  if Depth > PWEB_CLI_PIPE_MAX_TREE_DEPTH then
    exit;
  Refusal := pstSourceUnreadable;
  if not PWebCliListDir(FromDir, names) then
    exit;
  PWebCliSortBytewise(names);
  for i := 0 to High(names) do
  begin
    src := PWebCliJoin(FromDir, names[i]);
    dst := PWebCliJoin(ToDir, names[i]);
    case PWebCliNodeKind(src) of
      pcnDirectory:
        begin
          if not PWebCliPipeEnsureDir(ToDir, names[i], child, Refusal) then
            exit;
          if not CopyInto(src, child, Depth + 1, Files, Refusal) then
            exit;
        end;
      pcnFile:
        begin
          Inc(Files);
          if Files > PWEB_CLI_PIPE_MAX_TREE_FILES then
          begin
            Refusal := pstTreeTooLarge;
            exit;
          end;
          if not PWebCliPipeCopyFile(src, dst, Refusal) then
            exit;
        end;
    else
      // a link, a device, a FIFO: never copied, never followed, and never
      // silently skipped either
      begin
        Refusal := pstSourceMissing;
        exit;
      end;
    end;
  end;
  Refusal := pstNone;
  Result := True;
end;

function PWebCliPipeCopyTree(const FromDir, ToDir: RawUtf8;
  out Files: Integer; out Refusal: TPWebCliStageRefusal): Boolean;
begin
  Files := 0;
  Result := CopyInto(FromDir, ToDir, 0, Files, Refusal);
end;

// the recursive half of PWebCliPipeTreeLines
function ProjectInto(const Root, Dir, Rel: RawUtf8;
  const Excludes: TRawUtf8DynArray; Depth: Integer; var Files: Integer;
  var Lines: TRawUtf8DynArray; out Refusal: TPWebCliStageRefusal): Boolean;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  full, logical: RawUtf8;
  content: RawByteString;
  tooBig: Boolean;
begin
  Result := False;
  Refusal := pstTreeTooLarge;
  if Depth > PWEB_CLI_PIPE_MAX_TREE_DEPTH then
    exit;
  Refusal := pstSourceUnreadable;
  if not PWebCliListDir(Dir, names) then
    exit;
  PWebCliSortBytewise(names);
  for i := 0 to High(names) do
  begin
    if Rel = '' then
      logical := names[i]
    else
      logical := Rel + '/' + names[i];
    if PWebCliUnderAnyPrefix(logical, Excludes) then
      continue;
    full := PWebCliJoin(Dir, names[i]);
    case PWebCliNodeKind(full) of
      pcnDirectory:
        if not ProjectInto(Root, full, logical, Excludes, Depth + 1, Files,
             Lines, Refusal) then
          exit;
      pcnFile:
        begin
          Inc(Files);
          if Files > PWEB_CLI_PIPE_MAX_TREE_FILES then
          begin
            Refusal := pstTreeTooLarge;
            exit;
          end;
          if not PWebCliReadSmallFile(full, PWEB_CLI_PIPE_MAX_FILE_BYTES,
               content, tooBig) then
          begin
            if tooBig then
              Refusal := pstSourceTooBig
            else
              Refusal := pstSourceMissing;
            exit;
          end;
          SetLength(Lines, Length(Lines) + 1);
          Lines[High(Lines)] := logical + '|' +
            RawUtf8(IntToStr(Length(content))) + '|' +
            LowerCaseU(Sha256(content));
        end;
    else
      // a link inside the measured tree is RECORDED rather than followed:
      // its presence is exactly the kind of change the gate exists to see
      begin
        SetLength(Lines, Length(Lines) + 1);
        Lines[High(Lines)] := logical + '|link';
      end;
    end;
  end;
  Refusal := pstNone;
  Result := True;
end;

function PWebCliPipeTreeLines(const Root: RawUtf8;
  const Excludes: TRawUtf8DynArray; out Lines: RawUtf8; out Files: Integer;
  out Refusal: TPWebCliStageRefusal): Boolean;
var
  rows: TRawUtf8DynArray;
  i: PtrInt;
begin
  Lines := '';
  Files := 0;
  rows := nil;
  Result := ProjectInto(Root, Root, '', Excludes, 0, Files, rows, Refusal);
  if not Result then
    exit;
  // the walk already visits each directory in bytewise order, but the
  // projection is sorted again so the answer is a property of the NAMES and
  // never of the order the walk happened to take
  PWebCliSortBytewise(rows);
  for i := 0 to High(rows) do
    Lines := Lines + rows[i] + #10;
end;

function PWebCliPipeTreeDigest(const Root: RawUtf8;
  const Excludes: TRawUtf8DynArray; out Digest: RawUtf8;
  out Refusal: TPWebCliStageRefusal): Boolean;
var
  lines: RawUtf8;
  files: Integer;
begin
  Digest := '';
  Result := PWebCliPipeTreeLines(Root, Excludes, lines, files, Refusal);
  if Result then
    Digest := LowerCaseU(Sha256(lines));
end;

{ ---------------------------------------------------------------------------
  the manifest reader: strings and objects of strings, and nothing else
  --------------------------------------------------------------------------- }

type
  TManifestScan = record
    Text: RawUtf8;
    Pos: PtrInt;
    Ok: Boolean;
  end;

procedure SkipWs(var S: TManifestScan);
begin
  while (S.Pos <= Length(S.Text)) and
        (S.Text[S.Pos] in [' ', #9, #10, #13]) do
    Inc(S.Pos);
end;

// read one JSON string and return its RAW SOURCE BYTES including the quotes
function ReadRawString(var S: TManifestScan): RawUtf8;
var
  start: PtrInt;
begin
  Result := '';
  SkipWs(S);
  if (S.Pos > Length(S.Text)) or
     (S.Text[S.Pos] <> '"') then
  begin
    S.Ok := False;
    exit;
  end;
  start := S.Pos;
  Inc(S.Pos);
  while S.Pos <= Length(S.Text) do
  begin
    if S.Text[S.Pos] = '\' then
    begin
      // an escape consumes its introducer and one more byte; a \u escape's
      // four hex digits are ordinary bytes to a scanner that only has to
      // find the closing quote
      Inc(S.Pos, 2);
      continue;
    end;
    if S.Text[S.Pos] = '"' then
    begin
      Inc(S.Pos);
      Result := Copy(S.Text, start, S.Pos - start);
      exit;
    end;
    Inc(S.Pos);
  end;
  S.Ok := False;
end;

// serialise the value at the scanner's position the way
// JSON.stringify(value, null, 2) would, at the given indent depth
function ReadValue(var S: TManifestScan; Depth: Integer): RawUtf8;
var
  pad, inner, key, value: RawUtf8;
  first: Boolean;
  i: Integer;
begin
  Result := '';
  SkipWs(S);
  if S.Pos > Length(S.Text) then
  begin
    S.Ok := False;
    exit;
  end;
  if S.Text[S.Pos] = '"' then
  begin
    // a string is re-emitted from its SOURCE bytes: JSON.stringify escapes
    // exactly what a JSON document already had escaped, so the source form
    // is the output form and nothing is re-encoded on a guess
    Result := ReadRawString(S);
    exit;
  end;
  if S.Text[S.Pos] <> '{' then
  begin
    // a number, an array, a boolean or a null: refused, never guessed at
    S.Ok := False;
    exit;
  end;
  Inc(S.Pos);
  pad := '';
  for i := 1 to Depth * 2 do
    pad := pad + ' ';
  inner := pad + '  ';
  first := True;
  SkipWs(S);
  if (S.Pos <= Length(S.Text)) and
     (S.Text[S.Pos] = '}') then
  begin
    Inc(S.Pos);
    Result := '{}';
    exit;
  end;
  Result := '{';
  while S.Ok do
  begin
    key := ReadRawString(S);
    if not S.Ok then
      exit;
    SkipWs(S);
    if (S.Pos > Length(S.Text)) or
       (S.Text[S.Pos] <> ':') then
    begin
      S.Ok := False;
      exit;
    end;
    Inc(S.Pos);
    value := ReadValue(S, Depth + 1);
    if not S.Ok then
      exit;
    if not first then
      Result := Result + ',';
    first := False;
    Result := Result + #10 + inner + key + ': ' + value;
    SkipWs(S);
    if S.Pos > Length(S.Text) then
    begin
      S.Ok := False;
      exit;
    end;
    if S.Text[S.Pos] = ',' then
    begin
      Inc(S.Pos);
      continue;
    end;
    if S.Text[S.Pos] = '}' then
    begin
      Inc(S.Pos);
      Result := Result + #10 + pad + '}';
      exit;
    end;
    S.Ok := False;
  end;
end;

// find the value of one top-level key and serialise it at depth 1
function TopLevelValue(const Manifest, Key: RawUtf8;
  out Value: RawUtf8): Boolean;
var
  s: TManifestScan;
  name: RawUtf8;
  depth: Integer;
begin
  Value := '';
  Result := False;
  s.Text := Manifest;
  s.Pos := 1;
  s.Ok := True;
  SkipWs(s);
  if (s.Pos > Length(s.Text)) or
     (s.Text[s.Pos] <> '{') then
    exit;
  Inc(s.Pos);
  SkipWs(s);
  if (s.Pos <= Length(s.Text)) and
     (s.Text[s.Pos] = '}') then
    exit;
  while s.Ok do
  begin
    name := ReadRawString(s);
    if not s.Ok then
      exit;
    SkipWs(s);
    if (s.Pos > Length(s.Text)) or
       (s.Text[s.Pos] <> ':') then
      exit;
    Inc(s.Pos);
    if name = '"' + Key + '"' then
    begin
      Value := ReadValue(s, 1);
      Result := s.Ok;
      exit;
    end;
    // skip a value of any shape, including the ones the canonical seven may
    // not have: this is the DEVELOPMENT manifest, which legitimately carries
    // arrays and objects the distribution one never sees
    SkipWs(s);
    if s.Pos > Length(s.Text) then
      exit;
    case s.Text[s.Pos] of
      '"':
        ReadRawString(s);
      '{', '[':
        begin
          // a bracket walk that respects string literals, so a '}' inside a
          // description can never close an object
          depth := 0;
          repeat
            case s.Text[s.Pos] of
              '"': ReadRawString(s);
              '{', '[':
                begin
                  Inc(depth);
                  Inc(s.Pos);
                end;
              '}', ']':
                begin
                  Dec(depth);
                  Inc(s.Pos);
                end;
            else
              Inc(s.Pos);
            end;
          until (depth = 0) or (s.Pos > Length(s.Text)) or (not s.Ok);
          if depth <> 0 then
            exit;
        end;
    else
      // a bare token: number, true, false, null
      while (s.Pos <= Length(s.Text)) and
            not (s.Text[s.Pos] in [',', '}', ' ', #9, #10, #13]) do
        Inc(s.Pos);
    end;
    SkipWs(s);
    if s.Pos > Length(s.Text) then
      exit;
    if s.Text[s.Pos] = ',' then
    begin
      Inc(s.Pos);
      continue;
    end;
    exit; // '}' or anything else: the key is not in this document
  end;
end;

function PWebCliSdkManifest(const DevManifest: RawUtf8;
  out Canonical: RawUtf8; out Refusal: TPWebCliStageRefusal): Boolean;
const
  // the fixed key order of tools/stage-ts-sdk.mjs, restated nowhere else
  KEYS: array[0 .. 6] of RawUtf8 = (
    'name', 'version', 'license', 'type', 'main', 'types', 'exports');
var
  i: PtrInt;
  value: RawUtf8;
begin
  Canonical := '';
  Result := False;
  Refusal := pstManifestMalformed;
  if (DevManifest = '') or
     (DevManifest[1] <> '{') then
    exit;
  Canonical := '{';
  for i := 0 to High(KEYS) do
  begin
    if not TopLevelValue(DevManifest, KEYS[i], value) then
    begin
      // the reader answers False both for "absent" and for "a shape this
      // rule refuses to re-encode", and the two are different facts
      if Pos('"' + KEYS[i] + '"', DevManifest) = 0 then
        Refusal := pstManifestField
      else
        Refusal := pstManifestShape;
      Canonical := '';
      exit;
    end;
    if i > 0 then
      Canonical := Canonical + ',';
    Canonical := Canonical + #10 + '  "' + KEYS[i] + '": ' + value;
  end;
  Canonical := Canonical + #10 + '}' + #10;
  Refusal := pstNone;
  Result := True;
end;

function PWebCliStageTsSdk(const SrcDir, DestParent, DestName: RawUtf8;
  out Files: Integer; out Refusal: TPWebCliStageRefusal): Boolean;
var
  dev, canonical, dest, distSrc, distDir, srcDir2: RawUtf8;
  content: RawByteString;
  tooBig: Boolean;
  copied: Integer;
begin
  Files := 0;
  Result := False;
  // the source has to be a BUILT SDK: the script refuses an unbuilt one and
  // so does this, because a staged package with no dist/src is a link that
  // resolves and a module that does not
  Refusal := pstSdkNotBuilt;
  if PWebCliEntry(SrcDir, 'dist') <> pcnDirectory then
    exit;
  distSrc := PWebCliJoin(SrcDir, 'dist');
  if PWebCliEntry(distSrc, 'src') <> pcnDirectory then
    exit;
  srcDir2 := PWebCliJoin(distSrc, 'src');
  if PWebCliEntry(srcDir2, 'index.js') <> pcnFile then
    exit;
  Refusal := pstManifestMissing;
  if PWebCliEntry(SrcDir, 'package.json') <> pcnFile then
    exit;
  if not PWebCliReadSmallFile(PWebCliJoin(SrcDir, 'package.json'),
       PWEB_CLI_PIPE_MAX_FILE_BYTES, content, tooBig) then
    exit;
  dev := RawUtf8(content);
  if not PWebCliSdkManifest(dev, canonical, Refusal) then
    exit;
  // FRESH, never merged
  if not PWebCliPipeRemoveTree(DestParent, DestName, Refusal) then
    exit;
  if not PWebCliPipeEnsureDir(DestParent, DestName, dest, Refusal) then
    exit;
  if not PWebCliWriteNewFile(PWebCliJoin(dest, 'package.json'),
       RawByteString(canonical), {SetExecBit=}False) then
  begin
    Refusal := pstWriteFile;
    exit;
  end;
  Inc(Files);
  if not PWebCliPipeEnsureDir(dest, 'dist', distDir, Refusal) then
    exit;
  if not PWebCliPipeEnsureDir(distDir, 'src', dest, Refusal) then
    exit;
  if not PWebCliPipeCopyTree(srcDir2, dest, copied, Refusal) then
    exit;
  Inc(Files, copied);
  Refusal := pstNone;
  Result := True;
end;

end.
