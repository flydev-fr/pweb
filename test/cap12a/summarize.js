#!/usr/bin/env node
// CAP-12A: the ONE place a measurement becomes a verdict.
//
// The two run scripts differ in how they build and run; they must never
// differ in what a row means. Every engine's raw report is read here, joined
// with that engine's host timeline, and reduced to the M1-M5 table the
// decision artifact carries.
//
// Rules this file obeys:
//  * a verdict is computed from evidence present in the file, never from
//    what the author expected the engine to do;
//  * where the evidence cannot decide, the verdict is `undecided` with the
//    reason attached - never a guess and never a pass;
//  * an engine whose report is absent is `not_measured`, which is a
//    different thing from a failure and is printed as such.
//
// Usage: node test/cap12a/summarize.js [--work build/cap12a] [--json]

'use strict';

const fs = require('fs');
const path = require('path');

let work = 'build/cap12a';
let asJson = false;
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--work') { work = process.argv[++i]; }
  else if (process.argv[i] === '--json') { asJson = true; }
  else { console.error('unknown option: ' + process.argv[i]); process.exit(2); }
}

const TARGETS = [
  'windows-x86_64',
  'linux-x86_64',
  'macos-x86_64',
  'macos-arm64'
];

function load(target) {
  const p = path.join(work, target + '.json');
  if (!fs.existsSync(p)) { return null; }
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { return { parse_error: String(e.message) }; }
}

// --- timeline helpers -----------------------------------------------------

function slice(t, fromEvent, toEvent) {
  const i = t.findIndex((e) => e.e === fromEvent);
  if (i < 0) { return []; }
  const k = t.findIndex((e) => e.e === toEvent);
  return t.slice(i, k < 0 ? t.length : k + 1);
}

function firstUs(list, re) {
  const e = list.find((x) => re.test(x.e));
  return e ? e.us : null;
}

function lastUs(list, re) {
  for (let i = list.length - 1; i >= 0; i--) {
    if (re.test(list[i].e)) { return list[i].us; }
  }
  return null;
}

function count(list, re) {
  return list.filter((x) => re.test(x.e)).length;
}

// How many distinct producers did the engine switch between while draining?
// One switch per stream means strict serialisation; N times the stream count
// means interleaving. This is the only measurement that can tell a handler
// that was ASKED concurrently from an engine that DELIVERS concurrently.
function ownerSwitches(list, re) {
  let last = null;
  let switches = 0;
  for (const e of list) {
    if (!re.test(e.e)) { continue; }
    const id = e.e.split('.')[0];
    if (id !== last) { switches++; last = id; }
  }
  return switches;
}

function distinctOwners(list, re) {
  const s = new Set();
  for (const e of list) { if (re.test(e.e)) { s.add(e.e.split('.')[0]); } }
  return s.size;
}

// --- the verdicts ---------------------------------------------------------

function m1(rep) {
  const t = rep.timeline;
  const out = {};
  for (const [row, tag] of [['m1.stream_declared_len', 'm1a'],
                            ['m1.stream_no_len', 'm1b']]) {
    const r = rep.page.rows[row];
    const s = slice(t, 'row.begin:' + row, 'row.end:' + row);
    const lastProduce = lastUs(s, /\.produce$/);
    const firstChunkMark = firstUs(s, new RegExp('^' + tag + '\\.chunk$'));
    let verdict;
    let why;
    if (!r || r.error || r.timeout) {
      verdict = 'failed';
      why = JSON.stringify(r);
    } else if (!r.has_body_stream) {
      verdict = 'no_readable_stream';
      why = 'res.body was null';
    } else if (r.chunk_count <= 1) {
      // THE PAGE-SIDE WITNESS DECIDES, and deliberately so: the mark clock
      // runs on the host's GUI thread, which the engine may itself be
      // blocking, so a late mark could fake a "buffered" verdict. One reader
      // delivery carrying the whole body cannot.
      verdict = 'buffered_whole';
      why = 'the page ReadableStream produced ' + r.chunk_count +
            ' chunk(s) of ' + r.bytes + ' bytes';
    } else if (firstChunkMark !== null && lastProduce !== null &&
               firstChunkMark < lastProduce) {
      verdict = 'incremental';
      why = 'the page reported chunk 0 at ' + firstChunkMark +
            ' us, ' + Math.round((lastProduce - firstChunkMark) / 1000) +
            ' ms before the last chunk was produced (' + lastProduce + ' us)';
    } else {
      verdict = 'undecided';
      why = 'chunk_count=' + r.chunk_count + ' but no mark preceded the ' +
            'last production; the host clock cannot settle it';
    }
    out[row] = {
      verdict: verdict,
      why: why,
      chunk_count: r ? r.chunk_count : null,
      t_response_ms: r ? r.t_response_ms : null,
      t_first_chunk_ms: r ? r.t_first_chunk_ms : null,
      bytes_ok: r ? (r.bytes === r.expected_bytes) : null,
      pattern_ok: r ? (r.pattern_bad_at === -1) : null,
      engine_reads: count(s, /\.read$/) || null,
      engine_read_waits: count(s, /\.read_wait$/) || null,
      engine_seeks: count(s, /\.seek$/) || null
    };
  }

  const sse = rep.page.rows['m1.sse'];
  let sseVerdict = 'failed';
  let sseWhy = JSON.stringify(sse);
  if (sse && sse.events === sse.expected) {
    const spread = sse.t_last_ms - sse.t_first_ms;
    // the producer spaces events 150 ms apart, so five gaps is 750 ms of
    // wall clock: an engine that delivers live reproduces that spread, one
    // that buffers collapses it to the dispatch of a single batch
    if (spread > 300) {
      sseVerdict = 'live';
      sseWhy = 'six events spread over ' + Math.round(spread) +
               ' ms, against a 150 ms producer interval';
    } else {
      sseVerdict = 'buffered_whole';
      sseWhy = 'six events arrived within ' + Math.round(spread) +
               ' ms of each other, against a 150 ms producer interval';
    }
  }

  const img = rep.page.rows['m1.image_by_url'];
  return {
    fetch_stream: out,
    event_source: { verdict: sseVerdict, why: sseWhy,
                    events: sse ? sse.events : null },
    image_by_url: {
      verdict: img && img.loaded && img.width === 1 ? 'decoded' : 'failed',
      why: JSON.stringify(img)
    }
  };
}

function m2(rep) {
  const t = rep.timeline;
  const rows = rep.page.rows;
  const rangeSeen = t.filter((e) => e.e === 'req.range');
  const media = {};
  for (const row of ['m2.audio_ranged', 'm2.audio_x_wav', 'm2.audio_unranged']) {
    const r = rows[row];
    const s = slice(t, 'row.begin:' + row, 'row.end:' + row);
    const ranges = s.filter((e) => e.e === 'req.range').map((e) => e.d);
    media[row] = {
      verdict: !r ? 'missing'
        : r.seeked ? 'played_and_seeked'
        : r.loadedmetadata ? 'metadata_only'
        : 'refused',
      error: r ? r.error : null,
      duration: r ? r.duration : null,
      current_time: r ? r.current_time : null,
      range_requests_to_handler: ranges
    };
  }
  function rangeRow(name) {
    const r = rows[name];
    if (!r || r.error) { return { verdict: 'failed', why: JSON.stringify(r) }; }
    return {
      status: r.status,
      content_range: r.headers ? r.headers['content-range'] : null,
      accept_ranges: r.headers ? r.headers['accept-ranges'] : null,
      bytes_ok: r.bytes === r.expected_bytes,
      offset_ok: r.pattern_bad_at_expected_offset === -1 &&
                 r.first_byte === r.expected_first_byte
    };
  }
  const a = rangeRow('m2.range_supported');
  const b = rangeRow('m2.range_suffix');
  const c = rangeRow('m2.range_ignored_by_handler');
  return {
    request_header_surfaced: {
      verdict: rangeSeen.length > 0 ? 'yes' : 'no',
      occurrences: rangeSeen.length,
      distinct_values: [...new Set(rangeSeen.map((e) => e.d))].slice(0, 8)
    },
    partial_206: {
      verdict: a.status === 206 && a.bytes_ok && a.offset_ok ? 'honoured'
        : 'not_honoured',
      detail: a
    },
    suffix_206: {
      verdict: b.status === 206 && b.bytes_ok && b.offset_ok ? 'honoured'
        : 'not_honoured',
      detail: b
    },
    handler_may_ignore_range: {
      verdict: c.status === 200 && c.bytes_ok ? 'engine_accepts_200'
        : 'engine_rejects_200',
      detail: c
    },
    media: media,
    media_support_claimed: rows.media_support || null
  };
}

function m3(rep) {
  const rows = rep.page.rows;
  const out = {};
  for (const name of Object.keys(rows)) {
    if (!name.startsWith('m3.')) { continue; }
    const r = rows[name];
    if (!r || r.error || r.timeout || !r.handler) {
      out[name] = { verdict: 'body_unavailable', why: JSON.stringify(r) };
      continue;
    }
    const exact = r.handler.received === r.sent_bytes;
    const enveloped = r.kind === 'formdata' && r.handler.received > r.sent_bytes;
    out[name] = {
      verdict: (exact || enveloped) ? 'received' : 'short',
      sent: r.sent_bytes,
      received: r.handler.received,
      pattern_ok: r.pattern_applicable ? r.handler.pattern_ok : 'n/a',
      method: r.method,
      t_ms: Math.round(r.t_ms)
    };
  }
  const facts = rep.engine_facts || {};
  return {
    rows: out,
    methods_seen: facts.methods_seen,
    requests_with_body: facts.requests_with_body
  };
}

function m4(rep) {
  const t = rep.timeline;
  const rows = rep.page.rows;
  const phases = {};
  for (const p of rep.rss_phases || []) { phases[p.phase] = p; }

  // THE HANDLER-ATTRIBUTABLE NUMBER, counted by the handler rather than
  // inferred from RSS. A process working set cannot separate what the
  // handler allocated from pages the engine maps into the same process, and
  // it moves between runs as the allocator reuses freed pages - the same
  // whole-body row measured 251 MiB and then 42 MiB on one machine. This is
  // the figure IBlobStore controls, and it does not move.
  function materialised(tag) {
    const s = slice(t, tag + '.begin', tag + '.end');
    const m = s.filter((e) => /\.materialised$/.test(e.e));
    if (!m.length) { return null; }
    return { bytes: Math.max(...m.map((e) => e.v || 0)), what: m[0].d };
  }

  const conc = {};
  for (const [row, n] of [['m4.concurrency_1', 1], ['m4.concurrency_8', 8],
                          ['m4.concurrency_64', 64]]) {
    const s = slice(t, 'row.begin:' + row, 'row.end:' + row);
    const responded = count(s, /\.respond_lazy$|\.respond$/);
    const owners = distinctOwners(s, /\.(read|produce)$/);
    const switches = ownerSwitches(s, /\.(read|produce)$/);
    conc[row] = {
      requested: n,
      completed: rows[row] ? rows[row].completed : null,
      responded_before_first_body_ended: responded,
      distinct_bodies_drained: owners,
      owner_switches: switches,
      // one switch per body is strict serialisation; more than that means
      // the engine was moving between bodies as they produced
      delivery: owners > 0 && switches <= owners ? 'serial' : 'interleaved',
      wall_ms: rows[row] ? Math.round(rows[row].t_ms) : null
    };
  }

  const slow = rows['m4.slow_producer'] || {};
  const slowSlice = slice(t, 'm4d.begin', 'm4d.end');
  // the two engines name the arrival differently - WebView2 knows the URI at
  // req.enter, WebKitGTK only one call later at req.got_uri - so both
  // spellings are accepted rather than one leg silently reporting null
  const assetEnter = slowSlice.find(
    (e) => (e.e === 'req.enter' || e.e === 'req.got_uri') &&
           /assets\/probe\.js$/.test(e.d || ''));
  const slowBegin = slowSlice.length ? slowSlice[0].us : null;
  return {
    rss_256m_whole: phases.m4a || null,
    rss_256m_streamed: phases.m4b || null,
    handler_materialised_whole: materialised('m4a'),
    handler_materialised_streamed: materialised('m4b'),
    concurrency: conc,
    slow_producer: {
      // the two halves of "what does a slow producer cost": when the handler
      // was ASKED for the unrelated asset, and when the PAGE got it
      handler_reached_asset_after_ms:
        assetEnter && slowBegin !== null
          ? Math.round((assetEnter.us - slowBegin) / 1000) : null,
      page_saw_asset_after_ms: slow.asset ? Math.round(slow.asset.t_ms) : null,
      page_timer_max_gap_ms: slow.max_gap_ms,
      page_timer_mean_gap_ms: slow.mean_gap_ms
    }
  };
}

function namespaceSection(rep) {
  const ns = rep.page.rows.ns || {};
  const violations = rep.page.csp_violations || [];
  const connectViolation = violations.find(
    (v) => String(v.directive).indexOf('connect-src') === 0);
  const facts = rep.engine_facts || {};
  return {
    reserved_prefix_under_app: {
      verdict: ns.reserved_under_app && ns.reserved_under_app.ok &&
               ns.reserved_under_app.pattern_bad_at === -1
        ? 'served' : 'failed',
      detail: ns.reserved_under_app
    },
    second_authority: {
      verdict: ns.second_authority && ns.second_authority.reached === false
        ? 'refused' : 'reached',
      refused_by: connectViolation ? 'csp:' + connectViolation.directive
        : 'not attributed to CSP by this engine',
      blocked_uri: connectViolation ? connectViolation.blocked : null,
      handler_was_never_asked: facts.second_authority_requests === 0
        ? true : facts.second_authority_requests === undefined ? null : false,
      detail: ns.second_authority
    },
    query_string: {
      verdict: ns.query_string_ignored && ns.query_string_ignored.ok
        ? 'stripped_same_resource' : 'failed',
      detail: ns.query_string_ignored
    }
  };
}

// --- assemble -------------------------------------------------------------

const report = { schema: 1, generated: new Date().toISOString(), targets: {} };
for (const target of TARGETS) {
  const rep = load(target);
  if (!rep) {
    report.targets[target] = { state: 'not_measured' };
    continue;
  }
  if (rep.parse_error) {
    report.targets[target] = { state: 'unreadable', error: rep.parse_error };
    continue;
  }
  report.targets[target] = {
    state: rep.overall,
    failures: rep.failures || null,
    csp: rep.csp,
    timeline_events: rep.timeline_events,
    timeline_dropped: rep.timeline_dropped,
    namespace: namespaceSection(rep),
    M1: m1(rep),
    M2: m2(rep),
    M3: m3(rep),
    M4: m4(rep)
  };
}

if (asJson) {
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  process.exit(0);
}

function line(s) { process.stdout.write(s + '\n'); }

line('CAP-12A blob data-plane measurement summary');
line('generated ' + report.generated);
line('');
for (const [target, r] of Object.entries(report.targets)) {
  line('=== ' + target + ' === ' + r.state);
  if (r.state === 'not_measured' || r.state === 'unreadable') { line(''); continue; }
  if (r.failures) { line('  failures: ' + r.failures); }
  line('  timeline: ' + r.timeline_events + ' events, ' +
       r.timeline_dropped + ' dropped');
  line('  NAMESPACE');
  line('    _pweb/blob under pweb://app : ' +
       r.namespace.reserved_prefix_under_app.verdict);
  line('    pweb://blob (2nd authority) : ' +
       r.namespace.second_authority.verdict + ' (' +
       r.namespace.second_authority.refused_by + ', handler never asked: ' +
       r.namespace.second_authority.handler_was_never_asked + ')');
  line('    query string                : ' + r.namespace.query_string.verdict);
  line('  M1 STREAMING');
  for (const [k, v] of Object.entries(r.M1.fetch_stream)) {
    line('    ' + k.padEnd(24) + ': ' + v.verdict + ' - ' + v.why);
    line('      engine reads=' + v.engine_reads + ' waits=' +
         v.engine_read_waits + ' seeks=' + v.engine_seeks +
         ' t_response=' + Math.round(v.t_response_ms) + 'ms');
  }
  line('    EventSource             : ' + r.M1.event_source.verdict + ' - ' +
       r.M1.event_source.why);
  line('    <img> by URL            : ' + r.M1.image_by_url.verdict);
  line('  M2 RANGE');
  line('    Range header surfaced   : ' + r.M2.request_header_surfaced.verdict +
       ' (' + r.M2.request_header_surfaced.occurrences + ' requests; ' +
       JSON.stringify(r.M2.request_header_surfaced.distinct_values) + ')');
  line('    206 + Content-Range     : ' + r.M2.partial_206.verdict);
  line('    suffix range            : ' + r.M2.suffix_206.verdict);
  line('    200 to a Range request  : ' + r.M2.handler_may_ignore_range.verdict);
  for (const [k, v] of Object.entries(r.M2.media)) {
    line('    ' + k.padEnd(24) + ': ' + v.verdict +
         ' (err=' + v.error + ', ranges=' +
         JSON.stringify(v.range_requests_to_handler) + ')');
  }
  line('  M3 REQUEST BODIES');
  for (const [k, v] of Object.entries(r.M3.rows)) {
    line('    ' + k.padEnd(28) + ': ' + v.verdict +
         (v.received !== undefined
           ? ' sent=' + v.sent + ' received=' + v.received +
             ' pattern=' + v.pattern_ok + ' ' + v.t_ms + 'ms'
           : ' ' + v.why));
  }
  line('    methods seen            : ' + r.M3.methods_seen);
  line('  M4 MEMORY AND CONCURRENCY');
  const w = r.M4.rss_256m_whole;
  const st = r.M4.rss_256m_streamed;
  line('    256 MiB whole   peak RSS: ' +
       (w ? Math.round(w.delta_bytes / 1048576) + ' MiB over baseline' : 'n/a'));
  line('    256 MiB stream  peak RSS: ' +
       (st ? Math.round(st.delta_bytes / 1048576) + ' MiB over baseline' : 'n/a'));
  const mw = r.M4.handler_materialised_whole;
  const ms = r.M4.handler_materialised_streamed;
  line('    handler materialised    : whole=' +
       (mw ? Math.round(mw.bytes / 1048576) + ' MiB (' + mw.what + ')' : 'n/a'));
  line('                              stream=' +
       (ms ? Math.round(ms.bytes / 1048576) + ' MiB (' + ms.what + ')' : 'n/a'));
  for (const [k, v] of Object.entries(r.M4.concurrency)) {
    line('    ' + k.padEnd(24) + ': completed=' + v.completed +
         ' responded=' + v.responded_before_first_body_ended +
         ' bodies=' + v.distinct_bodies_drained +
         ' switches=' + v.owner_switches +
         ' -> ' + v.delivery + ' (' + v.wall_ms + 'ms)');
  }
  const sp = r.M4.slow_producer;
  line('    slow producer           : handler reached the unrelated asset ' +
       'after ' + sp.handler_reached_asset_after_ms + ' ms; the PAGE got it ' +
       'after ' + sp.page_saw_asset_after_ms + ' ms; page timer max gap ' +
       sp.page_timer_max_gap_ms + ' ms');
  line('');
}
