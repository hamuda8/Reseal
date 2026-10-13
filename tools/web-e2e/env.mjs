// Browser tests of the Zig Reseal web client (headless Chrome over the DevTools protocol, Node 22,
// no packages). Build first: zig build web -Doptimize=ReleaseSmall, then e.g.
//   node tools/web-e2e/flow.mjs <outdir>     (also flow2.mjs, flow3.mjs [scenario...])
// Needs MongoDB on 127.0.0.1:27017 and Chrome.
//
// Test environment for the Zig Reseal client: a throwaway Reseal-js server on the local MongoDB
// database ResealDev_zig (dropped at the end), a fake Wufour, seeded users and chats (encrypted
// with Reseal-js's crypto.js), and a proxy that serves zig-out/web on the same origin.
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
const oid = () => crypto.randomBytes(12).toString('hex');

// Reseal-js next to this repository (its server, test harness and crypto.js).
const here = path.dirname(fileURLToPath(import.meta.url));
const RJS = path.resolve(here, '../../../Reseal-js').split(path.sep).join('/');
const WEB = path.resolve(here, '../../zig-out/web');
const { startServer, client } = await import(pathToFileURL(`${RJS}/test/harness.js`).href);
export const E = await import(pathToFileURL(`${RJS}/public/js/crypto.js`).href);

export const WUFOUR_PORT = 4101;
export const PROXY_PORT = 4300;

export const people = {
  tok_alice: { userId: oid(), username: 'alice', role: 'user', email: 'alice@example.com' },
  tok_bob: { userId: oid(), username: 'bob', role: 'user', email: 'bob@example.com' },
  tok_carol: { userId: oid(), username: 'carol', role: 'user', email: 'carol@example.com' },
  tok_dan: { userId: oid(), username: 'dan', role: 'user', email: 'dan@example.com' },
};

export async function startAll() {
  // A clean throwaway database each run.
  const { MongoClient } = await import(pathToFileURL(`${RJS}/node_modules/mongodb/lib/index.js`).href);
  const m = new MongoClient('mongodb://127.0.0.1:27017');
  await m.connect();
  await m.db('ResealDev_zig').dropDatabase();
  await m.close();
  const wufour = http.createServer(async (req, res) => {
    let body = '';
    for await (const c of req) body += c;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    const b = JSON.parse(body || '{}');
    if (req.url === '/api/auth/login') {
      const tok = Object.keys(people).find(k => people[k].email === b.email);
      return res.end(JSON.stringify(tok && b.password === 'secret' ? { success: true, token: tok } : { success: false, message: 'Invalid credentials' }));
    }
    if (req.url !== '/api/auth/verify') return res.end('{"success":false}');
    const user = people[b.token];
    res.end(JSON.stringify(user ? { success: true, user } : { success: false }));
  });
  await new Promise(r => wufour.listen(WUFOUR_PORT, r));
  const srv = await startServer({ DB_NAME: 'ResealDev_zig', TEST_AUTH_HOST: `http://localhost:${WUFOUR_PORT}`, AUTH_HOST: `http://localhost:${WUFOUR_PORT}` });
  const base = srv.base;
  const target = new URL(base);

  const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };
  const PROXIED = /^\/(api|m|ws|login|logout|auth|sdk|push)(\/|$|\?)/;
  const proxy = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (PROXIED.test(url.pathname)) {
      const p = http.request({ host: target.hostname, port: target.port, path: req.url, method: req.method, headers: { ...req.headers, host: target.host } }, (r) => {
        res.writeHead(r.statusCode, r.headers);
        r.pipe(res);
      });
      p.on('error', () => { res.writeHead(502); res.end(); });
      req.pipe(p);
      return;
    }
    let file = path.join(WEB, decodeURIComponent(url.pathname));
    if (!file.startsWith(WEB) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(WEB, 'index.html');
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });
  proxy.on('upgrade', (req, socket, head) => {
    const up = net.connect(target.port, target.hostname, () => {
      up.write(`${req.method} ${req.url} HTTP/1.1\r\n` + Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') + '\r\n\r\n');
      up.write(head);
      up.pipe(socket);
      socket.pipe(up);
    });
    up.on('error', () => socket.destroy());
    socket.on('error', () => up.destroy());
  });
  await new Promise(r => proxy.listen(PROXY_PORT, r));
  return { srv, base, wufour, proxy, client };
}

export async function giveKeys(u) {
  u.identity = await E.generateIdentity();
  const { box, escrowKey } = await E.escrowBackup(u.identity);
  await u.api.put('/api/keys', { enc: u.identity.encPublic, sig: u.identity.sigPublic, mode: 'standard', backup: { escrow: box }, escrowKey });
}

export async function rotate(u, chatId, epoch = 1) {
  const raw = E.newChatKeyBytes();
  const { members } = await u.api.get(`/api/chats/${chatId}/key-members`);
  const keys = [];
  for (const m of members.filter(m => m.enc)) keys.push(await E.wrapChatKey(raw, { chatId, epoch, userId: m.userId, recipientEnc: m.enc, signer: u.identity.sigPrivate }));
  await u.api.post(`/api/chats/${chatId}/keys`, { epoch, rotate: true, keys });
  return E.importChatKey(raw);
}

export async function say(u, chatId, key, text, epoch = 1) {
  const enc = await E.encryptMessage(key, { v: 1, t: text }, { chatId, epoch, senderId: u.id, signer: u.identity.sigPrivate });
  return (await u.api.post(`/api/chats/${chatId}/messages`, { enc, clientId: `seed-${Math.random()}` })).message;
}

/** Unwrap a chat's key for `u` with crypto.js (to read what the Zig client sent). */
export async function keyOf(u, chatId, epoch, byUser) {
  const { keys } = await u.api.get(`/api/chats/${chatId}/keys`);
  const w = keys.find(k => k.epoch === epoch);
  if (!w) return null;
  const raw = await E.unwrapChatKey(w, { chatId, epoch, userId: u.id, encPrivate: u.identity.encPrivate, wrapperSig: byUser.keys.sig });
  return E.importChatKey(raw);
}

export async function objectId(hex) {
  const { ObjectId } = await import(pathToFileURL(`${RJS}/node_modules/mongodb/lib/index.js`).href);
  return new ObjectId(hex);
}

/** The test database itself (the harness's srv.db names another one). */
export async function devDb() {
  const { MongoClient } = await import(pathToFileURL(`${RJS}/node_modules/mongodb/lib/index.js`).href);
  const m = new MongoClient('mongodb://127.0.0.1:27017');
  await m.connect();
  return { db: m.db('ResealDev_zig'), close: () => m.close(), drop: async () => { await m.db('ResealDev_zig').dropDatabase(); await m.close(); } };
}

/** An app's message storage (Reseal-js examples/message-store.mjs, in memory) and its sealed secret. */
export async function appStorage(secret, port) {
  const h = await import(pathToFileURL(`${RJS}/test/harness.js`).href);
  process.env.MASTER_KEY = h.MASTER_KEY;
  const { seal } = await import(pathToFileURL(`${RJS}/src/util/secrets.js`).href);
  const { storageHandler } = await import(pathToFileURL(`${RJS}/examples/message-store.mjs`).href);
  const server = http.createServer(storageHandler({ secret }));
  await new Promise(r => server.listen(port, r));
  return { url: `http://localhost:${port}/reseal`, sealed: seal(secret), close: () => server.close() };
}
