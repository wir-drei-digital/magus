/**
 * Pure helpers for the brain editor's drag-drop / paste upload handlers.
 *
 * Kept DOM-free so the branchy extraction logic is unit-testable in the node
 * test env; the ProseMirror handlers that call these live in
 * `brain-editor.svelte` (editor-runtime, exercised by e2e).
 */

/**
 * Files carried by a drop or paste event. Prefers `.files`, falling back to
 * `.items` — clipboard images (e.g. a pasted screenshot) often arrive as items
 * rather than files. Items that can't yield a File are dropped.
 */
export function filesFromTransfer(
	transfer: Pick<DataTransfer, 'files' | 'items'> | null | undefined
): File[] {
	if (!transfer) return [];

	const direct = Array.from(transfer.files ?? []);
	if (direct.length > 0) return direct;

	return Array.from(transfer.items ?? [])
		.filter((item) => item.kind === 'file')
		.map((item) => item.getAsFile())
		.filter((file): file is File => file != null);
}

export type BrainUploadNode = {
	type: 'imageBlock' | 'fileBlock';
	attrs: { fileId: string; caption: string };
};

/**
 * The brain block a freshly-uploaded file embeds as: images render inline
 * (`imageBlock`), everything else as a file chip (`fileBlock`). Both round-trip
 * to `magus://image|file/<id>` markdown via the server ProseMirror profile.
 */
export function brainNodeForFile(
	fileId: string,
	mimeType: string | null | undefined
): BrainUploadNode {
	const isImage = (mimeType ?? '').startsWith('image/');
	return { type: isImage ? 'imageBlock' : 'fileBlock', attrs: { fileId, caption: '' } };
}
