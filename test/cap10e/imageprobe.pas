program imageprobe;

{ CAP-10E: what THIS process's own image path is, asked three ways, printed
  as exact bytes.

  It exists for three legs of the shard's evidence and for one measurement
  that has to survive being read a year from now:

    E9  the CLI's own image resolution (PWebCliImageDir) is the SAME RULE as
        the shipped hosts' (PWebImageDir), not a twin that happens to agree
        today - so both are asked here, in one process, and compared BYTE
        for byte on all four targets.
    E1  `image_path_source=kernel` on every target.
    --  the DEFECT itself, kept measurable after it is fixed: the RTL's
        answer (Executable.ProgramFilePath, i.e. ExpandFileName(ParamStr(0)))
        is printed beside the kernel's, and `rtl_equals_kernel` is an
        OBSERVATION rather than a gate. It is false exactly where the defect
        lives - a non-ASCII path on Windows - and that is the whole point:
        the row lets a reader see the mangling instead of taking a
        changelog's word for it.

  The rows go to stdout as RAW UTF-8 BYTES through one FileWrite on the
  standard output handle, never through WriteLn: the console layer is
  another encoding conversion, and an encoding conversion is the thing under
  test here. The caller redirects stdout to a file and reads the bytes.

  image_dir_hex is what makes the macOS question answerable rather than
  arguable: HFS+ normalised filenames to NFD and APFS preserves whatever
  composition it was given, so the only honest way to record what a macOS
  kernel hands back for a decomposed directory name is the bytes. }

{$mode ObjFPC}{$H+}
{$apptype console}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.os,
  pweb.imagepath,
  pweb.cli.platform;

var
  Rows: RawUtf8 = '';

procedure Row(const Name, Value: RawUtf8);
begin
  Rows := Rows + Name + '=' + Value + #10;
end;

function Bool(Value: Boolean): RawUtf8;
begin
  if Value then
    Result := 'true'
  else
    Result := 'false';
end;

function HasNonAscii(const Value: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  for i := 1 to Length(Value) do
    if Ord(Value[i]) > 127 then
      exit(True);
  Result := False;
end;

function Hex(const Value: RawUtf8): RawUtf8;
var
  i: PtrInt;
const
  DIGITS: array[0 .. 15] of AnsiChar = '0123456789abcdef';
begin
  SetLength(Result, Length(Value) * 2);
  for i := 1 to Length(Value) do
  begin
    Result[i * 2 - 1] := DIGITS[Ord(Value[i]) shr 4];
    Result[i * 2] := DIGITS[Ord(Value[i]) and 15];
  end;
end;

var
  imageFile, imageDir, rtlDir, cliDir, cliExeDir: RawUtf8;
  ok: Boolean;
begin
  // the four answers, in one process, at one moment
  imageFile := StringToUtf8(PWebImageFile);
  imageDir := StringToUtf8(PWebImageDir);
  rtlDir := StringToUtf8(Executable.ProgramFilePath);
  if not PWebCliImageDir(cliDir) then
    cliDir := '';
  if not PWebCliExeDir(cliExeDir) then
    cliExeDir := '';

  Row('schema', '1');
  Row('image_path_source', 'kernel');
  Row('image_file', imageFile);
  Row('image_dir', imageDir);
  Row('image_dir_len', RawUtf8(IntToStr(Length(imageDir))));
  Row('image_dir_non_ascii', Bool(HasNonAscii(imageDir)));
  Row('image_dir_hex', Hex(imageDir));
  Row('cli_image_dir', cliDir);
  Row('cli_equals_helper', Bool((cliDir <> '') and (cliDir = imageDir)));
  // the CLI's CANONICAL answer, which is its image dir put through
  // GetFinalPathNameByHandleW / an O_DIRECTORY fd. Recorded as an
  // observation: canonicalisation is the CLI's own extra step and may
  // legitimately re-spell the path (case, a resolved junction), so this row
  // says what it did rather than demanding that it did nothing
  Row('cli_exe_dir', cliExeDir);
  Row('cli_exe_dir_equals_image_dir', Bool((cliExeDir <> '') and
    (cliExeDir = imageDir)));
  // the defect, kept visible: not a gate, an observation
  Row('rtl_program_file_path', rtlDir);
  Row('rtl_equals_kernel', Bool(rtlDir = imageDir));
  Row('rtl_non_ascii', Bool(HasNonAscii(rtlDir)));

  // the probe PASSES when the kernel answered and the CLI agrees with the
  // helper. It deliberately does NOT require the RTL to agree: on a
  // non-ASCII Windows path it cannot, which is why this shard exists
  ok := (imageFile <> '') and
        (imageDir <> '') and
        (cliDir <> '') and
        (cliDir = imageDir);
  if ok then
    Row('verdict', 'PASS')
  else
    Row('verdict', 'FAIL');

  FileWrite(StdOutputHandle, pointer(Rows)^, Length(Rows));
  if ok then
    ExitCode := 0
  else
    ExitCode := 1;
end.
