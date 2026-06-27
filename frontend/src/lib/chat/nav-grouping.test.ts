import { describe, expect, it } from 'vitest';
import { capConversationGroups, groupConversationsByDate, navTimestamp } from './nav-grouping';
import type { ConversationSummary } from '$lib/ash/api';

function conversation(overrides: Partial<ConversationSummary>): ConversationSummary {
	return {
		id: crypto.randomUUID(),
		userId: 'user-1',
		title: 'Chat',
		chatMode: 'chat',
		updatedAt: '2026-06-12T08:00:00Z',
		selectedModelId: null,
		selectedImageModelId: null,
		selectedVideoModelId: null,
		imageGenerationSettings: null,
		videoGenerationSettings: null,
		workspaceId: null,
		customAgentId: null,
		folderId: null,
		isFavorited: false,
		isSharedToWorkspace: false,
		isMultiplayer: false,
		lastMessageAt: null,
		parentConversationId: null,
		...overrides
	};
}

const NOW = new Date('2026-06-12T12:00:00Z');

describe('navTimestamp', () => {
	it('prefers lastMessageAt and falls back to updatedAt', () => {
		expect(navTimestamp(conversation({ lastMessageAt: '2026-06-10T00:00:00Z' }))).toBe(
			'2026-06-10T00:00:00Z'
		);
		expect(navTimestamp(conversation({ lastMessageAt: null }))).toBe('2026-06-12T08:00:00Z');
	});
});

describe('groupConversationsByDate', () => {
	it('buckets by calendar-day distance with classic boundaries', () => {
		const groups = groupConversationsByDate(
			[
				conversation({ id: 'today', lastMessageAt: '2026-06-12T01:00:00Z' }),
				conversation({ id: 'yesterday', lastMessageAt: '2026-06-11T23:00:00Z' }),
				conversation({ id: 'three', lastMessageAt: '2026-06-09T12:00:00Z' }),
				conversation({ id: 'seven', lastMessageAt: '2026-06-05T12:00:00Z' }),
				conversation({ id: 'thirty', lastMessageAt: '2026-05-20T12:00:00Z' }),
				conversation({ id: 'older', lastMessageAt: '2025-01-01T12:00:00Z' })
			],
			NOW
		);

		expect(groups.map((group) => group.label)).toEqual([
			'Today',
			'Yesterday',
			'Last 3 Days',
			'Last 7 Days',
			'Last 30 Days',
			'Older'
		]);
		expect(groups.map((group) => group.conversations[0]?.id)).toEqual([
			'today',
			'yesterday',
			'three',
			'seven',
			'thirty',
			'older'
		]);
	});

	it('drops empty groups and sorts within a group, newest first', () => {
		const groups = groupConversationsByDate(
			[
				conversation({ id: 'b', lastMessageAt: '2026-06-12T02:00:00Z' }),
				conversation({ id: 'a', lastMessageAt: '2026-06-12T09:00:00Z' })
			],
			NOW
		);

		expect(groups).toHaveLength(1);
		expect(groups[0].label).toBe('Today');
		expect(groups[0].conversations.map((entry) => entry.id)).toEqual(['a', 'b']);
	});

	it('uses updatedAt when a conversation has no messages', () => {
		const groups = groupConversationsByDate(
			[conversation({ id: 'fresh', updatedAt: '2026-06-12T07:00:00Z', lastMessageAt: null })],
			NOW
		);

		expect(groups[0].label).toBe('Today');
	});
});

describe('capConversationGroups', () => {
	it('keeps the newest conversations across groups and drops emptied groups', () => {
		const groups = [
			{ label: 'Today', conversations: [conversation({ id: 'a' }), conversation({ id: 'b' })] },
			{ label: 'Yesterday', conversations: [conversation({ id: 'c' })] },
			{ label: 'Older', conversations: [conversation({ id: 'd' })] }
		];

		const capped = capConversationGroups(groups, 3);

		expect(capped.map((group) => group.label)).toEqual(['Today', 'Yesterday']);
		expect(capped.flatMap((group) => group.conversations.map((entry) => entry.id))).toEqual([
			'a',
			'b',
			'c'
		]);
	});

	it('truncates within a group when the cap lands mid-group', () => {
		const groups = [
			{
				label: 'Today',
				conversations: [conversation({ id: 'a' }), conversation({ id: 'b' })]
			}
		];

		expect(capConversationGroups(groups, 1)[0].conversations.map((entry) => entry.id)).toEqual([
			'a'
		]);
	});
});
