import type { ModelPreference, ModelSummary } from '$lib/ash/api';

export const FAVORITES_GROUP = 'Favorites';

export type ModelFilters = {
	search: string;
	favoritesOnly: boolean;
	showHidden: boolean;
	capability: 'any' | 'search' | 'reasoning' | 'tools';
};

export type ModelGroup = { label: string; models: ModelSummary[] };

/** Index preferences by model id for O(1) lookup while grouping. */
export function prefsById(prefs: ModelPreference[]): Map<string, ModelPreference> {
	return new Map(prefs.map((p) => [p.modelId, p]));
}

/**
 * Group and filter models for the picker. Favorites come first (and are not
 * duplicated in their provider group), then provider groups. Hidden wins over
 * favorite: a hidden model is excluded unless showHidden is on. Within a group,
 * models sort by position (nulls last) then name.
 */
export function groupModels(
	models: ModelSummary[],
	prefs: Map<string, ModelPreference>,
	filters: ModelFilters
): ModelGroup[] {
	const query = filters.search.trim().toLowerCase();

	const visible = models.filter((m) => {
		const pref = prefs.get(m.id);
		if (pref?.hidden && !filters.showHidden) return false;
		if (filters.favoritesOnly && !pref?.favorite) return false;
		if (filters.capability === 'search' && !m.supportsSearch) return false;
		if (filters.capability === 'reasoning' && !m.supportsReasoning) return false;
		if (filters.capability === 'tools' && !m.supportsTools) return false;
		if (
			query !== '' &&
			!m.name.toLowerCase().includes(query) &&
			!(m.provider ?? '').toLowerCase().includes(query)
		) {
			return false;
		}
		return true;
	});

	const orderOf = (m: ModelSummary) => prefs.get(m.id)?.position ?? Number.POSITIVE_INFINITY;
	const byOrderThenName = (a: ModelSummary, b: ModelSummary) =>
		orderOf(a) - orderOf(b) || a.name.localeCompare(b.name);

	const favorites = visible.filter((m) => prefs.get(m.id)?.favorite).sort(byOrderThenName);
	const favoriteIds = new Set(favorites.map((m) => m.id));

	const groups: ModelGroup[] = [];
	if (favorites.length > 0) groups.push({ label: FAVORITES_GROUP, models: favorites });

	const byProvider = new Map<string, ModelSummary[]>();
	for (const m of visible) {
		if (favoriteIds.has(m.id)) continue;
		const key = m.provider ?? 'Other';
		byProvider.set(key, [...(byProvider.get(key) ?? []), m]);
	}
	for (const [label, providerModels] of byProvider) {
		groups.push({ label, models: providerModels.sort(byOrderThenName) });
	}

	return groups;
}
