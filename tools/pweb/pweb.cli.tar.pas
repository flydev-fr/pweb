{
  pweb.cli.tar - the deterministic archive writer (CAP-10D1).

  ONE archive rule for both POSIX families: a POSIX ustar stream, written
  here, gzipped through mORMot. No external tool, no platform branch, and no
  timestamp anywhere - so two builds of the same release produce BYTE-
  IDENTICAL archives, and that is a property of the format this unit emits
  rather than of a flag somebody remembered to pass.

  ---------------------------------------------------------------------------
  WHY NOT THE FROZEN WRITER, AND WHY NOT tar(1)
  ---------------------------------------------------------------------------

  Both alternatives were MEASURED before this one was written, and the D1
  suite keeps measuring them so the choice cannot rot into a preference:

    the CAP-6 bundler's ZIP writer   mORMot's TZipWrite sets extFileAttr to
                                     $A0 - MS-DOS attributes, with no Unix
                                     mode plane at all. An extracted program
                                     would arrive without its execute bit,
                                     which is the one thing a distributable
                                     archive of an application may not lose.
                                     REFUSED: cannot carry the modes.

    a supervised tar(1)              GNU tar has --sort=name; macOS's bsdtar
                                     does not. Two argument vectors, two byte
                                     streams, and a determinism claim that
                                     would have to be made twice.
                                     REFUSED: one rule would become three.

  What is left needs no tool and no branch, and it is about a hundred and
  fifty lines.

  ---------------------------------------------------------------------------
  WHAT MAKES IT DETERMINISTIC
  ---------------------------------------------------------------------------

    entry order   BYTEWISE ascending by name - the same ordinal comparison
                  pweb.cli.stage's tree digest uses, and for the same reason
                  CAP-10B1 measured: a culture-aware comparer orders `App`
                  and `app` differently on two hosts and makes a four-target
                  equality field unsatisfiable
    mtime         0, on every entry
    uid / gid     0 / 0, with EMPTY uname and gname - a host's login name is
                  the most common way a "reproducible" archive stops being one
    mode          0755 for the program, the shared library and every
                  directory; 0644 for everything else. Nothing is read from
                  the filesystem, so a developer's umask cannot reach the
                  artifact
    header form   plain ustar. No PAX extended records, no GNU long-name
                  entries, no sparse handling - every one of those embeds
                  either a timestamp or an implementation's own choices
    gzip          mORMot's GZWrite, whose header is (GZ_MAGIC, 0, 0): the
                  MTIME field is zero and no original filename is stored, so
                  the container adds nothing that changes between two runs

  The one thing this unit deliberately does NOT do is read a disk. It is a
  pure function from an ordered list of entries to bytes, so the whole
  archive rule is testable without a filesystem and the same test runs
  identically on four targets.
}
unit pweb.cli.tar;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.zip,
  pweb.cli.packpins;

const
  /// one ustar header, and the block everything is padded to
  PWEB_TAR_BLOCK = 512;

  /// the ustar name and prefix fields. A path longer than NAME goes into
  // PREFIX + '/' + NAME; one that does not fit even then is REFUSED rather
  // than silently truncated or promoted to a GNU long-name entry
  PWEB_TAR_NAME_MAX = 100;
  PWEB_TAR_PREFIX_MAX = 155;

  /// the two modes this writer ever emits
  PWEB_TAR_MODE_EXEC = &755;
  PWEB_TAR_MODE_FILE = &644;

  /// the deflate level. Fixed, because a level is part of the output bytes
  PWEB_TAR_GZIP_LEVEL = 9;

type
  /// one member of the archive
  // - Name is LOGICAL: forward slashes, relative, no leading or trailing
  // separator and no '.' or '..' segment. The caller builds it; this unit
  // validates it and never rewrites it
  TPWebTarEntry = record
    Name: RawUtf8;
    /// a directory member; Content must be empty
    Directory: Boolean;
    /// 0755 rather than 0644 (always true for a directory)
    Executable: Boolean;
    Content: RawByteString;
  end;
  TPWebTarEntries = array of TPWebTarEntry;

  /// why an archive could not be written - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebTarRefusal = (
    patNone,
    /// no entries at all: an empty archive is never a correct answer
    patEmpty,
    /// a name is empty, absolute, carries a backslash, a '.'/'..' segment,
    /// a NUL, or does not fit the ustar name+prefix fields
    patName,
    /// two entries carry the same name
    patDuplicate,
    /// a member, or the whole stream, exceeds its bound
    patTooBig,
    /// the deflate step failed
    patCompress);

/// fixed diagnostic text - the machine authority, never localized prose
function PWebTarRefusalText(Refusal: TPWebTarRefusal): RawUtf8;

/// bytewise ascending sort by Name, in place
// - ORDINAL, never a culture comparison; see the unit header
procedure PWebTarSort(var Entries: TPWebTarEntries);

/// the ustar stream for an ALREADY SORTED entry list
// - the caller sorts, because sorting is where the determinism claim lives
// and a writer that silently re-sorted would hide a caller that did not
function PWebTarWrite(const Entries: TPWebTarEntries;
  out Data: RawByteString; out Refusal: TPWebTarRefusal): Boolean;

/// gzip a buffer with no timestamp and no stored filename
function PWebTarGzip(const Raw: RawByteString;
  out Data: RawByteString): Boolean;

/// the ratified artifact basename: `<name>-<version>-<target>`
// - it is BOTH the archive's own basename and the single top-level
// directory inside it, so an extraction can never scatter files into the
// current directory and two versions never collide
function PWebTarStem(const Name, Version, Target: RawUtf8): RawUtf8;


implementation

function PWebTarRefusalText(Refusal: TPWebTarRefusal): RawUtf8;
begin
  case Refusal of
    patNone:      Result := 'ok';
    patEmpty:     Result := 'archive_empty';
    patName:      Result := 'archive_name_refused';
    patDuplicate: Result := 'archive_duplicate_entry';
    patTooBig:    Result := 'archive_too_big';
    patCompress:  Result := 'archive_compress_failed';
  else
    Result := 'archive_refused';
  end;
end;

procedure PWebTarSort(var Entries: TPWebTarEntries);
var
  i, j: PtrInt;
  tmp: TPWebTarEntry;
begin
  // an insertion sort over a list that holds a release layout: four entries
  // on macOS, three plus its parents elsewhere. The comparison is what
  // matters here, not the algorithm
  for i := 1 to High(Entries) do
  begin
    tmp := Entries[i];
    j := i - 1;
    while (j >= 0) and
          (StrComp(PUtf8Char(Entries[j].Name), PUtf8Char(tmp.Name)) > 0) do
    begin
      Entries[j + 1] := Entries[j];
      Dec(j);
    end;
    Entries[j + 1] := tmp;
  end;
end;

function PWebTarStem(const Name, Version, Target: RawUtf8): RawUtf8;
begin
  Result := Name + '-' + Version + '-' + Target;
end;

// a logical member name: relative, forward-slashed, no traversal, no NUL,
// no backslash. Every one of these is already true of what the caller
// builds; this is the check that makes it true of what is WRITTEN
function AcceptableName(const Name: RawUtf8): Boolean;
var
  i, start: PtrInt;
  seg: RawUtf8;
begin
  Result := False;
  if (Name = '') or
     (Name[1] = '/') or
     (Name[Length(Name)] = '/') then
    exit;
  start := 1;
  for i := 1 to Length(Name) + 1 do
    if (i > Length(Name)) or
       (Name[i] = '/') then
    begin
      seg := Copy(Name, start, i - start);
      start := i + 1;
      if (seg = '') or
         (seg = '.') or
         (seg = '..') then
        exit;
    end
    else if (Name[i] = #0) or
            (Name[i] = '\') then
      exit;
  Result := True;
end;

// the ustar name/prefix split. The LAST separator that leaves both halves
// inside their fields wins, so a deep path uses as much of PREFIX as it can
function SplitUstarName(const Full: RawUtf8; Directory: Boolean;
  out Name, Prefix: RawUtf8): Boolean;
var
  path: RawUtf8;
  i, cut: PtrInt;
begin
  Result := False;
  Name := '';
  Prefix := '';
  path := Full;
  if Directory then
    // a ustar directory member is named with its trailing separator, and the
    // separator counts against the 100 bytes
    path := path + '/';
  if Length(path) <= PWEB_TAR_NAME_MAX then
  begin
    Name := path;
    Result := True;
    exit;
  end;
  cut := 0;
  for i := 1 to Length(path) do
    if (path[i] = '/') and
       (i - 1 <= PWEB_TAR_PREFIX_MAX) and
       (Length(path) - i <= PWEB_TAR_NAME_MAX) then
      cut := i;
  if cut = 0 then
    exit;
  Prefix := Copy(path, 1, cut - 1);
  Name := Copy(path, cut + 1, MaxInt);
  Result := (Name <> '') and (Prefix <> '');
end;

// an octal field: Width-1 zero-padded octal digits then a NUL, which is the
// form GNU tar, bsdtar and libarchive all read without a second thought
procedure PutOctal(var Header: array of AnsiChar; Offset, Width: PtrInt;
  Value: QWord);
var
  i: PtrInt;
begin
  Header[Offset + Width - 1] := #0;
  for i := Width - 2 downto 0 do
  begin
    Header[Offset + i] := AnsiChar(Ord('0') + (Value and 7));
    Value := Value shr 3;
  end;
end;

procedure PutText(var Header: array of AnsiChar; Offset, Width: PtrInt;
  const Text: RawUtf8);
var
  i: PtrInt;
begin
  for i := 0 to Width - 1 do
    if i < Length(Text) then
      Header[Offset + i] := AnsiChar(Text[i + 1])
    else
      Header[Offset + i] := #0;
end;

function PWebTarWrite(const Entries: TPWebTarEntries;
  out Data: RawByteString; out Refusal: TPWebTarRefusal): Boolean;
var
  header: array[0 .. PWEB_TAR_BLOCK - 1] of AnsiChar;
  out_: RawByteString;
  i, j, pad: PtrInt;
  sum: Cardinal;
  name, prefix: RawUtf8;
  mode: Cardinal;
  total: Int64;

  procedure Append(P: pointer; Len: PtrInt);
  var
    at: PtrInt;
  begin
    at := Length(out_);
    SetLength(out_, at + Len);
    if Len > 0 then
      MoveFast(P^, PByteArray(out_)^[at], Len);
  end;

begin
  Result := False;
  Data := '';
  Refusal := patNone;
  out_ := '';
  if Length(Entries) = 0 then
  begin
    Refusal := patEmpty;
    exit;
  end;
  total := 0;
  for i := 0 to High(Entries) do
  begin
    if not AcceptableName(Entries[i].Name) or
       not SplitUstarName(Entries[i].Name, Entries[i].Directory, name,
             prefix) then
    begin
      Refusal := patName;
      exit;
    end;
    // the list is sorted, so a duplicate is always the immediate neighbour
    if (i > 0) and
       (Entries[i].Name = Entries[i - 1].Name) then
    begin
      Refusal := patDuplicate;
      exit;
    end;
    if Entries[i].Directory and
       (Entries[i].Content <> '') then
    begin
      Refusal := patName;
      exit;
    end;
    total := total + PWEB_TAR_BLOCK + Length(Entries[i].Content);
    if total > PWEB_PACK_MAX_ARCHIVE_BYTES then
    begin
      Refusal := patTooBig;
      exit;
    end;

    FillCharFast(header, SizeOf(header), 0);
    PutText(header, 0, 100, name);
    if Entries[i].Directory or Entries[i].Executable then
      mode := PWEB_TAR_MODE_EXEC
    else
      mode := PWEB_TAR_MODE_FILE;
    PutOctal(header, 100, 8, mode);
    PutOctal(header, 108, 8, 0);            // uid
    PutOctal(header, 116, 8, 0);            // gid
    PutOctal(header, 124, 12, QWord(Length(Entries[i].Content)));
    PutOctal(header, 136, 12, 0);           // mtime
    // the checksum field is SPACES while the sum is taken, then written
    for j := 148 to 155 do
      header[j] := ' ';
    if Entries[i].Directory then
      header[156] := '5'
    else
      header[156] := '0';
    PutText(header, 257, 6, 'ustar');       // magic, NUL-terminated
    header[263] := '0';                     // version '00'
    header[264] := '0';
    // uname and gname stay EMPTY on purpose: a login name is host state
    PutOctal(header, 329, 8, 0);            // devmajor
    PutOctal(header, 337, 8, 0);            // devminor
    PutText(header, 345, 155, prefix);
    sum := 0;
    for j := 0 to PWEB_TAR_BLOCK - 1 do
      Inc(sum, Ord(header[j]));
    // six octal digits, NUL, space - the historical form every reader accepts
    PutOctal(header, 148, 7, sum);
    header[155] := ' ';
    Append(@header[0], PWEB_TAR_BLOCK);

    if Entries[i].Content <> '' then
    begin
      Append(pointer(Entries[i].Content), Length(Entries[i].Content));
      pad := Length(Entries[i].Content) mod PWEB_TAR_BLOCK;
      if pad <> 0 then
      begin
        FillCharFast(header, SizeOf(header), 0);
        Append(@header[0], PWEB_TAR_BLOCK - pad);
      end;
    end;
  end;
  // the two zero blocks that end a tar stream
  FillCharFast(header, SizeOf(header), 0);
  Append(@header[0], PWEB_TAR_BLOCK);
  Append(@header[0], PWEB_TAR_BLOCK);
  Data := out_;
  Result := True;
end;

function PWebTarGzip(const Raw: RawByteString;
  out Data: RawByteString): Boolean;
begin
  Data := '';
  if Raw = '' then
  begin
    Result := False;
    exit;
  end;
  // mORMot's GZHEAD is (GZ_MAGIC, 0, 0): no MTIME, no FNAME, no comment -
  // which is exactly the header a reproducible artifact needs and the reason
  // this is one call rather than a hand-rolled container
  Data := GZWrite(pointer(Raw), Length(Raw), PWEB_TAR_GZIP_LEVEL);
  Result := Data <> '';
end;

end.
