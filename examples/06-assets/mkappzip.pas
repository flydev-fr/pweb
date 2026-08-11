program mkappzip;

{ Builds the CAP-4 test package app.zip from a frontend/dist folder.

    mkappzip <distdir> <out.zip>

  Deterministic by construction: exactly the canonical frontend
  corpus, fixed order, canonical forward-slash entry names, mORMot
  TZipWrite. Fails loudly if any expected file is missing. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.zip;

const
  // canonical logical names, identical to their browser-visible
  // pweb://app/... paths
  CORPUS: array[0..2] of string = (
    'index.html',
    'assets/app.css',
    'assets/app.js');
  // fixed DOS timestamp (1980-01-01 00:00) so identical input bytes
  // yield identical archive bytes; TZipWrite's default FileAge of 0
  // would embed the current time on every build
  FIXED_FILE_AGE = $00210000;

var
  distDir, outZip, native: TFileName;
  zw: TZipWrite;
  i, j: PtrInt;
  content: RawByteString;
begin
  ExitCode := 0;
  try
    if ParamCount <> 2 then
      raise Exception.Create('usage: mkappzip <distdir> <out.zip>');
    distDir := ExcludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
    outZip := ExpandFileName(ParamStr(2));
    DeleteFile(outZip);
    zw := TZipWrite.Create(outZip);
    try
      for i := 0 to High(CORPUS) do
      begin
        native := CORPUS[i];
        for j := 1 to Length(native) do
          if native[j] = '/' then
            native[j] := PathDelim;
        native := distDir + PathDelim + native;
        if not FileExists(native) then
          raise Exception.CreateFmt('missing frontend file: %s', [native]);
        content := StringFromFile(native);
        // an unreadable (locked/denied) file also yields '' - verify
        // against the real size so it fails the build instead of
        // silently packaging an empty asset
        if Int64(Length(content)) <> FileSize(native) then
          raise Exception.CreateFmt('unreadable frontend file: %s', [native]);
        zw.AddDeflated(CORPUS[i], pointer(content), Length(content),
          {CompressLevel=}6, FIXED_FILE_AGE);
      end;
    finally
      zw.Free;
    end;
    WriteLn('mkappzip: ', outZip, ' (', Length(CORPUS), ' entries)');
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
