# CAP-10C2 — Final Artifact: `pweb dev`, rebuild-and-reload behind pweb://app

CAP-10C2 closes on hosted run **33748442256** (2026-09-03, commit
`765d5d0df049ca130353ea1217a6791a295043a3`, branch
`phase/cap-10/c2-react-dev-loop`, baseline `94694bc`): all six jobs green,
`cap7 aggregate` PASS with field-by-field agreement on four targets, ONE
`dev_digest`
`09cc2b1c1c2c6b103d88c744fd0a861818f43e55d76f852d6472f155ce0b7df6` — 71
decisions — equal on windows-x86_64, linux-x86_64, macos-x86_64 and
macos-arm64, and `pipeline_digest` re-measured **unchanged** at CAP-10C1's
closure value `f890424a…978e839a`.

`pweb --help` advertises `create doctor run dev`. `build` is still an unknown
command.

## The claim this shard exists to make

**A developer edits `App.tsx` and the running window shows the new bytes,
without the application restarting and without the privileged origin, the
CSP or the asset path moving an inch.** Every generation is one `app.pwb`
produced by the frozen CAP-6 bundler, published by one directory rename, and
loaded by one native re-navigation to `pweb://app`. There is no listener, no
development server, no proxy, no HMR transport, no folder store and no CSP
allowance anywhere in it.

| field | value | scope |
|---|---|---|
| `dev_loop_model` | `rebuild_and_reload` | absolute pin, four targets |
| `dev_digest` | `09cc2b1c…ce0b7df6` | four targets, 71 decisions |
| `dev_corpus` / `dev_suite` | `PASS` / `PASS` | must-PASS, four targets |
| `csp_identical` | `true` | absolute pin — dev host CSP == release host CSP, byte-compared |
| `csp_transport_terms` | `none` | absolute pin |
| `release_dev_unit_absent` / `dev_marker_in_release` | `true` / `false` | absolute pins, a directory listing and a byte scan |
| `dev2_host_pid_unchanged` | `true` | absolute pin — the whole claim |
| `dev5_final_value` / `dev5_final_content_correct` | `47` / `true` | absolute pins — the page's own arithmetic after a burst |
| `dev4_broken_published` | `false` | absolute pin |
| `dev6_pweb_exit` / `dev6_descendants_remaining` | `0` / `0` | absolute pins |
| `dev7_pweb_exit` / `dev8_pweb_exit` | `5` / `5` | absolute pins — a member ended from outside |
| `dev_interrupt_clean` | `true` | absolute pin, **all four targets** — the CAP-10C1 gap, closed |
| `dev_listener_members_max` | `0` | absolute pin, membership-scoped over BOTH members |
| `dev_loose_assets_used` | `false` | absolute pin |
| `dev11_exit` / `dev11_cause` | `3` / `dev_ui_unsupported` | absolute pins |
| `build_still_unknown` | `true` | absolute pin |
| `pipeline_digest` | **unchanged** | re-measured against the C1 closure value |

## What shipped

```
  tools/pweb/pweb.cli.dev.pas        the loop - the ONLY unit that runs a
                                     child; two supervised threads, one
                                     stop flag, one C0 ladder
  tools/pweb/pweb.cli.devlayout.pas  the layout, the generation, the
                                     publish-by-rename, the bounded cleanup
  tools/pweb/pweb.cli.native.pas     PWebCliFpcDevCommand, additive
  src/webview/pweb.webview.devhost.pas  the swapping store, the argument
                                     and its refusal, the poller, the reload
  src/webview/pweb.webview.host.pas  the seam, and only the seam
  tools/templates/{react,pas2js}/    the sentinel and the PWEB_DEV region
  docs/dev-contract.md               the contract
  test/cap10c2/                      the suite, the driver, the gates
```

## The first decision, and the data that made it

**Model A — Vite's dev server behind `pweb://app` — was refused on
measurement**, not on preference. The spike ran the real dev server on the
real generated project and read the served bytes; the record is
`cap10c2-model-a-spike.md`. Two findings decided it, and each is a
relaxation of frozen surface:

- **the query is load-bearing and `PWebParseAppUri` cuts it.**
  `/src/app.css` is 2563 bytes of `text/javascript`; `/src/app.css?direct` is
  1938 bytes of `text/css` — one path, two bodies;
- **the MIME type would have to come from the proxied response.** `.tsx`
  modules are served `text/javascript` while `PWebAssetMimeType` derives
  `application/octet-stream` from the extension, which every engine's module
  MIME check refuses.

Recorded beside them: the client derives its socket from the page URL, giving
`ws://app:/` under `pweb://app`, and the template ships no
`@vitejs/plugin-react`, so a `.tsx` edit already ends in `location.reload()`.
Model A's one advantage over model B does not exist for this template.

The ratified `ws://127.0.0.1:<port>` allowance stays **ratified, unused, and
pinned absent** on every leg.

## Four defects the gates found, and what each cost

**The two WebKit adapters cached the privileged bundle.** The spec recorded
this as a risk before the shard ran; it is now measured. Without
`Cache-Control: no-store` the WebKitGTK handler is asked for
`assets/app.js` **exactly once** — at the first document load — and every
later re-navigation re-runs the page against the previous bundle's
JavaScript. The archive changed, the host acknowledged the switch, the page
re-executed, and it computed the old answer. With the header the store is
asked on every navigation and the page tracks the archive: **42 → 47 → 42**
over three generations, which is the discriminating sequence. The Windows
adapter has sent the header since CAP-4W; the human ratified adding it to the
other two, and `check_cap10c2_contracts.ps1` section 9 now pins all three in
source.

**A reload dispatch could outlive the webview it names.** The auto-close
thread is safe because the teardown JOINS it before disowning the handle; a
composition's poller is not a thread the host owns. `PWebHostRequestReload`
now raises an interlocked busy count before it reads the handle, and the
teardown drains it — bounded, placed after the disown and before the first
teardown step, so the CAP-9 order is reached unchanged.

**A second `pweb dev` on the same project could not publish.** A session
numbers from 1 and publishes by a rename that must not replace, so a
surviving `gen-1` is a *different session's* content under the name this one
promises to write. Start-up now reclaims every published generation, matching
`gen-` plus digits and nothing else.

**A development compile rebuilt the whole mORMot surface every start.** The
dev vector inherited `-B`. The ratified spec says "cached units"; `-B` is now
release-only, where `build_deterministic` needs it.

## The production seam, and what it is not

Three things, and one drain:

1. `TPWebHostOptions.ConsumedArgs` — argv strings a composition declares it
   consumed, matched byte-exactly. Empty in production, so the refusal set is
   what it always was.
2. A `PWebHostRun` overload taking `const Store: IAssetStore`; `nil` means the
   production rule and nothing else.
3. `PWebHostRequestReload` — `PWebHostTerminate` with `webview_terminate`
   replaced, no parameter, and `PWEB_HOST_ORIGIN` the only destination.

`IAssetStore` gained nothing: the swapping store is an implementation.
`PWEB_NATIVE_CSP` gained nothing. The production host learned no dev name, no
dev argument and no dev string, and the release binary is measured free of
the dev unit and the dev marker on every leg.

## Evidence

New four-target fields: `dev_corpus` and `dev_suite` (both must-PASS) plus
`dev_digest`, `dev_corpus_lines`, `dev_loop_model`, `cli_dev_available`,
`dev_option_matrix`, `advertised_commands_c2`, `build_still_unknown`,
`csp_identical`, `csp_transport_terms`, `dev_origin`,
`release_dev_unit_absent`, `dev_marker_in_release`, `dev_marker_in_dev`,
`dev_units_linked`, `dev_transport_hits`, `dev_conditionals`,
`dev_env_reads`, the `dev1`–`dev14` rows, the `dev5_burst_*` rows, the
`dev7_*`/`dev8_*` rows, `dev_interrupt_clean`, `dev_interrupt_mechanism`,
`dev_listener_members_max`, `dev_listener_members_seen`,
`dev_listener_sampler_scope`, `dev_loose_assets_used`, `dev_app_dir_names`,
`dev10_release_seeded`, `dev_sentinel_in_template` and
`c1_pipeline_digest_unchanged`.

Twenty-four new negative self-test legs (c55–c78) prove each new aggregator
refusal red on a fixture before the real aggregation is trusted with it; the
committed self-test reaches **160 aggregator refusals + 2 divergence
refusals** (136 + 2 before this shard). Two of them exist because running the
aggregate locally — from the four downloaded evidence artifacts — found holes
the four native jobs structurally cannot show: a leg that still perturbed
`pipeline_units_linked` in the direction CAP-10C2 inverted, and three verdict
fields that were pins but not must-PASS.

## Superseded, and recorded as superseded

| field | before | CAP-10C2 |
|---|---|---|
| `cli_digest` | `1341221d…dfdd208` | moved — the parser corpus records `args\|dev\|ok` and the `dev` option rows |
| the React inventory | `ef5c09d0…`/15/66355 | `ef9a9312…`/16/71416 — the sentinel's `pweb-build.d.ts` |
| the Pas2JS inventory | — | moved — the `PWEB_DEV` region, which belongs in BOTH templates |
| `pipeline_units_linked` | `false` | `true` — **inverted, not deleted**, and its negative leg with it |
| `advertised_commands` | `create,doctor,run` | `create,doctor,run,dev` |
| `dev_build_unknown` | `dev,build` | `build_only` |
| `pipeline_digest`, every `c1_app_pwb_*`, `doctor_schema_digest`, `supervision_digest` | | **unchanged**, re-measured |

## Freeze result

Seven interfaces, `TInvocationContext`, `ICapabilityPolicy`, the scheduler,
the mORMot bridge, the nine-code taxonomy, protocol v1, the SDK wire,
`app.pwb`, `plugins.zip`, `pweb.json` schema 1, the CAP-10A parser grammar,
doctor and exit taxonomy, the CAP-10B0 engine, the CAP-10C0 engine, `pweb
run`, its exit mapping and its layout, the CAP-10C1 ten stages and mutation
set, the CAP-8A policy core, the CAP-8B classifier and CSP, the CAP-9
runtime, the CAP-13 profiles and every dependency pin: **unchanged**. The
project-mutation set is unchanged — everything the loop writes was already
inside it. `check_dev_trust.ps1` PASS on every leg. The divergence sweep
re-ratifies at 202.

Two frozen surfaces moved, both with ratification recorded: the React and
Pas2JS templates (the sentinel and the `PWEB_DEV` region), and the WebKitGTK
and Cocoa adapters (`Cache-Control: no-store`, which the WebView2 adapter has
sent since CAP-4W).

## Known limitations / deferred

See `deferred-work.md` (CAP-10C2 entries): the model-A refusal and its data;
the adapter cache fix and the human ratification behind it; the reload drain;
the generation reclaim; the incremental dev compile; the closed-shard pins
`dev` now owns; the build scripts that guarded on the compiler's default
target; the DEV14 leg that only passed while its subject was broken; the
`csp_transport_terms` empty-value rule; the two aggregate holes; the
measurement error that drew three conclusions from a stale binary; and the
CAP-10C3 handoff.

**CAP-10C2 PASS — REACT DEVELOPMENT LOOP FROZEN**
