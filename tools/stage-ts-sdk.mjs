// Stage the PWeb TypeScript SDK into an SDK root (CAP-10B1).
//
//     node tools/stage-ts-sdk.mjs <sdk/typescript> <out-dir>
//
// WHAT THIS IS FOR. A generated project declares its runtime dependency as
// a project-relative `file:` specifier and never as a registry package, a
// published name or an absolute path. Something has to put the package
// where that specifier points, and this is that something: it materialises
// the pinned SDK from the trusted PWeb SDK root into a build staging area,
// leaving the generated project itself untouched.
//
// WHAT IT EMITS, and why it is not a copy of sdk/typescript:
//
//   package.json   REWRITTEN into a canonical distribution manifest -
//                  name, version, license, type, main, types, exports and
//                  nothing else. The development manifest carries
//                  devDependencies (typescript, @types/node) that a
//                  CONSUMER never needs, and npm records a linked local
//                  package's manifest in the lockfile - so shipping the
//                  development one would make every generated lockfile
//                  depend on the SDK's own toolchain pins.
//   dist/src/**    the built JavaScript and its declarations, verbatim.
//                  dist/test is deliberately excluded: a `file:` dependency
//                  is LINKED rather than packed, so the package's own
//                  `files` field does not filter anything and the exclusion
//                  has to happen here.
//
// DETERMINISM. The manifest is written with a fixed key order, two-space
// indent, LF and exactly one trailing newline, so the bytes a generated
// lockfile describes are a pure function of the repository. The output
// directory is created fresh; an existing one is refused rather than merged,
// because a stale file surviving into a staged SDK is the one failure this
// script exists to prevent.
//
// It reads two paths it was told to read and writes one tree it was told to
// write. No network, no package manager, no shell.
import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import { join, resolve } from "node:path";

const [, , srcArg, outArg] = process.argv;
if (srcArg === undefined || outArg === undefined) {
  console.error("usage: node tools/stage-ts-sdk.mjs <sdk/typescript> <out-dir>");
  process.exit(2);
}
const src = resolve(srcArg);
const out = resolve(outArg);

const manifestPath = join(src, "package.json");
const distSrc = join(src, "dist", "src");
if (!existsSync(manifestPath)) {
  console.error(`stage-ts-sdk: no package.json in ${srcArg}`);
  process.exit(1);
}
if (!existsSync(join(distSrc, "index.js"))) {
  console.error(
    "stage-ts-sdk: the SDK is not built -- run `npm ci && npm run build` " +
      "in sdk/typescript first",
  );
  process.exit(1);
}

const dev = JSON.parse(readFileSync(manifestPath, "utf8"));
// the canonical distribution manifest: a fixed key order, and every value
// taken from the development manifest rather than restated here, so the two
// cannot drift
const canonical = {
  name: dev.name,
  version: dev.version,
  license: dev.license,
  type: dev.type,
  main: dev.main,
  types: dev.types,
  exports: dev.exports,
};
for (const [key, value] of Object.entries(canonical)) {
  if (value === undefined) {
    console.error(`stage-ts-sdk: the SDK manifest has no ${key}`);
    process.exit(1);
  }
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
writeFileSync(
  join(out, "package.json"),
  `${JSON.stringify(canonical, null, 2)}\n`,
  "utf8",
);

// a sorted walk, so the copy order is a property of the names rather than of
// whatever order the filesystem happened to return
function copyTree(from, to) {
  mkdirSync(to, { recursive: true });
  for (const name of readdirSync(from).sort()) {
    const source = join(from, name);
    const target = join(to, name);
    if (statSync(source).isDirectory()) {
      copyTree(source, target);
    } else {
      copyFileSync(source, target);
    }
  }
}
copyTree(distSrc, join(out, "dist", "src"));

const staged = [];
function list(dir, prefix) {
  for (const name of readdirSync(dir).sort()) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      list(full, `${prefix}${name}/`);
    } else {
      staged.push(`${prefix}${name}`);
    }
  }
}
list(out, "");
console.log(`stage-ts-sdk: ${canonical.name}@${canonical.version} -> ${outArg}`);
for (const entry of staged) {
  console.log(`  ${entry}`);
}
