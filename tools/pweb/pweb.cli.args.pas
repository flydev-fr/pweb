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
    pweb create NAME --ui react|pas2js --bundle-id <reverse.dns>
    pweb create --help
    pweb doctor [--json] [--with-paths] [--project <path>] [--no-color]
                [--verbose]
    pweb run [--project <path>]
    pweb run --help
    pweb dev [--project <path>]
    pweb dev --help
    pweb build [--project <path>]
    pweb build --help

  Long options only. There are no short forms in v1 - not because they are
  bad, but because every alias is a second spelling of one contract and this
  one is about to be frozen. Values may be written `--project X` or
  `--project=X`; an empty value is an error rather than a default.

  REFUSED, each with its own cause: an unknown command, an unknown option, a
  repeated option, a missing value, an empty value, an option that does not
  belong to the command, more than one positional, a missing operand, a
  missing required option, an unsupported frontend kind, a token that is not
  valid UTF-8, and a token carrying an embedded NUL.

  CAP-10B1 ADDS EXACTLY ONE COMMAND, and the shape of the addition matters
  more than the command: `create` takes a SECOND positional, which is
  accepted only after `create` itself, so `pweb doctor extra` is still the
  extra-positional refusal it always was. `--ui` and `--bundle-id` are
  create-only and `--project` is refused ON a create line, so an option can
  never be silently ignored by the command it was not meant for.

  THE SUPPORTED FRONTEND KINDS LIVE HERE, in a compiled allowlist, and not
  in a template lookup. `pweb create demo --ui svelte` is a USAGE failure
  rather than "no such template", because a CLI whose refusal depends on
  what happens to be in an archive is a CLI that would advertise a frontend
  the moment somebody added one. CAP-10B2 widened the allowlist to `react`
  and `pas2js` - the two kinds schema 1 has ratified since CAP-10A - in the
  same commit as the second template, and it added no alias and no case
  fold: `React` and `PAS2JS` are refused exactly like `svelte`.

  CAP-10C0 ADDS `run`, which takes `--project` and nothing else. It has no
  operand, no `--json` (it is a foreground supervisor, not a report), no
  colour and no verbosity, and - the rule that matters - NO pass-through:
  nothing typed after `run` ever reaches the application, because the
  application is launched in production mode with an empty argument vector.

  CAP-10C2 ADDS `dev`, with EXACTLY the same option set and no new usage
  cause anywhere. Every way of getting it wrong is a refusal that already
  existed - `option_not_for_command`, `duplicate_option`, `extra_positional`
  - and the ONE thing `dev` can refuse that `run` cannot is the project's
  declared `ui`, which is not a command-line fact at all and is answered by
  the dev loop with its own PROJECT cause.

  CAP-10D0 ADDS `build`, and it adds nothing else: the same option set as
  `run` and `dev`, the same refusals, and no new usage cause. `build` was an
  unknown command for as long as this executable could not perform one,
  which was the whole of the rule - a command that parses is a promise. The
  promise is now keepable, and the grammar is deliberately the SMALLEST one
  that keeps it: the frontend kind comes from `pweb.json` and never from an
  option, the target is this machine's, and every stage runs on every build,
  so there is no `--profile`, no `--target`, no `--clean`, no
  `--release`/`--debug` and no `--watch` to spell. Each of those absences is
  a contract rather than an omission: an option exposed before its semantics
  are ratified is an option that can never be taken back.

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

const
  /// the TWO frontend kinds this build can scaffold, each spelled ONCE.
  // CAP-10B1 shipped the first and CAP-10B2 added the second in the same
  // commit as the template that makes the claim true - which is the rule
  // this allowlist exists to enforce: a kind is accepted here only when a
  // trusted template for it is in the pack this executable compiled in
  PWEB_CLI_UI_REACT = 'react';
  PWEB_CLI_UI_PAS2JS = 'pas2js';

type
  /// the commands this build exposes
  // - each one arrived in the shard that made it do the whole of what its
  // name says, and never before: CAP-10B1 `create`, CAP-10C0 `run` (launch
  // what is already built), CAP-10C2/C3 `dev` (build, launch, watch,
  // rebuild, reload, for both frontend kinds) and CAP-10D0 `build` (run the
  // ten-stage lifecycle pipeline and leave the layout `run` resolves).
  // `build` was an unknown command until this one, because an unimplemented
  // command that parses is a promise the binary cannot keep
  TPWebCliCommand = (pccNone, pccCreate, pccDoctor, pccRun, pccDev, pccBuild);

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
    /// the command needs a positional operand that was not given
    pcuMissingOperand,
    /// the command needs an option that was not given
    pcuMissingOption,
    /// --ui named a frontend kind this build cannot scaffold
    pcuUnsupportedUi,
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
    /// create: the project NAME, verbatim. Its grammar is checked by the
    // scaffold engine, not here - one grammar, one owner
    Name: RawUtf8;
    /// create: the --ui value, already known to be a supported kind
    Ui: RawUtf8;
    /// create: the --bundle-id value, verbatim
    BundleId: RawUtf8;
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
    pcuMissingOperand:      Result := 'missing_operand';
    pcuMissingOption:       Result := 'missing_option';
    pcuUnsupportedUi:       Result := 'unsupported_ui';
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
  hasValue, seenProject, seenUi, seenBundleId: Boolean;
  seenPositional, seenName: Boolean;
begin
  Result := Default(TPWebCliArgs);
  seenProject := False;
  seenUi := False;
  seenBundleId := False;
  seenPositional := False;
  seenName := False;
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
      else if name = '--ui' then
      begin
        // the same value discipline as --project, spelled out rather than
        // factored: this file's whole job is that one grammar is visible
        if seenUi then
        begin
          Refuse(Result, pcuDuplicateOption, name);
          exit;
        end;
        if not hasValue then
        begin
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
        Result.Ui := value;
        seenUi := True;
      end
      else if name = '--bundle-id' then
      begin
        if seenBundleId then
        begin
          Refuse(Result, pcuDuplicateOption, name);
          exit;
        end;
        if not hasValue then
        begin
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
        Result.BundleId := value;
        seenBundleId := True;
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
      if seenName then
      begin
        Refuse(Result, pcuExtraPositional, token);
        exit;
      end;
      if seenPositional then
      begin
        // the SECOND positional belongs to `create` and to nothing else,
        // so `pweb doctor extra` is the extra-positional refusal it has
        // always been
        if Result.Command <> pccCreate then
        begin
          Refuse(Result, pcuExtraPositional, token);
          exit;
        end;
        seenName := True;
        Result.Name := token;
      end
      else
      begin
        seenPositional := True;
        if token = 'create' then
          Result.Command := pccCreate
        else if token = 'doctor' then
          Result.Command := pccDoctor
        else if token = 'run' then
          Result.Command := pccRun
        else if token = 'dev' then
          Result.Command := pccDev
        else if token = 'build' then
          Result.Command := pccBuild
        else
        begin
          Refuse(Result, pcuUnknownCommand, token);
          exit;
        end;
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
  if (Result.Command <> pccCreate) and
     (seenUi or seenBundleId) then
  begin
    if seenUi then
      Refuse(Result, pcuOptionNotForCommand, '--ui')
    else
      Refuse(Result, pcuOptionNotForCommand, '--bundle-id');
    exit;
  end;
  // create has no project to point at, and it emits no colour and no
  // verbose diagnostics at all - so each of these is an option this
  // command does not have, rather than one it quietly ignores
  if Result.Command = pccCreate then
  begin
    if seenProject then
    begin
      Refuse(Result, pcuOptionNotForCommand, '--project');
      exit;
    end;
    if Result.Verbose then
    begin
      Refuse(Result, pcuOptionNotForCommand, '--verbose');
      exit;
    end;
    if Result.NoColor then
    begin
      Refuse(Result, pcuOptionNotForCommand, '--no-color');
      exit;
    end;
  end;
  // run takes the project option and nothing else: it emits no colour, no
  // verbose diagnostics and no machine report, and the application it
  // launches receives NO argument - so each of these is an option this
  // command does not have, rather than one it quietly ignores or forwards
  // dev takes exactly what run takes and for the same reasons: it is a
  // foreground supervisor rather than a report, it emits no colour and no
  // verbose diagnostics, and NOTHING typed after it reaches the
  // application - the dev host receives one argument, and that argument is
  // this CLI's own, never the user's
  // build takes exactly what both take, and for the third time the same
  // reasons: its stage progress is a supervisor's rather than a report, it
  // emits no colour and no verbose diagnostics, and nothing typed after it
  // reaches a compiler, a package manager or a bundler - every argument a
  // stage spawns with is built by a plan builder from the descriptor
  if (Result.Command = pccRun) or
     (Result.Command = pccDev) or
     (Result.Command = pccBuild) then
  begin
    if Result.Verbose then
    begin
      Refuse(Result, pcuOptionNotForCommand, '--verbose');
      exit;
    end;
    if Result.NoColor then
    begin
      Refuse(Result, pcuOptionNotForCommand, '--no-color');
      exit;
    end;
  end;
  if Result.Help or Result.Version then
    exit; // both are complete requests on their own
  if not seenPositional then
  begin
    Refuse(Result, pcuNoCommand, '');
    exit;
  end;
  if Result.Command = pccCreate then
  begin
    // the operand and the two required options, named one at a time: a
    // diagnostic that says "usage error" and nothing else is a diagnostic
    // the reader has to guess at
    if not seenName then
    begin
      Refuse(Result, pcuMissingOperand, 'NAME');
      exit;
    end;
    if not seenUi then
    begin
      Refuse(Result, pcuMissingOption, '--ui');
      exit;
    end;
    if not seenBundleId then
    begin
      Refuse(Result, pcuMissingOption, '--bundle-id');
      exit;
    end;
    // the compiled allowlist. The comparison is BYTE-EXACT on purpose, so
    // `React` and `PAS2JS` are refused like `svelte` is: schema 1 matches
    // `ui` case-sensitively, and a CLI that accepted a spelling the
    // descriptor reader would later refuse would be scaffolding a project
    // its own doctor rejects
    if (Result.Ui <> PWEB_CLI_UI_REACT) and
       (Result.Ui <> PWEB_CLI_UI_PAS2JS) then
    begin
      Refuse(Result, pcuUnsupportedUi, Result.Ui);
      exit;
    end;
  end;
end;

end.
