import {
	setModelFavorite,
	setModelHidden,
	setModelPosition,
	type ModelPreference
} from '$lib/ash/api';
import { invalidateModelPreferences } from '$lib/chat/catalog';

async function apply(
	call: Promise<{ success: true; data: ModelPreference } | { success: false; errors: unknown }>
): Promise<ModelPreference | null> {
	const result = await call;
	if (result.success) {
		invalidateModelPreferences();
		return result.data;
	}
	return null;
}

export function toggleFavorite(modelId: string, favorite: boolean): Promise<ModelPreference | null> {
	return apply(setModelFavorite(modelId, favorite));
}

export function toggleHidden(modelId: string, hidden: boolean): Promise<ModelPreference | null> {
	return apply(setModelHidden(modelId, hidden));
}

export function moveModel(modelId: string, position: number): Promise<ModelPreference | null> {
	return apply(setModelPosition(modelId, position));
}
