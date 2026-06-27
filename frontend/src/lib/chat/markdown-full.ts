/**
 * Heavy markdown pipeline: highlight.js syntax highlighting + KaTeX math, plus
 * Mermaid fences (emitted as `<pre class="mermaid">` for markdown.svelte to
 * render in the DOM). Dynamically imported by markdown.svelte for settled
 * messages that contain code or math (see `hasRichContent`), so highlight.js and
 * KaTeX stay out of the main chat bundle and never load for plain-text chats.
 */
import { Marked, type Tokens } from 'marked';
import markedKatex from 'marked-katex-extension';
import markedFootnote from 'marked-footnote';
import hljs from 'highlight.js';
import katex from 'katex';
import { escapeHtml, languageOf, sanitizeAndCite, type Citation } from './markdown';
import { markedEmojiShortcodes } from './emoji-shortcodes';

const MATH_FENCES = new Set(['math', 'latex', 'katex', 'tex']);

/** Full fenced-code renderer: mermaid → a `<pre class="mermaid">` the component
 *  renders later, math → server-side KaTeX, else highlight.js. */
function richCode({ text, lang }: Tokens.Code): string {
	const language = languageOf(lang);

	if (language === 'mermaid') {
		return `<pre class="mermaid">${escapeHtml(text)}</pre>`;
	}

	if (MATH_FENCES.has(language)) {
		try {
			return katex.renderToString(text, {
				displayMode: true,
				throwOnError: false,
				output: 'htmlAndMathml'
			});
		} catch {
			return `<pre><code>${escapeHtml(text)}</code></pre>`;
		}
	}

	if (language && hljs.getLanguage(language)) {
		const { value } = hljs.highlight(text, { language, ignoreIllegals: true });
		return `<pre><code class="hljs language-${escapeHtml(language)}">${value}</code></pre>`;
	}

	const { value } = hljs.highlightAuto(text);
	return `<pre><code class="hljs">${value}</code></pre>`;
}

// Full pipeline (settled messages): KaTeX + highlight.js + footnotes.
const mdFull = new Marked();
mdFull.use(markedKatex({ throwOnError: false, output: 'htmlAndMathml' }));
mdFull.use(markedFootnote());
mdFull.use(markedEmojiShortcodes);
mdFull.use({ renderer: { code: richCode } });

/** Full render: highlight.js + KaTeX + footnotes + sanitize + citation badges. */
export function renderMarkdownFull(text: string, citations?: Citation[] | null): string {
	return sanitizeAndCite(mdFull.parse(text, { async: false }) as string, citations);
}
