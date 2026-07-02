/**
 * Pure, DOM-free helpers for the organization members roster. Kept separate from
 * the Svelte views so they stay unit-testable in the node vitest environment and
 * carry no dependency on the generated RPC client.
 *
 * Authorization is NEVER decided here — these only shape display and ordering.
 * Owner-only controls are gated in the view by the membership role, and the
 * server enforces every mutation via the organization policies.
 */

/** The minimal shape these helpers read; the real `OrgMemberEntry` is a superset. */
export type MemberLike = {
	role?: string | null;
	inviteEmail?: string | null;
	user?: { displayName?: string | null; email?: string | null } | null;
};

/**
 * The best human label for a member row: their display name, then their account
 * email, then the pending-invite email, and finally a placeholder for rows with
 * none of the above.
 */
export function memberDisplayName(member: MemberLike): string {
	return (
		member.user?.displayName || member.user?.email || member.inviteEmail || 'Unknown'
	);
}

/**
 * Owners first, then everyone else, each group ordered case-insensitively by
 * display name. Returns a new array; the input is left untouched.
 */
export function sortMembers<T extends MemberLike>(members: T[]): T[] {
	return [...members].sort((a, b) => {
		const aOwner = a.role === 'owner' ? 0 : 1;
		const bOwner = b.role === 'owner' ? 0 : 1;
		if (aOwner !== bOwner) return aOwner - bOwner;
		return memberDisplayName(a).localeCompare(memberDisplayName(b), undefined, {
			sensitivity: 'base'
		});
	});
}

/**
 * A pragmatic invite-email check (trimmed, single `@`, a dotted domain). The
 * server is the source of truth; this only guards the form to avoid obviously
 * bad round-trips.
 */
export function isValidInviteEmail(email: string): boolean {
	return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
}

/**
 * Gates the irreversible "Delete organization" confirm: the user must type the
 * organization's name exactly (whitespace trimmed on both sides). Never confirms
 * on an empty name, so a blank org name can't auto-arm the destructive action.
 */
export function canConfirmArchive(typed: string, orgName: string): boolean {
	const target = orgName.trim();
	return target !== '' && typed.trim() === target;
}
