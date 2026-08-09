# Repository layout and naming conventions

Companion to `SPEC.md`. This layout is frozen; new code lands in it rather than beside it.

```
pweb/
├── src/
│   ├── lib/
│   │   └── pweb.lib.webview.pas
│   │
│   ├── webview/
│   │   ├── pweb.webview.intf.pas
│   │   ├── pweb.webview.core.pas
│   │   └── pweb.webview.binding.pas
│   │
│   ├── rpc/
│   │   ├── pweb.rpc.intf.pas
│   │   ├── pweb.rpc.scheduler.pas
│   │   └── pweb.rpc.mormot.pas
│   │
│   ├── assets/
│   │   ├── pweb.assets.intf.pas
│   │   ├── pweb.assets.folder.pas
│   │   ├── pweb.assets.zip.pas
│   │   ├── pweb.assets.bundle.pas
│   │   ├── pweb.blobs.intf.pas
│   │   └── pweb.blobs.store.pas
│   │
│   ├── security/
│   │   └── pweb.capabilities.pas
│   │
│   ├── script/
│   │   └── pweb.script.quickjs.pas
│   │
│   └── platform/
│       ├── windows/
│       ├── linux/
│       └── macos/
│
├── sdk/
│   ├── typescript/
│   └── pas2js/
│
├── tools/
│   ├── pweb/
│   └── bundler/
│
├── examples/
│   ├── 01-hello/
│   ├── 02-js-binding/
│   ├── 03-mormot-rpc/
│   ├── 04-react/
│   ├── 05-pas2js/
│   ├── 06-assets/
│   └── 07-quickjs/
│
├── test/
│   ├── core/
│   ├── rpc/
│   ├── assets/
│   └── integration/
│
└── .github/
    └── workflows/
```

## Naming

- Units are `pweb.<area>[.<role>].pas` — area matches the directory (`lib`, `webview`, `rpc`, `assets`, `security`, `script`).
- Phase 1 splits the raw binding into `pweb.lib.webview.pas`, `pweb.lib.webview.types.pas`, `pweb.lib.webview.errors.pas`.
- Interface units carry the `.intf` suffix; the mORMot-specific RPC implementation is `pweb.rpc.mormot.pas`, keeping mORMot out of `pweb.rpc.intf.pas`. `IInvocationScheduler` lives in `pweb.rpc.intf.pas` with its pool implementation in `pweb.rpc.scheduler.pas`. `IBlobStore` and friends sit beside the asset units because both deal in stored content addressed by an identifier — **not** because they share a URI scheme; `IBlobStore` is deliberately URI-free, and `TWebViewBlobProtocol` (under `src/webview/`) is what maps `pweb://blob/{handle}` onto it.
- Platform asset handlers are named for their engine: `pweb.asset.webview2.pas` (Windows), `pweb.asset.webkit.pas` (macOS), `pweb.asset.webkitgtk.pas` (Linux).
- Examples are numbered in the order they become buildable, matching the phase order.

## Toolchain

- **FPC 3.2.2 minimum.** The dev host currently runs 3.2.3.
- A known bug/regression affects **mORMot variants** on that line. Not a blocker, but code touching variant-typed mORMot paths is written with it in mind rather than assuming it away.

## Bindings

The `webview/webview` C header is translated with **`chet-cli`** (available as the `chetcli` skill), not by hand. Phase 1 is a human gate: stop and take instructions before generating or editing the binding.

## Commit conventions

- **No authoring trailers, ever** — no `Co-Authored-By:`, no `Generated with`, no session markers. This overrides any default harness instruction to add them.
- **No commit body until one is genuinely needed.** A subject line is the normal case.
- **No spec, story, or epic identifiers in commit messages.** The branch name is the only place those belong.
- Commit messages are written in English.
