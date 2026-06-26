import { describe, expect, it } from 'vitest';
import { categoryEnabled, toggleCategory, toggleSkill, TOOL_CATEGORIES } from './agent-tools';

describe('TOOL_CATEGORIES', () => {
	it('lists the 7 backend categories', () => {
		expect(TOOL_CATEGORIES.map((c) => c.key)).toEqual([
			'web',
			'code',
			'memory',
			'files',
			'skills',
			'tasks',
			'integrations'
		]);
	});
});

describe('categoryEnabled', () => {
	it('is enabled unless present in the disabled list', () => {
		expect(categoryEnabled([], 'web')).toBe(true);
		expect(categoryEnabled(['web'], 'web')).toBe(false);
	});
});

describe('toggleCategory', () => {
	it('adds to disabled when turning a category off, removes when on', () => {
		expect(toggleCategory([], 'code', false)).toEqual(['code']);
		expect(toggleCategory(['code'], 'code', true)).toEqual([]);
	});

	it('does not duplicate or error on repeat toggles', () => {
		expect(toggleCategory(['code'], 'code', false)).toEqual(['code']);
		expect(toggleCategory([], 'code', true)).toEqual([]);
	});
});

describe('toggleSkill', () => {
	it('adds and removes a skill by name', () => {
		expect(toggleSkill([], 'research', true)).toEqual(['research']);
		expect(toggleSkill(['research'], 'research', false)).toEqual([]);
		expect(toggleSkill(['research'], 'research', true)).toEqual(['research']);
	});
});
