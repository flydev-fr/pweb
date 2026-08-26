// Imports a sibling INSIDE the same plugin root. The resolution edge
// this creates is recorded in the packaged module graph and pinned by
// the generated native registry, so a module swapped between build and
// run cannot go unnoticed.

import { ORIGIN } from './arith.js';

export function describe(value) {
  return ORIGIN + ' -> ' + value;
}
