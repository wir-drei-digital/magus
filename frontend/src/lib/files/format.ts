/** Human file size, matching the classic browser's compact style. */
export function formatFileSize(bytes: number): string {
	if (!Number.isFinite(bytes) || bytes < 0) return '—';
	if (bytes < 1024) return `${bytes} B`;

	const units = ['KB', 'MB', 'GB', 'TB'];
	let value = bytes;
	let unit = 'B';

	for (const next of units) {
		if (value < 1024) break;
		value /= 1024;
		unit = next;
	}

	return `${value >= 10 || Number.isInteger(value) ? Math.round(value) : value.toFixed(1)} ${unit}`;
}
