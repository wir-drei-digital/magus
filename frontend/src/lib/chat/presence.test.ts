import { describe, expect, it } from 'vitest';
import {
	normalizeViewers,
	viewerInitials,
	viewerOverflow,
	visibleOthers,
	type PresenceViewer
} from './presence';

function viewer(p: Partial<PresenceViewer> & { userId: string }): PresenceViewer {
	return { name: 'X', avatarPath: null, color: '#888', visible: true, ...p };
}

describe('normalizeViewers', () => {
	it('maps the snake_case channel payload to camelCase with defaults', () => {
		expect(
			normalizeViewers([{ user_id: 'u1', name: 'Ada', avatar_path: '/a.png', color: '#f00' }])
		).toEqual([{ userId: 'u1', name: 'Ada', avatarPath: '/a.png', color: '#f00', visible: true }]);
	});

	it('drops entries without a user_id and tolerates non-arrays', () => {
		expect(normalizeViewers([{ name: 'no id' }])).toEqual([]);
		expect(normalizeViewers(undefined)).toEqual([]);
	});
});

describe('visibleOthers', () => {
	it('excludes the current user and hidden viewers', () => {
		const viewers = [
			viewer({ userId: 'me' }),
			viewer({ userId: 'them' }),
			viewer({ userId: 'ghost', visible: false })
		];
		expect(visibleOthers(viewers, 'me').map((v) => v.userId)).toEqual(['them']);
	});

	it('keeps everyone when there is no current user', () => {
		const viewers = [viewer({ userId: 'a' }), viewer({ userId: 'b' })];
		expect(visibleOthers(viewers, null)).toHaveLength(2);
	});
});

describe('viewerOverflow', () => {
	it('returns all viewers and zero extra under the cap', () => {
		const v = [viewer({ userId: 'a' }), viewer({ userId: 'b' })];
		expect(viewerOverflow(v, 3)).toEqual({ shown: v, extra: 0 });
	});

	it('caps the shown list and counts the overflow', () => {
		const v = ['a', 'b', 'c', 'd'].map((id) => viewer({ userId: id }));
		const { shown, extra } = viewerOverflow(v, 2);
		expect(shown.map((x) => x.userId)).toEqual(['a', 'b']);
		expect(extra).toBe(2);
	});
});

describe('viewerInitials', () => {
	it('uses first + last initial for multi-word names', () => {
		expect(viewerInitials({ name: 'Ada Lovelace' })).toBe('AL');
	});

	it('uses the first two letters of a single name', () => {
		expect(viewerInitials({ name: 'ada' })).toBe('AD');
	});

	it('falls back to ? for an empty name', () => {
		expect(viewerInitials({ name: '   ' })).toBe('?');
	});
});
