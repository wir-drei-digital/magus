import { describe, expect, it } from 'vitest';
import { setPendingMessage, takePendingMessage } from './pending-message';

describe('pending-message', () => {
	it('returns null when nothing is pending', () => {
		expect(takePendingMessage('missing')).toBeNull();
	});

	it('round-trips a stashed message by conversation id', () => {
		setPendingMessage('conv-1', { text: 'hello', resources: [] });
		expect(takePendingMessage('conv-1')).toEqual({ text: 'hello', resources: [] });
	});

	it('is single-use — a taken message is cleared', () => {
		setPendingMessage('conv-2', { text: 'hi', resources: [{ type: 'file', id: 'f1' }] });
		expect(takePendingMessage('conv-2')).not.toBeNull();
		expect(takePendingMessage('conv-2')).toBeNull();
	});

	it('keeps messages isolated per conversation', () => {
		setPendingMessage('a', { text: 'a-text', resources: [] });
		setPendingMessage('b', { text: 'b-text', resources: [] });
		expect(takePendingMessage('b')?.text).toBe('b-text');
		expect(takePendingMessage('a')?.text).toBe('a-text');
	});
});
