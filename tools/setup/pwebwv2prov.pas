program pwebwv2prov;

{ CAP-6b1 WebView2 provisioning helper for the normal-profile Inno
  Setup project (tools/setup/normal.iss).

  One compiled Pascal console program, reusing the frozen CAP-6b0
  policy functions through pweb.platform.webview2.provision - never a
  PascalScript re-implementation. The setup runs it in
  PrepareToInstall; a nonzero exit aborts the installation before any
  file lands, so no launchable app can ever exist on a machine whose
  runtime could not be proven usable.

    pwebwv2prov <installer> <sha256> <subject> [timeout-ms] [logfile]
    pwebwv2prov --verify-only <file> <sha256> <subject> [logfile]

    installer   exact path of the extracted Evergreen Bootstrapper
    sha256      ratified lock digest (64 lowercase hex), derived from
                webview2-runtime.lock at BUILD time, never at run time
    subject     ratified Authenticode leaf subject, same provenance
    timeout-ms  optional bounded wait (1..900000; default 900000)
    logfile     optional file receiving a copy of every output line
                (the .iss loads it into the Inno setup log)

  --verify-only runs ONLY the two verification primitives (SHA-256
  digest, then WinVerifyTrust + exact leaf subject) over <file>: no
  detection, no execution, no re-probe - it exists so gates can prove
  the native ACCEPT path against the real lock-verified artifact and
  every refusal leg unconditionally, on any host, with zero risk of
  ever running the payload.

  Machine-parsable verdict lines (gates and the Inno log grep these):
    WV2PROV_DETECT status=... channel=... raw="..." usable=... decision=...
    WV2PROV_EXEC exit=...              (only when the installer ran)
    WV2PROV_REPROBE status=... raw="..." usable=...   (only when probed)
    WV2PROV_VERIFYONLY file=...        (only in --verify-only mode)
    WV2PROV_SUBJECT <native leaf subject>  (verify-only accept: the
       exact CN-first rendering the native check extracted)
    WV2PROV_DIAG <diagnostic>
    WV2PROV_RESULT outcome=<AlreadyUsable|Provisioned|Verified|Failed>
       step=<none|detect|verify_digest|verify_signature|execute|
       reprobe|usage>
       ('Verified' only in --verify-only mode; 'usage' is a reserved
       helper-only step value emitted with exit 64)

  Exit codes for the Inno gate (shared by both modes where relevant):
    0  success: AlreadyUsable (skip path) or Provisioned (re-probe
       proved the runtime usable - the frozen invariant), or a
       --verify-only run where both axes passed
    1  crash/unexpected error - the helper never completed its
       contract; always a failure (fail closed)
    2  initial detection failure          (N6 - installer never ran)
    3  sha256 verification failure        (N7 - installer never ran)
    4  authenticode verification failure  (N8 - installer never ran)
    5  execution failure: process creation failed, bounded timeout
       with kill, or executed-with-unknowable-fate (N10)
    6  post-install re-probe unusable     (N4/N12 - exit code never
       outranks the re-probe)
    64 usage/argument error (step=usage)

  The optional logfile receives every line printed, INCLUDING on
  usage errors and crashes - the log copy is flushed on every exit
  path once a log path was parsed. }

{$mode ObjFPC}{$H+}

{$apptype console}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.unicode,
  pweb.platform.webview2.runtime,
  pweb.platform.webview2.provision;

const
  EXIT_OK = 0;
  EXIT_DETECT = 2;
  EXIT_DIGEST = 3;
  EXIT_SIGNATURE = 4;
  EXIT_EXECUTE = 5;
  EXIT_REPROBE = 6;
  EXIT_USAGE = 64;

var
  Captured: array of RawUtf8;

procedure Emit(const Line: RawUtf8);
var
  n: PtrInt;
begin
  writeln(Utf8ToString(Line));
  n := Length(Captured);
  SetLength(Captured, n + 1);
  Captured[n] := Line;
end;

procedure FlushLog(const LogFile: string);
var
  all: RawUtf8;
  i: PtrInt;
  list: TStringList;
begin
  if LogFile = '' then
    exit;
  all := '';
  for i := 0 to High(Captured) do
    all := all + Captured[i] + #13#10;
  try
    list := TStringList.Create;
    try
      list.Text := Utf8ToString(all);
      list.SaveToFile(LogFile);
    finally
      list.Free;
    end;
  except
    // the log copy is evidence only: a write failure must never
    // change the provisioning verdict already printed on stdout
    on E: Exception do
      writeln(ErrOutput, 'pwebwv2prov: log write failed: ', E.Message);
  end;
end;

function BoolText(Value: Boolean): RawUtf8;
begin
  if Value then
    Result := 'true'
  else
    Result := 'false';
end;

procedure EmitDetect(const Marker: RawUtf8;
  const D: TPWebWv2DetectionResult);
begin
  Emit(Marker +
    ' status=' + PWebWv2StatusText(D.Status) +
    ' channel=' + PWebWv2ChannelText(D.Channel) +
    ' raw="' + D.RawVersion + '"' +
    ' usable=' + BoolText(PWebWv2DetectionUsable(D)) +
    ' decision=' + PWebWv2DecisionText(PWebWv2ProvisioningDecide(D)));
end;

function StepExitCode(Step: TPWebWv2ProvisionStep): Integer;
begin
  case Step of
    wv2psDetect:
      Result := EXIT_DETECT;
    wv2psVerifyDigest:
      Result := EXIT_DIGEST;
    wv2psVerifySignature:
      Result := EXIT_SIGNATURE;
    wv2psExecute:
      Result := EXIT_EXECUTE;
    wv2psReProbe:
      Result := EXIT_REPROBE;
  else
    Result := 1; // fail closed: an unnamed failure is still a failure
  end;
end;

// digest + signature primitives ONLY: no detection, no execution -
// exit codes mirror the orchestrator's verification steps
function RunVerifyOnly(const FilePath: TFileName;
  const ExpectedSha, ExpectedSubject: RawUtf8): Integer;
var
  actual, hashErr, sigDiag: RawUtf8;
begin
  Emit('WV2PROV_VERIFYONLY file=' + StringToUtf8(FilePath));
  if not PWebWv2FileSha256(FilePath, actual, hashErr) then
  begin
    Emit('WV2PROV_DIAG sha256 verification impossible: ' + hashErr);
    Emit('WV2PROV_RESULT outcome=Failed step=verify_digest');
    Result := EXIT_DIGEST;
    exit;
  end;
  if actual <> ExpectedSha then
  begin
    Emit('WV2PROV_DIAG sha256 mismatch: expected ' + ExpectedSha +
      ', got ' + actual + ' -- payload refused');
    Emit('WV2PROV_RESULT outcome=Failed step=verify_digest');
    Result := EXIT_DIGEST;
    exit;
  end;
  if not PWebWv2AuthenticodeCheck(FilePath, ExpectedSubject,
      sigDiag) then
  begin
    Emit('WV2PROV_DIAG ' + sigDiag);
    Emit('WV2PROV_RESULT outcome=Failed step=verify_signature');
    Result := EXIT_SIGNATURE;
    exit;
  end;
  // sigDiag on accept is 'authenticode Valid, subject=<native text>':
  // surface the native rendering explicitly for byte-equality gates
  Emit('WV2PROV_SUBJECT ' + ExpectedSubject);
  Emit('WV2PROV_DIAG ' + sigDiag);
  Emit('WV2PROV_RESULT outcome=Verified step=none');
  Result := EXIT_OK;
end;

var
  InstallerPath: TFileName;
  ExpectedSha, ExpectedSubject: RawUtf8;
  TimeoutMs: Integer;
  LogFile: string;
  VerifyOnly: Boolean;
  ArgBase: Integer;
  Res: TPWebWv2ProvisionResult;
begin
  ExitCode := EXIT_USAGE;
  LogFile := '';
  try
    try
      VerifyOnly := (ParamCount >= 1) and
                    (ParamStr(1) = '--verify-only');
      ArgBase := 0;
      if VerifyOnly then
        ArgBase := 1;
      if (ParamCount < ArgBase + 3) or
         (ParamCount > ArgBase + 4 + Ord(not VerifyOnly)) then
      begin
        Emit('WV2PROV_USAGE pwebwv2prov <installer> <sha256> <subject>' +
          ' [timeout-ms] [logfile] | pwebwv2prov --verify-only <file>' +
          ' <sha256> <subject> [logfile]');
        Emit('WV2PROV_RESULT outcome=Failed step=usage');
        exit;
      end;
      InstallerPath := ParamStr(ArgBase + 1);
      ExpectedSha := StringToUtf8(ParamStr(ArgBase + 2));
      ExpectedSubject := StringToUtf8(ParamStr(ArgBase + 3));
      if VerifyOnly then
      begin
        if ParamCount >= ArgBase + 4 then
          LogFile := ParamStr(ArgBase + 4);
        if (InstallerPath = '') or
           (ExpectedSha = '') or
           (ExpectedSubject = '') then
        begin
          Emit('WV2PROV_USAGE invalid --verify-only argument');
          Emit('WV2PROV_RESULT outcome=Failed step=usage');
          exit;
        end;
        ExitCode := RunVerifyOnly(InstallerPath, ExpectedSha,
          ExpectedSubject);
        exit;
      end;
      TimeoutMs := PWEB_WV2_INSTALL_TIMEOUT_MS;
      if ParamCount >= 4 then
        TimeoutMs := StrToIntDef(ParamStr(4), -1);
      if ParamCount >= 5 then
        LogFile := ParamStr(5);
      if (InstallerPath = '') or
         (ExpectedSha = '') or
         (ExpectedSubject = '') or
         (TimeoutMs < 1) or
         (TimeoutMs > PWEB_WV2_INSTALL_TIMEOUT_MS) then
      begin
        Emit('WV2PROV_USAGE invalid argument (timeout must be 1..' +
          RawUtf8(IntToStr(PWEB_WV2_INSTALL_TIMEOUT_MS)) + ' ms)');
        Emit('WV2PROV_RESULT outcome=Failed step=usage');
        exit;
      end;

      Res := PWebWv2ProvisionRun(InstallerPath, ExpectedSha,
        ExpectedSubject, Cardinal(TimeoutMs));

      EmitDetect('WV2PROV_DETECT', Res.Initial);
      if Res.InstallerExecuted then
        Emit('WV2PROV_EXEC exit=' + RawUtf8(IntToStr(Res.InstallerExitCode)));
      if Res.ReProbed then
        Emit('WV2PROV_REPROBE status=' +
          PWebWv2StatusText(Res.ReProbe.Status) +
          ' raw="' + Res.ReProbe.RawVersion + '"' +
          ' usable=' + BoolText(PWebWv2DetectionUsable(Res.ReProbe)));
      Emit('WV2PROV_DIAG ' + Res.Diagnostic);
      Emit('WV2PROV_RESULT outcome=' +
        PWebWv2ProvisionOutcomeText(Res.Outcome) +
        ' step=' + PWebWv2ProvisionStepText(Res.FailedStep));

      if Res.Outcome in [wv2poAlreadyUsable, wv2poProvisioned] then
        ExitCode := EXIT_OK
      else
        ExitCode := StepExitCode(Res.FailedStep);
    except
      // fail closed: an unexpected exception is a provisioning failure
      on E: Exception do
      begin
        Emit('WV2PROV_CRASH ' + RawUtf8(E.ClassName) + ': ' +
          StringToUtf8(E.Message));
        ExitCode := 1;
      end;
    end;
  finally
    // every exit path flushes the log copy once a log path was parsed
    FlushLog(LogFile);
  end;
end.
