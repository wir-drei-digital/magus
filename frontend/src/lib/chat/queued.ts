/**
 * Pure reducer for the per-conversation message queue.
 *
 * While the agent is mid-turn, new user messages are enqueued server-side
 * instead of starting a fresh turn. The conversation channel broadcasts
 * `queued.enqueue_message` (a message joined the queue), `queued.flush_queued`
 * (a queued message was sent now / flushed into the turn), and
 * `queued.remove_queued` (a queued message was dropped). This reducer folds
 * those events into the local queue array; the store owns the reactive state
 * and the channel wiring, keeping this module side-effect free and unit-testable.
 */
export type QueuedMessage = {
	id: string;
	text: string;
	insertedAt?: string;
	createdById?: string;
};

export type QueuedEvent = 'enqueue_message' | 'flush_queued' | 'remove_queued';

export function applyQueuedEvent(
	queue: QueuedMessage[],
	event: QueuedEvent,
	payload: { id: string; text?: string; insertedAt?: string; createdById?: string }
): QueuedMessage[] {
	switch (event) {
		case 'enqueue_message':
			// Idempotent: a replayed broadcast (reconnect gap-fill) must not duplicate.
			if (queue.some((m) => m.id === payload.id)) return queue;
			return [
				...queue,
				{
					id: payload.id,
					text: payload.text ?? '',
					insertedAt: payload.insertedAt,
					createdById: payload.createdById
				}
			];
		case 'flush_queued':
		case 'remove_queued':
			return queue.filter((m) => m.id !== payload.id);
		default:
			return queue;
	}
}
