import { describe, expect, it } from 'vitest';
import { brainNodeForFile, filesFromTransfer } from './editor-uploads';

// Minimal stand-ins — the real DataTransfer/File aren't available in the node
// test env, and the helpers only touch the fields below.
const asFile = (name: string, type: string): File => ({ name, type }) as unknown as File;

const item = (file: File | null, kind: 'file' | 'string' = 'file') =>
	({ kind, getAsFile: () => file }) as unknown as DataTransferItem;

const transfer = (parts: {
	files?: File[];
	items?: DataTransferItem[];
}): Pick<DataTransfer, 'files' | 'items'> =>
	({
		files: (parts.files ?? []) as unknown as FileList,
		items: (parts.items ?? []) as unknown as DataTransferItemList
	}) as Pick<DataTransfer, 'files' | 'items'>;

describe('filesFromTransfer', () => {
	it('returns [] for a null/undefined transfer', () => {
		expect(filesFromTransfer(null)).toEqual([]);
		expect(filesFromTransfer(undefined)).toEqual([]);
	});

	it('returns [] when there are no files or file items', () => {
		expect(filesFromTransfer(transfer({}))).toEqual([]);
		expect(filesFromTransfer(transfer({ items: [item(null, 'string')] }))).toEqual([]);
	});

	it('prefers .files when present', () => {
		const a = asFile('a.png', 'image/png');
		expect(filesFromTransfer(transfer({ files: [a] }))).toEqual([a]);
	});

	it('falls back to .items (pasted screenshots arrive as items)', () => {
		const a = asFile('paste.png', 'image/png');
		const result = filesFromTransfer(transfer({ items: [item(a)] }));
		expect(result).toEqual([a]);
	});

	it('drops string items and items that yield no file', () => {
		const a = asFile('paste.png', 'image/png');
		const result = filesFromTransfer(
			transfer({ items: [item(null, 'string'), item(null), item(a)] })
		);
		expect(result).toEqual([a]);
	});
});

describe('brainNodeForFile', () => {
	it('embeds an image mime as an imageBlock', () => {
		expect(brainNodeForFile('f-1', 'image/png')).toEqual({
			type: 'imageBlock',
			attrs: { fileId: 'f-1', caption: '' }
		});
	});

	it('embeds a non-image mime as a fileBlock', () => {
		expect(brainNodeForFile('f-2', 'application/pdf').type).toBe('fileBlock');
	});

	it('treats a null/missing mime as a fileBlock', () => {
		expect(brainNodeForFile('f-3', null).type).toBe('fileBlock');
		expect(brainNodeForFile('f-4', undefined).type).toBe('fileBlock');
	});
});
