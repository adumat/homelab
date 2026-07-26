const CACHE = "babymon-v2";
const SHELL = ["/", "/app.js", "/manifest.webmanifest"];
self.addEventListener("install", e => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); });
self.addEventListener("activate", e => e.waitUntil(
  caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  // never cache live streams or go2rtc assets/signaling
  if (u.pathname.startsWith("/audio/") || u.pathname.startsWith("/api/") || u.pathname.startsWith("/go2rtc/")) return;
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
});
