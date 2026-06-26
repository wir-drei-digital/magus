import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '$lib/ash/api';
import { readHistory, writeHistory } from './history-cache';

function storageStub(): Storage {
	const map = new Map<string, string>();
	return {
		get length() {
			return map.size;
		},
		key: (index: number) => [...map.keys()][index] ?? null,
		getItem: (key: string) => map.get(key) ?? null,
		setItem: (key: string, value: string) => void map.set(key, value),
		removeItem: (key: string) => void map.delete(key),
		clear: () => map.clear()
	};
}

function message(overrides: Partial<ChatMessage>): ChatMessage {
	return {
		id: crypto.randomUUID(),
		text: 'hi',
		source: 'user',
		role: 'user',
		messageType: 'message',
		status: 'complete',
		insertedAt: '2026-06-12T10:00:00Z',
		modelName: null,
		toolCallData: null,
		citations: null,
		reasoningSummary: null,
		...overrides
	} as ChatMessage;
}

describe('history cache', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', storageStub());
	});

	it('drops provisional rows and persists the settled tail', () => {
		writeHistory('c1', [
			message({ id: 'local-abc', status: 'pending' }),
			message({ id: 'streaming-1', status: 'streaming' }),
			message({ id: 'real-1' })
		]);

		expect(readHistory('c1')?.map((entry) => entry.id)).toEqual(['real-1']);
	});

	it('skips writing when nothing settled remains', () => {
		writeHistory('c2', [message({ id: 'local-x', status: 'pending' })]);
		expect(readHistory('c2')).toBeNull();
	});

	it('evicts the least recently written conversation beyond the cap', () => {
		for (let index = 0; index < 11; index++) {
			writeHistory(`conv-${index}`, [message({ id: `m-${index}` })]);
		}

		expect(readHistory('conv-0')).toBeNull();
		expect(readHistory('conv-1')?.[0]?.id).toBe('m-1');
		expect(readHistory('conv-10')?.[0]?.id).toBe('m-10');
	});
});
