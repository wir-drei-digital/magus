/// <reference types="@sveltejs/kit" />
/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />

// Iteration-0 service worker: precaches the app shell + immutable build
// assets so the installed PWA starts instantly, and serves the cached shell
// for navigations when the network is gone. RPC, sockets, and uploads are
// deliberately network-only — data caching strategies come with later
// iterations.
const sw = self as unknown as ServiceWorkerGlobalScope;

import { base, build, files, version } from '$service-worker';

const CACHE = `magus-next-${version}`;
const ASSETS = [...build, ...files];
// The SPA shell route (Phoenix serves index.html here). Cached separately:
// it's auth-gated, so only cache a direct 200 — a redirect means we'd be
// caching the sign-in page as the shell.
const SHELL = `${base}/`;

async function cacheShell(cache: Cache): Promise<void> {
	try {
		const response = await fetch(SHELL, { credentials: 'same-origin' });
		if (response.ok && !response.redirected) await cache.put(SHELL, response);
	} catch {
		// Offline install — navigations fall through to the network until the
		// next successful activation.
	}
}

sw.addEventListener('install', (event) => {
	event.waitUntil(
		caches
			.open(CACHE)
			.then((cache) => Promise.all([cache.addAll(ASSETS), cacheShell(cache)]))
			.then(() => sw.skipWaiting())
	);
});

sw.addEventListener('activate', (event) => {
	event.waitUntil(
		caches
			.keys()
			.then((keys) =>
				Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))
			)
			.then(() => sw.clients.claim())
	);
});

sw.addEventListener('fetch', (event) => {
	if (event.request.method !== 'GET') return;

	const url = new URL(event.request.url);
	if (url.origin !== location.origin) return;

	// SPA navigations under /next: network-first (fresh shell + auth redirects
	// keep working), cached shell as the offline fallback.
	if (event.request.mode === 'navigate' && url.pathname.startsWith(`${base}/`)) {
		event.respondWith(
			fetch(event.request).catch(async () => {
				const cached = await caches.open(CACHE).then((cache) => cache.match(SHELL));
				return cached ?? Response.error();
			})
		);
		return;
	}

	if (!ASSETS.includes(url.pathname)) return;

	event.respondWith(
		caches.open(CACHE).then(async (cache) => {
			const cached = await cache.match(url.pathname);
			return cached ?? fetch(event.request);
		})
	);
});
