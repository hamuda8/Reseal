// Phase-2 features of the Zig web client against Reseal-js: formatting, polls and quizzes,
// scheduled messages, multi-select, group administration, folders, chat lock and export.
//   node flow4.mjs <outdir> [scenario...]
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
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
    // Ctrl+B on a selection wraps it (the format bar's shortcut).
    await typeComposer('make it loud');
    await a.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message'); el.focus(); el.setSelectionRange(8, 12); el.dispatchEvent(new Event('select')); })()`);
    await sleep(300);
    check('format: the bar shows over a selection', await a.evaluate(`!!document.querySelector('[aria-label="Bold"]')`));
    await a.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'b', code: 'KeyB', windowsVirtualKeyCode: 66, modifiers: 2 });
    await a.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'b', code: 'KeyB', windowsVirtualKeyCode: 66, modifiers: 2 });
    await sleep(400);
    const val = await a.evaluate(`[...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message').value`);
    check('format: Ctrl+B wraps the selection', val === 'make it **loud**', val);
    await a.key('Enter');
    await sleep(1200);
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
    // A right click on Send opens the send options.
    const p = await a.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === 'Message'); const r = el.getBoundingClientRect(); const cands = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => Math.abs((b.y + b.height / 2) - (r.y + r.height / 2)) < 30 && b.x > r.x + r.width - 10 && b.width >= 48); cands.sort((x, y) => y.x - x.x); const b = cands[0]; return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
    await a.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: p[0], y: p[1], button: 'right', buttons: 2, clickCount: 1 });
    await a.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: p[0], y: p[1], button: 'right', buttons: 0, clickCount: 1 });
    await sleep(500);
    await a.shot('94-send-options');
    await a.clickText('Schedule message');
    await a.clickText('In 1 hour');
    check('schedule: toast', await a.waitText('Message scheduled', 4000));
    const { messages } = await alice.api.get(`/api/chats/${group.id}/messages/scheduled`);
    check('schedule: on the server for later', messages.length === 1 && messages[0].text === 'See you tomorrow' && new Date(messages[0].scheduledAt).getTime() > Date.now() + 50 * 60_000);
  }

  if (want('voice')) {
    await a.clickText('Plain crew');
    await sleep(800);
    // The round button at the far end of the composer (send, or record when empty).
    const sendAt = async () => a.evaluate(`(() => { const cands = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => b.width >= 48 && b.width <= 52 && b.y > 600); cands.sort((x, y) => y.x - x.x); const b = cands[0]; return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
    let p = await sendAt();
    await a.click(p[0], p[1]);
    await sleep(2500);
    await a.shot('103-recording');
    p = await sendAt();
    await a.click(p[0], p[1]);
    await sleep(3000);
    let m = await lastMessage(bob, group.id);
    check('voice: a voice message with duration and waveform', m?.media?.[0]?.kind === 'voice' && m.media[0].duration > 1 && typeof m.media[0].waveform === 'string', JSON.stringify(m?.media?.[0] || m));
    await a.shot('104-voice-bubble');
    // A round video: a right click switches the button to the camera.
    p = await sendAt();
    await a.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: p[0], y: p[1], button: 'right', buttons: 2, clickCount: 1 });
    await a.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: p[0], y: p[1], button: 'right', buttons: 0, clickCount: 1 });
    await sleep(500);
    p = await sendAt();
    await a.click(p[0], p[1]);
    await sleep(2500);
    await a.shot('105-round-recording');
    p = await sendAt();
    await a.click(p[0], p[1]);
    await sleep(4000);
    m = await lastMessage(bob, group.id);
    check('voice: a round video message', m?.media?.[0]?.kind === 'round' && /^video\//.test(m.media[0].mime || ''), JSON.stringify(m?.media?.[0] || m));
    await a.shot('106-round-bubble');
    // Play the voice message (the round play button in its bubble).
    const play = await a.evaluate(`(() => { const r = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => b.width === 44 && b.height === 44 && b.x > 600 && b.y < 600).sort((x, y) => x.y - y.y)[0]; return r ? [r.x + r.width / 2, r.y + r.height / 2] : null; })()`);
    // zui's players are detached media elements: watch play().
    await a.evaluate(`(() => { window.__media = []; const o = HTMLMediaElement.prototype.play; HTMLMediaElement.prototype.play = function () { window.__media.push(this); return o.call(this); }; })()`);
    if (play) await a.click(play[0], play[1]);
    let playing = false;
    for (let i = 0; i < 20 && !playing; i++) { await sleep(250); playing = await a.evaluate(`window.__media.some(e => !e.paused && e.currentTime > 0)`); }
    check('voice: plays back', playing);
  }

  if (want('profile')) {
    const png = makePng(80, 80);
    const file = path.resolve(out, 'me.png');
    fs.writeFileSync(file, png);
    await a.send('Page.setInterceptFileChooserDialog', { enabled: true });
    await a.go(APP);
    await a.waitText('Bob Haddad');
    const gear = await a.evaluate(`(() => { const b = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(r => r.x < 80 && r.y > 600); const r = b[0]; return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(gear[0], gear[1]);
    await sleep(500);
    await a.clickText('My account');
    // The camera badge on the big avatar opens the photo menu.
    const av = await a.evaluate(`(() => { const r = [...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(b => b.width === 120 && b.height === 120)[0]; return r ? [r.x + r.width / 2, r.y + r.height / 2] : null; })()`);
    await a.click(av[0], av[1]);
    await sleep(400);
    await a.clickText('Upload a photo');
    const opened = await a.waitEvent('Page.fileChooserOpened', 5000);
    if (opened) await a.send('DOM.setFileInputFiles', { files: [file], backendNodeId: opened.params.backendNodeId });
    let me = null;
    for (let i = 0; i < 30 && !me?.avatar; i++) { await sleep(300); me = (await alice.api.get('/api/me')).user; }
    check('profile: photo uploaded and set', Boolean(me?.avatar), JSON.stringify(me?.avatar));
    await carol.api.patch('/api/me', { username: 'carol_taken' });
    await a.typeIn('username', 'carol_taken');
    check('profile: a taken username is flagged', await a.waitText('That username is taken.', 4000));
    await a.typeIn('username', 'alice_new_name');
    check('profile: a free username is confirmed', await a.waitText('is available', 4000));
    await a.shot('107-profile');
  }

  if (want('extras')) {
    const anchor = (await bob.api.post(`/api/chats/${group.id}/messages`, { text: 'Anchor message far above', clientId: 'x0' })).message;
    for (let i = 0; i < 40; i++) await carol.api.post(`/api/chats/${group.id}/messages`, { text: `Filler ${i}`, clientId: `f${i}` });
    await bob.api.post(`/api/chats/${group.id}/messages`, { text: 'Replying to the anchor', replyTo: anchor.id, clientId: 'x1' });
    await a.go(APP);
    await a.waitText('Plain crew');
    await a.clickText('Plain crew');
    await a.waitText('Replying to the anchor');
    await sleep(800);
    // The quote inside the reply (its text is the anchor's).
    const q = await a.evaluate(`(() => { const els = [...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent === 'Anchor message far above'); const vis = els.map(e => e.getBoundingClientRect()).filter(r => r.width > 0 && r.y > 0 && r.y < 800); const r = vis[vis.length - 1]; return r ? [r.x + r.width / 2, r.y + r.height / 2] : null; })()`);
    await a.click(q[0], q[1]);
    await sleep(1500);
    const anchorVisible = await a.evaluate(`(() => { const els = [...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent === 'Anchor message far above'); return els.some(e => { const r = e.getBoundingClientRect(); return r.y > 80 && r.y < 700 && r.x > 470; }) ; })()`);
    check('extras: the reply quote jumps to the message', anchorVisible);
    await a.shot('108-jumped');
    // Pin with the dialog.
    await a.clickText('Replying to the anchor');
    await a.clickText('Pin');
    check('extras: pin asks whether to notify', await a.waitText('Notify all members', 3000));
    await a.clickText('Pin');
    await sleep(1000);
    const chat = (await bob.api.get(`/api/chats/${group.id}`)).chat;
    check('extras: pinned', (chat.pinned || []).length === 1, JSON.stringify(chat.pinned));
    // Details.
    await a.clickText('Filler 39');
    await a.clickText('Details');
    check('extras: details show the encryption', await a.waitText('Not end-to-end encrypted', 3000));
    await a.key('Escape');
    await sleep(400);
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
    const btns = await a.evaluate(`[...document.querySelectorAll('[role=button]')].map(b => b.getBoundingClientRect()).filter(r => r.y < 70 && r.x > 900).map(r => [r.x + r.width / 2, r.y + r.height / 2]).sort((p, q) => p[0] - q[0])`);
    console.log('  selection bar buttons', JSON.stringify(btns));
    await a.click(btns.at(-1)[0], btns.at(-1)[1]);
    await sleep(500);
    await a.shot('95c-confirm');
    // The confirmation (retried once: the first tap can land while the list still scrolls).
    if (!(await a.waitText('Delete 2 messages?', 3000))) { await a.click(btns.at(-1)[0], btns.at(-1)[1]); await a.waitText('Delete 2 messages?', 3000); }
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
    const hdr = await a.evaluate(`(() => { const r = [...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent === 'Plain crew').map(d => d.getBoundingClientRect()).find(r => r.x > 480 && r.y < 70); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    await a.click(hdr[0], hdr[1]);
    await sleep(600);
    await a.waitText('Group info');
    await a.waitText('Carol Nasser');
    await a.shot('96-group-info');
    const manage = await a.evaluate(`(() => { const inInfo = (d) => d.getBoundingClientRect().x > 900; const row = [...document.querySelectorAll('div')].find(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent === 'Carol Nasser' && inInfo(d)); row.scrollIntoView({ block: 'center' }); const rr = row.getBoundingClientRect(); const y = rr.y + rr.height / 2; const b = [...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent === 'Manage').map(d => d.getBoundingClientRect()).filter(p => p.y + p.height / 2 > y).sort((p, q) => p.y - q.y)[0]; return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
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
    check('admin: Carol is an admin with a title, without banUsers', carolM?.role === 'admin' && carolM?.title === 'Navigator' && carolM?.rights?.banUsers === false, JSON.stringify(members));
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
    await a.typeIn('Chat lock code', '4321');
    await a.clickText('Unlock');
    check('lock: right code opens it', await a.waitText('Encrypted chat', 5000) && !(await a.hasText('Unlock chat')));
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
    for (let i = 0; i < 40 && !file; i++) { await sleep(250); file = fs.readdirSync(dl).find(f => f.endsWith('.txt') || f.endsWith('.zip')); }
    // With files to include it is a .zip (the text inside, stored), else the .txt itself.
    const body = file ? fs.readFileSync(path.join(dl, file)).toString('latin1') : '';
    check('export: a text file with the chat', Boolean(file) && body.includes('Plain crew') && (only.size || body.includes('Capital of Jordan?')), file || 'no file');
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
  console.log(a.logs.slice(-25).join('\n'));
}
console.log(a.logs.filter(l => /EXCEPTION|NET 5/.test(l)).join('\n'));
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
