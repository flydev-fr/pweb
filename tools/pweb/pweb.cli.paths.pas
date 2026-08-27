{
  pweb.cli.paths - project-root confinement for the pweb CLI (CAP-10A).

  ONE question, asked the only way that is safe to ask it:

      given the canonical project root R and a project-root-relative logical
      path L from pweb.json, what real filesystem object does L name, and is
      it genuinely beneath R?

  ---------------------------------------------------------------------------
  WHY THIS IS NOT A STRING OPERATION
  ---------------------------------------------------------------------------

  A lexical answer - concatenate, then check the result starts with the root -
  is wrong on every platform this project ships to, and wrong in a way that
  looks correct in a test suite. `frontend` can be a symlink to /etc.
  `Src` and `src` are the same directory on NTFS and on a default APFS
  volume, and different ones on ext4. `SRC~1` resolves through an 8.3 alias.
  A junction has no marker in its name at all.

  So the walk asks the FILESYSTEM, one segment at a time, exactly as
  TFolderAssetStore does for served assets:

    - the root is canonicalized ONCE through the kernel (the descriptor or
      handle is asked what it really opened), so every later comparison is
      against the real directory rather than the spelled one;
    - each segment must exist in its parent directory with its EXACT on-disk
      spelling, read from the directory itself - a case variant is a miss;
    - a reparse point (symlink, junction, macOS firmlink target rewrite) at
      ANY position refuses the whole path. The CLI never follows a link out
      of a project;
    - the deepest existing directory is re-canonicalized and required to be
      byte-equal to what the walk built, which is the direct counterpart of
      the store's open-descriptor re-proof.

  ---------------------------------------------------------------------------
  WHY NOT SIMPLY REUSE THE ASSET STORE
  ---------------------------------------------------------------------------

  The SYNTAX is shared and deliberately so: PWebAssetPathValid is the one
  ratified answer to "is this a canonical logical path", and it already
  refuses absolute forms, '.'/'..'/empty segments, backslashes, drive and UNC
  prefixes, ADS colons, NUL and control bytes, '%', Windows device names,
  trailing dots and spaces, and non-shortest-form UTF-8. Re-deciding any of
  that here would be a second answer to a settled question.

  The RESOLUTION is not shared, because a project path is a different shape
  from an asset path. An asset is always a regular file that exists and whose
  bytes are read; a project path may name a DIRECTORY (frontend/), may name
  something that does not exist yet (dist/ before the first build), and is
  never read as content by this layer. TFolderAssetStore.TryRead can express
  none of those and would answer "no" to all three.
}
unit pweb.cli.paths;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.assets.support,
  pweb.cli.platform;

type
  /// why a project path was refused - machine-stable, one cause each
  // - ordinal 0 is the accepted state; every other value is a refusal
  TPWebCliPathRefusal = (
    pprNone,
    /// failed the shared canonical-logical-path grammar
    pprSyntax,
    /// a segment does not exist at all
    pprMissing,
    /// a segment exists only under a different spelling (case fold)
    pprCaseMismatch,
    /// an intermediate segment is not a directory
    pprNotDirectory,
    /// a symlink, junction or other reparse point on the chain
    pprLink,
    /// present but neither a file nor a directory (device, FIFO, socket)
    pprNotRegular,
    /// the kernel-resolved path is not the one the walk built
    pprEscape);

  /// everything one resolution learned
  TPWebCliResolved = record
    /// pprNone when the path is accepted (possibly with a missing tail)
    Refusal: TPWebCliPathRefusal;
    /// the deepest existing canonical directory on the chain - always set
    /// on success, and the anchor for a not-yet-created leaf
    ExistingDir: RawUtf8;
    /// the full native path the walk built (valid when MissingSegments = 0)
    Full: RawUtf8;
    /// what the final component is (pcnMissing when MissingSegments > 0)
    Kind: TPWebCliNodeKind;
    /// how many trailing segments do not exist yet; 0 means all present
    MissingSegments: Integer;
    /// the segment that caused a refusal, for a diagnostic that names it
    FailedSegment: RawUtf8;
  end;

/// fixed text for a refusal - the machine authority, never localized prose
function PWebCliPathRefusalText(Refusal: TPWebCliPathRefusal): RawUtf8;

/// resolve one project-root-relative logical path beneath a canonical root
// - Root MUST already be canonical (PWebCliCanonicalDir); this function
// never canonicalizes it again, so a caller that skipped that step cannot
// accidentally be granted confinement it did not establish
// - AllowMissingTail permits trailing segments that do not exist yet, which
// is what an output directory before the first build looks like; every
// EXISTING segment is still walked and confined
function PWebCliResolveUnder(const Root, Logical: RawUtf8;
  AllowMissingTail: Boolean): TPWebCliResolved;

implementation

function PWebCliPathRefusalText(Refusal: TPWebCliPathRefusal): RawUtf8;
begin
  case Refusal of
    pprNone:         Result := 'ok';
    pprSyntax:       Result := 'path_syntax';
    pprMissing:      Result := 'path_missing';
    pprCaseMismatch: Result := 'path_case_mismatch';
    pprNotDirectory: Result := 'path_not_directory';
    pprLink:         Result := 'path_link_refused';
    pprNotRegular:   Result := 'path_not_regular';
    pprEscape:       Result := 'path_escape';
  else
    Result := 'path_refused';
  end;
end;

// split on '/' only: the grammar above has already refused backslashes, so
// there is exactly one separator to know about
function SplitSegments(const Logical: RawUtf8): TRawUtf8DynArray;
var
  i, start, n: PtrInt;
begin
  Result := nil;
  n := 0;
  start := 1;
  for i := 1 to Length(Logical) + 1 do
    if (i > Length(Logical)) or
       (Logical[i] = '/') then
    begin
      SetLength(Result, n + 1);
      Result[n] := Copy(Logical, start, i - start);
      Inc(n);
      start := i + 1;
    end;
end;

function PWebCliResolveUnder(const Root, Logical: RawUtf8;
  AllowMissingTail: Boolean): TPWebCliResolved;
var
  segments: TRawUtf8DynArray;
  i, last: PtrInt;
  dir, candidate, reproof: RawUtf8;
  kind: TPWebCliNodeKind;
  missing: Boolean;
begin
  Result := Default(TPWebCliResolved);
  Result.Kind := pcnMissing;
  if (Root = '') or
     not PWebAssetPathValid(Logical) then
  begin
    Result.Refusal := pprSyntax;
    exit;
  end;
  segments := SplitSegments(Logical);
  last := High(segments);
  dir := Root;
  Result.ExistingDir := Root;
  missing := False;
  for i := 0 to last do
  begin
    candidate := PWebCliJoin(dir, segments[i]);
    if missing then
    begin
      // once the tail has started to be absent, no deeper segment may
      // exist: a hole in the middle is not a not-yet-created leaf
      if PWebCliNodeKind(candidate) <> pcnMissing then
      begin
        Result.Refusal := pprMissing;
        Result.FailedSegment := segments[i];
        exit;
      end;
      Inc(Result.MissingSegments);
      dir := candidate;
      continue;
    end;
    kind := PWebCliEntry(dir, segments[i]);
    if kind = pcnMissing then
    begin
      // distinguish "nothing there" from "there under another spelling":
      // asking the platform WITHOUT the exact-spelling requirement folds
      // case on NTFS and on a default APFS volume, which is precisely the
      // confusion this walk exists to refuse rather than to resolve
      if PWebCliNodeKind(candidate) <> pcnMissing then
      begin
        Result.Refusal := pprCaseMismatch;
        Result.FailedSegment := segments[i];
        exit;
      end;
      if not (AllowMissingTail) then
      begin
        Result.Refusal := pprMissing;
        Result.FailedSegment := segments[i];
        exit;
      end;
      missing := True;
      Inc(Result.MissingSegments);
      dir := candidate;
      continue;
    end;
    if kind = pcnLink then
    begin
      Result.Refusal := pprLink;
      Result.FailedSegment := segments[i];
      exit;
    end;
    if kind = pcnOther then
    begin
      Result.Refusal := pprNotRegular;
      Result.FailedSegment := segments[i];
      exit;
    end;
    if (i < last) and
       (kind <> pcnDirectory) then
    begin
      Result.Refusal := pprNotDirectory;
      Result.FailedSegment := segments[i];
      exit;
    end;
    dir := candidate;
    if kind = pcnDirectory then
      Result.ExistingDir := candidate;
    Result.Kind := kind;
  end;
  Result.Full := dir;
  if Result.MissingSegments > 0 then
    Result.Kind := pcnMissing;
  // the re-proof, on the deepest EXISTING directory: the walk refused a
  // reparse point at every step, but the answer must be the kernel's, not
  // the concatenation's. A lexical prefix test would pass here for free and
  // prove nothing, which is why the comparison is against what the kernel
  // says it opened.
  if not PWebCliCanonicalDir(Result.ExistingDir, reproof) or
     (reproof <> Result.ExistingDir) then
  begin
    Result.Refusal := pprEscape;
    exit;
  end;
  Result.Refusal := pprNone;
end;

end.
