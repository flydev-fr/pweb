; CAP-6b1 normal-profile per-user installer for the CAP-6 release
; triple (releaseapp.exe + app.pwb + webview.dll), with lock-verified
; Evergreen Bootstrapper provisioning of the WebView2 runtime.
;
; Built ONLY through test/cap6b1/build_normal_setup.ps1, which derives
; every /D define from the ratified locks at BUILD time:
;   PWEB_WV2_BOOTSTRAPPER bootstrapper filename from webview2-runtime.lock
;   (plus the shared defines documented in pwebprovgate.issi)
;
; The whole setup body - define validation, [Setup] identity, embedded
; payload model and the fail-closed provisioning [Code] gate - lives in
; the shared include tools/setup/pwebprovgate.issi, consumed by BOTH
; this normal profile and the CAP-6b2 offline profile (offline.iss) so
; the two can never fork. This file only maps the profile's installer
; define onto the include's neutral PWEB_WV2_INSTALLER.

#ifndef PWEB_WV2_BOOTSTRAPPER
  #error PWEB_WV2_BOOTSTRAPPER must be defined - build via test/cap6b1/build_normal_setup.ps1
#endif
#define PWEB_WV2_INSTALLER PWEB_WV2_BOOTSTRAPPER
#define PWEB_PROFILE "normal"
; CAP-6b4: the profile's own setup basename. Never "setup" - every
; executable named setup.exe is shimmed by Windows application
; compatibility into loading extra DLLs from its own directory. The
; build script reads this literal instead of passing /F, so the .iss
; stays the single source of the artifact name.
#define PWEB_SETUP_BASENAME "PWebRelease-Normal-Setup"

#include "pwebprovgate.issi"
