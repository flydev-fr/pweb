program geninc;

{ CAP-15B: the generated network include, produced by the PRODUCTION
  function, for the gate that compiles it.

  `pweb build` writes <output>/<target>/gen/app.network.inc from the
  descriptor and compiles it into the host. This program calls the same two
  production functions - PWebCliOpenProject and PWebCliNetworkInclude - so
  the bytes the gate's witness binary compiles are the bytes a real build
  would have compiled. A gate that hand-wrote that include would be a gate
  proving something about itself.

  It also prints the descriptor's own view of the origin set, which is what
  the "declared" half of `declared == compiled` is measured from.

  Usage: geninc --project=<dir> --out=<file> }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  pweb.cli.project,
  pweb.cli.native;

var
  i: Integer;
  a, projectDir, outPath: RawUtf8;
  p: TPWebCliProject;
begin
  ExitCode := 0;
  projectDir := '';
  outPath := '';
  for i := 1 to ParamCount do
  begin
    a := RawUtf8(ParamStr(i));
    if Copy(a, 1, 10) = '--project=' then
      projectDir := Copy(a, 11, MaxInt)
    else if Copy(a, 1, 6) = '--out=' then
      outPath := Copy(a, 7, MaxInt)
    else
    begin
      WriteLn(StdErr, 'geninc: unknown argument: ', a);
      Halt(2);
    end;
  end;
  if (projectDir = '') or (outPath = '') then
  begin
    WriteLn(StdErr, 'geninc: --project and --out are required');
    Halt(2);
  end;
  p := PWebCliOpenProject(projectDir, projectDir);
  WriteLn('refusal ', PWebCliProjectRefusalText(p.Refusal), ' ', p.Detail);
  if p.Refusal <> pcrNone then
    Halt(3);
  WriteLn('schema ', p.Schema);
  WriteLn('origins ', Length(p.NetworkOrigins));
  for i := 0 to High(p.NetworkOrigins) do
    WriteLn('origin ', p.NetworkOrigins[i]);
  for i := 0 to High(p.NetworkLoopback) do
    WriteLn('loopback ', p.NetworkLoopback[i]);
  WriteLn('digest ', p.NetworkOriginsDigest);
  if Length(p.NetworkOrigins) = 0 then
  begin
    // an empty set compiles NO include, because a build with no origins
    // defines no network region and reaches for none
    WriteLn('include none');
    exit;
  end;
  FileFromString(PWebCliNetworkInclude(p), Utf8ToString(outPath));
  WriteLn('include ', outPath);
end.
