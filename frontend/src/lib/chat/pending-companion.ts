import type { CompanionSpec } from '$lib/ash/api';

/**
 * Hand-off for opening a companion on a conversation tab that is not mounted
 * yet. Opening a thread from the nav navigates to the parent conversation and
 * stashes the companion here; the conversation route applies it once the tab is
 * ready. Mirrors pending-message. Module-level Map survives the client-side
 * goto.
 */
const pending = new Map<string, CompanionSpec>();

export function setPendingCompanion(conversationId: string, companion: CompanionSpec): void {
	pending.set(conversationId, companion);
}

/** Returns and removes the pending companion (single-use). */
export function takePendingCompanion(conversationId: string): CompanionSpec | null {
	const companion = pending.get(conversationId);
	if (companion) pending.delete(conversationId);
	return companion ?? null;
}
