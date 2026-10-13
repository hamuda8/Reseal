// Runs Reseal-js's own tests, unchanged, against either server. Loaded with --import, it
// redirects their `./harness.js` to tests/parity/harness.mjs, which starts the Zig binary when
// RESEAL_SERVER=zig (and Reseal-js's `node server.js` otherwise, for the baseline).
//
//   node --import ./tests/parity/register.mjs --test --test-concurrency=1 ../Reseal-js/test/backend.test.js
import { register } from 'node:module';

register('./hooks.mjs', import.meta.url);
