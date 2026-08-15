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
architectures — and neither was predicted here. Everything downstream of the
Pascal link (the seam, the threading contract, the origin, the URI verdicts)
is still EXPECTED.

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

**EXPECTED**: `webview_create` goes through this override exactly once per
create, and `pweb://app/index.html` is then really requested by WebKit. Gate:
M10 (`CAP7M_M10 precreate_seam_ran=1` plus a served main document).

### C — a minimal upstream patch. NOT WRITTEN.

Escalation only, and only with evidence that B failed. No patch exists in this
tree and none may be written before ratification.

## Eleven constraints that are not obvious

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

**EXPECTED**: a post-stop callback really does raise. Gate: M13 records
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

**EXPECTED**: the page reports
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

The decision lives in one place, `set_fpc_arch_link_flags` in
`test/cap7m/cap7m_common.sh`, and is consumed by every Pascal *program* link
this shard performs (`check_abi.sh`'s `abi_probe`, and `build_cap7m.sh`'s
`signature_pin` and `uri_oracle`).

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

## Threading

**EXPECTED**, and re-proven rather than adapted. The frozen model is the same
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
