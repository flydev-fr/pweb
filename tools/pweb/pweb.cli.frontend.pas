{
  pweb.cli.frontend - the frontend half of the pipeline (CAP-10C1).

  Two frontends, one shape: install what a lockfile pins, typecheck, build,
  and hand the pipeline a DIRECTORY the frozen CAP-6 bundler can pack.

    react    node <npm-cli.js> ci   ->  node tsc  ->  node vite build
             and the built directory is frontend/dist, where vite.config.ts
             (the project's own, never overridden here) puts it
    pas2js   the pinned compiler, then the ratified assembly below
             - entirely offline, and needing no Node at any point

  ---------------------------------------------------------------------------
  RESOLVING AN EXECUTABLE AND HANDING node A SCRIPT ARE DIFFERENT ACTS
  ---------------------------------------------------------------------------

  The CAP-10A rule "a candidate that resolves inside the project root is
  reported and never executed" is about EXECUTABLE RESOLUTION: which binary
  a name on PATH means. It is enforced in pweb.cli.toolset, and node, fpc and
  pas2js are all resolved by it.

  What happens here is the other thing: the RESOLVED node is handed a
  JavaScript file out of the project's own installed dependencies. That is
  not a loophole, it is what a frontend build IS - tsc and vite are packages
  the committed lockfile pins, installed by `npm ci` from that lockfile, and
  a build that refused to run them would be a build that cannot build a
  frontend. What the rule protects against is a stray binary called `node`
  deciding what `node` means, and that protection is untouched.

  On Windows those packages' PATH entries are .cmd shims, which the CAP-10C0
  engine refuses on every platform - so naming the .js entry point directly
  is also the only form that works at all without a shell.

  ---------------------------------------------------------------------------
  `ci`, NEVER `install`, AND NOTHING UNREVIEWED RUNS
  ---------------------------------------------------------------------------

    ci                 the committed package-lock.json is authoritative;
                       `install` would resolve floating ranges and make the
                       product different on every machine
    --no-audit         an audit is a network round trip that changes nothing
    --no-fund          likewise
    --ignore-scripts   MEASURED on the pinned tree: exactly ONE package
                       carries an install script - fsevents 2.3.3, dev and
                       optional and darwin-only, reached only by the dev
                       watcher and never by `vite build`. So the policy costs
                       nothing and buys the whole class: no unreviewed
                       lifecycle script runs, on any platform, ever.

  @pweb/runtime is a project-relative `file:` specifier that npm LINKS to
  frontend/.pweb/sdk/typescript. It is never fetched, and no registry ever
  answers for that name - which is why the SDK staging stage has to have run
  first, and why a stale staging is removed rather than merged.

  ---------------------------------------------------------------------------
  THE PAS2JS ASSEMBLY IS A MEASUREMENT, NOT A PREFERENCE
  ---------------------------------------------------------------------------

  Pas2JS writes its output through the host's text layer. MEASURED by
  CAP-10B2: on Windows app.js begins EF BB BF and carries CRLF; on POSIX it
  carries LF. Packing the compiler's raw bytes would make the Pas2JS app.pwb
  an OS-family artifact and its four-target semantic digest unsatisfiable by
  construction. So the BOM is stripped and EVERY CR is removed - every one,
  not only those in a CRLF pair, because a rule that treats a lone CR
  differently on two platforms is the same comparer disagreement in a
  different disguise.

  assets/boot.js is written byte-exactly with LF. -Jc concatenates the RTL
  and declares `rtl` without starting it, so a later CLASSIC script in the
  same global scope is all that is needed: no module, no defer, and above
  all no INLINE code, which the ratified script-src 'self' forbids and
  CAP-8B measured blocked on all three engines.
}
unit pweb.cli.frontend;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  pweb.cli.platform,
  pweb.cli.toolchain,
  pweb.cli.project,
  pweb.cli.stage;

const
  /// the npm subcommand and its flags, ratified at the CAP-10C1 checkpoint
  PWEB_NPM_CI: array[0 .. 3] of RawUtf8 = (
    'ci', '--no-audit', '--no-fund', '--ignore-scripts');

  /// where the two Node entry points live inside an installed frontend
  PWEB_FE_NODE_MODULES = 'node_modules';
  PWEB_FE_TSC_PKG = 'typescript';
  PWEB_FE_TSC_BIN = 'bin';
  PWEB_FE_TSC = 'tsc';
  PWEB_FE_VITE_PKG = 'vite';
  PWEB_FE_VITE_BIN = 'bin';
  PWEB_FE_VITE = 'vite.js';

  /// the staged SDK's home inside a project, and the built frontend
  PWEB_FE_PWEB_DIR = '.pweb';
  PWEB_FE_SDK_DIR = 'sdk';
  PWEB_FE_TS_DIR = 'typescript';
  PWEB_FE_DIST = 'dist';
  PWEB_FE_ASSETS = 'assets';

  /// the project files a Pas2JS frontend contributes to its static output
  PWEB_FE_INDEX = 'index.html';
  PWEB_FE_APP_CSS = 'app.css';
  PWEB_FE_APP_JS = 'app.js';
  PWEB_FE_BOOT_JS = 'boot.js';
  PWEB_FE_PAS2JS_CFG = 'pas2js.cfg';
  PWEB_FE_SRC = 'src';

  /// the ONE bootstrap line, byte-exact with LF
  PWEB_FE_BOOT_TEXT = 'rtl.run();'#10;

type
  /// why a frontend stage could not be planned or assembled
  // - ordinal 0 is the accepted state
  TPWebCliFrontendRefusal = (
    pfrNone,
    /// frontend/node_modules/typescript/bin/tsc is absent after the install
    pfrTypescriptMissing,
    /// frontend/node_modules/vite/bin/vite.js is absent after the install
    pfrViteMissing,
    /// the Pas2JS entry program or its configuration is absent
    pfrPas2jsEntryMissing,
    /// the compiler produced no output where it was told to
    pfrOutputMissing,
    /// a file operation of the assembly failed
    pfrAssembly,
    /// a package manager configuration file that could redirect the
    /// registry is present in the project
    pfrRegistryOverride);

  /// what the Pas2JS assembly had to normalise, recorded per target
  TPWebCliPas2jsNormalisation = record
    HadBom: Boolean;
    HadCr: Boolean;
  end;

/// fixed diagnostic text - the machine authority, never localized prose
function PWebCliFrontendRefusalText(
  Refusal: TPWebCliFrontendRefusal): RawUtf8;

/// `node <npm-cli.js> ci --no-audit --no-fund --ignore-scripts`
function PWebCliNpmCiCommand(const NodePath, NpmCli,
  FrontendRoot: RawUtf8): TPWebCliCommand;

/// `node <frontend>/node_modules/typescript/bin/tsc -p tsconfig.json`
function PWebCliTypecheckCommand(const NodePath, FrontendRoot: RawUtf8;
  out Cmd: TPWebCliCommand;
  out Refusal: TPWebCliFrontendRefusal): Boolean;

/// `node <frontend>/node_modules/vite/bin/vite.js build`
function PWebCliViteCommand(const NodePath, FrontendRoot: RawUtf8;
  out Cmd: TPWebCliCommand;
  out Refusal: TPWebCliFrontendRefusal): Boolean;

/// `pas2js @<frontend>/pas2js.cfg -Fu<sdk pas2js> -o<dist>/assets/app.js
///  <frontend>/src/<ident>app.lpr`
function PWebCliPas2jsCommand(const Pas2jsPath, FrontendRoot, SdkPas2js,
  OutJs: RawUtf8; const Project: TPWebCliProject; out Cmd: TPWebCliCommand;
  out Refusal: TPWebCliFrontendRefusal): Boolean;

/// True when the project carries a package-manager configuration that could
/// redirect a registry
// - the templates ship none, and the mutation gate proves the tree is the
// generated one; this is the third lock, and the only one that is a REFUSAL
// - Unreadable is True when the WALK failed (an unreadable directory, a tree
// past its bound). A caller must treat that as a refusal too: a check that
// answers "nothing found" when it could not look is a check that disappears
// on exactly the trees worth checking
// - Excludes is the caller's writable set, DERIVED from the descriptor
// (PWebCliMutationSet) and never restated here. A project whose
// frontend.root is `web` and whose output is `out` populates `web/...`, and
// a scan with `frontend/...` written into it would walk a real node_modules
// - hashing thousands of files and refusing on an .npmrc a DEPENDENCY ships
function PWebCliRegistryOverridePresent(const Root: RawUtf8;
  const Excludes: TRawUtf8DynArray; out Found: RawUtf8;
  out Unreadable: Boolean): Boolean;

/// normalise the compiler's output and assemble the ratified static set
// - DistDir must already exist and hold assets/app.js and nothing else
function PWebCliAssemblePas2jsDist(const FrontendRoot, DistDir: RawUtf8;
  out Normalisation: TPWebCliPas2jsNormalisation;
  out Refusal: TPWebCliFrontendRefusal): Boolean;


implementation

function PWebCliFrontendRefusalText(
  Refusal: TPWebCliFrontendRefusal): RawUtf8;
begin
  case Refusal of
    pfrNone:                Result := 'ok';
    pfrTypescriptMissing:   Result := 'typescript_missing';
    pfrViteMissing:         Result := 'vite_missing';
    pfrPas2jsEntryMissing:  Result := 'pas2js_entry_missing';
    pfrOutputMissing:       Result := 'frontend_output_missing';
    pfrAssembly:            Result := 'frontend_assembly_failed';
    pfrRegistryOverride:    Result := 'registry_override_present';
  else
    Result := 'frontend_refused';
  end;
end;

procedure Push(var Args: TRawUtf8DynArray; const Value: RawUtf8);
begin
  SetLength(Args, Length(Args) + 1);
  Args[High(Args)] := Value;
end;

function PWebCliNpmCiCommand(const NodePath, NpmCli,
  FrontendRoot: RawUtf8): TPWebCliCommand;
var
  i: PtrInt;
begin
  Result := Default(TPWebCliCommand);
  Result.Exe := NodePath;
  Push(Result.Args, PWebCliArgPath(NpmCli));
  for i := 0 to High(PWEB_NPM_CI) do
    Push(Result.Args, PWEB_NPM_CI[i]);
  Result.WorkDir := FrontendRoot;
end;

// walk node_modules/<pkg>/<bin>/<file> one component at a time, so a
// redirected package is refused rather than followed
function NodeEntryPoint(const FrontendRoot, Pkg, BinDir, FileName: RawUtf8;
  out Script: RawUtf8): Boolean;
var
  cur: RawUtf8;
begin
  Script := '';
  Result := False;
  if PWebCliEntry(FrontendRoot, PWEB_FE_NODE_MODULES) <> pcnDirectory then
    exit;
  cur := PWebCliJoin(FrontendRoot, PWEB_FE_NODE_MODULES);
  if PWebCliEntry(cur, Pkg) <> pcnDirectory then
    exit;
  cur := PWebCliJoin(cur, Pkg);
  if PWebCliEntry(cur, BinDir) <> pcnDirectory then
    exit;
  cur := PWebCliJoin(cur, BinDir);
  if PWebCliEntry(cur, FileName) <> pcnFile then
    exit;
  Script := PWebCliJoin(cur, FileName);
  Result := True;
end;

function PWebCliTypecheckCommand(const NodePath, FrontendRoot: RawUtf8;
  out Cmd: TPWebCliCommand;
  out Refusal: TPWebCliFrontendRefusal): Boolean;
var
  script: RawUtf8;
begin
  Cmd := Default(TPWebCliCommand);
  Refusal := pfrTypescriptMissing;
  Result := NodeEntryPoint(FrontendRoot, PWEB_FE_TSC_PKG, PWEB_FE_TSC_BIN,
    PWEB_FE_TSC, script);
  if not Result then
    exit;
  Cmd.Exe := NodePath;
  Push(Cmd.Args, PWebCliArgPath(script));
  // the project's own tsconfig.json, named exactly as its `typecheck`
  // script names it - a relative name, resolved against the working
  // directory this command states
  Push(Cmd.Args, '-p');
  Push(Cmd.Args, 'tsconfig.json');
  Cmd.WorkDir := FrontendRoot;
  Refusal := pfrNone;
end;

function PWebCliViteCommand(const NodePath, FrontendRoot: RawUtf8;
  out Cmd: TPWebCliCommand;
  out Refusal: TPWebCliFrontendRefusal): Boolean;
var
  script: RawUtf8;
begin
  Cmd := Default(TPWebCliCommand);
  Refusal := pfrViteMissing;
  Result := NodeEntryPoint(FrontendRoot, PWEB_FE_VITE_PKG, PWEB_FE_VITE_BIN,
    PWEB_FE_VITE, script);
  if not Result then
    exit;
  Cmd.Exe := NodePath;
  Push(Cmd.Args, PWebCliArgPath(script));
  Push(Cmd.Args, 'build');
  Cmd.WorkDir := FrontendRoot;
  Refusal := pfrNone;
end;

function PWebCliPas2jsCommand(const Pas2jsPath, FrontendRoot, SdkPas2js,
  OutJs: RawUtf8; const Project: TPWebCliProject; out Cmd: TPWebCliCommand;
  out Refusal: TPWebCliFrontendRefusal): Boolean;
var
  srcDir, entry, cfg: RawUtf8;
begin
  Cmd := Default(TPWebCliCommand);
  Refusal := pfrPas2jsEntryMissing;
  Result := False;
  if PWebCliEntry(FrontendRoot, PWEB_FE_PAS2JS_CFG) <> pcnFile then
    exit;
  cfg := PWebCliJoin(FrontendRoot, PWEB_FE_PAS2JS_CFG);
  if PWebCliEntry(FrontendRoot, PWEB_FE_SRC) <> pcnDirectory then
    exit;
  srcDir := PWebCliJoin(FrontendRoot, PWEB_FE_SRC);
  // the generated entry program: the template writes it as
  // frontend/src/{{PASCAL_PROGRAM}}app.lpr, so the name is a pure function
  // of the descriptor's program identifier and never a search
  if PWebCliEntry(srcDir, Project.ProgramIdent + 'app.lpr') <> pcnFile then
    exit;
  entry := PWebCliJoin(srcDir, Project.ProgramIdent + 'app.lpr');
  Cmd.Exe := Pas2jsPath;
  // the project's own options, read IN ADDITION to the compiler's own
  // configuration; the SDK unit path and the output path are supplied
  // beside it, because both belong to the machine doing the build
  Push(Cmd.Args, '@' + PWebCliArgPath(cfg));
  Push(Cmd.Args, '-Fu' + PWebCliArgPath(SdkPas2js));
  Push(Cmd.Args, '-o' + PWebCliArgPath(OutJs));
  Push(Cmd.Args, PWebCliArgPath(entry));
  Cmd.WorkDir := FrontendRoot;
  Refusal := pfrNone;
  Result := True;
end;

function PWebCliRegistryOverridePresent(const Root: RawUtf8;
  const Excludes: TRawUtf8DynArray; out Found: RawUtf8;
  out Unreadable: Boolean): Boolean;
const
  NAMES: array[0 .. 3] of RawUtf8 = (
    '.npmrc', '.yarnrc', '.yarnrc.yml', '.pnpmfile.cjs');
var
  lines: RawUtf8;
  files: Integer;
  refusal: TPWebCliStageRefusal;
  i, start, j: PtrInt;
  row, name: RawUtf8;
begin
  Found := '';
  Unreadable := False;
  Result := False;
  // the whole project tree minus what a build itself populates: an .npmrc
  // npm would read can sit anywhere from the frontend root upward inside
  // the project, and node_modules legitimately contains dozens
  if not PWebCliPipeTreeLines(Root, Excludes, lines, files, refusal) then
  begin
    Unreadable := True;
    exit;
  end;
  start := 1;
  for i := 1 to Length(lines) + 1 do
    if (i > Length(lines)) or
       (lines[i] = #10) then
    begin
      row := Copy(lines, start, i - start);
      start := i + 1;
      if row = '' then
        continue;
      // the logical path is everything before the first '|'
      j := Pos('|', row);
      if j > 0 then
        row := Copy(row, 1, j - 1);
      name := row;
      for j := Length(row) downto 1 do
        if row[j] = '/' then
        begin
          name := Copy(row, j + 1, Length(row) - j);
          break;
        end;
      for j := 0 to High(NAMES) do
        // ASCII case-insensitively: npm reads `.NPMRC` on a case-folding
        // volume, and a byte-exact comparison would miss it there
        if LowerCaseU(name) = NAMES[j] then
        begin
          Found := row;
          Result := True;
          exit;
        end;
    end;
end;

function PWebCliAssemblePas2jsDist(const FrontendRoot, DistDir: RawUtf8;
  out Normalisation: TPWebCliPas2jsNormalisation;
  out Refusal: TPWebCliFrontendRefusal): Boolean;
var
  assetsDir, outJs: RawUtf8;
  raw, normalised, stripped: RawByteString;
  tooBig: Boolean;
  stage: TPWebCliStageRefusal;
  i, n: PtrInt;
begin
  Normalisation := Default(TPWebCliPas2jsNormalisation);
  Result := False;
  Refusal := pfrOutputMissing;
  if PWebCliEntry(DistDir, PWEB_FE_ASSETS) <> pcnDirectory then
    exit;
  assetsDir := PWebCliJoin(DistDir, PWEB_FE_ASSETS);
  if PWebCliEntry(assetsDir, PWEB_FE_APP_JS) <> pcnFile then
    exit;
  outJs := PWebCliJoin(assetsDir, PWEB_FE_APP_JS);
  if not PWebCliReadSmallFile(outJs, PWEB_CLI_PIPE_MAX_FILE_BYTES, raw,
       tooBig) then
    exit;

  Refusal := pfrAssembly;
  Normalisation.HadBom := (Length(raw) >= 3) and
    (raw[1] = #$EF) and (raw[2] = #$BB) and (raw[3] = #$BF);
  normalised := raw;
  if Normalisation.HadBom then
    normalised := Copy(normalised, 4, Length(normalised) - 3);
  // a SEPARATE destination: writing back into `raw` while iterating
  // `normalised` - its own refcounted alias - is correct only because
  // SetLength uniquifies, and a rule that rests on copy-on-write timing is
  // a rule nobody should have to re-derive
  n := 0;
  SetLength(stripped, Length(normalised));
  for i := 1 to Length(normalised) do
    if normalised[i] = #13 then
      Normalisation.HadCr := True
    else
    begin
      Inc(n);
      stripped[n] := normalised[i];
    end;
  SetLength(stripped, n);
  if Normalisation.HadBom or
     Normalisation.HadCr then
  begin
    // this unit never replaces: the compiler's file is removed and the
    // normalised one is created, so a half-written rewrite is impossible
    if not PWebCliDeleteFile(outJs) then
      exit;
    if not PWebCliWriteNewFile(outJs, stripped, {SetExecBit=}False) then
      exit;
  end;

  if not PWebCliWriteNewFile(PWebCliJoin(assetsDir, PWEB_FE_BOOT_JS),
       RawByteString(PWEB_FE_BOOT_TEXT), {SetExecBit=}False) then
    exit;
  if not PWebCliPipeCopyFile(PWebCliJoin(FrontendRoot, PWEB_FE_INDEX),
       PWebCliJoin(DistDir, PWEB_FE_INDEX), stage) then
    exit;
  if not PWebCliPipeCopyFile(PWebCliJoin(FrontendRoot, PWEB_FE_APP_CSS),
       PWebCliJoin(assetsDir, PWEB_FE_APP_CSS), stage) then
    exit;
  Refusal := pfrNone;
  Result := True;
end;

end.
