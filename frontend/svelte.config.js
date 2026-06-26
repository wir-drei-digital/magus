import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),

	kit: {
		// Pure SPA: no prerendering, index.html fallback for client-side routing.
		// Built straight into priv/static so Plug.Static serves the assets and
		// MagusWeb.NextUiController serves the shell for non-asset paths.
		adapter: adapter({
			pages: '../priv/static/next',
			assets: '../priv/static/next',
			fallback: 'index.html',
			precompress: false,
			strict: true
		}),
		paths: {
			// Served under /next during the migration (preview path + asset base).
			// When panes start serving at workbench routes (iteration 3+), assets
			// keep resolving absolutely under /next/_app from any path.
			//
			// PWA cutover note: when the SPA takes over /chat (or moves to base '/'),
			// set this app's manifest "id" to "/chat" (matching the classic
			// priv/static/manifest.webmanifest) so already-installed PWAs upgrade in
			// place instead of being stranded as a separate identity, and register the
			// service worker at scope "/" so it supersedes the classic /sw.js.
			base: '/next'
		}
	}
};

export default config;
