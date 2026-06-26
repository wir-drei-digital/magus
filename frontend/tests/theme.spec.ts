import { expect, test, type Page } from '@playwright/test';

// Theme contract: the SPA reads the classic UI's `phx:theme` localStorage key
// ("dark" | "light" | absent = system) and toggles the `.dark` class. These
// tests assert the switch actually restyles the shell and drop screenshots
// into test-results/ for visual comparison against the LiveView workbench.

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: {}
};

function mockRpc(page: Page) {
	return Promise.all([
		page.route('**/rpc/run', async (route) => {
			const body = route.request().postDataJSON() as { action: string };
			const respond = (data: unknown) => route.fulfill({ json: { success: true, data } });

			switch (body.action) {
				case 'current_user':
					return respond(user);
				case 'get_or_create_tab_session':
					return respond({
						id: 't0000000-0000-0000-0000-000000000001',
						mode: 'chat',
						navFilter: 'all',
						tabs: [],
						activeTabId: null
					});
				case 'my_conversations':
					return respond([
						{
							id: 'c0000000-0000-0000-0000-000000000001',
							title: 'Quarterly planning',
							chatMode: 'chat',
							updatedAt: '2026-06-11T10:00:00Z',
							workspaceId: null,
							customAgentId: null
						}
					]);
				case 'my_workspaces':
					return respond([]);
				default:
					return respond(null);
			}
		}),
		page.route('**/rpc/socket-token', (route) => route.fulfill({ json: { token: 'test' } }))
	]);
}

async function backgroundColor(page: Page): Promise<string> {
	return page.evaluate(() => getComputedStyle(document.body).backgroundColor);
}

test('phx:theme localStorage key drives dark/light, in sync with the classic UI', async ({
	page
}) => {
	await mockRpc(page);

	await page.addInitScript(() => localStorage.setItem('phx:theme', 'light'));
	await page.goto('/next/chat');
	await expect(page.getByTestId('mode-strip')).toBeVisible();

	const lightBg = await backgroundColor(page);
	await expect(page.locator('html')).not.toHaveClass(/dark/);
	// Let transition-colors settle so screenshots show steady state.
	await page.waitForTimeout(300);
	await page.screenshot({ path: 'test-results/theme-light.png', fullPage: true });

	// Simulate the classic UI switching theme in another tab: same key, the
	// storage event re-applies without a reload.
	await page.evaluate(() => {
		localStorage.setItem('phx:theme', 'dark');
		window.dispatchEvent(new StorageEvent('storage', { key: 'phx:theme', newValue: 'dark' }));
	});

	await expect(page.locator('html')).toHaveClass(/dark/);
	const darkBg = await backgroundColor(page);
	expect(darkBg).not.toBe(lightBg);
	await page.waitForTimeout(300);
	await page.screenshot({ path: 'test-results/theme-dark.png', fullPage: true });
});

test('without a stored theme the system preference applies', async ({ page }) => {
	await mockRpc(page);
	await page.emulateMedia({ colorScheme: 'dark' });
	await page.goto('/next/chat');

	await expect(page.locator('html')).toHaveClass(/dark/);
});
