// Phase-2 features of the Zig web client against Reseal-js: formatting, polls and quizzes,
// scheduled messages, multi-select, group administration, folders, chat lock and export.
//   node flow4.mjs <outdir> [scenario...]
import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { startAll, giveKeys, rotate, keyOf, E, PROXY_PORT, devDb } from './env.mjs';
import { launch, tab } from './cdp.mjs';

const out = path.resolve(process.argv[2] || './s5');
const only = new Set(process.argv.slice(3));
const want = (n) => only.size === 0 || only.has(n);
fs.mkdirSync(out, { recursive: true });
const { srv, base, wufour, proxy, client } = await startAll();
const APP = `http://localhost:${PROXY_PORT}`;
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
const dm = (await alice.api.post('/api/chats/private', { userId: bob.id })).chat;
const dmKey = await rotate(alice, dm.id);
const group = (await alice.api.post('/api/chats', { type: 'group', title: 'Plain crew', members: [bob.id, carol.id], encrypted: false })).chat;

const browser = await launch(out, 9353);
// Downloads land in <out>/downloads.
const dl = path.join(out, 'downloads');
fs.mkdirSync(dl, { recursive: true });
const a = await tab(browser, out, { name: 'alice' });
await a.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dl }).catch(() => {});
await a.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: dl }).catch(() => {});
await a.send('Network.setCookie', { name: 'wufour_token', value: 'tok_alice', domain: 'localhost', path: '/' });
await a.go(APP);
await a.waitText('Bob Haddad');

const lastMessage = async (u, chatId) => (await u.api.get(`/api/chats/${chatId}/messages?limit=5`)).messages.at(-1);
// Typing into the composer (a text area when Enter does not send).
const typeComposer = async (text) => {
  const p = await a.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message'); if (!el) return null; const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  await a.click(p[0], p[1]);
  await a.send('Input.insertText', { text });
  await sleep(300);
};
const sendButton = async () => {
  // The round send button at the far end of the composer.
  const p = await a.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message'); const r = el.getBoundingClientRect(); const cands = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => Math.abs((b.y + b.height / 2) - (r.y + r.height / 2)) < 30 && b.x > r.x + r.width - 10 && b.width >= 48); cands.sort((x, y) => y.x - x.x); const b = cands[0]; return b ? [b.x + b.width / 2, b.y + b.height / 2] : null; })()`);
  await a.click(p[0], p[1]);
  await sleep(800);
};

try {
  if (want('format')) {
    await a.clickText('Bob Haddad');
    await sleep(800);
    await typeComposer('**Bold** move and ||secret||');
    await a.key('Enter');
    await sleep(1500);
    const m = await lastMessage(bob, dm.id);
    const key = await keyOf(bob, dm.id, 1, (await bob.api.get(`/api/users/${alice.id}`)).user);
    const d = m?.enc ? await E.decryptMessage(key, m.enc, { chatId: dm.id, senderId: alice.id, senderSig: (await bob.api.get(`/api/users/${alice.id}`)).user.keys.sig }) : null;
    const p = d?.payload ?? null;
    check('format: encrypted text without the marks', p?.t === 'Bold move and secret', JSON.stringify(p));
    check('format: entities (bold 0..4, spoiler) in the payload', Array.isArray(p?.ent) && p.ent.some(e => e.t === 'bold' && e.o === 0 && e.l === 4) && p.ent.some(e => e.t === 'spoiler'), JSON.stringify(p?.ent));
    check('format: spoiler hidden in the bubble', await a.waitText('░░░░░░', 4000));
    await a.shot('90-format');
  }

  if (want('poll')) {
    await a.clickText('Plain crew');
    await sleep(800);
    // Attach (the paperclip left of the composer).
    const p = await a.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message'); const r = el.getBoundingClientRect(); const cands = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => Math.abs((b.y + b.height / 2) - (r.y + r.height / 2)) < 30 && b.x + b.width < r.x); cands.sort((x, y) => y.x - x.x); const b = cands[0]; return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
    await a.click(p[0], p[1]);
    await sleep(500);
    await a.shot('91-attach');
    await a.clickText('Poll');
    await a.typeIn('Ask a question', 'Capital of Jordan?');
    await a.typeIn('Option 1', 'Irbid');
    await a.typeIn('Option 2', 'Amman');
    await a.clickText('Quiz mode');
    await sleep(300);
    // The second circle marks the right answer.
    const circles = await a.evaluate(`[...document.querySelectorAll('input')].filter(i => /^Option/.test(i.placeholder)).map(i => { const r = i.parentElement.getBoundingClientRect(); return [r.x - 21, r.y + r.height / 2]; })`);
    await a.click(circles[1][0], circles[1][1]);
    await sleep(300);
    await a.shot('92-quiz');
    await a.clickText('Send');
    await sleep(1500);
    const m = await lastMessage(alice, group.id);
    check('poll: quiz posted', m?.poll?.quiz === true && m?.poll?.question === 'Capital of Jordan?', JSON.stringify(m?.poll));
    await bob.api.post(`/api/chats/${group.id}/messages/${m.id}/vote`, { options: [1] });
    // Alice votes from the message menu.
    await a.clickText('Capital of Jordan?');
    await a.clickText('Vote: Amman');
    await sleep(1200);
    check('poll: results after voting (100%)', await a.waitText('100%', 4000));
    const voted = (await alice.api.get(`/api/chats/${group.id}/messages/${m.id}`)).message;
    check('poll: the right answer is Amman', voted?.poll?.correct === 1 || voted?.content?.poll?.correct === 1, JSON.stringify(voted?.poll));
    await a.shot('93-quiz-results');
  }

  if (want('schedule')) {
    await a.clickText('Plain crew');
    await typeComposer('See you tomorrow');
    // The send-options button sits between the input and the send button.
    const p = await a.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message'); const r = el.getBoundingClientRect(); const cands = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => Math.abs((b.y + b.height / 2) - (r.y + r.height / 2)) < 30 && b.width < 46 && b.x > r.x); cands.sort((x, y) => y.x - x.x); const b = cands[0]; return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
    await a.click(p[0], p[1]);
    await sleep(500);
    await a.shot('94-send-options');
    await a.clickText('Schedule message');
    await a.clickText('In 1 hour');
    check('schedule: toast', await a.waitText('Message scheduled', 4000));
    const { messages } = await alice.api.get(`/api/chats/${group.id}/messages/scheduled`);
    check('schedule: on the server for later', messages.length === 1 && messages[0].text === 'See you tomorrow' && new Date(messages[0].scheduledAt).getTime() > Date.now() + 50 * 60_000);
  }

  if (want('select')) {
    await alice.api.post(`/api/chats/${group.id}/messages`, { text: 'one to delete', clientId: 's1' });
    await alice.api.post(`/api/chats/${group.id}/messages`, { text: 'two to delete', clientId: 's2' });
    await a.clickText('Plain crew');
    await a.waitText('two to delete');
    await a.clickText('one to delete');
    await a.clickText('Select');
    await a.clickText('two to delete');
    await a.shot('95b-after-second');
    check('select: two selected', await a.waitText('2 selected', 3000));
    await a.shot('95-selected');
    // The trash button of the selection bar.
    const btns = await a.evaluate(`[...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(r => r.y < 70 && r.x > 900).map(r => [r.x + r.width / 2, r.y + r.height / 2])`);
    await a.click(btns.at(-1)[0], btns.at(-1)[1]);
    await sleep(500);
    await a.shot('95c-confirm');
    await a.clickText('Delete');
    await sleep(1500);
    await a.shot('95d-deleted');
    const { messages } = await bob.api.get(`/api/chats/${group.id}/messages?limit=20`);
    const texts = messages.filter(m => !m.deleted).map(m => m.text);
    check('select: both gone (for me)', !(await a.centerOfText('one to delete')) && !(await a.centerOfText('two to delete')));
    void texts;
  }

  if (want('admin')) {
    await a.clickText('Plain crew');
    // The chat header (its title) opens the info panel.
    const hdr = await a.evaluate(`(() => { const r = [...document.querySelectorAll('div')].filter(d => d.childElementCount === 0 && d.textContent === 'Plain crew').map(d => d.getBoundingClientRect()).find(r => r.x > 480 && r.y < 70); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(hdr[0], hdr[1]);
    await sleep(600);
    await a.waitText('Group info');
    await a.waitText('Carol Nasser');
    await a.shot('96-group-info');
    const manage = await a.evaluate(`(() => { const row = [...document.querySelectorAll('div')].find(d => d.childElementCount === 0 && d.textContent === 'Carol Nasser'); const y = row.getBoundingClientRect().y; const b = [...document.querySelectorAll('div')].filter(d => d.childElementCount === 0 && d.textContent === 'Manage').map(d => d.getBoundingClientRect()).sort((p, q) => Math.abs(p.y - y) - Math.abs(q.y - y))[0]; return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
    await a.click(manage[0], manage[1]);
    await sleep(500);
    await a.clickText('Make admin');
    await a.typeIn('admin', 'Navigator');
    await a.clickText('Ban users');
    await a.shot('97-admin-rights');
    await a.clickText('Save');
    await sleep(1500);
    const { members } = await alice.api.get(`/api/chats/${group.id}/members?filter=admins`);
    const carolM = members.find(m => m.userId === carol.id);
    check('admin: Carol is an admin with a title, without banUsers', carolM?.role === 'admin' && carolM?.title === 'Navigator' && carolM?.rights?.banUsers === false, JSON.stringify(carolM));
    check('admin: role shown', await a.waitText('Navigator', 4000));
    await a.clickText('Edit');
    await a.clickText('Add members');
    await sleep(1200);
    const chat = (await bob.api.get(`/api/chats/${group.id}`)).chat;
    check('admin: members may no longer add people', chat.permissions?.addMembers === false, JSON.stringify(chat.permissions));
    await a.shot('98-group-edit');
  }

  if (want('folders')) {
    await a.go(APP);
    await a.waitText('Bob Haddad');
    // Settings → Chat folders.
    await a.evaluate(`history.pushState({}, '', '/')`);
    const gear = await a.evaluate(`(() => { const b = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(r => r.x < 80 && r.y > 600); const r = b[0]; return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(gear[0], gear[1]);
    await sleep(500);
    await a.clickText('Chat folders');
    await a.clickText('Create a folder');
    await a.typeIn('Folder name', 'Work');
    await a.clickText('Groups');
    await a.shot('99-folder-editor');
    await a.clickText('Save');
    await sleep(1200);
    const { folders } = await alice.api.get('/api/folders');
    check('folders: created with the groups rule', folders.length === 1 && folders[0].name === 'Work' && folders[0].include.includes('groups'), JSON.stringify(folders));
  }

  if (want('lock')) {
    await a.go(APP);
    await a.waitText('Bob Haddad');
    // Lock the DM from its menu (the row's menu via the header's more button in the chat).
    await a.clickText('Bob Haddad');
    const more = await a.evaluate(`(() => { const r = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(r => r.y < 70 && r.x > 900).sort((p, q) => q.x - p.x)[0]; return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(more[0], more[1]);
    await sleep(500);
    await a.clickText('Lock chat');
    await a.typeIn('At least 4 characters', '4321');
    await a.typeIn('Repeat the code', '4321');
    const secure = await a.evaluate(`[...document.querySelectorAll('input')].filter(i => i.type === 'password').length`);
    check('lock: code fields are hidden', secure >= 2, String(secure));
    await a.clickText('Save');
    check('lock: chat locked', await a.waitText('Chat locked', 4000));
    await a.go(APP);
    await a.waitText('Locked chat');
    check('lock: the list hides the preview', await a.hasText('Locked chat'));
    await a.clickText('Bob Haddad');
    check('lock: asks for the code', await a.waitText('Unlock chat', 3000));
    await a.typeIn('Chat lock code', '1111');
    await a.clickText('Unlock');
    check('lock: wrong code refused', await a.waitText('That code is not right.', 3000));
    await a.evaluate(`(() => { const i = [...document.querySelectorAll('input')].find(i => i.placeholder === 'Chat lock code'); i.select(); })()`);
    await a.send('Input.insertText', { text: '4321' });
    await sleep(300);
    await a.clickText('Unlock');
    check('lock: right code opens it', await a.waitText('Bold move and', 5000));
    await a.shot('100-unlocked');
  }

  if (want('export')) {
    await a.go(APP);
    await a.waitText('Plain crew');
    await a.clickText('Plain crew');
    const more = await a.evaluate(`(() => { const r = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(r => r.y < 70 && r.x > 900).sort((p, q) => q.x - p.x)[0]; return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(more[0], more[1]);
    await sleep(500);
    await a.clickText('Export chat');
    await a.clickText('Plain text');
    await a.shot('101-export');
    await a.clickText('Export');
    let file = null;
    for (let i = 0; i < 40 && !file; i++) { await sleep(250); file = fs.readdirSync(dl).find(f => f.endsWith('.txt')); }
    const body = file ? fs.readFileSync(path.join(dl, file), 'utf8') : '';
    check('export: a text file with the chat', Boolean(file) && body.includes('Plain crew') && body.includes('Capital of Jordan?'), file || 'no file');
  }

  if (want('arabic')) {
    await a.go(APP);
    await a.evaluate(`localStorage.setItem('zui:lang', 'ar')`);
    await a.waitText('Plain crew');
    await a.clickText('Plain crew');
    await sleep(800);
    await a.shot('102-chat-en');
  }
} catch (e) {
  check('flow', false, String(e.stack || e));
}
console.log(a.logs.filter(l => /EXCEPTION|NET 5/.test(l)).join('\n'));
fs.writeFileSync(`${out}/results.txt`, results.join('\n') + '\n');
browser.kill();
await srv.stop();
await (await devDb()).drop();
wufour.close();
proxy.close();
process.exit(0);
