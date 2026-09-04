; CAP-10D1 OFFLINE-profile per-user installer for a GENERATED PWeb
; application - the CAP-10C1 release triple (<ident>.exe + app.pwb +
; webview.dll) embedding the lock-verified x64 Evergreen STANDALONE
; Installer, so a WebView2-less machine WITHOUT network gets a usable
; runtime from the embedded payload alone.
;
; Built ONLY through `pweb build --profile offline`, which derives every
; /D define from pweb.json and from the compiled pins in
; tools/pweb/pweb.cli.packpins.pas at BUILD time:
;   PWEB_WV2_STANDALONE  the pinned standalone-installer filename
;   (plus the shared defines documented in app/pwebappprov.issi and
;    app/pwebappid.issi)
;
; OFFLINE HARD INVARIANT, inherited from tools/setup/offline.iss: this
; manifest embeds NO Bootstrapper, no Fixed Runtime tree and no loose
; frontend files, and contains no network path of any kind. The only
; provisioning difference from the normal profile is WHICH ratified
; artifact is embedded. Provisioning failure aborts the setup fail-closed;
; there is no "try the Bootstrapper instead" and no online fallback, ever.
;
; The whole setup body - define validation, [Setup] identity (same AppId,
; same application as app-normal.iss), embedded payload model and the
; fail-closed provisioning [Code] gate - lives in the shared includes,
; consumed by BOTH profiles so the two can never fork.

#ifndef PWEB_WV2_STANDALONE
  #error PWEB_WV2_STANDALONE must be defined - build via `pweb build --profile offline`
#endif
#define PWEB_WV2_INSTALLER PWEB_WV2_STANDALONE
#define PWEB_PROFILE "offline"

#include "pwebappprov.issi"
