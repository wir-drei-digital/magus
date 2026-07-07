import { beforeEach, describe, expect, it, vi } from 'vitest';
import { TaskBottomBarStore } from './task-bottom-bar-store.svelte';

/**
 * Logic coverage for the task-bottom-bar collapse store: the persisted
 * `collapsed` boolean's default (task-count-driven) and the round-trip
 * through localStorage on toggle.
 *
 * Runs under the existing vitest config (environment: 'node'); the
 * sveltekit() vite plugin compiles the `.svelte.ts` runes module, so $state
 * works without jsdom (mirrors task-board-store.svelte.test.ts).
 */

// The node test environment lacks a full Storage implementation.
function storageStub(): Storage {
	const map = new Map<string, string>();
	return {
		get length() {
			return map.size;
		},
		key: (index: number) => [...map.keys()][index] ?? null,
		getItem: (key: string) => map.get(key) ?? null,
		setItem: (key: string, value: string) => void map.set(key, value),
		removeItem: (key: string) => void map.delete(key),
		clear: () => map.clear()
	};
}

beforeEach(() => {
	vi.stubGlobal('localStorage', storageStub());
});

describe('TaskBottomBarStore defaults', () => {
	it('defaults collapsed when the task count is 0', () => {
		const store = new TaskBottomBarStore('brain-1', () => 0);
		expect(store.collapsed).toBe(true);
	});

	it('defaults expanded when the task count is > 0', () => {
		const store = new TaskBottomBarStore('brain-1', () => 3);
		expect(store.collapsed).toBe(false);
	});

	it('a stored localStorage value takes precedence over the count default', () => {
		localStorage.setItem('brain-taskbar-collapsed:brain-1', 'false');
		// Count says "should be collapsed" but the stored value wins.
		const collapsedByCount = new TaskBottomBarStore('brain-1', () => 0);
		expect(collapsedByCount.collapsed).toBe(false);

		localStorage.setItem('brain-taskbar-collapsed:brain-2', 'true');
		// Count says "should be expanded" but the stored value wins.
		const expandedByCount = new TaskBottomBarStore('brain-2', () => 5);
		expect(expandedByCount.collapsed).toBe(true);
	});

	it('scopes the stored value to the brainId key', () => {
		localStorage.setItem('brain-taskbar-collapsed:brain-1', 'false');
		// A different brainId has no stored value, so the count default applies.
		const other = new TaskBottomBarStore('brain-2', () => 0);
		expect(other.collapsed).toBe(true);
	});
});

describe('TaskBottomBarStore.toggle', () => {
	it('flips the state and persists it to localStorage', () => {
		const store = new TaskBottomBarStore('brain-1', () => 0);
		expect(store.collapsed).toBe(true);

		store.toggle();
		expect(store.collapsed).toBe(false);
		expect(localStorage.getItem('brain-taskbar-collapsed:brain-1')).toBe('false');

		store.toggle();
		expect(store.collapsed).toBe(true);
		expect(localStorage.getItem('brain-taskbar-collapsed:brain-1')).toBe('true');
	});

	it('round-trips through a fresh store instance reading the persisted value', () => {
		const first = new TaskBottomBarStore('brain-1', () => 0);
		first.toggle(); // now expanded, persisted as 'false'

		const second = new TaskBottomBarStore('brain-1', () => 0);
		expect(second.collapsed).toBe(false);
	});
});
