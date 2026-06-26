import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [tailwindcss(), sveltekit()],
	resolve: {
		// tiptap-phoenix is a file: dep symlinked into deps/tiptap_phoenix; its
		// imports resolve from the symlink's real path, where no node_modules
		// exists on CI (and locally a nested node_modules would yield a second
		// @tiptap/core instance). Force every shared package to the frontend copy.
		dedupe: [
			'@tiptap/core',
			'@tiptap/pm',
			'@tiptap/starter-kit',
			'@tiptap/suggestion',
			'@tiptap/extension-code-block-lowlight',
			'@tiptap/extension-details',
			'@tiptap/extension-details-content',
			'@tiptap/extension-details-summary',
			'@tiptap/extension-image',
			'@tiptap/extension-link',
			'@tiptap/extension-placeholder',
			'@tiptap/extension-table',
			'@tiptap/extension-table-cell',
			'@tiptap/extension-table-header',
			'@tiptap/extension-table-row',
			'@tiptap/extension-task-item',
			'@tiptap/extension-task-list',
			'@tiptap/extension-typography',
			'@tiptap/extension-underline',
			'lowlight',
			'tippy.js'
		]
	},
	server: {
		// Dev: SvelteKit on :5173, Phoenix on :4000. Same-origin in production.
		proxy: {
			'/rpc': 'http://localhost:4000',
			'/api': 'http://localhost:4000',
			'/uploads': 'http://localhost:4000',
			'/fonts': 'http://localhost:4000',
			'/socket': {
				target: 'ws://localhost:4000',
				ws: true
			}
		}
	},
	test: {
		include: ['src/**/*.{test,spec}.{js,ts}'],
		environment: 'node'
	}
});
