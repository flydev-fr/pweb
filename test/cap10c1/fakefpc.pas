program fakefpc;

{ CAP-10C1: a compiler that is not one.

  It answers every question with version 1.0.0 and exits 0, and it exists so
  two refusals can be MEASURED rather than argued:

    TC2  a toolchain whose version does not satisfy the pin is refused with
         the doctor's own cause, at stage 2, BEFORE the pipeline writes
         anything at all;
    TC3  a candidate that resolves INSIDE the project root is reported with
         its path and NEVER EXECUTED - which is only provable with something
         that would be loud if it ran.

  So it also writes a marker file when it is executed, named by
  PWEBFAKE_MARKER. The gate asserts the marker is ABSENT after the
  inside-the-project leg: an assertion that the binary was not run, made by
  the binary itself.

  RTL-only by design: a fixture that shared code with the thing it tests
  would be measuring the code against itself. }

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

{$mode ObjFPC}{$H+}

uses
  sysutils;

var
  marker: string;
  f: TextFile;

begin
  marker := GetEnvironmentVariable('PWEBFAKE_MARKER');
  if marker <> '' then
    try
      AssignFile(f, marker);
      Rewrite(f);
      WriteLn(f, 'executed');
      CloseFile(f);
    except
      { a fixture that cannot record its own execution must still answer }
    end;
  WriteLn('1.0.0');
  ExitCode := 0;
end.
