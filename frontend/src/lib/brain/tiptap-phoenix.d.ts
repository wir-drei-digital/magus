declare module 'tiptap-phoenix' {
	import type { AnyExtension } from '@tiptap/core';

	export const DragHandle: AnyExtension;
	export const defaultCommands: unknown[];
	export function createSlashCommand(options?: { commands?: unknown[] }): AnyExtension;
	export function createBubbleMenu(options?: unknown): AnyExtension;
}

declare module '$lib/brain/blocks' {
	import type { AnyExtension } from '@tiptap/core';

	export const SourceBlock: AnyExtension;
	export const FileBlock: AnyExtension;
	export const MessageBlock: AnyExtension;
	export const CalloutBlock: AnyExtension;
	export const ImageBlock: AnyExtension;
	export const PageRef: AnyExtension;
	export const Tag: AnyExtension;
}

declare module '$lib/brain/page-link' {
	import type { AnyExtension } from '@tiptap/core';

	export function createPageLink(
		pages: { id: string; title: string }[],
		options?: { onPageRefClick?: (title: string) => void }
	): AnyExtension;
}
