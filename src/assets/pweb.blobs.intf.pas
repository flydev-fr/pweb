{
  pweb.blobs.intf - the blob data plane's contract (CAP-12A §5.1, ratified).

  THE PHASE-4b ENTRY RATIFICATION, implemented verbatim. phase-plan.md
  required the concrete method sets of IBlobStore / IBlobReader /
  IBlobWriter to be ratified "against the invariants fixed in
  core-interfaces.md ... BEFORE any blob implementation"; CAP-12A §5.1
  is that ratification and this unit is its transcription. The three
  interfaces below carry exactly the methods that document names, in
  that order, with those parameter names.

  IT IS AN ADDITIVE SECOND BOUNDARY, not a change to any of the seven
  (CAP-12A §3). IAssetStore.TryRead and TAssetResponse are untouched:
  everything the ranged plane needs is reachable through this interface
  plus a branch in each platform handler that runs BEFORE the asset
  store is consulted.

  WHAT MAY NOT APPEAR HERE, and the rule is the SPEC's own:
  "`IBlobStore` is decoupled from the URI scheme ... forbidden from
  naming URI schemes, WebView transports, filesystem paths or platform
  stream types". So there is no `pweb`, no `_pweb`, no `Range`, no
  `IStream`/`GInputStream`/`NSData`, and no TFileName in this file. The
  translator - pweb.blobs.protocol - is the ONE unit that knows both
  the store's spelling and the URL's, and nothing else in the tree does.

  Layering: mormot.core.base only, mirroring pweb.assets.intf. The
  RawUtf8/RawByteString aliases are the same ratified exception
  IAssetStore already carries on record.

  Three properties of the shape below are MEASURED rather than chosen
  (CAP-12A §1, §5.1):

    - `Info` before any bytes. Both measured engines need a total for
      `Content-Range` and a length for `Content-Length`; the frozen
      TryRead cannot give one without materialising, and materialising
      a 256 MiB body was measured at 512 MiB held on BOTH engines.

    - `ReadAt` into a CALLER-OWNED buffer, never a returned string.
      That 512 MiB figure is the seam's own doubling - the Pascal
      string, and then the engine's copy - and a returned
      RawByteString would reproduce it for every window.

    - no stream type anywhere. The three engines want three different
      ones, and a ranged plane never has to name any of them.
}
unit pweb.blobs.intf;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base;

type
  { What a reader can say about a blob WITHOUT materialising it.

    The `Size` field is the whole reason this record exists: a 206
    cannot be written without a total, and the frozen
    IAssetStore.TryRead has no way to report one.

    Evolution rule, the same one TAssetResponse carries: this record
    may grow ADDITIVELY at source level. PWeb v1 promises source-level
    API compatibility only - adding a field is not claimed to preserve
    binary ABI between separately compiled framework versions. }
  TBlobInfo = record
    /// the blob's whole length in bytes; 0 is a legitimate blob
    Size: Int64;
    /// served verbatim as Content-Type - NEVER derived from a path
    // - MEASURED (CAP-12A §1/M5): the frozen MIME table carries no audio
    // or video type at all, so a blob whose type came from a path
    // extension could not name its own content. The blob plane carries
    // the type it was sealed with and the asset plane's table is not
    // extended by this shard
    ContentType: RawUtf8;
    /// the principal id that created it
    Owner: RawUtf8;
    /// no further Append is accepted
    // - a blob is readable only once sealed, which is what makes a
    // reader's view of the bytes immutable and therefore lock-free
    Sealed: Boolean;
  end;

  { A read view of ONE sealed blob, held by ONE consumer.

    LIFETIME (CAP-12A §5.2): holding this interface keeps the BYTES
    alive even after the token has been released. Release makes the
    token unresolvable at once; the bytes go when the last reader does.
    That is what makes a scheme task that is mid-window unable to read
    freed memory. }
  IBlobReader = interface
    ['{980CE87F-BAE6-452A-8F25-470B47DB5EF1}']
    /// the blob's facts, without touching its bytes
    function Info(out Blob: TBlobInfo): Boolean;
    { POSITIONED READ - the frozen invariant, and now also the measured
      requirement: the guaranteed surface is ranged, so a window read
      into a caller-owned buffer is the ONLY read the plane needs.
      Returns the byte count, 0 at or past the end, -1 on failure.
      Never raises. }
    function ReadAt(Offset: Int64; Buffer: Pointer; Count: Integer): Integer;
  end;

  { A write view of ONE unsealed blob.

    A writer is exclusive: CreateBlob hands out exactly one, and the
    blob is unreadable until Seal succeeds. Abandon is idempotent and
    is what a failed producer owes the store. }
  IBlobWriter = interface
    ['{6D9E6F63-E169-4A0B-A783-BC6A96A58152}']
    /// append Count bytes; False when a bound refuses them
    function Append(Buffer: Pointer; Count: Integer): Boolean;
    /// close the blob for writing and mint its token
    // - the token is 32 lowercase hex characters, i.e. exactly the
    // 128 bits of handle entropy the frozen invariant requires
    function Seal(const ContentType: RawUtf8; out Token: RawUtf8): Boolean;
    /// give up: the blob never existed and nothing is charged for it
    procedure Abandon;
  end;

  { Ownership, lookup and lifetime of bulk binary payloads by opaque
    handle (CAP-12A §5.1).

    OWNER-SCOPED BY CONSTRUCTION, not by a check the caller may forget:
    OpenBlob takes the owner, and a foreign principal's token is
    answered EXACTLY as an unknown token is - the CAP-8C multi-principal
    rule, and the same shape CAP-15C gives a foreign socket id.

    Thread affinity: none required by contract. Implementations must
    tolerate concurrent calls from resource-handler threads, because on
    one measured engine the handler runs on the host's GUI thread and on
    another it does not. }
  IBlobStore = interface
    ['{73D3BB0D-58E7-4639-8F23-FF38AB2549F2}']
    /// begin a blob for Owner, optionally reserving SizeHint bytes
    // - SizeHint > 0 RESERVES: every ceiling is decided once, here,
    // inside one lock, and the writer may not exceed the reservation.
    // SizeHint = 0 grows, and each Append is checked instead
    function CreateBlob(const Owner: RawUtf8; SizeHint: Int64;
      out Writer: IBlobWriter): Boolean;
    /// resolve a token for Owner; False for unknown AND for foreign
    function OpenBlob(const Owner: RawUtf8; const Token: RawUtf8;
      out Reader: IBlobReader): Boolean;
    /// make the token unresolvable at once; the bytes go with the last
    /// reader
    function Release(const Owner: RawUtf8; const Token: RawUtf8): Boolean;
    /// release every blob of one principal; returns how many
    function ReleaseOwner(const Owner: RawUtf8): Integer;
    /// what the store is holding right now
    // - Count is every entry the store still holds, and Bytes is every
    // byte it is still charged for, RETIRED-BUT-REFERENCED ones
    // included: these are the two numbers the ceilings are computed
    // from, and a Stats that disagreed with the ceiling arithmetic
    // would be a trap rather than a diagnostic
    function Stats(out Count: Integer; out Bytes: Int64): Boolean;
  end;

type
  /// which bound a store refusal hit - a CATEGORY, never native text
  // - CAP-12A §5.2 fixes the shape: "a ceiling on count, a ceiling on
  // bytes, both per principal and in total, and a refusal that names
  // which ceiling it hit"
  TPWebBlobCeiling = (
    /// no bound was hit
    pbcNone,
    /// this principal already holds the most blobs it may
    pbcOwnerCount,
    /// this principal already holds the most bytes it may
    pbcOwnerBytes,
    /// the store as a whole holds the most blobs it may
    pbcTotalCount,
    /// the store as a whole holds the most bytes it may
    pbcTotalBytes,
    /// one blob may not be this large
    pbcBlobBytes,
    /// the owner id is empty or over its bound
    pbcInvalidOwner,
    /// the store is shutting down and accepts no new blob
    pbcClosed);

  /// the ceilings one store enforces
  // - a RECORD rather than constants so a test can build a store with
  // ceilings small enough to prove every refusal fires, which is the
  // only way a ceiling is ever known to work
  TPWebBlobLimits = record
    /// largest single blob, in bytes
    MaxBlobBytes: Int64;
    /// most blobs one principal may hold at once
    MaxCountPerOwner: Integer;
    /// most bytes one principal may hold at once
    MaxBytesPerOwner: Int64;
    /// most blobs the store may hold at once
    MaxCountTotal: Integer;
    /// most bytes the store may hold at once
    MaxBytesTotal: Int64;
  end;

  { The one thing a PRODUCER needs that IBlobStore deliberately does not
    carry: WHICH ceiling a refusal hit.

    It is a SUPPORTING interface of the IBlobStore boundary, in exactly
    the sense pweb.rpc.intf's header already fixes for ICancellationToken
    and IInvocationSource - "supporting interfaces belong to those
    boundaries; they do not create new top-level boundaries". IBlobStore's
    ratified method set is untouched.

    IT IS ONE CALL, not a query followed by a create, because the answer
    has to come from inside the same lock that refused. A producer that
    asked "would you refuse?" and then created would be reporting a
    number that had already moved. }
  IBlobBounds = interface
    ['{8822A767-B846-427C-BDA7-DE725DBE88D7}']
    /// CreateBlob, with the ceiling it hit reported instead of discarded
    function CreateBlobTyped(const Owner: RawUtf8; SizeHint: Int64;
      out Writer: IBlobWriter; out Ceiling: TPWebBlobCeiling): Boolean;
    /// the ceilings this store enforces
    function Limits: TPWebBlobLimits;
    /// what ONE principal is currently charged for
    function OwnerStats(const Owner: RawUtf8;
      out Count: Integer; out Bytes: Int64): Boolean;
  end;

  { The rest of what the RUNTIME needs and a consumer never does: the
    end of the plane, and the two counts a gate reads.

    It is the same supporting boundary as IBlobBounds and lives here
    rather than beside a concrete store so that the HOST - which owns
    the shutdown ORDER and nothing else about blobs - depends on the
    contract and not on an implementation. }
  IBlobStoreRuntime = interface(IBlobBounds)
    ['{2C1F3A54-7B90-4E6D-9F02-5A8D1C4B6E73}']
    { Release every blob of every principal and refuse every new one.

      THE CAP-9 ORDER, and the host owes it in this sequence: this runs
      BEFORE the binding closes and the scheduler drains, and the
      platform handler is DETACHED before the store REFERENCE is
      dropped - so no scheme task can start after the plane has gone,
      and one that is mid-window is holding its own bytes and cannot
      read freed memory. Idempotent. }
    procedure Close;
    /// False once Close has run
    function IsOpen: Boolean;
    /// how many blobs are still RESOLVABLE (retired ones excluded)
    function LiveCount: Integer;
    /// how many entries the store still holds, retired ones INCLUDED
    function HeldCount: Integer;
  end;

const
  /// a token is exactly 32 lowercase hex characters
  // - the frozen invariant is ">= 128-bit handle entropy"; 32 hex digits
  // is exactly 128 bits, is fixed length, is one path segment, and
  // survives every canonical-path rule without an escape
  PWEB_BLOB_TOKEN_CHARS = 32;

  /// longest principal id the store will charge
  // - an owner id is a runtime-issued principal, never page input; the
  // bound exists so that a store's per-owner bookkeeping cannot be
  // grown by one
  PWEB_BLOB_MAX_OWNER_BYTES = 128;

  /// longest Content-Type a blob may be sealed with
  // - a type that does not fit is a REFUSAL, never a truncation: a
  // truncated Content-Type is a different Content-Type and the engine
  // would sniff around it. The number is the macOS seam's own
  // PWEB_COCOA_CONTENT_TYPE_MAX, so a blob that seals here can always
  // be served on every target
  PWEB_BLOB_MAX_CONTENT_TYPE_BYTES = 255;

  /// the type a blob gets when its producer could not name one
  // - `application/octet-stream` is a REFUSAL TO GUESS, not a default: the
  // asset plane's MIME table is never consulted for a blob, and a body
  // whose own source said nothing about its type is a body the page has to
  // interpret rather than one an engine may sniff around
  PWEB_BLOB_FALLBACK_TYPE = 'application/octet-stream';

  /// the typed service_error categories the plane answers a ceiling with
  // - `service_error.data` is the only sanctioned application-defined
  // domain-error channel; the nine-code taxonomy is unchanged
  PWEB_BLOB_CAT_OWNER_COUNT = 'blob_owner_count_exceeded';
  PWEB_BLOB_CAT_OWNER_BYTES = 'blob_owner_bytes_exceeded';
  PWEB_BLOB_CAT_TOTAL_COUNT = 'blob_total_count_exceeded';
  PWEB_BLOB_CAT_TOTAL_BYTES = 'blob_total_bytes_exceeded';
  PWEB_BLOB_CAT_BLOB_BYTES  = 'blob_size_exceeded';
  PWEB_BLOB_CAT_UNAVAILABLE = 'blob_store_unavailable';

/// the typed category for one ceiling, or '' for pbcNone
// - one mapping, in the unit that owns the vocabulary, so a bridge
// answering a refusal cannot invent a category of its own
function PWebBlobCeilingCategory(ACeiling: TPWebBlobCeiling): RawUtf8;

/// is this a well-formed blob token: exactly 32 lowercase hex bytes
// - the grammar lives HERE rather than in the translator because the
// store has to refuse a malformed token too, and one grammar is one
// answer
function PWebBlobValidToken(const Token: RawUtf8): Boolean;

/// the ratified v1 ceilings, with their arithmetic in the implementation
function PWebBlobDefaultLimits: TPWebBlobLimits;

implementation

function PWebBlobCeilingCategory(ACeiling: TPWebBlobCeiling): RawUtf8;
begin
  case ACeiling of
    pbcOwnerCount:
      Result := PWEB_BLOB_CAT_OWNER_COUNT;
    pbcOwnerBytes:
      Result := PWEB_BLOB_CAT_OWNER_BYTES;
    pbcTotalCount:
      Result := PWEB_BLOB_CAT_TOTAL_COUNT;
    pbcTotalBytes:
      Result := PWEB_BLOB_CAT_TOTAL_BYTES;
    pbcBlobBytes:
      Result := PWEB_BLOB_CAT_BLOB_BYTES;
    pbcInvalidOwner, pbcClosed:
      Result := PWEB_BLOB_CAT_UNAVAILABLE;
  else
    Result := '';
  end;
end;

function PWebBlobValidToken(const Token: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if Length(Token) <> PWEB_BLOB_TOKEN_CHARS then
    exit;
  // LOWERCASE ONLY, and that is a rule rather than a courtesy: two
  // spellings of one token would be two cache keys to an engine and two
  // rows to a store
  for i := 1 to PWEB_BLOB_TOKEN_CHARS do
    if not (Token[i] in ['0'..'9', 'a'..'f']) then
      exit;
  Result := True;
end;

function PWebBlobDefaultLimits: TPWebBlobLimits;
begin
  { THE ARITHMETIC, and every number below is derived from something
    CAP-12A MEASURED rather than chosen for roundness.

    MaxBlobBytes = 8 MiB. CAP-12A §5.3 bounds the window a single
    response may carry at 8 MiB, because WebView2 was MEASURED
    delivering response bodies SERIALLY on the host GUI thread: a
    256 MiB whole body took 1 434 ms page-side, so a body's production
    plus drain is a stall for every other pweb://app response, and at
    8 MiB the same rate gives ~45 ms. It is also PWEB_FETCH_MAX_RESPONSE
    - the only producer this shard wires - and §5.3's upload chunk. One
    number, three uses. Making the largest blob EQUAL the window is what
    lets a whole-body request always be answered without ranging; a
    later shard that wants larger blobs raises this together with a
    file-backed store, and the ranged read path it would need is already
    built and already proven here.

    MaxBytesPerOwner = 64 MiB = 8 x MaxBlobBytes. The transient cost of
    serving one window was MEASURED at 2x the window on both engines
    (the handler holds it, the engine takes a copy), so a principal at
    its ceiling with one window in flight is 64 + 16 = 80 MiB - eight
    times the largest body the plane will ever serve, and an order of
    magnitude below the 2 048 MiB a WebView2 process was measured
    absorbing for a single 256 MiB body.

    MaxCountPerOwner = 128 = 16 x the eight largest-possible blobs the
    byte ceiling allows. The byte ceiling is what bounds MEMORY; this
    one bounds BOOKKEEPING, for a principal that creates thousands of
    tiny blobs and would never reach the byte ceiling. For the headline
    consumer the bytes bind first and by a wide margin: pweb.fetch only
    reaches the blob plane above the 1 MiB inline cap, so 64 blobs of
    just over 1 MiB already exhaust the byte ceiling.

    MaxBytesTotal = 256 MiB = 4 x MaxBytesPerOwner. Four principals can
    each reach their own ceiling before the total binds, and the fifth
    is refused by NAME - blob_total_bytes_exceeded - rather than
    starving one principal silently. 256 MiB is also exactly the largest
    single request body M3 measured crossing both engines intact, so the
    whole plane's resident ceiling is one measured body.

    MaxCountTotal = 512 = 4 x MaxCountPerOwner, the same factor. }
  Result.MaxBlobBytes := 8 * 1024 * 1024;
  Result.MaxCountPerOwner := 128;
  Result.MaxBytesPerOwner := Int64(64) * 1024 * 1024;
  Result.MaxCountTotal := 512;
  Result.MaxBytesTotal := Int64(256) * 1024 * 1024;
end;

end.
