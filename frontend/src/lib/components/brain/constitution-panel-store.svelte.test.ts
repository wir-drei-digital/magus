import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ConstitutionPanelStore } from './constitution-panel-store.svelte';

/**
 * Logic coverage for the constitution panel's collapse/edit/dirty/save state:
 * default collapsed, toggle, entering edit mode, dirty tracking as the draft
 * diverges from the loaded instructions, and save (injected) clearing dirty
 * and exiting edit mode on success.
 *
 * Runs under the existing vitest config (environment: 'node'); the
 * sveltekit() vite plugin compiles the `.svelte.ts` runes module, so $state
 * works without jsdom (mirrors task-bottom-bar-store.svelte.test.ts).
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

describe('ConstitutionPanelStore defaults', () => {
	it('defaults collapsed (power-user affordance, not front-and-center)', () => {
		const store = new ConstitutionPanelStore('brain-1', 'Some instructions', vi.fn());
		expect(store.collapsed).toBe(true);
	});

	it('starts not editing, with the draft seeded from the loaded instructions', () => {
		const store = new ConstitutionPanelStore('brain-1', 'Root instructions', vi.fn());
		expect(store.editing).toBe(false);
		expect(store.draft).toBe('Root instructions');
		expect(store.dirty).toBe(false);
	});

	it('treats null instructions as an empty draft', () => {
		const store = new ConstitutionPanelStore('brain-1', null, vi.fn());
		expect(store.draft).toBe('');
	});
});

describe('ConstitutionPanelStore.toggle', () => {
	it('flips collapsed and persists it to localStorage, scoped by brainId', () => {
		const store = new ConstitutionPanelStore('brain-1', null, vi.fn());
		expect(store.collapsed).toBe(true);

		store.toggle();
		expect(store.collapsed).toBe(false);
		expect(localStorage.getItem('brain-constitution-collapsed:brain-1')).toBe('false');

		store.toggle();
		expect(store.collapsed).toBe(true);
		expect(localStorage.getItem('brain-constitution-collapsed:brain-1')).toBe('true');
	});

	it('round-trips through a fresh store instance reading the persisted value', () => {
		const first = new ConstitutionPanelStore('brain-1', null, vi.fn());
		first.toggle(); // now expanded, persisted as 'false'

		const second = new ConstitutionPanelStore('brain-1', null, vi.fn());
		expect(second.collapsed).toBe(false);
	});

	it('scopes the stored value to the brainId key', () => {
		localStorage.setItem('brain-constitution-collapsed:brain-1', 'false');
		const other = new ConstitutionPanelStore('brain-2', null, vi.fn());
		expect(other.collapsed).toBe(true);
	});
});

describe('ConstitutionPanelStore edit mode + dirty tracking', () => {
	it('startEdit enters edit mode without marking dirty', () => {
		const store = new ConstitutionPanelStore('brain-1', 'Original', vi.fn());
		store.startEdit();
		expect(store.editing).toBe(true);
		expect(store.dirty).toBe(false);
	});

	it('setDraft marks dirty once the text diverges from the loaded instructions', () => {
		const store = new ConstitutionPanelStore('brain-1', 'Original', vi.fn());
		store.startEdit();

		store.setDraft('Original with more');
		expect(store.dirty).toBe(true);

		// Reverting back to the original clears dirty again.
		store.setDraft('Original');
		expect(store.dirty).toBe(false);
	});

	it('treats null-loaded instructions as an empty baseline for dirty comparison', () => {
		const store = new ConstitutionPanelStore('brain-1', null, vi.fn());
		store.startEdit();

		store.setDraft('');
		expect(store.dirty).toBe(false);

		store.setDraft('New text');
		expect(store.dirty).toBe(true);
	});

	it('cancelEdit resets the draft to the loaded instructions and exits edit mode', () => {
		const store = new ConstitutionPanelStore('brain-1', 'Original', vi.fn());
		store.startEdit();
		store.setDraft('Changed');
		expect(store.dirty).toBe(true);

		store.cancelEdit();
		expect(store.editing).toBe(false);
		expect(store.draft).toBe('Original');
		expect(store.dirty).toBe(false);
	});
});

describe('ConstitutionPanelStore.save', () => {
	it('calls the injected save function with the draft text and clears dirty on success', async () => {
		const save = vi.fn().mockResolvedValue(true);
		const store = new ConstitutionPanelStore('brain-1', 'Original', save);
		store.startEdit();
		store.setDraft('Updated instructions');

		await store.save();

		expect(save).toHaveBeenCalledWith('Updated instructions');
		expect(store.dirty).toBe(false);
		expect(store.editing).toBe(false);
		expect(store.saveState).toBe('saved');
	});

	it('leaves edit mode + dirty alone and surfaces an error when the save fails', async () => {
		const save = vi.fn().mockResolvedValue(false);
		const store = new ConstitutionPanelStore('brain-1', 'Original', save);
		store.startEdit();
		store.setDraft('Updated instructions');

		await store.save();

		expect(store.dirty).toBe(true);
		expect(store.editing).toBe(true);
		expect(store.saveState).toBe('error');
	});

	it('is a no-op when there is nothing dirty to save', async () => {
		const save = vi.fn().mockResolvedValue(true);
		const store = new ConstitutionPanelStore('brain-1', 'Original', save);
		store.startEdit();

		await store.save();

		expect(save).not.toHaveBeenCalled();
	});

	it('sets saveState to saving while the injected save is in flight', async () => {
		let resolveSave!: (ok: boolean) => void;
		const save = vi
			.fn()
			.mockReturnValue(new Promise<boolean>((resolve) => (resolveSave = resolve)));
		const store = new ConstitutionPanelStore('brain-1', 'Original', save);
		store.startEdit();
		store.setDraft('Updated instructions');

		const pending = store.save();
		expect(store.saveState).toBe('saving');

		resolveSave(true);
		await pending;
		expect(store.saveState).toBe('saved');
	});
});
