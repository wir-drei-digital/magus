import { describe, expect, it } from 'vitest';
import { extractOutline, outlineFromDoc, stripFrontmatter } from './outline';

describe('stripFrontmatter', () => {
	it('removes a leading YAML block', () => {
		const markdown = '---\ntags: [a, b]\n---\n\n# Title\nBody';
		expect(stripFrontmatter(markdown)).toBe('# Title\nBody');
	});

	it('leaves documents without frontmatter alone', () => {
		expect(stripFrontmatter('# Title\n---\nrule')).toBe('# Title\n---\nrule');
	});

	it('leaves an unterminated frontmatter fence alone', () => {
		expect(stripFrontmatter('---\ntags: x')).toBe('---\ntags: x');
	});
});

describe('extractOutline', () => {
	it('extracts headings with depth and order', () => {
		const markdown = '# One\n\ntext\n\n## Two\n\n### Three\n\n## Four';
		expect(extractOutline(markdown)).toEqual([
			{ depth: 1, text: 'One', index: 0 },
			{ depth: 2, text: 'Two', index: 1 },
			{ depth: 3, text: 'Three', index: 2 },
			{ depth: 2, text: 'Four', index: 3 }
		]);
	});

	it('ignores headings inside fenced code blocks', () => {
		const markdown = '# Real\n\n```sh\n# not a heading\n```\n\n## Also real';
		expect(extractOutline(markdown).map((entry) => entry.text)).toEqual(['Real', 'Also real']);
	});

	it('skips frontmatter and strips inline markup', () => {
		const markdown = '---\ntags: [x]\n---\n# **Bold** and [[Wiki Link]] and [md](http://x)';
		expect(extractOutline(markdown)).toEqual([
			{ depth: 1, text: 'Bold and Wiki Link and md', index: 0 }
		]);
	});

	it('requires a space after the hashes', () => {
		expect(extractOutline('#nospace\n#hashtag-style')).toEqual([]);
	});
});

describe('outlineFromDoc', () => {
	it('collects headings from ProseMirror JSON in document order', () => {
		const doc = {
			type: 'doc',
			content: [
				{ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Title' }] },
				{ type: 'paragraph', content: [{ type: 'text', text: 'Body' }] },
				{
					type: 'heading',
					attrs: { level: 2 },
					content: [
						{ type: 'text', text: 'Sub ' },
						{ type: 'text', text: 'section' }
					]
				}
			]
		};

		expect(outlineFromDoc(doc)).toEqual([
			{ depth: 1, text: 'Title', index: 0 },
			{ depth: 2, text: 'Sub section', index: 1 }
		]);
	});

	it('skips empty headings and tolerates non-documents', () => {
		expect(
			outlineFromDoc({ type: 'doc', content: [{ type: 'heading', attrs: { level: 3 } }] })
		).toEqual([]);
		expect(outlineFromDoc(null)).toEqual([]);
		expect(outlineFromDoc('nope')).toEqual([]);
	});

	it('finds headings nested inside containers', () => {
		const doc = {
			type: 'doc',
			content: [
				{
					type: 'blockquote',
					content: [
						{ type: 'heading', attrs: { level: 4 }, content: [{ type: 'text', text: 'Deep' }] }
					]
				}
			]
		};
		expect(outlineFromDoc(doc)).toEqual([{ depth: 4, text: 'Deep', index: 0 }]);
	});
});
