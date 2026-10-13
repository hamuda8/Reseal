// Differential parity: one script of API calls runs against Reseal-js and the Zig server side by
// side, and every answer (status and JSON) must match once the values that are random by nature
// (ids, dates, keys, tokens, invite codes) are replaced by placeholders in order of appearance.
// It covers what Reseal-js's own suite does not: profiles, contacts, blocks, folders, search,
// groups and channels, admins, invites, polls, pins, scheduled messages, bots, the developer
// console, the REST API, the widget endpoints, Wufour's internal search, link previews and the
// error answers.
//
//   node --test tests/parity/diff.test.mjs     (needs zig-out/bin/reseal-server and MongoDB)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { startServer, recorder, sleep } from './harness.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(process.env.RESEAL_JS || path.join(here, '../../../Reseal-js'));
const { createMemoryStore, answer } = await import(pathToFileURL(path.join(root, 'examples/message-store.mjs')).href);

const INTERNAL_KEY = 'k'.repeat(40);
const people = {
  'tok-amal': { userId: 'w-amal', username: 'amal_diff', role: 'user' },
  'tok-badr': { userId: 'w-badr', username: 'badr_diff', role: 'user' },
  'tok-carm': { userId: 'w-carm', username: 'Carm_Diff', role: 'admin' },
};

let wufour, models, site, servers = [];

before(async () => {
  wufour = await recorder((req, res, entry) => {
    if (req.url.startsWith('/api/internal/users/lookup')) {
      return res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ users: [{ id: 'w-dina', username: 'dina_diff' }] }));
    }
    if (req.url.startsWith('/api/internal/users/bulk')) {
      return res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify([{ _id: 'w-dina', username: 'dina_diff' }]));
    }
    const { token } = JSON.parse(entry.body || '{}');
    const user = people[token];
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(user ? { success: true, user } : { success: false }));
  });
  models = await recorder((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ data: [
      { id: 'b/model', name: 'Beta', context_length: 8000, architecture: { input_modalities: ['text', 'image'] }, pricing: { prompt: '0.000001', completion: '0.000002' } },
      { id: 'a/free', name: 'Alpha', context_length: 4000, architecture: { input_modalities: ['text'] }, pricing: { prompt: '0', completion: '0' } },
    ] }));
  });
  site = await recorder((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }).end('<html><head><title>Ignored</title><meta property="og:title" content="A &amp; B"><meta name="description" content="  Two   words "><meta property="og:image" content="/img/x.png"></head><body></body></html>');
  });
});

after(async () => {
  for (const s of servers) await s.srv.stop();
  for (const s of servers) await s.storage?.close();
  await wufour?.close();
  await models?.close();
  await site?.close();
});

/** Replaces what is random by nature with placeholders, numbered in order of appearance. */
function normalizer() {
  const ids = new Map();
  const id = (h) => { if (!ids.has(h)) ids.set(h, `<id${ids.size}>`); return ids.get(h); };
  const str = (s) => s
    .replace(/\b[0-9a-f]{64}\b/g, '<hex64>')
    .replace(/[0-9a-f]{24}/g, id)
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/g, '<date>')
    .replace(/rsl_(pk|sk|ut)_[A-Za-z0-9_-]+/g, 'rsl_$1_<rand>')
    .replace(/whsec_[A-Za-z0-9_-]+/g, 'whsec_<rand>')
    .replace(/…[A-Za-z0-9_-]{4}$/, '…<hint>')
    .replace(/e=\d+&s=[0-9a-f]+/g, 'e=<e>&s=<s>')
    .replace(/\/join\/[A-Za-z0-9]{12}/g, '/join/<code>')
    .replace(/localhost:\d+/g, 'localhost:<port>');
  const walk = (v, key) => {
    if (Array.isArray(v)) return v.map(x => walk(x));
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x, k)]));
    if (key === 'color' || key === 'serverTime' || key === 'credential') return `<${key}>`;
    if (key === 'username' && typeof v === 'string' && /^\d+:/.test(v)) return '<turn>';
    if (typeof v === 'number' && v > 1e12) return '<ms>';
    if (typeof v === 'string') {
      if (key === 'code' && /^[A-Za-z0-9]{12}$/.test(v) && /[A-Z0-9]/.test(v)) return '<code>';
      return str(v);
    }
    return v;
  };
  return (v) => walk(v);
}

/** The script: every call's status and answer, in order. */
async function script(srv, storage) {
  const out = [];
  const base = srv.base;
  const call = async (label, method, url, body, { token, headers = {}, raw } = {}) => {
    const res = await fetch(base + url, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body !== undefined && !raw ? { 'Content-Type': 'application/json' } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : raw ? body : JSON.stringify(body),
      redirect: 'manual',
    });
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { json = { text: text.slice(0, 200) }; }
    out.push({ label, status: res.status, json });
    return json;
  };
  const A = 'tok-amal', B = 'tok-badr', C = 'tok-carm';

  // Profiles
  const amal = (await call('me', 'GET', '/api/me', undefined, { token: A })).user;
  const badr = (await call('me b', 'GET', '/api/me', undefined, { token: B })).user;
  const carm = (await call('me c', 'GET', '/api/me', undefined, { token: C })).user;
  await call('patch me', 'PATCH', '/api/me', { displayName: ' Amal  A ', bio: 'Hi', privacy: { lastSeen: 'contacts', readReceipts: false }, settings: { theme: 'dark' } }, { token: A });
  await call('patch me bad', 'PATCH', '/api/me', { displayName: '' }, { token: A });
  await call('patch me bad privacy', 'PATCH', '/api/me', { privacy: { lastSeen: 'friends' } }, { token: A });
  await call('patch username bot', 'PATCH', '/api/me', { username: 'amalbot' }, { token: A });
  await call('patch username taken', 'PATCH', '/api/me', { username: 'badr_diff' }, { token: A });
  await call('patch settings keys', 'PATCH', '/api/me', { settings: { 'a.b': 1 } }, { token: A });
  await call('username check', 'GET', '/api/username/badr_diff', undefined, { token: A });
  await call('username free', 'GET', '/api/username/somebody_new', undefined, { token: A });
  await call('username bad', 'GET', '/api/username/1x', undefined, { token: A });

  // Contacts and blocks
  await call('add contact', 'POST', '/api/contacts', { userId: badr.id, name: 'Bee' }, { token: A });
  await call('add self', 'POST', '/api/contacts', { userId: amal.id }, { token: A });
  await call('add bad id', 'POST', '/api/contacts', { userId: 'nope' }, { token: A });
  await call('contacts', 'GET', '/api/contacts', undefined, { token: A });
  await call('lookup', 'POST', '/api/users/lookup', { ids: [badr.id, carm.id] }, { token: A });
  await call('user', 'GET', `/api/users/${badr.id}`, undefined, { token: A });
  await call('block', 'POST', '/api/blocks', { userId: carm.id }, { token: A });
  await call('blocks', 'GET', '/api/blocks', undefined, { token: A });
  await call('unblock', 'DELETE', `/api/blocks/${carm.id}`, undefined, { token: A });
  await call('from wufour', 'POST', '/api/users/from-wufour', { wufourId: 'w-dina' }, { token: A });

  // Folders
  const f1 = await call('folder', 'POST', '/api/folders', { name: 'Work', emoji: '💼', include: ['groups', 'x', 'groups'], excludeArchived: false }, { token: A });
  await call('folder 2', 'POST', '/api/folders', { name: 'Home' }, { token: A });
  await call('folder bad', 'POST', '/api/folders', { name: '' }, { token: A });
  await call('folder put', 'PUT', `/api/folders/${f1.folder.id}`, { name: 'Job', chatIds: [] }, { token: A });
  await call('folders', 'GET', '/api/folders', undefined, { token: A });

  // Groups and channels
  const g = (await call('group', 'POST', '/api/chats', { type: 'group', title: 'Plain', about: 'About', encrypted: false, members: [badr.id, carm.id] }, { token: A })).chat;
  await call('group bad type', 'POST', '/api/chats', { type: 'club', title: 'x' }, { token: A });
  await call('group no title', 'POST', '/api/chats', { type: 'group' }, { token: A });
  const ch = (await call('channel', 'POST', '/api/chats', { type: 'channel', title: 'News', username: 'news_diff' }, { token: A })).chat;
  await call('channel by username', 'GET', '/api/chats/by-username/news_diff', undefined, { token: B });
  await call('user by username', 'GET', '/api/chats/by-username/badr_diff', undefined, { token: A });
  await call('join channel', 'POST', `/api/chats/${ch.id}/join`, undefined, { token: B });
  await call('channel members as sub', 'GET', `/api/chats/${ch.id}/members`, undefined, { token: B });
  await call('channel post', 'POST', `/api/chats/${ch.id}/messages`, { text: 'Breaking' }, { token: A });
  await call('channel post by sub', 'POST', `/api/chats/${ch.id}/messages`, { text: 'Me too' }, { token: B });
  await call('patch group', 'PATCH', `/api/chats/${g.id}`, { title: 'Plainer', slowMode: 10, permissions: { sendMedia: false }, reactions: ['👍'] }, { token: A });
  await call('patch group bad slow', 'PATCH', `/api/chats/${g.id}`, { slowMode: 7 }, { token: A });
  await call('patch group not admin', 'PATCH', `/api/chats/${g.id}`, { title: 'Mine' }, { token: B });
  await call('members', 'GET', `/api/chats/${g.id}/members?filter=all`, undefined, { token: A });
  await call('admin', 'POST', `/api/chats/${g.id}/members/${badr.id}/admin`, { rights: { banUsers: false }, title: 'Mod' }, { token: A });
  await call('admins', 'GET', `/api/chats/${g.id}/members?filter=admins`, undefined, { token: A });
  const m1 = (await call('send', 'POST', `/api/chats/${g.id}/messages`, { text: 'Hello *there* friends', entities: [{ t: 'bold', o: 6, l: 7 }], clientId: 'c1' }, { token: A })).message;
  await call('send again', 'POST', `/api/chats/${g.id}/messages`, { text: 'Hello *there* friends', clientId: 'c1' }, { token: A });
  await call('send empty', 'POST', `/api/chats/${g.id}/messages`, { text: '   ' }, { token: A });
  await call('send bad entity', 'POST', `/api/chats/${g.id}/messages`, { text: 'abc', entities: [{ t: 'bold', o: 2, l: 5 }] }, { token: A });
  await call('send enc in plain', 'POST', `/api/chats/${g.id}/messages`, { enc: { e: 1 } }, { token: A });
  const poll = (await call('poll', 'POST', `/api/chats/${g.id}/messages`, { poll: { question: 'Lunch?', options: ['Yes', 'No'], anonymous: false } }, { token: B })).message;
  await call('vote', 'POST', `/api/chats/${g.id}/messages/${poll.id}/vote`, { options: [1] }, { token: A });
  await call('vote bad', 'POST', `/api/chats/${g.id}/messages/${poll.id}/vote`, { options: [5] }, { token: A });
  await call('voters', 'GET', `/api/chats/${g.id}/messages/${poll.id}/voters`, undefined, { token: A });
  await call('close poll', 'POST', `/api/chats/${g.id}/messages/${poll.id}/close-poll`, undefined, { token: B });
  await call('react', 'POST', `/api/chats/${g.id}/messages/${m1.id}/react`, { emoji: '👍' }, { token: B });
  await call('react not allowed', 'POST', `/api/chats/${g.id}/messages/${m1.id}/react`, { emoji: '😀' }, { token: B });
  await call('reactions', 'GET', `/api/chats/${g.id}/messages/${m1.id}/reactions`, undefined, { token: A });
  await call('edit', 'PATCH', `/api/chats/${g.id}/messages/${m1.id}`, { text: 'Hello again' }, { token: A });
  await call('edit not mine', 'PATCH', `/api/chats/${g.id}/messages/${m1.id}`, { text: 'x' }, { token: B });
  await call('pin', 'POST', `/api/chats/${g.id}/messages/${m1.id}/pin`, {}, { token: A });
  await call('read', 'POST', `/api/chats/${g.id}/read`, { seq: 100 }, { token: B });
  await call('readers', 'GET', `/api/chats/${g.id}/messages/${m1.id}/readers`, undefined, { token: A });
  await call('slow mode', 'POST', `/api/chats/${g.id}/messages`, { text: 'quick' }, { token: C });
  await call('slow mode again', 'POST', `/api/chats/${g.id}/messages`, { text: 'again' }, { token: C });
  const sched = (await call('schedule', 'POST', `/api/chats/${g.id}/messages`, { text: 'later', scheduledAt: Date.now() + 3600_000 }, { token: A })).message;
  await call('scheduled', 'GET', `/api/chats/${g.id}/messages/scheduled`, undefined, { token: A });
  await call('delete scheduled', 'POST', `/api/chats/${g.id}/messages/delete`, { ids: [sched.id], forEveryone: true }, { token: A });
  await call('history', 'GET', `/api/chats/${g.id}/messages?limit=10`, undefined, { token: B });
  await call('history around', 'GET', `/api/chats/${g.id}/messages?around=3&limit=4`, undefined, { token: B });
  await call('history bad', 'GET', `/api/chats/${g.id}/messages?limit=x`, undefined, { token: B });
  await call('one message', 'GET', `/api/chats/${g.id}/messages/${m1.id}`, undefined, { token: B });
  await call('media counts', 'GET', `/api/chats/${g.id}/media-counts`, undefined, { token: A });
  await call('state', 'POST', `/api/chats/${g.id}/state`, { pinned: true, archived: false, mutedUntil: 4102444800000, draft: { text: 'draft', replyTo: m1.id } }, { token: B });
  const inv = (await call('invite', 'POST', `/api/chats/${g.id}/invites`, { name: 'Friends', usageLimit: 5 }, { token: A })).invite;
  await call('invites', 'GET', `/api/chats/${g.id}/invites`, undefined, { token: A });
  await call('invite preview', 'GET', `/api/invites/${inv.code}`, undefined, { token: C });
  await call('invite bad', 'GET', '/api/invites/zzzzzzzzzzzz', undefined, { token: C });
  await call('common groups', 'GET', `/api/users/${badr.id}/common-groups`, undefined, { token: A });
  await call('chat', 'GET', `/api/chats/${g.id}`, undefined, { token: B });
  await call('chats', 'GET', '/api/chats', undefined, { token: B });
  await sleep(300);
  await call('search', 'GET', '/api/search?q=badr', undefined, { token: A });
  await call('search wufour', 'GET', '/api/search?q=din', undefined, { token: A });
  await call('search messages', 'GET', '/api/search/messages?q=again', undefined, { token: B });
  await call('remove member', 'DELETE', `/api/chats/${g.id}/members/${carm.id}`, undefined, { token: A });
  await call('banned', 'GET', `/api/chats/${g.id}/members?filter=banned`, undefined, { token: A });
  await call('leave', 'POST', `/api/chats/${g.id}/leave`, undefined, { token: B });
  await call('gone', 'GET', `/api/chats/${g.id}/messages`, undefined, { token: B });
  await call('delete chat not owner', 'DELETE', `/api/chats/${ch.id}`, undefined, { token: B });

  // Wufour's search bar.
  await call('internal no key', 'POST', '/api/internal/search', { userId: 'w-amal', query: 'news' });
  await call('internal', 'POST', '/api/internal/search', { userId: 'w-amal', query: 'news', lang: 'ar' }, { headers: { 'X-Internal-Key': INTERNAL_KEY } });
  await call('internal people', 'POST', '/api/internal/search', { userId: 'w-badr', query: 'amal' }, { headers: { 'X-Internal-Key': INTERNAL_KEY } });

  // Misc
  await call('config', 'GET', '/api/config');
  await call('ice', 'GET', '/api/calls/ice', undefined, { token: A });
  await call('calls', 'GET', '/api/calls', undefined, { token: A });
  await call('models', 'GET', '/api/ai/models', undefined, { token: A });
  await call('preview', 'GET', `/api/link-preview?url=${encodeURIComponent(`${site.url}/page`)}`, undefined, { token: A });
  await call('preview bad', 'GET', '/api/link-preview?url=ftp://x', undefined, { token: A });
  await call('unknown api', 'GET', '/api/nothing-here', undefined, { token: A });
  await call('unknown api anonymous', 'GET', '/api/nothing-here');
  await call('bad json', 'POST', '/api/chats', '{"type":', { token: A, raw: true, headers: { 'Content-Type': 'application/json' } });
  await call('scalar json', 'POST', '/api/chats', '"x"', { token: A, raw: true, headers: { 'Content-Type': 'application/json' } });
  await call('too large', 'POST', '/api/chats', JSON.stringify({ title: 'x'.repeat(600 * 1024) }), { token: A, raw: true, headers: { 'Content-Type': 'application/json' } });

  // Bots
  const bot = (await call('bot', 'POST', '/api/bots', { name: 'Helper', model: 'a/free', description: 'Helps', username: 'helper_diff_bot', starters: ['Hi'] }, { token: A })).bot;
  await call('bot bad name', 'POST', '/api/bots', { name: 'Helper', model: 'a/free', username: 'helper_diff' }, { token: A });
  await call('bots', 'GET', '/api/bots', undefined, { token: A });
  await call('bot patch', 'PATCH', `/api/bots/${bot.id}`, { public: true, temperature: 1.2, greeting: 'Hello!' }, { token: A });
  await call('discover', 'GET', '/api/bots/discover', undefined, { token: B });
  await call('bot chat', 'POST', '/api/chats/private', { userId: bot.id }, { token: B });

  // Developer console
  const app = (await call('app', 'POST', '/api/dev/apps', { name: 'Shop', allowedOrigins: ['https://Shop.Example.com/x', 'http://localhost:3000'] }, { token: A })).app;
  await call('app bad origin', 'POST', '/api/dev/apps', { name: 'X', allowedOrigins: ['nope'] }, { token: A });
  await call('apps', 'GET', '/api/dev/apps', undefined, { token: A });
  await call('app patch', 'PATCH', `/api/dev/apps/${app.id}`, { settings: { e2ee: 'off', guests: true, theme: { primary: '#112233', radius: 8 }, widget: { mode: 'inline' } }, storage: { url: `${storage.url}/store` }, webhook: { url: 'http://127.0.0.1:9/hook', enabled: false, events: ['message.created'] } }, { token: A });
  await call('app patch bad', 'PATCH', `/api/dev/apps/${app.id}`, { settings: { theme: { primary: 'red' } } }, { token: A });
  const secret = (await call('webhook secret', 'POST', `/api/dev/apps/${app.id}/webhook-secret`, {}, { token: A })).secret;
  storage.secret = secret;
  await call('storage test', 'POST', `/api/dev/apps/${app.id}/storage-test`, {}, { token: A });
  await call('app get', 'GET', `/api/dev/apps/${app.id}`, undefined, { token: A });
  const sk = (await call('rotate', 'POST', `/api/dev/apps/${app.id}/rotate-secret`, {}, { token: A })).secretKey;
  await call('app user', 'POST', `/api/dev/apps/${app.id}/users`, { externalId: 'u1', name: 'Una', role: 'agent' }, { token: A });
  await call('app users', 'GET', `/api/dev/apps/${app.id}/users?role=agent`, undefined, { token: A });
  await call('test token', 'POST', `/api/dev/apps/${app.id}/test-token`, {}, { token: A });
  await call('deliveries', 'GET', `/api/dev/apps/${app.id}/deliveries`, undefined, { token: A });
  await call('console as app user', 'GET', '/api/dev/apps', undefined, { token: (await (await fetch(`${base}/api/v1/users/u1/tokens`, { method: 'POST', headers: { Authorization: `Bearer ${sk}` } })).json()).token });

  // The REST API
  const v1 = (label, method, url, body) => call(label, method, url, body, { token: sk });
  await v1('v1 app', 'GET', '/api/v1/app');
  await v1('v1 bulk', 'POST', '/api/v1/users/bulk', { users: [{ externalId: 'u2', name: 'Two' }, { externalId: 'u3', name: 'Three', username: 'three_x' }] });
  await v1('v1 user', 'GET', '/api/v1/users/u2');
  await v1('v1 user missing', 'GET', '/api/v1/users/zz');
  await v1('v1 user patch', 'PATCH', '/api/v1/users/u2', { bio: 'Bio', metadata: { tier: 1 } });
  await v1('v1 bad metadata', 'PATCH', '/api/v1/users/u2', { metadata: { $x: 1 } });
  const vc = (await v1('v1 group', 'POST', '/api/v1/chats', { type: 'group', members: ['u1', 'u2', 'u3'], title: 'Team', externalId: 'g-1', metadata: { a: 1 } })).chat;
  await v1('v1 group again', 'POST', '/api/v1/chats', { type: 'group', members: ['u1'], externalId: 'g-1' });
  await v1('v1 chat', 'GET', '/api/v1/chats/ext:g-1');
  await v1('v1 chat patch', 'PATCH', `/api/v1/chats/${vc.id}`, { about: 'Desc' });
  await v1('v1 post', 'POST', '/api/v1/chats/ext:g-1/messages', { from: 'u2', text: 'From two' });
  await v1('v1 system post', 'POST', '/api/v1/chats/ext:g-1/messages', { text: 'System', buttons: [[{ text: 'Go', data: 'go' }]] });
  await v1('v1 messages', 'GET', '/api/v1/chats/ext:g-1/messages');
  await v1('v1 user chats', 'GET', '/api/v1/users/u1/chats');
  await v1('v1 unread', 'GET', '/api/v1/users/u1/unread');
  await v1('v1 remove member', 'DELETE', '/api/v1/chats/ext:g-1/members/u3');
  await v1('v1 add member', 'POST', '/api/v1/chats/ext:g-1/members', { members: ['u3'], role: 'admin' });
  await v1('v1 team', 'POST', '/api/v1/teams', { externalId: 't1', name: 'Store', members: ['u1'] });
  await v1('v1 team chat', 'POST', '/api/v1/chats', { type: 'team', team: 't1', members: ['u2'] });
  await v1('v1 teams', 'GET', '/api/v1/teams');
  await v1('v1 team chats', 'GET', '/api/v1/teams/t1/chats');
  await v1('v1 revoke', 'POST', '/api/v1/users/u2/sessions/revoke');
  await v1('v1 unknown', 'GET', '/api/v1/nothing');
  await v1('v1 delete chat', 'DELETE', '/api/v1/chats/ext:g-1');
  await call('v1 no key', 'GET', '/api/v1/app');

  // The widget
  await call('embed config', 'GET', `/api/embed/config?pk=${app.publishableKey}`);
  await call('embed config bad', 'GET', '/api/embed/config?pk=rsl_pk_nope');
  const guest = await call('guest', 'POST', '/api/embed/guest', { pk: app.publishableKey, guestId: 'g'.repeat(20), name: 'Visitor' });
  await call('guest me', 'GET', '/api/me', undefined, { token: guest.token });
  await call('resolve', 'GET', '/api/embed/resolve?user=u1', undefined, { token: guest.token });
  await call('embed teams', 'GET', '/api/embed/teams', undefined, { token: guest.token });
  await call('embed team', 'POST', '/api/embed/team', { team: 't1' }, { token: guest.token });

  // Pages
  for (const p of ['/developers', '/sdk/reseal.js', '/c/x', '/nothing.js', '/m/ffffffffffffffffffffffff', '/login']) {
    const res = await fetch(base + p, { redirect: 'manual' });
    out.push({ label: `page ${p}`, status: res.status, json: { type: (res.headers.get('content-type') || '').split(';')[0], csp: Boolean(res.headers.get('content-security-policy')), location: res.headers.get('location') && res.headers.get('location').replace(/localhost:\d+/g, 'host').replace(/%3A\d+/g, '') } });
  }
  return out;
}

test('the same calls get the same answers from Reseal-js and the Zig server', async () => {
  for (const zig of [false, true]) {
    const store = createMemoryStore();
    const storage = await recorder(async (req, res, entry) => {
      const { status, json } = await answer(store, storage.secret, entry.body, entry.headers['reseal-signature']);
      res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(json));
    });
    const srv = await startServer({ AUTH_HOST: wufour.url, WUFOUR_INTERNAL_KEY: INTERNAL_KEY, OPENROUTER_BASE_URL: models.url, TURN_URLS: 'turn:t.example', TURN_SECRET: 's' }, { zig });
    servers.push({ srv, storage, zig });
  }
  const [node, zig] = await Promise.all(servers.map(s => script(s.srv, s.storage)));
  const nn = normalizer(), nz = normalizer();
  const a = node.map(nn), b = zig.map(nz);
  assert.equal(b.length, a.length);
  const diffs = [];
  for (let i = 0; i < a.length; i++) {
    try { assert.deepStrictEqual(b[i], a[i]); } catch { diffs.push(`${a[i].label}\n  node: ${JSON.stringify(a[i])}\n  zig:  ${JSON.stringify(b[i])}`); }
  }
  assert.equal(diffs.length, 0, `${diffs.length} answers differ:\n${diffs.join('\n')}`);
});
