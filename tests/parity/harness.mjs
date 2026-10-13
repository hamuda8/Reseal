// Reseal-js's test/harness.js with one change: startServer() runs the Zig reseal-server when
// RESEAL_SERVER=zig, else `node server.js` in Reseal-js (the baseline). Everything else (the
// HTTP client, the WebSocket client, the recorder) is the original, so the tests assert the same.
//
// RESEAL_JS (default ../Reseal-js next to this repo) and RESEAL_SERVER_BIN (default
// zig-out/bin/reseal-server[.exe]) override paths.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import http from 'node:http';
import path from 'node:path';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(process.env.RESEAL_JS || path.join(here, '../../../Reseal-js'));
const zigBin = path.resolve(process.env.RESEAL_SERVER_BIN || path.join(here, '../../zig-out/bin', process.platform === 'win32' ? 'reseal-server.exe' : 'reseal-server'));
const useZig = process.env.RESEAL_SERVER === 'zig';
const { MongoClient } = createRequire(path.join(root, 'package.json'))('mongodb');

export const MASTER_KEY = process.env.MASTER_KEY || crypto.randomBytes(32).toString('base64');
process.env.MASTER_KEY = MASTER_KEY;
export const MONGO_URI = process.env.TEST_MONGO_URI || 'mongodb://127.0.0.1:27017';
export const sleep = (ms) => new Promise(r => setTimeout(r, ms));

export async function freePort() {
  const srv = http.createServer();
  await new Promise(r => srv.listen(0, r));
  const { port } = srv.address();
  await new Promise(r => srv.close(r));
  return port;
}

export async function startServer(extraEnv = {}, { zig = useZig } = {}) {
  const port = await freePort();
  const dbName = `${zig ? 'ResealTest_zig' : 'Reseal_test'}_${Date.now()}_${crypto.randomBytes(3).toString('hex')}`;
  const env = {
    ...process.env,
    PORT: String(port),
    PUBLIC_URL: `http://localhost:${port}`,
    DB_NAME: dbName,
    MONGO_URI,
    MASTER_KEY,
    AUTH_HOST: process.env.TEST_AUTH_HOST || 'http://localhost:4100',
    ALLOW_PRIVATE_FETCH: 'true',
    LOG_REQUESTS: 'false',
    RESEAL_PUBLIC_DIR: path.join(root, 'public'),
    ...extraEnv,
  };
  // The Zig server reads .env.production / .env from its working folder: give it an empty one,
  // so nothing but the variables above reaches it.
  const child = zig
    ? spawn(zigBin, [], { cwd: mkdtempSync(path.join(tmpdir(), 'reseal-zig-')), env, stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(process.execPath, ['server.js'], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', d => { output += d; });
  child.stderr.on('data', d => { output += d; if (process.env.TEST_VERBOSE) process.stderr.write(d); });
  const base = `http://localhost:${port}`;
  let ready = false;
  for (let i = 0; i < 300 && !ready; i++) {
    try {
      const res = await fetch(`${base}/api/health`);
      ready = res.ok;
    } catch {}
    if (child.exitCode !== null) throw new Error(`Server exited:\n${output}`);
    if (!ready) await sleep(100);
  }
  if (!ready) { child.kill(); throw new Error(`Server did not start in time:\n${output}`); }
  const mongo = new MongoClient(MONGO_URI);
  await mongo.connect();
  const db = mongo.db(dbName);
  return {
    base, port, db, dbName, child,
    output: () => output,
    async stop() {
      child.kill();
      await db.dropDatabase().catch(() => {});
      await mongo.close();
    },
  };
}

/** Small JSON client. `auth` is a bearer token. */
export function client(base, auth) {
  const call = async (method, url, body, { raw = false, headers = {} } = {}) => {
    const res = await fetch(base + url, {
      method,
      headers: {
        ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
        ...(body !== undefined && !raw ? { 'Content-Type': 'application/json' } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : raw ? body : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch {}
    if (!res.ok) {
      const err = new Error(`${method} ${url} → ${res.status}: ${json?.error?.message || text}`);
      err.status = res.status;
      err.code = json?.error?.code;
      throw err;
    }
    return json ?? text;
  };
  return {
    get: (u, o) => call('GET', u, undefined, o),
    post: (u, b, o) => call('POST', u, b ?? {}, o),
    put: (u, b, o) => call('PUT', u, b, o),
    patch: (u, b, o) => call('PATCH', u, b, o),
    del: (u, b, o) => call('DELETE', u, b, o),
  };
}

/** A WebSocket client that records events and can wait for one. */
export async function socket(base, token) {
  const ws = new WebSocket(`${base.replace('http', 'ws')}/ws?token=${encodeURIComponent(token)}`);
  const events = [];
  const waiters = [];
  let seq = 0;
  const acks = new Map();
  ws.addEventListener('message', (e) => {
    const msg = JSON.parse(e.data);
    if (msg.t === 'ack') {
      const a = acks.get(msg.d.id);
      if (a) { acks.delete(msg.d.id); msg.d.ok ? a.resolve(msg.d.result) : a.reject(Object.assign(new Error(msg.d.error), { code: msg.d.code })); }
      return;
    }
    events.push(msg);
    for (const w of [...waiters]) {
      if (w.match(msg)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(msg.d); }
    }
  });
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', () => reject(new Error('WebSocket failed to open')), { once: true });
  });
  const ready = await new Promise((resolve) => {
    const found = events.find(e => e.t === 'ready');
    if (found) return resolve(found.d);
    waiters.push({ match: (m) => m.t === 'ready', resolve });
  });
  return {
    ws, events, ready,
    send: (t, d) => ws.send(JSON.stringify({ t, d })),
    request: (t, d) => new Promise((resolve, reject) => {
      const id = ++seq;
      acks.set(id, { resolve, reject });
      ws.send(JSON.stringify({ t, d, id }));
    }),
    wait(t, pred = () => true, timeout = 5000) {
      const existing = events.find(e => e.t === t && pred(e.d) && !e.used);
      if (existing) { existing.used = true; return Promise.resolve(existing.d); }
      return new Promise((resolve, reject) => {
        const w = { match: (m) => m.t === t && pred(m.d) && !m.used && (m.used = true), resolve };
        waiters.push(w);
        setTimeout(() => {
          if (waiters.includes(w)) { waiters.splice(waiters.indexOf(w), 1); reject(new Error(`Timed out waiting for "${t}"`)); }
        }, timeout);
      });
    },
    close: () => ws.close(),
  };
}

/** A local HTTP server that records requests (for webhooks and a fake OpenRouter). */
export async function recorder(handler) {
  const requests = [];
  const srv = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks);
    const entry = { method: req.method, url: req.url, headers: req.headers, body: raw.toString(), raw };
    requests.push(entry);
    if (handler) return handler(req, res, entry);
    res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
  });
  await new Promise(r => srv.listen(0, r));
  return { url: `http://localhost:${srv.address().port}`, requests, close: () => new Promise(r => srv.close(r)) };
}
