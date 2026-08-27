program probechild;

{ CAP-10A probe fixture: a deliberately badly behaved child process.

  The CLI's probe runner claims four things that cannot be proven against a
  well-behaved tool, because a well-behaved tool never exercises them:

    version <text>   answers on stdout and exits 0 - the ordinary shape
    exit <code>      answers nothing and exits nonzero
    sleep <ms>       answers nothing and outstays the bound, so the runner
                     has to terminate and reap it (D6)
    flood <bytes>    writes more to STDOUT than the runner will keep, so the
                     capture ceiling and the deadlock-free drain are both
                     exercised at once (D7)
    floodstderr <n>  the same on STDERR, which is the stream a one-pipe
                     reader forgets and then deadlocks on (D8)
    argv             prints its own argv, one argument per line, so the
                     caller can prove the arguments arrived VERBATIM - no
                     shell split them, expanded them, or consumed them (D9)

  It reads nothing from stdin on purpose: a child that blocked on input would
  make the timeout test pass for the wrong reason.

  Deliberately RTL-only: no mORMot, no PWeb unit. A fixture that shared code
  with the thing it tests would be measuring the code against itself. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  sysutils;

var
  mode: string;
  n, i: Int64;
  chunk: string;
  written: Int64;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'probechild: no mode');
    ExitCode := 64;
    exit;
  end;
  mode := ParamStr(1);
  if mode = 'version' then
  begin
    if ParamCount >= 2 then
      WriteLn(ParamStr(2))
    else
      WriteLn('9.9.9');
    ExitCode := 0;
  end
  else if mode = 'exit' then
  begin
    ExitCode := StrToIntDef(ParamStr(2), 1);
  end
  else if mode = 'sleep' then
  begin
    n := StrToInt64Def(ParamStr(2), 1000);
    Sleep(n);
    ExitCode := 0;
  end
  else if (mode = 'flood') or
          (mode = 'floodstderr') then
  begin
    n := StrToInt64Def(ParamStr(2), 1 shl 20);
    // 64-byte lines: enough writes that the OS pipe buffer fills long
    // before the total, which is the condition a single-pipe reader
    // deadlocks on
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
  else if mode = 'argv' then
  begin
    for i := 1 to ParamCount do
      WriteLn(ParamStr(i));
    ExitCode := 0;
  end
  else
  begin
    WriteLn(StdErr, 'probechild: unknown mode ', mode);
    ExitCode := 64;
  end;
end.
