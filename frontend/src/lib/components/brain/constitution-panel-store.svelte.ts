/**
 * Collapse + edit/dirty/save state for the brain constitution panel (the
 * `brain.instructions` field: a brain-wide, always-on markdown guide the
 * agent reads on every turn). A power-user affordance, so it defaults
 * collapsed; the collapsed choice persists per brain in `localStorage`
 * (mirrors `TaskBottomBarStore`).
 *
 * The save itself is injected (`save: (draft) => Promise<boolean>`) rather
 * than calling the RPC directly, so this module stays pure logic: the view
 * wires it to `updateBrain`, tests inject a mock.
 */

const STORAGE_PREFIX = 'brain-constitution-collapsed:';

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

export type SaveState = 'idle' | 'saving' | 'saved' | 'error';

export class ConstitutionPanelStore {
	private brainId: string;
	private loaded: string;
	private saveFn: (draft: string) => Promise<boolean>;

	collapsed = $state(false);
	editing = $state(false);
	draft = $state('');
	saveState = $state<SaveState>('idle');

	constructor(
		brainId: string,
		instructions: string | null,
		save: (draft: string) => Promise<boolean>
	) {
		this.brainId = brainId;
		this.loaded = instructions ?? '';
		this.saveFn = save;
		this.collapsed = readStored(brainId) ?? true;
		this.draft = this.loaded;
	}

	get dirty(): boolean {
		return this.draft !== this.loaded;
	}

	toggle(): void {
		this.collapsed = !this.collapsed;
		writeStored(this.brainId, this.collapsed);
	}

	startEdit(): void {
		this.editing = true;
		this.saveState = 'idle';
	}

	setDraft(text: string): void {
		this.draft = text;
	}

	cancelEdit(): void {
		this.editing = false;
		this.draft = this.loaded;
		this.saveState = 'idle';
	}

	async save(): Promise<void> {
		if (!this.dirty) return;
		this.saveState = 'saving';
		const ok = await this.saveFn(this.draft);
		if (ok) {
			this.loaded = this.draft;
			this.editing = false;
			this.saveState = 'saved';
		} else {
			this.saveState = 'error';
		}
	}
}
