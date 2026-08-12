// CAP-5 cross-SDK captured-wire parity gate.
//
// Both SDK test harnesses perform the same canonical list of logical
// calls through their REAL public entry points against a capturing fake
// of the native primitive, and print the captured wire requests between
// PWEBSDK_CAPTURE_BEGIN/END markers. This script extracts both capture
// blocks and asserts, per call:
//   - the method string is byte-identical;
//   - the args are JSON-equivalent (deep, key-order-insensitive);
//   - each request carries EXACTLY {method, args} - no frontend-kind,
//     identity, capability, or any other injected field.
//
// Usage: node tools/check-sdk-parity.mjs <ts-output-file> <p2j-output-file>
import { readFileSync } from "node:fs";

function extract(path) {
  const text = readFileSync(path, "utf8");
  const lines = text.split(/\r?\n/);
  const begin = lines.indexOf("PWEBSDK_CAPTURE_BEGIN");
  const end = lines.indexOf("PWEBSDK_CAPTURE_END");
  if (begin < 0 || end < 0 || end <= begin) {
    throw new Error(`${path}: capture markers missing or out of order`);
  }
  return lines.slice(begin + 1, end).filter((l) => l.trim() !== "").map((l, i) => {
    try {
      return JSON.parse(l);
    } catch {
      throw new Error(`${path}: capture line ${i + 1} is not valid JSON: ${l}`);
    }
  });
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return false;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((v, i) => deepEqual(v, b[i]));
  }
  if (typeof a === "object") {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    if (ka.length !== kb.length || ka.some((k, i) => k !== kb[i])) return false;
    return ka.every((k) => deepEqual(a[k], b[k]));
  }
  return false;
}

// Canonical anchor: the exact method sequence both harnesses are
// expected to capture. Without it, both harnesses drifting together
// (dropping or reordering the same call) would still "agree".
const EXPECTED_METHODS = [
  "pweb.handshake",
  "CalculatorService.Add",
  "CalculatorService.Add",
  "CaseSensitive.MiXeD",
  "Svc.NoArgs",
];

const [tsPath, p2jPath] = process.argv.slice(2);
if (!tsPath || !p2jPath) {
  console.error("usage: node tools/check-sdk-parity.mjs <ts-output> <p2j-output>");
  process.exit(2);
}

const ts = extract(tsPath);
const p2j = extract(p2jPath);
let bad = 0;

if (ts.length === 0) {
  console.error("VIOLATION: TypeScript capture is empty");
  bad++;
}
if (
  ts.length !== EXPECTED_METHODS.length ||
  ts.some((c, i) => c.method !== EXPECTED_METHODS[i])
) {
  console.error(
    `VIOLATION: TS capture does not match the canonical manifest\n  expected: ${JSON.stringify(EXPECTED_METHODS)}\n  captured: ${JSON.stringify(ts.map((c) => c.method))}`,
  );
  bad++;
}
if (ts.length !== p2j.length) {
  console.error(`VIOLATION: capture length differs: TS=${ts.length} Pas2JS=${p2j.length}`);
  bad++;
}

const n = Math.min(ts.length, p2j.length);
for (let i = 0; i < n; i++) {
  const a = ts[i];
  const b = p2j[i];
  for (const [name, call] of [["TS", a], ["Pas2JS", b]]) {
    const keys = Object.keys(call).sort();
    if (keys.length !== 2 || keys[0] !== "args" || keys[1] !== "method") {
      console.error(
        `VIOLATION: call ${i} (${name}) carries fields beyond {method,args}: ${JSON.stringify(keys)}`,
      );
      bad++;
    }
  }
  if (a.method !== b.method) {
    console.error(`VIOLATION: call ${i} method differs: TS='${a.method}' Pas2JS='${b.method}'`);
    bad++;
  }
  if (!deepEqual(a.args, b.args)) {
    console.error(
      `VIOLATION: call ${i} args differ semantically:\n  TS:     ${JSON.stringify(a.args)}\n  Pas2JS: ${JSON.stringify(b.args)}`,
    );
    bad++;
  }
}

if (bad > 0) {
  console.error(`SDK parity: FAIL (${bad} violation(s))`);
  process.exit(1);
}
console.log(`SDK parity: PASS (${ts.length} captured calls semantically identical)`);
