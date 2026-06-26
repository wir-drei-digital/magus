import type { Channel } from 'phoenix';
import { markAllNotificationsRead, markNotificationRead, unreadNotifications } from '$lib/ash/api';
import { getSocket } from '$lib/realtime/socket';
import { applyNotificationEvent, mergeInitial, type NotificationItem } from '$lib/notifications';

const BRIDGED_EVENTS = ['notification.create', 'notification.mark_read'];

class NotificationFeed {
	items = $state<NotificationItem[]>([]);
	connection = $state<'connecting' | 'live' | 'offline'>('connecting');

	#loaded = false;

	get unreadCount(): number {
		return this.items.length;
	}

	/** Seeds the unread list once per session; live events keep it current. */
	async loadInitial(): Promise<void> {
		if (this.#loaded) return;
		this.#loaded = true;

		const result = await unreadNotifications();
		if (!result.success) return;

		const loaded: NotificationItem[] = result.data.map((entry) => ({
			id: entry.id,
			title: entry.title,
			body: entry.body,
			notificationType: entry.notificationType,
			targetConversationId: entry.targetConversationId,
			navigateTo:
				typeof entry.metadata?.navigate_to === 'string' ? entry.metadata.navigate_to : null,
			insertedAt: entry.insertedAt
		}));
		this.items = mergeInitial(this.items, loaded);
	}

	/** Optimistically clears the rows; the channel echo is a no-op after. */
	markRead(ids: string[]): void {
		const remove = new Set(ids);
		this.items = this.items.filter((item) => !remove.has(item.id));
		for (const id of ids) void markNotificationRead(id);
	}

	markAllRead(): void {
		this.items = [];
		void markAllNotificationsRead();
	}

	/**
	 * Bumped on every `file.*` / `folder.*` push from the user channel
	 * (id-only refetch hints; event-name suffixes are Ash action names, so
	 * the catch-all onMessage hook beats enumerating them).
	 */
	fileRevision = $state(0);

	/**
	 * Bumped on every `usage.changed` push from the user channel — a data-less
	 * refetch hint sent after billable usage is recorded. Drives the shell
	 * usage indicator to refresh live, matching the classic shell's PubSub
	 * recompute (MagusWeb.Workbench.Signals.broadcast_usage_changed/1).
	 */
	usageRevision = $state(0);

	#channel: Channel | null = null;

	async connect(userId: string): Promise<void> {
		if (this.#channel) return;

		const socket = await getSocket();
		if (!socket) {
			this.connection = 'offline';
			return;
		}

		this.#channel = socket.channel(`user:${userId}`);

		this.#channel.onMessage = (event, payload) => {
			if (event.startsWith('file.') || event.startsWith('folder.')) {
				this.fileRevision += 1;
			} else if (event === 'usage.changed') {
				this.usageRevision += 1;
			}
			return payload;
		};

		for (const event of BRIDGED_EVENTS) {
			this.#channel.on(event, (payload: Record<string, unknown>) => {
				this.items = applyNotificationEvent(this.items, event, payload);
			});
		}

		this.#channel
			.join()
			.receive('ok', () => {
				this.connection = 'live';
			})
			.receive('error', () => {
				this.connection = 'offline';
			})
			.receive('timeout', () => {
				this.connection = 'offline';
			});
	}

	disconnect(): void {
		this.#channel?.leave();
		this.#channel = null;
		this.connection = 'connecting';
	}
}

export const notificationFeed = new NotificationFeed();
