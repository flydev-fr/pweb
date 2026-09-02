{
  pweb.cli.toolchain - the pinned expectations `pweb doctor` compares against
  (CAP-10A).

  A generated PWeb project does not carry this repository's lock files, so
  the doctor cannot read fpc.lock or pas2js.lock at diagnosis time. It needs
  the numbers anyway. This unit is where they live, ONCE, and
  test/cap10a/check_cap10a_contracts.ps1 cross-checks every one of them
  against its lock or its ratified source in CI - the same single-source
  idiom PWEB_WV2_MIN_BUILD already uses against the CAP-4W patch.

  Editing a value here without editing its source (or the other way round)
  turns CI red. That is the entire point: a constant nobody cross-checks is
  a number somebody typed.
}
unit pweb.cli.toolchain;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base;

const
  /// minimum Free Pascal Compiler, from fpc.lock `version` and the
  // conventions.md toolchain floor
  // - a HIGHER version is accepted (the dev host runs 3.2.3 and CI accepts
  // both), a lower one is a required-environment failure
  PWEB_CLI_FPC_MIN: RawUtf8 = '3.2.2';

  /// minimum Node.js for a UI=react project
  // - chosen as the 20.19 LTS line: it is the floor the frontend toolchain
  // family this project pins (esbuild, and the Vite generation CAP-10C will
  // drive) requires, and the CI pin must satisfy it - which the contract
  // gate asserts against the workflow's own node-version
  PWEB_CLI_NODE_MIN: RawUtf8 = '20.19.0';

  /// exact Pas2JS version for a UI=pas2js project, from pas2js.lock
  // `version` - an EXACT match, because the SDK is compiled by it and a
  // different compiler is a different product, not a newer one
  PWEB_CLI_PAS2JS_VERSION: RawUtf8 = '3.0.1';

  /// minimum macOS product version, from webview.lock
  // `macos-deployment-target` - the first branch carrying WebKit's
  // secure-context treatment of custom scheme origins, which pweb://app
  // depends on
  PWEB_CLI_MACOS_MIN: RawUtf8 = '12.0';

  /// the tool names the doctor resolves on PATH, spelled once
  PWEB_CLI_TOOL_FPC = 'fpc';
  PWEB_CLI_TOOL_NODE = 'node';
  PWEB_CLI_TOOL_NPM = 'npm';
  PWEB_CLI_TOOL_PAS2JS = 'pas2js';

  /// bounded wait for ONE version probe, in milliseconds
  // - a version query that has not answered in this long is a broken tool,
  // not a slow one; the child is killed and the row fails
  PWEB_CLI_PROBE_TIMEOUT_MS = 15000;

  /// ceiling on captured child output, per stream, in bytes
  // - a tool that floods stdout must bound the CLI's memory, not the other
  // way round; the excess is discarded and the row records the overflow
  PWEB_CLI_PROBE_MAX_BYTES = 65536;

  /// ceiling on the project descriptor, in bytes
  PWEB_CLI_DESCRIPTOR_MAX_BYTES = 65536;

  /// how far the upward search for a descriptor may walk
  // - a bound, not a policy: the search stops at the filesystem root long
  // before this on any real tree, and an unbounded loop over a pathological
  // mount is not a thing a CLI should be able to do
  PWEB_CLI_DISCOVERY_MAX_DEPTH = 64;

  { CAP-10C0 - the supervision bounds. Every one of them is a LIMIT on how
    long the supervisor may wait for something it does not control, never a
    tuning knob: a supervised application that has not honoured a graceful
    stop inside PWEB_CLI_RUN_GRACE_MS is killed, and one that has not died
    inside PWEB_CLI_RUN_KILL_MS after that is reported as unreaped rather
    than waited on forever. test/cap10c0/check_cap10c0_contracts.ps1
    cross-checks each value against docs/supervision-contract.md. }

  /// graceful window: from the stop request (WM_CLOSE / SIGTERM to the
  // group) until the tree is force-terminated
  PWEB_CLI_RUN_GRACE_MS = 5000;

  /// forced window: from TerminateJobObject / SIGKILL until the child must
  // have been reaped
  PWEB_CLI_RUN_KILL_MS = 3000;

  /// while the graceful stop finds no window to close yet (a host still
  // starting up), the request is re-posted at this interval
  PWEB_CLI_RUN_STOP_RETRY_MS = 250;

  /// ceiling on ONE forwarded line, in bytes; the rest of a longer line is
  // discarded and the line is marked truncated
  PWEB_CLI_RUN_LINE_MAX = 4096;

  /// ceiling on the retained stderr tail kept for the exit report
  PWEB_CLI_RUN_DIAG_MAX = 65536;

  /// after the child exits, how many enumeration passes the descendant
  // drain makes at PWEB_CLI_RUN_DRAIN_POLL_MS before it stops re-checking
  PWEB_CLI_RUN_DRAIN_PASSES = 20;
  PWEB_CLI_RUN_DRAIN_POLL_MS = 250;

  { CAP-10C1 - the lifecycle-pipeline bounds. Each one is a LIMIT on how long
    the pipeline may wait for a toolchain it does not control, never a tuning
    knob: a stage that has not finished inside its bound is a broken or a
    hung tool, the whole child tree is stopped by the CAP-10C0 ladder, and no
    later stage runs. test/cap10c1/check_cap10c1_contracts.ps1 cross-checks
    each value against docs/pipeline-contract.md, exactly as the CAP-10C0
    bounds are cross-checked against the supervision contract. }

  /// `node <npm-cli.js> ci` - the ONE stage allowed to reach the network,
  // and therefore the one whose bound has to cover a cold registry
  PWEB_CLI_PIPE_NPM_MS = 600000;

  /// the TypeScript typecheck
  PWEB_CLI_PIPE_TSC_MS = 300000;

  /// the frontend production build: `vite build` (react) or the pinned
  // Pas2JS compiler (pas2js)
  PWEB_CLI_PIPE_BUILD_MS = 300000;

  /// the frozen CAP-6 bundler packing app.pwb
  PWEB_CLI_PIPE_PACK_MS = 120000;

  /// the native compile. It is the longest bound in this unit because `-B`
  // rebuilds every mORMot unit the program reaches, from source, on a cold
  // output directory
  PWEB_CLI_PIPE_FPC_MS = 900000;

  /// ceiling on ONE file the pipeline itself reads or copies, in bytes
  // - the pipeline's copy primitive is PWebCliReadSmallFile with this bound,
  // so a native executable and a staged static library are covered while an
  // unbounded read remains impossible. A file past it is a typed refusal,
  // never a partial copy
  PWEB_CLI_PIPE_MAX_FILE_BYTES = 268435456;

  /// bounds on the project-tree digest walk that guards the mutation set
  // - a bound, not a policy: a generated project holds a few dozen files,
  // and an unbounded walk over a pathological tree is not a thing a build
  // tool should be able to do
  PWEB_CLI_PIPE_MAX_TREE_FILES = 4096;
  PWEB_CLI_PIPE_MAX_TREE_DEPTH = 24;

  { CAP-10C1 - the platform artifacts the SDK root carries, spelled ONCE.
    Every one of them is cross-checked against webview.lock by
    test/cap10c1/check_cap10c1_contracts.ps1, the same single-source idiom
    PWEB_CLI_MACOS_MIN already uses against `macos-deployment-target`. }

  /// the webview library shipped beside a Windows release
  // - built by tools/build-webview-dll.ps1 from the pinned upstream commit
  PWEB_CLI_WEBVIEW_LIB_WINDOWS = 'webview.dll';
  /// webview.lock `linux-soname` - what FPC records as DT_NEEDED, which is
  // why it and not the chet LibraryName is the file a release ships
  PWEB_CLI_WEBVIEW_LIB_LINUX = 'libwebview.so.0.12';
  /// webview.lock `macos-dylib-versioned` - what the LC_LOAD_DYLIB command
  // ends up naming, exactly as DT_NEEDED records the SONAME on Linux
  PWEB_CLI_WEBVIEW_LIB_MACOS = 'libwebview.0.12.dylib';
  /// the compiled production Cocoa bridge, linked into every macOS binary
  // that uses it - an object file, never a second dylib (CAP-7M1)
  PWEB_CLI_MACOS_BRIDGE_OBJ = 'pweb_cocoa_bridge.o';

implementation

end.
