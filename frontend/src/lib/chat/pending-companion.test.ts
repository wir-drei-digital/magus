import { describe, expect, it } from 'vitest';
import { setPendingCompanion, takePendingCompanion } from './pending-companion';

describe('pending-companion', () => {
	it('returns null when nothing is pending', () => {
		expect(takePendingCompanion('missing')).toBeNull();
	});

	it('round-trips a stashed companion by conversation id', () => {
		setPendingCompanion('conv-1', { type: 'thread', id: 't1' });
		expect(takePendingCompanion('conv-1')).toEqual({ type: 'thread', id: 't1' });
	});

	it('is single-use — a taken companion is cleared', () => {
		setPendingCompanion('conv-2', { type: 'thread', id: 't2' });
		expect(takePendingCompanion('conv-2')).not.toBeNull();
		expect(takePendingCompanion('conv-2')).toBeNull();
	});

	it('keeps companions isolated per conversation', () => {
		setPendingCompanion('a', { type: 'thread', id: 'ta' });
		setPendingCompanion('b', { type: 'thread', id: 'tb' });
		expect(takePendingCompanion('b')?.id).toBe('tb');
		expect(takePendingCompanion('a')?.id).toBe('ta');
	});
});
