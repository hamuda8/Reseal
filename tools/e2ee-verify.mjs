#!/usr/bin/env node
// The other direction of tools/e2ee-vectors.mjs: what the Zig port makes, the web client opens.
// Runs the Zig test that prints its own wraps, messages, backups and files, then opens them with
// Reseal-js's crypto.js (Node 22 WebCrypto, no packages).
//
//   node tools/e2ee-verify.mjs [path/to/zig] [path/to/crypto.js]

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const zig = process.argv[2] || 'zig';
const C = await import(pathToFileURL(path.resolve(process.argv[3] || path.join(root, '../Reseal-js/public/js/crypto.js'))).href);
const vectors = JSON.parse(fs.readFileSync(path.join(root, 'src/client/testdata/e2ee_vectors.json'), 'utf8'));

let out = '';
try {
  out = execFileSync(zig, ['test', 'src/client/crypto.zig', '--test-filter', 'emit vectors'], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
} catch (err) {
  out = String(err.stdout || '') + String(err.stderr || '');
  if (!out.includes('ZIG_VECTORS')) throw err;
}
// zig test prints to stderr; execFileSync returns stdout only when it succeeded, so read both.
if (!out.includes('ZIG_VECTORS')) {
  const r = (await import('node:child_process')).spawnSync(zig, ['test', 'src/client/crypto.zig', '--test-filter', 'emit vectors'], { cwd: root, encoding: 'utf8' });
  out = r.stdout + r.stderr;
}
const line = out.split('\n').find(l => l.startsWith('ZIG_VECTORS ') || l.includes('ZIG_VECTORS {'));
assert.ok(line, 'the Zig test printed no vectors');
const z = JSON.parse(line.slice(line.indexOf('{')));

const { chatId, aliceId, bobId } = vectors;
// Bob (a crypto.js identity) unwraps the key Zig wrapped for him; Zig's Alice signed it.
const { identity: bob } = await C.unlockWithEscrow(...await escrowOf(vectors.bob));
const raw = await C.unwrapChatKey(z.wrap, { chatId, epoch: z.epoch, userId: bobId, encPrivate: bob.encPrivate, wrapperSig: z.alice.sigPublic });
assert.equal(C.toB64(raw), z.chatKey);
const key = await C.importChatKey(raw);

const msg = await C.decryptMessage(key, z.env, { chatId, senderId: aliceId, senderSig: z.alice.sigPublic });
assert.equal(msg.verified, true);
assert.deepEqual(msg.payload, { v: 1, t: 'from Zig ✓ مرحبا' });
assert.deepEqual(await C.decryptDraft(key, z.draft, chatId), { t: 'zig draft' });

// Backups: the passcode (NFKC: full-width letters equal ASCII ones), the recovery key, escrow.
for (const p of [z.passcode, z.passcodeAscii]) {
  const { identity } = await C.unlockWithPasscode({ passcode: z.passcodeBox }, p);
  assert.equal(identity.encPublic, z.alice.encPublic);
}
await assert.rejects(C.unlockWithPasscode({ passcode: z.passcodeBox }, 'nope'), /Wrong passcode/);
const rec = await C.unlockWithRecovery({ recovery: z.recovery.box }, z.recovery.key);
assert.equal(rec.identity.sigPublic, z.alice.sigPublic);
const esc = await C.unlockWithEscrow(z.escrow.box, z.escrow.key, { extractable: true });
assert.equal(esc.bundle.enc, z.alice.enc); // the same PKCS#8 bytes

// A signature by Zig's identity verifies, and crypto.js's own signature with the imported key too.
assert.equal(await C.verify(z.alice.sigPublic, await C.sign(esc.identity.sigPrivate, 'hello'), 'hello'), true);

// The file.
const fk = await C.importFileKey(z.file.key);
const iv = C.fromB64(z.file.iv);
const parts = [];
for (let i = 0; i < z.file.chunks.length; i++) parts.push(Buffer.from(await C.decryptChunk(fk, iv, i, i === z.file.chunks.length - 1, C.fromB64(z.file.chunks[i]))));
assert.equal(Buffer.concat(parts).toString(), 'zig file, part two');

// Safety number between Zig's Alice and crypto.js's Bob.
const s = await C.safetyNumber({ enc: z.alice.encPublic, sig: z.alice.sigPublic }, { enc: vectors.bob.encPublic, sig: vectors.bob.sigPublic });
assert.deepEqual(s.groups, z.safety);

console.log('OK: crypto.js opened everything the Zig port made (wrap, message, draft, 3 backups, file, safety number).');

async function escrowOf(bundle) {
  const { box, escrowKey } = await C.escrowBackup(bundle);
  return [box, escrowKey];
}
