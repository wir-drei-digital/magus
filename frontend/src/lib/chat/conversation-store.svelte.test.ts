import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

/**
 * Store-wiring coverage for the mid-turn-steering feature: the whole-turn
 * `busy` lifecycle, the `queued.*` channel handlers → applyQueuedEvent reducer
 * wiring, and send()'s enqueue-when-busy branch. The pure reducer
 * (applyQueuedEvent) is unit-tested separately in queued.test.ts; this exercises
 * the live store that drives it from real channel callbacks and RPC calls.
 *
 * Runes (`$state`) compile + run under the existing vitest config (the
 * sveltekit() vite plugin transforms the .svelte.ts module even with
 * environment: 'node'). No jsdom / @testing-library / extra plugin needed.
 */

// ─── Socket mock ───────────────────────────────────────────────────────────
// getSocket() returns a fake socket whose channel() yields a fake channel that
// RECORDS every on(event, cb) so the test can invoke handlers directly.
type Handler = (payload: Record<string, unknown>) => void;
const handlers = new Map<string, Handler>();

function fakeReceiver() {
	const chain = { receive: vi.fn(() => chain) };
	return chain;
}

const fakeChannel = {
	on: vi.fn((event: string, cb: Handler) => {
		handlers.set(event, cb);
	}),
	join: vi.fn(() => fakeReceiver()),
	push: vi.fn(),
	leave: vi.fn(),
	onClose: vi.fn()
};

const fakeSocket = { channel: vi.fn(() => fakeChannel) };

vi.mock('$lib/realtime/socket', () => ({
	getSocket: vi.fn(async () => fakeSocket)
}));

// ─── API mock ──────────────────────────────────────────────────────────────
// Stub the RPC layer so send()/enqueue() don't hit the network and the test can
// assert WHICH call was made. History fetches resolve empty so start() settles.
const emptyHistory = { success: true as const, data: { messages: [], hasMore: false } };
const okMessage = (id: string) => ({
	success: true as const,
	data: {
		id,
		text: 'hi',
		source: 'user',
		role: 'user',
		messageType: 'message',
		status: 'complete',
		insertedAt: '2026-06-18T10:00:00Z',
		modelName: null,
		toolCallData: null,
		citations: null,
		reasoningSummary: null,
		metadata: {},
		attachments: [],
		disabled: false
	}
});

const sendUserMessage = vi.fn(async () => okMessage('srv-1'));
const enqueueMessage = vi.fn(async () => okMessage('q-1'));
const messageHistoryPage = vi.fn(async () => emptyHistory);
const messagesSince = vi.fn(async () => ({ success: true as const, data: [] }));
// Loosely typed so individual tests can resolve either a not-found failure
// (the default) or a success snapshot (the context.updated refresh test).
const getContextWindow = vi.fn(
	async (): Promise<{ success: boolean; data?: unknown; errors?: unknown[] }> => ({
		success: false,
		errors: []
	})
);

vi.mock('$lib/ash/api', () => ({
	sendUserMessage: (...args: unknown[]) => sendUserMessage(...(args as [])),
	enqueueMessage: (...args: unknown[]) => enqueueMessage(...(args as [])),
	messageHistoryPage: (...args: unknown[]) => messageHistoryPage(...(args as [])),
	messagesSince: (...args: unknown[]) => messagesSince(...(args as [])),
	getContextWindow: (...args: unknown[]) => getContextWindow(...(args as [])),
	// Unused by these tests but imported at module load.
	clearContextWindow: vi.fn(),
	compactContextWindow: vi.fn(),
	deleteMessage: vi.fn(),
	removeQueued: vi.fn(),
	sendNowQueued: vi.fn(),
	setContextStrategy: vi.fn(),
	toggleMessageDisabled: vi.fn()
}));

import { ConversationStore } from './conversation-store.svelte';

/** Build a started store with its channel handlers registered. */
async function startedStore(): Promise<ConversationStore> {
	const store = new ConversationStore('conv-1');
	await store.start();
	return store;
}

/** Invoke a recorded channel handler by event name. */
function fire(event: string, payload: Record<string, unknown> = {}): void {
	const cb = handlers.get(event);
	if (!cb) throw new Error(`no handler bound for ${event}`);
	cb(payload);
}

beforeEach(() => {
	handlers.clear();
	vi.clearAllMocks();
	sendUserMessage.mockResolvedValue(okMessage('srv-1'));
	enqueueMessage.mockResolvedValue(okMessage('q-1'));
	messageHistoryPage.mockResolvedValue(emptyHistory);
	messagesSince.mockResolvedValue({ success: true, data: [] });
	getContextWindow.mockResolvedValue({ success: false, errors: [] });
});

afterEach(() => {
	vi.useRealTimers();
});

describe('busy lifecycle (state.change / response.complete / error)', () => {
	it('a non-idle state.change sets busy true', async () => {
		const store = await startedStore();
		expect(store.busy).toBe(false);

		fire('state.change', { state: 'processing' });
		expect(store.busy).toBe(true);

		store.stop();
	});

	it('state.change idle clears busy', async () => {
		const store = await startedStore();
		fire('state.change', { state: 'tool_calling' });
		expect(store.busy).toBe(true);

		fire('state.change', { state: 'idle' });
		expect(store.busy).toBe(false);

		store.stop();
	});

	it('response.complete clears busy', async () => {
		const store = await startedStore();
		fire('state.change', { state: 'processing' });
		expect(store.busy).toBe(true);

		fire('response.complete', {});
		expect(store.busy).toBe(false);

		store.stop();
	});

	it('error clears busy', async () => {
		const store = await startedStore();
		fire('state.change', { state: 'processing' });
		expect(store.busy).toBe(true);

		fire('error', {});
		expect(store.busy).toBe(false);

		store.stop();
	});

	it('agentThinking mirrors the waiting-state set (thinking on, streaming off)', async () => {
		const store = await startedStore();

		fire('state.change', { state: 'thinking' });
		expect(store.agentThinking).toBe(true);
		expect(store.busy).toBe(true);

		// streaming is active-but-not-waiting: busy stays, thinking dots hide.
		fire('state.change', { state: 'streaming' });
		expect(store.agentThinking).toBe(false);
		expect(store.busy).toBe(true);

		store.stop();
	});
});

describe('queued.* channel handlers → reducer wiring', () => {
	it('queued.enqueue_message appends to queued', async () => {
		const store = await startedStore();
		expect(store.queued).toEqual([]);

		fire('queued.enqueue_message', { id: 'q1', text: 'first' });
		fire('queued.enqueue_message', { id: 'q2', text: 'second' });

		expect(store.queued.map((q) => q.id)).toEqual(['q1', 'q2']);
		expect(store.queued[0].text).toBe('first');

		store.stop();
	});

	it('normalizes snake_case fields on enqueue', async () => {
		const store = await startedStore();

		fire('queued.enqueue_message', {
			id: 'q1',
			text: 'hi',
			inserted_at: '2026-06-18T09:00:00Z',
			created_by_id: 'user-7'
		});

		expect(store.queued[0]).toMatchObject({
			id: 'q1',
			insertedAt: '2026-06-18T09:00:00Z',
			createdById: 'user-7'
		});

		store.stop();
	});

	it('duplicate enqueue is idempotent', async () => {
		const store = await startedStore();

		fire('queued.enqueue_message', { id: 'q1', text: 'hi' });
		fire('queued.enqueue_message', { id: 'q1', text: 'hi' });

		expect(store.queued.map((q) => q.id)).toEqual(['q1']);

		store.stop();
	});

	it('queued.flush_queued removes by id', async () => {
		const store = await startedStore();
		fire('queued.enqueue_message', { id: 'q1', text: 'a' });
		fire('queued.enqueue_message', { id: 'q2', text: 'b' });

		fire('queued.flush_queued', { id: 'q1' });
		expect(store.queued.map((q) => q.id)).toEqual(['q2']);

		store.stop();
	});

	it('queued.remove_queued removes by id', async () => {
		const store = await startedStore();
		fire('queued.enqueue_message', { id: 'q1', text: 'a' });
		fire('queued.enqueue_message', { id: 'q2', text: 'b' });

		fire('queued.remove_queued', { id: 'q2' });
		expect(store.queued.map((q) => q.id)).toEqual(['q1']);

		store.stop();
	});

	it('ignores queued events with no id', async () => {
		const store = await startedStore();
		fire('queued.enqueue_message', { text: 'no id' });
		fire('queued.flush_queued', {});

		expect(store.queued).toEqual([]);

		store.stop();
	});
});

describe('send() enqueue-when-busy gate', () => {
	it('routes to enqueueMessage (not sendUserMessage) while busy', async () => {
		const store = await startedStore();
		// Whole turn in progress.
		fire('state.change', { state: 'processing' });
		expect(store.busy).toBe(true);

		const ok = await store.send('a follow-up');

		expect(ok).toBe(true);
		expect(enqueueMessage).toHaveBeenCalledTimes(1);
		expect(enqueueMessage).toHaveBeenCalledWith('conv-1', 'a follow-up');
		expect(sendUserMessage).not.toHaveBeenCalled();

		store.stop();
	});

	it('takes the normal send path while idle', async () => {
		const store = await startedStore();
		expect(store.busy).toBe(false);

		const ok = await store.send('hello');

		expect(ok).toBe(true);
		expect(sendUserMessage).toHaveBeenCalledTimes(1);
		expect(enqueueMessage).not.toHaveBeenCalled();
		// The normal path marks the turn busy after a successful send.
		expect(store.busy).toBe(true);

		store.stop();
	});
});

describe('context.updated refreshes the snapshot (drives the floor divider)', () => {
	it('pulls the new window snapshot, including the compaction summary', async () => {
		const store = await startedStore();
		expect(store.contextWindow).toBeNull();

		// A completed compaction advances the floor and stores a summary. The
		// floor divider + its expandable summary derive from this snapshot, so a
		// `context.updated` broadcast must refresh it live (no reload).
		getContextWindow.mockResolvedValue({
			success: true,
			data: {
				total: 1000,
				max: 8000,
				fill: 0.125,
				breakdown: [],
				strategy: 'compact',
				modelKey: null,
				compactionStatus: 'idle',
				cachedTokens: null,
				actualInputTokens: null,
				windowStartAt: '2026-06-18T10:05:00Z',
				summaryMessageCount: 3,
				summary: 'Recap of earlier messages.'
			}
		});

		fire('context.updated', {});
		// #refreshContextWindow is fire-and-forget; let its promise settle.
		await vi.waitFor(() => expect(store.contextWindow).not.toBeNull());

		expect(store.contextWindow?.windowStartAt).toBe('2026-06-18T10:05:00Z');
		expect(store.contextWindow?.summaryMessageCount).toBe(3);
		expect(store.contextWindow?.summary).toBe('Recap of earlier messages.');

		store.stop();
	});
});
