import { describe, expect, it } from 'vitest';
import { formatFileSize } from './format';

describe('formatFileSize', () => {
	it('formats across magnitudes', () => {
		expect(formatFileSize(0)).toBe('0 B');
		expect(formatFileSize(512)).toBe('512 B');
		expect(formatFileSize(2048)).toBe('2 KB');
		expect(formatFileSize(1536)).toBe('1.5 KB');
		expect(formatFileSize(10 * 1024 * 1024)).toBe('10 MB');
		expect(formatFileSize(1.5 * 1024 * 1024 * 1024)).toBe('1.5 GB');
	});

	it('handles garbage defensively', () => {
		expect(formatFileSize(-1)).toBe('—');
		expect(formatFileSize(Number.NaN)).toBe('—');
	});
});
