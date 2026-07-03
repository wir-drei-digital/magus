import { describe, expect, it } from 'vitest';
import { PROVIDER_TYPES, badgeKind, requiresBaseUrl } from './provider-form';

describe('provider form logic', () => {
	it('only openai_compatible requires base url', () => {
		expect(requiresBaseUrl('openai_compatible')).toBe(true);
		for (const t of PROVIDER_TYPES.filter((t) => t !== 'openai_compatible')) {
			expect(requiresBaseUrl(t)).toBe(false);
		}
	});

	it('maps validation status to badge kind', () => {
		expect(badgeKind('valid')).toBe('success');
		expect(badgeKind('invalid')).toBe('danger');
		expect(badgeKind('error')).toBe('warning');
		expect(badgeKind('pending')).toBe('neutral');
	});
});
