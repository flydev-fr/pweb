// CAP-9C1 packaged plugin entry point (denied principal).
//
// This plugin is packaged in the very same archive as the calculator
// and passes the very same integrity checks. It holds parking.read and
// nothing else, so the method the calculator is allowed is refused here
// with forbidden/403 and the SOA layer is never reached.

import { label } from './lib/report.js';

pwebExports.add = function (args) {
  try {
    pweb.invoke('CalculatorService.Add', { a: args.a, b: args.b });
    return 'reached';
  } catch (e) {
    return e.code;
  }
};

pwebExports.label = function () {
  return label('reporting');
};

// CAP-9C2 liveness for the DENIED principal. Without it, "the denied
// call reached nothing" is indistinguishable from "this plugin was
// never running": pweb.handshake is capability-free by ratified design,
// so it proves the generation, its source and the whole invocation
// chain are alive at the very moment the denied call is refused.
pwebExports.alive = function () {
  var info = pweb.handshake();
  return { protocol: info.protocol, capabilities: info.capabilities };
};

// CAP-9C2 CPU-bound containment leg, and the ONE authoritative one per
// target. The native TimeoutSeconds bound is a compiled constant this
// file cannot read, raise or switch off; exceeding it must taint THIS
// generation, refuse the next call, leave the host failed, and leave
// the neighbouring plugin and the WebView UI untouched. Reachable only
// through the native acceptance harness - no browser content and no
// public API can name an export.
pwebExports.runaway = function () {
  var spin = 0;
  for (;;) {
    spin = (spin + 1) % 1000000007;
  }
};
