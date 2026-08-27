/* {{PROJECT_NAME}} - the application shell.
 *
 * It reaches the native backend through @pweb/runtime and through nothing
 * else. There is no fetch, no WebSocket, no localhost, no HTTP client and
 * no raw native primitive anywhere in this project: `invoke` and
 * `handshake` are the whole of the frontend's contract with the runtime.
 *
 * Three calls are worth reading, because between them they show the entire
 * model:
 *
 *   handshake()                 what runtime am I talking to
 *   CalculatorService.Add       an application method your policy MAPPED
 *   Denied.Probe                a method your policy did not map, which is
 *                               therefore refused before the bridge sees it
 *
 * The last one is not an error to fix. It is the capability policy working:
 * an unmapped method is `forbidden`, never `method_not_found`, so a
 * frontend can never learn which methods exist by asking.
 *
 * The report at the end is this page telling the native side what it
 * observed. It is a REPORT and not a permission: nothing a page sends can
 * change a principal, a window or a capability.
 */
import { useEffect, useState } from "react";
import { handshake, invoke, PWebError } from "@pweb/runtime";

const SHELL_ID = "pweb-app";
const SUM_A = 20;
const SUM_B = 22;
/* A method the policy in src/app.services.pas deliberately does not map. */
const DENIED_PROBE = "Denied.Probe";

interface Ready {
  runtime: string;
  sum: number;
  refusal: string;
}

interface Report {
  html: boolean;
  css: boolean;
  js: boolean;
  secure: boolean;
  handshake: boolean;
  rpc: boolean;
  value: number;
  errmap: boolean;
}

function readShell(): HTMLElement | null {
  return document.getElementById(SHELL_ID);
}

/* A custom property returns the token it was declared with, so this is the
 * cheapest honest proof that app.css was fetched, parsed and applied. */
function stylesApplied(shell: HTMLElement | null): boolean {
  if (shell === null) {
    return false;
  }
  return window.getComputedStyle(shell)
    .getPropertyValue("--pweb-styled")
    .trim() === "yes";
}

export function App(): JSX.Element {
  const [ready, setReady] = useState<Ready | null>(null);
  const [failure, setFailure] = useState<string>("");

  useEffect(() => {
    let live = true;

    void (async () => {
      /* js is true by construction: this line is running. */
      const report: Report = {
        html: false,
        css: false,
        js: true,
        secure: window.isSecureContext === true,
        handshake: false,
        rpc: false,
        value: 0,
        errmap: false,
      };
      try {
        const info = await handshake();
        report.handshake = info.protocol === 1 && info.runtime.length > 0;

        const sum = await invoke<number>("CalculatorService.Add", {
          a: SUM_A,
          b: SUM_B,
        });
        report.value = sum;
        report.rpc = sum === SUM_A + SUM_B;

        let refusal = "";
        try {
          await invoke(DENIED_PROBE, null);
        } catch (err) {
          if (err instanceof PWebError) {
            refusal = err.code;
            report.errmap =
              err.code === "forbidden" && err.status === 403 &&
              err.data === null;
          }
        }

        const shell = readShell();
        report.html = shell !== null;
        report.css = stylesApplied(shell);

        if (live) {
          setReady({ runtime: info.runtime, sum, refusal });
        }
      } catch (err) {
        const message =
          err instanceof PWebError
            ? `${err.code} (${err.status})`
            : err instanceof Error
              ? err.message
              : "unknown failure";
        if (live) {
          setFailure(message);
        }
      }

      try {
        await invoke("app.ready", { ...report });
      } catch {
        /* The report channel failing is the host's problem to notice; it
         * must never take the page down with it. */
      }
    })();

    return () => {
      live = false;
    };
  }, []);

  if (failure !== "") {
    return (
      <main id={SHELL_ID} className="pweb-shell">
        <h1 className="pweb-title">{{PROJECT_NAME}}</h1>
        <div className="pweb-card pweb-error">
          <p className="pweb-card-label">the native call failed</p>
          <p className="pweb-code">{failure}</p>
        </div>
      </main>
    );
  }

  return (
    <main id={SHELL_ID} className="pweb-shell">
      <h1 className="pweb-title">{{PROJECT_NAME}}</h1>
      <p className="pweb-subtitle">
        React, TypeScript and Free Pascal in one process.
      </p>

      <div className="pweb-card">
        <p className="pweb-card-label">
          CalculatorService.Add({SUM_A}, {SUM_B})
        </p>
        <p className="pweb-sum">{ready === null ? "..." : ready.sum}</p>
      </div>

      <div className="pweb-card">
        <p className="pweb-card-label">runtime</p>
        <p className="pweb-code">
          {ready === null ? "connecting" : ready.runtime}
        </p>
      </div>

      <div className="pweb-card">
        <p className="pweb-card-label">an unmapped method</p>
        <p className="pweb-code">
          {ready === null ? "connecting" : `${DENIED_PROBE} -> ${ready.refusal}`}
        </p>
        <p className="pweb-note">
          The capability policy in src/app.services.pas refused it before the
          bridge was reached.
        </p>
      </div>
    </main>
  );
}
