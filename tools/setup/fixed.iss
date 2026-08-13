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
;     MEASURED (Inno 6.7.3): an exception at ssPostInstall is NOT a
;     rollback and does NOT make setup.exe exit nonzero - by then every
;     file is copied, the uninstall key is written and the log already
;     says "Installation process succeeded". So this profile undoes the
;     installation ITSELF (see AbortFixedInstall below): it removes
;     {app} and the per-user uninstall key before raising. The CAP-6b3
;     abort-probe gate leg asserts that resulting STATE - failure
;     verdict in the log, no {app}, no HKCU uninstall key - rather than
;     an exit code Inno never produces.
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

[Code]
// The per-user uninstall key Inno writes for this AppId. The GUID is
// NOT duplicated here: SetupSetting is an ISPP PREPROCESSOR function
// (there is no scripting function of that name), so the AppId the
// shared pwebappsetup.issi authored is substituted into this literal at
// COMPILE time. A drift in the include therefore changes this key
// automatically, and the CAP-6b1 contract gate still parses the one
// authored directive.
function PWebUninstallKey: String;
var
  Id: String;
begin
  Id := '{#SetupSetting("AppId")}';
  // the [Setup] directive escapes one literal '{' as '{{' - undo that
  if (Length(Id) >= 2) and (Id[1] = '{') and (Id[2] = '{') then
    Delete(Id, 1, 1);
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    Id + '_is1';
end;

// Fail closed, EXPLICITLY. Measured Inno 6.7.3 behaviour: an exception
// raised in CurStepChanged(ssPostInstall) is NOT a rollback. By then
// Inno has logged "Installation process succeeded", copied every
// [Files] entry and written the uninstall registry key; it reports the
// exception as an (under /SUPPRESSMSGBOXES, suppressed) error box and
// then deinitializes normally, leaving the process exit code at 0.
// So this profile undoes the installation itself: the installed tree
// AND the uninstall entry both go, or a failed verification would leave
// a launchable app - or, worse, an entry in Programs & Features
// pointing at a directory that no longer exists.
procedure AbortFixedInstall(const Reason: String);
begin
  Log('PWEB_WV2FIXED aborting and removing {app}: ' + Reason);
  DelTree(ExpandConstant('{app}'), True, True, True);
  if RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, PWebUninstallKey) then
    Log('PWEB_WV2FIXED removed the uninstall key: ' + PWebUninstallKey)
  else
    Log('PWEB_WV2FIXED uninstall key not present: ' + PWebUninstallKey);
  RaiseException(Reason);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Helper, RuntimeRoot, GateLog, Params: String;
  Output: AnsiString;
  Rc: Integer;
begin
  if CurStep <> ssPostInstall then
    exit;
  ExtractTemporaryFile('{#PWEB_ACL_HELPER}');
  Helper := ExpandConstant('{tmp}\{#PWEB_ACL_HELPER}');
  RuntimeRoot := ExpandConstant('{app}\runtime\webview2');
  GateLog := ExpandConstant('{tmp}\pwebwv2fixed.log');
  // one Exec, three checks: signatures of the five critical binaries
  // that landed, then apply the AppContainer grant, then re-read and
  // verify it BY SID
  Params := '--postinstall "' + RuntimeRoot + '" "{#PWEB_FIXED_SUBJECT}" "' +
    GateLog + '"';
  Log('PWEB_WV2FIXED launching: ' + Helper + ' ' + Params);
  if not Exec(Helper, Params, ExpandConstant('{tmp}'), SW_HIDE,
       ewWaitUntilTerminated, Rc) then
  begin
    Log('PWEB_WV2FIXED exec-failed');
    AbortFixedInstall('The WebView2 fixed-runtime post-install helper could ' +
      'not be started. Setup cannot complete and nothing was left installed.');
    exit;
  end;
  if LoadStringFromFile(GateLog, Output) then
    Log('PWEB_WV2FIXED output:' + #13#10 + Output)
  else
    Log('PWEB_WV2FIXED output file missing');
  Log('PWEB_WV2FIXED exit=' + IntToStr(Rc));
  if Rc <> 0 then
    // the helper's signer + verify-by-SID verdicts are authoritative
    AbortFixedInstall('WebView2 fixed-runtime post-install verification ' +
      'failed (helper exit ' + IntToStr(Rc) + '). Setup cannot complete and ' +
      'nothing was left installed.');
end;
