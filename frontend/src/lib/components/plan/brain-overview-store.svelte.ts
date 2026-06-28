/**
 * State + derivations for the Brain Overview coordination dashboard.
 *
 * A read-only, brain-level view over every plan task in one brain. It loads the
 * brain's tasks + recent task events (the existing RPC seam), the actor's custom
 * agents (to name in-app agent workers), and the brain's page tree (to map a
 * task's `brainPageId` → its plan title), then derives the three regions the
 * page renders:
 *
 *  - IN FLIGHT  : one worker per distinct assignee on an `in_progress` task,
 *                 with the task they're on + a staleness flag.
 *  - ROLLUP     : groupable by plan / assignee / status; per-group status counts,
 *                 a segmented progress proportion, and the distinct workers.
 *  - ACTIVITY   : the reverse-chron event feed, each event mapped to an actor +
 *                 verb + task + plan + relative time.
 *
 * All derivations are pure and unit-tested (brain-overview-store.svelte.test.ts);
 * the api.ts seam is the only I/O. Live cross-client updates (C3) are wired in
 * the overview route: it subscribes to the brain's task channel and calls
 * `reload()` on each `task.*` event. The store exposes `reload()` for that (and
 * for a manual / focus refresh).
 */
import {
	brainTasks,
	brainTaskEvents,
	brainPlanPages,
	markBrainPageDelivered,
	undeliverBrainPage,
	myAgents,
	type PlanTask,
	type PlanPage,
	type TaskStatus,
	type TaskPriority,
	type TaskEventEntry,
	type TaskEventKind
} from '$lib/ash/api';
import { session } from '$lib/stores/session.svelte';
import type { Assignee } from './assignee-chip.svelte';
import { resolveAssignee, assigneeKey, assigneeName, assigneeTypeLabel } from './assignee';
import { isReady, isStale, LEASE_EXPIRING_MS } from './plan-board-store.svelte';
import { buildPlanTree, isStranded, type PlanTreeNode } from './plan-tree-store.svelte';

export type { PlanTreeNode };

export { LEASE_EXPIRING_MS };

export type RollupMode = 'plan' | 'assignee' | 'status';

/** Priority order for sorting tasks within a worker card / group (urgent first). */
const PRIORITY_RANK: Record<TaskPriority, number> = { urgent: 0, high: 1, normal: 2, low: 3 };

function byPriorityThenClaimed(a: PlanTask, b: PlanTask): number {
	const rank = PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority];
	if (rank !== 0) return rank;
	// More-recent claims first within a priority (fresh work surfaces on top).
	return (b.claimedAt ?? '').localeCompare(a.claimedAt ?? '');
}

/** A distinct worker currently on at least one in-progress task. */
export type InFlightWorker = {
	key: string;
	assignee: Assignee;
	name: string;
	typeLabel: string;
	/** The in-progress tasks this worker holds, freshest first. */
	tasks: PlanTask[];
	/** The primary task to feature on the card (the freshest / highest priority). */
	primary: PlanTask;
	/** Most recent claim across this worker's tasks (drives the card's "Xm ago"). */
	claimedAt: string | null;
	/** True when the primary task's lease has expired (the reaper will reclaim it). */
	stale: boolean;
};

/** Per-status counts for a rollup row + the summary header. */
export type StatusCounts = {
	inProgress: number;
	ready: number;
	done: number;
	blocked: number;
	total: number;
};

/** Segmented progress proportions (0..1; sum may be < 1, the remainder is "to do"). */
export type Progress = { inProgress: number; ready: number; done: number };

/** One row in the rollup, keyed by plan / assignee / status depending on mode. */
export type RollupRow = {
	key: string;
	label: string;
	/** For `plan` mode: the plan page id (links the row to its page). */
	brainPageId: string | null;
	counts: StatusCounts;
	progress: Progress;
	/** Distinct workers with a task in this group (empty = no one assigned). */
	workers: Assignee[];
};

/** A single activity-feed entry, fully resolved for rendering. */
export type ActivityEntry = {
	id: string;
	kind: TaskEventKind;
	/** Verb shown after the actor ("created", "claimed", "started", …). */
	verb: string;
	/** Actor display label; `isSelf` lets the view render "You". */
	actorLabel: string;
	isSelf: boolean;
	taskId: string;
	/** Resolved task title, or null when the task no longer exists. */
	taskTitle: string | null;
	brainPageId: string;
	planTitle: string;
	insertedAt: string;
};

/** Event kind → past-tense verb for the feed. */
function verbFor(event: TaskEventEntry): string {
	switch (event.kind) {
		case 'created':
			return 'created';
		case 'claimed':
			return 'claimed';
		case 'released':
			return 'released';
		case 'completed':
			return 'completed';
		case 'reassigned':
			return 'reassigned';
		case 'lease_expired':
			return 'reclaimed';
		case 'status_changed': {
			// Differentiate "started" (→ in_progress) from a generic move when the
			// event metadata records the target status; fall back to "updated".
			const to = (event.metadata?.to ?? event.metadata?.to_status ?? event.metadata?.status) as
				| string
				| undefined;
			if (to === 'in_progress') return 'started';
			if (to === 'done') return 'completed';
			if (to === 'blocked') return 'flagged blocked';
			return 'updated';
		}
	}
}

export class BrainOverviewStore {
	brainId = $state('');
	tasks = $state<PlanTask[]>([]);
	events = $state<TaskEventEntry[]>([]);
	/** Every :plan / :spec / :page in the brain with its lifecycle rollup loaded.
	 *  Drives the plan tree, the stranded set, and the plan-title lookup. */
	planPages = $state<PlanPage[]>([]);
	/** Plan ids with a deliver/undeliver mutation in flight (disables the control). */
	deliverPending = $state<Set<string>>(new Set());
	loading = $state(true);
	loadError = $state<string | null>(null);
	/** Which dimension the rollup groups by (segmented toggle). */
	rollupMode = $state<RollupMode>('plan');

	/** custom-agent id → display name, for in-app agent workers. */
	private agentNames = $state<Map<string, string>>(new Map());
	/** brain page id → plan title, for the rollup + activity plan labels. */
	private pageTitles = $state<Map<string, string>>(new Map());

	constructor(brainId: string) {
		this.brainId = brainId;
	}

	// ── Loading ────────────────────────────────────────────────────────────
	async load(): Promise<void> {
		const id = this.brainId;
		this.loading = true;
		this.loadError = null;

		const [tasksResult, eventsResult, agentsResult, pagesResult] = await Promise.all([
			brainTasks(id),
			brainTaskEvents(id),
			myAgents(),
			brainPlanPages(id)
		]);
		if (id !== this.brainId) return;

		if (agentsResult.success) {
			this.agentNames = new Map(agentsResult.data.map((agent) => [agent.id, agent.name]));
		}
		if (pagesResult.success) {
			this.planPages = pagesResult.data;
			this.pageTitles = new Map(
				pagesResult.data.map((page) => [page.id, page.title ?? 'Untitled plan'])
			);
		}
		if (eventsResult.success) this.events = eventsResult.data;

		if (tasksResult.success) {
			this.tasks = tasksResult.data;
		} else {
			this.loadError = tasksResult.errors[0]?.message ?? 'Overview could not be loaded';
		}
		this.loading = false;
	}

	/** Refresh from the server, driven by the route's live task subscription (C3)
	 * on each `task.*` event, and available for a manual / focus refresh. */
	async reload(): Promise<void> {
		await this.load();
	}

	private setDeliverPending(id: string, on: boolean): void {
		const next = new Set(this.deliverPending);
		if (on) next.add(id);
		else next.delete(id);
		this.deliverPending = next;
	}

	/**
	 * Refetch every plan page after a delivery change. A delivery flips one page's
	 * gate, but the recursive lifecycle rollup means an ancestor's lifecycle can
	 * change too (a phase delivered → its parent plan becomes done/delivered), so
	 * the whole set is reloaded rather than patching a single row.
	 */
	private async refetchPlanPages(): Promise<void> {
		const id = this.brainId;
		const result = await brainPlanPages(id);
		if (id === this.brainId && result.success) this.planPages = result.data;
	}

	/**
	 * Close out a plan: stamp its delivery gate (optionally with a reference). The
	 * tree + stranded set derive from `planPages`, so reconciling the whole set
	 * keeps the recursive rollup correct. A failed delivery leaves the set as-is.
	 */
	async markDelivered(pageId: string, deliveryRef: string | null): Promise<void> {
		if (this.deliverPending.has(pageId)) return;
		this.setDeliverPending(pageId, true);
		await markBrainPageDelivered(pageId, deliveryRef);
		await this.refetchPlanPages();
		this.setDeliverPending(pageId, false);
	}

	/** Reverse a mistaken delivery; the plan returns to its derived lifecycle. */
	async undeliver(pageId: string): Promise<void> {
		if (this.deliverPending.has(pageId)) return;
		this.setDeliverPending(pageId, true);
		await undeliverBrainPage(pageId);
		await this.refetchPlanPages();
		this.setDeliverPending(pageId, false);
	}

	// ── Plan tree + stranded set (derived from planPages) ────────────────────
	/** The unified spec -> plan -> phases -> tasks tree. */
	get tree(): PlanTreeNode[] {
		return buildPlanTree(this.planPages, this.tasks);
	}

	/** Done-but-not-delivered plans: the anti-stranding alarm list. */
	get strandedPlans(): PlanPage[] {
		return this.planPages.filter(isStranded);
	}

	/** Count of plans complete but not yet delivered (the alarm badge). */
	get strandedCount(): number {
		return this.strandedPlans.length;
	}

	// ── Shared helpers ───────────────────────────────────────────────────────
	private resolve(task: PlanTask): Assignee | null {
		return resolveAssignee(task, this.agentNames);
	}

	planTitle(brainPageId: string | null): string {
		if (!brainPageId) return 'Unfiled';
		return this.pageTitles.get(brainPageId) ?? 'Untitled plan';
	}

	get active(): PlanTask[] {
		return this.tasks.filter((t) => t.status !== 'archived');
	}

	// ── Header summary ───────────────────────────────────────────────────────
	/** Distinct plan pages that have at least one (non-archived) task. */
	get planCount(): number {
		return new Set(this.active.map((t) => t.brainPageId)).size;
	}

	get readyCount(): number {
		return this.active.filter((t) => isReady(t)).length;
	}

	get inFlightCount(): number {
		return this.inFlight.length;
	}

	get counts(): StatusCounts {
		return countStatuses(this.active);
	}

	// ── IN FLIGHT (workers on in-progress tasks) ─────────────────────────────
	get inFlight(): InFlightWorker[] {
		const groups = new Map<string, { assignee: Assignee; tasks: PlanTask[] }>();
		for (const task of this.active) {
			if (task.status !== 'in_progress') continue;
			const assignee = this.resolve(task);
			if (!assignee) continue; // an unassigned in-progress task has no worker
			const key = assigneeKey(assignee);
			const group = groups.get(key);
			if (group) group.tasks.push(task);
			else groups.set(key, { assignee, tasks: [task] });
		}

		const now = Date.now();
		const workers = [...groups.entries()].map(([key, { assignee, tasks }]) => {
			const sorted = [...tasks].sort(byPriorityThenClaimed);
			const primary = sorted[0];
			const claimedAt = sorted.reduce<string | null>(
				(latest, t) => (t.claimedAt && (!latest || t.claimedAt > latest) ? t.claimedAt : latest),
				null
			);
			return {
				key,
				assignee,
				name: assigneeName(assignee),
				typeLabel: assigneeTypeLabel(assignee),
				tasks: sorted,
				primary,
				claimedAt,
				stale: isStale(primary, now)
			} satisfies InFlightWorker;
		});

		// Freshest claim first, so the most-recently-active worker leads.
		return workers.sort((a, b) => (b.claimedAt ?? '').localeCompare(a.claimedAt ?? ''));
	}

	// ── ROLLUP (by plan / assignee / status) ─────────────────────────────────
	get rollup(): RollupRow[] {
		switch (this.rollupMode) {
			case 'plan':
				return this.rollupByPlan();
			case 'assignee':
				return this.rollupByAssignee();
			case 'status':
				return this.rollupByStatus();
		}
	}

	private rollupByPlan(): RollupRow[] {
		const groups = new Map<string, PlanTask[]>();
		for (const task of this.active) {
			const key = task.brainPageId ?? '__unfiled__';
			(groups.get(key) ?? groups.set(key, []).get(key)!).push(task);
		}
		const rows = [...groups.entries()].map(([key, tasks]) => {
			const brainPageId = key === '__unfiled__' ? null : key;
			return {
				key,
				label: this.planTitle(brainPageId),
				brainPageId,
				counts: countStatuses(tasks),
				progress: progressOf(tasks),
				workers: this.workersOf(tasks)
			} satisfies RollupRow;
		});
		// Busiest plans first (most in-progress, then most total).
		return rows.sort(
			(a, b) => b.counts.inProgress - a.counts.inProgress || b.counts.total - a.counts.total
		);
	}

	private rollupByAssignee(): RollupRow[] {
		const groups = new Map<string, { assignee: Assignee | null; tasks: PlanTask[] }>();
		for (const task of this.active) {
			const assignee = this.resolve(task);
			const key = assignee ? assigneeKey(assignee) : '__unassigned__';
			const group = groups.get(key);
			if (group) group.tasks.push(task);
			else groups.set(key, { assignee, tasks: [task] });
		}
		const rows = [...groups.entries()].map(([key, { assignee, tasks }]) => ({
			key,
			label: assignee ? assigneeName(assignee) : 'Unassigned',
			brainPageId: null,
			counts: countStatuses(tasks),
			progress: progressOf(tasks),
			workers: assignee ? [assignee] : []
		}));
		// Most in-progress first; unassigned (a pool, not a worker) sinks last.
		return rows.sort((a, b) => {
			if (a.key === '__unassigned__') return 1;
			if (b.key === '__unassigned__') return -1;
			return b.counts.inProgress - a.counts.inProgress || b.counts.total - a.counts.total;
		});
	}

	private rollupByStatus(): RollupRow[] {
		// A fixed lane order so the rollup reads the same as the board.
		const order: { status: TaskStatus | 'ready'; label: string }[] = [
			{ status: 'in_progress', label: 'In progress' },
			{ status: 'ready', label: 'Ready' },
			{ status: 'blocked', label: 'Blocked' },
			{ status: 'done', label: 'Done' }
		];
		return order
			.map(({ status, label }) => {
				const tasks =
					status === 'ready'
						? this.active.filter((t) => isReady(t))
						: status === 'blocked'
							? this.active.filter((t) => t.status === 'blocked' || t.status === 'cancelled')
							: this.active.filter((t) => t.status === status);
				return {
					key: status,
					label,
					brainPageId: null,
					counts: countStatuses(tasks),
					progress: progressOf(tasks),
					workers: this.workersOf(tasks)
				} satisfies RollupRow;
			})
			.filter((row) => row.counts.total > 0);
	}

	/** Distinct workers (resolved assignees) across a set of tasks, freshest-claim ordered. */
	private workersOf(tasks: PlanTask[]): Assignee[] {
		const seen = new Map<string, { assignee: Assignee; claimedAt: string | null }>();
		for (const task of tasks) {
			const assignee = this.resolve(task);
			if (!assignee) continue;
			const key = assigneeKey(assignee);
			const prev = seen.get(key);
			if (!prev || (task.claimedAt ?? '') > (prev.claimedAt ?? '')) {
				seen.set(key, { assignee, claimedAt: task.claimedAt });
			}
		}
		return [...seen.values()]
			.sort((a, b) => (b.claimedAt ?? '').localeCompare(a.claimedAt ?? ''))
			.map((entry) => entry.assignee);
	}

	// ── ACTIVITY feed ─────────────────────────────────────────────────────────
	get activity(): ActivityEntry[] {
		const titles = new Map(this.tasks.map((t) => [t.id, t.title]));
		const selfName = (session.user?.displayName ?? session.user?.email ?? '').toLowerCase();
		// The RPC already returns events newest-first (inserted_at desc); keep that
		// order, but sort defensively so the feed is correct regardless of source.
		return [...this.events]
			.sort((a, b) => b.insertedAt.localeCompare(a.insertedAt))
			.map((event) => {
				const label = event.actorLabel?.trim() || 'Someone';
				return {
					id: event.id,
					kind: event.kind,
					verb: verbFor(event),
					actorLabel: label,
					isSelf: selfName !== '' && label.toLowerCase() === selfName,
					taskId: event.taskId,
					taskTitle: titles.get(event.taskId) ?? null,
					brainPageId: event.brainPageId,
					planTitle: this.planTitle(event.brainPageId),
					insertedAt: event.insertedAt
				} satisfies ActivityEntry;
			});
	}
}

// ── Pure group helpers (exported for unit tests) ─────────────────────────────

/** Status counts over a task set: ready is derived (open + unassigned + deps clear). */
export function countStatuses(tasks: PlanTask[]): StatusCounts {
	let inProgress = 0;
	let ready = 0;
	let done = 0;
	let blocked = 0;
	for (const task of tasks) {
		if (task.status === 'in_progress') inProgress++;
		else if (task.status === 'done') done++;
		else if (task.status === 'blocked') blocked++;
		if (isReady(task)) ready++;
	}
	return { inProgress, ready, done, blocked, total: tasks.length };
}

/** Segmented progress proportions over a task set (in-progress / ready / done). */
export function progressOf(tasks: PlanTask[]): Progress {
	const total = tasks.length || 1;
	const c = countStatuses(tasks);
	return { inProgress: c.inProgress / total, ready: c.ready / total, done: c.done / total };
}
