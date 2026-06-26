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
