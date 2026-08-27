import { defineConfig } from "vite";

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
export default defineConfig({
  base: "/",
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
