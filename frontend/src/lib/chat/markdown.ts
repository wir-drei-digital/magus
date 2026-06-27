/**
 * Light markdown rendering for chat messages: marked + footnotes + sanitize +
 * citation badges, with NO highlight.js / KaTeX so it stays small and ships in
 * the main chat bundle. Used while a message streams and as the immediate base
 * render. Settled messages that contain code or math are upgraded by the full
 * pipeline in `markdown-full.ts`, which is dynamically imported on demand so the
 * heavy syntax-highlight + math deps never load for plain-text chats.
 *
 * Parity target: the workbench MDEx pipeline
 * (lib/magus_web/workbench/chat/components/message/helpers.ex):
 *   - syntax highlighting (highlight.js) — full pipeline
 *   - KaTeX math: inline `$…$` / block `$$…$$` and ```math fences — full pipeline
 *   - Mermaid diagrams: ```mermaid fences become `<pre class="mermaid">` for the
 *     component to render client-side — full pipeline
 *   - footnotes (`[^n]`) — both pipelines
 *   - inline `[N]` citation references rewritten to clickable domain badges
 *     (replace_citation_references) and a referenced-only sources helper
 *
 * Everything here is a pure string transform so it can be unit-tested; the
 * Mermaid DOM pass lives in markdown.svelte.
 */
import { Marked, type Tokens } from 'marked';
import markedFootnote from 'marked-footnote';
import DOMPurify from 'dompurify';
import { markedEmojiShortcodes } from './emoji-shortcodes';

export type Citation = Record<string, unknown>;

/** Class on rendered citation badges; styled in markdown.svelte. */
export const CITATION_CLASS = 'chat-citation';

/** Schemes allowed on a rendered link/badge href (citation badges bypass the
 *  sanitizer, so the scheme is allowlisted here; mirrors the safe href set). */
const SAFE_URL_SCHEME = /^(https?:|mailto:)/i;

export function escapeHtml(text: string): string {
	return text
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

export function languageOf(lang: string | undefined): string {
	return (lang ?? '').trim().split(/\s+/)[0].toLowerCase();
}

/** Light fenced-code renderer: escaped source only, no highlight.js / KaTeX /
 *  Mermaid (those run in the full pipeline once the message settles). */
function plainCode({ text, lang }: Tokens.Code): string {
	const language = languageOf(lang);
	const cls = language ? ` class="language-${escapeHtml(language)}"` : '';
	return `<pre><code${cls}>${escapeHtml(text)}</code></pre>`;
}

// Light pipeline: footnotes only; code is escaped, math/mermaid stay literal
// until the full pass takes over on a settled message.
const mdLight = new Marked();
mdLight.use(markedFootnote());
mdLight.use(markedEmojiShortcodes);
mdLight.use({ renderer: { code: plainCode } });

function citationField(citation: Citation, key: string): string | null {
	const value = citation[key];
	return typeof value === 'string' && value !== '' ? value : null;
}

function citationUrl(citation: Citation): string | null {
	return citationField(citation, 'url');
}

function safeHref(url: string | null): string {
	const candidate = (url ?? '').trim();
	return SAFE_URL_SCHEME.test(candidate) ? candidate : '#';
}

function extractDomain(url: string): string {
	try {
		const host = new URL(url).hostname;
		return host.replace(/^www\./, '') || 'source';
	} catch {
		return 'source';
	}
}

function citationTooltip(citation: Citation): string {
	return citationField(citation, 'title') ?? citationUrl(citation) ?? 'Source';
}

function buildCitationBadge(citation: Citation): string {
	const href = safeHref(citationUrl(citation));
	const domain = extractDomain(href);
	const title = citationTooltip(citation);
	return (
		`<a href="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer"` +
		` title="${escapeHtml(title)}" class="${CITATION_CLASS}">${escapeHtml(domain)}</a>`
	);
}

/**
 * Rewrites `[N]` references into citation badges, mirroring
 * helpers.ex replace_citation_references. Runs on the already-sanitized HTML;
 * each badge is assembled from escaped, controlled values with an allowlisted
 * href scheme, so it stays safe without a second sanitize pass.
 */
function replaceCitationReferences(html: string, citations: Citation[]): string {
	if (citations.length === 0) return html;
	return html.replace(/\[(\d+)\]/g, (full, numStr: string) => {
		const num = Number.parseInt(numStr, 10);
		if (!Number.isInteger(num) || num < 1) return full;
		const citation = citations[num - 1];
		return citation ? buildCitationBadge(citation) : full;
	});
}

/**
 * Sanitize parsed HTML (keeping the MathML + SVG that KaTeX and some embeds
 * emit) and rewrite `[N]` citation references. Shared by the light and full
 * pipelines.
 */
export function sanitizeAndCite(parsedHtml: string, citations?: Citation[] | null): string {
	const html = DOMPurify.sanitize(parsedHtml, {
		USE_PROFILES: { html: true, mathMl: true, svg: true }
	});
	return replaceCitationReferences(html, citations ?? []);
}

/**
 * Light render: marked + footnotes + sanitize + citation badges. Synchronous and
 * dependency-light (no highlight.js / KaTeX). Used while streaming and as the
 * immediate base render; the full pipeline upgrades settled code/math.
 */
export function renderMarkdownLight(text: string, citations?: Citation[] | null): string {
	return sanitizeAndCite(mdLight.parse(text, { async: false }) as string, citations);
}

/**
 * True when the text contains fenced code or `$`-delimited math, i.e. when it is
 * worth loading the heavy full pipeline (highlight.js + KaTeX) to upgrade the
 * render. Plain prose renders identically in both pipelines, so it never
 * triggers the load.
 */
const RICH_CONTENT_RE = /```|\$/;
export function hasRichContent(text: string): boolean {
	return RICH_CONTENT_RE.test(text);
}

/**
 * Citations actually referenced via `[N]` in the text, de-duplicated by URL.
 * Mirrors helpers.ex get_referenced_citations: when the model emitted no `[N]`
 * markers (e.g. some Sonar responses) but citations exist, fall back to all.
 */
export function referencedCitations(text: string, citations: Citation[] | null): Citation[] {
	if (!citations || citations.length === 0) return [];

	const indices = new Set<number>();
	for (const match of text.matchAll(/\[(\d+)\]/g)) {
		const num = Number.parseInt(match[1], 10);
		if (Number.isInteger(num) && num >= 1) indices.add(num - 1);
	}

	const byUrl = (list: Citation[]): Citation[] => {
		const seen = new Set<string>();
		const out: Citation[] = [];
		for (const citation of list) {
			// All url-less citations collapse to one bucket (uniq_by(nil) parity).
			const url = citationUrl(citation) ?? '__nourl__';
			if (seen.has(url)) continue;
			seen.add(url);
			out.push(citation);
		}
		return out;
	};

	const referenced = byUrl(
		[...indices]
			.sort((a, b) => a - b)
			.map((index) => citations[index])
			.filter((citation): citation is Citation => citation != null)
	);

	return referenced.length > 0 ? referenced : byUrl(citations);
}
