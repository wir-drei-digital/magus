import { expect, test, type Page } from '@playwright/test';

// Skill approval card suite: mirrors smoke.spec.ts / skills.spec.ts in
// structure. The SPA is served by `vite preview` with no Phoenix backend;
// RPC is mocked at the network level. The card renders inside the
// notification bell for `approval_request` notifications whose metadata
// carries an `approve_phrase` (and now a `declared_secret_keys` list).

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: { tabs_enabled: true }
};

const tabSession = {
	id: 't0000000-0000-0000-0000-000000000001',
	mode: 'chat',
	navFilter: 'all',
	tabs: [] as { id: string; primary: { type: string; id: string } }[],
	activeTabId: null as string | null
};

const conversationId = 'c0000000-0000-0000-0000-000000000001';
const skillId = 'skill-bundle-0000-0000-0000-000000000001';

// One approval_request notification whose metadata declares a secret key.
const approvalNotification = {
	id: 'n-approval-1',
	title: 'Skill approval needed',
	body: 'Allow the skill "deepl-translate" to run its bundled code in the sandbox?',
	notificationType: 'approval_request',
	targetConversationId: conversationId,
	metadata: {
		skill_id: skillId,
		approve_phrase: `Approve skill: ${skillId}`,
		declared_secret_keys: ['DEEPL_API_KEY'],
		options: ['Approve', 'Reject']
	},
	insertedAt: '2026-06-11T10:00:00Z'
};

// Records the actions the card fires so we can assert trust-on-approve.
type Recorder = { trustSkillCalls: Record<string, unknown>[] };

async function mockRpc(
	page: Page,
	options: {
		authenticated: boolean;
		respond?: Record<string, (input: Record<string, unknown>) => unknown>;
	}
): Promise<Recorder> {
	const sessionState = { ...tabSession };
	const recorder: Recorder = { trustSkillCalls: [] };

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
				case 'unread_notifications':
					return respond([approvalNotification]);
				case 'trust_skill':
					recorder.trustSkillCalls.push(body.input ?? {});
					return respond({ id: 'trust-1' });
				case 'send_user_message': {
					const input = (body.input ?? {}) as { text?: string };
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

	return recorder;
}

test('approval card shows declared keys and a trust checkbox', async ({ page }) => {
	await mockRpc(page, { authenticated: true });
	await page.goto('/chat');

	await page.getByTestId('notification-bell').click();

	const card = page.getByTestId('approval-card');
	await expect(card).toBeVisible();
	await expect(page.getByTestId('approval-declared-keys')).toContainText('DEEPL_API_KEY');
	await expect(page.getByTestId('approval-trust')).toBeVisible();
});

test('approving with trust checked calls trustSkill with the declared skill id', async ({
	page
}) => {
	const recorder = await mockRpc(page, { authenticated: true });
	await page.goto('/chat');

	await page.getByTestId('notification-bell').click();
	await expect(page.getByTestId('approval-card')).toBeVisible();

	// Tick "Always allow this skill", then approve.
	await page.getByTestId('approval-trust').check();
	await page.getByTestId('approval-approve').click();

	// The approve handler navigates to the target conversation once done; the
	// trust RPC must have fired exactly once with the notification's skill id.
	await expect.poll(() => recorder.trustSkillCalls.length, { timeout: 5000 }).toBe(1);
	expect(recorder.trustSkillCalls[0]).toEqual({ skillId });
});
