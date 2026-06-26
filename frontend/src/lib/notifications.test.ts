import { describe, expect, it } from 'vitest';
import {
	applyNotificationEvent,
	groupNotifications,
	mergeInitial,
	notificationTitle,
	type NotificationItem
} from './notifications';

const existing: NotificationItem = {
	id: 'n-1',
	title: 'Existing',
	body: null,
	notificationType: 'system',
	targetConversationId: null,
	navigateTo: null,
	insertedAt: null
};

function item(overrides: Partial<NotificationItem>): NotificationItem {
	return { ...existing, ...overrides };
}

describe('applyNotificationEvent', () => {
	it('prepends created notifications', () => {
		const result = applyNotificationEvent([existing], 'notification.create', {
			id: 'n-2',
			title: 'New',
			notification_type: 'mention'
		});

		expect(result.map((item) => item.id)).toEqual(['n-2', 'n-1']);
		expect(result[0].notificationType).toBe('mention');
	});

	it('dedupes by id', () => {
		const result = applyNotificationEvent([existing], 'notification.create', { id: 'n-1' });
		expect(result).toHaveLength(1);
	});

	it('removes read notifications', () => {
		const result = applyNotificationEvent([existing], 'notification.mark_read', { id: 'n-1' });
		expect(result).toHaveLength(0);
	});

	it('ignores unknown events', () => {
		const result = applyNotificationEvent([existing], 'notification.unknown', { id: 'n-9' });
		expect(result).toEqual([existing]);
	});
});

describe('mergeInitial', () => {
	it('appends loaded rows after live inserts, deduping by id', () => {
		const live = item({ id: 'live-1' });
		const loaded = [item({ id: 'live-1' }), item({ id: 'old-1' })];

		const result = mergeInitial([live], loaded);
		expect(result.map((entry) => entry.id)).toEqual(['live-1', 'old-1']);
	});
});

describe('notificationTitle', () => {
	it('prefers the explicit title and falls back per type', () => {
		expect(notificationTitle(item({ title: 'Custom' }))).toBe('Custom');
		expect(notificationTitle(item({ title: null, notificationType: 'mention' }))).toBe(
			'You were mentioned'
		);
		expect(notificationTitle(item({ title: null, notificationType: 'whatever' }))).toBe(
			'Notification'
		);
	});
});

describe('groupNotifications', () => {
	it('groups by conversation with a count, leaving singles alone', () => {
		const groups = groupNotifications([
			item({ id: 'a', targetConversationId: 'c-1' }),
			item({ id: 'b', targetConversationId: 'c-1' }),
			item({ id: 'c', targetConversationId: null })
		]);

		expect(groups).toHaveLength(2);
		expect(groups[0].head.id).toBe('a');
		expect(groups[0].count).toBe(2);
		expect(groups[0].ids).toEqual(['a', 'b']);
		expect(groups[1].count).toBe(1);
	});

	it('groups by custom link when no conversation is set', () => {
		const groups = groupNotifications([
			item({ id: 'a', navigateTo: '/settings' }),
			item({ id: 'b', navigateTo: '/settings' })
		]);

		expect(groups).toHaveLength(1);
		expect(groups[0].count).toBe(2);
	});
});
