# CAP-14A — the bundler refuses what the native CSP will not run

Shard record, 2026-09-09, branch `phase/cap-14/a-bundler-csp-refusal`, baseline
`958ff45f13488dad6be4b8b08f1f5cafd2772a7f`. **The hosted four-target run is
outstanding**; everything below was measured on the Windows dev host (FPC 3.2.3
x86_64-win64) and, where it can be, under WSL Ubuntu-24.04 (FPC 3.2.3
x86_64-linux). The macOS legs and the POSIX halves of the two pipeline seams are
the hosted run's to confirm.

## The defect

`PWEB_NATIVE_CSP` (`src/security/pweb.navigation.policy.pas:132`) carries
`script-src 'self'` with no `'unsafe-inline'`. An external reviewer took an
arbitrary third-party static dist, bundled it, and it **rendered correctly on
the first attempt, fonts and all** — and then half-worked, because its
`index.html` carried an inline `<script>` that the CSP silently refused to run.
Nothing reported it: not `pwebbundle`, not `pwebbundle --verify`, not `pweb
build`, not the host, and not the engine, because a blocked inline script raises
no application-visible error. TODO.txt #2, and the reviewer's own framing is the
right one — "a `pwebbundle` warning when it sees `<script>` without src is maybe
twenty lines and kills the worst first-contact experience — silent half-working
with no error anywhere."

It is not twenty lines, and the reason is the whole of this shard: a rule that
finds `<script>alert(1)</script>` is easy, and a rule an executable script
cannot slip past is not.

## TOKENIZER

`src/assets/pweb.assets.htmlpolicy.pas` — one forward pass over the bytes. No
DOM, no full HTML parser, no regex, no backtracking, no recursion; every state
advances and none moves left. Attributes are **judged as they are parsed**
rather than collected, so a pathological tag grows nothing, and at most
`PWEB_HTML_MAX_VIOLATIONS` (64) findings are recorded before the scan stops with
a truncation flag — the bound is on the report, never on the refusal.

The scanned set is exactly the logical names `PWebAssetMimeType` resolves to
`text/html`, **read from the resolver rather than typed a second time**, so the
scanned set and the served type cannot disagree.

It agrees with the HTML tokenizer where that matters. **Two places had to be
exact rather than conservative, and both were found by attacking the scanner
rather than by reading it.** The first is the comment state's **abrupt-closing
rule**: `<!-->` and `<!--->` are complete comments, so a scanner that missed it
would read `<!--><script>alert(1)</script>` as one unterminated comment and
never see the script. That is a real bypass, and it is closed by seeding the
dash counter at two — which is also why that shape is a corpus row rather than a
comment. The second is below, in the character-reference decoder.

**Six named divergences, every one towards refusal:**

| divergence | consequence |
|---|---|
| `<![CDATA[` is the HTML-namespace bogus comment in **both** namespaces | a `<script>` that is text inside an SVG CDATA section carrying a `>` is refused |
| the script-data **escape** states are not implemented | a script element ends at the first `</script` delimiter; an engine may end it later, never earlier, so this scanner resumes reading markup **sooner** — it can over-refuse, it cannot under-refuse |
| an `on`-prefixed attribute no engine honours (`once`) | refused; a handler a hand-written allowlist forgot is the exact failure this shard exists to close, and the corpus carries none |
| an absolute `pweb://app/x.js` src | refused although it would run: a bundle names its own assets relatively, and authority parsing (`pweb://app.evil/`, `pweb://app@evil/`) is where cross-origin acceptance bugs live |
| a raw-text element that is never closed | refused rather than skipped to EOF, which is the one shape that would hide the rest of a document from the scan |
| a `<script>` inside a `<template>` | refused although template content is **inert** — it never runs, not even after cloning — so the author believed something that was never true; the `on*=` in the same template is a different case, and refusing it is simply correct because a handler survives cloning and then meets `script-src 'self'` |

**The second place that had to be exact** is the numeric-character-reference
accumulator, and it was found by attacking the decoder rather than by reading
it: nine hex digits overflow a `Cardinal`, so an unclamped decoder wraps
`&#x10000006A;` to `$6A` and reads a `j` no engine ever produces — every engine
maps anything above U+10FFFF to U+FFFD. An over-refusal rather than a bypass,
but a disagreement with the engines either way. It is clamped at `$10FFFF` and
pinned by a corpus row.

**A `<base href>` needs no rule at all**, and the corpus says why rather than
leaving it to be rediscovered: a `<base>` would move the document base that a
same-origin-relative `src` resolves against, and `PWEB_NATIVE_CSP` carries
`base-uri 'none'`, so the element cannot. The accept row exists to record that
this scanner's silence there depends on that CSP term.

**Character references in attribute values are decoded once before any URL is
judged**, because the engines do: `href="java&#9;script:x"` is a `javascript:`
URL, `&#106avascript:x` is one without its semicolon (the engines flush the
reference anyway), and `src="&#100;ata:,x"` is a `data:` URL. Attribute *names*
are never entity-decoded, which is also what the engines do.

**Measured against real output.** Vite emits
`<script type="module" crossorigin src="/assets/app.js"></script>` — accepted,
and it is one of the twelve accept classes. The Pas2JS assembly emits two
same-origin classic scripts — accepted. Every template, every example dist and
every runtime fixture in the repository is accepted. The corpus is 54 rows plus
two built-at-runtime UTF-16 fixtures, and it is emitted as
`build/cap7f/html-policy.txt` so four targets can be compared on it byte for
byte.

## REFUSAL CLASSES

Four violation classes and two refusals to **judge** — the distinction matters,
because one says "the CSP will not run this" and the other says "this bundler
cannot tell you what the CSP would do here", and they earn different closing
sentences in the diagnostic.

| cause | rule |
|---|---|
| `bundle_inline_script` | `<script>` with no `src` and an executable type |
| `bundle_external_script` | `<script src=…>` carrying a scheme, or beginning `//` (or its backslash spellings) |
| `bundle_inline_handler` | an attribute whose ASCII-lowercased name begins `on` and is at least three bytes |
| `bundle_javascript_url` | an attribute value whose URL scheme is `javascript`, after the URL parser's normalisation and one decode pass |
| `bundle_html_encoding` | a UTF-16 byte order mark |
| `bundle_html_unterminated` | a raw-text element that is never closed |

**Executability is HTML's own rule, not a four-name list**: absent, empty,
`module`, `importmap`, or a MIME *essence* (up to the first `;`, trimmed,
lowercased) in the sixteen-entry JavaScript MIME set. So
`text/javascript; charset=utf-8` is refused and `application/json`,
`application/ld+json`, `text/template` and every other type the engines do not
run are accepted. A four-name list would have run the first one silently.

One diagnostic line per finding, cause, logical path and line:

```
pwebbundle: bundle_inline_script: index.html:9: inline <script>: script-src 'self'
  carries no 'unsafe-inline', so this block never runs [(no type)]
pwebbundle: the native CSP (script-src 'self', no 'unsafe-inline') will not run
  those 1 construct(s); there is no option that packs them anyway
FAIL: Exception: 1 refused input file(s) - nothing was written
```

The path is the **logical** one, so a line forwarded through `pweb build` or
`pweb dev` carries no absolute path. Every offender is reported in one round —
the CSP pass joins the ratified D3 classification's round for exactly that
reason — and a refusal writes nothing and leaves any previous output
byte-identical.

**There is no override**, and the absence is measured rather than promised: the
option surface swept out of the parser is exactly
`--include-sourcemaps,--max-asset-bytes,--min-runtime,--verify`, the bundler
reads no environment variable, and both facts are absolute pins in the
aggregate. The CSP decides what runs; a flag that packed it anyway would be a
lie told at build time and paid for at run time.

## PIPELINE AND DEV INTEGRATION

**Neither the CLI nor the host changed.** Both seams already did the right
thing; CAP-14A measures them with a new cause travelling through.

`pweb build` — the pack child exits nonzero, which is the pipeline's existing
`stage_exited`, which is `ppcStageFailed`, which is **exit 5**. Measured on a
real generated Pas2JS project whose `frontend/index.html` grew one inline
script: `build_refusal_exit=5`, `build_refusal_stage=stage_exited`, the
bundler's cause forwarded into the build output, the previous release
**byte-identical** by a recursive fingerprint taken before and after, and no
partial layout directory. The clean build before it exited 0, so the release the
refusal had to leave alone is one the gate watched being made.

`pweb dev` — the ratified "a build or a pack child fails" row of the
development contract. Measured on the same project, in one real session:
generation 1 published and loaded, the edit introduced, the cause forwarded with
the `pack: ` prefix, **no generation 2 directory**, `gen-1/app.pwb` still there,
the loop still running, and — the row that separates the true claim from its
lookalike — **the host pid unchanged across the refusal**, because "the previous
generation stays live" and "the host was restarted with the previous generation"
look identical from the outside. Reverting the edit published generation 2.

Pas2JS rather than React for both seams, and that is a measurement rather than a
preference: its pipeline reaches `pack` with no npm, no registry and no network,
so the two seams are proven without borrowing another shard's install. React's
own path is covered by the corpus leg, which packs Vite's **real** output.

## SUPERSESSION

The CAP-6 bundler is frozen and this is an additive refusal. What moved:

| | before | after |
|---|---|---|
| `bundler_digest` (`tools/bundler/pwebbundle.pas`, LF-normalised) | `894c1cc88edaf0024fb65254b63c8de40cdbbd3aad88630d18194c7a8cd41074` | `9ccfddef0d44aff77138b5103af8cea18e5568b06fa925afa2cb68d7e2ed0f84` |
| `csp_policy_digest` (`src/assets/pweb.assets.htmlpolicy.pas`) | — (new unit) | `c98d03d5580d858e60850647865c7c56d4ae6615eab0bf3d983ab25c531b3cc9` |
| `html_policy_digest` (`build/cap7f/html-policy.txt`, 4626 bytes, 56 decisions) | — (new corpus) | `eee49f70438aa664b059d4d1cff05569f8ce77cdae639e7c629765cf51d22a41` |
| `ci_sequence_digest` | `7f7dc950d8bc7aa96856869421a8bbc8dbfebc469263a3a76a2d1b35d1ac527c` (202 steps) | `412b21b257dd6945ad2bd95313d584bab67c0ef5d9cebde85cd92db9a77586d1` (203) |
| `schema_field_count` | 734 | 771 |

The reason for the bundler digest move is the whole of the shard: one `uses`
entry, one nested `ScanDocument`, one loop over the HTML documents in the input,
and two closing diagnostics. The declared amendment recording the sequence move
carries body digest `fb0dcca69379cb24` and names both digests and both step
counts, so the arithmetic is in the table rather than in a comment.

**The archive bytes did not move**, and that was measured the only way it can
be: HEAD's pre-change bundler was compiled with the **same** compiler as the new
one, and the two produced the identical `app.pwb` from the React example dist.
The full CAP-6 gate then re-ran green with its recorded
`424238FDCC182E4A41C44FB43812B0CDF145BD7D34B304B40FD090B447FF52A5` unmoved,
including the deterministic-rebuild and non-ASCII-path legs that compare it.

`app.pwb` bytes are deterministic **per toolchain and not across toolchains**,
re-measured on this shard's own fixture: the signage corpus packs to
`dcd2f40e…` from the win64 bundler and to `5dfe3831…` from the linux one over
the identical input tree. That is the same fact the CAP-9C1 ledger records for
`plugins.zip`, and it is why `bundle_accept_sha256` is required present on four
targets and compared on none while `bundle_accept_deterministic` — the same dist
packed twice on the same toolchain — is an absolute pin.

## REGRESSIONS

Every existing corpus still packs, measured rather than assumed. On the dev
host, 17 items with zero refusals:

- `examples/04-react`, `05-pas2js`, `06-assets`, `07-quickjs` dists;
- the CAP-10C1, C2, C3 and D2 staged dists — **Vite's real output and the
  Pas2JS assembly**;
- the React, Pas2JS and fixture templates;
- the CAP-7M, CAP-8B (two), CAP-8C (two) and CAP-9C2 runtime fixtures.

Under WSL the linux bundler packed the four example dists and produced
byte-identical typed refusals on all five fixture classes.

Green locally, before any push:

| gate | result |
|---|---|
| `test/cap6/build_cap6.ps1` | the isolation compile, the bundler and the release host, x86_64-win64 |
| `test/cap6/check_cap6_nonetwork.ps1` | PASS with the policy unit added to the swept set |
| `test/cap6/run_cap6_gates.ps1` | ALL PASS, archive digest unmoved |
| `pwebtests` (Windows) | 0 / 2,636 assertions failed; the new `Html policy` case is 134 of them |
| `pwebtests` html-policy case (WSL Linux) | 0 / 134, corpus **byte-identical** to Windows |
| `test/cap14a/check_cap14a_contracts.ps1` | PASS on Windows **and** under Linux pwsh |
| `test/cap14a/run_cap14a_gates.ps1` | PASS on windows-x86_64, C0-C9 + B1 + D1 |
| `test/cap7f/check_schema_agreement.ps1` | 771 fields, three lists, zero asymmetry |
| `test/cap11a/check_migration_map.ps1` | 445 legacy steps, 342 bodies, 203 declared |
| `test/cap11a/check_ci_structure.ps1` | PASS, largest CI file 56,690 B against a 65,536 B bound |
| `test/backlog/check_backlog.ps1` | PASS — 349 entries, 0 orphans, 47 open |
| `test/backlog/check_backlog_selftest.ps1` | 14/14 legs refused, tree restored |

**The adversarial pass changed four things, and it is worth saying that it was
run by hand.** The workflow's three review subagents were launched and all three
stalled without returning a finding, so the review was done directly against the
diff rather than skipped. It produced: the numeric-reference clamp above (a
disagreement with the engines, closed and pinned); seven further corpus rows —
`<template>`, `<base>`, a NUL in a tag name, an unquoted `javascript:` URL,
spaces around `=`, a whitespace-only `src`, and the out-of-range reference; and
two verification-gap fixes in this shard's own gate. The first of those matters
most: the twelve accept classes were a **hand-written list beside a fixture**,
which is one deletion away from asserting that a construct was accepted after
somebody removed it. Each class now names the bytes in the fixture that carry
it, so a class whose construct is gone fails the gate instead of passing it. The
second is a floor on the corpus count, because "zero refused" is also what a leg
that packed nothing would report.

**The self-test found one of its own defects on the way through.** Its
"summary that disagrees with its own table" leg replaced the literal
`| ROADMAP | 39 |`; CAP-14A's roadmap row made that string absent, the
replacement a no-op, and the leg reported `13/14`. It now reads the stated count
and decrements it. Ledger `14A-6`, and the same family as `11B-11` and the
CAP-10C1 fixture that hardcoded `/usr/libexec`.

The policy unit is **not linked into any release host**: the CAP-6 host unit
directory carries no `pweb.assets.htmlpolicy.ppu` while the bundler's does, and
the source-level form of the same claim — exactly one caller,
`tools/bundler/pwebbundle.pas` — is T1 of the contract check and an absolute pin
in the aggregate.

## FREEZE

No CSP change: T5 re-reads `PWEB_NATIVE_CSP` and refuses a `script-src` that
grew `'unsafe-inline'` or a `style-src` that lost it. No host change: nothing
under `src/webview`, `src/platform` or `examples/` was touched, and the writer
`pweb.assets.bundle.pas` — the unit a host links — is byte-unchanged. No schema
change beyond additive evidence rows. No option, no environment variable, no
manifest field, no per-file exemption.

## What is owed

`14A-3`, ROADMAP: `.svg` is not scanned. An SVG referenced as an image has
scripting disabled by the image context, so a handler inside one is inert **by
design** rather than by CSP and refusing it would refuse a working dist — but
`PWebClassifyNavigation` permits a top-level navigation to any `pweb://app/...`
URI, so an application that links to `/logo.svg` gets a real SVG *document*
whose inline script is blocked with exactly the silence this shard exists to
end. No shipped corpus does it. Closing it is a decision about what an SVG in a
bundle is, and only then a question of whether an XML tokenizer is a second
scanner or a mode of this one.

## VERDICT

**CAP-14A PASS — BUNDLER REFUSES WHAT THE CSP WILL NOT RUN**

pending the hosted four-target run, which owes the macOS legs, the POSIX halves
of the `pweb build` and `pweb dev` seams, and the four-target equality of
`bundle_refusal_classes`, `bundle_accept_classes`, `html_policy_digest`,
`bundler_digest` and `csp_policy_digest`.
