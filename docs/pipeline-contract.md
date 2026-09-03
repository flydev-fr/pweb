# The lifecycle-pipeline contract (CAP-10C1)

The `pweb` CLI turns a generated project into the CAP-10C0 run layout through
**one** ordered pipeline, `tools/pweb/pweb.cli.pipeline.pas`, over the five
plan builders beneath it and over the **one** child-process engine
(`pweb.cli.process.pas`, [supervision-contract.md](supervision-contract.md)).

The pipeline was **private** at CAP-10C1: `pweb --help` advertised `create`,
`doctor` and `run`, and `test/cap10c1/check_cap10c1_contracts.ps1` measured
the pipeline units' ABSENCE from the shipped executable's compiled unit set
at the link.

**CAP-10C2 made it public.** `pweb dev` runs these prerequisites — the
toolchain refusal, the SDK staging, a conditional `npm ci`, one `tsc`, and
the frozen bundler — so every unit named below is now linked into `pweb`,
and that same measurement is required to come out the other way. Nothing
about the ten stages, the mutation set, the network policy or the failure
semantics moved; `docs/dev-contract.md` records what the development loop
adds on top. CAP-10D will expose the whole of it as `pweb build`, which is
**still an unknown command** and exits 2.

## 1. The units, and why they are shaped this way

| unit | role |
|---|---|
| `pweb.cli.sdkroot` | what an installed SDK holds, and where |
| `pweb.cli.toolset` | node / npm / fpc / pas2js, resolved once |
| `pweb.cli.stage` | the pipeline's file operations and the TypeScript SDK rule |
| `pweb.cli.frontend` | the frontend plans, and the Pas2JS static assembly |
| `pweb.cli.pack` | the `app.pwb` argument contract |
| `pweb.cli.native` | the `fpc` argument vector, per target |
| `pweb.cli.layout` | the release layout, committed by rename |
| `pweb.cli.pipeline` | the ordered stage machine — **the only caller of the engine** |

Every unit except `pweb.cli.pipeline` is a **pure plan builder** or a file
operation: it produces `(exact executable path, argument vector, explicit
working directory)` and never spawns anything. Two consequences, both wanted:

- the whole **four-target command matrix** can be asserted from any single
  target, which is how a Linux runner proves what the macOS arm64 link line
  will be — the same property CAP-10C0 used for the Windows quoting rule;
- no pipeline unit carries a platform conditional, so none of them is on the
  CAP-7F divergence allowlist. The target arrives as
  `(TPWebCliOs, TPWebCliArch)` and the branch is ordinary runtime code.

## 2. The SDK root

```
<root>/bin/pweb[.exe]                            the anchor (CAP-10B0)
<root>/bin/pwebbundle[.exe]                      the frozen CAP-6 bundler
<root>/share/pweb/pweb-templates.zip             the trusted pack
<root>/share/pweb/src/{lib,rpc,security,webview,assets,platform/<os>}
<root>/share/pweb/sdk/typescript/                the pinned TypeScript SDK
<root>/share/pweb/sdk/pas2js/pweb.native.pas
<root>/share/pweb/deps/mormot2/src/              mORMot, from the INSTALLATION
<root>/share/pweb/deps/mormot2/static/<fpc-target>/
<root>/share/pweb/lib/<os>-<arch>/               the platform artifacts
```

The root is resolved from the **running image** by the one CAP-10B0 anchor
rule (`<sdk>/bin/pweb` → `parent(dir(image))`); every component below it is
walked one at a time through `PWebCliEntry`, so a junction cannot redirect
mORMot and a case variant cannot resolve. There is no `PWEB_SDK`, no
`PWEB_HOME` and no `PWEB_MORMOT`: a build tool that can be pointed at a
different framework by exporting a variable is a build tool whose trusted
input is whatever the last shell profile said it was.

`<os>-<arch>` is the CAP-10C0 target name (`windows-x86_64`, `linux-x86_64`,
`macos-x86_64`, `macos-arm64`); `<fpc-target>` is mORMot's own static
directory naming (`x86_64-win64`, `x86_64-linux`, `x86_64-darwin`,
`aarch64-darwin`). Two namings of one target is a fact about the dependency,
and each is written down exactly once.

**Windows ships a CAP-3U-patched mORMot.** `tools/patch-cap3u.ps1` needs MSVC's
`ml64` and a mORMot *git checkout*, and it edits that checkout in place. The
patch is therefore applied once at staging time and the patched source travels
into the SDK root with its `x64callmethod.obj`; the build path has no patch
window and never edits a framework checkout. `static/delphi` is staged on
Windows only, because two objects a Win64 build links are reached from inside
mORMot's own sources by a relative path.

## 3. The ten stages

| # | stage | react | pas2js |
|---|---|---|---|
| 1 | `open` | the CAP-10A project, strict-parsed | same |
| 2 | `toolchain` | resolve everything; **refuse before any write** | same |
| 3 | `stage_sdk` | materialise the TypeScript SDK | — |
| 4 | `install` | `node <npm-cli.js> ci …` | — |
| 5 | `typecheck` | `node …/typescript/bin/tsc -p tsconfig.json` | — |
| 6 | `build` | `node …/vite/bin/vite.js build` | `pas2js …` + the assembly |
| 7 | `pack` | `pwebbundle <dist> <output>/<target>/app.pwb` | same |
| 8 | `compile` | `fpc …` against the SDK root | same |
| 9 | `layout` | assemble and commit by rename | same |
| 10 | `verify` | the CAP-10C0 resolver accepts what was committed | same |

Ordered and **resumable by design** — each stage's inputs are the previous
stage's outputs on a disk — but **not resuming** at C1: every run does every
stage of its UI. Resumption is a decision about staleness, and a build tool
that guesses what is still fresh is a build tool that ships a stale artifact.

### Bounds

Stated once in `tools/pweb/pweb.cli.toolchain.pas`; this table is
cross-checked against the constants by `check_cap10c1_contracts.ps1`.

| constant | value |
|---|---|
| `PWEB_CLI_PIPE_NPM_MS` | 600000 |
| `PWEB_CLI_PIPE_TSC_MS` | 300000 |
| `PWEB_CLI_PIPE_BUILD_MS` | 300000 |
| `PWEB_CLI_PIPE_PACK_MS` | 120000 |
| `PWEB_CLI_PIPE_FPC_MS` | 900000 |
| `PWEB_CLI_PIPE_MAX_FILE_BYTES` | 268435456 |
| `PWEB_CLI_PIPE_MAX_TREE_FILES` | 4096 |
| `PWEB_CLI_PIPE_MAX_TREE_DEPTH` | 24 |

### The Pas2JS assembly

The compiler writes through the host's text layer, and CAP-10B2 measured the
consequence: on Windows `app.js` begins `EF BB BF` and carries CRLF, on POSIX
it carries LF. The pipeline strips the BOM and removes **every** CR — every
one, not only those in a CRLF pair, because a rule that treats a lone CR
differently on two platforms is a comparer disagreement in disguise — then
writes `assets/boot.js` as `rtl.run();\n` byte-exactly and places
`index.html` and `assets/app.css`. Without that normalisation the Pas2JS
`app.pwb` is an OS-family artifact and its four-target semantic digest is
unsatisfiable by construction.

## 4. The project-mutation set

A pipeline may write in exactly four places:

```
<root>/frontend/.pweb/          the staged SDK      (react)
<root>/frontend/node_modules/   npm ci              (react)
<root>/frontend/dist/           vite build          (react)
<root>/<output>/                everything else     (both)
```

Everything else in the project is **read-only**, and that is measured rather
than asserted: the tree minus those four prefixes is digested before the first
stage and after **every** stage, and any change stops the pipeline with
`pipeline_mutation` (exit 6). The exclusion is matched on a component
boundary, so `frontend/dist` excludes that directory and never
`frontend/dist-backup`.

Nothing outside the project root is written by the pipeline itself — the
toolchain's own children use the OS temp directory, which is theirs — and the
SDK root is read-only to a build, digested before and after by the gate.

## 5. The network, and lifecycle scripts

**Exactly one stage may reach the network: `npm ci`, for a React project.**

```
node <npm-cli.js> ci --no-audit --no-fund --ignore-scripts
```

- `ci`, never `install`: the committed `package-lock.json` is authoritative,
  and `install` would resolve floating ranges and make the product different
  on every machine;
- `--ignore-scripts` is ratified against a **measurement** of the pinned tree,
  not a precaution: exactly one package in it carries an install script —
  `fsevents@2.3.3`, dev and optional and `os: ["darwin"]`, reached only by the
  dev watcher and never by `vite build`. The gate re-counts
  `"hasInstallScript": true` in the generated lockfile on every leg, so the
  day the pinned tree grows a second one the ratification is re-opened rather
  than silently outgrown;
- `@pweb/runtime` is a project-relative `file:` specifier that npm **links** to
  `frontend/.pweb/sdk/typescript`. No registry ever answers for that name, and
  the gate reads the reparse **target** rather than the manifest that asked
  for it;
- a package-manager configuration file inside the project (`.npmrc`,
  `.yarnrc`, `.yarnrc.yml`, `.pnpmfile.cjs`) is a **refusal**
  (`registry_override_present`, exit 3) before any stage runs. The templates
  ship none; this is the lock that makes that a rule rather than a habit.

A Pas2JS pipeline runs entirely offline and declares no network stage at all.

## 6. `npm`, through `node`

```
D = the directory of the canonical node executable
Windows   D\node_modules\npm\bin\npm-cli.js
POSIX     parent(D)/lib/node_modules/npm/bin/npm-cli.js
```

Each component is walked through `PWebCliEntry`; the resolved script is probed
as `node <npm-cli.js> --version`. On Windows npm's only entry point on PATH is
`npm.cmd`, a **batch file**, which the CAP-10C0 engine refuses before any
spawn on every platform — so `node <npm-cli.js>` is not a preference, it is the
only form that works without a shell. When the script is not where the rule
says, that is a refusal (`npm_cli_unresolved`, exit 4): a React build that
cannot install its dependencies has no slower path, it has no path.

Resolving an executable and handing `node` a script are different acts. The
CAP-10A rule "a candidate inside the project root is reported and never
executed" governs which binary a *name* means, and it is enforced for node,
fpc and pas2js. `tsc` and `vite` are packages the committed lockfile pins;
running them is what a frontend build *is*.

**A resolved path is not an argument.** This CLI canonicalizes Windows paths
into the extended-length form; `pweb.cli.platform` strips it for the
executable, argv[0] and the working directory, but the other arguments are the
caller's. Every path the pipeline puts into an argument goes through
`PWebCliArgPath`, and the pipeline refuses to spawn a vector that still
carries the prefix (`arg_longpath_form`). Measured: `node` given a prefixed
script path dies inside `realpathSync` with `EISDIR … lstat 'C:'`.

## 7. The native compile

S = `<sdk>/share/pweb`, M = `S/deps/mormot2`, L = `S/lib/<os>-<arch>`,
O = `<root>/<output>/<os>-<arch>`:

```
common   -MObjFPC -Sh -B -FU O/units -FE O/obj -Fu <root>/src
         -Fu S/src/{lib,rpc,security,webview,assets} -Fu S/src/platform/<os>
         -Fi M/src -Fu M/src/{core,lib,crypt,net,db,orm,rest,soa}
         -Fl M/static/<fpc-target>
windows  -Px86_64 -Twin64 -Xm
linux    -Fl L -k-rpath=$ORIGIN -k-lgcc_s
macos    -WM<PWEB_CLI_MACOS_MIN> -Fl L -k-rpath -k@executable_path
         -k-L L -k-lwebview -k L/pweb_cocoa_bridge.o
         -k-framework -kCocoa -k-framework -kWebKit -k-lc++ -k-lobjc
         [aarch64 only] -k-no_fixup_chains
last     <root>/src/<ident>.lpr
```

**No compiler flag comes from `pweb.json`.** Schema 1 has no toolchain model
and deliberately no place for one: a descriptor that could add a `-k` would be
a descriptor that could add a linker argument.

The compiler's own default target (`fpc -iTO` / `-iTP`) is recorded on every
platform and **refused** on Linux and macOS only, because there no `-P`/`-T` is
passed and the default *is* the target. On Windows one installation routinely
carries both compilers and the command selects explicitly.

## 8. The release layout

```
<root>/<output>/<os>-<arch>/release/
  windows, linux    <ident>[.exe]  app.pwb  <webview library>
  macos             <ident>.app/Contents/MacOS/<ident>
                    <ident>.app/Contents/MacOS/<webview library>
                    <ident>.app/Contents/Resources/app.pwb
                    <ident>.app/Contents/Info.plist
```

The logical paths are not restated: `PWebCliRunLogicalLayout` is the one place
the rule lives, and the committed directory is re-resolved through the
**CAP-10C0 resolver itself**. A layout the pipeline assembled and `pweb run`
refuses is a defect this pipeline must discover, not one a user should.

The release is assembled in a sibling `.pweb-release.tmp` and committed by a
rename that must not replace. An existing release is renamed aside first and
reclaimed after the commit, so the only intermediate state is *no* release —
which `pweb run` reports as `not_built`, a correct answer — and never a
mixture of two builds. Nothing is removed except a directory this pipeline
created, through the guarded `PWebCliRemoveStagedTree`.

Every `Info.plist` value comes from the descriptor, and none of them can carry
an XML metacharacter: schema 1's grammars are `^[a-z][a-z0-9]*$` for the
program identifier, a dotted lowercase form for the bundle identifier, and
strict `X.Y.Z` for the version. There is no escaper because there is nothing
in the input alphabet to escape.

## 9. Failure, interruption, and the exit categories

| code | meaning |
|---|---|
| 0 | every stage of this UI ran and the layout verified |
| 2 | the driver was invoked wrongly |
| 3 | the project, its descriptor, its paths or its layout |
| 4 | the machine cannot build it: the doctor refused, or a tool is missing, unrunnable or the wrong target |
| 5 | a stage's child failed, died, or was stopped |
| 6 | an invariant of the pipeline itself broke |

On a stage failure the pipeline stops at once: no later stage runs, the child's
**real typed status** is reported (an exit code is an exit code, a signal is a
signal, a forced termination is a forced termination — never all three
flattened to "failed"), the engine drains the tree by membership, and no
release directory exists because the layout stage never runs.

A stop request — Ctrl+C, `SIGINT`, `SIGTERM`, `SIGHUP` — travels through the
engine's own graceful-then-forced ladder into the running child tree and is
then observed between stages, so an interrupted build stops within one stage's
bound and leaves the same nothing a failure leaves.

**When `doctor` already refuses the environment the pipeline refuses with the
same cause**, at stage 2, before anything is written. The pipeline runs the
CAP-10A requirement graph rather than re-implementing its version checks: two
answers to one question is how a build and a diagnosis start disagreeing about
the same machine.

## 10. What the pipeline does not do

It starts no watcher, no development server, no proxy, no HMR transport and no
listener; it adds no `ws://`, `localhost` or `127.0.0.1` allowance anywhere; it
changes no CSP and no privileged origin; it modifies no generated **source**
file; it vendors neither PWeb nor mORMot into a project. Each of those is a
property of what these units do not link or do not write, and each is measured
rather than promised.
