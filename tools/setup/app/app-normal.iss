; CAP-10D1 NORMAL-profile per-user installer for a GENERATED PWeb
; application - the CAP-10C1 release triple (<ident>.exe + app.pwb +
; webview.dll) with lock-verified Evergreen Bootstrapper provisioning of
; the WebView2 runtime.
;
; Built ONLY through `pweb build --profile normal`, which derives every
; /D define from pweb.json and from the compiled pins in
; tools/pweb/pweb.cli.packpins.pas at BUILD time:
;   PWEB_WV2_BOOTSTRAPPER  the pinned bootstrapper filename
;   (plus the shared defines documented in app/pwebappprov.issi and
;    app/pwebappid.issi)
;
; This file is the CAP-13 twin of tools/setup/normal.iss and maps the same
; profile define onto the same neutral PWEB_WV2_INSTALLER. The whole setup
; body - define validation, [Setup] identity, embedded payload model and
; the fail-closed provisioning [Code] gate - lives in the shared includes,
; consumed by this profile and by app-offline.iss so the two can never
; fork.
;
; THE SETUP BASENAME IS NOT AUTHORED HERE. CAP-6b4 authored it in the
; manifest and parsed it out, because one manifest owned one artifact
; name; a generated application's artifact name is its own, so it arrives
; as /DPWEB_SETUP_BASENAME and app/pwebappid.issi VALIDATES it - including
; the ban on "setup" in any casing, which is the property that mattered.

#ifndef PWEB_WV2_BOOTSTRAPPER
  #error PWEB_WV2_BOOTSTRAPPER must be defined - build via `pweb build --profile normal`
#endif
#define PWEB_WV2_INSTALLER PWEB_WV2_BOOTSTRAPPER
#define PWEB_PROFILE "normal"

#include "pwebappprov.issi"
