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
//   * Only files under /assets/ whose name carries a phx.digest content hash
//     (e.g. app-85b45c444d1ceeb284caa60c25317b09.js) are cached, cache-first.
//     Those are safe to keep indefinitely because the filename changes
//     whenever the content does. Undigested paths like /assets/js/app.js —
//     which is what dev mode and a server that skipped `mix assets.deploy`
//     serve — are left entirely to the network: caching one of those once
//     froze the bundle across deploys, so pages kept running pre-deploy JS
//     (seen as `unknown hook found for "Turnstile"` breaking signup after the
//     captcha shipped server-side).
//   * /live, /auth and /api are left entirely to the network.
//   * activate() only drops this worker's own cache generations
//     (magus-static-*). Cache storage is origin-wide and shared with the
//     SvelteKit shell's worker (magus-next-*), so deleting foreign keys here
//     would wipe that worker's cache on every activation.
//
// The digest gate also covers development: dev serves undigested filenames,
// so nothing is ever cached there — no hostname sniffing needed (v1 guessed
// dev-ness from `localhost`, which mislabeled LAN/tunnel/deployed dev hosts
// and let them poison the cache). The fetch handler existing at all is what
// makes the app installable, so the worker still registers everywhere.
//
// CACHE bumped v1 -> v2 so every browser that holds a v1 cache (potentially
// poisoned with undigested app.js) drops it on activation of this version.

const CACHE = "magus-static-v2";

// phx.digest inserts a 32-char lowercase md5 before the final extension:
// "app.js" -> "app-85b45c444d1ceeb284caa60c25317b09.js".
const DIGESTED = /-[a-f0-9]{32}\.[^\/]+$/;

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((key) => key.startsWith("magus-static-") && key !== CACHE)
          .map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener("fetch", (event) => {
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

  // Content-hashed build output only: cache-first (immutable). Everything
  // else falls through to the network and normal HTTP caching.
  if (url.pathname.startsWith("/assets/") && DIGESTED.test(url.pathname)) {
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
