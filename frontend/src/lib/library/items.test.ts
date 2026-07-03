import { describe, expect, it } from 'vitest';
import type { PromptSummary, SkillSummary } from '$lib/ash/api';
import {
	itemIsFavorited,
	itemMatches,
	itemName,
	itemUseCount,
	partitionLibrary,
	promptItem,
	skillItem
} from './items';

function prompt(overrides: Partial<PromptSummary> = {}): PromptSummary {
	return {
		id: 'p1',
		name: 'Summarizer',
		description: null,
		content: 'Summarize this text',
		type: 'user',
		useCount: 3,
		isFavorited: false,
		isSharedToWorkspace: false,
		isPublic: false,
		tags: [],
		...overrides
	} as PromptSummary;
}

function skill(overrides: Partial<SkillSummary> = {}): SkillSummary {
	return {
		id: 's1',
		name: 'pdf-tools',
		displayName: null,
		description: 'Work with PDFs',
		workspaceId: null,
		isFavorited: false,
		isSharedToWorkspace: false,
		hasExecutableBundle: false,
		requestedTools: [],
		version: null,
		body: null,
		...overrides
	} as SkillSummary;
}

describe('item accessors', () => {
	it('itemName prefers skill displayName and falls back to name', () => {
		expect(itemName(skillItem(skill({ displayName: 'PDF Tools' })))).toBe('PDF Tools');
		expect(itemName(skillItem(skill()))).toBe('pdf-tools');
		expect(itemName(promptItem(prompt()))).toBe('Summarizer');
	});

	it('itemUseCount is 0 for skills', () => {
		expect(itemUseCount(promptItem(prompt({ useCount: 7 })))).toBe(7);
		expect(itemUseCount(skillItem(skill()))).toBe(0);
	});

	it('itemIsFavorited reads both kinds', () => {
		expect(itemIsFavorited(promptItem(prompt({ isFavorited: true })))).toBe(true);
		expect(itemIsFavorited(skillItem(skill({ isFavorited: true })))).toBe(true);
		expect(itemIsFavorited(skillItem(skill()))).toBe(false);
	});

	it('itemMatches searches prompt content and skill body', () => {
		expect(itemMatches(promptItem(prompt()), 'summarize this')).toBe(true);
		expect(itemMatches(skillItem(skill()), 'pdfs')).toBe(true);
		expect(itemMatches(skillItem(skill({ body: 'Run scripts/fill.py first' })), 'fill.py')).toBe(
			true
		);
		expect(itemMatches(skillItem(skill()), 'zzz')).toBe(false);
		expect(itemMatches(promptItem(prompt()), '')).toBe(true);
	});
});

describe('partitionLibrary', () => {
	it('merges kinds into all/favorites/shared/personal', () => {
		const sharedPrompt = prompt({ id: 'p-shared', isSharedToWorkspace: true });
		const personalPrompt = prompt({ id: 'p-personal' });
		const workspaceSkill = skill({ id: 's-ws', workspaceId: 'ws1' });
		const personalSkill = skill({ id: 's-personal' });
		const favPrompt = prompt({ id: 'p-fav', isFavorited: true });
		const favSkill = skill({ id: 's-fav', isFavorited: true });

		const result = partitionLibrary({
			prompts: [sharedPrompt, personalPrompt, favPrompt],
			favoritePrompts: [favPrompt],
			skills: [workspaceSkill, personalSkill, favSkill],
			favoriteSkills: [favSkill]
		});

		expect(result.all).toHaveLength(6);
		expect(result.favorites.map((i) => i.id)).toEqual(['p-fav', 's-fav']);
		expect(result.shared.map((i) => i.id)).toEqual(['p-shared', 's-ws']);
		expect(result.personal.map((i) => i.id).sort()).toEqual(
			['p-fav', 'p-personal', 's-fav', 's-personal'].sort()
		);
	});
});
