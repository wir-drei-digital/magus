import { describe, expect, it } from 'vitest';
import { providerLabel } from './provider-label';

describe('providerLabel', () => {
	it('upper-cases a known acronym key', () => {
		expect(providerLabel('api')).toBe('API');
	});

	it('combines an acronym with a title-cased word', () => {
		expect(providerLabel('rss_source')).toBe('RSS Source');
	});

	it('title-cases an ordinary single-word provider', () => {
		expect(providerLabel('telegram')).toBe('Telegram');
		expect(providerLabel('notion')).toBe('Notion');
	});

	it('title-cases a multi-word provider', () => {
		expect(providerLabel('google_drive')).toBe('Google Drive');
	});

	it('normalizes already-cased or mixed input', () => {
		expect(providerLabel('RSS_Source')).toBe('RSS Source');
		expect(providerLabel('Telegram')).toBe('Telegram');
	});

	it('accepts spaces and hyphens as separators', () => {
		expect(providerLabel('rss-source')).toBe('RSS Source');
	});

	it('returns an empty string for empty input', () => {
		expect(providerLabel('')).toBe('');
	});
});
