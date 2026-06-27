import type { Channel } from 'phoenix';
import { SvelteMap } from 'svelte/reactivity';
import { getSocket } from '$lib/realtime/socket';
import { normalizeViewers, type PresenceViewer, type RawPresenceViewer } from './presence';
import { watchKey } from './conversation-presence';

/**
 * Aggregate nav-row presence over the per-user `conversation_presence:<id>`
 * feed. The nav tells the server which collaborative conversations it shows
 * (`watch`); the server pushes a snapshot then per-conversation updates. The
 * map is keyed by conversation id; values include self (the avatar UI filters
 * self + hidden out).
 *
 * Singleton, started once from the chat nav. `start` is idempotent for the same
 * user; `watch` is deduped by set identity so a reordered list (e.g. a row
 * bumped by a new message) doesn't re-push.
 */
export class ConversationPresenceStore {
	byConversation = new SvelteMap<string, PresenceViewer[]>();

	#channel: Channel | null = null;
	#userId: string | null = null;
	#desiredIds: string[] = [];
	#sentKey: string | null = null;

	async start(userId: string): Promise<void> {
		if (this.#channel && this.#userId === userId) return;
		this.stop();
		this.#userId = userId;

		const socket = await getSocket();
		if (!socket || this.#userId !== userId) return;

		const channel = socket.channel(`conversation_presence:${userId}`);
		this.#channel = channel;

		channel.on('presence.snapshot', (payload: Record<string, unknown>) => {
			const map = (payload.conversations ?? {}) as Record<string, RawPresenceViewer[]>;
			this.byConversation.clear();
			for (const [id, raw] of Object.entries(map)) {
				this.byConversation.set(id, normalizeViewers(raw));
			}
		});

		channel.on('presence.update', (payload: Record<string, unknown>) => {
			const id = String(payload.conversation_id ?? '');
			if (!id) return;
			this.byConversation.set(id, normalizeViewers(payload.viewers as RawPresenceViewer[]));
		});

		// Send the watch set once the feed is live (watch() may have been called
		// while the socket/join was still in flight).
		channel.join().receive('ok', () => this.#flushWatch());
	}

	/** Declare the collaborative conversations the nav currently displays. */
	watch(conversationIds: string[]): void {
		this.#desiredIds = conversationIds;
		this.#flushWatch();
	}

	// Push the desired watch set, but only once the channel exists and only when
	// the set actually changed (a reordered list must not re-trigger a watch).
	#flushWatch(): void {
		if (!this.#channel) return;
		const key = watchKey(this.#desiredIds);
		if (key === this.#sentKey) return;
		this.#sentKey = key;
		this.#channel.push('watch', { conversation_ids: this.#desiredIds });
	}

	viewers(conversationId: string): PresenceViewer[] {
		return this.byConversation.get(conversationId) ?? [];
	}

	stop(): void {
		this.#channel?.leave();
		this.#channel = null;
		this.#userId = null;
		this.#desiredIds = [];
		this.#sentKey = null;
		this.byConversation.clear();
	}
}

export const conversationPresence = new ConversationPresenceStore();
