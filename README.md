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

Fonts: the phone apps draw with Wufour Sans and Wufour Arabic from zig-core's `shells/fonts/`
(`zui/font.zig` has the rule: weight 400/500/700, Arabic text in the Arabic face with the Sans
filling in, the system font when a file is missing). The APK gets them on its own
(`assets/fonts/`). On iOS `zig build ios` puts them in `zig-out/ios/fonts/`; the bundle needs those
six files next to `Info.plist` (listed there under `UIAppFonts`) and the app links `CoreText`. To
refresh them, copy `..\WufourType\dist\golden\*.ttf` into `..\zig-core\shells\fonts\`, then point
`build.zig.zon` at the new zig-core commit (or build with `--fork=C:/MProjects/zig-core`).

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

## Running it (like the npm scripts)

| Command | Like | What it does |
|---|---|---|
| `zig build dev` (or `local`) | `npm run dev` | builds, then runs on this machine in the window, with `../Reseal-js/.env.local` (Ctrl+C stops it) |
| `zig build staging` | `npm run staging` | builds, then runs reseal.wreseal.com in this window with `../Reseal-js/.env.staging` (Ctrl+C stops it; `tools\run.ps1 -Mode staging -Background` starts it hidden instead) |
| `zig build production` | `npm start` | builds the Linux server and pages into `zig-out/production` and prints how to run them on Proxmox with `.env.production` |

All three run `tools/run.ps1` (`powershell -File tools\run.ps1 -Mode local|staging|production` does the same).
Staging runs behind Cloudflare Tunnel on this laptop: keep its window open (and Wufour's
`npm run staging`) while people use it. Roll back to Node: stop `reseal-server.exe` and run
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
