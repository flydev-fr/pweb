{
  pweb.blobs.memory - the v1 memory-backed IBlobStore (CAP-12B).

  ONE implementation, in memory, with ceilings. CAP-12A §6.3.3 made
  re-measuring the 8 MiB window against a REAL store an entry condition
  for this shard precisely so that the choice between a memory-backed
  and a file-backed store would be made on a number; the measurement is
  in the CAP-12B artifact and it chose this one. A file-backed store is
  a later shard, and the only thing it has to change is this file:
  IBlobStore names no filesystem path, so nothing above it knows which
  kind of store it is talking to.

  WHAT MAKES A READ LOCK-FREE, and it is a property rather than an
  optimisation: a blob is unreadable until it is SEALED, and sealing is
  the last write it will ever take. A reader therefore takes its own
  reference to the immutable RawByteString at open time and never
  touches the store again until it is destroyed. Two consequences that
  the CAP-12A contract asks for fall straight out of that:

    - `Release` makes the token unresolvable AT ONCE - it is one flag
      under the lock - while the bytes stay alive for exactly as long as
      some reader still holds them. A scheme task that is mid-window
      cannot read freed memory because it is holding the string.
    - `ReadAt` cannot block the engine's thread on a store lock. On one
      MEASURED engine the resource handler runs on the host's GUI
      thread; a plane whose reads contended with its writes would put a
      producer's allocation in front of the user interface.

  ACCOUNTING IS TRUTHFUL RATHER THAN FLATTERING. A released blob whose
  readers have not all gone is still resident, so it is still charged to
  its owner and still counted by Stats. A Stats that disagreed with the
  arithmetic the ceilings are computed from would be a trap.

  EVERYTHING IS ONE ARRAY, SCANNED. At the ratified ceilings the store
  holds at most 512 entries, and a create - the only operation that
  needs the per-owner aggregates - happens once per large response. A
  scan of 512 records is microseconds and removes an entire class of
  incremental-bookkeeping defect. It also gives OpenBlob the property
  the security model actually requires: the scan does not short-circuit,
  so an unknown token and a FOREIGN token cost the same walk.

  Layering: RTL plus mormot.core.base for the string aliases and
  mormot.crypt.core for Random128. Nothing else. No webview, no rpc, no
  platform unit, no URI scheme.
}
unit pweb.blobs.memory;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  syncobjs,
  mormot.core.base,
  mormot.crypt.core,
  pweb.blobs.intf;

type
  EPWebBlobStore = class(Exception);

  { The v1 store. Thread-safe; every public entry point is bounded and
    none of them raises across a caller that cannot afford one. }
  TPWebMemoryBlobStore = class(TInterfacedObject,
    IBlobStore, IBlobBounds, IBlobStoreRuntime)
  private
    type
      TEntry = class
      public
        Token: RawUtf8;        // '' once retired: unresolvable, by construction
        Owner: RawUtf8;
        ContentType: RawUtf8;
        Data: RawByteString;   // the store's own reference; dropped at retire
        Reserved: Int64;       // what the owner is charged, >= Filled
        Filled: Int64;         // bytes appended so far
        // created with SizeHint > 0: the reservation is a CEILING and the
        // writer may not exceed it. A blob created with SizeHint = 0 grows
        // instead, and pays for every growth against the same ceilings
        Hinted: Boolean;
        Sealed: Boolean;
        Retired: Boolean;
        Readers: Integer;      // live IBlobReader views
        Writers: Integer;      // 0 or 1
      end;
  private
    fLock: TCriticalSection;
    fLimits: TPWebBlobLimits;
    fEntries: array of TEntry;
    fClosed: Boolean;
    fCreated: Int64;           // cumulative, diagnostic
    fReleased: Int64;          // cumulative, diagnostic
    // all of these run under fLock
    function IndexOfLocked(const Token: RawUtf8): PtrInt;
    function NewTokenLocked: RawUtf8;
    procedure DropLocked(AIndex: PtrInt);
    procedure RetireLocked(AIndex: PtrInt);
    function ChargeLocked(const Owner: RawUtf8; Bytes: Int64;
      out Ceiling: TPWebBlobCeiling): Boolean;
    // called by the writer and the reader
    function EntryAppend(AEntry: TObject; Buffer: Pointer;
      Count: Integer): Boolean;
    function EntrySeal(AEntry: TObject; const ContentType: RawUtf8;
      out Token: RawUtf8): Boolean;
    procedure EntryAbandon(AEntry: TObject);
    procedure EntryUnref(AEntry: TObject);
  public
    /// build a store with the ratified v1 ceilings
    constructor Create; overload;
    /// build a store with ceilings of the caller's choosing
    // - a test builds one with ceilings small enough to prove every
    // refusal fires, which is the only way a ceiling is ever known to
    // work at all
    constructor Create(const ALimits: TPWebBlobLimits); overload;
    destructor Destroy; override;
    // --- IBlobStore, CAP-12A §5.1 verbatim ---
    function CreateBlob(const Owner: RawUtf8; SizeHint: Int64;
      out Writer: IBlobWriter): Boolean;
    function OpenBlob(const Owner: RawUtf8; const Token: RawUtf8;
      out Reader: IBlobReader): Boolean;
    function Release(const Owner: RawUtf8; const Token: RawUtf8): Boolean;
    function ReleaseOwner(const Owner: RawUtf8): Integer;
    function Stats(out Count: Integer; out Bytes: Int64): Boolean;
    // --- IBlobBounds ---
    function CreateBlobTyped(const Owner: RawUtf8; SizeHint: Int64;
      out Writer: IBlobWriter; out Ceiling: TPWebBlobCeiling): Boolean;
    function Limits: TPWebBlobLimits;
    function OwnerStats(const Owner: RawUtf8;
      out Count: Integer; out Bytes: Int64): Boolean;
    // --- IBlobStoreRuntime ---
    procedure Close;
    function IsOpen: Boolean;
    function LiveCount: Integer;
    function HeldCount: Integer;
    /// blobs sealed since construction - DIAGNOSTIC, never a decision
    property Created: Int64 read fCreated;
    /// tokens made unresolvable since construction - DIAGNOSTIC
    property Released: Int64 read fReleased;
  end;

implementation

type
  { One read view. It holds the BYTES, not the entry's buffer: the
    string reference is what keeps them alive past a Release, and it is
    also why ReadAt takes no lock. }
  TPWebBlobReaderView = class(TInterfacedObject, IBlobReader)
  private
    fStore: TPWebMemoryBlobStore;
    fStoreRef: IBlobStore;   // keeps the store alive while this view is
    fEntry: TObject;
    fData: RawByteString;
    fInfo: TBlobInfo;
  public
    constructor Create(AStore: TPWebMemoryBlobStore; AEntry: TObject;
      const AData: RawByteString; const AInfo: TBlobInfo);
    destructor Destroy; override;
    function Info(out Blob: TBlobInfo): Boolean;
    function ReadAt(Offset: Int64; Buffer: Pointer; Count: Integer): Integer;
  end;

  { One write view. Exclusive by construction: CreateBlob hands out
    exactly one and the entry counts it. }
  TPWebBlobWriterView = class(TInterfacedObject, IBlobWriter)
  private
    fStore: TPWebMemoryBlobStore;
    fStoreRef: IBlobStore;
    fEntry: TObject;
    fDone: Boolean;
  public
    constructor Create(AStore: TPWebMemoryBlobStore; AEntry: TObject);
    destructor Destroy; override;
    function Append(Buffer: Pointer; Count: Integer): Boolean;
    function Seal(const ContentType: RawUtf8; out Token: RawUtf8): Boolean;
    procedure Abandon;
  end;

{ ---- owner comparison, deliberately without a short circuit ---- }

// A FOREIGN TOKEN AND AN UNKNOWN TOKEN MUST COST THE SAME, so this
// walks every byte instead of returning at the first difference, and
// the length difference is folded into the accumulator rather than
// answered early. It is not a defence against a remote timing attack -
// nothing here is - it is the removal of the one comparison that WOULD
// have made the two answers trivially distinguishable from the page.
function SameOwnerCt(const a, b: RawUtf8): Boolean;
var
  i, n, m: PtrInt;
  acc: PtrUInt;
begin
  n := Length(a);
  m := Length(b);
  acc := PtrUInt(n) xor PtrUInt(m);
  if n > m then
    n := m;
  for i := 1 to n do
    acc := acc or PtrUInt(Ord(a[i]) xor Ord(b[i]));
  Result := acc = 0;
end;

{ ---- TPWebBlobReaderView ---- }

constructor TPWebBlobReaderView.Create(AStore: TPWebMemoryBlobStore;
  AEntry: TObject; const AData: RawByteString; const AInfo: TBlobInfo);
begin
  inherited Create;
  fStore := AStore;
  fStoreRef := AStore; // the store may not go while a view of it lives
  fEntry := AEntry;
  fData := AData;
  fInfo := AInfo;
end;

destructor TPWebBlobReaderView.Destroy;
begin
  if (fStore <> nil) and
     (fEntry <> nil) then
    fStore.EntryUnref(fEntry);
  fEntry := nil;
  fStore := nil;
  fStoreRef := nil;
  fData := '';
  inherited Destroy;
end;

function TPWebBlobReaderView.Info(out Blob: TBlobInfo): Boolean;
begin
  Blob := fInfo;
  Result := True;
end;

function TPWebBlobReaderView.ReadAt(Offset: Int64; Buffer: Pointer;
  Count: Integer): Integer;
var
  avail: Int64;
begin
  // NEVER RAISES, and every refusal is -1 rather than an exception: the
  // callers are three resource handlers, two of which sit behind a C
  // frame a Pascal exception may not cross
  Result := -1;
  if (Buffer = nil) or
     (Count < 0) or
     (Offset < 0) then
    exit;
  if Count = 0 then
    exit(0);
  if Offset >= Int64(Length(fData)) then
    exit(0); // at or past the end is 0, which is not a failure
  avail := Int64(Length(fData)) - Offset;
  if avail > Count then
    avail := Count;
  Move(PByteArray(pointer(fData))^[Offset], Buffer^, avail);
  Result := Integer(avail);
end;

{ ---- TPWebBlobWriterView ---- }

constructor TPWebBlobWriterView.Create(AStore: TPWebMemoryBlobStore;
  AEntry: TObject);
begin
  inherited Create;
  fStore := AStore;
  fStoreRef := AStore;
  fEntry := AEntry;
end;

destructor TPWebBlobWriterView.Destroy;
begin
  // A PRODUCER THAT DROPPED ITS WRITER WITHOUT SEALING HAS ABANDONED IT.
  // The alternative - leaving the reservation charged - turns one
  // forgotten error path into a plane that refuses every later blob.
  if not fDone then
    Abandon;
  fEntry := nil;
  fStore := nil;
  fStoreRef := nil;
  inherited Destroy;
end;

function TPWebBlobWriterView.Append(Buffer: Pointer; Count: Integer): Boolean;
begin
  Result := (not fDone) and
            (fStore <> nil) and
            fStore.EntryAppend(fEntry, Buffer, Count);
end;

function TPWebBlobWriterView.Seal(const ContentType: RawUtf8;
  out Token: RawUtf8): Boolean;
begin
  Token := '';
  if fDone or
     (fStore = nil) then
    exit(False);
  Result := fStore.EntrySeal(fEntry, ContentType, Token);
  if Result then
    fDone := True;
end;

procedure TPWebBlobWriterView.Abandon;
begin
  if fDone or
     (fStore = nil) then
    exit;
  fDone := True;
  fStore.EntryAbandon(fEntry);
end;

{ ---- TPWebMemoryBlobStore ---- }

constructor TPWebMemoryBlobStore.Create;
begin
  Create(PWebBlobDefaultLimits);
end;

constructor TPWebMemoryBlobStore.Create(const ALimits: TPWebBlobLimits);
begin
  inherited Create;
  if (ALimits.MaxBlobBytes <= 0) or
     (ALimits.MaxCountPerOwner <= 0) or
     (ALimits.MaxBytesPerOwner <= 0) or
     (ALimits.MaxCountTotal <= 0) or
     (ALimits.MaxBytesTotal <= 0) then
    raise EPWebBlobStore.Create('every blob-store ceiling must be positive');
  fLimits := ALimits;
  fLock := TCriticalSection.Create;
end;

destructor TPWebMemoryBlobStore.Destroy;
var
  i: PtrInt;
begin
  if fLock <> nil then
    fLock.Acquire;
  try
    fClosed := True;
    for i := 0 to High(fEntries) do
      fEntries[i].Free;
    fEntries := nil;
  finally
    if fLock <> nil then
      fLock.Release;
  end;
  FreeAndNil(fLock);
  inherited Destroy;
end;

function TPWebMemoryBlobStore.IndexOfLocked(const Token: RawUtf8): PtrInt;
var
  i: PtrInt;
begin
  // NO SHORT CIRCUIT. See the unit header: an unknown token and a token
  // that belongs to somebody else must cost the same walk, and a scan
  // that stopped at the hit would not.
  Result := -1;
  if Length(Token) <> PWEB_BLOB_TOKEN_CHARS then
    exit;
  for i := 0 to High(fEntries) do
    if (Length(fEntries[i].Token) = PWEB_BLOB_TOKEN_CHARS) and
       CompareMem(pointer(fEntries[i].Token), pointer(Token),
         PWEB_BLOB_TOKEN_CHARS) then
      Result := i;
end;

function TPWebMemoryBlobStore.NewTokenLocked: RawUtf8;
const
  HEX: array[0 .. 15] of AnsiChar = '0123456789abcdef';
var
  b: THash128;
  i, guard: Integer;
  candidate: RawUtf8;
begin
  // 128 BITS FROM AN UNPREDICTABLE SOURCE, not from TLecuyer: a token is
  // never an authorisation on its own - the owner is checked too - but
  // it must not be an enumeration either, and a Tausworthe generator is
  // predictable from its own output. Random128 is AES-CTR.
  //
  // The collision loop is theatre against a 2^-128 event and costs
  // nothing; what it really guards is a broken generator returning a
  // constant, which would otherwise mint one token forever.
  Result := '';
  for guard := 1 to 8 do
  begin
    Random128(@b);
    SetLength(candidate, PWEB_BLOB_TOKEN_CHARS);
    for i := 0 to 15 do
    begin
      candidate[i * 2 + 1] := HEX[b[i] shr 4];
      candidate[i * 2 + 2] := HEX[b[i] and 15];
    end;
    if IndexOfLocked(candidate) < 0 then
      exit(candidate);
  end;
end;

procedure TPWebMemoryBlobStore.DropLocked(AIndex: PtrInt);
var
  last: PtrInt;
begin
  fEntries[AIndex].Free;
  last := High(fEntries);
  if AIndex <> last then
    fEntries[AIndex] := fEntries[last];
  SetLength(fEntries, last);
end;

procedure TPWebMemoryBlobStore.RetireLocked(AIndex: PtrInt);
var
  e: TEntry;
begin
  e := fEntries[AIndex];
  // UNRESOLVABLE AT ONCE: the token is gone from the only place a lookup
  // can find it, before this procedure returns, whatever any reader is
  // doing.
  e.Token := '';
  e.Retired := True;
  // the store drops ITS reference to the bytes here; a reader that holds
  // one keeps them alive, which is precisely the contract
  e.Data := '';
  Inc(fReleased);
  if (e.Readers <= 0) and
     (e.Writers <= 0) then
    DropLocked(AIndex);
end;

function TPWebMemoryBlobStore.ChargeLocked(const Owner: RawUtf8; Bytes: Int64;
  out Ceiling: TPWebBlobCeiling): Boolean;
var
  i: PtrInt;
  ownerCount, totalCount: Integer;
  ownerBytes, totalBytes: Int64;
begin
  Ceiling := pbcNone;
  Result := False;
  if fClosed then
  begin
    Ceiling := pbcClosed;
    exit;
  end;
  if (Owner = '') or
     (Length(Owner) > PWEB_BLOB_MAX_OWNER_BYTES) then
  begin
    Ceiling := pbcInvalidOwner;
    exit;
  end;
  if (Bytes < 0) or
     (Bytes > fLimits.MaxBlobBytes) then
  begin
    Ceiling := pbcBlobBytes;
    exit;
  end;
  ownerCount := 0;
  totalCount := 0;
  ownerBytes := 0;
  totalBytes := 0;
  for i := 0 to High(fEntries) do
  begin
    Inc(totalCount);
    Inc(totalBytes, fEntries[i].Reserved);
    if fEntries[i].Owner = Owner then
    begin
      Inc(ownerCount);
      Inc(ownerBytes, fEntries[i].Reserved);
    end;
  end;
  // THE ORDER IS THE REPORT'S ORDER: the most specific ceiling first, so
  // a principal that is over its own bound is told that rather than
  // being told the store is full.
  if ownerCount + 1 > fLimits.MaxCountPerOwner then
    Ceiling := pbcOwnerCount
  else if ownerBytes + Bytes > fLimits.MaxBytesPerOwner then
    Ceiling := pbcOwnerBytes
  else if totalCount + 1 > fLimits.MaxCountTotal then
    Ceiling := pbcTotalCount
  else if totalBytes + Bytes > fLimits.MaxBytesTotal then
    Ceiling := pbcTotalBytes
  else
    Result := True;
end;

function TPWebMemoryBlobStore.CreateBlobTyped(const Owner: RawUtf8;
  SizeHint: Int64; out Writer: IBlobWriter;
  out Ceiling: TPWebBlobCeiling): Boolean;
var
  e: TEntry;
begin
  Writer := nil;
  Ceiling := pbcNone;
  Result := False;
  if SizeHint < 0 then
  begin
    Ceiling := pbcBlobBytes;
    exit;
  end;
  fLock.Acquire;
  try
    if not ChargeLocked(Owner, SizeHint, Ceiling) then
      exit;
    e := TEntry.Create;
    e.Token := '';          // unresolvable until Seal mints one
    e.Owner := Owner;
    e.Reserved := SizeHint; // charged from this instant, not from Seal
    e.Filled := 0;
    e.Hinted := SizeHint > 0;
    e.Writers := 1;
    if SizeHint > 0 then
      // ONE ALLOCATION FOR A KNOWN SIZE. The producer that matters -
      // the fetch door - always knows the length, and growing a
      // RawByteString in place would reallocate and briefly hold twice
      // the body, which is the exact cost §5.3 bounds.
      SetLength(e.Data, SizeHint);
    SetLength(fEntries, Length(fEntries) + 1);
    fEntries[High(fEntries)] := e;
  finally
    fLock.Release;
  end;
  Writer := TPWebBlobWriterView.Create(Self, e);
  Result := True;
end;

function TPWebMemoryBlobStore.CreateBlob(const Owner: RawUtf8;
  SizeHint: Int64; out Writer: IBlobWriter): Boolean;
var
  ignored: TPWebBlobCeiling;
begin
  Result := CreateBlobTyped(Owner, SizeHint, Writer, ignored);
end;

function TPWebMemoryBlobStore.EntryAppend(AEntry: TObject; Buffer: Pointer;
  Count: Integer): Boolean;
var
  e: TEntry;
  ceiling: TPWebBlobCeiling;
  grow: Int64;
begin
  Result := False;
  e := TEntry(AEntry);
  if (e = nil) or
     (Count < 0) then
    exit;
  if Count = 0 then
    exit(True);
  if Buffer = nil then
    exit;
  fLock.Acquire;
  try
    if e.Sealed or
       e.Retired or
       (e.Writers <= 0) then
      exit;
    if e.Filled + Count > e.Reserved then
    begin
      // A RESERVATION IS A CEILING, not a hint about how much to
      // allocate: a producer that declared 8 MiB and sends 9 is refused
      // here rather than quietly re-charged, because the ceiling decision
      // was taken once at create time against the numbers as they were
      // then and re-taking it per append is how a bound stops being one.
      if e.Hinted then
        exit;
      // A blob created with SizeHint = 0 grows instead, and pays for
      // every growth against the same ceilings a create would - INCLUDING
      // the per-blob one, which is checked on the RESULTING size rather
      // than on the increment. Charging only the increment would let a
      // blob walk past MaxBlobBytes in steps that each fit.
      grow := e.Filled + Count - e.Reserved;
      if e.Reserved + grow > fLimits.MaxBlobBytes then
        exit;
      if not ChargeLocked(e.Owner, grow, ceiling) then
        exit;
      Inc(e.Reserved, grow);
      SetLength(e.Data, e.Reserved);
    end;
    Move(Buffer^, PByteArray(pointer(e.Data))^[e.Filled], Count);
    Inc(e.Filled, Count);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.EntrySeal(AEntry: TObject;
  const ContentType: RawUtf8; out Token: RawUtf8): Boolean;
var
  e: TEntry;
  i: PtrInt;
begin
  Token := '';
  Result := False;
  e := TEntry(AEntry);
  if e = nil then
    exit;
  if (ContentType = '') or
     (Length(ContentType) > PWEB_BLOB_MAX_CONTENT_TYPE_BYTES) then
    exit; // a blob without a type is a blob the plane cannot serve
  for i := 1 to Length(ContentType) do
    // a header value carrying CR, LF or NUL is a second header, and this
    // one is written into three different native header sets
    if ContentType[i] < ' ' then
      exit;
  fLock.Acquire;
  try
    if fClosed or
       e.Sealed or
       e.Retired or
       (e.Writers <= 0) then
      exit;
    // THE RESERVATION IS RETURNED at seal: a producer that reserved
    // 8 MiB and wrote 1 keeps 1 charged, not 8. The ceilings are about
    // what is resident, and after this point that is exactly Filled.
    if e.Filled < e.Reserved then
    begin
      SetLength(e.Data, e.Filled);
      e.Reserved := e.Filled;
    end;
    e.ContentType := ContentType;
    e.Sealed := True;
    e.Writers := 0;
    e.Token := NewTokenLocked;
    if e.Token = '' then
      exit; // the generator is broken; the blob stays unresolvable
    Token := e.Token;
    Inc(fCreated);
    Result := True;
  finally
    fLock.Release;
  end;
end;

procedure TPWebMemoryBlobStore.EntryAbandon(AEntry: TObject);
var
  e: TEntry;
  i: PtrInt;
begin
  e := TEntry(AEntry);
  if e = nil then
    exit;
  fLock.Acquire;
  try
    if e.Sealed then
      exit; // already a blob; Release is what ends it now
    e.Writers := 0;
    for i := 0 to High(fEntries) do
      if fEntries[i] = e then
      begin
        // never sealed, so no reader can exist and nothing is owed
        DropLocked(i);
        break;
      end;
  finally
    fLock.Release;
  end;
end;

procedure TPWebMemoryBlobStore.EntryUnref(AEntry: TObject);
var
  e: TEntry;
  i: PtrInt;
begin
  e := TEntry(AEntry);
  if e = nil then
    exit;
  fLock.Acquire;
  try
    if e.Readers > 0 then
      Dec(e.Readers);
    if e.Retired and
       (e.Readers <= 0) and
       (e.Writers <= 0) then
      for i := 0 to High(fEntries) do
        if fEntries[i] = e then
        begin
          DropLocked(i);
          break;
        end;
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.OpenBlob(const Owner: RawUtf8;
  const Token: RawUtf8; out Reader: IBlobReader): Boolean;
var
  idx: PtrInt;
  e: TEntry;
  data: RawByteString;
  info: TBlobInfo;
  ownerOk: Boolean;
begin
  Reader := nil;
  Result := False;
  data := '';
  e := nil;
  fLock.Acquire;
  try
    if fClosed then
      exit;
    idx := IndexOfLocked(Token);
    // THE OWNER COMPARISON RUNS WHATEVER THE SCAN FOUND. Comparing only
    // on a hit is what would make "somebody else's token" measurably
    // cheaper than "no such token", and CAP-12A §5.2 requires the two to
    // be indistinguishable from outside.
    if idx < 0 then
      ownerOk := SameOwnerCt(Owner, Owner)
    else
      ownerOk := SameOwnerCt(Owner, fEntries[idx].Owner);
    if (idx < 0) or
       not ownerOk then
      exit;
    e := fEntries[idx];
    if not e.Sealed or
       e.Retired then
      exit;
    Inc(e.Readers);
    data := e.Data;          // a reference, not a copy
    info.Size := e.Filled;
    info.ContentType := e.ContentType;
    info.Owner := e.Owner;
    info.Sealed := True;
  finally
    fLock.Release;
  end;
  if e = nil then
    exit;
  Reader := TPWebBlobReaderView.Create(Self, e, data, info);
  Result := True;
end;

function TPWebMemoryBlobStore.Release(const Owner: RawUtf8;
  const Token: RawUtf8): Boolean;
var
  idx: PtrInt;
  ownerOk: Boolean;
begin
  Result := False;
  fLock.Acquire;
  try
    idx := IndexOfLocked(Token);
    if idx < 0 then
      ownerOk := SameOwnerCt(Owner, Owner)
    else
      ownerOk := SameOwnerCt(Owner, fEntries[idx].Owner);
    if (idx < 0) or
       not ownerOk then
      exit;
    RetireLocked(idx);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.ReleaseOwner(const Owner: RawUtf8): Integer;
var
  i: PtrInt;
begin
  Result := 0;
  if Owner = '' then
    exit;
  fLock.Acquire;
  try
    // BACKWARDS, because RetireLocked may drop the entry and DropLocked
    // moves the last element into the hole
    for i := High(fEntries) downto 0 do
      if (fEntries[i].Owner = Owner) and
         not fEntries[i].Retired then
      begin
        if fEntries[i].Sealed then
          Inc(Result);
        RetireLocked(i);
      end;
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.Stats(out Count: Integer;
  out Bytes: Int64): Boolean;
var
  i: PtrInt;
begin
  Count := 0;
  Bytes := 0;
  fLock.Acquire;
  try
    for i := 0 to High(fEntries) do
    begin
      Inc(Count);
      Inc(Bytes, fEntries[i].Reserved);
    end;
  finally
    fLock.Release;
  end;
  Result := True;
end;

function TPWebMemoryBlobStore.OwnerStats(const Owner: RawUtf8;
  out Count: Integer; out Bytes: Int64): Boolean;
var
  i: PtrInt;
begin
  Count := 0;
  Bytes := 0;
  fLock.Acquire;
  try
    for i := 0 to High(fEntries) do
      if fEntries[i].Owner = Owner then
      begin
        Inc(Count);
        Inc(Bytes, fEntries[i].Reserved);
      end;
  finally
    fLock.Release;
  end;
  Result := True;
end;

function TPWebMemoryBlobStore.Limits: TPWebBlobLimits;
begin
  Result := fLimits;
end;

procedure TPWebMemoryBlobStore.Close;
var
  i: PtrInt;
begin
  fLock.Acquire;
  try
    fClosed := True;
    for i := High(fEntries) downto 0 do
      if not fEntries[i].Retired then
        RetireLocked(i);
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.IsOpen: Boolean;
begin
  fLock.Acquire;
  try
    Result := not fClosed;
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.LiveCount: Integer;
var
  i: PtrInt;
begin
  Result := 0;
  fLock.Acquire;
  try
    for i := 0 to High(fEntries) do
      if fEntries[i].Sealed and
         not fEntries[i].Retired then
        Inc(Result);
  finally
    fLock.Release;
  end;
end;

function TPWebMemoryBlobStore.HeldCount: Integer;
begin
  fLock.Acquire;
  try
    Result := Length(fEntries);
  finally
    fLock.Release;
  end;
end;

end.
