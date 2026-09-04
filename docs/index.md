# PWeb — the contract documents

Every rule this repository enforces is written down in exactly one place, and
this is the map of those places. Each document is a **contract**: the human
prose may be reworded freely, the grammars, layouts, digests, bounds and exit
codes may not, except by a version bump.

Nothing generates this file. It is maintained by hand, and a shard that adds
a contract document adds its row here — `test/cap10c3/check_cap10c_ledger.ps1`
requires every document below to be cross-linked.

## The kernel

| document | what it settles |
|---|---|
| [kernel.md](kernel.md) | the ratified contract and its companions, the architecture landmines, the seven frozen boundaries, threading, wire, security, assets and toolchain conventions |

The canonical contract itself is `_bmad-output/specs/spec-pweb/SPEC.md` plus
every companion in its frontmatter.

## The CLI and the lifecycle

| document | what it freezes | shard |
|---|---|---|
| [cli-contract.md](cli-contract.md) | the public command surface, `pweb.json` schema 1, the `doctor` report, the six exit codes, the reusable runtime-command layer, and §5 the development-trust decision | CAP-10A, 10B1, 10B2, 10C0, 10C2, 10C3 |
| [template-contract.md](template-contract.md) | the scaffold engine, the trusted template pack, the identity mapping, the placeholder model and the atomic creation transaction | CAP-10B0 |
| [supervision-contract.md](supervision-contract.md) | the one child-process engine: exact path, argument vector, explicit working directory, no shell, graceful-then-forced, drained by membership | CAP-10C0 |
| [pipeline-contract.md](pipeline-contract.md) | the ten-stage lifecycle pipeline, the SDK root, the project-mutation set, the network policy and the Pas2JS assembly | CAP-10C1 |
| [dev-contract.md](dev-contract.md) | the development loop for both frontends: the dev host, the generation, publish-by-rename, the poller, the acknowledgement, and the two change detectors | CAP-10C2 (React), CAP-10C3 (Pas2JS) |
| [build-contract.md](build-contract.md) | the public `pweb build`: its grammar and the options it deliberately does not have, the one execution path, the release replacement rule and its failure table, the summary, and interruption | CAP-10D0 |

`_bmad-output/implementation-artifacts/cap10c-closure-artifact.md` is the
CAP-10C phase closure: the four hosted green runs, every digest supersession,
a disposition for every deferred item, and the CAP-10D handoff.

## The platform semantics

| document | what it records |
|---|---|
| [webview-upstream-semantics.md](webview-upstream-semantics.md) | the pinned `webview/webview` surface and its error paths |
| [webkitgtk-linux-semantics.md](webkitgtk-linux-semantics.md) | what WebKitGTK 4.1 does, measured |
| [wkwebview-macos-semantics.md](wkwebview-macos-semantics.md) | what WKWebView does, measured |
| [third-party-licenses.md](third-party-licenses.md) | every dependency this product ships and the licence it ships under |
