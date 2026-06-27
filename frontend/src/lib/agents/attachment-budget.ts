/**
 * Always-include attachment token budget, mirroring the workbench
 * `Magus.Agents.AttachmentLimits`: files in `always` mode are injected into
 * every prompt, so their combined token_count is capped.
 */
export const MAX_ALWAYS_INCLUDE_TOKENS = 30_000;
export const ALWAYS_INCLUDE_WARN_TOKENS = 20_000;

export type BudgetTier = 'ok' | 'warn' | 'over';

/** Sum token_count across `always`-mode attachments (the budgeted set). */
export function alwaysIncludeTokens(attachments: { mode: string; tokenCount: number }[]): number {
	return attachments
		.filter((a) => a.mode === 'always')
		.reduce((sum, a) => sum + (a.tokenCount || 0), 0);
}

/** `over` above the hard cap, `warn` above the soft threshold, else `ok`. */
export function budgetTier(tokens: number): BudgetTier {
	if (tokens > MAX_ALWAYS_INCLUDE_TOKENS) return 'over';
	if (tokens > ALWAYS_INCLUDE_WARN_TOKENS) return 'warn';
	return 'ok';
}
