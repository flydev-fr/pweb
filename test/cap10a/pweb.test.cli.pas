{
  pweb.test.cli - the CAP-10A suite over the pweb CLI (mormot.core.test).

  Four subjects, one file, all four targets:

    ARGS     the parser's whole refusal matrix (C1-C6), proved over an
             argument ARRAY rather than a process, so the same rows run
             identically everywhere and nothing depends on a shell;
    PROJECT  the descriptor and the path model (P1-P16), proved against
             REAL directories - including a real symlink on POSIX and a
             real NTFS junction on Windows, because a confinement rule
             tested against a mock is a rule about the mock;
    DOCTOR   the requirement graph and both emitters (D1-D5, D10-D11, C7-C9)
             over a fully INJECTED environment, so the healthy path, every
             distinct failure cause and the project-aware exclusions are
             reproducible without four broken machines;
    PROBE    the bounded, shell-free runner (D6-D9) against a deliberately
             badly behaved real child process.

  It also emits build/cap10a/cli-corpus.txt: every DECISION this suite made,
  as one LF line each. The CAP-7F evidence emitters hash that file into
  cli_digest and the aggregator requires the four targets to produce the same
  bytes. Every line is the verdict of platform-independent logic, so equality
  is a property rather than a hope - and the file deliberately carries no
  path, no version and no timing, because those are the three things that
  cannot be equal across four machines.
}

{$I mormot.defines.inc}

unit pweb.test.cli;

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.test,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.probe,
  pweb.cli.toolchain,
  pweb.cli.doctor,
  pweb.cli.report,
  pweb.cli.args;

type
  TTestPWebCliArgs = class(TSynTestCase)
  published
    procedure HelpAndVersion;
    procedure UnknownAndDuplicate;
    procedure OptionValues;
    procedure PositionalsAndInjection;
    procedure ArgumentEncoding;
  end;

  TTestPWebCliProject = class(TSynTestCase)
  published
    procedure ValidDescriptor;
    procedure MalformedAndStrictJson;
    procedure SchemaAndFieldRules;
    procedure IdentifierGrammars;
    procedure PathSyntaxRefusals;
    procedure PathConfinement;
    procedure ExactCase;
    procedure Discovery;
    procedure CwdCannotRedirect;
  end;

  TTestPWebCliDoctor = class(TSynTestCase)
  published
    procedure HealthyEnvironment;
    procedure RequiredToolMissing;
    procedure MalformedVersion;
    procedure WrongVersion;
    procedure OptionalGapIsWarning;
    procedure ProjectAwareRequirements;
    procedure ProjectRefusalIsReported;
    procedure BothProjectionsAgree;
    procedure JsonIsCanonical;
    procedure HumanCarriesNoAnsiWhenRedirected;
  end;

  TTestPWebCliProbe = class(TSynTestCase)
  published
    procedure BoundedTimeout;
    procedure StdOutSaturation;
    procedure StdErrSaturation;
    procedure ArgumentsAreNotInterpreted;
    procedure PathResolutionRules;
  end;

const
  /// the file the CAP-7F emitters hash into cli_digest - ONE spelling
  PWEB_CAP10A_CORPUS_FILE = 'build/cap10a/cli-corpus.txt';

implementation

{$ifdef WINDOWS}
uses
  windows;
{$else}
uses
  baseunix;
{$endif WINDOWS}

var
  /// every decision this suite made, in emission order
  Corpus: TRawUtf8DynArray;

procedure Record_(const Line: RawUtf8);
begin
  SetLength(Corpus, Length(Corpus) + 1);
  Corpus[High(Corpus)] := Line;
end;

{ ---------------------------------------------------------------------------
  fixture plumbing
  --------------------------------------------------------------------------- }

{$ifdef WINDOWS}
const
  IO_REPARSE_TAG_MOUNT_POINT = $A0000003;
  FSCTL_SET_REPARSE_POINT = $000900A4;
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;

type
  TMountPointReparseBuffer = record
    ReparseTag: DWord;
    ReparseDataLength: Word;
    Reserved: Word;
    SubstituteNameOffset: Word;
    SubstituteNameLength: Word;
    PrintNameOffset: Word;
    PrintNameLength: Word;
    PathBuffer: array[0 .. 1023] of WideChar;
  end;

// a real NTFS junction through the documented reparse-point control code.
// It needs no privilege, unlike a symlink, which is why the Windows half of
// the link-refusal fixture is a junction (the same technique
// test/platform/pweb.test.wv2fixed.pas uses, and for the same reason).
function MakeLink(const LinkDir, TargetDir: TFileName): Boolean;
var
  h: THandle;
  buf: TMountPointReparseBuffer;
  subst: UnicodeString;
  nameBytes: Word;
  returned, total: DWord;
begin
  Result := False;
  if not ForceDirectories(LinkDir) then
    exit;
  h := CreateFileW(PWideChar(Utf8ToSynUnicode(StringToUtf8(LinkDir))),
    GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h = INVALID_HANDLE_VALUE then
    exit;
  try
    subst := '\??\' + Utf8ToSynUnicode(StringToUtf8(
      ExcludeTrailingPathDelimiter(TargetDir)));
    FillChar(buf, SizeOf(buf), 0);
    buf.ReparseTag := IO_REPARSE_TAG_MOUNT_POINT;
    nameBytes := Length(subst) * 2;
    buf.SubstituteNameOffset := 0;
    buf.SubstituteNameLength := nameBytes;
    buf.PrintNameOffset := nameBytes + 2;
    buf.PrintNameLength := 0;
    Move(PWideChar(subst)^, buf.PathBuffer[0], nameBytes);
    buf.ReparseDataLength := 8 + nameBytes + 4;
    total := 8 + buf.ReparseDataLength;
    returned := 0;
    Result := DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, @buf, total,
      nil, 0, returned, nil);
  finally
    CloseHandle(h);
  end;
end;

function ProbeChildName: TFileName;
begin
  Result := 'probechild.exe';
end;
{$else}
function MakeLink(const LinkDir, TargetDir: TFileName): Boolean;
begin
  Result := FpSymlink(PAnsiChar(RawByteString(TargetDir)),
    PAnsiChar(RawByteString(LinkDir))) = 0;
end;

function ProbeChildName: TFileName;
begin
  Result := 'probechild';
end;
{$endif WINDOWS}

var
  FixtureRoot: TFileName;
  FixtureSeq: Integer;

// every fixture directory is CHECKED into existence. A fixture that
// silently failed to appear would make a confinement assertion pass for the
// wrong reason - "the path is not there" is the expected answer in half
// these rows, so an absent fixture looks exactly like a working refusal.
procedure MakeDir(const Dir: TFileName);
begin
  if DirectoryExists(Dir) then
    exit;
  if not ForceDirectories(Dir) then
    raise Exception.CreateFmt('CAP-10A fixture directory not created: %s',
      [Dir]);
  if not DirectoryExists(Dir) then
    raise Exception.CreateFmt('CAP-10A fixture directory vanished: %s',
      [Dir]);
end;

function NewFixture(const Tag: RawUtf8): TFileName;
begin
  if FixtureRoot = '' then
  begin
    FixtureRoot := IncludeTrailingPathDelimiter(GetSystemPath(spTemp)) +
      'pweb-cap10a-' + IntToStr(GetCurrentProcessId);
    MakeDir(FixtureRoot);
  end;
  Inc(FixtureSeq);
  Result := IncludeTrailingPathDelimiter(FixtureRoot) +
    Utf8ToString(Tag) + '-' + IntToStr(FixtureSeq);
  MakeDir(Result);
end;

const
  VALID_DESCRIPTOR: RawUtf8 =
    '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "name": "my-app",' + #10 +
    '  "version": "0.1.0",' + #10 +
    '  "bundleId": "com.example.myapp",' + #10 +
    '  "ui": "react",' + #10 +
    '  "native": { "program": "src/myapp.lpr" },' + #10 +
    '  "frontend": { "root": "frontend" },' + #10 +
    '  "output": "dist"' + #10 +
    '}' + #10;

// a complete, healthy project tree
function NewProject(const Tag: RawUtf8; const Descriptor: RawUtf8;
  out Root: RawUtf8): TFileName;
begin
  Result := NewFixture(Tag);
  MakeDir(IncludeTrailingPathDelimiter(Result) + 'src');
  MakeDir(IncludeTrailingPathDelimiter(Result) + 'frontend');
  FileFromString('program myapp;'#10'begin'#10'end.'#10,
    IncludeTrailingPathDelimiter(Result) + 'src' + PathDelim + 'myapp.lpr');
  FileFromString('{"name":"fixture","private":true}'#10,
    IncludeTrailingPathDelimiter(Result) + 'frontend' + PathDelim +
    'package.json');
  FileFromString('{"lockfileVersion":3}'#10,
    IncludeTrailingPathDelimiter(Result) + 'frontend' + PathDelim +
    'package-lock.json');
  if Descriptor <> '' then
    FileFromString(Descriptor,
      IncludeTrailingPathDelimiter(Result) + 'pweb.json');
  if not PWebCliCanonicalDir(RawUtf8(Result), Root) then
    Root := '';
end;

{ ---------------------------------------------------------------------------
  ARGS - C1..C6
  --------------------------------------------------------------------------- }

function Argv(const A: array of RawUtf8): TRawUtf8DynArray;
var
  i: PtrInt;
begin
  SetLength(Result, Length(A));
  for i := 0 to High(A) do
    Result[i] := A[i];
end;

procedure TTestPWebCliArgs.HelpAndVersion;
var
  a: TPWebCliArgs;
begin
  // C1
  a := PWebCliParseArgs(Argv(['--help']));
  Check(a.Usage = pcuNone, 'C1: --help accepted');
  Check(a.Help, 'C1: --help sets the request');
  Record_('args|--help|ok');
  // C2
  a := PWebCliParseArgs(Argv(['--version']));
  Check(a.Usage = pcuNone, 'C2: --version accepted');
  Check(a.Version, 'C2: --version sets the request');
  Record_('args|--version|ok');
  // the canonical version line is one line and names the protocol
  CheckEqual(PWebCliVersionLine, 'pweb ' + PWEB_CLI_VERSION +
    ' (protocol 1)', 'C2: the version line is exact');
  // help for a command is still help
  a := PWebCliParseArgs(Argv(['doctor', '--help']));
  Check(a.Usage = pcuNone, 'C1: doctor --help accepted');
  Check(a.Help and (a.Command = pccDoctor), 'C1: both are recorded');
  Record_('args|doctor --help|ok');
  // a bare invocation is a usage error, and it says which one
  a := PWebCliParseArgs(Argv([]));
  Check(a.Usage = pcuNoCommand, 'no command is refused');
  Record_('args||' + PWebCliUsageText(a.Usage));
end;

procedure TTestPWebCliArgs.UnknownAndDuplicate;
var
  a: TPWebCliArgs;
begin
  // C3. CAP-10B1 exposes `create`, so the case it makes here changed from
  // "unknown command" to "a command that needs its operand": a bare
  // `pweb create` is now a MISSING OPERAND, which is still a usage refusal
  // and still never a silent no-op. The three that follow are unchanged,
  // and they are the reason this case still exists.
  a := PWebCliParseArgs(Argv(['create']));
  Check(a.Usage = pcuMissingOperand,
    'C3: create needs its NAME, and says so rather than doing nothing');
  Record_('args|create|' + PWebCliUsageText(a.Usage));
  // CAP-10D0 exposes `build`, the last command of the CAP-10 surface, and
  // the corpus row moves from `unknown_command` to `ok` exactly as it moved
  // for `run` at CAP-10C0 and for `dev` at CAP-10C2 - a RECORDED
  // supersession of cli_digest, never a silent re-baseline. The six option
  // rows below are the whole of what `build` adds to this grammar: it takes
  // --project and --help and nothing else, and it introduces no usage cause
  // that did not already exist.
  a := PWebCliParseArgs(Argv(['build']));
  Check(a.Usage = pcuNone, 'C3: build is a command since CAP-10D0');
  Check(a.Command = pccBuild, 'C3: and it is the build command');
  Record_('args|build|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--project', 'p']));
  Check(a.Usage = pcuNone, 'C3: build takes --project');
  CheckEqual(a.ProjectPath, 'p', 'C3: and it captures its value');
  Record_('args|build --project p|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--project', 'p', '--project', 'q']));
  Check(a.Usage = pcuDuplicateOption, 'C3: build refuses a repeated --project');
  Record_('args|build --project twice|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--json']));
  Check(a.Usage = pcuOptionNotForCommand, 'C3: build has no machine report');
  Record_('args|build --json|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', 'extra']));
  Check(a.Usage = pcuExtraPositional, 'C3: build takes no operand');
  Record_('args|build extra|' + PWebCliUsageText(a.Usage));
  // CAP-10D1 RATIFIED `--profile`, and this row is the recorded
  // supersession: it read `unknown_option` for as long as the option's
  // semantics were unratified, which is the whole of why the absence was
  // measured rather than assumed. Everything ELSE a reader of another build
  // tool reaches for first is still an option this grammar does not have.
  a := PWebCliParseArgs(Argv(['build', '--profile', 'offline']));
  Check(a.Usage = pcuNone, 'D1: --profile is a build option');
  Check(a.Command = pccBuild, 'D1: on the build command');
  Check(a.Profile = 'offline', 'D1: carrying its value verbatim');
  Record_('args|build --profile offline|' + PWebCliUsageText(a.Usage));
  // the value discipline is --project's, and it is measured rather than
  // inherited: a missing value, a duplicate and an empty one each earn the
  // cause CAP-10A already had, which is why this shard adds no fourteenth
  a := PWebCliParseArgs(Argv(['build', '--profile']));
  Check(a.Usage = pcuMissingValue, 'D1: --profile needs a value');
  Record_('args|build --profile bare|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--profile=']));
  Check(a.Usage = pcuEmptyValue, 'D1: an empty --profile is refused');
  Record_('args|build --profile empty|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--profile', 'a', '--profile', 'b']));
  Check(a.Usage = pcuDuplicateOption, 'D1: --profile is not repeatable');
  Record_('args|build --profile twice|' + PWebCliUsageText(a.Usage));
  // and it belongs to `build` and to nothing else
  a := PWebCliParseArgs(Argv(['run', '--profile', 'archive']));
  Check(a.Usage = pcuOptionNotForCommand, 'D1: run has no --profile');
  Record_('args|run --profile|' + PWebCliUsageText(a.Usage));
  // THE ACCEPTED SET IS THE SAME ON FOUR TARGETS. The parser takes every
  // ratified name on every platform, because a parser whose accepted values
  // differed per platform is the divergence this contract forbids; whether
  // the HOST can build the profile is answered after parsing, with its own
  // typed cause
  a := PWebCliParseArgs(Argv(['build', '--profile', 'archive']));
  Check(a.Usage = pcuNone, 'D1: archive parses on every target');
  Record_('args|build --profile archive|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--profile', 'fixed-runtime']));
  Check(a.Usage = pcuNone, 'D1: fixed-runtime parses on every target');
  Record_('args|build --profile fixed-runtime|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--clean']));
  Check(a.Usage = pcuUnknownOption,
    'C3: every stage runs every time, so there is nothing to clean');
  Record_('args|build --clean|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['build', '--help']));
  Check(a.Usage = pcuNone, 'C3: build --help is a complete request');
  Check(a.Help, 'C3: and it asks for help');
  Check(a.Command = pccBuild, 'C3: for the build command');
  Record_('args|build --help|' + PWebCliUsageText(a.Usage));
  // CAP-10C2 exposes `dev`: a bare `pweb dev` is a complete command line
  // (the project is discovered from the working directory, exactly as `run`
  // discovers it), so the case it makes here changed from "unknown command"
  // to "accepted", and cli_digest is re-baselined as a RECORDED supersession
  // in the same way CAP-10C0 re-baselined it for `run`. What `dev` refuses
  // that `run` does not is a PROJECT fact - the declared frontend kind - and
  // no usage cause was added for it.
  a := PWebCliParseArgs(Argv(['dev']));
  Check(a.Usage = pcuNone, 'C3: dev is a command since CAP-10C2');
  Check(a.Command = pccDev, 'C3: and it is the dev command');
  Record_('args|dev|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', '--project', 'p']));
  Check(a.Usage = pcuNone, 'C3: dev takes --project');
  CheckEqual(a.ProjectPath, 'p', 'C3: and it captures its value');
  Record_('args|dev --project p|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', '--project', 'p', '--project', 'q']));
  Check(a.Usage = pcuDuplicateOption, 'C3: dev refuses a repeated --project');
  Record_('args|dev --project twice|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', '--json']));
  Check(a.Usage = pcuOptionNotForCommand, 'C3: dev has no machine report');
  Record_('args|dev --json|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', '--verbose']));
  Check(a.Usage = pcuOptionNotForCommand, 'C3: dev has no verbosity');
  Record_('args|dev --verbose|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', '--no-color']));
  Check(a.Usage = pcuOptionNotForCommand, 'C3: dev emits no colour');
  Record_('args|dev --no-color|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', 'extra']));
  Check(a.Usage = pcuExtraPositional, 'C3: dev takes no operand');
  Record_('args|dev extra|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['dev', '--help']));
  Check(a.Usage = pcuNone, 'C3: dev --help is a complete request');
  Check(a.Help, 'C3: and it asks for help');
  Check(a.Command = pccDev, 'C3: for the dev command');
  Record_('args|dev --help|' + PWebCliUsageText(a.Usage));
  // CAP-10C0 exposes `run`: a bare `pweb run` is a complete command line
  // (the project is discovered from the working directory), so the case it
  // makes here changed from "unknown command" to "accepted". The corpus
  // line moved with it, and cli_digest was re-baselined by the CAP-10C0
  // closure as a RECORDED supersession, exactly as CAP-10B1 recorded the
  // template corpus one
  a := PWebCliParseArgs(Argv(['run']));
  Check(a.Usage = pcuNone, 'C3: run is a command since CAP-10C0');
  Check(a.Command = pccRun, 'C3: and it is the run command');
  Record_('args|run|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['run', '--json']));
  Check(a.Usage = pcuOptionNotForCommand, 'C3: run has no machine report');
  Record_('args|run --json|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['run', 'extra']));
  Check(a.Usage = pcuExtraPositional, 'C3: run takes no operand');
  Record_('args|run extra|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['DOCTOR']));
  Check(a.Usage = pcuUnknownCommand, 'C3: commands are case-sensitive');
  Record_('args|DOCTOR|' + PWebCliUsageText(a.Usage));
  // C4
  a := PWebCliParseArgs(Argv(['doctor', '--bogus']));
  Check(a.Usage = pcuUnknownOption, 'C4: unknown option refused');
  CheckEqual(a.Detail, '--bogus', 'C4: the diagnostic names the token');
  Record_('args|doctor --bogus|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['doctor', '-j']));
  Check(a.Usage = pcuUnknownOption, 'C4: there are no short options');
  Record_('args|doctor -j|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['doctor', '--']));
  Check(a.Usage = pcuUnknownOption,
    'C4: -- is not an argument terminator in v1');
  Record_('args|doctor --|' + PWebCliUsageText(a.Usage));
  // C5
  a := PWebCliParseArgs(Argv(['doctor', '--json', '--json']));
  Check(a.Usage = pcuDuplicateOption, 'C5: duplicate flag refused');
  Record_('args|doctor --json --json|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['doctor', '--project', 'a', '--project', 'b']));
  Check(a.Usage = pcuDuplicateOption, 'C5: duplicate valued option refused');
  Record_('args|doctor --project a --project b|' +
    PWebCliUsageText(a.Usage));
  // an option that belongs to another command
  a := PWebCliParseArgs(Argv(['--json']));
  Check(a.Usage = pcuOptionNotForCommand,
    '--json without doctor is refused');
  Record_('args|--json|' + PWebCliUsageText(a.Usage));
end;

procedure TTestPWebCliArgs.OptionValues;
var
  a: TPWebCliArgs;
begin
  // C6
  a := PWebCliParseArgs(Argv(['doctor', '--project']));
  Check(a.Usage = pcuMissingValue, 'C6: a missing value is refused');
  Record_('args|doctor --project|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['doctor', '--project', '--json']));
  Check(a.Usage = pcuMissingValue,
    'C6: an option cannot be swallowed as a value');
  Record_('args|doctor --project --json|' + PWebCliUsageText(a.Usage));
  a := PWebCliParseArgs(Argv(['doctor', '--project=']));
  Check(a.Usage = pcuEmptyValue, 'C6: an empty value is refused');
  Record_('args|doctor --project=|' + PWebCliUsageText(a.Usage));
  // both accepted spellings, same meaning
  a := PWebCliParseArgs(Argv(['doctor', '--project', 'some/dir']));
  Check(a.Usage = pcuNone, 'separate-token value accepted');
  CheckEqual(a.ProjectPath, 'some/dir', 'the value is verbatim');
  Record_('args|doctor --project VALUE|ok');
  a := PWebCliParseArgs(Argv(['doctor', '--project=some/dir']));
  Check(a.Usage = pcuNone, 'inline value accepted');
  CheckEqual(a.ProjectPath, 'some/dir', 'the value is verbatim');
  Record_('args|doctor --project=VALUE|ok');
  // a flag never takes a value
  a := PWebCliParseArgs(Argv(['doctor', '--json=true']));
  Check(a.Usage = pcuUnknownOption, 'a flag with a value is not that flag');
  Record_('args|doctor --json=true|' + PWebCliUsageText(a.Usage));
  // the accepted full line
  a := PWebCliParseArgs(Argv(['doctor', '--json', '--no-color', '--verbose',
    '--with-paths', '--project=x']));
  Check(a.Usage = pcuNone, 'the full doctor line is accepted');
  Check(a.Json and a.NoColor and a.Verbose and a.WithPaths,
    'every flag is recorded');
  Record_('args|doctor full|ok');
end;

procedure TTestPWebCliArgs.PositionalsAndInjection;
var
  a: TPWebCliArgs;
begin
  a := PWebCliParseArgs(Argv(['doctor', 'extra']));
  Check(a.Usage = pcuExtraPositional, 'one positional only');
  Record_('args|doctor extra|' + PWebCliUsageText(a.Usage));
  // '/json' is a POSITIONAL on every platform. A Windows-only option
  // syntax would make one command line mean two things on two machines.
  a := PWebCliParseArgs(Argv(['/json']));
  Check(a.Usage = pcuUnknownCommand,
    'a slash form is never an option, on any platform');
  Record_('args|/json|' + PWebCliUsageText(a.Usage));
  // response files are not expanded: '@args.txt' is an ordinary token
  a := PWebCliParseArgs(Argv(['@args.txt']));
  Check(a.Usage = pcuUnknownCommand, 'a response file is never expanded');
  Record_('args|@args.txt|' + PWebCliUsageText(a.Usage));
  // shell metacharacters have no meaning to this parser at all
  a := PWebCliParseArgs(Argv(['doctor', '--project=a; rm -rf /']));
  Check(a.Usage = pcuNone, 'metacharacters are ordinary bytes');
  CheckEqual(a.ProjectPath, 'a; rm -rf /',
    'the value survives byte for byte');
  Record_('args|doctor --project=metachars|ok');
end;

procedure TTestPWebCliArgs.ArgumentEncoding;
var
  a: TPWebCliArgs;
  bad: TRawUtf8DynArray;
begin
  SetLength(bad, 2);
  bad[0] := 'doctor';
  bad[1] := '--project=' + #$C3; // a truncated UTF-8 sequence
  a := PWebCliParseArgs(bad);
  Check(a.Usage = pcuEncoding, 'invalid UTF-8 is refused');
  Record_('args|invalid-utf8|' + PWebCliUsageText(a.Usage));
  bad[1] := '--project=a' + #0 + 'b';
  a := PWebCliParseArgs(bad);
  Check(a.Usage = pcuEncoding, 'an embedded NUL is refused');
  Record_('args|embedded-nul|' + PWebCliUsageText(a.Usage));
  // a legitimate non-ASCII value is NOT refused
  bad[1] := '--project=caf' + #$C3#$A9;
  a := PWebCliParseArgs(bad);
  Check(a.Usage = pcuNone, 'valid UTF-8 passes');
  Record_('args|valid-utf8|ok');
end;

{ ---------------------------------------------------------------------------
  PROJECT - P1..P16
  --------------------------------------------------------------------------- }

procedure TTestPWebCliProject.ValidDescriptor;
var
  root: RawUtf8;
  p: TPWebCliProject;
begin
  NewProject('valid', VALID_DESCRIPTOR, root);
  Check(root <> '', 'the fixture root canonicalized');
  p := PWebCliOpenProject(root, root);
  Check(p.Refusal = pcrNone, 'P1: a valid descriptor is accepted');
  CheckEqual(p.Name, 'my-app', 'P1: name');
  CheckEqual(p.Version, '0.1.0', 'P1: version');
  CheckEqual(p.BundleId, 'com.example.myapp', 'P1: bundleId');
  Check(p.Ui = puiReact, 'P1: ui');
  CheckEqual(p.NativeProgram, 'src/myapp.lpr', 'P1: native.program');
  CheckEqual(p.FrontendRoot, 'frontend', 'P1: frontend.root');
  CheckEqual(p.Output, 'dist', 'P1: output');
  // the derived identifier, by the ratified rule and nothing else
  CheckEqual(p.ProgramIdent, 'myapp', 'P1: the program identifier');
  CheckEqual(p.NativeProgramPath.MissingSegments, 0, 'P1: the source exists');
  CheckEqual(p.OutputPath.MissingSegments, 1,
    'P1: dist does not exist yet, and that is fine');
  Record_('project|valid|ok');
end;

procedure TTestPWebCliProject.MalformedAndStrictJson;

  // the descriptor is written DIRECTLY, so an empty file is a real empty
  // file rather than an absent one
  procedure Refuses(const Tag, Json: RawUtf8;
    Expected: TPWebCliProjectRefusal);
  var
    root: RawUtf8;
    dir: TFileName;
    p: TPWebCliProject;
  begin
    dir := NewProject(Tag, '', root);
    FileFromString(Json,
      IncludeTrailingPathDelimiter(dir) + 'pweb.json');
    p := PWebCliOpenProject(root, root);
    Check(p.Refusal = Expected, 'refusal for ' + string(Tag) + ': got ' +
      string(PWebCliProjectRefusalText(p.Refusal)));
    Record_('project|' + Tag + '|' +
      PWebCliProjectRefusalText(p.Refusal));
  end;

begin
  // P2
  Refuses('malformed', '{ "schema": 1, ', pcrJsonMalformed);
  Refuses('notobject', '[1,2,3]' + #10, pcrJsonMalformed);
  Refuses('empty', '', pcrJsonMalformed);
  // P3 - after escape decoding, so an obfuscated key cannot slip past
  Refuses('duplicate',
    '{"schema":1,"name":"a","name":"b"}' + #10, pcrDuplicateKey);
  Refuses('duplicate-escaped',
    '{"schema":1,"name":"a","na\u006de":"b"}' + #10, pcrDuplicateKey);
  // trailing content, comments and a BOM are all refusals, not tolerances
  Refuses('trailing', '{"schema":1}' + #10 + 'trailing' + #10,
    pcrTrailingContent);
  Refuses('comment',
    '{"schema":1, // a comment' + #10 + '"name":"a"}' + #10,
    pcrJsonMalformed);
  Refuses('bom', #$EF#$BB#$BF + '{"schema":1}' + #10, pcrEncoding);
  Refuses('nul', '{"schema":1,"name":"a' + #0 + 'b"}' + #10, pcrEncoding);
  Refuses('overlong-utf8',
    '{"schema":1,"name":"' + #$C0#$AF + '"}' + #10, pcrEncoding);
  // a float or an exponent where an integer is required
  Refuses('schema-float', '{"schema":1.0}' + #10, pcrJsonMalformed);
end;

procedure TTestPWebCliProject.SchemaAndFieldRules;

  procedure Refuses(const Tag: RawUtf8; const Json: RawUtf8;
    Expected: TPWebCliProjectRefusal);
  var
    root: RawUtf8;
    p: TPWebCliProject;
  begin
    NewProject(Tag, Json, root);
    p := PWebCliOpenProject(root, root);
    Check(p.Refusal = Expected, 'refusal for ' + string(Tag) + ': got ' +
      string(PWebCliProjectRefusalText(p.Refusal)));
    Record_('project|' + Tag + '|' +
      PWebCliProjectRefusalText(p.Refusal));
  end;

  function Swap(const Old, New_: RawUtf8): RawUtf8;
  begin
    Result := StringReplaceAll(VALID_DESCRIPTOR, Old, New_);
  end;

begin
  // P5
  Refuses('schema-2', Swap('"schema": 1', '"schema": 2'),
    pcrSchemaUnsupported);
  Refuses('schema-0', Swap('"schema": 1', '"schema": 0'),
    pcrSchemaUnsupported);
  Refuses('schema-string', Swap('"schema": 1', '"schema": "1"'),
    pcrFieldType);
  // P4 - an unknown field is refused, at both levels
  Refuses('unknown-top',
    Swap('"output": "dist"', '"output": "dist",' + #10 + '  "extra": 1'),
    pcrUnknownField);
  Refuses('unknown-nested',
    Swap('{ "program": "src/myapp.lpr" }',
      '{ "program": "src/myapp.lpr", "flags": "x" }'), pcrUnknownField);
  // P16 - a key that LOOKS like a credential gets its own diagnostic
  Refuses('secret-token',
    Swap('"output": "dist"', '"output": "dist",' + #10 + '  "token": "x"'),
    pcrSecretField);
  Refuses('secret-signing',
    Swap('"output": "dist"', '"output": "dist",' + #10 +
      '  "signingKey": "x"'), pcrSecretField);
  Refuses('secret-password',
    Swap('"output": "dist"', '"output": "dist",' + #10 +
      '  "password": "x"'), pcrSecretField);
  Refuses('secret-env',
    Swap('"output": "dist"', '"output": "dist",' + #10 + '  "env": "x"'),
    pcrSecretField);
  // a required field cannot simply be left out
  Refuses('missing-bundleid',
    StringReplaceAll(VALID_DESCRIPTOR,
      '  "bundleId": "com.example.myapp",' + #10, ''), pcrMissingField);
  // P6
  Refuses('ui-invalid', Swap('"ui": "react"', '"ui": "vue"'), pcrUiInvalid);
  Refuses('ui-case', Swap('"ui": "react"', '"ui": "React"'), pcrUiInvalid);
  Refuses('ui-type', Swap('"ui": "react"', '"ui": 1'), pcrFieldType);
end;

procedure TTestPWebCliProject.IdentifierGrammars;
begin
  Check(PWebCliValidName('my-app'), 'name: kebab');
  Check(PWebCliValidName('a'), 'name: single letter');
  Check(PWebCliValidName('app2'), 'name: digits after a letter');
  Check(not PWebCliValidName(''), 'name: empty');
  Check(not PWebCliValidName('My-App'), 'name: no uppercase');
  Check(not PWebCliValidName('2app'), 'name: must start with a letter');
  Check(not PWebCliValidName('my--app'), 'name: no empty label');
  Check(not PWebCliValidName('my-app-'), 'name: no trailing separator');
  Check(not PWebCliValidName('my_app'), 'name: no underscore');
  Check(not PWebCliValidName('my.app'), 'name: no dot');
  Record_('project|name-grammar|ok');

  Check(PWebCliValidBundleId('com.example.myapp'), 'bundleId: three labels');
  Check(PWebCliValidBundleId('com.example'), 'bundleId: two labels');
  Check(PWebCliValidBundleId('com.example.my-app'),
    'bundleId: a dash inside a label');
  Check(not PWebCliValidBundleId('com'), 'bundleId: one label is not enough');
  Check(not PWebCliValidBundleId('com..example'), 'bundleId: empty label');
  Check(not PWebCliValidBundleId('com.example.'), 'bundleId: trailing dot');
  Check(not PWebCliValidBundleId('Com.Example'), 'bundleId: no uppercase');
  Check(not PWebCliValidBundleId('com.1example'),
    'bundleId: a label starts with a letter');
  Check(not PWebCliValidBundleId('a.b.c.d.e.f'),
    'bundleId: bounded label count');
  Record_('project|bundleid-grammar|ok');

  // the derivation rule, spelled out rather than inferred
  CheckEqual(PWebCliProgramIdentOf('src/myapp.lpr'), 'myapp',
    'ident: basename without extension');
  CheckEqual(PWebCliProgramIdentOf('myapp.lpr'), 'myapp', 'ident: no folder');
  CheckEqual(PWebCliProgramIdentOf('a/b/c.d.pas'), 'c.d',
    'ident: only the FINAL extension is removed');
  CheckEqual(PWebCliProgramIdentOf('src/noext'), 'noext',
    'ident: no extension at all');
  Check(PWebCliValidProgramIdent('myapp'), 'ident grammar: accepted');
  Check(not PWebCliValidProgramIdent('my-app'),
    'ident grammar: no dash - it must be a Pascal identifier');
  Check(not PWebCliValidProgramIdent('MyApp'), 'ident grammar: no uppercase');
  Check(not PWebCliValidProgramIdent('c.d'), 'ident grammar: no dot');
  Record_('project|ident-grammar|ok');
end;

procedure TTestPWebCliProject.PathSyntaxRefusals;
const
  BAD: array[0 .. 13] of RawUtf8 = (
    '/abs/path',            // absolute
    'C:/drive/path',        // drive
    '//server/share',       // UNC
    '..\\escape',           // backslash
    '../escape',            // traversal
    './here',               // dot segment
    'a//b',                 // empty segment
    'a/../b',               // traversal in the middle
    'con',                  // Windows device name
    'con.txt',              // device name with an extension
    'a/nul',                // device name in a segment
    'trailing.',            // trailing dot
    'trailing ',            // trailing space
    'per%20cent');          // percent form: one decode only, refused here
var
  i: PtrInt;
  root: RawUtf8;
  p: TPWebCliProject;
begin
  // P7, P8, P9 - every one of these is refused BEFORE the filesystem is
  // consulted, by the shared canonical-logical-path grammar
  for i := 0 to High(BAD) do
  begin
    NewProject('badpath', StringReplaceAll(VALID_DESCRIPTOR,
      '"root": "frontend"', '"root": "' + BAD[i] + '"'), root);
    p := PWebCliOpenProject(root, root);
    Check(p.Refusal = pcrPath, 'path refused: ' + string(BAD[i]) +
      ' got ' + string(PWebCliProjectRefusalText(p.Refusal)));
    Check(Pos('frontend.root', p.Detail) = 1,
      'the diagnostic names the field: ' + string(p.Detail));
    Record_('project|badpath|' + BAD[i] + '|' + p.Detail);
  end;
end;

procedure TTestPWebCliProject.PathConfinement;
var
  projectDir, outsideDir: TFileName;
  root: RawUtf8;
  p: TPWebCliProject;
  r: TPWebCliResolved;
  linked: Boolean;
begin
  // P10: a real link on the chain refuses the whole path, and it is a link
  // that would otherwise ESCAPE the root
  projectDir := NewProject('confine', '', root);
  outsideDir := NewFixture('outside');
  MakeDir(IncludeTrailingPathDelimiter(outsideDir) + 'secret');
  linked := MakeLink(IncludeTrailingPathDelimiter(projectDir) + 'escape',
    outsideDir);
  // a machine that cannot create the fixture cannot prove the row, and the
  // suite says so LOUDLY rather than recording a weaker corpus line - a
  // gate that quietly downgrades itself on one target is how four-way
  // equality stops meaning anything. Windows uses an NTFS junction (no
  // privilege required); POSIX uses a symlink.
  Check(linked, 'P10: the link fixture could not be created on this machine');
  if linked then
  begin
    r := PWebCliResolveUnder(root, 'escape', True);
    Check(r.Refusal = pprLink,
      'P10: a reparse point on the chain refuses the path, got ' +
      string(PWebCliPathRefusalText(r.Refusal)));
    r := PWebCliResolveUnder(root, 'escape/secret', True);
    Check(r.Refusal = pprLink, 'P10: and refuses everything under it');
    Record_('project|link-escape|' + PWebCliPathRefusalText(pprLink));
    // and the descriptor route reaches the same verdict
    FileFromString(StringReplaceAll(VALID_DESCRIPTOR,
      '"root": "frontend"', '"root": "escape"'),
      IncludeTrailingPathDelimiter(projectDir) + 'pweb.json');
    p := PWebCliOpenProject(root, root);
    Check(p.Refusal = pcrPath, 'P10: the descriptor refuses it too');
    Record_('project|link-descriptor|' + p.Detail);
  end;
  // a path that simply does not exist yet is NOT an escape
  r := PWebCliResolveUnder(root, 'dist/win/x64', True);
  Check(r.Refusal = pprNone, 'a missing tail is allowed when asked for');
  CheckEqual(r.MissingSegments, 3, 'all three segments are absent');
  r := PWebCliResolveUnder(root, 'dist/win/x64', False);
  Check(r.Refusal = pprMissing, 'and refused when not');
  Record_('project|missing-tail|ok');
  // an existing directory whose CHILDREN are absent: the walk must count
  // exactly the absent tail, not the whole path, so 'dist' being creatable
  // and 'hole/missing/deep' being creatable are the same shape
  MakeDir(IncludeTrailingPathDelimiter(projectDir) + 'hole');
  Check(PWebCliEntry(root, 'hole') = pcnDirectory,
    'the hole fixture is visible from the canonical root');
  r := PWebCliResolveUnder(root, 'hole/missing/deep', True);
  Check(r.Refusal = pprNone, 'a genuinely absent tail is still allowed');
  CheckEqual(r.MissingSegments, 2, 'and both segments are counted absent');
  Record_('project|hole-in-tail|ok');
end;

procedure TTestPWebCliProject.ExactCase;
var
  projectDir: TFileName;
  root: RawUtf8;
  r: TPWebCliResolved;
begin
  projectDir := NewProject('case', '', root);
  // P11: the on-disk spelling is 'frontend'. 'Frontend' must MISS on every
  // platform - including the two whose filesystems fold case by default.
  r := PWebCliResolveUnder(root, 'frontend', False);
  Check(r.Refusal = pprNone, 'P11: the exact spelling resolves');
  r := PWebCliResolveUnder(root, 'Frontend', False);
  Check(r.Refusal in [pprCaseMismatch, pprMissing],
    'P11: a case variant never resolves, got ' +
    string(PWebCliPathRefusalText(r.Refusal)));
  // the CORPUS records the platform-independent fact - refused - because
  // WHICH refusal is genuinely a property of the volume: a case-folding
  // filesystem can say "it exists under another spelling", a case-sensitive
  // one has nothing to distinguish it from absent. Recording the exact
  // token here would make the four-target digest diverge for a reason that
  // is not a defect.
  Record_('project|exact-case|refused');
  r := PWebCliResolveUnder(root, 'src/MyApp.lpr', False);
  Check(r.Refusal in [pprCaseMismatch, pprMissing],
    'P11: and the same for a file');
  Record_('project|exact-case-file|refused');
end;

procedure TTestPWebCliProject.Discovery;
var
  outerDir, innerDir, deepDir: TFileName;
  outerRoot, innerRoot, deepRoot: RawUtf8;
  p: TPWebCliProject;
  outer: RawUtf8;
begin
  // two nested projects: the outer one, and an inner one three levels down
  outerDir := NewProject('outer', VALID_DESCRIPTOR, outerRoot);
  innerDir := IncludeTrailingPathDelimiter(outerDir) + 'packages' +
    PathDelim + 'inner';
  MakeDir(innerDir);
  MakeDir(IncludeTrailingPathDelimiter(innerDir) + 'src');
  MakeDir(IncludeTrailingPathDelimiter(innerDir) + 'frontend');
  FileFromString('program myapp;'#10'begin'#10'end.'#10,
    IncludeTrailingPathDelimiter(innerDir) + 'src' + PathDelim + 'myapp.lpr');
  FileFromString(StringReplaceAll(VALID_DESCRIPTOR, '"name": "my-app"',
    '"name": "inner-app"'),
    IncludeTrailingPathDelimiter(innerDir) + 'pweb.json');
  deepDir := IncludeTrailingPathDelimiter(innerDir) + 'frontend';
  Check(PWebCliCanonicalDir(RawUtf8(innerDir), innerRoot), 'inner root');
  Check(PWebCliCanonicalDir(RawUtf8(deepDir), deepRoot), 'deep dir');

  // P13: the walk stops at the NEAREST descriptor, not the outermost
  p := PWebCliOpenProject('', deepRoot);
  Check(p.Refusal = pcrNone, 'P13: discovery succeeded');
  CheckEqual(p.Name, 'inner-app', 'P13: the nearest descriptor wins');
  Check(p.Discovered, 'P13: recorded as discovered');
  CheckEqual(p.DiscoveryDepth, 1, 'P13: one level up');
  Record_('project|discovery-nearest|ok');

  // P12: an explicit --project wins, deterministically, with no search
  outer := outerRoot;
  p := PWebCliOpenProject(outer, deepRoot);
  Check(p.Refusal = pcrNone, 'P12: the explicit project opened');
  CheckEqual(p.Name, 'my-app', 'P12: --project beats the nearest descriptor');
  Check(not p.Discovered, 'P12: not a discovery');
  Record_('project|explicit-wins|ok');

  // --project naming the descriptor itself is the same project
  p := PWebCliOpenProject(PWebCliJoin(outer, 'pweb.json'), deepRoot);
  Check(p.Refusal = pcrNone, 'P12: naming pweb.json directly works');
  CheckEqual(p.Name, 'my-app', 'P12: same project either way');
  Record_('project|explicit-descriptor|ok');

  // naming any OTHER file is an error, never a hint to look nearby
  p := PWebCliOpenProject(PWebCliJoin(outer, 'other.json'), deepRoot);
  Check(p.Refusal = pcrDescriptorName,
    'P12: --project other.json is refused, never redirected');
  Record_('project|explicit-wrong-name|' +
    PWebCliProjectRefusalText(p.Refusal));

  // an explicit directory with no descriptor does NOT fall back to a search
  p := PWebCliOpenProject(deepRoot, deepRoot);
  Check(p.Refusal = pcrDescriptorMissing,
    'P12: an explicit path never searches upward');
  Record_('project|explicit-no-fallback|' +
    PWebCliProjectRefusalText(p.Refusal));

  // P14: a tree with no descriptor anywhere above it fails clearly
  deepDir := NewFixture('nowhere');
  Check(PWebCliCanonicalDir(RawUtf8(deepDir), deepRoot), 'temp dir');
  p := PWebCliOpenProject('', deepRoot);
  Check(p.Refusal = pcrDescriptorNotFound,
    'P14: the walk ends at the filesystem root with a clear refusal');
  Record_('project|discovery-none|' +
    PWebCliProjectRefusalText(p.Refusal));
end;

procedure TTestPWebCliProject.CwdCannotRedirect;
var
  projectDir, elsewhereDir, saved: TFileName;
  root: RawUtf8;
  before, after: TPWebCliProject;
begin
  projectDir := NewProject('cwd', VALID_DESCRIPTOR, root);
  elsewhereDir := NewFixture('elsewhere');
  saved := GetCurrentDir;
  try
    // P15: resolve once, then move the process somewhere else entirely and
    // resolve again from the SAME captured root. Nothing may change.
    SetCurrentDir(projectDir);
    before := PWebCliOpenProject('', root);
    Check(before.Refusal = pcrNone, 'P15: resolved from inside');
    SetCurrentDir(elsewhereDir);
    after := PWebCliOpenProject('', root);
    Check(after.Refusal = pcrNone, 'P15: still resolves after the move');
    CheckEqual(after.Root, before.Root, 'P15: the root is unchanged');
    CheckEqual(after.NativeProgramPath.Full, before.NativeProgramPath.Full,
      'P15: a descriptor path still resolves to the same file');
    CheckEqual(after.OutputPath.ExistingDir, before.OutputPath.ExistingDir,
      'P15: and so does the output anchor');
    Record_('project|cwd-independent|ok');
  finally
    SetCurrentDir(saved);
  end;
end;

{ ---------------------------------------------------------------------------
  DOCTOR - D1..D5, D10, D11, C7..C9
  --------------------------------------------------------------------------- }

type
  TFakeTool = record
    Name: RawUtf8;
    Outcome: TPWebCliProbeOutcome;
    ExitCode: Integer;
    Output: RawUtf8;
  end;

var
  FakeTools: array of TFakeTool;
  FakeDirs: TRawUtf8DynArray;
  FakeFiles: TRawUtf8DynArray;
  FakeWritable: Boolean;

function FakeProbe(const Tool, ProjectRoot: RawUtf8;
  const Args: TRawUtf8DynArray; TimeoutMs: Cardinal): TPWebCliProbe;
var
  i: PtrInt;
begin
  Result := Default(TPWebCliProbe);
  Result.Outcome := ppoNotFound;
  for i := 0 to High(FakeTools) do
    if FakeTools[i].Name = Tool then
    begin
      Result.Outcome := FakeTools[i].Outcome;
      Result.ExitCode := FakeTools[i].ExitCode;
      Result.Output := FakeTools[i].Output;
      Result.Path := '/fake/bin/' + Tool;
      exit;
    end;
end;

function FakeNodeKind(const Path: RawUtf8): TPWebCliNodeKind;
var
  i: PtrInt;
begin
  for i := 0 to High(FakeDirs) do
    if FakeDirs[i] = Path then
      exit(pcnDirectory);
  for i := 0 to High(FakeFiles) do
    if FakeFiles[i] = Path then
      exit(pcnFile);
  Result := pcnMissing;
end;

function FakeDirWritable(const Dir: RawUtf8): Boolean;
begin
  Result := FakeWritable;
end;

procedure SetTool(const Name: RawUtf8; Outcome: TPWebCliProbeOutcome;
  ExitCode: Integer; const Output: RawUtf8);
var
  i: PtrInt;
begin
  for i := 0 to High(FakeTools) do
    if FakeTools[i].Name = Name then
    begin
      FakeTools[i].Outcome := Outcome;
      FakeTools[i].ExitCode := ExitCode;
      FakeTools[i].Output := Output;
      exit;
    end;
  SetLength(FakeTools, Length(FakeTools) + 1);
  FakeTools[High(FakeTools)].Name := Name;
  FakeTools[High(FakeTools)].Outcome := Outcome;
  FakeTools[High(FakeTools)].ExitCode := ExitCode;
  FakeTools[High(FakeTools)].Output := Output;
end;

procedure DropTool(const Name: RawUtf8);
var
  i, n: PtrInt;
  kept: array of TFakeTool;
begin
  n := 0;
  SetLength(kept, Length(FakeTools));
  for i := 0 to High(FakeTools) do
    if FakeTools[i].Name <> Name then
    begin
      kept[n] := FakeTools[i];
      Inc(n);
    end;
  SetLength(kept, n);
  FakeTools := kept;
end;

// a healthy injected world for a react project rooted at Root
function HealthyEnv(const Project: TPWebCliProject): TPWebCliDoctorEnv;
begin
  FakeTools := nil;
  SetTool(PWEB_CLI_TOOL_FPC, ppoCompleted, 0, '3.2.2'#10);
  SetTool(PWEB_CLI_TOOL_NODE, ppoCompleted, 0, 'v22.11.0'#10);
  SetTool(PWEB_CLI_TOOL_NPM, ppoCompleted, 0, '10.9.0'#10);
  SetTool(PWEB_CLI_TOOL_PAS2JS, ppoCompleted, 0, '3.0.1'#10);
  FakeDirs := nil;
  FakeFiles := nil;
  SetLength(FakeDirs, 2);
  FakeDirs[0] := Project.FrontendRootPath.Full;
  FakeDirs[1] := PWebCliJoin(Project.FrontendRootPath.Full, 'node_modules');
  SetLength(FakeFiles, 3);
  FakeFiles[0] := Project.NativeProgramPath.Full;
  FakeFiles[1] := PWebCliJoin(Project.FrontendRootPath.Full, 'package.json');
  FakeFiles[2] := PWebCliJoin(Project.FrontendRootPath.Full,
    'package-lock.json');
  FakeWritable := True;
  Result := Default(TPWebCliDoctorEnv);
  Result.OsText := 'linux';
  Result.ArchText := 'x86_64';
  Result.Release := 'injected';
  Result.OsProductVersion := '';
  Result.Engine.Usable := True;
  Result.Engine.Category := 'usable';
  Result.Engine.Observed := 'injected engine';
  Result.Engine.Expected := 'an injected engine';
  Result.NodeKind := @FakeNodeKind;
  Result.DirWritable := @FakeDirWritable;
  Result.ProbeTool := @FakeProbe;
end;

function FindRow(const Report: TPWebCliReport; const Id: RawUtf8;
  out Row: TPWebCliCheck): Boolean;
var
  i: PtrInt;
begin
  for i := 0 to High(Report.Checks) do
    if Report.Checks[i].Id = Id then
    begin
      Row := Report.Checks[i];
      exit(True);
    end;
  Row := Default(TPWebCliCheck);
  Result := False;
end;

function OpenFixtureProject(const Tag, Descriptor: RawUtf8):
  TPWebCliProject;
var
  root: RawUtf8;
begin
  NewProject(Tag, Descriptor, root);
  Result := PWebCliOpenProject(root, root);
end;

procedure TTestPWebCliDoctor.HealthyEnvironment;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
begin
  p := OpenFixtureProject('healthy', VALID_DESCRIPTOR);
  Check(p.Refusal = pcrNone, 'the fixture project opened');
  env := HealthyEnv(p);
  r := PWebCliDoctorRun(env, p, pdmSource);
  // D1
  CheckEqual(r.CountFail, 0, 'D1: a healthy world fails nothing');
  CheckEqual(r.CountWarning, 0, 'D1: and warns about nothing');
  Check(r.Status = pdsPass, 'D1: overall pass');
  Check(not r.ProbeFailure, 'D1: no probe failure');
  Record_('doctor|healthy|' + PWebCliStatusText(r.Status));
  // the rows are sorted by id, which is part of the public contract
  Check(Length(r.Checks) > 5, 'the graph produced rows');
  Check(r.Checks[0].Id < r.Checks[High(r.Checks)].Id,
    'rows are ordered by id');
end;

procedure TTestPWebCliDoctor.RequiredToolMissing;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  row: TPWebCliCheck;
begin
  p := OpenFixtureProject('nofpc', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  DropTool(PWEB_CLI_TOOL_FPC);
  r := PWebCliDoctorRun(env, p, pdmSource);
  // D2
  Check(FindRow(r, 'toolchain.fpc', row), 'the fpc row exists');
  Check(row.Status = pdsFail, 'D2: a missing required tool fails');
  CheckEqual(row.Cause, 'tool_not_found', 'D2: with its own cause');
  Check(row.Severity = pdvRequired, 'D2: and it is required');
  Check(not r.ProbeFailure,
    'D2: an ABSENT tool is an environment failure, never a probe one');
  Record_('doctor|fpc-missing|' + row.Cause);
end;

procedure TTestPWebCliDoctor.MalformedVersion;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  row: TPWebCliCheck;
begin
  p := OpenFixtureProject('badver', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  SetTool(PWEB_CLI_TOOL_FPC, ppoCompleted, 0, 'not a version at all'#10);
  r := PWebCliDoctorRun(env, p, pdmSource);
  // D3
  Check(FindRow(r, 'toolchain.fpc', row), 'the fpc row exists');
  Check(row.Status = pdsFail, 'D3: an unparseable version fails');
  CheckEqual(row.Cause, 'version_malformed',
    'D3: distinct from absent and from too old');
  Record_('doctor|fpc-malformed|' + row.Cause);
  // the normalizer itself, over the shapes real tools produce
  Check(PWebCliNormalizeVersion('3.2.2'#10, row.Observed), 'plain');
  CheckEqual(row.Observed, '3.2.2', 'plain');
  Check(PWebCliNormalizeVersion('v22.11.0'#10, row.Observed), 'v prefix');
  CheckEqual(row.Observed, '22.11.0', 'v prefix stripped');
  Check(PWebCliNormalizeVersion('14.6'#10, row.Observed), 'two components');
  CheckEqual(row.Observed, '14.6.0', 'padded to three');
  Check(PWebCliNormalizeVersion('3.2.2'#10'banner line'#10, row.Observed),
    'first line only');
  CheckEqual(row.Observed, '3.2.2', 'the banner is ignored');
  Check(not PWebCliNormalizeVersion('3.2.2-rc1'#10, row.Observed),
    'a prerelease suffix is not comparable');
  Check(not PWebCliNormalizeVersion(''#10, row.Observed), 'empty');
  Record_('doctor|version-normalizer|ok');
end;

procedure TTestPWebCliDoctor.WrongVersion;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  row: TPWebCliCheck;
begin
  p := OpenFixtureProject('oldver', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  SetTool(PWEB_CLI_TOOL_FPC, ppoCompleted, 0, '3.0.4'#10);
  SetTool(PWEB_CLI_TOOL_NODE, ppoCompleted, 0, 'v18.20.0'#10);
  r := PWebCliDoctorRun(env, p, pdmSource);
  // D4
  Check(FindRow(r, 'toolchain.fpc', row), 'the fpc row exists');
  Check(row.Status = pdsFail, 'D4: a version below the floor fails');
  CheckEqual(row.Cause, 'version_too_old', 'D4: with its own cause');
  CheckEqual(row.Observed, '3.0.4', 'D4: the measured value is reported');
  Record_('doctor|fpc-too-old|' + row.Cause);
  Check(FindRow(r, 'frontend.node', row), 'the node row exists');
  CheckEqual(row.Cause, 'version_too_old', 'D4: node too old');
  Record_('doctor|node-too-old|' + row.Cause);
  // a NEWER version than the floor is accepted - the floor is a minimum
  env := HealthyEnv(p);
  SetTool(PWEB_CLI_TOOL_FPC, ppoCompleted, 0, '3.2.3'#10);
  r := PWebCliDoctorRun(env, p, pdmSource);
  Check(FindRow(r, 'toolchain.fpc', row), 'the fpc row exists');
  Check(row.Status = pdsPass, 'D4: 3.2.3 satisfies a 3.2.2 floor');
  Record_('doctor|fpc-newer|pass');
end;

procedure TTestPWebCliDoctor.OptionalGapIsWarning;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  row: TPWebCliCheck;
begin
  p := OpenFixtureProject('nodeps', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  // remove node_modules only
  SetLength(FakeDirs, 1);
  r := PWebCliDoctorRun(env, p, pdmSource);
  // D5
  Check(FindRow(r, 'frontend.dependencies', row), 'the optional row exists');
  Check(row.Status = pdsWarning, 'D5: an optional gap WARNS');
  Check(row.Severity = pdvOptional, 'D5: and is marked optional');
  CheckEqual(r.CountFail, 0, 'D5: nothing failed');
  Check(r.Status = pdsWarning, 'D5: the overall status is warning');
  Record_('doctor|deps-missing|' + PWebCliStatusText(row.Status));
end;

procedure TTestPWebCliDoctor.ProjectAwareRequirements;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  row: TPWebCliCheck;
begin
  // D11: a react project must not be asked for Pas2JS
  p := OpenFixtureProject('reactui', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  DropTool(PWEB_CLI_TOOL_PAS2JS);
  r := PWebCliDoctorRun(env, p, pdmSource);
  Check(FindRow(r, 'frontend.pas2js', row), 'the pas2js row exists');
  Check(row.Status = pdsNotApplicable,
    'D11: Pas2JS is not applicable to a react project');
  CheckEqual(row.Cause, 'ui_not_pas2js', 'D11: and it says why');
  CheckEqual(r.CountFail, 0, 'D11: an irrelevant tool cannot fail a project');
  Record_('doctor|react-excludes-pas2js|' + row.Cause);
  // and a pas2js project must not be asked for Node, npm or a lockfile
  p := OpenFixtureProject('pas2jsui', StringReplaceAll(VALID_DESCRIPTOR,
    '"ui": "react"', '"ui": "pas2js"'));
  Check(p.Refusal = pcrNone, 'the pas2js fixture opened');
  env := HealthyEnv(p);
  DropTool(PWEB_CLI_TOOL_NODE);
  DropTool(PWEB_CLI_TOOL_NPM);
  r := PWebCliDoctorRun(env, p, pdmSource);
  Check(FindRow(r, 'frontend.node', row), 'the node row exists');
  Check(row.Status = pdsNotApplicable, 'D11: Node is not applicable');
  Check(FindRow(r, 'frontend.npm', row), 'the npm row exists');
  Check(row.Status = pdsNotApplicable, 'D11: npm is not applicable');
  Check(FindRow(r, 'frontend.lockfile', row), 'the lockfile row exists');
  Check(row.Status = pdsNotApplicable, 'D11: the lockfile is not applicable');
  Check(FindRow(r, 'frontend.pas2js', row), 'the pas2js row exists');
  Check(row.Status = pdsPass, 'D11: and Pas2JS IS required here');
  CheckEqual(r.CountFail, 0, 'D11: nothing failed');
  Record_('doctor|pas2js-excludes-node|ok');
  // the exact-pin rule: a NEWER pas2js is still wrong, because the SDK is
  // compiled by the pinned one
  env := HealthyEnv(p);
  SetTool(PWEB_CLI_TOOL_PAS2JS, ppoCompleted, 0, '3.1.0'#10);
  r := PWebCliDoctorRun(env, p, pdmSource);
  Check(FindRow(r, 'frontend.pas2js', row), 'the pas2js row exists');
  CheckEqual(row.Cause, 'version_mismatch',
    'D11: pas2js is pinned exactly, not by a floor');
  Record_('doctor|pas2js-exact-pin|' + row.Cause);
end;

procedure TTestPWebCliDoctor.ProjectRefusalIsReported;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  row: TPWebCliCheck;
begin
  p := OpenFixtureProject('broken', '{ "schema": 1, ');
  Check(p.Refusal <> pcrNone, 'the fixture is broken on purpose');
  env := HealthyEnv(p);
  r := PWebCliDoctorRun(env, p, pdmSource);
  Check(FindRow(r, 'project.descriptor', row), 'the descriptor row exists');
  Check(row.Status = pdsFail, 'a broken descriptor fails its row');
  CheckEqual(row.Cause, PWebCliProjectRefusalText(p.Refusal),
    'and the row carries the exact refusal');
  // every project-dependent row is not_applicable WITH A REASON - never a
  // SKIP that hides the failure above
  Check(FindRow(r, 'project.native_program', row), 'the row exists');
  Check(row.Status = pdsNotApplicable, 'not applicable without a project');
  CheckEqual(row.Cause, 'no_project', 'and it says exactly why');
  // the HOST rows still ran: a machine can be diagnosed without a project
  Check(FindRow(r, 'host.platform', row), 'the host row exists');
  Check(row.Status = pdsPass, 'the host is still diagnosed');
  Record_('doctor|no-project|' + PWebCliProjectRefusalText(p.Refusal));
end;

procedure TTestPWebCliDoctor.BothProjectionsAgree;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  o: TPWebCliRenderOptions;
  human, json: RawUtf8;
  i: PtrInt;
begin
  p := OpenFixtureProject('agree', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  DropTool(PWEB_CLI_TOOL_FPC);
  SetLength(FakeDirs, 1);
  r := PWebCliDoctorRun(env, p, pdmSource);
  o := Default(TPWebCliRenderOptions);
  human := PWebCliRenderHuman(r, p, env, o);
  json := PWebCliRenderJson(r, p, env, o);
  // D10: one result array, two projections. Every row id and every status
  // appears in both, and the overall verdict is the same word.
  for i := 0 to High(r.Checks) do
  begin
    Check(Pos(r.Checks[i].Id, human) > 0,
      'D10: the human report carries ' + string(r.Checks[i].Id));
    Check(Pos('"id":"' + r.Checks[i].Id + '"', json) > 0,
      'D10: the JSON carries ' + string(r.Checks[i].Id));
    Check(Pos('"id":"' + r.Checks[i].Id + '","status":"' +
      PWebCliStatusText(r.Checks[i].Status) + '"', json) > 0,
      'D10: with the same status');
  end;
  Check(Pos('"status":"' + PWebCliStatusText(r.Status) + '"', json) > 0,
    'D10: the JSON verdict');
  Check(Pos('doctor: ' + RawUtf8(UpperCase(string(
    PWebCliStatusText(r.Status)))), human) > 0,
    'D10: the human verdict is the same word');
  Record_('doctor|projections-agree|ok');
end;

procedure TTestPWebCliDoctor.JsonIsCanonical;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  o: TPWebCliRenderOptions;
  a, b: RawUtf8;
  i: PtrInt;
begin
  p := OpenFixtureProject('canon', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  r := PWebCliDoctorRun(env, p, pdmSource);
  o := Default(TPWebCliRenderOptions);
  a := PWebCliRenderJson(r, p, env, o);
  b := PWebCliRenderJson(PWebCliDoctorRun(env, p, pdmSource), p, env, o);
  // C9: identical injected observations produce identical bytes. No
  // timestamp, no ordering that depends on emission, no locale.
  CheckEqual(a, b, 'C9: the JSON is byte-deterministic');
  // C8: no ANSI, anywhere - ONE assertion over the whole document, so the
  // count stays a fact about the document rather than about its length
  i := 1;
  while (i <= Length(a)) and
        (a[i] <> #27) do
    Inc(i);
  Check(i > Length(a), 'C8: not one escape byte in the JSON');
  Check(Pos('"doctor":1', a) > 0, 'C8: the schema version is present');
  // the redaction default is what makes the corpus comparable at all
  Check(Pos('<project>', a) > 0, 'paths are redacted by default');
  Check(Pos(p.Root, a) = 0, 'the absolute root does not leak');
  o.WithPaths := True;
  b := PWebCliRenderJson(r, p, env, o);
  Check(Pos('"root":"<project>"', b) = 0,
    '--with-paths opts out of redaction');
  Check(Pos('"root":""', b) = 0, 'and still reports a root');
  Check(b <> a, '--with-paths produces a different document');
  Record_('doctor|json-canonical|ok');
end;

procedure TTestPWebCliDoctor.HumanCarriesNoAnsiWhenRedirected;
var
  p: TPWebCliProject;
  env: TPWebCliDoctorEnv;
  r: TPWebCliReport;
  o: TPWebCliRenderOptions;
  text: RawUtf8;
  i: PtrInt;
begin
  p := OpenFixtureProject('ansi', VALID_DESCRIPTOR);
  env := HealthyEnv(p);
  DropTool(PWEB_CLI_TOOL_FPC);
  r := PWebCliDoctorRun(env, p, pdmSource);
  o := Default(TPWebCliRenderOptions);
  o.Color := False;
  text := PWebCliRenderHuman(r, p, env, o);
  // C7 - one assertion over the whole rendering
  i := 1;
  while (i <= Length(text)) and
        (text[i] <> #27) do
    Inc(i);
  Check(i > Length(text), 'C7: not one escape byte when colour is off');
  Check(Pos('[fail]', text) > 0, 'the ASCII marker vocabulary is used');
  Check(Pos('[ ok ]', text) > 0, 'and the pass marker too');
  Record_('doctor|human-no-ansi|ok');
  // and a DATA SOURCE cannot break that promise either. The Windows engine
  // row reports the runtime version as the REGISTRY supplied it and the host
  // release line is whatever the OS says: neither is this CLI's to promise
  // control-byte-free, so an escape arriving through one of them must not
  // become an escape in a report that just promised to carry none.
  env.Release := 'injected' + #27 + '[31mRED';
  env.Engine.Observed := 'engine' + #27 + '[32mGREEN';
  r := PWebCliDoctorRun(env, p, pdmSource);
  o.Color := False;
  text := PWebCliRenderHuman(r, p, env, o);
  i := 1;
  while (i <= Length(text)) and
        (text[i] <> #27) do
    Inc(i);
  Check(i > Length(text),
    'C7: an escape byte in an OBSERVED value never reaches the report');
  Check(Pos('injected?[31mRED', text) > 0,
    'C7: it is neutralized rather than dropped, so the value is still read');
  Record_('doctor|human-sanitized|ok');
  // with colour ON the markers are wrapped, and ONLY then
  o.Color := True;
  text := PWebCliRenderHuman(r, p, env, o);
  Check(Pos(#27'[31m[fail]', text) > 0, 'colour is applied when asked for');
  Record_('doctor|human-colour|ok');
end;

{ ---------------------------------------------------------------------------
  PROBE - D6..D9
  --------------------------------------------------------------------------- }

function ProbeChildPath: RawUtf8;
begin
  Result := RawUtf8(ExtractFilePath(ParamStr(0))) +
    RawUtf8(ProbeChildName);
end;

// CR/LF-tolerant line split: the child's WriteLn is CRLF on Windows and LF
// elsewhere, and the point of the test is the ARGUMENTS, not the newline
function SplitLines(const Text: RawUtf8): TRawUtf8DynArray;
var
  i, start, n: PtrInt;
  line: RawUtf8;
begin
  Result := nil;
  n := 0;
  start := 1;
  for i := 1 to Length(Text) + 1 do
    if (i > Length(Text)) or
       (Text[i] = #10) then
    begin
      line := Copy(Text, start, i - start);
      while (line <> '') and
            (line[Length(line)] = #13) do
        SetLength(line, Length(line) - 1);
      SetLength(Result, n + 1);
      Result[n] := line;
      Inc(n);
      start := i + 1;
    end;
end;

procedure TTestPWebCliProbe.BoundedTimeout;
var
  r: TPWebCliProbe;
  started, elapsed: QWord;
begin
  if PWebCliNodeKind(ProbeChildPath) <> pcnFile then
  begin
    Record_('probe|timeout|child-unavailable');
    Check(False, 'D6: the probe child fixture must be built beside the suite');
    exit;
  end;
  started := GetTickCount64;
  // D6: the child sleeps far past the bound; the runner must terminate it
  // and answer, rather than wait for it
  r := PWebCliRunProbe(ProbeChildPath, ['sleep', '30000'], 1500);
  elapsed := GetTickCount64 - started;
  Check(r.Outcome = ppoTimedOut, 'D6: the bound expired');
  Check(elapsed < 15000,
    'D6: the runner returned promptly, not after the child (' +
    IntToStr(elapsed) + ' ms)');
  Record_('probe|timeout|' + PWebCliProbeOutcomeText(r.Outcome));
end;

procedure TTestPWebCliProbe.StdOutSaturation;
var
  r: TPWebCliProbe;
begin
  if PWebCliNodeKind(ProbeChildPath) <> pcnFile then
    exit;
  // D7: far more stdout than any pipe buffer holds, and more than the
  // capture ceiling. A reader that stopped at the ceiling would deadlock
  // the child; this must complete.
  r := PWebCliRunProbe(ProbeChildPath,
    ['flood', IntToStr(PWEB_CLI_PROBE_MAX_BYTES * 4)], 60000);
  Check(r.Outcome = ppoCompleted, 'D7: saturation did not deadlock');
  CheckEqual(r.ExitCode, 0, 'D7: the child exited normally');
  Check(r.Truncated, 'D7: the capture ceiling was reported');
  Check(Length(r.Output) <= PWEB_CLI_PROBE_MAX_BYTES,
    'D7: and the capture stayed bounded');
  Record_('probe|stdout-saturation|' + PWebCliProbeOutcomeText(r.Outcome));
end;

procedure TTestPWebCliProbe.StdErrSaturation;
var
  r: TPWebCliProbe;
begin
  if PWebCliNodeKind(ProbeChildPath) <> pcnFile then
    exit;
  // D8: the stream a one-pipe reader forgets. Same requirement.
  r := PWebCliRunProbe(ProbeChildPath,
    ['floodstderr', IntToStr(PWEB_CLI_PROBE_MAX_BYTES * 4)], 60000);
  Check(r.Outcome = ppoCompleted, 'D8: stderr saturation did not deadlock');
  Check(r.Truncated, 'D8: the ceiling was reported');
  Check(Length(r.ErrorText) <= PWEB_CLI_PROBE_MAX_BYTES,
    'D8: stderr capture stayed bounded');
  Check(Length(r.ErrorText) > 0, 'D8: stderr was actually captured');
  Record_('probe|stderr-saturation|' + PWebCliProbeOutcomeText(r.Outcome));
end;

procedure TTestPWebCliProbe.ArgumentsAreNotInterpreted;
var
  r: TPWebCliProbe;
  lines: TRawUtf8DynArray;
  n: PtrInt;
begin
  if PWebCliNodeKind(ProbeChildPath) <> pcnFile then
    exit;
  // D9: arguments carrying every metacharacter a shell would act on. The
  // child prints its own argv, so "no shell touched this" is a byte
  // comparison rather than an assertion about the code.
  r := PWebCliRunProbe(ProbeChildPath,
    ['argv', 'a b; rm -rf / && echo $(whoami) `id` | cat > /tmp/x'], 30000);
  Check(r.Outcome = ppoCompleted, 'D9: the child ran');
  CheckEqual(r.ExitCode, 0, 'D9: and exited cleanly');
  lines := SplitLines(r.Output);
  n := Length(lines);
  while (n > 0) and (lines[n - 1] = '') do
    Dec(n);
  CheckEqual(n, 2, 'D9: exactly two arguments arrived, never split');
  if n = 2 then
  begin
    CheckEqual(lines[0], 'argv', 'D9: the first argument');
    CheckEqual(lines[1],
      'a b; rm -rf / && echo $(whoami) `id` | cat > /tmp/x',
      'D9: the second arrived VERBATIM - nothing expanded it');
  end;
  Record_('probe|argv-verbatim|ok');
  // and the ordinary shape still works
  r := PWebCliRunProbe(ProbeChildPath, ['version', '7.7.7'], 30000);
  Check(r.Outcome = ppoCompleted, 'the ordinary probe completes');
  Check(Pos('7.7.7', r.Output) > 0, 'and its stdout is captured');
  r := PWebCliRunProbe(ProbeChildPath, ['exit', '3'], 30000);
  Check(r.Outcome = ppoCompleted, 'a nonzero exit is still a completion');
  CheckEqual(r.ExitCode, 3, 'and the exact code is reported');
  Record_('probe|exit-code|ok');
end;

procedure TTestPWebCliProbe.PathResolutionRules;
var
  path, shadowed, parent, dummy: RawUtf8;
  dup: Integer;
  outcome: TPWebCliProbeOutcome;
  probe: TPWebCliProbe;
begin
  // a name nothing on PATH carries
  outcome := PWebCliResolveTool('pweb-no-such-tool-cap10a', '', path, dup);
  Check(outcome = ppoNotFound, 'an absent tool is not found');
  CheckEqual(path, '', 'and nothing is reported as selected');
  Record_('probe|resolve-absent|' + PWebCliProbeOutcomeText(outcome));

  // the SHADOWING refusal, proved without touching the environment: resolve
  // a tool that really is on PATH, then declare its own directory to be the
  // project root and ask again. A tool inside the project must be reported
  // and NEVER executed - which is the whole answer to "can a project-local
  // binary called fpc or node take over the build".
  outcome := PWebCliResolveTool(PWEB_CLI_TOOL_FPC, '', shadowed, dup);
  // FPC on PATH is a precondition of every CI leg (each job asserts its
  // version before this suite runs), so its absence fails the row rather
  // than downgrading the corpus on one target
  Check(outcome = ppoCompleted,
    'the shadow fixture needs fpc on PATH, which every CI leg asserts');
  if outcome = ppoCompleted then
  begin
    Check(PWebCliSplitLast(shadowed, parent, dummy),
      'the resolved tool has a parent directory');
    outcome := PWebCliResolveTool(PWEB_CLI_TOOL_FPC, parent, path, dup);
    Check(outcome = ppoInsideProject,
      'a tool inside the project root is refused, got ' +
      string(PWebCliProbeOutcomeText(outcome)));
    CheckEqual(path, shadowed,
      'and it is REPORTED, so a human can see what shadowed the toolchain');
    // and the one-step form refuses before it starts anything
    probe := PWebCliProbeTool(PWEB_CLI_TOOL_FPC, parent, [], 5000);
    Check(probe.Outcome = ppoInsideProject,
      'the probe refuses before spawning');
    CheckEqual(probe.ExitCode, 0, 'nothing ran, so there is no exit code');
    CheckEqual(probe.Output, '', 'and nothing was captured');
    Record_('probe|resolve-inside-project|' +
      PWebCliProbeOutcomeText(probe.Outcome));
  end;
end;

{ ---------------------------------------------------------------------------
  the corpus
  --------------------------------------------------------------------------- }

procedure WriteCorpus;
var
  i: PtrInt;
  text: RawUtf8;
begin
  text := '# CAP-10A CLI decision corpus' + #10 +
    '# every line is the verdict of platform-independent logic; no path,' +
    #10 + '# no version and no timing appears here, by construction' + #10;
  for i := 0 to High(Corpus) do
    text := text + Corpus[i] + #10;
  ForceDirectories(ExtractFilePath(PWEB_CAP10A_CORPUS_FILE));
  FileFromString(text, PWEB_CAP10A_CORPUS_FILE);
end;

initialization

finalization
  WriteCorpus;

end.
