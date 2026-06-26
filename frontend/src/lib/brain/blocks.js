// @ts-nocheck — vendored port of the classic editor extensions; kept
// byte-close to assets/js/extensions/* for easy diffing.
/**
 * Custom TipTap nodes for brain pages — ported from the classic editor
 * (assets/js/extensions/brain_blocks.js) with DaisyUI utility classes mapped
 * to the workbench/shadcn tokens. Keep the node names and attribute shapes
 * EXACTLY in sync with Magus.Brain.ProseMirrorProfile: the server converts
 * these nodes to/from markdown.
 */
import { Node, mergeAttributes } from '@tiptap/core';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function escapeHtml(str) {
	if (!str) return '';
	return str
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

/**
 * Render a minimal subset of inline markdown to HTML.
 *
 * Safe by construction: HTML is escaped first, then markdown patterns
 * are applied. Captured groups never contain `<`/`>`/`&`/`"` (they were
 * already escaped), so wrapping them in literal tags can't inject HTML.
 */
function renderInlineMarkdown(str) {
	if (!str) return '';

	let s = escapeHtml(str);
	s = s.replace(/`([^`\n]+?)`/g, '<code>$1</code>');
	s = s.replace(/\*\*([^*\n]+?)\*\*/g, '<strong>$1</strong>');
	s = s.replace(/__([^_\n]+?)__/g, '<strong>$1</strong>');
	s = s.replace(/(^|[^*<])\*([^*\n]+?)\*(?!\*)/g, '$1<em>$2</em>');
	s = s.replace(/(^|[^_>])_([^_\n]+?)_(?!_)/g, '$1<em>$2</em>');
	s = s.replace(
		/\[([^\]\n]+?)\]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/g,
		'<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
	);
	s = s.replace(/\s+\|\s+/g, '<br>');
	s = s.replace(/\n/g, '<br>');
	return s;
}

function hostname(url) {
	try {
		return new URL(url).hostname;
	} catch {
		return url;
	}
}

function sourceIcon(type) {
	switch (type) {
		case 'video':
			return '\u{1F3AC}';
		case 'pdf':
			return '\u{1F4C4}';
		case 'paper':
			return '\u{1F4D1}';
		default:
			return '\u{1F517}';
	}
}

function calloutConfig(variant) {
	switch (variant) {
		case 'insight':
			return {
				icon: '\u{1F4A1}',
				label: 'Insight',
				cls: 'bg-success/10 border-success/30'
			};
		case 'warning':
			return {
				icon: '⚠️',
				label: 'Warning',
				cls: 'bg-warning/10 border-warning/30'
			};
		case 'question':
			return {
				icon: '❓',
				label: 'Question',
				cls: 'bg-info/10 border-info/30'
			};
		default:
			return {
				icon: 'ℹ️',
				label: 'Note',
				cls: 'bg-secondary/50 border-input/50'
			};
	}
}

// ---------------------------------------------------------------------------
// Source Block (fenced ```source ... ```)
// ---------------------------------------------------------------------------

export const SourceBlock = Node.create({
	name: 'sourceBlock',
	group: 'block',
	atom: true,
	draggable: true,

	addAttributes() {
		return {
			url: { default: '' },
			title: { default: '' },
			sourceType: { default: 'web' },
			description: { default: '' },
			// `ingested` / `ingestionError` are server-side derived. They're
			// not in the markdown body; the LiveView pushes them in via a
			// separate refresh event when state changes.
			ingested: { default: false },
			ingestionError: { default: null }
		};
	},

	parseHTML() {
		return [{ tag: 'div[data-type="sourceBlock"]' }];
	},

	renderHTML({ HTMLAttributes }) {
		return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'sourceBlock' })];
	},

	addNodeView() {
		return ({ node }) => {
			const dom = document.createElement('div');
			dom.className = 'bg-secondary/50 border border-input/50 rounded-lg p-3 my-2 not-prose';
			dom.setAttribute('data-type', 'sourceBlock');
			dom.contentEditable = 'false';

			const a = node.attrs;
			const title = escapeHtml(a.title || 'Untitled');
			const host = escapeHtml(hostname(a.url));
			const desc = a.description
				? `<p class="text-xs text-muted-foreground mt-1">${escapeHtml(a.description)}</p>`
				: '';

			let badges = '';
			if (a.ingested) {
				badges += `<span class="text-xs bg-muted px-2 py-0.5 rounded text-primary">content extracted</span>`;
			}
			if (a.ingestionError) {
				badges += `<span class="text-xs bg-destructive/10 px-2 py-0.5 rounded text-destructive">extraction failed</span>`;
			}
			const link = a.url
				? `<a href="${escapeHtml(a.url)}" target="_blank" rel="noopener" class="text-xs text-muted-foreground/80 hover:text-primary ml-auto">open →</a>`
				: '';

			dom.innerHTML = `
        <div class="flex items-center gap-2 mb-1">
          <span class="text-sm">${sourceIcon(a.sourceType)}</span>
          <span class="text-sm font-medium text-foreground truncate">${title}</span>
          <span class="text-xs text-muted-foreground/80 ml-auto truncate max-w-[120px]">${host}</span>
        </div>
        ${desc}
        <div class="flex items-center gap-2 mt-2">
          ${badges}${link}
        </div>
      `;

			return { dom };
		};
	}
});

// ---------------------------------------------------------------------------
// File Block ([📎 caption](magus://file/<id>))
// ---------------------------------------------------------------------------

function fileIcon(file) {
	if (file.type === 'image') return '\u{1F5BC}';
	if (file.type === 'video') return '\u{1F3AC}';
	if (file.type === 'text') return '\u{1F4DD}';
	if (file.type === 'email') return '✉️';
	if ((file.mime_type || '') === 'application/pdf') return '\u{1F4C4}';
	if (file.type === 'document') return '\u{1F4C3}';
	return '\u{1F4CE}';
}

function formatBytes(bytes) {
	if (!bytes) return '';
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function fileImageUrl(file) {
	return file && typeof file.url === 'string' ? file.url : '';
}

export const FileBlock = Node.create({
	name: 'fileBlock',
	group: 'block',
	atom: true,
	draggable: true,

	addAttributes() {
		return {
			fileId: { default: null },
			caption: { default: '' }
		};
	},

	parseHTML() {
		return [{ tag: 'div[data-type="fileBlock"]' }];
	},

	renderHTML({ HTMLAttributes }) {
		return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'fileBlock' })];
	},

	addNodeView() {
		return ({ node }) => {
			const dom = document.createElement('div');
			dom.contentEditable = 'false';
			dom.setAttribute('data-type', 'fileBlock');
			dom.setAttribute('data-file-id', node.attrs.fileId || '');

			const editorRoot = dom.closest('[data-page-id]');
			const pageId = editorRoot?.getAttribute('data-page-id');
			const fileMaps = window.__brainFileMaps || {};
			const fileMap = (pageId && fileMaps[pageId]) || {};
			const file = node.attrs.fileId ? fileMap[node.attrs.fileId] : null;

			const dispatchOpen = () => {
				const tabRole = dom.closest('[data-brain-pane]')?.getAttribute('data-role') || 'primary';
				window.dispatchEvent(
					new CustomEvent('phx:open-brain-file', {
						detail: {
							fileId: node.attrs.fileId,
							tabRole,
							pageId
						}
					})
				);
			};

			if (!file) {
				dom.className =
					'bg-secondary/50 border border-warning/30 rounded-lg p-3 my-2 flex items-center gap-3 not-prose';
				dom.innerHTML = `
          <div class="bg-warning/10 rounded-md w-9 h-9 flex items-center justify-center text-lg">⚠️</div>
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium text-foreground truncate">File no longer available</div>
            ${node.attrs.caption ? `<div class="text-xs text-muted-foreground/80 truncate">${escapeHtml(node.attrs.caption)}</div>` : ''}
          </div>
        `;
				return { dom };
			}

			const isImage = file.type === 'image' || (file.mime_type || '').startsWith('image/');

			if (isImage) {
				dom.className = 'my-2 not-prose relative group';
				dom.innerHTML = `
          <img
            src="${escapeHtml(fileImageUrl(file))}"
            alt="${escapeHtml(file.name || '')}"
            loading="lazy"
            class="rounded max-h-[240px] w-auto"
          />
          ${node.attrs.caption ? `<div class="text-xs text-muted-foreground mt-1">${escapeHtml(node.attrs.caption)}</div>` : ''}
          <button
            type="button"
            data-open-full
            class="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition bg-background/80 rounded p-1 text-xs"
            title="Open full view"
          >↗</button>
        `;
				dom.querySelector('[data-open-full]')?.addEventListener('click', (e) => {
					e.stopPropagation();
					dispatchOpen();
				});
			} else {
				dom.className =
					'bg-secondary/50 border border-input/50 rounded-lg p-3 my-2 flex items-center gap-3 not-prose cursor-pointer hover:bg-secondary/70';
				dom.innerHTML = `
          <div class="bg-muted rounded-md w-9 h-9 flex items-center justify-center text-lg">${fileIcon(file)}</div>
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium text-foreground truncate">${escapeHtml(file.name || '')}</div>
            <div class="text-xs text-muted-foreground/80">${escapeHtml(file.mime_type || '')} · ${formatBytes(file.file_size)}</div>
            ${node.attrs.caption ? `<div class="text-xs text-muted-foreground truncate">${escapeHtml(node.attrs.caption)}</div>` : ''}
          </div>
          <div class="text-muted-foreground/80 text-xs">open ↗</div>
        `;
				dom.addEventListener('click', () => dispatchOpen());
			}

			return { dom };
		};
	}
});

// ---------------------------------------------------------------------------
// Message Block (inline atom: [[msg:<id>|preview]])
// ---------------------------------------------------------------------------

export const MessageBlock = Node.create({
	name: 'messageBlock',
	group: 'block',
	atom: true,
	draggable: true,

	addAttributes() {
		return {
			messageId: { default: null },
			conversationId: { default: null },
			previewText: { default: '' }
		};
	},

	parseHTML() {
		return [{ tag: 'div[data-type="messageBlock"]' }];
	},

	renderHTML({ HTMLAttributes }) {
		return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'messageBlock' })];
	},

	addNodeView() {
		return ({ node }) => {
			const dom = document.createElement('div');
			dom.className =
				'bg-secondary/50 border-l-[3px] border-l-primary rounded-r-lg p-3 my-2 not-prose';
			dom.setAttribute('data-type', 'messageBlock');
			dom.contentEditable = 'false';

			const preview = escapeHtml(node.attrs.previewText || '...');

			dom.innerHTML = `
        <div class="flex items-center gap-2 mb-1">
          <span class="text-xs bg-primary text-primary-foreground px-1.5 py-0.5 rounded font-medium">from conversation</span>
        </div>
        <p class="text-sm text-foreground leading-relaxed">${preview}</p>
      `;

			return { dom };
		};
	}
});

// ---------------------------------------------------------------------------
// Callout Block (fenced ```callout ... ```)
// ---------------------------------------------------------------------------

export const CalloutBlock = Node.create({
	name: 'calloutBlock',
	group: 'block',
	atom: true,
	draggable: true,

	addAttributes() {
		return {
			variant: { default: 'note' },
			text: { default: '' },
			contributorType: { default: null }
		};
	},

	parseHTML() {
		return [{ tag: 'div[data-type="calloutBlock"]' }];
	},

	renderHTML({ HTMLAttributes }) {
		return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'calloutBlock' })];
	},

	addNodeView() {
		return ({ node }) => {
			const a = node.attrs;
			const cfg = calloutConfig(a.variant);

			const dom = document.createElement('div');
			dom.className = `rounded-lg p-3 my-2 not-prose border ${cfg.cls}`;
			dom.setAttribute('data-type', 'calloutBlock');
			dom.contentEditable = 'false';

			const agentBadge =
				a.contributorType === 'custom_agent'
					? `<span class="text-xs text-muted-foreground/80 ml-auto">by agent</span>`
					: '';

			dom.innerHTML = `
        <div class="flex items-center gap-2 mb-1">
          <span class="text-sm">${cfg.icon}</span>
          <span class="text-xs font-medium">${cfg.label}</span>
          ${agentBadge}
        </div>
        <p class="text-sm text-foreground leading-relaxed">${renderInlineMarkdown(a.text)}</p>
      `;

			return { dom };
		};
	}
});

// ---------------------------------------------------------------------------
// Image Block (![caption](magus://image/<id>))
// ---------------------------------------------------------------------------

export const ImageBlock = Node.create({
	name: 'imageBlock',
	group: 'block',
	atom: true,
	draggable: true,

	addAttributes() {
		return {
			fileId: { default: null },
			caption: { default: '' }
		};
	},

	parseHTML() {
		return [{ tag: 'div[data-type="imageBlock"]' }];
	},

	renderHTML({ HTMLAttributes }) {
		return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'imageBlock' })];
	},

	addNodeView() {
		return ({ node }) => {
			const dom = document.createElement('div');
			dom.className = 'my-2 not-prose';
			dom.setAttribute('data-type', 'imageBlock');
			dom.contentEditable = 'false';

			// Resolve the actual image URL through the per-page file map, same
			// pattern as `fileBlock`. When the workspace file is unavailable
			// we fall back to a placeholder so the editor still renders.
			const editorRoot = dom.closest('[data-page-id]');
			const pageId = editorRoot?.getAttribute('data-page-id');
			const fileMap = (pageId && (window.__brainFileMaps || {})[pageId]) || {};
			const file = node.attrs.fileId ? fileMap[node.attrs.fileId] : null;
			const url = file ? fileImageUrl(file) : '';

			const caption = node.attrs.caption
				? `<p class="text-xs text-muted-foreground mt-1 px-1">${escapeHtml(node.attrs.caption)}</p>`
				: '';

			if (url) {
				dom.innerHTML = `
          <div class="rounded-lg overflow-hidden border border-input/50">
            <img src="${escapeHtml(url)}" alt="${escapeHtml(node.attrs.caption || '')}" loading="lazy" class="w-full h-auto" />
          </div>
          ${caption}
        `;
			} else {
				dom.innerHTML = `
          <div class="rounded-lg overflow-hidden border border-input/50">
            <div class="bg-secondary/50 p-8 flex items-center justify-center text-muted-foreground/60">
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/>
                <circle cx="9" cy="9" r="2"/>
                <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>
              </svg>
            </div>
          </div>
          ${caption}
        `;
			}

			return { dom };
		};
	}
});

// ---------------------------------------------------------------------------
// Inline atoms: PageRef ([[Title]]) and Tag (#tag-name)
//
// These exist so the editor can render a clickable chip / styled fragment
// for shapes that don't have native CommonMark equivalents. They round-trip
// back to literal `[[Title]]` and `#tag` strings via the server-side
// `Magus.Brain.ProseMirrorProfile`.
// ---------------------------------------------------------------------------

export const PageRef = Node.create({
	name: 'pageRef',
	group: 'inline',
	inline: true,
	atom: true,
	selectable: true,

	addAttributes() {
		return { title: { default: '' } };
	},

	parseHTML() {
		return [{ tag: 'a[data-type="pageRef"]' }];
	},

	renderHTML({ HTMLAttributes, node }) {
		return [
			'a',
			mergeAttributes(HTMLAttributes, {
				'data-type': 'pageRef',
				class: 'brain-page-ref',
				href: '#'
			}),
			`[[${node.attrs.title || ''}]]`
		];
	},

	addNodeView() {
		return ({ node, HTMLAttributes }) => {
			const dom = document.createElement('a');
			dom.className = 'brain-page-ref';
			dom.setAttribute('data-type', 'pageRef');
			dom.setAttribute('href', '#');
			dom.textContent = `[[${node.attrs.title || ''}]]`;
			// Click handling lives at the editor host level; firing a window
			// event keeps NodeView wiring decoupled from the LiveView hook.
			dom.addEventListener('mousedown', (e) => {
				e.preventDefault();
				e.stopPropagation();
				window.dispatchEvent(
					new CustomEvent('phx:brain-page-ref-click', {
						detail: { title: node.attrs.title }
					})
				);
			});
			return { dom };
		};
	}
});

export const Tag = Node.create({
	name: 'tag',
	group: 'inline',
	inline: true,
	atom: true,
	selectable: true,

	addAttributes() {
		return { name: { default: '' } };
	},

	parseHTML() {
		return [{ tag: 'span[data-type="tag"]' }];
	},

	renderHTML({ HTMLAttributes, node }) {
		return [
			'span',
			mergeAttributes(HTMLAttributes, {
				'data-type': 'tag',
				class: 'brain-tag'
			}),
			`#${node.attrs.name || ''}`
		];
	},

	addNodeView() {
		return ({ node }) => {
			const dom = document.createElement('span');
			dom.className = 'brain-tag';
			dom.setAttribute('data-type', 'tag');
			dom.textContent = `#${node.attrs.name || ''}`;
			return { dom };
		};
	}
});
