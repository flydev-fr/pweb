// CAP-12B: the live page. It drives the PRODUCTION blob plane through the
// PRODUCTION handler and reports what it observed; the verdict is computed
// once, in test/cap12b/summarize_live.js, from this report joined with what
// the host could see.
//
// THE PAGE REPORTS FACTS, NEVER VERDICTS. Every row carries what happened -
// a status, a byte count, the index of the first byte that did not match,
// a duration - and never "ok". A page that decided its own verdicts would
// be a page that could decide them wrongly and still say PASS.
//
// IT RUNS IN TWO DOCUMENTS, on purpose. Phase 1 exercises the plane and
// then reloads; phase 2 checks that every blob phase 1 held is gone. A
// document replacement is the one lifetime rule that cannot be observed
// from inside a single document, and the host's trusted-document hook -
// the production one - is what the reload is testing.
'use strict';

var PATTERN_MOD = 251;

var report = {
  phase1: null,
  phase2: null,
  errors: [],
  csp_violations: []
};

function now() { return performance.now(); }

// `__pweb_blob_phase` is called EXACTLY ONCE per document, and that is what
// makes it a phase counter at all. There is deliberately no mark() helper
// here: a second caller would make the host's count of document loads a
// count of something else.

function patternBytes(n) {
  var out = new Uint8Array(n);
  for (var i = 0; i < n; i++) { out[i] = i % PATTERN_MOD; }
  return out;
}

// CRC-32C (Castagnoli), reflected, init and xorout 0xFFFFFFFF - the same
// function the native side computes over what ARRIVED. It is written here,
// independently, on purpose: "byte-exact" checked by comparing the handler's
// count against the page's count is a length claim, and two independent
// implementations of one checksum agreeing over 256 MiB is not.
var CRC32C_TABLE = (function () {
  var t = new Uint32Array(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) ? (0x82F63B78 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32c(buf) {
  var c = 0xFFFFFFFF;
  for (var i = 0; i < buf.length; i++) {
    c = CRC32C_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  }
  return ((c ^ 0xFFFFFFFF) >>> 0).toString(16).padStart(8, '0');
}

// the index of the first byte that is not the pattern at `offset`, or -1.
// AN OFFSET CHECK, not a length one: a handler that answered the first N
// bytes of a window instead of the requested window passes a length check.
function patternBadAt(u8, offset) {
  for (var i = 0; i < u8.length; i++) {
    if (u8[i] !== ((offset + i) % PATTERN_MOD)) { return i; }
  }
  return -1;
}

function headerMap(res) {
  var out = {};
  try { res.headers.forEach(function (v, k) { out[String(k).toLowerCase()] = v; }); }
  catch (e) { /* no-op */ }
  return out;
}

function withDeadline(ms, tag, fn) {
  return new Promise(function (resolve) {
    var done = false;
    var timer = setTimeout(function () {
      if (!done) { done = true; resolve({ deadline_ms: ms, timed_out: true }); }
    }, ms);
    Promise.resolve().then(fn).then(function (v) {
      if (done) { return; }
      done = true; clearTimeout(timer); resolve(v);
    }, function (e) {
      if (done) { return; }
      done = true; clearTimeout(timer);
      resolve({ error: String(e && e.name), message: String(e && e.message) });
    });
  });
}

// --- the rows ------------------------------------------------------------

function wholeRow(seed) {
  return withDeadline(60000, 'whole', function () {
    var t0 = now();
    return fetch(seed.prefix + seed.small).then(function (res) {
      var h = headerMap(res);
      return res.arrayBuffer().then(function (b) {
        var u8 = new Uint8Array(b);
        return {
          status: res.status,
          bytes: u8.length,
          expected_bytes: seed.smallBytes,
          pattern_bad_at: patternBadAt(u8, 0),
          content_type: h['content-type'] || null,
          accept_ranges: h['accept-ranges'] || null,
          cache_control: h['cache-control'] || null,
          csp: h['content-security-policy'] || null,
          nosniff: h['x-content-type-options'] || null,
          referrer_policy: h['referrer-policy'] || null,
          t_ms: now() - t0
        };
      });
    });
  });
}

function rangeRow(seed, rangeValue, expectBytes, expectOffset) {
  return withDeadline(60000, 'range', function () {
    return fetch(seed.prefix + seed.mid, {
      headers: { Range: rangeValue }
    }).then(function (res) {
      var h = headerMap(res);
      return res.arrayBuffer().then(function (b) {
        var u8 = new Uint8Array(b);
        return {
          range: rangeValue,
          status: res.status,
          bytes: u8.length,
          expected_bytes: expectBytes,
          pattern_bad_at: patternBadAt(u8, expectOffset),
          content_range: h['content-range'] || null,
          accept_ranges: h['accept-ranges'] || null,
          csp: h['content-security-policy'] || null
        };
      });
    });
  });
}

function imageRow(seed) {
  return withDeadline(30000, 'image', function () {
    return new Promise(function (resolve) {
      var el = document.getElementById('shot');
      var t0 = now();
      el.onload = function () {
        resolve({ loaded: true, width: el.naturalWidth,
                  height: el.naturalHeight, t_ms: now() - t0 });
      };
      el.onerror = function () {
        resolve({ loaded: false, t_ms: now() - t0 });
      };
      el.src = seed.prefix + seed.png;
    });
  });
}

// THE UPLOAD PATH, PROVEN BY ITS OWN REFUSAL. CAP-12B builds the request
// body path on all three engines and wires no consumer onto it, so the
// handler drains the body, refuses the method by name, and names the count
// and the crc32c of what actually arrived. The page checks the count; the
// checksum is what makes "byte-exact" more than a length claim, and the
// summarizer compares it against the one the host computes over the same
// pattern.
function uploadRow(seed, sizeBytes, method) {
  return withDeadline(300000, 'upload', function () {
    var body = patternBytes(sizeBytes);
    var sentCrc = crc32c(body);
    var t0 = now();
    return fetch(seed.prefix + seed.small, {
      method: method, body: body
    }).then(function (res) {
      var h = headerMap(res);
      return res.text().then(function (t) {
        var parsed = null;
        try { parsed = JSON.parse(t); } catch (e) { /* no-op */ }
        return {
          method: method,
          sent_bytes: sizeBytes,
          sent_crc32c: sentCrc,
          status: res.status,
          allow: h['allow'] || null,
          csp: h['content-security-policy'] || null,
          handler: parsed,
          raw: parsed ? undefined : t.slice(0, 200),
          t_ms: now() - t0
        };
      });
    });
  });
}

function refusedRow(seed, token) {
  return withDeadline(30000, 'refused', function () {
    return fetch(seed.prefix + token).then(function (res) {
      var h = headerMap(res);
      return res.text().then(function (t) {
        return {
          status: res.status,
          body: t.slice(0, 64),
          content_type: h['content-type'] || null,
          csp: h['content-security-policy'] || null,
          accept_ranges: h['accept-ranges'] || null
        };
      });
    });
  });
}

// CAP-12A entry condition 6.3.3, against the REAL store: the 8 MiB window
// produced and drained through the production handler, with an ordinary
// ASSET requested while it is in flight. The stall an engine imposes on the
// rest of the resource plane is the number the window bound exists for, so
// it is measured rather than assumed - and it is measured here because the
// dev host is the one that reaches WebView2.
function windowRow(seed) {
  return withDeadline(300000, 'window', function () {
    var t0 = now();
    var assetAt = -1;
    var blobAt = -1;
    var blobBytes = -1;
    var blobBad = -2;
    var blob = fetch(seed.prefix + seed.window).then(function (res) {
      return res.arrayBuffer().then(function (b) {
        blobAt = now() - t0;
        var u8 = new Uint8Array(b);
        blobBytes = u8.length;
        // the whole 8 MiB is offset-checked, not sampled: this row is the
        // one that decides the ceiling, so it does not get to be cheap
        blobBad = patternBadAt(u8, 0);
        return res.status;
      });
    });
    var asset = fetch('pweb://app/assets/live.js').then(function (res) {
      return res.text().then(function (t) {
        assetAt = now() - t0;
        return { status: res.status, bytes: t.length };
      });
    });
    return Promise.all([blob, asset]).then(function (r) {
      return {
        blob_status: r[0],
        blob_bytes: blobBytes,
        expected_bytes: seed.windowBytes,
        pattern_bad_at: blobBad,
        blob_at_ms: blobAt,
        asset_status: r[1].status,
        asset_bytes: r[1].bytes,
        asset_at_ms: assetAt,
        total_ms: now() - t0
      };
    });
  });
}

function concurrentRow(seed, n) {
  return withDeadline(120000, 'concurrent', function () {
    var t0 = now();
    var all = [];
    for (var i = 0; i < n; i++) {
      all.push(fetch(seed.prefix + seed.small).then(function (res) {
        return res.arrayBuffer().then(function (b) {
          return res.status === 200 ? b.byteLength : ('status:' + res.status);
        });
      }).catch(function (e) { return 'err:' + String(e && e.name); }));
    }
    return Promise.all(all).then(function (sizes) {
      var ok = 0;
      var bad = [];
      for (var i = 0; i < sizes.length; i++) {
        if (sizes[i] === seed.smallBytes) { ok++; } else { bad.push(sizes[i]); }
      }
      return { n: n, completed: ok, failures: bad.slice(0, 8),
               t_ms: now() - t0 };
    });
  });
}

// THE ASSET PLANE, BESIDE THE BLOB PLANE, AND UNCHANGED. The branch runs
// before the asset store is consulted, so the one thing that must be
// measured is that an ordinary asset still behaves exactly as it did.
function assetRow() {
  return withDeadline(30000, 'asset', function () {
    return fetch('pweb://app/assets/live.js').then(function (res) {
      var h = headerMap(res);
      return res.text().then(function (t) {
        return {
          status: res.status,
          bytes: t.length,
          content_type: h['content-type'] || null,
          accept_ranges: h['accept-ranges'] || null,
          content_range: h['content-range'] || null,
          csp: h['content-security-policy'] || null,
          cache_control: h['cache-control'] || null
        };
      });
    });
  });
}

function reservedRow() {
  return withDeadline(30000, 'reserved', function () {
    // a reserved path that is not a blob path: the handler answers it, and
    // NO store - asset, folder or generation - is ever consulted under it
    return fetch('pweb://app/_pweb/blob/not-a-token').then(function (res) {
      return res.text().then(function (t) {
        return { status: res.status, body: t.slice(0, 64) };
      });
    });
  });
}

// --- the two phases ------------------------------------------------------

function phaseOne(seed) {
  var out = {};
  var steps = [
    ['whole', function () { return wholeRow(seed); }],
    ['range_single', function () {
      return rangeRow(seed, 'bytes=1000-1099', 100, 1000);
    }],
    ['range_suffix', function () {
      return rangeRow(seed, 'bytes=-128', 128, seed.midBytes - 128);
    }],
    ['range_declined', function () {
      return rangeRow(seed, 'bytes=0-9,20-29', seed.midBytes, 0);
    }],
    ['range_unsatisfiable', function () {
      return rangeRow(seed, 'bytes=' + (seed.midBytes + 10) + '-', 0, 0);
    }],
    ['image', function () { return imageRow(seed); }],
    ['upload_put_1m', function () {
      return uploadRow(seed, 1048576, 'PUT');
    }],
    ['upload_post_16m', function () {
      return uploadRow(seed, 16 * 1048576, 'POST');
    }],
    ['upload_put_256m', function () {
      return uploadRow(seed, 256 * 1048576, 'PUT');
    }],
    ['foreign', function () { return refusedRow(seed, seed.foreign); }],
    ['unknown', function () { return refusedRow(seed, seed.unknown); }],
    ['released', function () {
      return withDeadline(30000, 'released', function () {
        return Promise.resolve(window.__pweb_blob_release(seed.releasable))
          .then(function (ok) {
            return refusedRow(seed, seed.releasable).then(function (r) {
              r.host_released = ok;
              return r;
            });
          });
      });
    }],
    ['window', function () { return windowRow(seed); }],
    ['concurrent', function () { return concurrentRow(seed, 32); }],
    ['asset_beside', function () { return assetRow(); }],
    ['reserved_not_a_blob', function () { return reservedRow(); }]
  ];
  var i = 0;
  function step() {
    if (i >= steps.length) { return Promise.resolve(out); }
    var name = steps[i][0];
    var fn = steps[i][1];
    i++;
    document.getElementById('state').textContent = 'phase1: ' + name;
    return Promise.resolve().then(fn).then(function (v) {
      out[name] = v;
    }, function (e) {
      out[name] = { fatal: String(e && e.message) };
    }).then(step);
  }
  return step();
}

function phaseTwo(seed, carried) {
  // EVERY BLOB OF THE PREVIOUS DOCUMENT, checked one by one. The page does
  // not ask whether "some" survived: it asks about each token it held.
  var names = ['small', 'png', 'mid', 'window'];
  var out = { carried: carried, tokens: {} };
  var i = 0;
  function step() {
    if (i >= names.length) {
      return assetRow().then(function (a) {
        out.asset_after_navigation = a;
        return out;
      });
    }
    var name = names[i];
    i++;
    document.getElementById('state').textContent = 'phase2: ' + name;
    return refusedRow(seed, seed[name]).then(function (r) {
      out.tokens[name] = r;
    }).then(step);
  }
  return step();
}

// --- the run -------------------------------------------------------------

function run() {
  var seed = null;
  var phase = 0;
  document.addEventListener('securitypolicyviolation', function (e) {
    if (report.csp_violations.length < 16) {
      report.csp_violations.push({
        directive: e.violatedDirective, blocked: e.blockedURI,
        disposition: e.disposition
      });
    }
  });
  window.addEventListener('error', function (e) {
    if (report.errors.length < 16) { report.errors.push(String(e.message)); }
  });

  Promise.resolve(window.__pweb_blob_seed()).then(function (s) {
    seed = typeof s === 'string' ? JSON.parse(s) : s;
    return Promise.resolve(window.__pweb_blob_phase());
  }).then(function (p) {
    phase = Number(p) || 0;
    if (phase <= 1) {
      return phaseOne(seed).then(function (one) {
        report.phase1 = one;
        // THE RELOAD IS THE TEST. sessionStorage carries the phase-1 report
        // across the document replacement, because the host cannot hold it
        // for us without becoming part of what is being measured.
        try { sessionStorage.setItem('cap12b', JSON.stringify(one)); }
        catch (e) { /* the host's phase counter is the backstop */ }
        document.getElementById('state').textContent = 'reloading';
        location.reload();
        return null;
      });
    }
    var carried = null;
    try { carried = JSON.parse(sessionStorage.getItem('cap12b') || 'null'); }
    catch (e) { carried = null; }
    report.phase1 = carried;
    return phaseTwo(seed, carried !== null).then(function (two) {
      report.phase2 = two;
      document.getElementById('state').textContent = 'done';
      return window.__pweb_blob_report(report);
    });
  }).catch(function (e) {
    report.errors.push('run: ' + String(e && e.message));
    try { window.__pweb_blob_report(report); } catch (x) { /* no-op */ }
  });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', run);
} else {
  run();
}
