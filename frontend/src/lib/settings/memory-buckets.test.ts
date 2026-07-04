import { describe, it, expect } from 'vitest';
import { bucketOptions } from './memory-buckets';

describe('bucketOptions', () => {
	it('always lists Personal first with a null value', () => {
		expect(bucketOptions([], null)[0]).toEqual({ value: null, label: 'Personal' });
	});

	it('appends one option per workspace in order', () => {
		expect(
			bucketOptions(
				[
					{ id: 'a', name: 'Alpha' },
					{ id: 'b', name: 'Beta' }
				],
				null
			)
		).toEqual([
			{ value: null, label: 'Personal' },
			{ value: 'a', label: 'Alpha' },
			{ value: 'b', label: 'Beta' }
		]);
	});
});
