import { describe, expect, it } from 'vitest';
import { modeFromPath } from './route-mode';

describe('modeFromPath', () => {
	it('maps /library to library', () => {
		expect(modeFromPath('/library')).toBe('library');
		expect(modeFromPath('/library/prompts/abc')).toBe('library');
		expect(modeFromPath('/library/skills/abc')).toBe('library');
	});

	it('maps legacy /prompts and /skills paths to library', () => {
		expect(modeFromPath('/prompts')).toBe('library');
		expect(modeFromPath('/prompts/abc')).toBe('library');
		expect(modeFromPath('/skills/abc')).toBe('library');
	});

	it('keeps the other modes', () => {
		expect(modeFromPath('/brain/x')).toBe('brain');
		expect(modeFromPath('/files')).toBe('files');
		expect(modeFromPath('/agents/a1')).toBe('agents');
		expect(modeFromPath('/settings')).toBe('chat');
	});
});
