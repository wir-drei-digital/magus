import type { FileEntry } from '$lib/ash/api';

/**
 * Browser filters over the loaded scope, mirroring the server-side
 * `ApplyBrowserFilters` semantics (classic honors the same buckets via
 * ?type/modified/source URL params).
 */

export type TypeFilter = 'any' | 'image' | 'video' | 'pdf' | 'document' | 'text' | 'email';
export type ModifiedFilter = 'any' | 'today' | 'this_week' | 'this_month' | 'this_year' | 'older';
export type SourceFilter = 'any' | 'uploaded' | 'agent' | 'synced';

export function matchesType(
	file: Pick<FileEntry, 'type' | 'mimeType'>,
	filter: TypeFilter
): boolean {
	switch (filter) {
		case 'any':
			return true;
		case 'pdf':
			return file.mimeType === 'application/pdf';
		case 'document':
			return file.type === 'document' && file.mimeType !== 'application/pdf';
		default:
			return file.type === filter;
	}
}

const DAY_MS = 24 * 60 * 60 * 1000;

const SINCE_DAYS: Partial<Record<ModifiedFilter, number>> = {
	today: 1,
	this_week: 7,
	this_month: 30,
	this_year: 365
};

export function matchesModified(
	updatedAt: string,
	filter: ModifiedFilter,
	now: Date = new Date()
): boolean {
	if (filter === 'any') return true;
	const age = now.getTime() - new Date(updatedAt).getTime();
	if (filter === 'older') return age >= 365 * DAY_MS;
	const days = SINCE_DAYS[filter];
	return days !== undefined ? age < days * DAY_MS : true;
}

const SOURCE_MAP: Partial<Record<SourceFilter, FileEntry['source']>> = {
	uploaded: 'user',
	agent: 'agent',
	synced: 'connector'
};

export function matchesSource(file: Pick<FileEntry, 'source'>, filter: SourceFilter): boolean {
	if (filter === 'any') return true;
	return file.source === SOURCE_MAP[filter];
}
