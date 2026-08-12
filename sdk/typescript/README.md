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
  runtimes; its `capabilities` are advisory metadata, never authorization.

Build & test (Node, pinned lockfile):

```powershell
cd sdk/typescript
npm ci
npm test        # tsc build + node:test suite
npm run capture # emits wire captures for the cross-SDK parity gate
```
