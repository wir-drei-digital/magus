// Magus service worker.
//
// Purpose: make the classic LiveView app installable as a PWA and speed up
// repeat loads by serving content-hashed build assets from cache. It does NOT
// attempt offline support: LiveView runs over a WebSocket that service workers
// cannot intercept, so the app always needs the server to function.
//
// Safety rules baked in below:
//   * Only same-origin GET requests are ever cached.
//   * Navigations (HTML) are never cached. The server-rendered page carries a
//     CSRF token and a signed, time-limited LiveView session token, so serving
//     a stale copy would break mount/auth.
//   * Only /assets/* (esbuild + tailwind output, content-hashed by phx.digest)
//     is cached, cache-first. That is safe to keep indefinitely because the
//     filename changes whenever the content does.
//   * /live, /auth and /api are left entirely to the network.
//   * In development the worker is a pass-through no-op, so it never serves a
//     stale bundle or fights phoenix_live_reload. It still registers and still
//     has a fetch handler, so the install prompt can be tested on localhost.

const CACHE = "magus-static-v1";
const DEV = ["localhost", "127.0.0.1"].includes(self.location.hostname);

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", (event) => {
  // Pass-through in dev. The handler still exists, which is all Chrome needs to
  // consider the app installable, but nothing is cached.
  if (DEV) return;

  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Never cache HTML navigations (CSRF + signed LiveView session token).
  if (request.mode === "navigate") return;

  // Never touch the live transport, auth, or API.
  if (
    url.pathname.startsWith("/live") ||
    url.pathname.startsWith("/auth") ||
    url.pathname.startsWith("/api")
  ) {
    return;
  }

  // Content-hashed build output: cache-first (immutable).
  if (url.pathname.startsWith("/assets/")) {
    event.respondWith(cacheFirst(request));
  }
});

async function cacheFirst(request) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  if (response.ok) {
    cache.put(request, response.clone());
  }
  return response;
}
