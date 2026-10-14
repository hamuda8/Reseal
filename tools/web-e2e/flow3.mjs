// Interactions between two Zig web clients (Alice on localhost, Bob on 127.0.0.1): typing, read
// receipts, reactions, replies, edits, deletes, a new group, a picture (encrypted upload and
// download), advanced protection.
//   node flow3.mjs <outdir> [scenario...]
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { setTimeout as sleep } from 'node:timers/promises';
import { startAll, giveKeys, rotate, say, keyOf, E, PROXY_PORT, devDb } from './env.mjs';
import { launch, tab } from './cdp.mjs';

const out = process.argv[2] || './s4';
const only = new Set(process.argv.slice(3));
const want = (n) => only.size === 0 || only.has(n);
fs.mkdirSync(out, { recursive: true });
const { srv, base, wufour, proxy, client } = await startAll();
const APP = `http://localhost:${PROXY_PORT}`;
const APP2 = `http://127.0.0.1:${PROXY_PORT}`;
const results = [];
const check = (name, ok, extra = '') => { results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ` (${extra})` : ''}`); console.log(results.at(-1)); };

const users = {};
for (const [tok, name] of [['tok_alice', 'Alice Carter'], ['tok_bob', 'Bob Haddad'], ['tok_carol', 'Carol Nasser']]) {
  const api = client(base, tok);
  const me = (await api.get('/api/me')).user;
  await api.patch('/api/me', { displayName: name });
  users[tok] = { id: me.id, api, token: tok };
  await giveKeys(users[tok]);
}
const alice = users.tok_alice, bob = users.tok_bob, carol = users.tok_carol;
await alice.api.post('/api/contacts', { userId: bob.id });
await alice.api.post('/api/contacts', { userId: carol.id });
const dm = (await alice.api.post('/api/chats/private', { userId: bob.id })).chat;
const dmKey = await rotate(alice, dm.id);
await say(bob, dm.id, dmKey, 'Ping from Bob');

const browser = await launch(out, 9352);
const setCookie = (t, tok, domain) => t.send('Network.setCookie', { name: 'wufour_token', value: tok, domain, path: '/' });
const a = await tab(browser, out, { name: 'alice' });
const b = await tab(browser, out, { name: 'bob' });
await setCookie(a, 'tok_alice', 'localhost');
await setCookie(b, 'tok_bob', '127.0.0.1');
await a.go(APP);
await b.go(APP2);
await a.waitText('Bob Haddad');
await b.waitText('Alice Carter');

// A tap on a message's bubble (the text's box).
const tapMessage = async (t, text) => {
  // The bubble in the message list (the chat list may show the same words first).
  const p = await t.evaluate(`(() => { const els = [...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent.includes(${JSON.stringify(text)}) && d.getBoundingClientRect().x > 470); const el = els[0]; if (!el) return null; const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  if (!p) throw new Error('no bubble ' + text);
  await t.click(p[0], p[1]);
  // The menu opens once a double tap (a heart) is ruled out.
  await sleep(900);
  if (!(await t.waitText('Details', 2000))) {
    console.log('DEBUG tap missed', JSON.stringify(p), JSON.stringify((await t.texts())?.slice(-40)));
    throw new Error('menu did not open for ' + text);
  }
};

try {
  if (want('chat')) {
    // The tab title counts unread chats (chatlist.js).
    { let title = ''; for (let i = 0; i < 20 && !title.startsWith('('); i++) { title = await a.evaluate('document.title'); if (!title.startsWith('(')) await sleep(250); } check('tab title shows the unread count', title.startsWith('('), title); }
    await a.clickText('Bob Haddad');
    await b.clickText('Alice Carter');
    await a.waitText('Ping from Bob');
    // Icon buttons carry labels (tooltips, screen readers).
    check('icon buttons are labelled', await a.evaluate(`!![...document.querySelectorAll('[aria-label],[title]')].find(e => (e.getAttribute('aria-label') || e.title) === 'Search')`));
    // Typing
    await a.typeIn('Message', 'Hel');
    check('typing indicator shown to Bob', await b.waitText('typing', 6000));
    await b.shot('100-typing');
    await a.send('Input.insertText', { text: 'lo Bob!' });
    await a.key('Enter');
    check('message arrives at Bob (Zig to Zig)', await b.waitText('Hello Bob!'));
    // Read receipts: Bob has it open, so Alice sees it read (two checks: the icon is a path; check the seq instead).
    await sleep(1500);
    const chat = (await alice.api.get(`/api/chats/${dm.id}`)).chat;
    check('read receipt reached the server', chat.readSeq >= 2, `readSeq=${chat.readSeq}`);
    // React from Bob's message menu.
    await tapMessage(b, 'Hello Bob!');
    await b.shot('101-message-menu');
    await b.clickText('🔥');
    check('reaction shows for Alice', await a.waitText('🔥', 6000));
    // Reply from Bob
    await tapMessage(b, 'Hello Bob!');
    await b.clickText('Reply');
    await b.typeIn('Message', 'This is a reply');
    await b.key('Enter');
    check('reply arrives', await a.waitText('This is a reply'));
    await a.shot('102-reply-and-reaction');
    // Edit by Alice
    await tapMessage(a, 'Hello Bob!');
    await a.shot('102b-edit-menu');
    await a.clickText('Edit');
    await a.send('Input.insertText', { text: ' (edited)' });
    await a.key('Enter');
    check('edit arrives at Bob', await b.waitText('(edited)', 8000));
    // Delete by Bob for everyone
    await tapMessage(b, 'This is a reply');
    await b.clickText('Delete');
    // As in Reseal-js: 'Also delete for {name}', ticked to begin with.
    check('the delete dialog offers deleting for the other person too', await b.waitText('Also delete for Alice Carter', 4000));
    await b.clickText('Delete');
    let gone = false;
    for (let i = 0; i < 30 && !gone; i++) { gone = !(await a.hasText('This is a reply')); if (!gone) await sleep(250); }
    check('delete for everyone removes it at Alice', gone);
    await a.shot('103-after-edit-delete');
    await b.shot('104-bob-view');
  }

  if (want('forward')) {
    const cdm = (await alice.api.post('/api/chats/private', { userId: carol.id })).chat;
    const ck = await rotate(alice, cdm.id);
    await say(carol, cdm.id, ck, 'Hi Alice, Carol here');
    await a.go(APP);
    await a.waitText('Bob Haddad');
    await a.clickText('Bob Haddad');
    await a.waitText('Ping from Bob');
    await tapMessage(a, 'Ping from Bob');
    await a.clickText('Forward');
    await a.clickText('Carol Nasser');
    // The chat picker takes several chats, then Send.
    await a.clickText('Send');
    await sleep(2500);
    let got = null;
    try {
      const { messages } = await carol.api.get(`/api/chats/${cdm.id}/messages?limit=5`);
      const m = messages.at(-1);
      const k = await keyOf(carol, cdm.id, m.enc.e, (await carol.api.get(`/api/users/${alice.id}`)).user);
      got = (await E.decryptMessage(k, m.enc, { chatId: cdm.id, senderId: alice.id, senderSig: alice.identity.sigPublic })).payload;
    } catch (e) { got = String(e); }
    check('forwarded into another encrypted chat, readable with its sender label', got?.t === 'Ping from Bob' && got?.fwd?.fromUserId === bob.id, JSON.stringify(got));
    await a.clickText('Carol Nasser');
    await a.waitText('Forwarded from');
    await a.shot('105-forwarded');
  }

  if (want('file')) {
    // A small PNG, picked through the shell's file chooser.
    const png = makePng(64, 48);
    const file = path.resolve(out, 'pic.png');
    fs.writeFileSync(file, png);
    await a.send('Page.setInterceptFileChooserDialog', { enabled: true });
    await a.clickText('Bob Haddad');
    await sleep(800);
    const chooser = new Promise((resolve) => {
      const t0 = Date.now();
      const poll = async () => {
        const ev = a.events?.find?.((e) => e.method === 'Page.fileChooserOpened');
        if (ev || Date.now() - t0 > 5000) resolve(ev); else setTimeout(poll, 100);
      };
      poll();
    });
    void chooser;
    // The attach button is left of the composer.
    const p = await a.evaluate(`(() => { const i = [...document.querySelectorAll('input')].find(x => x.placeholder === 'Message'); const r = i.getBoundingClientRect(); return [r.x - 50, r.y + r.height / 2]; })()`);
    await a.click(p[0], p[1]);
    await sleep(500);
    await a.clickText('Photo or video');
    const opened = await a.waitEvent('Page.fileChooserOpened', 5000);
    check('attach opens the file chooser', Boolean(opened));
    if (opened) await a.send('DOM.setFileInputFiles', { files: [file], backendNodeId: opened.params.backendNodeId });
    // It waits in the attach sheet (caption, compression, spoiler) until Send.
    check('the attach sheet shows the photo', await a.waitText('Send photo', 5000));
    await a.clickText('Send');
    await sleep(4000);
    const { messages } = await bob.api.get(`/api/chats/${dm.id}/messages?limit=20`);
    const last = messages.at(-1);
    let media = null;
    try {
      const k = await keyOf(bob, dm.id, last.enc.e, (await bob.api.get(`/api/users/${alice.id}`)).user);
      media = (await E.decryptMessage(k, last.enc, { chatId: dm.id, senderId: alice.id, senderSig: alice.identity.sigPublic })).payload.media?.[0];
    } catch (e) { media = { error: String(e) }; }
    check('the picture went out encrypted, with its key in the message', Boolean(media?.key && media?.iv && media.kind === 'photo'), JSON.stringify(media)?.slice(0, 160));
    // crypto.js decrypts the uploaded chunks to the same bytes.
    if (media?.key) {
      const info = (await bob.api.get(`/api/media/${media.id}`)).media;
      const fk = await E.importFileKey(media.key);
      const parts = [];
      for (let i = 0; i < info.chunks; i++) {
        const res = await fetch(`${base}/api/media/${media.id}/chunks/${i}`, { headers: { Authorization: 'Bearer tok_bob' } });
        parts.push(Buffer.from(await E.decryptChunk(fk, E.fromB64(media.iv), i, i === info.chunks - 1, new Uint8Array(await res.arrayBuffer()))));
      }
      check('crypto.js decrypts the file to the same bytes', Buffer.concat(parts).equals(png));
    }
    // Bob's Zig client shows it (downloaded and decrypted; drawn from its bytes).
    await b.clickText('Alice Carter');
    let shown = false;
    for (let i = 0; i < 40 && !shown; i++) { shown = await b.evaluate(`[...document.querySelectorAll('img')].some(i => (i.src.startsWith('data:image/png') || i.src.startsWith('blob:')) && i.naturalWidth === 64)`); if (!shown) await sleep(250); }
    check('Bob\'s client decrypts and shows the picture', shown);
    await b.shot('110-picture');
    // A file pasted into the page waits in the attach sheet (the web shell reads it).
    await a.evaluate(`(() => { const dt = new DataTransfer(); dt.items.add(new File(['notes for the trip'], 'notes.txt', { type: 'text/plain' })); window.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true })); })()`);
    check('a pasted file opens the attach sheet', await a.waitText('Send file', 5000));
    await a.clickText('Cancel');
  }

  if (want('group')) {
    // Compose → New group → pick Carol → Next → name → Create.
    const compose = await a.evaluate(`(() => { const btns = [...document.querySelectorAll('[role=button]')].filter(x => { const r = x.getBoundingClientRect(); return r.y < 80 && r.x > 380 && r.x < 470; }); const r = btns[0].getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(compose[0], compose[1]);
    await sleep(500);
    await a.clickText('New group');
    await a.waitText('Carol Nasser');
    await a.clickText('Carol Nasser');
    await a.shot('119-picked');
    await a.clickText('Next');
    await a.typeIn('Group name', 'Launch crew');
    await a.clickText('Create');
    check('group created and opened', await a.waitText('created the group', 8000));
    await a.typeIn('Message', 'Welcome to the launch crew');
    await a.key('Enter');
    await sleep(2500);
    const chats = (await carol.api.get('/api/chats')).chats;
    const g = chats.find(c => c.title === 'Launch crew');
    let text = null;
    try {
      const { messages } = await carol.api.get(`/api/chats/${g.id}/messages?limit=10`);
      const m = messages.filter(x => x.enc).at(-1);
      const k = await keyOf(carol, g.id, m.enc.e, (await carol.api.get(`/api/users/${alice.id}`)).user);
      text = (await E.decryptMessage(k, m.enc, { chatId: g.id, senderId: alice.id, senderSig: alice.identity.sigPublic })).payload.t;
    } catch (e) { text = String(e); }
    check('Carol (crypto.js) reads the new group\'s first message (key epoch made by Zig)', text === 'Welcome to the launch crew', text);
    await a.shot('120-new-group');
  }

  if (want('advanced')) {
    // Settings → Privacy → Advanced protection: passcode, recovery key shown.
    const p = await a.evaluate(`(() => { const btns = [...document.querySelectorAll('[role=button]')].filter(b => b.getBoundingClientRect().x < 80); const b = btns[btns.length - 2]; const r = b.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(p[0], p[1]);
    await a.clickText('Privacy and security');
    await a.clickText('Advanced protection');
    await a.typeIn('New passcode', 'correct horse 42');
    await a.typeIn('Repeat the passcode', 'correct horse 42');
    await a.clickText('Turn on');
    check('recovery key shown', await a.waitText('Your recovery key', 20000));
    await a.shot('130-recovery-key');
    const recovery = (await a.texts()).find(x => /^[0-9A-Z]{4}(-[0-9A-Z]{4}){11}$/.test(x));
    const me = (await alice.api.get('/api/me')).user;
    check('server: advanced mode', me.keyMode === 'advanced');
    // crypto.js opens the passcode backup the Zig client made.
    const backup = (await alice.api.get('/api/keys/backup')).backup;
    const opened = await E.unlockWithPasscode(backup, 'correct horse 42').then(r => r.identity.encPublic).catch(e => String(e));
    check('crypto.js opens the passcode backup made in Zig', opened === me.keys.enc);
    const viaRecovery = recovery ? await E.unlockWithRecovery(backup, recovery).then(r => r.identity.encPublic).catch(e => String(e)) : 'no key shown';
    check('crypto.js opens the recovery backup with the key shown', viaRecovery === me.keys.enc);
    await a.clickText('I saved my recovery key');
    // A new device (fresh profile storage): the unlock screen, then the passcode.
    const c = await tab(browser, out, { name: 'alice2' });
    await c.go('http://127.0.0.3:4300/', 500);
    await c.send('Network.setCookie', { name: 'wufour_token', value: 'tok_alice', domain: '127.0.0.3', path: '/' });
    await c.go('http://127.0.0.3:4300/');
    check('new device asks to unlock', await c.waitText('Unlock your chats'));
    await c.typeIn('Your passcode', 'correct horse 42');
    await c.clickText('Unlock');
    check('unlocked with the passcode: chats decrypt', await c.waitText(only.size && !only.has('chat') && !only.has('group') ? 'Ping from Bob' : 'Welcome to the launch crew', 30000));
    await c.shot('131-unlocked-new-device');
  }
} catch (e) {
  check('flow', false, String(e.stack || e));
  await a.shot('error-a').catch(() => {});
}
console.log(JSON.stringify({ a: a.logs.slice(-15), b: b.logs.slice(-15) }));
fs.writeFileSync(`${out}/results.txt`, results.join('\n') + '\n');
browser.kill();
await srv.stop();
await (await devDb()).drop();
wufour.close();
proxy.close();
process.exit(0);

function makePng(w, h) {
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (buf) => { let c = 0xffffffff; for (const x of buf) c = crcTable[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const rows = [];
  for (let y = 0; y < h; y++) { rows.push(0); for (let x = 0; x < w; x++) rows.push(x * 4, y * 5, 200); }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(Buffer.from(rows))), chunk('IEND', Buffer.alloc(0))]);
}
