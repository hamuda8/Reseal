// Realtime and sign-in checks that Reseal-js's suite does not make: Wufour tokens as Bearer
// headers (the native apps), the WebSocket opened with ?token= and with a header, chat events,
// typing, presence, group calls with large signalling messages, and acks for failures.
// Runs against Node or Zig like the others:
//
//   RESEAL_SERVER=zig node --test tests/parity/realtime.test.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer, client, socket, recorder, sleep } from './harness.mjs';

let srv, wufour;
const users = {
  'tok-amal': { userId: 'w-amal', username: 'amal_test', role: 'user' },
  'tok-badr': { userId: 'w-badr', username: 'badr_test', role: 'user' },
  'tok-carm': { userId: 'w-carm', username: 'carm_test', role: 'user' },
};

before(async () => {
  // A fake Wufour: /api/auth/verify answers for the three tokens above.
  wufour = await recorder((req, res, entry) => {
    const { token } = JSON.parse(entry.body || '{}');
    const user = users[token];
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(user ? { success: true, user } : { success: false }));
  });
  srv = await startServer({ AUTH_HOST: wufour.url });
});

after(async () => {
  await srv?.stop();
  await wufour?.close();
});

test('Bearer: a Wufour token signs in without cookies; bad or missing ones get 401 JSON', async () => {
  const me = await client(srv.base, 'tok-amal').get('/api/me');
  assert.equal(me.user.displayName, 'amal_test');
  assert.equal(me.user.username, 'amal_test');
  // The same account through the cookie, as the web app signs in.
  const viaCookie = await fetch(`${srv.base}/api/me`, { headers: { Cookie: 'wufour_token=tok-amal' } }).then(r => r.json());
  assert.equal(viaCookie.user.id, me.user.id);
  // Bearer writes need no CSRF header (cookies do).
  const patched = await client(srv.base, 'tok-amal').patch('/api/me', { bio: 'hello' });
  assert.equal(patched.user.bio, 'hello');
  const csrf = await fetch(`${srv.base}/api/me`, { method: 'PATCH', headers: { Cookie: 'wufour_token=tok-amal', 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(csrf.status, 403);
  for (const headers of [{ Authorization: 'Bearer nope' }, { Accept: 'application/json' }, {}]) {
    const res = await fetch(`${srv.base}/api/me`, { headers, redirect: 'manual' });
    assert.equal(res.status, 401);
    assert.match(res.headers.get('content-type'), /application\/json/);
    assert.equal((await res.json()).error.code, 'unauthorized');
  }
});

test('WebSocket: ?token= and an Authorization header both sign in; bad tokens are refused', async () => {
  const s = await socket(srv.base, 'tok-badr');
  assert.match(s.ready.connId, /^[0-9a-f-]{36}$/);
  assert.ok(s.ready.userId);
  s.close();
  const withHeader = new WebSocket(`${srv.base.replace('http', 'ws')}/ws`, { headers: { Authorization: 'Bearer tok-badr' } });
  const first = await new Promise((resolve, reject) => {
    withHeader.addEventListener('message', e => resolve(JSON.parse(e.data)), { once: true });
    withHeader.addEventListener('error', () => reject(new Error('header sign-in failed')), { once: true });
  });
  assert.equal(first.t, 'ready');
  withHeader.close();
  const bad = new WebSocket(`${srv.base.replace('http', 'ws')}/ws?token=wrong`);
  await new Promise((resolve) => { bad.addEventListener('error', resolve, { once: true }); bad.addEventListener('close', resolve, { once: true }); });
  assert.notEqual(bad.readyState, WebSocket.OPEN);
});

test('chat events: new chat, messages, typing, reads, edits, presence', async () => {
  const amal = client(srv.base, 'tok-amal');
  const badr = client(srv.base, 'tok-badr');
  const carm = client(srv.base, 'tok-carm');
  const bId = (await badr.get('/api/me')).user.id;
  const cId = (await carm.get('/api/me')).user.id;
  const sb = await socket(srv.base, 'tok-badr');
  const sc = await socket(srv.base, 'tok-carm');
  const { chat } = await amal.post('/api/chats', { type: 'group', title: 'Plain', encrypted: false, members: [bId, cId] });
  assert.equal(chat.encrypted, false);
  await sb.wait('chat.new', d => d.id === chat.id);
  const sa = await socket(srv.base, 'tok-amal');

  const { message } = await amal.post(`/api/chats/${chat.id}/messages`, { text: 'Hello **all**', clientId: 'x1' });
  const got = await sb.wait('message', d => d.id === message.id);
  assert.equal(got.text, 'Hello **all**');
  assert.equal(got.clientId, undefined); // only the sender sees its clientId
  assert.equal((await sa.wait('message', d => d.id === message.id)).clientId, 'x1');

  sb.send('typing', { chatId: chat.id, action: 'recording_voice' });
  const typing = await sa.wait('typing', d => d.chatId === chat.id);
  assert.equal(typing.userId, bId);
  assert.equal(typing.action, 'recording_voice');
  assert.equal(typing.topicId, null);

  await badr.post(`/api/chats/${chat.id}/read`, { seq: message.seq });
  assert.equal((await sa.wait('read', d => d.chatId === chat.id)).seq, message.seq);

  await amal.patch(`/api/chats/${chat.id}/messages/${message.id}`, { text: 'Hello all' });
  assert.ok((await sc.wait('message.edit', d => d.id === message.id)).editedAt);

  // Presence: Badr hides his tab, then leaves.
  sb.send('presence', { visible: false });
  const away = await sa.wait('presence', d => d.userId === bId && d.status === 'offline');
  assert.ok(away.lastSeenAt);
  sb.send('presence', { visible: true });
  await sa.wait('presence', d => d.userId === bId && d.status === 'online');
  sb.close();
  await sa.wait('presence', d => d.userId === bId && d.status === 'offline');

  // Unknown types are ignored; handler errors come back as failed acks.
  sc.send('nonsense', {});
  await assert.rejects(sc.request('call.accept', { callId: 'ffffffffffffffffffffffff' }), (err) => err.code === 'call_ended');
  sa.close();
  sc.close();
});

test('group call: join, large signalling messages, media, reactions, end for everyone', async () => {
  const amal = client(srv.base, 'tok-amal');
  const badr = client(srv.base, 'tok-badr');
  const bId = (await badr.get('/api/me')).user.id;
  const { chat } = await amal.post('/api/chats', { type: 'group', title: 'Call room', encrypted: false, members: [bId] });
  const sa = await socket(srv.base, 'tok-amal');
  const sb = await socket(srv.base, 'tok-badr');
  const started = await sa.request('call.start', { chatId: chat.id, video: false });
  assert.equal(started.join, true);
  const groupEvt = await sb.wait('call.group', d => d.callId === started.callId);
  assert.equal(groupEvt.count, 0);
  const joinA = await sa.request('call.join', { callId: started.callId });
  assert.deepEqual(joinA.peers, []);
  const joinB = await sb.request('call.join', { callId: started.callId, video: true });
  assert.equal(joinB.peers.length, 1);
  assert.equal(joinB.peers[0].connId, sa.ready.connId);
  const joined = await sa.wait('call.participant_joined', d => d.callId === started.callId);
  assert.equal(joined.connId, sb.ready.connId);
  assert.deepEqual(joined.media, { audio: true, video: true, screen: false });

  // An SDP offer far bigger than one TCP segment (and than 16 KiB).
  const sdp = 'v=0\r\n' + 'a=candidate:x\r\n'.repeat(3000);
  sa.send('call.signal', { callId: started.callId, to: sb.ready.connId, data: { type: 'offer', sdp } });
  const sig = await sb.wait('call.signal', d => d.callId === started.callId);
  assert.equal(sig.data.sdp, sdp);
  assert.equal(sig.from, sa.ready.connId);

  sb.send('call.media', { callId: started.callId, audio: false, video: true, screen: true });
  assert.deepEqual((await sa.wait('call.media', d => d.callId === started.callId)).media, { audio: false, video: true, screen: true });
  sb.send('call.reaction', { callId: started.callId, emoji: '👏', hand: true });
  assert.equal((await sa.wait('call.reaction', d => d.callId === started.callId)).hand, true);

  // A member who is not an admin cannot end it for everyone; the owner can.
  await assert.rejects(sb.request('call.end_for_all', { callId: started.callId }), /Only admins/);
  sa.send('call.end_for_all', { callId: started.callId });
  const ended = await sb.wait('call.ended', d => d.callId === started.callId);
  assert.equal(ended.reason, 'ended_by_admin');
  const svc = await sb.wait('message', d => d.kind === 'service' && d.service.action === 'group_call_ended');
  assert.equal(svc.chatId, chat.id);
  await sleep(100);
  const { calls } = await amal.get('/api/calls');
  assert.equal(calls.find(c => c.id === started.callId).status, 'ended');
  sa.close();
  sb.close();
});
