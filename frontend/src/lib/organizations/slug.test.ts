import { describe, it, expect } from 'vitest';
import { slugify } from './slug';

describe('slugify', () => {
	it('lowercases and hyphenates a plain name', () => {
		expect(slugify('Acme Inc')).toBe('acme-inc');
	});

	it('strips non [a-z0-9\\s-] characters, then trims and hyphenates', () => {
		expect(slugify('  Ümlauts & Co  ')).toBe('mlauts-co');
	});

	it('trims leading and trailing hyphens', () => {
		expect(slugify('--x--')).toBe('x');
	});

	it('collapses runs of whitespace into a single hyphen', () => {
		expect(slugify('a   b\tc')).toBe('a-b-c');
	});

	it('returns an empty string when nothing survives the filter', () => {
		expect(slugify('   ')).toBe('');
		expect(slugify('&&&')).toBe('');
	});
});
