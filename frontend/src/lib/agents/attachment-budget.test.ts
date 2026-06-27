import { describe, expect, it } from 'vitest';
import {
	ALWAYS_INCLUDE_WARN_TOKENS,
	MAX_ALWAYS_INCLUDE_TOKENS,
	alwaysIncludeTokens,
	budgetTier
} from './attachment-budget';

describe('alwaysIncludeTokens', () => {
	it('sums tokenCount only for always-mode attachments', () => {
		const atts = [
			{ mode: 'always', tokenCount: 100 },
			{ mode: 'search', tokenCount: 5000 },
			{ mode: 'always', tokenCount: 250 }
		];
		expect(alwaysIncludeTokens(atts)).toBe(350);
	});

	it('is zero when no attachment is in always mode', () => {
		expect(alwaysIncludeTokens([{ mode: 'search', tokenCount: 9999 }])).toBe(0);
	});

	it('tolerates a zero/absent token count', () => {
		expect(alwaysIncludeTokens([{ mode: 'always', tokenCount: 0 }])).toBe(0);
	});
});

describe('budgetTier', () => {
	it('is ok at or below the warn threshold', () => {
		expect(budgetTier(0)).toBe('ok');
		expect(budgetTier(ALWAYS_INCLUDE_WARN_TOKENS)).toBe('ok');
	});

	it('warns above the warn threshold up to the max', () => {
		expect(budgetTier(ALWAYS_INCLUDE_WARN_TOKENS + 1)).toBe('warn');
		expect(budgetTier(MAX_ALWAYS_INCLUDE_TOKENS)).toBe('warn');
	});

	it('is over above the max', () => {
		expect(budgetTier(MAX_ALWAYS_INCLUDE_TOKENS + 1)).toBe('over');
	});
});
