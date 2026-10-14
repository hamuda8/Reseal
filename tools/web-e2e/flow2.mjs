// The Zig Reseal web client in headless Chrome: layouts, languages, new accounts, sign-in,
// calls between two clients, and the embedded widget on a Taazur-like page.
//   node flow2.mjs <outdir> [scenario...]
import http from 'node:http';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { startAll, giveKeys, rotate, say, keyOf, E, PROXY_PORT, objectId, devDb, appStorage } from './env.mjs';
import { launch, tab } from './cdp.mjs';

const out = process.argv[2] || './s2';
const only = new Set(process.argv.slice(3));
const want = (n) => only.size === 0 || only.has(n);
fs.mkdirSync(out, { recursive: true });
const { srv, base, wufour, proxy, client } = await startAll();
const APP = `http://localhost:${PROXY_PORT}`;
const APP2 = `http://127.0.0.1:${PROXY_PORT}`; // a second cookie jar (Bob)
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
await bob.api.post(`/api/chats/${dm.id}/read`, { seq: 3 });
const group = (await alice.api.post('/api/chats', { type: 'group', title: 'Design team', members: [bob.id, carol.id], about: 'Everything about the Reseal look and feel' })).chat;
const gKey = await rotate(alice, group.id);
await say(carol, group.id, gKey, 'Morning all ☀️');
await say(bob, group.id, gKey, 'Morning! Standup in 10?');
await say(alice, group.id, gKey, 'Yes. I will share the launch checklist there.');
console.log('seeded; server', base);

const browser = await launch(out, 9351);
const setCookie = (t, tok, domain) => t.send('Network.setCookie', { name: 'wufour_token', value: tok, domain, path: '/' });

try {
  if (want('light')) {
    const t = await tab(browser, out, { name: 'light' });
    await setCookie(t, 'tok_alice', 'localhost');
    await t.go(APP);
    check('light: list', await t.waitText('Design team'));
    await t.shot('10-light-list');
    await t.clickText('Bob Haddad');
    check('light: dm', await t.waitText('soften the shadows'));
    await t.shot('11-light-dm');
    await t.clickText('Design team');
    await t.waitText('launch checklist');
    await t.shot('12-light-group');
    // Info panel
    await t.clickText('Design team');
    await sleep(800);
    await t.shot('13-light-info');
    t.close();
  }

  if (want('settings')) {
    const t = await tab(browser, out, { name: 'settings' });
    await setCookie(t, 'tok_alice', 'localhost');
    await t.go(APP);
    await t.waitText('Design team');
    // The rail's settings button is the last icon before the avatar: use the tab bar labels on phone instead.
    const p = await t.evaluate(`(() => { const btns = [...document.querySelectorAll('[role=button]')].filter(b => b.getBoundingClientRect().x < 80); const b = btns[btns.length - 2]; const r = b.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await t.click(p[0], p[1]);
    check('settings root', await t.waitText('Privacy and security'));
    await t.shot('20-settings');
    await t.clickText('Privacy and security');
    check('privacy: encryption card', await t.waitText('Your chats are encrypted'));
    await t.shot('21-privacy');
    await t.clickText('My key fingerprint');
    await sleep(600);
    await t.shot('22-fingerprint');
    t.close();
  }

  if (want('panes')) {
    const t = await tab(browser, out, { name: 'panes' });
    await setCookie(t, 'tok_alice', 'localhost');
    await t.go(APP);
    await t.waitText('Design team');
    const rail = async (i) => { const p = await t.evaluate(`(() => { const btns = [...document.querySelectorAll('[role=button]')].filter(b => b.getBoundingClientRect().x < 80); const r = btns[${i}].getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`); await t.click(p[0], p[1]); await sleep(1200); };
    await rail(3);
    check('contacts pane', await t.waitText('Carol Nasser'));
    await t.shot('23-contacts');
    await rail(1);
    await sleep(800);
    await t.shot('24-calls');
    await rail(2);
    check('saved pane opens the Saved chat', await t.waitText('Your private space for notes, links, files and messages you want to keep. Encrypted and on all your devices.', 6000));
    await t.typeIn('Write a note…', 'Note to self 📝');
    await t.key('Enter');
    await sleep(2500);
    check('a note in Saved (first key epoch made here)', await t.waitText('Note to self'));
    const saved = (await alice.api.get('/api/chats')).chats.find(c => c.type === 'saved');
    check('saved note stored encrypted', saved?.lastMessage?.enc != null && !saved?.lastMessage?.text);
    await t.shot('25-saved');
    t.close();
  }

  if (want('invite')) {
    const club = (await alice.api.post('/api/chats', { type: 'group', title: 'Book club', members: [] })).chat;
    const k = await rotate(alice, club.id);
    await say(alice, club.id, k, 'This month: Dune');
    const { invite } = await alice.api.post(`/api/chats/${club.id}/invites`, {});
    const t = await tab(browser, out, { name: 'carol' });
    await setCookie(t, 'tok_carol', '127.0.0.1');
    await t.go(`${APP2}/join/${invite.code}`);
    check('invite link shows the group', await t.waitText('Book club'));
    await t.shot('26-invite');
    await t.clickText('Join group');
    check('joined: the group opens', await t.waitText('joined the group', 8000));
    await t.shot('27-joined');
    t.close();
  }

  if (want('phone')) {
    const t = await tab(browser, out, { name: 'phone', width: 390, height: 844, mobile: true });
    await setCookie(t, 'tok_alice', 'localhost');
    await t.go(APP);
    check('phone: list', await t.waitText('Bob Haddad'));
    await t.shot('30-phone-list');
    await t.clickText('Bob Haddad');
    check('phone: chat', await t.waitText('soften the shadows'));
    await t.shot('31-phone-chat');
    t.close();
  }

  if (want('arabic')) {
    const t = await tab(browser, out, { name: 'ar', width: 1280, height: 800 });
    await setCookie(t, 'tok_alice', 'localhost');
    await t.go(APP, 800);
    await t.evaluate(`localStorage.setItem('zui:lang', 'ar')`);
    await t.go(APP);
    check('arabic: list title', await t.waitText('المحادثات'));
    await t.shot('40-ar-list');
    await t.clickText('Bob Haddad');
    await t.waitText('soften the shadows');
    await t.shot('41-ar-dm');
    const p = await tab(browser, out, { name: 'ar-phone', width: 390, height: 844, mobile: true });
    await setCookie(p, 'tok_alice', 'localhost');
    await p.go(APP);
    await p.waitText('المحادثات');
    await p.shot('42-ar-phone-list');
    // Back to English from Settings: the web says so and reloads (settings.js).
    await p.clickText('الإعدادات');
    await p.clickText('اللغة');
    await p.clickText('English');
    check('language: changed, reloading', await p.waitText('Language changed. Reloading…', 3000));
    check('language: reloaded in English', await p.waitText('Chats', 8000));
    t.close();
    p.close();
  }

  if (want('newuser')) {
    const t = await tab(browser, out, { name: 'dan' });
    await setCookie(t, 'tok_dan', '127.0.0.1');
    await t.go(APP2);
    check('new user: empty list', await t.waitText('No chats yet', 10000));
    const me = (await client(base, 'tok_dan').get('/api/me')).user;
    check('new user: keys created on this device and backed up', Boolean(me.hasKeys && me.keyMode === 'standard'), JSON.stringify({ hasKeys: me.hasKeys, keyMode: me.keyMode }));
    await t.shot('50-new-user');
    // Search for Alice and write to her (an encrypted chat with a fresh key epoch).
    await t.typeIn('Search people and chats', 'alice');
    check('global search finds Alice', await t.waitText('Alice Carter', 6000));
    await t.shot('51-search');
    await t.clickText('Alice Carter');
    await t.typeIn('Message', 'Hi Alice, Dan here');
    await t.key('Enter');
    await sleep(2500);
    const dchats = (await alice.api.get('/api/chats')).chats;
    const dd = dchats.find(c => c.peer?.displayName === 'dan' || c.peer?.username === 'dan');
    let got = null;
    try {
      const { messages } = await alice.api.get(`/api/chats/${dd.id}/messages?limit=5`);
      const m = messages.at(-1);
      const danUser = (await alice.api.get(`/api/users/${m.senderId}`)).user;
      const k = await keyOf(alice, dd.id, m.enc.e, danUser);
      got = (await E.decryptMessage(k, m.enc, { chatId: dd.id, senderId: m.senderId, senderSig: danUser.keys.sig })).payload.t;
    } catch (e) { got = String(e); }
    check('a new account first message (new chat, new key epoch) reads in crypto.js', got === 'Hi Alice, Dan here', got);
    await t.shot('52-new-user-chat');
    t.close();
  }

  if (want('signin')) {
    const t = await tab(browser, out, { name: 'signin' });
    await t.go('http://127.0.0.2:4300/');
    check('signed out: Wufour sign-in', await t.waitText('Continue with Wufour'));
    await t.shot('60-signin');
    t.close();
  }

  if (want('calls')) {
    const a = await tab(browser, out, { name: 'call-alice' });
    const b = await tab(browser, out, { name: 'call-bob' });
    await setCookie(a, 'tok_alice', 'localhost');
    await setCookie(b, 'tok_bob', '127.0.0.1');
    await a.go(APP);
    await b.go(APP2);
    // English (an earlier scenario may have switched the app to Arabic).
    for (const t of [a, b]) await t.evaluate(`localStorage.setItem('zui:lang', 'en')`);
    await a.go(APP);
    await b.go(APP2);
    await a.waitText('Bob Haddad');
    await b.waitText('Alice Carter');
    await a.clickText('Bob Haddad');
    await a.waitText('soften the shadows');
    // The call button is the first icon of the header actions.
    let p = null;
    for (let i = 0; i < 20 && !p; i++) { p = await a.evaluate(`(() => { let btns = [...document.querySelectorAll('[role=button]')].filter(b => { const r = b.getBoundingClientRect(); return r.y < 70 && r.x > 900; }); if (!btns.length) { btns = [...document.querySelectorAll('[role=button]')].filter(b => { const r = b.getBoundingClientRect(); return r.y < 70 && r.x < 400; }).sort((x, y) => y.getBoundingClientRect().x - x.getBoundingClientRect().x); } if (!btns.length) return null; const r = btns[0].getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`); if (!p) await sleep(250); }
    if (!p) await a.shot('70-call-no-header');
    // Count the sounds the pages play (dial tone, ringtone).
    for (const t of [a, b]) await t.evaluate(`(() => { window.__plays = 0; const o = HTMLMediaElement.prototype.play; HTMLMediaElement.prototype.play = function () { window.__plays++; return o.apply(this, arguments); }; })()`);
    await a.click(p[0], p[1]);
    check('call: ringing on the caller', await a.waitText('Ringing', 8000));
    check('call: incoming on the callee', await b.waitText('Incoming voice call', 8000));
    const plays = [await a.evaluate('window.__plays'), await b.evaluate('window.__plays')];
    check('call: dial tone and ringtone play', plays[0] >= 1 && plays[1] >= 1, JSON.stringify(plays));
    await a.shot('70-call-ringing');
    await b.shot('71-call-incoming');
    // Answer: the green phone at the end of the banner.
    const ans = await b.evaluate(`(() => { const btns = [...document.querySelectorAll('[role=button]')].filter(x => x.getBoundingClientRect().y < 120); const r = btns[btns.length - 1].getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await b.click(ans[0], ans[1]);
    const connected = await a.evaluate(`new Promise(r => setTimeout(() => r(true), 6000))`);
    let ticking = false;
    for (let i = 0; i < 40 && !ticking; i++) { ticking = (await a.texts()).some(x => /^0:[0-9][0-9]$/.test(x)); if (!ticking) await sleep(250); }
    check('call: connected (timer shown)', ticking);
    await a.shot('72-call-active-caller');
    await b.shot('73-call-active-callee');
    check('call: emoji fingerprint shown on both', (await a.texts()).some(x => /\p{Extended_Pictographic}/u.test(x) && x.length <= 12) && (await b.texts()).some(x => /\p{Extended_Pictographic}/u.test(x) && x.length <= 12));
    await a.clickText('End');
    let gone = false;
    for (let i = 0; i < 30 && !gone; i++) { gone = !(await b.hasText('Mute')); if (!gone) await sleep(250); }
    check('call: ended on the callee', gone);
    void connected;
    a.close();
    b.close();
  }

  if (want('embed')) {
    const SECRET = `rsl_sk_${crypto.randomBytes(24).toString('base64url')}`;
    const HOST_PORT = 4401;
    const hostOrigin = `http://localhost:${HOST_PORT}`;
    const dev = await devDb();
    const store = await appStorage('whsec_taazur', 4510);
    await dev.db.collection('apps').insertOne({
      ownerId: await objectId(alice.id), name: 'Taazur', publishableKey: 'rsl_pk_taazur', secretKeyHash: crypto.createHash('sha256').update(SECRET).digest('hex'), secretKeyHint: '…abcd',
      allowedOrigins: [hostOrigin], settings: { e2ee: 'on', guests: false, theme: { primary: '#0ea5a0', accent: '#0ea5a0', title: 'Taazur', subtitle: 'Chat with stores' }, widget: { mode: 'inline', welcome: 'Ask a store anything about an order or a product.' } },
      webhook: { secretSealed: store.sealed }, storage: { url: store.url }, createdAt: new Date(),
    });
    const v1 = client(base, SECRET);
    const appUser = async (externalId, name) => {
      await v1.post('/api/v1/users', { externalId, name });
      const { token, user } = await v1.post(`/api/v1/users/${externalId}/tokens`, { ttlSeconds: 3600 });
      const u = { id: user.id, token, api: client(base, token) };
      await giveKeys(u);
      return u;
    };
    const buyer = await appUser('buyer-42', 'Sara Ahmad');
    const staff = await appUser('staff-12', 'Hadi Saleh');
    await appUser('owner-7', 'Noor Haddad');
    await v1.post('/api/v1/teams', { externalId: 'store-7', name: 'Noor Boutique', about: 'Dresses, abayas and accessories', members: ['owner-7', 'staff-12'] });
    const storeChat = (await v1.post('/api/v1/chats', { type: 'team', team: 'store-7', members: ['buyer-42'] })).chat;
    const k1 = await rotate(buyer, storeChat.id);
    await say(buyer, storeChat.id, k1, 'Hi! Is the blue dress available in size M?');
    await say(staff, storeChat.id, k1, 'Hello Sara 👋 Yes, we have 3 left in M. Want me to reserve one for you?');
    const page = `<!doctype html><html><head><meta charset="utf-8"><title>Taazur</title><style>body{margin:0;font-family:system-ui;background:#f6f7f9}header{background:#fff;border-bottom:1px solid #e5e7eb;padding:16px 32px;font-weight:700;font-size:20px}#chat{position:absolute;left:32px;top:80px;width:420px;height:640px;border-radius:16px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.15)}</style></head>
<body><header>Taazur · Noor Boutique</header><div id="chat"></div>
<script src="${APP}/sdk/reseal.js"></script>
<script>window.chat = Reseal.init({ publishableKey: 'rsl_pk_taazur', getToken: () => Promise.resolve(${JSON.stringify(buyer.token)}), mode: 'inline', container: '#chat' });
chat.on('unread', n => { window.__unread = n; });</script></body></html>`;
    const hostSrv = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(page); });
    await new Promise(r => hostSrv.listen(HOST_PORT, r));
    const t = await tab(browser, out, { name: 'embed' });
    await t.go(hostOrigin, 6000);
    // The widget lives in an iframe: read its frame's texts.
    const frameTexts = async () => {
      const tree = await t.send('Page.getFrameTree');
      const child = tree.result?.frameTree?.childFrames?.[0]?.frame;
      if (!child) return [];
      const world = await t.send('Page.createIsolatedWorld', { frameId: child.id });
      const r = await t.send('Runtime.evaluate', { contextId: world.result.executionContextId, expression: `[...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent).map(d => d.textContent)`, returnByValue: true });
      return r.result?.result?.value || [];
    };
    let ok = false;
    for (let i = 0; i < 30 && !ok; i++) { ok = (await frameTexts()).some(x => x.includes('Noor Boutique')); if (!ok) await sleep(500); }
    check('embed: the widget lists the store chat (team title)', ok, JSON.stringify((await frameTexts()).slice(0, 12)));
    check('embed: the store\'s encrypted reply decrypts', (await frameTexts()).some(x => x.includes('we have 3 left')));
    await t.shot('80-embed');
    t.close();
    hostSrv.close();
  }
} catch (e) {
  check('flow', false, String(e.stack || e));
}
fs.writeFileSync(`${out}/results.txt`, results.join('\n') + '\n');
browser.kill();
await srv.stop();
await (await devDb()).drop();
wufour.close();
proxy.close();
process.exit(0);
