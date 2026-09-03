import { defineConfig } from "vite";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/* The production build of a PWeb frontend.
 *
 * The output is loaded from app.pwb over pweb://app, not from a web server,
 * so three things differ from a browser deployment and each is deliberate:
 *
 *   no content hashes   there is no HTTP cache behind pweb://app, so a hash
 *                       in a file name buys nothing and costs a name that
 *                       changes on every edit;
 *   fixed asset names   the bundler that packs app.pwb wants index.html at
 *                       the root and everything else under assets/;
 *   no preload polyfill it exists for browsers this application will never
 *                       run in - the WebView is the platform's own engine.
 *
 * The application origin is pweb://app in development and in production
 * alike, so `base` stays at the root and every emitted URL is absolute
 * within that origin.
 */

/* THE COMPLETION SENTINEL (CAP-10C2).
 *
 * `pweb dev` supervises `vite build --watch` and has to know when ONE
 * rebuild has finished writing dist/, so it can pack an immutable
 * generation from a directory nothing is still writing into.
 *
 * It does not parse the watcher's console output, and the reason is
 * measured rather than stylistic: watch mode prints `built in 51ms.` where a
 * one-shot build prints `built in 52ms` with a leading tick - two spellings
 * of one event - and the output carries ANSI whenever the inherited
 * environment enables colour, which a supervisor that injects no environment
 * cannot turn off.
 *
 * So the build states the fact itself. `writeBundle` fires once per
 * completed write, and this plugin writes
 *
 *     <frontend>/.pweb/dev/build-id      "<watcher-start-ms>.<n>"
 *
 * The start stamp makes the value unique per watcher process, so a stale
 * file from a previous session can never be mistaken for this session's
 * first build; the counter makes every rebuild a new value even inside one
 * millisecond.
 *
 * WHERE IT IS WRITTEN MATTERS TWICE. `.pweb/` is already inside the
 * ratified project-mutation set and is already git-ignored by this
 * template, so the sentinel costs no new writable prefix; and it is OUTSIDE
 * dist/, so no byte of what the bundler packs moves because of it and no
 * app.pwb digest changes.
 *
 * It is written by EVERY build, production included. A file the production
 * pipeline also writes is one fewer difference between the two paths, and
 * the pipeline's own mutation gate already excludes the directory.
 */
const configDir = dirname(fileURLToPath(import.meta.url));

function pwebDevSentinel() {
  const started = Date.now();
  let builds = 0;
  return {
    name: "pweb-dev-sentinel",
    writeBundle() {
      builds += 1;
      const dir = join(configDir, ".pweb", "dev");
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "build-id"), `${started}.${builds}`, {
        encoding: "utf8",
      });
    },
  };
}

export default defineConfig({
  base: "/",
  plugins: [pwebDevSentinel()],
  build: {
    target: "es2020",
    assetsDir: "assets",
    modulePreload: { polyfill: false },
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name][extname]",
      },
    },
  },
});
