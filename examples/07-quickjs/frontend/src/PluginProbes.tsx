/* PWeb CAP-9C2 browser-invisibility probe block.
 *
 * Runs in the REAL trusted pweb://app document of the plugin-enabled
 * acceptance application, beside the unmodified CAP-5 App component, and
 * reports through its own channel (example.pluginProbe) so neither
 * verdict can mask the other.
 *
 * WHAT THIS PROVES, and what it deliberately does not. This half is the
 * BROWSER's account: every request it made, every refusal it observed,
 * and the state of the execution marker afterwards. It is joined by the
 * host with the NATIVE account - the plugin package store's arrival
 * counter, which stays at zero, and the app store's, which does not.
 * CAP-8B's lesson is why both halves exist: a page that cannot find a
 * transport reports the same "refused" as a page whose request was
 * genuinely denied, so a same-origin control runs first and the native
 * counter is what makes the absence real.
 *
 * NOTHING HERE IS A CAPABILITY. Every probe below is an ordinary
 * request from ordinary web APIs; none of it needs, asks for or
 * receives a grant, and the three plugin-read method names are
 * deliberately methods that DO NOT EXIST - no plugin-reading runtime
 * method was added to make this test possible. */
import { useEffect, useState } from "react";
import { invoke, PWebError } from "@pweb/runtime";

/* The plugin package's own logical paths, spelled the four ways a
 * browser could plausibly reach for them: under a /plugins/ prefix, at
 * the archive-root spelling, as a bare entry-point name that exists ONLY
 * inside plugins.zip, and through a percent-encoded escape. */
const PROBE_ARCHIVE = "pweb://app/plugins.zip";
const PROBE_ENTRY = "pweb://app/plugins/quickjs.calculator/main.js";
const PROBE_LEAF = "pweb://app/plugins/quickjs.calculator/lib/arith.js";
const PROBE_MANIFEST = "pweb://app/plugins/quickjs.calculator/plugin.json";
const PROBE_REPORTING = "pweb://app/plugins/quickjs.reporting/main.js";
const PROBE_BARE_ENTRY = "pweb://app/main.js";
const PROBE_ARCHIVE_ROOT = "pweb://app/quickjs.calculator/main.js";
const PROBE_TRAVERSAL = "pweb://app/%2e%2e/plugins.zip";
const PROBE_RELATIVE_ESCAPE = "pweb://app/assets/../plugins.zip";

/* The control. `connect-src 'self'` was ratified over `'none'` so that
 * same-origin fetch keeps working, which is exactly what makes a refusal
 * above mean "denied" rather than "no transport". */
const CONTROL_ASSET = "/index.html";

/* Deliberately nonexistent, deliberately plausible: the shapes someone
 * would try if they believed a plugin-reading method existed. The
 * capability policy answers unmapped-method before routing, so all three
 * must come back forbidden without ever reaching a catalog. */
const READ_METHODS = ["pweb.plugin.read", "pweb.plugins.getSource", "PluginService.Read"];

/* Byte sequences that appear ONLY in packaged plugin source. If any of
 * them ever turns up in a browser response or in a native error, plugin
 * bytes reached the browser and the run is red. */
const SOURCE_TOKENS = [
  "pwebExports",
  "__PWEB_PLUGIN_SOURCE_EXECUTED" + "_IN_WEBVIEW__",
  "quickjs.calculator/lib/arith.js",
];

/* The browser-only side effect the calculator's leaf module carries. If
 * a WebView ever executed that module, this global becomes true. */
const MARKER = "__PWEB_PLUGIN_SOURCE_EXECUTED_IN_WEBVIEW__";

const PROBE_TIMEOUT_MS = 4000;

interface RawChannel {
  call(binding: string, method: string, args: unknown): Promise<unknown>;
}

interface PluginProbeVerdict {
  ok: boolean;
  href: string;
  secure: boolean;
  control: boolean;
  assetAttempts: number;
  assetRefused: number;
  assetServed: string[];
  scriptAttempts: number;
  scriptExecuted: boolean;
  subresourceAttempts: number;
  rawChannel: boolean;
  rawAttempts: number;
  rawRefused: number;
  rawCodes: string[];
  sdkAttempts: number;
  sdkRefused: number;
  sdkCodes: string[];
  sourceBytes: number;
  leakedPath: number;
  leakedDigest: number;
  error?: string;
}

function safeText(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(value, Object.getOwnPropertyNames(Object(value))) ?? "";
  } catch {
    return String(value);
  }
}

/* One scan, three separable disclosures. `path` looks for an absolute
 * host path or the archive file name; `digest` for any 64-hex run, so a
 * package digest cannot leak through an error message that happens not
 * to name the file. */
function scanDisclosure(text: string): {
  source: boolean;
  path: boolean;
  digest: boolean;
} {
  return {
    source: SOURCE_TOKENS.some((token) => text.indexOf(token) >= 0),
    path:
      text.indexOf("plugins.zip") >= 0 ||
      /[A-Za-z]:\\/.test(text) ||
      /\/(?:Users|home|Applications|private|var)\//.test(text),
    digest: /\b[0-9a-f]{64}\b/.test(text),
  };
}

function loadScript(src: string, asModule: boolean): Promise<string> {
  return new Promise((resolve) => {
    const element = document.createElement("script");
    if (asModule) {
      element.type = "module";
    }
    element.src = src;
    let settled = false;
    const finish = (how: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      element.remove();
      resolve(how);
    };
    element.onload = () => finish("load");
    element.onerror = () => finish("error");
    window.setTimeout(() => finish("timeout"), PROBE_TIMEOUT_MS);
    document.head.appendChild(element);
  });
}

function loadFrame(src: string): Promise<string> {
  return new Promise((resolve) => {
    const element = document.createElement("iframe");
    element.src = src;
    element.style.display = "none";
    let settled = false;
    const finish = (how: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      element.remove();
      resolve(how);
    };
    element.onload = () => finish("load");
    element.onerror = () => finish("error");
    window.setTimeout(() => finish("timeout"), PROBE_TIMEOUT_MS);
    document.body.appendChild(element);
  });
}

function loadImage(src: string): Promise<string> {
  return new Promise((resolve) => {
    const element = new Image();
    let settled = false;
    const finish = (how: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(how);
    };
    element.onload = () => finish("load");
    element.onerror = () => finish("error");
    window.setTimeout(() => finish("timeout"), PROBE_TIMEOUT_MS);
    element.src = src;
  });
}

export function PluginProbes(): JSX.Element {
  const [status, setStatus] = useState<string>("plugin probes running…");

  useEffect(() => {
    let cancelled = false;
    const startHref = window.location.href;

    (async () => {
      const verdict: PluginProbeVerdict = {
        ok: false,
        href: startHref,
        secure: window.isSecureContext === true,
        control: false,
        assetAttempts: 0,
        assetRefused: 0,
        assetServed: [],
        scriptAttempts: 0,
        scriptExecuted: false,
        subresourceAttempts: 0,
        rawChannel: false,
        rawAttempts: 0,
        rawRefused: 0,
        rawCodes: [],
        sdkAttempts: 0,
        sdkRefused: 0,
        sdkCodes: [],
        sourceBytes: 0,
        leakedPath: 0,
        leakedDigest: 0,
      };

      const account = (text: string): void => {
        const found = scanDisclosure(text);
        if (found.source) {
          verdict.sourceBytes += 1;
        }
        if (found.path) {
          verdict.leakedPath += 1;
        }
        if (found.digest) {
          verdict.leakedDigest += 1;
        }
      };

      try {
        // the control FIRST: a refusal only means something once the same
        // request shape is shown to succeed on the trusted authority
        try {
          const response = await fetch(CONTROL_ASSET, { cache: "no-store" });
          verdict.control = response.ok && (await response.text()).length > 0;
        } catch {
          verdict.control = false;
        }

        // 1-2 + the extra spellings: every plugin path a browser can name
        for (const uri of [
          PROBE_ARCHIVE,
          PROBE_ENTRY,
          PROBE_LEAF,
          PROBE_MANIFEST,
          PROBE_REPORTING,
          PROBE_BARE_ENTRY,
          PROBE_ARCHIVE_ROOT,
          PROBE_TRAVERSAL,
          PROBE_RELATIVE_ESCAPE,
        ]) {
          verdict.assetAttempts += 1;
          try {
            const response = await fetch(uri, { cache: "no-store" });
            if (response.ok) {
              const body = await response.text();
              account(body);
              verdict.assetServed.push(uri);
            } else {
              verdict.assetRefused += 1;
            }
          } catch {
            // a refusal that throws is still a refusal, and still no bytes
            verdict.assetRefused += 1;
          }
        }

        // 3-4: script tags. The MODULE form on the leaf module is the
        // load-bearing one - it is the only module in the corpus with no
        // import of its own, so it is the only one whose top level would
        // actually run if the bytes were ever served.
        verdict.scriptAttempts += 1;
        await loadScript(PROBE_ENTRY, false);
        verdict.scriptAttempts += 1;
        await loadScript(PROBE_LEAF, true);
        verdict.scriptAttempts += 1;
        await loadScript(PROBE_BARE_ENTRY, false);
        verdict.scriptAttempts += 1;
        await loadScript(PROBE_ARCHIVE_ROOT, true);

        // 5: subresource shapes that are not scripts
        verdict.subresourceAttempts += 1;
        await loadFrame(PROBE_ENTRY);
        verdict.subresourceAttempts += 1;
        await loadImage(PROBE_LEAF);

        // 6: the RAW engine channel, one level below the bound global -
        // window.__webview__.call posts straight into chrome.webview /
        // webkit.messageHandlers. CAP-8B measured it reachable from the
        // trusted top document on every engine, which is what makes this
        // a real attempt rather than a missing transport.
        const raw = (window as unknown as { __webview__?: RawChannel }).__webview__;
        verdict.rawChannel = !!raw && typeof raw.call === "function";
        if (raw && verdict.rawChannel) {
          for (const method of READ_METHODS) {
            verdict.rawAttempts += 1;
            try {
              const result = await raw.call("__pweb_invoke", method, null);
              account(safeText(result));
            } catch (err) {
              verdict.rawRefused += 1;
              const text = safeText(err);
              account(text);
              const code = (err as { code?: unknown }).code;
              verdict.rawCodes.push(typeof code === "string" ? code : "unknown");
            }
          }
        }

        // 7: the same nonexistent methods through the PUBLIC SDK
        for (const method of READ_METHODS) {
          verdict.sdkAttempts += 1;
          try {
            const result = await invoke(method, null);
            account(safeText(result));
          } catch (err) {
            verdict.sdkRefused += 1;
            account(safeText(err));
            verdict.sdkCodes.push(
              err instanceof PWebError ? err.code : "unknown",
            );
          }
        }

        // read the marker LAST, after every script/frame/image attempt has
        // settled: "it never executed" is only a fact once the attempts are over
        verdict.scriptExecuted =
          (window as unknown as Record<string, unknown>)[MARKER] === true;

        verdict.href = window.location.href;
        verdict.ok =
          verdict.control &&
          verdict.secure &&
          verdict.href === startHref &&
          window.location.protocol === "pweb:" &&
          verdict.assetAttempts > 0 &&
          verdict.assetRefused === verdict.assetAttempts &&
          verdict.assetServed.length === 0 &&
          verdict.scriptAttempts === 4 &&
          !verdict.scriptExecuted &&
          verdict.subresourceAttempts === 2 &&
          verdict.rawRefused === verdict.rawAttempts &&
          verdict.sdkAttempts === READ_METHODS.length &&
          verdict.sdkRefused === verdict.sdkAttempts &&
          verdict.sourceBytes === 0 &&
          verdict.leakedPath === 0 &&
          verdict.leakedDigest === 0;
      } catch (err) {
        verdict.error = err instanceof Error ? `${err.name}: ${err.message}` : "unknown";
      }

      if (!cancelled) {
        setStatus(
          verdict.ok
            ? `plugin invisibility OK (${verdict.assetRefused}/${verdict.assetAttempts} refused)`
            : "plugin invisibility FAILED",
        );
      }
      try {
        await invoke("example.pluginProbe", { ...verdict });
      } catch {
        // the report channel itself failing is the host's problem to notice
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <section>
      <h2>CAP-9C2 plugin invisibility</h2>
      <div id="plugin-probe-result">{status}</div>
    </section>
  );
}
