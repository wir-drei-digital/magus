/**
 * Pure notification-feed logic, kept runes-free so it unit-tests in node.
 * Event names mirror the UserChannel bridge: `notification.<ash action>`.
 */

export type NotificationItem = {
	id: string;
	title: string | null;
	body: string | null;
	notificationType: string;
	targetConversationId: string | null;
	/** Optional custom link (classic `metadata["navigate_to"]`). */
	navigateTo: string | null;
	/** Absent on live channel payloads; present on RPC-loaded rows. */
	insertedAt: string | null;
};

type RawPayload = Record<string, unknown>;

function toItem(payload: RawPayload): NotificationItem {
	const metadata = (payload.metadata as Record<string, unknown> | null) ?? null;
	return {
		id: String(payload.id ?? ''),
		title: (payload.title as string | null) ?? null,
		body: (payload.body as string | null) ?? null,
		notificationType: String(payload.notification_type ?? 'system'),
		targetConversationId: (payload.target_conversation_id as string | null) ?? null,
		navigateTo: typeof metadata?.navigate_to === 'string' ? metadata.navigate_to : null,
		insertedAt: (payload.inserted_at as string | null) ?? null
	};
}

/** Seeds the feed from an RPC load, keeping any live inserts that raced it. */
export function mergeInitial(
	items: NotificationItem[],
	loaded: NotificationItem[]
): NotificationItem[] {
	const seen = new Set(loaded.map((item) => item.id));
	return [...items.filter((item) => !seen.has(item.id)), ...loaded];
}

/** Fallback titles per type, mirroring the classic bell's derivation. */
export function notificationTitle(item: NotificationItem): string {
	if (item.title) return item.title;
	switch (item.notificationType) {
		case 'task_update':
			return 'Task updated';
		case 'task_completed':
			return 'Task completed';
		case 'mention':
			return 'You were mentioned';
		case 'message':
			return 'New message';
		case 'approval_request':
			return 'Approval requested';
		default:
			return 'Notification';
	}
}

export type NotificationGroup = {
	key: string;
	head: NotificationItem;
	count: number;
	ids: string[];
};

/**
 * Classic grouping: one row per conversation (or custom link), newest first,
 * with a "+N more" count; ungrouped items stand alone.
 */
export function groupNotifications(items: NotificationItem[]): NotificationGroup[] {
	const groups = new Map<string, NotificationGroup>();
	for (const item of items) {
		const key = item.targetConversationId ?? item.navigateTo ?? item.id;
		const existing = groups.get(key);
		if (existing) {
			existing.count += 1;
			existing.ids.push(item.id);
		} else {
			groups.set(key, { key, head: item, count: 1, ids: [item.id] });
		}
	}
	return [...groups.values()];
}

export function applyNotificationEvent(
	items: NotificationItem[],
	event: string,
	payload: RawPayload
): NotificationItem[] {
	switch (event) {
		case 'notification.create': {
			const item = toItem(payload);
			if (!item.id || items.some((existing) => existing.id === item.id)) return items;
			return [item, ...items];
		}
		case 'notification.mark_read': {
			const id = String(payload.id ?? '');
			return items.filter((existing) => existing.id !== id);
		}
		default:
			return items;
	}
}
