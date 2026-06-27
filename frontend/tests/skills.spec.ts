import { expect, test, type Page } from '@playwright/test';

// Skills E2E suite: mirrors smoke.spec.ts in structure. The SPA is served by
// `vite preview` with no Phoenix backend; RPC and the multipart import
// endpoint are mocked at the network level.

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: { tabs_enabled: true }
};

const tabSession = {
	id: 't0000000-0000-0000-0000-000000000001',
	mode: 'skills',
	navFilter: 'all',
	tabs: [] as { id: string; primary: { type: string; id: string } }[],
	activeTabId: null as string | null
};

const conversations = [
	{
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
	}
];

// Two representative skills used across tests.
const bundledSkill = {
	id: 'skill-bundle-0000-0000-0000-000000000001',
	name: 'bash-runner',
	displayName: 'Bash Runner',
	description: 'Runs bash scripts in a sandbox',
	hasExecutableBundle: true,
	requestedTools: ['bash'],
	version: '1.0.0',
	workspaceId: null,
	isSharedToWorkspace: false,
	updatedAt: '2026-06-11T10:00:00Z'
};

const promptSkill = {
	id: 'skill-prompt-0000-0000-0000-000000000002',
	name: 'code-review',
	displayName: 'Code Review',
	description: 'Reviews code for quality and correctness',
	hasExecutableBundle: false,
	requestedTools: [],
	version: '0.1.0',
	workspaceId: null,
	isSharedToWorkspace: false,
	updatedAt: '2026-06-10T10:00:00Z'
};

const skillDetail = {
	...bundledSkill,
	body: '## Bash Runner\n\nRuns bash commands safely inside a sandbox.',
	license: 'MIT',
	sourceUrl: null,
	compatibility: null,
	fileManifest: [{ path: 'scripts/run.sh', size: 1024, sha256: 'abc123', executable: true }]
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
				case 'open_workbench_tab': {
					const input = (body.input ?? {}) as {
						primary?: { type: string; id: string };
						single?: boolean;
					};
					const primary = input.primary ?? { type: 'conversation', id: 'none' };
					const tab = { id: 'tab-1', primary };
					sessionState.tabs = input.single === true ? [tab] : [tab];
					sessionState.activeTabId = tab.id;
					return respond({ ...sessionState });
				}
				case 'replace_workbench_tabs':
				case 'activate_workbench_tab':
					return respond({ ...sessionState });
				case 'set_tab_session_mode':
					sessionState.mode = (body.input as { mode?: string })?.mode ?? 'skills';
					return respond({ ...sessionState });
				case 'my_conversations':
				case 'personal_conversations':
					return respond(conversations);
				case 'conversation_history':
					return respond({
						results: conversations.map((c) => ({ ...c, messageCount: 0 })),
						hasMore: false,
						limit: 25,
						offset: 0
					});
				case 'trashed_conversations':
					return respond([]);
				case 'my_folder_states':
				case 'unread_notifications':
				case 'my_knowledge_collections':
				case 'workspace_knowledge_collections':
					return respond([]);
				case 'merged_slash_commands':
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
				case 'my_workspaces':
					return respond([]);
				case 'list_active_models':
					return respond([]);
				case 'my_agents':
					return respond([]);
				case 'my_prompts':
				case 'my_favorite_prompts':
				case 'my_prompt_favorites':
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
				case 'my_skills':
					return respond([bundledSkill, promptSkill]);
				case 'get_skill':
					return respond(skillDetail);
				case 'send_user_message': {
					const input = (body.input ?? {}) as { text?: string; conversationId?: string };
					return respond({
						id: 'm-new',
						text: input.text ?? '',
						source: 'user',
						role: 'user',
						messageType: 'message',
						status: 'complete',
						insertedAt: '2026-06-11T10:02:00Z',
						modelName: null,
						toolCallData: null,
						citations: null,
						reasoningSummary: null
					});
				}
				default:
					return respond(null);
			}
		}),
		page.route('**/rpc/socket-token', (route) =>
			route.fulfill({ status: options.authenticated ? 200 : 401, json: { token: 'test' } })
		)
	]);
}

test('browse + open: skills-nav and gallery render; clicking a card loads the detail', async ({
	page
}) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/next/skills');

	await expect(page.getByTestId('skills-nav')).toBeVisible();
	await expect(page.getByTestId('skill-gallery')).toBeVisible();

	// Both skill cards are rendered.
	const cards = page.getByTestId('skill-card');
	await expect(cards).toHaveCount(2);

	// Click the first card (Bash Runner, bundled) to open the detail.
	await cards.first().click();

	// Detail pane loads and shows the title.
	await expect(page.getByTestId('skill-title')).toBeVisible();
	await expect(page.getByTestId('skill-title')).toHaveText('Bash Runner');
});

test('runnable badge: bundled skill card shows sandbox chip; prompt-only does not', async ({
	page
}) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/next/skills');

	const cards = page.getByTestId('skill-card');
	await expect(cards).toHaveCount(2);

	// Select each card by its display name rather than relying on sort order.
	const bundledCard = cards.filter({ hasText: 'Bash Runner' });
	const promptOnlyCard = cards.filter({ hasText: 'Code Review' });

	// Bundled card shows the "sandbox" chip (exact text on the badge span, not
	// the description which contains "sandbox" as a substring).
	await expect(bundledCard.getByText('sandbox', { exact: true })).toBeVisible();

	// Prompt-only card does NOT show the "sandbox" chip.
	await expect(promptOnlyCard.getByText('sandbox', { exact: true })).toHaveCount(0);
});

test('import: opening dialog, setting a file, and submitting navigates to the new skill', async ({
	page
}) => {
	const importedSkillId = 'skill-imported-0000-0000-0000-000000000099';
	const importedSkillDetail = {
		...promptSkill,
		id: importedSkillId,
		name: 'imported-skill',
		displayName: 'Imported Skill',
		description: 'Imported from bundle',
		body: '## Imported',
		hasExecutableBundle: true,
		fileManifest: [] as Record<string, unknown>[],
		license: null,
		sourceUrl: null,
		compatibility: null
	};

	// Seed an empty gallery so the empty-state "Import skill" button is visible.
	// get_skill always returns the imported detail (the only call that happens
	// after import navigates to /skills/<importedSkillId>).
	await mockRpc(page, {
		authenticated: true,
		respond: {
			my_skills: () => [],
			get_skill: () => importedSkillDetail
		}
	});

	// Mock the multipart import endpoint (mirrors how smoke.spec.ts mocks /rpc/upload).
	await page.route('**/rpc/skills/import', (route) =>
		route.fulfill({
			json: { success: true, data: { id: importedSkillId, name: 'imported-skill' } }
		})
	);

	await page.goto('/next/skills');

	// Empty state is visible: click the import button to open the dialog.
	await page.getByTestId('import-skill-empty').click();
	await expect(page.getByTestId('skill-import-dialog')).toBeVisible();

	// Set a small in-memory zip file on the file input.
	const zipBuffer = Buffer.from('PK\x05\x06' + '\x00'.repeat(18)); // minimal valid zip stub
	await page.getByTestId('skill-import-file').setInputFiles({
		name: 'my-skill.zip',
		mimeType: 'application/zip',
		buffer: zipBuffer
	});

	// Submit the import.
	await page.getByTestId('skill-import-submit').click();

	// After import the dialog closes and the app navigates to the imported skill.
	await expect(page).toHaveURL(new RegExp(`/skills/${importedSkillId}$`));
	await expect(page.getByTestId('skill-title')).toHaveText('Imported Skill');
});

test('create: filling the new-skill form and submitting navigates to the created skill', async ({
	page
}) => {
	const createdSkillId = 'skill-created-0000-0000-0000-000000000088';
	const createdSkillDetail = {
		...promptSkill,
		id: createdSkillId,
		name: 'my-new-skill',
		displayName: 'My New Skill',
		description: 'A brand-new skill',
		body: '## My New Skill\n\nDoes great things.',
		hasExecutableBundle: false,
		fileManifest: null,
		license: null,
		sourceUrl: null,
		compatibility: null
	};

	await mockRpc(page, {
		authenticated: true,
		respond: {
			create_skill: () => createdSkillDetail,
			get_skill: () => createdSkillDetail
		}
	});

	await page.goto('/next/skills/new');

	// The create form is immediately in edit mode for /new.
	await expect(page.getByTestId('skill-name-input')).toBeVisible();

	// Fill in the required fields.
	await page.getByTestId('skill-name-input').fill('my-new-skill');

	// Fill description — locate by placeholder since Field label wraps it without testid.
	await page.locator('input[placeholder="What this skill does"]').fill('A brand-new skill');

	// Fill the body textarea.
	await page.getByTestId('skill-body-input').fill('## My New Skill\n\nDoes great things.');

	// Click save.
	await page.getByTestId('skill-save').click();

	// After creation the app navigates to the created skill.
	await expect(page).toHaveURL(new RegExp(`/skills/${createdSkillId}$`));
	await expect(page.getByTestId('skill-title')).toHaveText('My New Skill');
});

test('approval card: notification bell shows card; Approve sends the phrase via send_user_message', async ({
	page
}) => {
	const approvePhrase = 'Approve skill: skill-bundle-0000-0000-0000-000000000001';
	const targetConversationId = conversations[0].id;

	let sendUserMessageText: string | null = null;

	await mockRpc(page, {
		authenticated: true,
		respond: {
			unread_notifications: () => [
				{
					id: 'notif-approval-1',
					title: 'Skill approval requested',
					body: 'An agent wants to install Bash Runner.',
					notificationType: 'approval_request',
					targetConversationId,
					metadata: {
						approve_phrase: approvePhrase
					},
					insertedAt: '2026-06-11T10:00:00Z'
				}
			],
			send_user_message: (input) => {
				sendUserMessageText = (input as { text?: string }).text ?? null;
				return {
					id: 'm-approval',
					text: sendUserMessageText ?? '',
					source: 'user',
					role: 'user',
					messageType: 'message',
					status: 'complete',
					insertedAt: '2026-06-11T10:02:00Z',
					modelName: null,
					toolCallData: null,
					citations: null,
					reasoningSummary: null
				};
			},
			mark_notification_read: () => ({
				id: 'notif-approval-1',
				title: 'Skill approval requested',
				body: null,
				notificationType: 'approval_request',
				targetConversationId,
				metadata: {},
				insertedAt: '2026-06-11T10:00:00Z'
			})
		}
	});

	await page.goto('/next/skills');

	// The notification badge shows count 1.
	await expect(page.getByTestId('notification-badge')).toHaveText('1');

	// Open the notification bell.
	await page.getByTestId('notification-bell').click();
	await expect(page.getByTestId('notification-feed')).toBeVisible();

	// The approval card is rendered.
	await expect(page.getByTestId('approval-card')).toBeVisible();

	// Click "Approve" — this calls send_user_message with the approve phrase.
	await page.getByTestId('approval-approve').click();

	// The send_user_message RPC must have been called with the exact phrase.
	await expect
		.poll(() => sendUserMessageText, {
			message: 'expected send_user_message to be called with the approve phrase'
		})
		.toBe(approvePhrase);

	// After approval the card is removed (notification marked read) and the
	// app navigates to the target conversation.
	await expect(page).toHaveURL(new RegExp(`/chat/${targetConversationId}$`));
});
