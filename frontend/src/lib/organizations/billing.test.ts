import { describe, it, expect } from 'vitest';
import { billingStatusLabel, billingStatusDisplay, billingAction } from './billing';

describe('org billing helpers', () => {
	describe('billingStatusLabel', () => {
		it('maps known Stripe statuses to friendly labels', () => {
			expect(billingStatusLabel('active')).toBe('Active');
			expect(billingStatusLabel('past_due')).toBe('Past due');
			expect(billingStatusLabel('canceled')).toBe('Canceled');
			expect(billingStatusLabel('incomplete')).toBe('Incomplete');
			expect(billingStatusLabel('trialing')).toBe('Trialing');
		});

		it('humanizes an unknown status by de-snaking and capitalizing it', () => {
			expect(billingStatusLabel('some_other_state')).toBe('Some other state');
		});

		it('renders a placeholder for a blank status', () => {
			expect(billingStatusLabel('')).toBe('Unknown');
		});
	});

	describe('billingStatusDisplay', () => {
		it("reads 'Not set up' before checkout, ignoring the server's default active status", () => {
			// billing_status defaults to :active at creation; without a Stripe
			// subscription the card must not claim the org is actively billed.
			expect(
				billingStatusDisplay({
					billingStatus: 'active',
					seatCount: 1,
					billingSetUp: false,
					billingEdition: true
				})
			).toBe('Not set up');
		});

		it('falls through to the status label once billing is set up', () => {
			expect(
				billingStatusDisplay({
					billingStatus: 'active',
					seatCount: 4,
					billingSetUp: true,
					billingEdition: true
				})
			).toBe('Active');

			expect(
				billingStatusDisplay({
					billingStatus: 'past_due',
					seatCount: 4,
					billingSetUp: true,
					billingEdition: true
				})
			).toBe('Past due');
		});
	});

	describe('billingAction', () => {
		it('is unavailable when the billing edition is absent (open-core self-host)', () => {
			// billingEdition wins over every other flag: no Stripe surface at all.
			expect(
				billingAction({
					billingStatus: 'active',
					seatCount: 3,
					billingSetUp: true,
					billingEdition: false
				})
			).toEqual({ kind: 'unavailable' });
		});

		it('offers setup when the edition is present but billing is not set up', () => {
			expect(
				billingAction({
					billingStatus: 'incomplete',
					seatCount: 1,
					billingSetUp: false,
					billingEdition: true
				})
			).toEqual({ kind: 'setup' });
		});

		it('offers manage once billing is set up', () => {
			expect(
				billingAction({
					billingStatus: 'active',
					seatCount: 5,
					billingSetUp: true,
					billingEdition: true
				})
			).toEqual({ kind: 'manage' });
		});
	});
});
