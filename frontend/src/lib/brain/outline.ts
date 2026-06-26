/**
 * Markdown heading outline for the brain-page companion's Outline tab.
 * Pure (unit-tested in node); rendering scrolls by heading order, so each
 * entry's `index` is its position among all headings in the document.
 */

export type OutlineEntry = {
	/** 1-6 (# count). */
	depth: number;
	/** Heading text with light inline markup stripped. */
	text: string;
	/** Position among all headings, used to scroll the nth rendered heading. */
	index: number;
};

const FENCE = /^(```|~~~)/;
const HEADING = /^(#{1,6})\s+(.+?)\s*#*\s*$/;

/** Removes a leading YAML frontmatter block (page metadata, not content). */
export function stripFrontmatter(markdown: string): string {
	if (!markdown.startsWith('---')) return markdown;

	const lines = markdown.split('\n');
	if (lines[0]?.trim() !== '---') return markdown;

	const end = lines.findIndex((line, i) => i > 0 && line.trim() === '---');
	return end > 0
		? lines
				.slice(end + 1)
				.join('\n')
				.replace(/^\n+/, '')
		: markdown;
}

/** Strips a light set of inline markers so the outline reads as plain text. */
function stripInline(text: string): string {
	return text
		.replace(/\[\[([^\]]+)\]\]/g, '$1')
		.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
		.replace(/[*_~`]/g, '')
		.trim();
}

export function extractOutline(markdown: string): OutlineEntry[] {
	const lines = stripFrontmatter(markdown).split('\n');

	const entries: OutlineEntry[] = [];
	let inFence = false;
	let index = 0;

	for (const line of lines) {
		if (FENCE.test(line.trim())) {
			inFence = !inFence;
			continue;
		}
		if (inFence) continue;

		const match = HEADING.exec(line);
		if (!match) continue;

		entries.push({ depth: match[1].length, text: stripInline(match[2]), index });
		index += 1;
	}

	return entries;
}

// ─── ProseMirror outline (brain page bottom bar) ─────────────────────────────

type PmNode = {
	type?: string;
	attrs?: { level?: number };
	text?: string;
	content?: PmNode[];
};

function nodeText(node: PmNode): string {
	if (typeof node.text === 'string') return node.text;
	return (node.content ?? []).map(nodeText).join('');
}

/**
 * Outline from the live editor document (unlike `extractOutline`, which
 * parses stored markdown): walks ProseMirror JSON for heading nodes, so
 * unsaved edits are reflected too. Entry order matches rendered heading
 * order, as with `OutlineEntry.index`.
 */
export function outlineFromDoc(doc: unknown): OutlineEntry[] {
	const entries: OutlineEntry[] = [];

	const walk = (node: PmNode) => {
		if (node.type === 'heading') {
			const text = nodeText(node).trim();
			if (text !== '') {
				entries.push({ depth: node.attrs?.level ?? 1, text, index: entries.length });
			}
		}
		for (const child of node.content ?? []) walk(child);
	};

	if (doc && typeof doc === 'object') walk(doc as PmNode);
	return entries;
}
