; CAP-6b2 OFFLINE-profile per-user installer for the CAP-6 release
; triple (releaseapp.exe + app.pwb + webview.dll), embedding the
; lock-verified x64 Evergreen STANDALONE Installer so a WebView2-less
; machine WITHOUT network gets a usable runtime from the embedded
; payload alone.
;
; Built ONLY through test/cap6b2/build_offline_setup.ps1, which derives
; every /D define from the ratified locks at BUILD time:
;   PWEB_WV2_STANDALONE standalone-installer filename from
;                       webview2-runtime.lock (evergreen-standalone-x64)
;   (plus the shared defines documented in pwebprovgate.issi)
;
; Offline hard invariant: this manifest embeds NO Bootstrapper, no
; Fixed Runtime tree and no loose frontend files, and contains no
; network path of any kind - the only provisioning difference vs the
; normal profile is WHICH ratified artifact is embedded. Provisioning
; failure aborts the setup fail-closed; there is no "try the
; Bootstrapper instead" and no online fallback, ever.
;
; The whole setup body - define validation, [Setup] identity (same
; AppId, same app as normal.iss), embedded payload model and the
; fail-closed provisioning [Code] gate - lives in the shared include
; tools/setup/pwebprovgate.issi, consumed by BOTH profiles so the two
; can never fork. This file only maps the profile's installer define
; onto the include's neutral PWEB_WV2_INSTALLER.

#ifndef PWEB_WV2_STANDALONE
  #error PWEB_WV2_STANDALONE must be defined - build via test/cap6b2/build_offline_setup.ps1
#endif
#define PWEB_WV2_INSTALLER PWEB_WV2_STANDALONE
#define PWEB_PROFILE "offline"
; CAP-6b4: the profile's own setup basename. Never "setup" - every
; executable named setup.exe is shimmed by Windows application
; compatibility into loading extra DLLs from its own directory. The
; build script reads this literal instead of passing /F, so the .iss
; stays the single source of the artifact name.
#define PWEB_SETUP_BASENAME "PWebRelease-Offline-Setup"

#include "pwebprovgate.issi"
