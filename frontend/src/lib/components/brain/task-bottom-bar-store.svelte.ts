/**
 * Collapse state for the task bottom bar docked under every content brain
 * page. Persisted per brain in `localStorage` so a viewer's choice sticks
 * across page navigations within the same brain.
 *
 * Default (no stored value yet): collapsed when the page has zero tasks,
 * expanded otherwise, so an empty board doesn't eat vertical space but a
 * page with live work stays visible on first load. A stored value always
 * wins once the viewer has toggled it once. The task count is read via a
 * getter (not a snapshot) since it typically isn't known until the task
 * board's own store finishes loading, after this store is constructed.
 */

const STORAGE_PREFIX = 'brain-taskbar-collapsed:';

function storageKey(brainId: string): string {
	return STORAGE_PREFIX + brainId;
}

function readStored(brainId: string): boolean | null {
	if (typeof localStorage === 'undefined') return null;
	const raw = localStorage.getItem(storageKey(brainId));
	if (raw === 'true') return true;
	if (raw === 'false') return false;
	return null;
}

function writeStored(brainId: string, collapsed: boolean): void {
	if (typeof localStorage === 'undefined') return;
	localStorage.setItem(storageKey(brainId), String(collapsed));
}

export class TaskBottomBarStore {
	private brainId: string;
	collapsed = $state(false);

	constructor(brainId: string, getTaskCount: () => number) {
		this.brainId = brainId;
		const stored = readStored(brainId);
		this.collapsed = stored ?? getTaskCount() === 0;
	}

	toggle(): void {
		this.collapsed = !this.collapsed;
		writeStored(this.brainId, this.collapsed);
	}
}
