// @vitest-environment jsdom
// The renderers sanitize via DOMPurify, which needs a DOM window.
import { describe, expect, it } from 'vitest';
import {
	CITATION_CLASS,
	hasRichContent,
	referencedCitations,
	renderMarkdownLight
} from './markdown';
import { renderMarkdownFull } from './markdown-full';

describe('renderMarkdownLight', () => {
	it('renders basic markdown to sanitized html', () => {
		const html = renderMarkdownLight('# Title\n\nHello **world**');
		expect(html).toContain('<h1>Title</h1>');
		expect(html).toContain('<strong>world</strong>');
	});

	it('strips dangerous markup', () => {
		const html = renderMarkdownLight('<img src=x onerror=alert(1)>\n\n<script>alert(2)</script>');
		expect(html).not.toContain('onerror');
		expect(html).not.toContain('<script');
	});

	it('renders footnotes (MDEx footnotes parity)', () => {
		const html = renderMarkdownLight('A claim.[^1]\n\n[^1]: The source.');
		expect(html).toContain('footnote');
		expect(html).toContain('The source.');
	});

	it('escapes fenced code without highlight.js (kept out of the light bundle)', () => {
		const html = renderMarkdownLight('```js\nconst x = 1;\n```');
		expect(html).not.toContain('hljs');
		expect(html).toContain('language-js');
	});

	it('leaves $…$ math literal until the full pass upgrades it', () => {
		const html = renderMarkdownLight('$e^{i\\pi}$');
		expect(html).not.toContain('katex');
	});

	it('does not emit pre.mermaid (no diagram render in the light pass)', () => {
		const html = renderMarkdownLight('```mermaid\ngraph TD; A-->B;\n```');
		expect(html).not.toContain('class="mermaid"');
	});
});

describe('renderMarkdownFull', () => {
	it('syntax-highlights fenced code with hljs + language class', () => {
		const html = renderMarkdownFull('```js\nconst x = 1;\n```');
		expect(html).toContain('class="hljs language-js"');
		expect(html).toContain('hljs-keyword'); // `const`
	});

	it('turns a mermaid fence into a pre.mermaid block (rendered client-side)', () => {
		const html = renderMarkdownFull('```mermaid\ngraph TD; A-->B;\n```');
		expect(html).toContain('<pre class="mermaid">');
		expect(html).toContain('graph TD');
		// Source is escaped, not executed.
		expect(html).toContain('A--&gt;B');
	});

	it('renders inline $…$ math via KaTeX', () => {
		const html = renderMarkdownFull('Euler: $e^{i\\pi} + 1 = 0$ is neat.');
		expect(html).toContain('katex');
		expect(html).toContain('<math'); // MathML kept by the sanitizer
	});

	it('renders a ```math fence as block KaTeX', () => {
		const html = renderMarkdownFull('```math\n\\frac{1}{2}\n```');
		expect(html).toContain('katex');
		expect(html).toContain('katex-display');
	});

	it('does not throw on malformed math, leaving best-effort output', () => {
		expect(() => renderMarkdownFull('$\\frac{1}{$')).not.toThrow();
	});
});

describe('hasRichContent', () => {
	it('detects fenced code and $-math, ignores plain prose', () => {
		expect(hasRichContent('```js\n1\n```')).toBe(true);
		expect(hasRichContent('inline $x$ math')).toBe(true);
		expect(hasRichContent('just some **prose** with a [link](https://x.com)')).toBe(false);
	});
});

describe('citation badges', () => {
	const citations = [
		{ url: 'https://www.example.com/a', title: 'First source' },
		{ url: 'https://docs.foo.org/b', title: 'Second source' }
	];

	it('rewrites [N] into a domain badge linking the citation', () => {
		const html = renderMarkdownLight('See [1] and [2].', citations);
		expect(html).toContain(`class="${CITATION_CLASS}"`);
		expect(html).toContain('>example.com<');
		expect(html).toContain('>docs.foo.org<');
		expect(html).toContain('href="https://www.example.com/a"');
		expect(html).not.toContain('[1]');
	});

	it('leaves out-of-range references untouched', () => {
		const html = renderMarkdownLight('See [9].', citations);
		expect(html).toContain('[9]');
	});

	it('leaves brackets alone when there are no citations', () => {
		const html = renderMarkdownLight('Array index arr[1] here.', []);
		expect(html).toContain('arr[1]');
	});

	it('neutralizes a javascript: citation href to # (scheme allowlist)', () => {
		const html = renderMarkdownLight('See [1].', [{ url: 'javascript:alert(1)', title: 'evil' }]);
		expect(html).not.toContain('javascript:');
		expect(html).toContain('href="#"');
	});
});

describe('referencedCitations', () => {
	const citations = [
		{ url: 'https://a.com', title: 'A' },
		{ url: 'https://b.com', title: 'B' },
		{ url: 'https://a.com', title: 'A dup' }
	];

	it('returns only referenced citations, de-duped by url, in order', () => {
		const result = referencedCitations('Per [2] and again [2].', citations);
		expect(result).toEqual([{ url: 'https://b.com', title: 'B' }]);
	});

	it('falls back to all (de-duped) when no [N] markers are present', () => {
		const result = referencedCitations('No markers here.', citations);
		expect(result).toEqual([
			{ url: 'https://a.com', title: 'A' },
			{ url: 'https://b.com', title: 'B' }
		]);
	});

	it('returns [] for empty / null citations', () => {
		expect(referencedCitations('[1]', null)).toEqual([]);
		expect(referencedCitations('[1]', [])).toEqual([]);
	});

	it('collapses all url-less citations into a single bucket', () => {
		const noUrl = [{ title: 'A' }, { title: 'B' }];
		expect(referencedCitations('no markers', noUrl)).toEqual([{ title: 'A' }]);
	});
});
