/**
 * Acronyms that read better fully upper-cased in a provider label.
 * Keep lowercase here; lookup is case-insensitive.
 */
const ACRONYMS = new Set(['api', 'rss', 'url', 'ai', 'mcp', 'id', 'sdk']);

function humanizeWord(word: string): string {
	const lower = word.toLowerCase();
	if (ACRONYMS.has(lower)) return lower.toUpperCase();
	return lower.charAt(0).toUpperCase() + lower.slice(1);
}

/**
 * Turn an integration/knowledge provider key into a human-readable label.
 * Splits on `_`, `-`, and whitespace, title-cases each word, and upper-cases
 * known acronyms: `api` → `API`, `rss_source` → `RSS Source`,
 * `google_drive` → `Google Drive`.
 */
export function providerLabel(key: string): string {
	if (!key) return '';
	return key
		.split(/[_\s-]+/)
		.filter(Boolean)
		.map(humanizeWord)
		.join(' ');
}
