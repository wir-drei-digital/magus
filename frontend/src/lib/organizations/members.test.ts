import { describe, it, expect } from 'vitest';
import { memberDisplayName, sortMembers, isValidInviteEmail } from './members';

describe('members helpers', () => {
	it('renders a display name', () => {
		expect(
			memberDisplayName({ user: { displayName: 'Bob', email: 'b@x.io' }, inviteEmail: null })
		).toBe('Bob');
		expect(memberDisplayName({ user: null, inviteEmail: 'c@x.io' })).toBe('c@x.io');
	});

	it('falls back to the user email, then to a placeholder', () => {
		expect(memberDisplayName({ user: { displayName: null, email: 'b@x.io' }, inviteEmail: null })).toBe(
			'b@x.io'
		);
		expect(memberDisplayName({ user: null, inviteEmail: null })).toBe('Unknown');
	});

	it('sorts owners first then by name', () => {
		const rows = sortMembers([
			{ role: 'member', user: { displayName: 'Bob' } },
			{ role: 'owner', user: { displayName: 'Alice' } }
		] as never);
		expect(rows[0].role).toBe('owner');
		expect(rows[1].role).toBe('member');
	});

	it('orders same-role members alphabetically and does not mutate the input', () => {
		const input = [
			{ role: 'member', user: { displayName: 'Zed' } },
			{ role: 'member', user: { displayName: 'Ann' } }
		];
		const rows = sortMembers(input as never);
		expect(rows.map((r) => r.user?.displayName)).toEqual(['Ann', 'Zed']);
		// original array left untouched
		expect(input[0].user.displayName).toBe('Zed');
	});

	it('validates invite email', () => {
		expect(isValidInviteEmail('a@b.io')).toBe(true);
		expect(isValidInviteEmail('nope')).toBe(false);
		expect(isValidInviteEmail('')).toBe(false);
		expect(isValidInviteEmail('  spaced@ok.com  ')).toBe(true);
		expect(isValidInviteEmail('a@b')).toBe(false);
	});
});
