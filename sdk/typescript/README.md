# @pweb/runtime — PWeb TypeScript SDK (CAP-5)

Thin, dependency-free adapter over the native PWeb invocation primitive
(the CAP-2 binding's `__pweb_invoke` JS global). No HTTP client, no
fallback transport, no capability logic — SDK responsibility ends at the
primitive.

```ts
import { handshake, invoke, PWebError } from "@pweb/runtime";

const info = await handshake();            // protocol gate: {1} supported
const value = await invoke<number>(
  "CalculatorService.Add",                 // byte-exact, case-sensitive
  { a: 20, b: 22 },                        // named args only; keys are API
);
// value === 42; success may be ANY JSON value, null included
```

- Errors reject as `PWebError { code, status, data }`; `code` (the nine
  frozen protocol v1 codes) is the only discriminator, `status` is
  informative. `service_error` keeps its structured `data`; `busy` keeps
  retry metadata; malformed native rejections map to a generic local
  `internal_error`.
- Absent primitive (plain browser) ⇒ immediate `runtime_closed`
  rejection; there is no fallback transport.
- `handshake()` rejects `protocol_mismatch` for unsupported/malformed
  runtimes; its `capabilities` and `features` are advisory metadata, never
  authorization.

## Signals (CAP-16)

Native code says that a topic moved; the page reads what changed through
`invoke`. A signal carries the topic and a sequence number only, so a lost
one costs latency, never correctness.

```ts
import { invoke, onSignal } from "@pweb/runtime";

let cursor = 0;
async function refresh(): Promise<void> {
  const page = await invoke<{ next: number }>("Jobs.Since", { since: cursor });
  cursor = page.next;      // YOUR cursor is the truth; the sequence is a wake-up
}

const jobs = onSignal("jobs", () => void refresh());
await jobs.ready;          // subscribed (needs the capability signal.jobs)
await refresh();           // read everything ONCE, after subscribing
// ... later: jobs.off();
```

- `onSignal(topic, cb)` subscribes natively on its topic's first callback;
  `ready` resolves with the current sequence or rejects with a `PWebError`
  (`forbidden` for an undeclared or unauthorised topic).
- `lastSeq(topic)` is the last sequence seen; a pair that is not newer is
  ignored, whatever order it arrived in.
- A signal emitted before the subscription, during a navigation or during a
  `pweb dev` reload may be lost; the re-read after `ready` recovers it. A
  revoked subscription is gone natively: `off()` every callback and
  subscribe again to hear the topic once the capability is back.
- `PWebSocket` receives on the runtime's `pweb.socket` topic (or every 20 s)
  and never holds a native worker while a socket is quiet.

Build & test (Node, pinned lockfile):

```powershell
cd sdk/typescript
npm ci
npm test        # tsc build + node:test suite
npm run capture # emits wire captures for the cross-SDK parity gate
```
