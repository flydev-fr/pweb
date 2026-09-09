/* CAP-15A: join the host reports with the probe server's wire log.
 *
 * ONE summarizer, called by both run scripts, because the join is the actual
 * evidence and two copies of it in two languages would be two answers to one
 * question - the same reason the repository keeps one classifier and one
 * bundler. The Windows script and the POSIX script differ in how they BUILD
 * and RUN; what the measurement MEANS is decided here.
 *
 * It asserts exactly one thing, and only about the SHIPPED product: under
 * connect-src 'self' no request the ENGINE issued reached a socket, while the
 * native door reached the server anyway. Every other row is recorded and not
 * graded - a measurement shard reports what an engine does.
 *
 * Usage: node summarize.js --work build/cap15a --target linux-x86_64
 *                          --portA 41597 --portB 41598
 */
'use strict';

const fs = require('fs');
const path = require('path');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const WORK = arg('work', 'build/cap15a');
const TARGET = arg('target', 'unknown');
const PORT_A = parseInt(arg('portA', '41597'), 10);
const PORT_B = parseInt(arg('portB', '41598'), 10);
const MODES = ['baseline', 'widened'];
const NATIVE_UA = 'PWeb-CAP15A-spike';

// A TRUNCATED LAST LINE IS DROPPED AND COUNTED, never thrown on. The wire log
// is appended by a process the runner stops, so its final record can be a
// partial line; a JSON.parse throw here would abort the join and the run would
// report "the baseline invariant did not hold" for a witness that was merely
// cut short. Counting the drop keeps that visible instead of silent.
let jsonlDropped = 0;
function readJsonl(p) {
  if (!fs.existsSync(p)) return [];
  return fs
    .readFileSync(p, 'utf8')
    .split('\n')
    .filter(function (l) { return l.trim(); })
    .map(function (l) {
      try {
        return JSON.parse(l);
      } catch (e) {
        jsonlDropped += 1;
        return null;
      }
    })
    .filter(Boolean);
}

function uniq(a) {
  return Array.from(new Set(a));
}

function wireSummary(rows) {
  const native = rows.filter(function (r) {
    return (r.headers['user-agent'] || '') === NATIVE_UA;
  });
  const engine = rows.filter(function (r) {
    return (r.headers['user-agent'] || '') !== NATIVE_UA;
  });
  const shapes = {};
  rows.forEach(function (r) {
    const k =
      r.srv + ' ' + r.kind + ' ' + r.method + ' ' + String(r.url).split('?')[0] +
      ' origin=' + (r.headers.origin || '-') +
      ' via=' + ((r.headers['user-agent'] || '') === NATIVE_UA ? 'native' : 'engine');
    shapes[k] = (shapes[k] || 0) + 1;
  });
  return {
    total: rows.length,
    native_door: native.length,
    engine_side: engine.length,
    reached_srv_b: rows.filter(function (r) { return r.srv === 'B'; }).length,
    origins_seen: uniq(rows.map(function (r) { return r.headers.origin || '(none)'; })),
    engine_origins: uniq(engine.map(function (r) { return r.headers.origin || '(none)'; })),
    native_origins: uniq(native.map(function (r) { return r.headers.origin || '(none)'; })),
    shapes: shapes,
    exfil_bodies: rows
      .filter(function (r) { return r.kind === 'exfil'; })
      .map(function (r) { return r.bodyHead; }),
    preflights: rows
      .filter(function (r) { return String(r.kind).indexOf('preflight') === 0; })
      .map(function (r) { return r.kind + ' acrh=' + (r.acrHeaders || '-'); }),
    ws: rows
      .filter(function (r) { return String(r.kind).indexOf('ws-') === 0; })
      .map(function (r) { return r.kind + ' origin=' + (r.headers.origin || '-'); }),
    cookies_sent: rows
      .filter(function (r) { return r.headers.cookie; })
      .map(function (r) { return r.url + ' -> ' + r.headers.cookie; }),
    referers_sent: uniq(
      rows.filter(function (r) { return r.headers.referer; })
        .map(function (r) { return r.headers.referer; })
    ),
    engine_request_headers: (function () {
      const e = engine[0];
      return e ? e.headers : null;
    })(),
    native_request_headers: (function () {
      const n = native[0];
      return n ? n.headers : null;
    })()
  };
}

const summary = {
  schema: 1,
  target: TARGET,
  portA: PORT_A,
  portB: PORT_B,
  modes: {}
};

MODES.forEach(function (mode) {
  const wire = wireSummary(readJsonl(path.join(WORK, 'requests-' + TARGET + '-' + mode + '.jsonl')));
  const hostPath = path.join(WORK, TARGET + '-' + mode + '.json');
  let report = null;
  if (fs.existsSync(hostPath)) {
    report = JSON.parse(fs.readFileSync(hostPath, 'utf8'));
  }
  summary.modes[mode] = { wire: wire, report: report };
});

const violations = [];
const base = summary.modes.baseline;
if (!base.report) {
  violations.push('baseline: no host report was written');
} else if (base.report.overall !== 'COMPLETE') {
  violations.push('baseline: host report overall=' + base.report.overall +
    ' ' + (base.report.failures || ''));
}
if (base.wire.engine_side !== 0) {
  violations.push('baseline: ' + base.wire.engine_side +
    " engine-side request(s) reached the probe server under connect-src 'self'");
}
if (base.wire.native_door < 1) {
  violations.push('baseline: the native door reached the server zero times');
}
// THE WITNESS SAYS WHETHER IT IS WHOLE. A dropped partial line is not a
// violation - the runner stops the server and the last record can be cut - but
// a reader has to be able to tell "no engine request reached a socket" from
// "the tail of the log is missing", and only this number distinguishes them.
summary.wire_lines_unparsable = jsonlDropped;
summary.baseline_invariant = violations.length === 0 ? 'HELD' : 'BROKEN';
summary.violations = violations;

fs.writeFileSync(
  path.join(WORK, 'summary-' + TARGET + '.json'),
  JSON.stringify(summary, null, 2) + '\n'
);

MODES.forEach(function (mode) {
  const w = summary.modes[mode].wire;
  process.stdout.write(
    '[CAP-15A] ' + mode.padEnd(8) + ' wire: total=' + w.total +
      ' engine=' + w.engine_side + ' native=' + w.native_door +
      ' srvB=' + w.reached_srv_b +
      ' engine-origins=' + JSON.stringify(w.engine_origins) + '\n'
  );
});
if (jsonlDropped > 0) {
  process.stdout.write('[CAP-15A] NOTE: ' + jsonlDropped +
    ' unparsable wire line(s) dropped -- the log was cut short\n');
}
process.stdout.write('[CAP-15A] baseline invariant: ' + summary.baseline_invariant + '\n');
violations.forEach(function (v) { process.stdout.write('VIOLATION: ' + v + '\n'); });
// EXIT CODE, NOT process.exit(): node drains stdout before leaving, so the
// VIOLATION lines above cannot be lost when the runner reads this through a
// pipe. The two runners both capture this output and quote it.
process.exitCode = violations.length === 0 ? 0 : 1;
