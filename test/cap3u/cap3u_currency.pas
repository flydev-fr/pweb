program cap3u_currency;

{ CAP-3U Currency return matrix, over the PRISTINE PINNED dependency, on all
  four targets.

  WHY THIS EXISTS. mORMot's CallMethod reads a Currency result out of a
  register that depends on the ABI, and this program measured two upstream
  steps of getting it right:

    790154af (2026-08-12) "core: ensure imvCurrency is returned in rax on
      x86-64" - taken by the 2026-09-08 pin move. It fixed Win64 (0/5 -> 5/5)
      and, because the asm block is shared by the whole x64 ABI, left SysV x64
      reading RAX, where FPC leaves nothing it means: 1/5 on linux-x86_64 and
      macos-x86_64. macos-arm64 was measured at 0/5 at that pin too, but not
      because of 790154af - AAPCS64 has its own CallMethod, which that commit
      never touched and which had always read the result from d0.
    6a27c07f (2026-09-16) "core: fixed currency result in
      mormot.core.interfaces" - written in answer to that measurement and
      taken by the 2026-09-16 pin move. FPC on SysV x64 leaves a Currency in
      x87 ST0, which the asm now pops with fistp; AArch64 now keeps the x0
      value instead of reading d0. Measured unpatched: 5/5 on all four
      targets, each on its own leg's compiler.

  WHAT THIS PROGRAM IS. The permanent gate over that result register, against
  the pristine dependency. It runs the five cases (arities 0/1/2), prints what
  each one did, writes the corpus, and holds the run to
  `test/cap3u/currency-expectations.tsv`. Since the 2026-09-16 move every row
  there is `must_pass`, so any case that regresses fails its leg. The
  `observe` verdict is still understood: it is how a row records a known
  upstream defect without failing anything, and demoting a row to it is a
  deliberate act that needs a measurement and a ledger entry.

  PWeb's own bridge was never changed by any of this. `SupportedInputType` in
  src/rpc/pweb.rpc.mormot.pas has always accepted `imvCurrency`; while the
  register was wrong that was a documented limitation of the pin, deliberately
  not worked around in the bridge so the defect stayed visible to the report
  that fixed it. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.interfaces,
  mormot.orm.core,
  mormot.rest.core,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.test.reporoot;

const
  CASE_COUNT = 5;
  TARGET_COUNT = 4;
  EXPECTATIONS = 'test/cap3u/currency-expectations.tsv';
  CORPUS = 'build/cap3u/currency-corpus.txt';

  // the four targets this repository builds; the table must cover every one,
  // so a target cannot be quietly dropped from the observation
  TARGETS: array[0 .. TARGET_COUNT - 1] of RawUtf8 = (
    'windows-x86_64', 'linux-x86_64', 'macos-x86_64', 'macos-arm64');

  CASE_NAMES: array[0 .. CASE_COUNT - 1] of RawUtf8 = (
    'cur-zero-arg', 'cur-one-int', 'cur-one-cur', 'cur-one-double',
    'cur-two-int');

type
  ICap3UCurrency = interface(IInvokable)
    ['{8E31C0A5-47B2-4D6F-B1C8-9F05A3E7D264}']
    function CurZero: Currency;
    function CurOneInt(A: Integer): Currency;
    function CurOneCur(const V: Currency): Currency;
    function CurOneDouble(V: Double): Currency;
    function CurTwoInt(A, B: Integer): Currency;
  end;

  TCap3UCurrency = class(TInterfacedObject, ICap3UCurrency)
  public
    function CurZero: Currency;
    function CurOneInt(A: Integer): Currency;
    function CurOneCur(const V: Currency): Currency;
    function CurOneDouble(V: Double): Currency;
    function CurTwoInt(A, B: Integer): Currency;
  end;

function TCap3UCurrency.CurZero: Currency;
begin
  Result := 1234.5678;
end;

function TCap3UCurrency.CurOneInt(A: Integer): Currency;
begin
  Result := A + 0.5;
end;

function TCap3UCurrency.CurOneCur(const V: Currency): Currency;
begin
  Result := V * 2;
end;

function TCap3UCurrency.CurOneDouble(V: Double): Currency;
begin
  Result := V * 2;
end;

function TCap3UCurrency.CurTwoInt(A, B: Integer): Currency;
begin
  Result := A * 100 + B + 0.25;
end;

var
  GServer: TRestServerFullMemory;
  GCorpus: RawUtf8;

function ThisTarget: RawUtf8;
begin
  // test-tree code, outside the CAP-7F production divergence surface: the
  // four names are the ones every other four-target gate already writes.
  {$ifdef OSWINDOWS}
  Result := 'windows-x86_64';
  {$else}
  {$ifdef OSDARWIN}
  {$ifdef CPUAARCH64}
  Result := 'macos-arm64';
  {$else}
  Result := 'macos-x86_64';
  {$endif CPUAARCH64}
  {$else}
  Result := 'linux-x86_64';
  {$endif OSDARWIN}
  {$endif OSWINDOWS}
end;

function RunCase(const AMethod, ABody, AExpected: RawUtf8): Boolean;
var
  Call: TRestUriParams;
begin
  Call.Init('root/Cap3UCurrency.' + AMethod, 'POST',
    JSON_CONTENT_TYPE_HEADER, ABody);
  Call.RestAccessRights := @SUPERVISOR_ACCESS_RIGHTS;
  Include(Call.LowLevelConnectionFlags, llfInProcess);
  UniqueRawUtf8(Call.InBody); // Uri() parses this buffer in place
  GServer.Uri(Call);
  Result := (Call.OutStatus = HTTP_SUCCESS) and (Call.OutBody = AExpected);
  // the wrong answer is the interesting one: print it, always
  if not Result then
    WriteLn('CAP3UCUR detail ', AMethod, ' status=', Call.OutStatus,
      ' body=', Call.OutBody, ' expected=', AExpected);
end;

// one line of the expectation table, split on TAB by hand: the table has
// three columns and a fixed vocabulary, and a general CSV reader would bring
// quoting and trimming rules this file does not want.
function SplitTabs(const ALine: RawUtf8; out A, B, C: RawUtf8): Boolean;
var
  i, first, second: Integer;
begin
  Result := False;
  first := 0;
  second := 0;
  for i := 1 to Length(ALine) do
    if ALine[i] = #9 then
      if first = 0 then
        first := i
      else if second = 0 then
        second := i
      else
        exit; // a fourth column is a table this reader does not understand
  if (first = 0) or (second = 0) then
    exit;
  A := Copy(ALine, 1, first - 1);
  B := Copy(ALine, first + 1, second - first - 1);
  C := Copy(ALine, second + 1, Length(ALine) - second);
  Result := (A <> '') and (B <> '') and (C <> '');
end;

function IndexOfText(const AValue: RawUtf8; const AList: array of RawUtf8): Integer;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if AList[i] = AValue then
      exit(i);
  Result := -1;
end;

function ReadExpectations(const ARoot: TFileName; const ATarget: RawUtf8;
  out AKind: array of RawUtf8): Boolean;
var
  text, line, a, b, c: RawUtf8;
  p, len, start: Integer;
  i, j, ti, ci: Integer;
  covered: array[0 .. TARGET_COUNT - 1, 0 .. CASE_COUNT - 1] of Boolean;
  mine: array[0 .. CASE_COUNT - 1] of Boolean;
begin
  Result := False;
  text := StringFromFile(ARoot + StringReplace(EXPECTATIONS, '/', PathDelim,
    [rfReplaceAll]));
  if text = '' then
  begin
    WriteLn('CAP3UCUR: ', EXPECTATIONS, ' is missing or empty');
    exit;
  end;
  for i := 0 to TARGET_COUNT - 1 do
    for j := 0 to CASE_COUNT - 1 do
      covered[i, j] := False;
  for i := 0 to CASE_COUNT - 1 do
    mine[i] := False;

  len := Length(text);
  start := 1;
  for p := 1 to len + 1 do
    if (p = len + 1) or (text[p] = #10) then
    begin
      line := Copy(text, start, p - start);
      start := p + 1;
      while (line <> '') and (line[Length(line)] = #13) do
        SetLength(line, Length(line) - 1);
      if (line = '') or (line[1] = '#') then
        continue;
      if not SplitTabs(line, a, b, c) then
      begin
        WriteLn('CAP3UCUR: malformed expectation row: ', line);
        exit;
      end;
      if a = 'target' then
        continue; // the header row
      if (c <> 'must_pass') and (c <> 'observe') then
      begin
        WriteLn('CAP3UCUR: unknown expectation "', c, '" in row: ', line);
        exit;
      end;
      ti := IndexOfText(a, TARGETS);
      ci := IndexOfText(b, CASE_NAMES);
      if (ti < 0) or (ci < 0) then
      begin
        WriteLn('CAP3UCUR: row names an unknown target or case: ', line);
        exit;
      end;
      if covered[ti, ci] then
      begin
        WriteLn('CAP3UCUR: duplicate expectation row: ', line);
        exit;
      end;
      covered[ti, ci] := True;
      if a <> ATarget then
        continue;
      AKind[ci] := c;
      mine[ci] := True;
    end;

  // A TABLE THAT DOES NOT COVER A TARGET IS A TARGET NOBODY OBSERVES. The
  // completeness check is over all four, not just this one, so dropping a
  // target's rows fails on every leg rather than going unnoticed on three.
  for i := 0 to TARGET_COUNT - 1 do
    for j := 0 to CASE_COUNT - 1 do
      if not covered[i, j] then
      begin
        WriteLn('CAP3UCUR: ', EXPECTATIONS, ' does not cover ', TARGETS[i],
          '/', CASE_NAMES[j]);
        exit;
      end;
  for i := 0 to CASE_COUNT - 1 do
    if not mine[i] then
    begin
      WriteLn('CAP3UCUR: no expectation for ', ATarget, '/', CASE_NAMES[i]);
      exit;
    end;
  Result := True;
end;

var
  Factory: TServiceFactoryServerAbstract;
  Root: TFileName;
  Target, Verdict: RawUtf8;
  Kind: array[0 .. CASE_COUNT - 1] of RawUtf8;
  Passed: array[0 .. CASE_COUNT - 1] of Boolean;
  Failures, Observed, i: Integer;
  CorpusPath: TFileName;
begin
  Failures := 0;
  Observed := 0;
  Target := ThisTarget;
  Root := RepoRootFromExecutable;
  if Root = '' then
  begin
    WriteLn('CAP3UCUR: the repository root was not found from ',
      Executable.ProgramFilePath);
    Halt(1);
  end;
  if not ReadExpectations(Root, Target, Kind) then
    Halt(1);

  GServer := TRestServerFullMemory.CreateWithOwnModel([]);
  try
    Factory := GServer.ServiceRegister(TCap3UCurrency,
      [TypeInfo(ICap3UCurrency)], sicShared);
    if Factory = nil then
      raise Exception.Create('unable to register ICap3UCurrency');
    Passed[0] := RunCase('CurZero', 'null', '{"result":[1234.5678]}');
    Passed[1] := RunCase('CurOneInt', '{"A":41}', '{"result":[41.5]}');
    Passed[2] := RunCase('CurOneCur', '{"V":21.25}', '{"result":[42.5]}');
    Passed[3] := RunCase('CurOneDouble', '{"V":21.25}', '{"result":[42.5]}');
    Passed[4] := RunCase('CurTwoInt', '{"A":4,"B":2}', '{"result":[402.25]}');
  finally
    GServer.Free;
  end;

  GCorpus := 'schema=1'#10 + 'target=' + Target + #10;
  for i := 0 to CASE_COUNT - 1 do
  begin
    if Passed[i] then
      Verdict := 'PASS'
    else
      Verdict := 'FAIL';
    GCorpus := GCorpus + CASE_NAMES[i] + '=' + Verdict + ',' + Kind[i] + #10;
    WriteLn('CAP3UCUR ', Target, ' ', CASE_NAMES[i], ' ', Verdict,
      ' (', Kind[i], ')');
    if Kind[i] = 'must_pass' then
    begin
      if not Passed[i] then
        Inc(Failures);
    end
    else
      Inc(Observed);
  end;
  if Failures = 0 then
    GCorpus := GCorpus + 'verdict=PASS'#10
  else
    GCorpus := GCorpus + 'verdict=FAIL'#10;

  CorpusPath := Root + StringReplace(CORPUS, '/', PathDelim, [rfReplaceAll]);
  if not DirectoryExists(ExtractFilePath(CorpusPath)) then
    ForceDirectories(ExtractFilePath(CorpusPath));
  FileFromString(GCorpus, CorpusPath);

  WriteLn('CAP3UCUR: ', Target, ' ', CASE_COUNT - Observed, ' gated, ',
    Observed, ' observed, ', Failures, ' gated failure(s)');
  if Failures = 0 then
  begin
    WriteLn('CAP3UCUR: PASS');
    Halt(0);
  end;
  WriteLn('CAP3UCUR: FAIL');
  Halt(1);
end.
