import type { ThreadNavSummary } from '$lib/ash/api';

/**
 * Groups nav threads under their parent conversation id, preserving the
 * backend's oldest-first order. Threads without a parent (should not happen for
 * real threads) are skipped.
 */
export function groupThreadsByParent(
	threads: ThreadNavSummary[]
): Map<string, ThreadNavSummary[]> {
	const map = new Map<string, ThreadNavSummary[]>();
	for (const thread of threads) {
		if (!thread.parentConversationId) continue;
		const list = map.get(thread.parentConversationId);
		if (list) list.push(thread);
		else map.set(thread.parentConversationId, [thread]);
	}
	return map;
}
