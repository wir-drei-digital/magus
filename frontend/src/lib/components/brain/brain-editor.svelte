<script lang="ts">
	import { onDestroy, untrack } from 'svelte';
	import { Editor } from '@tiptap/core';
	import StarterKit from '@tiptap/starter-kit';
	import Placeholder from '@tiptap/extension-placeholder';
	import Image from '@tiptap/extension-image';
	import Link from '@tiptap/extension-link';
	import Underline from '@tiptap/extension-underline';
	import Typography from '@tiptap/extension-typography';
	import Table from '@tiptap/extension-table';
	import TableRow from '@tiptap/extension-table-row';
	import TableCell from '@tiptap/extension-table-cell';
	import TableHeader from '@tiptap/extension-table-header';
	import Details from '@tiptap/extension-details';
	import DetailsSummary from '@tiptap/extension-details-summary';
	import DetailsContent from '@tiptap/extension-details-content';
	import TaskList from '@tiptap/extension-task-list';
	import TaskItem from '@tiptap/extension-task-item';
	import {
		createBubbleMenu,
		createSlashCommand,
		defaultCommands,
		DragHandle
	} from 'tiptap-phoenix';
	import {
		CalloutBlock,
		FileBlock,
		ImageBlock,
		MessageBlock,
		PageRef,
		SourceBlock,
		Tag
	} from '$lib/brain/blocks';
	import { createPageLink } from '$lib/brain/page-link';
	import { addBrainFileToMap } from '$lib/brain/file-map';
	import { brainNodeForFile, filesFromTransfer } from '$lib/brain/editor-uploads';
	import { getFile, uploadFile, type PageTreeNode } from '$lib/ash/api';

	let {
		content,
		pages = [],
		pageId,
		workspaceId = null,
		onChange,
		onPageRefClick,
		onBubbleAction,
		onUploadError
	}: {
		/** Server-converted ProseMirror document. */
		content: Record<string, unknown>;
		/** Wikilink suggestion source ([[ trigger). */
		pages?: PageTreeNode[];
		/**
		 * Owning page id — keys the per-page file map for drop/paste uploads.
		 * Omitted by non-page hosts (e.g. the draft companion), where drop/paste
		 * upload is disabled since there is no page-scoped file map to resolve.
		 */
		pageId?: string;
		/** Brain's workspace (null = personal); scopes drop/paste uploads. */
		workspaceId?: string | null;
		/** Fired on every document change (drives the autosave debounce). */
		onChange: () => void;
		onPageRefClick?: (title: string) => void;
		/**
		 * Bubble-menu "Ask"/"Refine" handler (classic ask/refine extras). When
		 * provided, the selection bubble gains those actions, which forward the
		 * selection to the host (e.g. the docked chat composer). event is
		 * 'ask' | 'refine'; payload has { text, node_context, instruction? }.
		 */
		onBubbleAction?: (event: string, payload: Record<string, unknown>) => void;
		/** Surfaced when a drop/paste upload fails (e.g. over the storage cap). */
		onUploadError?: (message: string) => void;
	} = $props();

	// Tiny inline icons for the bubble extras (innerHTML), mirroring classic.
	const ASK_ICON =
		'<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>';
	const REFINE_ICON =
		'<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/></svg>';

	/** Selection text + its enclosing block(s) as context (classic parity). */
	function selectionPayload(activeEditor: Editor): Record<string, unknown> {
		const { from, to } = activeEditor.state.selection;
		const fromPos = activeEditor.state.doc.resolve(from);
		const toPos = activeEditor.state.doc.resolve(to);
		const nodeContext = activeEditor.state.doc.textBetween(
			fromPos.start(fromPos.depth),
			toPos.end(toPos.depth),
			'\n'
		);
		return { text: activeEditor.state.doc.textBetween(from, to, ' '), node_context: nodeContext };
	}

	function bubbleExtras() {
		if (!onBubbleAction) return [];
		return [
			{ type: 'separator' },
			{
				type: 'button',
				label: 'Ask',
				icon: ASK_ICON,
				event: 'ask',
				getPayload: (ed: Editor) => selectionPayload(ed)
			},
			{
				type: 'input',
				label: 'Refine',
				icon: REFINE_ICON,
				placeholder: 'Improve this text…',
				event: 'refine',
				getPayload: (ed: Editor, instruction: string) => ({
					...selectionPayload(ed),
					instruction
				})
			}
		];
	}

	let host = $state<HTMLElement | null>(null);
	let editor: Editor | null = null;

	export function getJSON(): Record<string, unknown> | null {
		return editor ? (editor.getJSON() as Record<string, unknown>) : null;
	}

	/** Replaces the document (conflict reloads) without re-mounting. */
	export function setContent(next: Record<string, unknown>): void {
		editor?.commands.setContent(next, false);
	}

	export function focus(): void {
		editor?.commands.focus();
	}

	// Drop/paste upload: store the file (workspace- or personally-scoped to match
	// the brain), register it in the page's file map so the NodeView renders it
	// at once, then insert the matching brain block. Autosave then writes the
	// `magus://` reference into the body via the normal onChange path. Returns
	// the caret position just after the inserted node (or null if nothing was
	// inserted) so a multi-file drop can thread the position and keep order.
	async function uploadAndInsert(file: File, at: number | null): Promise<number | null> {
		if (!editor || !pageId) return null;
		const pid = pageId;

		const result = await uploadFile(file, workspaceId ? { workspaceId } : {});
		if (!result.success) {
			onUploadError?.(result.errors[0]?.message ?? 'Upload failed');
			return null;
		}

		const fileId = result.data.id;
		// The upload response omits filePath, so resolve the full record to build
		// the preview URL the way the rest of the file map does. If that read
		// fails the block still inserts and self-heals to the real preview on the
		// next load (the autosaved magus:// ref re-resolves via populateBrainFileMap).
		const full = await getFile(fileId);
		if (full.success) addBrainFileToMap(pid, full.data);
		else onUploadError?.('Uploaded — reload to see the preview.');
		if (!editor) return null;

		const node = brainNodeForFile(fileId, result.data.mimeType);
		// `at` was computed before the awaits; clamp in case the doc shrank
		// (local edits or a remote update replacing the document mid-upload).
		const size = editor.state.doc.content.size;
		const chain = editor.chain().focus();
		if (at == null) chain.insertContent(node).run();
		else chain.insertContentAt(Math.min(Math.max(at, 0), size), node).run();
		return editor.state.selection.from;
	}

	// Sequence uploads so several dropped/pasted files keep their source order —
	// firing them concurrently would insert whichever upload resolved first.
	async function insertFilesInOrder(files: File[], at: number | null): Promise<void> {
		let pos = at;
		for (const file of files) {
			const next = await uploadAndInsert(file, pos);
			if (next != null) pos = next;
		}
	}

	// Build the editor exactly once, when the host mounts. Wrapping creation in
	// untrack keeps later prop changes (notably the async-loaded `pages` wikilink
	// list, and content refreshed after a save) from tearing down and recreating
	// the editor mid-edit, which would drop the caret. Content updates flow
	// through setContent(); the wikilink list stays live via the getter passed to
	// createPageLink.
	$effect(() => {
		if (!host) return;
		const element = host;

		editor = untrack(() => new Editor({
			element,
			content,
			editorProps: {
				attributes: {
					// tiptap-phoenix's stylesheet targets .tiptap-editor-content.
					class: 'tiptap-editor-content focus:outline-none'
				},
				handleDrop: (view, event, _slice, moved) => {
					// Internal node drags (DragHandle reorder) and page-less hosts
					// (draft companion) keep ProseMirror's default handling.
					if (moved || !pageId) return false;
					const files = filesFromTransfer(event.dataTransfer);
					if (files.length === 0) return false;
					event.preventDefault();
					const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
					void insertFilesInOrder(files, coords ? coords.pos : null);
					return true;
				},
				handlePaste: (_view, event) => {
					if (!pageId) return false;
					const files = filesFromTransfer(event.clipboardData);
					if (files.length === 0) return false;
					event.preventDefault();
					void insertFilesInOrder(files, null);
					return true;
				}
			},
			extensions: [
				StarterKit,
				Placeholder.configure({ placeholder: "Write, or type '/' for blocks…" }),
				Image.configure({ inline: false, allowBase64: false }),
				Link.configure({ openOnClick: false, autolink: true }),
				Underline,
				Typography,
				Table.configure({ resizable: false }),
				TableRow,
				TableCell,
				TableHeader,
				Details,
				DetailsSummary,
				DetailsContent,
				TaskList,
				TaskItem.configure({ nested: true }),
				createSlashCommand({ commands: defaultCommands }),
				// Formatting bubble on selection (classic parity). The ask/refine
				// extras forward the selection to the host via onBubbleAction.
				createBubbleMenu({
					extras: bubbleExtras(),
					pushEvent: onBubbleAction
						? (event: string, payload: Record<string, unknown>) => onBubbleAction(event, payload)
						: null
				}),
				DragHandle,
				// Getter (not a snapshot) so the wikilink list stays live as `pages`
				// loads, without re-creating the editor. createPageLink is a vendored
				// @ts-nocheck module whose JSDoc only advertises the array form, so the
				// getter is cast through to satisfy the type-checker.
				createPageLink(
					(() =>
						pages.map((page) => ({
							id: page.id,
							title: page.title ?? 'Untitled'
						}))) as unknown as { id: string; title: string }[],
					{ onPageRefClick }
				),
				SourceBlock,
				FileBlock,
				MessageBlock,
				CalloutBlock,
				ImageBlock,
				PageRef,
				Tag
			],
			onUpdate: () => onChange()
		}));

		return () => {
			editor?.destroy();
			editor = null;
		};
	});

	onDestroy(() => {
		editor?.destroy();
		editor = null;
	});
</script>

<div bind:this={host} class="brain-editor min-h-full" data-testid="brain-editor"></div>

<style>
	/* The editor fills the page column like classic's .tiptap surface. */
	.brain-editor :global(.tiptap) {
		min-height: 60vh;
		outline: none;
	}
</style>
