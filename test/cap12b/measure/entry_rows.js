#!/usr/bin/env node
// CAP-12B: the three entry conditions of cap12a-decision-artifact.md §6.3,
// reduced to TYPED ROWS.
//
// It reads ONE raw report written by the CAP-12A instrument
// (`build/cap12a/<target>.json`) plus a small `key=value` facts file the
// measurement workflow fills from the runner itself, and writes
// `build/cap12b/entry/<target>.json`: a list of rows, each with an `id`, a
// `verdict` and the `evidence` the verdict was read from.
//
// IT DECIDES NOTHING THE EVIDENCE DOES NOT SAY. Three verdicts exist and the
// third is load-bearing:
//   yes / no   - the report contains the fact and it is this
//   undecided  - the report does not contain the fact, with the reason
// A row whose evidence is absent is `undecided`, never `no`: "the engine
// cannot" and "nobody looked" are different findings and CAP-12A's whole
// method is to keep them apart. Nothing here is a pass/fail gate; the rows
// are an artifact the shard reads, which is why this file never exits
// non-zero on a verdict.
//
// It is NOT test/cap12a/summarize.js and must not grow into it. summarize.js
// is the one place an M1-M5 measurement becomes the decision artifact's
// table; this is the one place the §6.3 ENTRY CONDITIONS become rows. The two
// read the same raw report and answer different questions.
//
// Usage:
//   node test/cap12b/measure/entry_rows.js --target macos-arm64 \
//        [--work build/cap12a] [--facts build/cap12b/entry/facts.txt] \
//        [--out build/cap12b/entry/<target>.json]

'use strict';

const fs = require('fs');
const path = require('path');

const TARGET_SOURCE = {
  'linux': 'linux-x86_64',
  'macos-x64': 'macos-x86_64',
  'macos-arm64': 'macos-arm64'
};

let target = '';
let work = 'build/cap12a';
let factsPath = '';
let outPath = '';
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--target') { target = process.argv[++i]; }
  else if (a === '--work') { work = process.argv[++i]; }
  else if (a === '--facts') { factsPath = process.argv[++i]; }
  else if (a === '--out') { outPath = process.argv[++i]; }
  else { console.error('unknown option: ' + a); process.exit(2); }
}
if (!Object.prototype.hasOwnProperty.call(TARGET_SOURCE, target)) {
  console.error('--target must be one of: ' + Object.keys(TARGET_SOURCE).join(', '));
  process.exit(2);
}
if (!outPath) { outPath = path.join('build/cap12b/entry', target + '.json'); }

// --- the raw report -------------------------------------------------------

const sourcePath = path.join(work, TARGET_SOURCE[target] + '.json');
let raw = null;
let rawError = '';
if (!fs.existsSync(sourcePath)) {
  rawError = 'the instrument wrote no ' + sourcePath;
} else {
  try { raw = JSON.parse(fs.readFileSync(sourcePath, 'utf8')); }
  catch (e) { rawError = 'unreadable ' + sourcePath + ': ' + String(e.message); }
}

const facts = {};
if (factsPath && fs.existsSync(factsPath)) {
  for (const line of fs.readFileSync(factsPath, 'utf8').split(/\r?\n/)) {
    const eq = line.indexOf('=');
    if (eq <= 0 || line.trim().startsWith('#')) { continue; }
    facts[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
}

const rows = [];
function row(id, verdict, evidence) {
  rows.push({ id: id, verdict: verdict, evidence: String(evidence) });
}
function absent(id, what) {
  row(id, 'undecided', rawError || ('the report carries no ' + what));
}

function pageRow(name) {
  if (!raw || !raw.page || !raw.page.rows) { return null; }
  const v = raw.page.rows[name];
  return (v === undefined) ? null : v;
}
function timeline() {
  return (raw && Array.isArray(raw.timeline)) ? raw.timeline : [];
}
function engineFact(name) {
  if (!raw || !raw.engine_facts) { return undefined; }
  return raw.engine_facts[name];
}

// --- 6.3.1, the four macOS rows ------------------------------------------

function macosRows() {
  // (1) Range reaches the handler through -[NSURLRequest allHTTPHeaderFields].
  // The witness is the HANDLER's own mark, not the page's request: a page can
  // send a header an engine drops, and that is exactly the row.
  const ranges = timeline().filter(
    (e) => e.e === 'req.read_range' && typeof e.d === 'string' && e.d !== '');
  if (!raw) {
    absent('macos_range_through_allhttpheaderfields', 'timeline');
  } else if (ranges.length > 0) {
    row('macos_range_through_allhttpheaderfields', 'yes',
      ranges.length + ' request(s) carried a Range the handler read, first: ' +
      ranges[0].d);
  } else {
    row('macos_range_through_allhttpheaderfields', 'no',
      'the handler read allHTTPHeaderFields on ' +
      (engineFact('requests_with_headers') === undefined
        ? 'an unrecorded number of' : engineFact('requests_with_headers')) +
      ' request(s) and never found a Range');
  }

  // (2) a 206 with Content-Range on an NSHTTPURLResponse, read back by fetch().
  // OFFSET-verified: a handler answering the first N bytes of a window would
  // pass a length-only check, which is why the instrument checks the bytes.
  for (const [id, name] of [
    ['macos_206_content_range_read_back', 'm2.range_supported'],
    ['macos_206_suffix_range_read_back', 'm2.range_suffix']
  ]) {
    const r = pageRow(name);
    if (!r) { absent(id, 'page row ' + name); continue; }
    const headers = r.headers || {};
    // OFFSET, not length: `pattern_bad_at_expected_offset` is the index of the
    // first byte that does not match the window the page asked for, and -1
    // means every byte did. A handler that answered with the first N bytes
    // instead of the requested window fails here and passes a length check.
    const offsetOk = r.pattern_bad_at_expected_offset === -1 &&
      r.bytes === r.expected_bytes && r.first_byte === r.expected_first_byte;
    if (r.status === 206 && offsetOk && headers['content-range']) {
      row(id, 'yes', 'status 206, content-range "' + headers['content-range'] +
        '", accept-ranges "' + (headers['accept-ranges'] || '') + '", ' +
        r.bytes + ' byte(s), offset verified');
    } else {
      row(id, 'no', 'status ' + r.status + ', content-range "' +
        (headers['content-range'] || '') + '", ' + r.bytes + ' of ' +
        r.expected_bytes + ' byte(s), first mismatch at ' +
        r.pattern_bad_at_expected_offset);
    }
  }

  // (3) which of HTTPBody and HTTPBodyStream carries a TYPED-ARRAY body, at
  // the three sizes §6.3.1 names. The carrier is recorded per row by the
  // probe; the cumulative counters cannot answer a per-size question.
  for (const [id, name] of [
    ['macos_typed_array_carrier_1mib', 'm3.post_arraybuffer_1m'],
    ['macos_typed_array_carrier_16mib', 'm3.post_arraybuffer_16m'],
    ['macos_typed_array_carrier_256mib', 'm3.post_arraybuffer_256m']
  ]) {
    const r = pageRow(name);
    if (!r) { absent(id, 'page row ' + name); continue; }
    const h = r.handler;
    if (!h || typeof h.carrier !== 'string') {
      row(id, 'undecided', 'the handler recorded no carrier: ' +
        JSON.stringify(r).slice(0, 300));
      continue;
    }
    const exact = h.received === r.sent_bytes && h.pattern_ok === true;
    row(id, exact ? 'yes' : 'no',
      h.carrier + ', received ' + h.received + ' of ' + r.sent_bytes +
      ' byte(s), pattern_ok=' + h.pattern_ok + ', chunks=' + h.chunks);
  }

  // (4) a whole 8 MiB body served synchronously - the window §5.3 bounds a
  // single response to.
  wholeEightRow('macos_whole_8mib_synchronous');

  // the CAP-7M constraint, re-read on the engine that owns it: this
  // instrument DOES defer delivery, so an interleaving stop is reachable here
  // in a way the production handler cannot produce.
  const stops = engineFact('stop_arrivals');
  const offMain = engineFact('handler_calls_off_main_thread');
  row('macos_stop_arrivals',
    stops === undefined ? 'undecided' : 'yes',
    stops === undefined ? (rawError || 'the report carries no stop_arrivals')
      : (stops + ' stopURLSchemeTask: arrival(s), ' +
         engineFact('stops_while_serving') + ' while serving, ' +
         engineFact('suppressed_terminals') + ' suppressed terminal(s), ' +
         engineFact('caught_exceptions') + ' caught exception(s)'));
  row('macos_handler_on_main_thread',
    offMain === undefined ? 'undecided' : (offMain === 0 ? 'yes' : 'no'),
    offMain === undefined ? (rawError || 'the report carries no thread count')
      : (offMain + ' handler call(s) arrived off the main thread'));
}

// --- 6.3.2, the WebKitGTK blob-backed-body fault -------------------------

function linuxRows() {
  const version = facts.webkitgtk_version || '';
  row('webkitgtk_version', version ? 'yes' : 'undecided',
    version ? ('webkit2gtk-4.1 ' + version +
      (facts.gtk_version ? ', gtk+-3.0 ' + facts.gtk_version : ''))
      : 'the runner recorded no webkit2gtk-4.1 version');

  // THE FAULT, and its CONTROL in the same run. A typed-array body of the
  // same size goes through the same webkit_uri_scheme_request_get_http_body
  // call; without that control a "Load failed" row would say nothing about
  // the body KIND.
  const faults = timeline().filter((e) => e.e === 'req.exception');
  for (const [id, name] of [
    ['webkitgtk_upload_fault_blob', 'm3.post_blob_1m'],
    ['webkitgtk_upload_fault_file', 'm3.post_file_1m'],
    ['webkitgtk_upload_fault_formdata', 'm3.post_formdata_1m']
  ]) {
    const r = pageRow(name);
    if (!r) { absent(id, 'page row ' + name); continue; }
    if (r.error || r.fatal) {
      row(id, 'yes', 'the page saw ' + (r.error || 'fatal') + ': ' +
        String(r.message || r.fatal) + '; the handler recorded ' +
        faults.length + ' native fault(s) in the run' +
        (faults.length ? ' (' + faults[0].d + ')' : ''));
    } else {
      row(id, 'no', 'the body reached the handler: ' +
        JSON.stringify(r.handler || r).slice(0, 300));
    }
  }
  for (const [id, name] of [
    ['webkitgtk_typed_array_control_1mib', 'm3.post_arraybuffer_1m'],
    ['webkitgtk_typed_array_control_16mib', 'm3.post_arraybuffer_16m'],
    ['webkitgtk_typed_array_control_256mib', 'm3.post_arraybuffer_256m']
  ]) {
    const r = pageRow(name);
    if (!r) { absent(id, 'page row ' + name); continue; }
    const h = r.handler;
    if (!h) { row(id, 'no', JSON.stringify(r).slice(0, 300)); continue; }
    row(id, (h.received === r.sent_bytes && h.pattern_ok === true) ? 'yes' : 'no',
      'received ' + h.received + ' of ' + r.sent_bytes + ' byte(s), pattern_ok=' +
      h.pattern_ok + ', chunks=' + h.chunks);
  }
  wholeEightRow('linux_whole_8mib_synchronous');
}

// --- shared: the 8 MiB whole-body row every engine answers ---------------

function wholeEightRow(id) {
  const r = pageRow('m2.whole_8m');
  if (!r) { absent(id, 'page row m2.whole_8m'); return; }
  const want = 8 * 1024 * 1024;
  row(id, (r.status === 200 && r.bytes === want) ? 'yes' : 'no',
    'status ' + r.status + ', ' + r.bytes + ' of ' + want +
    ' byte(s), ' + (typeof r.t_ms === 'number' ? r.t_ms.toFixed(1) : '?') +
    ' ms page-side');
}

// --- emit -----------------------------------------------------------------

if (target === 'linux') { linuxRows(); } else { macosRows(); }

const out = {
  schema: 1,
  shard: 'CAP-12B',
  entry_conditions: target === 'linux' ? '6.3.2' : '6.3.1',
  target: target,
  source: sourcePath,
  source_present: raw !== null,
  source_overall: raw ? (raw.overall || '') : '',
  source_failures: raw ? (raw.failures || '') : rawError,
  runner: {
    webkitgtk_version: facts.webkitgtk_version || '',
    gtk_version: facts.gtk_version || '',
    os_version: facts.os_version || '',
    arch: facts.arch || '',
    toolchain: facts.toolchain || ''
  },
  rows: rows
};

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n');

const width = rows.reduce((m, r) => Math.max(m, r.id.length), 0);
console.log('[cap12b] entry-condition rows for ' + target +
  ' (' + out.entry_conditions + ')');
for (const r of rows) {
  console.log('  ' + r.id.padEnd(width) + '  ' + r.verdict.padEnd(9) + '  ' +
    r.evidence);
}
console.log('[cap12b] wrote ' + outPath);
