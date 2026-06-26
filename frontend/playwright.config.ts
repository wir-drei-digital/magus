import { defineConfig } from '@playwright/test';

// Smoke suite: builds the SPA and serves it with `vite preview` — no Phoenix
// backend, so tests cover client rendering and the unauthenticated path.
// Full-stack scenarios (streaming, reconnect, suspend/resume) run against a
// real backend from iteration 2 on.
export default defineConfig({
	testDir: 'tests',
	timeout: 30_000,
	use: {
		baseURL: 'http://localhost:4173'
	},
	webServer: {
		command: 'npm run build && npm run preview',
		port: 4173,
		reuseExistingServer: !process.env.CI
	}
});
