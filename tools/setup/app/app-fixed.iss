; CAP-10D1 FIXED-RUNTIME-profile per-user installer for a GENERATED PWeb
; application - the CAP-10C1 release triple (<ident>.exe + app.pwb +
; webview.dll) deploying the lock-verified x64 WebView2 Fixed Version
; Runtime tree plus the pinned WebView2 SDK's WebView2Loader.dll as
; ordinary application content under {app}\runtime\webview2.
;
; Built ONLY through `pweb build --profile fixed-runtime`, which derives
; every /D define from pweb.json and from the compiled pins in
; tools/pweb/pweb.cli.packpins.pas at BUILD time:
;   PWEB_RUNTIME_DIR   the staged runtime folder - the cabinet expanded
;                      from bytes whose sha256 the driver verified against
;                      the pin before `expand` was ever spawned, plus the
;                      pinned-SDK loader, also verified by digest
;   PWEB_FIXED_TREE    the extracted tree's folder name, from the pinned
;                      version
;   PWEB_FIXED_SUBJECT the ratified Authenticode leaf subject; the gate
;                      below refuses to complete unless the five critical
;                      binaries that LANDED carry a Valid signature with
;                      exactly this subject
;   PWEB_ACL_HELPER    the compiled native post-install helper (default
;                      pwebwv2fixed.exe), extracted to {tmp} on demand and
;                      NEVER installed. TEST HOOK, mirroring the ratified
;                      CAP-6b3 convention
;   (plus the shared identity defines documented in app/pwebappid.issi)
;
; This file is the CAP-13 twin of tools/setup/fixed.iss, and everything
; below the [Code] marker is BYTE-IDENTICAL to that file's [Code] region -
; an equality test/cap10d1/check_cap10d1_contracts.ps1 requires on every
; CI leg, so the verdict-file abort mechanism CAP-6b3 measured against the
; pinned ISCC 6.7.3 cannot fork between the repository's installer and a
; generated application's.
;
; Fixed-profile hard invariants, inherited unchanged:
;   - this manifest embeds NO Evergreen Bootstrapper, NO Evergreen
;     Standalone Installer and NO loose frontend files; it runs NO
;     provisioning of any kind and contains no network path whatever. The
;     bundled tree is the runtime, full stop.
;   - there is no [Run] launch entry and no [Icons] entry: setup either
;     completes with a verified runtime tree or fails.
;   - the ONE piece of logic is the post-install gate, run through the
;     compiled helper: the five critical binaries that ACTUALLY LANDED are
;     Authenticode-verified against the ratified leaf subject, the Windows
;     10 AppContainer grant a Fixed Version Runtime >= 120 requires is
;     applied, and that grant is re-read from the object and verified BY
;     SID.
;
; WHY THE GATE IS A VERDICT FILE rather than a raised exception: because
; CAP-6b3 MEASURED the pinned ISCC lifecycle and found that an exception
; raised from AfterInstall or ssPostInstall is SWALLOWED and can never
; fail setup, while a missing `external` source during the installing
; phase is a genuine Setup error that triggers Inno's own rollback. That
; measurement is recorded in tools/setup/fixed.iss and is not re-derived
; here; the mechanism is inherited with the [Code] body it belongs to.
;
; WHAT THIS PROFILE DOES NOT RE-DO. CAP-6b3's BUILD script additionally
; Authenticode-verifies the freshly expanded tree, because it expands a
; cabinet it has just re-fetched. `pweb build` expands a cabinet whose
; sha256 it has already verified byte-exactly against the pin, and the
; expansion of a fixed archive is deterministic - so the build-time signer
; axis would be re-deriving what the digest already settled. The axis that
; protects a USER is the one over the DEPLOYED bytes, and that is the gate
; below, unchanged.

#ifndef PWEB_RUNTIME_DIR
  #error PWEB_RUNTIME_DIR must be defined - build via `pweb build --profile fixed-runtime`
#endif
#ifndef PWEB_FIXED_TREE
  #error PWEB_FIXED_TREE must be defined - build via `pweb build --profile fixed-runtime`
#endif
#ifndef PWEB_FIXED_SUBJECT
  #error PWEB_FIXED_SUBJECT must be defined - build via `pweb build --profile fixed-runtime`
#endif
#ifndef PWEB_ACL_HELPER
  #define PWEB_ACL_HELPER "pwebwv2fixed.exe"
#endif
; the gate's verdict, written to {tmp} by FixedRuntimeGate ONLY when the
; helper exits 0, and consumed as the external source of the [Files] entry
; that follows the whole runtime tree. deleteafterinstall keeps it out of
; the installed layout.
#define PWEB_VERDICT_FILE "pweb-fixed-runtime.verdict"
#define PWEB_PROFILE "fixed-runtime"

#include "pwebappid.issi"

[Files]
; the bundled runtime, deployed as ordinary application content: the
; extracted Fixed Version Runtime tree plus the pinned-SDK loader. The
; loader sits INSIDE this folder on purpose, so the application can only
; ever load it by explicit absolute path, never by DLL search order. The
; subdirectory name comes from the single PWEB_RUNTIME_SUBDIR source in
; app/pwebappid.issi - the same one the Evergreen profiles'
; [InstallDelete] reclaim targets, so the tree this profile installs and
; the tree they remove can never be two different directories.
Source: "{#PWEB_RUNTIME_DIR}\*"; DestDir: "{app}\{#PWEB_RUNTIME_SUBDIR}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs
; the ACL helper is extracted to {tmp} on demand and auto-deleted by Inno
; when setup exits (success OR abort) - never installed to {app}
Source: "{#PWEB_PAYLOAD_DIR}\{#PWEB_ACL_HELPER}"; Flags: dontcopy
; THE GATE. It must stay after every RUNTIME TREE entry - its
; BeforeInstall therefore runs once the whole tree has landed, so the
; helper verifies the DEPLOYED bytes, which is the only thing it verifies.
; The source is `external` and lives in {tmp}; the gate creates it only
; when the helper exits 0. If it is missing, Setup cannot find this
; entry's source and rolls the whole installation back - which IS the
; abort. There is deliberately NO skipifsourcedoesntexist here: that flag
; would turn the failure signal into a silent skip.
Source: "{tmp}\{#PWEB_VERDICT_FILE}"; DestDir: "{app}"; \
    Flags: external ignoreversion deleteafterinstall; \
    BeforeInstall: FixedRuntimeGate

; the shared release triple comes LAST, AFTER the verdict gate above -
; the CAP-6b4 order, and for the reason CAP-6b4 measured: with the triple
; before the gate, a failed Evergreen -> fixed switch leaves a fixed-mode
; executable behind with no runtime tree and a marker still reading the
; source profile. With it after, the abort happens before these three
; entries are reached and the source install comes out byte-identical to
; pre-switch.
#include "pwebapptriple.issi"

[Code]
// The post-install gate. Runs as the BeforeInstall of the [Files]
// entry that follows the whole runtime tree, so the tree has already
// landed and the helper verifies the DEPLOYED bytes:
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
  // the same single PWEB_RUNTIME_SUBDIR source the [Files] entry above
  // deploys into: the gate can never verify a different directory than
  // the one that was installed
  RuntimeRoot := ExpandConstant('{app}\{#PWEB_RUNTIME_SUBDIR}');
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
