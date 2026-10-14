// Glimpses (stories) between the Zig web client and Reseal-js's crypto: the Zig client posts a
// text glimpse that crypto.js opens, and opens one that crypto.js sealed.
//   node flow5.mjs <outdir>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { startAll, giveKeys, E, PROXY_PORT, devDb } from './env.mjs';
import { launch, tab } from './cdp.mjs';

const out = path.resolve(process.argv[2] || './s6');
fs.mkdirSync(out, { recursive: true });
const { srv, base, wufour, proxy, client } = await startAll();
const APP = `http://localhost:${PROXY_PORT}`;
const results = [];
const check = (name, ok, extra = '') => { results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ` (${extra})` : ''}`); console.log(results.at(-1)); };

const users = {};
for (const [tok, name] of [['tok_alice', 'Alice Carter'], ['tok_bob', 'Bob Haddad']]) {
  const api = client(base, tok);
  const me = (await api.get('/api/me')).user;
  await api.patch('/api/me', { displayName: name });
  users[tok] = { id: me.id, api, token: tok };
  await giveKeys(users[tok]);
}
const alice = users.tok_alice, bob = users.tok_bob;
await alice.api.post('/api/contacts', { userId: bob.id });
await bob.api.post('/api/contacts', { userId: alice.id });
await alice.api.post('/api/chats/private', { userId: bob.id });

// What e2ee.js sealStory does, with crypto.js.
async function sealStory(u, payload, viewers) {
  const ref = crypto.randomBytes(16).toString('base64url');
  const raw = E.newChatKeyBytes();
  const ctx = `story:${ref}`;
  const enc = await E.encryptMessage(await E.importChatKey(raw), payload, { chatId: ctx, epoch: 1, senderId: u.id, signer: u.identity.sigPrivate });
  const keys = [];
  for (const v of [{ id: u.id, enc: u.identity.encPublic }, ...viewers]) keys.push(await E.wrapChatKey(raw, { chatId: ctx, epoch: 1, userId: v.id, recipientEnc: v.enc, signer: u.identity.sigPrivate }));
  return { ref, enc, keys };
}
async function openStory(u, story, authorSig) {
  const ctx = `story:${story.ref}`;
  const raw = await E.unwrapChatKey(story.key, { chatId: ctx, epoch: 1, userId: u.id, encPrivate: u.identity.encPrivate, wrapperSig: authorSig });
  return E.decryptMessage(await E.importChatKey(raw), story.enc, { chatId: ctx, senderId: story.userId, senderSig: authorSig });
}

const browser = await launch(out, 9355);
const a = await tab(browser, out, { name: 'alice' });
await a.send('Network.setCookie', { name: 'wufour_token', value: 'tok_alice', domain: 'localhost', path: '/' });
try {
  // Bob's glimpse, sealed by crypto.js for Alice.
  const sealed = await sealStory(bob, { v: 1, kind: 'text', text: 'Sunset at Wadi Rum', bg: 2 }, [{ id: alice.id, enc: alice.identity.encPublic }]);
  await bob.api.post('/api/stories', { ...sealed, mediaIds: [], audience: 'contacts', pinned: false });
  await a.go(APP);
  await a.waitText('Bob Haddad');
  check('strip: Bob in the glimpses row', await a.waitText('Bob', 6000));
  await a.shot('110-strip');
  // Open it from the row (the circle with his first name).
  await a.clickText('Bob');
  check('viewer: crypto.js glimpse opens in Zig', await a.waitText('Sunset at Wadi Rum', 8000));
  await a.shot('111-viewer');
  await sleep(1000);
  const feed = (await bob.api.get('/api/stories')).stories;
  check('viewer: marked as viewed', feed[0]?.viewCount === 1, String(feed[0]?.viewCount));
  // Close, then post Alice's own text glimpse.
  await a.key('Escape');
  await a.go(APP);
  await a.waitText('Your glimpse');
  await a.clickText('Your glimpse');
  await a.clickText('Text');
  await a.typeIn('Type something', 'Hello from Zig');
  await a.shot('112-compose');
  await a.clickText('Share glimpse');
  check('post: toast', await a.waitText('Glimpse shared', 8000));
  await sleep(1000);
  const bobFeed = (await bob.api.get('/api/stories')).stories;
  const mine = bobFeed.find(s => s.userId === alice.id);
  check('post: Bob sees Alice\'s glimpse', Boolean(mine));
  if (mine) {
    const aliceSig = (await bob.api.get(`/api/users/${alice.id}`)).user.keys.sig;
    const d = await openStory(bob, mine, aliceSig).catch(e => ({ error: String(e) }));
    check('post: crypto.js opens the Zig glimpse, signature verified', d?.verified === true && d?.payload?.text === 'Hello from Zig', JSON.stringify(d?.payload || d));
  }
} catch (e) {
  check('flow', false, String(e.stack || e));
}
console.log(a.logs.filter(l => /EXCEPTION|NET 5|NET 4/.test(l)).join('\n'));
fs.writeFileSync(`${out}/results.txt`, results.join('\n') + '\n');
browser.kill();
await srv.stop();
await (await devDb()).drop();
wufour.close();
proxy.close();
process.exit(0);
