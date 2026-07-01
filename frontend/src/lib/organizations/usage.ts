/**
 * Pure, DOM-free helpers for the organization Usage tab. Kept separate from the
 * Svelte view so they stay unit-testable in the node vitest environment and carry
 * no dependency on the generated RPC client.
 *
 * Scoping is NEVER decided here: the server already returns the visible member
 * set (owner sees everyone, a member sees only their own row), so these helpers
 * pass rows through untouched and only shape display and pluralization.
 */

import { formatCents } from '$lib/billing/format';

/** The minimal member shape these helpers read; the real member is a superset. */
export type UsageMemberLike = {
	userId: string;
	displayName?: string | null;
	spentCents: number;
	capCents?: number | null;
};

/** The minimal overview shape these helpers read. */
export type UsageOverviewLike = {
	seatCount: number;
	members: UsageMemberLike[];
};

/** A per-member display row for the usage table. */
export type UsageRow = {
	userId: string;
	name: string;
	spentCents: number;
	capCents: number | null;
};

/**
 * Map the (already scoped) overview members into display rows, resolving each
 * member's name to their display name, or "Unknown" when it is blank. The server
 * ordering is preserved and no filtering is applied.
 */
export function usageRows(overview: UsageOverviewLike): UsageRow[] {
	return overview.members.map((member) => ({
		userId: member.userId,
		name: member.displayName?.trim() || 'Unknown',
		spentCents: member.spentCents,
		capCents: member.capCents ?? null
	}));
}

/** The pooled label shown next to pooled spend, e.g. "1 seat" / "4 seats". */
export function seatLabel(seatCount: number): string {
	return `${seatCount} seat${seatCount === 1 ? '' : 's'}`;
}

/**
 * A member's monthly spend cap in CHF, or a placeholder glyph when they have no
 * cap set. Reuses the shared cents formatter so the currency style matches spend.
 */
export function formatCap(cents: number | null): string {
	if (cents == null) return '—';
	return formatCents(cents);
}
