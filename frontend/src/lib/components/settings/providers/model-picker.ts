/**
 * Pure logic for the owned-model add form's model-id picker.
 *
 * The picker is fed by a live probe of the provider (`listRemoteModels`): when
 * the probe succeeds and returns ids we render a searchable select; otherwise
 * (auth failure, endpoint unavailable, rate-limited, or an empty listing) we
 * fall back to a free-text input so the user can always type an id manually.
 */
export type RemoteListStatus = 'ok' | 'unauthorized' | 'unavailable' | 'rate_limited';

/** Case-insensitive substring filter; an empty query returns the ids unchanged. */
export function filterModelIds(ids: string[], query: string): string[] {
	const q = query.trim().toLowerCase();
	if (q === '') return ids;
	return ids.filter((id) => id.toLowerCase().includes(q));
}

/** Searchable select only when the probe succeeded and yielded ids; else free-text. */
export function pickerMode(status: RemoteListStatus, ids: string[]): 'picker' | 'freetext' {
	return status === 'ok' && ids.length > 0 ? 'picker' : 'freetext';
}

/**
 * The subset of an owned model needed to render a provider's model rows. Keeps
 * this module free of the generated RPC types so its tests stay pure.
 */
export type OwnedModelRow = { id: string; modelProviderId: string | null };

/**
 * Rows belonging to one provider, derived client-side from the full owned-model
 * list (which spans every provider). Drives the `model-row` count per card.
 */
export function modelsForProvider<T extends OwnedModelRow>(models: T[], providerId: string): T[] {
	return models.filter((model) => model.modelProviderId === providerId);
}
