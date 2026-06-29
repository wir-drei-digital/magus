import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),

	kit: {
		// Pure SPA: no prerendering, index.html fallback for client-side routing.
		// Built into priv/static/next (its own dir so the SvelteKit build never
		// clobbers Phoenix's priv/static); a dedicated Plug.Static serves that dir
		// at the site root and MagusWeb.NextUiController serves the shell for
		// non-asset paths.
		adapter: adapter({
			pages: '../priv/static/next',
			assets: '../priv/static/next',
			fallback: 'index.html',
			precompress: false,
			strict: true
		}),
		paths: {
			// The SPA is the primary UI, served at the site root. Assets resolve
			// absolutely under /_app from any path; the service worker registers at
			// scope "/" so it supersedes the classic /sw.js.
			base: ''
		}
	}
};

export default config;
