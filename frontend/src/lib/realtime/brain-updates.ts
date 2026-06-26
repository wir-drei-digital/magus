import { getSocket } from './socket';

export type BrainUpdate = {
	event: string;
	pageId: string | null;
	lockVersion: number | null;
	actorId: string | null;
};

/**
 * Joins `brain_updates:<brainId>` and invokes the callback per page event
 * (`page.created|updated|deleted|body_updated`). Returns a cleanup function.
 */
export async function joinBrainUpdates(
	brainId: string,
	onEvent: (update: BrainUpdate) => void
): Promise<() => void> {
	const socket = await getSocket();
	if (!socket) return () => {};

	const channel = socket.channel(`brain_updates:${brainId}`);

	channel.onMessage = (event, payload) => {
		if (event.startsWith('page.')) {
			const data = (payload ?? {}) as Record<string, unknown>;
			onEvent({
				event,
				pageId: typeof data.page_id === 'string' ? data.page_id : null,
				lockVersion: typeof data.lock_version === 'number' ? data.lock_version : null,
				actorId: typeof data.actor_id === 'string' ? data.actor_id : null
			});
		}
		return payload;
	};

	channel.join();
	return () => {
		channel.leave();
	};
}
