; CAP-6b3 FIXED-RUNTIME profile per-user installer for the CAP-6
; release triple (releaseapp.exe + app.pwb + webview.dll), deploying
; the lock-verified x64 WebView2 Fixed Version Runtime tree plus the
; pinned WebView2 SDK's WebView2Loader.dll as ordinary application
; content under {app}\runtime\webview2.
;
; Built ONLY through test/cap6b3/build_fixed_setup.ps1, which derives
; every /D define from the ratified locks at BUILD time:
;   PWEB_RUNTIME_DIR staged runtime folder (extracted Fixed Runtime
;                    tree + the pinned-SDK loader), validated and
;                    manifested against webview2-runtime.lock before
;                    ISCC ever sees it
;   PWEB_FIXED_TREE  the extracted tree's folder name, derived from
;                    the pinned version (used by the gate below)
;   PWEB_FIXED_SUBJECT  ratified Authenticode leaf subject from
;                    webview2-runtime.lock; the gate below refuses to
;                    complete unless the five critical binaries that
;                    LANDED carry a Valid signature with exactly this
;                    subject
;   PWEB_ACL_HELPER  compiled native post-install helper (default
;                    pwebwv2fixed.exe), extracted to {tmp} on demand
;                    and NEVER installed. TEST HOOK, mirroring the
;                    ratified PWEB_PROV_HELPER convention: the
;                    abort-probe TEST build overrides it with an
;                    always-fail stub so the gates can PROVE, by
;                    automation, that a failing gate leaves nothing
;                    installed. Nothing else may ever override it.
;   (plus the shared identity defines documented in pwebappsetup.issi)
;
; Fixed-profile hard invariants:
;   - this manifest embeds NO Evergreen Bootstrapper, NO Evergreen
;     Standalone Installer and NO loose frontend files; it runs NO
;     provisioning of any kind and contains no network path whatever.
;     The bundled tree is the runtime, full stop - there is no "try
;     Evergreen instead" and no online fallback, ever.
;   - there is no [Run] launch entry and no [Icons] entry: setup
;     either completes with a verified runtime tree or fails.
;   - the ONE piece of logic here is the post-install gate, run through
;     the compiled helper (Windows security descriptors can not be
;     walked from PascalScript, and localized identity display names
;     must never be parsed):
;       1. the five critical binaries that ACTUALLY LANDED are
;          Authenticode-verified against the ratified leaf subject -
;          the build-time signer check proves the staged bytes, this
;          one proves the deployed bytes;
;       2. the Windows 10 AppContainer grant a Fixed Version Runtime
;          >= 120 requires on an unpackaged Win32 host is applied -
;          exactly S-1-15-2-1 and S-1-15-2-2, Read+Execute, (OI)(CI)
;          on the tree root;
;       3. that grant is re-read from the object and verified BY SID.
;     It needs no elevation under the ratified per-user scope; if a
;     machine ever demanded one, the apply fails and setup aborts
;     rather than widening the scope.
;
; Why the gate is expressed as a VERDICT FILE rather than as a raised
; exception. The pinned ISCC 6.7.3 lifecycle was measured directly
; (throwaway probes, all with /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
; /SP-):
;
;   seam                                   exit  {app}   uninst key
;   -------------------------------------  ----  ------  ----------
;   CurStepChanged(ssPostInstall) + raise      0  present  present
;     (log: "Installation process succeeded", THEN "CurStepChanged
;      raised an exception" - the exception is swallowed)
;   AfterInstall + raise                       0  present  present
;     (reported as an OK-only "Internal error" box; install CONTINUES)
;   AfterInstall + our own DelTree + raise     4  absent   absent
;     (exit 4 was an incidental EFileError our DelTree caused by
;      racing the installer - not a supported abort)
;   CurStepChanged(ssInstall) + raise          3  absent   absent
;     (a genuine fatal abort - but BEFORE any file is copied)
;   verdict file present  (gate passed)        0  installed present
;   verdict file ABSENT   (gate failed)        5  absent   absent
;     (log: "Defaulting to Abort for suppressed message box
;      (Abort/Retry/Ignore) ... does not exist" -> "Rolling back
;      changes. Starting the uninstallation process. Uninstallation
;      process succeeded.")
;
;     Two facts settle it: a script exception raised from AfterInstall
;     or ssPostInstall is SWALLOWED and can never fail setup, and
;     Inno's own rollback machinery exists, works, and is triggered by
;     a genuine Setup file error during the installing phase. So the
;     gate's verdict is expressed as something SETUP ITSELF checks: the
;     last [Files] entry is an `external` source in {tmp} that the gate
;     creates ONLY on success. Its BeforeInstall runs after the whole
;     runtime tree has landed (post-copy validation is unchanged and
;     unweakened) and before the uninstall key is written; a missing
;     source is a real Setup error, with no skipifsourcedoesntexist to
;     silence it, so Setup rolls the installation back itself. Nothing
;     here removes files or registry keys by hand: our own DelTree is
;     exactly what produced the incidental EFileError above.
;     Fail-closed by construction, relied on deliberately: if the gate
;     itself crashes, the exception is swallowed but no verdict file is
;     written, so the abort still happens. ABSENCE of the verdict file
;     is the failure signal, and an explicit success write is the only
;     way to produce it.
;   - the installed app ALSO refuses to start when that grant is
;     absent, so even a machine that somehow kept a partial install can
;     never launch on an unverifiable runtime.
;
; The [Setup] identity (same AppId, same {localappdata} location, same
; PrivilegesRequired=lowest) and the release triple live in the shared
; include tools/setup/pwebappsetup.issi, consumed by ALL profiles so
; they can never fork. This file only names the profile, adds the
; runtime tree and runs the ACL gate.

#ifndef PWEB_RUNTIME_DIR
  #error PWEB_RUNTIME_DIR must be defined - build via test/cap6b3/build_fixed_setup.ps1
#endif
#ifndef PWEB_FIXED_TREE
  #error PWEB_FIXED_TREE must be defined - build via test/cap6b3/build_fixed_setup.ps1
#endif
#ifndef PWEB_FIXED_SUBJECT
  #error PWEB_FIXED_SUBJECT must be defined - build via test/cap6b3/build_fixed_setup.ps1
#endif
#ifndef PWEB_ACL_HELPER
  #define PWEB_ACL_HELPER "pwebwv2fixed.exe"
#endif
; the gate's verdict, written to {tmp} by FixedRuntimeGate ONLY when
; the helper exits 0, and consumed as the last [Files] entry's external
; source. deleteafterinstall keeps it out of the installed layout.
#define PWEB_VERDICT_FILE "pweb-fixed-runtime.verdict"
#define PWEB_PROFILE "fixed"

#include "pwebappsetup.issi"

[Files]
; the bundled runtime, deployed as ordinary application content: the
; extracted Fixed Version Runtime tree plus the pinned-SDK loader. The
; loader sits INSIDE this folder on purpose, so the application can
; only ever load it by explicit absolute path, never by DLL search
; order.
Source: "{#PWEB_RUNTIME_DIR}\*"; DestDir: "{app}\runtime\webview2"; \
    Flags: ignoreversion recursesubdirs createallsubdirs
; the ACL helper is extracted to {tmp} on demand and auto-deleted by
; Inno when setup exits (success OR abort) - it is never installed to
; {app}, so the installed layout stays exactly the release triple plus
; the runtime folder
Source: "{#PWEB_PAYLOAD_DIR}\{#PWEB_ACL_HELPER}"; Flags: dontcopy
; THE GATE. This must stay the LAST entry: its BeforeInstall therefore
; runs after every file above has landed, so the helper verifies the
; DEPLOYED tree. The source is `external` and lives in {tmp}; the gate
; creates it only when the helper exits 0. If it is missing, Setup
; cannot find its source and rolls the whole installation back - which
; is the abort. There is deliberately NO skipifsourcedoesntexist here:
; that flag would turn the failure signal into a silent skip.
Source: "{tmp}\{#PWEB_VERDICT_FILE}"; DestDir: "{app}"; \
    Flags: external ignoreversion deleteafterinstall; \
    BeforeInstall: FixedRuntimeGate

[Code]
// The post-install gate. Runs as the LAST [Files] entry's
// BeforeInstall, so the whole runtime tree has already landed and the
// helper verifies the DEPLOYED bytes:
//   1. Authenticode of the five critical binaries vs the ratified
//      leaf subject;
//   2. the AppContainer grant applied to the tree root;
//   3. that grant re-read and verified BY SID.
//
// This procedure NEVER removes files or registry keys and NEVER
// raises to abort - both were measured to be either impossible or
// harmful (see the header table). It communicates exactly one bit:
// the verdict file exists, or it does not. Setup turns the second
// case into its own rollback.
procedure FixedRuntimeGate;
var
  Helper, RuntimeRoot, GateLog, Verdict, Params, Reason: String;
  Output: AnsiString;
  Rc: Integer;
begin
  Verdict := ExpandConstant('{tmp}\{#PWEB_VERDICT_FILE}');
  // a stale verdict left in this {tmp} could wave a FAILED gate
  // through: the only verdict that may exist is the one written below
  DeleteFile(Verdict);
  Reason := '';
  ExtractTemporaryFile('{#PWEB_ACL_HELPER}');
  Helper := ExpandConstant('{tmp}\{#PWEB_ACL_HELPER}');
  RuntimeRoot := ExpandConstant('{app}\runtime\webview2');
  GateLog := ExpandConstant('{tmp}\pwebwv2fixed.log');
  Params := '--postinstall "' + RuntimeRoot + '" "{#PWEB_FIXED_SUBJECT}" "' +
    GateLog + '"';
  Log('PWEB_WV2FIXED launching: ' + Helper + ' ' + Params);
  if not Exec(Helper, Params, ExpandConstant('{tmp}'), SW_HIDE,
       ewWaitUntilTerminated, Rc) then
  begin
    Log('PWEB_WV2FIXED exec-failed');
    Reason := 'The WebView2 fixed-runtime post-install helper could not be' +
      ' started.';
  end
  else
  begin
    if LoadStringFromFile(GateLog, Output) then
      Log('PWEB_WV2FIXED output:' + #13#10 + Output)
    else
      Log('PWEB_WV2FIXED output file missing');
    Log('PWEB_WV2FIXED exit=' + IntToStr(Rc));
    if Rc = 0 then
    begin
      // the ONE place a verdict file is ever produced
      if SaveStringToFile(Verdict, 'verified' + #13#10, False) then
      begin
        Log('PWEB_WV2FIXED verdict written: ' + Verdict);
        exit;
      end;
      Reason := 'The WebView2 fixed-runtime verification succeeded but its' +
        ' verdict could not be recorded.';
    end
    else
      Reason := 'WebView2 fixed-runtime post-install verification failed' +
        ' (helper exit ' + IntToStr(Rc) + ').';
  end;
  // No verdict file. Setup will fail to find this entry's source and
  // roll the installation back. Say WHY first: without this, an
  // interactive user would see only "The source file ... does not
  // exist", which explains nothing.
  //
  // SuppressibleMsgBox, never MsgBox: /SUPPRESSMSGBOXES only applies to
  // the Suppressible* variants, so a plain MsgBox here would BLOCK a
  // /VERYSILENT run forever waiting for a click nobody can give -
  // measured, after it hung the abort-probe gate. Suppressed runs take
  // the IDOK default and carry straight on to the missing-source abort;
  // the Log() below is what automation reads either way.
  Log('PWEB_WV2FIXED REFUSED: ' + Reason);
  SuppressibleMsgBox(Reason + #13#10#13#10 +
    'Setup cannot complete and the installation will be rolled back.',
    mbCriticalError, MB_OK, IDOK);
end;
