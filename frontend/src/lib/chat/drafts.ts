/**
 * Per-conversation composer drafts in localStorage. Plain functions with the
 * storage injected so the logic is unit-testable in node; the composer passes
 * `window.localStorage`.
 */

type StorageLike = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

const key = (conversationId: string) => `magus:next:draft:${conversationId}`;

export function loadDraft(storage: StorageLike, conversationId: string): string {
	try {
		return storage.getItem(key(conversationId)) ?? '';
	} catch {
		return '';
	}
}

export function saveDraft(storage: StorageLike, conversationId: string, text: string): void {
	try {
		if (text.trim() === '') {
			storage.removeItem(key(conversationId));
		} else {
			storage.setItem(key(conversationId), text);
		}
	} catch {
		// Quota/denied — drafts are best-effort.
	}
}

export function clearDraft(storage: StorageLike, conversationId: string): void {
	try {
		storage.removeItem(key(conversationId));
	} catch {
		// Best-effort.
	}
}
