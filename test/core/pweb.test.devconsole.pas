unit pweb.test.devconsole;

{ mormot.core.test cases for CAP-14B: the development console surface.

  The defect this suite exists for is that a frontend under `pweb dev` had
  no voice at all - every console.log, every uncaught throw and every
  unhandled rejection died inside the engine while the supervisor forwarded
  only the host's own lines (TODO.txt #6).

  WHAT IS DECIDED HERE, AND WHAT IS NOT. Everything below the engine is a
  pure function of bytes and is decided here, headless, on four targets: the
  parameter decode, the record grammar, the level table, the sanitiser, the
  two truncations, the digit rule, and the AUTHORITATIVE ring bound driven
  through the real ring and the real writer path. Everything that needs a
  real page - the levels a real engine reports, a real source position, a
  real 10 000-line burst, survival across a generation switch, and the
  release binary carrying none of it - belongs to
  test/cap14b/run_cap14b_gates.ps1, which drives real `pweb dev` sessions.

  THE ADVERSARIAL ROWS ARE THE POINT. A diagnostic channel that a page
  writes into is a channel a page can attack: a record that carries an
  embedded newline would become TWO supervisor lines; a record naming a
  level nobody ratified would let a page invent a category; a `dropped`
  record whose count is not a number would let a page write its own
  attribution; an unframed or over-long payload would put a general parser
  in front of page bytes. Each of those is a row.

  ONE TABLE drives the grammar rows, and DecisionDigest emits the whole
  table as build/cap7f/dev-console.txt. Its SHA-256 is recorded by the
  CAP-7F emitters as dev_console_digest and required IDENTICAL on four
  targets: every decision here is a pure function of bytes, so a target that
  disagreed would be running a different rule.

  Webview-free, bridge-free, window-free: it installs nothing and binds
  nothing, so it is headless on all four CI targets. }

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.test,
  pweb.webview.devconsole,
  pweb.test.reporoot;

type
  /// CAP-14B dev-console cases: the wire decode, the record grammar, the
  /// level table, the sanitiser, the bounds and the four-target corpus
  TTestDevConsole = class(TSynTestCase)
  published
    /// the five console levels and the two engine error levels
    procedure Levels;
    /// a console method whose name is not its level is named in the text
    procedure MethodNaming;
    /// a source position is rendered when the record carries one
    procedure SourcePosition;
    /// every control byte is replaced, so one record is always one line
    procedure Sanitiser;
    /// both truncations - the byte bound and its visible marker
    procedure Truncation;
    /// the parameter array decode: framing, the payload bound, base64
    procedure ParameterDecode;
    /// what a record cannot be: a bad level, a short record, a forged
    /// drop attribution
    procedure RefusedRecords;
    /// the AUTHORITATIVE bound, driven through the real ring
    procedure RingBound;
    /// the shim's own invariants, checked against the unit's constants
    procedure ShimInvariants;
    /// the four-target decision corpus
    procedure DecisionDigest;
  end;

const
  /// where the four-target decision corpus is written
  PWEB_CAP14B_DIGEST_FILE = 'build/cap7f/dev-console.txt';
  /// where the EMITTED shim is written, so a gate can hold it to a
  /// JavaScript parser rather than to a reader's eye - the defect that
  /// made this file necessary was a shim that threw while being parsed
  PWEB_CAP14B_SHIM_FILE = 'build/cap7f/dev-console-shim.js';


implementation

const
  US = #31;
  LF = #10;
  PREFIX = 'demo';

type
  TConsoleRow = record
    Name: RawUtf8;
    Batch: RawUtf8;
    /// every emitted line, joined by '|', and the refused count after '#'
    Want: RawUtf8;
  end;

var
  /// what the probe collected, since an emit sink is a plain procedure
  ProbeLines: TRawUtf8DynArray;
  ProbeCount: Integer;

procedure ProbeSink(const Line: RawUtf8);
begin
  if ProbeCount = Length(ProbeLines) then
    SetLength(ProbeLines, ProbeCount + 64);
  ProbeLines[ProbeCount] := Line;
  Inc(ProbeCount);
end;

function Rec(const Level, Method, Origin, Text: RawUtf8): RawUtf8;
begin
  Result := Level + US + Method + US + Origin + US + Text;
end;

// one batch through the real renderer, flattened so a row is one string
function Render(const Batch: RawUtf8): RawUtf8;
var
  lines: TRawUtf8DynArray;
  refused, i: Integer;
begin
  lines := PWebDevConsoleRenderBatch(PREFIX, Batch, refused);
  Result := '';
  for i := 0 to High(lines) do
  begin
    if Result <> '' then
      Result := Result + '|';
    Result := Result + lines[i];
  end;
  Result := Result + '#' + RawUtf8(IntToStr(refused));
end;

const
  /// the whole grammar, as rows a four-target digest can compare
  CORPUS: array[0 .. 21] of TConsoleRow = (
    (Name: 'level_log';
     Batch: 'log' + US + 'log' + US + US + 'hello';
     Want: 'demo: console log: hello#0'),
    (Name: 'level_info';
     Batch: 'info' + US + 'info' + US + US + 'hello';
     Want: 'demo: console info: hello#0'),
    (Name: 'level_warn';
     Batch: 'warn' + US + 'warn' + US + US + 'hello';
     Want: 'demo: console warn: hello#0'),
    (Name: 'level_error';
     Batch: 'error' + US + 'error' + US + US + 'hello';
     Want: 'demo: console error: hello#0'),
    (Name: 'level_debug';
     Batch: 'debug' + US + 'debug' + US + US + 'hello';
     Want: 'demo: console debug: hello#0'),
    (Name: 'level_uncaught';
     Batch: 'uncaught' + US + US + 'pweb://app/assets/app.js:3:30' + US +
       'TypeError: null is not an object';
     Want: 'demo: console uncaught @pweb://app/assets/app.js:3:30: ' +
       'TypeError: null is not an object#0'),
    (Name: 'level_rejection';
     Batch: 'rejection' + US + US + '@pweb://app/assets/app.js:4:50' + US +
       'Error: page rejection';
     Want: 'demo: console rejection @@pweb://app/assets/app.js:4:50: ' +
       'Error: page rejection#0'),
    (Name: 'level_dropped_page';
     Batch: 'dropped' + US + US + US + '1234';
     Want: 'demo: console dropped: 1234 (page)#0'),
    (Name: 'method_named_when_it_differs';
     Batch: 'log' + US + 'trace' + US + US + 'hello';
     Want: 'demo: console log: trace hello#0'),
    (Name: 'method_silent_when_it_matches';
     Batch: 'warn' + US + 'warn' + US + US + 'hello';
     Want: 'demo: console warn: hello#0'),
    (Name: 'method_absent';
     Batch: 'log' + US + US + US + 'hello';
     Want: 'demo: console log: hello#0'),
    (Name: 'no_position_no_at';
     Batch: 'uncaught' + US + US + US + 'Script error.';
     Want: 'demo: console uncaught: Script error.#0'),
    // AN EMBEDDED NEWLINE CANNOT SMUGGLE A LINE, and the reason is
    // structural rather than cosmetic: LF is the RECORD separator, so the
    // splitter sees the tail as its own record, that record carries no
    // separators, and it is refused. The page loses its own text and the
    // supervisor gains no second content line
    (Name: 'embedded_newline_splits_and_the_tail_is_refused';
     Batch: 'log' + US + 'log' + US + US + 'a' + #10 + 'b';
     Want: 'demo: console log: a#1'),
    (Name: 'carriage_return_and_escape';
     Batch: 'log' + US + 'log' + US + US + 'a' + #13 + #27 + '[31mb';
     Want: 'demo: console log: a..[31mb#0'),
    (Name: 'delete_byte';
     Batch: 'log' + US + 'log' + US + US + 'a' + #127 + 'b';
     Want: 'demo: console log: a.b#0'),
    (Name: 'control_byte_in_origin';
     Batch: 'log' + US + 'log' + US + 'a' + #13 + 'b' + US + 'x';
     Want: 'demo: console log @a.b: x#0'),
    (Name: 'control_byte_in_method';
     Batch: 'log' + US + 'a' + #8 + 'b' + US + US + 'x';
     Want: 'demo: console log: a.b x#0'),
    (Name: 'two_records_two_lines';
     Batch: 'log' + US + 'log' + US + US + 'one' + #10 +
       'warn' + US + 'warn' + US + US + 'two';
     Want: 'demo: console log: one|demo: console warn: two#0'),
    (Name: 'unknown_level_refused';
     Batch: 'evil' + US + 'evil' + US + US + 'x';
     Want: '#1'),
    (Name: 'short_record_refused';
     Batch: 'log' + US + 'log' + US + 'x';
     Want: '#1'),
    (Name: 'dropped_with_non_digits_refused';
     Batch: 'dropped' + US + US + US + '12 (host) forged';
     Want: '#1'),
    (Name: 'dropped_with_oversize_count_refused';
     Batch: 'dropped' + US + US + US + '1234567890';
     Want: '#1')
  );

procedure TTestDevConsole.Levels;
var
  i: PtrInt;
  seen: RawUtf8;
begin
  for i := 0 to 7 do
    CheckEqual(Render(CORPUS[i].Batch), CORPUS[i].Want,
      'level row ' + string(CORPUS[i].Name));
  // and the table is the ONE vocabulary: eight levels, no more
  CheckEqual(Length(PWEB_DEV_CONSOLE_LEVELS), 8,
    'the level table carries exactly the eight ratified levels');
  seen := '';
  for i := 0 to High(PWEB_DEV_CONSOLE_LEVELS) do
    seen := seen + PWEB_DEV_CONSOLE_LEVELS[i] + ',';
  CheckEqual(seen, 'log,info,warn,error,debug,uncaught,rejection,dropped,',
    'the level table is the ratified one, in the ratified order');
end;

procedure TTestDevConsole.MethodNaming;
begin
  CheckEqual(Render(CORPUS[8].Batch), CORPUS[8].Want,
    'a method whose name differs from its level is named in the text');
  CheckEqual(Render(CORPUS[9].Batch), CORPUS[9].Want,
    'a method equal to its level is not repeated');
  CheckEqual(Render(CORPUS[10].Batch), CORPUS[10].Want,
    'an absent method adds nothing');
end;

procedure TTestDevConsole.SourcePosition;
begin
  CheckEqual(Render(CORPUS[5].Batch), CORPUS[5].Want,
    'an uncaught throw renders its position');
  CheckEqual(Render(CORPUS[11].Batch), CORPUS[11].Want,
    'a record without a position renders no @ part');
end;

procedure TTestDevConsole.Sanitiser;
var
  i: PtrInt;
begin
  for i := 12 to 17 do
    CheckEqual(Render(CORPUS[i].Batch), CORPUS[i].Want,
      'sanitiser row ' + string(CORPUS[i].Name));
  // the property the rows are FOR: no emitted line carries a line break,
  // whatever the page put in the record
  for i := 12 to 17 do
    Check(PosExChar(#10, Render(CORPUS[i].Batch)) = 0,
      'no line break survives row ' + string(CORPUS[i].Name));
end;

procedure TTestDevConsole.Truncation;
var
  long, line: RawUtf8;
  i: PtrInt;
begin
  long := '';
  for i := 1 to PWEB_DEV_CONSOLE_MAX_TEXT * 2 do
    long := long + 'x';
  line := Render(Rec('log', 'log', '', long));
  Check(Pos(RawUtf8(' [+' + IntToStr(PWEB_DEV_CONSOLE_MAX_TEXT) + ']'),
    line) > 0, 'an over-long text is cut at the bound and says by how much');
  Check(Length(line) <= PWEB_DEV_CONSOLE_LINE_MAX + 16,
    'no emitted line passes the line bound');
  // A MULTI-BYTE CODE POINT IS NEVER CUT IN HALF. 1200 three-byte
  // characters is 3600 bytes, and byte 1024 - the bound - is a
  // CONTINUATION byte of the 342nd character, so the cut has to back off to
  // 1023 (341 whole characters) and report 2577 dropped. A scanner that did
  // not back off would emit a broken code point into a developer's terminal
  long := '';
  for i := 1 to 1200 do
    long := long + #$E2#$82#$AC; // U+20AC, three bytes
  line := Render(Rec('log', 'log', '', long));
  CheckEqual(Length(long), 3600, 'the multi-byte fixture is 3600 bytes');
  Check(Pos(RawUtf8(' [+2577]'), line) > 0,
    'the cut backed off to a UTF-8 boundary and said what it dropped');
end;

procedure TTestDevConsole.ParameterDecode;
var
  batch, payload, over: RawUtf8;
  i: PtrInt;
begin
  payload := BinToBase64(RawByteString('log' + US + 'log' + US + US + 'hi'));
  Check(PWebDevConsoleDecodeParams('["' + payload + '"]', batch),
    'a well-framed base64 payload decodes');
  CheckEqual(batch, 'log' + US + 'log' + US + US + 'hi',
    'the decoded batch is the bytes the page sent');
  Check(not PWebDevConsoleDecodeParams('[]', batch),
    'an unframed parameter array is refused');
  Check(not PWebDevConsoleDecodeParams('["' + payload, batch),
    'a payload with no closing quote is refused');
  Check(not PWebDevConsoleDecodeParams('["not base64 at all!!"]', batch),
    'a payload that is not base64 is refused whole');
  Check(not PWebDevConsoleDecodeParams('', batch),
    'an empty parameter array is refused');
  over := '';
  for i := 1 to PWEB_DEV_CONSOLE_MAX_PAYLOAD + 8 do
    over := over + 'A';
  Check(not PWebDevConsoleDecodeParams('["' + over + '"]', batch),
    'a payload past its bound is refused BEFORE a decode is attempted');
end;

procedure TTestDevConsole.RefusedRecords;
var
  i: PtrInt;
begin
  for i := 18 to 21 do
    CheckEqual(Render(CORPUS[i].Batch), CORPUS[i].Want,
      'refusal row ' + string(CORPUS[i].Name));
  // and a refusal is never partial: nothing of the record is printed
  Check(Pos(RawUtf8('forged'), Render(CORPUS[20].Batch)) = 0,
    'a refused drop record contributes no text at all');
end;

procedure TTestDevConsole.RingBound;
var
  emitted, i, dropNotices: Integer;
  dropped: Int64;
begin
  // MORE batches than the ring holds, through the REAL ring and the REAL
  // writer path. This is the bound a page cannot defeat by calling the
  // binding directly, so it is the one that has to be measured
  ProbeCount := 0;
  ProbeLines := nil;
  Check(PWebDevConsoleProbe(PWEB_DEV_CONSOLE_MAX_BATCHES * 4, 8,
    @ProbeSink, emitted, dropped), 'the headless probe ran');
  CheckEqual(emitted, PWEB_DEV_CONSOLE_MAX_BATCHES * 4 * 8,
    'the probe offered every record');
  Check(dropped > 0,
    'pushing past the ring drops, rather than blocking the caller');
  Check(ProbeCount < emitted,
    'the bound is enforced: fewer lines came out than went in');
  dropNotices := 0;
  for i := 0 to ProbeCount - 1 do
    if Pos(RawUtf8(' (host)'), ProbeLines[i]) > 0 then
      Inc(dropNotices);
  CheckEqual(dropNotices, 1,
    'the channel SAYS how many it dropped, once, attributed natively');
  // the ring holds one fewer than its capacity, which is what a
  // head/tail ring costs; the accepted count is that, times the records
  CheckEqual(ProbeCount,
    (PWEB_DEV_CONSOLE_MAX_BATCHES - 1) * 8 + 1,
    'exactly the ring capacity was emitted, plus the one notice');
  CheckEqual(dropped,
    Int64(PWEB_DEV_CONSOLE_MAX_BATCHES * 4 * 8) -
    Int64((PWEB_DEV_CONSOLE_MAX_BATCHES - 1) * 8),
    'every record that did not come out was counted');
end;

procedure TTestDevConsole.ShimInvariants;
var
  shim: RawUtf8;
begin
  shim := PWebDevConsoleShim;
  Check(shim <> '', 'the shim is not empty');
  Check(Pos(RawUtf8(PWEB_DEV_CONSOLE_BIND), shim) > 0,
    'the shim calls the ONE ratified binding name');
  Check(Pos(RawUtf8('%BIND%'), shim) = 0,
    'every placeholder was substituted');
  Check(Pos(RawUtf8('%MAX'), shim) = 0,
    'every bound placeholder was substituted');
  // the bounds are the unit's, not a second set typed into JavaScript
  Check(Pos(RawUtf8('MAXT=' + IntToStr(PWEB_DEV_CONSOLE_MAX_TEXT)), shim) > 0,
    'the page-side text bound is the unit constant');
  Check(Pos(RawUtf8('MAXB=' + IntToStr(PWEB_DEV_CONSOLE_MAX_BATCH)), shim) > 0,
    'the page-side batch bound is the unit constant');
  Check(Pos(RawUtf8('MAXP=' + IntToStr(PWEB_DEV_CONSOLE_MAX_PENDING)),
    shim) > 0, 'the page-side pending bound is the unit constant');
  Check(Pos(RawUtf8('IVL=' + IntToStr(PWEB_DEV_CONSOLE_FLUSH_MS)), shim) > 0,
    'the page-side flush interval is the unit constant');
  // and it names every level it can send, so the two vocabularies are one
  Check(Pos(RawUtf8('"dropped"'), shim) > 0, 'the shim names the drop level');
  Check(Pos(RawUtf8('"uncaught"'), shim) > 0,
    'the shim names the uncaught level');
  Check(Pos(RawUtf8('"rejection"'), shim) > 0,
    'the shim names the rejection level');
  // NO TRANSPORT: the shim opens nothing and names no origin
  Check(Pos(RawUtf8('WebSocket'), shim) = 0, 'the shim opens no socket');
  Check(Pos(RawUtf8('fetch('), shim) = 0, 'the shim makes no request');
  Check(Pos(RawUtf8('XMLHttpRequest'), shim) = 0, 'the shim opens no XHR');
  Check(Pos(RawUtf8('__pweb_invoke'), shim) = 0,
    'the shim never touches the invocation binding');
  // NO BACKSLASH, and it is checked here rather than only by the gate.
  // MEASURED: a doubled escape in the Pascal literal reached the engine as
  // an invalid character range and threw while the shim was being PARSED,
  // so nothing installed and the channel was silent with no diagnostic
  Check(PosExChar('\', shim) = 0,
    'the shim carries no backslash, so no Pascal escape can be doubled');
end;

procedure TTestDevConsole.DecisionDigest;
var
  lines: RawUtf8;
  allPass: Boolean;
  i: PtrInt;
  got: RawUtf8;
  stream: TFileStream;
  root, digestFile: TFileName;

  procedure Emit(const ALine: RawUtf8);
  begin
    lines := lines + ALine + LF; // LF only - the digest crosses OSes
  end;

begin
  // Every line below is a pure decision of a pure function over a fixed
  // table, so the file bytes - and therefore dev_console_digest - are
  // identical on all four targets by construction.
  lines := '';
  allPass := True;
  Emit('schema=1');
  Emit('bind=' + PWEB_DEV_CONSOLE_BIND);
  Emit('levels=log,info,warn,error,debug,uncaught,rejection,dropped');
  Emit('max_text=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_TEXT)));
  Emit('max_origin=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_ORIGIN)));
  Emit('max_batch=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_BATCH)));
  Emit('flush_ms=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_FLUSH_MS)));
  Emit('max_pending=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_PENDING)));
  Emit('max_payload=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_PAYLOAD)));
  Emit('max_batches=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_BATCHES)));
  Emit('line_max=' + RawUtf8(IntToStr(PWEB_DEV_CONSOLE_LINE_MAX)));
  for i := 0 to High(CORPUS) do
  begin
    got := Render(CORPUS[i].Batch);
    if got <> CORPUS[i].Want then
    begin
      allPass := False;
      Check(False, 'row ' + string(CORPUS[i].Name) + ' decided ' + string(got));
    end;
    Emit('decision name=' + CORPUS[i].Name + ' out=' + got);
  end;
  if allPass then
    Emit('verdict=PASS')
  else
    Emit('verdict=FAIL');

  root := RepoRootFromExecutable;
  if root = '' then
  begin
    Check(False, 'repository root (webview.lock marker) not found from ' +
      string(Executable.ProgramFilePath) +
      ' - refusing to write the digest corpus at an ambiguous location');
    exit;
  end;
  digestFile := root + TFileName(StringReplace(PWEB_CAP14B_DIGEST_FILE,
    '/', PathDelim, [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(digestFile)) then
    Check(False, 'unable to create ' + string(ExtractFilePath(digestFile)))
  else
  begin
    stream := TFileStream.Create(digestFile, fmCreate);
    try
      if lines <> '' then
        stream.WriteBuffer(lines[1], Length(lines));
    finally
      stream.Free;
    end;
  end;

  // and the shim itself, beside the corpus: a gate holds it to a real
  // JavaScript parser, because the one defect this channel has already had
  // was a shim that threw while it was being parsed
  digestFile := root + TFileName(StringReplace(PWEB_CAP14B_SHIM_FILE,
    '/', PathDelim, [rfReplaceAll]));
  lines := PWebDevConsoleShim;
  stream := TFileStream.Create(digestFile, fmCreate);
  try
    stream.WriteBuffer(lines[1], Length(lines));
  finally
    stream.Free;
  end;

  Check(allPass, 'every dev-console row decided as ratified');
end;

end.
