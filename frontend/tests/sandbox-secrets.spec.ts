import { expect, test, type Page } from '@playwright/test';

// Sandbox-secrets settings page E2E: mirrors skills.spec.ts. The SPA is served
// by `vite preview` with no Phoenix backend, so RPC is mocked at the network
// level (POST /rpc/run, action names snake_case). Structural assertions only
// (data-testid + counts); the secret VALUE is write-only and is never returned
// by the server, so it never appears in any mocked response or in the DOM.

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: { tabs_enabled: true }
};

const tabSession = {
	id: 't0000000-0000-0000-0000-000000000001',
	mode: 'library',
	navFilter: 'all',
	tabs: [] as { id: string; primary: { type: string; id: string } }[],
	activeTabId: null as string | null
};

// A seeded secret KEY (no value; the list projection exposes id/key/description/insertedAt).
const seededSecret = {
	id: 'k0000000-0000-0000-0000-000000000001',
	key: 'DEEPL_API_KEY',
	description: null as string | null,
	insertedAt: '2026-07-04T00:00:00Z'
};

async function mockRpc(
	page: Page,
	options: {
		authenticated: boolean;
		respond?: Record<string, (input: Record<string, unknown>) => unknown>;
	}
) {
	const sessionState = { ...tabSession };

	await Promise.all([
		page.route('**/rpc/run', async (route) => {
			if (!options.authenticated) {
				return route.fulfill({ status: 401, json: { error: 'Authentication required' } });
			}

			const body = route.request().postDataJSON() as {
				action: string;
				input?: Record<string, unknown>;
			};
			const respond = (data: unknown) => route.fulfill({ json: { success: true, data } });

			const override = options.respond?.[body.action];
			if (override) return respond(override(body.input ?? {}));

			switch (body.action) {
				case 'current_user':
				case 'update_ui_preferences':
					return respond(user);
				case 'get_or_create_tab_session':
					return respond({ ...sessionState });
				case 'my_sandbox_secrets':
					return respond([seededSecret]);
				// Shell chrome loaded alongside every route; default them to empty.
				case 'my_conversations':
				case 'personal_conversations':
				case 'my_folder_states':
				case 'unread_notifications':
				case 'my_workspaces':
				case 'list_active_models':
				case 'my_agents':
					return respond([]);
				case 'credit_status':
					return respond({ exempt: false, credits_used: 0, credits_limit: 50, percentage: 0 });
				case 'money_usage_status':
					return respond({
						exempt: false,
						trial: false,
						delinquent: false,
						spent_cents: 0,
						cap_cents: 5000,
						tokens_used: 0
					});
				default:
					return respond(null);
			}
		}),
		page.route('**/rpc/socket-token', (route) =>
			route.fulfill({ status: options.authenticated ? 200 : 401, json: { token: 'test' } })
		)
	]);
}

test('lists secret keys and offers add', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/settings/sandbox-secrets');

	// The page renders and the seeded key is listed (never its value).
	await expect(page.getByTestId('sandbox-secrets-page')).toBeVisible();
	await expect(page.getByTestId('secret-list')).toContainText('DEEPL_API_KEY');
	await expect(page.getByTestId('secret-add')).toBeVisible();
});

test('add form clears the value input after a successful create', async ({ page }) => {
	const created = {
		id: 'k0000000-0000-0000-0000-000000000002',
		key: 'OPENAI_API_KEY',
		description: null as string | null,
		insertedAt: '2026-07-04T01:00:00Z'
	};

	await mockRpc(page, {
		authenticated: true,
		respond: {
			// create_sandbox_secret returns the write-only projection (no value).
			create_sandbox_secret: () => created
		}
	});

	await page.goto('/settings/sandbox-secrets');
	await expect(page.getByTestId('sandbox-secrets-page')).toBeVisible();

	await page.getByTestId('secret-key').fill('OPENAI_API_KEY');
	await page.getByTestId('secret-value').fill('sk-super-secret');
	await page.getByTestId('secret-add').click();

	// The new key joins the list.
	await expect(page.getByTestId('secret-list')).toContainText('OPENAI_API_KEY');

	// The value input is cleared so the plaintext does not linger in the DOM.
	await expect(page.getByTestId('secret-value')).toHaveValue('');
	await expect(page.getByTestId('secret-key')).toHaveValue('');
});
