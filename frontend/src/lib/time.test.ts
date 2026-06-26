import { describe, expect, it } from 'vitest';
import { compactTime, messageTime, relativeTime } from './time';

const NOW = new Date('2026-06-12T12:00:00Z');

describe('compactTime', () => {
	it('formats the nav-row scale', () => {
		expect(compactTime('2026-06-12T11:59:40Z', NOW)).toBe('now');
		expect(compactTime('2026-06-12T11:30:00Z', NOW)).toBe('30m');
		expect(compactTime('2026-06-12T06:00:00Z', NOW)).toBe('6h');
		expect(compactTime('2026-06-09T12:00:00Z', NOW)).toBe('3d');
		expect(compactTime('2026-05-29T12:00:00Z', NOW)).toBe('2w');
		expect(compactTime('2026-03-12T12:00:00Z', NOW)).toBe('3mo');
	});
});

describe('relativeTime', () => {
	it('formats header subtitles', () => {
		expect(relativeTime('2026-06-12T11:59:50Z', NOW)).toBe('just now');
		expect(relativeTime('2026-06-10T12:00:00Z', NOW)).toBe('2d ago');
		expect(relativeTime('2026-05-22T12:00:00Z', NOW)).toBe('3w ago');
	});
});

describe('messageTime', () => {
	it('uses the weekday inside the last week, the date beyond', () => {
		expect(messageTime('2026-06-09T21:14:00Z', NOW)).toMatch(/^Tuesday at \d{2}:\d{2}$/);
		expect(messageTime('2026-05-27T12:23:00Z', NOW)).toMatch(/^May 27 at \d{2}:\d{2}$/);
	});
});
