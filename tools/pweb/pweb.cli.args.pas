{
  pweb.cli.args - the one command-line parser of the pweb CLI (CAP-10A).

  ONE parser, one grammar, identical on all four targets.

  ---------------------------------------------------------------------------
  WHY NOT mORMot'S TExecutableCommandLine
  ---------------------------------------------------------------------------

  Because it is deliberately forgiving where this contract must be exact. It
  accepts `/option` as an option on Windows and not on POSIX, which is the
  platform-divergent parsing the CAP-10A contract forbids in as many words;
  and it is tolerant of unknown options, where the public CLI must refuse
  them. Every other mORMot core utility this CLI wanted - UTF-8, RawUtf8,
  SemVer, hashing, console handling - is used unchanged.

  ---------------------------------------------------------------------------
  THE GRAMMAR
  ---------------------------------------------------------------------------

    pweb --help
    pweb --version
    pweb doctor [--json] [--with-paths] [--project <path>] [--no-color]
                [--verbose]

  Long options only. There are no short forms in v1 - not because they are
  bad, but because every alias is a second spelling of one contract and this
  one is about to be frozen. Values may be written `--project X` or
  `--project=X`; an empty value is an error rather than a default.

  REFUSED, each with its own cause: an unknown command, an unknown option, a
  repeated option, a missing value, an empty value, an option that does not
  belong to the command, more than one positional, a token that is not valid
  UTF-8, and a token carrying an embedded NUL.

  DELIBERATELY NOT IMPLEMENTED: response files (`@file` is an ordinary
  positional and is never expanded), `--` as an argument terminator (it is
  simply an unknown option), and any option that can be set from the
  environment. The CLI reads PATH and PATHEXT to FIND tools; no environment
  variable can set, override or inject an option.

  `/foo` is a positional on EVERY platform. A Windows-only option syntax
  would make `pweb doctor /json` mean two different things on two machines,
  which is the exact defect this rule exists to prevent.
}
unit pweb.cli.args;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.assets.support;

type
  /// the commands this build exposes
  // - create/dev/run/build are NOT here: an unimplemented command that
  // parses is a promise the binary cannot keep, so they are unknown
  // commands and are refused like any other
  TPWebCliCommand = (pccNone, pccDoctor);

  /// why a command line was refused - ordinal 0 is the accepted state
  TPWebCliUsage = (
    pcuNone,
    /// no command was given
    pcuNoCommand,
    pcuUnknownCommand,
    pcuUnknownOption,
    pcuDuplicateOption,
    pcuMissingValue,
    pcuEmptyValue,
    /// the option exists but not for this command
    pcuOptionNotForCommand,
    /// more than one positional argument
    pcuExtraPositional,
    /// invalid UTF-8 or an embedded NUL in an argument
    pcuEncoding);

  /// one parsed command line
  TPWebCliArgs = record
    Usage: TPWebCliUsage;
    /// the offending token, for a diagnostic that names it
    Detail: RawUtf8;
    Command: TPWebCliCommand;
    Help: Boolean;
    Version: Boolean;
    Json: Boolean;
    NoColor: Boolean;
    Verbose: Boolean;
    WithPaths: Boolean;
    ProjectPath: RawUtf8;
  end;

/// stable text for a usage refusal
function PWebCliUsageText(Usage: TPWebCliUsage): RawUtf8;

/// parse argv[1..]
function PWebCliParseArgs(const Argv: TRawUtf8DynArray): TPWebCliArgs;

implementation

function PWebCliUsageText(Usage: TPWebCliUsage): RawUtf8;
begin
  case Usage of
    pcuNone:                Result := 'ok';
    pcuNoCommand:           Result := 'no_command';
    pcuUnknownCommand:      Result := 'unknown_command';
    pcuUnknownOption:       Result := 'unknown_option';
    pcuDuplicateOption:     Result := 'duplicate_option';
    pcuMissingValue:        Result := 'missing_value';
    pcuEmptyValue:          Result := 'empty_value';
    pcuOptionNotForCommand: Result := 'option_not_for_command';
    pcuExtraPositional:     Result := 'extra_positional';
    pcuEncoding:            Result := 'argument_encoding';
  else
    Result := 'usage_error';
  end;
end;

function Refuse(var A: TPWebCliArgs; Usage: TPWebCliUsage;
  const Detail: RawUtf8): Boolean;
begin
  A.Usage := Usage;
  A.Detail := Detail;
  Result := False;
end;

// one flag, set at most once - a repeated option is a mistake worth naming
// rather than a value silently taken twice
function SetFlag(var A: TPWebCliArgs; var Flag: Boolean;
  const Token: RawUtf8): Boolean;
begin
  if Flag then
    exit(Refuse(A, pcuDuplicateOption, Token));
  Flag := True;
  Result := True;
end;

function PWebCliParseArgs(const Argv: TRawUtf8DynArray): TPWebCliArgs;
var
  i, eq: PtrInt;
  token, name, value: RawUtf8;
  hasValue, seenProject, seenPositional: Boolean;
begin
  Result := Default(TPWebCliArgs);
  seenProject := False;
  seenPositional := False;
  i := 0;
  while i <= High(Argv) do
  begin
    token := Argv[i];
    // encoding before meaning: a token that is not strict UTF-8, or that
    // carries a NUL, is refused before anything tries to interpret it
    if (Pos(#0, token) > 0) or
       not PWebStrictUtf8(token) then
    begin
      Refuse(Result, pcuEncoding, '');
      exit;
    end;
    if Copy(token, 1, 1) = '-' then
    begin
      // long options only. '-x', '--' and '-' all land here and are
      // refused by name; there is no short form and no terminator in v1.
      if Copy(token, 1, 2) <> '--' then
      begin
        Refuse(Result, pcuUnknownOption, token);
        exit;
      end;
      name := token;
      value := '';
      hasValue := False;
      eq := Pos('=', token);
      if eq > 0 then
      begin
        name := Copy(token, 1, eq - 1);
        value := Copy(token, eq + 1, MaxInt);
        hasValue := True;
      end;
      if name = '--help' then
      begin
        if hasValue then
        begin
          Refuse(Result, pcuUnknownOption, token);
          exit;
        end;
        if not SetFlag(Result, Result.Help, name) then
          exit;
      end
      else if name = '--version' then
      begin
        if hasValue then
        begin
          Refuse(Result, pcuUnknownOption, token);
          exit;
        end;
        if not SetFlag(Result, Result.Version, name) then
          exit;
      end
      else if name = '--json' then
      begin
        if hasValue then
        begin
          Refuse(Result, pcuUnknownOption, token);
          exit;
        end;
        if not SetFlag(Result, Result.Json, name) then
          exit;
      end
      else if name = '--no-color' then
      begin
        if hasValue then
        begin
          Refuse(Result, pcuUnknownOption, token);
          exit;
        end;
        if not SetFlag(Result, Result.NoColor, name) then
          exit;
      end
      else if name = '--verbose' then
      begin
        if hasValue then
        begin
          Refuse(Result, pcuUnknownOption, token);
          exit;
        end;
        if not SetFlag(Result, Result.Verbose, name) then
          exit;
      end
      else if name = '--with-paths' then
      begin
        if hasValue then
        begin
          Refuse(Result, pcuUnknownOption, token);
          exit;
        end;
        if not SetFlag(Result, Result.WithPaths, name) then
          exit;
      end
      else if name = '--project' then
      begin
        if seenProject then
        begin
          Refuse(Result, pcuDuplicateOption, name);
          exit;
        end;
        if not hasValue then
        begin
          // the separate-token spelling; the next argument is the value,
          // and an option in that position is a MISSING value rather than
          // a value that happens to start with a dash
          if (i >= High(Argv)) or
             (Copy(Argv[i + 1], 1, 1) = '-') then
          begin
            Refuse(Result, pcuMissingValue, name);
            exit;
          end;
          Inc(i);
          value := Argv[i];
          if (Pos(#0, value) > 0) or
             not PWebStrictUtf8(value) then
          begin
            Refuse(Result, pcuEncoding, '');
            exit;
          end;
        end;
        if value = '' then
        begin
          Refuse(Result, pcuEmptyValue, name);
          exit;
        end;
        Result.ProjectPath := value;
        seenProject := True;
      end
      else
      begin
        Refuse(Result, pcuUnknownOption, name);
        exit;
      end;
    end
    else
    begin
      // a positional. '@file' and '/foo' arrive here on EVERY platform: a
      // response file is never expanded and a slash is never an option.
      if seenPositional then
      begin
        Refuse(Result, pcuExtraPositional, token);
        exit;
      end;
      seenPositional := True;
      if token = 'doctor' then
        Result.Command := pccDoctor
      else
      begin
        Refuse(Result, pcuUnknownCommand, token);
        exit;
      end;
    end;
    Inc(i);
  end;
  // options that belong to a command are refused elsewhere, even when the
  // line would otherwise be a help or version request: a line that names an
  // option out of place is wrong whatever else it asks for
  if (Result.Command <> pccDoctor) and
     (Result.Json or Result.WithPaths) then
  begin
    if Result.Json then
      Refuse(Result, pcuOptionNotForCommand, '--json')
    else
      Refuse(Result, pcuOptionNotForCommand, '--with-paths');
    exit;
  end;
  if Result.Help or Result.Version then
    exit; // both are complete requests on their own
  if not seenPositional then
  begin
    Refuse(Result, pcuNoCommand, '');
    exit;
  end;
end;

end.
