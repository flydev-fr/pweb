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

// CAP-9C2: what a plugin can SEE, reported from inside the sandbox
// rather than inferred from the absence of a code path. `typeof` on an
// undeclared identifier is the only probe that cannot itself throw, so
// every answer below is a fact about this context and not about how the
// question was asked. Nothing here changes the sandbox: the shim
// deletes __pweb_invoke_json from globalThis at bootstrap and
// __pweb_invoke is the WEBVIEW binding name, which was never registered
// on this engine at all.
pwebExports.env = function () {
  return {
    window: typeof window,
    document: typeof document,
    webkit: typeof webkit,
    chrome: typeof chrome,
    external: typeof external,
    rawInvoke: typeof __pweb_invoke,
    rawInvokeJson: typeof __pweb_invoke_json,
    fetch: typeof fetch,
    std: typeof std,
    os: typeof os,
    pweb: typeof pweb,
    marker: typeof globalThis.__PWEB_PLUGIN_SOURCE_EXECUTED_IN_WEBVIEW__
  };
};

// CAP-9C2 memory-bound containment leg. The native MemoryLimitBytes
// bound is a compiled constant this file cannot read or raise; blowing
// through it must taint THIS generation and leave the UI and the
// scheduler healthy. Called only by the native acceptance harness, and
// deliberately LAST in the gate sequence for that reason.
pwebExports.memhog = function () {
  var blocks = [];
  for (;;) {
    blocks.push(new Array(65536).fill(7));
  }
};
