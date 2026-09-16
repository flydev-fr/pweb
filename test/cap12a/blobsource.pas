unit blobsource;

{ CAP-12A: the throwaway blob store, and the one clock every row is read on.

  A SPIKE, not product code. Nothing here is linked by a host, shipped in
  an artifact or run by a CI gate. It exists so that the engine handlers
  under test/cap12a/ can be thin: each one translates a native request into
  a TBlobPlan, pulls bytes from here, and records what the engine did.

  THE MEASUREMENT PROBLEM THIS UNIT SOLVES. M1 asks "did the page observe
  chunk 1 before the handler produced chunk 8?". The page's clock is
  performance.now(); the handler's is this process's. Rather than correlate
  two clocks, EVERY page-side observation is reported through a bound
  mark() call that THIS PROCESS timestamps on arrival. A mark can only be
  later than the page event it reports, never earlier, so "mark(m1.chunk1)
  is earlier than the production of chunk 8" is a sound one-clock statement
  and the one the M1 verdict rests on.

  The body bytes are deterministic - byte i is (i mod 251) - so a 206 can
  be checked for OFFSET as well as for length: a handler that answers a
  Range request with the first N bytes instead of the requested window is
  caught by the page rather than believed. }

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  {$ifdef MSWINDOWS}
  windows,
  {$endif MSWINDOWS}
  mormot.core.base,
  mormot.core.os,
  mormot.core.buffers; // Base64ToBin, for the one embedded PNG

type
  /// what the spike id in _pweb/blob/<id> asks the store to produce
  TBlobPlanKind = (
    bpkUnknown,
    /// one whole in-memory body, produced before the response is set
    bpkWhole,
    /// N chunks of M bytes, D milliseconds apart, produced lazily
    bpkStream,
    /// text/event-stream: N events, D milliseconds apart
    bpkSse,
    /// a real, seekable RIFF/WAVE body
    bpkWav,
    /// a real 1x1 PNG, for the "images by URL" consumer
    bpkPng,
    /// a POST/PUT target that reports what body it received
    bpkEcho);

  TBlobPlan = record
    Kind: TBlobPlanKind;
    /// total body bytes (Chunks * ChunkBytes for bpkStream); -1 when the
    /// plan deliberately declares no length
    Total: Int64;
    Chunks: Integer;
    ChunkBytes: Integer;
    /// delay between produced chunks / events, milliseconds
    DelayMs: Integer;
    /// does this plan honour a Range request with a 206?
    Ranged: Boolean;
    ContentType: RawUtf8;
    /// the id as spelled, for the report
    Id: RawUtf8;
  end;

const
  /// the reserved segment the blob plane is measured under. It is a PREFIX
  // of a canonical asset path, not a second authority: see the namespace
  // section of the decision artifact for why.
  CAP12A_BLOB_PREFIX: RawUtf8 = '_pweb/blob/';
  /// the modulus of the deterministic body pattern
  CAP12A_PATTERN_MOD = 251;
  /// per-row ceiling on what the store will ever materialise at once
  CAP12A_MAX_TOTAL = Int64(512) * 1024 * 1024;
  /// 8000 Hz, mono, 8-bit unsigned PCM - the smallest body that is a real,
  // seekable media resource on every engine rather than a synthetic blob
  CAP12A_WAV_RATE = 8000;
  CAP12A_WAV_HEADER = 44;

/// split a canonical logical path into the reserved prefix and its id
// - returns False for every path that is not under CAP12A_BLOB_PREFIX,
// which is exactly the set the ordinary IAssetStore must still answer
function BlobPathId(const LogicalPath: RawUtf8; out Id: RawUtf8): Boolean;

/// decode a spike id into a plan; False means "no such blob"
function ParseBlobPlan(const Id: RawUtf8; out Plan: TBlobPlan): Boolean;

/// the deterministic body byte at absolute offset i
function BlobByte(Offset: Int64): Byte; inline;

/// fill Count bytes of the plan's body starting at absolute Offset
// - for bpkWav the first 44 bytes are the RIFF header and the rest is the
// deterministic sample pattern, so a Range window anywhere in the file is
// produced without materialising the file
procedure FillPlanRange(const Plan: TBlobPlan; Dest: PByte;
  Offset, Count: Int64);

/// build the whole body of a plan as one RawByteString
function BuildWholeBody(const Plan: TBlobPlan): RawByteString;

/// the smallest real PNG: 1x1, 8-bit RGBA, one IDAT. It is a genuine image
// rather than a byte pattern with an image/png label, because "an <img> got
// bytes" and "an <img> decoded an image" are different measurements.
function TinyPngBytes: RawByteString;

/// build one Server-Sent Events frame
function SseFrame(Index: Integer; Micros: Int64): RawUtf8;

/// parse a single-range `bytes=a-b` request header against a known total
// - supports `a-b`, `a-` and `-suffix`; False for multi-range, for a
// syntactically invalid header and for an unsatisfiable window
function ParseSingleRange(const HeaderValue: RawUtf8; Total: Int64;
  out First, Last: Int64): Boolean;

{ ---- the one clock, and the timeline every engine handler writes to ---- }

/// microseconds on this process's monotonic clock, zeroed at TimelineReset
function NowMicros: Int64;

/// reset the timeline and every counter (called once, before the window)
procedure TimelineReset;

/// append one timestamped event; safe from any thread
procedure Mark(const Event: RawUtf8; const Detail: RawUtf8 = '';
  Value: Int64 = 0);

/// the whole timeline as a JSON array, oldest first
function TimelineJson: RawUtf8;

function TimelineCount: Integer;
/// events the fixed-size timeline could not hold. A full timeline is
/// REPORTED as full rather than silently truncated: a dropped production
/// event would turn an "engine buffered the whole body" verdict into an
/// artefact of the instrument.
function TimelineDropped: Integer;

/// the microsecond timestamp of the FIRST event with this exact name, or
/// -1 when it never happened
function FirstMicrosOf(const Event: RawUtf8): Int64;
/// ... and of the LAST one
function LastMicrosOf(const Event: RawUtf8): Int64;
function CountOf(const Event: RawUtf8): Integer;
/// the largest number of events named Open that were outstanding against
/// events named Close at any instant - the concurrency measurement
function MaxOverlap(const OpenEvent, CloseEvent: RawUtf8): Integer;

{ ---- resident set size, sampled rather than asked for once ---- }

/// current resident set size in bytes, or -1 where it cannot be read
function ProcessRssBytes: Int64;

procedure RssSamplerStart(IntervalMs: Integer);
procedure RssSamplerStop;
/// reset the running maximum to the current RSS and return it
function RssMarkBaseline: Int64;
function RssPeakBytes: Int64;
function RssSamples: Integer;

/// JSON string escaping for the report (control bytes, quote, backslash)
function JsonQuote(const Text: RawUtf8): RawUtf8;
/// the two JSON literals, spelled once
function JsonBool(Value: Boolean): RawUtf8;

implementation

function JsonBool(Value: Boolean): RawUtf8;
begin
  if Value then
    Result := 'true'
  else
    Result := 'false';
end;

{ ---- deterministic body ---- }

function BlobByte(Offset: Int64): Byte;
begin
  Result := Byte(Offset mod CAP12A_PATTERN_MOD);
end;

procedure FillBlobRange(Dest: PByte; Offset, Count: Int64);
var
  i: Int64;
  v: Integer;
begin
  if (Dest = nil) or (Count <= 0) then
    exit;
  v := Integer(Offset mod CAP12A_PATTERN_MOD);
  for i := 0 to Count - 1 do
  begin
    Dest[i] := Byte(v);
    Inc(v);
    if v = CAP12A_PATTERN_MOD then
      v := 0;
  end;
end;

// The masks are not decoration: with the constant arguments below FPC folds
// the shifts at compile time and a bare Byte(8000) is a constant range error
// rather than a truncation.
procedure PutLE32(Dest: PByte; Value: LongWord); inline;
begin
  Dest[0] := Byte(Value and $FF);
  Dest[1] := Byte((Value shr 8) and $FF);
  Dest[2] := Byte((Value shr 16) and $FF);
  Dest[3] := Byte((Value shr 24) and $FF);
end;

procedure PutLE16(Dest: PByte; Value: Word); inline;
begin
  Dest[0] := Byte(Value and $FF);
  Dest[1] := Byte((Value shr 8) and $FF);
end;

// The 44-byte canonical RIFF/WAVE header for 8000 Hz mono 8-bit PCM. It is
// built rather than embedded so the data length always agrees with the body
// the plan will actually produce - a WAVE whose header lies about its length
// is exactly the shape that makes a seek measurement unreadable.
procedure BuildWavHeader(out Header: array of Byte; DataBytes: LongWord);
var
  h: PByte;
begin
  h := @Header[0];
  FillChar(h^, CAP12A_WAV_HEADER, 0);
  h[0] := Ord('R'); h[1] := Ord('I'); h[2] := Ord('F'); h[3] := Ord('F');
  PutLE32(@h[4], 36 + DataBytes);
  h[8] := Ord('W'); h[9] := Ord('A'); h[10] := Ord('V'); h[11] := Ord('E');
  h[12] := Ord('f'); h[13] := Ord('m'); h[14] := Ord('t'); h[15] := Ord(' ');
  PutLE32(@h[16], 16);              // fmt chunk size
  PutLE16(@h[20], 1);               // PCM
  PutLE16(@h[22], 1);               // mono
  PutLE32(@h[24], CAP12A_WAV_RATE); // sample rate
  PutLE32(@h[28], CAP12A_WAV_RATE); // byte rate = rate * channels * bytes
  PutLE16(@h[32], 1);               // block align
  PutLE16(@h[34], 8);               // bits per sample
  h[36] := Ord('d'); h[37] := Ord('a'); h[38] := Ord('t'); h[39] := Ord('a');
  PutLE32(@h[40], DataBytes);
end;

procedure FillPlanRange(const Plan: TBlobPlan; Dest: PByte;
  Offset, Count: Int64);
var
  header: array[0 .. CAP12A_WAV_HEADER - 1] of Byte;
  headPart: Int64;
  png: RawByteString;
begin
  if (Dest = nil) or (Count <= 0) then
    exit;
  if Plan.Kind = bpkPng then
  begin
    png := TinyPngBytes;
    if Offset + Count > Length(png) then
      exit;
    Move(PByte(png)[Offset], Dest^, Count);
    exit;
  end;
  if Plan.Kind <> bpkWav then
  begin
    FillBlobRange(Dest, Offset, Count);
    exit;
  end;
  BuildWavHeader(header, LongWord(Plan.Total - CAP12A_WAV_HEADER));
  headPart := 0;
  if Offset < CAP12A_WAV_HEADER then
  begin
    headPart := CAP12A_WAV_HEADER - Offset;
    if headPart > Count then
      headPart := Count;
    Move(header[Offset], Dest^, headPart);
  end;
  if headPart < Count then
    FillBlobRange(@Dest[headPart], Offset + headPart - CAP12A_WAV_HEADER,
      Count - headPart);
end;

const
  TINY_PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE' +
                 'QVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

var
  TinyPngCache: RawByteString;

function TinyPngBytes: RawByteString;
begin
  if TinyPngCache = '' then
    TinyPngCache := Base64ToBin(RawUtf8(TINY_PNG_B64));
  Result := TinyPngCache;
end;

function BuildWholeBody(const Plan: TBlobPlan): RawByteString;
begin
  Result := '';
  if Plan.Kind = bpkPng then
  begin
    Result := TinyPngBytes;
    exit;
  end;
  if (Plan.Total <= 0) or (Plan.Total > CAP12A_MAX_TOTAL) then
    exit;
  SetLength(Result, Plan.Total);
  FillPlanRange(Plan, PByte(Result), 0, Plan.Total);
end;

{ ---- id grammar ---- }

function NextField(const s: RawUtf8; var p: PtrInt; out field: RawUtf8): Boolean;
var
  start: PtrInt;
begin
  start := p;
  while (p <= Length(s)) and (s[p] <> '-') do
    Inc(p);
  field := Copy(s, start, p - start);
  if p <= Length(s) then
    Inc(p); // step over the separator
  Result := field <> '';
end;

function FieldInt(const field: RawUtf8; Min, Max: Int64; out v: Int64): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  v := 0;
  if (field = '') or (Length(field) > 18) then
    exit;
  for i := 1 to Length(field) do
  begin
    if not (field[i] in ['0' .. '9']) then
      exit;
    v := v * 10 + (Ord(field[i]) - Ord('0'));
  end;
  Result := (v >= Min) and (v <= Max);
end;

function BlobPathId(const LogicalPath: RawUtf8; out Id: RawUtf8): Boolean;
var
  n: PtrInt;
begin
  Id := '';
  n := Length(CAP12A_BLOB_PREFIX);
  Result := (Length(LogicalPath) > n) and
            CompareMem(Pointer(LogicalPath), Pointer(CAP12A_BLOB_PREFIX), n);
  if Result then
    Id := Copy(LogicalPath, n + 1, Length(LogicalPath) - n);
end;

function ParseBlobPlan(const Id: RawUtf8; out Plan: TBlobPlan): Boolean;
var
  p: PtrInt;
  verb, f: RawUtf8;
  a, b, c: Int64;
begin
  Plan := Default(TBlobPlan);
  Plan.Id := Id;
  Plan.ContentType := 'application/octet-stream';
  Result := False;
  p := 1;
  if not NextField(Id, p, verb) then
    exit;

  if verb = 'whole' then
  begin
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 0, CAP12A_MAX_TOTAL, a) then exit;
    Plan.Kind := bpkWhole;
    Plan.Total := a;
    Plan.Chunks := 1;
    Plan.ChunkBytes := Integer(a);
  end
  else if verb = 'stream' then
  begin
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, 4096, a) then exit;
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, 64 * 1024 * 1024, b) then exit;
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 0, 60000, c) then exit;
    if a * b > CAP12A_MAX_TOTAL then exit;
    Plan.Kind := bpkStream;
    Plan.Chunks := Integer(a);
    Plan.ChunkBytes := Integer(b);
    Plan.DelayMs := Integer(c);
    Plan.Total := a * b;
  end
  else if verb = 'streamnolen' then
  begin
    // the same producer with NO declared Content-Length, because an engine
    // may well buffer a body whose length it knows and stream one it does
    // not, and a measurement that only ever declares a length cannot tell
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, 4096, a) then exit;
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, 64 * 1024 * 1024, b) then exit;
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 0, 60000, c) then exit;
    if a * b > CAP12A_MAX_TOTAL then exit;
    Plan.Kind := bpkStream;
    Plan.Chunks := Integer(a);
    Plan.ChunkBytes := Integer(b);
    Plan.DelayMs := Integer(c);
    Plan.Total := -1;
  end
  else if verb = 'sse' then
  begin
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, 1000, a) then exit;
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 0, 60000, b) then exit;
    Plan.Kind := bpkSse;
    Plan.Chunks := Integer(a);
    Plan.DelayMs := Integer(b);
    Plan.Total := -1; // length unknown and deliberately undeclared
    Plan.ContentType := 'text/event-stream';
  end
  else if (verb = 'wav') or (verb = 'wavnorange') or (verb = 'wavx') then
  begin
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, 600, a) then exit;
    Plan.Kind := bpkWav;
    Plan.Total := CAP12A_WAV_HEADER + a * CAP12A_WAV_RATE;
    Plan.Chunks := 1;
    Plan.ChunkBytes := Integer(Plan.Total);
    // audio/wav and audio/x-wav are BOTH measured, because an engine that
    // rejects a media resource may be rejecting the type rather than the
    // scheme, and the two answers lead to different data planes
    if verb = 'wavx' then
      Plan.ContentType := 'audio/x-wav'
    else
      Plan.ContentType := 'audio/wav';
    Plan.Ranged := verb <> 'wavnorange';
  end
  else if verb = 'png' then
  begin
    Plan.Kind := bpkPng;
    Plan.Total := Length(TinyPngBytes);
    Plan.Chunks := 1;
    Plan.ChunkBytes := Integer(Plan.Total);
    Plan.ContentType := 'image/png';
    Plan.Ranged := True;
  end
  else if verb = 'ranged' then
  begin
    if not NextField(Id, p, f) then exit;
    if not FieldInt(f, 1, CAP12A_MAX_TOTAL, a) then exit;
    Plan.Kind := bpkWhole;
    Plan.Total := a;
    Plan.Chunks := 1;
    Plan.ChunkBytes := Integer(a);
    Plan.Ranged := True;
  end
  else if verb = 'echo' then
  begin
    Plan.Kind := bpkEcho;
    Plan.Total := 0;
    Plan.ContentType := 'application/json';
  end
  else
    exit;

  // a trailing field is a spelling this grammar does not define: refuse it
  // rather than ignore it, so a typo in a row is a missing blob and never a
  // silently different measurement
  if p <= Length(Id) then
  begin
    Plan := Default(TBlobPlan);
    exit;
  end;
  Result := True;
end;

function SseFrame(Index: Integer; Micros: Int64): RawUtf8;
begin
  Result := 'id: ' + RawUtf8(IntToStr(Index)) + #10 +
            'event: tick' + #10 +
            'data: {"i":' + RawUtf8(IntToStr(Index)) +
            ',"produced_us":' + RawUtf8(IntToStr(Micros)) + '}' + #10#10;
end;

function ParseSingleRange(const HeaderValue: RawUtf8; Total: Int64;
  out First, Last: Int64): Boolean;
var
  s, lhs, rhs: RawUtf8;
  i, dash: PtrInt;
  a, b: Int64;
begin
  Result := False;
  First := 0;
  Last := -1;
  if (Total <= 0) or (Length(HeaderValue) > 128) then
    exit;
  s := '';
  for i := 1 to Length(HeaderValue) do
    if HeaderValue[i] <> ' ' then
      s := s + HeaderValue[i];
  if Copy(s, 1, 6) <> 'bytes=' then
    exit;
  s := Copy(s, 7, Length(s) - 6);
  // MULTI-RANGE IS REFUSED, not partially honoured. A handler that answers
  // the first window of a multi-range request with a plain 206 is lying to
  // the engine about what it sent; the measurement says "not supported".
  if Pos(',', s) > 0 then
    exit;
  dash := Pos('-', s);
  if dash = 0 then
    exit;
  lhs := Copy(s, 1, dash - 1);
  rhs := Copy(s, dash + 1, Length(s) - dash);
  if lhs = '' then
  begin
    // suffix form: the last N bytes
    if not FieldInt(rhs, 1, Total, b) then
      exit;
    First := Total - b;
    Last := Total - 1;
    Result := True;
    exit;
  end;
  if not FieldInt(lhs, 0, Total - 1, a) then
    exit;
  if rhs = '' then
    b := Total - 1
  else if not FieldInt(rhs, 0, High(Int64) div 2, b) then
    exit;
  if b > Total - 1 then
    b := Total - 1;
  if b < a then
    exit;
  First := a;
  Last := b;
  Result := True;
end;

{ ---- the clock and the timeline ---- }

type
  TTimelineEntry = record
    Micros: Int64;
    Value: Int64;
    Event: RawUtf8;
    Detail: RawUtf8;
  end;

const
  TIMELINE_MAX = 20000;

var
  TimelineLock: TRTLCriticalSection;
  Timeline: array[0 .. TIMELINE_MAX - 1] of TTimelineEntry;
  TimelineN: Integer;
  TimelineLost: Integer;
  ClockBase: Int64;

function NowMicros: Int64;
var
  v: Int64;
begin
  QueryPerformanceMicroSeconds(v);
  Result := v - ClockBase;
end;

procedure TimelineReset;
var
  i: Integer;
begin
  EnterCriticalSection(TimelineLock);
  try
    for i := 0 to TimelineN - 1 do
    begin
      Timeline[i].Event := '';
      Timeline[i].Detail := '';
    end;
    TimelineN := 0;
    TimelineLost := 0;
    QueryPerformanceMicroSeconds(ClockBase);
  finally
    LeaveCriticalSection(TimelineLock);
  end;
end;

procedure Mark(const Event: RawUtf8; const Detail: RawUtf8; Value: Int64);
var
  us: Int64;
begin
  // the timestamp is taken BEFORE the lock, so a contended timeline cannot
  // reorder two events that really happened in that order
  us := NowMicros;
  EnterCriticalSection(TimelineLock);
  try
    if TimelineN >= TIMELINE_MAX then
    begin
      Inc(TimelineLost);
      exit;
    end;
    Timeline[TimelineN].Micros := us;
    Timeline[TimelineN].Value := Value;
    Timeline[TimelineN].Event := Event;
    Timeline[TimelineN].Detail := Detail;
    Inc(TimelineN);
  finally
    LeaveCriticalSection(TimelineLock);
  end;
end;

function TimelineCount: Integer;
begin
  EnterCriticalSection(TimelineLock);
  Result := TimelineN;
  LeaveCriticalSection(TimelineLock);
end;

function TimelineDropped: Integer;
begin
  EnterCriticalSection(TimelineLock);
  Result := TimelineLost;
  LeaveCriticalSection(TimelineLock);
end;

function FirstMicrosOf(const Event: RawUtf8): Int64;
var
  i: Integer;
begin
  Result := -1;
  EnterCriticalSection(TimelineLock);
  try
    for i := 0 to TimelineN - 1 do
      if Timeline[i].Event = Event then
      begin
        Result := Timeline[i].Micros;
        exit;
      end;
  finally
    LeaveCriticalSection(TimelineLock);
  end;
end;

function LastMicrosOf(const Event: RawUtf8): Int64;
var
  i: Integer;
begin
  Result := -1;
  EnterCriticalSection(TimelineLock);
  try
    for i := TimelineN - 1 downto 0 do
      if Timeline[i].Event = Event then
      begin
        Result := Timeline[i].Micros;
        exit;
      end;
  finally
    LeaveCriticalSection(TimelineLock);
  end;
end;

function CountOf(const Event: RawUtf8): Integer;
var
  i: Integer;
begin
  Result := 0;
  EnterCriticalSection(TimelineLock);
  try
    for i := 0 to TimelineN - 1 do
      if Timeline[i].Event = Event then
        Inc(Result);
  finally
    LeaveCriticalSection(TimelineLock);
  end;
end;

function MaxOverlap(const OpenEvent, CloseEvent: RawUtf8): Integer;
var
  i, live: Integer;
begin
  Result := 0;
  live := 0;
  EnterCriticalSection(TimelineLock);
  try
    for i := 0 to TimelineN - 1 do
      if Timeline[i].Event = OpenEvent then
      begin
        Inc(live);
        if live > Result then
          Result := live;
      end
      else if Timeline[i].Event = CloseEvent then
      begin
        if live > 0 then
          Dec(live);
      end;
  finally
    LeaveCriticalSection(TimelineLock);
  end;
end;

function JsonQuote(const Text: RawUtf8): RawUtf8;
const
  HEX: array[0 .. 15] of AnsiChar = '0123456789abcdef';
var
  i: PtrInt;
  c: AnsiChar;
begin
  Result := '"';
  for i := 1 to Length(Text) do
  begin
    c := Text[i];
    case c of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if c < #$20 then
        Result := Result + '\u00' + HEX[Ord(c) shr 4] + HEX[Ord(c) and 15]
      else
        Result := Result + c;
    end;
  end;
  Result := Result + '"';
end;

function TimelineJson: RawUtf8;
var
  i: Integer;
  sep: RawUtf8;
begin
  Result := '[';
  sep := '';
  EnterCriticalSection(TimelineLock);
  try
    for i := 0 to TimelineN - 1 do
    begin
      Result := Result + sep + '{"us":' +
        RawUtf8(IntToStr(Timeline[i].Micros)) +
        ',"e":' + JsonQuote(Timeline[i].Event);
      if Timeline[i].Detail <> '' then
        Result := Result + ',"d":' + JsonQuote(Timeline[i].Detail);
      if Timeline[i].Value <> 0 then
        Result := Result + ',"v":' + RawUtf8(IntToStr(Timeline[i].Value));
      Result := Result + '}';
      sep := ',';
    end;
  finally
    LeaveCriticalSection(TimelineLock);
  end;
  Result := Result + ']';
end;

{ ---- RSS ---- }

{$ifdef MSWINDOWS}
type
  TPWebProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize: PtrUInt;
    WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage: PtrUInt;
    QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage: PtrUInt;
    QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage: PtrUInt;
    PeakPagefileUsage: PtrUInt;
  end;

// Windows 7 and later export the psapi entry points from kernel32 under a
// K32 prefix, which is why this spike needs no psapi import at all.
function K32GetProcessMemoryInfo(Process: THandle;
  var ppsmemCounters: TPWebProcessMemoryCounters; cb: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'K32GetProcessMemoryInfo';
{$endif MSWINDOWS}

function ProcessRssBytes: Int64;
{$ifdef MSWINDOWS}
var
  pmc: TPWebProcessMemoryCounters;
begin
  FillChar(pmc, SizeOf(pmc), 0);
  pmc.cb := SizeOf(pmc);
  if K32GetProcessMemoryInfo(GetCurrentProcess, pmc, SizeOf(pmc)) then
    Result := Int64(pmc.WorkingSetSize)
  else
    Result := -1;
end;
{$else}
var
  f: TextFile;
  line: string;
  v: Int64;
  code, sp: Integer;
begin
  // WHY /proc/self/statm AND NOT VmHWM: the peak in /proc/self/status is a
  // process-lifetime high-water mark that cannot be reset without
  // clear_refs, so the 256 MiB whole row would poison every later row's
  // peak. This is the current value; the sampler below turns it into a
  // per-row maximum.
  Result := -1;
  {$I-}
  AssignFile(f, '/proc/self/statm');
  Reset(f);
  if IOResult <> 0 then
    exit;
  ReadLn(f, line);
  CloseFile(f);
  if IOResult <> 0 then
    exit;
  {$I+}
  // statm: size resident shared text lib data dt, in pages
  sp := Pos(' ', line);
  if sp <= 0 then
    exit;
  line := Copy(line, sp + 1, Length(line) - sp);
  sp := Pos(' ', line);
  if sp > 0 then
    line := Copy(line, 1, sp - 1);
  Val(line, v, code);
  if code <> 0 then
    exit;
  Result := v * Int64(4096);
end;
{$endif MSWINDOWS}

var
  RssThread: system.TThreadID;
  RssRun: Boolean;
  RssStarted: Boolean;
  RssMax: Int64;
  RssCount: Integer;
  RssIntervalMs: Integer;

function RssSamplerLoop(p: Pointer): PtrInt;
var
  v, lastMarked: Int64;
begin
  Result := 0;
  lastMarked := 0;
  while RssRun do
  begin
    v := ProcessRssBytes;
    if v > 0 then
    begin
      EnterCriticalSection(TimelineLock);
      if v > RssMax then
        RssMax := v;
      Inc(RssCount);
      LeaveCriticalSection(TimelineLock);
      // A PHASE TOTAL IS NOT A SHAPE. The per-phase peak says how high the
      // process went; it cannot say whether that was one allocation or four
      // in a row, and a 2 GiB phase peak for a 256 MiB body is exactly the
      // question a total cannot answer. Every 8 MiB step is put on the
      // timeline so the shape is readable afterwards.
      if (v > lastMarked + 8 * 1024 * 1024) or
         (v < lastMarked - 8 * 1024 * 1024) then
      begin
        Mark('rss', '', v);
        lastMarked := v;
      end;
    end;
    Sleep(RssIntervalMs);
  end;
end;

procedure RssSamplerStart(IntervalMs: Integer);
var
  id: system.TThreadID;
begin
  if RssStarted then
    exit;
  if IntervalMs < 5 then
    IntervalMs := 5;
  RssIntervalMs := IntervalMs;
  RssRun := True;
  RssMax := 0;
  RssCount := 0;
  RssThread := BeginThread(@RssSamplerLoop, nil, id);
  RssStarted := RssThread <> TThreadID(0);
  if not RssStarted then
    RssRun := False;
end;

procedure RssSamplerStop;
begin
  if not RssStarted then
    exit;
  RssRun := False;
  WaitForThreadTerminate(RssThread, 5000);
  CloseThread(RssThread);
  RssStarted := False;
end;

function RssMarkBaseline: Int64;
begin
  Result := ProcessRssBytes;
  if Result < 0 then
    Result := 0;
  EnterCriticalSection(TimelineLock);
  RssMax := Result;
  LeaveCriticalSection(TimelineLock);
end;

function RssPeakBytes: Int64;
begin
  EnterCriticalSection(TimelineLock);
  Result := RssMax;
  LeaveCriticalSection(TimelineLock);
end;

function RssSamples: Integer;
begin
  EnterCriticalSection(TimelineLock);
  Result := RssCount;
  LeaveCriticalSection(TimelineLock);
end;

initialization
  InitCriticalSection(TimelineLock);
  QueryPerformanceMicroSeconds(ClockBase);

finalization
  RssSamplerStop;
  DoneCriticalSection(TimelineLock);

end.
