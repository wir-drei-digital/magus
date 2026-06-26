import type { ThreadSummary } from '$lib/ash/api';

/**
 * In-memory per-conversation thread cache.
 *
 * The conversation view is rebuilt on every switch (keyed by id), so without a
 * cache it refetches `conversationThreads` on each visit — one more request in
 * the per-open waterfall. Threads aren't broadcast over the conversation
 * channel, so the cache uses a short freshness window: a revisit renders
 * instantly from cache and skips the refetch within the window, and local
 * thread creation refreshes the entry directly (see conversation-view).
 */

type Entry = { threads: ThreadSummary[]; at: number };

const cache = new Map<string, Entry>();
const FRESH_MS = 30_000;

/**
 * Cached threads for a conversation, with whether they're fresh enough to skip
 * a refetch. Returns null when nothing is cached yet.
 */
export function readThreads(
	conversationId: string
): { threads: ThreadSummary[]; fresh: boolean } | null {
	const entry = cache.get(conversationId);
	if (!entry) return null;
	return { threads: entry.threads, fresh: Date.now() - entry.at < FRESH_MS };
}

export function writeThreads(conversationId: string, threads: ThreadSummary[]): void {
	cache.set(conversationId, { threads, at: Date.now() });
}
