// CAP-12A: the page half of the blob data-plane measurement.
//
// Every row states an OBSERVED fact and never a verdict. The verdicts are
// computed once, in test/cap12a/summarize.js, from this report joined with
// the host's timeline - because the two are read on one clock only through
// the host, and because a page that graded itself would be the one witness
// that cannot be cross-checked.
//
// Two rules the rows obey:
//  * every row is bounded by its own deadline, so one hung engine row costs
//    that row and not the run;
//  * every body is the deterministic pattern byte[i] == (offset + i) % 251,
//    so a 206 is checked for OFFSET, not merely for length. An engine that
//    answered a Range request with the first N bytes would pass a
//    length-only check and is caught here.

'use strict';

var PAT = 251;
var report = {
  schema: 1,
  started: Date.now(),
  rows: {},
  csp_violations: [],
  errors: []
};

function mark(label) {
  // fire and forget: awaiting a mark inside a read loop would add the
  // round trip to the very latency the row measures
  try { window.__cap12a_mark(label); } catch (e) { /* no-op */ }
}

function markSync(label) {
  try { return window.__cap12a_mark(label); } catch (e) { return Promise.resolve(); }
}

function now() { return performance.now(); }

function withDeadline(ms, label, fn) {
  return new Promise(function (resolve) {
    var done = false;
    var timer = setTimeout(function () {
      if (done) { return; }
      done = true;
      resolve({ timeout: true, deadline_ms: ms });
    }, ms);
    Promise.resolve()
      .then(fn)
      .then(function (v) {
        if (done) { return; }
        done = true;
        clearTimeout(timer);
        resolve(v);
      })
      .catch(function (e) {
        if (done) { return; }
        done = true;
        clearTimeout(timer);
        resolve({ error: String(e && e.name), message: String(e && e.message) });
      });
  });
}

function patternBytes(n, offset) {
  var a = new Uint8Array(n);
  var v = (offset || 0) % PAT;
  for (var i = 0; i < n; i++) {
    a[i] = v;
    v = (v + 1) % PAT;
  }
  return a;
}

function checkPattern(u8, offset) {
  var v = (offset || 0) % PAT;
  for (var i = 0; i < u8.length; i++) {
    if (u8[i] !== v) { return i; }
    v = (v + 1) % PAT;
  }
  return -1;
}

function headerMap(res) {
  var h = {};
  try {
    res.headers.forEach(function (value, key) { h[key] = value; });
  } catch (e) { h.__unreadable = String(e); }
  return h;
}

// --- M1: streamed responses -----------------------------------------------

function streamRow(tag, url, expectBytes) {
  return withDeadline(60000, tag, function () {
    var t0 = now();
    return fetch(url).then(function (res) {
      var tResp = now();
      var chunks = [];
      var total = 0;
      var hasBody = !!res.body;
      if (!hasBody) {
        // no ReadableStream at all on this engine: read it whole and say so
        return res.arrayBuffer().then(function (b) {
          mark(tag + '.whole');
          return {
            status: res.status,
            headers: headerMap(res),
            has_body_stream: false,
            bytes: b.byteLength,
            t_response_ms: tResp - t0,
            t_first_chunk_ms: null,
            t_last_chunk_ms: now() - t0,
            chunk_count: 0,
            chunk_sizes: [],
            chunk_ms: [],
            pattern_bad_at: checkPattern(new Uint8Array(b), 0)
          };
        });
      }
      var reader = res.body.getReader();
      var firstMs = null;
      var sizes = [];
      var times = [];
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) { return; }
          total += r.value.length;
          if (firstMs === null) { firstMs = now() - t0; }
          // THE MARK IS THE MEASUREMENT: the host timestamps its arrival on
          // the same clock its producer wrote, so "chunk 0 seen before the
          // last chunk was produced" is a one-clock statement.
          mark(tag + '.chunk');
          sizes.push(r.value.length);
          times.push(now() - t0);
          if (chunks.length < 4096) { chunks.push(r.value); }
          return pump();
        });
      }
      return pump().then(function () {
        var joined = new Uint8Array(total);
        var at = 0;
        for (var i = 0; i < chunks.length; i++) {
          joined.set(chunks[i], at);
          at += chunks[i].length;
        }
        return {
          status: res.status,
          headers: headerMap(res),
          has_body_stream: true,
          bytes: total,
          expected_bytes: expectBytes,
          t_response_ms: tResp - t0,
          t_first_chunk_ms: firstMs,
          t_last_chunk_ms: times.length ? times[times.length - 1] : null,
          chunk_count: sizes.length,
          chunk_sizes: sizes.slice(0, 64),
          chunk_ms: times.slice(0, 64),
          pattern_bad_at: checkPattern(joined, 0)
        };
      });
    });
  });
}

function sseRow(tag, url, expectEvents) {
  return withDeadline(30000, tag, function () {
    return new Promise(function (resolve) {
      var t0 = now();
      var got = [];
      var es;
      try {
        es = new EventSource(url);
      } catch (e) {
        resolve({ constructed: false, error: String(e && e.message) });
        return;
      }
      var finish = function (why) {
        try { es.close(); } catch (e) { /* no-op */ }
        resolve({
          constructed: true,
          why: why,
          events: got.length,
          expected: expectEvents,
          t_ms: got.slice(0, 32),
          t_first_ms: got.length ? got[0] : null,
          t_last_ms: got.length ? got[got.length - 1] : null
        });
      };
      es.addEventListener('tick', function () {
        got.push(now() - t0);
        mark(tag + '.event');
        if (got.length >= expectEvents) { finish('complete'); }
      });
      es.onerror = function () {
        // an EventSource error after the last event is the ordinary end of a
        // finite stream, so it is recorded rather than treated as a failure
        finish(got.length >= expectEvents ? 'complete' : 'error');
      };
      setTimeout(function () { finish('deadline'); }, 25000);
    });
  });
}

// --- M2: Range ------------------------------------------------------------

function rangeRow(tag, url, rangeValue, expectLen, expectOffset) {
  return withDeadline(30000, tag, function () {
    return fetch(url, { headers: { Range: rangeValue } }).then(function (res) {
      return res.arrayBuffer().then(function (b) {
        var u8 = new Uint8Array(b);
        return {
          status: res.status,
          headers: headerMap(res),
          bytes: u8.length,
          expected_bytes: expectLen,
          // an engine (or handler) that served the FIRST N bytes instead of
          // the requested window fails here and passes a length-only check
          pattern_bad_at_expected_offset: checkPattern(u8, expectOffset),
          first_byte: u8.length ? u8[0] : null,
          expected_first_byte: expectOffset % PAT
        };
      });
    });
  });
}

// THE DISCRIMINATOR FOR EVERY MEDIA ROW. A media element that errors with
// MEDIA_ERR_SRC_NOT_SUPPORTED says nothing about the scheme until we know
// whether the engine claims the TYPE at all: an empty canPlayType means the
// build has no decoder and the row is environmental, while 'maybe' or
// 'probably' plus an error means the custom scheme is what failed.
function mediaSupportRow() {
  return withDeadline(10000, 'media_support', function () {
    var a = document.createElement('audio');
    var v = document.createElement('video');
    return {
      audio_wav: a.canPlayType('audio/wav'),
      audio_x_wav: a.canPlayType('audio/x-wav'),
      audio_wave: a.canPlayType('audio/wave'),
      audio_mpeg: a.canPlayType('audio/mpeg'),
      video_mp4: v.canPlayType('video/mp4'),
      video_webm: v.canPlayType('video/webm')
    };
  });
}

function imageRow(tag, url) {
  return withDeadline(20000, tag, function () {
    return new Promise(function (resolve) {
      var img = new Image();
      var t0 = now();
      img.onload = function () {
        resolve({ loaded: true, width: img.naturalWidth,
                  height: img.naturalHeight, t_ms: now() - t0 });
      };
      img.onerror = function () {
        resolve({ loaded: false, t_ms: now() - t0 });
      };
      img.src = url;
    });
  });
}

function audioRow(tag, url, seekTo) {
  return withDeadline(40000, tag, function () {
    return new Promise(function (resolve) {
      // a FRESH element per row: an <audio> that has already failed keeps a
      // sticky error and a network state that would be charged to the next
      // row's URL
      var el = document.createElement('audio');
      el.preload = 'metadata';
      document.body.appendChild(el);
      var out = {
        loadedmetadata: false,
        duration: null,
        seeked: false,
        seek_target: seekTo,
        current_time: null,
        error: null,
        ready_state: null
      };
      var settle = function (why) {
        out.why = why;
        out.ready_state = el.readyState;
        try { el.removeAttribute('src'); el.load(); } catch (e) { /* no-op */ }
        resolve(out);
      };
      el.addEventListener('error', function () {
        out.error = el.error ? (el.error.code + ':' + el.error.message) : 'unknown';
        settle('error');
      });
      el.addEventListener('loadedmetadata', function () {
        out.loadedmetadata = true;
        out.duration = el.duration;
        mark(tag + '.metadata');
        try {
          el.currentTime = seekTo;
        } catch (e) {
          out.error = 'seek threw: ' + String(e && e.message);
          settle('seek-threw');
        }
      });
      el.addEventListener('seeked', function () {
        out.seeked = true;
        out.current_time = el.currentTime;
        mark(tag + '.seeked');
        settle('seeked');
      });
      setTimeout(function () { if (!out.seeked) { settle('deadline'); } }, 35000);
      el.src = url;
      el.load();
    });
  });
}

// --- M3: request bodies ---------------------------------------------------

function echoRow(tag, bodyKind, sizeBytes, method) {
  return withDeadline(180000, tag, function () {
    var url = 'pweb://app/_pweb/blob/echo';
    var bytes = patternBytes(sizeBytes, 0);
    var body;
    if (bodyKind === 'string') {
      // a string body is UTF-8 encoded by fetch, so the pattern must stay
      // inside ASCII for the handler's byte check to mean anything
      var s = '';
      var ascii = new Uint8Array(sizeBytes);
      for (var i = 0; i < sizeBytes; i++) { ascii[i] = bytes[i] % 128; }
      s = new TextDecoder('latin1').decode(ascii);
      body = s;
    } else if (bodyKind === 'blob') {
      body = new Blob([bytes], { type: 'application/octet-stream' });
    } else if (bodyKind === 'file') {
      // A File CONSTRUCTED in the page, not one picked from <input type=file>:
      // the native file dialog cannot be driven in this harness. It is the
      // same interface object, and the difference - a picked File is backed
      // by an OS file the engine may transport by descriptor - is named as a
      // limitation rather than papered over.
      body = new File([bytes], 'upload.bin', { type: 'application/octet-stream' });
    } else if (bodyKind === 'formdata') {
      var fd = new FormData();
      fd.append('meta', 'cap12a');
      fd.append('blob', new Blob([bytes]), 'upload.bin');
      body = fd;
    } else if (bodyKind === 'arraybuffer') {
      body = bytes;
    }
    mark(tag + '.send');
    var t0 = now();
    return fetch(url, { method: method || 'POST', body: body }).then(function (res) {
      return res.text().then(function (t) {
        var parsed = null;
        try { parsed = JSON.parse(t); } catch (e) { /* no-op */ }
        return {
          status: res.status,
          sent_bytes: sizeBytes,
          kind: bodyKind,
          method: method || 'POST',
          // the string row folds the pattern into ASCII so that fetch's UTF-8
          // encoding cannot change the byte count, which means its bytes are
          // NOT the handler's pattern: pattern_ok is not applicable there
          pattern_applicable: bodyKind !== 'string' && bodyKind !== 'formdata',
          // formdata wraps the bytes in a multipart envelope, so `received`
          // is EXPECTED to exceed sent_bytes there and only there
          handler: parsed,
          raw: parsed ? undefined : t.slice(0, 200),
          t_ms: now() - t0
        };
      });
    });
  });
}

// --- M4: memory and concurrency -------------------------------------------

function drainRow(tag, url, useStream) {
  return withDeadline(180000, tag, function () {
    var t0 = now();
    return markSync(tag + '.begin').then(function () {
      return fetch(url);
    }).then(function (res) {
      if (!useStream || !res.body) {
        return res.arrayBuffer().then(function (b) {
          return { mode: 'whole', bytes: b.byteLength, status: res.status };
        });
      }
      var reader = res.body.getReader();
      var total = 0;
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) { return; }
          total += r.value.length;
          // the chunk is dropped immediately: this row asks what the ENGINE
          // holds, so the page must hold nothing
          return pump();
        });
      }
      return pump().then(function () {
        return { mode: 'stream', bytes: total, status: res.status };
      });
    }).then(function (v) {
      v.t_ms = now() - t0;
      return markSync(tag + '.end').then(function () { return v; });
    });
  });
}

function concurrencyRow(tag, url, n) {
  return withDeadline(120000, tag, function () {
    var t0 = now();
    return markSync(tag + '.begin').then(function () {
      var all = [];
      for (var i = 0; i < n; i++) {
        all.push(fetch(url).then(function (res) {
          return res.arrayBuffer().then(function (b) {
            return b.byteLength;
          });
        }).catch(function (e) { return 'err:' + String(e && e.name); }));
      }
      return Promise.all(all);
    }).then(function (sizes) {
      var ok = 0;
      var bad = [];
      for (var i = 0; i < sizes.length; i++) {
        if (typeof sizes[i] === 'number') { ok++; } else { bad.push(sizes[i]); }
      }
      var v = { n: n, completed: ok, failures: bad.slice(0, 8), t_ms: now() - t0 };
      return markSync(tag + '.end').then(function () { return v; });
    });
  });
}

function heartbeatRow(tag, slowUrl, assetUrl) {
  return withDeadline(120000, tag, function () {
    var gaps = [];
    var last = now();
    var timer = setInterval(function () {
      var t = now();
      gaps.push(t - last);
      last = t;
    }, 20);
    return markSync(tag + '.begin').then(function () {
      var slow = fetch(slowUrl).then(function (r) { return r.arrayBuffer(); });
      // the asset request is issued WHILE the slow producer is mid-body, and
      // its latency is the answer to "what does a slow producer do to the
      // page's other requests". The clock starts INSIDE the delay: an
      // earlier revision started it before, so the 300 ms wait was reported
      // as request latency and the row read as a 315 ms stall that was not
      // there.
      var assetT0 = 0;
      var asset = new Promise(function (resolve) {
        setTimeout(function () {
          assetT0 = now();
          fetch(assetUrl, { cache: 'no-store' }).then(function (r) {
            return r.text();
          }).then(function (t) {
            resolve({ ok: true, bytes: t.length, t_ms: now() - assetT0 });
          }).catch(function (e) {
            resolve({ ok: false, error: String(e && e.name) });
          });
        }, 300);
      });
      return Promise.all([slow, asset]);
    }).then(function (both) {
      clearInterval(timer);
      var max = 0;
      var sum = 0;
      for (var i = 0; i < gaps.length; i++) {
        if (gaps[i] > max) { max = gaps[i]; }
        sum += gaps[i];
      }
      var v = {
        slow_bytes: both[0].byteLength,
        asset: both[1],
        ticks: gaps.length,
        max_gap_ms: Math.round(max),
        mean_gap_ms: gaps.length ? Math.round((sum / gaps.length) * 10) / 10 : null
      };
      return markSync(tag + '.end').then(function () { return v; });
    });
  });
}

// --- the namespace rows ---------------------------------------------------

function namespaceRows() {
  var out = {};
  return withDeadline(30000, 'ns', function () {
    return fetch('pweb://app/_pweb/blob/whole-1024').then(function (res) {
      return res.arrayBuffer().then(function (b) {
        out.reserved_under_app = {
          ok: res.ok,
          status: res.status,
          bytes: b.byteLength,
          pattern_bad_at: checkPattern(new Uint8Array(b), 0)
        };
      });
    }).catch(function (e) {
      out.reserved_under_app = { ok: false, error: String(e && e.name),
                                 message: String(e && e.message) };
    }).then(function () {
      // THE PREMISE OF THE WHOLE SHARD, stated as a row: connect-src 'self'
      // is the shipped policy, so a SECOND AUTHORITY is a different origin
      // and a fetch to it is a CSP decision, not a handler decision.
      return fetch('pweb://blob/whole-1024').then(function (res) {
        return { reached: true, status: res.status };
      }).catch(function (e) {
        return { reached: false, error: String(e && e.name),
                 message: String(e && e.message) };
      });
    }).then(function (v) {
      out.second_authority = v;
      return fetch('pweb://app/_pweb/blob/whole-1024?range=1').then(function (res) {
        return res.arrayBuffer().then(function (b) {
          // the production URI parser DISCARDS the query string, so this
          // must be the same resource - recorded because a blob plane that
          // wanted to carry parameters in a query would find it cannot
          return { ok: res.ok, status: res.status, bytes: b.byteLength };
        });
      }).catch(function (e) {
        return { ok: false, error: String(e && e.name) };
      });
    }).then(function (v) {
      out.query_string_ignored = v;
      return out;
    });
  });
}

// --- the run --------------------------------------------------------------

var MB = 1024 * 1024;

function run() {
  document.addEventListener('securitypolicyviolation', function (e) {
    if (report.csp_violations.length < 32) {
      report.csp_violations.push({
        directive: e.violatedDirective,
        blocked: String(e.blockedURI).slice(0, 200),
        disposition: e.disposition
      });
    }
  });
  window.addEventListener('error', function (e) {
    if (report.errors.length < 16) { report.errors.push(String(e.message)); }
  });

  var seq = [
    ['ns', function () { return namespaceRows(); }],

    ['m1.stream_declared_len', function () {
      return streamRow('m1a', 'pweb://app/_pweb/blob/stream-8-262144-80', 8 * 262144);
    }],
    ['m1.stream_no_len', function () {
      return streamRow('m1b', 'pweb://app/_pweb/blob/streamnolen-8-262144-80', 8 * 262144);
    }],
    ['m1.sse', function () {
      return sseRow('m1c', 'pweb://app/_pweb/blob/sse-6-150', 6);
    }],

    ['m2.range_supported', function () {
      return rangeRow('m2a', 'pweb://app/_pweb/blob/ranged-1048576',
        'bytes=1000-1099', 100, 1000);
    }],
    ['m2.range_suffix', function () {
      return rangeRow('m2b', 'pweb://app/_pweb/blob/ranged-1048576',
        'bytes=-128', 128, 1048576 - 128);
    }],
    ['m2.range_ignored_by_handler', function () {
      return rangeRow('m2c', 'pweb://app/_pweb/blob/whole-1048576',
        'bytes=0-99', 1048576, 0);
    }],
    ['media_support', function () { return mediaSupportRow(); }],
    ['m1.image_by_url', function () {
      return imageRow('m1.image_by_url', 'pweb://app/_pweb/blob/png');
    }],
    ['m2.audio_ranged', function () {
      return audioRow('m2.audio_ranged', 'pweb://app/_pweb/blob/wav-60', 55);
    }],
    ['m2.audio_x_wav', function () {
      return audioRow('m2.audio_x_wav', 'pweb://app/_pweb/blob/wavx-60', 55);
    }],
    ['m2.audio_unranged', function () {
      return audioRow('m2.audio_unranged', 'pweb://app/_pweb/blob/wavnorange-60', 55);
    }],

    // THE FOUR BODY KINDS AT ONE SIZE FIRST, THEN ONE KIND AT THREE SIZES.
    // The first arrangement of these rows varied kind and size together -
    // arraybuffer at 1 MiB, blob at 16 MiB - and the four failures it
    // produced could be read either way. Kind and size are separated here so
    // each row answers one question.
    ['m3.post_arraybuffer_1m', function () { return echoRow('m3a', 'arraybuffer', MB); }],
    ['m3.post_string_1m', function () { return echoRow('m3b', 'string', MB); }],
    ['m3.post_blob_1m', function () { return echoRow('m3c', 'blob', MB); }],
    ['m3.post_file_1m', function () { return echoRow('m3d', 'file', MB); }],
    ['m3.post_formdata_1m', function () { return echoRow('m3e', 'formdata', MB); }],
    ['m3.post_arraybuffer_16m', function () { return echoRow('m3f', 'arraybuffer', 16 * MB); }],
    ['m3.post_arraybuffer_256m', function () { return echoRow('m3g', 'arraybuffer', 256 * MB); }],
    ['m3.put_arraybuffer_1m', function () { return echoRow('m3h', 'arraybuffer', MB, 'PUT'); }],

    ['m4.whole_256m', function () {
      return drainRow('m4a', 'pweb://app/_pweb/blob/whole-268435456', false);
    }],
    ['m4.stream_256m', function () {
      return drainRow('m4b', 'pweb://app/_pweb/blob/stream-256-1048576-0', true);
    }],
    ['m4.concurrency_1', function () {
      return concurrencyRow('m4c1', 'pweb://app/_pweb/blob/stream-4-65536-120', 1);
    }],
    ['m4.concurrency_8', function () {
      return concurrencyRow('m4c8', 'pweb://app/_pweb/blob/stream-4-65536-120', 8);
    }],
    ['m4.concurrency_64', function () {
      return concurrencyRow('m4c64', 'pweb://app/_pweb/blob/stream-4-65536-120', 64);
    }],
    ['m4.slow_producer', function () {
      return heartbeatRow('m4d', 'pweb://app/_pweb/blob/stream-40-65536-100',
        'pweb://app/assets/probe.js');
    }]
  ];

  var i = 0;
  function step() {
    if (i >= seq.length) {
      report.finished = Date.now();
      document.getElementById('state').textContent = 'done';
      try {
        window.__cap12a_report(JSON.stringify(report));
      } catch (e) { /* the host's watchdog is the backstop */ }
      return;
    }
    var name = seq[i][0];
    var fn = seq[i][1];
    i++;
    document.getElementById('state').textContent = name;
    markSync('row.begin:' + name).then(function () {
      return fn();
    }).then(function (v) {
      report.rows[name] = v;
      return markSync('row.end:' + name);
    }).catch(function (e) {
      report.rows[name] = { fatal: String(e && e.message) };
    }).then(step);
  }
  markSync('page.boot').then(step);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', run);
} else {
  run();
}
