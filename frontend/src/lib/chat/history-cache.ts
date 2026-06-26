import type { ChatMessage } from '$lib/ash/api';
import { readShellCache, removeShellCache, writeShellCache } from '$lib/shell-cache';

/**
 * Per-conversation message snapshots so re-opening a conversation renders
 * instantly: the store hydrates from here, gap-fills the delta over
 * messages_since, and trues up in the background. Hot path is the in-memory
 * map; the shell cache (cleared on sign-out) persists a bounded LRU of
 * recent conversations across reloads.
 */
const MAX_MESSAGES = 50;
const MAX_CONVERSATIONS = 10;
const INDEX_KEY = 'history-index';

const memory = new Map<string, ChatMessage[]>();

export function readHistory(conversationId: string): ChatMessage[] | null {
	const hot = memory.get(conversationId);
	if (hot) return hot;

	const persisted = readShellCache<ChatMessage[]>(`history:${conversationId}`);
	if (persisted && persisted.length > 0) {
		memory.set(conversationId, persisted);
		return persisted;
	}
	return null;
}

export function writeHistory(conversationId: string, messages: ChatMessage[]): void {
	// Only settled rows: provisional/streaming entries would hydrate as
	// permanently stuck bubbles on the next visit.
	const settled = messages.filter(
		(message) =>
			!message.id.startsWith('local-') &&
			message.status !== 'pending' &&
			message.status !== 'streaming'
	);
	const tail = settled.slice(-MAX_MESSAGES);
	if (tail.length === 0) return;

	memory.set(conversationId, tail);
	writeShellCache(`history:${conversationId}`, tail);

	// Bounded LRU across conversations; evictions only drop snapshots.
	const index = (readShellCache<string[]>(INDEX_KEY) ?? []).filter(
		(entry) => entry !== conversationId
	);
	index.push(conversationId);
	for (const evicted of index.splice(0, Math.max(0, index.length - MAX_CONVERSATIONS))) {
		removeShellCache(`history:${evicted}`);
		memory.delete(evicted);
	}
	writeShellCache(INDEX_KEY, index);
}
