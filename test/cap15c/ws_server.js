#!/usr/bin/env node
//
// CAP-15C: the local RFC 6455 witness.
//
// A dependency-free WebSocket server - node's own `http`, `https`, `crypto`
// and nothing from a package registry - whose JSONL log is the INDEPENDENT
// witness for everything a client cannot see about itself: which headers the
// handshake carried, whether a 3xx was followed, whether a pong came back,
// which close code reached the wire, and when the kernel refused to take
// more bytes because the client had stopped reading.
//
// It is deliberately NOT a mORMot peer. mORMot's client also speaks its own
// binary REST-over-WebSockets protocol, and a spike measured against a
// mORMot server could pass for reasons a standard server does not share.
// Nothing here knows mORMot exists.
//
// It is the CAP-15B `probe_server.js` shape: loopback only, --stdin-shutdown
// opt-in, --ttl backstop, and no public dependency for anything that gates.
//
// Usage:
//   node ws_server.js --port=<n> --log=<file> [--tls-cert=<pem> --tls-key=<pem>]
//                     [--stdin-shutdown] [--ttl=<s>]
//
// Upgrade routes (the path selects the behaviour; the query carries numbers):
//   /echo                  echo every message back, same opcode, one frame
//   /fragment?size=S&parts=K[&ping=1]
//                          send a text message and a binary message of S bytes
//                          each, split into K frames; ping=1 injects a PING
//                          between two fragments (RFC 6455 section 5.4 permits
//                          it); then a text "sha:<text sha256>:<binary sha256>"
//   /ping                  send PING "probe-1"; on the PONG, send "pong:<payload>:<ms>"
//   /close?code=C&reason=R send "hello", then CLOSE(C, R)
//   /bigframe?size=S       send ONE binary frame of S bytes
//   /contflood?frames=N&size=S
//                          one binary message: N frames of S bytes, FIN on the last
//   /flood?count=N&size=S  N binary messages of S bytes, [u32 seq][fill=seq&255],
//                          honouring the kernel: a refused write waits for drain,
//                          and every block and drain is logged with its timing
//   /delayed?ms=N          after N ms send {"t":<server ms>}
//   /idle                  accept and send nothing
//   /noack                 accept, and never answer a CLOSE
//   /drop                  accept, then destroy the TCP connection after 200 ms
//   /redirect              answer 302 Location: /echo?from=redirect
//   /notws                 answer 200 with a body
//   /badproto              101 selecting a protocol the client did not offer
//   /noproto               101 selecting no protocol even when some were offered
//   /slow?ms=N             hold the 101 for N ms
//   /setcookie             101 carrying Set-Cookie: probe=1
// Plain HTTP:
//   GET /ready             204
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');

function arg(name, fallback) {
  const hit = process.argv.find((a) => a.startsWith('--' + name + '='));
  return hit === undefined ? fallback : hit.slice(name.length + 3);
}

const port = parseInt(arg('port', '0'), 10);
const logPath = arg('log', '');
if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  process.stderr.write('ws_server: --port=<1..65535> is required\n');
  process.exit(2);
}
if (logPath === '') {
  process.stderr.write('ws_server: --log=<file> is required\n');
  process.exit(2);
}
const tlsCert = arg('tls-cert', '');
const tlsKey = arg('tls-key', '');
const stdinShutdown = process.argv.indexOf('--stdin-shutdown') >= 0;
const ttlSeconds = parseInt(arg('ttl', '600'), 10);

const log = fs.createWriteStream(logPath, { flags: 'w' });
function record(row) {
  row.t = Date.now();
  log.write(JSON.stringify(row) + '\n');
}

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OP_CONT = 0x0, OP_TEXT = 0x1, OP_BIN = 0x2, OP_CLOSE = 0x8,
  OP_PING = 0x9, OP_PONG = 0xA;
// what this witness will buffer from a CLIENT: the client under test sends at
// most 1 MiB per frame, so anything past this is a client defect worth a row
const SERVER_MAX_MESSAGE = 64 * 1024 * 1024;

function frameHeader(opcode, len, fin) {
  let h;
  if (len < 126) {
    h = Buffer.alloc(2);
    h[1] = len;
  } else if (len < 65536) {
    h = Buffer.alloc(4);
    h[1] = 126;
    h.writeUInt16BE(len, 2);
  } else {
    h = Buffer.alloc(10);
    h[1] = 127;
    h.writeBigUInt64BE(BigInt(len), 2);
  }
  h[0] = (fin ? 0x80 : 0) | opcode;
  return h;
}

// one connection: a parser for masked client frames, message reassembly,
// the control-frame rules, and a writer whose return value is the kernel's
class Conn {
  constructor(id, route, sock, head) {
    this.id = id;
    this.route = route;
    this.sock = sock;
    this.pending = Buffer.alloc(0);
    this.msgOp = -1;
    this.msgParts = [];
    this.closeSent = false;
    this.closed = false;
    this.opened = Date.now();
    this.onMessage = null;
    this.onPong = null;
    this.onClientClose = null;
    sock.setNoDelay(true);
    sock.on('data', (d) => this.feed(d));
    sock.on('error', (e) => record({ id, event: 'socket_error', code: e.code || String(e) }));
    sock.on('close', () => {
      this.closed = true;
      record({ id, event: 'tcp_closed', afterMs: Date.now() - this.opened });
    });
    // node's http.Server creates its sockets with allowHalfOpen, so a client
    // FIN does NOT close an upgraded socket by itself - without this, a
    // client that really did close its TCP connection would read in this log
    // as a connection still open. MEASURED on the first run: both /noack rows
    // showed no tcp_closed at all
    sock.on('end', () => {
      record({ id, event: 'tcp_peer_end', afterMs: Date.now() - this.opened });
      sock.end();
    });
    if (head && head.length) this.feed(head);
  }

  write(opcode, payload, fin = true) {
    if (this.closed) return false;
    this.sock.write(frameHeader(opcode, payload.length, fin));
    return this.sock.write(payload);
  }

  close(code, reason) {
    if (this.closeSent || this.closed) return;
    const r = Buffer.from(reason || '', 'utf8');
    const p = Buffer.alloc(2 + r.length);
    p.writeUInt16BE(code, 0);
    r.copy(p, 2);
    this.closeSent = true;
    this.write(OP_CLOSE, p);
  }

  // the client under test sends small frames except for the 1 MiB rows, so a
  // single concatenated pending buffer is simpler than a chunk list and fast
  // enough for every route here
  feed(d) {
    this.pending = this.pending.length === 0 ? d : Buffer.concat([this.pending, d]);
    for (;;) {
      const p = this.pending;
      if (p.length < 2) return;
      const fin = (p[0] & 0x80) !== 0;
      const opcode = p[0] & 0x0f;
      const masked = (p[1] & 0x80) !== 0;
      let len = p[1] & 0x7f;
      let hdr = 2;
      if (len === 126) hdr = 4;
      else if (len === 127) hdr = 10;
      if (masked) hdr += 4;
      if (p.length < hdr) return;
      if (len === 126) len = p.readUInt16BE(2);
      else if (len === 127) len = Number(p.readBigUInt64BE(2));
      if (len > SERVER_MAX_MESSAGE) {
        record({ id: this.id, event: 'client_frame_too_large', len });
        this.sock.destroy();
        return;
      }
      if (p.length < hdr + len) return;
      const payload = Buffer.from(p.subarray(hdr, hdr + len));
      if (masked) {
        const m = p.subarray(hdr - 4, hdr);
        for (let i = 0; i < payload.length; i++) payload[i] ^= m[i & 3];
      } else {
        // RFC 6455 section 5.1: a client MUST mask every frame it sends
        record({ id: this.id, event: 'client_frame_unmasked', opcode });
      }
      this.pending = p.subarray(hdr + len);
      this.frame(fin, opcode, payload);
      if (this.closed) return;
    }
  }

  frame(fin, opcode, payload) {
    if (opcode >= 0x8) {
      if (opcode === OP_PING) {
        record({ id: this.id, event: 'client_ping', len: payload.length });
        this.write(OP_PONG, payload);
      } else if (opcode === OP_PONG) {
        record({ id: this.id, event: 'client_pong', payload: payload.toString('utf8') });
        if (this.onPong) this.onPong(payload);
      } else if (opcode === OP_CLOSE) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : null;
        const reason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
        const wasEcho = this.closeSent;
        record({ id: this.id, event: wasEcho ? 'close_echo' : 'client_close',
          code, reason, afterMs: Date.now() - this.opened });
        if (this.onClientClose && !wasEcho) {
          if (this.onClientClose(code, reason) === false) return; // /noack
        }
        if (!this.closeSent) {
          this.closeSent = true;
          this.write(OP_CLOSE, payload.length >= 2 ? payload.subarray(0, 2) : Buffer.alloc(0));
        }
        this.sock.end();
      } else {
        record({ id: this.id, event: 'client_bad_opcode', opcode });
      }
      return;
    }
    if (opcode === OP_TEXT || opcode === OP_BIN) {
      this.msgOp = opcode;
      this.msgParts = [payload];
    } else if (opcode === OP_CONT && this.msgOp >= 0) {
      this.msgParts.push(payload);
    } else {
      record({ id: this.id, event: 'client_bad_continuation', opcode });
      return;
    }
    if (!fin) return;
    const msg = this.msgParts.length === 1 ? this.msgParts[0] : Buffer.concat(this.msgParts);
    const op = this.msgOp;
    this.msgOp = -1;
    this.msgParts = [];
    record({ id: this.id, event: 'client_message', opcode: op, len: msg.length,
      sha256: crypto.createHash('sha256').update(msg).digest('hex'),
      text: op === OP_TEXT && msg.length <= 256 ? msg.toString('utf8') : undefined });
    if (this.onMessage) this.onMessage(op, msg);
  }
}

function pattern(size, seed) {
  const b = Buffer.allocUnsafe(size);
  for (let i = 0; i < size; i++) b[i] = (i * 31 + seed) & 0xff;
  return b;
}

function waitDrain(conn) {
  return new Promise((resolve) => {
    if (conn.closed) return resolve(false);
    const done = (ok) => {
      conn.sock.off('drain', onDrain);
      conn.sock.off('close', onClose);
      resolve(ok);
    };
    const onDrain = () => done(true);
    const onClose = () => done(false);
    conn.sock.on('drain', onDrain);
    conn.sock.on('close', onClose);
  });
}

async function sendFragmented(conn, opcode, data, parts, pingBetween) {
  const step = Math.ceil(data.length / parts);
  for (let i = 0, off = 0; off < data.length; i++, off += step) {
    const chunk = data.subarray(off, Math.min(off + step, data.length));
    const last = off + step >= data.length;
    const ok = conn.write(i === 0 ? opcode : OP_CONT, chunk, last);
    if (pingBetween && i === 0) conn.write(OP_PING, Buffer.from('mid-fragment'));
    if (!ok && !(await waitDrain(conn))) return false;
  }
  return true;
}

const routes = {
  echo(conn) {
    conn.onMessage = (op, msg) => conn.write(op, msg);
  },

  async fragment(conn, q) {
    const size = parseInt(q.get('size') || '100000', 10);
    const parts = parseInt(q.get('parts') || '7', 10);
    const ping = q.get('ping') === '1';
    const text = Buffer.allocUnsafe(size);
    for (let i = 0; i < size; i++) text[i] = 0x61 + (i % 26);
    const bin = pattern(size, 7);
    await sendFragmented(conn, OP_TEXT, text, parts, ping);
    await sendFragmented(conn, OP_BIN, bin, parts, false);
    const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
    record({ id: conn.id, event: 'fragment_sent', size, parts, ping,
      textSha256: sha(text), binSha256: sha(bin) });
    conn.write(OP_TEXT, Buffer.from('sha:' + sha(text) + ':' + sha(bin)));
    conn.onMessage = (op, msg) => conn.write(op, msg);
  },

  ping(conn) {
    const sentAt = Date.now();
    conn.onPong = (p) => {
      conn.write(OP_TEXT, Buffer.from('pong:' + p.toString('utf8') + ':' + (Date.now() - sentAt)));
    };
    conn.write(OP_PING, Buffer.from('probe-1'));
    conn.onMessage = (op, msg) => conn.write(op, msg);
  },

  close(conn, q) {
    const code = parseInt(q.get('code') || '4001', 10);
    const reason = q.get('reason') || 'bye';
    conn.write(OP_TEXT, Buffer.from('hello'));
    setTimeout(() => conn.close(code, reason), 50);
  },

  bigframe(conn, q) {
    const size = parseInt(q.get('size') || '1048576', 10);
    const b = pattern(size, 3);
    record({ id: conn.id, event: 'bigframe_sent', size,
      sha256: crypto.createHash('sha256').update(b).digest('hex') });
    conn.write(OP_BIN, b);
    conn.onMessage = (op, msg) => conn.write(op, msg);
  },

  async contflood(conn, q) {
    const frames = parseInt(q.get('frames') || '2048', 10);
    const size = parseInt(q.get('size') || '16384', 10);
    const chunk = pattern(size, 5);
    let blocked = 0, sent = 0;
    for (let i = 0; i < frames && !conn.closed; i++) {
      const ok = conn.write(i === 0 ? OP_BIN : OP_CONT, chunk, i === frames - 1);
      sent++;
      if (!ok) {
        blocked++;
        if (!(await waitDrain(conn))) break;
      }
    }
    record({ id: conn.id, event: 'contflood_sent', frames, size, sent,
      total: sent * size, blocked, closed: conn.closed });
  },

  async flood(conn, q) {
    const count = parseInt(q.get('count') || '1000', 10);
    const size = parseInt(q.get('size') || '65536', 10);
    const start = Date.now();
    let blocks = 0, blockedMs = 0, longestBlockMs = 0, firstBlockSeq = -1, sent = 0;
    conn.onMessage = (op, msg) => {
      record({ id: conn.id, event: 'flood_client_message',
        text: op === OP_TEXT ? msg.toString('utf8').slice(0, 64) : undefined,
        floodSent: sent });
    };
    for (let seq = 0; seq < count; seq++) {
      if (conn.closed) break;
      const b = Buffer.allocUnsafe(size);
      b.fill(seq & 0xff, 4);
      b.writeUInt32BE(seq, 0);
      const ok = conn.write(OP_BIN, b);
      sent = seq + 1;
      if (!ok) {
        blocks++;
        const t0 = Date.now();
        if (firstBlockSeq < 0) {
          firstBlockSeq = seq;
          record({ id: conn.id, event: 'flood_first_block', seq,
            bytesWritten: conn.sock.bytesWritten, writableLength: conn.sock.writableLength,
            afterMs: t0 - start });
        }
        if (!(await waitDrain(conn))) break;
        const waited = Date.now() - t0;
        blockedMs += waited;
        if (waited > longestBlockMs) longestBlockMs = waited;
        if (waited >= 250) {
          record({ id: conn.id, event: 'flood_long_block', seq, waitedMs: waited,
            bytesWritten: conn.sock.bytesWritten });
        }
      }
    }
    record({ id: conn.id, event: 'flood_done', count, size, sent, blocks, blockedMs,
      longestBlockMs, firstBlockSeq, closed: conn.closed, ms: Date.now() - start });
    if (!conn.closed) conn.write(OP_TEXT, Buffer.from('flood-done:' + sent));
  },

  delayed(conn, q) {
    const ms = parseInt(q.get('ms') || '2000', 10);
    setTimeout(() => {
      const t = Date.now();
      record({ id: conn.id, event: 'delayed_sent', serverT: t });
      conn.write(OP_TEXT, Buffer.from(JSON.stringify({ t })));
    }, ms);
  },

  idle() {},

  noack(conn) {
    conn.onClientClose = () => false;
  },

  drop(conn) {
    setTimeout(() => conn.sock.destroy(), 200);
  },

  // stop READING from the client: its sends fill the kernel buffers and a
  // client write must then block, which is the outbound half of backpressure
  noread(conn) {
    conn.sock.pause();
    record({ id: conn.id, event: 'noread_paused' });
  },
};

let nextId = 1;

function handleUpgrade(req, sock, head) {
  const id = nextId++;
  const u = new URL(req.url, 'http://witness');
  const route = u.pathname.replace(/^\//, '');
  const names = [];
  for (let i = 0; i < req.rawHeaders.length; i += 2) names.push(req.rawHeaders[i]);
  record({ id, kind: 'upgrade', method: req.method, url: req.url, route,
    httpVersion: req.httpVersion, headerNames: names, headers: req.headers });

  const refuse = (text) => {
    sock.end(text);
    record({ id, event: 'handshake_refused', status: text.split('\r\n')[0] });
  };

  if (route === 'redirect') {
    return refuse('HTTP/1.1 302 Found\r\nLocation: /echo?from=redirect\r\n' +
      'Content-Length: 0\r\nConnection: close\r\n\r\n');
  }
  if (route === 'notws') {
    return refuse('HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok');
  }
  const key = req.headers['sec-websocket-key'];
  if (req.method !== 'GET' || !key || req.headers['sec-websocket-version'] !== '13' ||
      String(req.headers.upgrade || '').toLowerCase() !== 'websocket') {
    return refuse('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
  }
  const handshakeOnly = ['badproto', 'noproto', 'slow', 'setcookie'];
  if (!Object.prototype.hasOwnProperty.call(routes, route) &&
      handshakeOnly.indexOf(route) < 0) {
    return refuse('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
  }

  const accept = crypto.createHash('sha1').update(key + GUID).digest('base64');
  const offered = String(req.headers['sec-websocket-protocol'] || '')
    .split(',').map((s) => s.trim()).filter((s) => s !== '');
  const lines = ['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket',
    'Connection: Upgrade', 'Sec-WebSocket-Accept: ' + accept];
  let selected = '';
  if (route === 'badproto') selected = 'not-offered';
  else if (route !== 'noproto' && offered.length > 0) selected = offered[offered.length - 1];
  if (selected !== '') lines.push('Sec-WebSocket-Protocol: ' + selected);
  if (route === 'setcookie') lines.push('Set-Cookie: probe=1; Path=/');

  const go = () => {
    if (sock.destroyed) return;
    sock.write(lines.join('\r\n') + '\r\n\r\n');
    record({ id, event: 'upgraded', route, selected, offered });
    const conn = new Conn(id, route, sock, head);
    const handler = routes[route] || routes.echo;
    Promise.resolve(handler(conn, u.searchParams)).catch((e) =>
      record({ id, event: 'route_error', error: String(e) }));
  };
  if (route === 'slow') setTimeout(go, parseInt(u.searchParams.get('ms') || '5000', 10));
  else go();
}

function handleRequest(req, res) {
  record({ kind: 'http', method: req.method, url: req.url, headers: req.headers });
  if (req.method === 'GET' && req.url === '/ready') {
    res.writeHead(204);
    return res.end();
  }
  res.writeHead(404, { 'Content-Length': '0' });
  res.end();
}

const server = tlsCert !== ''
  ? https.createServer({ cert: fs.readFileSync(tlsCert), key: fs.readFileSync(tlsKey) }, handleRequest)
  : http.createServer(handleRequest);
server.on('upgrade', handleUpgrade);
server.on('tlsClientError', (e) => record({ kind: 'tls_client_error', code: e.code || String(e) }));
server.listen(port, '127.0.0.1', () => {
  record({ kind: 'listening', port, tls: tlsCert !== '' });
  process.stdout.write('ws_server listening on 127.0.0.1:' + port + (tlsCert ? ' (tls)' : '') + '\n');
});

function shutdown(why) {
  record({ kind: 'shutdown', why });
  log.end(() => process.exit(0));
}
if (stdinShutdown) {
  process.stdin.on('end', () => shutdown('stdin'));
  process.stdin.resume();
}
setTimeout(() => shutdown('ttl'), ttlSeconds * 1000).unref();
process.on('SIGTERM', () => shutdown('sigterm'));
