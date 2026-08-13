program pwebwv2fixed;

{ CAP-6b3 fixed-runtime helper for the fixed-profile Inno Setup project
  (tools/setup/fixed.iss) and for the CAP-6b3 gates.

  One compiled Pascal console program, reusing the ratified CAP-6b3
  primitives through pweb.platform.webview2.fixed - never a
  PascalScript re-implementation. Windows security descriptors can not
  be walked from PascalScript at all (there is no pointer arithmetic
  there), so the ONE place ACL code exists in this repository is the
  Pascal unit, and both the installer and the gates reach it through
  this helper.

    pwebwv2fixed --acl-apply  <dir> [logfile]
    pwebwv2fixed --acl-verify <dir> [logfile]
    pwebwv2fixed --validate   <runtime-root> [logfile]
    pwebwv2fixed --verify-signers <runtime-root> <subject> [logfile]
    pwebwv2fixed --postinstall    <runtime-root> <subject> [logfile]
    pwebwv2fixed --manifest-write  <tree> <manifest-file> [logfile]
    pwebwv2fixed --manifest-verify <tree> <manifest-file> [logfile]
    pwebwv2fixed --file-version <file> [logfile]
    pwebwv2fixed --detect [logfile]
    pwebwv2fixed --pin [logfile]

    dir           the extracted Fixed Runtime tree root the Windows 10
                  AppContainer grant applies to
    runtime-root  the bundled runtime folder holding WebView2Loader.dll
                  and the extracted tree (validation only - this helper
                  NEVER selects a runtime; only the app does that, in
                  its own process, before webview_create)
    subject       ratified Authenticode leaf subject, derived from
                  webview2-runtime.lock at BUILD time, never at run time
    tree          a directory whose deterministic manifest is written
                  or verified through the CAP-6b2 streamed digest
    file          one binary whose NUMERIC VS_FIXEDFILEINFO version is
                  printed - the build script asserts the tree version
                  through THIS mode, so the build and every installed
                  app read the version through one code path
    logfile       optional file receiving a copy of every output line
                  (the .iss loads it into the Inno setup log)

  --postinstall is what the fixed profile's setup runs after its files
  land: verify the five critical binaries' signatures, then apply the
  AppContainer grant, then re-read and verify that grant BY SID. Any
  step failing aborts the installation.

  --pin prints the ratified pin facts so a build script can cross-check
  the Pascal constants against webview2-runtime.lock (the house
  1587-cross-check idiom) instead of duplicating literals.

  --detect runs the frozen CAP-6b0 EVERGREEN detector and reports it,
  changing nothing. The fixed profile never consults it at run time -
  it exists so the clean-machine gate can OBSERVE, before and after,
  that the machine has no usable Evergreen runtime and that installing
  this profile did not give it one.

  Machine-parsable verdict lines (gates and the Inno log grep these).
  The COMPILED-IN pin facts and the OBSERVED facts of a real tree get
  distinct line prefixes on purpose, so no consumer can grep one and
  silently accept the other:
    WV2FIXED_MODE <mode> target=...
    WV2FIXED_PIN version=... treename=... loader=... subdir=...
       manifest=...                    (--pin: compiled-in constants)
    WV2FIXED_VALIDATED version=... treedir=... loaderpath=...
                                       (--validate: an observed tree)
    WV2FIXED_FILEVERSION file=... version=...
    WV2FIXED_SIGNERS <diagnostic>
    WV2FIXED_DETECT status=... channel=... raw="..." usable=...
    WV2FIXED_DIAG <diagnostic>
    WV2FIXED_RESULT outcome=<Ok|Failed> step=<none|acl|manifest|
       signers|usage|... the fixed-runtime step texts ...>

  Exit codes for the Inno gate:
    0  success
    1  crash/unexpected error (fail closed)
    2  ACL apply failed
    3  ACL verify failed
    4  manifest write/verify failed
    5  tree validation failed
    6  critical-binary signature verification failed
    64 usage/argument error

  --detect always exits 0: it REPORTS machine state, it never judges
  it (the gate reading the line decides what that state means).

  Nothing here downloads, installs, registers or executes anything,
  and no URL exists in this file. }

{$mode ObjFPC}{$H+}

{$apptype console}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.unicode,
  pweb.platform.webview2.runtime,
  pweb.platform.webview2.provision,
  pweb.platform.webview2.fixed;

const
  EXIT_OK = 0;
  EXIT_ACL_APPLY = 2;
  EXIT_ACL_VERIFY = 3;
  EXIT_MANIFEST = 4;
  EXIT_VALIDATE = 5;
  EXIT_SIGNERS = 6;
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
    // the log copy is evidence only: a write failure must never change
    // the verdict already printed on stdout
    on E: Exception do
      writeln(ErrOutput, 'pwebwv2fixed: log write failed: ', E.Message);
  end;
end;

procedure EmitResult(const Outcome, Step: RawUtf8);
begin
  Emit('WV2FIXED_RESULT outcome=' + Outcome + ' step=' + Step);
end;

function BoolText(Value: Boolean): RawUtf8;
begin
  if Value then
    Result := 'true'
  else
    Result := 'false';
end;

var
  Mode: string;
  Target, Second: TFileName;
  LogFile: string;
  Diag, Second2: RawUtf8;
  Validated: TPWebWv2FixedResult;
  Detection: TPWebWv2DetectionResult;
begin
  ExitCode := EXIT_USAGE;
  LogFile := '';
  try
    try
      Mode := ParamStr(1);
      Target := ParamStr(2);
      Second := ParamStr(3);
      if Mode = '--pin' then
      begin
        if ParamCount >= 2 then
          LogFile := ParamStr(2);
        Emit('WV2FIXED_MODE pin target=');
        // compiled-in constants ONLY - never an observed tree; see the
        // header note on why this line and WV2FIXED_VALIDATED differ
        Emit('WV2FIXED_PIN version=' + PWEB_WV2_FIXED_VERSION +
          ' treename=' + StringToUtf8(PWebWv2FixedTreeName) +
          ' loader=' + PWEB_WV2_FIXED_LOADER +
          ' subdir=' + PWEB_WV2_FIXED_SUBDIR +
          ' manifest=' + PWEB_WV2_FIXED_MANIFEST_TAG);
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      if Mode = '--detect' then
      begin
        if ParamCount >= 2 then
          LogFile := ParamStr(2);
        Emit('WV2FIXED_MODE detect target=');
        // the frozen CAP-6b0 Evergreen detector, reported and NOT
        // acted upon: this profile's runtime is the bundled tree, and
        // no Evergreen verdict can ever change that in either direction
        Detection := PWebWv2Detect;
        Emit('WV2FIXED_DETECT status=' +
          PWebWv2StatusText(Detection.Status) +
          ' channel=' + PWebWv2ChannelText(Detection.Channel) +
          ' raw="' + Detection.RawVersion + '"' +
          ' usable=' + BoolText(PWebWv2DetectionUsable(Detection)));
        Emit('WV2FIXED_DIAG ' + Detection.Diagnostic);
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      if (Mode = '--acl-apply') or
         (Mode = '--acl-verify') or
         (Mode = '--validate') or
         (Mode = '--file-version') then
      begin
        if ParamCount >= 3 then
          LogFile := ParamStr(3);
        if (ParamCount < 2) or
           (ParamCount > 3) or
           (Target = '') then
        begin
          Emit('WV2FIXED_USAGE pwebwv2fixed ' + StringToUtf8(Mode) +
            ' <dir|file> [logfile]');
          EmitResult('Failed', 'usage');
          exit;
        end;
      end
      else if (Mode = '--verify-signers') or
              (Mode = '--postinstall') or
              (Mode = '--manifest-write') or
              (Mode = '--manifest-verify') then
      begin
        if ParamCount >= 4 then
          LogFile := ParamStr(4);
        if (ParamCount < 3) or
           (ParamCount > 4) or
           (Target = '') or
           (Second = '') then
        begin
          Emit('WV2FIXED_USAGE pwebwv2fixed ' + StringToUtf8(Mode) +
            ' <tree|runtime-root> <manifest-file|subject> [logfile]');
          EmitResult('Failed', 'usage');
          exit;
        end;
      end
      else
      begin
        Emit('WV2FIXED_USAGE pwebwv2fixed --acl-apply|--acl-verify|' +
          '--validate|--file-version <dir|file> [logfile] | ' +
          '--verify-signers|--postinstall <runtime-root> <subject> ' +
          '[logfile] | --manifest-write|--manifest-verify <tree> ' +
          '<manifest-file> [logfile] | --detect | --pin');
        EmitResult('Failed', 'usage');
        exit;
      end;

      Emit('WV2FIXED_MODE ' + StringToUtf8(Copy(Mode, 3, MaxInt)) +
        ' target=' + StringToUtf8(Target));

      if Mode = '--file-version' then
      begin
        // the build script asserts the extracted tree's version through
        // THIS mode, so the build side and every installed app read the
        // version through one code path (the NUMERIC VS_FIXEDFILEINFO,
        // never the string resource, which can legitimately differ)
        if not PWebWv2FixedFileVersion(Target, Diag, Second2) then
        begin
          Emit('WV2FIXED_DIAG ' + Second2);
          EmitResult('Failed', 'version');
          ExitCode := EXIT_VALIDATE;
          exit;
        end;
        Emit('WV2FIXED_FILEVERSION file=' + StringToUtf8(Target) +
          ' version=' + Diag);
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      if (Mode = '--verify-signers') or
         (Mode = '--postinstall') then
      begin
        if not PWebWv2FixedVerifySigners(Target,
             StringToUtf8(Second), Diag) then
        begin
          Emit('WV2FIXED_DIAG ' + Diag);
          EmitResult('Failed', 'signers');
          ExitCode := EXIT_SIGNERS;
          exit;
        end;
        Emit('WV2FIXED_SIGNERS ' + Diag);
        if Mode = '--verify-signers' then
        begin
          EmitResult('Ok', 'none');
          ExitCode := EXIT_OK;
          exit;
        end;
        // --postinstall continues into the ACL half over the tree
        // INSIDE the runtime root the signers were just proven on
        Target := IncludeTrailingPathDelimiter(Target) +
          PWebWv2FixedTreeName;
        Mode := '--acl-apply';
      end;
      if Mode = '--acl-apply' then
      begin
        if not PWebWv2FixedAclApply(Target, Diag) then
        begin
          Emit('WV2FIXED_DIAG ' + Diag);
          EmitResult('Failed', 'acl');
          ExitCode := EXIT_ACL_APPLY;
          exit;
        end;
        Emit('WV2FIXED_DIAG ' + Diag);
        // apply is never trusted on its own: the grant is immediately
        // re-read from the object and verified BY SID
        if not PWebWv2FixedAclVerify(Target, Diag) then
        begin
          Emit('WV2FIXED_DIAG ' + Diag);
          EmitResult('Failed', 'acl');
          ExitCode := EXIT_ACL_VERIFY;
          exit;
        end;
        Emit('WV2FIXED_DIAG ' + Diag);
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      if Mode = '--acl-verify' then
      begin
        if not PWebWv2FixedAclVerify(Target, Diag) then
        begin
          Emit('WV2FIXED_DIAG ' + Diag);
          EmitResult('Failed', 'acl');
          ExitCode := EXIT_ACL_VERIFY;
          exit;
        end;
        Emit('WV2FIXED_DIAG ' + Diag);
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      if Mode = '--manifest-write' then
      begin
        if not PWebWv2FixedManifestWrite(Target, Second, Diag) then
        begin
          Emit('WV2FIXED_DIAG ' + Diag);
          EmitResult('Failed', 'manifest');
          ExitCode := EXIT_MANIFEST;
          exit;
        end;
        Emit('WV2FIXED_DIAG wrote ' + StringToUtf8(Second));
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      if Mode = '--manifest-verify' then
      begin
        if not PWebWv2FixedManifestVerify(Target, Second, Diag) then
        begin
          Emit('WV2FIXED_DIAG ' + Diag);
          EmitResult('Failed', 'manifest');
          ExitCode := EXIT_MANIFEST;
          exit;
        end;
        Emit('WV2FIXED_DIAG tree matches ' + StringToUtf8(Second));
        EmitResult('Ok', 'none');
        ExitCode := EXIT_OK;
        exit;
      end;
      // --validate: the app-side pre-create validation, WITHOUT the
      // selection half (this process must never own the override)
      Validated := PWebWv2FixedValidate(Target);
      Emit('WV2FIXED_DIAG ' + Validated.Diagnostic);
      if Validated.Status <> wv2fxValidated then
      begin
        EmitResult('Failed',
          PWebWv2FixedStepText(Validated.FailedStep));
        ExitCode := EXIT_VALIDATE;
        exit;
      end;
      // OBSERVED facts of a real tree - deliberately a different line
      // prefix and different keys from WV2FIXED_PIN above
      Emit('WV2FIXED_VALIDATED version=' + Validated.TreeVersion +
        ' treedir=' + StringToUtf8(Validated.TreeDir) +
        ' loaderpath=' + StringToUtf8(Validated.LoaderPath));
      EmitResult('Ok', 'none');
      ExitCode := EXIT_OK;
    except
      // fail closed: an unexpected exception is a failure
      on E: Exception do
      begin
        Emit('WV2FIXED_CRASH ' + RawUtf8(E.ClassName) + ': ' +
          StringToUtf8(E.Message));
        ExitCode := 1;
      end;
    end;
  finally
    // every exit path flushes the log copy once a log path was parsed
    FlushLog(LogFile);
  end;
end.
