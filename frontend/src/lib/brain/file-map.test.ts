import { describe, expect, it } from 'vitest';
import type { FileEntry, RpcError, RpcResult } from '$lib/ash/api';
import { extractBrainFileIds, resolveBrainFileMap, toBrainFileSummary } from './file-map';

const file = (overrides: Partial<FileEntry> = {}): FileEntry => ({
	id: '11111111-1111-1111-1111-111111111111',
	name: 'spec.pdf',
	type: 'document',
	source: 'user',
	mimeType: 'application/pdf',
	fileSize: 2048,
	filePath: 'ab/cd/spec.pdf',
	isTemplate: false,
	status: 'ready',
	updatedAt: '2026-06-18T00:00:00Z',
	folderId: null,
	workspaceId: null,
	userId: 'u-1',
	isSharedToWorkspace: false,
	...overrides
});

const ok = (data: FileEntry): RpcResult<FileEntry> => ({ success: true, data });
const fail = (message: string): RpcResult<FileEntry> => ({
	success: false,
	errors: [
		{
			type: 'not_found',
			message,
			shortMessage: message,
			vars: {},
			fields: [],
			path: []
		} as RpcError
	]
});

const UUID = '11111111-1111-1111-1111-111111111111';
const UUID2 = '22222222-2222-2222-2222-222222222222';

describe('extractBrainFileIds', () => {
	it('returns [] for nil/empty bodies', () => {
		expect(extractBrainFileIds(null)).toEqual([]);
		expect(extractBrainFileIds(undefined)).toEqual([]);
		expect(extractBrainFileIds('')).toEqual([]);
		expect(extractBrainFileIds('no attachments here')).toEqual([]);
	});

	it('extracts a file link id', () => {
		expect(extractBrainFileIds(`See [📎 spec](magus://file/${UUID})`)).toEqual([UUID]);
	});

	it('extracts both file and image link ids', () => {
		const body = `[📎 spec](magus://file/${UUID}) and ![](magus://image/${UUID2})`;
		expect(extractBrainFileIds(body).sort()).toEqual([UUID, UUID2].sort());
	});

	it('dedupes a repeated id', () => {
		const body = `magus://file/${UUID} again magus://image/${UUID}`;
		expect(extractBrainFileIds(body)).toEqual([UUID]);
	});

	it('matches the 26-char ULID form too', () => {
		const ulid = '01arz3ndektsv4rrffq69g5fav';
		expect(extractBrainFileIds(`magus://file/${ulid}`)).toEqual([ulid]);
	});

	it('ignores wikilinks, tags, and plain urls', () => {
		const body = `[[Some Page]] #tag https://example.com/file/${UUID}`;
		expect(extractBrainFileIds(body)).toEqual([]);
	});
});

describe('toBrainFileSummary', () => {
	it('maps a FileEntry to the snake_case block shape with a preview url', () => {
		expect(toBrainFileSummary(file())).toEqual({
			id: UUID,
			name: 'spec.pdf',
			mime_type: 'application/pdf',
			type: 'document',
			file_size: 2048,
			status: 'ready',
			url: '/uploads/files/ab/cd/spec.pdf'
		});
	});
});

describe('resolveBrainFileMap', () => {
	it('returns an empty map when there are no file ids', async () => {
		const map = await resolveBrainFileMap('plain text', () => {
			throw new Error('should not fetch');
		});
		expect(map).toEqual({});
	});

	it('resolves referenced files into a map keyed by id', async () => {
		const body = `[📎](magus://file/${UUID}) ![](magus://image/${UUID2})`;
		const map = await resolveBrainFileMap(body, async (id) =>
			ok(file({ id, name: `${id}.bin`, type: id === UUID2 ? 'image' : 'document' }))
		);
		expect(Object.keys(map).sort()).toEqual([UUID, UUID2].sort());
		expect(map[UUID2].type).toBe('image');
		expect(map[UUID].name).toBe(`${UUID}.bin`);
	});

	it('skips ids whose fetch fails (denied / missing) without throwing', async () => {
		const body = `magus://file/${UUID} magus://file/${UUID2}`;
		const map = await resolveBrainFileMap(body, async (id) =>
			id === UUID ? ok(file({ id })) : fail('not found')
		);
		expect(Object.keys(map)).toEqual([UUID]);
	});
});
