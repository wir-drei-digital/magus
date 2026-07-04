import { expect, test, type Page } from '@playwright/test';

// Slash-menu skills suite: mirrors smoke.spec.ts / skills.spec.ts. The SPA is
// served by `vite preview` with no Phoenix backend, so RPC is mocked at the
// network level. The user's skills surface in the composer's plus menu as
// slash rows; runnable (bundled) skills carry a "sandbox" badge.

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: { tabs_enabled: true }
};

const conversation = {
	id: 'c0000000-0000-0000-0000-000000000001',
	title: 'Quarterly planning',
	chatMode: 'chat',
	updatedAt: '2026-06-11T10:00:00Z',
	workspaceId: null,
	customAgentId: null,
	folderId: null,
	isFavorited: false,
	isSharedToWorkspace: false,
	lastMessageAt: '2026-06-11T10:00:00Z'
};

const tabSession = {
	id: 't0000000-0000-0000-0000-000000000001',
	mode: 'chat',
	navFilter: 'all',
	tabs: [] as { id: string; primary: { type: string; id: string } }[],
	activeTabId: null as string | null
};

// One bundled skill (runnable → sandbox badge) and one prompt-only skill.
const bundledSkill = {
	id: 'skill-bundle-0000-0000-0000-000000000001',
	name: 'bash-runner',
	displayName: 'Bash Runner',
	description: 'Runs bash scripts in a sandbox',
	requestedTools: ['bash'],
	version: '1.0.0',
	license: 'MIT',
	sourceFormat: 'skill_md',
	hasExecutableBundle: true,
	isSharedToWorkspace: false,
	workspaceId: null,
	isFavorited: false,
	body: '## Bash Runner'
};

const promptSkill = {
	id: 'skill-prompt-0000-0000-0000-000000000002',
	name: 'code-review',
	displayName: 'Code Review',
	description: 'Reviews code for quality',
	requestedTools: [],
	version: '0.1.0',
	license: null,
	sourceFormat: 'skill_md',
	hasExecutableBundle: false,
	isSharedToWorkspace: false,
	workspaceId: null,
	isFavorited: false,
	body: '## Code Review'
};

async function mockRpc(
	page: Page,
	options: {
		respond?: Record<string, (input: Record<string, unknown>) => unknown>;
	} = {}
) {
	const sessionState = { ...tabSession };

	await Promise.all([
		page.route('**/rpc/run', async (route) => {
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
				case 'open_workbench_tab': {
					const input = (body.input ?? {}) as { primary?: { type: string; id: string } };
					const primary = input.primary ?? { type: 'conversation', id: conversation.id };
					const tab = { id: 'tab-1', primary };
					sessionState.tabs = [tab];
					sessionState.activeTabId = tab.id;
					return respond({ ...sessionState });
				}
				case 'replace_workbench_tabs':
				case 'activate_workbench_tab':
					return respond({ ...sessionState });
				case 'set_tab_session_mode':
					sessionState.mode = (body.input as { mode?: string })?.mode ?? 'chat';
					return respond({ ...sessionState });
				case 'my_conversations':
				case 'personal_conversations':
					return respond([conversation]);
				case 'conversation_history':
					return respond({
						results: [{ ...conversation, messageCount: 0 }],
						hasMore: false,
						limit: 25,
						offset: 0
					});
				case 'get_conversation':
					return respond({
						...conversation,
						systemPrompt: null,
						samplingSettings: null,
						activeSystemPrompt: null
					});
				case 'message_history':
					return respond({ results: [], hasMore: false });
				case 'merged_slash_commands':
					return respond([{ name: 'web-search', title: 'Search the web', icon: 'lucide-globe' }]);
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
				case 'list_active_models':
					return respond([]);
				case 'my_skills':
					return respond([bundledSkill, promptSkill]);
				case 'trashed_conversations':
				case 'my_folder_states':
				case 'unread_notifications':
				case 'my_knowledge_collections':
				case 'workspace_knowledge_collections':
				case 'my_workspaces':
				case 'my_agents':
				case 'my_prompts':
				case 'my_favorite_prompts':
				case 'my_prompt_favorites':
				case 'my_favorite_skills':
				case 'my_skill_favorites':
				case 'list_tags':
				case 'workspace_agents':
				case 'agent_activity':
				case 'agent_inbox_events':
				case 'agent_secrets':
				case 'my_brains':
				case 'root_brain_pages':
				case 'brain_page_children':
				case 'trashed_brain_pages':
				case 'list_page_backlinks':
				case 'my_folders':
				case 'my_library_files':
				case 'recent_files':
				case 'template_files':
				case 'trash_files':
				case 'folder_files':
				case 'folder_children':
				case 'messages_since':
				case 'conversation_threads':
				case 'conversation_drafts':
				case 'conversation_files':
				case 'conversation_jobs':
					return respond([]);
				default:
					return respond(null);
			}
		}),
		page.route('**/rpc/socket-token', (route) =>
			route.fulfill({ status: 200, json: { token: 'test' } })
		)
	]);
}

test('the composer plus menu lists a user skill with a sandbox badge', async ({ page }) => {
	await mockRpc(page);
	await page.goto(`/chat/${conversation.id}`);

	// Open the plus menu, mirroring smoke.spec.ts's slash-command test.
	await page.getByTestId('composer-actions').click();

	const commands = page.getByTestId('composer-slash-command');
	// One global command (web-search) plus two user skills.
	await expect(commands).toHaveCount(3);

	// The bundled skill row is present and carries the sandbox badge.
	const bundledRow = commands.filter({ hasText: 'Bash Runner' });
	await expect(bundledRow).toHaveCount(1);
	await expect(bundledRow.getByTestId('slash-sandbox-badge')).toBeVisible();

	// The prompt-only skill row is present without a sandbox badge.
	const promptRow = commands.filter({ hasText: 'Code Review' });
	await expect(promptRow).toHaveCount(1);
	await expect(promptRow.getByTestId('slash-sandbox-badge')).toHaveCount(0);

	// Exactly one row across the menu carries the badge.
	await expect(page.getByTestId('slash-sandbox-badge')).toHaveCount(1);
});

test('clicking a skill row injects its /name into the composer', async ({ page }) => {
	await mockRpc(page);
	await page.goto(`/chat/${conversation.id}`);

	await page.getByTestId('composer-actions').click();
	const bundledRow = page.getByTestId('composer-slash-command').filter({ hasText: 'Bash Runner' });
	await bundledRow.click();

	await expect(page.getByTestId('composer-input')).toHaveValue('/bash-runner ');
});
