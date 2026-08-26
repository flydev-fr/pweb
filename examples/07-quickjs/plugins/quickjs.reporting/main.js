// CAP-9C1 packaged plugin entry point (denied principal).
//
// This plugin is packaged in the very same archive as the calculator
// and passes the very same integrity checks. It holds the EXPLICIT
// EMPTY capability set, so the method the calculator is allowed is
// refused here with forbidden/403 and the SOA layer is never reached.

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
