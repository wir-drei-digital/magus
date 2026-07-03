import { describe, expect, it } from 'vitest';
import { filterModelIds, modelsForProvider, pickerMode } from './model-picker';

describe('model picker', () => {
	it('filters ids by case-insensitive substring', () => {
		const ids = ['gpt-4o', 'gpt-4o-mini', 'o3-mini'];
		expect(filterModelIds(ids, 'MINI')).toEqual(['gpt-4o-mini', 'o3-mini']);
		expect(filterModelIds(ids, '')).toEqual(ids);
	});

	it('falls back to freetext when listing is not ok', () => {
		expect(pickerMode('ok', ['a'])).toBe('picker');
		expect(pickerMode('ok', [])).toBe('freetext');
		expect(pickerMode('unauthorized', [])).toBe('freetext');
		expect(pickerMode('unavailable', [])).toBe('freetext');
		expect(pickerMode('rate_limited', [])).toBe('freetext');
	});
});

describe('modelsForProvider', () => {
	const models = [
		{ id: 'm1', modelProviderId: 'p1' },
		{ id: 'm2', modelProviderId: 'p2' },
		{ id: 'm3', modelProviderId: 'p1' },
		{ id: 'm4', modelProviderId: null }
	];

	it('keeps only the rows for the given provider', () => {
		expect(modelsForProvider(models, 'p1').map((m) => m.id)).toEqual(['m1', 'm3']);
		expect(modelsForProvider(models, 'p2').map((m) => m.id)).toEqual(['m2']);
	});

	it('returns an empty list when a provider has no models', () => {
		expect(modelsForProvider(models, 'p3')).toEqual([]);
	});
});
