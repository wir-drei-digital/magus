import { describe, expect, it } from 'vitest';
import {
	PAID_PLAN_REQUIRED,
	PROVIDER_TYPES,
	SUBSCRIPTION_SETTINGS_PATH,
	badgeKind,
	isPaidPlanRequired,
	requiresBaseUrl
} from './provider-form';

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

	it('detects the paid-plan-required gate rejection', () => {
		expect(isPaidPlanRequired([{ message: PAID_PLAN_REQUIRED }])).toBe(true);
		// Present alongside other errors still trips the gate.
		expect(
			isPaidPlanRequired([{ message: 'provider limit reached' }, { message: PAID_PLAN_REQUIRED }])
		).toBe(true);
	});

	it('does not treat ordinary save errors as a gate rejection', () => {
		expect(isPaidPlanRequired([])).toBe(false);
		expect(isPaidPlanRequired([{ message: 'is not an allowed provider' }])).toBe(false);
		expect(isPaidPlanRequired([{ message: undefined }])).toBe(false);
	});

	it('points the upgrade CTA at the subscription settings route', () => {
		expect(SUBSCRIPTION_SETTINGS_PATH).toBe('/settings/subscription');
	});
});
