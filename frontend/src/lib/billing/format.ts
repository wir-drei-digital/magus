/** Money + token formatting for the billing section. Amounts are in cents. */

export function formatCents(cents: number | null | undefined): string {
	if (cents == null) return '—';
	return `CHF ${(cents / 100).toFixed(2)}`;
}

export function formatTokens(tokens: number): string {
	if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`;
	if (tokens >= 1_000) return `${(tokens / 1_000).toFixed(1)}K`;
	return String(tokens);
}

/**
 * A member's monthly spend cap in CHF, or "No cap" when none is set. Reuses the
 * shared cents formatter so a set cap matches how spend is rendered elsewhere.
 */
export function formatCap(cents: number | null): string {
	if (cents == null) return 'No cap';
	return formatCents(cents);
}
