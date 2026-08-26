// CAP-9C1 packaged plugin module. Pure arithmetic: it touches no host
// surface at all, so it proves a resolution edge without proving
// anything about authority.

export function sum(a, b) {
  return a + b;
}

export const ORIGIN = 'quickjs.calculator/lib/arith.js';
