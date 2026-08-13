unit pweb.test.wv2provision;

{ mormot.core.test cases for CAP-6b1: normal-profile WebView2
  provisioning orchestration (pweb.platform.webview2.provision).

  The full ratified N-matrix runs headlessly through the unit's
  injectable seams (detector, hasher, signature check, bounded
  runner) - no registry, no file, no process and no Microsoft binary
  is ever involved in the matrix; the fakes count their calls so the
  tests can prove NEGATIVES (the bootstrapper was never invoked on
  the skip path, verification never ran after a detection failure,
  the runner never ran after a refused digest or signature):

    N1/N11 usable runtime      -> AlreadyUsable, installer never read
    N2  absent + exit 0 + usable re-probe        -> Provisioned
    N3  old (<1587) + usable re-probe            -> Provisioned
    N4  exit 0 + unavailable re-probe            -> FAILS (reprobe)
    N5  exit nonzero + usable re-probe           -> Provisioned
        (the frozen PWebWv2ConfirmPostInstall verdict - no special case)
    N6  initial detection_error                  -> FAILS, never runs
    N7  sha mismatch                             -> FAILS, digests named
    N8  bad/unsigned authenticode                -> FAILS, subject named
    N10 bounded timeout                          -> FAILS after kill
    N12 re-probe below 1587                      -> FAILS (one threshold)

  (N9, build-time acquisition drift, is a build gate: it lives in
  test/cap6b/check_wv2lock.ps1 over tools/get-webview2-runtime.ps1.)

  Beyond the ratified matrix, the fail-closed edges of the runner and
  the orchestrator entry are pinned too: a timeout bound of 0 or
  INFINITE is refused before even the detector runs, a missing payload
  fails at the TOCTOU guard before any hashing, and the truthful
  "executed, fate unknown" runner outcome fails the execute step with
  InstallerExecuted preserved. The matrix payload is a REAL temp file
  because the orchestrator holds a GENERIC_READ/FILE_SHARE_READ guard
  handle across verify -> execute - and the fake runner PROVES that
  guard by attempting (and failing) a write-open of the payload at the
  exact moment the real bootstrapper would execute.

  RealPrimitivesSmoke exercises the real implementations without any
  Microsoft binary: the SHA-256 file digest against the FIPS 'abc'
  vector, the WinVerifyTrust check refusing the (unsigned) test
  executable with its status named, and the bounded runner's
  create-failure path on a nonexistent image - plus, when the standard
  System32 tools exist, a real bounded run (whoami.exe) and a real
  timeout+kill (waitfor.exe). Every seam is restored in a finally
  block, mirroring the ratified CAP-6b0 seam discipline. }

{$I mormot.defines.inc}

interface

uses
  windows,
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.os,
  mormot.core.test,
  pweb.platform.webview2.runtime,
  pweb.platform.webview2.provision;

type
  /// CAP-6b1 provisioning orchestration cases - headless, no WebView2
  // runtime, no registry, no Microsoft binary required
  TTestWv2Provision = class(TSynTestCase)
  published
    /// the full injected N-matrix over the orchestration seams
    procedure OrchestrationMatrix;
    /// stable outcome/step texts (the setup helper and gates parse them)
    procedure VerdictTexts;
    /// real hasher/signature/runner primitives, no Microsoft binary
    procedure RealPrimitivesSmoke;
  end;

implementation

const
  // the ratified lock digest shape used across the injected matrix
  FAKE_SHA: RawUtf8 =
    '8c4a80540b6bbcbef30a4e8c7d1ac504b6fc09db922b4acdfd85c9d5f6f1050e';
  OTHER_SHA: RawUtf8 =
    '0000000000000000000000000000000000000000000000000000000000000000';
  FAKE_SUBJECT: RawUtf8 =
    'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, ' +
    'S=Washington, C=US';
  // FIPS 180-2 test vector: sha256('abc')
  ABC_SHA: RawUtf8 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

{ ---- fakes for the four seams, with call counting ---- }

var
  FakeDetections: array of TPWebWv2DetectionResult;
  FakeDetectIndex: PtrInt;
  FakeHashOk: Boolean;
  FakeHashHex: RawUtf8;
  FakeHashCalls: PtrInt;
  FakeSigOk: Boolean;
  FakeSigCalls: PtrInt;
  FakeSigSubject: RawUtf8;
  FakeRunOutcome: TPWebWv2RunOutcome;
  FakeRunExit: Integer;
  FakeRunCalls: PtrInt;
  FakeRunPath: TFileName;
  FakeRunArgs: RawUtf8;
  FakeRunTimeout: Cardinal;
  FakeRunSawWriteLock: Boolean;

function FakeDetect: TPWebWv2DetectionResult;
begin
  if FakeDetectIndex > High(FakeDetections) then
    // more probes than the scenario scripted: fail closed loudly
    raise Exception.Create('FakeDetect: unscripted extra probe')
  else
    Result := FakeDetections[FakeDetectIndex];
  Inc(FakeDetectIndex);
end;

function FakeHash(const FileName: TFileName;
  out HexDigest, ErrorText: RawUtf8): Boolean;
begin
  Inc(FakeHashCalls);
  HexDigest := FakeHashHex;
  ErrorText := '';
  Result := FakeHashOk;
  if not Result then
  begin
    HexDigest := '';
    ErrorText := 'injected hash failure for ' + StringToUtf8(FileName);
  end;
end;

function FakeSig(const FileName: TFileName;
  const ExpectedSubject: RawUtf8; out Diag: RawUtf8): Boolean;
begin
  Inc(FakeSigCalls);
  FakeSigSubject := ExpectedSubject;
  Result := FakeSigOk;
  if Result then
    Diag := 'authenticode Valid, subject=' + ExpectedSubject
  else
    Diag := 'authenticode status=0x800B0100 (not Valid); ' +
      'expected subject ' + ExpectedSubject;
end;

function FakeRun(const ExePath: TFileName; const Args: RawUtf8;
  TimeoutMs: Cardinal; out ExitCode: Integer;
  out Diag: RawUtf8): TPWebWv2RunOutcome;
var
  h: THandle;
begin
  Inc(FakeRunCalls);
  FakeRunPath := ExePath;
  FakeRunArgs := Args;
  FakeRunTimeout := TimeoutMs;
  // TOCTOU proof: at the exact moment the real bootstrapper would
  // execute, the orchestrator must still hold its GENERIC_READ /
  // FILE_SHARE_READ guard - so a write-open of the payload MUST fail
  // with a sharing violation here
  h := FileOpen(ExePath, fmOpenWrite or fmShareDenyNone);
  if h = THandle(-1) then
    FakeRunSawWriteLock := True
  else
  begin
    FakeRunSawWriteLock := False;
    FileClose(h);
  end;
  Result := FakeRunOutcome;
  ExitCode := -1;
  Diag := 'injected';
  if Result = wv2roCompleted then
  begin
    ExitCode := FakeRunExit;
    Diag := 'completed with exit code ' + RawUtf8(IntToStr(FakeRunExit));
  end
  else if Result = wv2roTimedOut then
    Diag := 'timed out after ' + RawUtf8(IntToStr(TimeoutMs)) +
      ' ms; process killed'
  else if Result = wv2roExecutedUnknown then
    Diag := 'executed, but WaitForSingleObject failed: error 6; ' +
      'kill UNCONFIRMED (injected)';
end;

procedure ResetFakes;
begin
  FakeDetections := nil;
  FakeDetectIndex := 0;
  FakeHashOk := True;
  FakeHashHex := FAKE_SHA;
  FakeHashCalls := 0;
  FakeSigOk := True;
  FakeSigCalls := 0;
  FakeSigSubject := '';
  FakeRunOutcome := wv2roCompleted;
  FakeRunExit := 0;
  FakeRunCalls := 0;
  FakeRunPath := '';
  FakeRunArgs := '';
  FakeRunTimeout := 0;
  FakeRunSawWriteLock := False;
end;

procedure ScriptDetections(const A: array of TPWebWv2DetectionResult);
var
  i: PtrInt;
begin
  SetLength(FakeDetections, Length(A));
  for i := 0 to High(A) do
    FakeDetections[i] := A[i];
  FakeDetectIndex := 0;
end;

// injected detector outcome, parsing Raw exactly like the real probe
// (the same private Det() convention the CAP-6b0 tests ratified)
function Det(AStatus: TPWebWv2DetectionStatus; const ARaw: RawUtf8;
  AChannel: TPWebWv2Channel): TPWebWv2DetectionResult;
begin
  Result.Status := AStatus;
  Result.RawVersion := ARaw;
  Result.ParsedOk := PWebWv2VersionParse(ARaw, Result.Parsed);
  Result.Channel := AChannel;
  Result.Diagnostic := 'injected';
end;

procedure TTestWv2Provision.OrchestrationMatrix;
var
  r: TPWebWv2ProvisionResult;
  payload: TFileName;
begin
  // a REAL temp file: the orchestrator's TOCTOU guard opens the
  // payload before hashing, so the matrix needs actual bytes on disk
  // (their content is irrelevant - the hasher/signature are fakes)
  payload := TemporaryFileName;
  FileFromString('matrix payload stand-in', payload);
  PWebWv2ProvisionDetector := @FakeDetect;
  PWebWv2ProvisionHasher := @FakeHash;
  PWebWv2ProvisionSignature := @FakeSig;
  PWebWv2ProvisionRunner := @FakeRun;
  try
    // ---- N1/N11: usable runtime -> AlreadyUsable, nothing else runs
    ResetFakes;
    ScriptDetections([Det(wv2dsAvailable, '151.0.4129.72', wv2chHKLM)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poAlreadyUsable, 'N1 outcome');
    Check(r.FailedStep = wv2psNone, 'N1 step');
    Check(not r.InstallerExecuted, 'N1 executed');
    Check(not r.ReProbed, 'N1 reprobed');
    CheckEqual(FakeHashCalls, 0, 'N1: installer file was read');
    CheckEqual(FakeSigCalls, 0, 'N1: signature was checked');
    CheckEqual(FakeRunCalls, 0, 'N1: bootstrapper was invoked');
    // exact-minimum boundary is equally a skip (1.0.1587.0)
    ResetFakes;
    ScriptDetections([Det(wv2dsAvailable, '1.0.1587.0', wv2chHKCU)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poAlreadyUsable, 'N11 outcome');
    CheckEqual(FakeRunCalls, 0, 'N11: bootstrapper was invoked');

    // ---- N2: absent -> verified execute exit 0 -> usable re-probe
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone),
      Det(wv2dsAvailable, '151.0.4129.72', wv2chHKLM)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poProvisioned, 'N2 outcome');
    Check(r.FailedStep = wv2psNone, 'N2 step');
    Check(r.InstallerExecuted, 'N2 executed');
    Check(r.ReProbed, 'N2 reprobed');
    CheckEqual(r.InstallerExitCode, 0, 'N2 exit');
    CheckEqual(FakeHashCalls, 1, 'N2 hash calls');
    CheckEqual(FakeSigCalls, 1, 'N2 sig calls');
    CheckEqual(FakeRunCalls, 1, 'N2 run calls');
    // the runner received the EXACT verified path, the EXACT
    // documented arguments and the caller's bounded timeout
    CheckEqual(RawUtf8(FakeRunPath), RawUtf8(payload), 'N2 path');
    CheckEqual(FakeRunArgs, '/silent /install', 'N2 args');
    CheckEqual(FakeRunTimeout, 900000, 'N2 timeout');
    // the expected subject reached the signature check unmodified
    CheckEqual(FakeSigSubject, FAKE_SUBJECT, 'N2 subject');
    // TOCTOU: the guard handle was provably held while the "installer"
    // ran - the fake runner's write-open of the payload was denied
    Check(FakeRunSawWriteLock,
      'N2: payload was writable during execution (guard not held)');

    // ---- N3: present-but-old (<1587) -> provision -> usable
    ResetFakes;
    ScriptDetections([Det(wv2dsAvailable, '1.0.1586.99', wv2chHKLM),
      Det(wv2dsAvailable, '1.0.1587.0', wv2chHKLM)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poProvisioned, 'N3 outcome');
    CheckEqual(FakeRunCalls, 1, 'N3 run calls');

    // ---- N4: exit 0 but re-probe unavailable -> FAILS (the frozen
    // invariant: the re-probe verdict outranks the exit code)
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone),
      Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N4 outcome');
    Check(r.FailedStep = wv2psReProbe, 'N4 step');
    Check(r.InstallerExecuted, 'N4 executed');
    Check(r.ReProbed, 'N4 reprobed');
    CheckEqual(r.InstallerExitCode, 0, 'N4 exit');
    CheckUtf8(Pos('observational', r.Diagnostic) > 0,
      'N4 diagnostic must brand the exit code observational: %',
      [r.Diagnostic]);

    // ---- N5: exit nonzero but re-probe usable -> success via the
    // frozen PWebWv2ConfirmPostInstall, no CAP-6b1 special case
    ResetFakes;
    FakeRunExit := 1602;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone),
      Det(wv2dsAvailable, '151.0.4129.72', wv2chHKLM)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poProvisioned, 'N5 outcome');
    CheckEqual(r.InstallerExitCode, 1602, 'N5 exit preserved');

    // ---- N6: initial detection_error -> fail closed, NOTHING runs
    ResetFakes;
    ScriptDetections([Det(wv2dsDetectionError, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N6 outcome');
    Check(r.FailedStep = wv2psDetect, 'N6 step');
    Check(not r.InstallerExecuted, 'N6 executed');
    CheckEqual(FakeHashCalls, 0, 'N6 hash calls');
    CheckEqual(FakeSigCalls, 0, 'N6 sig calls');
    CheckEqual(FakeRunCalls, 0, 'N6: bootstrapper ran on unknown state');

    // ---- N7: sha mismatch -> never executed, both digests named
    ResetFakes;
    FakeHashHex := OTHER_SHA;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N7 outcome');
    Check(r.FailedStep = wv2psVerifyDigest, 'N7 step');
    Check(not r.InstallerExecuted, 'N7 executed');
    CheckEqual(FakeSigCalls, 0, 'N7: signature checked after sha fail');
    CheckEqual(FakeRunCalls, 0, 'N7: tampered payload executed');
    CheckUtf8(Pos(FAKE_SHA, r.Diagnostic) > 0,
      'N7 expected digest missing: %', [r.Diagnostic]);
    CheckUtf8(Pos(OTHER_SHA, r.Diagnostic) > 0,
      'N7 actual digest missing: %', [r.Diagnostic]);
    // unreadable payload equals a digest failure (fail closed)
    ResetFakes;
    FakeHashOk := False;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N7b outcome');
    Check(r.FailedStep = wv2psVerifyDigest, 'N7b step');
    CheckEqual(FakeRunCalls, 0, 'N7b: unreadable payload executed');
    // a malformed EXPECTED digest can never wave a payload through -
    // and the file is not even read
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, 'DEADBEEF', FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N7c outcome');
    Check(r.FailedStep = wv2psVerifyDigest, 'N7c step');
    CheckEqual(FakeHashCalls, 0, 'N7c: file read despite bad pin');
    CheckEqual(FakeRunCalls, 0, 'N7c run calls');

    // ---- N8: authenticode refused -> never executed, subject named
    ResetFakes;
    FakeSigOk := False;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N8 outcome');
    Check(r.FailedStep = wv2psVerifySignature, 'N8 step');
    Check(not r.InstallerExecuted, 'N8 executed');
    CheckEqual(FakeHashCalls, 1, 'N8: sha ran first');
    CheckEqual(FakeRunCalls, 0, 'N8: unsigned payload executed');
    CheckUtf8(Pos(FAKE_SUBJECT, r.Diagnostic) > 0,
      'N8 subject missing: %', [r.Diagnostic]);
    CheckUtf8(Pos('800B0100', r.Diagnostic) > 0,
      'N8 status missing: %', [r.Diagnostic]);
    // an empty expected subject fails closed before the check
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, '', 900000);
    Check(r.Outcome = wv2poFailed, 'N8b outcome');
    Check(r.FailedStep = wv2psVerifySignature, 'N8b step');
    CheckEqual(FakeSigCalls, 0, 'N8b sig calls');
    CheckEqual(FakeRunCalls, 0, 'N8b run calls');

    // ---- N10: bounded timeout -> killed, FAILS, no re-probe rescue
    ResetFakes;
    FakeRunOutcome := wv2roTimedOut;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N10 outcome');
    Check(r.FailedStep = wv2psExecute, 'N10 step');
    Check(r.InstallerExecuted, 'N10 executed');
    Check(not r.ReProbed, 'N10: a timeout was re-probed into success');
    CheckUtf8(Pos('killed', r.Diagnostic) > 0,
      'N10 kill missing from diagnostic: %', [r.Diagnostic]);
    // process-creation failure fails the same step, without execution
    ResetFakes;
    FakeRunOutcome := wv2roCreateFailed;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N10b outcome');
    Check(r.FailedStep = wv2psExecute, 'N10b step');
    Check(not r.InstallerExecuted, 'N10b executed');
    Check(not r.ReProbed, 'N10b reprobed');

    // ---- N12: re-probe below 1587 -> FAILS, the ONE threshold rules
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone),
      Det(wv2dsAvailable, '1.0.1586.99', wv2chHKLM)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N12 outcome');
    Check(r.FailedStep = wv2psReProbe, 'N12 step');
    Check(r.ReProbed, 'N12 reprobed');
    CheckEqual(r.ReProbe.RawVersion, '1.0.1586.99', 'N12 raw preserved');
    // a detection_error on re-probe equally fails (never a false pass)
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone),
      Det(wv2dsDetectionError, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'N12b outcome');
    Check(r.FailedStep = wv2psReProbe, 'N12b step');

    // ---- timeout bound 0 / INFINITE: refused at entry, before even
    // the detector runs (an empty script makes any probe raise)
    ResetFakes;
    ScriptDetections([]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 0);
    Check(r.Outcome = wv2poFailed, 'T0 outcome');
    Check(r.FailedStep = wv2psExecute, 'T0 step');
    Check(not r.InstallerExecuted, 'T0 executed');
    CheckEqual(FakeHashCalls, 0, 'T0 hash calls');
    CheckEqual(FakeSigCalls, 0, 'T0 sig calls');
    CheckEqual(FakeRunCalls, 0, 'T0 run calls');
    CheckUtf8(Pos('timeout bound invalid', r.Diagnostic) > 0,
      'T0 diagnostic: %', [r.Diagnostic]);
    ResetFakes;
    ScriptDetections([]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT,
      $FFFFFFFF);
    Check(r.Outcome = wv2poFailed, 'TINF outcome');
    Check(r.FailedStep = wv2psExecute, 'TINF step');
    CheckEqual(FakeRunCalls, 0, 'TINF run calls');
    CheckUtf8(Pos('timeout bound invalid', r.Diagnostic) > 0,
      'TINF diagnostic: %', [r.Diagnostic]);

    // ---- missing payload: the TOCTOU guard refuses before hashing
    ResetFakes;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun('Z:\no\such\payload.exe', FAKE_SHA,
      FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'GUARD outcome');
    Check(r.FailedStep = wv2psVerifyDigest, 'GUARD step');
    CheckEqual(FakeHashCalls, 0, 'GUARD: hashed an unheld payload');
    CheckEqual(FakeRunCalls, 0, 'GUARD run calls');
    CheckUtf8(Pos('cannot hold the payload', r.Diagnostic) > 0,
      'GUARD diagnostic: %', [r.Diagnostic]);

    // ---- executed-but-unknown: truthful fail-closed execute failure
    ResetFakes;
    FakeRunOutcome := wv2roExecutedUnknown;
    ScriptDetections([Det(wv2dsUnavailable, '', wv2chNone)]);
    r := PWebWv2ProvisionRun(payload, FAKE_SHA, FAKE_SUBJECT, 900000);
    Check(r.Outcome = wv2poFailed, 'UNKNOWN outcome');
    Check(r.FailedStep = wv2psExecute, 'UNKNOWN step');
    Check(r.InstallerExecuted,
      'UNKNOWN: an executed child reported as never started');
    Check(not r.ReProbed, 'UNKNOWN reprobed');
    CheckUtf8(Pos('UNCONFIRMED', r.Diagnostic) > 0,
      'UNKNOWN diagnostic lost the kill truthfulness: %',
      [r.Diagnostic]);
  finally
    PWebWv2ProvisionDetector := @PWebWv2Detect;
    PWebWv2ProvisionHasher := @PWebWv2FileSha256;
    PWebWv2ProvisionSignature := @PWebWv2AuthenticodeCheck;
    PWebWv2ProvisionRunner := @PWebWv2RunProcessBounded;
    ResetFakes;
    DeleteFile(payload);
  end;
end;

procedure TTestWv2Provision.VerdictTexts;
begin
  // the setup helper prints these and the gates regex-match them: a
  // rename must break this test before it can break a gate silently
  CheckEqual(PWebWv2ProvisionOutcomeText(wv2poFailed), 'Failed');
  CheckEqual(PWebWv2ProvisionOutcomeText(wv2poAlreadyUsable),
    'AlreadyUsable');
  CheckEqual(PWebWv2ProvisionOutcomeText(wv2poProvisioned),
    'Provisioned');
  CheckEqual(PWebWv2ProvisionStepText(wv2psNone), 'none');
  CheckEqual(PWebWv2ProvisionStepText(wv2psDetect), 'detect');
  CheckEqual(PWebWv2ProvisionStepText(wv2psVerifyDigest),
    'verify_digest');
  CheckEqual(PWebWv2ProvisionStepText(wv2psVerifySignature),
    'verify_signature');
  CheckEqual(PWebWv2ProvisionStepText(wv2psExecute), 'execute');
  CheckEqual(PWebWv2ProvisionStepText(wv2psReProbe), 'reprobe');
  // the documented arguments and bound are literally frozen here
  CheckEqual(PWEB_WV2_BOOTSTRAPPER_ARGS, '/silent /install');
  CheckEqual(PWEB_WV2_INSTALL_TIMEOUT_MS, 900000);
end;

procedure TTestWv2Provision.RealPrimitivesSmoke;
var
  temp: TFileName;
  hex, err, diag: RawUtf8;
  code: Integer;
  sys32: TFileName;
  outcome: TPWebWv2RunOutcome;
  started: Int64;
begin
  // ---- real SHA-256 against the FIPS 'abc' vector
  temp := TemporaryFileName;
  try
    FileFromString('abc', temp);
    Check(PWebWv2FileSha256(temp, hex, err), 'hash failed');
    CheckEqual(hex, ABC_SHA, 'FIPS vector mismatch');
    // ---- real WinVerifyTrust: a non-signed file is refused with its
    // status named (never a pass without an embedded signature)
    Check(not PWebWv2AuthenticodeCheck(temp, 'CN=Never Matches', diag),
      'unsigned file passed authenticode');
    CheckUtf8(Pos('800B', diag) > 0,
      'unsigned refusal does not name a trust status: %', [diag]);
  finally
    DeleteFile(temp);
  end;
  // a missing file can never produce a digest
  Check(not PWebWv2FileSha256('Z:\no\such\payload.exe', hex, err),
    'missing file hashed');
  Check(err <> '', 'missing-file error empty');
  // the (unsigned) test executable itself is refused too - a real PE
  Check(not PWebWv2AuthenticodeCheck(Executable.ProgramFileName,
    'CN=Never Matches', diag), 'unsigned PE passed authenticode');
  // ---- real bounded runner: create-failure path, nothing executed
  outcome := PWebWv2RunProcessBounded('Z:\no\such\image.exe', '',
    5000, code, diag);
  Check(outcome = wv2roCreateFailed, 'nonexistent image ran');
  Check(diag <> '', 'create-failure diagnostic empty');
  // ---- real bounded runner over harmless System32 tools (evidence
  // when present; a stripped-down host only skips, never fails)
  sys32 := IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('SystemRoot')) + 'System32\';
  if FileExists(sys32 + 'whoami.exe') then
  begin
    outcome := PWebWv2RunProcessBounded(sys32 + 'whoami.exe', '',
      30000, code, diag);
    Check(outcome = wv2roCompleted, 'whoami did not complete');
    CheckEqual(code, 0, 'whoami exit code');
  end
  else
    AddConsole('whoami.exe absent - completion leg skipped');
  if FileExists(sys32 + 'waitfor.exe') then
  begin
    // waitfor blocks on a signal that never comes: the bounded wait
    // must kill it and report the timeout as a failure outcome
    started := GetTickCount64;
    outcome := PWebWv2RunProcessBounded(sys32 + 'waitfor.exe',
      'pwebNeverSignalled /t 60', 1500, code, diag);
    Check(outcome = wv2roTimedOut, 'hung child not timed out');
    Check(GetTickCount64 - started < 45000,
      'timeout leg took implausibly long (kill did not work?)');
    CheckUtf8(Pos('killed', diag) > 0, 'kill not reported: %', [diag]);
  end
  else
    AddConsole('waitfor.exe absent - timeout leg skipped');
end;

end.
