---
title: 'CAP-9C2 — Plugin-enabled GUI host, platform release layouts and CAP-9 closure'
type: 'feature'
created: '2026-08-26'
status: 'ready-for-dev'
review_loop_iteration: 0
baseline_commit: '61c7a46f96dad0992280ff7c31ded0b4241f7b92'
context:
  - '{project-root}/docs/kernel.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/security-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/threading-model.md'
  - '{project-root}/_bmad-output/specs/spec-pweb/deployment.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9c1-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap9b2-final-artifact.md'
  - '{project-root}/_bmad-output/implementation-artifacts/cap8-final-artifact.md'
---

<frozen-after-approval reason="human-owned intent — ratified at Checkpoint 1, items 1-5">

## Intent

**Problem:** CAP-9C1 froze a deterministic native-only plugin package and the
trusted loader that consumes it, but ships no host: nothing yet puts a real
WebView UI and isolated QuickJS plugins in ONE process, over ONE scheduler,
ONE CAP-8 policy, ONE bridge and ONE mORMot server, in a real platform
release layout. Two of C1's browser-invisibility claims are proven only
indirectly for exactly that reason.

**Approach:** Add a dedicated plugin-enabled acceptance application under
`examples/07-quickjs`, assemble it into an exact release layout on all four
targets, and prove the combined topology from a real platform WebView —
including the browser-invisibility, cross-store, containment, reload and
shutdown gates — then close CAP-9.

## Boundaries & Constraints

**Always:**
- One scheduler, one CAP-8 policy, one bridge/decorator chain, one mORMot
  server, one error taxonomy. The WebView and QuickJS are invocation
  SOURCES only; object identity is MEASURED, never asserted.
- `app.pwb` and `plugins.zip` are independent security domains: the browser
  handler owns only the app store, the package manager owns only the plugin
  store, no shared mutable store variable, no cross-store fallback.
- Every path resolves from the executable / application-bundle location,
  never the CWD.
- Whole-archive integrity/inventory/registry failure refuses the COMPLETE
  package before any service, scheduler, engine or WebView exists.
- Past that gate, one plugin's failure fails only that plugin and is
  recorded explicitly.
- `AppMaximum = {calculator.add, external.open, parking.read}`; calculator
  holds `calculator.add`, reporting holds `parking.read`, neither holds
  `external.open`, filesystem, process or network.
- PrincipalIds stay `plugin:calculator` / `plugin:reporting`; PluginIds stay
  `quickjs.calculator` / `quickjs.reporting`. They are principal
  identifiers and are NOT validated through the capability-name grammar.
- `examples/04-react/**` and `examples/08-release/releaseapp.pas` stay
  byte-untouched.

**Ask First:**
- Any change to a frozen interface, to `plugins.zip`/`plugin.json`/the B1
  module contract/the B2 lifecycle contract, or to the CAP-13 installer
  profiles.
- Any new public interface, native WebView export, or RPC method.

**Never:**
- Plugin discovery, directory scanning, file watching, automatic reload,
  installation, update, signed third-party packages, a public package
  format or a public CLI.
- A plugin-management API reachable from JavaScript; a plugin URL scheme;
  mounting `plugins.zip` under any `pweb://` authority.
- Plugin files inside `app.pwb`; filesystem/network/process APIs in
  QuickJS; a second scheduler, policy or bridge; CAP-10 CLI work.
- Shipping the generated registry include as a runtime file.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Combined happy path | verified `app.pwb` + `plugins.zip` beside the executable | UI `Add`=42 and calculator plugin `Add`=42 through the SAME scheduler/policy/bridge/server | N/A |
| Denied plugin | reporting plugin calls `CalculatorService.Add` | `forbidden`/403 pre-bridge; denied bridge and SOA deltas both 0 | typed error only |
| Browser asks for plugin bytes | 7 probe shapes from the trusted `pweb://app` page | every request not-found/refused; plugin-store arrivals 0; marker stays false | no bytes, no source text |
| Raw native channel | plausible plugin-read methods over the lowest raw transport | unmapped/forbidden; 0 plugin-store reads; no path, no digest, no bytes | typed error only |
| Missing/truncated/wrong-digest/inventory-mismatch/registry-mismatch/symlink/over-size `plugins.zip` | mutated staged release | nonzero exit, typed marker, `webviews_created=0`, `engines_created=0`, `soa_calls=0` | fail-closed before step 7 |
| Byte-valid archive, one plugin fails to evaluate | hostile fixture archive + matching fixture registry | `archive_valid=true running_plugins=1 failed_plugins=1 ui_ok=true` | failed plugin never published |
| CPU bound exceeded in the GUI process | reporting `runaway` export | `resource_limit`, generation tainted, next call `unavailable`, host `failed` | neighbour + UI unaffected |
| Reload in the GUI process | explicit B2 reload of the calculator | generation id changes, result stays 42, module/global state reset | old generation retired, no late completion |

</frozen-after-approval>

## Code Map

Frozen surface consumed unchanged (read-only):
- `src/script/pweb.script.release.pas` — `PWebVerifyQuickJSPackage`,
  `PWebRegistryFrom`, `TPWebPackageRegistry`, `PWEB_RELEASE_*`.
- `src/script/pweb.script.startup.pas` — `PWebStartQuickJSPackage`,
  `TPWebQuickJSPackageLoader` (`HostOf`, `ScopedStoreOf`, `StartResult`,
  `RunningCount`, `UnloadAll`), `PWebResolvePluginPackage`,
  `PWebPluginArchiveEntries`.
- `src/script/pweb.script.plugin.pas` — `TPWebQuickJSPluginHost`
  (`CallExport`, `Reload`, `ReloadTemplate`, `Unload`, `GenerationId`,
  `State`, `GraphProjection`, counters).
- `src/rpc/pweb.rpc.scheduler.pas:TInvocationScheduler` — note
  `TryGetSourceCounts` returns False for a source this scheduler did not
  create: that is the same-scheduler proof.
- `src/security/pweb.capabilities.policy.pas` — builder +
  `SnapshotCapabilities`.
- `src/platform/{windows,linux,macos}` — asset handler + navigation guard
  aliases; Cocoa's two-phase construct/Attach shape.
- `src/assets/pweb.assets.bundle.pas:PWebBundleLoadFile`.

Reference host to mirror in construction order (NOT to edit):
- `examples/08-release/releaseapp.pas:317-357` policy builder,
  `:824-905` construction, `:906-1000` WebView seam, `:1000-1100` teardown.

Corpus and tooling:
- `examples/07-quickjs/plugins.trusted`, `plugins/quickjs.*` — the shipped
  acceptance corpus this shard extends.
- `tools/quickjs/pwebqjspack.pas` — the private packager (unchanged).
- `build/quickjs-release/` — staged payload: `plugins.zip`,
  `pweb.quickjs.registry.inc`, `LICENSE.quickjs`, inventory, build info.

Gates to extend:
- `test/cap7f/emit_evidence.ps1:553-700` / `emit_evidence.sh` — new fields.
- `test/cap7f/check_cap7f_aggregate.ps1:56-300` — compare + refuse.
- `test/cap7f/check_cap7f_selftest.ps1` — negative legs.
- `test/cap7f/check_divergence.ps1:66-75` — allowlist + swept roots.
- `.github/workflows/ci.yml` — 4 platform jobs + `cap7-aggregate`.

## Tasks & Acceptance

**Execution:**
- [ ] `examples/07-quickjs/plugins/quickjs.calculator/lib/arith.js` — add the guarded browser-execution marker — the leaf module is the only one that would evaluate cleanly as a module script, so the marker is meaningful there.
- [ ] `examples/07-quickjs/plugins/quickjs.calculator/main.js` — add `env` and `memhog` exports — QuickJS-side absence proof and the memory containment leg.
- [ ] `examples/07-quickjs/plugins/quickjs.reporting/main.js` — add `alive` (`pweb.handshake`) and `runaway` exports — liveness for the denied principal and the authoritative CPU containment leg.
- [ ] `examples/07-quickjs/plugins.trusted` — document the C2 acceptance exports — the trusted list stays self-describing; no new key, no capability, no bound.
- [ ] `examples/07-quickjs/frontend/**` — new React frontend importing the canonical CAP-5 `App` unmodified plus `PluginProbes` — CAP-8 corpus preserved by construction, CAP-9C2 probes added.
- [ ] `examples/07-quickjs/quickjsapp.pas` — the shipped plugin-enabled host — the acceptance artifact.
- [ ] `test/cap9c2/quickjsgui.pas` — real-GUI hostile-package harness — the only honest way to reach `running=1 failed=1`.
- [ ] `test/cap9c2/run_quickjsgui.ps1` / `.sh` — per-target build, layout assembly, positive + negative legs, corpus/JSON emission.
- [ ] `test/cap7f/*` — emitters, aggregator, selftest, divergence allowlist.
- [ ] `.github/workflows/ci.yml` — four platform jobs + aggregation.
- [ ] `docs/third-party-licenses.md` — factual QuickJS section — a new licence now ships.
- [ ] `_bmad-output/implementation-artifacts/deferred-work.md` — ledger C2 scope decisions.

**Acceptance Criteria:**
- Given the staged release layout on each of the four targets, when `quickjsapp` runs from an unrelated CWD, then the exact-set layout gate passes (files, directories, symlinks) and the structured verdict reports every field of the ratified GUI corpus.
- Given a UI invocation and a plugin invocation in the same process, when both complete, then the scheduler answers `TryGetSourceCounts` True for BOTH sources and a second equally-configured scheduler answers False for both.
- Given the four targets, when the aggregator runs, then `quickjs_gui_corpus` reads PASS everywhere and one `quickjs_gui_digest` is equal on all four.
- Given the CAP-9A/B1/B2, CAP-8 and CAP-7 corpora, when the closure run completes, then their digests are byte-identical to their recorded closure values.

## Design Notes

**Object-identity tokens.** A host-private table maps an object to a small
monotonic id in first-seen order, so the corpus records `bridge_token=1`
observed from both a `pkWindow` and a `pkQuickJS` invocation without ever
printing an address. `same_scheduler` is stronger: it is answered by the
scheduler itself through `TryGetSourceCounts`, with a decoy scheduler
proving the predicate discriminates.

**Two report channels.** The page sends `example.report` (the unmodified
CAP-5/CAP-8B verdict) and `example.pluginProbe` (the CAP-9C2 browser
corpus). Both are zero-cap registered; the host latches PASS only when both
arrive green. This keeps `examples/04-react/**` byte-untouched, so every
existing `app.pwb` hash and logical-inventory gate is unaffected.

**Counting store wrappers.** `app.pwb` and `plugins.zip` are each wrapped in
a counting `IAssetStore` decorator before they are handed out, so
`browser_plugin_store_arrivals` / `quickjs_app_store_arrivals` are measured
numbers rather than the absence of a code path.

**Corpus supersession.** Extending the shipped plugins intentionally moves
`cap9c1_inventory_digest`, `quickjs_release_digest`, both graph digests, the
per-target `plugins.zip` hashes and the generated registry bytes. The C2
artifact records the previous AND new values with the reason for each; the
C1 package/integrity CONTRACT is unchanged and its full gate is re-run
against the extended corpus.

## Verification

**Commands:**
- `pwsh -File test/cap9c1/run_quickjsrelease.ps1` — expected: PASS against the extended corpus.
- `pwsh -File test/cap9c2/run_quickjsgui.ps1` — expected: PASS, corpus + JSON written.
- `pwsh -File test/cap7f/check_divergence.ps1` — expected: allowlist holds with the new roots.
- `pwsh -File test/cap7f/check_cap7f_selftest.ps1` — expected: every new refusal branch proven red.
