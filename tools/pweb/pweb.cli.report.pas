{
  pweb.cli.report - the human and JSON projections of one doctor report
  (CAP-10A).

  BOTH emitters read the SAME TPWebCliReport. Neither computes a status,
  re-runs a check, or knows anything the other does not: if the two ever
  disagree it is because one of them formats badly, never because they
  measured different things.

  ---------------------------------------------------------------------------
  THE JSON IS A PUBLIC CONTRACT
  ---------------------------------------------------------------------------

  Canonical by construction: fixed key order, rows sorted by id (the engine
  does that), UTF-8, no ANSI, no localized prose in any machine field, and NO
  TIMESTAMP anywhere - a document that changes every second cannot be
  compared across four platforms, and comparing it across four platforms is
  the point.

  Paths are REDACTED by default, and that is not only a privacy measure: a
  machine path is the one field that cannot be equal on a Windows runner, an
  Ubuntu runner and two macOS runners, so redaction is also what makes the
  corpus four-way comparable. Inside the project a path becomes
  '<project>/relative'; outside it becomes '<external>/basename'.
  `--with-paths` opts into absolute paths for a human who is debugging.

  ---------------------------------------------------------------------------
  THE HUMAN REPORT
  ---------------------------------------------------------------------------

  ASCII status markers, never emoji: [ ok ] [warn] [fail] [ -- ]. Colour only
  when stdout is a terminal that accepted the request, never when redirected
  and never with --no-color or --json. Nothing semantic depends on terminal
  width - the columns are fixed and a narrow terminal wraps text, not
  meaning.
}
unit pweb.cli.report;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.rpc.intf,
  pweb.cli.platform,
  pweb.cli.project,
  pweb.cli.doctor,
  pweb.cli.args; // the supported-UI allowlist, so help cannot contradict it

type
  /// how a report should be rendered
  TPWebCliRenderOptions = record
    /// ANSI SGR is permitted (already ANDed with terminal + --no-color)
    Color: Boolean;
    /// show observed/expected for passing rows too
    Verbose: Boolean;
    /// emit absolute paths instead of the redacted forms
    WithPaths: Boolean;
  end;

/// redact one path against a project root
// - '' stays ''; inside the root becomes '<project>/rel'; anything else
// becomes '<external>/basename'
function PWebCliRedactPath(const Path, Root: RawUtf8): RawUtf8;

/// the human report
function PWebCliRenderHuman(const Report: TPWebCliReport;
  const Project: TPWebCliProject; const Env: TPWebCliDoctorEnv;
  const Options: TPWebCliRenderOptions): RawUtf8;

/// the canonical machine report
function PWebCliRenderJson(const Report: TPWebCliReport;
  const Project: TPWebCliProject; const Env: TPWebCliDoctorEnv;
  const Options: TPWebCliRenderOptions): RawUtf8;

/// the usage text - the only place the command surface is spelled
function PWebCliUsageBanner: RawUtf8;

/// the `pweb create --help` text
// - it advertises exactly the frontend kinds this build can scaffold, in the
// parser's own spelling and joined by '|', and the gate parses the set back
// OUT of this text rather than restating it: a help text and a parser that
// disagree is how a CLI ends up promising a template nobody shipped
function PWebCliCreateHelp: RawUtf8;

/// the `pweb run --help` text
function PWebCliRunHelp: RawUtf8;

/// the --version line
function PWebCliVersionLine: RawUtf8;

implementation

const
  CRLF_NONE = #10;
  ANSI_RESET = #27'[0m';
  ANSI_GREEN = #27'[32m';
  ANSI_YELLOW = #27'[33m';
  ANSI_RED = #27'[31m';
  ANSI_DIM = #27'[2m';

function PWebCliVersionLine: RawUtf8;
begin
  Result := 'pweb ' + PWEB_CLI_VERSION + ' (protocol ' +
    RawUtf8(IntToStr(PWEB_PROTOCOL_VERSION)) + ')';
end;

function PWebCliUsageBanner: RawUtf8;
begin
  // dev/build are absent ON PURPOSE. This build does not implement them,
  // and a command listed in help that answers "not implemented" is a
  // contract nobody can rely on either way. `create` appeared here in
  // CAP-10B1 and `run` in CAP-10C0, each in the shard that made it a
  // command that does the whole of what its name says.
  Result :=
    'pweb - the PWeb application lifecycle CLI' + CRLF_NONE +
    CRLF_NONE +
    'usage:' + CRLF_NONE +
    '  pweb --help' + CRLF_NONE +
    '  pweb --version' + CRLF_NONE +
    '  pweb create NAME --ui ' + PWEB_CLI_UI_REACT + '|' +
      PWEB_CLI_UI_PAS2JS + ' --bundle-id <reverse.dns>' + CRLF_NONE +
    '  pweb doctor [--json] [--with-paths] [--project <path>]' + CRLF_NONE +
    '              [--no-color] [--verbose]' + CRLF_NONE +
    '  pweb run [--project <path>]' + CRLF_NONE +
    CRLF_NONE +
    'commands:' + CRLF_NONE +
    '  create         create a new PWeb project (pweb create --help)' +
      CRLF_NONE +
    '  doctor         diagnose this machine against the current project' +
      CRLF_NONE +
    '  run            launch the already-built application and supervise' +
      CRLF_NONE +
    '                 it in the foreground (pweb run --help)' + CRLF_NONE +
    CRLF_NONE +
    'options:' + CRLF_NONE +
    '  --ui <kind>    the frontend kind to scaffold (create only)' +
      CRLF_NONE +
    '  --bundle-id <id>' + CRLF_NONE +
    '                 the application identity, e.g. com.example.demo' +
      CRLF_NONE +
    '                 (create only, required, never defaulted)' + CRLF_NONE +
    '  --project <p>  use this pweb.json, or the project rooted at this' +
      CRLF_NONE +
    '                 directory, instead of searching upward from the' +
      CRLF_NONE +
    '                 working directory' + CRLF_NONE +
    '  --json         emit the canonical machine report (doctor only)' +
      CRLF_NONE +
    '  --with-paths   emit absolute paths instead of redacted ones' +
      CRLF_NONE +
    '  --no-color     never emit terminal colour' + CRLF_NONE +
    '  --verbose      show observed and expected values for every row' +
      CRLF_NONE +
    '  --help         show this text' + CRLF_NONE +
    '  --version      show the CLI and protocol version' + CRLF_NONE +
    CRLF_NONE +
    'exit codes:' + CRLF_NONE +
    '  0 success   2 usage   3 project   4 environment   5 probe' +
      CRLF_NONE +
    '  6 internal' + CRLF_NONE;
end;

function PWebCliCreateHelp: RawUtf8;
begin
  // the supported kinds are INTERPOLATED from the parser's own allowlist, so
  // this text cannot advertise a frontend the parser refuses
  Result :=
    'pweb create - create a new PWeb project' + CRLF_NONE +
    CRLF_NONE +
    'usage:' + CRLF_NONE +
    '  pweb create NAME --ui ' + PWEB_CLI_UI_REACT + '|' +
      PWEB_CLI_UI_PAS2JS + ' --bundle-id <reverse.dns>' + CRLF_NONE +
    CRLF_NONE +
    'arguments:' + CRLF_NONE +
    '  NAME           the project name: lowercase letters and digits,' +
      CRLF_NONE +
    '                 starting with a letter. It is also the directory,' +
      CRLF_NONE +
    '                 the Pascal program identifier and the executable' +
      CRLF_NONE +
    '                 base name, so it is stated once and never derived' +
      CRLF_NONE +
    CRLF_NONE +
    'options:' + CRLF_NONE +
    '  --ui <kind>    the frontend kind. This build supports: ' +
      PWEB_CLI_UI_REACT + '|' + PWEB_CLI_UI_PAS2JS + CRLF_NONE +
    '  --bundle-id <id>' + CRLF_NONE +
    '                 the application identity, e.g. com.example.demo.' +
      CRLF_NONE +
    '                 Required and never defaulted: it becomes the macOS' +
      CRLF_NONE +
    '                 bundle identifier and the Windows setup identity' +
      CRLF_NONE +
    '  --help         show this text' + CRLF_NONE +
    CRLF_NONE +
    'the destination is NAME inside the current directory, and it must not' +
      CRLF_NONE +
    'exist. Creation is offline: it writes source files and does not run a' +
      CRLF_NONE +
    'package manager, start a compiler, initialise a repository or open a' +
      CRLF_NONE +
    'network connection.' + CRLF_NONE +
    CRLF_NONE +
    'exit codes:' + CRLF_NONE +
    '  0 success   2 usage   3 project   4 environment   6 internal' +
      CRLF_NONE;
end;

function PWebCliRunHelp: RawUtf8;
begin
  Result :=
    'pweb run - launch the already-built application and supervise it' +
      CRLF_NONE +
    CRLF_NONE +
    'usage:' + CRLF_NONE +
    '  pweb run [--project <path>]' + CRLF_NONE +
    CRLF_NONE +
    'options:' + CRLF_NONE +
    '  --project <p>  use this pweb.json, or the project rooted at this' +
      CRLF_NONE +
    '                 directory, instead of searching upward from the' +
      CRLF_NONE +
    '                 working directory' + CRLF_NONE +
    '  --help         show this text' + CRLF_NONE +
    CRLF_NONE +
    'the application is taken from the project''s output directory:' +
      CRLF_NONE +
    '  <output>/<os>-<arch>/release/    the native executable and app.pwb' +
      CRLF_NONE +
    '                                   (a .app bundle on macOS)' + CRLF_NONE +
    'and must already have been built. Run builds nothing: it does not' +
      CRLF_NONE +
    'compile, run a package manager, repack app.pwb, modify the project or' +
      CRLF_NONE +
    'open a network connection. The application starts in production mode' +
      CRLF_NONE +
    'with no arguments and inherits this environment unchanged; its output' +
      CRLF_NONE +
    'is forwarded, Ctrl+C asks it to close gracefully, and every process' +
      CRLF_NONE +
    'it started is gone before pweb exits.' + CRLF_NONE +
    CRLF_NONE +
    'exit codes:' + CRLF_NONE +
    '  0 the application exited 0   2 usage   3 project or not built' +
      CRLF_NONE +
    '  4 supervision unavailable   5 the application exited nonzero, died' +
      CRLF_NONE +
    '    or had to be terminated   6 internal' + CRLF_NONE;
end;

{ ---------------------------------------------------------------------------
  path redaction
  --------------------------------------------------------------------------- }

{ Every value that did not originate as a fixed literal in this repository
  passes through here before a human sees it.

  MOST of them are already constrained - a version has been through
  PWebCliNormalizeVersion, a project name through its grammar, a path through
  the canonical-path validator. Two are NOT: the Windows engine row reports
  the runtime version string as the REGISTRY supplied it, and the host release
  line is whatever the operating system says it is. Neither is attacker
  controlled in any ordinary sense, and neither is this CLI's to promise
  control-byte-free.

  A control byte there would be an ANSI sequence written into a report that
  the --no-color path has just promised carries none - a promise about the
  RENDERER that a data source could quietly break. The JSON side is already
  safe (its escaper encodes every byte below 0x20), so this closes the human
  side of the same hole rather than adding a second rule. }
function Safe(const Value: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := Value;
  for i := 1 to Length(Result) do
    if (Result[i] < ' ') or
       (Result[i] = #127) then
      Result[i] := '?';
end;

function Basename(const Path: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  i := Length(Path);
  while (i > 0) and
        (Path[i] <> '/') and
        (Path[i] <> '\') do
    Dec(i);
  Result := Copy(Path, i + 1, MaxInt);
  if Result = '' then
    Result := Path;
end;

function PWebCliRedactPath(const Path, Root: RawUtf8): RawUtf8;
var
  rel: RawUtf8;
  i: PtrInt;
begin
  if Path = '' then
    exit('');
  if (Root <> '') and
     (Length(Path) > Length(Root)) and
     (Copy(Path, 1, Length(Root)) = Root) then
  begin
    rel := Copy(Path, Length(Root) + 2, MaxInt);
    for i := 1 to Length(rel) do
      if rel[i] = '\' then
        rel[i] := '/'; // one logical spelling in the machine document
    exit('<project>/' + rel);
  end;
  if (Root <> '') and
     (Path = Root) then
    exit('<project>');
  Result := '<external>/' + Basename(Path);
end;

function RenderPath(const Path, Root: RawUtf8;
  const Options: TPWebCliRenderOptions): RawUtf8;
begin
  if Path = '' then
    Result := ''
  else if Options.WithPaths then
    Result := PWebCliDisplayPath(Path)
  else
    Result := PWebCliRedactPath(Path, Root);
end;

{ ---------------------------------------------------------------------------
  human
  --------------------------------------------------------------------------- }

function Marker(Status: TPWebCliStatus): RawUtf8;
begin
  // ASCII only. An emoji is not a status vocabulary: it renders as a box on
  // half the consoles this runs on and cannot be grepped for.
  case Status of
    pdsPass:          Result := '[ ok ]';
    pdsNotApplicable: Result := '[ -- ]';
    pdsWarning:       Result := '[warn]';
  else
    Result := '[fail]';
  end;
end;

function Colorize(const Text: RawUtf8; Status: TPWebCliStatus;
  Color: Boolean): RawUtf8;
begin
  if not Color then
    exit(Text);
  case Status of
    pdsPass:          Result := ANSI_GREEN + Text + ANSI_RESET;
    pdsNotApplicable: Result := ANSI_DIM + Text + ANSI_RESET;
    pdsWarning:       Result := ANSI_YELLOW + Text + ANSI_RESET;
  else
    Result := ANSI_RED + Text + ANSI_RESET;
  end;
end;

function Pad(const S: RawUtf8; Width: PtrInt): RawUtf8;
begin
  Result := S;
  while Length(Result) < Width do
    Result := Result + ' ';
end;

function PWebCliRenderHuman(const Report: TPWebCliReport;
  const Project: TPWebCliProject; const Env: TPWebCliDoctorEnv;
  const Options: TPWebCliRenderOptions): RawUtf8;
var
  i: PtrInt;
  c: TPWebCliCheck;
  line, path: RawUtf8;
begin
  Result := PWebCliVersionLine + CRLF_NONE;
  Result := Result + 'host    ' + Env.OsText + '/' + Env.ArchText +
    '  ' + Safe(Env.Release) + CRLF_NONE;
  if Project.Refusal = pcrNone then
    Result := Result + 'project ' + Safe(Project.Name) + ' ' +
      Safe(Project.Version) + ' (' + PWebCliUiText(Project.Ui) + ') at ' +
      Safe(RenderPath(Project.Root, Project.Root, Options)) + CRLF_NONE
  else
    Result := Result + 'project ' +
      PWebCliProjectRefusalText(Project.Refusal) + CRLF_NONE;
  Result := Result + CRLF_NONE;
  for i := 0 to High(Report.Checks) do
  begin
    c := Report.Checks[i];
    line := '  ' + Colorize(Marker(c.Status), c.Status, Options.Color) +
      '  ' + Pad(c.Id, 24) + '  ' + Safe(c.Summary);
    Result := Result + line + CRLF_NONE;
    if (c.Status <> pdsPass) or
       Options.Verbose then
    begin
      if c.Observed <> '' then
        Result := Result + '          observed: ' + Safe(c.Observed) +
          CRLF_NONE;
      if c.Expected <> '' then
        Result := Result + '          expected: ' + Safe(c.Expected) +
          CRLF_NONE;
      path := Safe(RenderPath(c.Path, Project.Root, Options));
      if path <> '' then
        Result := Result + '          path:     ' + path + CRLF_NONE;
      if (c.Remediation <> '') and
         (c.Status <> pdsPass) then
        Result := Result + '          fix:      ' + Safe(c.Remediation) +
          CRLF_NONE;
    end;
  end;
  Result := Result + CRLF_NONE +
    RawUtf8(IntToStr(Report.CountPass)) + ' pass, ' +
    RawUtf8(IntToStr(Report.CountWarning)) + ' warning, ' +
    RawUtf8(IntToStr(Report.CountFail)) + ' fail, ' +
    RawUtf8(IntToStr(Report.CountNotApplicable)) + ' not applicable' +
    CRLF_NONE;
  Result := Result + 'doctor: ' +
    Colorize(RawUtf8(UpperCase(string(PWebCliStatusText(Report.Status)))),
      Report.Status, Options.Color) + CRLF_NONE;
end;

{ ---------------------------------------------------------------------------
  JSON
  --------------------------------------------------------------------------- }

function JsonEscape(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
  c: AnsiChar;
const
  HEX: array[0 .. 15] of AnsiChar = '0123456789abcdef';
begin
  Result := '';
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
        // an ANSI escape can only ever reach here through a bug; encoded
        // rather than emitted raw, so the document stays parseable and the
        // "no ANSI in JSON" gate stays a byte test
        Result := Result + '\u00' + HEX[Ord(c) shr 4] + HEX[Ord(c) and 15]
      else
        Result := Result + c;
    end;
  end;
end;

function Str(const Name, Value: RawUtf8): RawUtf8;
begin
  Result := '"' + Name + '":"' + JsonEscape(Value) + '"';
end;

function Num(const Name: RawUtf8; Value: Integer): RawUtf8;
begin
  Result := '"' + Name + '":' + RawUtf8(IntToStr(Value));
end;

function Bool(const Name: RawUtf8; Value: Boolean): RawUtf8;
begin
  if Value then
    Result := '"' + Name + '":true'
  else
    Result := '"' + Name + '":false';
end;

function PWebCliRenderJson(const Report: TPWebCliReport;
  const Project: TPWebCliProject; const Env: TPWebCliDoctorEnv;
  const Options: TPWebCliRenderOptions): RawUtf8;
var
  i: PtrInt;
  c: TPWebCliCheck;
begin
  // fixed key order, two-space indentation, LF only: the document is
  // compared byte-for-byte across four targets, so its SHAPE is as much a
  // contract as its content
  Result := '{' + CRLF_NONE +
    '  ' + Num('doctor', PWEB_CLI_DOCTOR_SCHEMA) + ',' + CRLF_NONE +
    '  "cli": {' + Str('version', PWEB_CLI_VERSION) + ',' +
      Num('protocol', PWEB_PROTOCOL_VERSION) + '},' + CRLF_NONE +
    '  "host": {' + Str('os', Env.OsText) + ',' +
      Str('arch', Env.ArchText) + '},' + CRLF_NONE +
    '  "project": {' + CRLF_NONE +
    '    ' + Bool('present', Project.Refusal = pcrNone) + ',' + CRLF_NONE +
    '    ' + Str('refusal', PWebCliProjectRefusalText(Project.Refusal)) +
      ',' + CRLF_NONE +
    '    ' + Str('detail', Project.Detail) + ',' + CRLF_NONE +
    '    ' + Num('schema', Project.Schema) + ',' + CRLF_NONE +
    '    ' + Str('name', Project.Name) + ',' + CRLF_NONE +
    '    ' + Str('version', Project.Version) + ',' + CRLF_NONE +
    '    ' + Str('bundleId', Project.BundleId) + ',' + CRLF_NONE +
    '    ' + Str('ui', PWebCliUiText(Project.Ui)) + ',' + CRLF_NONE +
    '    ' + Str('programIdent', Project.ProgramIdent) + ',' + CRLF_NONE +
    '    ' + Bool('discovered', Project.Discovered) + ',' + CRLF_NONE +
    '    ' + Str('root',
      RenderPath(Project.Root, Project.Root, Options)) + ',' + CRLF_NONE +
    '    ' + Str('descriptor',
      RenderPath(Project.DescriptorPath, Project.Root, Options)) +
      CRLF_NONE +
    '  },' + CRLF_NONE +
    '  "summary": {' + Num('pass', Report.CountPass) + ',' +
      Num('warning', Report.CountWarning) + ',' +
      Num('fail', Report.CountFail) + ',' +
      Num('notApplicable', Report.CountNotApplicable) + '},' + CRLF_NONE +
    '  ' + Str('status', PWebCliStatusText(Report.Status)) + ',' +
      CRLF_NONE +
    '  "checks": [' + CRLF_NONE;
  for i := 0 to High(Report.Checks) do
  begin
    c := Report.Checks[i];
    Result := Result + '    {' +
      Str('id', c.Id) + ',' +
      Str('status', PWebCliStatusText(c.Status)) + ',' +
      Str('severity', PWebCliSeverityText(c.Severity)) + ',' +
      Str('cause', c.Cause) + ',' +
      Str('summary', c.Summary) + ',' +
      Str('observed', c.Observed) + ',' +
      Str('expected', c.Expected) + ',' +
      Str('remediation', c.Remediation) + ',' +
      Str('path', RenderPath(c.Path, Project.Root, Options)) +
      '}';
    if i < High(Report.Checks) then
      Result := Result + ',';
    Result := Result + CRLF_NONE;
  end;
  Result := Result + '  ]' + CRLF_NONE + '}' + CRLF_NONE;
end;

end.
