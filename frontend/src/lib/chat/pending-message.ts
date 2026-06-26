import type { AttachedResource } from '$lib/ash/api';

/**
 * Hand-off for the first message of a freshly created conversation.
 *
 * The new-chat landing page (`/chat`) defers conversation creation until the
 * user sends — classic `conversation_id = "new"` parity. On send it creates
 * the conversation, stashes the composed message here, then navigates to
 * `/chat/{id}`. The conversation route picks it up and sends it only once the
 * `ConversationStore` has joined the channel, so the first agent response
 * streams in live instead of being missed in the join gap.
 *
 * Module-level Map is fine: the SPA navigates client-side, so the value
 * survives the `goto` to the conversation route.
 */
export type PendingMessage = { text: string; resources: AttachedResource[] };

const pending = new Map<string, PendingMessage>();

export function setPendingMessage(conversationId: string, message: PendingMessage): void {
	pending.set(conversationId, message);
}

/** Returns and removes the pending message (single-use). */
export function takePendingMessage(conversationId: string): PendingMessage | null {
	const message = pending.get(conversationId);
	if (message) pending.delete(conversationId);
	return message ?? null;
}
