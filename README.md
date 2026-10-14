# Reseal

End-to-end encrypted messenger with calls, written in Zig. It replaces Reseal-js (Node) with the
same HTTP API, `/ws` protocol, MongoDB data and encryption format, so old and new clients talk to
each other and Taazur's embedded widget keeps working.

- **Client** (`src/client`): one zui codebase for the web (PWA), Android and iOS.
  - Chats, groups, channels, saved messages, folders, search (including encrypted chats),
    stories (Glimpses), polls, voice and round video messages, files and albums, reactions,
    replies, forwarding, scheduled and disappearing messages, chat lock, export.
  - AI assistants (streamed Markdown replies, Stop / Copy / Regenerate), bots with inline
    buttons, the developer console.
  - End-to-end encryption byte-compatible with Reseal-js's `crypto.js` (vectors checked both
    ways). Private keys live in `zui.keys`: non-extractable WebCrypto keys on the web,
    AndroidKeyStore on Android, the Keychain / Secure Enclave on iOS.
  - Calls: 1:1 and group, video, screen share (desktop web). The web uses the browser's WebRTC;
    the phones use [reseal-rtc](https://github.com/hamuda8/reseal-rtc) (our own WebRTC engine)
    with the system call screen (Android ConnectionService, iOS CallKit) and push to ring a closed app.
  - `/embed`: the widget Taazur embeds through `/sdk/reseal.js`.
  - Arabic (right-to-left) and English; home-screen widget; notifications.
- **Server** (`src/server`): every Reseal-js route and `/ws` event (presence, typing, messages,
  keys, calls and signalling), background jobs, media storage with Range, webhooks, Web Push and
  FCM/APNs push, AI through OpenRouter, Wufour sign-in with cookies or a Bearer token.

What is still different from Reseal-js, item by item: [docs/parity.md](docs/parity.md).

Shared code lives in [zig-core](https://github.com/hamuda8/zig-core); both zig-core and
reseal-rtc are pinned in `build.zig.zon`.

## Build

Zig 0.17.0.

| Command | Output |
|---|---|
| `zig build web -Doptimize=small` | `zig-out/web` |
| `zig build android -Doptimize=safe` | `zig-out/android/reseal.apk` |
| `zig build ios` | iOS static libraries |
| `zig build server -Doptimize=safe` | `zig-out/bin/reseal-server` |
| `zig build server-linux -Doptimize=safe` | `zig-out/linux/reseal-server` |
| `zig build test` | client (crypto vectors, headless flows) and server tests |

Build options (defaults are staging): `-Dserver=https://reseal.wreseal.com`,
`-Dauth=https://www.wreseal.com` (Wufour sign-in for the phone apps; keep the `www`).

Push on Android reads `..\secrets\reseal-google-services.json` (outside the repo, never
committed). Google's `firebase-messaging` client is the one third-party library allowed.

## Server configuration

Same variable names as Reseal-js. Environment variables win; otherwise `RESEAL_ENV_FILE`, or the
first of `.env.local`, `.env.production`, `.env`.

- `PORT`, `LISTEN`, `PUBLIC_URL`, `TRUST_PROXY`, `PUBLIC_APP`, `EARLY_ACCESS_USERS`, `NODE_ENV`
- `MONGO_URI`, `DB_NAME`, `MASTER_KEY` (same key derivation: existing sealed secrets still open)
- `AUTH_HOST`, `WUFOUR_INTERNAL_KEY`, `MAPS_URL`, `MODERATION_HOST`, `MODERATION_API_KEY`
- Calls: `STUN_URLS`, `TURN_URLS`, `TURN_SECRET`
- `MAX_UPLOAD_MB`, `API_RATE_LIMIT`, `LOG_REQUESTS`, `ALLOW_PRIVATE_FETCH`
- AI: `OPENROUTER_API_KEY`, `OPENROUTER_BASE_URL`
- Web Push: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`
- Phone push (each unset = off): `FCM_SERVICE_ACCOUNT_FILE`, `APNS_KEY_FILE`, `APNS_KEY_ID`,
  `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_SANDBOX`
- `RESEAL_PUBLIC_DIR`: the web pages to serve (see Staging).

## Staging

`reseal.wreseal.com` runs on the dev laptop behind Cloudflare Tunnel:

```
zig build server -Doptimize=safe
zig build web -Doptimize=small
powershell -File tools\staging.ps1
```

The script serves the zui web app (also at `/embed` and `/developers`), plus three files other
sites load unchanged from Reseal-js: `sdk/reseal.js`, `push.html` and `coming-soon.html`.
Settings come from `..\Reseal-js\.env.staging`; phone push uses
`..\secrets\firebase-service-account.json`. Roll back: stop `reseal-server.exe` and run
`npm run staging` in Reseal-js.

## Tests

- `zig build test`
- Server parity with Reseal-js (local MongoDB, throwaway databases):
  - `node --import ./tests/parity/register.mjs --test --test-concurrency=1 ../Reseal-js/test/zip.test.js ../Reseal-js/test/pushpreview.test.js ../Reseal-js/test/backend.test.js`
    runs Reseal-js's own suite against Node; prefix `RESEAL_SERVER=zig` to run it against this server.
  - `node --test tests/parity/realtime.test.mjs` and `node --test tests/parity/diff.test.mjs`
    (the same calls against both servers, answers and stored documents compared).
- Encryption compatibility: `node tools/e2ee-vectors.mjs` and `node tools/e2ee-verify.mjs`.
- Browser flows against a local server: `tools/web-e2e/flow*.mjs`.
