# CAP-15A — the outbound-network measurement spike

**This directory is a measurement instrument, not product code.** Nothing here
is linked by a host, shipped in an artifact or **run** by a CI gate — a run
compiles a binary whose `connect-src` has been widened, and a gate that
compiles a widened CSP is a gate that can normalise one. Two files are
nonetheless *read* on every hosted Windows leg: section 5b of
`test/backlog/check_backlog.ps1` asserts that both runners still validate a
delete target against `build` (ledger `15A-13`), that nothing under `.github`
names this directory, and that the `connect-src` needle both runners substitute
still occurs exactly once in the shipped policy — the last one because door B's
reopening condition 1 costs "one run per macOS architecture" only while the
instrument still fits the tree it reads. Reading is not running, and none of
those assertions builds anything. It exists to
answer TODO.txt #1 — *`PWEB_NATIVE_CSP` says `connect-src 'self'`, so a
frontend cannot reach a remote server; is PWeb an application platform, and
through which door?* — with measurements instead of opinions.

The verdict and every number it rests on are in
`_bmad-output/implementation-artifacts/cap15a-decision-artifact.md`. Read that
first; this file only says how to re-run the measurement.

## What it measures

One instrumented host runs the **same** probe page twice on the same engine:

| mode | compiled against | what it shows |
|---|---|---|
| `baseline` | the shipped `src/security/pweb.navigation.policy.pas` | the product as it stands: `connect-src 'self'` |
| `widened` | a **generated** shim of that unit whose `connect-src` also names the probe server's origin A | what a per-application CSP would open |

The shim is produced by the run script as **one exact substitution** of one
token in one constant, is asserted to match exactly once, and lives only under
`build/cap15a/shim/`. **Nothing widened is ever committed**: the repository
keeps the substitution rule so a reader can see that the two binaries differ by
one token and nothing else.

The host's `mode` is **derived from `PWEB_NATIVE_CSP` at runtime**, never from
an environment variable, so a report cannot claim a policy its binary does not
carry.

Production on the enforcement path, unchanged: the asset handler serving
`pweb://app`, the navigation guard, the scheduler, the CAP-8A capability policy
and the per-invocation effective snapshot. The spike parts are the CSP shim and
`TSpikeFetchBridge` — a `pweb.fetch` `IInvocationBridge` decorator in the exact
shape of the ratified `pweb.rpc.command.pas` layer, built to be measured rather
than shipped.

`probe_server.js` (node, **no dependencies**) listens on two ports and appends
every request with its full header set to a JSONL log. That log is the
independent witness: the page can misreport, and a `no-cors` request is
unreadable to it, but a request that reached a socket is in the log. **Origin B
is named by nothing** — not the CSP, not the native allowlist — so a refusal is
measured as an absence rather than inferred from a rejected promise.

`summarize.js` joins the host reports with the wire log and is the **one** place
the measurement is interpreted; the two run scripts differ only in how they
build and run.

## Running it

```
# Windows / WebView2
pwsh test/cap15a/run_cap15a.ps1 [-PublicHttps https://httpbin.org/get]

# Linux / WebKitGTK  (WSLg, a real session, or under xvfb-run -a)
test/cap15a/run_cap15a.sh [--public-https https://httpbin.org/get]

# macOS / WKWebView  (same script; NOT YET RUN — see the artifact)
test/cap15a/run_cap15a.sh --public-https https://httpbin.org/get
```

Prerequisites are the CAP-8B ones, because the build recipe is CAP-8B's:
`build/webview-dist/webview.dll` on Windows, `build/cap7l/webview-dist` on
Linux (`tools/build-webview-so.sh`), the staged dylib plus the Cocoa bridge
object on macOS. `node` must be on `PATH`. `--public-https` is optional: it
adds one real-internet origin to both the widened CSP and the native allowlist,
and without it those two rows record `na` rather than guessing.

Outputs, all under `build/cap15a/`:

```
<target>-baseline.json / <target>-widened.json    the host reports
requests-<target>-baseline.jsonl / -widened.jsonl the server's wire witness
summary-<target>.json                             the joined evidence
```

## The one thing this spike asserts

Everything is recorded; only one row is graded, and it is about the **shipped**
product: in `baseline` mode **no request the engine issued reached a socket**,
while the native door reached the server anyway. `summarize.js` exits nonzero
if that stops being true. Every other row is a measurement — a measurement
shard reports what an engine does, it does not grade it.

## Disposition

Kept or deleted by ratified decision at CAP-15B, per the artifact's FREEZE
section. If door A ships, the parts worth keeping are `probe_server.js` and the
`pweb.fetch` rows of the driver, as the seed of a headless transport test with
no socket at all.
