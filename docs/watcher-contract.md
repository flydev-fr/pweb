# The upstream watcher contract

The watcher answers one question, on a schedule, per target:

> Does the pinned PWeb binding still match upstream `webview/webview` head, and
> if not, what changed?

It publishes the answer and **acts on nothing**. Everything below is enforced by
`test/cap11b/check_watcher_contract.ps1`, which runs on all four platform legs
of the ordinary matrix and proves it refuses with fourteen seeded perturbations
of its own sources. The watcher's *source* is gated; the watcher's *runtime* is
never part of the matrix.

The prose here may be reworded freely. The permissions, the trigger set, the six
verdict words, the retention class and the eight-stage order may not, except by
a version bump.

## 1. What it may never do

| | why |
|---|---|
| move `webview.lock`, `mormot.lock` or any pin | the watcher reports; re-pinning is a deliberate, reviewed act |
| write into `src/`, `sdk/`, `tools/pweb/`, `tools/setup/`, `examples/`, or regenerate `webview.chet` | the binding is regenerated only by `tools/regen-webview-binding.ps1`, by a human, on purpose |
| commit, push, tag, open a pull request, or write a GitHub issue | see §5 |
| be called by `ci.yml` or `platform-leg.yml`, be `needs:`-linked, or declare `workflow_call` | it must not be able to become a required check by being wired into one |
| fail because upstream changed | a change is news, not a regression |
| read its own previous report — no `download-artifact`, no `gh run download`, no `actions/cache` | a verdict that consumed the last verdict is not a measurement |

## 2. Permissions

`permissions: contents: read`, declared once at workflow level, with **no
job-level grant, no secret and no token beyond the default read-only one**. The
job compiles code from an unpinned upstream commit; it runs with the least it
can, and writes nothing but its own artifact and job summary.

## 3. Triggers

`schedule` (weekly, Mondays 04:17 UTC) + `workflow_dispatch` (optional `ref`
input, default the remote head) + `push` filtered to the watcher's own sources.

The `push` trigger is a measurement, not a preference: GitHub offers
`workflow_dispatch` only for workflows present on the **default branch**, and
this repository's shard branches are not merged to `main` before their closure.
Without it, a watcher could not be run once on the branch that introduces it and
every later edit to it would ship unexercised. The `paths:` filter is mandatory
— unfiltered, the watcher would build an unpinned upstream commit on every
commit to the repository.

## 4. The eight stages, in order

1. **Pin** — the pinned ref and the platform patch digest, read from `webview.lock`.
2. **Fetch** — upstream head, the one network step besides toolchain fetches. Its commit and date are recorded; the author is not.
3. **Patch** — the pinned platform patch attempted on head, typed `clean | offset | rejected`. Windows is the only target that patches upstream (CAP-4W); the other three declare none and report `not_applicable`, never `patch_drift`.
4. **Build** — the library from head, through the *pinned build script* parameterised by its ref input (§6).
5. **Compile** — `test/core/signature_pin.pas` and the paired ABI probes, against head's header and library; then the exported-symbol check.
6. **Diff** — pinned → head: added / removed / changed prototypes, enum members and values, version macros and callback signatures, **from the headers, mechanically**.
7. **Checklist** — the CAP-1 ABI checklist items that are runnable headless.
8. **Verdict** — one of six words, with the evidence for each.

### The calibration

`ChetCLI` is a Windows-only Delphi tool at a hard-coded path that no runner has,
and the watcher may not write into `src/` in any case. So stage 5 projects
head's headers into a Pascal binding in the watcher's own workspace
(`test/cap11b/project_binding.ps1`) — and before it touches head at all, it runs
the **same projector over the pinned headers** and compiles the pins against
that. If the calibration fails, the tool is broken and the verdict is
`inconclusive`, **never** `abi_break`. Only after it passes is a failed head
compile evidence about upstream. An unmapped C type is a refusal, not a guess.

### The verdicts

| verdict | what stands behind it |
|---|---|
| `unchanged` | the head model equals the pinned model; the diff is empty |
| `compatible_additive` | head adds declarations; nothing removed, no signature changed, no enum value moved; the pins still compile |
| `patch_drift` | the pinned platform patch no longer applies where it did — `rejected`, or `offset` with git's own displacement |
| `abi_break` | after a passing calibration: a pin fails to compile against head, or a declaration was removed or changed, or an export vanished |
| `build_failed` | the head library did not build; the log tail is in the report |
| `inconclusive` | network, toolchain, runner, an unparsable declaration, an unmapped type, or a failed calibration — always naming which |

Precedence, first match wins, every observation still recorded:
`abi_break` → `patch_drift` → `build_failed` → `inconclusive` →
`compatible_additive` → `unchanged`. `inconclusive` is deliberately **not**
first: `patch_drift`, `build_failed` and the removals and changes behind
`abi_break` are settled by git and the headers alone, so a run whose Pascal
toolchain could not calibrate still knows those for certain. What does depend on
the projector is the claim that nothing broke — so `inconclusive` outranks both
`compatible_additive` and `unchanged`.

**`unchanged` is only ever said about a run that compared something.** A run
that produced no API model reports `inconclusive`, because "nothing changed" and
"nothing was measured" are different answers.

## 5. The report, and why there is no issue

One artifact per target — `upstream-watch-<target>`, JSON plus a human Markdown,
retention 90 days (the CAP-11A **records** class) — and one job summary. **The
job's conclusion is `success` whenever the watcher itself ran**; the driver
exits 0 unconditionally and the verdict lives inside the report.

There is no GitHub issue. Writing one needs `issues: write`, which cannot
coexist with the `contents: read`-only posture of §2 on a job that compiles an
unpinned upstream commit — the whole reason that posture exists. And "one
long-lived issue *titled by the upstream commit*" is self-cancelling: the title
changes every time upstream moves, so the rule would create a second issue at
the next commit, which is what it forbids.

## 6. The ref input, and the pinned path

`tools/get-webview.ps1`, `tools/build-webview-dll.ps1`,
`tools/build-webview-so.sh` and `tools/build-webview-dylib.sh` each take one
optional input, `-Ref` / `--ref`. With it they read `deps/webview-watch` and
write under `build/cap11b/`; without it every path, flag and assertion is what
it always was.

Each also has `--print-plan`: it resolves every path, flag and assertion mode,
prints them, and exits 0 having touched nothing.
`test/cap11b/pinned-plan.expected.txt` records the five pinned plans, and
`test/cap11b/check_ref_input.ps1` compares them **byte for byte** on every leg,
then re-reads both lock digests. Adding an input necessarily changes the source
of these scripts; what must not change is what they do when nobody passes one,
and that is a comparison rather than a claim.

Under `--ref`, the lock's **name** pins become observations — the SONAME on
Linux, the three dylib names on macOS — because an upstream version bump renames
them and a watcher that died on that would report `build_failed` for news. The
**engine** pins (WebKitGTK 4.1, GTK 3.0), the deployment target, the install-name
strategy and the WebView2 SDK pin hold in both modes: the watcher measures
webview drift, not a different engine.

## 7. Evidence

Per target, in the CAP-7F matrix: `watcher_available`,
`watcher_verdict_vocabulary_digest` (compared across four),
`watcher_pinned_path_byte_identical`, `locks_unchanged_after_watch`,
`watcher_permissions`, `watcher_in_matrix`, `watcher_seeded_verdicts`,
`mormot_watcher`.

Six verdicts cannot be demonstrated by an upstream that has not moved, so
`test/cap11b/check_cap11b_cases.ps1` drives the same driver through a named seam
with seeded input on every leg: eight cases, offline, six verdicts, **with a
real FPC compile behind `abi_break`** and a control case proving the unedited
fixture takes the pinned patch cleanly.
