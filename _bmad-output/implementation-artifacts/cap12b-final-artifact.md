# CAP-12B — the blob data plane: built, and proven where it can be proven

```
CAP-12B NOT READY
the plane is measured green on four targets (run 35108018300, commit 5e4554b)
the run after it was red on Windows, in CAP-6b4, and the fix moves the HEAD
PASS waits for a green hosted run on the new final HEAD
```

**Why the closure was withdrawn.** A closure was recorded on run
`35108018300` as commit `78dec5e`. Pushing that commit started run
`35127169228`, and its **Windows** leg failed at step 80, the CAP-6b4 profile
matrix:

```
CAP-6b4 S4 PASS (offline -> fixed: ...)              17:32:14.87
RmGetList finished successfully.                      17:32:17.906
RestartManager found an application using one of our files: Microsoft Edge WebView2   (x5)
Setup was unable to automatically close all applications.
Defaulting to Abort for suppressed message box
Rolling back changes.
S6: setup exited 5
```

`78dec5e` changed one Markdown file, and its code is byte-identical to the
green run's. This is ledger D1-16's residue in a row its drain did not cover:
the fixed-profile smoke's browser outlived the app by at least 2.9 s, and the
next switch (S6, fixed → offline) could not reclaim a tree that a live process
still held. S5 failed the same way on run `33981222264`, before this shard
existed. CAP-12B did not cause it, but PASS needs a green final HEAD, so it is
fixed here rather than re-run and hoped away (ledger `12B-4`,
CLOSED):
`test/cap6b4/run_profile_matrix.ps1` now runs the CAP-6b3 path-scoped drain
before S5 and S6 as well as before every uninstall, with the measured U3
bounds unchanged. It reports and never refuses. CAP-11A FL2 still reads its
order, the CAP-6b4 and CAP-6b1 contracts pass, and both of its branches were
exercised on this host against a real process inside a scratch install root:
one process was waited for, and one was terminated by path.

**The four-target measurement of the plane.** Run **35108018300** on
implementation commit `5e4554b8acab6605833e058177e926dc7734d12c`, attempt 1,
had all six jobs `success`: windows, linux, macos-x64, macos-arm64, macos
release inventory, cap7 aggregate. I checked what the run actually proved,
not just its green status:

- step 185, `CAP-12B blob data plane gates (S1, L1, P1, B1, C1-C9) +
  evidence`, **ran** and passed on all four legs, after CAP-15B (183) and
  CAP-15C (184). Each leg's gate log carries
  `bloblive: CAP-12B LIVE PASS target=<target>`, `[CAP-12B] PASS`, and
  `self-test: 5/5 perturbations refused`. The build log on each leg ends
  `build OK`, with the engine library staged (`webview.dll`,
  `libwebview.so.0.12`, `libwebview.0.12.dylib` on both Macs). On macOS
  arm64, `-k-no_fixup_chains` is present in all four link sets;
- every record `build/cap12b/cli-<target>.json` reads `verdict = PASS`,
  `violations = 0`, and **every boolean row `true` on all four targets**:
  `blob_plane_available`, `blob_whole_by_url`, `blob_csp_byte_identical`,
  `blob_range_206`, `blob_range_declined_200`, `blob_range_416`, `blob_img`,
  `blob_body_bytes_256mib`, `blob_upload_refused_typed`,
  `blob_foreign_token_unknown`, `blob_released_unresolvable`,
  `blob_window_ok`, `blob_concurrent_bounded`, `blob_asset_unchanged`,
  `blob_reserved_intercepted`, `blob_released_on_navigation`,
  `blob_lifetime_rules`, `pack_refuses_pweb_prefix`,
  `pack_clean_dist_unaffected`, `blob_units_present`. Also on all four:
  `blob_release_order = cap9`, `blob_csp_violations = 0`,
  `blob_namespace = _pweb/blob`, `blob_url_prefix = pweb://app/_pweb/blob/`;
- **one cross-target corpus**: `blob_suite = PASS`, and
  `blob_corpus_digest = 5d0ce4b9ba06421aed2ed67761e11ecbe2066ce930b0f47b9ce17faee1c093bc`
  (31 lines) is identical on Windows, Linux, macOS x64 and macOS arm64.
  `fetch_corpus_digest = 64eb3db2…8176`, the value re-pinned in §8, is equal
  on all four;
- `[CAP-7F] aggregate PASS - platform-matrix.json written`, with the CAP-12B
  fields required and absolute-pinned by the aggregator.
  `capability_policy_digest` (`23b87da5…4bddb2f`) and
  `navigation_policy_digest` (`360d69f2…c7212e`) are equal on all four and
  **unchanged**, so `PWEB_NATIVE_CSP` did not move. CAP-11A reports four
  identical sequences of **207** steps, `CAP11A_SEQUENCE_PASS steps=207
  digest=0379943652198e3a178387454dd08204cafa254bbcc458569e5515bbcafd5a3b`.

The 8 MiB window (entry condition 6.3.3) on the hosted runners, from the same
records. These are **observations, never thresholds**. `asset` is the
ordinary asset request the page launched beside the blob:

| target | `blob_window_ms` | `blob_window_asset_ms` |
|---|---|---|
| windows (WebView2) | 131 | 149 |
| linux (WebKitGTK 2.52.6) | 39 | 3 |
| macos-x64 (WKWebView) | 82 | 95 |
| macos-arm64 (WKWebView) | 205 | 214 |

On the three targets whose engine delivers on the GUI thread (WebView2, and
WKWebView on both Macs), the asset arrives **9–18 ms after** the window. WebKitGTK serves the asset first.
That is the shape §6.3.3 measured on this host (WebView2 38–42 ms, the asset
about 5–6 ms after the window), scaled by slower shared runners. The bound
in this shard is one window; it is not a latency promise.

None of the plane's code has changed since that run. The only later code
change is the CAP-6b4 harness drain above. The ledger rows `12B-1`
(ACCEPTED), `12B-2` and `12B-3` (ROADMAP) stand as written, and `12B-4` is
CLOSED.

**What this shard did.** It turned CAP-12A's decision into a data plane:
bytes the runtime holds for one principal, addressed by a 128-bit token,
served from the reserved prefix `pweb://app/_pweb/blob/<32 hex>` by the *same
production handler that serves the application's assets*, whole or by
`Range`, with `PWEB_NATIVE_CSP` byte-identical on every one of its responses.
The headline consumer is wired: a `pweb.fetch` response too large to inline
is no longer a typed refusal, it is a handle the page reads by URL.

**What it did not do, and both are on purpose.** It added no response
streaming, no `EventSource`, no media promise and no SDK upload API — the
first two were refused by CAP-12A's measurements rather than deferred, and
the upload SDK is CAP-12C's. And it did not move `PWEB_NATIVE_CSP`: that
constant is the premise the whole namespace decision rests on, and two
independent checks in this shard prove it is the same bytes.

**Checkpoint 1 is `cap12b-checkpoint1.md`** and carries the three entry
conditions in full. They are summarised in §1 here because the decisions
below rest on them.

**One hosted run was spent on a claim this shard did not run locally, and it
is recorded rather than tidied away.** Run `35102099474` (commit `7aaf114`)
failed its Windows leg at step 52, the CAP-5 zero-network sweep:

```
FORBIDDEN CAP-5 NETWORK PATTERN: sdk\typescript\src\blob.ts:135: response = await fetch(url, init);
FORBIDDEN CAP-5 NETWORK PATTERN: sdk\pas2js\pweb.native.pas:476: return fetch(AUrl, init).then(...)
FORBIDDEN CAP-5 NETWORK PATTERN: sdk\typescript\src\blob.ts:6:  * `fetch(PUT pweb://…)` ...
```

The first SDK read surface carried a reader beside the handle type, and
CAP-5's bar is that **no SDK source contains a browser network primitive at
all** — comments included, because that sweep does not strip them. The
sweep was right and the surface was wrong: a blob is an ordinary same-origin
resource at `handle.url`, served by the handler that serves the
application's own assets, so the page loads it the way it loads everything
else. The reader is gone from both SDKs; the handle type is what ships, and
it is exactly the "blob URL and handle type" the brief asked for. Contract C4
now reads CAP-5's own pattern back out of its script and applies it to both
SDK files, and its self-test plants a network primitive in `blob.ts` and
requires the refusal. Every script-bodied step of the Windows leg was then
replayed locally from `platform-leg.yml` itself before the next push.

**The same run also found the macOS defect, and it was in the harness build,
not in the plane.** Both macOS legs failed the CAP-12B step while compiling
the live harness:

```
Error: Illegal parameter: -k
```

`build_cap12b.ps1` had hand-typed the Darwin link flags, and a hand-typed
list would also have missed `-k-no_fixup_chains`, without which every
aarch64 link against the webview dylib fails. The script also threw at that
first failure, so the bundler was never built and the pack gate reported a
second red for the same cause. The harness now links through
`tools/macos-buildenv.sh` exactly as `test/cap8b/run_nav_matrix.sh` does
(`pweb_macos_init_fpc`, then `PWEB_MACOS_FPC_FLAGS` and
`PWEB_MACOS_FPC_LINK_BRIDGE`, then the versioned dylib staged beside the
binary). The script now tries every artifact before it fails, and the
harness refuses to create a WebView unless the Cocoa seam reports the FPU
traps masked, as every other Cocoa live harness does. The Cocoa unit is now
type-checked with `-dDARWIN -Cn` on every non-Mac leg, and the live
harness's Darwin branch is type-checked the same way on Linux. That follows
CAP-15B's approach, and both checks pass on this host and under WSL. The
check cannot reach the link itself, which only a Mac performs.

Everything else in that run that reached CAP-12B was green. The **Linux**
CAP-12B step passed on the hosted WebKitGTK (window `50 ms`, asset beside it
`4 ms`). On **macOS arm64**, S1 ran before the link failure and passed with
`blob_corpus_digest = 5d0ce4b9…93bc`, which is byte-identical to Windows and
Linux.

---

## 0. COVERAGE, STATED BEFORE THE CONCLUSIONS

| target | headless suite | live plane | how |
|---|---|---|---|
| **Windows x64 / WebView2** | **MEASURED** | **MEASURED** | this host; `test/cap12b/run_cap12b_gates.ps1`, verdict PASS; and the hosted leg of run `35108018300`, verdict PASS |
| **Linux x64 / WebKitGTK 2.52.6** | **MEASURED** | **MEASURED** | WSL + `xvfb-run`, same gate script, verdict PASS; and the hosted legs of runs `35102099474` and `35108018300`, verdict PASS |
| **macOS x64 / WKWebView** | **MEASURED** on run `35108018300` | **MEASURED** on run `35108018300` | the Objective-C++ seam **and** the Pascal adapter first compiled on the hosted measurement run (`measure-cap12.yml`, run `35089828854`: `pweb_cocoa_bridge.o arch=x86_64 minos=12.0`, 23 073 lines of Pascal); the live harness passed on the hosted CI leg |
| **macOS arm64 / WKWebView** | **MEASURED** on runs `35102099474` and `35108018300` | **MEASURED** on run `35108018300` | seam as above (`arch=arm64`, 19 919 lines); run `35102099474` refused the live harness's link, and the fix is described above |

**The adapters already passed the whole existing matrix on four targets.**
Hosted run `35089829631` on commit `a57b14e` — the store, the translator,
the reserved branch in all three handlers, the grown macOS seam and the host
wiring, before the CAP-12B step existed — was green on all six jobs,
including the CAP-7M runtime gates, the CAP-8B/8C real-window matrices and
the CAP-9C2 real-GUI acceptance on **both** macOS architectures, and the
`cap7 aggregate`. That is the four-target measurement that the branch did
not change a single asset-path behaviour any existing gate observes.

The macOS **engine** rows of §6.3.1 were measured on the hosted measurement
run, through CAP-12A's instrument. The CAP-12B **live harness** on those two
targets was measured by the hosted CI legs of run `35108018300`, recorded in
the closure record above.

---

## 1. THE THREE ENTRY CONDITIONS (§6.3)

Full tables in `cap12b-checkpoint1.md`. In brief:

**6.3.1 — the four macOS rows are MEASURED on both architectures**, on
hosted measurement run `35085891349` (commit `ef6a6b1`), macOS 15.7.9, Apple
clang 17.0.0. `Range` reaches the handler through `allHTTPHeaderFields` (36
requests); a 206 with `Content-Range` on an `NSHTTPURLResponse` is read back
by `fetch()`, offset-verified, for `a-b` and for `-suffix`; a typed-array
body arrives as **`HTTPBody`** at 1, 16 **and** 256 MiB, byte-exact and
pattern-verified, with `HTTPBodyStream` **nil in every case**; a whole 8 MiB
body served synchronously returns 200 in 85.0 ms (x64) and 25.0 ms (arm64).
`stop_arrivals = 0` and `handler_calls_off_main_thread = 0` on both, even
though that instrument *does* defer delivery — so §6.5's conclusion holds
with room to spare.

**Its first run produced measurements instead of a stack trace because two
defects were found by reading the never-compiled probe first**: `usleep()`
with no `<unistd.h>` (a compile error in C++), and `[NSApp terminate:]`,
which calls `exit()` so `-[NSApplication run]` never returns and the JSON the
instrument exists to write is dead code. Recorded rather than tidied away.

**A finding CAP-12A could not have.** On WKWebView a `Blob`, a `File` and a
`FormData` request body arrive as **neither `HTTPBody` nor `HTTPBodyStream`**:
the handler is entered, the request carries no body, and the page gets a
successful response describing **zero bytes**. No crash, no diagnostic. That
is *worse* than the WebKitGTK fault, because a fault is visible — and it is
why "never a `Blob`, a `File` or a `FormData`" is now justified on three
engines rather than one.

**6.3.2 — the CI baseline is the same version and the same fault.**
`ubuntu-24.04` resolves `webkit2gtk-4.1` at **2.52.6** (typed row, run
`35089828854`; the fault rows themselves were identical on run
`35085891349` before it), and
`webkit_uri_scheme_request_get_http_body()` faults for all three blob-backed
kinds while typed arrays at 1, 16 and 256 MiB go through the same call
byte-exact. So the branch §6.3.2 named is taken: **the workaround ships and
the UPSTREAM report is written** —
`docs/upstream/webkitgtk-uri-scheme-request-get-http-body-blob.md`, claiming
a version range of exactly **2.52.6 on two independent hosts** and nothing
wider.

**6.3.3 — the 8 MiB window against a REAL store confirms §5.3's arithmetic
and does not force a file-backed store.** Through the production handler
against `TPWebMemoryBlobStore` on WebView2, over four runs: the 8 MiB blob
arrives page-side in **38.2 / 38.5 / 40.0 / 41.8 ms**, and an ordinary asset
requested in the same turn arrives **~5–6 ms after it** — it waited, which is
the serial drain CAP-12A measured at 256 MiB, now costing milliseconds
instead of 3.6 seconds. On WebKitGTK the same asset arrives *before* the blob
(16 ms against 30 ms), because that engine interleaves. §5.3 projected
~45 ms; the real store gives 38–42. **The window bound stands and v1 ships
memory-backed.**

---

## 2. STORE AND SEAM

Three new units, beside the asset units, naming no URI scheme:

| unit | what it is | layering |
|---|---|---|
| `src/assets/pweb.blobs.intf.pas` | CAP-12A §5.1 **verbatim** — `TBlobInfo`, `IBlobReader`, `IBlobWriter`, `IBlobStore` — plus the two supporting interfaces and the ceilings record | `mormot.core.base` only, mirroring `pweb.assets.intf` |
| `src/assets/pweb.blobs.memory.pas` | the v1 store: thread-safe, owner-scoped, refcounted readers, ceilings | RTL + `mormot.core.base` + `mormot.crypt.core` |
| `src/assets/pweb.blobs.protocol.pas` | the translator — the ONE unit that knows both spellings | RTL + `mormot.core.base` + the contract. **No crypt**, which is what keeps the three adapters inside the CAP-4 isolation compile |

**The ratification is verbatim and it is machine-checked.** `check_cap12b_contracts.ps1`
C6 compares the ten ratified signatures *and their order*, and `TBlobInfo`'s
four fields; a method added, removed or reordered is a contract change that
has to be ratified rather than committed.

**Two supporting interfaces, and why they are not an eighth boundary.**
`IBlobBounds` and `IBlobStoreRuntime` belong to the `IBlobStore` boundary in
exactly the sense `pweb.rpc.intf`'s own header already fixes for
`ICancellationToken` and `IInvocationSource`: *"supporting interfaces belong
to those boundaries; they do not create new top-level boundaries."*
`IBlobStore`'s ratified method set is untouched. They exist because a
producer needs **which ceiling refused it**, decided inside the same lock
that refused — a query followed by a create would report a number that had
already moved — and because the host needs to END the plane in the CAP-9
order without depending on a concrete store.

**What makes a read lock-free is a property, not an optimisation.** A blob is
unreadable until sealed, and sealing is its last write, so a reader takes its
own reference to the immutable `RawByteString` at open time and never touches
the store again. Two contract requirements fall straight out: `Release` makes
the token unresolvable *at once* (one flag under the lock) while the bytes
live exactly as long as some reader holds them, and `ReadAt` cannot block the
engine's thread on a store lock — which matters because on WebView2 the
resource handler runs on the host's GUI thread.

**The ceilings, with the arithmetic** (all five in
`PWebBlobDefaultLimits`, and every one proven to FIRE on a store built with
ceilings small enough to reach):

| bound | value | derivation |
|---|---|---|
| largest blob | **8 MiB** | the window §5.3 bounds a response to, `PWEB_FETCH_MAX_RESPONSE`, and §5.3's upload chunk — one number, three uses. Making the largest blob *equal* the window is what lets a whole-body request always be answered without ranging |
| bytes per principal | **64 MiB** | 8 × the largest blob. Serving one window costs 2× the window (MEASURED, both engines), so a principal at its ceiling with one window in flight is 80 MiB — an order of magnitude below the 2 048 MiB one 256 MiB body cost a WebView2 process |
| blobs per principal | **128** | 16 × the eight largest-possible blobs. The byte ceiling bounds memory; this bounds bookkeeping. For the headline consumer bytes bind first: `pweb.fetch` only reaches the plane above the 1 MiB inline cap |
| bytes in total | **256 MiB** | 4 × per principal, so four principals reach their own ceiling before the total binds and the fifth is refused **by name**. It is also the largest single body M3 measured crossing both engines intact |
| blobs in total | **512** | 4 × per principal, the same factor |

**Two defects the suite found in the store on its first run, both fixed.**
A blob created with a `SizeHint` was allowed to **grow past its reservation**
— so a reservation was not a ceiling at all — and a blob created *without*
one could walk past `MaxBlobBytes` in increments that each fit, because
growth charged only the increment. Both are now refused, and the suite pins
each.

---

## 3. HANDLER BRANCHES

The same shape on all three engines, and the ORDER is the whole reservation:

```
  native request
    -> PWebParseAppUri                      (frozen, unchanged)
    -> PWebBlobIsReserved(logicalPath)?      <-- BEFORE any store
         yes -> read method, Range, (body) -> PWebBlobServe -> answer
         no  -> IAssetStore.TryRead          (frozen, unchanged)
```

| engine | Range | method | request body | response |
|---|---|---|---|---|
| **WebView2** | `ICoreWebView2HttpRequestHeaders.GetHeader` — three vtable slots promoted from never-called stubs, in the pinned 1.0.1587.40 order | `get_Method` | `get_Content` → `IStream.Read`, drained in 256 KiB chunks, bounded at 512 MiB | `CreateWebResourceResponse` with the status and an extra header block appended AFTER the policy |
| **WebKitGTK** | `webkit_uri_scheme_request_get_http_headers` + `soup_message_headers_get_one` | `..._get_http_method` | `..._get_http_body` → `g_input_stream_read`, same bounds | `webkit_uri_scheme_response_set_status` through **one** response path shared with the asset branch |
| **WKWebView** | `[[task request] allHTTPHeaderFields]` | `HTTPMethod` | `HTTPBody` — passed across the seam as a **pointer into the engine's own `NSData`**, so a 256 MiB upload is not copied | the `NSHTTPURLResponse` the adapter already built, now with a status |

**The macOS seam grew, and it grew by one struct and three fields** — a
`pweb_cocoa_request_t` in, and `status` / `reason` / `extra_headers` out.
There is still exactly ONE callback out of the bridge. `status <= 0` reads as
200 on the bridge side, so a path that fills nothing serves what it always
did; the asset branch fills it anyway, so one reader of that record never has
to know which branch wrote it.

**A path that would have been taken silently is written and bounded anyway**:
`pweb_drain_body_stream` handles an `NSInputStream` body. The measurement says
it is never taken — `HTTPBodyStream` was nil at every size — and the comment
says so, so that an engine change becomes a bounded read rather than a body
that silently arrives empty.

**On WebKitGTK the response tail became ONE function.** Before this shard
there was one kind of response to build, so it was built inline; the blob
branch adds four statuses and three headers, and a second copy of that
sequence is how two answers on one engine start disagreeing about which
headers ride which response. The asset path calls it with 200/`OK` and an
empty extra set, which reproduces the previous bytes — and the CAP-4/7L
corpora are what check that it does.

---

## 4. TRANSLATOR AND RANGE

`pweb.blobs.protocol` is the only unit in the tree that knows both the
reserved URL namespace and `IBlobStore`. The contract gate C7 refuses a
`pweb://` or `_pweb` in the contract unit and in the store, and B1 measures
that the URL prefix is concatenated in **exactly one file**.

**The ratified grammar — one rule on four engines:**

| header | answer | reason |
|---|---|---|
| absent | 200 whole | |
| `bytes=a-b` / `a-` / `-suffix` | **206** + `Content-Range` + `Accept-Ranges: bytes` | the measured guaranteed surface |
| multi-range | **200 whole** | RFC 7233 §3.1 permits ignoring a Range; a 206 carrying only the first window would lie about what was asked, and `multipart/byteranges` is a second body format the plane refuses to own. Safe here because a blob is at most one window |
| malformed (`bytes=abc`, `a>b`, two dashes, unknown unit, over 256 bytes) | **200 whole** | an invalid byte-range-spec invalidates the header |
| unsatisfiable (first past the end, suffix length 0, any range on an empty blob) | **416** + `Content-Range: bytes */<total>` | a page BUG, and a whole body in reply is indistinguishable from success. `Accept-Ranges` **stays**: what was wrong was the range, not the capability |

A `count` over the window bound is clamped and the `Content-Range` reports
what was actually sent — legal, and in v1 unreachable because the largest
blob equals the window. The clamp exists in ONE place so a later shard that
raises the blob ceiling does not have to rediscover where the window is
bounded.

**Methods.** `GET` is served. **Everything else is `405` with `Allow: GET`,
after the adapter has drained the request body** — and the refusal carries a
receipt: `{"error":"blob_upload_not_enabled","method":…,"requestBodyBytes":…,
"requestBodyCrc32c":…,"requestBodyComplete":…}`. CAP-12A §6.2 ratified
`fetch(PUT …)` with a typed-array body as the JS→native transport; CAP-12B
**builds and proves that path on three engines and wires no consumer onto
it**, because the SDK upload API is CAP-12C's. A body path that is never
drained is a body path that has never run, so it is drained — and the count
and checksum make the refusal a measurement rather than a shrug.

---

## 5. FETCH INTEGRATION

`TPWebFetchBridge` gains one constructor overload and one field.

- body ≤ the inline cap → **unchanged**, and `"blob":null`.
- inline cap < body ≤ `PWEB_FETCH_MAX_RESPONSE` **with a blob store**:
  a **success** carrying
  `"blob":{"token":…,"url":"pweb://app/_pweb/blob/…","size":…,"type":…}`,
  `bodyText` and `bodyBase64` both null, `bytes` still the wire length,
  `truncated` still false. The type is the response's own `content-type`
  (control bytes and over-length refused), never the MIME table.
- the same range **without** a store → `response_too_large_to_inline`,
  **byte for byte what CAP-15B always answered**. That is what makes this
  additive rather than a contract change for every host that ships today.
- a ceiling → a typed `service_error` naming **which** ceiling
  (`blob_owner_bytes_exceeded`, `blob_total_count_exceeded`, …), never the
  too-large-to-inline refusal in disguise: a page that hit a ceiling has a
  different problem from a page whose response was simply too big.
- above the response ceiling → the transport stops the read as it always
  did; nothing over the ceiling reaches the plane.

`blob` is in **every** envelope and null in all but one case. A field that
appeared only sometimes is a field every caller has to feature-detect, and
the SDK would then be describing two shapes of success.

**The second consumer, images by URL, needs no code**: an `<img src>` on a
blob URL is an ordinary same-origin request through the same handler, and it
is measured decoding on both reachable engines and on both macOS targets.

**The SDK read surface is the handle type and nothing else** —
`PWebBlobHandle` and the shape check `isPWebBlobHandle` in `@pweb/runtime`,
`TPWebBlobHandle` in the Pas2JS SDK, and the `blob` member on both fetch
response types. Neither SDK loads a blob and neither builds a URL: the page
loads `handle.url` the way it loads anything else it ships, which keeps
CAP-5's rule that no SDK source contains a network primitive. The runtime's
answers to a ranged load (206, 200-declined, 416) are documented on the type.

---

## 6. SECURITY PROPERTIES, EACH WITH ITS PROOF

| property | proof |
|---|---|
| a token is 128 bits, never enumerable, never listed | `Random128` (AES-CTR), 32 lowercase hex; contract C5 refuses `TLecuyer`, `Random32` and any listing method on `IBlobStore`; the suite mints 256 tokens and requires no collision and no constant |
| a foreign token and an unknown token are indistinguishable, **timing bounded** | the store's scan does **not short-circuit** and the owner comparison runs whatever the scan found, over a constant-time byte walk; the suite MEASURES 20 000 lookups of each and requires the two within a factor of four. Live: the two 404s are compared to *each other* — same body, same type, same reason |
| `Release` makes the token unresolvable at once; bytes go with the last reader | the suite releases a blob a reader is holding, requires the token to stop resolving immediately, requires that reader to read its whole body afterwards, and requires the entry and its charge to disappear when the reader goes |
| a scheme task mid-window never reads freed memory | structural: the reader holds the `RawByteString`, not the store's slot. The suite drives it through `Close` |
| the handler is detached before the store is released | the host closes the plane at the `BeforeDrain` position and drops the reference only after `assetHandler.Detach`; the live harness owes the same order and asserts the store holds nothing afterwards (`blob_release_order = cap9`) |
| every blob of a window released on navigation / reload / generation switch | the production `PWebNavTrustedDocumentHook` calls `ReleaseOwner` **first**, before anything else learns the document is changing. The live page reloads itself and checks **each** phase-1 token in its second document: four of four gone, on both targets |
| released on shutdown BEFORE binding close and scheduler drain | the host's sequence, unchanged except for one call prepended; the suite pins the order through `IBlobStoreRuntime.Close` |
| released on revocation before the revoking call returns | the policy's notification carries the principal id and nothing else, so the release **is** `ReleaseOwner` — the same call a document replacement makes |
| ceilings hit → typed `service_error` naming which ceiling, never native text | `PWebBlobCeilingCategory`; six categories; the suite fires all five bounds and the fetch-door case asserts the named category reaches the envelope |
| the CSP and `PWebNativeSecurityHeaders` ride **every** blob response, 206 and 416 included; `Cache-Control: no-store` | the live gate compares the CSP of the 200, both 206s, the 200-declined, the 416, the 405 and two 404s **against the shipped constant** and requires byte identity, and requires zero `securitypolicyviolation` events |
| a bundle cannot carry `_pweb/`, and the branch intercepts before any store | pack: a planted dist is refused with `reserved_prefix_in_bundle` naming the file, and the same dist without the plant packs. Serve: `reserved_not_a_blob` gets the branch's 404, and contract C1 compares the *offset* of the reserved test against the *offset* of the asset-store call in all three adapters |
| the blob branch does not weaken the frozen asset path | the live gate requires an asset response beside a blob response to carry its old content type, `no-store`, and **no** `Accept-Ranges` and **no** `Content-Range`; the CAP-4/4W/7L/7M corpora and the 2 703-assertion core suite are unchanged |

---

## 7. PACK RESERVATION

`pwebbundle` refuses any logical path whose first segment is `_pweb`, in the
CAP-14A shape — a typed cause, the file named, every offender reported before
anything fails — and **with no override**, which contract C8 pins by name. It
is a walk-time PATH rule, deliberately not in the CAP-14A HTML tokenizer: that
scanner decides which HTML *constructs* the native CSP would refuse, and a
document referencing `pweb://app/_pweb/blob/…` in a `src` is a same-origin
relative reference it accepts and should.

Proven to fire, and proven not to over-fire: the gate plants
`_pweb/blob/planted.bin` in a dist, requires the refusal and requires no
output file; then removes the plant and requires the same dist to pack.

---

## 8. SUPERSESSIONS, RECORDED OLD → NEW

| what | old | new | why |
|---|---|---|---|
| `fetch_corpus_digest` (CAP-15B) | `526789b249f1bedba2570482207adffa1d0fcc918623f7ff988cfbfd6de0a381` | `64eb3db2db4bf586c2739892b9cc320661e53eb9def9fc690cd16dd35cfe8176` | the envelope corpus now pins `"blob":null` in every envelope. 145 lines before and after |
| CAP-15C K15 pin of `src/rpc/pweb.rpc.fetch.pas` | `82aedb926a8a6a77633a6eb82aa3da74a285365602cd44101ce054960e4ec5fb` | `a158a35aaf247f0c494b779d08953eb10ca38af57144d7fd8d917cebe8ff50e9` | the fetch door is the headline consumer of the plane |
| the one CI sequence | 206 steps | **207** | one step added after CAP-15C: `CAP-12B blob data plane gates (S1, L1, P1, B1, C1-C9) + evidence` |
| `ci_sequence_digest` | `b9e904096532204c5013e86f9d24eb6acf5120ea3e579fac98c1fab3e58533d0` (206 steps; main run `35062557082` on `6f78477`, this branch's base) | `0379943652198e3a178387454dd08204cafa254bbcc458569e5515bbcafd5a3b` (207 steps; run `35108018300`, four identical sequences) | the same added step |
| `test/cap11a/step-applicability.tsv` | 206 rows | **207** | the same step, four targets, unconditional |
| CAP-12A containment claim §5c(1) | *no file under `.github/` may name `test/cap12a`* | *no file of the ONE STEP SEQUENCE may; `.github/workflows/measure-cap12.yml` is the one named exception, and three new assertions hold it to being dispatch-only and uncallable* | two of the three entry conditions need a macOS or a baseline-WebKitGTK host the dev machine does not have. The claim that mattered — a GATE must not put a throwaway store behind the production seam — is unchanged and now stated exactly |
| `cap12a_named_in_ci` | empty | `.github/workflows/measure-cap12.yml` | the same narrowing, as the evidence row reads it |
| backlog negative self-test | 23 perturbations | **26** | three new legs: the measurement workflow becoming callable, losing its button, or being referenced by the sequence |
| the three platform adapters | — | **each gained a branch**, and this row says so rather than "unchanged" | `pweb.platform.webview2.pas` (three vtable slots promoted, one branch, one header helper), `pweb.platform.webkitgtk.pas` (three imports, one branch, the response tail factored into one function), `pweb.platform.cocoa.pas` + the private C seam (one in struct, three out fields, one branch) |
| `navigation_policy_digest` | `360d69f282e9d8b053d1ef8a5052f76860875c723b9e6512b0d38685f0c7212e` | **byte-identical**, re-measured on this host | `PWEB_NATIVE_CSP` did not move. It is the premise the namespace rests on |
| `capability_policy_digest` | `23b87da524b158f4b1a8ca53057ad794f485086257997534b426b28334bddb2f` | **byte-identical**, re-measured | the CAP-8A corpus gained nothing |
| the WebKitGTK upstream row | `12A-1`, report owed once the version range was pinned | **written**: `docs/upstream/webkitgtk-uri-scheme-request-get-http-body-blob.md`, range exactly 2.52.6 on two independent hosts | entry condition 6.3.2 |

**One supersession the brief anticipated did NOT happen, and it is worth
saying why.** The CAP-15B envelope corpus did not move *of its own accord*:
that suite builds its decorator with no blob store, so its envelopes are the
CAP-15B envelopes byte for byte. The digest above moved because the corpus
gained a deliberate row pinning the new `blob` member — recording the change
rather than discovering it later.

---

## 9. REGRESSIONS, RE-MEASURED ON THIS HOST

| gate | result |
|---|---|
| core suite (`test/core/pwebtests`) — CAP-4 assets, CAP-8A capabilities, CAP-8B navigation, the asset corpora | **0 / 2 703 assertions failed** |
| `navigation_policy_digest` | `360d69f2…c7212e`, **unchanged** |
| `capability_policy_digest` | `23b87da5…4bddb2f`, **unchanged** |
| CAP-7F divergence sweep | PASS — 222 platform conditionals, all inside the allowlist |
| CAP-7F always-false conditional sweep | PASS — 206 symbols, 99 files, 0 hits |
| CAP-7F schema agreement | PASS — 916 fields, both emitters, zero asymmetry |
| CAP-11A CI structure | PASS |
| CAP-11A migration map | PASS — 445 legacy, 342 bodies, 103 uploads |
| CAP-11B watcher contract | PASS — 22/22 perturbations refused |
| CAP-14A contracts + gates | PASS |
| CAP-14B contracts | PASS |
| CAP-15B contracts + gates (incl. the live TLS pair) | PASS |
| CAP-15C contracts | PASS — with K15 re-pinned, above |
| CAP-10A / B0 / B1 (+ the private build proof and real GUI run) / C0 / C1 / C2 / D0 / D1 / D2 contracts + gates, **Windows** | PASS |
| CAP-10A / B0 / B1 (+ proof) / **B2** (+ proof) / C0 / C1 / C2 / **C3** contracts + gates, **Linux** | PASS, in a copy inside the Linux filesystem — `pweb create` cannot run on `/mnt/c` |
| backlog gate | PASS — 0 violations |
| backlog negative self-test | **26/26 perturbations refused** |
| CAP-5 zero-network sweep, protocol cross-check, both SDK suites (TypeScript 29 tests, Pas2JS 72/72) | PASS — after the reader was removed (above) |
| CAP-12B contracts | PASS — **5/5 perturbations refused** |
| CAP-12B gates, Windows | PASS |
| CAP-12B gates, Linux (WSL + xvfb) | PASS |
| CAP-12B Darwin type check (`-dDARWIN -Cn`) | PASS — the Cocoa unit on Windows and Linux, and the live harness on Linux |
| CAP-6b4 profile matrix drain before S5/S6 (`12B-4`) | CAP-11A FL2, CAP-6b4 and CAP-6b1 contracts PASS. The drain's wait and terminate branches were both exercised against a real in-root process. The matrix itself installs and uninstalls on the machine and runs on the hosted Windows leg |

The two CAP-12B corpus digests agree across targets to the byte:
`blob_corpus_digest = 5d0ce4b9ba06421aed2ed67761e11ecbe2066ce930b0f47b9ce17faee1c093bc`,
31 lines, on Windows **and** Linux.

---

## 10. FREEZE — §6.4, VERBATIM AND HELD

- `webview.lock`, `mormot.lock` and every other pin: **untouched**.
- `src/lib/` and `webview.chet`: **untouched**.
- the seven interface signatures beyond ratifying `IBlobStore`'s method sets:
  **untouched**. `IAssetStore.TryRead` and `TAssetResponse` are byte-identical
  — the Phase-0 freeze sweep compares them against the baseline commit.
- `pweb.rpc.intf.pas`'s independence from every `pweb.webview.*` unit:
  **untouched**.
- **`PWEB_NATIVE_CSP`: byte-identical**, checked twice — by contract C2
  against the ratified constant, and by `navigation_policy_digest` measured
  from the corpus.
- the watcher, the licence set: **untouched**.
- `test/cap12a/` as a CI step: **still not one.** It is named by exactly one
  file under `.github/`, the dispatch-only measurement workflow, which is
  held to that by three new assertions in the backlog gate.
- the nine-code error taxonomy and `PWEB_PROTOCOL_VERSION = 1`: **unchanged**
  — every blob refusal is `service_error` with a category in `data`, which is
  the sanctioned channel.

---

## 11. KNOWN LIMITATIONS

1. **The 8 MiB window is bounded, not fast.** On the engines that deliver on
   the GUI thread, an asset requested beside a blob waits for that one
   window: 9–18 ms behind it on the hosted runners, where the window itself
   took 82–205 ms. `blob_window_ms` is recorded as an observation on every
   leg and is not gated.
2. **`HEAD` is not served.** It is answered `405` with `Allow: GET`. v1
   promises `GET`, because a `HEAD` with a declared length and no body is a
   shape no engine here has been measured on.
3. **One blob is at most one window (8 MiB).** The ranged read path is built
   and proven, so a later shard raises the ceiling and gets ranging for free;
   it should raise it together with a file-backed store.
4. **There is no upload consumer.** The transport is built, drained and
   proven byte-exact on three engines, and then refused by name. CAP-12C
   turns the refusal into a store write and adds the SDK.
5. **Media by URL is not promised** — WebKitGTK refuses a custom-scheme media
   resource outright (CAP-12A `12A-3`), so any exposure is a typed per-engine
   capability a page must do without.
6. **A ceiling refusal is best-effort about *which* ceiling under
   concurrency** only in the sense that the store answers from the state at
   the instant it refused; the decision and the naming happen in one lock, so
   the category is never a second look at a moved number.
7. **The `blob` member is now in every fetch envelope.** Applications that
   parse the envelope strictly will see a new null field; the SDK types carry
   it and the CAP-15B corpus pins it.

---

## 12. VERDICT

```
CAP-12B NOT READY
```

- **§6.1's eight items** are built and measured on four targets.
- **The three entry conditions** are measured and recorded.
- **Both consumers are wired:** large `pweb.fetch` responses come back as a
  blob handle, and `<img>` loads by blob URL.
- **Every security property** has a proof rather than an argument.
- **The regressions are green.** Both frozen policy digests are
  byte-identical on all four targets.
- **The supersessions** are recorded old → new.
- **Hosted CI was green on implementation commit `5e4554b`** (run
  `35108018300`), with its substance checked against this document, not
  just its green status (top).

**Missing: a green hosted run on the final HEAD.** The run after
`35108018300` was red on Windows in CAP-6b4 (`S6: setup exited 5`), which is
the pre-existing D1-16 race, now fixed in the harness (`12B-4`). The verdict
becomes `CAP-12B PASS — BLOB DATA PLANE FROZEN` when the run on the HEAD that
carries that fix is green and its substance has been checked.

CAP-12C is not begun.
