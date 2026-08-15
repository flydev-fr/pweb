# Runtime and build profiles

Companion to `SPEC.md`. Invariant 2: **Evergreen first.** Covers CAP-13
(Windows) and CAP-7L (Linux x64).

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

## Linux x64: the distro provides the engine

There is no Linux equivalent of the three Windows profiles, and deliberately so. Windows needs them because WebView2 may simply be absent from the machine; on Linux the engine is a **distribution package**, and installing it is the user's or the packager's job, never the application's.

```
PWeb Linux default
       =
distro WebKitGTK
```

**Ratified baseline**, pinned in `webview.lock` and asserted at build time:

```
GTK 3 (gtk+-3.0) + WebKitGTK API 4.1 (webkit2gtk-4.1, libsoup3)
x86_64, glibc
```

Never autodetected: every configure passes `-DWEBVIEW_WEBKITGTK_API`, and the build re-reads `CMakeCache.txt` to prove which module `pkg-config` actually resolved. A machine that happens to carry `webkitgtk-6.0` fails the build rather than silently producing a different product.

### Build-time packages

Debian/Ubuntu names; installed explicitly by `tools/build-webview-so.sh`'s prerequisites and by CI:

```
cmake pkg-config ninja-build build-essential
libgtk-3-dev libwebkit2gtk-4.1-dev
```

### Runtime packages — the user's responsibility

A shipped PWeb application dynamically links, and therefore **requires on the target machine**:

```
libwebkit2gtk-4.1.so.0      (Debian/Ubuntu: libwebkit2gtk-4.1-0)
libgtk-3.so.0               (libgtk-3-0)
libgio-2.0.so.0
libgobject-2.0.so.0         (libglib2.0-0)
libglib-2.0.so.0
```

The application **never installs any of them**. If one is missing, the dynamic loader fails before `main()` with a message naming the exact soname and exit code **127** — the same fail-closed, never-a-silent-start model as a missing `webview.dll` on Windows.

Stating the dependency is the whole obligation here. PWeb produces artifacts and stops: there is no Linux CAP-13, no runtime download, and no provisioning path.

### Release layout

Mirrors `dist/windows/…`, and is asserted to contain exactly these four entries:

```
dist/linux-x64/release/
  releaseapp            # RUNPATH=$ORIGIN, no CWD dependence
  app.pwb               # resolved from Executable.ProgramFilePath
  libwebview.so.0.12    # the DT_NEEDED name (MEASURED: the SONAME, not
                        # the chet LibraryName)
  LICENSE.webview
```

No `frontend/dist`, no `node_modules`, no compiler artifacts, and no WebKit files — the engine is the system's, not ours. The application runs from an unrelated working directory with no `LD_LIBRARY_PATH` set.

The measured record behind all of this is `docs/webkitgtk-linux-semantics.md`.

## Out of scope

Code signing, macOS notarization, and auto-update are not PWeb's concern. `pweb build` produces artifacts and stops.

`.deb`, `.rpm`, AppImage and Flatpak are explicitly **not** PWeb's concern either: CAP-7L ships a directory layout, not a distribution package. Vendoring or bundling WebKitGTK is likewise out of scope — it would recreate exactly the 250 MB problem the Fixed Runtime section above declines on Windows.
