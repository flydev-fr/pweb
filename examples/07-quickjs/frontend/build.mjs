// CAP-9C2 plugin-enabled acceptance frontend. Byte-for-byte the CAP-5
// build shape (offline, deterministic, single IIFE, no dev server and no
// CDN), differing only in which entry point it bundles and in the alias
// block below.
//
// The CAP-5 App component is imported UNMODIFIED from
// examples/04-react/frontend/src/App.tsx rather than copied, so the
// CAP-8 browser corpus this page runs cannot drift from the one the
// release host already gates on, and examples/04-react stays
// byte-untouched - which is what keeps every existing app.pwb hash and
// logical-inventory gate unaffected by this shard.
//
// WHY THE ALIAS BLOCK IS LOAD-BEARING, and not a tidy-up. Node resolves
// a bare import from the IMPORTING file's directory upwards, so
// App.tsx's `import { useEffect } from "react"` resolves against
// examples/04-react/frontend/node_modules while main.tsx's resolves
// against ours. Both directories exist once CI has built the CAP-5
// frontend, so the bundle would contain TWO React instances: the
// component's hooks would belong to one and createRoot to the other,
// React would throw "invalid hook call" during the first render, and
// the page would come up completely blank with no console anyone reads.
// MEASURED exactly that way before the aliases were added. Pinning the
// three shared packages to THIS package's own resolution makes the
// cross-example import safe by construction.
import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
// react and react-dom both export "./package.json", so their own
// resolution is exact. The SDK's export map deliberately does not, so
// it is named by the same relative path package.json already declares.
const own = (pkg) => dirname(require.resolve(`${pkg}/package.json`));
const sdk = fileURLToPath(new URL("../../../sdk/typescript", import.meta.url));

// clean-room: stale files must never survive into the folder the
// bundler turns into app.pwb
rmSync("dist", { recursive: true, force: true });

await build({
  entryPoints: ["src/main.tsx"],
  bundle: true,
  outfile: "dist/assets/app.js",
  format: "iife",
  target: ["es2020"],
  jsx: "automatic",
  minify: true,
  define: { "process.env.NODE_ENV": '"production"' },
  alias: {
    react: own("react"),
    "react-dom": own("react-dom"),
    "@pweb/runtime": sdk,
  },
  logLevel: "info",
});

mkdirSync("dist", { recursive: true });
cpSync("src/index.html", "dist/index.html");
console.log("quickjs acceptance frontend built into dist/");
