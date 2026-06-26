import { describe, it, expect } from 'vitest';
import { applyQueuedEvent, type QueuedMessage } from './queued';

describe('applyQueuedEvent', () => {
	const base: QueuedMessage[] = [{ id: 'm1', text: 'a' }];

	it('appends on enqueue_message', () => {
		const next = applyQueuedEvent(base, 'enqueue_message', { id: 'm2', text: 'b' });
		expect(next.map((m) => m.id)).toEqual(['m1', 'm2']);
	});

	it('removes on flush_queued', () => {
		const next = applyQueuedEvent(base, 'flush_queued', { id: 'm1' });
		expect(next).toEqual([]);
	});

	it('removes on remove_queued', () => {
		const next = applyQueuedEvent(base, 'remove_queued', { id: 'm1' });
		expect(next).toEqual([]);
	});

	it('is idempotent on duplicate enqueue', () => {
		const next = applyQueuedEvent(base, 'enqueue_message', { id: 'm1', text: 'a' });
		expect(next.map((m) => m.id)).toEqual(['m1']);
	});
});
