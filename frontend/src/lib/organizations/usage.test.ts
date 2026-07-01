import { describe, it, expect } from 'vitest';
import { usageRows, seatLabel, formatCap } from './usage';

describe('org usage helpers', () => {
	describe('usageRows', () => {
		it('maps members into display rows, resolving the name fallback', () => {
			const rows = usageRows({
				seatCount: 2,
				members: [
					{ userId: 'u1', displayName: 'Alice', spentCents: 1234, capCents: 5000 },
					{ userId: 'u2', displayName: null, spentCents: 0, capCents: null }
				]
			});
			expect(rows).toEqual([
				{ userId: 'u1', name: 'Alice', spentCents: 1234, capCents: 5000 },
				{ userId: 'u2', name: 'Unknown', spentCents: 0, capCents: null }
			]);
		});

		it('preserves the server ordering and does not re-filter rows', () => {
			// The server already scopes the members list (owner: all, member: own),
			// so the helper must pass rows through untouched.
			const rows = usageRows({
				seatCount: 1,
				members: [{ userId: 'only', displayName: 'Solo', spentCents: 500, capCents: null }]
			});
			expect(rows).toHaveLength(1);
			expect(rows[0].userId).toBe('only');
		});

		it('treats a blank display name as Unknown', () => {
			const rows = usageRows({
				seatCount: 1,
				members: [{ userId: 'u', displayName: '   ', spentCents: 0, capCents: null }]
			});
			expect(rows[0].name).toBe('Unknown');
		});

		it('defaults a missing cap to null', () => {
			const rows = usageRows({
				seatCount: 1,
				members: [{ userId: 'u', displayName: 'A', spentCents: 0 }]
			});
			expect(rows[0].capCents).toBeNull();
		});
	});

	describe('seatLabel', () => {
		it('pluralizes the seat count', () => {
			expect(seatLabel(1)).toBe('1 seat');
			expect(seatLabel(0)).toBe('0 seats');
			expect(seatLabel(4)).toBe('4 seats');
		});
	});

	describe('formatCap', () => {
		it('formats a set cap as CHF', () => {
			expect(formatCap(5000)).toBe('CHF 50.00');
		});

		it('renders a placeholder when there is no cap', () => {
			expect(formatCap(null)).toBe('—');
		});
	});
});
