/* CAP-15A probe server - THROWAWAY MEASUREMENT INSTRUMENT, not product code.
 *
 * It exists to answer one class of question that only a server can answer:
 * what does each engine actually PUT ON THE WIRE when a page served over
 * pweb://app talks to a remote origin. `fetch()` in the page can report what
 * it received; it cannot report what the server received, and for a no-cors
 * request it cannot report anything at all. So every request is appended to
 * a JSONL log with its full header set, and that log is the witness.
 *
 * Two listeners, on purpose:
 *   A  is the origin the throwaway widened CSP names, and the only origin the
 *      spike's native fetch allowlist names.
 *   B  is named by NOTHING. It is how "connect-src still governs" and "the
 *      native allowlist still refuses" are measured as an absence: a request
 *      that reaches B is a hole, and the log is where it shows up.
 *
 * No dependencies (no `ws`, no express): the WebSocket handshake and one
 * echo frame are ~40 lines, and a spike that needs `npm install` is a spike
 * that will not run on the next machine.
 *
 * Usage: node probe_server.js --portA 41597 --portB 41598 --log <path>
 */
'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const PORT_A = parseInt(arg('portA', '41597'), 10);
const PORT_B = parseInt(arg('portB', '41598'), 10);
const LOG = arg('log', 'probe-requests.jsonl');

// A PORT IS VALIDATED BEFORE ANYTHING BINDS. listen(NaN) binds a RANDOM free
// port and still calls back, so PROBE_READY would be printed for a server the
// page can never reach - and every row would then read as a refusal. Same
// reason the two runners now check their own --portA/--portB.
[['portA', PORT_A], ['portB', PORT_B]].forEach(function (p) {
  if (!Number.isInteger(p[1]) || p[1] < 1 || p[1] > 65535) {
    process.stderr.write('probe_server: bad --' + p[0] + '\n');
    process.exit(2);
  }
});
if (PORT_A === PORT_B) {
  process.stderr.write('probe_server: --portA and --portB must differ\n');
  process.exit(2);
}

const logStream = fs.createWriteStream(LOG, { flags: 'w' });

function record(srv, kind, req, extra) {
  const row = Object.assign(
    {
      t: Date.now(),
      srv: srv,
      kind: kind,
      method: req.method,
      url: req.url,
      headers: req.headers
    },
    extra || {}
  );
  logStream.write(JSON.stringify(row) + '\n');
}

/* ---- CORS composition, driven by the query so one endpoint measures every
 * shape without a second endpoint to keep in step ---------------------- */
function corsHeaders(req, q) {
  const origin = req.headers.origin;
  const mode = q.get('acao') || 'origin';
  const h = {};
  if (mode === 'origin') {
    // the exact-origin echo: what a cooperating server would have to send,
    // and the only shape that works with credentials
    if (origin !== undefined) h['Access-Control-Allow-Origin'] = origin;
  } else if (mode === 'star') {
    h['Access-Control-Allow-Origin'] = '*';
  } else if (mode === 'null') {
    h['Access-Control-Allow-Origin'] = 'null';
  } else if (mode === 'none') {
    /* deliberately nothing: the refusal control */
  }
  if (q.get('acac') === '1') h['Access-Control-Allow-Credentials'] = 'true';
  const expose = q.get('expose');
  if (expose) h['Access-Control-Expose-Headers'] = expose;
  return h;
}

function preflight(req, res, q) {
  const h = corsHeaders(req, q);
  h['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS';
  const asked = req.headers['access-control-request-headers'];
  h['Access-Control-Allow-Headers'] = asked || 'content-type, x-cap15a';
  h['Access-Control-Max-Age'] = '0';
  res.writeHead(204, h);
  res.end();
}

const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/' +
    'q842iQAAAABJRU5ErkJggg==',
  'base64'
);

function readBody(req, cap, cb) {
  let n = 0;
  const chunks = [];
  req.on('data', function (c) {
    n += c.length;
    if (n <= cap) chunks.push(c);
  });
  req.on('end', function () {
    cb(n, Buffer.concat(chunks));
  });
}

function handler(srv) {
  return function (req, res) {
    const u = new URL(req.url, 'http://127.0.0.1');
    const q = u.searchParams;

    if (req.method === 'OPTIONS') {
      record(srv, 'preflight', req, {
        acrMethod: req.headers['access-control-request-method'] || null,
        acrHeaders: req.headers['access-control-request-headers'] || null
      });
      if ((q.get('acao') || 'origin') === 'none') {
        // a preflight with no CORS answer at all: the browser must refuse
        record(srv, 'preflight-refused', req, {});
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('no cors');
        return;
      }
      preflight(req, res, q);
      return;
    }

    const path = u.pathname;

    if (path === '/echo' || path === '/exfil') {
      readBody(req, 4096, function (n, body) {
        record(srv, path === '/exfil' ? 'exfil' : 'echo', req, {
          bodyBytes: n,
          bodyHead: body.slice(0, 96).toString('utf8')
        });
        const h = corsHeaders(req, q);
        h['Content-Type'] = 'application/json';
        h['X-Cap15a-Server'] = srv;
        res.writeHead(200, h);
        res.end(
          JSON.stringify({
            srv: srv,
            saw: {
              origin: req.headers.origin === undefined ? null : req.headers.origin,
              referer: req.headers.referer === undefined ? null : req.headers.referer,
              cookie: req.headers.cookie === undefined ? null : req.headers.cookie,
              ua: req.headers['user-agent'] || null,
              secFetchSite: req.headers['sec-fetch-site'] || null,
              secFetchMode: req.headers['sec-fetch-mode'] || null,
              acceptLanguage: req.headers['accept-language'] || null,
              method: req.method,
              bodyBytes: n
            }
          })
        );
      });
      return;
    }

    if (path === '/setcookie') {
      record(srv, 'setcookie', req, {});
      const h = corsHeaders(req, q);
      h['Content-Type'] = 'application/json';
      // two shapes, because a cross-site cookie needs SameSite=None and a
      // custom-scheme page may or may not count as a secure context to the
      // cookie store
      h['Set-Cookie'] = [
        'c15a_none=1; Path=/; SameSite=None',
        'c15a_lax=1; Path=/'
      ];
      res.writeHead(200, h);
      res.end(JSON.stringify({ set: true }));
      return;
    }

    if (path === '/cookiecheck') {
      record(srv, 'cookiecheck', req, {
        cookie: req.headers.cookie === undefined ? null : req.headers.cookie
      });
      const h = corsHeaders(req, q);
      h['Content-Type'] = 'application/json';
      res.writeHead(200, h);
      res.end(
        JSON.stringify({
          cookie: req.headers.cookie === undefined ? null : req.headers.cookie
        })
      );
      return;
    }

    if (path === '/redirect') {
      record(srv, 'redirect', req, { to: q.get('to') });
      const h = corsHeaders(req, q);
      h['Location'] = q.get('to') || '/echo';
      res.writeHead(302, h);
      res.end();
      return;
    }

    if (path === '/sse') {
      record(srv, 'sse', req, {});
      const h = corsHeaders(req, q);
      h['Content-Type'] = 'text/event-stream';
      h['Cache-Control'] = 'no-store';
      res.writeHead(200, h);
      let i = 0;
      const timer = setInterval(function () {
        i += 1;
        res.write('data: tick-' + i + '\n\n');
        if (i >= 3) {
          clearInterval(timer);
          res.write('event: end\ndata: done\n\n');
          res.end();
        }
      }, 60);
      req.on('close', function () {
        clearInterval(timer);
      });
      return;
    }

    if (path === '/bytes') {
      const n = Math.max(0, Math.min(parseInt(q.get('n') || '1024', 10), 64 * 1024 * 1024));
      record(srv, 'bytes', req, { n: n });
      const h = corsHeaders(req, q);
      h['Content-Type'] = 'application/octet-stream';
      h['Content-Length'] = String(n);
      res.writeHead(200, h);
      res.end(Buffer.alloc(n, 0x78));
      return;
    }

    if (path === '/slow') {
      const ms = Math.max(0, Math.min(parseInt(q.get('ms') || '1000', 10), 60000));
      record(srv, 'slow', req, { ms: ms });
      setTimeout(function () {
        const h = corsHeaders(req, q);
        h['Content-Type'] = 'text/plain';
        res.writeHead(200, h);
        res.end('slept ' + ms);
      }, ms);
      return;
    }

    if (path === '/img.png') {
      record(srv, 'img', req, {});
      const h = corsHeaders(req, q);
      h['Content-Type'] = 'image/png';
      res.writeHead(200, h);
      res.end(PNG_1x1);
      return;
    }

    record(srv, 'other', req, {});
    const h = corsHeaders(req, q);
    h['Content-Type'] = 'text/plain';
    res.writeHead(404, h);
    res.end('no route');
  };
}

/* ---- the minimal WebSocket half: handshake, one echo frame, close ------- */
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function wsFrame(payload) {
  const b = Buffer.from(payload, 'utf8');
  const head = Buffer.alloc(2);
  head[0] = 0x81; // FIN + text
  head[1] = b.length; // spike bound: payloads stay < 126 bytes
  return Buffer.concat([head, b]);
}

function attachWs(server, srv) {
  server.on('upgrade', function (req, socket) {
    record(srv, 'ws-upgrade', req, {});
    const key = req.headers['sec-websocket-key'];
    if (!key) {
      socket.destroy();
      return;
    }
    const accept = crypto
      .createHash('sha1')
      .update(key + WS_GUID)
      .digest('base64');
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Accept: ' +
        accept +
        '\r\n\r\n'
    );
    socket.write(wsFrame('hello-from-' + srv));
    socket.on('data', function (buf) {
      // decode exactly one small masked client frame, echo its text back
      if (buf.length < 6) return;
      const len = buf[1] & 0x7f;
      if (len > 125) return;
      const mask = buf.slice(2, 6);
      const data = buf.slice(6, 6 + len);
      const out = Buffer.alloc(len);
      for (let i = 0; i < len; i += 1) out[i] = data[i] ^ mask[i % 4];
      record(srv, 'ws-message', req, { text: out.toString('utf8') });
      socket.write(wsFrame('echo:' + out.toString('utf8')));
    });
    socket.on('error', function () {});
  });
}

const serverA = http.createServer(handler('A'));
const serverB = http.createServer(handler('B'));
attachWs(serverA, 'A');
attachWs(serverB, 'B');

let up = 0;
function ready() {
  up += 1;
  if (up === 2) {
    process.stdout.write('PROBE_READY ' + PORT_A + ' ' + PORT_B + '\n');
  }
}
// A LISTEN FAILURE MUST SAY SO. Without an 'error' listener an EADDRINUSE or
// EACCES is an unhandled event: node dies with a stack the runner never reads,
// and the runner reports "never reported PROBE_READY" fifteen seconds later.
[[serverA, 'A', PORT_A], [serverB, 'B', PORT_B]].forEach(function (s) {
  s[0].on('error', function (e) {
    process.stderr.write('probe_server: listen ' + s[1] + ' on ' + s[2] +
      ' failed: ' + (e && e.code ? e.code : e) + '\n');
    process.exit(3);
  });
});
serverA.listen(PORT_A, '127.0.0.1', ready);
serverB.listen(PORT_B, '127.0.0.1', ready);

// THE LOG IS FLUSHED BEFORE THE PROCESS GOES, and that is the whole point of
// this block. `logStream.end()` is asynchronous; calling process.exit() on the
// next line can drop buffered records, and a dropped record is
// indistinguishable from the ABSENCE the graded baseline row asserts - "origin
// B is named by nothing, so a refusal is measured as an absence". Exiting from
// the stream's own callback is the difference between a witness and an
// anecdote.
function shutdown() {
  try { serverA.close(); } catch (e) { /* already closing */ }
  try { serverB.close(); } catch (e) { /* already closing */ }
  logStream.end(function () { process.exit(0); });
  // a last resort if the stream never drains, so a runner is never hung by it
  setTimeout(function () { process.exit(0); }, 2000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
// Windows delivers no signal a node handler can run when a parent stops it, so
// the runner closes this process's stdin instead and the server leaves on that.
process.stdin.on('end', shutdown);
process.stdin.on('close', shutdown);
process.stdin.resume();
