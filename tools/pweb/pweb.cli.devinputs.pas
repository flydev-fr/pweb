{
  pweb.cli.devinputs - the Pas2JS development loop's change detector
  (CAP-10C3).

  A PURE PLAN plus the bounded walk that realises it, over the CAP-10B0
  primitives in pweb.cli.platform. Nothing here spawns a child, reads the
  environment or carries a platform conditional, so the whole rule can be
  asserted from any single target - the CAP-10C1 property, kept, and the
  reason this is a unit of its own rather than a region of pweb.cli.dev
  (which stays the ONE unit of the dev loop that runs a child).

  ---------------------------------------------------------------------------
  WHY THE CLI OWNS DETECTION AT ALL
  ---------------------------------------------------------------------------

  React's loop is told when a build finished: the template's vite.config.ts
  writes a sentinel from `writeBundle`, and the CLI reads it. Pas2JS has no
  watch mode and no writeBundle, and the CAP-10C1 assembly runs in the CLI
  rather than in the build - so nothing exists to say "rebuild now" and the
  CLI has to decide it. That is the whole of what this unit does; everything
  after the decision is the CAP-10C2 loop, unchanged.

  ---------------------------------------------------------------------------
  THE INPUT SET, AND WHY IT IS NOT FILTERED BY EXTENSION
  ---------------------------------------------------------------------------

      <frontend>/src/**        EVERY file, at any depth
      <frontend>/index.html
      <frontend>/app.css
      <frontend>/pas2js.cfg

  which is exactly what the CAP-10C1 Pas2JS plan reads: the compiler is
  handed `@pas2js.cfg` and `<src>/<ident>app.lpr`, and the assembly places
  index.html and app.css. Nothing else is watched - not the SDK root, not
  <output>, not .pweb, and not the NATIVE src/, because a native change still
  requires restarting `pweb dev` exactly as it does for React.

  `src/**` is deliberately NOT filtered to .pas/.pp/.inc/.lpr. An extension
  allowlist would be a SECOND place the compiler's real input set is written
  down, and the day somebody include-directives a file whose extension is
  not on it, the detector silently stops detecting. Watching the directory
  is the same answer with nothing to keep in step.

  (A compiler directive may NOT be written inside a brace comment - FPC
  reads the nested brace as one and ends the comment at the next closing
  brace - so it is spelled in prose here, exactly as pweb.webview.host's own
  header requires.)

  ---------------------------------------------------------------------------
  THE FINGERPRINT IS CONTENT, NOT (SIZE, MTIME)
  ---------------------------------------------------------------------------

  The obvious fingerprint is the cheap one - sorted (path, size, mtime) - and
  it is the wrong one. FPC's portable timestamp layer is SECOND-granular, so
  two edits inside one second that leave the length alone produce one
  fingerprint and the change is never seen. Hashing the bytes costs a few
  kilobytes of reads four times a second, is immune to that AND to a
  same-size edit, and buys a property worth having on its own: a `touch`, a
  `git checkout` or a mode change that alters no byte costs no generation.

  The fingerprint is therefore

      sha256( sorted( "<logical path>|<size>|<sha256 of content>"\n ) )

  and the logical path is relative to the frontend root, so the value is a
  property of the PROJECT rather than of where it happens to sit.

  ---------------------------------------------------------------------------
  BOUNDED, AND FAIL-CLOSED
  ---------------------------------------------------------------------------

  A walk this loop repeats forever needs its own bounds rather than the C1
  pipeline's, which are sized for a gate that runs once per stage:

      PWEB_CLI_DEV_MAX_INPUT_FILES   how many files the set may hold
      PWEB_CLI_DEV_MAX_INPUT_DEPTH   how deep it may go
      PWEB_CLI_DEV_INPUT_FILE_MAX    how big ONE input may be
      PWEB_CLI_DEV_INPUT_PATH_MAX    how long one logical path may be

  A symlink or reparse point anywhere inside the set is a REFUSAL and never a
  recorded line: following one would let the compiler read outside the
  project root, and recording one would mean the detector had walked a tree
  it does not own. A directory that cannot be enumerated is a refusal too -
  a check that answers "nothing changed" when it could not look is a check
  that disappears on exactly the trees worth checking.
}
unit pweb.cli.devinputs;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.crypt.core,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.stage,
  pweb.cli.frontend;

type
  /// why an input-set walk was refused - one cause each
  // - ordinal 0 is the accepted state
  TPWebCliDevInputRefusal = (
    pdiNone,
    /// a symlink or reparse point exists inside the input set
    pdiLink,
    /// the set holds more files, more depth or a longer path than the
    /// ratified bounds allow
    pdiBound,
    /// one input is larger than the ratified per-file ceiling
    pdiFileTooBig,
    /// a directory could not be enumerated, or a file could not be read
    pdiUnreadable,
    /// the frontend root does not hold the ratified input set at all
    pdiSetMissing);

  /// everything one walk of the input set learned
  TPWebCliDevInputs = record
    Refusal: TPWebCliDevInputRefusal;
    /// which input caused the refusal - LOGICAL, never absolute
    Detail: RawUtf8;
    /// sha256 of the sorted projection; '' unless Refusal is pdiNone
    Fingerprint: RawUtf8;
    /// how many files the set held
    Files: Integer;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliDevInputRefusalText(
  Refusal: TPWebCliDevInputRefusal): RawUtf8;

/// the three frontend-root files of the ratified input set, in the order
/// the projection records them
// - the fourth member is the whole of <frontend>/src, which is a directory
// rather than a name and is walked
function PWebCliDevInputFiles: TRawUtf8DynArray;

/// walk the ratified input set beneath a frontend root and fingerprint it
// - answers False on any refusal, with Detail naming the logical input
function PWebCliDevInputScan(const FrontendRoot: RawUtf8;
  out Inputs: TPWebCliDevInputs): Boolean;

/// True when Path - a LOGICAL path relative to the frontend root - is a
/// member of the ratified input set
// - the one place "is this watched" is decided, so a test can assert the
// boundary without a filesystem
function PWebCliDevInputWatched(const LogicalPath: RawUtf8): Boolean;


implementation

function PWebCliDevInputRefusalText(
  Refusal: TPWebCliDevInputRefusal): RawUtf8;
begin
  case Refusal of
    pdiNone:       Result := 'ok';
    pdiLink:       Result := 'dev_input_link';
    pdiBound:      Result := 'dev_input_bound';
    pdiFileTooBig: Result := 'dev_input_too_big';
    pdiUnreadable: Result := 'dev_input_unreadable';
    pdiSetMissing: Result := 'dev_input_set_missing';
  else
    Result := 'dev_input_refused';
  end;
end;

function PWebCliDevInputFiles: TRawUtf8DynArray;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := PWEB_FE_APP_CSS;
  Result[1] := PWEB_FE_INDEX;
  Result[2] := PWEB_FE_PAS2JS_CFG;
end;

function PWebCliDevInputWatched(const LogicalPath: RawUtf8): Boolean;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  prefix: RawUtf8;
begin
  Result := False;
  if LogicalPath = '' then
    exit;
  names := PWebCliDevInputFiles;
  for i := 0 to High(names) do
    if LogicalPath = names[i] then
      exit(True);
  // everything beneath <frontend>/src, at any depth, and matched on a
  // COMPONENT boundary so `src` selects that directory and never `src-old`
  prefix := PWEB_FE_SRC + '/';
  Result := Copy(LogicalPath, 1, Length(prefix)) = prefix;
end;

// one file of the set, projected as `<logical>|<size>|<sha256>`
function ProjectFile(const Full, Logical: RawUtf8; var Rows: TRawUtf8DynArray;
  var Inputs: TPWebCliDevInputs): Boolean;
var
  content: RawByteString;
  tooBig: Boolean;
begin
  Result := False;
  if Length(Logical) > PWEB_CLI_DEV_INPUT_PATH_MAX then
  begin
    Inputs.Refusal := pdiBound;
    Inputs.Detail := Copy(Logical, 1, 80);
    exit;
  end;
  Inc(Inputs.Files);
  if Inputs.Files > PWEB_CLI_DEV_MAX_INPUT_FILES then
  begin
    Inputs.Refusal := pdiBound;
    Inputs.Detail := Logical;
    exit;
  end;
  if not PWebCliReadSmallFile(Full, PWEB_CLI_DEV_INPUT_FILE_MAX, content,
       tooBig) then
  begin
    if tooBig then
      Inputs.Refusal := pdiFileTooBig
    else
      Inputs.Refusal := pdiUnreadable;
    Inputs.Detail := Logical;
    exit;
  end;
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)] := Logical + '|' + RawUtf8(IntToStr(Length(content))) +
    '|' + LowerCaseU(Sha256(content));
  Result := True;
end;

// the <frontend>/src half: EVERY entry, at any depth up to the bound, and a
// link anywhere in it is a refusal rather than a line
function ProjectTree(const Dir, Rel: RawUtf8; Depth: Integer;
  var Rows: TRawUtf8DynArray; var Inputs: TPWebCliDevInputs): Boolean;
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  logical, full: RawUtf8;
begin
  Result := False;
  if Depth > PWEB_CLI_DEV_MAX_INPUT_DEPTH then
  begin
    Inputs.Refusal := pdiBound;
    Inputs.Detail := Rel;
    exit;
  end;
  if not PWebCliListDir(Dir, names) then
  begin
    Inputs.Refusal := pdiUnreadable;
    Inputs.Detail := Rel;
    exit;
  end;
  for i := 0 to High(names) do
  begin
    logical := Rel + '/' + names[i];
    full := PWebCliJoin(Dir, names[i]);
    case PWebCliNodeKind(full) of
      pcnDirectory:
        if not ProjectTree(full, logical, Depth + 1, Rows, Inputs) then
          exit;
      pcnFile:
        if not ProjectFile(full, logical, Rows, Inputs) then
          exit;
      pcnMissing:
        // enumerated a moment ago and gone now: the tree moved under the
        // walk, which the CALLER's consistency rule is there to notice. A
        // walk that silently skipped it would hand back a fingerprint of a
        // set that never existed
        begin
          Inputs.Refusal := pdiUnreadable;
          Inputs.Detail := logical;
          exit;
        end;
    else
      // a link or a device inside the input set. Following it would let the
      // compiler read outside the project root; recording it would mean this
      // walk had accepted a tree it does not own
      begin
        Inputs.Refusal := pdiLink;
        Inputs.Detail := logical;
        exit;
      end;
    end;
  end;
  Result := True;
end;

function PWebCliDevInputScan(const FrontendRoot: RawUtf8;
  out Inputs: TPWebCliDevInputs): Boolean;
var
  rows, names: TRawUtf8DynArray;
  i: PtrInt;
  lines: RawUtf8;
  srcDir: RawUtf8;
begin
  Inputs := Default(TPWebCliDevInputs);
  Result := False;
  rows := nil;
  // 1. the three frontend-root files. Each must be a FILE: a link in their
  // place is the same refusal as a link inside src/
  names := PWebCliDevInputFiles;
  for i := 0 to High(names) do
    case PWebCliEntry(FrontendRoot, names[i]) of
      pcnFile:
        if not ProjectFile(PWebCliJoin(FrontendRoot, names[i]), names[i],
             rows, Inputs) then
          exit;
      pcnMissing:
        begin
          Inputs.Refusal := pdiSetMissing;
          Inputs.Detail := names[i];
          exit;
        end;
    else
      begin
        Inputs.Refusal := pdiLink;
        Inputs.Detail := names[i];
        exit;
      end;
    end;
  // 2. the whole of <frontend>/src
  if PWebCliEntry(FrontendRoot, PWEB_FE_SRC) <> pcnDirectory then
  begin
    Inputs.Refusal := pdiSetMissing;
    Inputs.Detail := PWEB_FE_SRC;
    exit;
  end;
  srcDir := PWebCliJoin(FrontendRoot, PWEB_FE_SRC);
  if not ProjectTree(srcDir, PWEB_FE_SRC, 1, rows, Inputs) then
    exit;
  // 3. sorted, so the fingerprint is a property of the NAMES and never of
  // the order the walk happened to take
  PWebCliSortBytewise(rows);
  lines := '';
  for i := 0 to High(rows) do
    lines := lines + rows[i] + #10;
  Inputs.Fingerprint := LowerCaseU(Sha256(lines));
  Inputs.Refusal := pdiNone;
  Inputs.Detail := '';
  Result := True;
end;

end.
