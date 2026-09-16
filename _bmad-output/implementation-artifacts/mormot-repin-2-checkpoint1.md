# MORMOT-REPIN-2 — Checkpoint 1: measured, nothing moved

Branch `phase/post-mvp/mormot-repin-2`, cut from `main` at
`4aed789bb029fb5f4e2bd4d14749268a7d82358a`. CAP-12B had already merged when
the branch was cut (`phase/cap-12/b-blob-data-plane` is an ancestor of
`main`), so no rebase was owed.

**What "nothing moved" means here.** No contract, digest, gate or ledger row
was changed to reach these numbers. The one commit on the branch at this
checkpoint, `291eb32d0c6feb9f1f414f91e9afe54cf8953e07`, changes the `commit =`
line of `mormot.lock` and nothing else. It is the measurement vehicle: the
two macOS targets can only be reached through a hosted run, and a hosted run
builds whatever the lock names. Its run, **35141256648**, is expected to go red
at the first pin-derived literal (CAP-9C1 C30), and it did on Windows and
Linux — after the Currency step had run on every leg.

Hosts: the Windows dev host (FPC 3.2.2 x86_64-win64, the toolchain `fpc.lock`
pins for the hosted Windows leg; MSVC from Visual Studio 18), and WSL
Ubuntu-24.04 (FPC 3.2.3, WebKitGTK 2.52.6, Xvfb, Node 24.11.1) in a fresh git
clone of the branch so its line endings are a CI checkout's, not a Windows
one's.

---

## M1 — the candidate

The three hashes in the brief were resolved in the upstream tree, not trusted:

| brief | resolves to | committed (author date) | subject | on `master` | descends from `da7e1c2f` |
|---|---|---|---|---|---|
| `6a27c07fc6c9` | `6a27c07fc6c9f796711076561c293e68eb6b6398` | 2026-09-16 12:13:13 +0200 | core: fixed currency result in mormot.core.interfaces | yes | yes |
| `37fa86b45` | `37fa86b451304c15bacd34cf673cb4f0c40f0235` | 2026-09-16 12:59:49 +0200 | lib: fixed JS_SetMaxStackSize() definition | yes | yes |
| `66d7d51c1` | `66d7d51c1fd21bd222b360382ed8e2b4f656aaad` | 2026-09-16 13:16:20 +0200 | lib: fixed pas_malloc() wrapper definition | yes | yes |

`6a27c07f` and `37fa86b4` are both ancestors of `66d7d51c`, and `66d7d51c`
is on `master`'s **first-parent** line (16th from the tip when measured;
`da7e1c2f` is 122nd). So the smallest commit on the line the pin sits on that
carries all three is **`66d7d51c1fd21bd222b360382ed8e2b4f656aaad`** itself —
`2.4.16907`, `git describe` `2.4-stable-2584-g66d7d51c1`. The next seventeen
commits on `master` (TLS 1.3, futex shutdown, TSynLog) are not taken.

### The delta from `da7e1c2f`

106 first-parent commits; 41 files, +4108 / −985.

| area | files | lines | what matters to PWeb |
|---|---:|---:|---|
| `src/core` | 14 | +2717 / −672 | `mormot.core.interfaces.pas` +7/−5 (the Currency fix, and `a5b75dde` int64 clamp refactoring); `mormot.core.base.asmx64.inc` +1258/−8 (SSSE3 JSON number parsing — new x64 asm, which is why the Win64 unwind gate and the whole Windows chain were re-run rather than assumed); `datetime`, `text`, `variants`, `unicode`, `fpcx64mm`, `os`/`os.posix.inc` refactoring |
| `src/lib` | 3 | +18 / −16 | `mormot.lib.quickjs.pas` +10/−11 — **only** `37fa86b4` and `66d7d51c`; `mormot.lib.static.pas` +7/−4 (`66d7d51c`); `mormot.lib.openssl11.full.inc` 1 line |
| static bindings (`static/`) | 0 | — | byte-identical, `dev.sha256` included |
| `res/` | 3 | +13 / −13 | `res/static/liblizard/lib/{fse,huf,lizard_common}.h` — prototype text only (`int` → `size_t`), from `66d7d51c`. `res/static/libquickjs` untouched |
| the QuickJS binding's other half, `src/script` | 0 | — | untouched |
| `src/mormot.defines.inc`, `mormot.uses.inc` | 0 | — | untouched (so `test/cap7f/mormot-defines.tsv` holds) |
| `src/net`, `src/crypt`, `src/db`, `src/orm` | 14 | | TLS/DNS/DHCP/SQL work; `mormot.net.sock.posix.inc` and `mormot.net.http.pas` are on CAP-15's path and are covered by its gates |
| `test/` (upstream's own) | 5 | | not compiled by PWeb |

### Statics

**No second pin.** `static/` is byte-identical between the two commits.
`2.4-stable` is still the newest release (`gh release list`), its
`mormot2static.tgz` asset reports `updated_at` 2026-01-12T18:35:58Z and a
GitHub digest equal to the pin, and a fresh download on 2026-09-16T19:25Z
hashed to `ae2d8da212c5b4f2778370de7aee965f7fd82eef911da27eeb797d6db06db449`
over 33 675 498 bytes.

One thing about the statics is worth writing down and is **not** a reason to
move them: `66d7d51c` changed the liblizard **header** prototypes to `size_t`,
and the pinned archive's `liblizard.a` was built from the old `int` ones. PWeb
uses no `mormot.lib.lizard` unit (the one reference in `mormot.core.buffers`
is a comment), and the Win64 link map of the CAP-9A harness names no lizard
symbol at all. The QuickJS objects the archive carries were already compiled
against a `size_t` `cutils.h`, which is the whole of `9A-4`.

---

## M2 — Currency, unpatched, four targets

`test/cap3u/cap3u_currency.pas`, five cases over arities 0/1/2, through a real
in-process `TRestServer.Uri()`, on the candidate with nothing applied:

| target | compiler | where | at `da7e1c2f` | **at `66d7d51c`** |
|---|---|---|---:|---:|
| windows-x86_64 | FPC 3.2.2 x86_64-win64 | dev host; hosted run 35141256648 job 104946058896 | 5/5 | **5/5** |
| linux-x86_64 | `3.2.2+dfsg-32` | hosted run 35141256648 job 104946058471 | 1/5 | **5/5** |
| linux-x86_64 | FPC 3.2.3 | WSL | 1/5 | **5/5** |
| macos-x86_64 | FPC 3.2.2 [2021/05/16] x86_64 | hosted run 35141256648 job 104946058765 | 1/5 | **5/5** |
| macos-arm64 | FPC 3.2.2 [2021/05/16] aarch64 | hosted run 35141256648 job 104946058773 | 0/5 | **5/5** |

The `da7e1c2f` column is hosted run 34241426338.

**Why the SysV cases now pass**, from the diff rather than inferred from the
count. On FPC POSIX x64 the asm now does `cmp cl, imvCurrency / jne @e /
fistp qword [r12].res64`: FPC leaves a `Currency` result in x87 ST0, as its
scaled `Int64` loaded with `fild`, and `fistp` of an exact 64-bit integer is
exact. That also explains the one case that used to pass: in `cur-zero-arg`
RAX still held the integer FPC had just loaded into ST0. `FPCPOSIX` is defined
for every non-Windows FPC target (`mormot.defines.inc:317`), Darwin included.
On AArch64 the `cmp x15, imvCurrency / b.eq float_result` pair is gone, so the
x0 value the stub already stored is kept instead of being overwritten from d0.

**The Win64 half did not move.** Dev host and hosted run agree: one
RUNTIME_FUNCTION on CallMethod (`00053560..000535EF` locally,
`00054A80..00054B0F` hosted), unwind info inside the mapped `.xdata`, RBP
`SET_FPREG`, RBP/R12 saved, and the unwind matrix **12/12**; `cap3tests`
193/193.

---

## M3 — `JS_SetMaxStackSize` without the shadow

The candidate declares `procedure JS_SetMaxStackSize(rt: JSRuntime;
stack_size: PtrUInt)`. With the re-declaration deleted from
`src/script/pweb.script.quickjs.pas` and `ApplyLimits` calling the pinned
import with `FEngine.rt`:

| gate | Windows | Linux (WSL) |
|---|---|---|
| CAP-9A — q20 loop interrupted, q22 recursion safe, q23 oom safe, q23 engine destroyed on its owner | PASS | PASS |
| CAP-9B1 | PASS | PASS |
| CAP-9B2 — the limit/taint rows (`StackLimitBytes` 128 KB) | PASS | PASS |
| CAP-9C1 | PASS once C30's pin prefix is updated (below) | PASS, same |
| CAP-9C2 real GUI | PASS once the `LICENSE.quickjs` pin is updated | PASS, same |

**The call site is a compile-time gate, and it was observed firing.** FPC
keeps `JSRuntime = ^TJSRuntime` and `JSContext = ^TJSContext` distinct. The
unit was compiled against a scratch copy of the candidate's `src/` whose
binding had the old `ctx: JSContext` first parameter written back:

```
pweb.script.quickjs.pas(964,34) Error: Incompatible type for arg no. 1: Got "JSRuntime", expected "JSContext"
```

and against the candidate itself it compiles clean (167 995 lines). So an
upstream revert cannot pass silently through any leg's compile, and the
runtime rows above are the other half.

**The CAP-9 corpora did not move** although the binding source did:

| corpus | frozen | Windows | Linux |
|---|---|---|---|
| `quickjs_corpus_digest` | `601b86ffd24d5642174758120d58d240da6e5cc0d4e0cc3a40b3ec0847e7909f` | same | same |
| `quickjs_package_digest` | `4b01cf06677ff52fb26c74b031c72282258f26b7c5b44bd44131586c77209c45` | same | same |
| `quickjs_lifecycle_digest` | `6c8d0bd7147cadb384ff06e8841b17212a6a1fa550a978c31d23ba1f1a785131` | same | same |
| `quickjs_release_digest` | `04c2db17eebfc48a9486d318b1c12586898a3c81952122c8e354577fcfc769fd` | same | same |
| `quickjs_gui_digest` | `1c88bda98dd369abba75659951ce38f848515959c41ce759429ac43e7658fdb8` | same | same |

---

## M4 — the `pas_*` types

The candidate's `mormot.lib.static.pas` exports `pas_malloc(size: PtrInt)`,
`pas_calloc(n, size: PtrUInt)` (now refusing an overflowing product),
`pas_free`, `pas_realloc(P; Size: PtrInt)` and
`pas_malloc_usable_size(P): PtrUInt`. **The brief says PtrUInt; the tree says
PtrInt for `pas_malloc`.** That is signed where `size_t` is not, and it is not
a finding that blocks anything: the defect `9A-4` described is the WIDTH, a
32-bit read of a 64-bit argument, and the width is fixed. The Win64 link map
of the CAP-9A harness shows it in the binary:
`pas_malloc$int64$$pointer` and `pas_malloc_usable_size$pointer$$qword`.

**Did PWeb carry a workaround? Confirmed: not on the targets that link
`mormot.lib.static`.** Windows and Linux call upstream's family and always
did. What PWeb does carry is the aarch64-darwin export block — and that is a
**provision, not a workaround**: `mormot.defines.inc:1062` still defines
`NOLIBCSTATIC` for Darwin on a non-Intel CPU at the candidate, so upstream
still ships no family there and the block stays. It had been widened ahead of
upstream in CAP-9A, except `pas_malloc_usable_size`, which still returned
`integer`. Decision: it returns `PtrUInt` now, like the pin and like
`cutils.h`, and its comment no longer describes the pin as narrower. No
platform directive changes, so the CAP-7F divergence fingerprint of the unit
holds.

The QuickJS gates pass against the pinned statics on Windows and Linux (M3).

---

## M5 — everything else, Windows and Linux

Replayed straight out of `.github/workflows/platform-leg.yml` and each
`.github/actions/<slug>/action.yml`, in sequence order, continuing past
failures.

**Windows.** Steps 8–186, except the Lazarus install (12) and the five steps
that execute a real installer on the host (67, 70, 74, 79, 80). Those five
**were** run against the candidate by the hosted Windows leg of 35141256648:
all 82 of its steps before CAP-9C1 are green, the CAP-6b0 → CAP-6b4 installer
profiles and matrix included. _Local results: see the table in the final
artifact._

**Linux.** Steps 3, 5, 8, 10, 84–99, 122–188 in the WSL clone. The first pass
used the distro Node (24.20.0), which the CAP-7L SDK step refuses by design;
everything that cascaded from it was re-run with the pinned 24.11.1.

**What fails at this checkpoint, and why each is a supersession, not a
regression:**

| gate | why | the move |
|---|---|---|
| CAP-9C1 C30 | `LICENSE.quickjs` must name the pin: `mORMot2 commit  : da7e1c2f` | → `66d7d51c` |
| CAP-9C2 `license_quickjs_sha256`, CAP-10D2 staging, CAP-7F aggregate, `docs/third-party-licenses.md` | the provenance line moved | `a1d491db…` → `3475555a50debb194de75ba33eb0a08e92ea9995c2021249c7966a3f0923ee19` |
| CAP-10D2 contract "a shipped path is modified in the working tree" | local only — the gate refuses an uncommitted `src/` change, so the final chain runs on a committed HEAD | — |

`LICENSE.quickjs` is 450 lines and 22 044 bytes at both pins, and writing
`da7e1c2fabb17cc18279c7c8599b563d35845168` back into line 17 of the new
artifact reproduces `a1d491db…` byte for byte.

---

## The table

| item | upstream state at candidate | probe, unpatched | decision |
|---|---|---|---|
| Currency return (`RP-2`) | fixed by `6a27c07f`: x87 ST0 on FPC SysV x64, x0 on AArch64 | 5/5 windows (dev + hosted), 5/5 linux (hosted 3.2.2 + WSL 3.2.3), 5/5 macos-x86_64 and 5/5 macos-arm64 (hosted) | every row `must_pass`, run 35141256648 as provenance; limitation retired; `RP-2` CLOSED |
| Win64 CallMethod unwind (`RP-1`, closed) | unchanged, `896f1c1c` still in | one RUNTIME_FUNCTION, 12/12, dev + hosted | nothing to do; the gate stays |
| `JS_SetMaxStackSize` (`9A-3`) | fixed by `37fa86b4` | CAP-9A/9B2 limit rows PASS without the shadow; reverted binding fails the compile | shadow removed; `9A-3` CLOSED |
| `pas_*` widths (`9A-4`) | fixed by `66d7d51c` (`pas_malloc` signed pointer-width) | QuickJS gates PASS on the pinned statics; link map shows `int64` / `qword` | no workaround existed on Win/Linux; darwin block kept, `usable_size` aligned; `9A-4` CLOSED |
| statics | `static/` byte-identical; archive re-downloaded to the pinned sha256 | — | **no second pin** |
| CAP-9 corpora | binding source moved | all five byte-identical, Windows and Linux | **unchanged, measured** |
| `LICENSE.quickjs` | provenance line only | reconstruction proves it | `a1d491db…` → `3475555a…`, six sites + C30 |
| `sdk_inventory_digest` | `deps/mormot2/src` is staged byte for byte | measured per target by the chains | superseded per target (final artifact) |

**VERDICT: PLAN READY.** All four Currency rows are 5/5 on the unpatched
candidate, so there is no failing row to bring back. Every finding carries the
decision above, and none moves a frozen contract without precedent: the
2026-09-08 repin is the precedent for each one. Per this repository's
standing instruction, a PLAN READY checkpoint whose proposals are the default
ones is recorded and implementation continues in the same run.

Two things this checkpoint could not measure, and where they are measured
instead:

- macOS **without the shadow**. The measurement commit still carried the
  re-declaration, so the arm64 and x64 CAP-9 rows above were taken with it in
  place. The hosted legs of the final HEAD run the same rows without it.
- macOS `sdk_inventory_digest`. Every leg of the measurement run stopped at
  C30, before CAP-10D2, so both macOS values come from the final HEAD's run.
