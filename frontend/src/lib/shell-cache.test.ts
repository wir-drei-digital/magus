import { beforeEach, describe, expect, it, vi } from 'vitest';
import { clearShellCache, readShellCache, writeShellCache } from './shell-cache';
import { modeFromPath } from './route-mode';

// The node test environment lacks a full Storage implementation.
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

describe('shell cache', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', storageStub());
	});

	it('round-trips values', () => {
		writeShellCache('thing', { a: 1, list: ['x'] });
		expect(readShellCache('thing')).toEqual({ a: 1, list: ['x'] });
	});

	it('returns null for missing or corrupt entries', () => {
		expect(readShellCache('absent')).toBeNull();
		localStorage.setItem('magus:next:cache:v1:bad', '{not json');
		expect(readShellCache('bad')).toBeNull();
	});

	it('clears only its own keys', () => {
		writeShellCache('one', 1);
		localStorage.setItem('magus:next:draft:abc', 'keep me');
		clearShellCache();
		expect(readShellCache('one')).toBeNull();
		expect(localStorage.getItem('magus:next:draft:abc')).toBe('keep me');
	});
});

describe('modeFromPath', () => {
	it('derives the mode from the route', () => {
		expect(modeFromPath('/next/brain/page/123')).toBe('brain');
		expect(modeFromPath('/next/files/file/9')).toBe('files');
		expect(modeFromPath('/next/prompts/p1')).toBe('prompts');
		expect(modeFromPath('/next/agents/a1')).toBe('agents');
		expect(modeFromPath('/next/chat/c1')).toBe('chat');
		expect(modeFromPath('/next')).toBe('chat');
	});
});
