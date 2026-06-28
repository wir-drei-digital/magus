/**
 * State + derivations for the unified plan tree: the spec -> plan -> phases ->
 * tasks chain that makes a brain's delivery state legible at a glance.
 *
 * A brain's pages arrive as a flat list (each carrying its recursive `lifecycle`
 * rollup) and its tasks as a second flat list. {@link buildPlanTree} assembles
 * the hierarchy from two edges:
 *
 *   - `specPageId`     : a :plan page implements a :spec page (the spec anchors it),
 *   - `parentPageId`   : a :plan page nested under another :plan page is a phase.
 *
 * Each node carries its direct task counts (ready / blocked / total), a rolled-up
 * `totalReadyCount` over its subtree, its `lifecycle`, and a `stranded` flag
 * (a :plan that is `done` but never `delivered`: the anti-stranding alarm).
 *
 * The pure assembly (`buildPlanTree`, `isStranded`) is unit-tested
 * (plan-tree.svelte.test.ts); the store is a thin `$state` shell over the api.ts
 * seam with optimistic deliver / undeliver mutations reconciled from the server
 * row, refetching on error (mirrors the plan-board store's claim flow).
 */
import {
	brainPlanPages,
	brainTasks,
	markBrainPageDelivered,
	undeliverBrainPage,
	type PlanPage,
	type PlanTask,
	type Lifecycle
} from '$lib/ash/api';
import { isReady } from './plan-board-store.svelte';

/** A node in the unified plan tree: a :plan or :spec page plus its tasks + children. */
export type PlanTreeNode = {
	id: string;
	title: string;
	icon: string | null;
	kind: PlanPage['kind'];
	lifecycle: Lifecycle;
	deliveredAt: string | null;
	deliveryRef: string | null;
	/** Direct tasks attached to this page (not its descendants'). */
	tasks: PlanTask[];
	/** Nested plan phases / implementing plans. */
	children: PlanTreeNode[];
	/** Direct task counts. */
	taskCount: number;
	readyCount: number;
	blockedCount: number;
	/** Ready tasks across this node and its whole subtree. */
	totalReadyCount: number;
	/** A :plan that is done but was never delivered: the work that needs closing out. */
	stranded: boolean;
};

/**
 * True when a page is the anti-stranding alarm: a :plan whose recursive lifecycle
 * rolled up to `done` (every task complete) but whose delivery gate was never set.
 * Only :plan pages strand; :spec / :page never do.
 */
export function isStranded(page: Pick<PlanPage, 'kind' | 'lifecycle'>): boolean {
	return page.kind === 'plan' && page.lifecycle === 'done';
}

/** Count ready (claimable) tasks in a set, trusting the server `ready` calc. */
function countReady(tasks: PlanTask[]): number {
	return tasks.filter((t) => isReady(t)).length;
}

/** Count blocked / cancelled tasks (the stuck overflow). */
function countBlocked(tasks: PlanTask[]): number {
	return tasks.filter((t) => t.status === 'blocked' || t.status === 'cancelled').length;
}

/**
 * Assemble the spec -> plan -> phases -> tasks tree from a brain's flat page +
 * task lists. Plain `:page` pages are dropped; only `:plan` and `:spec` pages
 * become nodes. A plan with a `specPageId` anchors under that spec (the spec
 * wins over a plan parent); otherwise a plan nested under another plan is a phase
 * of it; everything else is a root.
 */
export function buildPlanTree(pages: PlanPage[], tasks: PlanTask[]): PlanTreeNode[] {
	const relevant = pages.filter((p) => p.kind === 'plan' || p.kind === 'spec');
	const planIds = new Set(relevant.filter((p) => p.kind === 'plan').map((p) => p.id));
	const specIds = new Set(relevant.filter((p) => p.kind === 'spec').map((p) => p.id));

	// Direct tasks per page id.
	const tasksByPage = new Map<string, PlanTask[]>();
	for (const task of tasks) {
		if (!task.brainPageId) continue;
		(
			tasksByPage.get(task.brainPageId) ??
			tasksByPage.set(task.brainPageId, []).get(task.brainPageId)!
		).push(task);
	}

	// Build a bare node per relevant page.
	const nodes = new Map<string, PlanTreeNode>();
	for (const page of relevant) {
		const direct = tasksByPage.get(page.id) ?? [];
		nodes.set(page.id, {
			id: page.id,
			title: page.title ?? 'Untitled',
			icon: page.icon,
			kind: page.kind,
			lifecycle: page.lifecycle,
			deliveredAt: page.deliveredAt,
			deliveryRef: page.deliveryRef,
			tasks: direct,
			children: [],
			taskCount: direct.length,
			readyCount: countReady(direct),
			blockedCount: countBlocked(direct),
			totalReadyCount: 0, // filled after the tree is wired
			stranded: isStranded(page)
		});
	}

	// Wire parent edges. A plan anchors under its spec when set+present; else under
	// its plan parent when that parent is itself a plan; else it is a root.
	const roots: PlanTreeNode[] = [];
	for (const page of relevant) {
		const node = nodes.get(page.id)!;
		const specParent =
			page.kind === 'plan' && page.specPageId && specIds.has(page.specPageId)
				? page.specPageId
				: null;
		const planParent =
			page.kind === 'plan' && page.parentPageId && planIds.has(page.parentPageId)
				? page.parentPageId
				: null;
		const anchor = specParent ?? planParent;
		if (anchor) nodes.get(anchor)!.children.push(node);
		else roots.push(node);
	}

	// Roll the ready counts up the subtree (depth-first, memoised by mutation).
	const rollup = (node: PlanTreeNode): number => {
		node.totalReadyCount = node.readyCount + node.children.reduce((sum, c) => sum + rollup(c), 0);
		return node.totalReadyCount;
	};
	for (const root of roots) rollup(root);

	return roots;
}

export class PlanTreeStore {
	brainId = $state('');
	pages = $state<PlanPage[]>([]);
	tasks = $state<PlanTask[]>([]);
	loading = $state(true);
	loadError = $state<string | null>(null);
	/** Page ids with a deliver/undeliver mutation in flight (disables the control). */
	pending = $state<Set<string>>(new Set());

	constructor(brainId: string) {
		this.brainId = brainId;
	}

	async load(): Promise<void> {
		const id = this.brainId;
		this.loading = true;
		this.loadError = null;
		const [pagesResult, tasksResult] = await Promise.all([brainPlanPages(id), brainTasks(id)]);
		if (id !== this.brainId) return;
		if (tasksResult.success) this.tasks = tasksResult.data;
		if (pagesResult.success) {
			this.pages = pagesResult.data;
		} else {
			this.loadError = pagesResult.errors[0]?.message ?? 'Plans could not be loaded';
		}
		this.loading = false;
	}

	async reload(): Promise<void> {
		await this.load();
	}

	private async refetch(): Promise<void> {
		const id = this.brainId;
		const result = await brainPlanPages(id);
		if (id === this.brainId && result.success) this.pages = result.data;
	}

	private upsertPage(page: PlanPage): void {
		const index = this.pages.findIndex((p) => p.id === page.id);
		this.pages =
			index >= 0 ? this.pages.map((p) => (p.id === page.id ? page : p)) : [...this.pages, page];
	}

	private setPending(id: string, on: boolean): void {
		const next = new Set(this.pending);
		if (on) next.add(id);
		else next.delete(id);
		this.pending = next;
	}

	/** The assembled tree (pure, recomputed from pages + tasks). */
	get tree(): PlanTreeNode[] {
		return buildPlanTree(this.pages, this.tasks);
	}

	/** The flat stranded set (done-but-not-delivered plans) for the overview alarm. */
	get stranded(): PlanPage[] {
		return this.pages.filter(isStranded);
	}

	// ── Mutations (optimistic, server-reconciled) ───────────────────────────
	async markDelivered(pageId: string, deliveryRef: string | null): Promise<void> {
		if (this.pending.has(pageId)) return;
		this.setPending(pageId, true);
		const result = await markBrainPageDelivered(pageId, deliveryRef);
		if (result.success) this.upsertPage(result.data);
		else await this.refetch();
		this.setPending(pageId, false);
	}

	async undeliver(pageId: string): Promise<void> {
		if (this.pending.has(pageId)) return;
		this.setPending(pageId, true);
		const result = await undeliverBrainPage(pageId);
		if (result.success) this.upsertPage(result.data);
		else await this.refetch();
		this.setPending(pageId, false);
	}
}
