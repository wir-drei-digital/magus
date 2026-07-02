/**
 * Pure form/display logic for the BYOK providers settings page.
 *
 * `PROVIDER_TYPES` are the `req_llm_id` values a user may pick when adding a
 * provider. The type is immutable after creation (it maps to the ReqLLM
 * provider id), so the page disables the select on edit.
 */
export const PROVIDER_TYPES = [
	'anthropic',
	'openai',
	'openrouter',
	'xai',
	'google',
	'openai_compatible'
] as const;
export type ProviderType = (typeof PROVIDER_TYPES)[number];

/**
 * Only `openai_compatible` providers need an explicit base URL; the rest have a
 * well-known endpoint baked into ReqLLM.
 */
export function requiresBaseUrl(type: ProviderType): boolean {
	return type === 'openai_compatible';
}

export type ValidationStatus = 'pending' | 'valid' | 'invalid' | 'error';

/**
 * Maps a credential validation status to a visual badge kind. Kept pure and
 * decoupled from any styling so the page can translate the kind to classes.
 */
export function badgeKind(
	status: ValidationStatus
): 'neutral' | 'success' | 'danger' | 'warning' {
	switch (status) {
		case 'valid':
			return 'success';
		case 'invalid':
			return 'danger';
		case 'error':
			return 'warning';
		default:
			return 'neutral';
	}
}
