import { describe, it, expect } from 'vitest';
import { usageRows, seatLabel } from './usage';

describe('org usage helpers', () => {
	describe('usageRows', () => {
		it('maps members into display rows, resolving the name fallback', () => {
			const rows = usageRows({
				seatCount: 2,
				members: [
					{ userId: 'u1', displayName: 'Alice', spentCents: 1234, capCents: 5000, tokens: 42_000 },
					{ userId: 'u2', displayName: null, spentCents: 0, capCents: null, tokens: 0 }
				]
			});
			expect(rows).toEqual([
				{ userId: 'u1', name: 'Alice', spentCents: 1234, capCents: 5000, tokens: 42_000 },
				{ userId: 'u2', name: 'Unknown', spentCents: 0, capCents: null, tokens: 0 }
			]);
		});

		it('preserves the server ordering and does not re-filter rows', () => {
			// The server already scopes the members list (owner: all, member: own),
			// so the helper must pass rows through untouched.
			const rows = usageRows({
				seatCount: 1,
				members: [{ userId: 'only', displayName: 'Solo', spentCents: 500, capCents: null, tokens: 7 }]
			});
			expect(rows).toHaveLength(1);
			expect(rows[0].userId).toBe('only');
		});

		it('treats a blank display name as Unknown', () => {
			const rows = usageRows({
				seatCount: 1,
				members: [{ userId: 'u', displayName: '   ', spentCents: 0, capCents: null, tokens: 0 }]
			});
			expect(rows[0].name).toBe('Unknown');
		});

		it('defaults a missing cap to null and missing tokens to zero', () => {
			const rows = usageRows({
				seatCount: 1,
				members: [{ userId: 'u', displayName: 'A', spentCents: 0 }]
			});
			expect(rows[0].capCents).toBeNull();
			expect(rows[0].tokens).toBe(0);
		});

		it('carries each member token count through to the display row', () => {
			const rows = usageRows({
				seatCount: 2,
				members: [
					{ userId: 'u1', displayName: 'A', spentCents: 0, capCents: null, tokens: 1_500 },
					{ userId: 'u2', displayName: 'B', spentCents: 0, capCents: null, tokens: 0 }
				]
			});
			expect(rows.map((row) => row.tokens)).toEqual([1_500, 0]);
		});
	});

	describe('seatLabel', () => {
		it('pluralizes the seat count', () => {
			expect(seatLabel(1)).toBe('1 seat');
			expect(seatLabel(0)).toBe('0 seats');
			expect(seatLabel(4)).toBe('4 seats');
		});
	});
});
