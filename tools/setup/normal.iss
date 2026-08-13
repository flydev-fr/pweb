; CAP-6b1 normal-profile per-user installer for the CAP-6 release
; triple (releaseapp.exe + app.pwb + webview.dll), with lock-verified
; Evergreen Bootstrapper provisioning of the WebView2 runtime.
;
; Built ONLY through test/cap6b1/build_normal_setup.ps1, which derives
; every /D define below from the ratified locks at BUILD time:
;   PWEB_PAYLOAD_DIR      staged payload directory (release triple +
;                         lock-verified bootstrapper + compiled helper)
;   PWEB_WV2_BOOTSTRAPPER bootstrapper filename from webview2-runtime.lock
;   PWEB_WV2_SHA256       ratified lock digest (64 lowercase hex)
;   PWEB_WV2_SUBJECT      ratified Authenticode leaf subject
;   PWEB_WV2_TIMEOUT_MS   bounded helper wait, parsed by the build
;                         script from PWEB_WV2_INSTALL_TIMEOUT_MS in
;                         pweb.platform.webview2.provision.pas - the
;                         Pascal constant is the single source, never
;                         a literal duplicated here
;   PWEB_PROV_HELPER      TEST HOOK (optional; default pwebwv2prov.exe):
;                         filename of the provisioning helper inside
;                         PWEB_PAYLOAD_DIR. Production builds leave it
;                         at the default; the abort-probe TEST build
;                         (build_normal_setup.ps1) overrides it with an
;                         always-fail stub to prove, by automation,
;                         that a helper failure aborts the setup with
;                         nothing installed. Nothing else may ever
;                         override it.
;
; Provisioning runs in PrepareToInstall through the COMPILED Pascal
; helper pwebwv2prov.exe (reusing the frozen CAP-6b0 policy functions;
; never re-implemented in PascalScript): detect -> verify (SHA-256 +
; Authenticode) -> bounded silent execute -> mandatory re-probe. A
; nonzero helper exit aborts the setup BEFORE any file is installed,
; so no launchable app can remain on a machine whose runtime could not
; be proven usable. The runtime may end up per-machine through the
; documented Microsoft auto-promotion - that is NOT a failure; the
; acceptance is a per-user app install plus a usable post-provision
; detector verdict.
;
; There is deliberately NO Launch entry and no [Run] section: setup
; either completes with a proven-usable runtime or aborts fail-closed.

#ifndef PWEB_PAYLOAD_DIR
  #error PWEB_PAYLOAD_DIR must be defined - build via test/cap6b1/build_normal_setup.ps1
#endif
#ifndef PWEB_WV2_BOOTSTRAPPER
  #error PWEB_WV2_BOOTSTRAPPER must be defined - build via test/cap6b1/build_normal_setup.ps1
#endif
#ifndef PWEB_WV2_SHA256
  #error PWEB_WV2_SHA256 must be defined - build via test/cap6b1/build_normal_setup.ps1
#endif
#ifndef PWEB_WV2_SUBJECT
  #error PWEB_WV2_SUBJECT must be defined - build via test/cap6b1/build_normal_setup.ps1
#endif
#ifndef PWEB_WV2_TIMEOUT_MS
  #error PWEB_WV2_TIMEOUT_MS must be defined - build via test/cap6b1/build_normal_setup.ps1
#endif
#ifndef PWEB_PROV_HELPER
  #define PWEB_PROV_HELPER "pwebwv2prov.exe"
#endif
#ifndef PWEB_APP_VERSION
  #define PWEB_APP_VERSION "0.1.0"
#endif

[Setup]
AppId={{7C3E9A1B-5D24-4F68-A0C9-2B8E6D4F1A57}
AppName=PWeb Release
AppVersion={#PWEB_APP_VERSION}
AppPublisher=PWeb
DefaultDirName={localappdata}\Programs\PWebRelease
; per-user by construction: never any elevation, never any attempt to
; force where Microsoft places the runtime
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
Compression=lzma2
SolidCompression=yes
OutputBaseFilename=setup
Uninstallable=yes

[Files]
; the unchanged CAP-6 release triple - no loose frontend files, ever
Source: "{#PWEB_PAYLOAD_DIR}\releaseapp.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PWEB_PAYLOAD_DIR}\app.pwb"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PWEB_PAYLOAD_DIR}\webview.dll"; DestDir: "{app}"; Flags: ignoreversion
; provisioning payload: extracted to {tmp} on demand, auto-deleted by
; Inno when setup exits (success OR abort) - never installed to {app}
Source: "{#PWEB_PAYLOAD_DIR}\{#PWEB_WV2_BOOTSTRAPPER}"; Flags: dontcopy
Source: "{#PWEB_PAYLOAD_DIR}\{#PWEB_PROV_HELPER}"; Flags: dontcopy

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Helper, Installer, ProvLog, Params: String;
  Output: AnsiString;
  Rc: Integer;
begin
  Result := '';
  ExtractTemporaryFile('{#PWEB_PROV_HELPER}');
  ExtractTemporaryFile('{#PWEB_WV2_BOOTSTRAPPER}');
  Helper := ExpandConstant('{tmp}\{#PWEB_PROV_HELPER}');
  Installer := ExpandConstant('{tmp}\{#PWEB_WV2_BOOTSTRAPPER}');
  ProvLog := ExpandConstant('{tmp}\pwebwv2prov.log');
  Params := '"' + Installer + '" {#PWEB_WV2_SHA256} "{#PWEB_WV2_SUBJECT}" ' +
    '{#PWEB_WV2_TIMEOUT_MS} "' + ProvLog + '"';
  Log('PWEB_WV2PROV launching: ' + Helper + ' ' + Params);
  if not Exec(Helper, Params, ExpandConstant('{tmp}'), SW_HIDE,
       ewWaitUntilTerminated, Rc) then
  begin
    Log('PWEB_WV2PROV exec-failed');
    Result := 'The WebView2 provisioning helper could not be started. ' +
      'Setup cannot continue and nothing was installed.';
    exit;
  end;
  if LoadStringFromFile(ProvLog, Output) then
    Log('PWEB_WV2PROV output:' + #13#10 + Output)
  else
    Log('PWEB_WV2PROV output file missing');
  Log('PWEB_WV2PROV exit=' + IntToStr(Rc));
  if Rc <> 0 then
    // fail closed: the helper's re-probe verdict is authoritative and
    // aborting here leaves NO installed launchable app behind
    Result := 'WebView2 runtime provisioning failed (helper exit ' +
      IntToStr(Rc) + '). Setup cannot continue and nothing was installed.';
end;
