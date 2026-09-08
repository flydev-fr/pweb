# MORMOT-REPIN — moving the mORMot pin onto the upstream CAP-3U fix

Post-MVP shard, 2026-09-08. It moves `mormot.lock` from
`b1a129b09197b6b9fb67c6d4d2a13445987a3fe1` (2.4.16242, 2026-08-05) to
`da7e1c2fabb17cc18279c7c8599b563d35845168` (2.4.16776, 2026-09-07) and
removes the CAP-3U patch, because upstream took both halves of the CAP-3U
finding.

## What upstream took, and from whom

| commit | when | what |
|---|---|---|
| `790154afbfb004d31404c81e13e8a1bc90a04d32` | 2026-08-12 22:02:12Z | *core: ensure imvCurrency is returned in rax on x86-64* |
| `896f1c1c66653c5c995ec9790117f0d6b8eeb427` | 2026-08-12 22:03:58Z | *core: Win64 requires unwinding information for its asm stub* |

Both messages end `- see https://github.com/flydev-fr/mormot-fpc-win64-callmethod-unwind`,
which is this project's own report. Two minutes apart, both halves.

## Checkpoint 1 — measured before anything moved

Every number below was measured on fresh checkouts the patch had never
touched, on the Windows dev host (FPC 3.2.2 x86_64-win64, the toolchain
`fpc.lock` pins for the hosted Windows leg; MSVC 14.50.35717) and under WSL
Ubuntu-24.04 (FPC 3.2.3, WebKitGTK 2.52.6, Xvfb).

### Unwind (the reason the patch existed)

| build | RUNTIME_FUNCTION for `CallMethod` | 12-case matrix |
|---|---|---|
| `b1a129b`, unpatched | **none** — the table jumps `00052030..00052075` → `00052120`, and CallMethod sits at `00052080` (`0xa0`) | dies at case 09, exit `0xE0465043` |
| `b1a129b` + CAP-3U patch | `0005BA30..0005BABF`, binary gate PASS | 12/12 PASS |
| `da7e1c2`, unpatched | `00052770..000527FD`, unwind RVA `0023B838` inside the mapped `.xdata`, version 1, prologue `0x06`, frame register **rbp**, `SET_FPREG rbp offset=0`, `PUSH_NONVOL r12`, `PUSH_NONVOL rbp` | **12/12 PASS** |

**FPC 3.2.2's internal PE-COFF writer honours `.seh_pushreg` / `.seh_setframe`
/ `.seh_endprologue`.** Confirmed twice: the default build (no `-A` flag)
emits no `.s` file at all, and an explicit `-Apecoff` build produces a
byte-equivalent RUNTIME_FUNCTION and the same 12/12.

### Currency (the other half)

Arities 0/1/2 through a real interface service, five cases:

| | `b1a129b` unpatched | `b1a129b` + patch | `da7e1c2` unpatched |
|---|---|---|---|
| windows-x86_64 | 0/5 | 5/5 | **5/5** |
| linux-x86_64 (FPC 3.2.3) | 0/5 | n/a — the patch is Windows-only | **1/5** |

Currency *arguments* are correct at both pins on both platforms; it is the
*return* that upstream changed. The four failing Linux cases read a leftover
pointer out of RAX — a defect that **predates the move and that the move
improves**, recorded as `RP-2` and reported upstream.

### Statics, and the two other upstream bugs

`static/` (`dev.sha256` included) and `res/` are byte-identical between the
two pins; 2.4-stable is still the newest release, its asset was last modified
2026-01-12, and re-downloading it on 2026-09-08 reproduced
`ae2d8da212c5b4f2778370de7aee965f7fd82eef911da27eeb797d6db06db449` over all
33 675 498 bytes. **No statics pin move.**

`mormot.lib.quickjs.pas` and `mormot.lib.static.pas` are byte-unchanged, so
`9A-3` (`JS_SetMaxStackSize` typed `JSContext` where the C takes `JSRuntime*`)
and `9A-4` (`pas_malloc(size: cardinal)` against a `size_t` caller) are still
live upstream and both PWeb-side shadow declarations stay exactly as they are.

## What changed here

- `mormot.lock` — the commit, with both upstream commits and the report URL in
  its own comment, and a note saying the statics are unchanged *by measurement*.
- **Gone:** `tools/patch-cap3u.ps1`, `tools/cap3u/x64callmethod.asm`, the
  generated `x64callmethod.obj`, the `PWEB_CALLMETHOD_UNWIND_PROBE` and
  `CAP3U_PRISTINE_DIFFERENTIAL` defines, and every apply/restore window in
  `test/cap5`, `test/cap6`, `test/cap6b3`, `test/cap8c`, `test/cap9a`,
  `test/cap9b1`, `test/cap9b2`, `test/cap9c1`, `test/cap9c2`,
  `test/cap10b1`, `test/cap10b2` and `test/cap10c1`.
- **Kept, and pointed at the compiler's own output:**
  `test/cap3u/check_unwind.ps1` now resolves `CallMethod` from the FPC link
  map (`.text.n_mormot.core.interfaces_$$_callmethod$tcallmethodargs` and its
  `.pdata`/`.xdata`) and makes the same five assertions, plus one the OBJ era
  could not express — no `x64callmethod` symbol may appear in the map. Proven
  discriminating: it refuses the old pin's binary (no `.pdata` contribution at
  all) and refuses a tree that still carries the patch (by name).
- **New:** `test/cap3u/cap3u_currency.pas` +
  `test/cap3u/currency-expectations.tsv` + `run_currency.ps1`/`.sh`, and the
  four-target step `CAP-3U Currency return matrix (typed observation, four
  targets)`, declared as a CAP-11A amendment.
- `pweb.cli.sdkroot`, `pweb.cli.native`, `pwebsdk`'s ship table,
  `docs/pipeline-contract.md` §2 and `docs/sdk-contract.md` — an SDK root is
  now the pinned upstream tree byte for byte on every target, and **`ml64` is
  no longer required to produce one.** `build_cap10c1.ps1` asserts the staged
  source *matches* `deps/mormot2` and that no `x64callmethod.obj` accompanies
  it — the inverse of the assertion it used to make.

## The CI step names did not move, deliberately

`CAP-5 host examples compile (re-applied CAP-3U window)` and `CAP-6 compile
bundler + release host (CAP-3U window)` keep their names although neither
opens a window any more. The CAP-11A migration invariant requires every legacy
step name to remain, in order, in the one platform-leg sequence:
`check_migration_map.ps1` fails a legacy step that is "absent from the
sequence", and `check_ci_sequence.ps1` re-measures the same claim as an
ordered subsequence of what actually ran on the hosted leg. Renaming them
would mean rewriting `ci-legacy-inventory.tsv`, which is the record of what
the *legacy* workflow contained and not ours to edit. The bodies changed and
are declared as amendments; the names are a residue, recorded here and in
`RP-1` rather than quietly left to mislead.

## Supersessions

| value | before | after |
|---|---|---|
| `ci_sequence_digest` | `3d74864bbf0488ef282f18973bc85d45768507b4d6bad7d4cd21e80d79df351a` (201 steps) | `7f7dc950d8bc7aa96856869421a8bbc8dbfebc469263a3a76a2d1b35d1ac527c` (202) |
| `LICENSE.quickjs` sha256 | `8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc` | `a1d491db9c87a750c2bb37d7d47b642ce4b94a0d56332640f1d14521233875bf` |
| `quickjsrelease.pas` expected pin | `mORMot2 commit  : b1a129b0` | `mORMot2 commit  : da7e1c2f` |
| `sdk_ship_table_digest` | `8a4d9fa32ed02a5dcf6c11acd6bb73a151734dfdbceb80490c2e53e5ba9a0636` | `92f53b632cdd3f08bea4c5604a2867cbc6885f90e3b2a969c8ea309122c4e995` — the ship-table note stopped saying "CAP-3U-patched on Windows" |
| `sdk_inventory_digest` (windows-x86_64) | `03158a82729daa7b715a0a2c004fa0769ac9fa3402d8272dceb7b3ef2a65ace7` | `a974b29fea9c091a8c3141a0d7d68a5f1f82a27c3e6470af9018742fc4d64b9a`, `sdk_files` 291, `sdk_bytes` 38656512 |
| `sdk_inventory_digest` (linux-x86_64) | per target by construction | `735cd8406a3aeefdaa0f7bb11a5acae3b2e4138d4b0497e10f8a993d1e515362`, `sdk_files` 218 |
| `sdk_digest` | `b33df77edacdffd9336bc6835635a010a0b0d48ec4c2256773592a008f82e9be` | **re-measured unchanged** |
| `quickjs_corpus_digest` | `601b86ff…` | **re-measured unchanged** |
| `quickjs_package_digest` | `4b01cf06…` | **re-measured unchanged** |
| `quickjs_lifecycle_digest` | `6c8d0bd7…` | **re-measured unchanged** |
| `quickjs_release_digest` | `04c2db17…` | **re-measured unchanged** |
| `quickjs_gui_digest` | `1c88bda9…` | **re-measured unchanged**, Windows and Linux agreeing |

All five CAP-9 corpora were re-measured on both platforms rather than assumed
unchanged, and all ten digests are byte-identical to the recorded values —
which is what "the QuickJS binding did not move" has to mean if it is to mean
anything: `mormot.lib.quickjs.pas` and `res/static/libquickjs` are unchanged
between the two pins.

## What was run, and where

Windows dev host, all green on the committed HEAD: the rewritten CAP-3U
unwind gate and its 12/12 matrix, the new Currency matrix 5/5, CAP-3 bridge +
`cap3tests` 193/193, `pwebtests` 2502/2502, CAP-5, CAP-6, CAP-8B, CAP-8C,
CAP-9A/B1/B2/C1/C2, CAP-10A/B0/B1/B2/C0/C1/C2/C3/D0/D1/D2/E, CAP-7F
divergence/schema/host-args, CAP-11A migration-map/structure/cases, CAP-11B
ref-input/contract/cases/ledger, and the backlog gate.

Linux under WSL (FPC 3.2.3, WebKitGTK 2.52.6, Xvfb), all green: the Currency
matrix as a typed observation (1/5, nothing gated), CAP-7L, CAP-8B, CAP-8C,
CAP-9A/B1/B2/C1/C2 and CAP-10A/B0/B1/B2/C0/C1/C2/C3/D0/D1/D2/E.

The `LICENSE.quickjs` digest moved and **the licence text did not**: both
artifacts are 450 lines and 22 044 bytes and differ on exactly one line — line
17, `mORMot2 commit  : …`. Seventeen per-file `sha256` lines, fourteen MIT
permission sentences and eight copyright lines (Fabrice Bellard 2016-2017,
2017, 2017-2018, 2017-2020, 2017-2021; Charlie Gordon 2017-2018, 2018,
2017-2021) are identical. See `RP-3`.

## What the first hosted run measured, and RP-4's closure

Run **34241426338** on `c1955928390707c165e00f75ac29d4a3327996b8`, six jobs
green, **202 steps** with `ci_sequence_digest`
`7f7dc950d8bc7aa96856869421a8bbc8dbfebc469263a3a76a2d1b35d1ac527c` identical
on all four legs and equal to the declared sequence — the amendment landed
exactly as recorded.

| target | compiler that leg builds with | Currency matrix |
|---|---|---:|
| windows-x86_64 | FPC 3.2.2 x86_64-win64 | **5 / 5** |
| linux-x86_64 | `3.2.2+dfsg-32`, the Ubuntu 24.04 package | **1 / 5** |
| macos-x86_64 | FPC 3.2.2 [2021/05/16] x86_64 | **1 / 5** |
| macos-arm64 | FPC 3.2.2 [2021/05/16] aarch64 | **0 / 5** |

`cur-zero-arg` is promoted to `must_pass` on linux-x86_64 and macos-x86_64;
everything else stays `observe`. The hosted Linux 3.2.2 agrees with the
dev-host 3.2.3, which was the check `RP-4` existed to make.

**The two SysV x64 targets are identical**, 1/5 each — what sharing the
non-`ABIWINX64` branch predicts. **macos-arm64 is a third and worse case**:
AAPCS64 has its own `CallMethod`, untouched by `790154af`, and returns 0/5
including the no-argument case, with the *same five values Win64 produced at
the previous pin unpatched*. The result register is wrong on three ABIs, and
on aarch64 apparently always was; `RP-2`'s report says so now.

The same run cleared the other outstanding measurement: **all twenty-two
CAP-6b0 → CAP-6b4 steps green**, with the release host compiled against the
pristine dependency — the three installer profiles built and installed,
CAP-6b3 staging 256 files / 689 841 950 bytes and observing runtime
151.0.4129.78, and CAP-6b4's I1-I3, S1-S6, F1-F4, U1-U3 matrix passing over
the three real setups.

**One defect of this shard's own making, found and fixed here.** The
Currency corpora were only in the `diagnostics` collection class, which
uploads on a **red** leg, so `RP-4`'s own instruction — read the four
`currency-corpus.txt` files — was impossible on a green run and the first
ratification had to be taken from the job logs instead. They are now in the
`records` class.
