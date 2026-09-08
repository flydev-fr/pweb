program cap3u_currency;

{ CAP-3U Currency return matrix, over the PRISTINE PINNED dependency, on all
  four targets.

  WHY THIS EXISTS. Upstream 790154af ("core: ensure imvCurrency is returned in
  rax on x86-64", 2026-08-12) removed the `cmp cl, imvCurrency / je @d` pair
  from mORMot's CallMethod, so an interface-based service returning Currency
  now takes its result from RAX rather than from XMM0. That asm block is
  shared by the WHOLE x64 ABI - Win64 and SysV alike - and it was written for
  the Win64 half. The 2026-09-08 pin move MEASURED what it does on each:

    windows-x86_64  5/5 at the new pin, 0/5 at the old one unpatched, 5/5 at
                    the old one with the removed CAP-3U patch. Fixed, and the
                    reason the patch could go.
    linux-x86_64    1/5 at the new pin, 0/5 at the old one: only the
                    no-argument case is right, and the four with arguments
                    read a leftover pointer out of RAX. BROKEN AT BOTH PINS -
                    the pin move improves it and cannot have caused it.
                    (Measured under FPC 3.2.3; the hosted leg builds with the
                    distro 3.2.2, which is why the Linux rows are `observe`
                    rather than a prediction dressed up as a gate.)
    macos-x86_64    unmeasured - shares ABISYSVX64 with Linux, so the same
                    question, but a question is not an answer.
    macos-arm64     unmeasured - AAPCS64 is a DIFFERENT ABI with its own
                    CallMethod, so nothing about Linux predicts it.

  WHAT THIS PROGRAM IS. A typed observation, not a verdict. It runs the five
  cases, prints what each one did, and holds the run to
  `test/cap3u/currency-expectations.tsv` - which declares `must_pass` only
  where a PASS has actually been measured on the toolchain the leg uses, and
  `observe` everywhere else. An `observe` row records; it never fails a leg.
  Ratifying an `observe` into a `must_pass` is a deliberate act, taken once a
  hosted run has measured it.

  PWeb's own bridge is NOT changed by any of this. `SupportedInputType` in
  src/rpc/pweb.rpc.mormot.pas accepts `imvCurrency`, so a service that returns
  Currency is inside the supported surface and is documented as a known
  limitation of this pin on SysV x64 - it is not worked around here, because a
  workaround in the bridge would hide the defect from the report that should
  fix it upstream. }

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
