/**
 * State + mutations for one plan-page task board (kanban ⇄ list).
 *
 * Owns the task list, the derived status groupings both views render, and the
 * optimistic mutation flows (claim / status change / add). Assignee resolution
 * lives here too: a task carries only ids, so the board joins the current user
 * (from the session store) and a custom-agent name lookup into the resolved
 * {@link Assignee} descriptor the chip renders.
 *
 * Mirrors the prompts/tasks-companion pattern: a thin class of `$state` fields
 * with async methods, optimistic local writes reconciled from the server row,
 * and a refetch on error. Live cross-client updates (other agents claiming /
 * moving cards) are wired in plan-board.svelte: it subscribes to the plan's
 * task channel and calls `load()` on each `task.*` event (B6).
 */
import {
	planTasks,
	createPlanTask,
	updatePlanTask,
	claimPlanTask,
	myAgents,
	type PlanTask,
	type TaskStatus,
	type TaskPriority
} from '$lib/ash/api';
import { session } from '$lib/stores/session.svelte';
import type { Assignee } from './assignee-chip.svelte';
import { resolveAssignee } from './assignee';

/**
 * A claim renews a 900s lease on each heartbeat/activity; the reaper reclaims it
 * once `leaseExpiresAt` passes. A claim within this window of expiry reads as
 * "expiring" (an amber heads-up before the reaper steps in).
 */
export const LEASE_EXPIRING_MS = 2 * 60 * 1000;

export type BoardView = 'list' | 'columns';

const VIEW_STORAGE_PREFIX = 'magus:next:plan-view:';

/** Read the persisted list/columns choice for a plan (localStorage, per page). */
export function loadBoardView(brainPageId: string): BoardView {
	if (typeof localStorage === 'undefined') return 'columns';
	return localStorage.getItem(VIEW_STORAGE_PREFIX + brainPageId) === 'list' ? 'list' : 'columns';
}

export function saveBoardView(brainPageId: string, view: BoardView): void {
	if (typeof localStorage === 'undefined') return;
	localStorage.setItem(VIEW_STORAGE_PREFIX + brainPageId, view);
}

/** Priority order for sorting within a column/group (urgent first). */
const PRIORITY_RANK: Record<TaskPriority, number> = { urgent: 0, high: 1, normal: 2, low: 3 };

/** A task is "ready" when the server says so, or (fallback) open + unassigned + deps clear. */
export function isReady(task: PlanTask): boolean {
	if (task.ready !== null) return task.ready;
	return (
		task.status === 'open' &&
		task.assignedToUserId === null &&
		task.assignedToAgent === null &&
		task.assignedToCustomAgentId === null &&
		task.openDependenciesCount === 0
	);
}

export function isAssigned(task: PlanTask): boolean {
	return (
		task.assignedToUserId !== null ||
		task.assignedToAgent !== null ||
		task.assignedToCustomAgentId !== null
	);
}

/**
 * Lease freshness for an in-progress claim, derived from `leaseExpiresAt`:
 *  - `expired`: the lease has lapsed; the reaper will/has reclaimed the task.
 *  - `expiring`: the lease lapses within {@link LEASE_EXPIRING_MS} (amber warning).
 *  - `fresh`: a live lease (or, when no lease is recorded, no signal to show).
 *
 * A null `leaseExpiresAt` on an in-progress task means no lease signal, treated
 * as `fresh` (the UI shows nothing). Only in-progress tasks carry a lease.
 */
export type LeaseState = 'fresh' | 'expiring' | 'expired';

export function leaseState(task: PlanTask, now: number = Date.now()): LeaseState {
	if (task.status !== 'in_progress' || !task.leaseExpiresAt) return 'fresh';
	const remaining = new Date(task.leaseExpiresAt).getTime() - now;
	if (remaining <= 0) return 'expired';
	if (remaining <= LEASE_EXPIRING_MS) return 'expiring';
	return 'fresh';
}

/**
 * Whole minutes until an in-progress claim's lease expires, or null when there
 * is no live future lease. Used for the "expires in Xm" heads-up.
 */
export function leaseExpiresInMinutes(task: PlanTask, now: number = Date.now()): number | null {
	if (task.status !== 'in_progress' || !task.leaseExpiresAt) return null;
	const remaining = new Date(task.leaseExpiresAt).getTime() - now;
	if (remaining <= 0) return null;
	return Math.max(1, Math.ceil(remaining / 60_000));
}

/**
 * Whether an in-progress claim's lease has expired (the reaper will reclaim it).
 * Kept as `isStale` so existing call sites and `data-stale` hooks stay stable.
 */
export function isStale(task: PlanTask, now: number = Date.now()): boolean {
	return leaseState(task, now) === 'expired';
}

function byPriorityThenPosition(a: PlanTask, b: PlanTask): number {
	const rank = PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority];
	if (rank !== 0) return rank;
	return (a.position ?? 0) - (b.position ?? 0);
}

export class PlanBoardStore {
	brainPageId = $state('');
	tasks = $state<PlanTask[]>([]);
	loading = $state(true);
	loadError = $state<string | null>(null);
	/** Ids with a claim/status mutation in flight (disables the affordance). */
	pending = $state<Set<string>>(new Set());
	/** Custom-agent id → display name, for resolving in-app agent chips. */
	private agentNames = $state<Map<string, string>>(new Map());

	constructor(brainPageId: string) {
		this.brainPageId = brainPageId;
	}

	// ── Loading ────────────────────────────────────────────────────────────
	async load(): Promise<void> {
		const id = this.brainPageId;
		this.loading = true;
		this.loadError = null;
		const [tasksResult, agentsResult] = await Promise.all([planTasks(id), myAgents()]);
		if (id !== this.brainPageId) return;
		if (agentsResult.success) {
			this.agentNames = new Map(agentsResult.data.map((agent) => [agent.id, agent.name]));
		}
		if (tasksResult.success) {
			this.tasks = tasksResult.data;
		} else {
			this.loadError = tasksResult.errors[0]?.message ?? 'Tasks could not be loaded';
		}
		this.loading = false;
	}

	private async refetch(): Promise<void> {
		const id = this.brainPageId;
		const result = await planTasks(id);
		if (id === this.brainPageId && result.success) this.tasks = result.data;
	}

	private upsert(task: PlanTask): void {
		const index = this.tasks.findIndex((t) => t.id === task.id);
		this.tasks =
			index >= 0 ? this.tasks.map((t) => (t.id === task.id ? task : t)) : [...this.tasks, task];
	}

	private setPending(id: string, on: boolean): void {
		const next = new Set(this.pending);
		if (on) next.add(id);
		else next.delete(id);
		this.pending = next;
	}

	// ── Derived groupings (both views read these) ───────────────────────────
	get active(): PlanTask[] {
		return this.tasks.filter((t) => t.status !== 'archived');
	}

	get todo(): PlanTask[] {
		return this.active.filter((t) => t.status === 'open').sort(byPriorityThenPosition);
	}

	get inProgress(): PlanTask[] {
		return this.active.filter((t) => t.status === 'in_progress').sort(byPriorityThenPosition);
	}

	get done(): PlanTask[] {
		return this.active.filter((t) => t.status === 'done').sort(byPriorityThenPosition);
	}

	/** The right-hand overflow lane: blocked + cancelled. */
	get blockedLane(): PlanTask[] {
		return this.active
			.filter((t) => t.status === 'blocked' || t.status === 'cancelled')
			.sort(byPriorityThenPosition);
	}

	get ready(): PlanTask[] {
		return this.todo.filter((t) => isReady(t));
	}

	get readyCount(): number {
		return this.ready.length;
	}

	get blockedCount(): number {
		return this.active.filter((t) => t.status === 'blocked').length;
	}

	/** True when every open task is ready (the "all ready" To-Do column pill). */
	get allTodoReady(): boolean {
		return this.todo.length > 0 && this.todo.every((t) => isReady(t));
	}

	get counts(): { inProgress: number; ready: number; done: number; blocked: number } {
		return {
			inProgress: this.inProgress.length,
			ready: this.readyCount,
			done: this.done.length,
			blocked: this.blockedCount
		};
	}

	/** Proportions for the segmented summary progress bar (sum may be < 1). */
	get progress(): { inProgress: number; ready: number; done: number } {
		const total = this.active.length || 1;
		return {
			inProgress: this.inProgress.length / total,
			ready: this.readyCount / total,
			done: this.done.length / total
		};
	}

	// ── Assignee resolution (shared with the brain overview) ────────────────
	resolveAssignee(task: PlanTask): Assignee | null {
		return resolveAssignee(task, this.agentNames);
	}

	// ── Mutations (optimistic, server-reconciled) ───────────────────────────
	async claim(task: PlanTask): Promise<void> {
		const userId = session.user?.id;
		if (!userId || this.pending.has(task.id)) return;
		this.setPending(task.id, true);
		// Optimistic: move into In Progress, assigned to me, claimed now with a
		// fresh 900s lease (the server sets the authoritative value on success).
		const nowMs = Date.now();
		this.upsert({
			...task,
			status: 'in_progress',
			assignedToUserId: userId,
			claimedAt: new Date(nowMs).toISOString(),
			leaseExpiresAt: new Date(nowMs + 900_000).toISOString(),
			ready: false
		});
		const result = await claimPlanTask(task.id, { assignedToUserId: userId });
		if (result.success) this.upsert(result.data);
		else await this.refetch();
		this.setPending(task.id, false);
	}

	async setStatus(task: PlanTask, status: TaskStatus): Promise<void> {
		if (task.status === status || this.pending.has(task.id)) return;
		this.setPending(task.id, true);
		this.upsert({ ...task, status });
		const result = await updatePlanTask(task.id, { status });
		if (result.success) this.upsert(result.data);
		else await this.refetch();
		this.setPending(task.id, false);
	}

	async addTask(title: string): Promise<void> {
		const trimmed = title.trim();
		if (!trimmed) return;
		const result = await createPlanTask(this.brainPageId, { title: trimmed });
		if (result.success) this.upsert(result.data);
		else await this.refetch();
	}

	/**
	 * Create a task from the full add-task form: title (required) plus optional
	 * description, priority, and due date. Mirrors `addTask`'s upsert/refetch
	 * handling; returns true on success so the dialog can close.
	 */
	async createTask(input: {
		title: string;
		description?: string;
		priority?: TaskPriority;
		dueAt?: string | null;
	}): Promise<boolean> {
		const title = input.title.trim();
		if (!title) return false;
		const payload: {
			title: string;
			description?: string;
			priority?: TaskPriority;
			dueAt?: string | null;
		} = { title };
		const description = input.description?.trim();
		if (description) payload.description = description;
		if (input.priority) payload.priority = input.priority;
		if (input.dueAt) payload.dueAt = input.dueAt;
		const result = await createPlanTask(this.brainPageId, payload);
		if (result.success) {
			this.upsert(result.data);
			return true;
		}
		await this.refetch();
		return false;
	}
}
