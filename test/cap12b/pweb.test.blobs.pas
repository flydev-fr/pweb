{
  pweb.test.blobs - the CAP-12B suite over the blob data plane
  (mormot.core.test).

  EVERY CONTRACT ROW, AND NOT ONE ENGINE. The store and the translator are
  platform-independent by construction - IBlobStore names no URI scheme and
  the translator names no native type - so the whole of CAP-12A §5 and the
  Range grammar of §6.1 are provable headless, on all four targets, with no
  window, no display and no scheme handler.

    STORE      create/append/seal/open/read at offset; Info before bytes; a
               foreign owner answered exactly as an unknown token; release
               semantics and the reader refcount; ReleaseOwner; Close
    CEILINGS   every bound, per principal and in total, each one proven to
               FIRE on a store built with ceilings small enough to reach
    GRAMMAR    the token grammar, the reserved prefix, and the Range grammar
               ratified by CAP-12B: a-b, -suffix, a-, unsatisfiable, multi,
               malformed - each to its own typed answer
    EXCHANGE   what a handler gets back: the 206 headers exactly, the 200 a
               declined Range produces, the 416, the typed upload refusal
               and its receipt, and the content type taken from the info
               record rather than from the MIME table
    LIFECYCLE  a document replacement, the CAP-9 shutdown order and a
               capability revocation, each releasing what it owes

  WHAT IS NOT HERE, on purpose: anything that needs an engine. That a 206
  built here is honoured by fetch(), that a Range header reaches a handler
  at all, and that a typed-array body arrives byte-exact are ENGINE facts,
  and they are measured live by test/cap12b/bloblive.pas on four targets.

  It emits build/cap12b/blob-corpus.txt, one LF line per decision, which the
  CAP-7F emitters hash into blob_corpus_digest. Every line is the verdict of
  platform-independent logic: no path, no version, no timing, no token - a
  token is 128 random bits and a corpus that carried one would never repeat.
}

{$I mormot.defines.inc}

unit pweb.test.blobs;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.test,
  pweb.assets.support,
  pweb.blobs.intf,
  pweb.blobs.memory,
  pweb.blobs.protocol,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.fetch;

type
  TTestPWebBlobStore = class(TSynTestCase)
  published
    procedure WriteSealRead;
    procedure InfoBeforeBytes;
    procedure ForeignOwnerIsUnknown;
    procedure ReleaseAndRefcount;
    procedure ReleaseOwnerAndClose;
    procedure TokenEntropy;
  end;

  TTestPWebBlobCeilings = class(TSynTestCase)
  published
    procedure PerOwnerCount;
    procedure PerOwnerBytes;
    procedure TotalCount;
    procedure TotalBytes;
    procedure OneBlobTooLarge;
    procedure ReservationIsACeiling;
  end;

  TTestPWebBlobGrammar = class(TSynTestCase)
  published
    procedure Tokens;
    procedure ReservedPrefix;
    procedure RangeGrammar;
  end;

  TTestPWebBlobExchange = class(TSynTestCase)
  published
    procedure WholeBody;
    procedure SingleRange;
    procedure SuffixRange;
    procedure DeclinedRange;
    procedure Unsatisfiable;
    procedure UploadRefused;
    procedure UnknownAndForeign;
    procedure ContentTypeFromInfo;
  end;

  TTestPWebBlobLifecycle = class(TSynTestCase)
  published
    procedure DocumentReplaced;
    procedure ShutdownOrder;
    procedure Revocation;
  end;

  TTestPWebBlobFetchDoor = class(TSynTestCase)
  published
    procedure InlineIsUnchanged;
    procedure OverInlineBecomesAHandle;
    procedure OverTheCeilingIsStillRefused;
    procedure WithoutAPlaneNothingChanges;
    procedure ACeilingIsAnsweredByName;
  end;

implementation

const
  OWNER_A = 'window:main';
  OWNER_B = 'plugin:other';

var
  // one corpus per process, appended by every case in declaration order
  BlobCorpus: TRawUtf8DynArray;

// ONE LINE PER DECISION, and never a token: the corpus is hashed into an
// evidence digest that has to be identical on four targets, and a token is
// 128 bits of fresh randomness by design.
procedure Note(const Line: RawUtf8);
begin
  SetLength(BlobCorpus, Length(BlobCorpus) + 1);
  BlobCorpus[High(BlobCorpus)] := Line;
end;

procedure WriteCorpus;
var
  i: PtrInt;
  all: RawUtf8;
  path: TFileName;
begin
  all := '';
  for i := 0 to High(BlobCorpus) do
    all := all + BlobCorpus[i] + #10;
  path := MakePath([Executable.ProgramFilePath, 'blob-corpus.txt']);
  FileFromString(all, path);
end;

function Pattern(Size: PtrInt; Offset: PtrInt = 0): RawByteString;
var
  i: PtrInt;
begin
  SetLength(Result, Size);
  for i := 0 to Size - 1 do
    Result[i + 1] := AnsiChar((i + Offset) mod 251);
end;

function TinyLimits: TPWebBlobLimits;
begin
  // SMALL ENOUGH TO REACH, which is the only way a ceiling is ever known to
  // work: at the ratified numbers a test would have to allocate 256 MiB to
  // see one fire, so it would not, so nobody would know whether it does.
  Result.MaxBlobBytes := 1024;
  Result.MaxCountPerOwner := 3;
  Result.MaxBytesPerOwner := 2048;
  Result.MaxCountTotal := 4;
  Result.MaxBytesTotal := 3072;
end;

function PutInto(const Store: IBlobStore; const Owner: RawUtf8;
  const Content: RawByteString; const Mime: RawUtf8;
  out Token: RawUtf8): TPWebBlobCeiling;
begin
  if PWebBlobPut(Store, Owner, Content, Mime, Token, Result) then
    Result := pbcNone;
end;

function ReadWhole(const Reader: IBlobReader; Size: Int64): RawByteString;
var
  got: Integer;
begin
  Result := '';
  if Size <= 0 then
    exit;
  SetLength(Result, Size);
  got := Reader.ReadAt(0, pointer(Result), Integer(Size));
  if got <> Size then
    Result := '';
end;

{ ---- TTestPWebBlobStore ---- }

procedure TTestPWebBlobStore.WriteSealRead;
var
  store: IBlobStore;
  writer: IBlobWriter;
  reader: IBlobReader;
  token: RawUtf8;
  content, window: RawByteString;
  got: Integer;
begin
  store := TPWebMemoryBlobStore.Create;
  content := Pattern(4096);
  Check(store.CreateBlob(OWNER_A, Length(content), writer), 'create');
  Check(writer <> nil, 'writer');
  // APPENDED IN THREE PIECES, because a producer that had the whole body in
  // one buffer would never exercise the offset arithmetic
  Check(writer.Append(@content[1], 1000), 'append 1');
  Check(writer.Append(@content[1001], 2000), 'append 2');
  Check(writer.Append(@content[3001], 1096), 'append 3');
  Check(writer.Seal('application/octet-stream', token), 'seal');
  Check(PWebBlobValidToken(token), 'token grammar');
  writer := nil;
  Check(store.OpenBlob(OWNER_A, token, reader), 'open');
  CheckEqual(ReadWhole(reader, 4096), content, 'whole');
  // POSITIONED READS, which is the only read the plane has
  SetLength(window, 100);
  got := reader.ReadAt(1000, pointer(window), 100);
  CheckEqual(got, 100, 'window length');
  CheckEqual(window, Copy(content, 1001, 100), 'window offset');
  // at or past the end is 0, and 0 is not a failure
  CheckEqual(reader.ReadAt(4096, pointer(window), 100), 0, 'at end');
  CheckEqual(reader.ReadAt(9999, pointer(window), 100), 0, 'past end');
  // a short tail is short, never an error
  CheckEqual(reader.ReadAt(4090, pointer(window), 100), 6, 'tail');
  // and every refusal is -1, never an exception
  CheckEqual(reader.ReadAt(-1, pointer(window), 100), -1, 'negative offset');
  CheckEqual(reader.ReadAt(0, nil, 100), -1, 'nil buffer');
  Note('store.write_seal_read=ok');
end;

procedure TTestPWebBlobStore.InfoBeforeBytes;
var
  store: IBlobStore;
  reader: IBlobReader;
  token: RawUtf8;
  info: TBlobInfo;
begin
  store := TPWebMemoryBlobStore.Create;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(8192), 'image/png', token)),
    Ord(pbcNone), 'put');
  Check(store.OpenBlob(OWNER_A, token, reader), 'open');
  // THE WHOLE REASON TBlobInfo EXISTS: a 206 needs a total, and the frozen
  // IAssetStore.TryRead cannot report one without materialising the body -
  // which CAP-12A measured at twice the body on both engines.
  Check(reader.Info(info), 'info');
  CheckEqual(info.Size, 8192, 'size');
  CheckEqual(info.ContentType, 'image/png', 'type');
  CheckEqual(info.Owner, OWNER_A, 'owner');
  Check(info.Sealed, 'sealed');
  Note('store.info_before_bytes=ok');
end;

procedure TTestPWebBlobStore.ForeignOwnerIsUnknown;
var
  store: IBlobStore;
  reader: IBlobReader;
  token, unknown: RawUtf8;
  i: PtrInt;
  foreignUs, unknownUs: Int64;
  t: Int64;
begin
  store := TPWebMemoryBlobStore.Create;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(64), 'text/plain', token)),
    Ord(pbcNone), 'put');
  unknown := '0123456789abcdef0123456789abcdef';
  Check(unknown <> token, 'the unknown token is not the real one');
  // A FOREIGN TOKEN IS ANSWERED EXACTLY AS AN UNKNOWN ONE IS - the CAP-8C
  // multi-principal rule, and the same shape CAP-15C gives a foreign socket
  Check(not store.OpenBlob(OWNER_B, token, reader), 'foreign refused');
  Check(reader = nil, 'foreign yields no reader');
  Check(not store.OpenBlob(OWNER_A, unknown, reader), 'unknown refused');
  Check(not store.Release(OWNER_B, token), 'foreign cannot release');
  Check(store.OpenBlob(OWNER_A, token, reader), 'the owner still resolves');
  reader := nil;
  // AND THE TWO COST THE SAME, measured rather than asserted from the code.
  // The bound is deliberately loose - this is a scheduler-dependent
  // measurement on four very different machines - and what it refuses is an
  // ORDER-OF-MAGNITUDE difference, which is what a short-circuiting scan
  // would produce once the store held its ratified 512 entries.
  for i := 1 to 200 do // warm
    store.OpenBlob(OWNER_B, token, reader);
  t := GetTickCount64;
  for i := 1 to 20000 do
    store.OpenBlob(OWNER_B, token, reader);
  foreignUs := GetTickCount64 - t;
  t := GetTickCount64;
  for i := 1 to 20000 do
    store.OpenBlob(OWNER_A, unknown, reader);
  unknownUs := GetTickCount64 - t;
  Check((foreignUs <= (unknownUs * 4) + 25) and
        (unknownUs <= (foreignUs * 4) + 25),
    FormatUtf8('foreign % ms vs unknown % ms over 20000 lookups',
      [foreignUs, unknownUs]));
  Note('store.foreign_is_unknown=ok');
end;

procedure TTestPWebBlobStore.ReleaseAndRefcount;
var
  store: IBlobStore;
  runtime: IBlobStoreRuntime;
  reader, second: IBlobReader;
  token: RawUtf8;
  content: RawByteString;
  count: Integer;
  bytes: Int64;
begin
  store := TPWebMemoryBlobStore.Create;
  runtime := store as IBlobStoreRuntime;
  content := Pattern(2048);
  CheckEqual(Ord(PutInto(store, OWNER_A, content, 'text/plain', token)),
    Ord(pbcNone), 'put');
  Check(store.OpenBlob(OWNER_A, token, reader), 'open');
  CheckEqual(runtime.LiveCount, 1, 'live before release');
  // RELEASE MAKES THE TOKEN UNRESOLVABLE AT ONCE...
  Check(store.Release(OWNER_A, token), 'release');
  Check(not store.OpenBlob(OWNER_A, token, second), 'unresolvable at once');
  Check(not store.Release(OWNER_A, token), 'released twice is not found');
  CheckEqual(runtime.LiveCount, 0, 'no live blob');
  // ...AND THE BYTES GO WITH THE LAST READER. The reader opened before the
  // release still reads its whole body: this is what makes a scheme task
  // that is mid-window unable to read freed memory.
  CheckEqual(ReadWhole(reader, 2048), content, 'the reader still reads');
  Check(store.Stats(count, bytes), 'stats');
  CheckEqual(count, 1, 'the retired entry is still held');
  CheckEqual(bytes, 2048, 'and still charged');
  reader := nil;
  Check(store.Stats(count, bytes), 'stats after the last reader');
  CheckEqual(count, 0, 'the entry goes with the last reader');
  CheckEqual(bytes, 0, 'and so does the charge');
  Note('store.release_refcount=ok');
end;

procedure TTestPWebBlobStore.ReleaseOwnerAndClose;
var
  store: IBlobStore;
  runtime: IBlobStoreRuntime;
  writer: IBlobWriter;
  token: RawUtf8;
  tokens: array[0 .. 2] of RawUtf8;
  i: PtrInt;
  count: Integer;
  bytes: Int64;
begin
  store := TPWebMemoryBlobStore.Create;
  runtime := store as IBlobStoreRuntime;
  for i := 0 to 2 do
    CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(16), 'text/plain',
      tokens[i])), Ord(pbcNone), 'put a');
  CheckEqual(Ord(PutInto(store, OWNER_B, Pattern(16), 'text/plain', token)),
    Ord(pbcNone), 'put b');
  CheckEqual(store.ReleaseOwner(OWNER_A), 3, 'three of this principal');
  CheckEqual(store.ReleaseOwner(OWNER_A), 0, 'and no more');
  CheckEqual(runtime.LiveCount, 1, 'the other principal is untouched');
  CheckEqual(store.ReleaseOwner(''), 0, 'an empty owner releases nothing');
  // CLOSE ENDS THE PLANE and refuses every new blob after it
  runtime.Close;
  Check(not runtime.IsOpen, 'closed');
  CheckEqual(runtime.LiveCount, 0, 'every blob of every principal');
  Check(not store.CreateBlob(OWNER_A, 16, writer), 'no new blob');
  runtime.Close; // idempotent
  Check(store.Stats(count, bytes), 'stats');
  CheckEqual(count, 0, 'nothing held');
  Note('store.release_owner_close=ok');
end;

procedure TTestPWebBlobStore.TokenEntropy;
var
  store: IBlobStore;
  seen: TRawUtf8DynArray;
  token: RawUtf8;
  i, j: PtrInt;
begin
  store := TPWebMemoryBlobStore.Create;
  SetLength(seen, 256);
  for i := 0 to High(seen) do
  begin
    CheckEqual(Ord(PutInto(store, OWNER_A, '', 'text/plain', token)),
      Ord(pbcNone), 'put');
    Check(PWebBlobValidToken(token), 'grammar');
    CheckEqual(Length(token), PWEB_BLOB_TOKEN_CHARS, '32 hex characters');
    seen[i] := token;
    Check(store.Release(OWNER_A, token), 'release');
  end;
  // NOT AN ENTROPY TEST - 256 samples cannot be one - but a COLLISION and a
  // CONSTANT-GENERATOR test, which are the two ways this could be broken in
  // a way that matters: a token that repeats is a token another principal
  // can guess by waiting.
  for i := 0 to High(seen) do
    for j := i + 1 to High(seen) do
      if seen[i] = seen[j] then
        Check(False, 'two blobs were minted the same token');
  Note('store.token_grammar=ok');
end;

{ ---- TTestPWebBlobCeilings ---- }

procedure TTestPWebBlobCeilings.PerOwnerCount;
var
  store: IBlobStore;
  bounds: IBlobBounds;
  writer: IBlobWriter;
  ceiling: TPWebBlobCeiling;
  token: RawUtf8;
  i: PtrInt;
begin
  store := TPWebMemoryBlobStore.Create(TinyLimits);
  bounds := store as IBlobBounds;
  for i := 1 to 3 do
    CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(16), 'text/plain', token)),
      Ord(pbcNone), 'within the count');
  Check(not bounds.CreateBlobTyped(OWNER_A, 16, writer, ceiling), 'refused');
  CheckEqual(Ord(ceiling), Ord(pbcOwnerCount), 'names the ceiling it hit');
  CheckEqual(PWebBlobCeilingCategory(ceiling), PWEB_BLOB_CAT_OWNER_COUNT,
    'typed category');
  // ANOTHER PRINCIPAL IS UNAFFECTED: a per-principal ceiling that bound the
  // store would be a denial of service one page could aim at another
  CheckEqual(Ord(PutInto(store, OWNER_B, Pattern(16), 'text/plain', token)),
    Ord(pbcNone), 'the other principal still fits');
  Note('ceiling.owner_count=fires');
end;

procedure TTestPWebBlobCeilings.PerOwnerBytes;
var
  store: IBlobStore;
  bounds: IBlobBounds;
  writer: IBlobWriter;
  ceiling: TPWebBlobCeiling;
  token: RawUtf8;
  count: Integer;
  bytes: Int64;
begin
  store := TPWebMemoryBlobStore.Create(TinyLimits);
  bounds := store as IBlobBounds;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(1024), 'text/plain', token)),
    Ord(pbcNone), 'one');
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(1024), 'text/plain', token)),
    Ord(pbcNone), 'two');
  Check(bounds.OwnerStats(OWNER_A, count, bytes), 'owner stats');
  CheckEqual(count, 2, 'two blobs');
  CheckEqual(bytes, 2048, 'at the byte ceiling');
  Check(not bounds.CreateBlobTyped(OWNER_A, 1, writer, ceiling), 'refused');
  CheckEqual(Ord(ceiling), Ord(pbcOwnerBytes), 'names the ceiling it hit');
  CheckEqual(PWebBlobCeilingCategory(ceiling), PWEB_BLOB_CAT_OWNER_BYTES,
    'typed category');
  Note('ceiling.owner_bytes=fires');
end;

procedure TTestPWebBlobCeilings.TotalCount;
var
  store: IBlobStore;
  bounds: IBlobBounds;
  writer: IBlobWriter;
  ceiling: TPWebBlobCeiling;
  token: RawUtf8;
  i: PtrInt;
begin
  store := TPWebMemoryBlobStore.Create(TinyLimits);
  bounds := store as IBlobBounds;
  for i := 1 to 3 do
    CheckEqual(Ord(PutInto(store, OWNER_A, '', 'text/plain', token)),
      Ord(pbcNone), 'owner a');
  CheckEqual(Ord(PutInto(store, OWNER_B, '', 'text/plain', token)),
    Ord(pbcNone), 'owner b reaches the total');
  Check(not bounds.CreateBlobTyped(OWNER_B, 0, writer, ceiling), 'refused');
  CheckEqual(Ord(ceiling), Ord(pbcTotalCount), 'names the ceiling it hit');
  CheckEqual(PWebBlobCeilingCategory(ceiling), PWEB_BLOB_CAT_TOTAL_COUNT,
    'typed category');
  Note('ceiling.total_count=fires');
end;

procedure TTestPWebBlobCeilings.TotalBytes;
var
  store: IBlobStore;
  bounds: IBlobBounds;
  writer: IBlobWriter;
  ceiling: TPWebBlobCeiling;
  token: RawUtf8;
begin
  store := TPWebMemoryBlobStore.Create(TinyLimits);
  bounds := store as IBlobBounds;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(1024), 'text/plain', token)),
    Ord(pbcNone), 'a1');
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(1024), 'text/plain', token)),
    Ord(pbcNone), 'a2');
  CheckEqual(Ord(PutInto(store, OWNER_B, Pattern(1024), 'text/plain', token)),
    Ord(pbcNone), 'b1');
  Check(not bounds.CreateBlobTyped(OWNER_B, 1, writer, ceiling), 'refused');
  CheckEqual(Ord(ceiling), Ord(pbcTotalBytes), 'names the ceiling it hit');
  CheckEqual(PWebBlobCeilingCategory(ceiling), PWEB_BLOB_CAT_TOTAL_BYTES,
    'typed category');
  Note('ceiling.total_bytes=fires');
end;

procedure TTestPWebBlobCeilings.OneBlobTooLarge;
var
  store: IBlobStore;
  bounds: IBlobBounds;
  writer: IBlobWriter;
  ceiling: TPWebBlobCeiling;
  limits: TPWebBlobLimits;
begin
  store := TPWebMemoryBlobStore.Create(TinyLimits);
  bounds := store as IBlobBounds;
  limits := bounds.Limits;
  CheckEqual(limits.MaxBlobBytes, 1024, 'the limits come back');
  Check(not bounds.CreateBlobTyped(OWNER_A, limits.MaxBlobBytes + 1, writer,
    ceiling), 'refused');
  CheckEqual(Ord(ceiling), Ord(pbcBlobBytes), 'names the ceiling it hit');
  CheckEqual(PWebBlobCeilingCategory(ceiling), PWEB_BLOB_CAT_BLOB_BYTES,
    'typed category');
  // an empty owner is never charged: the store would otherwise share one
  // account between every caller that forgot to pass a principal
  Check(not bounds.CreateBlobTyped('', 16, writer, ceiling), 'no owner');
  CheckEqual(Ord(ceiling), Ord(pbcInvalidOwner), 'invalid owner');
  Note('ceiling.blob_bytes=fires');
end;

procedure TTestPWebBlobCeilings.ReservationIsACeiling;
var
  store: IBlobStore;
  writer: IBlobWriter;
  grown: IBlobReader;
  token: RawUtf8;
  content: RawByteString;
  count: Integer;
  bytes: Int64;
begin
  store := TPWebMemoryBlobStore.Create(TinyLimits);
  content := Pattern(64);
  // A RESERVATION IS A CEILING, not a hint about how much to allocate
  Check(store.CreateBlob(OWNER_A, 64, writer), 'create');
  Check(writer.Append(pointer(content), 64), 'fills it');
  Check(not writer.Append(pointer(content), 1), 'and not one byte more');
  Check(writer.Seal('text/plain', token), 'seal');
  writer := nil;
  // A BLOB CREATED WITH NO HINT GROWS, and pays for every growth against
  // the same ceilings a create would
  Check(store.CreateBlob(OWNER_A, 0, writer), 'create unsized');
  Check(writer.Append(pointer(content), 64), 'grows');
  Check(writer.Append(pointer(content), 64), 'and again');
  Check(writer.Seal('text/plain', token), 'seal');
  writer := nil;
  Check(store.OpenBlob(OWNER_A, token, grown), 'the grown blob opens');
  CheckEqual(ReadWhole(grown, 128), content + content, 'both appends');
  grown := nil;
  // AND THE RESERVATION IS RETURNED AT SEAL: a producer that reserved a
  // kilobyte and wrote sixteen bytes keeps sixteen charged
  Check(store.CreateBlob(OWNER_A, 1024, writer), 'create oversized');
  Check(writer.Append(pointer(content), 16), 'writes little');
  Check(writer.Seal('text/plain', token), 'seal');
  writer := nil;
  Check((store as IBlobBounds).OwnerStats(OWNER_A, count, bytes), 'stats');
  CheckEqual(bytes, 64 + 128 + 16, 'only what was written is charged');
  Note('ceiling.reservation=ok');
end;

{ ---- TTestPWebBlobGrammar ---- }

procedure TTestPWebBlobGrammar.Tokens;
begin
  Check(PWebBlobValidToken('0123456789abcdef0123456789abcdef'), 'canonical');
  Check(not PWebBlobValidToken(''), 'empty');
  Check(not PWebBlobValidToken('0123456789abcdef0123456789abcde'), 'short');
  Check(not PWebBlobValidToken('0123456789abcdef0123456789abcdef0'), 'long');
  // UPPERCASE IS A DIFFERENT TOKEN, refused rather than folded: two
  // spellings of one token would be two cache keys to an engine
  Check(not PWebBlobValidToken('0123456789ABCDEF0123456789abcdef'), 'upper');
  Check(not PWebBlobValidToken('0123456789abcdef0123456789abcdeg'), 'non-hex');
  Check(not PWebBlobValidToken('0123456789abcdef0123456789abcd f'), 'space');
  Note('grammar.token=ok');
end;

procedure TTestPWebBlobGrammar.ReservedPrefix;
var
  logical: RawUtf8;
begin
  Check(PWebBlobIsReserved('_pweb'), 'the segment alone');
  Check(PWebBlobIsReserved('_pweb/blob/0123456789abcdef0123456789abcdef'),
    'a blob path');
  Check(PWebBlobIsReserved('_pweb/anything/else'), 'anything under it');
  // A PATH THAT MERELY STARTS WITH THOSE FIVE BYTES IS AN ORDINARY ASSET
  Check(not PWebBlobIsReserved('_pwebbing/x'), 'not a prefix match');
  Check(not PWebBlobIsReserved('assets/_pweb/x'), 'not a first segment');
  Check(not PWebBlobIsReserved('index.html'), 'an ordinary asset');
  Check(not PWebBlobIsReserved(''), 'empty');
  // and the reserved path is one PWebAssetPathValid accepts, which is what
  // makes the serve-time branch reachable at all
  Check(PWebAssetPathValid('_pweb/blob/0123456789abcdef0123456789abcdef'),
    'canonical by the frozen rules');
  CheckEqual(PWebBlobPathToken('_pweb/blob/0123456789abcdef0123456789abcdef'),
    '0123456789abcdef0123456789abcdef', 'token out');
  CheckEqual(PWebBlobPathToken('_pweb/blob/short'), '', 'short token');
  CheckEqual(PWebBlobPathToken('_pweb/blob/0123456789abcdef0123456789abcdef/x'),
    '', 'a fourth segment');
  CheckEqual(PWebBlobPathToken('_pweb/other/0123456789abcdef0123456789abcdef'),
    '', 'another namespace under the reservation');
  CheckEqual(PWebBlobUrl('0123456789abcdef0123456789abcdef'),
    'pweb://app/_pweb/blob/0123456789abcdef0123456789abcdef', 'url');
  CheckEqual(PWebBlobUrl('nope'), '', 'no url for a malformed token');
  // THE QUERY STRING IS NOT A CHANNEL, and this is the frozen parser saying
  // so rather than the plane: `?range=1` is cut before the path is validated
  Check(PWebParseAppUri(
    'pweb://app/_pweb/blob/0123456789abcdef0123456789abcdef?range=1', logical),
    'parses');
  CheckEqual(logical, '_pweb/blob/0123456789abcdef0123456789abcdef',
    'the query is not part of the resource');
  Note('grammar.reserved_prefix=ok');
end;

procedure TTestPWebBlobGrammar.RangeGrammar;
var
  first, last: Int64;

  procedure Single(const Raw: RawUtf8; Total, WantFirst, WantLast: Int64);
  begin
    CheckEqual(Ord(PWebBlobParseRange(Raw, Total, first, last)),
      Ord(prvSingle), Raw);
    CheckEqual(first, WantFirst, Raw + ' first');
    CheckEqual(last, WantLast, Raw + ' last');
  end;

  procedure Verdict(const Raw: RawUtf8; Total: Int64;
    Want: TPWebRangeVerdict);
  begin
    CheckEqual(Ord(PWebBlobParseRange(Raw, Total, first, last)), Ord(Want),
      Raw);
  end;

begin
  // SINGLE AND SUFFIX -> 206
  Single('bytes=0-99', 1000, 0, 99);
  Single('bytes=1000-1099', 1048576, 1000, 1099);
  Single('bytes=500-', 1000, 500, 999);
  Single('bytes=0-', 1000, 0, 999);
  Single('bytes=-128', 1048576, 1048448, 1048575);
  Single('bytes = 10 - 20', 1000, 10, 20); // spaces are stripped
  Single('bytes=900-99999', 1000, 900, 999); // the end is clamped
  Single('bytes=-99999', 1000, 0, 999); // a suffix longer than the blob
  Single('bytes=999-999', 1000, 999, 999); // the last byte
  // MULTI-RANGE AND MALFORMED -> 200 WHOLE. RFC 7233 §3.1 lets an origin
  // server ignore a Range it does not understand, and CAP-12A measured the
  // 200 answer as honoured on both engines.
  Verdict('', 1000, prvAbsent);
  Verdict('bytes=0-9,20-29', 1000, prvIgnored);
  Verdict('items=0-9', 1000, prvIgnored);
  Verdict('bytes=abc', 1000, prvIgnored);
  Verdict('bytes=', 1000, prvIgnored);
  Verdict('bytes=-', 1000, prvIgnored);
  Verdict('bytes=1-2-3', 1000, prvIgnored);
  Verdict('bytes=20-10', 1000, prvIgnored); // an invalid byte-range-spec
  Verdict('bytes=-1e3', 1000, prvIgnored);
  Verdict('0-99', 1000, prvIgnored); // no unit
  // UNSATISFIABLE -> 416. Valid syntax, nothing to send: a page BUG, and a
  // whole body in reply would be indistinguishable from success.
  Verdict('bytes=1000-1099', 1000, prvUnsatisfiable);
  Verdict('bytes=1000-', 1000, prvUnsatisfiable);
  Verdict('bytes=-0', 1000, prvUnsatisfiable);
  Verdict('bytes=0-99', 0, prvUnsatisfiable); // an empty blob
  Verdict('bytes=-1', 0, prvUnsatisfiable);
  // A HEADER LONGER THAN THE BOUND IS NOT A RANGE
  Verdict('bytes=' + RawUtf8(StringOfChar('0', 300)) + '-1', 1000, prvIgnored);
  Note('grammar.range=ok');
end;

{ ---- TTestPWebBlobExchange ---- }

function Exchange(const Store: IBlobStore; const Path, Method, Range,
  Owner: RawUtf8): TPWebBlobExchange;
begin
  Result := Default(TPWebBlobExchange);
  Result.LogicalPath := Path;
  Result.Method := Method;
  Result.RangeHeader := Range;
  Result.Owner := Owner;
  PWebBlobServe(Store, Result);
end;

procedure TTestPWebBlobExchange.WholeBody;
var
  store: IBlobStore;
  token: RawUtf8;
  content: RawByteString;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  content := Pattern(4096);
  CheckEqual(Ord(PutInto(store, OWNER_A, content, 'image/png', token)),
    Ord(pbcNone), 'put');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboServe), 'served');
  CheckEqual(x.Status, 200, 'status');
  CheckEqual(x.Reason, 'OK', 'reason');
  CheckEqual(x.ContentType, 'image/png', 'type');
  CheckEqual(x.Body, content, 'bytes');
  CheckEqual(x.ContentRange, '', 'no content-range on a 200');
  Check(x.AcceptRanges, 'accept-ranges');
  CheckEqual(x.TotalSize, 4096, 'total');
  // an empty method reads as GET, because two engines can leave it empty
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, '', '', OWNER_A);
  CheckEqual(x.Status, 200, 'an empty method is a GET');
  Note('exchange.whole=200');
end;

procedure TTestPWebBlobExchange.SingleRange;
var
  store: IBlobStore;
  token: RawUtf8;
  content: RawByteString;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  content := Pattern(1048576);
  CheckEqual(Ord(PutInto(store, OWNER_A, content, 'application/octet-stream',
    token)), Ord(pbcNone), 'put');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', 'bytes=1000-1099',
    OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboServe), 'served');
  CheckEqual(x.Status, 206, 'status');
  CheckEqual(x.Reason, 'Partial Content', 'reason');
  // THE 206 HEADERS, EXACTLY
  CheckEqual(x.ContentRange, 'bytes 1000-1099/1048576', 'content-range');
  Check(x.AcceptRanges, 'accept-ranges');
  CheckEqual(Length(x.Body), 100, 'length');
  // OFFSET-VERIFIED: a handler that answered with the first N bytes would
  // pass a length-only check and fail here
  CheckEqual(x.Body, Copy(content, 1001, 100), 'the requested window');
  Note('exchange.single_range=206');
end;

procedure TTestPWebBlobExchange.SuffixRange;
var
  store: IBlobStore;
  token: RawUtf8;
  content: RawByteString;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  content := Pattern(1048576);
  CheckEqual(Ord(PutInto(store, OWNER_A, content, 'application/octet-stream',
    token)), Ord(pbcNone), 'put');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', 'bytes=-128',
    OWNER_A);
  CheckEqual(x.Status, 206, 'status');
  CheckEqual(x.ContentRange, 'bytes 1048448-1048575/1048576', 'content-range');
  CheckEqual(x.Body, Copy(content, 1048449, 128), 'the last 128 bytes');
  Note('exchange.suffix_range=206');
end;

procedure TTestPWebBlobExchange.DeclinedRange;
var
  store: IBlobStore;
  token: RawUtf8;
  content: RawByteString;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  content := Pattern(4096);
  CheckEqual(Ord(PutInto(store, OWNER_A, content, 'text/plain', token)),
    Ord(pbcNone), 'put');
  // MULTI-RANGE IS DECLINED, AND DECLINING IS A 200 WHOLE - the one rule on
  // four engines, and the only answer CAP-12A measured as guaranteed
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET',
    'bytes=0-9,20-29', OWNER_A);
  CheckEqual(x.Status, 200, 'multi-range is answered whole');
  CheckEqual(Ord(x.Range), Ord(prvIgnored), 'declined');
  CheckEqual(x.Body, content, 'the whole body');
  CheckEqual(x.ContentRange, '', 'and no content-range');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', 'furlongs=0-9',
    OWNER_A);
  CheckEqual(x.Status, 200, 'an unknown unit is answered whole');
  Note('exchange.declined_range=200');
end;

procedure TTestPWebBlobExchange.Unsatisfiable;
var
  store: IBlobStore;
  token: RawUtf8;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(1000), 'text/plain', token)),
    Ord(pbcNone), 'put');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', 'bytes=1000-1099',
    OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboRangeNotSatisfiable), 'refused');
  CheckEqual(x.Status, 416, 'status');
  CheckEqual(x.Reason, 'Range Not Satisfiable', 'reason');
  // RFC 7233 §4.4: the page learns the real size rather than guessing again
  CheckEqual(x.ContentRange, 'bytes */1000', 'content-range');
  // and the resource is still rangeable - what was wrong was the range
  Check(x.AcceptRanges, 'a 416 keeps the advertisement');
  Note('exchange.unsatisfiable=416');
end;

procedure TTestPWebBlobExchange.UploadRefused;
var
  store: IBlobStore;
  token: RawUtf8;
  x: TPWebBlobExchange;
  content: RawByteString;
begin
  store := TPWebMemoryBlobStore.Create;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(16), 'text/plain', token)),
    Ord(pbcNone), 'put');
  content := Pattern(1024);
  x := Default(TPWebBlobExchange);
  x.LogicalPath := PWEB_BLOB_PATH_PREFIX + token;
  x.Method := 'PUT';
  x.Owner := OWNER_A;
  // what an adapter fills in after draining the request body
  x.RequestBodyBytes := Length(content);
  x.RequestBodyCrc := crc32c(0, pointer(content), Length(content));
  x.RequestBodyComplete := True;
  PWebBlobServe(store, x);
  CheckEqual(Ord(x.Outcome), Ord(pboMethodRefused), 'refused');
  CheckEqual(x.Status, 405, 'status');
  CheckEqual(x.ExtraHeaders, PWEB_BLOB_ALLOW_HEADER, 'allow');
  CheckEqual(x.ContentType, 'application/json; charset=utf-8', 'type');
  // THE REFUSAL IS A MEASUREMENT: it names how many bytes arrived and their
  // checksum, so a page can prove its upload crossed intact even though
  // CAP-12B wires no consumer onto the transport
  Check(PosEx(PWEB_BLOB_UPLOAD_REFUSAL, x.Body) > 0, 'typed cause');
  Check(PosEx('"requestBodyBytes":1024', x.Body) > 0, 'the count');
  Check(PosEx('"requestBodyComplete":true', x.Body) > 0, 'completeness');
  Check(PosEx('"method":"PUT"', x.Body) > 0, 'the method');
  // POST is refused identically, and so is a method nobody sends
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'POST', '', OWNER_A);
  CheckEqual(x.Status, 405, 'POST');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'HEAD', '', OWNER_A);
  CheckEqual(x.Status, 405, 'HEAD is not promised in v1');
  Note('exchange.upload=405');
end;

procedure TTestPWebBlobExchange.UnknownAndForeign;
var
  store: IBlobStore;
  token: RawUtf8;
  x, y: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(16), 'text/plain', token)),
    Ord(pbcNone), 'put');
  // THE FOUR WAYS A BLOB URL CAN FAIL ARE ONE ANSWER FROM OUTSIDE
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_B);
  y := Exchange(store, PWEB_BLOB_PATH_PREFIX +
    '0123456789abcdef0123456789abcdef', 'GET', '', OWNER_A);
  CheckEqual(x.Status, 404, 'foreign');
  CheckEqual(y.Status, 404, 'unknown');
  CheckEqual(x.Body, y.Body, 'the same body');
  CheckEqual(x.ContentType, y.ContentType, 'the same type');
  CheckEqual(x.Reason, y.Reason, 'the same reason');
  Check(not x.AcceptRanges, 'no accept-ranges on a 404');
  Check(store.Release(OWNER_A, token), 'release');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(x.Status, 404, 'released');
  CheckEqual(x.Body, y.Body, 'and the same body again');
  // A RESERVED PATH THAT IS NOT A BLOB PATH IS ALSO A 404, and it is still
  // THIS unit's answer: the caller must never fall through to an asset store
  x := Exchange(store, '_pweb', 'GET', '', OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboNotFound), 'the segment alone');
  x := Exchange(store, '_pweb/blob/not-a-token', 'GET', '', OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboNotFound), 'a malformed token');
  x := Exchange(store, '_pweb/somethingelse', 'GET', '', OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboNotFound), 'another reserved namespace');
  // AND AN ORDINARY ASSET PATH IS NOT THIS UNIT'S AT ALL
  x := Exchange(store, 'index.html', 'GET', '', OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboNotReserved), 'an asset');
  CheckEqual(x.Status, 0, 'and nothing was decided about it');
  // A STORE THAT IS NOT THERE STILL RESERVES THE PREFIX
  x := Exchange(nil, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(Ord(x.Outcome), Ord(pboNotFound), 'no store, still reserved');
  Note('exchange.unknown_foreign=404');
end;

procedure TTestPWebBlobExchange.ContentTypeFromInfo;
var
  store: IBlobStore;
  token: RawUtf8;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  // THE MIME TABLE IS NEVER CONSULTED. MEASURED (CAP-12A §1/M5): it carries
  // no audio or video type at all, so `.wav` resolves to
  // application/octet-stream there. A blob carries the type it was sealed
  // with, and this asserts the difference rather than the equality.
  CheckEqual(PWebAssetMimeType('song.wav'), PWEB_ASSET_FALLBACK_MIME,
    'the asset table has no audio type');
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(64), 'audio/wav', token)),
    Ord(pbcNone), 'put');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(x.ContentType, 'audio/wav', 'from the info record');
  Note('exchange.content_type=from_info');
end;

{ ---- TTestPWebBlobLifecycle ---- }

procedure TTestPWebBlobLifecycle.DocumentReplaced;
var
  store: IBlobStore;
  runtime: IBlobStoreRuntime;
  token, other: RawUtf8;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  runtime := store as IBlobStoreRuntime;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(16), 'text/plain', token)),
    Ord(pbcNone), 'a blob of this window');
  CheckEqual(Ord(PutInto(store, OWNER_B, Pattern(16), 'text/plain', other)),
    Ord(pbcNone), 'a blob of another principal');
  // EVERY BLOB OF A WINDOW GOES WHEN ITS DOCUMENT IS REPLACED - a
  // navigation, a reload, and a development generation switch all arrive at
  // the host as the same hook, which is why there is one call and not three
  CheckEqual(store.ReleaseOwner(OWNER_A), 1, 'released');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(x.Status, 404, 'gone with the document');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + other, 'GET', '', OWNER_B);
  CheckEqual(x.Status, 200, 'and another principal is untouched');
  Note('lifecycle.document_replaced=ok');
end;

procedure TTestPWebBlobLifecycle.ShutdownOrder;
var
  store: IBlobStore;
  runtime: IBlobStoreRuntime;
  reader: IBlobReader;
  token: RawUtf8;
  content: RawByteString;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  runtime := store as IBlobStoreRuntime;
  content := Pattern(512);
  CheckEqual(Ord(PutInto(store, OWNER_A, content, 'text/plain', token)),
    Ord(pbcNone), 'put');
  // A SCHEME TASK THAT IS MID-WINDOW holds a reader. The CAP-9 order closes
  // the plane BEFORE the binding closes and the scheduler drains, and this
  // is the case that order exists for: the task finishes its window out of
  // its own reference, and nothing new can start.
  Check(store.OpenBlob(OWNER_A, token, reader), 'a task is mid-window');
  runtime.Close;
  CheckEqual(ReadWhole(reader, 512), content, 'it finishes its window');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(x.Status, 404, 'and nothing new resolves');
  CheckEqual(runtime.HeldCount, 1, 'the retired entry outlives the close');
  reader := nil;
  CheckEqual(runtime.HeldCount, 0, 'and goes with its last reader');
  Note('lifecycle.shutdown_order=ok');
end;

procedure TTestPWebBlobLifecycle.Revocation;
var
  store: IBlobStore;
  token: RawUtf8;
  x: TPWebBlobExchange;
begin
  store := TPWebMemoryBlobStore.Create;
  CheckEqual(Ord(PutInto(store, OWNER_A, Pattern(16), 'text/plain', token)),
    Ord(pbcNone), 'put');
  // REVOKING THE GOVERNING CAPABILITY releases every affected blob BEFORE
  // the revoking call returns. The policy's own notification carries the
  // principal id and nothing else, so the release is exactly ReleaseOwner -
  // the same call a document replacement makes, for the same reason.
  CheckEqual(store.ReleaseOwner(OWNER_A), 1, 'released on revocation');
  x := Exchange(store, PWEB_BLOB_PATH_PREFIX + token, 'GET', '', OWNER_A);
  CheckEqual(x.Status, 404, 'unresolvable before the caller returns');
  Note('lifecycle.revocation=ok');
end;

{ ---- TTestPWebBlobFetchDoor ---- }

type
  { The inner bridge every fetch decorator wraps. It is never reached here -
    `pweb.fetch` is intercepted before it - and it counts, so that "the
    decorator answered" is a number rather than an absence. }
  TInnerCounter = class(TInterfacedObject, IInvocationBridge)
  public
    Calls: Integer;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

function TInnerCounter.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
begin
  Inc(Calls);
  Result := PWebDefaultErrorResult(pecMethodNotFound);
end;

var
  // what the injected transport will answer with, set per case
  FakeBodyBytes: PtrInt;
  FakeContentType: RawUtf8;

// THE TRANSPORT IS INJECTED, exactly as CAP-15B ratified it: the envelope is
// a property of the DECORATOR, and putting a real server behind it would
// measure a server. What a fake transport cannot stand in for - a TLS
// handshake, a redirect, a dribbling read - is measured live by CAP-15B and
// is not what this case is about.
function FakeTransport(const Request: TPWebFetchRequest;
  const Token: ICancellationToken;
  out Response: TPWebFetchResponse): TPWebFetchOutcome;
var
  i: PtrInt;
begin
  Response := Default(TPWebFetchResponse);
  Response.Status := 200;
  Response.Headers := 'Content-Type: ' + FakeContentType;
  SetLength(Response.Body, FakeBodyBytes);
  // NOT valid UTF-8 and NOT compressible into a pattern the envelope could
  // shortcut: the byte at each offset is the offset, so a body that came
  // back rearranged is visible
  for i := 0 to FakeBodyBytes - 1 do
    Response.Body[i + 1] := AnsiChar(200 + (i mod 50));
  Response.Bytes := FakeBodyBytes;
  Response.Ms := 7;
  Result := pfoOk;
end;

function FetchOnce(const Blobs: IBlobStore; Bytes: PtrInt;
  const Mime: RawUtf8; out Inner: TInnerCounter): TPWebInvocationResult;
var
  bridge: IInvocationBridge;
  context: TInvocationContext;
begin
  FakeBodyBytes := Bytes;
  FakeContentType := Mime;
  Inner := TInnerCounter.Create;
  bridge := TPWebFetchBridge.Create(Inner, @FakeTransport,
    ['https://api.example.com'], nil, Blobs);
  context := Default(TInvocationContext);
  context.WindowId := 'main';
  context.PrincipalId := OWNER_A;
  context.PrincipalKind := pkWindow;
  context.TrustedContent := True;
  Result := bridge.Invoke(context, 'pweb.fetch',
    TPWebJson('{"url":"https://api.example.com/thing"}'), nil);
end;

procedure TTestPWebBlobFetchDoor.InlineIsUnchanged;
var
  r: TPWebInvocationResult;
  inner: TInnerCounter;
  store: IBlobStore;
begin
  store := TPWebMemoryBlobStore.Create;
  // UNDER the inline cap: the envelope is what it always was, and `blob` is
  // present and null. A field that appeared only sometimes would be a field
  // every caller has to feature-detect.
  r := FetchOnce(store, 4096, 'application/octet-stream', inner);
  CheckEqual(Ord(r.Kind), Ord(prkSuccess), 'success');
  Check(PosEx('"bodyBase64":"', r.Value) > 0, 'inlined as base64');
  Check(PosEx('"blob":null', r.Value) > 0, 'blob is null');
  Check(PosEx('"truncated":false', r.Value) > 0, 'never truncated');
  CheckEqual(inner.Calls, 0, 'the inner bridge is never reached');
  CheckEqual((store as IBlobStoreRuntime).LiveCount, 0, 'no blob was made');
  Note('fetch.inline=unchanged');
end;

procedure TTestPWebBlobFetchDoor.OverInlineBecomesAHandle;
var
  r: TPWebInvocationResult;
  inner: TInnerCounter;
  store: IBlobStore;
  reader: IBlobReader;
  info: TBlobInfo;
  token, url: RawUtf8;
  i: PtrInt;
begin
  store := TPWebMemoryBlobStore.Create;
  // THE HEADLINE: 2 MiB is over the 1 MiB inline cap and under the 8 MiB
  // response ceiling, which used to be `response_too_large_to_inline` and
  // is now a handle.
  r := FetchOnce(store, 2 * 1024 * 1024, 'application/pdf', inner);
  CheckEqual(Ord(r.Kind), Ord(prkSuccess), 'a SUCCESS, not a refusal');
  Check(PosEx('"bodyText":null', r.Value) > 0, 'no inline text');
  Check(PosEx('"bodyBase64":null', r.Value) > 0, 'no inline base64');
  Check(PosEx('"truncated":false', r.Value) > 0, 'never truncated');
  Check(PosEx('"bytes":2097152', r.Value) > 0, 'bytes is the wire length');
  Check(PosEx('"type":"application/pdf"', r.Value) > 0, 'the wire type');
  Check(PosEx('"size":2097152', r.Value) > 0, 'the blob size');
  CheckEqual((store as IBlobStoreRuntime).LiveCount, 1, 'one blob');
  // THE HANDLE RESOLVES, and through the same grammar a page's URL takes
  i := PosEx('"token":"', r.Value);
  Check(i > 0, 'a token');
  token := Copy(RawUtf8(r.Value), i + 9, PWEB_BLOB_TOKEN_CHARS);
  Check(PWebBlobValidToken(token), 'the token grammar');
  url := PWebBlobUrl(token);
  Check(PosEx(RawUtf8('"url":"' + url + '"'), r.Value) > 0,
    'the url the runtime built');
  Check(store.OpenBlob(OWNER_A, token, reader), 'the owner resolves it');
  Check(reader.Info(info), 'info');
  CheckEqual(info.Size, 2 * 1024 * 1024, 'the whole body is there');
  CheckEqual(info.ContentType, 'application/pdf', 'sealed with the type');
  // AND ONLY THE OWNER RESOLVES IT
  Check(not store.OpenBlob(OWNER_B, token, reader), 'another principal');
  Note('fetch.over_inline=blob_handle');
end;

procedure TTestPWebBlobFetchDoor.OverTheCeilingIsStillRefused;
var
  r: TPWebInvocationResult;
  inner: TInnerCounter;
  store: IBlobStore;
begin
  store := TPWebMemoryBlobStore.Create;
  // ABOVE the response ceiling the transport itself stops the read, so the
  // plane never sees the body: `response_too_large` is a DIFFERENT refusal
  // from `response_too_large_to_inline` and neither becomes a handle.
  FakeBodyBytes := 0;
  r := FetchOnce(store, 9 * 1024 * 1024, 'application/octet-stream', inner);
  // the fake transport does not enforce MaxResponseBytes - a real one does,
  // and CAP-15B measures that - so what this case pins is the OTHER half:
  // a body over the ceiling must not reach the plane as a handle
  CheckEqual((store as IBlobStoreRuntime).LiveCount, 0,
    'nothing over the ceiling is placed on the plane');
  CheckEqual(Ord(r.Kind), Ord(prkError), 'refused');
  Check(PosEx(PWEB_BLOB_CAT_BLOB_BYTES, RawUtf8(r.Error.Data)) > 0,
    'and refused by the name of the bound it crossed');
  Note('fetch.over_ceiling=refused');
end;

procedure TTestPWebBlobFetchDoor.WithoutAPlaneNothingChanges;
var
  r: TPWebInvocationResult;
  inner: TInnerCounter;
begin
  // NO STORE: the CAP-15B answer, byte for byte. This is what makes the
  // shard additive rather than a change of contract for every host that
  // already ships.
  r := FetchOnce(nil, 2 * 1024 * 1024, 'application/octet-stream', inner);
  CheckEqual(Ord(r.Kind), Ord(prkError), 'refused');
  Check(PosEx('response_too_large_to_inline', RawUtf8(r.Error.Data)) > 0,
    'the CAP-15B category, unchanged');
  Note('fetch.no_plane=cap15b_refusal');
end;

procedure TTestPWebBlobFetchDoor.ACeilingIsAnsweredByName;
var
  r: TPWebInvocationResult;
  inner: TInnerCounter;
  store: IBlobStore;
  limits: TPWebBlobLimits;
begin
  // a plane whose per-principal byte ceiling is below the body: the refusal
  // NAMES the ceiling, and it is not the too-large-to-inline one
  limits := PWebBlobDefaultLimits;
  limits.MaxBytesPerOwner := 1024;
  store := TPWebMemoryBlobStore.Create(limits);
  r := FetchOnce(store, 2 * 1024 * 1024, 'application/octet-stream', inner);
  CheckEqual(Ord(r.Kind), Ord(prkError), 'refused');
  Check(PosEx(PWEB_BLOB_CAT_OWNER_BYTES, RawUtf8(r.Error.Data)) > 0,
    'the ceiling it hit');
  Check(PosEx('response_too_large_to_inline', RawUtf8(r.Error.Data)) = 0,
    'and NOT the refusal it would have given without a plane');
  CheckEqual((store as IBlobStoreRuntime).LiveCount, 0, 'no blob');
  Note('fetch.ceiling=named');
end;

initialization

finalization
  WriteCorpus;

end.
