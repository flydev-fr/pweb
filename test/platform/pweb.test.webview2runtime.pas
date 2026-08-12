unit pweb.test.webview2runtime;

{ mormot.core.test cases for CAP-6b0: WebView2 runtime detection and
  provisioning foundation.

  Headless coverage of the full ratified I/O matrix: the strict
  fail-closed 4-part version parser, the single usability threshold
  (build >= PWEB_WV2_MIN_BUILD = 1587, the CAP-4W loader minimum,
  numeric and build-component-only exactly like the pinned loader's
  reject/accept boundary triple 1.0.1586.99 / 1.0.1587.0 / 1.0.1588.0),
  provisioning decisions over INJECTED detection records (no registry
  involved - the policy functions are pure), the frozen post-install
  invariant (installer exit 0 + unusable re-probe = installation
  FAILED; the re-probe verdict outranks the exit code), the
  present-but-old vs absent distinction CAP-4W could not report, and
  one real host registry probe smoke that must never raise, whatever
  the machine state is - its outcome is logged as evidence, never
  asserted against a particular runtime.

  RegistrySeamMatrix swaps the unit's internal registry-reader seam
  for a fake hive whose entries are matched on the EXACT documented
  root/key path/value name AND the 32-bit-view flag, all hardcoded
  here rather than shared with the unit: probing the wrong value name
  (the 'pv' -> 'pw' drift), the wrong GUID, the wrong hive order or
  dropping KEY_WOW64_32KEY makes these tests fail - such a drift can
  never pass silently again. It also pins the ratified precedence
  (an HKCU hit is available even when the HKLM read errored, with the
  Win32 error code preserved in the Diagnostic) and that every
  detection_error carries a non-empty Diagnostic naming the code. }

{$I mormot.defines.inc}

interface

uses
  windows,
  sysutils,
  mormot.core.base,
  mormot.core.test,
  pweb.platform.webview2.runtime;

type
  /// CAP-6b0 detection/policy/provisioning cases - headless, no
  // WebView2 runtime required (the smoke only READS registry state)
  TTestWebView2Runtime = class(TSynTestCase)
  published
    /// strict 4-part grammar: accept/reject tables, exact components,
    // zeroed outputs on refusal, canonical round-trip
    procedure VersionParserMatrix;
    /// the CAP-4W boundary triple and the numeric-only comparison
    procedure UsabilityPolicyBoundary;
    /// present-but-old is distinguishable from absent (the CAP-4W gap)
    procedure OldVersusAbsentDistinction;
    /// injected detection records -> provisioning decisions
    procedure ProvisioningDecisions;
    /// installer success is never runtime success (frozen invariant)
    procedure PostInstallInvariant;
    /// fake-hive walk over the injectable reader seam: exact paths,
    // hive precedence, sentinels, error diagnostics, drift detection
    procedure RegistrySeamMatrix;
    /// the real registry probe: never raises, structurally coherent
    procedure HostProbeSmoke;
  end;

implementation

{ ---- fake registry hive for the private reader seam ----

  Entries are matched on the EXACT (root, subkey, valuename) triple,
  with the documented paths hardcoded HERE, independently of the
  unit's own constants - and any probe that does not carry the
  KEY_WOW64_32KEY view flag sees an empty hive, exactly like a value
  that only exists in the 32-bit view. }

const
  // hardcoded on purpose: must match the Microsoft-documented paths,
  // NOT the unit's constants, so a drift in the unit fails these tests
  FAKE_CLIENTS_KEY: UnicodeString =
    'SOFTWARE\Microsoft\EdgeUpdate\Clients\' +
    '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  FAKE_CLIENT_STATE_KEY: UnicodeString =
    'SOFTWARE\Microsoft\EdgeUpdate\ClientState\' +
    '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  FAKE_PV: UnicodeString = 'pv';
  FAKE_EBWEBVIEW: UnicodeString = 'EBWebView';
  ERROR_CODE_DENIED = 5;    // ERROR_ACCESS_DENIED
  ERROR_CODE_NOMEM = 1450;  // ERROR_NO_SYSTEM_RESOURCES

type
  TFakeRegEntry = record
    Root: HKEY;
    SubKey: UnicodeString;
    ValueName: UnicodeString;
    Outcome: TPWebWv2RegRead;
    Text: RawUtf8;
    SysError: LongInt;
  end;

var
  FakeHive: array of TFakeRegEntry;

procedure FakeClear;
begin
  FakeHive := nil;
end;

procedure FakeAdd(ARoot: HKEY; const ASubKey, AValueName: UnicodeString;
  AOutcome: TPWebWv2RegRead; const AText: RawUtf8; ASysError: LongInt);
var
  n: PtrInt;
begin
  n := Length(FakeHive);
  SetLength(FakeHive, n + 1);
  FakeHive[n].Root := ARoot;
  FakeHive[n].SubKey := ASubKey;
  FakeHive[n].ValueName := AValueName;
  FakeHive[n].Outcome := AOutcome;
  FakeHive[n].Text := AText;
  FakeHive[n].SysError := ASysError;
end;

function FakeRegRead(Root: HKEY; const SubKey, ValueName: UnicodeString;
  SamFlags: LongWord; out Text: RawUtf8;
  out SysError: LongInt): TPWebWv2RegRead;
var
  i: PtrInt;
begin
  Result := wv2rrAbsent;
  Text := '';
  SysError := 0;
  // a probe without the 32-bit-view flag sees nothing, like a value
  // living only in the WOW6432Node view - dropping the flag in the
  // unit turns every seam test red
  if (SamFlags and PWEB_KEY_WOW64_32KEY) = 0 then
    exit;
  for i := 0 to High(FakeHive) do
    if (FakeHive[i].Root = Root) and
       (FakeHive[i].SubKey = SubKey) and
       (FakeHive[i].ValueName = ValueName) then
    begin
      Text := FakeHive[i].Text;
      SysError := FakeHive[i].SysError;
      Result := FakeHive[i].Outcome;
      exit;
    end;
end;

function V(AMajor, AMinor, ABuild, APatch: Cardinal): TPWebWv2Version;
begin
  Result.Major := AMajor;
  Result.Minor := AMinor;
  Result.Build := ABuild;
  Result.Patch := APatch;
end;

// builds an injected detector outcome, parsing Raw exactly like the
// real probe does - the private seam ratified for these pure tests
function Det(AStatus: TPWebWv2DetectionStatus; const ARaw: RawUtf8;
  AChannel: TPWebWv2Channel): TPWebWv2DetectionResult;
begin
  Result.Status := AStatus;
  Result.RawVersion := ARaw;
  Result.ParsedOk := PWebWv2VersionParse(ARaw, Result.Parsed);
  Result.Channel := AChannel;
  Result.Diagnostic := 'injected';
end;

procedure TTestWebView2Runtime.VersionParserMatrix;
const
  GOOD: array[0..7] of RawUtf8 = (
    '1.0.1587.0', '1.0.1586.99', '1.0.1588.0', '151.0.4129.72',
    '0.0.0.0', '10.20.30.40', '999999999.0.0.1', '1.0.0.0');
  BAD: array[0..24] of RawUtf8 = (
    '', 'abc', '1', '1.2', '1.2.3', '1.2.3.4.5', '1.2.3.',
    '.1.2.3', '1..2.3', '1.2.3.4.', '01.0.0.0', '1.0.0.00',
    '1.0.01587.0', 'v1.0.1587.0', ' 1.0.1587.0', '1.0.1587.0 ',
    '1.0.1587.0-beta', '1.0.1587.0 beta', '1.0.1587.0'#10,
    '1.0.1587.0'#0, '1,0,1587,0', '1.0.1587.x', '1.0.-1.0',
    '1234567890.0.0.0', '1.2.3.4.5.6');
var
  i: PtrInt;
  version: TPWebWv2Version;
begin
  for i := 0 to High(GOOD) do
    CheckUtf8(PWebWv2VersionParse(GOOD[i], version),
      'valid version rejected: %', [GOOD[i]]);
  for i := 0 to High(BAD) do
  begin
    CheckUtf8(not PWebWv2VersionParse(BAD[i], version),
      'malformed version accepted: %', [BAD[i]]);
    // fail closed: a refused parse never leaks partial components
    CheckUtf8((version.Major = 0) and (version.Minor = 0) and
      (version.Build = 0) and (version.Patch = 0),
      'refused parse leaked components for %', [BAD[i]]);
  end;
  // exact component extraction
  Check(PWebWv2VersionParse('151.0.4129.72', version));
  CheckEqual(version.Major, 151);
  CheckEqual(version.Minor, 0);
  CheckEqual(version.Build, 4129);
  CheckEqual(version.Patch, 72);
  Check(PWebWv2VersionParse('1.0.1587.40', version));
  CheckEqual(version.Build, 1587);
  CheckEqual(version.Patch, 40);
  // the strict grammar is canonical: parse and text round-trip
  Check(PWebWv2VersionParse('120.0.2210.61', version));
  CheckEqual(PWebWv2VersionText(version), '120.0.2210.61');
  CheckEqual(PWebWv2VersionText(V(1, 0, 1587, 0)), '1.0.1587.0');
end;

procedure TTestWebView2Runtime.UsabilityPolicyBoundary;
var
  detection: TPWebWv2DetectionResult;
begin
  // the exact CAP-4W loader boundary triple (cap4w_loader_boundary.cpp)
  Check(not PWebWv2VersionUsable(V(1, 0, 1586, 99)),
    'below-boundary version usable');
  Check(PWebWv2VersionUsable(V(1, 0, 1587, 0)),
    'exact-boundary version not usable');
  Check(PWebWv2VersionUsable(V(1, 0, 1588, 0)),
    'above-boundary version not usable');
  // a modern runtime is usable
  Check(PWebWv2VersionUsable(V(151, 0, 4129, 72)));
  // numeric comparison, never lexicographic: as strings '999' > '1587'
  // and '10000' < '1587' - both traps must resolve numerically
  Check(not PWebWv2VersionUsable(V(1, 0, 999, 0)),
    'lexicographic comparison leaked in (999 accepted)');
  Check(PWebWv2VersionUsable(V(1, 0, 10000, 0)),
    'lexicographic comparison leaked in (10000 rejected)');
  // pinned-loader parity: the BUILD component alone decides - other
  // components can never compensate for an old build
  Check(not PWebWv2VersionUsable(V(999, 999, 1586, 999)),
    'non-build component compensated for an old build');
  Check(PWebWv2VersionUsable(V(0, 0, 1587, 0)),
    'zero major/minor rejected a new-enough build');
  // full detection-level policy: only available + parsed + new enough
  Check(PWebWv2DetectionUsable(
    Det(wv2dsAvailable, '1.0.1587.0', wv2chHKLM)));
  Check(PWebWv2DetectionUsable(
    Det(wv2dsAvailable, '151.0.4129.72', wv2chHKCU)));
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsAvailable, '1.0.1586.99', wv2chHKLM)),
    'present-but-old runtime usable');
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsUnavailable, '', wv2chNone)), 'absent runtime usable');
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsDetectionError, '', wv2chNone)),
    'detection error reported usable');
  // malformed version text fails closed: never usable
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsAvailable, 'abc', wv2chHKLM)));
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsAvailable, '1.2', wv2chHKLM)));
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsAvailable, '1.2.3.4.5', wv2chHKLM)));
  Check(not PWebWv2DetectionUsable(
    Det(wv2dsAvailable, '', wv2chHKLM)));
  // the status gates the verdict even over a forged parsed version:
  // an unavailable record can never become usable
  detection := Det(wv2dsUnavailable, '', wv2chNone);
  detection.ParsedOk := True;
  detection.Parsed := V(151, 0, 4129, 72);
  Check(not PWebWv2DetectionUsable(detection),
    'status did not gate the usability verdict');
end;

procedure TTestWebView2Runtime.OldVersusAbsentDistinction;
var
  old, absent: TPWebWv2DetectionResult;
begin
  // the distinction CAP-4W could not report: webview_create returns
  // the same nil for both, this seam keeps them structurally apart
  old := Det(wv2dsAvailable, '1.0.1586.99', wv2chHKLM);
  absent := Det(wv2dsUnavailable, '', wv2chNone);
  // neither is usable and both need provisioning...
  Check(not PWebWv2DetectionUsable(old));
  Check(not PWebWv2DetectionUsable(absent));
  Check(PWebWv2ProvisioningDecide(old) = wv2pdProvisionRequired);
  Check(PWebWv2ProvisioningDecide(absent) = wv2pdProvisionRequired);
  // ...but the records stay distinguishable for diagnosis
  Check(old.Status <> absent.Status, 'old and absent collapsed');
  Check(old.RawVersion <> '', 'old runtime lost its version text');
  Check(old.ParsedOk, 'old runtime lost its parsed version');
  CheckEqual(PWebWv2VersionText(old.Parsed), '1.0.1586.99');
  Check(old.Channel <> wv2chNone);
  CheckEqual(absent.RawVersion, '');
  Check(not absent.ParsedOk);
  // and the stable status texts differ too
  Check(PWebWv2StatusText(old.Status) <>
    PWebWv2StatusText(absent.Status));
  CheckEqual(PWebWv2StatusText(old.Status), 'available');
  CheckEqual(PWebWv2StatusText(absent.Status), 'unavailable');
end;

procedure TTestWebView2Runtime.ProvisioningDecisions;
begin
  // Detect -> AlreadyUsable | ProvisionRequired | DetectionFailure
  // over the full ratified matrix, via injected records only
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsAvailable, '151.0.4129.72', wv2chHKLM)) =
    wv2pdAlreadyUsable, 'modern runtime');
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsAvailable, '1.0.1587.0', wv2chHKLM)) =
    wv2pdAlreadyUsable, 'exact minimum');
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsAvailable, '1.0.1588.0', wv2chHKCU)) =
    wv2pdAlreadyUsable, 'above minimum');
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsAvailable, '1.0.1586.99', wv2chHKLM)) =
    wv2pdProvisionRequired, 'just below minimum');
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsUnavailable, '', wv2chNone)) =
    wv2pdProvisionRequired, 'absent runtime');
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsAvailable, 'garbage', wv2chHKLM)) =
    wv2pdProvisionRequired, 'malformed version text');
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsDetectionError, '', wv2chNone)) =
    wv2pdDetectionFailure, 'detection error');
  // an error can never silently downgrade to an install attempt or
  // upgrade to a false success, even with plausible version text
  Check(PWebWv2ProvisioningDecide(
    Det(wv2dsDetectionError, '151.0.4129.72', wv2chHKLM)) =
    wv2pdDetectionFailure, 'error status outranked by version text');
  // decision texts are distinct and stable
  CheckEqual(PWebWv2DecisionText(wv2pdAlreadyUsable), 'AlreadyUsable');
  CheckEqual(PWebWv2DecisionText(wv2pdProvisionRequired),
    'ProvisionRequired');
  CheckEqual(PWebWv2DecisionText(wv2pdDetectionFailure),
    'DetectionFailure');
end;

procedure TTestWebView2Runtime.PostInstallInvariant;
begin
  // THE frozen invariant: installer exit 0 + unusable re-probe means
  // the installation FAILED - success is only ever proven by re-probe
  Check(not PWebWv2ConfirmPostInstall(0,
    Det(wv2dsUnavailable, '', wv2chNone)),
    'exit 0 masked an absent runtime');
  Check(not PWebWv2ConfirmPostInstall(0,
    Det(wv2dsAvailable, '1.0.1586.99', wv2chHKLM)),
    'exit 0 masked a too-old runtime');
  Check(not PWebWv2ConfirmPostInstall(0,
    Det(wv2dsAvailable, 'broken', wv2chHKLM)),
    'exit 0 masked a malformed runtime version');
  Check(not PWebWv2ConfirmPostInstall(0,
    Det(wv2dsDetectionError, '', wv2chNone)),
    'exit 0 masked a failed re-probe');
  // a usable re-probe confirms the install
  Check(PWebWv2ConfirmPostInstall(0,
    Det(wv2dsAvailable, '1.0.1587.0', wv2chHKLM)));
  Check(PWebWv2ConfirmPostInstall(0,
    Det(wv2dsAvailable, '151.0.4129.72', wv2chHKCU)));
  // the re-probe verdict outranks the exit code in BOTH directions:
  // a nonzero exit with a provably usable runtime is still success
  // (e.g. "already installed" exit codes), and vice versa never holds
  Check(PWebWv2ConfirmPostInstall(1602,
    Det(wv2dsAvailable, '1.0.1588.0', wv2chHKLM)),
    'usable re-probe overruled by exit code');
  Check(not PWebWv2ConfirmPostInstall(1,
    Det(wv2dsUnavailable, '', wv2chNone)));
end;

procedure TTestWebView2Runtime.RegistrySeamMatrix;
var
  d: TPWebWv2DetectionResult;
begin
  PWebWv2RegReader := FakeRegRead;
  try
    // (a) HKLM outranks HKCU when both hives report a runtime
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '1.0.1600.0', 0);
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '1.0.1700.0', 0);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsAvailable, 'both-hives not available');
    CheckEqual(d.RawVersion, '1.0.1600.0', 'HKLM did not outrank HKCU');
    Check(d.Channel = wv2chHKLM);
    // (c) an available result carries version text, parse and channel
    FakeClear;
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '1.0.1587.40', 0);
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENT_STATE_KEY, FAKE_EBWEBVIEW,
      wv2rrFound, 'C:\fake\EdgeWebView\Application\1.0.1587.40', 0);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsAvailable, 'hkcu-only not available');
    CheckEqual(d.RawVersion, '1.0.1587.40');
    Check(d.Channel = wv2chHKCU, 'wrong channel for hkcu hit');
    Check(d.ParsedOk);
    CheckEqual(d.Parsed.Build, 1587);
    Check(PWebWv2DetectionUsable(d));
    // the pinned-loader ClientState walk agreed (last path component)
    Check(Pos('agrees with pv', d.Diagnostic) > 0,
      'clientstate cross-check did not agree');
    // (b) '' and '0.0.0.0' are the documented not-installed sentinels
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '', 0);
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '0.0.0.0', 0);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsUnavailable, 'sentinels not unavailable');
    Check(d.Channel = wv2chNone);
    CheckEqual(d.RawVersion, '');
    // a sentinel hive must not mask a real runtime in the next hive
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '0.0.0.0', 0);
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '1.0.1590.0', 0);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsAvailable, 'sentinel masked the hkcu runtime');
    Check(d.Channel = wv2chHKCU);
    // (d) RATIFIED precedence: an HKCU hit is available even when the
    // HKLM read errored - loader parity wins - and the HKLM error is
    // preserved in the Diagnostic, named by its Win32 code
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrError, '', ERROR_CODE_DENIED);
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrFound, '152.0.9999.1', 0);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsAvailable,
      'HKLM error masked the usable HKCU runtime');
    CheckEqual(d.RawVersion, '152.0.9999.1');
    Check(d.Channel = wv2chHKCU);
    CheckUtf8(Pos('error 5', d.Diagnostic) > 0,
      'HKLM error code lost from diagnostic: %', [d.Diagnostic]);
    // (4) every detection_error names its concrete Win32 error code(s)
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrError, '', ERROR_CODE_DENIED);
    FakeAdd(HKEY_CURRENT_USER, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrError, '', ERROR_CODE_NOMEM);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsDetectionError, 'errors did not escalate');
    Check(d.Diagnostic <> '', 'detection_error without diagnostic');
    CheckUtf8(Pos('error 5', d.Diagnostic) > 0,
      'hklm code missing: %', [d.Diagnostic]);
    CheckUtf8(Pos('error 1450', d.Diagnostic) > 0,
      'hkcu code missing: %', [d.Diagnostic]);
    Check(PWebWv2ProvisioningDecide(d) = wv2pdDetectionFailure);
    // one error + one absent still escalates (unknown machine state)
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, FAKE_PV,
      wv2rrError, '', ERROR_CODE_DENIED);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsDetectionError);
    Check(Pos('error 5', d.Diagnostic) > 0);
    // (e) the review's drift demonstration: a value only published
    // under the WRONG name ('pw') or the WRONG GUID is never found -
    // and conversely, had the unit drifted to those, the exact-match
    // cases above would all fail
    FakeClear;
    FakeAdd(HKEY_LOCAL_MACHINE, FAKE_CLIENTS_KEY, 'pw',
      wv2rrFound, '1.0.1600.0', 0);
    FakeAdd(HKEY_LOCAL_MACHINE,
      'SOFTWARE\Microsoft\EdgeUpdate\Clients\' +
      '{00000000-0000-0000-0000-000000000000}', FAKE_PV,
      wv2rrFound, '1.0.1600.0', 0);
    d := PWebWv2Detect;
    Check(d.Status = wv2dsUnavailable,
      'detector read a wrong value name or GUID');
    // an empty fake hive is simply an absent runtime
    FakeClear;
    d := PWebWv2Detect;
    Check(d.Status = wv2dsUnavailable);
    Check(PWebWv2ProvisioningDecide(d) = wv2pdProvisionRequired);
  finally
    PWebWv2RegReader := PWebWv2RegReadOs;
    FakeClear;
  end;
end;

procedure TTestWebView2Runtime.HostProbeSmoke;
const
  USABLE_STR: array[Boolean] of RawUtf8 = ('false', 'true');
var
  detection, second: TPWebWv2DetectionResult;
  decision: TPWebWv2ProvisioningDecision;
begin
  // the real registry probe: whatever this machine's state is, the
  // call must return a structured result and never raise (any
  // exception escaping PWebWv2Detect fails this case by itself)
  detection := PWebWv2Detect;
  if detection.Status = wv2dsAvailable then
  begin
    Check(detection.RawVersion <> '',
      'available without raw version text');
    Check(detection.Channel in [wv2chHKLM, wv2chHKCU],
      'available without a source channel');
    if detection.ParsedOk then
      // the strict grammar is canonical, so a successful parse must
      // round-trip to the exact registry bytes
      CheckEqual(PWebWv2VersionText(detection.Parsed),
        detection.RawVersion, 'parsed version does not round-trip');
  end
  else
  begin
    Check(detection.Channel = wv2chNone,
      'channel reported without an available runtime');
    CheckEqual(detection.RawVersion, '',
      'version text reported without an available runtime');
    Check(not detection.ParsedOk);
  end;
  Check(detection.Diagnostic <> '', 'probe produced no diagnostic');
  // policy/decision coherence over the real record
  decision := PWebWv2ProvisioningDecide(detection);
  Check((decision = wv2pdAlreadyUsable) =
    PWebWv2DetectionUsable(detection), 'decision/policy divergence');
  if detection.Status = wv2dsDetectionError then
    Check(decision = wv2pdDetectionFailure);
  // log the evidence (never asserted against a particular runtime)
  AddConsole('host WebView2 probe: status=% channel=% raw=% usable=% ' +
    'decision=%', [PWebWv2StatusText(detection.Status),
    PWebWv2ChannelText(detection.Channel), detection.RawVersion,
    USABLE_STR[PWebWv2DetectionUsable(detection)],
    PWebWv2DecisionText(decision)]);
  AddConsole('host WebView2 probe diagnostic: %',
    [detection.Diagnostic]);
  // a second probe must be equally safe AND report the same machine
  // state (idempotent boundary - nothing here mutates the registry)
  second := PWebWv2Detect;
  Check(second.Status = detection.Status, 'probe status not stable');
  CheckEqual(second.RawVersion, detection.RawVersion,
    'probe version not stable');
  Check(second.Channel = detection.Channel, 'probe channel not stable');
  // pin EVERY status/channel text: test/cap6b/run_wv2probe.ps1 regex-
  // matches these exact strings, so a rename must break this test
  CheckEqual(PWebWv2StatusText(wv2dsAvailable), 'available');
  CheckEqual(PWebWv2StatusText(wv2dsUnavailable), 'unavailable');
  CheckEqual(PWebWv2StatusText(wv2dsDetectionError), 'detection_error');
  CheckEqual(PWebWv2ChannelText(wv2chNone), 'none');
  CheckEqual(PWebWv2ChannelText(wv2chHKLM), 'hklm');
  CheckEqual(PWebWv2ChannelText(wv2chHKCU), 'hkcu');
end;

end.
