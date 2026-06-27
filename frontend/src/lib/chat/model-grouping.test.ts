import { describe, expect, it } from 'vitest';
import { FAVORITES_GROUP, groupModels, prefsById, type ModelFilters } from './model-grouping';
import type { ModelPreference, ModelSummary } from '$lib/ash/api';

function model(id: string, over: Partial<ModelSummary> = {}): ModelSummary {
	return {
		id,
		name: id,
		provider: 'Acme',
		shortDescription: null,
		contextWindow: null,
		inputModalities: ['text'],
		outputModalities: ['text'],
		supportsSearch: false,
		supportsReasoning: false,
		supportsTools: true,
		inputCost: null,
		outputCost: null,
		requestCostCents: null,
		...over
	};
}

function pref(modelId: string, over: Partial<ModelPreference> = {}): ModelPreference {
	return { id: `p-${modelId}`, modelId, favorite: false, hidden: false, position: null, ...over };
}

const NO_FILTERS: ModelFilters = {
	search: '',
	favoritesOnly: false,
	showHidden: false,
	capability: 'any'
};

describe('groupModels', () => {
	it('puts favorites first and removes them from their provider group', () => {
		const models = [model('a'), model('b')];
		const prefs = prefsById([pref('a', { favorite: true })]);
		const groups = groupModels(models, prefs, NO_FILTERS);

		expect(groups[0].label).toBe(FAVORITES_GROUP);
		expect(groups[0].models.map((m) => m.id)).toEqual(['a']);
		const acme = groups.find((g) => g.label === 'Acme');
		expect(acme?.models.map((m) => m.id)).toEqual(['b']);
	});

	it('omits the Favorites group when there are none', () => {
		const groups = groupModels([model('a')], prefsById([]), NO_FILTERS);
		expect(groups.some((g) => g.label === FAVORITES_GROUP)).toBe(false);
	});

	it('hides hidden models unless showHidden is on', () => {
		const models = [model('a'), model('b')];
		const prefs = prefsById([pref('a', { hidden: true })]);
		expect(groupModels(models, prefs, NO_FILTERS).flatMap((g) => g.models.map((m) => m.id))).toEqual([
			'b'
		]);
		expect(
			groupModels(models, prefs, { ...NO_FILTERS, showHidden: true }).flatMap((g) =>
				g.models.map((m) => m.id)
			)
		).toEqual(['a', 'b']);
	});

	it('hidden wins over favorite in the picker', () => {
		const prefs = prefsById([pref('a', { favorite: true, hidden: true })]);
		const groups = groupModels([model('a')], prefs, NO_FILTERS);
		expect(groups).toEqual([]);
	});

	it('favoritesOnly keeps only favorites', () => {
		const models = [model('a'), model('b')];
		const prefs = prefsById([pref('a', { favorite: true })]);
		const groups = groupModels(models, prefs, { ...NO_FILTERS, favoritesOnly: true });
		expect(groups.flatMap((g) => g.models.map((m) => m.id))).toEqual(['a']);
	});

	it('filters by capability', () => {
		const models = [model('a', { supportsReasoning: true }), model('b')];
		const groups = groupModels(models, prefsById([]), { ...NO_FILTERS, capability: 'reasoning' });
		expect(groups.flatMap((g) => g.models.map((m) => m.id))).toEqual(['a']);
	});

	it('filters by search across name and provider', () => {
		const models = [model('alpha', { provider: 'OpenAI' }), model('beta', { provider: 'Acme' })];
		const groups = groupModels([...models], prefsById([]), { ...NO_FILTERS, search: 'openai' });
		expect(groups.flatMap((g) => g.models.map((m) => m.id))).toEqual(['alpha']);
	});

	it('orders by position then name', () => {
		const models = [model('a'), model('b'), model('c')];
		const prefs = prefsById([
			pref('a', { favorite: true, position: 2 }),
			pref('b', { favorite: true, position: 1 }),
			pref('c', { favorite: true })
		]);
		const favorites = groupModels(models, prefs, NO_FILTERS)[0];
		expect(favorites.models.map((m) => m.id)).toEqual(['b', 'a', 'c']);
	});
});
