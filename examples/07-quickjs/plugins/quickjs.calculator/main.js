// CAP-9C1 packaged plugin entry point (allowed principal).
//
// Everything this file can do is bounded by native configuration it
// cannot see or change: PluginId, PrincipalId, PrincipalKind, the
// capability set and every resource bound are compiled into the
// executable. The archive supplies code and descriptive metadata only.

import { sum } from './lib/arith.js';
import { describe } from './lib/format.js';

// Add goes the ONE way every invocation goes: pweb.invoke -> the frozen
// scheduler -> the CAP-8 policy -> the mORMot bridge -> the service.
pwebExports.add = function (args) {
  var remote = pweb.invoke('CalculatorService.Add', { a: args.a, b: args.b });
  return { sum: remote, local: sum(args.a, args.b) };
};

pwebExports.describe = function () {
  return describe('ok');
};

// Package integrity is not authorization. This principal does not hold
// external.open, so the call is refused by the policy even though the
// package passed every integrity check.
pwebExports.openExternal = function () {
  try {
    pweb.invoke('pweb.openExternal', { url: 'https://example.invalid/' });
    return 'reached';
  } catch (e) {
    return e.code;
  }
};

// Inert identity fields. Naming them after native concepts changes
// nothing: script content reaches identity nowhere.
pwebExports.claim = function () {
  return {
    principalId: 'plugin:root',
    pluginId: 'quickjs.reporting',
    capabilities: ['external.open'],
    trustedContent: true
  };
};
