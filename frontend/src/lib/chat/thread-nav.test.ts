import { describe, expect, it } from 'vitest';
import { groupThreadsByParent } from './thread-nav';
import type { ThreadNavSummary } from '$lib/ash/api';

function thread(overrides: Partial<ThreadNavSummary>): ThreadNavSummary {
	return {
		id: crypto.randomUUID(),
		title: 'Thread',
		parentConversationId: 'parent-1',
		insertedAt: '2026-06-29T08:00:00Z',
		messageCount: 0,
		...overrides
	};
}

describe('groupThreadsByParent', () => {
	it('returns an empty map for no threads', () => {
		expect(groupThreadsByParent([]).size).toBe(0);
	});

	it('groups threads under their parent conversation id', () => {
		const a = thread({ parentConversationId: 'p1' });
		const b = thread({ parentConversationId: 'p1' });
		const c = thread({ parentConversationId: 'p2' });
		const map = groupThreadsByParent([a, b, c]);
		expect(map.get('p1')).toEqual([a, b]);
		expect(map.get('p2')).toEqual([c]);
	});

	it('preserves input order within a parent', () => {
		const first = thread({ id: 'first', parentConversationId: 'p1' });
		const second = thread({ id: 'second', parentConversationId: 'p1' });
		const map = groupThreadsByParent([first, second]);
		expect(map.get('p1')?.map((t) => t.id)).toEqual(['first', 'second']);
	});

	it('skips threads with a null parent', () => {
		const map = groupThreadsByParent([thread({ parentConversationId: null })]);
		expect(map.size).toBe(0);
	});
});
