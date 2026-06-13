/* Service Worker — Rota do Pet
   Estratégia: network-first para conteúdo do próprio site (sempre pega a versão
   mais nova quando online; usa cache só como reserva offline).
   NUNCA intercepta Supabase nem Google Analytics — esses sempre vão direto à rede. */
const CACHE = 'rdp-v2';
const SHELL = [
  '/',
  '/index.html',
  '/logo.png',
  '/logo-header.jpg',
  '/favicon.png',
  '/icon-192.png',
  '/icon-512.png',
  '/manifest.json'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  // Só lida com GET do mesmo domínio. Supabase, GA, fontes etc. passam direto.
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;

  e.respondWith(
    fetch(req)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then(r => r || caches.match('/index.html')))
  );
});
