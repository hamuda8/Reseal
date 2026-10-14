// Drives the Zig Reseal web client in headless Chrome against a local Reseal-js server.
//   node tools/web-e2e/flow.mjs <outdir>   (see env.mjs)
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { startAll, giveKeys, rotate, say, keyOf, E, PROXY_PORT, devDb } from './env.mjs';

const out = process.argv[2] || './shots';
fs.mkdirSync(out, { recursive: true });
const { srv, base, wufour, proxy, client } = await startAll();
const APP = `http://localhost:${PROXY_PORT}`;
const results = [];
const check = (name, ok, extra = '') => { results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ` (${extra})` : ''}`); console.log(results.at(-1)); };

// ---- seed ----
const users = {};
for (const [tok, name] of [['tok_alice', 'Alice Carter'], ['tok_bob', 'Bob Haddad'], ['tok_carol', 'Carol Nasser']]) {
  const api = client(base, tok);
  const me = (await api.get('/api/me')).user;
  await api.patch('/api/me', { displayName: name, bio: 'Building things at Wufour' });
  users[tok] = { id: me.id, api, token: tok };
  await giveKeys(users[tok]);
}
const alice = users.tok_alice, bob = users.tok_bob, carol = users.tok_carol;
await alice.api.post('/api/contacts', { userId: bob.id });
await alice.api.post('/api/contacts', { userId: carol.id });
const dm = (await alice.api.post('/api/chats/private', { userId: bob.id })).chat;
const dmKey = await rotate(alice, dm.id);
await say(bob, dm.id, dmKey, 'Hey Alice! Did you see the new designs?');
await say(alice, dm.id, dmKey, 'Just opened them. The aurora canvas looks great 🤩');
await say(bob, dm.id, dmKey, 'Right? I think we should keep the floating panels and soften the shadows a bit.');
await bob.api.post(`/api/chats/${dm.id}/read`, { seq: 2 });
const group = (await alice.api.post('/api/chats', { type: 'group', title: 'Design team', members: [bob.id, carol.id], about: 'Everything about the Reseal look and feel' })).chat;
const gKey = await rotate(alice, group.id);
await say(carol, group.id, gKey, 'Morning all ☀️');
await say(bob, group.id, gKey, 'Morning! Standup in 10?');
console.log('seeded; server', base);

// ---- Chrome ----
const chrome = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe', ['--headless=new', '--remote-debugging-port=9343', `--user-data-dir=${path.resolve(out)}/profile`, '--window-size=1280,800', '--no-first-run', 'about:blank']);
let ws;
for (let i = 0; i < 150 && !ws; i++) { await sleep(200);
  try { const page = (await (await fetch('http://127.0.0.1:9343/json')).json()).find(t => t.type === 'page'); if (page) ws = new WebSocket(page.webSocketDebuggerUrl); } catch { await sleep(200); }
}
await new Promise(r => ws.addEventListener('open', r));
let seq = 0;
const pending = new Map();
const logs = [];
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') logs.push(m.params.args.map(a => a.value ?? a.description).join(' '));
  if (m.method === 'Network.responseReceived' && m.params.response.url.includes('/api')) logs.push('NET ' + m.params.response.status + ' ' + m.params.response.url.split('/api')[1]);
  if (m.method === 'Log.entryAdded') logs.push('LOG ' + m.params.entry.text);
  if (m.method === 'Runtime.exceptionThrown') logs.push('EXCEPTION ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
});
const send = (method, params = {}) => new Promise(r => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.result?.value;
const shot = async (name) => { const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(`${out}/${name}.png`, Buffer.from(r.result.data, 'base64')); console.log('  shot', name); };
const click = async (x, y) => {
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
};
const texts = () => evaluate(`[...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent).map(d => d.textContent)`);
const hasText = async (t) => (await texts())?.some(x => x.includes(t));
const waitText = async (t, ms = 8000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await hasText(t)) return true; await sleep(250); } return false; };
const clickText = async (label) => {
  const p = await evaluate(`(() => { const el = [...document.querySelectorAll('div')].find(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent === ${JSON.stringify(label)}); if (!el) return null; const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  if (!p) throw new Error('no text ' + label);
  await click(p[0], p[1]);
  await sleep(500);
};
const typeIn = async (placeholder, text) => {
  const p = await evaluate(`(() => { const el = [...document.querySelectorAll('input')].find(i => i.placeholder === ${JSON.stringify(placeholder)}); if (!el) return null; const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  if (!p) throw new Error('no input ' + placeholder);
  await click(p[0], p[1]);
  await send('Input.insertText', { text });
  await sleep(200);
};
const key = async (k) => {
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k, windowsVirtualKeyCode: k === 'Enter' ? 13 : 0 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k, windowsVirtualKeyCode: k === 'Enter' ? 13 : 0 });
};

await send('Runtime.enable');
await send('Page.enable');
await send('Network.enable');
await send('Log.enable');
await send('Network.setCookie', { name: 'wufour_token', value: 'tok_alice', domain: 'localhost', path: '/' });
const go = async (url, wait = 3500) => { await send('Page.navigate', { url }); await sleep(wait); };

try {
  // 1. Alice, desktop: the chat list with the seeded chats, decrypted previews.
  await go(APP);
  check('chat list shows the DM', await waitText('Bob Haddad'));
  check('group preview decrypted (crypto.js message)', await waitText('Morning! Standup in 10?'));
  await shot('01-desktop-list');

  // 2. Open the DM: messages from crypto.js decrypt and verify.
  await clickText('Bob Haddad');
  check('DM message decrypted', await waitText('soften the shadows'));
  await shot('02-desktop-dm');

  // 3. Send from the Zig client; Bob (crypto.js) reads it.
  await typeIn('Message', 'Hello from the Zig client 👋');
  await key('Enter');
  await sleep(2000);
  const { messages } = await bob.api.get(`/api/chats/${dm.id}/messages?limit=10`);
  const last = messages.at(-1);
  let read = null;
  try {
    const k = await keyOf(bob, dm.id, last.enc.e, (await bob.api.get(`/api/users/${alice.id}`)).user);
    read = (await E.decryptMessage(k, last.enc, { chatId: dm.id, senderId: alice.id, senderSig: alice.identity.sigPublic })).payload;
  } catch (e) { read = String(e); }
  check('crypto.js decrypts the Zig client\'s message', read?.t === 'Hello from the Zig client 👋', JSON.stringify(read));
  await shot('03-desktop-sent');

  // 4. Bob replies (crypto.js): it arrives over the socket.
  await say(bob, dm.id, dmKey, 'Got it, the Zig one reads me too 🎉');
  check('realtime message arrives and decrypts', await waitText('the Zig one reads me too'));
  await shot('04-desktop-realtime');

  // 5. Group, settings.
  await clickText('Design team');
  check('group messages decrypted', await waitText('Morning all'));
  await shot('05-desktop-group');
} catch (e) {
  check('flow', false, String(e));
  await shot('error');
}
console.log(JSON.stringify({ logs: logs.slice(-30) }, null, 1));
fs.writeFileSync(`${out}/results.txt`, results.join('\n') + '\n');
ws.close();
chrome.kill();
await srv.stop();
await (await devDb()).drop();
wufour.close();
proxy.close();
process.exit(0);
