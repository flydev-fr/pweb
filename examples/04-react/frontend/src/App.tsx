/* PWeb CAP-5 React acceptance app.
 *
 * A real React component tree that talks to the backend EXCLUSIVELY
 * through the @pweb/runtime SDK - never through the raw CAP-2 primitive.
 * Flow: pweb.handshake (protocol gate) -> CalculatorService.Add
 * {a:20,b:22} -> render the 42 -> report the machine verdict to the host
 * through the same SDK. */
import { useEffect, useState } from "react";
import { handshake, invoke, PWebError } from "@pweb/runtime";

interface Verdict {
  ok: boolean;
  handshake: boolean;
  secure: boolean;
  rendered: boolean;
  rpc: boolean;
  errmap: boolean;
  value?: number;
  error?: string;
}

export function App(): JSX.Element {
  const [display, setDisplay] = useState<string>("running…");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const verdict: Verdict = {
        ok: false,
        handshake: false,
        secure: window.isSecureContext === true,
        rendered: true, // this effect only fires after React committed the tree
        rpc: false,
        errmap: false,
      };
      try {
        const info = await handshake();
        verdict.handshake = info.protocol === 1 && info.runtime.length > 0;
        const value = await invoke<number>("CalculatorService.Add", {
          a: 20,
          b: 22,
        });
        verdict.value = value;
        verdict.rpc = value === 42;
        // real-rejection probe: an unregistered method must surface
        // through the REAL binding+shim as a typed method_not_found
        try {
          await invoke("No.SuchMethod", null);
        } catch (err) {
          verdict.errmap =
            err instanceof PWebError &&
            err.code === "method_not_found" &&
            err.status === 404 &&
            err.data === null;
        }
        verdict.ok =
          verdict.handshake &&
          verdict.secure &&
          verdict.rendered &&
          verdict.rpc &&
          verdict.errmap;
        if (!cancelled) {
          setDisplay(verdict.ok ? `CalculatorService.Add(20, 22) = ${value}` : "FAILED");
        }
      } catch (err) {
        verdict.error = err instanceof Error ? `${err.name}: ${err.message}` : "unknown";
        if (!cancelled) {
          setDisplay(`FAILED: ${verdict.error}`);
        }
      }
      try {
        await invoke("example.report", { ...verdict });
      } catch {
        // the report channel itself failing is the host's problem to notice
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main>
      <h1>PWeb CAP-5: React over pweb://app</h1>
      <p>
        React → TypeScript SDK → native primitive → scheduler → policy →
        mORMot
      </p>
      <div id="result">{display}</div>
    </main>
  );
}
