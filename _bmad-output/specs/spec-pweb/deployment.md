# Windows runtime and build profiles

Companion to `SPEC.md`. Invariant 2: **Evergreen first.** Covers CAP-13.

## Default: WebView2 Evergreen

```
PWeb Windows default
       =
WebView2 Evergreen
```

Microsoft recommends Evergreen for most applications: the runtime is shared between apps, updates itself, and costs less disk. Windows 11 includes it, and Microsoft reports it present on the large majority of eligible Windows 10 machines.

## Three `pweb build` profiles

```
pweb build
    │
    ├── normal
    │      Evergreen
    │      installer checks presence
    │      bootstrapper if absent
    │
    ├── offline
    │      Evergreen Standalone Installer
    │
    └── fixed-runtime
           opt-in only
```

The Evergreen bootstrapper is currently around **2 MB** and downloads the right architecture itself. Microsoft's guidance is to check and install the runtime at setup time rather than letting the app fail at launch — so:

```
setup.exe
   ↓
WebView2 present?
   │
 ┌─┴─┐
yes  no
 │    │
 │    ▼
 │ bootstrapper
 │
 ▼
install MyApp
```

A fully offline package embeds the **Standalone Evergreen Installer**, not the Fixed Runtime.

## Fixed Runtime: opt-in, narrow

Reserved for:

```
frozen industrial environment
certification
kiosk application
regulated compatibility
fully controlled machines
```

Microsoft currently puts the Fixed Runtime at **250 MB+** added to distributed binaries, and it makes us responsible for keeping it updated. `PWeb + Fixed WebView2` would turn a "no 250 MB Electron" project into "here is our own 250 MB". The irony would be flawless; avoid it anyway.

## Out of scope

Code signing, macOS notarization, and auto-update are not PWeb's concern. `pweb build` produces artifacts and stops.
