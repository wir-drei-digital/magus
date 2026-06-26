import {
	brainPageChildren,
	createBrain,
	myBrains,
	rootBrainPages,
	shareBrainToTeam,
	unshareBrainFromTeam,
	updateBrain,
	workspaceBrains,
	type BrainSummary,
	type PageTreeNode
} from '$lib/ash/api';
import { readShellCache, writeShellCache } from '$lib/shell-cache';

/**
 * Brain-mode nav state: ALL of the actor's brains rendered as expandable
 * file-tree roots (classic BrainModeNav parity), each with a lazily loaded
 * page tree beneath it. Expanded brains persist per workspace.
 */
class BrainNav {
	brains = $state<BrainSummary[]>([]);
	/** brainId → root pages; presence means "expanded". */
	roots = $state<Record<string, PageTreeNode[]>>({});
	/** parentPageId → children; presence means "expanded". */
	children = $state<Record<string, PageTreeNode[]>>({});
	loading = $state(true);

	#workspaceId: string | null = null;
	#loadKey: string | null = null;

	get shared(): BrainSummary[] {
		return this.brains.filter((brain) => brain.isSharedToWorkspace);
	}

	get personal(): BrainSummary[] {
		return this.brains.filter((brain) => !brain.isSharedToWorkspace);
	}

	async load(workspaceId: string | null, force = false): Promise<void> {
		const key = workspaceId ?? '';
		if (!force && this.#loadKey === key) return;
		this.#workspaceId = workspaceId;
		this.#loadKey = key;
		this.loading = true;
		this.roots = {};
		this.children = {};

		// Last-known brains + expanded page trees render instantly; the
		// fetches below reconcile them.
		const snapshot = readShellCache<{
			brains: BrainSummary[];
			roots: Record<string, PageTreeNode[]>;
		}>(`brain-nav:${key}`);
		if (snapshot) {
			this.brains = snapshot.brains;
			this.roots = snapshot.roots;
			this.loading = false;
		}

		const result = workspaceId ? await workspaceBrains(workspaceId) : await myBrains();
		if (this.#loadKey !== key) return;

		this.brains = result.success
			? result.data.filter((brain) => (brain.workspaceId ?? null) === workspaceId)
			: [];

		// Restore expanded brains (or expand the first one for orientation).
		const stored = this.#readExpanded(key);
		const toExpand = this.brains.filter((brain) => stored.has(brain.id)).map((brain) => brain.id);
		if (toExpand.length === 0 && this.brains[0]) toExpand.push(this.brains[0].id);

		// Drop hydrated roots for brains that aren't in the fresh expansion
		// set (deleted elsewhere, or collapsed on another device).
		const expanding = new Set(toExpand);
		this.roots = Object.fromEntries(
			Object.entries(this.roots).filter(([brainId]) => expanding.has(brainId))
		);

		await Promise.all(toExpand.map((brainId) => this.expandBrain(brainId, true)));
		this.loading = false;
		this.#persistSnapshot();
	}

	isBrainExpanded(brainId: string): boolean {
		return this.roots[brainId] !== undefined;
	}

	async expandBrain(brainId: string, force = false): Promise<void> {
		if (!force && this.roots[brainId]) return;
		const result = await rootBrainPages(brainId);
		if (result.success) {
			this.roots = { ...this.roots, [brainId]: result.data };
			this.#persistExpanded();
		}
	}

	collapseBrain(brainId: string): void {
		const next = { ...this.roots };
		delete next[brainId];
		this.roots = next;
		this.#persistExpanded();
	}

	async expandPage(parentId: string, force = false): Promise<void> {
		if (!force && this.children[parentId]) return;
		const result = await brainPageChildren(parentId);
		if (result.success) {
			this.children = { ...this.children, [parentId]: result.data };
		}
	}

	collapsePage(parentId: string): void {
		const next = { ...this.children };
		delete next[parentId];
		this.children = next;
	}

	/** Refreshes every expanded brain + page branch (channel hints, saves). */
	async reloadTree(): Promise<void> {
		const brains = Object.keys(this.roots);
		await Promise.all(brains.map((brainId) => this.expandBrain(brainId, true)));
		const pages = Object.keys(this.children);
		await Promise.all(pages.map((parentId) => this.expandPage(parentId, true)));
	}

	async createBrain(title: string): Promise<BrainSummary | null> {
		const result = await createBrain({ title, workspaceId: this.#workspaceId });
		if (!result.success) return null;
		this.brains = [...this.brains, result.data];
		await this.expandBrain(result.data.id, true);
		return result.data;
	}

	/** Settings modal save: update brain metadata, reflect it in the nav. */
	async updateBrain(
		id: string,
		input: {
			title?: string;
			description?: string | null;
			icon?: string | null;
			color?: string | null;
		}
	): Promise<boolean> {
		const result = await updateBrain(id, input);
		if (!result.success) return false;
		this.brains = this.brains.map((brain) => (brain.id === id ? result.data : brain));
		this.#persistSnapshot();
		return true;
	}

	/** Settings modal: flip workspace-wide sharing for a workspace brain. */
	async toggleShare(brain: BrainSummary): Promise<boolean> {
		const result = brain.isSharedToWorkspace
			? await unshareBrainFromTeam(brain.id)
			: await shareBrainToTeam(brain.id);
		if (!result.success) return false;
		this.brains = this.brains.map((entry) => (entry.id === brain.id ? result.data : entry));
		this.#persistSnapshot();
		return true;
	}

	#readExpanded(key: string): Set<string> {
		try {
			const raw = localStorage.getItem(`magus:next:brains-expanded:${key}`);
			return new Set(raw ? (JSON.parse(raw) as string[]) : []);
		} catch {
			return new Set();
		}
	}

	#persistExpanded(): void {
		try {
			localStorage.setItem(
				`magus:next:brains-expanded:${this.#loadKey ?? ''}`,
				JSON.stringify(Object.keys(this.roots))
			);
		} catch {
			// Best-effort.
		}
		this.#persistSnapshot();
	}

	#persistSnapshot(): void {
		if (this.#loadKey === null) return;
		writeShellCache(`brain-nav:${this.#loadKey}`, { brains: this.brains, roots: this.roots });
	}
}

export const brainNav = new BrainNav();
