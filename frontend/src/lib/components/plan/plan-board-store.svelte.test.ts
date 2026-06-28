import { describe, it, expect, vi, beforeEach } from 'vitest';

/**
 * Logic coverage for the plan-board store: status groupings, the ready/stale
 * derivations both views render from, assignee resolution (id → chip
 * descriptor), and the optimistic claim / status-change / add-task flows with
 * server reconciliation + refetch-on-error.
 *
 * Runs under the existing vitest config (environment: 'node'); the sveltekit()
 * vite plugin compiles the `.svelte.ts` runes module, so $state/$derived work
 * without jsdom (mirrors conversation-store.svelte.test.ts). The api.ts seam is
 * mocked so no network is touched.
 */

// ─── api.ts mock ─────────────────────────────────────────────────────────────
const planTasks = vi.fn();
const myAgents = vi.fn();
const claimPlanTask = vi.fn();
const updatePlanTask = vi.fn();
const createPlanTask = vi.fn();

vi.mock('$lib/ash/api', () => ({
	planTasks: (...args: unknown[]) => planTasks(...args),
	myAgents: (...args: unknown[]) => myAgents(...args),
	claimPlanTask: (...args: unknown[]) => claimPlanTask(...args),
	updatePlanTask: (...args: unknown[]) => updatePlanTask(...args),
	createPlanTask: (...args: unknown[]) => createPlanTask(...args)
}));

// Session store mock: a fixed current user so resolveAssignee can detect self.
vi.mock('$lib/stores/session.svelte', () => ({
	session: { user: { id: 'user-self', displayName: 'Ada', email: 'ada@example.com' } }
}));

import {
	PlanBoardStore,
	isReady,
	isStale,
	isAssigned,
	leaseState,
	leaseExpiresInMinutes,
	LEASE_EXPIRING_MS,
	loadBoardView,
	saveBoardView,
	type BoardView
} from './plan-board-store.svelte';
import type { PlanTask } from '$lib/ash/api';

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
		brainPageId: 'page-1',
		resultSummary: null,
		ready: null,
		subtaskCount: 0,
		completedSubtaskCount: 0,
		openDependenciesCount: 0,
		...overrides
	};
}

const ok = <T>(data: T) => ({ success: true as const, data });
const err = (message: string) => ({
	success: false as const,
	errors: [{ type: 'x', message, shortMessage: message, vars: {}, fields: [], path: [] }]
});

beforeEach(() => {
	vi.clearAllMocks();
	myAgents.mockResolvedValue(ok([{ id: 'agent-teal', name: 'Atlas' }]));
});

// ─── Pure derivations ────────────────────────────────────────────────────────
describe('ready / assigned / stale predicates', () => {
	it('trusts the server ready calc when present', () => {
		expect(isReady(task({ id: 't', ready: true, status: 'in_progress' }))).toBe(true);
		expect(isReady(task({ id: 't', ready: false, status: 'open' }))).toBe(false);
	});

	it('falls back to open + unassigned + deps-clear when ready is null', () => {
		expect(isReady(task({ id: 't', ready: null, status: 'open' }))).toBe(true);
		expect(isReady(task({ id: 't', ready: null, status: 'open', openDependenciesCount: 1 }))).toBe(
			false
		);
		expect(isReady(task({ id: 't', ready: null, status: 'open', assignedToUserId: 'u' }))).toBe(
			false
		);
		expect(isReady(task({ id: 't', ready: null, status: 'done' }))).toBe(false);
	});

	it('detects assignment across all three assignee fields', () => {
		expect(isAssigned(task({ id: 't' }))).toBe(false);
		expect(isAssigned(task({ id: 't', assignedToUserId: 'u' }))).toBe(true);
		expect(isAssigned(task({ id: 't', assignedToAgent: 'claude-code' }))).toBe(true);
		expect(isAssigned(task({ id: 't', assignedToCustomAgentId: 'a' }))).toBe(true);
	});

	it('derives lease state from leaseExpiresAt (expired / expiring / fresh)', () => {
		const now = Date.now();
		const past = new Date(now - 1000).toISOString();
		const soon = new Date(now + LEASE_EXPIRING_MS - 1000).toISOString();
		const later = new Date(now + 10 * 60_000).toISOString();

		expect(leaseState(task({ id: 't', status: 'in_progress', leaseExpiresAt: past }), now)).toBe(
			'expired'
		);
		expect(leaseState(task({ id: 't', status: 'in_progress', leaseExpiresAt: soon }), now)).toBe(
			'expiring'
		);
		expect(leaseState(task({ id: 't', status: 'in_progress', leaseExpiresAt: later }), now)).toBe(
			'fresh'
		);
		// No lease recorded → no signal (fresh).
		expect(leaseState(task({ id: 't', status: 'in_progress', leaseExpiresAt: null }), now)).toBe(
			'fresh'
		);
		// Only in-progress tasks carry a lease.
		expect(leaseState(task({ id: 't', status: 'open', leaseExpiresAt: past }), now)).toBe('fresh');
	});

	it('isStale is true only for an expired in-progress lease', () => {
		const now = Date.now();
		const past = new Date(now - 1000).toISOString();
		const later = new Date(now + 10 * 60_000).toISOString();
		expect(isStale(task({ id: 't', status: 'in_progress', leaseExpiresAt: past }), now)).toBe(true);
		expect(isStale(task({ id: 't', status: 'in_progress', leaseExpiresAt: later }), now)).toBe(
			false
		);
		// A claim without a lease signal is never stale.
		expect(
			isStale(task({ id: 't', status: 'in_progress', leaseExpiresAt: null, claimedAt: past }), now)
		).toBe(false);
		expect(isStale(task({ id: 't', status: 'open', leaseExpiresAt: past }), now)).toBe(false);
	});

	it('reports whole minutes until a live lease expires (null when none/expired)', () => {
		const now = Date.now();
		const inFive = new Date(now + 5 * 60_000).toISOString();
		expect(
			leaseExpiresInMinutes(task({ id: 't', status: 'in_progress', leaseExpiresAt: inFive }), now)
		).toBe(5);
		// Rounds up partial minutes, floored at 1.
		const in30s = new Date(now + 30_000).toISOString();
		expect(
			leaseExpiresInMinutes(task({ id: 't', status: 'in_progress', leaseExpiresAt: in30s }), now)
		).toBe(1);
		// Expired / no lease → null.
		const past = new Date(now - 1000).toISOString();
		expect(
			leaseExpiresInMinutes(task({ id: 't', status: 'in_progress', leaseExpiresAt: past }), now)
		).toBeNull();
		expect(
			leaseExpiresInMinutes(task({ id: 't', status: 'in_progress', leaseExpiresAt: null }), now)
		).toBeNull();
	});
});

describe('board-view persistence', () => {
	it('round-trips the view through localStorage and defaults to columns', () => {
		const store: Record<string, string> = {};
		vi.stubGlobal('localStorage', {
			getItem: (k: string) => store[k] ?? null,
			setItem: (k: string, v: string) => {
				store[k] = v;
			}
		});
		expect(loadBoardView('page-1')).toBe<BoardView>('columns');
		saveBoardView('page-1', 'list');
		expect(loadBoardView('page-1')).toBe<BoardView>('list');
		vi.unstubAllGlobals();
	});
});

// ─── Store: loading + groupings ──────────────────────────────────────────────
describe('PlanBoardStore groupings', () => {
	it('groups tasks by status and computes counts + readiness', async () => {
		planTasks.mockResolvedValue(
			ok([
				task({ id: 'ready', status: 'open', ready: true, priority: 'high' }),
				task({ id: 'open-blocked-deps', status: 'open', ready: false, openDependenciesCount: 1 }),
				task({ id: 'wip', status: 'in_progress', assignedToUserId: 'user-self' }),
				task({ id: 'done', status: 'done' }),
				task({ id: 'blocked', status: 'blocked' }),
				task({ id: 'cancelled', status: 'cancelled' }),
				task({ id: 'archived', status: 'archived' })
			])
		);

		const board = new PlanBoardStore('page-1');
		await board.load();

		expect(board.loading).toBe(false);
		// archived is excluded from the active set entirely.
		expect(board.active.map((t) => t.id)).not.toContain('archived');
		expect(board.todo.map((t) => t.id).sort()).toEqual(['open-blocked-deps', 'ready']);
		expect(board.inProgress.map((t) => t.id)).toEqual(['wip']);
		expect(board.done.map((t) => t.id)).toEqual(['done']);
		// Blocked lane carries blocked + cancelled.
		expect(board.blockedLane.map((t) => t.id).sort()).toEqual(['blocked', 'cancelled']);
		// Only the truly-ready open task counts as ready.
		expect(board.ready.map((t) => t.id)).toEqual(['ready']);

		expect(board.counts).toEqual({ inProgress: 1, ready: 1, done: 1, blocked: 1 });
		// allTodoReady is false: one open task has open deps.
		expect(board.allTodoReady).toBe(false);
	});

	it('sorts a column by priority then position', async () => {
		planTasks.mockResolvedValue(
			ok([
				task({ id: 'low', status: 'open', priority: 'low', ready: false, position: 0 }),
				task({ id: 'urgent', status: 'open', priority: 'urgent', ready: false, position: 9 }),
				task({ id: 'normal', status: 'open', priority: 'normal', ready: false, position: 1 })
			])
		);
		const board = new PlanBoardStore('page-1');
		await board.load();
		expect(board.todo.map((t) => t.id)).toEqual(['urgent', 'normal', 'low']);
	});

	it('reports a load error', async () => {
		planTasks.mockResolvedValue(err('boom'));
		const board = new PlanBoardStore('page-1');
		await board.load();
		expect(board.loading).toBe(false);
		expect(board.loadError).toBe('boom');
	});
});

// ─── Store: assignee resolution ──────────────────────────────────────────────
describe('resolveAssignee', () => {
	it('maps each assignee field to the right chip descriptor', async () => {
		planTasks.mockResolvedValue(ok([]));
		const board = new PlanBoardStore('page-1');
		await board.load(); // loads the agent-name lookup (Atlas)

		expect(board.resolveAssignee(task({ id: 't' }))).toBeNull();

		expect(board.resolveAssignee(task({ id: 't', assignedToUserId: 'user-self' }))).toEqual({
			kind: 'human',
			name: 'Ada',
			self: true
		});
		expect(
			board.resolveAssignee(task({ id: 't', assignedToUserId: 'someone-else' }))
		).toMatchObject({ kind: 'human', self: false });
		expect(board.resolveAssignee(task({ id: 't', assignedToAgent: 'claude-code' }))).toEqual({
			kind: 'external',
			label: 'claude-code'
		});
		expect(board.resolveAssignee(task({ id: 't', assignedToCustomAgentId: 'agent-teal' }))).toEqual(
			{
				kind: 'agent',
				name: 'Atlas'
			}
		);
	});
});

// ─── Store: optimistic mutations ─────────────────────────────────────────────
describe('claim', () => {
	it('optimistically moves a ready task into In Progress, then reconciles', async () => {
		planTasks.mockResolvedValue(ok([task({ id: 'ready', status: 'open', ready: true })]));
		const board = new PlanBoardStore('page-1');
		await board.load();

		let resolveClaim!: (v: unknown) => void;
		claimPlanTask.mockReturnValue(new Promise((r) => (resolveClaim = r)));

		const promise = board.claim(board.todo[0]);

		// Optimistic: already in In Progress, assigned to self, pending flagged.
		expect(board.inProgress.map((t) => t.id)).toEqual(['ready']);
		expect(board.ready).toHaveLength(0);
		expect(board.pending.has('ready')).toBe(true);
		expect(claimPlanTask).toHaveBeenCalledWith('ready', { assignedToUserId: 'user-self' });

		resolveClaim(
			ok(task({ id: 'ready', status: 'in_progress', assignedToUserId: 'user-self', ready: false }))
		);
		await promise;

		expect(board.inProgress.map((t) => t.id)).toEqual(['ready']);
		expect(board.pending.has('ready')).toBe(false);
	});

	it('refetches to roll back when the claim fails (lost race)', async () => {
		planTasks.mockResolvedValueOnce(ok([task({ id: 'ready', status: 'open', ready: true })]));
		const board = new PlanBoardStore('page-1');
		await board.load();

		claimPlanTask.mockResolvedValue(err('already claimed'));
		// The rollback refetch sees the task taken by someone else.
		planTasks.mockResolvedValueOnce(
			ok([task({ id: 'ready', status: 'in_progress', assignedToAgent: 'claude-code' })])
		);

		await board.claim(board.todo[0]);

		expect(board.ready).toHaveLength(0);
		expect(board.inProgress.map((t) => t.id)).toEqual(['ready']);
		expect(board.resolveAssignee(board.inProgress[0])).toEqual({
			kind: 'external',
			label: 'claude-code'
		});
		expect(board.pending.has('ready')).toBe(false);
	});

	it('is a no-op without a current user', async () => {
		const sessionModule = await import('$lib/stores/session.svelte');
		const original = sessionModule.session.user;
		sessionModule.session.user = null;

		planTasks.mockResolvedValue(ok([task({ id: 'ready', status: 'open', ready: true })]));
		const board = new PlanBoardStore('page-1');
		await board.load();
		await board.claim(board.todo[0]);
		expect(claimPlanTask).not.toHaveBeenCalled();

		sessionModule.session.user = original;
	});
});

describe('setStatus', () => {
	it('optimistically applies a status change (drag between columns)', async () => {
		planTasks.mockResolvedValue(ok([task({ id: 'wip', status: 'in_progress' })]));
		const board = new PlanBoardStore('page-1');
		await board.load();

		updatePlanTask.mockResolvedValue(ok(task({ id: 'wip', status: 'done' })));
		await board.setStatus(board.inProgress[0], 'done');

		expect(updatePlanTask).toHaveBeenCalledWith('wip', { status: 'done' });
		expect(board.done.map((t) => t.id)).toEqual(['wip']);
		expect(board.inProgress).toHaveLength(0);
	});

	it('ignores a no-op status change to the same status', async () => {
		planTasks.mockResolvedValue(ok([task({ id: 'wip', status: 'in_progress' })]));
		const board = new PlanBoardStore('page-1');
		await board.load();
		await board.setStatus(board.inProgress[0], 'in_progress');
		expect(updatePlanTask).not.toHaveBeenCalled();
	});
});

describe('addTask', () => {
	it('creates and appends a task; trims and ignores blanks', async () => {
		planTasks.mockResolvedValue(ok([]));
		const board = new PlanBoardStore('page-1');
		await board.load();

		await board.addTask('   ');
		expect(createPlanTask).not.toHaveBeenCalled();

		createPlanTask.mockResolvedValue(ok(task({ id: 'new', title: 'Ship it', status: 'open' })));
		await board.addTask('  Ship it  ');
		expect(createPlanTask).toHaveBeenCalledWith('page-1', { title: 'Ship it' });
		expect(board.active.map((t) => t.id)).toContain('new');
	});
});
