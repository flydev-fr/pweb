{
  pweb.assets.zip - packaged IAssetStore over a ZIP archive.

  TZipAssetStore serves the canonical corpus from app.zip through the
  pinned mORMot TZipRead, without ever extracting to disk. The archive
  is indexed and validated deterministically at construction; a
  hostile or ambiguous archive is rejected as a whole (packaging
  error), never served partially:

    - every entry's RAW stored name (Entry[].storedName bytes, before
      any of TZipRead's delimiter/charset normalization) must be a
      canonical logical path per pweb.assets.support - this rejects
      traversal, backslash, absolute-like, device, '%', non-UTF-8 and
      folder ('name/') entries outright;
    - exact-name duplicates, and any two names comparing equal under
      the pinned mORMot Unicode 10.0 simple case fold
      (UpperCaseReference - compiled-in tables, never the OS case
      mapping), are ambiguous and reject the archive (ratified CAP-6
      D1); the fold is an ambiguity-rejection rule only - it never
      normalizes or rewrites a name;
    - lookup is byte-exact and case-sensitive: TZipRead.NameToIndex is
      deliberately NOT used (it is case-insensitive and normalizes
      path delimiters).

  TZipRead shared reads are not reentrant: file-backed archives seek
  and read one shared fSource stream inside UnZip, so this store
  serializes every archive access behind a private lock. That is an
  implementation detail of this class - IAssetStore is unchanged.

  TryRead never raises - any violation or archive failure returns
  False. Zero-byte entries are served from the construction-time index
  without touching the archive, keeping '' unambiguous.
}
unit pweb.assets.zip;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.zip,
  pweb.assets.intf,
  pweb.assets.support;

type
  EPWebZipAssetStore = class(Exception);

  TZipAssetStore = class(TInterfacedObject, IAssetStore)
  private
    fZip: TZipRead;
    fBuffer: RawByteString; // keeps a memory archive alive for fZip
    fNames: TRawUtf8DynArray; // sorted byte-exact raw entry names
    fZipIndex: TIntegerDynArray; // fNames[i] -> TZipRead entry index
    fFullSize: TInt64DynArray; // expected uncompressed size
    fLock: TOSLock; // TZipRead shared reads are not reentrant
    procedure IndexAndValidate;
    function Find(const Path: RawUtf8): PtrInt;
  public
    // open and validate a .zip archive file; raises EPWebZipAssetStore
    // on any invalid, hostile or ambiguous archive
    constructor Create(const AZipFileName: TFileName); overload;
    // open and validate a .zip archive held in memory (the buffer is
    // copied and kept alive for the store's lifetime)
    constructor CreateFromBuffer(const AZipData: RawByteString);
    destructor Destroy; override;
    function TryRead(const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
  end;

implementation

constructor TZipAssetStore.Create(const AZipFileName: TFileName);
begin
  inherited Create;
  fLock.Init;
  try
    fZip := TZipRead.Create(AZipFileName);
  except
    on E: Exception do
      raise EPWebZipAssetStore.CreateFmt(
        'invalid asset archive %s (%s)', [AZipFileName, E.ClassName]);
  end;
  IndexAndValidate;
end;

constructor TZipAssetStore.CreateFromBuffer(const AZipData: RawByteString);
begin
  inherited Create;
  fLock.Init;
  fBuffer := AZipData; // hold a reference while fZip points into it
  try
    fZip := TZipRead.Create(PByteArray(fBuffer), Length(fBuffer));
  except
    on E: Exception do
      raise EPWebZipAssetStore.CreateFmt(
        'invalid asset archive buffer (%s)', [E.ClassName]);
  end;
  IndexAndValidate;
end;

destructor TZipAssetStore.Destroy;
begin
  fZip.Free;
  fLock.Done;
  inherited Destroy;
end;

procedure TZipAssetStore.IndexAndValidate;
var
  n, i, j, ins: PtrInt;
  raw: RawUtf8;
  info: TFileInfoFull;
  folded: TRawUtf8DynArray;
begin
  n := fZip.Count;
  if n = 0 then
    // a parseable but empty package would construct silently and then
    // 404 every asset - a broken build fails at startup instead
    raise EPWebZipAssetStore.Create('empty asset archive rejected');
  SetLength(fNames, n);
  SetLength(fZipIndex, n);
  SetLength(fFullSize, n);
  SetLength(folded, n);
  for i := 0 to n - 1 do
  begin
    // the raw stored bytes are the only honest name: zipName has
    // already been delimiter-normalized and charset-converted
    FastSetString(raw, fZip.Entry[i].storedName,
      fZip.Entry[i].dir^.fileInfo.nameLen);
    if not PWebAssetPathValid(raw) then
      raise EPWebZipAssetStore.CreateFmt(
        'non-canonical entry name rejected: "%s"', [raw]);
    if not fZip.RetrieveFileInfo(i, info) then
      raise EPWebZipAssetStore.CreateFmt(
        'unreadable entry info rejected: "%s"', [raw]);
    // v1 assets are materialised; cap entries at the same 2GB bound
    // the folder store enforces - and refuse zip-bomb-sized claims
    // deterministically at construction, not at first read
    if info.f64.zfullSize > High(Integer) then
      raise EPWebZipAssetStore.CreateFmt(
        'oversized entry rejected: "%s"', [raw]);
    // insertion sort keeps fNames byte-ordered for binary search
    ins := 0;
    while (ins < i) and
          (CompareStr(fNames[ins], raw) < 0) do
      Inc(ins);
    if (ins < i) and
       (fNames[ins] = raw) then
      raise EPWebZipAssetStore.CreateFmt(
        'duplicate entry name rejected: "%s"', [raw]);
    for j := i downto ins + 1 do
    begin
      fNames[j] := fNames[j - 1];
      fZipIndex[j] := fZipIndex[j - 1];
      fFullSize[j] := fFullSize[j - 1];
    end;
    fNames[ins] := raw;
    fZipIndex[ins] := i;
    fFullSize[ins] := info.f64.zfullSize;
  end;
  // case collisions are ambiguous under the exact-case rule - two
  // entries comparing equal under the pinned mORMot Unicode 10.0
  // simple case fold reject the whole archive (ratified CAP-6 D1;
  // this construction-time gate is the second enforcement point, so
  // a hand-crafted app.pwb cannot bypass the bundler policy). The
  // compiled-in tables keep the verdict deterministic across
  // machines and years - the OS case mapping is never consulted; the
  // fold never rewrites a name and lookup stays byte-exact
  for i := 0 to n - 1 do
    folded[i] := UpperCaseReference(fNames[i]);
  for i := 0 to n - 1 do
    for j := i + 1 to n - 1 do
      if folded[i] = folded[j] then
        raise EPWebZipAssetStore.CreateFmt(
          'case-colliding entry names rejected: "%s" vs "%s"',
          [fNames[i], fNames[j]]);
  // a name that is also a directory prefix of another name ('a' plus
  // 'a/b.js') cannot exist in any folder store - such an archive can
  // never satisfy Folder/ZIP parity and is rejected as ambiguous
  for i := 0 to n - 1 do
    for j := 0 to n - 1 do
      if (i <> j) and
         (Length(fNames[j]) > Length(fNames[i]) + 1) and
         (CompareStr(Copy(fNames[j], 1, Length(fNames[i])), fNames[i]) = 0) and
         (fNames[j][Length(fNames[i]) + 1] = '/') then
        raise EPWebZipAssetStore.CreateFmt(
          'file/directory-colliding entry names rejected: "%s" vs "%s"',
          [fNames[i], fNames[j]]);
end;

function TZipAssetStore.Find(const Path: RawUtf8): PtrInt;
var
  lo, hi, mid, cmp: PtrInt;
begin
  lo := 0;
  hi := Length(fNames) - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) shr 1;
    cmp := CompareStr(fNames[mid], Path); // byte-exact, case-sensitive
    if cmp = 0 then
    begin
      Result := mid;
      exit;
    end;
    if cmp < 0 then
      lo := mid + 1
    else
      hi := mid - 1;
  end;
  Result := -1;
end;

function TZipAssetStore.TryRead(const Path: RawUtf8;
  out Asset: TAssetResponse): Boolean;
var
  i: PtrInt;
  content: RawByteString;
begin
  Result := False;
  Asset.Content := '';
  Asset.ContentType := '';
  if not PWebAssetPathValid(Path) then
    exit; // stores fail closed independently of the URI layer
  i := Find(Path);
  if i < 0 then
    exit;
  if fFullSize[i] = 0 then
    // legitimate zero-byte asset: UnZip cannot distinguish it from a
    // failure, so serve it from the validated construction-time index
    content := ''
  else
  begin
    fLock.Lock; // shared TZipRead reads are not reentrant
    try
      try
        // explicit bound matching the construction-time 2GB entry cap
        content := fZip.UnZip(fZipIndex[i], High(Integer));
      except
        exit; // archive was validated at construction: this is damage
      end;
    finally
      fLock.UnLock;
    end;
    if Int64(Length(content)) <> fFullSize[i] then
      exit; // never serve truncated or padded bytes
  end;
  Asset.Content := content;
  Asset.ContentType := PWebAssetMimeType(Path);
  Result := True;
end;

end.
