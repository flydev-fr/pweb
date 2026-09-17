# pweb.native — PWeb Pas2JS SDK (CAP-5)

Thin adapter over the SAME native primitive the TypeScript SDK wraps —
same wire, same binding, same scheduler, same policy, same bridge. No
special Pascal payload, method grammar, or serialization exists; the
captured-wire parity gate in CI proves semantic equality per call.

```pascal
uses JS, pweb.native;

procedure Run; async;
var
  info, v: JSValue;
begin
  info := await(JSValue, PWebHandshake);           // protocol gate
  v := await(JSValue, PWebInvoke('CalculatorService.Add',
    New(['a', 20, 'b', 22])));                     // named args only
  // v = 42; success may be ANY JSON value, null included
end;
```

- Entry points return `TJSPromise`; rejections are converted inside the
  SDK to typed `EPWebError` (Code/Status/Data), so `await` sites catch
  `on E: EPWebError`. Promise semantics on the wire are identical to
  TypeScript — the difference is language ergonomics only.
- Absent primitive ⇒ immediate `runtime_closed`; malformed rejections ⇒
  generic local `internal_error`; unsupported/malformed handshake ⇒
  `protocol_mismatch` with advisory-only capabilities.

Signals (CAP-16), the twin of `onSignal` in `@pweb/runtime`:

```pascal
var
  jobs: TPWebSignalSubscription;
begin
  jobs := PWebOnSignal('jobs',
    procedure(ASeq: NativeInt; const ATopic: String)
    begin
      Refresh;                                      // read since YOUR cursor
    end);
  await(JSValue, jobs.Ready);                       // needs signal.jobs
  Refresh;                                          // read everything ONCE
end;
```

A signal carries a topic and a sequence number only (`PWebLastSeq` is the
last one seen); one lost before the subscription or across a navigation is
recovered by that re-read. `TPWebSocket` receives on the runtime's
`pweb.socket` topic, or every 20 s, and holds no native worker while quiet.

Compile with the pinned toolchain (`pwsh tools/get-pas2js.ps1` →
`deps/pas2js`). Semantic suite (run under node):

```powershell
deps/pas2js/bin/pas2js.exe -Tnodejs -Jc -O1 -Fusdk/pas2js sdk/pas2js/test/pwebsdktests.pas
node sdk/pas2js/test/pwebsdktests.js   # expect: PWEBSDK: n/n PASS (all cases)
```
