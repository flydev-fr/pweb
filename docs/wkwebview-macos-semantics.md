# Cocoa/WKWebView semantics for the pinned webview commit

Pinned commit: `cbbdee44afff22867de9fd88a9fc8350d9bdd399` (see `webview.lock`).
Companion to `webview-upstream-semantics.md` (Windows/WebView2) and
`webkitgtk-linux-semantics.md` (Linux/WebKitGTK), recording the same kind of
facts for the third backend.

```
Cocoa + WKWebView, macOS 12.0 deployment target (PROPOSED)
x86_64-darwin and aarch64-darwin, FPC 3.2.2, Xcode pinned by fpc.lock
```

## Read the provenance markers before you rely on a line here

This document was opened by **CAP-7M0**, a feasibility shard whose entire
output is a measurement. Its two siblings were written *after* their platform
ran; this one is written *around the gates that will make it run*, so every
statement carries where it comes from:

| Marker | Means |
|---|---|
| **DERIVED** | Read out of the pinned sources in this repository. True now, checkable now, no macOS needed. |
| **MEASURED** | Observed by a gate that has already been executed. |
| **EXPECTED** | Predicted from Apple's documentation or upstream's code, with the gate that will settle it named. **Not yet a fact.** |

Nothing below is marked MEASURED on the strength of a hosted run that has not
happened. As each `macos-x64` / `macos-arm64` run gets further, EXPECTED lines
are either promoted to MEASURED with their observed values or become the
finding that blocks CAP-7M.

**Run `31904189177` got as far as building the dylib on both architectures.**
It promoted constraints 7 and 8 to MEASURED — an aarch64 linker failure at the
proposed floor, and an export surface that genuinely differs between
architectures — and neither was predicted here. Runs `31905105454`,
`31908958453` and `31909456486` then added constraints 9, 10 and 11 as each
got a little further.

**Run `31909938201` ran the probe against a real WKWebView on both arches**,
and promoted most of what was left: seam B works while seam A is measurably
and *silently* ineffective, the frozen threading contract holds, `pweb://app`
**is** a secure context, WebKit copies the response body at handoff, a
post-stop callback really does raise, and every hostile URI vector was
refused. It also produced constraint 12 — the one assertion that failed.

What is still EXPECTED is now narrow: the mechanism behind constraint 11, and
whatever CAP-7M measures beyond this shard's matrix.

**CAP-7M1 built the production adapter on top of these measurements** and
added three constraints of its own — 13, 14 and 15 — which are the surprises
a reader porting from either sibling platform will hit first. Everything
CAP-7M0 measured is carried forward unchanged; nothing below reopens it.

## The seam: the whole architectural question, and not the Linux one

**DERIVED.** Upstream builds the configuration *and* the web view inside
`webview_create`:

```
webview_create
  cocoa_wkwebview_engine::window_settings          cocoa_webkit.hh:447
    WKWebViewConfiguration_new()                   cocoa_webkit.hh:450
    ...
    WKWebView_withFrame(CGRectMake(0,0,0,0), config)   cocoa_webkit.hh:486
```

There is no moment between those two statements that a caller can reach. That
is the difference from Linux, where `webview_create` builds a `WebKitWebView`
and navigates nowhere, so the whole `BROWSER_CONTROLLER` →
`WebKitWebContext` → `register_uri_scheme` sequence fits comfortably *after*
create.

Three candidate seams, and only one of them is proposed:

### A — post-create, through the existing native handle. REFUSED.

```
webview_get_native_handle(w, BROWSER_CONTROLLER)  -> WKWebView*   (DERIVED,
    cocoa_webkit.hh:163-168 returns m_webview)
  [webView configuration]                          -> a COPY
    setURLSchemeHandler:forURLScheme:              -> affects nothing
```

Apple documents `WKWebView.configuration` as returning a copy, and states that
mutating it "doesn't affect the web view's configuration". **EXPECTED**: the
handler installs without complaint and is then never consulted. Gate: M9, in
`test/cap7m/cap7m_probe.mm`, which installs a handler for its own `pwebpost`
scheme on the post-create copy and compares the object identity against the
configuration `webview_create` actually used.

**The verdict is read from the HANDLER, never from the page.** The page's
`fetch('pwebpost://app/probe')` fails identically in both worlds — no handler
registered on the live configuration, and handler registered but refusing —
so a page-side boolean would be constant `false` and would look like a
measurement while measuring nothing. The deciding number is
`postcreate_hits`, the handler's own arrival counter, emitted as
`CAP7M_M9 … seam_a_effective=yes|no`.

An ineffective result **refuses seam A**; it is not a failure of the shard,
and the gate records the answer rather than requiring one.

**MEASURED, run `31909938201`, and it is stronger than Apple's documentation
sentence — because it shows seam A failing SILENTLY:**

```
CAP7M_M9 postcreate_install_accepted=1 configuration_is_same_object=1 \
         postcreate_hits=0 seam_a_effective=no
```

Read that together: the registration was **accepted** — no exception, no
error, nothing to catch — the configuration object compared **equal** to the
one `webview_create` used, and the handler was **still never consulted**. An
adapter written against seam A would look correct, log nothing, and simply
never serve. That is the most dangerous shape a wrong seam can take, and it
is why seam B is not merely preferred but required: `precreate_seam_ran=1` is
what actually works.

One honest caveat on the middle term. `configuration_is_same_object=1` is
pointer equality against the configuration the seam saw at `+new`. Upstream
autoreleases that object (`cocoa_webkit.hh:450`), so by the time
`WKWebView.configuration` is read the original may have been deallocated and
a fresh copy allocated **at the same address**. Pointer equality cannot tell
those apart. So the load-bearing facts are `postcreate_install_accepted=1`
with `postcreate_hits=0`; treat the identity as suggestive, not settled.

### B — a PWeb-owned pre-create seam. PROPOSED.

The smallest thing that does not touch the ABI is to own the constructor
upstream calls:

```
class_addMethod(object_getClass([WKWebViewConfiguration class]),
                @selector(new), pweb_configuration_new, "@@:")

pweb_configuration_new(cls, _cmd):
    config = [[cls alloc] init]              // exactly what +new does
    [config setURLSchemeHandler:handler forURLScheme:@"pweb"]
    return config                            // +1, as +new must return
```

Public Objective-C runtime, public `setURLSchemeHandler:forURLScheme:`,
`deps/webview` unpatched, export surface still exactly 17.

**One trap, DERIVED and worth stating because getting it wrong is silent:**
`class_getClassMethod(WKWebViewConfiguration, @selector(new))` returns
*NSObject's* inherited `+new`, and `method_setImplementation` on that would
swizzle `+new` for **every class in the process**. `class_addMethod` on this
class's own metaclass affects this class alone. The probe uses the second and
only falls back to replacing an implementation if the class already declares
its own `+new`.

**MEASURED**, run `31909938201`: `webview_create` goes through this override once per
create, and `pweb://app/index.html` is then really requested by WebKit. Gate:
M10 (`CAP7M_M10 precreate_seam_ran=1` plus a served main document).

### C — a minimal upstream patch. NOT WRITTEN.

Escalation only, and only with evidence that B failed. No patch exists in this
tree and none may be written before ratification.

## Fifteen constraints that are not obvious

### 1. `WKURLSchemeTask` throws. Nothing in the GLib model carries over

**DERIVED from Apple's documentation.** An `NSException` is raised for:

- a second response after completion,
- data before a response,
- finish before a response,
- finish *or* fail after either,
- **any** callback after `stopURLSchemeTask:`.

WebKitGTK has no analogue: there, a stale call is merely ignored. So a macOS
adapter needs a **terminal-state guard** that WebKitGTK never needed, and an
`NSException` escaping into a C++ — later a Pascal — frame is undefined
behaviour, not an error path.

The shape the probe uses, and the shape CAP-7M should mirror: a task is
tracked from `startURLSchemeTask:` and **claimed** exactly once. Whoever
claims it owns the right to send a terminal callback; everyone else silently
does nothing. `stopURLSchemeTask:` claims it too, which is what makes
"no callback after stop" structural rather than a rule to remember.

**MEASURED**, run `31909938201` (`poststop_throws=1`): a post-stop callback really does raise. M13 records
`poststop_throws=0|1` from one deliberate, contained attempt on a task WebKit
has just stopped. If it turns out **not** to throw, the guard is still
correct — but the reason to keep it changes, and that is worth knowing.

Two details the cancellation case depends on, and both are easy to get wrong:

- **`fetch()` resolves at `didReceiveResponse`, not at the end of the body.**
  Aborting a promise that has already settled does nothing at all, so the page
  awaits `r.arrayBuffer()`; only then does the abort land *during* data
  delivery, which is the path `stopURLSchemeTask:` actually exercises.
- **`dispatch_after` is neither drained nor cancellable at teardown.** The
  deferred half of the slow response first runs on the *next* cycle's run
  loop, so it captures its owning cycle by value and does nothing at all if
  the owner has moved on. Without that, an exception raised by cycle N is
  charged to cycle N+1 — and the tracked-task set, keyed by task address, is
  reset between cycles because the allocator reuses addresses freely.

### 2. Whether WebKit copies the response body at handoff

**EXPECTED, and it decides an ownership rule the Pascal adapter cannot guess.**
On Linux the answer is explicit: `g_memory_input_stream_new_from_data(copy,
size, g_free)` transfers ownership, so nothing the page receives points at the
adapter's frame. `-[WKURLSchemeTask didReceiveData:]` takes an `NSData` and
documents no such contract.

Gate: M14 hands the body over with `dataWithBytesNoCopy:` and **poisons the
source buffer in place** the instant `didReceiveData:` returns. If the page
still reads the original text, WebKit copied at handoff; if it reads the
poison, WebKit kept the pointer and a Pascal adapter must keep its source
alive until `didFinish`. The probe deliberately never frees that buffer:
measuring ownership must not itself become a use-after-free.

**MEASURED, run `31909938201`: `handoff=original-bytes`,
`ownership=webkit-copies-at-handoff`.** The page read the original text after
the source buffer was poisoned, so on this OS and toolchain WebKit copies the
bytes at `didReceiveData:` and a Pascal adapter need **not** keep its source
alive until `didFinish`.

That is a licence to simplify, not a licence to stop checking: it is one
measurement on one OS/toolchain pair of an API that documents no such
contract. CAP-7M should keep the poisoned-buffer case as a regression rather
than rely on the result — if a future WebKit starts retaining the pointer,
the failure would be silent data corruption in served assets.

**Both answers are results, so neither is a pass condition.** "WebKit keeps
the pointer" is precisely the finding that would tell CAP-7M its adapter must
hold the source buffer alive — folding it into the page's `ok` would turn
learning that into a shard failure. The gate therefore requires the verdict to
*exist and be determinate* (`ownership=undetermined` blocks, per the matrix's
"undetermined ⇒ incomplete") and never requires a particular one of the two.
The same treatment is given to M13's `abort_delivered` and M9's
`seam_a_effective`.

### 3. `pweb://app` as a secure context — code evidence, not yet a field fact

**DERIVED.** WebKit's `SecurityOrigin.cpp` `shouldTreatAsPotentiallyTrustworthy`
returns true for `schemeIsHandledBySchemeHandler(protocol)` since commit
`1985ef105c30` (2021-03-19, bug 223423, "Custom scheme handled origins should
be considered secure"), first shipped in the Safari 15 / macOS 12 branch, and
WebKit's own test asserts `secure` for a **non-localhost** custom-scheme host.

That is why `pweb://app` is plausible here where the
`tauri://localhost` / `capacitor://localhost` generation needed the localhost
host — and it is the entire justification for the proposed macOS 12.0 floor.

**MEASURED**, run `31909938201`. The page reports
`{"protocol":"pweb:","host":"app","origin":"pweb://app","secure":true}`.
Gate: M15, which requires the page to **state** it. `"secure":false` is
reported exactly and stops the shard; it is never waived and never inferred
from "it rendered".

### 4. The generated binding needed the platform block translated, not written

**MEASURED**, on the dev host. ChetCLI is a Delphi tool and emits Delphi
conditional symbols for its `[Platform.*]` sections. For Win64 and Linux64
that is invisible, because `WIN64` and `LINUX` mean the same thing to both
compilers. For macOS it is not:

```
generated (Delphi):  {$ELSEIF Defined(MACOS64) and Defined(CPUARM64) and not Defined(IOS)}
required (FPC):      {$ELSEIF Defined(DARWIN) and Defined(CPUAARCH64) and not Defined(IOS)}
```

Left as generated, both Darwin branches are dead under FPC and the unit stops
at `{$MESSAGE Error 'Unsupported platform'}` — on a compiler that would
otherwise have built it. The split is the same one mORMot relies on
(`mormot.defines.inc:316` uses `{$ifdef DARWIN}` for FPC, `:522`
`{$ifdef MACOS}` for Delphi, and `:601` shows `CPUARM64` is the Delphi
spelling of `CPUAARCH64`).

The translation lives in `tools/regen-webview-binding.ps1`, the same committed
post-process that already adds `{$MODE OBJFPC}` and `{$PACKRECORDS C}`. It is
exact-match and throws if the generator's shape changes, so a silent no-op is
not a possible outcome. The generated unit is still never edited by hand, and
regenerating twice is byte-identical.

`_PU` stays `''`: **DERIVED**, FPC applies the Mach-O `_` prefix itself for
`external ... name 'sym'` (mORMot declares `mach_absolute_time` and friends
without it and works on Darwin). The underscore is therefore a *link-time*
convention, which is why `test/cap7m/check_webview_exports.sh` strips it
before comparing — and treats an exported symbol *without* it as a finding.

**The export gate reads the export trie, not `nm`.** The Linux gate's `nm -D
--defined-only` reads the dynamic symbol table — the list the loader actually
publishes. Mach-O's equivalent is the export trie, and `dyld_info -exports`
is what reads it; `nm -gU` reads the *static* table's global defined entries,
which is a different and larger set. `nm -gU` is still run, and the difference
between the two lists is **recorded** (`CAP7M_M2 export_trie=… nm_gU=…`)
rather than gated.

Upstream sets `CMAKE_CXX_VISIBILITY_PRESET hidden` (`cmake/internal.cmake:28`),
which is why only the 17 `WEBVIEW_API` entry points reach the trie as
*callable* exports — see constraint 8 for the C++ RTTI records that
accompany them on x86_64 and not on arm64.

### 5. FPC records the install name, exactly as it records the SONAME

**DERIVED** from the pinned CMake sources, **asserted** by the gates.
`core/include/webview/version.h` is 0.12.0, so CMake's `VERSION` is 0.12.0 and
its `SOVERSION` (`WEBVIEW_VERSION_COMPATIBILITY`, `cmake/internal.cmake:21-25`)
is 0.12. On Apple that yields:

```
libwebview.0.12.0.dylib   the real file CMake writes
libwebview.0.12.dylib     the compatibility name -> LC_LOAD_DYLIB
libwebview.dylib          the link-time name -> the chet [Platform.Mac*] LibraryName
```

The binding says `external 'libwebview.dylib'`; the linker reads the install
name out of that file and records **`@rpath/libwebview.0.12.dylib`**. So a
bundle ships the *versioned* name and the bare `.dylib` is a dev-only
convenience — the identical structure the Linux port has with
`libwebview.so.0.12` versus `libwebview.so`, arrived at by a different
mechanism.

**With one difference that constraint 9 makes precise:** the linker records
that name only when the binary actually *references* a symbol from the dylib.
`DT_NEEDED` follows the link line; `LC_LOAD_DYLIB` follows the call graph.

`tools/build-webview-dylib.sh` asserts only that the install name is
`@rpath`-relative (an absolute build-tree install name is what would break a
bundle) and **records** the exact observed string, because M3 measures it.

### 6. The runner's Xcode is a variable, and FPC 3.2.2 predates all of it

**DERIVED** from FPC's own issue tracker: aarch64 + Xcode 16.3 fails with `ld`
exit −11, and Intel + Xcode 16.2 fails to build. Both are listed as
`macos-xcode-known-bad` in `fpc.lock` and are **excluded outright rather than
kept as fallbacks** — a fallback onto a known-broken toolchain only converts a
clear failure into an obscure one.

`tools/get-fpc-macos.ps1` selects the first `macos-xcode-candidates` entry
present as `/Applications/Xcode_<v>.app`, exports `DEVELOPER_DIR`, and — if
none is present — prints every Xcode the image actually carries and fails, so
the next pin is chosen from evidence rather than from whatever the image
defaults to.

### 7. FPC 3.2.2 cannot link on aarch64 at the proposed floor without a flag

**MEASURED**, run `31904189177` on `macos-15` (macOS 15.7.7, Xcode 16.4,
Apple clang 17.0.0), linking the plain console `test/core/abi_probe.pas`:

```
ld: pointer not aligned in 'FPC_THREADVARTABLES'+0x4 (…/abi_probe.o)
```

Apple enables the **chained-fixups** format for every binary whose deployment
target is macOS 12 or later. Chained fixups store the next-fixup offset inside
the pointer word itself, so on arm64 the pointer data must be 8-byte aligned;
FPC 3.2.2 emits `FPC_THREADVARTABLES` 4-byte aligned. Under the old `ld64`
this was a warning (FPC issue 31696, 2017); under `ld_prime` — the linker in
every Xcode from 15 onward — it is a hard error.

Three properties make this a baseline fact rather than a nuisance:

- **Unconditional.** `FPC_THREADVARTABLES` is RTL data emitted for every
  program, threads or not.
- **arm64-only.** Which is precisely why the x86_64 leg linked cleanly and
  the problem could have been missed by a single-architecture shard.
- **Unavoidable by Xcode choice.** Every Xcode on the runner is 15 or newer.

**The remedy taken: `-k-no_fixup_chains`, on the aarch64 link only.** It is
the flag the linker's own message names, it reverts to classic rebase/bind
opcodes that every supported macOS loads, and — decisively — it leaves
`-WM12.0` alone, so `LC_BUILD_VERSION minos` stays 12.0 and the ratified floor
survives. It is applied to aarch64 only: x86_64 links cleanly without it, and
passing a flag one architecture does not need would contaminate that
architecture's measurement with a workaround for the other one's defect.

**The remedy deliberately NOT taken: `-WM11.0`.** Lowering the deployment
target below the chained-fixups threshold is the better-sourced fix for this
exact FPC 3.2.2 error (MacPorts ticket 68368), and it is still the wrong one
here, because it contradicts the floor this shard proposes. 12.0 was chosen
because WebKit's custom-scheme secure-origin change first ships in the macOS
12 branch — the entire basis for expecting `pweb://app` to be a secure
context. Linking at 11.0 would emit binaries claiming to run on a system where
that premise does not hold: an unsound support claim traded for a tidier
build.

**Recorded caveats.** `-no_fixup_chains` is an `ld_prime` flag with no
guaranteed lifetime. `-ld_classic` is **not** a fallback — deprecated in Xcode
16 and removed in Xcode 27 — so if this flag ever disappears the answer is a
newer FPC, not an older linker. And this is **not** Lazarus issue 41570
(`ld` exit −11 on FPC 3.3.1), which is a different bug with a different fix;
conflating the two is easy and would send the next reader after the wrong
remedy.

The decision lives in one place — `tools/macos-buildenv.sh`, where CAP-7M1
moved it from `test/cap7m/cap7m_common.sh` — and is consumed by every Pascal
*program* link this project performs. It was the ONE macOS flag that was
already centralized; **that file is now the single source for all of them**
(the deployment target, the architecture, the mORMot static directory, the
clang flags, the FPC compile and link flags, the frameworks, the rpath, the
bridge object and the CMake OSX cache variables). Before CAP-7M1 the
deployment target was written at twelve call sites and fetched from the lock
four times; adding an adapter on top of that would have inherited twenty
places for the ratified floor to drift from.

### 8. The export surface is not the same on both architectures

**MEASURED**, same run, and it is C++ RTTI rather than anything to do with the
webview API:

```
arm64    17 exports - the 17 webview entry points, nothing else
x86_64   25 exports - the same 17, plus 8 libc++ typeinfo records
```

The eight extras are `_ZTI…` / `_ZTS…` typeinfo and typeinfo-name symbols for
the `std::function` instantiations upstream creates (`bool()`, `void()`,
`void(string,string,void*)`) and for `std::bad_function_call`. They are weak,
coalesced, carry no code and cannot be invoked; the x86_64 toolchain emits
them into the image where the arm64 one does not. Linux never showed this
because ELF resolves the same typeinfos out of libstdc++ instead of emitting
them into the `.so`.

**This is why the gate does not simply count to 17.** The contract is "never
an 18th *public webview* export", so `test/cap7m/check_webview_exports.sh`
asserts (a) the `webview_*` set is exactly the pinned 17 on both arches, and
(b) every other export matches `^_ZT[IS]` — anything else blocks and is named,
because an export that is neither an entry point nor RTTI *is* the "someone
patched upstream" case. The complete list and count are recorded per
architecture as `CAP7M_EXPORTS`.

Note what was **not** done: no `-fvisibility=hidden` or any other compiler
flag was added to make the count match. That would change how the pinned
upstream is built, diverge from the Windows and Linux builds, and convert a
measured fact into a hidden one.

### 9. A Mach-O load command records USE, where `DT_NEEDED` records LINKAGE

**MEASURED**, run `31905105454`, identically on both architectures:

```
[CAP-7M0] the Pascal probe records no libwebview load command at all
```

Mach-O's linker emits an `LC_LOAD_DYLIB` only when a symbol from that dylib is
actually **referenced** — ELF's `--as-needed` behaviour, unconditionally and
with no opt-out by default. ELF's `ld` records `DT_NEEDED` for any library
merely *named on the command line*.

That difference is exactly why CAP-7L could write up
`DT_NEEDED = libwebview.so.0.12`, measured straight off `abi_probe`, as a
load-bearing fact (see "Linkage, sonames and the release layout" in
`webkitgtk-linux-semantics.md`). `test/core/abi_probe.pas` references
**nothing**: it declares the externals, assigns its *own* `cdecl` procedures
to the typed callback consts, and measures sizes, offsets and signedness. On
Linux it still recorded a `DT_NEEDED`. On Darwin it correctly records no load
command at all, and a gate that demanded one was asserting a Linux property
that does not exist here.

Two things were deliberately **not** done to make it pass:

- **`abi_probe.pas` / `abi_probe.c` were not modified** to call into the
  dylib. That pair is the single pinned CAP-1 probe, unmodified on every
  platform; making it reference a symbol to satisfy a gate would change what
  it measures.
- **The dependency was not manufactured** with `-needed_library` /
  `-needed-lwebview`. Forcing a load command onto a binary that genuinely
  references nothing fabricates the measurement instead of taking it.

So the fact is **recorded** (`CAP7M_M5 binary=abi_probe references_dylib=no`)
rather than asserted, and the two obligations move to where they belong:

- **M5 — "all 17 externals resolve through the Mach-O underscore
  convention"** is proven by `dlopen` + `dlsym` on the staged dylib, which is
  the stronger claim anyway: it shows the names are reachable at *run* time
  through the exact mangling FPC's `external` uses. Asserted from both sides —
  the bare name `webview_create` must resolve, and the trie's own spelling
  `_webview_create` must not, because `dlsym` applies the Mach-O prefix
  itself.
- **The load command is asserted on `cap7m_probe`**, which really does call
  `webview_create` and fifteen others, and whose `@rpath/libwebview.0.12.dylib`
  is the value PROBE K's bundle layout actually depends on. Any binary that
  carries one at all must name that path; `signature_pin` (which only takes
  the 17 addresses) and `uri_oracle` (which references none) are recorded.

Consequence for CAP-7M: on Darwin, "what does this executable need at run
time" is a question about the *call graph*, not about the link line. A future
adapter that stops calling a library stops depending on it, silently — which
is convenient for packaging and treacherous for anyone porting a Linux
assumption across.

### 10. `O_DIRECTORY` and `O_NOFOLLOW` are POSIX by name, not by RTL

**MEASURED**, run `31908958453`, and it stopped the isolation compile dead:

```
pweb.assets.folder.pas(362,40) Error: Identifier not found "O_DIRECTORY"
pweb.assets.folder.pas(441,35) Error: Identifier not found "O_NOFOLLOW"
```

FPC 3.2.2's **Linux** BaseUnix declares both; its **Darwin** BaseUnix
declares neither. So the POSIX branch CAP-7L hardened — the one that makes
the dev folder store behave like the packaged archive store rather than like
whatever filesystem sits underneath it — simply does not compile on Darwin.

Both uses are confinement code, which is why the branch was not weakened:

- `O_DIRECTORY` (`:362`) makes *a file was passed as the asset root* a
  construction-time refusal instead of a silent 404 stream later;
- `O_NOFOLLOW` (`:441`) makes a symlink swapped in between the walk and the
  open **fail**, instead of resolving somewhere else.

The constants are therefore declared for Darwin only, `{$ifdef DARWIN}`
guarded, in the unit's **interface** — the same placement, for the same
reason, that CAP-7L used for its hand-declared GTK aliases: a probe has to be
able to see them. Linux keeps taking BaseUnix's, and no call site changed.

**The values are measured, not transcribed.** The failure modes are
asymmetric and that asymmetry is the whole argument:

| Wrong constant | What happens |
|---|---|
| `O_DIRECTORY` | the store stops constructing — loud, immediate |
| `O_NOFOLLOW` | the open quietly stops refusing symlinks, and every test still passes |

A confinement guarantee that disappears silently is worse than one that was
never claimed, so `test/cap7m/abi_probe_fcntl.c` prints what `<fcntl.h>`
actually defines on the runner's SDK, `abi_probe_fcntl.pas` prints what the
unit declares, and `check_abi.sh` compares them line by line with **zero**
permitted deltas — unlike the core webview pair, which has two documented
signedness lines, there is no legitimate difference here. Values are recorded
as `CAP7M_FCNTL`.

Two details that would quietly break the measurement:

- the C probe is compiled with **no** `-std=…`. A strict-ISO mode sets
  `__STRICT_ANSI__`, which lowers `__DARWIN_C_LEVEL` and can hide
  `O_NOFOLLOW` behind its `_DARWIN_C_SOURCE` guard;
- a missing macro is a `#error`, not an absent line, so a broken measurement
  cannot present itself as a diff.

`O_RDONLY` is probed too, though BaseUnix supplies it everywhere: it is what
both call sites `or` the other two into, so a probe without it would not be
measuring the argument actually passed to `FpOpen`.

### 11. An FPC binary that CALLS into the dylib needs an explicit `-L`/`-l`

**MEASURED**, run `31909456486` — the failure. **EXPECTED**, the mechanism:
the cause is not yet established, and this section says so rather than
inventing one.

```
"_webview_version", referenced from:
    _TC_$P$SIGNATURE_PIN_$$_PIN_VERSION in signature_pin.o
ld: symbol(s) not found for architecture arm64
```

All 17 undefined. `signature_pin` takes the address of every entry point;
`abi_probe`, linked with the same flags, references none and linked cleanly —
the same asymmetry as constraint 9, from the other side. `-Fl` supplies a
search **path**; something has to put the library itself on the line.

**The fix is settled: pass `-k-L<dir> -k-lwebview`** to every FPC binary that
references a webview symbol, mirroring what the clang line already does for
the ObjC++ probe. `-lwebview` resolves `libwebview.dylib`, whose install name
is `@rpath/libwebview.0.12.dylib`, so the resulting `LC_LOAD_DYLIB` is the
one M16 already asserts. It is correct whether or not FPC also emits its own
`-l`, since a duplicate resolves once.

**The mechanism is NOT settled, and the obvious explanation does not survive
reading the compiler.** "FPC emits no `-l` for `external` on Mach-O" is not
supported by FPC 3.2.2's source:

- `compiler/systems/t_bsd.pas:355-369` emits `-l<lib>` from `SharedLibFiles`,
  stripping `target_info.sharedlibext`;
- `:132` sets `LdSupportsNoResponseFile` true for `systems_darwin`, so those
  arguments go straight onto the command line;
- `compiler/systems/t_linux.pas:565-576` is the **same code**, and Linux
  demonstrably works.

And the observed error was `symbol(s) not found`, not `library not found for
-l…` — which is what an emitted-but-unresolvable `-l` would have produced. So
a wrongly-spelled `-l` is also ruled out. The remaining candidate is that
`SharedLibFiles` is empty for this build, and *why* is open.

`test/cap7m/build_cap7m.sh` therefore runs one `fpc -va` link with the
explicit flags deliberately **withheld** and records what FPC passed unaided
as `CAP7M_LINKLINE` (`fpc_emits_l_webview=yes|no`, the matched tokens, and
the linker invocation). That is a standing instrument, not a one-off: it is
also what keeps constraint 9's mechanism observable now that `abi_probe` is
linked with an explicit `-l` and can no longer demonstrate it.

**Consequence for CAP-7M, whatever the mechanism turns out to be:** the
production application links Pascal against the dylib and calls into it, so
it needs these flags too. Both this and constraint 9 are the same underlying
difference — *Darwin binds by use where ELF binds by declaration* — and the
practical rule that falls out of it is: on Mach-O, what a binary needs at run
time follows its call graph, and what reaches the linker must be stated
explicitly rather than inferred from a declaration.

### 12. A bare `NSURLResponse` loads the resource but gives `fetch()` no status

**MEASURED**, run `31909938201`, and it was the last failing assertion of an
otherwise passing probe:

```
CAP7M_URI cycle=1 verdict=serve url=pweb://app/probe.css   <- the handler DID serve it
"css":true                                                 <- computed style proves it applied
"subresource":false                                        <- and yet fetch() says not ok
```

A `WKURLSchemeTask` completed with a plain `NSURLResponse` **loads correctly**:
the HTML renders, the stylesheet applies, subresources arrive. But
`NSURLResponse` carries no status code, so `fetch()` sees `status: 0` and
`ok === false`. A subresource load does not care; JavaScript does.

**Only `NSHTTPURLResponse` gives JavaScript a status** - `statusCode: 200`,
`HTTPVersion: "HTTP/1.1"`, header fields carrying at least `Content-Type`
and `Content-Length`.

The refusal path is deliberately left as `didFailWithError:`, which is the
measured Darwin refusal shape and matches how CAP-7L documented WebKitGTK
refusing without a status.

One trap the probe hit while fixing this: `Content-Length` must be OMITTED
(not merely wrong) for a response whose body is meant to stay open. The M13
cancellation case declares no length, because a declared length the response
never delivers makes `fetch()` reject on a truncated body - reporting
`aborted` whether or not the abort ever arrived, and quietly turning the
cancellation measurement into a tautology.

**Three platforms, three status stories** - worth having in one place, since
a handler ported from either sibling gets this wrong by default:

| | Serving | Refusing |
|---|---|---|
| **Windows / WebView2** | status set on the response | constant **404**, empty body |
| **Linux / WebKitGTK** | `finish` + stream, no status concept | `finish_error`, **no status at all** - `fetch()` rejects |
| **macOS / WKWebView** | `NSURLResponse` loads but reports **0**; `NSHTTPURLResponse` reports **200** | `didFailWithError:`, **no status** - `fetch()` rejects |

(CAP-7L's "A refusal has no status code" paragraph in
`webkitgtk-linux-semantics.md` is the Linux row. The two REFUSAL columns
agree across all three; it is the SERVING column that differs.)

**Consequences.** The CAP-7M production adapter must use `NSHTTPURLResponse`.
A bare `NSURLResponse` would ship an asset plane where every `fetch()` of an
app resource reports failure while the page looks perfectly fine - a defect
that surfaces in a user's application code rather than in any gate here.
**CAP-12's blob plane will depend on it harder**: `Range` handling is
meaningless without status codes, since 206, 416 and `Content-Range` have
nowhere to live on an `NSURLResponse`.

### 13. `/proc/self/fd` has no Darwin equivalent, and the folder store needed one

**MEASURED**, CAP-7M1, and it is the blocker CAP-7M0 could not see because it
only ever *compiled* `pweb.assets.folder.pas` — it never constructed a store.

The hardened POSIX branch re-proves confinement on the **open descriptor**:
after walking each segment with `lstat` and opening the final component
`O_NOFOLLOW`, it asks the kernel what it actually opened and requires the
answer to equal the expected path byte-exactly. On Linux that question is
`readlink("/proc/self/fd/N")`. **macOS has no `/proc`**, so `FinalPathOfFd`
returned `''`, the constructor raised at its root-canonicalization step, and
`TFolderAssetStore` could not be created at all. The whole CAP-7L confinement
branch was, until CAP-7M1, dead on macOS — and with it the ten published
`TTestAssetStores` cases, which take the suite down in `Setup`.

The replacement is the direct counterpart, not a different algorithm:

| | "what did I actually open?" |
|---|---|
| **Windows** | `GetFinalPathNameByHandleW(h, …)` |
| **Linux** | `readlink("/proc/self/fd/N")` |
| **macOS** | `fcntl(fd, F_GETPATH, buf)` — `buf` at least `PATH_MAX` (1024) |

Both call sites and the confinement algorithm are **byte-identical** across
the two POSIX systems; only the way the question is asked differs.

**Three things about it are easy to get wrong, and all three are gated.**

- **`fcntl` is variadic in C, and Apple's two ABIs disagree about variadics.**
  `int fcntl(int, int, ...)` passes its third argument **on the stack** on
  arm64 and **in a register** on x86_64. A plain three-argument `cdecl`
  external would therefore be correct on Intel and silently wrong on Apple
  Silicon. The declaration uses FPC's `varargs`, and — because "the
  declaration is right" is an *architecture-specific* claim — the paired probe
  now performs a **round trip**: `test/cap7m/abi_probe_fcntl.c` and
  `.pas` are handed the same file and must report the same kernel-resolved
  path, on each architecture separately. FPC 3.2.2's Darwin `BaseUnix` offers
  only the integer-argument `FpFcntl` forms, which would truncate a 64-bit
  pointer to 32 bits, so there is nothing in the RTL to use instead.
- **macOS resolves firmlinks.** A root under `/tmp` canonicalizes to
  `/private/tmp/...`, and `/var` to `/private/var/...`. That is not a defect —
  it is exactly why the root is canonicalized *through the descriptor* in the
  first place — but a gate that builds fixtures must compare on `pwd -P`
  output or it will construct link targets that never compare equal.
- **An unlinked file reports its last path with no `(deleted)` marker**,
  unlike Linux. Neither system's answer is an escape (the fd was opened
  `O_NOFOLLOW` at a walked-and-`lstat`'d path), but the difference is real and
  a reader porting the Linux reasoning across will not expect it.

**The failure mode is loud, unlike `O_NOFOLLOW`'s.** A wrong `F_GETPATH` stops
the store constructing and fails every read's re-proof, so nothing is servable
at all. That asymmetry is an argument for caring *more* about `O_NOFOLLOW`,
never for measuring `F_GETPATH` less: the probe covers both, with zero
permitted deltas.

**What the re-proof does NOT close, stated so nobody infers otherwise.** A
**hard link** inside the root pointing at an inode outside it is served — on
Linux exactly as on Darwin. The ratified model is *no symlink on the resolved
chain, and the opened descriptor's kernel path equals the expected path*, and
a hard link satisfies both by construction: `lstat` sees a regular file, and
`F_GETPATH` (like `/proc/self/fd`) reports the path the descriptor was
*opened by*, which is the in-root path. Neither mechanism was ever going to
close that, and reading `F_GETPATH` as if it did is the mistake this paragraph
exists to prevent; closing it needs a different invariant (same-device plus
inode-set membership, or an `openat`-relative walk from a root descriptor),
which is a change to CAP-7L's algorithm rather than a Darwin body for it.
Ledgered.

### 14. The bridge holds a generation-checked handle, never a Pascal pointer

**DERIVED**, and it is the one place the macOS adapter is deliberately
*stronger* than its siblings rather than merely different.

The Linux adapter disowns by clearing an interlocked owner **pointer** in a
GLib-owned cell. That works, and it depends on the store being ordered
correctly relative to the free. The Cocoa bridge instead receives a `uint64_t`
packing a slot index and a generation counter, and resolves it through a
Pascal-side registry that bumps the generation on **both claim and release**.
So a handle minted for a handler that has since been detached does not resolve
to a stale object, or to whatever now occupies the slot — it does not resolve
at all.

```
Detach:  disown (the bridge stops calling out)
      -> claim and fail every live task (no request is left waiting forever)
      -> release the slot (the handle becomes unresolvable)
      -> only now may webview_destroy run
```

That makes "no callback after handler destruction" a property of the
*representation* rather than of the teardown order, and it is what the
`HandleRegistryGenerations` case asserts by re-occupying the slot and
requiring the old handle to stay dead.

The reverse direction has one rule and one owner: a response body is allocated
by Pascal through `pweb_cocoa_alloc` and belongs to the **bridge** from the
moment the resolve callback returns non-zero, whether the task is served or
abandoned. Pairing the allocator with the deallocator on one side of the seam
is why those two entry points exist at all — Pascal never has to assume which
libc allocator the Objective-C++ side frees with.

`Attach` is the other half of the same idea, and it takes **two** steps
because the first one alone is nearly vacuous:

1. the bridge's seam-invocation counter must have moved across
   `webview_create`. Cheap, and safe on a handle that is not really a webview
   — but process-global and monotonic, so *any* unrelated
   `+[WKWebViewConfiguration new]` anywhere in the process would satisfy it;
2. the view's own configuration must report **our** handler for the `pweb`
   scheme, read through the public
   `-[WKWebViewConfiguration urlSchemeHandlerForURLScheme:]` reached via
   `webview_get_native_handle(w, BROWSER_CONTROLLER)`.

Step 2 is what turns "a counter moved" into "this view will route `pweb://` to
us". Note that it does not contradict constraint A: CAP-7M0 measured that
*writing* to the configuration a `WKWebView` hands back is silently
ineffective, which is a statement about mutation — reading back a registration
the configuration was **copied with** is a different operation. Constraint 12's
lesson generalises: on this backend the dangerous failures are the quiet ones,
so both steps raise and neither warns.

`Detach` and `Attach` additionally refuse to run off the thread that created
the handler. That is not defensive tidiness: `Detach` sends
`didFailWithError:` to any still-live `WKURLSchemeTask`, and those are
main-thread-only.

### 15. A synchronous main-thread handler, and the honest claim about races

**DERIVED, and stated narrowly on purpose.**

Every request is resolved and completed inside `startURLSchemeTask:` on the
main thread. `stopURLSchemeTask:` therefore cannot interleave with serving,
the tracked-task set is empty between calls, and most of the race surface
constraint 1 documents is **structurally absent rather than merely untested**.

The claim-once state machine is still built and still gated, for two reasons:
"structurally absent" is a property of *this* implementation that a future
chunked or deferred delivery would remove — CAP-12's `Range` plane will need
one — and the invariants are cheap to hold and expensive to retrofit.

**The claim and the removal are separate steps, and that separation is the
whole guard.** A task moves `New → Serving → Completed|Cancelled`; the claim
is the transition *out of* a non-terminal state and succeeds exactly once, but
the task stays **tracked** until it is settled, after the terminal callback
has actually been delivered. Claiming and removing in one step would mean an
`NSException` out of `didReceiveResponse:` leaves a task that is untracked
*and* unterminated — a resource WebKit waits on forever, invisible because
`live_tasks` already reads 0 and every gate stays green. The states are
load-bearing rather than decorative: `stops_while_serving` counts a stop that
arrived on a `Serving` task specifically, which is the interleaving this
handler cannot produce and a chunked one will.

It is proven two ways, and only one of them is a race test:

- **Deterministically**, in `test/platform/pweb.test.cocoa.pas`, by driving
  the real handler with a bridge-internal stub task: a second terminal is
  suppressed, a post-stop delivery is suppressed *before the call is made*, a
  second cancel is a no-op, teardown claims and fails a task deliberately left
  live, and a disowned handler serves nothing and reaches no Pascal code. The
  stub **mimics WebKit's documented raising behaviour**, so a guard that
  stopped working would surface as a raised misuse rather than as silence — a
  stub that quietly accepted misuse would let the claim gate be deleted with
  every test still green.
- **In a real `WKWebView`**, by `test/cap7m/run_cap7m_runtime.sh`, which
  asserts zero suppressed terminals, zero caught exceptions, zero unresolved
  handles and an empty task set at every teardown, across both shutdown
  shapes.

**What the real leg does *not* prove is recorded as a limitation.** If it
records zero `stopURLSchemeTask:` arrivals — which is the expected outcome of
a synchronous handler — the gate says so in as many words rather than
reporting a passing race test. That distinction is the whole reason the
deterministic leg exists.

### 16. FPC enables FPU traps; WebKit computes on NaNs. The process dies

**MEASURED**, run `31951505821` on `macos-x64`, and it killed every cycle of
the production runtime harness before a single asset was served:

```
CAP7M1_FAIL cycle=1 store=folder reason=EInvalidOp: Invalid floating point operation
CAP7M1_FAIL cycle=2 store=folder reason=EInvalidOp: Invalid floating point operation
CAP7M1_FAIL cycle=3 store=folder reason=EInvalidOp: Invalid floating point operation
```

This is CAP-7L's Linux finding on a second backend
(`webkitgtk-linux-semantics.md`, and the `initialization` block of
`pweb.platform.webkitgtk.pas`). FPC does not leave the FPU in the C default
state: it deliberately **enables** the invalid-operation, divide-by-zero and
overflow traps at startup — on `aarch64` explicitly at
`rtl/aarch64/aarch64.inc:133`, which ORs `fpu_ioe|fpu_dze|fpu_ofe` into FPCR,
and equivalently on `x86_64` through the x87 control word and MXCSR. WebKit,
CoreGraphics and AppKit compute with NaNs, infinities and denormals as
ordinary intermediate values — entirely legal IEEE-754 arithmetic — so the
first such computation traps inside a C frame with no handler.

**The same run proves it from the other side.** `cap7m_probe`, the retained M0
instrument, drives a real `WKWebView` through the identical path in the same
job and **passes** — because it is a pure C++ program that never had the traps
enabled. Only the FPC-hosted process dies. That asymmetry is the diagnosis,
and it is also why CAP-7M0 could never have found this: M0 had no Pascal
program that opened a window.

**Why CAP-7L's remedy could not be copied.** `Set8087CW` + `SetSSECSR` are
x86-only and would not compile for `aarch64-darwin`, where the same state
lives in FPCR — with the **opposite polarity**: `1` means *masked* on x86 and
*trap enabled* on ARM, so hand-writing both would risk silently leaving the
traps live on one architecture. FPC's own `getfpcr`/`setfpcr` are not an
option either: they are implementation-internal to the system unit and are not
exported by `systemh.inc`.

**The remedy taken:** `fesetenv(FE_DFL_ENV)` in the bridge
(`pweb_cocoa_mask_fpu_traps`), where libc knows which register it is. It is
C99, it is the environment the C runtime starts in, and by IEEE-754 that
environment has every trap disabled. It also normalises rounding to
`FE_TONEAREST`, which is not a behaviour change — FPC already rounds to
nearest on both targets (`rtl/aarch64/aarch64.inc:129` clears the FPCR
rounding bits).

**Deliberately NOT `math.SetExceptionMask`** — CAP-7L's measurement applies
unchanged: `math`'s finalization restores the control words, mORMot's units
initialise earlier and therefore finalise later, and the result was a
completely successful run that then exited 217.

**Applied twice, because FPU control is per thread.** Once at unit
initialization — before any application code, so no window can be created
ahead of it, and before any worker exists, so workers inherit the masked
state — and again in `TCocoaAssetHandler.Create`, which runs on the thread
that will actually host WebKit and is not guaranteed by contract to be the
one the unit initialised on. The gate asserts
`CAP7M1_FPU store=… traps_masked=1` rather than accepting a process that
merely survived.

## Threading

**MEASURED**, run `31909938201` (`gui_affine=1 worker_distinct=1 direct_return=1`, `echoes=8 errors=1 outstanding=1`), and re-proven rather than adapted. The frozen model is the same
on all three backends:

- the bind callback runs on the **GUI thread**;
- the callback's `id` and `req` are **borrowed**: valid only for the duration
  of the call, copied before it returns. Note what the probe can and cannot
  show here. Seeing the *same address* handed back a second time proves the
  buffer is reused and therefore borrowed; seeing different addresses proves
  nothing either way, because an allocator is free not to reuse one. So
  `id_ptr_reused` is **recorded as evidence and never asserted on**, and the
  lifetime rule the adapter follows is the documented one, not an inference
  from this number. Re-reading the buffer after the call to "prove" it went
  away would be a use-after-free performed on purpose;
- a worker calling `webview_return` **directly** resolves the JS promise —
  eight concurrent invocations all resolve, exactly once each;
- no Cocoa call runs on the worker, because upstream's `webview_return`
  forwards through `engine_base::resolve` → `dispatch` →
  `dispatch_async_f(dispatch_get_main_queue(), …)` (`cocoa_webkit.hh:180-188`);
- `worker → webview_dispatch → webview_return` is forbidden, here as
  everywhere else.

`webview_dispatch` remains the only cross-thread route for anything else, and
the watchdog in `test/cap7m/cap7m_probe.mm` uses it to terminate.

Gates: M7 (`gui_affine=1 worker_distinct=1 direct_return=1`) and M8 (eight
concurrent, one forced error rejecting with its payload intact, and one
invocation deliberately still outstanding when shutdown begins — teardown
drains it before `webview_destroy`).

## Shutdown has two shapes, and only one of them is `webview_terminate`

**DERIVED.** Upstream installs an `NSWindowDelegate` whose `windowWillClose:`
nulls `m_widget`/`m_webview`/`m_window` and dispatches `on_window_destroyed()`
(`cocoa_webkit.hh:369-387,440-446`), which stops the run loop when the engine
owns the window. So a user clicking the red button and a programmatic
`webview_terminate` reach the run loop by **different paths**, and a probe
that only ever terminates programmatically says nothing about the commoner of
the two.

The probe alternates: odd cycles terminate, even cycles close the `NSWindow`.
Gate: M6 requires both shapes to have been exercised across the run.

**Each shutdown is on its own deadline.** The page's report sets `finished`
*before* the shutdown is even attempted, so the main watchdog returning says
nothing about whether the run loop stopped. A second, shorter deadline is
armed on `webview_run` actually returning; without it, a window close that
fails to end the loop hangs until the CI step timeout and reports as
infrastructure rather than as the defect M6 exists to catch. The watchdog also
terminates on any *failure*, not only on timeout — otherwise a detected defect
leaves `webview_run` spinning and turns a clean failure into a hang.

**M6 also measures the leak**, because the matrix row says
"crash/hang/leak blocks" and the repeated create/destroy loop is the natural
place to catch a Cocoa leak. Resident size is sampled after every cycle
(`CAP7M_RSS`), and growth from cycle 2 to the last cycle is bounded
(`CAP7M_M6_LEAK`). Cycle 1 is never the baseline: WebKit legitimately
populates its caches on the first navigation. The bound is deliberately coarse
and is described as such — it catches a per-cycle leak of a whole WKWebView,
not a handful of stray objects. Three cycles is therefore the default, since
two leave nothing to measure growth against.

## Bundled and non-bundled behave differently

**DERIVED**, `cocoa_webkit.hh:402-436`: upstream asks `NSBundle` whether the
app is bundled and calls `setActivationPolicy:` +
`activateIgnoringOtherApps:` **only when it is not**. A non-bundled Mach-O
therefore presents a window on a hosted runner without any help from us, and
the bundled path is a *different* branch that the bare binary never reaches.

`test/cap7m/check_release_layout.sh` is the only gate that exercises it: it
assembles a throwaway `.app` **outside the checkout**, strips every `DYLD_*`
hint — `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH` and
`DYLD_FALLBACK_LIBRARY_PATH`, in the negative half as well as the positive
one, since a "hidden" dylib that one of them can still find would make the
whole conclusion vacuous — runs it from `/`, and requires `otool` to state why
the dylib resolved. That is a measurement of what a future layout must
satisfy — it is not a proposed release layout, and this shard packages
nothing.

**Signing is deferred; the signing CONSTRAINT is measured.** On Apple Silicon
every Mach-O must carry at least an ad-hoc signature to execute at all, and
the linker applies one unasked — so "did we have to sign it?" is already
answered by the artifact, and a future layout inherits that answer whether or
not anyone looked. The gate records `codesign -dvv`, whether
`codesign --verify` passes, whether the signature that let the bundle run was
an ad-hoc one the toolchain applied, and any `com.apple.quarantine` attribute
(`CAP7M_M18_SIGNING`). It signs, re-signs, strips and staples nothing.

## The release `.app` products (CAP-7M2)

CAP-7M2 turns the M18 measurements into two shipped products per
architecture — `PWebReleaseReact.app` (`dev.pweb.release.react`) and
`PWebReleasePas2js.app` (`dev.pweb.release.pas2js`) — assembled and gated by
`test/cap7m/run_cap7m_release.sh`. Four platform facts shape that gate, and
they belong here because each one cost a measurement to learn.

**LaunchServices delivers argv, and nothing else.** `open -W` waits for the
launched instance but forwards **neither its stdout nor its exit code**, and
a LaunchServices launch does **not** inherit the caller's environment — so
neither `PWEB_SMOKE_AUTOCLOSE_MS` nor any capture of the process's output
can carry evidence out of an `open`-launched run. The only deterministic
channel is a file path passed **in argv**: the shared release host gained
`--pweb-verdict=<file>` (the canonical PASS/FAIL line, written atomically as
temp + rename on every exit path) and `--pweb-autoclose-ms=<N>` (argv wins
over the environment, because argv is all LaunchServices delivers). Direct
launches keep the real exit code and stderr, so both launch shapes stay
gated.

**`Contents/Resources` is the bundle's data directory, resolved from the
executable.** Inside a `.app` the executable lives in `Contents/MacOS` and
`app.pwb` in `Contents/Resources`; the host resolves it as
`<exedir>/../Resources/app.pwb` through `ExpandFileName` over
`Executable.ProgramFilePath` — an already-absolute path, so the working
directory is never consulted. Every **42-verdict** launch (direct and
LaunchServices alike) runs from `cwd=/` with all three `DYLD_*` hints
stripped, against a relocated copy under a path carrying a space and a
non-ASCII character, so that rule is measured rather than assumed; the
refusal-matrix launches (R4–R6) deliberately run the in-checkout dist
product instead — still from `cwd=/` with the hints stripped — because what
they mutate and restore is the real product tree.

**Codesign state is recorded per architecture, never performed as product
signing.** On arm64 the linker applies an ad-hoc signature unasked (the M18
finding); on x86_64 the binaries may run unsigned. `run_cap7m_release.sh`
records `codesign -dvv` / `--verify` per product binary
(`CAP7M2_CODESIGN`). If — and only if — a LaunchServices launch demonstrably
refuses the product as built, a deterministic `codesign -s -` is applied to
the **relocated copy** as recorded local prep (`role=local-prep`) and the
launch retried exactly once; the dist products stay byte-untouched, which is
what keeps the R8 exe/dylib parity hashes honest. Nothing here is Developer
ID signing or notarization, and neither is claimed.

**WebKit keys persistent state by bundle identifier.** A WKWebView's caches
and website data land under `~/Library/WebKit/<bundle-id>` and
`~/Library/Caches/<bundle-id>` — and network/cookie state under
`~/Library/HTTPStorages/<bundle-id>` as well. That is *why* the two
products carry distinct identifiers: per-frontend state is disjoint by
construction, and a React-warmed cache can never stand in for a Pas2JS
verdict (and LaunchServices instance identity stays unambiguous). The
release gate removes exactly the first two per-identifier trees between
frontends — through the guarded deleter with `$HOME/Library` as the
explicit allowed root — and the warm rerun of the *same* product must still
produce the full verdict, including the live RPC 42. `HTTPStorages` is
deliberately **recorded, never cleaned** (`CAP7M2_WEBKIT_STATE`): the
ratified matrix bounds the cleanup to the two named trees, and a cleanup
that quietly grew a third would be a bound that stopped bounding.

## The URI is the whole URI, and there is exactly one validator

**MEASURED**, on the dev host, against the real routine.

`test/cap7m/cap7m_probe.mm` contains **no URI parser**. It serves an exact
full-string allowlist and refuses everything else, then prints every URL that
reached the handler, verbatim. `test/cap7m/uri_oracle.pas` feeds those strings
— plus the canonical list in `test/cap7m/uri_vectors.txt` — to the shared,
portable, frozen `PWebParseAppUri` (`src/assets/pweb.assets.support.pas:80`),
and `run_cap7m_probes.sh` cross-checks the two streams.

The assertion that matters is one-directional and deliberately so:

> **every URI the probe SERVED must be one `PWebParseAppUri` ACCEPTS.**

The converse is not asserted. A perfectly canonical `pweb://app/missing.txt`
is accepted by the routine and still refused by the probe, because the probe
has no such asset — "refused for lack of an asset" and "refused because the
URI is not ours" are different questions, and only the second is a security
verdict.

All 44 vectors in `uri_vectors.txt` were run through `PWebParseAppUri` on the
dev host and every verdict matched the ratified expectation, including the
ones that are easy to get wrong:

```
accept  PWEB://APP/index.html      scheme and authority fold case (RFC 3986)
accept  pweb://app                 -> index.html, in the URI layer only
accept  pweb://app/a%20b.txt       -> "a b.txt", decoded exactly once
reject  pweb://user@app/…          userinfo is part of the authority
reject  pweb://app:8080/…          so is the port
reject  pweb://app/%252e%252e/…    double encoding never decodes twice
reject  pweb://app/a%25b           a surviving '%' fails the store validator
```

Vectors WebKit normalises or refuses *before* the handler are recorded as
defence in depth (`CAP7M_VECTOR_REACHED_HANDLER`) and are never why a vector
is considered handled. The moment PWeb leans on the engine's normalisation,
the engine's rules become part of the security model — and they are not.

## Where the numbers will come from

Every gate appends to `build/cap7m/measurements.txt`, which is uploaded as
`cap7m-measurements-<arch>` on success as well as on failure — because the
measurement *is* the deliverable — with `if-no-files-found: error`, so a job
that measured nothing cannot also report the upload green. The headline facts
are additionally written to the run summary by
`test/cap7m/summarize_cap7m.sh`, so Checkpoint 1 does not require downloading
and diffing two artifacts by hand.

| Probe | Gate | Marker to read |
|---|---|---|
| A (M1–M3) | `tools/build-webview-dylib.sh` | `CAP7M_PIN` (lock = checkout), `CAP7M_ARCH`, `CAP7M_DEPLOYMENT_TARGET`, `CAP7M_XCODE`, `CAP7M_INSTALL_NAME`, `CAP7M_LC_RPATH`, `CAP7M_OTOOL_L` |
| A (M2) | `check_webview_exports.sh` | `CAP7M_EXPORTS arch=… total=… webview_api=17 other=…`; the `webview_*` set is identical on both arches, the total is **not** (constraint 8) |
| B (M4/M5) | `check_abi.sh` | 36 facts, exactly 2 documented deltas; `CAP7M_M5 dlsym_bare_resolved=17 … dlsym_underscored_resolved=0`; `CAP7M_M5 binary=abi_probe references_dylib=…` (constraint 9) |
| C (M6) | `run_cap7m_probes.sh` | `CAP7M_M6 shutdown=terminate` *and* `=window-close`; `CAP7M_RSS`, `CAP7M_M6_LEAK` |
| D (M7/M8) | `run_cap7m_probes.sh` | `CAP7M_M7`, `CAP7M_M8` (one marker per cycle, asserted) |
| E (M9/M10) | `run_cap7m_probes.sh` | `CAP7M_M10 precreate_seam_ran=1`; `CAP7M_M9 … seam_a_effective` (recorded) |
| F (M11/M12) | `run_cap7m_probes.sh` | `CAP7M_URI`, `CAP7M_ORACLE`, `CAP7M_VECTOR_REACHED_HANDLER` |
| G (M13/M14) | `run_cap7m_probes.sh` | `CAP7M_M13` (`poststop_throws`, `abort_delivered`), `CAP7M_M14 ownership=…` |
| H (M15) | `run_cap7m_probes.sh` | `"secure":true` in `CAP7M_REPORT` |
| I/J (M16/M17) | `build_cap7m.sh` | `CAP7M_M16` per binary: `minos`, `LC_LOAD_DYLIB`, `LC_RPATH` |
| K (M18) | `check_release_layout.sh` | `CAP7M_M18`, `CAP7M_M18_SIGNING` |
| L (M19) | **every** gate | `CAP7M_ENV gate=…` — one tagged block per gate, including the selected `DEVELOPER_DIR` |
| M20 | `check_cap7m_nonetwork.sh` | sample count, zero owned listeners |
| CAP-7M1 bridge | `tools/build-macos-bridge.sh` | `CAP7M_MACHO binary=pweb_cocoa_bridge.o arch=… minos=…`; the object exports only `_pweb_cocoa_*` |
| CAP-7M1 headless | `run_cap7m_gates.sh` | `CAP7M1_SUITE`, `CAP7M1_CONFINEMENT vectors=… cwd_independent=yes` |
| CAP-7M1 runtime | `run_cap7m_runtime.sh` | `CAP7M1_SEAM`, `CAP7M1_REPORT`, `CAP7M1_THREADS`, `CAP7M1_INVOKE`, `CAP7M1_STATS`, `CAP7M1_REGISTRY`, `CAP7M1_SHUTDOWN`, `CAP7M1_LEAK`, `CAP7M1_URI store=… leaks=0`, `CAP7M1_CWD` |
| CAP-7M1 fcntl | `check_abi.sh` | `CAP7M_FCNTL` — now **6** facts including `F_GETPATH`, `PATH_BOUND` and the round trip (constraint 13) |
| CAP-7M2 release build | `build_cap7m_release.sh` | `CAP7M_MACHO binary=releaseapp …` / `binary=pwebbundle …` |
| CAP-7M2 release gates | `run_cap7m_release.sh` | `CAP7M2 product=… direct=… warm=… ls=… listeners=0`, `CAP7M2_HASHES`, `CAP7M2_PARITY`, `CAP7M2_REFUSALS`, `CAP7M2_DETERMINISM`, `CAP7M2_CODESIGN`, `CAP7M2_PAS2JS` — plus `manifest-<frontend>.txt` / `inventory-<frontend>.txt` uploaded as `cap7m2-release-<arch>` for the R7 compare job |

## The one ABI delta, expected to be the same two lines

**EXPECTED.** MSVC types every C enum as signed `int`; gcc and clang both pick
unsigned when no enumerator is negative. So the Darwin C probe should report

```
signed.webview_hint_t=0                 (Pascal binding: 1)
signed.webview_native_handle_kind_t=0   (Pascal binding: 1)
```

while `webview_error_t` — which has negative enumerators — is signed on both.
Width is 4 bytes everywhere and every transported value is `0..3`, so the
calling convention is untouched.

`test/cap7m/check_abi.sh` compares all 36 facts and permits **exactly** those
two, with exactly those values, on **each** architecture. `allowed -eq 2` and
not `<= 2`: a delta that *vanished* is as interesting as a new one, because it
would mean an enum changed shape.
