/* Ambient declarations for the three Node built-ins the BUILD CONFIGURATION
 * uses, and for nothing else.
 *
 * `vite.config.ts` runs in Node, not in the WebView, and it writes the PWeb
 * development completion sentinel from its `writeBundle` hook. The project's
 * typecheck covers that file (tsconfig `include`), so the imports have to be
 * typed - and this file types exactly the four functions the config calls
 * rather than pulling `@types/node` into the lockfile for them.
 *
 * WHY NOT @types/node. It is a large dependency whose whole surface would
 * become available to a typecheck that also covers `src/`, where nothing may
 * touch the filesystem: a PWeb frontend runs behind pweb://app, has no Node
 * runtime under it, and an `fs` import that typechecked in `src/` would be a
 * mistake nobody caught until it failed inside a WebView. Four declarations
 * cost one file and keep that mistake impossible.
 *
 * This file declares NOTHING for the application. It is build tooling, and
 * the modules below are unavailable to `src/` because nothing there imports
 * them - which the typecheck would refuse to resolve if it tried, since
 * these declarations only describe what is imported here.
 */

declare module "node:fs" {
  export function mkdirSync(
    path: string,
    options?: { recursive?: boolean }
  ): string | undefined;
  export function writeFileSync(
    path: string,
    data: string,
    options?: { encoding?: string }
  ): void;
}

declare module "node:path" {
  export function dirname(path: string): string;
  export function join(...parts: string[]): string;
}

declare module "node:url" {
  export function fileURLToPath(url: string | URL): string;
}
