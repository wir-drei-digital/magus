/**
 * Per-page file-metadata map for the brain editor's File/Image blocks.
 *
 * The page body only stores file references by id (`magus://file/<id>` /
 * `magus://image/<id>`); the `FileBlock`/`ImageBlock` NodeViews in `blocks.js`
 * render from `window.__brainFileMaps[pageId][fileId]`, which must hold the
 * file's name/type/size/url. The classic LiveView populated that global from a
 * server-pushed summary map; the SPA resolves the referenced files through the
 * policy-gated `getFile` RPC and publishes the same shape here.
 *
 * Mirrors the server canonical `Magus.Brain.BodyParser.file_ids/1` regex and
 * `Magus.Brain.BlockSerializer.file_summary_for_js/1` field shape.
 */
import { fileUrl, getFile, type FileEntry, type RpcResult } from '$lib/ash/api';

/** The summary shape the blocks read (snake_case, matching the classic JS map). */
export type BrainFileSummary = {
	id: string;
	name: string;
	mime_type: string;
	type: string;
	file_size: number;
	status: string;
	url: string;
};

declare global {
	interface Window {
		/** Per-page file metadata read by the brain editor File/Image NodeViews. */
		__brainFileMaps?: Record<string, Record<string, BrainFileSummary>>;
	}
}

// Same id grammar as Magus.Brain.BodyParser.file_ids/1: a hyphenated UUID or a
// 26-char ULID, after a `magus://file/` or `magus://image/` scheme.
const FILE_ID_RE = /magus:\/\/(?:file|image)\/([0-9a-f-]{36}|[0-9a-z]{26})/gi;

/** Unique file ids referenced by a page body, in first-seen order. */
export function extractBrainFileIds(body: string | null | undefined): string[] {
	if (!body) return [];
	const ids = new Set<string>();
	for (const match of body.matchAll(FILE_ID_RE)) ids.add(match[1]);
	return [...ids];
}

export function toBrainFileSummary(file: FileEntry): BrainFileSummary {
	return {
		id: file.id,
		name: file.name,
		mime_type: file.mimeType,
		type: file.type,
		file_size: file.fileSize,
		status: file.status,
		url: fileUrl(file)
	};
}

type FetchFile = (id: string) => Promise<RpcResult<FileEntry>>;

/**
 * Resolve every file referenced by `body` into a `{ id => summary }` map.
 * Files the actor cannot read (or that no longer exist) are silently dropped,
 * so their blocks fall back to the "no longer available" placeholder, matching
 * the classic behavior. `fetchFile` is injectable for testing.
 */
export async function resolveBrainFileMap(
	body: string | null | undefined,
	fetchFile: FetchFile = getFile
): Promise<Record<string, BrainFileSummary>> {
	const ids = extractBrainFileIds(body);
	if (ids.length === 0) return {};

	const map: Record<string, BrainFileSummary> = {};
	await Promise.all(
		ids.map(async (id) => {
			const result = await fetchFile(id);
			if (result.success) map[id] = toBrainFileSummary(result.data);
		})
	);
	return map;
}

function globalFileMaps(): Record<string, Record<string, BrainFileSummary>> {
	window.__brainFileMaps = window.__brainFileMaps || {};
	return window.__brainFileMaps;
}

/**
 * Resolve a page body's files and publish them to the global map the editor
 * NodeViews read. Resolves even on an empty body (publishes `{}`), so a stale
 * entry from a previous body never lingers.
 */
export async function populateBrainFileMap(
	pageId: string,
	body: string | null | undefined
): Promise<void> {
	const map = await resolveBrainFileMap(body);
	globalFileMaps()[pageId] = map;
}

/**
 * Merge a single freshly-uploaded file into a page's map so the editor's
 * Image/File NodeView resolves it immediately — before the autosave writes the
 * `magus://` reference into the body (after which a reload re-resolves it the
 * normal way through `populateBrainFileMap`).
 */
export function addBrainFileToMap(pageId: string, file: FileEntry): void {
	const maps = globalFileMaps();
	const pageMap = (maps[pageId] = maps[pageId] ?? {});
	pageMap[file.id] = toBrainFileSummary(file);
}

/** Drop a page's entry when its editor unmounts (avoids an unbounded global). */
export function clearBrainFileMap(pageId: string): void {
	if (typeof window !== 'undefined' && window.__brainFileMaps) {
		delete window.__brainFileMaps[pageId];
	}
}
