import { describe, expect, it } from 'vitest';
import type { ChatMessage } from '$lib/ash/api';
import {
	applyStreamChunk,
	buildChatStream,
	dropPersistedTools,
	isRenderableMessage,
	applyToolEvent,
	completeStreamMessage,
	lastInsertedAt,
	messageFromBroadcast,
	toolViewFromLive,
	toolViewFromPersisted,
	upsertMessage,
	type LiveToolEvent
} from './events';

const message = (overrides: Partial<ChatMessage>): ChatMessage => ({
	id: 'm-1',
	text: 'hello',
	source: 'user',
	role: 'user',
	messageType: 'message',
	status: 'complete',
	insertedAt: '2026-06-11T10:00:00Z',
	modelName: null,
	attachments: [],
	disabled: false,
	toolCallData: null,
	citations: null,
	reasoningSummary: null,
	metadata: {},
	...overrides
});

describe('messageFromBroadcast', () => {
	it('normalizes snake_case broadcast payloads', () => {
		const result = messageFromBroadcast({
			id: 'm-9',
			text: 'hi',
			source: 'agent',
			complete: true,
			message_type: 'message',
			inserted_at: '2026-06-11T11:00:00Z',
			model_name: 'grok-4.1'
		});

		expect(result).toMatchObject({
			id: 'm-9',
			source: 'agent',
			messageType: 'message',
			status: 'complete',
			insertedAt: '2026-06-11T11:00:00Z',
			modelName: 'grok-4.1'
		});
	});

	it('returns null without an id', () => {
		expect(messageFromBroadcast({ text: 'x' })).toBeNull();
	});
});

describe('upsertMessage', () => {
	it('appends new messages in insertedAt order', () => {
		const older = message({ id: 'm-1', insertedAt: '2026-06-11T10:00:00Z' });
		const newer = message({ id: 'm-2', insertedAt: '2026-06-11T11:00:00Z' });

		const result = upsertMessage([newer], older);
		expect(result.map((entry) => entry.id)).toEqual(['m-1', 'm-2']);
	});

	it('merges updates for existing ids in place', () => {
		const original = message({ id: 'm-1', text: 'old', status: 'streaming' });
		const update = message({ id: 'm-1', text: 'new', status: 'complete' });

		const result = upsertMessage([original], update);
		expect(result).toHaveLength(1);
		expect(result[0]).toMatchObject({ text: 'new', status: 'complete' });
	});

	it('keeps known metadata when a later broadcast omits it', () => {
		const original = message({ id: 'm-1', metadata: { draft_selection: { text: 'x' } } });
		const update = message({ id: 'm-1', text: 'new', metadata: {} });

		const result = upsertMessage([original], update);
		expect(result[0].metadata).toEqual({ draft_selection: { text: 'x' } });
	});
});

describe('applyStreamChunk', () => {
	it('creates a streaming agent message on first chunk', () => {
		const result = applyStreamChunk([], { message_id: 'm-3', text: 'He', delta: 'He' }, 'text');

		expect(result).toHaveLength(1);
		expect(result[0]).toMatchObject({
			id: 'm-3',
			text: 'He',
			status: 'streaming',
			source: 'agent'
		});
	});

	it('replaces text with the accumulated payload text', () => {
		const first = applyStreamChunk([], { message_id: 'm-3', text: 'He', delta: 'He' }, 'text');
		const second = applyStreamChunk(
			first,
			{ message_id: 'm-3', text: 'Hello', delta: 'llo' },
			'text'
		);

		expect(second[0].text).toBe('Hello');
	});

	it('completeStreamMessage finalizes the message', () => {
		const streaming = applyStreamChunk(
			[],
			{ message_id: 'm-3', text: 'Hel', delta: 'Hel' },
			'text'
		);
		const done = completeStreamMessage(streaming, { message_id: 'm-3', text: 'Hello!' });

		expect(done[0]).toMatchObject({ text: 'Hello!', status: 'complete' });
	});
});

describe('applyToolEvent', () => {
	it('tracks the start → progress → complete lifecycle', () => {
		let tools = applyToolEvent([], 'tool.start', {
			event_id: 'ev-1',
			tool_name: 'web_search',
			display_name: 'Web Search'
		});
		expect(tools[0]).toMatchObject({ eventId: 'ev-1', status: 'running' });

		tools = applyToolEvent(tools, 'tool.progress', {
			event_id: 'ev-1',
			data: { message: 'searching…' }
		});
		expect(tools[0].progress).toBe('searching…');

		tools = applyToolEvent(tools, 'tool.complete', {
			event_id: 'ev-1',
			status: 'success',
			output_summary: '3 results',
			duration_ms: 1200
		});
		expect(tools[0]).toMatchObject({
			status: 'success',
			outputSummary: '3 results',
			durationMs: 1200
		});
	});

	it('marks errored tools', () => {
		let tools = applyToolEvent([], 'tool.start', { event_id: 'ev-2', tool_name: 'x' });
		tools = applyToolEvent(tools, 'tool.complete', { event_id: 'ev-2', error: 'boom' });
		expect(tools[0].status).toBe('error');
	});

	it('trusts the explicit status over a stray error field', () => {
		let tools = applyToolEvent([], 'tool.start', { event_id: 'ev-3', tool_name: 'x' });
		tools = applyToolEvent(tools, 'tool.complete', {
			event_id: 'ev-3',
			status: 'success',
			error: ''
		});
		expect(tools[0].status).toBe('success');

		let failing = applyToolEvent([], 'tool.start', { event_id: 'ev-4', tool_name: 'x' });
		failing = applyToolEvent(failing, 'tool.complete', {
			event_id: 'ev-4',
			status: 'error',
			error: null
		});
		expect(failing[0].status).toBe('error');
	});

	it('captures inputs on start and initializes an empty steps list', () => {
		const tools = applyToolEvent([], 'tool.start', {
			event_id: 'ev-i',
			tool_name: 'web_search',
			inputs: { query: 'hi' }
		});
		expect(tools[0].inputs).toEqual({ query: 'hi' });
		expect(tools[0].steps).toEqual([]);
	});

	it('accumulates streaming sub-steps (start → progress append/replace → complete)', () => {
		let tools = applyToolEvent([], 'tool.start', { event_id: 'ev-s', tool_name: 'x' });

		tools = applyToolEvent(tools, 'tool.step.start', {
			event_id: 'ev-s',
			step_id: 'ev-s-step-0',
			step_index: 0,
			label: 'Searching web'
		});
		expect(tools[0].steps).toHaveLength(1);
		expect(tools[0].steps[0]).toMatchObject({ label: 'Searching web', status: 'running' });

		// append mode streams content in
		tools = applyToolEvent(tools, 'tool.step.progress', {
			event_id: 'ev-s',
			step_id: 'ev-s-step-0',
			content: 'foo'
		});
		tools = applyToolEvent(tools, 'tool.step.progress', {
			event_id: 'ev-s',
			step_id: 'ev-s-step-0',
			content: 'bar'
		});
		expect(tools[0].steps[0].content).toBe('foobar');

		// replace mode overwrites
		tools = applyToolEvent(tools, 'tool.step.progress', {
			event_id: 'ev-s',
			step_id: 'ev-s-step-0',
			content: 'final',
			mode: 'replace'
		});
		expect(tools[0].steps[0].content).toBe('final');

		tools = applyToolEvent(tools, 'tool.step.complete', {
			event_id: 'ev-s',
			step_id: 'ev-s-step-0',
			status: 'complete',
			summary: 'done'
		});
		expect(tools[0].steps[0]).toMatchObject({ status: 'success', summary: 'done' });
	});

	it('does not duplicate a step with a repeated start', () => {
		let tools = applyToolEvent([], 'tool.start', { event_id: 'ev-d', tool_name: 'x' });
		const start = { event_id: 'ev-d', step_id: 'ev-d-step-0', step_index: 0, label: 'A' };
		tools = applyToolEvent(tools, 'tool.step.start', start);
		tools = applyToolEvent(tools, 'tool.step.start', start);
		expect(tools[0].steps).toHaveLength(1);
	});
});

describe('toolViewFromLive / toolViewFromPersisted', () => {
	it('live: shows progress while running, output summary when done', () => {
		let tools = applyToolEvent([], 'tool.start', { event_id: 'ev', tool_name: 'x' });
		tools = applyToolEvent(tools, 'tool.progress', {
			event_id: 'ev',
			data: { message: 'working' }
		});
		expect(toolViewFromLive(tools[0])).toMatchObject({ status: 'running', summary: 'working' });

		tools = applyToolEvent(tools, 'tool.complete', {
			event_id: 'ev',
			status: 'success',
			output_summary: 'ok'
		});
		expect(toolViewFromLive(tools[0])).toMatchObject({ status: 'success', summary: 'ok' });
	});

	it('persisted: maps snake_case row to the view (cancelled → error)', () => {
		const view = toolViewFromPersisted({
			status: 'success',
			display_name: 'Web Search',
			tool_name: 'web_search',
			output_summary: '3 results',
			inputs: { query: 'hi' },
			output: { results: [] }
		});
		expect(view).toMatchObject({
			status: 'success',
			displayName: 'Web Search',
			summary: '3 results',
			persisted: true
		});
		expect(view.inputs).toEqual({ query: 'hi' });

		expect(toolViewFromPersisted({ status: 'cancelled' }).status).toBe('error');
	});
});

describe('lastInsertedAt', () => {
	it('returns the max insertedAt as the gap-fill cursor', () => {
		const messages = [
			message({ id: 'a', insertedAt: '2026-06-11T10:00:00Z' }),
			message({ id: 'b', insertedAt: '2026-06-11T12:00:00Z' }),
			message({ id: 'c', insertedAt: '2026-06-11T11:00:00Z' })
		];

		expect(lastInsertedAt(messages)).toBe('2026-06-11T12:00:00Z');
		expect(lastInsertedAt([])).toBeNull();
	});

	it('ignores event messages — messages_since only returns regular messages', () => {
		const messages = [
			message({ id: 'a', insertedAt: '2026-06-11T10:00:00Z' }),
			message({ id: 'tool-ev', messageType: 'event', insertedAt: '2026-06-11T12:00:00Z' })
		];

		expect(lastInsertedAt(messages)).toBe('2026-06-11T10:00:00Z');
		expect(lastInsertedAt([message({ id: 'e', messageType: 'event' })])).toBeNull();
	});
});

describe('isRenderableMessage', () => {
	const base = {
		id: 'm1',
		text: '',
		source: 'agent',
		role: 'agent',
		messageType: 'message',
		status: 'complete',
		insertedAt: '2026-06-12T10:00:00Z',
		modelName: null,
		toolCallData: null,
		citations: null,
		reasoningSummary: null,
		attachments: []
	} as unknown as ChatMessage;

	it('hides completed text rows with no content (tool-only turns)', () => {
		expect(isRenderableMessage(base)).toBe(false);
		expect(isRenderableMessage({ ...base, text: '   ' })).toBe(false);
	});

	it('keeps rows with text, attachments, errors, or in-flight status', () => {
		expect(isRenderableMessage({ ...base, text: 'hello' })).toBe(true);
		expect(isRenderableMessage({ ...base, attachments: ['f1'] })).toBe(true);
		expect(isRenderableMessage({ ...base, status: 'error' })).toBe(true);
		expect(isRenderableMessage({ ...base, status: 'streaming' })).toBe(true);
		expect(isRenderableMessage({ ...base, status: 'pending' })).toBe(true);
	});

	it('never hides event rows', () => {
		expect(isRenderableMessage({ ...base, messageType: 'event' })).toBe(true);
	});
});

const liveTool = (overrides: Partial<LiveToolEvent>): LiveToolEvent => ({
	eventId: 'ev-1',
	toolName: 'run_code',
	displayName: 'Run code',
	status: 'running',
	progress: null,
	outputSummary: null,
	durationMs: null,
	inputs: null,
	steps: [],
	startedAt: '2026-06-12T10:00:01Z',
	...overrides
});

describe('dropPersistedTools', () => {
	it('drops a live tool once its persisted twin (toolCallData.id) is in messages', () => {
		const tools = [liveTool({ eventId: 'ev-1' })];
		const messages = [
			message({
				id: 'm-evt',
				messageType: 'event',
				toolCallData: { id: 'ev-1', status: 'success' }
			})
		];
		expect(dropPersistedTools(tools, messages)).toEqual([]);
	});

	it('keeps live tools with no persisted twin and returns the same ref (no churn)', () => {
		const tools = [liveTool({ eventId: 'ev-9' })];
		const messages = [message({ id: 'm-1' })];
		expect(dropPersistedTools(tools, messages)).toBe(tools);
	});
});

describe('buildChatStream', () => {
	it('interleaves messages and live tools by time (tool between two messages)', () => {
		const messages = [
			message({ id: 'u', insertedAt: '2026-06-12T10:00:00Z' }),
			message({ id: 'a', source: 'agent', text: 'done', insertedAt: '2026-06-12T10:00:05Z' })
		];
		const tools = [liveTool({ eventId: 'ev-1', startedAt: '2026-06-12T10:00:02Z' })];
		const stream = buildChatStream(messages, tools);
		expect(stream.map((i) => i.key)).toEqual(['u', 'tool:ev-1', 'a']);
	});

	it('de-dupes a live tool whose persisted twin is already a message', () => {
		const messages = [
			message({ id: 'u', insertedAt: '2026-06-12T10:00:00Z' }),
			message({
				id: 'm-evt',
				messageType: 'event',
				insertedAt: '2026-06-12T10:00:03Z',
				toolCallData: { id: 'ev-1', status: 'success' }
			})
		];
		const tools = [liveTool({ eventId: 'ev-1', startedAt: '2026-06-12T10:00:02Z' })];
		const stream = buildChatStream(messages, tools);
		// Only the persisted event row renders — the live twin is dropped.
		expect(stream.filter((i) => i.kind === 'tool')).toHaveLength(0);
		expect(stream.map((i) => i.key)).toEqual(['u', 'm-evt']);
	});

	it('omits empty tool-only agent rows but keeps the streaming bubble', () => {
		const messages = [
			message({ id: 'empty', source: 'agent', text: '', status: 'complete' }),
			message({ id: 'streaming', source: 'agent', text: 'hi', status: 'streaming' })
		];
		const stream = buildChatStream(messages, []);
		expect(stream.map((i) => i.key)).toEqual(['streaming']);
	});
});
