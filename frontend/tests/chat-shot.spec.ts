import { test, type Page } from '@playwright/test';

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: {}
};

const convId = 'c0000000-0000-0000-0000-000000000002';

const history = [
	{
		id: 'm-2',
		text: 'It prevents **data races** at compile time.',
		source: 'agent',
		role: 'agent',
		messageType: 'message',
		status: 'complete',
		insertedAt: '2026-06-11T10:01:00Z',
		modelName: 'grok-4.1-fast',
		toolCallData: null,
		citations: null,
		reasoningSummary: null
	},
	{
		id: 'm-1',
		text: 'Why does Rust have a borrow checker?',
		source: 'user',
		role: 'user',
		messageType: 'message',
		status: 'complete',
		insertedAt: '2026-06-11T10:00:00Z',
		modelName: null,
		toolCallData: null,
		citations: null,
		reasoningSummary: null
	}
];

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
						id: 't1',
						mode: 'chat',
						navFilter: 'all',
						tabs: [{ id: 'tab-1', primary: { type: 'conversation', id: convId } }],
						activeTabId: 'tab-1'
					});
				case 'open_workbench_tab':
				case 'activate_workbench_tab':
					return respond({
						id: 't1',
						mode: 'chat',
						navFilter: 'all',
						tabs: [{ id: 'tab-1', primary: { type: 'conversation', id: convId } }],
						activeTabId: 'tab-1'
					});
				case 'my_conversations':
					return respond([
						{
							id: convId,
							title: 'Rust borrow checker',
							chatMode: 'chat',
							updatedAt: '2026-06-11T10:00:00Z',
							workspaceId: null,
							customAgentId: null
						}
					]);
				case 'my_workspaces':
					return respond([]);
				case 'message_history':
					return respond({ results: history, hasMore: false });
				case 'messages_since':
					return respond([]);
				case 'list_active_models':
					return respond([
						{
							id: 'model-1',
							name: 'grok-4.1-fast',
							supportsSearch: true,
							supportsReasoning: true,
							supportsTools: true,
							costMultiplier: '1.0'
						}
					]);
				case 'my_agents':
					return respond([]);
				default:
					return respond(null);
			}
		}),
		page.route('**/rpc/socket-token', (route) => route.fulfill({ json: { token: 'test' } }))
	]);
}

for (const theme of ['light', 'dark'] as const) {
	test(`chat view screenshot (${theme})`, async ({ page }) => {
		await mockRpc(page);
		await page.addInitScript((t) => localStorage.setItem('phx:theme', t), theme);
		await page.goto(`/chat/${convId}`);
		await page.getByTestId('message-list').waitFor();
		await page.waitForTimeout(400);
		await page.screenshot({ path: `test-results/chat-${theme}.png`, fullPage: true });
	});
}
