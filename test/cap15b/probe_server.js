#!/usr/bin/env node
//
// CAP-15B: the local witness.
//
// A dependency-free HTTP server whose JSONL request log is the INDEPENDENT
// witness for everything the client cannot see about itself. It is the
// reduced descendant of test/cap15a/probe_server.js that ledger 15A-12 said
// this shard would keep: the CSP-widening half is gone, the wire log is not.
//
// WHY A SERVER-SIDE LOG AT ALL. Three of the four defects CAP-15A found in
// its own transport were invisible from the client: mORMot re-sent a failed
// request (one call, TWO hits), a socket timeout was not a deadline, and a
// cookie rode a request nobody could read. A client that says "I sent one
// request" is a client reporting its own intention; the log is what the
// socket actually carried.
//
// It is LOCAL and it is part of the leg. No gate in this shard depends on
// the public internet: the one row that needs a real certificate chain
// (`tls_live_status`) is RECORDED and never gates, because a self-signed
// local certificate cannot be used - TLS validation is not disableable
// anywhere in this product, which is the point.
//
// Usage:
//   node probe_server.js --port=<n> --log=<file> [--stdin-shutdown] [--ttl=<s>]
//
// --stdin-shutdown is OPT-IN, and that is deliberate: a server that shut
// down on a closed stdin by default would exit instantly under any runner
// that hands it /dev/null, which is most of them, and the failure looks
// exactly like a server that never started. The gate passes it because the
// gate holds a real pipe open. --ttl is the backstop that keeps a forgotten
// server from outliving the run that owns it.
//
// Routes (all plain http, loopback only):
//   GET  /ok                 200 application/json
//   GET  /echo               200, the request's own headers as JSON
//   GET  /bytes?n=N          200, exactly N bytes with a Content-Length
//   GET  /chunked?n=N        200, N bytes chunked with NO Content-Length
//   GET  /ready              204, the readiness probe - deliberately NOT /ok,
//                            so a runner waiting for the port cannot be
//                            mistaken for the one call of the one-hit row
//   GET  /slow?ms=N          200, one byte every 50 ms for N ms, chunked
//   GET  /redirect           302 Location: /ok
//   GET  /setcookie          200 Set-Cookie: probe=1; Path=/
//   GET  /headers            200, the allowlist-exercising response headers
//   POST /sink               200, records the body length
//   any  else                404
'use strict';

const http = require('http');
const fs = require('fs');

function arg(name, fallback) {
  const hit = process.argv.find((a) => a.startsWith('--' + name + '='));
  return hit === undefined ? fallback : hit.slice(name.length + 3);
}

const port = parseInt(arg('port', '0'), 10);
const logPath = arg('log', '');
if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  process.stderr.write('probe_server: --port=<1..65535> is required\n');
  process.exit(2);
}
if (logPath === '') {
  process.stderr.write('probe_server: --log=<file> is required\n');
  process.exit(2);
}

const stdinShutdown = process.argv.indexOf('--stdin-shutdown') >= 0;
const ttlSeconds = parseInt(arg('ttl', '300'), 10);

const log = fs.createWriteStream(logPath, { flags: 'w' });

// EVERY request, with its FULL header set, before any routing decision: a
// route that refused still tells us what reached the socket
function record(req, extra) {
  const row = {
    t: Date.now(),
    method: req.method,
    url: req.url,
    headers: req.headers,
  };
  if (extra !== undefined) {
    Object.assign(row, extra);
  }
  log.write(JSON.stringify(row) + '\n');
}

function filler(n) {
  return Buffer.alloc(n, 0x61); // 'a'
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const path = u.pathname;
  const n = parseInt(u.searchParams.get('n') || '0', 10);
  const ms = parseInt(u.searchParams.get('ms') || '0', 10);

  if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
    let total = 0;
    req.on('data', (c) => {
      total += c.length;
    });
    req.on('end', () => {
      record(req, { bodyBytes: total });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, bodyBytes: total }));
    });
    return;
  }

  record(req);

  switch (path) {
    case '/ok':
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    case '/echo':
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ headers: req.headers }));
      return;
    case '/bytes': {
      const body = filler(n);
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': String(body.length),
      });
      res.end(body);
      return;
    }
    case '/chunked': {
      // NO Content-Length: the running-total half of the response bound is
      // the only thing that can stop this one
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      const slice = filler(64 * 1024);
      let sent = 0;
      const pump = () => {
        while (sent < n) {
          const take = Math.min(slice.length, n - sent);
          sent += take;
          if (!res.write(take === slice.length ? slice : slice.slice(0, take))) {
            res.once('drain', pump);
            return;
          }
        }
        res.end();
      };
      pump();
      return;
    }
    case '/ready':
      res.writeHead(204);
      res.end();
      return;
    case '/slow': {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      const started = Date.now();
      const tick = () => {
        if (Date.now() - started >= ms) {
          res.end();
          return;
        }
        res.write('.');
        setTimeout(tick, 50);
      };
      tick();
      return;
    }
    case '/redirect':
      res.writeHead(302, { Location: '/ok', 'Content-Type': 'text/plain' });
      res.end('moved');
      return;
    case '/setcookie':
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Set-Cookie': 'probe=1; Path=/',
      });
      res.end(JSON.stringify({ ok: true }));
      return;
    case '/headers':
      res.writeHead(200, {
        'Content-Type': 'application/json',
        ETag: '"v1"',
        'Last-Modified': 'Tue, 01 Jan 2030 00:00:00 GMT',
        'Retry-After': '12',
        Location: 'https://api.example.com/v2',
        'X-Request-Id': 'abc',
        'Set-Cookie': 'secret=value; Path=/',
        Server: 'probe',
      });
      res.end(JSON.stringify({ ok: true }));
      return;
    default:
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('no');
      return;
  }
});

server.on('clientError', (err, socket) => {
  try {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
  } catch (e) {
    /* the socket is already gone; there is nothing to say to it */
  }
});

// loopback ONLY. A probe server that listened on every interface would be a
// listening socket this repository spends six gates proving it does not have
server.listen(port, '127.0.0.1', () => {
  process.stdout.write('probe_server: listening on 127.0.0.1:' + port + '\n');
});

// STDIN CLOSE IS THE SHUTDOWN, and the log is flushed from the stream's own
// drain callback before the process exits: a record lost at shutdown is
// indistinguishable from the absence a graded row asserts (CAP-15A 15A-15).
function shutdown() {
  server.close(() => {
    log.end(() => {
      process.exit(0);
    });
  });
  // a bounded backstop: a connection somebody left open must not keep this
  // process alive past the run that owns it
  setTimeout(() => {
    log.end(() => {
      process.exit(0);
    });
  }, 2000).unref();
}

if (stdinShutdown) {
  process.stdin.on('end', shutdown);
  process.stdin.on('close', shutdown);
  process.stdin.resume();
}
if (Number.isInteger(ttlSeconds) && ttlSeconds > 0) {
  setTimeout(shutdown, ttlSeconds * 1000).unref();
}
