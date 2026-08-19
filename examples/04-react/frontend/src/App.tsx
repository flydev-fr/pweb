/* PWeb CAP-5 React acceptance app.
 *
 * A real React component tree that talks to the backend EXCLUSIVELY
 * through the @pweb/runtime SDK - never through the raw CAP-2 primitive.
 * Flow: pweb.handshake (protocol gate) -> CalculatorService.Add
 * {a:20,b:22} -> render the 42 -> report the machine verdict to the host
 * through the same SDK.
 *
 * CAP-8B adds the navigation-security block. Every fact in it is
 * OBSERVED by this page and reported; none of it is inferred from "the
 * page still works". The release host REQUIRES the block before it
 * latches PASS, while this page's own `ok` deliberately excludes it -
 * the same bundle also runs under the allow-all example hosts, which
 * install no navigation guard, exactly as `denied` already works.
 *
 * The pas2js acceptance page performs the identical probes, in the
 * identical order, and reports the identical member names. */
import { useEffect, useState } from "react";
import { handshake, invoke, PWebError } from "@pweb/runtime";

/* CAP-8B probe targets. `.invalid` is reserved by RFC 6761 and can never
 * resolve, so a regression that let one of these through would still
 * reach nothing - the failure is recorded, never acted on. */
const CSP_SCRIPT_PROBE = "https://blocked.invalid/pweb-csp-probe.js";
const WRONG_AUTHORITY_PROBE = "pweb://evil/index.html";
const SAME_ORIGIN_CONTROL = "/index.html";
const EXTERNAL_NAV_PROBE = "https://blocked.invalid/pweb-nav-probe";
/* http: is NOT in the ratified external allowlist (https and mailto
 * only), so this is a URI the native validator must refuse. */
const REFUSED_SCHEME_PROBE = "http://blocked.invalid/pweb-open-probe";
const EXTERNAL_OPEN_CAPABILITY = "external.open";

interface Verdict {
  ok: boolean;
  handshake: boolean;
  secure: boolean;
  rendered: boolean;
  rpc: boolean;
  errmap: boolean;
  denied: boolean;
  navExternalBlocked: boolean;
  navAuthorityBlocked: boolean;
  navCspBlocked: boolean;
  navOpenExternal: boolean;
  value?: number;
  error?: string;
}

export function App(): JSX.Element {
  const [display, setDisplay] = useState<string>("running…");

  useEffect(() => {
    let cancelled = false;

    /* The trusted document's own address, captured BEFORE anything can
     * navigate away from it: "the page is still on pweb://app" is only
     * a fact if the address it is compared against was recorded first. */
    const startHref = window.location.href;

    /* The CSP probe is armed before it can be violated. A blocked
     * external script is NOT provable from an error event - a script
     * from an unresolvable host errors either way - so the only honest
     * evidence is the policy-violation report itself. */
    let cspBlocked = false;
    const onViolation = (event: SecurityPolicyViolationEvent): void => {
      /* Chromium names the effective directive (script-src-elem),
       * WebKit names script-src; both were MEASURED naming one of them,
       * so match the family rather than a single spelling. */
      if (
        typeof event.violatedDirective === "string" &&
        event.violatedDirective.indexOf("script-src") === 0
      ) {
        cspBlocked = true;
      }
    };
    document.addEventListener("securitypolicyviolation", onViolation);
    const cspProbe = document.createElement("script");
    cspProbe.src = CSP_SCRIPT_PROBE;
    document.head.appendChild(cspProbe);

    (async () => {
      const verdict: Verdict = {
        ok: false,
        handshake: false,
        secure: window.isSecureContext === true,
        rendered: true, // this effect only fires after React committed the tree
        rpc: false,
        errmap: false,
        denied: false,
        navExternalBlocked: false,
        navAuthorityBlocked: false,
        navCspBlocked: false,
        navOpenExternal: false,
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
        // CAP-8A deny probe: an UNMAPPED method through the production
        // contextual policy must come back as typed forbidden/403. The
        // fact is REPORTED here and REQUIRED only by the release-side
        // gates: under the deliberate allow-all hosts (examples 02-06)
        // the same probe reaches the bridge and 404s, so `denied` stays
        // false there WITHOUT failing this page's own `ok` verdict.
        try {
          await invoke("Denied.Probe", null);
        } catch (err) {
          verdict.denied =
            err instanceof PWebError &&
            err.code === "forbidden" &&
            err.status === 403 &&
            err.data === null;
        }
        // CAP-8B wrong-authority SUBRESOURCE probe. The control comes
        // first and is load-bearing: `connect-src 'self'` was ratified
        // over `'none'` precisely because same-origin fetch has to keep
        // working, so a refusal only means something once the same
        // request shape is shown to succeed on the trusted authority.
        let sameOriginServed = false;
        try {
          const res = await fetch(SAME_ORIGIN_CONTROL, { cache: "no-store" });
          sameOriginServed = res.ok;
        } catch {
          sameOriginServed = false;
        }
        let wrongAuthorityRefused = false;
        try {
          // refused either by CSP (pweb://evil is a different origin) or
          // by the asset handler's constant refusal - both are "no bytes
          // were served", which is the property being asserted
          const res = await fetch(WRONG_AUTHORITY_PROBE, { cache: "no-store" });
          wrongAuthorityRefused = !res.ok;
        } catch {
          wrongAuthorityRefused = true;
        }
        verdict.navAuthorityBlocked = sameOriginServed && wrongAuthorityRefused;
        // CAP-8B external-open probe: pweb.openExternal is reachable and
        // capability-checked. invalid_request/400 is the ONLY answer that
        // proves both halves at once - the CAP-8A policy allowed the call
        // (an absent `external.open` would have been forbidden/403 before
        // the host ever saw it) and the native validator then refused a
        // non-allowlisted scheme. No browser is ever launched here: a
        // successful open is a side effect on the machine running the
        // smoke, and a gate must not need one.
        try {
          await invoke("pweb.openExternal", { url: REFUSED_SCHEME_PROBE });
        } catch (err) {
          verdict.navOpenExternal =
            err instanceof PWebError &&
            err.code === "invalid_request" &&
            err.status === 400 &&
            err.data === null;
        }
        // CAP-8B external-NAVIGATION probe, attempted only where the
        // runtime advertises `external.open` - which is exactly the
        // release host, the only host that installs a navigation guard.
        // Under the allow-all example hosts the same attempt would
        // succeed, replace this document and destroy the report channel,
        // so the probe is gated on the advertised capability rather than
        // on a build flag the page cannot have.
        const caps = info.capabilities ?? [];
        if (caps.indexOf(EXTERNAL_OPEN_CAPABILITY) >= 0) {
          try {
            // new window first: on Linux and macOS an opened window was
            // MEASURED to inherit the whole native transport, so this
            // path has to be exercised, not just the top-level one
            window.open(EXTERNAL_NAV_PROBE, "_blank");
          } catch {
            // a refusal that throws is still a refusal
          }
          try {
            window.location.href = EXTERNAL_NAV_PROBE;
          } catch {
            // idem
          }
          // a navigation assignment is asynchronous, so the page has to
          // yield before its own address means anything; a real native
          // round trip is a yield the page can actually prove happened
          try {
            await invoke("pweb.echo", { navprobe: 1 });
          } catch {
            // the yield failing is reported by the flag staying false
          }
          verdict.navExternalBlocked =
            window.location.href === startHref &&
            window.location.protocol === "pweb:";
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
      // read as late as possible, and outside the try: the violation
      // report is queued by the engine, and every await above has since
      // let the task queue drain
      verdict.navCspBlocked = cspBlocked;
      document.removeEventListener("securitypolicyviolation", onViolation);
      try {
        await invoke("example.report", { ...verdict });
      } catch {
        // the report channel itself failing is the host's problem to notice
      }
    })();
    return () => {
      cancelled = true;
      document.removeEventListener("securitypolicyviolation", onViolation);
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
