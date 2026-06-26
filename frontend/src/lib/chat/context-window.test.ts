import { describe, expect, it } from 'vitest';
import { effectiveContextMax, floorBoundaryMessageId, floorDividerLabel } from './context-window';
import type { ChatMessage } from '$lib/ash/api';

const msg = (id: string, insertedAt: string): ChatMessage => ({ id, insertedAt }) as ChatMessage;

describe('floorBoundaryMessageId', () => {
	const messages = [
		msg('a', '2026-06-21T10:00:00.000000Z'),
		msg('b', '2026-06-21T11:00:00.000000Z'),
		msg('c', '2026-06-21T12:00:00.000000Z')
	];

	it('returns null when no floor is set', () => {
		expect(floorBoundaryMessageId(messages, null)).toBeNull();
	});

	it('returns the last out-of-window message when some are out-of-window', () => {
		// Floor at 11:00 → only 'a' (10:00) is out-of-window; the divider anchors
		// to it and renders just below it (above the in-window 'b').
		expect(floorBoundaryMessageId(messages, '2026-06-21T11:00:00.000000Z')).toBe('a');
		// Floor at 12:00 → 'a' and 'b' are out-of-window; anchor to the newest, 'b'.
		expect(floorBoundaryMessageId(messages, '2026-06-21T12:00:00.000000Z')).toBe('b');
	});

	it('anchors past the latest message when the floor cleared the whole window', () => {
		// Mirrors a Clear: the floor sits after every loaded message, so the newest
		// message is the anchor and the divider shows immediately.
		expect(floorBoundaryMessageId(messages, '2026-06-21T13:00:00.000000Z')).toBe('c');
	});

	it('returns null when all loaded messages are in-window', () => {
		expect(floorBoundaryMessageId(messages, '2026-06-21T09:00:00.000000Z')).toBeNull();
	});

	it('returns null for an empty list', () => {
		expect(floorBoundaryMessageId([], '2026-06-21T11:00:00.000000Z')).toBeNull();
	});
});

describe('floorDividerLabel', () => {
	it('says summarized when a summary exists', () => {
		expect(floorDividerLabel(3)).toBe('Older messages summarized');
	});
	it('says out of context otherwise', () => {
		expect(floorDividerLabel(0)).toBe('Older messages are out of context');
	});
});

describe('effectiveContextMax', () => {
	it('uses the selected model window when set', () => {
		expect(effectiveContextMax(200_000, 128_000)).toBe(200_000);
	});
	it('falls back to the snapshot max in auto mode (null selection)', () => {
		expect(effectiveContextMax(null, 128_000)).toBe(128_000);
	});
	it('ignores a non-positive selected window', () => {
		expect(effectiveContextMax(0, 128_000)).toBe(128_000);
	});
});
