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
 * (plan-tree.svelte.test.ts). Pages + tasks are fetched and the delivery
 * mutations driven by the brain overview store, which renders this tree.
 */
import type { PlanPage, PlanTask, Lifecycle } from '$lib/ash/api';
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
