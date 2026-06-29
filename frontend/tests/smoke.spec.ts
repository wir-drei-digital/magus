import { expect, test, type Page } from '@playwright/test';

// vite preview serves only the static SPA; RPC endpoints are mocked at the
// network level so both auth states are covered deterministically. With no
// socket behind the preview server, these tests also cover the degraded
// (offline) rendering path. Full-stack E2E runs against a real Phoenix.

// tabs_enabled mirrors the classic opt-in preference; the suite's shell
// tests exercise the tabbed layout, so the shared fixture turns it on. The
// disabled (default) path has its own test below.
const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: { tabs_enabled: true }
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
	},
	{
		id: 'c0000000-0000-0000-0000-000000000002',
		title: 'Rust borrow checker',
		chatMode: 'chat',
		updatedAt: '2026-06-10T10:00:00Z',
		workspaceId: null,
		customAgentId: null,
		folderId: null,
		isFavorited: false,
		isSharedToWorkspace: false,
		lastMessageAt: '2026-06-10T10:00:00Z'
	}
];

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

const tabSession = {
	id: 't0000000-0000-0000-0000-000000000001',
	mode: 'chat',
	navFilter: 'all',
	tabs: [],
	activeTabId: null
};

async function mockRpc(
	page: Page,
	options: {
		authenticated: boolean;
		/** Per-action overrides, checked before the defaults below. */
		respond?: Record<string, (input: Record<string, unknown>) => unknown>;
		/** Seed the mutable TabSession state (e.g. a stale multi-tab session). */
		initialTabs?: { id: string; primary: { type: string; id: string } }[];
		initialActiveTabId?: string | null;
	}
) {
	// Mutable TabSession state: every tab-session response returns the full
	// current state, like the real backend — a static fixture here previously
	// made set_tab_session_mode drop the tabs, retriggering the deep-link
	// openTab effect whose response reverted the mode (CI-only flake).
	const sessionState = {
		...tabSession,
		tabs: (options.initialTabs ?? []) as { id: string; primary: { type: string; id: string } }[],
		activeTabId: (options.initialActiveTabId ?? null) as string | null
	};

	// Inputs of replace_workbench_tabs calls — the tabs-disabled trim path.
	const replaceTabsCalls: Array<Record<string, unknown>> = [];

	// Client-side placeholder tab ids must never reach the server: the real
	// backend rejects them, and the resulting rollback once sustained an
	// endless activate_workbench_tab loop. Recorded here, asserted empty.
	const optimisticTabIdCalls: string[] = [];

	// Inputs of open_workbench_tab calls — the tabs-disabled path opens with
	// single:true (open-and-trim) rather than a follow-up replace_workbench_tabs.
	const openTabCalls: Array<Record<string, unknown>> = [];

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

			const tabIdInput = body.input?.tabId;
			if (typeof tabIdInput === 'string' && tabIdInput.startsWith('optimistic-')) {
				optimisticTabIdCalls.push(`${body.action}:${tabIdInput}`);
			}

			const override = options.respond?.[body.action];
			if (override) return respond(override(body.input ?? {}));

			switch (body.action) {
				case 'current_user':
				case 'update_ui_preferences':
					return respond(user);
				case 'get_or_create_tab_session':
					return respond({ ...sessionState });
				case 'open_workbench_tab': {
					// Append-or-focus, like the real OpenTab change. With single:true
					// (tabs disabled) it open-and-trims to just this tab, mirroring the
					// server's maybe_trim_to_active_tab.
					const input = (body.input ?? {}) as {
						primary?: { type: string; id: string };
						single?: boolean;
					};
					openTabCalls.push({ ...input });
					const primary = input.primary ?? { type: 'conversation', id: conversations[1].id };
					const found = sessionState.tabs.find(
						(tab) => tab.primary.type === primary.type && tab.primary.id === primary.id
					);
					const tab = found ?? { id: `tab-${sessionState.tabs.length + 1}`, primary };
					if (input.single === true) sessionState.tabs = [tab];
					else if (!found) sessionState.tabs = [...sessionState.tabs, tab];
					sessionState.activeTabId = tab.id;
					return respond({ ...sessionState });
				}
				case 'replace_workbench_tabs': {
					const input = body.input as {
						tabs?: { id: string; primary: { type: string; id: string } }[];
						activeTabId?: string | null;
					};
					replaceTabsCalls.push({ ...input });
					sessionState.tabs = input.tabs ?? [];
					sessionState.activeTabId = input.activeTabId ?? null;
					return respond({ ...sessionState });
				}
				case 'activate_workbench_tab': {
					// Faithful to ActivateTab: unknown ids are an error response.
					const tabId = typeof tabIdInput === 'string' ? tabIdInput : null;
					if (!tabId || !sessionState.tabs.some((tab) => tab.id === tabId)) {
						return route.fulfill({
							json: { success: false, errors: [{ message: `no open tab with id ${tabId}` }] }
						});
					}
					sessionState.activeTabId = tabId;
					return respond({ ...sessionState });
				}
				case 'my_conversations':
				case 'personal_conversations':
					return respond(conversations);
				case 'conversation_history':
					return respond({
						results: conversations.map((entry) => ({ ...entry, messageCount: 2 })),
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
					return respond([
						{ name: 'web-search', title: 'Search the web', icon: 'lucide-globe' },
						{ name: 'draft', title: 'Create a draft', icon: 'lucide-file-text' }
					]);
				case 'credit_status':
					return respond({ exempt: false, credits_used: 2, credits_limit: 50, percentage: 4.0 });
				case 'money_usage_status':
					return respond({
						exempt: false,
						trial: false,
						delinquent: false,
						spent_cents: 1234,
						cap_cents: 5000,
						tokens_used: 8200
					});
				case 'get_conversation':
					return respond({
						...conversations[1],
						systemPrompt: null,
						samplingSettings: null,
						activeSystemPrompt: null
					});
				case 'my_workspaces':
					return respond([]);
				case 'message_history':
					return respond({ results: history, hasMore: false });
				case 'messages_since':
				case 'conversation_threads':
				case 'conversation_drafts':
				case 'conversation_files':
				case 'conversation_jobs':
				case 'my_library_files':
				case 'my_folders':
				case 'recent_files':
				case 'template_files':
				case 'trash_files':
				case 'folder_files':
				case 'folder_children':
					return respond([]);
				case 'set_tab_session_mode':
					sessionState.mode = (body.input as { mode?: string })?.mode ?? 'chat';
					return respond({ ...sessionState });
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
					return respond([
						{
							id: 'agent-1',
							name: 'Researcher',
							handle: 'researcher',
							icon: null,
							description: 'Digs into things',
							isDefault: false,
							workspaceId: null,
							isSharedToWorkspace: false,
							isPaused: false,
							updatedAt: '2026-06-11T09:00:00Z'
						}
					]);
				case 'send_user_message': {
					const input = (route.request().postDataJSON() as { input: { text: string } }).input;
					return respond({
						id: 'm-3',
						text: input.text,
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

	return { optimisticTabIdCalls, replaceTabsCalls, openTabCalls };
}

test('unauthenticated users get the sign-in state', async ({ page }) => {
	await mockRpc(page, { authenticated: false });
	await page.goto('/');

	await expect(page.getByText("You're not signed in.")).toBeVisible();
	await expect(page.getByRole('button', { name: 'Sign in' })).toBeVisible();
});

test('authenticated users see the workbench shell with their conversations', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/');

	// Index redirects into chat mode with the shell chrome.
	await expect(page).toHaveURL(/\/chat$/);
	await expect(page.getByTestId('mode-strip')).toBeVisible();
	await expect(page.getByTestId('conversation-list')).toBeVisible();
	await expect(page.getByText('Quarterly planning')).toBeVisible();
	await expect(page.getByTestId('connection-status')).toBeVisible();
});

test('switching modes swaps the nav but keeps the open view', async ({ page }) => {
	const rpc = await mockRpc(page, { authenticated: true });
	await page.goto(`/chat/${conversations[1].id}`);
	await expect(page.getByTestId('message-list')).toBeVisible();
	// The conversation list only renders client-side after the session load,
	// so waiting for it guarantees hydration finished before the click (CI
	// runners are slow enough to otherwise lose the event).
	await expect(page.getByTestId('conversation-list')).toBeVisible();

	await page.getByTestId('mode-files').click();
	await expect(page.getByTestId('files-nav')).toBeVisible();

	// The open conversation stays in the center pane; only the nav changed.
	await expect(page.getByTestId('message-list')).toBeVisible();
	await expect(page).toHaveURL(new RegExp(`/chat/${conversations[1].id}$`));

	// Switching back restores the chat nav without touching the view.
	await page.getByTestId('mode-chat').click();
	await expect(page.getByTestId('nav-search')).toBeVisible();
	await expect(page.getByTestId('message-list')).toBeVisible();

	// The deep-link open/activate round trips must never leak a client-side
	// optimistic tab id to the server (regression: endless activate loop).
	expect(rpc.optimisticTabIdCalls).toEqual([]);
});

test('the rail footer shows the notification bell and credit indicator', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			unread_notifications: () => [
				{
					id: 'n-1',
					title: 'Research finished',
					body: 'The agent completed your task.',
					notificationType: 'task_completed',
					targetConversationId: conversations[0].id,
					metadata: {},
					insertedAt: '2026-06-11T10:00:00Z'
				},
				{
					id: 'n-2',
					title: null,
					body: null,
					notificationType: 'mention',
					targetConversationId: conversations[0].id,
					metadata: {},
					insertedAt: '2026-06-11T09:00:00Z'
				}
			]
		}
	});
	await page.goto('/chat');

	// Bell badge counts both unread rows; the popover groups them (+1 more).
	await expect(page.getByTestId('notification-badge')).toHaveText('2');
	await page.getByTestId('notification-bell').click();
	await expect(page.getByTestId('notification-feed')).toBeVisible();
	await expect(page.getByText('Research finished')).toBeVisible();
	await expect(page.getByText('+1 more')).toBeVisible();

	// Mark all as read empties the feed and clears the badge.
	await page.getByTestId('mark-all-read').click();
	await expect(page.getByText('No unread notifications')).toBeVisible();
	await expect(page.getByTestId('notification-badge')).not.toBeVisible();

	// Credit indicator renders bars and opens the usage popover.
	await page.keyboard.press('Escape');
	await page.getByTestId('credit-indicator').click();
	// PAYG money panel: the spent line is present and currency-formatted.
	await expect(page.getByTestId('usage-spent')).toContainText('CHF');
});

test('the chat nav renders a folder tree with date-grouped conversations', async ({ page }) => {
	const folder = {
		id: 'f0000000-0000-0000-0000-000000000001',
		name: 'Projects',
		kind: 'conversations',
		parentId: null,
		workspaceId: null
	};
	const filed = {
		...conversations[0],
		id: 'c0000000-0000-0000-0000-000000000003',
		title: 'Filed conversation',
		folderId: folder.id
	};

	await mockRpc(page, {
		authenticated: true,
		respond: {
			personal_conversations: () => [...conversations, filed],
			my_folders: () => [folder],
			my_folder_states: () => [{ id: 's-1', folderId: folder.id, isExpanded: false }]
		}
	});
	await page.goto('/chat');

	// Folder renders collapsed; its conversation is hidden until expanded.
	const folderRow = page.getByTestId('chat-folder');
	await expect(folderRow).toBeVisible();
	await expect(page.getByText('Filed conversation')).not.toBeVisible();
	await folderRow.click();
	await expect(page.getByText('Filed conversation')).toBeVisible();
	await expect(page.getByTestId('new-chat-in-folder')).toBeVisible();

	// Unfiled conversations render date-grouped (boundary labels are pinned by
	// the nav-grouping unit tests; the real clock moves fixtures across groups).
	await expect(page.getByTestId('conversation-list')).toBeVisible();
	await expect(page.getByText('Quarterly planning')).toBeVisible();

	// Hover actions: favorite and delete appear on the row.
	await page.getByText('Quarterly planning').hover();
	await expect(page.getByTestId('conversation-favorite-toggle').first()).toBeVisible();
	await expect(page.getByTestId('conversation-delete').first()).toBeVisible();
});

test('opening a conversation renders history, markdown, and a tab', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/chat');

	await page.getByText('Rust borrow checker').click();

	await expect(page).toHaveURL(new RegExp(`/chat/${conversations[1].id}$`));
	await expect(page.getByTestId('message-list')).toBeVisible();
	await expect(page.getByText('Why does Rust have a borrow checker?')).toBeVisible();
	// Agent markdown is rendered (bold), not shown raw.
	await expect(page.locator('strong', { hasText: 'data races' })).toBeVisible();
	await expect(page.getByText('grok-4.1-fast')).toBeVisible();
	// No socket behind vite preview → degraded banner instead of blocking
	// (it sits out an 8s grace period so routine handshakes stay quiet).
	await expect(page.getByTestId('conversation-offline')).toBeVisible({ timeout: 15_000 });
	// The TabSession tab was opened for it.
	await expect(page.getByTestId('tab-bar')).toBeVisible();
});

test('with tabs disabled the bar is hidden and the session trims to one tab', async ({ page }) => {
	const rpc = await mockRpc(page, {
		authenticated: true,
		// Classic default: tabs are opt-in.
		respond: { current_user: () => ({ ...user, uiPreferences: {} }) },
		// A stale multi-tab session (accumulated while the preference was on).
		initialTabs: [
			{ id: 'tab-a', primary: { type: 'conversation', id: conversations[0].id } },
			{ id: 'tab-b', primary: { type: 'brain_page', id: 'p0000000-0000-0000-0000-000000000001' } }
		],
		initialActiveTabId: 'tab-a'
	});
	await page.goto(`/chat/${conversations[1].id}`);

	await expect(page.getByTestId('message-list')).toBeVisible();
	await expect(page.getByTestId('tab-bar')).toHaveCount(0);

	// Opening the deep link trimmed the session to just the active tab via a
	// single open-and-trim round trip (classic maybe_trim_to_active_tab parity):
	// the client sends open_workbench_tab with single:true, not replace_tabs.
	await expect
		.poll(() => rpc.openTabCalls.filter((call) => call.single === true).length, {
			message: 'expected a single-trim open call'
		})
		.toBeGreaterThan(0);
	const trim = rpc.openTabCalls.filter((call) => call.single === true).at(-1) as {
		primary: { id: string };
	};
	expect(trim.primary.id).toBe(conversations[1].id);
});

test('the history view lists conversations and restores from trash', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			trashed_conversations: () => [
				{
					...conversations[0],
					id: 'c0000000-0000-0000-0000-00000000dead',
					title: 'Deleted research',
					messageCount: 4,
					deletedAt: '2026-06-10T10:00:00Z'
				}
			],
			// The view drops the row from its local list on success.
			restore_conversation: () => conversations[0]
		}
	});
	await page.goto('/history');

	await expect(page.getByTestId('history-view')).toBeVisible();
	await expect(page.getByTestId('history-list')).toBeVisible();
	// Scoped: the title also shows in the nav pane's conversation list.
	await expect(page.getByTestId('history-list').getByText('Quarterly planning')).toBeVisible();

	await page.getByTestId('history-tab-trash').click();
	await expect(page.getByTestId('trash-list')).toBeVisible();
	await expect(page.getByText('Deleted research')).toBeVisible();

	await page.getByTestId('trash-restore').click();
	await expect(page.getByText('Trash is empty.')).toBeVisible();
});

test('the share dialog creates and revokes read-only links', async ({ page }) => {
	const link = {
		id: 's-1',
		token: 'tok123',
		accessType: 'public',
		label: 'For the blog',
		isActive: true,
		insertedAt: '2026-06-12T10:00:00Z'
	};
	await mockRpc(page, {
		authenticated: true,
		respond: {
			conversation_share_links: () => [],
			create_share_link: () => link,
			revoke_share_link: () => ({ ...link, isActive: false })
		}
	});
	await page.goto(`/chat/${conversations[1].id}`);
	await expect(page.getByTestId('message-list')).toBeVisible();

	await page.getByTestId('conversation-menu').click();
	await page.getByTestId('conversation-share').click();
	await expect(page.getByTestId('share-dialog')).toBeVisible();

	await page.getByTestId('share-link-create').click();
	await expect(page.getByTestId('share-link-list')).toBeVisible();
	await expect(page.getByText('For the blog')).toBeVisible();

	await page.getByTestId('share-link-revoke').click();
	await expect(page.getByTestId('share-link-list')).toHaveCount(0);
});

test('the members panel enables collaboration and lists participants', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			enable_conversation_multiplayer: () => ({ ...conversations[1], isMultiplayer: true }),
			conversation_members: () => [
				{
					id: 'mem-1',
					role: 'owner',
					isMuted: false,
					acceptedAt: '2026-06-11T10:00:00Z',
					user: { id: user.id, email: 'ada@example.com', displayName: 'Ada' }
				},
				{
					id: 'mem-2',
					role: 'member',
					isMuted: false,
					acceptedAt: '2026-06-11T10:00:00Z',
					user: { id: 'u-bob', email: 'bob@example.com', displayName: 'Bob' }
				}
			],
			pending_conversation_invitations: () => [],
			conversation_invite_links: () => []
		}
	});
	await page.goto(`/chat/${conversations[1].id}`);
	await expect(page.getByTestId('message-list')).toBeVisible();

	await page.getByTestId('right-rail-toggle').click();
	await page.getByTestId('rail-tab-members').click();
	await expect(page.getByTestId('members-panel')).toBeVisible();

	// Non-multiplayer conversations show the enable CTA; enabling loads members.
	await page.getByTestId('members-enable-collaboration').click();
	await expect(page.getByTestId('members-list')).toBeVisible();
	await expect(page.getByTestId('members-list').getByText('Bob')).toBeVisible();

	// The owner sees the invite form for adding more participants.
	await expect(page.getByTestId('member-invite-email')).toBeVisible();
});

test('the settings routes render profile and preferences sections', async ({ page }) => {
	const richUser = {
		...user,
		name: 'Ada Lovelace',
		language: 'en',
		timezone: 'UTC',
		lastTimezoneChangeAt: null,
		selectedModelId: null,
		selectedImageModelId: null,
		selectedVideoModelId: null,
		pendingEmail: null,
		hasPassword: true,
		avatarPath: null
	};
	await mockRpc(page, {
		authenticated: true,
		respond: {
			current_user: () => richUser,
			list_image_generation_models: () => [],
			list_video_generation_models: () => []
		}
	});

	// The index redirects into the profile section.
	await page.goto('/settings');
	await expect(page).toHaveURL(/\/settings\/profile$/);
	await expect(page.getByTestId('settings-view')).toBeVisible();
	await expect(page.getByTestId('settings-profile')).toBeVisible();
	await expect(page.getByTestId('profile-display-name')).toHaveValue('Ada');
	// hasPassword:true → the change-password flow asks for the current password.
	await expect(page.getByTestId('profile-current-password')).toBeVisible();

	// Section nav switches to preferences: model defaults + interface toggles.
	await page.getByTestId('settings-nav-preferences').click();
	await expect(page).toHaveURL(/\/settings\/preferences$/);
	await expect(page.getByTestId('default-chat-model')).toBeVisible();
	await expect(page.getByTestId('preferences-autoscroll')).toBeVisible();
	await expect(page.getByTestId('preferences-tabs')).toHaveAttribute('aria-checked', 'true');
});

test('the api-tokens settings page creates a token and shows the plaintext once', async ({
	page
}) => {
	await mockRpc(page, { authenticated: true });

	// API tokens live behind a dedicated controller, not /rpc/run.
	await page.route('**/rpc/api-tokens', async (route) => {
		if (route.request().method() === 'POST') {
			return route.fulfill({
				json: {
					success: true,
					data: {
						id: 'tok-1',
						name: 'Laptop CLI',
						keyPrefix: 'mag_abc12345',
						scope: 'read',
						createdVia: 'settings',
						lastUsedAt: null,
						expiresAt: null,
						revokedAt: null,
						workspaceId: null,
						insertedAt: '2026-06-13T10:00:00Z',
						plaintext: 'mag_abc12345_SECRETPLAINTEXT'
					}
				}
			});
		}
		return route.fulfill({ json: { success: true, data: [] } });
	});

	await page.goto('/settings/api-tokens');
	await expect(page.getByTestId('settings-api-tokens')).toBeVisible();

	await page.getByTestId('api-token-new').click();
	await expect(page.getByTestId('api-token-dialog')).toBeVisible();
	await page.getByTestId('api-token-name').fill('Laptop CLI');
	await page.getByTestId('api-token-create').click();

	// The one-time plaintext is revealed after creation.
	await expect(page.getByTestId('api-token-plaintext')).toHaveValue('mag_abc12345_SECRETPLAINTEXT');
	await page.getByTestId('api-token-done').click();

	// And the token now appears in the list.
	await expect(page.getByTestId('api-token-list').getByText('Laptop CLI')).toBeVisible();
});

test('the data settings page exports and guards account deletion', async ({ page }) => {
	await mockRpc(page, { authenticated: true });

	await page.route('**/rpc/account/deletion-preflight', (route) =>
		route.fulfill({
			json: {
				success: true,
				data: {
					canDelete: true,
					summary: {
						activeSubscription: { plan: 'free', currentPeriodEnd: null },
						multiplayerMembershipCount: 0,
						conversationCount: 3,
						brainCount: 1,
						memoryCount: 0,
						promptCount: 0,
						draftCount: 0,
						customAgentCount: 0
					}
				}
			}
		})
	);

	await page.goto('/settings/data');
	await expect(page.getByTestId('settings-data')).toBeVisible();

	// Export is a browser download link to the Phoenix controller.
	await expect(page.getByTestId('data-export')).toHaveAttribute('href', '/settings/data/export');

	// Delete is gated behind a typed email-match confirmation.
	await page.getByTestId('data-delete-open').click();
	await expect(page.getByTestId('data-delete-dialog')).toBeVisible();
	const confirm = page.getByTestId('data-delete-confirm');
	await expect(confirm).toBeDisabled();
	await page.getByTestId('data-delete-confirm-email').fill('ada@example.com');
	await expect(confirm).toBeEnabled();
});

test('the jobs route shows a master-detail with schedule and run history', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			user_jobs: () => [
				{
					id: 'job-1',
					name: 'Daily digest',
					description: 'Summarize the day',
					status: 'active',
					scheduleType: 'cron',
					cronExpression: '0 9 * * *',
					cronExpressionLocal: 'Every day at 09:00',
					userTimezone: 'UTC',
					scheduledAt: null,
					startsAt: '2026-06-10T00:00:00Z',
					endsAt: null,
					nextRunAt: '2026-06-14T09:00:00Z',
					lastRunAt: '2026-06-13T09:00:00Z',
					triggerPrompt: 'Write a digest of today',
					memoryName: null,
					conversationId: conversations[1].id
				}
			],
			job_runs: () => [
				{
					id: 'run-1',
					status: 'success',
					startedAt: '2026-06-13T09:00:00Z',
					completedAt: '2026-06-13T09:00:04Z',
					errorMessage: null,
					retryAttempt: 0
				}
			]
		}
	});

	await page.goto('/jobs');
	await expect(page.getByTestId('jobs-view')).toBeVisible();
	await expect(page.getByTestId('jobs-list').getByText('Daily digest')).toBeVisible();

	// First job auto-selected: detail pane shows the trigger prompt + actions.
	await expect(page.getByTestId('jobs-detail')).toBeVisible();
	await expect(page.getByText('Write a digest of today')).toBeVisible();
	await expect(page.getByTestId('jobs-pause')).toBeVisible();
	await expect(page.getByTestId('jobs-runs')).toBeVisible();

	// Filtering to paused hides the active job.
	await page.getByTestId('jobs-filter-paused').click();
	await expect(page.getByTestId('jobs-list').getByText('Daily digest')).toHaveCount(0);
});

test('the search route renders unified results and filters by type', async ({ page }) => {
	await mockRpc(page, { authenticated: true });

	await page.route('**/rpc/search**', (route) => {
		const url = new URL(route.request().url());
		const type = url.searchParams.get('type');
		const conversationHit = {
			type: 'conversation',
			id: conversations[1].id,
			title: 'Rust borrow checker',
			snippet: 'Why does <mark>Rust</mark> have a borrow checker',
			score: 1,
			metadata: {}
		};
		const promptHit = {
			type: 'prompt',
			id: 'p-9',
			title: 'Rust tutor',
			snippet: 'Teach <mark>Rust</mark>',
			score: 0.5,
			metadata: {}
		};
		const data = type === 'conversation' ? [conversationHit] : [conversationHit, promptHit];
		return route.fulfill({ json: { success: true, data } });
	});

	// ?q seeds the query (the Cmd+K overlay navigates here).
	await page.goto('/search?q=rust');
	await expect(page.getByTestId('search-view')).toBeVisible();
	await expect(page.getByTestId('search-input')).toHaveValue('rust');
	await expect(page.getByTestId('search-results')).toBeVisible();
	await expect(page.getByText('Rust tutor')).toBeVisible();

	// The conversation result links into the chat route.
	const firstResult = page.getByTestId('search-result').first();
	await expect(firstResult).toHaveAttribute('href', new RegExp(`/chat/${conversations[1].id}`));

	// Narrowing to Conversations drops the prompt hit.
	await page.getByTestId('search-tab-conversation').click();
	await expect(page.getByText('Rust tutor')).toHaveCount(0);
	await expect(page.getByTestId('search-result')).toHaveCount(1);
});

test('the composer sends a message with Enter and renders the reply bubble', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto(`/chat/${conversations[1].id}`);

	await expect(page.getByTestId('message-list')).toBeVisible();

	const input = page.getByTestId('composer-input');
	await input.fill('What about lifetimes?');
	await input.press('Enter');

	// Optimistic bubble settles into the server row; the input clears.
	await expect(page.getByText('What about lifetimes?')).toBeVisible();
	await expect(input).toHaveValue('');
});

test('the chat surface shows header actions and composer controls', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto(`/chat/${conversations[1].id}`);

	// Header: avatar/title/menu. Composer footer: model selector + mode toggles.
	await expect(page.getByTestId('conversation-header')).toBeVisible();
	await expect(page.getByTestId('conversation-menu')).toBeVisible();
	await expect(page.getByTestId('model-selector')).toBeVisible();
	await expect(page.getByTestId('mode-toggle-image')).toBeVisible();
	await expect(page.getByTestId('mode-toggle-video')).toBeVisible();
	await expect(page.getByTestId('composer-actions')).toBeVisible();
});

test('the right rail opens, inserts a prompt, and switches panels', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			my_prompts: () => [
				{
					id: 'p-1',
					name: 'Tone guide',
					description: 'House style',
					type: 'user',
					isFavorited: false,
					isSharedToWorkspace: false,
					workspaceId: null
				}
			],
			get_prompt: () => ({
				id: 'p-1',
				name: 'Tone guide',
				description: 'House style',
				type: 'user',
				isFavorited: false,
				isSharedToWorkspace: false,
				workspaceId: null,
				content: 'Use a warm tone.',
				chatMode: null,
				additionalInformation: null,
				isPublic: false,
				tags: []
			})
		}
	});
	await page.goto(`/chat/${conversations[1].id}`);

	await page.getByTestId('right-rail-toggle').click();
	await expect(page.getByTestId('right-rail')).toBeVisible();
	await expect(page.getByTestId('rail-prompts-panel')).toBeVisible();

	// Inserting a user prompt lands its content in the composer.
	await page.getByText('Tone guide').hover();
	await page.getByTestId('rail-insert-prompt').click();
	await expect(page.getByTestId('composer-input')).toHaveValue('Use a warm tone.');

	// Panel switching: settings form and files scope tabs render.
	await page.getByTestId('rail-tab-settings').click();
	await expect(page.getByTestId('rail-system-prompt')).toBeVisible();
	await page.getByTestId('rail-tab-files').click();
	await expect(page.getByTestId('rail-files-panel')).toBeVisible();
	await page.getByTestId('rail-tab-drafts').click();
	await expect(page.getByTestId('rail-drafts-panel')).toBeVisible();

	// Escape closes the popover.
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('right-rail')).not.toBeVisible();
});

test('the search item opens the global overlay and Escape closes it', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/chat');

	await page.getByTestId('nav-search').click();
	await expect(page.getByTestId('search-overlay')).toBeVisible();
	await expect(page.getByTestId('search-overlay-input')).toBeFocused();

	await page.keyboard.press('Escape');
	await expect(page.getByTestId('search-overlay')).not.toBeVisible();

	// The keyboard shortcut opens it too.
	await page.keyboard.press('ControlOrMeta+k');
	await expect(page.getByTestId('search-overlay')).toBeVisible();
});

test('the composer plus menu lists slash commands and injects one', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto(`/chat/${conversations[1].id}`);

	await page.getByTestId('composer-actions').click();
	const commands = page.getByTestId('composer-slash-command');
	await expect(commands).toHaveCount(2);
	await expect(commands.first()).toContainText('Search the web');
	await expect(commands.first()).toContainText('/web-search');

	await commands.first().click();
	await expect(page.getByTestId('composer-input')).toHaveValue('/web-search ');
});

test('Open chat docks a conversation companion beside the file', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			get_file: () => ({
				id: 'f0000000-0000-0000-0000-00000000000f',
				name: 'report.txt',
				type: 'text',
				source: 'user',
				mimeType: 'text/plain',
				fileSize: 600 * 1024,
				filePath: 'u/report.txt',
				isTemplate: false,
				status: 'ready',
				updatedAt: '2026-06-11T10:00:00Z',
				folderId: null,
				workspaceId: null,
				userId: user.id
			}),
			open_companion_chat: () => ({
				conversation_id: conversations[0].id,
				title: 'About report.txt'
			})
		}
	});
	await page.goto('/files/file/f0000000-0000-0000-0000-00000000000f');
	await expect(page.getByTestId('file-detail-name')).toHaveText('report.txt');

	// The file stays primary; the chat docks beside it as a companion pane.
	await page.getByTestId('file-open-chat').click();
	await expect(page.getByTestId('conversation-companion-messages')).toBeVisible();
	await expect(page).toHaveURL(/\/files\/file\/f0000000-0000-0000-0000-00000000000f$/);
	await expect(page.getByTestId('file-open-chat')).toContainText('Close chat');

	// Toggling again closes the pane.
	await page.getByTestId('file-open-chat').click();
	await expect(page.getByTestId('conversation-companion-messages')).not.toBeVisible();
});

test('typing @ opens the mention dropdown and picks an agent handle', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto(`/chat/${conversations[1].id}`);

	const input = page.getByTestId('composer-input');
	await input.click();
	await input.pressSequentially('hey @res');

	await expect(page.getByTestId('mention-dropdown')).toBeVisible();
	await page.getByTestId('mention-option').first().click();

	await expect(input).toHaveValue('hey @researcher ');
	await expect(page.getByTestId('mention-dropdown')).not.toBeVisible();
});

test('drafts persist across reloads and clear after sending', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto(`/chat/${conversations[1].id}`);

	const input = page.getByTestId('composer-input');
	await input.fill('draft in progress');
	// The draft save is debounced (400ms).
	await page.waitForTimeout(600);

	await page.reload();
	await expect(page.getByTestId('composer-input')).toHaveValue('draft in progress');

	await page.getByTestId('composer-input').press('Enter');
	await page.waitForTimeout(100);
	const stored = await page.evaluate(
		(id) => localStorage.getItem(`magus:next:draft:${id}`),
		conversations[1].id
	);
	expect(stored).toBeNull();
});

test('client-side routing serves unknown paths through the SPA fallback', async ({ page }) => {
	await mockRpc(page, { authenticated: false });
	const response = await page.goto('/some/future/route');

	expect(response?.status()).toBeLessThan(500);
});

test('a persisted brain-page companion renders in a split pane and closes', async ({ page }) => {
	const conversationTab = {
		id: 'tab-1',
		primary: { type: 'conversation', id: conversations[1].id },
		companion: { type: 'brain_page', id: 'page-1' }
	};
	let companionInput: Record<string, unknown> | null = null;

	await mockRpc(page, {
		authenticated: true,
		respond: {
			get_or_create_tab_session: () => ({
				...tabSession,
				tabs: [conversationTab],
				activeTabId: 'tab-1'
			}),
			get_brain_page: () => ({
				id: 'page-1',
				title: 'Quarterly Roadmap',
				icon: null,
				body: '# Goals\n\nShip the workbench.\n\n## Risks\n\nScope.',
				updatedAt: '2026-06-10T10:00:00Z',
				brain: { id: 'brain-1', workspaceId: null }
			}),
			list_page_backlinks: () => [
				{
					id: 'link-1',
					targetTitleAtLinkTime: 'Quarterly Roadmap',
					sourcePage: { id: 'page-2', title: 'Weekly Notes', icon: null }
				}
			],
			list_page_sources: () => [],
			list_brain_page_versions: () => [],
			set_workbench_companion: (input) => {
				companionInput = input;
				return {
					...tabSession,
					tabs: [{ ...conversationTab, companion: null }],
					activeTabId: 'tab-1'
				};
			}
		}
	});

	await page.goto(`/chat/${conversations[1].id}`);

	// Split pane restored from the TabSession: chat on the left, page right.
	await expect(page.getByTestId('message-list')).toBeVisible();
	await expect(page.getByTestId('companion-pane')).toBeVisible();
	await expect(page.getByTestId('companion-title')).toHaveText('Quarterly Roadmap');

	// Footer tab strip: outline lists the page headings; related lists backlinks.
	await page.getByTestId('companion-tab-outline').click();
	await expect(page.getByTestId('companion-panel')).toContainText('Goals');
	await page.getByTestId('companion-tab-related').click();
	await expect(page.getByTestId('companion-panel')).toContainText('Weekly Notes');

	// Closing persists companion: null and collapses the split.
	await page.getByTestId('companion-close').click();
	await expect(page.getByTestId('companion-pane')).not.toBeVisible();
	await expect.poll(() => companionInput).toEqual({ tabId: 'tab-1', companion: null });
});

const libraryFile = {
	id: 'f0000000-0000-0000-0000-000000000001',
	name: 'notes.txt',
	type: 'text',
	source: 'user',
	mimeType: 'text/plain',
	fileSize: 2048,
	filePath: 'u-1/f-1.txt',
	isTemplate: false,
	status: 'ready',
	updatedAt: '2026-06-10T10:00:00Z',
	folderId: null,
	workspaceId: null
};

const libraryFolder = {
	id: 'd0000000-0000-0000-0000-000000000001',
	name: 'Reports',
	kind: 'files',
	parentId: null,
	workspaceId: null
};

test('the files browser lists folders and files with scope navigation', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			my_library_files: () => [libraryFile],
			my_folders: () => [libraryFolder]
		}
	});

	await page.goto('/files');

	await expect(page.getByTestId('files-browser')).toBeVisible();
	await expect(page.getByTestId('files-nav')).toBeVisible();
	await expect(page.getByTestId('folder-entry')).toContainText('Reports');
	await expect(page.getByTestId('file-entry')).toContainText('notes.txt');

	// Scope navigation swaps the listing (trash is mocked empty).
	await page.getByTestId('files-scope-trash').click();
	await expect(page.getByTestId('files-empty')).toContainText('Trash is empty');
});

test('creating a folder and renaming a file work inline', async ({ page }) => {
	const renamed = { ...libraryFile, name: 'report-final.txt' };

	await mockRpc(page, {
		authenticated: true,
		respond: {
			my_library_files: () => [libraryFile],
			my_folders: () => [],
			create_folder: (input) => ({
				id: 'd0000000-0000-0000-0000-000000000002',
				name: (input as { name: string }).name,
				kind: 'files',
				parentId: null,
				workspaceId: null
			}),
			rename_file: () => renamed
		}
	});

	await page.goto('/files');
	await expect(page.getByTestId('file-entry')).toBeVisible();

	await page.getByTestId('new-folder').click();
	await page.getByTestId('new-folder-input').fill('Q3 Planning');
	await page.getByTestId('new-folder-input').press('Enter');
	await expect(page.getByTestId('folder-entry')).toContainText('Q3 Planning');

	await page.getByTestId('file-entry').hover();
	await page.getByTestId('file-entry').getByTestId('entry-menu').click();
	await page.getByRole('menuitem', { name: 'Rename' }).click();
	await page.getByTestId('rename-input').fill('report-final.txt');
	await page.getByTestId('rename-input').press('Enter');

	await expect(page.getByTestId('file-entry')).toContainText('report-final.txt');
});

const libraryPrompt = {
	id: 'p0000000-0000-0000-0000-000000000001',
	name: 'Code review checklist',
	description: 'Steps for reviewing PRs',
	type: 'user',
	isFavorited: false,
	isSharedToWorkspace: false,
	workspaceId: null
};

test('prompts mode lists the library and opens a prompt', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			my_prompts: () => [libraryPrompt],
			get_prompt: () => ({
				...libraryPrompt,
				content: 'Check tests. Check naming.',
				chatMode: null,
				additionalInformation: null,
				isPublic: false,
				tags: [{ id: 'tag-1', name: 'review' }]
			})
		}
	});

	await page.goto('/prompts');
	await expect(page.getByTestId('prompts-nav')).toBeVisible();
	await expect(page.getByText('Code review checklist')).toBeVisible();

	await page.getByText('Code review checklist').click();
	await expect(page.getByTestId('prompt-title')).toHaveText('Code review checklist');
	await expect(page.getByTestId('prompt-content')).toContainText('Check tests.');
	await expect(page.getByText('#review ×')).toBeVisible();

	await page.getByTestId('prompt-edit').click();
	await expect(page.getByTestId('prompt-name-input')).toHaveValue('Code review checklist');
});

const agentDetail = {
	id: 'a0000000-0000-0000-0000-000000000001',
	name: 'Researcher',
	handle: 'researcher',
	description: 'Digs into things',
	icon: null,
	instructions: 'Research thoroughly.',
	chatMode: 'chat',
	maxIterations: 10,
	isDefault: false,
	isPaused: false,
	isSharedToWorkspace: false,
	canReadGlobalMemories: true,
	canWriteGlobalMemories: false,
	canAccessGlobalFiles: true,
	canAccessKnowledge: true,
	heartbeatEnabled: false,
	heartbeatInstructions: null,
	heartbeatDefaultIntervalMinutes: 60,
	maxDailyRuns: 24,
	maxTokensPerRun: 100000,
	nextScheduledAt: null,
	updatedAt: '2026-06-11T10:00:00Z'
};

test('agents mode renders the config sections', async ({ page }) => {
	await mockRpc(page, {
		authenticated: true,
		respond: {
			get_custom_agent: () => agentDetail
		}
	});

	await page.goto(`/agents/${agentDetail.id}`);
	await expect(page.getByTestId('agent-title')).toHaveText('Researcher');
	await expect(page.getByTestId('agent-sections')).toBeVisible();
	await expect(page.getByTestId('agent-instructions')).toHaveValue('Research thoroughly.');

	await page.getByTestId('agent-section-privacy').click();
	await expect(page.getByText('Read global memories')).toBeVisible();

	await page.getByTestId('agent-section-secrets').click();
	await expect(page.getByTestId('agent-secrets-list')).toBeVisible();

	await page.getByTestId('agent-section-activity').click();
	await expect(page.getByTestId('agent-inbox-list')).toBeVisible();
	await expect(page.getByTestId('agent-activity-list')).toBeVisible();
});

const brainFixture = {
	id: 'b0000000-0000-0000-0000-000000000001',
	title: 'Research',
	icon: null,
	workspaceId: null
};
const brainPageFixture = {
	id: 'bp000000-0000-0000-0000-000000000001',
	title: 'Roadmap',
	icon: null,
	parentPageId: null
};

test('brain mode shows the page tree and autosaves rich edits with LWW conflicts', async ({
	page
}) => {
	let saveCalls = 0;

	await mockRpc(page, {
		authenticated: true,
		respond: {
			my_brains: () => [brainFixture],
			root_brain_pages: () => [brainPageFixture],
			brain_pages: () => [brainPageFixture],
			get_brain_page: () => ({
				...brainPageFixture,
				body: '# Goals',
				updatedAt: '2026-06-11T10:00:00Z',
				lockVersion: 3,
				prosemirror: {
					type: 'doc',
					content: [
						{
							type: 'heading',
							attrs: { level: 1 },
							content: [{ type: 'text', text: 'Goals' }]
						}
					]
				},
				brain: { id: brainFixture.id, workspaceId: null }
			})
		}
	});

	// First save returns a version conflict; the LWW retry succeeds.
	await page.route('**/rpc/run', async (route) => {
		const body = route.request().postDataJSON() as { action: string };
		if (body.action === 'save_brain_page_prosemirror') {
			saveCalls += 1;
			if (saveCalls === 1) {
				return route.fulfill({
					json: {
						success: false,
						errors: [
							{
								type: 'version_conflict',
								message: 'Page was edited concurrently: base version 3 is stale (current: 7).',
								shortMessage: 'Version conflict',
								vars: { current_version: 7, base_version: 3 },
								fields: ['base_version'],
								path: []
							}
						]
					}
				});
			}
			return route.fulfill({
				json: { success: true, data: { id: brainPageFixture.id, lock_version: 8 } }
			});
		}
		return route.fallback();
	});

	await page.goto('/brain');
	await expect(page.getByTestId('brain-nav')).toBeVisible();
	// The first brain auto-expands as a tree root with its pages nested.
	await expect(page.getByTestId('brain-root')).toContainText('Research');
	await expect(page.getByTestId('brain-page-tree')).toContainText('Roadmap');

	await page.getByText('Roadmap').click();
	await expect(page.getByTestId('brain-page-title')).toHaveText('Roadmap');

	// The rich editor renders the server-converted ProseMirror document.
	const editor = page.getByTestId('brain-editor').locator('.tiptap');
	await expect(editor).toBeVisible();
	await expect(editor.locator('h1')).toHaveText('Goals');

	// Typing triggers the autosave; the stale first save resolves via LWW.
	await editor.click();
	await page.keyboard.press('End');
	await page.keyboard.type(' v2');
	await expect(page.getByTestId('brain-page-conflict')).toBeVisible();
	await expect(page.getByTestId('brain-save-state')).toHaveText('Saved');
	expect(saveCalls).toBe(2);
});

test('starting a thread from a message opens the thread companion', async ({ page }) => {
	const conversationTab = {
		id: 'tab-1',
		primary: { type: 'conversation', id: conversations[1].id },
		companion: null as Record<string, unknown> | null
	};

	await mockRpc(page, {
		authenticated: true,
		respond: {
			get_or_create_tab_session: () => ({
				...tabSession,
				tabs: [conversationTab],
				activeTabId: 'tab-1'
			}),
			create_thread: () => ({
				id: 'thread-1',
				title: null,
				branchedAtMessageId: history[0].id,
				insertedAt: '2026-06-11T10:05:00Z'
			}),
			set_workbench_companion: (input) => {
				conversationTab.companion = (input.companion as Record<string, unknown>) ?? null;
				return { ...tabSession, tabs: [{ ...conversationTab }], activeTabId: 'tab-1' };
			},
			// The thread companion loads the thread conversation's history.
			message_history: (input) =>
				input.conversationId === conversations[1].id
					? { results: history, hasMore: false }
					: { results: [], hasMore: false }
		}
	});

	await page.goto(`/chat/${conversations[1].id}`);
	await expect(page.getByTestId('message-list')).toBeVisible();

	await page.getByText('data races').hover();
	await page.locator('[data-role="agent"]').getByTestId('message-start-thread').click();

	await expect(page.getByTestId('companion-pane')).toBeVisible();
	await expect(page.getByTestId('thread-messages')).toBeVisible();
	// The branch chip now marks the message as threaded.
	await expect(page.getByTestId('message-open-thread')).toBeVisible();
});
