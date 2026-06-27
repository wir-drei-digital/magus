/**
 * Pure helpers for nav-row presence. The reactive channel store lives in
 * `conversation-presence.svelte.ts`; these are the side-effect-free bits the
 * nav uses to decide what to watch.
 */

/**
 * The conversations whose rows can show co-viewers: only multiplayer or
 * workspace-shared ones. A solo, unshared conversation never has another
 * viewer, so watching it would be pure overhead.
 */
export function collaborativeConversationIds(
	conversations: { id: string; isMultiplayer: boolean; isSharedToWorkspace: boolean }[]
): string[] {
	return conversations.filter((c) => c.isMultiplayer || c.isSharedToWorkspace).map((c) => c.id);
}

/**
 * Order-independent identity of a watch set, so the nav re-pushes `watch` only
 * when the *set* of collaborative conversations changes, not when the list is
 * merely re-sorted (e.g. a new message bumps a row to the top).
 */
export function watchKey(ids: string[]): string {
	return [...ids].sort().join(',');
}
