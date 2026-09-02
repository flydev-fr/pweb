{
  pweb.cli.run - the run-mode output layout, and the launch of an already
  built application under supervision (CAP-10C0).

  `pweb run` launches what a project has ALREADY BUILT, in production mode,
  supervises it in the foreground, propagates its termination and leaves no
  orphaned process behind. It builds nothing, mutates nothing, downloads
  nothing and listens on nothing; every one of those is a property of what
  this unit does not link rather than of a flag it does not set.

  ---------------------------------------------------------------------------
  THE LAYOUT CONTRACT (ratified at the CAP-10C0 checkpoint; CAP-10D produces
  exactly this and nothing else)
  ---------------------------------------------------------------------------

      <root>/<output>/<os>-<arch>/release/

        windows, linux    <ident>[.exe]            the native executable
                          app.pwb                  beside it - the SAME
                                                   executable-relative rule
                                                   pweb.webview.host resolves
        macos             <ident>.app/Contents/MacOS/<ident>
                          <ident>.app/Contents/Resources/app.pwb
                          <ident>.app/Contents/Info.plist

  <os>-<arch> is this CLI's own target name (windows-x86_64, linux-x86_64,
  macos-x86_64, macos-arm64) and <ident> is the descriptor's program
  identifier - the executable base name schema 1 fixes as the basename of
  native.program. Nothing is derived from a display string and nothing is
  searched for: every component is stated once and walked exactly.

  The walk is pweb.cli.paths' PWebCliResolveUnder with no missing tail
  allowed, so the layout inherits every CAP-10A confinement rule unchanged -
  exact on-disk spelling per segment, a reparse point anywhere refusing the
  whole path, the deepest directory re-canonicalized and compared byte-exact.
  A layout that is absent is `not_built`; a layout that exists under a case
  variant, through a link, or outside the root is refused under its own
  cause and is never treated as "not built" - the two are different facts.

  ---------------------------------------------------------------------------
  THE LAUNCH
  ---------------------------------------------------------------------------

  The application is spawned by the one execution engine in its supervise
  profile with NO arguments, the executable's OWN directory as the working
  directory (never the directory `pweb` was started from), and the
  supervisor's environment inherited unchanged. Its stdout and stderr are
  forwarded line by line through the sink the caller provides; the
  supervisor's own lines are the caller's business and carry the `pweb: `
  prefix so they can never be mistaken for the application's.
}
unit pweb.cli.run;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.project,
  pweb.cli.toolchain,
  pweb.cli.process;

const
  /// the release directory beneath the target directory
  PWEB_CLI_RUN_RELEASE = 'release';
  /// the bundle, resolved exactly where the host resolves it
  PWEB_CLI_RUN_BUNDLE = 'app.pwb';
  /// the macOS bundle structure
  PWEB_CLI_RUN_APP_SUFFIX = '.app';
  PWEB_CLI_RUN_CONTENTS = 'Contents';
  PWEB_CLI_RUN_MACOS = 'MacOS';
  PWEB_CLI_RUN_RESOURCES = 'Resources';
  PWEB_CLI_RUN_PLIST = 'Info.plist';
  PWEB_CLI_RUN_WINDOWS_EXT = '.exe';

type
  /// why a project cannot be run - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebCliRunRefusal = (
    prrNone,
    /// the descriptor's `output` did not resolve (its own refusal is in
    // the project record)
    prrOutputUnresolved,
    /// a layout component is absent: the project has not been built for
    // this target
    prrNotBuilt,
    /// a layout component exists only under a different spelling
    prrLayoutCase,
    /// a symlink, junction or other reparse point on the layout chain
    prrLayoutLink,
    /// the kernel-resolved layout is not under the project root
    prrLayoutEscape,
    /// a component is the wrong kind (a directory where a file must be, a
    // device, a FIFO)
    prrLayoutShape);

  /// the resolved layout, or the reason there is none
  TPWebCliRunLayout = record
    Refusal: TPWebCliRunRefusal;
    /// the LOGICAL path (root-relative, forward slashes) that failed
    Detail: RawUtf8;
    /// the target name this layout was resolved for
    Target: RawUtf8;
    /// logical paths, for reports that must never carry an absolute path
    ExeLogical: RawUtf8;
    BundleLogical: RawUtf8;
    /// canonical native paths, for the spawn
    ExeDir: RawUtf8;
    ExePath: RawUtf8;
    BundlePath: RawUtf8;
  end;

/// fixed text for a run refusal
function PWebCliRunRefusalText(Refusal: TPWebCliRunRefusal): RawUtf8;

/// the <os>-<arch> directory name for a target
function PWebCliRunTargetName(Os: TPWebCliOs; Arch: TPWebCliArch): RawUtf8;

/// the logical paths of the layout for a target - a pure function of the
/// descriptor, so the same rule is what CAP-10D will have to produce
procedure PWebCliRunLogicalLayout(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; out Exe, Bundle, Plist: RawUtf8);

/// resolve the built layout beneath the project's `output`, confined
// - Project must be an accepted project (Refusal = pcrNone)
function PWebCliResolveRunLayout(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch): TPWebCliRunLayout;

/// launch the resolved application under supervision and run it to its end
// - no arguments, the executable's own directory, the environment inherited
// - Sink receives every forwarded line; StopCheck nil = the installed handler
function PWebCliRunApplication(const Layout: TPWebCliRunLayout;
  Sink: TPWebCliLineSink; StopCheck: TPWebCliStopCheck;
  Started: TPWebCliStartedNotify; Opaque: Pointer): TPWebCliExecResult;


implementation

function PWebCliRunRefusalText(Refusal: TPWebCliRunRefusal): RawUtf8;
begin
  case Refusal of
    prrNone:             Result := 'ok';
    prrOutputUnresolved: Result := 'output_unresolved';
    prrNotBuilt:         Result := 'not_built';
    prrLayoutCase:       Result := 'layout_case';
    prrLayoutLink:       Result := 'layout_link';
    prrLayoutEscape:     Result := 'layout_escape';
    prrLayoutShape:      Result := 'layout_shape';
  else
    Result := 'run_refused';
  end;
end;

function PWebCliRunTargetName(Os: TPWebCliOs; Arch: TPWebCliArch): RawUtf8;
var
  o, a: RawUtf8;
begin
  // spelled from the same two enumerations the doctor reports, so the
  // corpus target name and the layout directory can never drift apart
  case Os of
    pcoWindows: o := 'windows';
    pcoMacos:   o := 'macos';
  else
    o := 'linux';
  end;
  case Arch of
    pcaX86_64: a := 'x86_64';
    pcaArm64:  a := 'arm64';
  else
    a := 'other';
  end;
  Result := o + '-' + a;
end;

procedure PWebCliRunLogicalLayout(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch; out Exe, Bundle, Plist: RawUtf8);
var
  base: RawUtf8;
begin
  base := Project.Output + '/' + PWebCliRunTargetName(Os, Arch) + '/' +
    PWEB_CLI_RUN_RELEASE;
  Plist := '';
  case Os of
    pcoWindows:
      begin
        Exe := base + '/' + Project.ProgramIdent + PWEB_CLI_RUN_WINDOWS_EXT;
        Bundle := base + '/' + PWEB_CLI_RUN_BUNDLE;
      end;
    pcoMacos:
      begin
        base := base + '/' + Project.ProgramIdent + PWEB_CLI_RUN_APP_SUFFIX +
          '/' + PWEB_CLI_RUN_CONTENTS;
        Exe := base + '/' + PWEB_CLI_RUN_MACOS + '/' + Project.ProgramIdent;
        Bundle := base + '/' + PWEB_CLI_RUN_RESOURCES + '/' +
          PWEB_CLI_RUN_BUNDLE;
        Plist := base + '/' + PWEB_CLI_RUN_PLIST;
      end;
  else
    begin
      Exe := base + '/' + Project.ProgramIdent;
      Bundle := base + '/' + PWEB_CLI_RUN_BUNDLE;
    end;
  end;
end;

// one component of the layout, walked and confined exactly like a project
// path; False with the layout's refusal set
function ResolveFile(const Root, Logical: RawUtf8;
  var Layout: TPWebCliRunLayout; out Full: RawUtf8): Boolean;
var
  r: TPWebCliResolved;
begin
  Result := False;
  Full := '';
  r := PWebCliResolveUnder(Root, Logical, {AllowMissingTail=}False);
  Layout.Detail := Logical;
  case r.Refusal of
    pprNone:
      ;
    pprMissing:
      begin
        Layout.Refusal := prrNotBuilt;
        exit;
      end;
    pprCaseMismatch:
      begin
        Layout.Refusal := prrLayoutCase;
        exit;
      end;
    pprLink:
      begin
        Layout.Refusal := prrLayoutLink;
        exit;
      end;
    pprEscape:
      begin
        Layout.Refusal := prrLayoutEscape;
        exit;
      end;
  else
    begin
      // pprSyntax cannot happen for a layout this unit spelled; a
      // not-a-directory or not-regular segment is a shape failure
      Layout.Refusal := prrLayoutShape;
      exit;
    end;
  end;
  if (r.MissingSegments <> 0) or
     (r.Kind <> pcnFile) then
  begin
    Layout.Refusal := prrLayoutShape;
    exit;
  end;
  Layout.Detail := '';
  Full := r.Full;
  Result := True;
end;

function PWebCliResolveRunLayout(const Project: TPWebCliProject;
  Os: TPWebCliOs; Arch: TPWebCliArch): TPWebCliRunLayout;
var
  exeLogical, bundleLogical, plistLogical, plistFull, name: RawUtf8;
begin
  Result := Default(TPWebCliRunLayout);
  Result.Target := PWebCliRunTargetName(Os, Arch);
  if (Project.Refusal <> pcrNone) or
     (Project.OutputPath.Refusal <> pprNone) then
  begin
    Result.Refusal := prrOutputUnresolved;
    Result.Detail := Project.Output;
    exit;
  end;
  PWebCliRunLogicalLayout(Project, Os, Arch, exeLogical, bundleLogical,
    plistLogical);
  Result.ExeLogical := exeLogical;
  Result.BundleLogical := bundleLogical;
  // the executable first: its absence is the ordinary "not built" answer,
  // and its directory is the working directory of the run
  if not ResolveFile(Project.Root, exeLogical, Result, Result.ExePath) then
    exit;
  if not ResolveFile(Project.Root, bundleLogical, Result, Result.BundlePath) then
    exit;
  if plistLogical <> '' then
    if not ResolveFile(Project.Root, plistLogical, Result, plistFull) then
      exit;
  if not PWebCliSplitLast(Result.ExePath, Result.ExeDir, name) then
  begin
    Result.Refusal := prrLayoutShape;
    Result.Detail := exeLogical;
    exit;
  end;
  Result.Refusal := prrNone;
end;

function PWebCliRunApplication(const Layout: TPWebCliRunLayout;
  Sink: TPWebCliLineSink; StopCheck: TPWebCliStopCheck;
  Started: TPWebCliStartedNotify; Opaque: Pointer): TPWebCliExecResult;
var
  spec: TPWebCliExecSpec;
begin
  spec := Default(TPWebCliExecSpec);
  spec.ExePath := Layout.ExePath;
  spec.Args := nil;          // production mode: no argument at all
  spec.WorkDir := Layout.ExeDir;
  spec.Profile := pepSupervise;
  spec.TimeoutMs := 0;       // the application decides when it is done
  spec.Sink := Sink;
  spec.StopCheck := StopCheck;
  spec.Started := Started;
  spec.Opaque := Opaque;
  spec.TreeRoot := PWebCliDisplayPath(Layout.ExeDir);
  Result := PWebCliExecute(spec);
end;

end.
