import type { Channel } from 'phoenix';
import { getSocket } from '$lib/realtime/socket';
import { normalizeViewers, type PresenceViewer, type RawPresenceViewer } from './presence';

/**
 * Live viewer presence for a single companion resource (brain page, draft),
 * over the `viewers:<type>:<id>` channel. The backend tracks this viewer on the
 * resource's shared `presence:<type>:<id>` topic — the same one the workbench
 * LiveViews use — so SPA and classic viewers of one page/draft appear together.
 *
 * One instance per companion; call `start` from an `$effect` keyed on the id
 * and `stop` from its teardown. `start` is safe to call repeatedly for the same
 * resource (it no-ops); switching ids leaves the old channel first.
 */
export class ResourcePresence {
	viewers = $state<PresenceViewer[]>([]);

	#channel: Channel | null = null;
	#key: string | null = null;

	async start(resourceType: 'page' | 'draft', resourceId: string): Promise<void> {
		const key = `${resourceType}:${resourceId}`;
		if (this.#key === key) return;
		this.stop();
		this.#key = key;

		const socket = await getSocket();
		// A stop() (or a re-start to another resource) may have run while the
		// socket promise was in flight — bail if we're no longer current.
		if (!socket || this.#key !== key) return;

		const channel = socket.channel(`viewers:${resourceType}:${resourceId}`);
		this.#channel = channel;
		channel.on('presence.state', (payload: Record<string, unknown>) => {
			this.viewers = normalizeViewers(payload.viewers as RawPresenceViewer[] | undefined);
		});
		channel.join();
	}

	stop(): void {
		this.#channel?.leave();
		this.#channel = null;
		this.#key = null;
		this.viewers = [];
	}
}
