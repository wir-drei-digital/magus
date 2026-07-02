import { describe, expect, it } from 'vitest';
import {
	isBrokenSelection,
	precedingUserText,
	resetTarget,
	type BrokenSelectionPayload
} from './broken-selection';

const payload: BrokenSelectionPayload = {
	kind: 'broken_model_selection',
	requested_by: 'key',
	requested_value: 'openrouter:gone/model',
	fallback_key: 'openrouter:x-ai/grok-4.3',
	scope: 'user'
};

describe('isBrokenSelection', () => {
	it('accepts the Task 1 broken_model_selection payload', () => {
		expect(isBrokenSelection(payload)).toBe(true);
	});

	it('accepts a payload with a null fallback_key (rare backend case)', () => {
		expect(isBrokenSelection({ ...payload, fallback_key: null })).toBe(true);
	});

	it('rejects other tool_call_data kinds', () => {
		expect(isBrokenSelection({ kind: 'some_tool', tool_name: 'search' })).toBe(false);
	});

	it('rejects null / undefined / non-objects', () => {
		expect(isBrokenSelection(null)).toBe(false);
		expect(isBrokenSelection(undefined)).toBe(false);
		expect(isBrokenSelection('broken_model_selection')).toBe(false);
		expect(isBrokenSelection(42)).toBe(false);
	});

	it('rejects an empty object (no kind)', () => {
		expect(isBrokenSelection({})).toBe(false);
	});
});

describe('resetTarget', () => {
	it('maps scope "user" to user', () => {
		expect(resetTarget({ ...payload, scope: 'user' })).toBe('user');
	});

	it('maps scope "conversation" to conversation', () => {
		expect(resetTarget({ ...payload, scope: 'conversation' })).toBe('conversation');
	});

	it('maps any non-user scope to conversation', () => {
		expect(resetTarget({ ...payload, scope: 'anything-else' })).toBe('conversation');
	});
});

describe('precedingUserText', () => {
	type Row = {
		id: string;
		source: 'user' | 'agent';
		messageType: 'message' | 'event';
		text: string;
	};

	const user = (id: string, text: string): Row => ({
		id,
		source: 'user',
		messageType: 'message',
		text
	});
	const event = (id: string): Row => ({
		id,
		source: 'agent',
		messageType: 'event',
		text: 'The model you selected is no longer available.'
	});

	it('returns the nearest prior user message text before the event', () => {
		const messages = [user('u1', 'first'), user('u2', 'blocked ask'), event('e1')];
		expect(precedingUserText(messages, 'e1')).toBe('blocked ask');
	});

	it('skips the event row itself and any non-user rows when scanning back', () => {
		const messages = [
			user('u1', 'the ask'),
			{ id: 'a1', source: 'agent' as const, messageType: 'message' as const, text: 'reply' },
			event('e1')
		];
		expect(precedingUserText(messages, 'e1')).toBe('the ask');
	});

	it('returns null when the event id is unknown', () => {
		expect(precedingUserText([user('u1', 'x'), event('e1')], 'missing')).toBeNull();
	});

	it('returns null when there is no prior user message', () => {
		expect(precedingUserText([event('e1')], 'e1')).toBeNull();
	});

	it('ignores user messages that come after the event', () => {
		const messages = [event('e1'), user('u2', 'later')];
		expect(precedingUserText(messages, 'e1')).toBeNull();
	});
});
