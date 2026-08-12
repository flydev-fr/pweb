// Offline deterministic build: bundles the React app (which consumes the
// @pweb/runtime SDK) into a single IIFE served as a static pweb://app
// asset. No dev server, no CDN, no network at runtime.
import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";

// clean-room: stale files must never survive into the folder the smoke
// serves via TFolderAssetStore
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
  logLevel: "info",
});

mkdirSync("dist", { recursive: true });
cpSync("src/index.html", "dist/index.html");
console.log("react frontend built into dist/");
