import { describe, it, expect } from 'vitest';

/**
 * Logic coverage for the pure plan-tree assembly: the recursive spec -> plan ->
 * phases -> tasks tree built from the brain's flat page + task lists, the
 * ready/blocked task counts each node carries, and the "done but not delivered"
 * (stranded) flag the tree and the overview surface.
 *
 * Runs under the vitest `node` env; the sveltekit() vite plugin compiles the
 * `.svelte.ts` runes module (mirrors plan-board-store.svelte.test.ts).
 */

import { buildPlanTree, type PlanTreeNode, isStranded } from './plan-tree-store.svelte';
import type { PlanPage, PlanTask, Lifecycle } from '$lib/ash/api';

// ─── Fixtures ────────────────────────────────────────────────────────────────
function pageOf(overrides: Partial<PlanPage> & { id: string }): PlanPage {
	return {
		title: 'Page',
		icon: null,
		kind: 'page',
		parentPageId: null,
		specPageId: null,
		lifecycle: 'draft',
		deliveredAt: null,
		deliveryRef: null,
		...overrides
	};
}

function taskOf(overrides: Partial<PlanTask> & { id: string }): PlanTask {
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
		brainPageId: null,
		resultSummary: null,
		ready: null,
		subtaskCount: 0,
		completedSubtaskCount: 0,
		openDependenciesCount: 0,
		...overrides
	};
}

/** Flatten the tree to id -> node for assertions. */
function index(nodes: PlanTreeNode[]): Map<string, PlanTreeNode> {
	const map = new Map<string, PlanTreeNode>();
	const walk = (list: PlanTreeNode[]) => {
		for (const node of list) {
			map.set(node.id, node);
			walk(node.children);
		}
	};
	walk(nodes);
	return map;
}

// ─── isStranded ──────────────────────────────────────────────────────────────
describe('isStranded', () => {
	it('is true only for a plan that is done but not delivered', () => {
		expect(isStranded(pageOf({ id: 'p', kind: 'plan', lifecycle: 'done' }))).toBe(true);
	});

	it('is false once delivered, and for non-done lifecycles', () => {
		expect(isStranded(pageOf({ id: 'p', kind: 'plan', lifecycle: 'delivered' }))).toBe(false);
		expect(isStranded(pageOf({ id: 'p', kind: 'plan', lifecycle: 'active' }))).toBe(false);
		expect(isStranded(pageOf({ id: 'p', kind: 'plan', lifecycle: 'draft' }))).toBe(false);
	});

	it('is false for non-plan kinds even when done', () => {
		expect(isStranded(pageOf({ id: 's', kind: 'spec', lifecycle: 'done' as Lifecycle }))).toBe(
			false
		);
		expect(isStranded(pageOf({ id: 'g', kind: 'page', lifecycle: 'done' as Lifecycle }))).toBe(
			false
		);
	});
});

// ─── buildPlanTree: hierarchy ────────────────────────────────────────────────
describe('buildPlanTree hierarchy', () => {
	it('nests phases (child plan pages) under their parent plan', () => {
		const pages = [
			pageOf({ id: 'plan', kind: 'plan', title: 'Build it', lifecycle: 'active' }),
			pageOf({ id: 'phase1', kind: 'plan', parentPageId: 'plan', title: 'Phase 1' }),
			pageOf({ id: 'phase2', kind: 'plan', parentPageId: 'plan', title: 'Phase 2' })
		];
		const tree = buildPlanTree(pages, []);
		expect(tree.map((n) => n.id)).toEqual(['plan']);
		expect(tree[0].children.map((n) => n.id)).toEqual(['phase1', 'phase2']);
		expect(tree[0].children.every((n) => n.kind === 'plan')).toBe(true);
	});

	it('nests implementing plans under the spec they reference', () => {
		const pages = [
			pageOf({ id: 'spec', kind: 'spec', title: 'The spec' }),
			pageOf({ id: 'planA', kind: 'plan', specPageId: 'spec', title: 'Plan A' }),
			pageOf({ id: 'planB', kind: 'plan', specPageId: 'spec', title: 'Plan B' })
		];
		const tree = buildPlanTree(pages, []);
		const spec = tree.find((n) => n.id === 'spec');
		expect(spec).toBeDefined();
		expect(spec!.children.map((n) => n.id)).toEqual(['planA', 'planB']);
	});

	it('builds spec -> plan -> phase -> tasks in one chain', () => {
		const pages = [
			pageOf({ id: 'spec', kind: 'spec' }),
			pageOf({ id: 'plan', kind: 'plan', specPageId: 'spec', lifecycle: 'active' }),
			pageOf({ id: 'phase', kind: 'plan', parentPageId: 'plan', lifecycle: 'active' })
		];
		const tasks = [taskOf({ id: 't1', brainPageId: 'phase', status: 'in_progress' })];
		const tree = buildPlanTree(pages, tasks);
		const byId = index(tree);
		expect(byId.get('spec')!.children.map((n) => n.id)).toEqual(['plan']);
		expect(byId.get('plan')!.children.map((n) => n.id)).toEqual(['phase']);
		expect(byId.get('phase')!.tasks.map((t) => t.id)).toEqual(['t1']);
	});

	it('omits plain :page pages and pages with no plan/spec role', () => {
		const pages = [
			pageOf({ id: 'note', kind: 'page', title: 'Just a note' }),
			pageOf({ id: 'plan', kind: 'plan', title: 'A plan' })
		];
		const tree = buildPlanTree(pages, []);
		expect(tree.map((n) => n.id)).toEqual(['plan']);
	});

	it('treats a plan with no spec and no plan-parent as a root', () => {
		// parentPageId points at a plain page (not a plan), so it is a top-level plan.
		const pages = [
			pageOf({ id: 'note', kind: 'page' }),
			pageOf({ id: 'plan', kind: 'plan', parentPageId: 'note' })
		];
		const tree = buildPlanTree(pages, []);
		expect(tree.map((n) => n.id)).toEqual(['plan']);
	});

	it('does not duplicate a plan that has both a spec and a plan parent (spec wins as the anchor)', () => {
		const pages = [
			pageOf({ id: 'spec', kind: 'spec' }),
			pageOf({ id: 'parentPlan', kind: 'plan' }),
			pageOf({ id: 'child', kind: 'plan', specPageId: 'spec', parentPageId: 'parentPlan' })
		];
		const tree = buildPlanTree(pages, []);
		const occurrences = [...index(tree).keys()].filter((id) => id === 'child').length;
		expect(occurrences).toBe(1);
		// spec is the anchor when both edges exist.
		expect(
			index(tree)
				.get('spec')!
				.children.map((n) => n.id)
		).toContain('child');
		expect(
			index(tree)
				.get('parentPlan')!
				.children.map((n) => n.id)
		).not.toContain('child');
	});
});

// ─── buildPlanTree: counts + flags ───────────────────────────────────────────
describe('buildPlanTree counts and flags', () => {
	it('counts ready and blocked tasks per node', () => {
		const pages = [pageOf({ id: 'plan', kind: 'plan', lifecycle: 'active' })];
		const tasks = [
			taskOf({ id: 'r1', brainPageId: 'plan', status: 'open', ready: true }),
			taskOf({ id: 'r2', brainPageId: 'plan', status: 'open', ready: true }),
			taskOf({ id: 'b1', brainPageId: 'plan', status: 'blocked' }),
			taskOf({ id: 'p1', brainPageId: 'plan', status: 'in_progress' })
		];
		const node = buildPlanTree(pages, tasks)[0];
		expect(node.readyCount).toBe(2);
		expect(node.blockedCount).toBe(1);
		expect(node.taskCount).toBe(4);
	});

	it('rolls descendant task counts into a parent total (totalReadyCount)', () => {
		const pages = [
			pageOf({ id: 'plan', kind: 'plan', lifecycle: 'active' }),
			pageOf({ id: 'phase', kind: 'plan', parentPageId: 'plan', lifecycle: 'active' })
		];
		const tasks = [
			taskOf({ id: 'r1', brainPageId: 'plan', ready: true }),
			taskOf({ id: 'r2', brainPageId: 'phase', ready: true }),
			taskOf({ id: 'r3', brainPageId: 'phase', ready: true })
		];
		const node = buildPlanTree(pages, tasks)[0];
		expect(node.readyCount).toBe(1); // direct only
		expect(node.totalReadyCount).toBe(3); // self + descendants
	});

	it('flags a done-but-not-delivered plan as stranded; a delivered one is not', () => {
		const pages = [
			pageOf({ id: 'done', kind: 'plan', lifecycle: 'done' }),
			pageOf({ id: 'shipped', kind: 'plan', lifecycle: 'delivered' })
		];
		const byId = index(buildPlanTree(pages, []));
		expect(byId.get('done')!.stranded).toBe(true);
		expect(byId.get('shipped')!.stranded).toBe(false);
	});

	it('carries the lifecycle through to each node', () => {
		const pages = [
			pageOf({ id: 'spec', kind: 'spec' }),
			pageOf({ id: 'plan', kind: 'plan', specPageId: 'spec', lifecycle: 'done' })
		];
		const byId = index(buildPlanTree(pages, []));
		expect(byId.get('plan')!.lifecycle).toBe('done');
		// A spec page has no rollup lifecycle of its own; it reports its raw value.
		expect(byId.get('spec')!.kind).toBe('spec');
	});
});
