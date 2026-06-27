import { describe, expect, it } from 'vitest';
import { collaborativeConversationIds, watchKey } from './conversation-presence';

type Convo = { id: string; isMultiplayer: boolean; isSharedToWorkspace: boolean };

function convo(p: Partial<Convo> & { id: string }): Convo {
	return { isMultiplayer: false, isSharedToWorkspace: false, ...p };
}

describe('collaborativeConversationIds', () => {
	it('keeps multiplayer and workspace-shared conversations only', () => {
		const list = [
			convo({ id: 'solo' }),
			convo({ id: 'mp', isMultiplayer: true }),
			convo({ id: 'shared', isSharedToWorkspace: true }),
			convo({ id: 'both', isMultiplayer: true, isSharedToWorkspace: true })
		];
		expect(collaborativeConversationIds(list).sort()).toEqual(['both', 'mp', 'shared']);
	});

	it('returns an empty list when nothing is collaborative', () => {
		expect(collaborativeConversationIds([convo({ id: 'a' }), convo({ id: 'b' })])).toEqual([]);
	});
});

describe('watchKey', () => {
	it('is order-independent so reordering does not re-trigger a watch', () => {
		expect(watchKey(['b', 'a', 'c'])).toBe(watchKey(['c', 'b', 'a']));
	});

	it('changes when the set of ids changes', () => {
		expect(watchKey(['a', 'b'])).not.toBe(watchKey(['a', 'b', 'c']));
	});
});
