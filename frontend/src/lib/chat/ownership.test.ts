import { describe, expect, it } from 'vitest';
import { isConversationOwner } from './ownership';

describe('isConversationOwner', () => {
	it('is true when the current user is the conversation owner', () => {
		expect(isConversationOwner({ userId: 'u1' }, 'u1')).toBe(true);
	});

	it('is false for a non-owner member', () => {
		expect(isConversationOwner({ userId: 'u1' }, 'u2')).toBe(false);
	});

	it('is false when the conversation is not loaded', () => {
		expect(isConversationOwner(null, 'u1')).toBe(false);
		expect(isConversationOwner(undefined, 'u1')).toBe(false);
	});

	it('is false when there is no current user', () => {
		expect(isConversationOwner({ userId: 'u1' }, null)).toBe(false);
		expect(isConversationOwner({ userId: 'u1' }, undefined)).toBe(false);
	});
});
