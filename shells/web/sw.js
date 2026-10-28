// Reseal service worker: an installable app that opens offline, and Web Push notifications.
// - The app's files (page, zui.js, app.wasm, icons): network first so deploys show at once, the
//   cache when offline. A page never opened here gets offline.html.
// - The API, media, the socket, sign-in and the widget: never cached.
// - Push: the server's payload names the chat and the sender. Message text in end-to-end
//   encrypted chats stays encrypted here (this worker cannot reach the keys, which the app keeps
//   in its own storage), so those say "New message", as Reseal-js does when it cannot decrypt.
const CACHE = 'reseal-zig-v2';
const SHELL = ['/', '/offline.html', '/manifest.json', '/zui.js', '/app.wasm', '/icon.svg', '/img/icons/icon-192.png',
  '/fonts/WufourSansGolden-Regular.woff2', '/fonts/WufourSansGolden-Medium.woff2', '/fonts/WufourSansGolden-Bold.woff2', '/fonts/WufourArabicGolden-Regular.woff2', '/fonts/WufourArabicGolden-Medium.woff2', '/fonts/WufourArabicGolden-Bold.woff2'];
const NEVER = /^\/(api|m|ws|embed|push|login|logout|auth|sdk)(\/|$)/;

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE).then((cache) => Promise.all(SHELL.map((url) => cache.add(url).catch(() => {})))));
});

self.addEventListener('activate', (event) => event.waitUntil((async () => {
  const names = await caches.keys();
  await Promise.all(names.filter((n) => n.startsWith('reseal-') && n !== CACHE).map((n) => caches.delete(n)));
  await self.clients.claim();
})()));

async function networkFirst(request, key) {
  try {
    const response = await fetch(request);
    if (response.ok && response.type === 'basic') {
      const copy = response.clone();
      caches.open(CACHE).then((cache) => cache.put(key || request, copy)).catch(() => {});
    }
    return response;
  } catch {
    const cache = await caches.open(CACHE);
    return (await cache.match(key || request)) || (request.mode === 'navigate' ? await cache.match('/offline.html') : null) || new Response('', { status: 503, statusText: 'Offline' });
  }
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET' || request.headers.has('range')) return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || NEVER.test(url.pathname)) return;
  // Every app address (/, /c/<id>, /@name, /join/<code>) is the same page.
  if (request.mode === 'navigate') return event.respondWith(networkFirst(request, '/'));
  if (!url.search) event.respondWith(networkFirst(request));
});

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = {}; }
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (windows.some((w) => w.visibilityState === 'visible' && w.focused)) return;
    const text = data.type === 'call' ? data.body : (data.enc ? 'New message' : (data.body || 'New message'));
    await self.registration.showNotification(data.title || 'Reseal', {
      body: `${data.sender && data.type !== 'call' ? `${data.sender}: ` : ''}${text}`,
      tag: data.type === 'call' ? `call:${data.callId}` : `chat:${data.chatId}`,
      renotify: true,
      silent: Boolean(data.silent),
      icon: '/icon.svg',
      badge: '/icon.svg',
      requireInteraction: data.type === 'call',
      data: { chatId: data.chatId },
    });
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const chatId = event.notification.data?.chatId;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const app = windows.find((w) => !w.url.includes('/embed'));
    if (app) {
      if (chatId) app.postMessage({ type: 'open-chat', chatId });
      try { await app.focus(); } catch {}
      return;
    }
    await self.clients.openWindow(chatId ? `/c/${chatId}` : '/');
  })());
});
