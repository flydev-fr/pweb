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

implementation

end.
