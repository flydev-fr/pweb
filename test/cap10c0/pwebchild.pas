program pwebchild;

{ CAP-10C0 supervision fixture: a deliberately badly behaved child process.

  The supervision engine claims things that a well-behaved application never
  exercises, so this fixture exercises them on purpose:

    exit <code>        exits with exactly that code, printing nothing (S1)
    argv               prints its own argv[1..] as ONE JSON array on stdout,
                       so the caller can prove every byte arrived verbatim,
                       newlines included, without a shell having touched it
                       (S3)
    flood <bytes>      writes at least that many bytes to STDOUT in short
                       lines, far past any pipe buffer (S5)
    floodstderr <n>    the same on STDERR (S6)
    lines <n> <len>    writes n lines of exactly len 'x' bytes to stdout and
                       n lines of len 'y' bytes to stderr, interleaved, each
                       numbered, so per-stream ORDER and the line bound can
                       be checked (S7)
    sleep <ms>         sleeps, then exits 0 (S8 in the probe profile)
    forever            sleeps forever; exits only when killed (S9/S10/S11)
    stubborn           IGNORES the graceful stop - SIGTERM is set to SIG_IGN
                       on POSIX, and on Windows it simply has no window for
                       a WM_CLOSE to reach - and then sleeps forever, so the
                       forced path is the only way out (S8/S9)
    spawn              starts a COPY of itself in `forever` mode, prints the
                       grandchild's pid, and exits 0 at once - so whatever
                       survives is a grandchild the tree must still own (S10)
    tail               prints one line, then a final fragment on each
                       stream WITHOUT a newline, and exits 0 (S7)
    cwd                prints its working directory (S17)
    env <NAME>         prints `set` or `unset` for that variable (S18)
    envnames           prints every environment variable NAME it received,
                       one per line, never a value (S18)
    die                POSIX: raises SIGABRT against itself so the death is
                       by signal; Windows: exits 3 (S2)
    ctrlbreak <pid>    Windows: attaches to that process's console and
                       delivers Ctrl+C to it, as a terminal would - the R10
                       driver; POSIX: sends SIGINT to the pid

  With NO argument the mode is read from PWEBCHILD_MODE, so a copy of this
  program standing in for a built application (which `pweb run` starts with
  an empty argument vector) can be told to be stubborn or to die - the way
  the run command's forced and signalled categories are measured end to end.

  It reads nothing from stdin on purpose: a child that blocked on input would
  make the timeout test pass for the wrong reason.

  Deliberately RTL-only: no mORMot, no PWeb unit. A fixture that shared code
  with the thing it tests would be measuring the code against itself. }

{$mode ObjFPC}{$H+}

{$ifdef WINDOWS}
  {$apptype console}
{$endif WINDOWS}

uses
  {$ifdef WINDOWS}
  windows,
  {$else}
  baseunix,
  unix,
  {$endif WINDOWS}
  sysutils;

// a minimal JSON string escaper: quotes, backslashes and control bytes
// escaped, everything else passed through as the UTF-8 it already is
function JsonString(const S: RawByteString): RawByteString;
var
  i: Integer;
  c: Char;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if c < ' ' then
        Result := Result + '\u' + IntToHex(Ord(c), 4)
      else
        Result := Result + c;
    end;
  end;
  Result := Result + '"';
end;

{$ifdef WINDOWS}
// the C runtime's parser, which is what the supervisor's quoting targets
function CommandLineToArgvW(lpCmdLine: PWideChar;
  var pNumArgs: Integer): PPWideChar;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

function ArgW(Index: Integer): RawByteString;
var
  argv: PPWideChar;
  n: Integer;
  p: PPWideChar;
begin
  // the C runtime's own split, converted to UTF-8, so the round trip is
  // measured against the parser the supervisor's quoting targets
  Result := '';
  n := 0;
  argv := CommandLineToArgvW(GetCommandLineW, n);
  if argv = nil then
    exit;
  try
    if Index < n then
    begin
      p := argv;
      Inc(p, Index);
      Result := RawByteString(UTF8Encode(WideString(p^)));
    end;
  finally
    LocalFree(HLOCAL(argv));
  end;
end;

function ArgCount: Integer;
var
  argv: PPWideChar;
  n: Integer;
begin
  n := 0;
  argv := CommandLineToArgvW(GetCommandLineW, n);
  if argv <> nil then
    LocalFree(HLOCAL(argv));
  Result := n - 1;
end;
{$else}
function ArgW(Index: Integer): RawByteString;
begin
  Result := RawByteString(ParamStr(Index));
end;

function ArgCount: Integer;
begin
  Result := ParamCount;
end;
{$endif WINDOWS}

procedure SleepForever;
begin
  repeat
    Sleep(1000);
  until False;
end;

var
  mode, json: RawByteString;
  n, len, i, total: Int64;
  chunk: string;
  written: Int64;
  {$ifdef WINDOWS}
  si: TStartupInfoW;
  pi: TProcessInformation;
  cmd: UnicodeString;
  pid: DWORD;
  {$else}
  pid: pid_t;
  self, forever: RawByteString;
  childArgv: array[0 .. 2] of PAnsiChar;
  {$endif WINDOWS}
begin
  if ArgCount < 1 then
  begin
    // no argument: the mode may come from PWEBCHILD_MODE, so a copy of this
    // fixture standing in for a built application - which `pweb run`
    // launches with NO argument - can still be told how to misbehave
    mode := RawByteString(GetEnvironmentVariable('PWEBCHILD_MODE'));
    if mode = '' then
    begin
      WriteLn(StdErr, 'pwebchild: no mode');
      ExitCode := 64;
      exit;
    end;
  end
  else
    mode := ArgW(1);
  if mode = 'exit' then
    ExitCode := StrToIntDef(ArgW(2), 1)
  else if mode = 'argv' then
  begin
    // assembled as BYTES and written untagged: a code-page-tagged string
    // would be transcoded by the text layer on its way out, which is how
    // an argument that arrived intact can still be printed double-encoded
    json := '[';
    for i := 2 to ArgCount do
    begin
      if i > 2 then
        json := json + ',';
      json := json + JsonString(ArgW(i));
    end;
    json := json + ']' + #10;
    SetCodePage(json, CP_NONE, False);
    Write(json);
    ExitCode := 0;
  end
  else if (mode = 'flood') or
          (mode = 'floodstderr') then
  begin
    n := StrToInt64Def(ArgW(2), 1 shl 20);
    chunk := StringOfChar('x', 63);
    written := 0;
    while written < n do
    begin
      if mode = 'flood' then
        WriteLn(chunk)
      else
        WriteLn(StdErr, chunk);
      Inc(written, 64);
    end;
    ExitCode := 0;
  end
  else if mode = 'lines' then
  begin
    n := StrToInt64Def(ArgW(2), 10);
    len := StrToInt64Def(ArgW(3), 10);
    for i := 1 to n do
    begin
      WriteLn('o', i, ':', StringOfChar('x', len));
      WriteLn(StdErr, 'e', i, ':', StringOfChar('y', len));
    end;
    ExitCode := 0;
  end
  else if mode = 'sleep' then
  begin
    Sleep(StrToInt64Def(ArgW(2), 1000));
    ExitCode := 0;
  end
  else if mode = 'forever' then
  begin
    // flushed explicitly: a process that never exits never flushes its
    // buffered stdout on its own, and the announcement is what a driver
    // waits for (MEASURED on Linux: without it the line never left)
    WriteLn('forever ', GetProcessID);
    Flush(Output);
    SleepForever;
  end
  else if mode = 'stubborn' then
  begin
    {$ifndef WINDOWS}
    FpSignal(SIGTERM, SignalHandler(SIG_IGN));
    FpSignal(SIGINT, SignalHandler(SIG_IGN));
    FpSignal(SIGHUP, SignalHandler(SIG_IGN));
    {$endif WINDOWS}
    WriteLn('stubborn ', GetProcessID);
    Flush(Output);
    SleepForever;
  end
  else if mode = 'spawn' then
  begin
    {$ifdef WINDOWS}
    FillChar(si, SizeOf(si), 0);
    si.cb := SizeOf(si);
    FillChar(pi, SizeOf(pi), 0);
    cmd := '"' + UnicodeString(ParamStr(0)) + '" forever';
    UniqueString(cmd);
    if CreateProcessW(nil, PWideChar(cmd), nil, nil, False, 0, nil, nil,
         si, pi) then
    begin
      pid := pi.dwProcessId;
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      WriteLn('grandchild ', pid);
      ExitCode := 0;
    end
    else
    begin
      WriteLn(StdErr, 'pwebchild: spawn failed ', GetLastError);
      ExitCode := 70;
    end;
    {$else}
    self := ParamStr(0);
    forever := 'forever';
    childArgv[0] := PAnsiChar(self);
    childArgv[1] := PAnsiChar(forever);
    childArgv[2] := nil;
    pid := FpFork;
    if pid = 0 then
    begin
      FpExecv(PAnsiChar(self), PPAnsiChar(@childArgv[0])); // never returns
      FpExit(70);
    end;
    if pid > 0 then
    begin
      WriteLn('grandchild ', pid);
      ExitCode := 0;
    end
    else
    begin
      WriteLn(StdErr, 'pwebchild: fork failed');
      ExitCode := 70;
    end;
    {$endif WINDOWS}
  end
  else if mode = 'tail' then
  begin
    // a last line on each stream WITHOUT its newline, as a crash message
    // commonly ends: the supervisor must still deliver both, once each
    WriteLn('head');
    Write('tail-out');
    Write(StdErr, 'tail-err');
    ExitCode := 0;
  end
  else if mode = 'cwd' then
  begin
    WriteLn(GetCurrentDir);
    ExitCode := 0;
  end
  else if mode = 'env' then
  begin
    if GetEnvironmentVariable(ArgW(2)) <> '' then
      WriteLn('set')
    else
      WriteLn('unset');
    ExitCode := 0;
  end
  else if mode = 'envnames' then
  begin
    // every variable NAME this process received, one per line, so the
    // caller can prove the environment arrived unchanged - nothing added,
    // nothing removed. Values are never printed.
    for i := 1 to GetEnvironmentVariableCount do
    begin
      chunk := GetEnvironmentString(i);
      n := Pos('=', chunk);
      if n > 1 then
        WriteLn(Copy(chunk, 1, n - 1));
    end;
    ExitCode := 0;
  end
  else if mode = 'die' then
  begin
    {$ifdef WINDOWS}
    ExitCode := 3;
    {$else}
    FpKill(FpGetPid, SIGABRT);
    Sleep(1000);
    ExitCode := 3; // unreachable when the signal did its job
    {$endif WINDOWS}
  end
  else if mode = 'ctrlbreak' then
  begin
    {$ifdef WINDOWS}
    pid := StrToIntDef(ArgW(2), 0);
    FreeConsole;
    if not AttachConsole(pid) then
    begin
      WriteLn(StdErr, 'pwebchild: AttachConsole failed ', GetLastError);
      ExitCode := 71;
      exit;
    end;
    // this process must not act on the event it is about to raise.
    // CTRL_C to EVERY process attached to that console - exactly what a
    // terminal delivers: the supervisor handles it, the application and
    // its browser processes were created in a new group and ignore it
    SetConsoleCtrlHandler(nil, True);
    if GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) then
      ExitCode := 0
    else
    begin
      WriteLn(StdErr, 'pwebchild: GenerateConsoleCtrlEvent failed ',
        GetLastError);
      ExitCode := 72;
    end;
    {$else}
    pid := StrToIntDef(ArgW(2), 0);
    if FpKill(pid, SIGINT) = 0 then
      ExitCode := 0
    else
      ExitCode := 72;
    {$endif WINDOWS}
  end
  else
  begin
    WriteLn(StdErr, 'pwebchild: unknown mode ', mode);
    ExitCode := 64;
  end;
end.
