<script lang="ts">
	import { renderMarkdownLight, hasRichContent, type Citation } from '$lib/chat/markdown';

	let {
		text,
		citations = null,
		streaming = false
	}: { text: string; citations?: Citation[] | null; streaming?: boolean } = $props();

	// Immediate, dependency-light render (marked + footnotes + sanitize). Skips
	// the per-frame highlight.js + KaTeX cost while streaming.
	const baseHtml = $derived(renderMarkdownLight(text, citations));

	// Upgrade settled messages that actually contain code or math to the full
	// pipeline, dynamically imported so highlight.js + KaTeX (and Mermaid) stay
	// out of the chat bundle and never load for plain-text chats.
	let fullHtml = $state<string | null>(null);
	$effect(() => {
		const settledText = text;
		const settledCitations = citations;
		if (streaming || !hasRichContent(settledText)) {
			fullHtml = null;
			return;
		}
		let cancelled = false;
		void import('$lib/chat/markdown-full').then(({ renderMarkdownFull }) => {
			if (!cancelled) fullHtml = renderMarkdownFull(settledText, settledCitations);
		});
		return () => {
			cancelled = true;
		};
	});

	const html = $derived(fullHtml ?? baseHtml);

	// Mermaid runs against the live DOM: `pre.mermaid` blocks are replaced with
	// SVG once their source is complete. It's lazily imported so the (heavy)
	// library only loads when a diagram actually appears.
	let container = $state<HTMLDivElement | null>(null);
	let mermaidLib: Promise<typeof import('mermaid')> | null = null;

	function loadMermaid() {
		mermaidLib ??= import('mermaid');
		return mermaidLib;
	}

	$effect(() => {
		void html; // re-run whenever the rendered markup changes
		const el = container;
		if (!el) return;
		const nodes = Array.from(
			el.querySelectorAll<HTMLElement>('pre.mermaid:not([data-mermaid-done])')
		);
		if (nodes.length === 0) return;

		let cancelled = false;
		void (async () => {
			const { default: mermaid } = await loadMermaid();
			if (cancelled) return;
			const dark = document.documentElement.classList.contains('dark');
			mermaid.initialize({
				startOnLoad: false,
				securityLevel: 'strict',
				suppressErrorRendering: true,
				theme: dark ? 'dark' : 'default',
				fontFamily: 'inherit'
			});
			for (const node of nodes) {
				if (cancelled) return;
				const code = node.textContent ?? '';
				try {
					const { svg } = await mermaid.render(`mmd-${crypto.randomUUID()}`, code);
					if (cancelled) return;
					node.innerHTML = svg;
					node.setAttribute('data-mermaid-done', '');
					node.classList.add('mermaid-rendered');
				} catch {
					// Incomplete (mid-stream) or invalid diagram: leave the source
					// visible. A later html update with complete source retries.
				}
			}
		})();
		return () => {
			cancelled = true;
		};
	});
</script>

<div bind:this={container} class="markdown text-sm leading-relaxed">
	<!-- eslint-disable-next-line svelte/no-at-html-tags — sanitized in renderMarkdown -->
	{@html html}
</div>

<style>
	.markdown :global(p) {
		margin: 0.5rem 0;
	}
	.markdown :global(p:first-child) {
		margin-top: 0;
	}
	.markdown :global(p:last-child) {
		margin-bottom: 0;
	}
	.markdown :global(pre) {
		background: var(--color-muted);
		border-radius: 0.5rem;
		padding: 0.75rem;
		overflow-x: auto;
		font-size: 0.8125rem;
		margin: 0.5rem 0;
	}
	.markdown :global(code) {
		font-family: ui-monospace, monospace;
		font-size: 0.8125rem;
	}
	.markdown :global(:not(pre) > code) {
		background: var(--color-muted);
		border-radius: 0.25rem;
		padding: 0.125rem 0.375rem;
	}
	.markdown :global(ul),
	.markdown :global(ol) {
		padding-left: 1.25rem;
		margin: 0.5rem 0;
	}
	.markdown :global(ul) {
		list-style: disc;
	}
	.markdown :global(ol) {
		list-style: decimal;
	}
	.markdown :global(a) {
		text-decoration: underline;
		text-underline-offset: 2px;
	}
	.markdown :global(h1),
	.markdown :global(h2),
	.markdown :global(h3) {
		font-weight: 600;
		margin: 0.75rem 0 0.25rem;
	}
	.markdown :global(blockquote) {
		border-left: 2px solid var(--color-border);
		padding-left: 0.75rem;
		color: var(--color-muted-foreground);
		margin: 0.5rem 0;
	}
	.markdown :global(table) {
		border-collapse: collapse;
		margin: 0.5rem 0;
	}
	.markdown :global(th),
	.markdown :global(td) {
		border: 1px solid var(--color-border);
		padding: 0.25rem 0.5rem;
		font-size: 0.8125rem;
	}

	/* Block math + mermaid: centered, horizontally scrollable. */
	.markdown :global(.katex-display) {
		margin: 0.5rem 0;
		overflow-x: auto;
		overflow-y: hidden;
	}
	.markdown :global(pre.mermaid) {
		background: transparent;
		text-align: center;
		font-family: ui-monospace, monospace;
		/* While unrendered, show the source as a code block. */
		white-space: pre-wrap;
	}
	.markdown :global(pre.mermaid.mermaid-rendered) {
		white-space: normal;
	}
	.markdown :global(pre.mermaid svg) {
		max-width: 100%;
		height: auto;
	}

	/* Citation badge: clickable [N] reference (replace_citation_references). */
	.markdown :global(.chat-citation) {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		height: 1.25rem;
		padding: 0 0.375rem;
		margin: 0 0.125rem;
		font-size: 0.75rem;
		font-weight: 500;
		line-height: 1;
		border-radius: 0.25rem;
		text-decoration: none;
		vertical-align: baseline;
		color: var(--color-primary);
		background: color-mix(in oklab, var(--color-primary) 18%, transparent);
	}
	.markdown :global(.chat-citation:hover) {
		background: color-mix(in oklab, var(--color-primary) 30%, transparent);
	}

	/*
	 * highlight.js tokens, mapped to the GitHub light/dark palettes (the SPA
	 * follows `.dark` on <html>). The pre's muted background carries the block;
	 * .hljs only colors tokens. Mirrors the workbench's MDEx github_pre_lang.
	 */
	.markdown :global(.hljs) {
		color: inherit;
		background: transparent;
	}
	.markdown :global(.hljs-doctag),
	.markdown :global(.hljs-keyword),
	.markdown :global(.hljs-meta .hljs-keyword),
	.markdown :global(.hljs-template-tag),
	.markdown :global(.hljs-template-variable),
	.markdown :global(.hljs-type),
	.markdown :global(.hljs-variable.language_) {
		color: #d73a49;
	}
	.markdown :global(.hljs-title),
	.markdown :global(.hljs-title.class_),
	.markdown :global(.hljs-title.class_.inherited__),
	.markdown :global(.hljs-title.function_) {
		color: #6f42c1;
	}
	.markdown :global(.hljs-attr),
	.markdown :global(.hljs-attribute),
	.markdown :global(.hljs-literal),
	.markdown :global(.hljs-meta),
	.markdown :global(.hljs-number),
	.markdown :global(.hljs-operator),
	.markdown :global(.hljs-variable),
	.markdown :global(.hljs-selector-attr),
	.markdown :global(.hljs-selector-class),
	.markdown :global(.hljs-selector-id) {
		color: #005cc5;
	}
	.markdown :global(.hljs-regexp),
	.markdown :global(.hljs-string),
	.markdown :global(.hljs-meta .hljs-string) {
		color: #032f62;
	}
	.markdown :global(.hljs-built_in),
	.markdown :global(.hljs-symbol) {
		color: #e36209;
	}
	.markdown :global(.hljs-comment),
	.markdown :global(.hljs-code),
	.markdown :global(.hljs-formula) {
		color: #6a737d;
	}
	.markdown :global(.hljs-name),
	.markdown :global(.hljs-quote),
	.markdown :global(.hljs-selector-tag),
	.markdown :global(.hljs-selector-pseudo) {
		color: #22863a;
	}
	.markdown :global(.hljs-subst) {
		color: inherit;
	}
	.markdown :global(.hljs-section) {
		color: #005cc5;
		font-weight: 600;
	}
	.markdown :global(.hljs-bullet) {
		color: #735c0f;
	}
	.markdown :global(.hljs-emphasis) {
		font-style: italic;
	}
	.markdown :global(.hljs-strong) {
		font-weight: 600;
	}
	.markdown :global(.hljs-addition) {
		color: #22863a;
		background-color: #f0fff4;
	}
	.markdown :global(.hljs-deletion) {
		color: #b31d28;
		background-color: #ffeef0;
	}

	:global(.dark) .markdown :global(.hljs-doctag),
	:global(.dark) .markdown :global(.hljs-keyword),
	:global(.dark) .markdown :global(.hljs-meta .hljs-keyword),
	:global(.dark) .markdown :global(.hljs-template-tag),
	:global(.dark) .markdown :global(.hljs-template-variable),
	:global(.dark) .markdown :global(.hljs-type),
	:global(.dark) .markdown :global(.hljs-variable.language_) {
		color: #ff7b72;
	}
	:global(.dark) .markdown :global(.hljs-title),
	:global(.dark) .markdown :global(.hljs-title.class_),
	:global(.dark) .markdown :global(.hljs-title.class_.inherited__),
	:global(.dark) .markdown :global(.hljs-title.function_) {
		color: #d2a8ff;
	}
	:global(.dark) .markdown :global(.hljs-attr),
	:global(.dark) .markdown :global(.hljs-attribute),
	:global(.dark) .markdown :global(.hljs-literal),
	:global(.dark) .markdown :global(.hljs-meta),
	:global(.dark) .markdown :global(.hljs-number),
	:global(.dark) .markdown :global(.hljs-operator),
	:global(.dark) .markdown :global(.hljs-variable),
	:global(.dark) .markdown :global(.hljs-selector-attr),
	:global(.dark) .markdown :global(.hljs-selector-class),
	:global(.dark) .markdown :global(.hljs-selector-id) {
		color: #79c0ff;
	}
	:global(.dark) .markdown :global(.hljs-regexp),
	:global(.dark) .markdown :global(.hljs-string),
	:global(.dark) .markdown :global(.hljs-meta .hljs-string) {
		color: #a5d6ff;
	}
	:global(.dark) .markdown :global(.hljs-built_in),
	:global(.dark) .markdown :global(.hljs-symbol) {
		color: #ffa657;
	}
	:global(.dark) .markdown :global(.hljs-comment),
	:global(.dark) .markdown :global(.hljs-code),
	:global(.dark) .markdown :global(.hljs-formula) {
		color: #8b949e;
	}
	:global(.dark) .markdown :global(.hljs-name),
	:global(.dark) .markdown :global(.hljs-quote),
	:global(.dark) .markdown :global(.hljs-selector-tag),
	:global(.dark) .markdown :global(.hljs-selector-pseudo) {
		color: #7ee787;
	}
	:global(.dark) .markdown :global(.hljs-section) {
		color: #1f6feb;
	}
	:global(.dark) .markdown :global(.hljs-bullet) {
		color: #f2cc60;
	}
	:global(.dark) .markdown :global(.hljs-addition) {
		color: #aff5b4;
		background-color: #033a16;
	}
	:global(.dark) .markdown :global(.hljs-deletion) {
		color: #ffdcd7;
		background-color: #67060c;
	}
</style>
