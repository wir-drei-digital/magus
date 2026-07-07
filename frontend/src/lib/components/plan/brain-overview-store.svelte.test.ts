import { describe, it, expect, vi, beforeEach } from 'vitest';

/**
 * Logic coverage for the brain-overview store: the IN FLIGHT worker grouping
 * (incl. multi-task workers, the stale flag, and the unassigned-in-progress
 * exclusion), the three rollup modes (by plan / assignee / status), the
 * header summary counts (plans / in-flight / ready), and the activity-feed
 * derivation (ordering, kind→verb mapping, self detection, task + plan joins).
 *
 * Runs under the existing vitest config (environment: 'node'); the sveltekit()
 * vite plugin compiles the `.svelte.ts` runes module so $state/$derived work
 * without jsdom (mirrors task-board-store.svelte.test.ts). The api.ts seam is
 * mocked so no network is touched.
 */

// ─── api.ts mock ─────────────────────────────────────────────────────────────
const brainTasks = vi.fn();
const brainTaskEvents = vi.fn();
const brainPlanPages = vi.fn();
const markBrainPageDelivered = vi.fn();
const undeliverBrainPage = vi.fn();
const myAgents = vi.fn();

vi.mock('$lib/ash/api', () => ({
	brainTasks: (...args: unknown[]) => brainTasks(...args),
	brainTaskEvents: (...args: unknown[]) => brainTaskEvents(...args),
	brainPlanPages: (...args: unknown[]) => brainPlanPages(...args),
	markBrainPageDelivered: (...args: unknown[]) => markBrainPageDelivered(...args),
	undeliverBrainPage: (...args: unknown[]) => undeliverBrainPage(...args),
	myAgents: (...args: unknown[]) => myAgents(...args),
	// task-board-store.svelte (imported transitively for isReady/isStale) also
	// pulls these from the api module; stub them so the import resolves.
	planTasks: vi.fn(),
	createPlanTask: vi.fn(),
	updatePlanTask: vi.fn(),
	claimPlanTask: vi.fn()
}));

// Fixed current user so resolveAssignee + activity self-detection work.
vi.mock('$lib/stores/session.svelte', () => ({
	session: { user: { id: 'user-self', displayName: 'Ada', email: 'ada@example.com' } }
}));

import {
	BrainOverviewStore,
	countStatuses,
	progressOf,
	LEASE_EXPIRING_MS
} from './brain-overview-store.svelte';
import type { PlanTask, PlanPage, TaskEventEntry, TaskEventKind } from '$lib/ash/api';

function task(overrides: Partial<PlanTask> & { id: string }): PlanTask {
	return {
		title: 'Task',
		status: 'open',
		priority: 'normal',
		position: 0,
		dueAt: null,
		claimedAt: null,
		leaseExpiresAt: null,
		createdByLabel: null,
		assignedToAgent: null,
		assignedToUserId: null,
		assignedToCustomAgentId: null,
		brainPageId: 'plan-a',
		resultSummary: null,
		ready: null,
		subtaskCount: 0,
		completedSubtaskCount: 0,
		openDependenciesCount: 0,
		...overrides
	};
}

function event(
	overrides: Partial<TaskEventEntry> & { id: string; kind: TaskEventKind }
): TaskEventEntry {
	return {
		taskId: 'task-1',
		brainPageId: 'plan-a',
		actorLabel: 'claude-code',
		metadata: {},
		insertedAt: '2026-06-24T10:00:00Z',
		...overrides
	};
}

const ok = <T>(data: T) => ({ success: true as const, data });
const err = (message: string) => ({
	success: false as const,
	errors: [{ type: 'x', message, shortMessage: message, vars: {}, fields: [], path: [] }]
});

const NOW = Date.parse('2026-06-24T12:00:00Z');
// Claim timestamps drive recency ordering; lease timestamps drive staleness.
const staleClaim = new Date(NOW - 6 * 60 * 60_000).toISOString();
const freshClaim = new Date(NOW - 60_000).toISOString();
// A lease in the past means the reaper will reclaim it (the "stale" signal); a
// live future lease is fresh.
const expiredLease = new Date(NOW - 60_000).toISOString();
const liveLease = new Date(NOW + 10 * 60_000).toISOString();

beforeEach(() => {
	vi.clearAllMocks();
	vi.useFakeTimers();
	vi.setSystemTime(NOW);
	myAgents.mockResolvedValue(ok([{ id: 'agent-teal', name: 'Atlas' }]));
	brainTaskEvents.mockResolvedValue(ok([]));
	brainPlanPages.mockResolvedValue(
		ok([
			planPage({ id: 'plan-a', title: 'Launch plan', lifecycle: 'active' }),
			planPage({ id: 'plan-b', title: 'Research plan', lifecycle: 'active' })
		])
	);
});

/** A plan page fixture (defaults non-stranded). */
function planPage(overrides: Partial<PlanPage> & { id: string }): PlanPage {
	return {
		title: 'Plan',
		icon: null,
		kind: 'plan',
		parentPageId: null,
		specPageId: null,
		lifecycle: 'active',
		deliveredAt: null,
		deliveryRef: null,
		...overrides
	};
}

/** A done-but-not-delivered plan fixture for the stranded section. */
function strandedPage(overrides: Partial<PlanPage> & { id: string }): PlanPage {
	return planPage({ lifecycle: 'done', ...overrides });
}

async function build(
	tasks: PlanTask[],
	events: TaskEventEntry[] = []
): Promise<BrainOverviewStore> {
	brainTasks.mockResolvedValue(ok(tasks));
	brainTaskEvents.mockResolvedValue(ok(events));
	const store = new BrainOverviewStore('brain-1');
	await store.load();
	return store;
}

// ─── Pure group helpers ──────────────────────────────────────────────────────
describe('countStatuses / progressOf', () => {
	it('counts statuses and derives ready (open + unassigned + deps clear)', () => {
		const counts = countStatuses([
			task({ id: 'r', status: 'open', ready: true }),
			task({ id: 'o', status: 'open', ready: false, openDependenciesCount: 1 }),
			task({ id: 'w', status: 'in_progress' }),
			task({ id: 'd', status: 'done' }),
			task({ id: 'b', status: 'blocked' })
		]);
		expect(counts).toEqual({ inProgress: 1, ready: 1, done: 1, blocked: 1, total: 5 });
	});

	it('returns proportions that map onto the segmented bar', () => {
		const p = progressOf([
			task({ id: 'w', status: 'in_progress' }),
			task({ id: 'r', status: 'open', ready: true }),
			task({ id: 'd', status: 'done' }),
			task({ id: 'o', status: 'open', ready: false, openDependenciesCount: 1 })
		]);
		expect(p).toEqual({ inProgress: 0.25, ready: 0.25, done: 0.25 });
	});
});

// ─── Loading + header summary ────────────────────────────────────────────────
describe('header summary', () => {
	it('counts distinct plans, in-flight workers, and ready tasks', async () => {
		const store = await build([
			task({ id: 'r1', brainPageId: 'plan-a', status: 'open', ready: true }),
			task({ id: 'r2', brainPageId: 'plan-b', status: 'open', ready: true }),
			task({
				id: 'w1',
				brainPageId: 'plan-a',
				status: 'in_progress',
				assignedToUserId: 'user-self',
				claimedAt: freshClaim
			}),
			task({ id: 'arch', brainPageId: 'plan-a', status: 'archived' })
		]);

		// plan-a + plan-b have active tasks (archived excluded from the set, but it
		// still belongs to plan-a which already counts).
		expect(store.planCount).toBe(2);
		expect(store.readyCount).toBe(2);
		expect(store.inFlightCount).toBe(1);
		expect(store.counts.total).toBe(3); // archived excluded
	});

	it('reports a load error from the tasks call', async () => {
		brainTasks.mockResolvedValue(err('boom'));
		brainTaskEvents.mockResolvedValue(ok([]));
		const store = new BrainOverviewStore('brain-1');
		await store.load();
		expect(store.loading).toBe(false);
		expect(store.loadError).toBe('boom');
	});
});

// ─── IN FLIGHT grouping ──────────────────────────────────────────────────────
describe('inFlight', () => {
	it('groups in-progress tasks by distinct worker and excludes unassigned', async () => {
		const store = await build([
			task({
				id: 'w1',
				status: 'in_progress',
				assignedToAgent: 'claude-code',
				claimedAt: freshClaim,
				leaseExpiresAt: liveLease
			}),
			task({
				id: 'w2',
				status: 'in_progress',
				assignedToCustomAgentId: 'agent-teal',
				claimedAt: staleClaim,
				leaseExpiresAt: expiredLease
			}),
			// Unassigned in-progress task → no worker.
			task({ id: 'w3', status: 'in_progress', claimedAt: freshClaim }),
			// Not in progress → ignored.
			task({ id: 'r', status: 'open', ready: true })
		]);

		const workers = store.inFlight;
		expect(workers.map((w) => w.key).sort()).toEqual(['agent:Atlas', 'external:claude-code']);

		const external = workers.find((w) => w.assignee.kind === 'external')!;
		expect(external.name).toBe('claude-code');
		expect(external.typeLabel).toBe('external agent · terminal');
		expect(external.stale).toBe(false); // live lease

		const agent = workers.find((w) => w.assignee.kind === 'agent')!;
		expect(agent.name).toBe('Atlas');
		expect(agent.stale).toBe(true); // lease expired → reaper will reclaim
	});

	it('collapses multiple tasks for one worker, featuring the freshest/highest-priority', async () => {
		const store = await build([
			task({
				id: 'lo',
				status: 'in_progress',
				assignedToUserId: 'user-self',
				priority: 'low',
				claimedAt: '2026-06-24T08:00:00Z'
			}),
			task({
				id: 'hi',
				status: 'in_progress',
				assignedToUserId: 'user-self',
				priority: 'urgent',
				claimedAt: '2026-06-24T09:00:00Z'
			})
		]);

		expect(store.inFlight).toHaveLength(1);
		const me = store.inFlight[0];
		expect(me.assignee).toEqual({ kind: 'human', name: 'Ada', self: true });
		expect(me.tasks.map((t) => t.id)).toEqual(['hi', 'lo']); // priority-sorted
		expect(me.primary.id).toBe('hi');
		expect(me.claimedAt).toBe('2026-06-24T09:00:00Z'); // most recent claim
	});

	it('orders workers by freshest claim first', async () => {
		const store = await build([
			task({
				id: 'old',
				status: 'in_progress',
				assignedToAgent: 'claude-code',
				claimedAt: '2026-06-24T08:00:00Z'
			}),
			task({
				id: 'new',
				status: 'in_progress',
				assignedToCustomAgentId: 'agent-teal',
				claimedAt: '2026-06-24T11:00:00Z'
			})
		]);
		expect(store.inFlight.map((w) => w.key)).toEqual(['agent:Atlas', 'external:claude-code']);
	});
});

// ─── ROLLUP ──────────────────────────────────────────────────────────────────
describe('rollup', () => {
	const tasks = () => [
		task({
			id: 'a-wip',
			brainPageId: 'plan-a',
			status: 'in_progress',
			assignedToUserId: 'user-self',
			claimedAt: freshClaim
		}),
		task({ id: 'a-ready', brainPageId: 'plan-a', status: 'open', ready: true }),
		task({ id: 'a-done', brainPageId: 'plan-a', status: 'done' }),
		task({ id: 'b-blocked', brainPageId: 'plan-b', status: 'blocked' }),
		task({ id: 'b-ready', brainPageId: 'plan-b', status: 'open', ready: true })
	];

	it('by plan: one row per plan with counts, progress, workers; busiest first', async () => {
		const store = await build(tasks());
		store.rollupMode = 'plan';
		const rows = store.rollup;

		expect(rows.map((r) => r.key)).toEqual(['plan-a', 'plan-b']); // plan-a has the WIP
		const planA = rows[0];
		expect(planA.label).toBe('Launch plan');
		expect(planA.brainPageId).toBe('plan-a');
		expect(planA.counts).toEqual({ inProgress: 1, ready: 1, done: 1, blocked: 0, total: 3 });
		expect(planA.workers).toHaveLength(1);
		expect(planA.workers[0]).toEqual({ kind: 'human', name: 'Ada', self: true });

		const planB = rows[1];
		expect(planB.counts).toEqual({ inProgress: 0, ready: 1, done: 0, blocked: 1, total: 2 });
		expect(planB.workers).toHaveLength(0); // no one assigned
	});

	it('by assignee: groups by worker, unassigned pool sinks to the bottom', async () => {
		const store = await build(tasks());
		store.rollupMode = 'assignee';
		const rows = store.rollup;

		expect(rows[0].key).toBe('human:self');
		expect(rows[0].label).toBe('You'); // self renders as "You" in worker labels
		expect(rows[0].counts.inProgress).toBe(1);

		const unassigned = rows[rows.length - 1];
		expect(unassigned.key).toBe('__unassigned__');
		expect(unassigned.label).toBe('Unassigned');
		// The 4 unassigned tasks (ready×2, done, blocked).
		expect(unassigned.counts.total).toBe(4);
		expect(unassigned.workers).toHaveLength(0);
	});

	it('by status: fixed lane order, empty lanes dropped', async () => {
		const store = await build(tasks());
		store.rollupMode = 'status';
		const rows = store.rollup;

		expect(rows.map((r) => r.key)).toEqual(['in_progress', 'ready', 'blocked', 'done']);
		const ready = rows.find((r) => r.key === 'ready')!;
		expect(ready.counts.total).toBe(2); // both ready tasks across plans
	});

	it('by status: includes cancelled in the blocked lane', async () => {
		const store = await build([
			task({ id: 'c', status: 'cancelled' }),
			task({ id: 'b', status: 'blocked' })
		]);
		store.rollupMode = 'status';
		const blocked = store.rollup.find((r) => r.key === 'blocked')!;
		expect(blocked.counts.total).toBe(2);
	});
});

// ─── ACTIVITY feed ───────────────────────────────────────────────────────────
describe('activity', () => {
	it('orders newest-first and maps kinds to verbs', async () => {
		const store = await build(
			[task({ id: 'task-1', title: 'Write docs', brainPageId: 'plan-a' })],
			[
				event({ id: 'e-old', kind: 'created', insertedAt: '2026-06-24T08:00:00Z' }),
				event({ id: 'e-new', kind: 'completed', insertedAt: '2026-06-24T11:00:00Z' }),
				event({ id: 'e-mid', kind: 'claimed', insertedAt: '2026-06-24T10:00:00Z' })
			]
		);

		const feed = store.activity;
		expect(feed.map((e) => e.id)).toEqual(['e-new', 'e-mid', 'e-old']);
		expect(feed.map((e) => e.verb)).toEqual(['completed', 'claimed', 'created']);
		// Task + plan joins.
		expect(feed[0].taskTitle).toBe('Write docs');
		expect(feed[0].planTitle).toBe('Launch plan');
	});

	it('maps a lease_expired event to a reclaim verb', async () => {
		const store = await build(
			[task({ id: 'task-1', title: 'Migrate the schema' })],
			[
				event({
					id: 'reaped',
					kind: 'lease_expired',
					actorLabel: 'system:lease-reaper'
				})
			]
		);
		const entry = store.activity.find((e) => e.id === 'reaped')!;
		expect(entry.verb).toBe('reclaimed');
		expect(entry.actorLabel).toBe('system:lease-reaper');
	});

	it('maps status_changed to a verb from its metadata target status', async () => {
		const store = await build(
			[task({ id: 'task-1' })],
			[
				event({ id: 's1', kind: 'status_changed', metadata: { to: 'in_progress' } }),
				event({ id: 's2', kind: 'status_changed', metadata: { to_status: 'done' } }),
				event({ id: 's3', kind: 'status_changed', metadata: {} })
			]
		);
		const byId = Object.fromEntries(store.activity.map((e) => [e.id, e.verb]));
		expect(byId.s1).toBe('started');
		expect(byId.s2).toBe('completed');
		expect(byId.s3).toBe('updated'); // no target status → generic
	});

	it('detects the current user as the actor (self) and falls back for missing titles', async () => {
		const store = await build(
			[], // no tasks → the event's task title can't be joined
			[
				event({ id: 'mine', kind: 'claimed', actorLabel: 'Ada' }),
				event({ id: 'theirs', kind: 'claimed', actorLabel: 'claude-code' })
			]
		);
		const mine = store.activity.find((e) => e.id === 'mine')!;
		const theirs = store.activity.find((e) => e.id === 'theirs')!;
		expect(mine.isSelf).toBe(true);
		expect(theirs.isSelf).toBe(false);
		expect(mine.taskTitle).toBeNull(); // unknown task → view renders "a task"
	});
});

// ─── planTitle resolution ────────────────────────────────────────────────────
describe('planTitle', () => {
	it('maps a brain page id to its title, with fallbacks', async () => {
		const store = await build([]);
		expect(store.planTitle('plan-a')).toBe('Launch plan');
		expect(store.planTitle('unknown')).toBe('Untitled plan');
		expect(store.planTitle(null)).toBe('Unfiled');
	});
});

// ─── stranded work (anti-stranding alarm) ─────────────────────────────────────
describe('stranded plans + plan tree', () => {
	it('derives the stranded set + count from the loaded plan pages', async () => {
		brainPlanPages.mockResolvedValue(
			ok([
				strandedPage({ id: 'plan-a' }),
				strandedPage({ id: 'plan-b' }),
				planPage({ id: 'plan-c', lifecycle: 'delivered' })
			])
		);
		const store = await build([]);
		expect(store.strandedCount).toBe(2);
		expect(store.strandedPlans.map((p) => p.id).sort()).toEqual(['plan-a', 'plan-b']);
	});

	it('exposes the assembled tree from the same loaded pages', async () => {
		brainPlanPages.mockResolvedValue(
			ok([
				planPage({ id: 'plan', lifecycle: 'active' }),
				planPage({ id: 'phase', parentPageId: 'plan', lifecycle: 'active' })
			])
		);
		const store = await build([]);
		expect(store.tree.map((n) => n.id)).toEqual(['plan']);
		expect(store.tree[0].children.map((n) => n.id)).toEqual(['phase']);
	});

	it('reconciles the whole set on mark-delivered (recursive rollup can shift ancestors)', async () => {
		brainPlanPages
			.mockResolvedValueOnce(ok([strandedPage({ id: 'plan-a' })]))
			.mockResolvedValueOnce(
				ok([planPage({ id: 'plan-a', lifecycle: 'delivered', deliveryRef: 'v2' })])
			);
		markBrainPageDelivered.mockResolvedValue(
			ok(planPage({ id: 'plan-a', lifecycle: 'delivered', deliveryRef: 'v2' }))
		);
		const store = await build([]);
		expect(store.strandedCount).toBe(1);

		await store.markDelivered('plan-a', 'v2');

		expect(markBrainPageDelivered).toHaveBeenCalledWith('plan-a', 'v2');
		expect(brainPlanPages).toHaveBeenCalledTimes(2); // load + reconcile
		expect(store.strandedPlans).toEqual([]);
	});

	it('leaves the alarm intact when a delivery fails (server refetch restores it)', async () => {
		brainPlanPages
			.mockResolvedValueOnce(ok([strandedPage({ id: 'plan-a' })]))
			.mockResolvedValueOnce(ok([strandedPage({ id: 'plan-a' })]));
		markBrainPageDelivered.mockResolvedValue(err('forbidden'));
		const store = await build([]);

		await store.markDelivered('plan-a', null);

		expect(store.strandedPlans.map((p) => p.id)).toEqual(['plan-a']);
	});

	it('returns a plan to the stranded set after an undeliver', async () => {
		brainPlanPages
			.mockResolvedValueOnce(ok([planPage({ id: 'plan-a', lifecycle: 'delivered' })]))
			.mockResolvedValueOnce(ok([strandedPage({ id: 'plan-a' })]));
		undeliverBrainPage.mockResolvedValue(ok(strandedPage({ id: 'plan-a' })));
		const store = await build([]);
		expect(store.strandedCount).toBe(0);

		await store.undeliver('plan-a');

		expect(undeliverBrainPage).toHaveBeenCalledWith('plan-a');
		expect(store.strandedPlans.map((p) => p.id)).toEqual(['plan-a']);
	});
});
