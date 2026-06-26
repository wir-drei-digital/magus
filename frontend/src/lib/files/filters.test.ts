import { describe, expect, it } from 'vitest';
import { matchesModified, matchesSource, matchesType } from './filters';

const NOW = new Date('2026-06-12T12:00:00Z');

describe('matchesType', () => {
	it('separates pdf from other documents by mime type', () => {
		const pdf = { type: 'document' as const, mimeType: 'application/pdf' };
		const docx = { type: 'document' as const, mimeType: 'application/msword' };

		expect(matchesType(pdf, 'pdf')).toBe(true);
		expect(matchesType(docx, 'pdf')).toBe(false);
		expect(matchesType(pdf, 'document')).toBe(false);
		expect(matchesType(docx, 'document')).toBe(true);
		expect(matchesType(pdf, 'any')).toBe(true);
	});

	it('matches simple types directly', () => {
		expect(matchesType({ type: 'image', mimeType: 'image/png' }, 'image')).toBe(true);
		expect(matchesType({ type: 'video', mimeType: 'video/mp4' }, 'image')).toBe(false);
	});
});

describe('matchesModified', () => {
	it('buckets by age with classic boundaries', () => {
		expect(matchesModified('2026-06-12T08:00:00Z', 'today', NOW)).toBe(true);
		expect(matchesModified('2026-06-09T12:00:00Z', 'today', NOW)).toBe(false);
		expect(matchesModified('2026-06-09T12:00:00Z', 'this_week', NOW)).toBe(true);
		expect(matchesModified('2026-05-20T12:00:00Z', 'this_month', NOW)).toBe(true);
		expect(matchesModified('2024-01-01T12:00:00Z', 'this_year', NOW)).toBe(false);
		expect(matchesModified('2024-01-01T12:00:00Z', 'older', NOW)).toBe(true);
		expect(matchesModified('2026-06-12T08:00:00Z', 'older', NOW)).toBe(false);
		expect(matchesModified('2020-01-01T00:00:00Z', 'any', NOW)).toBe(true);
	});
});

describe('matchesSource', () => {
	it('maps the classic source labels onto the resource enum', () => {
		const user = { source: 'user' as const };
		const agent = { source: 'agent' as const };
		const connector = { source: 'connector' as const };

		expect(matchesSource(user, 'uploaded')).toBe(true);
		expect(matchesSource(agent, 'uploaded')).toBe(false);
		expect(matchesSource(agent, 'agent')).toBe(true);
		expect(matchesSource(connector, 'synced')).toBe(true);
		expect(matchesSource(connector, 'any')).toBe(true);
	});
});
