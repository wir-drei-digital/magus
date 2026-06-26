import { describe, expect, it } from 'vitest';
import type { AgentSummary } from '$lib/ash/api';
import { detectMention, filterAgents, insertMention } from './mentions';
import { clearDraft, loadDraft, saveDraft } from './drafts';

const agent = (overrides: Partial<AgentSummary>): AgentSummary => ({
	id: 'a-1',
	name: 'Researcher',
	handle: 'researcher',
	icon: null,
	description: null,
	isDefault: false,
	workspaceId: null,
	isSharedToWorkspace: false,
	isPaused: false,
	updatedAt: '2026-06-11T00:00:00Z',
	imageUrl: null,
	...overrides
});

describe('detectMention', () => {
	it('detects a mention at the start of the text', () => {
		expect(detectMention('@res', 4)).toEqual({ start: 0, query: 'res' });
	});

	it('detects a mention after whitespace', () => {
		expect(detectMention('hey @res', 8)).toEqual({ start: 4, query: 'res' });
		expect(detectMention('line\n@a', 7)).toEqual({ start: 5, query: 'a' });
	});

	it('returns the empty query right after @', () => {
		expect(detectMention('ask @', 5)).toEqual({ start: 4, query: '' });
	});

	it('rejects emails and mid-word @', () => {
		expect(detectMention('mail me a@b', 11)).toBeNull();
	});

	it('rejects queries with non-handle characters', () => {
		expect(detectMention('@Res Q', 6)).toBeNull();
		expect(detectMention('@res que', 8)).toBeNull();
	});

	it('only looks before the caret', () => {
		expect(detectMention('@res tail', 4)).toEqual({ start: 0, query: 'res' });
	});
});

describe('filterAgents', () => {
	const agents = [
		agent({ id: '1', handle: 'researcher', name: 'Researcher' }),
		agent({ id: '2', handle: 'writer', name: 'Copy Writer' }),
		agent({ id: '3', handle: 'rev', name: 'Reviewer' })
	];

	it('matches handle prefix or name substring (classic behavior)', () => {
		expect(filterAgents(agents, 're').map((a) => a.id)).toEqual(['1', '3']);
		expect(filterAgents(agents, 'writ').map((a) => a.id)).toEqual(['2']);
		// name substring: "Writer" contains "rit"
		expect(filterAgents(agents, 'rit').map((a) => a.id)).toEqual(['2']);
	});

	it('caps at five suggestions', () => {
		const many = Array.from({ length: 8 }, (_, i) => agent({ id: `m-${i}`, handle: `agent-${i}` }));
		expect(filterAgents(many, 'agent')).toHaveLength(5);
	});
});

describe('insertMention', () => {
	it('replaces the partial mention and appends a space', () => {
		const result = insertMention('hey @res tail', 8, { start: 4, query: 'res' }, 'researcher');
		expect(result.text).toBe('hey @researcher  tail');
		expect(result.caret).toBe(4 + '@researcher '.length);
	});
});

describe('drafts', () => {
	function memoryStorage(): Storage {
		const map = new Map<string, string>();
		return {
			getItem: (k: string) => map.get(k) ?? null,
			setItem: (k: string, v: string) => void map.set(k, v),
			removeItem: (k: string) => void map.delete(k),
			clear: () => map.clear(),
			key: () => null,
			length: 0
		};
	}

	it('round-trips and clears per conversation', () => {
		const storage = memoryStorage();
		saveDraft(storage, 'c-1', 'hello');
		saveDraft(storage, 'c-2', 'other');

		expect(loadDraft(storage, 'c-1')).toBe('hello');
		expect(loadDraft(storage, 'c-2')).toBe('other');

		clearDraft(storage, 'c-1');
		expect(loadDraft(storage, 'c-1')).toBe('');
		expect(loadDraft(storage, 'c-2')).toBe('other');
	});

	it('removes the entry when saving an empty draft', () => {
		const storage = memoryStorage();
		saveDraft(storage, 'c-1', 'something');
		saveDraft(storage, 'c-1', '   ');
		expect(loadDraft(storage, 'c-1')).toBe('');
	});
});
