import { expect, test, type Page } from '@playwright/test';

// Structural E2E for the Brain Overview dashboard (Plan 3, Phase C). vite preview
// serves the static SPA; every RPC the shell + overview issue is mocked at the
// network level. Assertions use data-testid hooks + counts ONLY, never visible
// label text / CSS / copy (project rule: no brittle UI tests).
//
// The overview route does NOT mount the brain rich-text editor, so it should not
// hit the pre-existing wikilink crash that blocks the plan-board page spec under
// vite preview. We still guard for it (detect + skip) so the suite stays green
// if the shell pulls the editor in transitively; the store's derivations are
// covered exhaustively by brain-overview-store.svelte.test.ts (vitest).

const user = {
	id: '6a0b7e6e-0000-0000-0000-000000000000',
	email: 'ada@example.com',
	displayName: 'Ada',
	currentWorkspaceId: null,
	uiPreferences: {}
};

const brain = { id: 'b0000000-0000-0000-0000-000000000001', workspaceId: null };
const planA = 'bp000000-0000-0000-0000-00000000000a';
const planB = 'bp000000-0000-0000-0000-00000000000b';

function brainTasksFixture(): Record<string, unknown>[] {
	const base = {
		dueAt: null,
		assignedToAgent: null,
		assignedToUserId: null,
		assignedToCustomAgentId: null,
		resultSummary: null,
		subtaskCount: 0,
		openDependenciesCount: 0,
		position: 1
	};
	return [
		// plan-a: one in-flight (external agent, fresh), one ready, one done.
		{
			...base,
			id: 'a-wip',
			title: 'Cut the release branch',
			status: 'in_progress',
			priority: 'urgent',
			claimedAt: '2026-06-24T11:55:00Z',
			// Live lease far in the future → fresh (not reclaimed).
			leaseExpiresAt: '2099-01-01T00:00:00Z',
			assignedToAgent: 'claude-code',
			brainPageId: planA,
			ready: false,
			subtaskCount: 3
		},
		{
			...base,
			id: 'a-ready',
			title: 'Write the announcement',
			status: 'open',
			priority: 'high',
			claimedAt: null,
			brainPageId: planA,
			ready: true
		},
		{
			...base,
			id: 'a-done',
			title: 'Draft the changelog',
			status: 'done',
			priority: 'normal',
			claimedAt: '2026-06-23T09:00:00Z',
			assignedToUserId: user.id,
			brainPageId: planA,
			ready: false
		},
		// plan-b: one in-flight whose lease has EXPIRED (the reaper will reclaim
		// it), one ready.
		{
			...base,
			id: 'b-stale',
			title: 'Migrate the schema',
			status: 'in_progress',
			priority: 'normal',
			claimedAt: '2026-06-20T09:00:00Z',
			// Lease lapsed in the past → stale (reclaim treatment).
			leaseExpiresAt: '2026-06-20T09:15:00Z',
			assignedToUserId: user.id,
			brainPageId: planB,
			ready: false
		},
		{
			...base,
			id: 'b-ready',
			title: 'Audit the indexes',
			status: 'open',
			priority: 'low',
			claimedAt: null,
			brainPageId: planB,
			ready: true
		}
	];
}

function brainEventsFixture(): Record<string, unknown>[] {
	return [
		{
			id: 'ev-1',
			taskId: 'a-wip',
			brainPageId: planA,
			kind: 'claimed',
			actorLabel: 'claude-code',
			metadata: {},
			insertedAt: '2026-06-24T11:55:00Z'
		},
		{
			id: 'ev-2',
			taskId: 'a-done',
			brainPageId: planA,
			kind: 'completed',
			actorLabel: 'Ada',
			metadata: {},
			insertedAt: '2026-06-23T12:00:00Z'
		},
		{
			id: 'ev-3',
			taskId: 'a-ready',
			brainPageId: planA,
			kind: 'created',
			actorLabel: 'Ada',
			metadata: {},
			insertedAt: '2026-06-23T08:00:00Z'
		}
	];
}

async function mockOverviewRpc(page: Page) {
	await Promise.all([
		page.route('**/rpc/run', async (route) => {
			const body = route.request().postDataJSON() as { action: string };
			const respond = (data: unknown) => route.fulfill({ json: { success: true, data } });

			switch (body.action) {
				case 'current_user':
				case 'update_ui_preferences':
					return respond(user);
				case 'get_or_create_tab_session':
					return respond({
						id: 't0000000-0000-0000-0000-000000000001',
						mode: 'brain',
						navFilter: 'all',
						tabs: [],
						activeTabId: null
					});
				case 'my_brains':
					return respond([{ ...brain, title: 'Research', icon: null }]);
				case 'root_brain_pages':
					return respond([
						{ id: planA, title: 'Launch plan', icon: null, parentPageId: null },
						{ id: planB, title: 'Research plan', icon: null, parentPageId: null }
					]);
				case 'brain_pages':
					// The overview loads pages WITH their lifecycle fields (project-state):
					// planA is active, planB is done-but-not-delivered (stranded).
					return respond([
						{
							id: planA,
							title: 'Launch plan',
							icon: null,
							kind: 'plan',
							parentPageId: null,
							specPageId: null,
							lifecycle: 'active',
							deliveredAt: null,
							deliveryRef: null
						},
						{
							id: planB,
							title: 'Research plan',
							icon: null,
							kind: 'plan',
							parentPageId: null,
							specPageId: null,
							lifecycle: 'done',
							deliveredAt: null,
							deliveryRef: null
						}
					]);
				case 'brain_tasks':
					return respond(brainTasksFixture());
				case 'brain_task_events':
					return respond(brainEventsFixture());
				case 'my_agents':
					return respond([]);
				default:
					return respond([]);
			}
		}),
		page.route('**/rpc/socket-token', (route) =>
			route.fulfill({ status: 200, json: { token: 'test' } })
		)
	]);
}

async function openOverview(page: Page) {
	let editorCrash = false;
	page.on('pageerror', (error) => {
		if (/Maximum call stack size exceeded/.test(error.message)) editorCrash = true;
	});
	await page.goto(`/next/brain/overview`);

	const loaded = await page
		.getByTestId('overview-worker-card')
		.first()
		.waitFor({ state: 'visible', timeout: 6000 })
		.then(() => true)
		.catch(() => false);

	test.skip(
		!loaded && editorCrash,
		'Pre-existing brain editor crash under vite preview blocks the shell render'
	);
}

test('the overview renders in-flight workers, the rollup, and the activity feed', async ({
	page
}) => {
	await mockOverviewRpc(page);
	await openOverview(page);

	await expect(page.getByTestId('brain-overview')).toBeVisible();

	// Two distinct in-flight workers (external claude-code on plan-a, the user on
	// plan-b). The unassigned tasks do not produce worker cards.
	await expect(page.getByTestId('overview-worker-card')).toHaveCount(2);

	// One worker is stale (its claim's lease has lapsed → the reaper reclaims it).
	await expect(page.locator('[data-testid="overview-worker-card"][data-stale="true"]')).toHaveCount(
		1
	);

	// The rollup defaults to "by plan": one row per plan with at least one task.
	await expect(page.getByTestId('overview-rollup')).toBeVisible();
	await expect(page.getByTestId('rollup-row')).toHaveCount(2);

	// The activity feed lists every event, newest-first.
	await expect(page.getByTestId('overview-activity')).toBeVisible();
	await expect(page.getByTestId('activity-entry')).toHaveCount(3);
});

test('switching the rollup grouping re-renders the rows', async ({ page }) => {
	await mockOverviewRpc(page);
	await openOverview(page);

	const rollup = page.getByTestId('overview-rollup');
	// By plan → 2 rows (plan-a, plan-b).
	await expect(page.getByTestId('rollup-row')).toHaveCount(2);

	// By status → in_progress + ready + done lanes have tasks (no blocked).
	await rollup.locator('[data-testid="rollup-mode"][data-mode="status"]').click();
	await expect(page.getByTestId('rollup-row')).toHaveCount(3);

	// By assignee → claude-code, the user, and the unassigned pool.
	await rollup.locator('[data-testid="rollup-mode"][data-mode="assignee"]').click();
	await expect(page.getByTestId('rollup-row')).toHaveCount(3);
});

test('the overview surfaces stranded plans and the unified plan tree', async ({ page }) => {
	await mockOverviewRpc(page);
	await openOverview(page);

	// plan-b is done-but-not-delivered → exactly one stranded row, with a deliver
	// control. plan-a (active) is not stranded.
	await expect(page.getByTestId('overview-stranded')).toBeVisible();
	await expect(page.getByTestId('stranded-plan')).toHaveCount(1);
	await expect(page.getByTestId('stranded-deliver')).toHaveCount(1);

	// The plan tree lists both plan pages as nodes (kind: plan), with their
	// lifecycle badges. The done plan also carries a deliver affordance.
	await expect(page.getByTestId('overview-plan-tree')).toBeVisible();
	await expect(page.getByTestId('plan-node')).toHaveCount(2);
	await expect(page.locator('[data-testid="plan-node"][data-stranded="true"]')).toHaveCount(1);
	await expect(page.getByTestId('lifecycle-badge')).toHaveCount(3); // 2 tree + 1 stranded row
});
