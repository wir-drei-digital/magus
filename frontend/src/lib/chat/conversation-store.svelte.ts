import type { Channel } from 'phoenix';
import { getSocket } from '$lib/realtime/socket';
import {
	clearContextWindow,
	compactContextWindow,
	deleteMessage,
	enqueueMessage,
	getContextWindow,
	messageHistoryPage,
	messagesSince,
	removeQueued,
	sendNowQueued,
	sendUserMessage,
	setContextStrategy,
	toggleMessageDisabled,
	type AttachedResource,
	type ChatMessage,
	type CompanionSpec,
	type ContextWindowSnapshot
} from '$lib/ash/api';
import {
	applyStreamChunk,
	applyToolEvent,
	completeStreamMessage,
	dropPersistedTools,
	lastInsertedAt,
	messageFromBroadcast,
	upsertMessage,
	type LiveToolEvent
} from '$lib/chat/events';
import { applyQueuedEvent, type QueuedMessage } from '$lib/chat/queued';
import { readHistory, writeHistory } from '$lib/chat/history-cache';

export type TypingUser = { userId: string; userName: string };

/**
 * Messages loaded per page (initial render + each scroll-up fetch).
 * Kept close to the classic workbench's 25 (@message_page_size): a smaller
 * first page cuts the cold-open cost that scales with message count: RPC
 * payload, JSON parse, DOM nodes, and the synchronous per-message markdown
 * parse (marked + DOMPurify) in markdown.svelte. Older messages stream in on
 * scroll-up via messageHistoryPage({ before }).
 */
const PAGE_SIZE = 30;

/**
 * Agent states whose `state.change` shows the "thinking" indicator, mirroring
 * the workbench Helpers.derive_thinking_state `waiting` flag. `streaming`,
 * `processing`, and `idle` are deliberately absent (the answer is arriving or
 * the turn is done), as are unknown states.
 */
const WAITING_STATES = new Set([
	'thinking',
	'reasoning',
	'tool_calling',
	'tool_call',
	'running_tools',
	'generating_image',
	'generating_video',
	'waiting'
]);

/**
 * Per-conversation live store: history via RPC, then live events over the
 * `conversation:<id>` channel. Renders instantly from local state; reconnects
 * gap-fill via `messages_since`. The store degrades gracefully — without a
 * socket the history still renders and a banner reports the offline state.
 */
export class ConversationStore {
	conversationId: string;

	messages = $state<ChatMessage[]>([]);
	liveTools = $state<LiveToolEvent[]>([]);
	typing = $state<TypingUser[]>([]);
	agentThinking = $state(false);
	/**
	 * true for the whole agent turn (thinking + tools + streaming); gates
	 * enqueue-vs-send and is distinct from agentThinking (thinking-dots only).
	 */
	busy = $state(false);
	/**
	 * Live reasoning text accumulated from `thinking.chunk` (the full text rides
	 * each chunk). Drives the streaming reasoning indicator; cleared when the
	 * turn settles, at which point the persisted message carries its own
	 * reasoning summary. Parity with the workbench streaming_thinking_indicator.
	 */
	streamingThinking = $state('');
	/** Watchdog: no streaming activity for a while — "taking longer…" hint. */
	agentDelayed = $state(false);
	connection = $state<'connecting' | 'live' | 'offline'>('connecting');
	loading = $state(true);
	loadError = $state<string | null>(null);

	/** Older messages remain before the oldest loaded one (scroll-up affordance). */
	hasMore = $state(false);
	/** A load-older page is in flight (gates re-entry + shows the top spinner). */
	loadingOlder = $state(false);
	sending = $state(false);
	sendError = $state<string | null>(null);
	accessRevoked = $state(false);

	/**
	 * Messages enqueued while the agent is mid-turn. Reconciled entirely from
	 * the conversation channel's `queued.*` broadcasts via applyQueuedEvent, so
	 * every viewer (and this tab's own RPC echo) converges on the same queue.
	 */
	queued = $state<QueuedMessage[]>([]);

	/** Plan-limit error from the last turn; renders the limit dialog. */
	limitExceeded = $state<string | null>(null);

	/**
	 * Persisted context-window snapshot for the donut indicator, or `null` when
	 * no row exists yet (fresh conversation). Fetched once on join, then
	 * refetched on every `context.updated` channel event (the backend broadcasts
	 * on turn completion and on clear/compact/set-strategy). The payload is never
	 * trusted: each event triggers a fresh read, mirroring the LiveView approach.
	 */
	contextWindow = $state<ContextWindowSnapshot | null>(null);

	/**
	 * Send-lock parity with the LiveView composer: true while a compaction is in
	 * flight (`pending`/`running`). `idle` and `failed` do not block sending.
	 */
	get compactionInProgress(): boolean {
		const status = this.contextWindow?.compactionStatus;
		return status === 'pending' || status === 'running';
	}

	/** Bumped on draft.* channel events so an open draft companion refetches. */
	draftRevision = $state(0);

	/**
	 * Bumped on every `ui.open_brain_pane` signal — edit_brain emits it after
	 * each successful write_page, so an already-open brain companion refetches
	 * and the user watches the page fill in (classic live-reload parity).
	 */
	brainRevision = $state(0);

	/**
	 * Agent-initiated companion opens (`ui.open_brain_pane` after brain tool
	 * runs, `draft.created` after write_draft — classic parity). The host
	 * page wires this to `workbench.setCompanion` for the conversation's tab.
	 */
	onCompanionRequest: ((spec: CompanionSpec) => void) | null = null;

	/**
	 * Text the right rail asked the composer to insert at the caret (classic
	 * `insert_text` push event). Revision-armed so re-renders don't re-insert.
	 */
	insertTextRequest = $state<{ text: string; revision: number }>({ text: '', revision: 0 });

	requestInsertText(text: string): void {
		this.insertTextRequest = { text, revision: this.insertTextRequest.revision + 1 };
	}

	#channel: Channel | null = null;
	#joinedOnce = false;
	#typing = false;
	#typingIdleTimer: ReturnType<typeof setTimeout> | null = null;
	#delayedTimer: ReturnType<typeof setTimeout> | null = null;
	#stuckTimer: ReturnType<typeof setTimeout> | null = null;

	/**
	 * Newest server-stamped insertedAt when the current turn began — the
	 * post-turn reconcile fetches only messages since then instead of the
	 * whole history. Captured before any client-stamped provisional rows
	 * (optimistic send bubble, streaming placeholder) enter the array.
	 */
	#turnBaseline: string | null = null;

	/**
	 * Streaming chunks are buffered and applied once per animation frame.
	 * Fast streams otherwise reassign `messages` per chunk, re-running the
	 * full reactive chain (markdown parse of the growing text, list diff,
	 * auto-scroll) dozens of times per second.
	 */
	#chunkBuffer: Array<{ payload: Record<string, unknown>; kind: 'text' | 'thinking' }> = [];
	#chunkFlushHandle: number | null = null;

	#queueChunk(payload: Record<string, unknown>, kind: 'text' | 'thinking'): void {
		this.#turnBaseline ??= lastInsertedAt(this.messages);
		this.#chunkBuffer.push({ payload, kind });
		this.agentThinking = kind === 'thinking';
		if (kind === 'thinking') {
			// Reasoning chunks carry the full accumulated reasoning text; surface
			// it live.
			if (typeof payload.text === 'string') this.streamingThinking = payload.text;
		} else {
			// The answer text has begun: retire the live reasoning box (parity with
			// the workbench, which hides it once is_streaming). The settled message
			// then carries its own reasoning summary.
			this.streamingThinking = '';
		}
		this.#armWatchdog();
		this.#chunkFlushHandle ??=
			typeof requestAnimationFrame === 'function'
				? requestAnimationFrame(() => this.#flushChunks())
				: (setTimeout(() => this.#flushChunks(), 16) as unknown as number);
	}

	#flushChunks(): void {
		this.#chunkFlushHandle = null;
		if (this.#chunkBuffer.length === 0) return;
		const buffered = this.#chunkBuffer;
		this.#chunkBuffer = [];
		let next = this.messages;
		for (const { payload, kind } of buffered) {
			next = applyStreamChunk(next, payload, kind);
		}
		this.messages = next;
	}

	/**
	 * A silent agent crash mid-turn (hibernation/recovery) never sends a
	 * terminal event, leaving the thinking indicator on forever. Every
	 * streaming signal re-arms the watchdog: 30s of silence shows a
	 * "taking longer" hint; 120s clears the indicator and reconciles
	 * history so any persisted-but-unstreamed reply still appears.
	 */
	#armWatchdog(): void {
		this.#clearWatchdog();
		this.#delayedTimer = setTimeout(() => {
			this.agentDelayed = true;
		}, 30_000);
		this.#stuckTimer = setTimeout(() => {
			this.agentThinking = false;
			this.busy = false;
			this.agentDelayed = false;
			this.streamingThinking = '';
			void this.#reconcileAfterResponse();
		}, 120_000);
	}

	#clearWatchdog(): void {
		if (this.#delayedTimer) clearTimeout(this.#delayedTimer);
		if (this.#stuckTimer) clearTimeout(this.#stuckTimer);
		this.#delayedTimer = null;
		this.#stuckTimer = null;
		this.agentDelayed = false;
	}

	constructor(conversationId: string) {
		this.conversationId = conversationId;
	}

	async start(): Promise<void> {
		// Re-opening a conversation renders from the snapshot immediately;
		// the gap-fill fetches only the delta and the true-up below settles
		// anything a delta can't catch (deletions while away).
		const cached = readHistory(this.conversationId);
		if (cached) {
			this.messages = cached;
			// Optimistic: a full cached tail likely has older messages behind it.
			// #trueUp corrects this from the server, and the first loadOlder
			// self-corrects to false if nothing older comes back.
			this.hasMore = cached.length >= PAGE_SIZE;
			this.loading = false;
			await Promise.all([this.#gapFill(), this.#join()]);
			void this.#trueUp();
			return;
		}
		await Promise.all([this.#loadHistory(), this.#join()]);
	}

	stop(): void {
		writeHistory(this.conversationId, this.messages);
		this.#setTyping(false);
		this.streamingThinking = '';
		this.#clearWatchdog();
		if (this.#chunkFlushHandle !== null) {
			if (typeof cancelAnimationFrame === 'function') cancelAnimationFrame(this.#chunkFlushHandle);
			else clearTimeout(this.#chunkFlushHandle);
			this.#chunkFlushHandle = null;
		}
		this.#chunkBuffer = [];
		this.#channel?.leave();
		this.#channel = null;
	}

	/**
	 * User pressed Stop. Ask the server to cancel the in-flight agent turn
	 * (`cancel_response` → `message.cancel` signal + a "Response cancelled"
	 * event) and optimistically clear the local streaming flags so the composer
	 * returns to its idle send affordance immediately. The event message and any
	 * `response.complete` arrive over the channel and reconcile as usual.
	 */
	cancelResponse(): void {
		this.#channel?.push('cancel_response', {});
		this.agentThinking = false;
		this.agentDelayed = false;
		this.streamingThinking = '';
		this.#clearWatchdog();
	}

	/**
	 * Call on every composer keystroke: emits `typing` true once, then false
	 * after 3s of inactivity (or explicitly via stopTyping/send). The server
	 * relays the frozen `user_typing` broadcast only for collaborative
	 * conversations, so this is a cheap no-op otherwise.
	 */
	notifyTyping(): void {
		this.#setTyping(true);
		if (this.#typingIdleTimer) clearTimeout(this.#typingIdleTimer);
		this.#typingIdleTimer = setTimeout(() => this.#setTyping(false), 3000);
	}

	stopTyping(): void {
		if (this.#typingIdleTimer) clearTimeout(this.#typingIdleTimer);
		this.#typingIdleTimer = null;
		this.#setTyping(false);
	}

	#setTyping(isTyping: boolean): void {
		if (this.#typing === isTyping || !this.#channel) {
			this.#typing = isTyping && this.#channel !== null;
			return;
		}
		this.#typing = isTyping;
		this.#channel.push('typing', { is_typing: isTyping });
	}

	/**
	 * Optimistically removes the message; on failure re-inserts just that
	 * message (not a whole-array snapshot, which would clobber broadcasts
	 * that landed during the RPC).
	 */
	async removeMessage(id: string): Promise<boolean> {
		const removed = this.messages.find((message) => message.id === id);
		this.messages = this.messages.filter((message) => message.id !== id);

		const result = await deleteMessage(id);
		if (!result.success) {
			if (removed) this.messages = upsertMessage(this.messages, removed);
			return false;
		}
		return true;
	}

	/** Classic eye toggle: optimistic flip, server-reconciled. */
	async toggleDisabled(id: string): Promise<void> {
		const current = this.messages.find((message) => message.id === id);
		if (!current) return;
		this.messages = upsertMessage(this.messages, { ...current, disabled: !current.disabled });

		const result = await toggleMessageDisabled(id);
		this.messages = upsertMessage(this.messages, result.success ? result.data : current);
	}

	/**
	 * Optimistic send: a pending bubble renders immediately and is replaced by
	 * the server row on success (the `message.send_user_message` broadcast
	 * carries the same id, so the channel echo dedupes via upsert). On failure
	 * the bubble is removed and the composer keeps the text for retry.
	 */
	async send(text: string, resources: AttachedResource[] = []): Promise<boolean> {
		const trimmed = text.trim();
		if (!trimmed || this.sending || this.accessRevoked) return false;

		// Mid-turn steering: while the agent is working (the WHOLE turn —
		// thinking, tool rounds, and answer streaming), a new message joins the
		// server-side queue instead of starting a fresh turn. Gated on `busy`,
		// not `agentThinking`, which is true only during the thinking phase. The
		// `queued.enqueue_message` broadcast reconciles `queued`.
		if (this.busy) {
			return this.enqueue(trimmed);
		}

		this.sending = true;
		this.sendError = null;
		this.streamingThinking = '';
		this.stopTyping();

		// Before the client-stamped optimistic bubble lands: everything this
		// turn produces will have a server insertedAt >= this.
		this.#turnBaseline ??= lastInsertedAt(this.messages);

		const localId = `local-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
		this.messages = upsertMessage(this.messages, {
			id: localId,
			text: trimmed,
			source: 'user',
			role: 'user',
			messageType: 'message',
			status: 'pending',
			insertedAt: new Date().toISOString(),
			modelName: null,
			toolCallData: null,
			citations: null,
			reasoningSummary: null,
			metadata: {},
			attachments: resources.map((resource) => resource.id),
			disabled: false
		});

		const result = await sendUserMessage(this.conversationId, trimmed, resources);
		this.messages = this.messages.filter((message) => message.id !== localId);

		if (result.success) {
			this.messages = upsertMessage(this.messages, result.data);
			// The agent is now working even though no signal has streamed yet —
			// show the thinking dots immediately (classic parity). The first
			// text chunk or terminal event replaces/clears it.
			this.agentThinking = true;
			// Mark the whole turn busy so a follow-up message enqueues instead of
			// starting a new turn. Set only AFTER the enqueue branch above, so the
			// first message at idle still takes the normal send path.
			this.busy = true;
			this.#armWatchdog();
		} else {
			this.sendError = result.errors[0]?.message ?? 'Message could not be sent';
		}

		this.sending = false;
		return result.success;
	}

	/**
	 * Enqueues a message for the in-flight turn. The server broadcasts
	 * `queued.enqueue_message`, which reconciles `this.queued`, so no optimistic
	 * local insert is needed. Returns whether the enqueue succeeded (mirrors
	 * `send()`'s boolean so the composer can clear/keep its text the same way).
	 */
	async enqueue(text: string): Promise<boolean> {
		const trimmed = text.trim();
		if (!trimmed || this.accessRevoked) return false;

		this.sendError = null;
		this.stopTyping();

		const result = await enqueueMessage(this.conversationId, trimmed);
		if (!result.success) {
			this.sendError = result.errors[0]?.message ?? 'Message could not be queued';
		}
		return result.success;
	}

	/** Flushes the queued messages into the agent's turn now. */
	async sendNow(): Promise<boolean> {
		const result = await sendNowQueued(this.conversationId);
		if (!result.success) {
			this.sendError = result.errors[0]?.message ?? 'Queued messages could not be sent';
		}
		return result.success;
	}

	/** Drops a single queued message before it is sent (server-reconciled). */
	async removeQueued(id: string): Promise<boolean> {
		const result = await removeQueued(id);
		if (!result.success) {
			this.sendError = result.errors[0]?.message ?? 'Queued message could not be removed';
		}
		return result.success;
	}

	async #loadHistory(): Promise<void> {
		this.loading = true;
		const result = await messageHistoryPage(this.conversationId, { limit: PAGE_SIZE });

		if (result.success) {
			// Server returns newest-first; we keep ascending order.
			this.messages = result.data.messages
				.slice()
				.sort((a, b) => a.insertedAt.localeCompare(b.insertedAt));
			this.hasMore = result.data.hasMore;
			this.loadError = null;
			writeHistory(this.conversationId, this.messages);
		} else {
			this.loadError = result.errors[0]?.message ?? 'Failed to load messages';
		}

		this.loading = false;
	}

	/**
	 * Scroll-up pagination: fetch the page of messages older than the oldest
	 * loaded one and merge them in (deduped, re-sorted ascending). The view
	 * preserves scroll position across the prepend.
	 */
	async loadOlder(): Promise<void> {
		if (!this.hasMore || this.loadingOlder || this.loading) return;
		const oldest = this.messages[0]?.insertedAt;
		if (!oldest) return;

		this.loadingOlder = true;
		const result = await messageHistoryPage(this.conversationId, {
			limit: PAGE_SIZE,
			before: oldest
		});

		if (result.success) {
			const byId = new Map(this.messages.map((message) => [message.id, message]));
			for (const message of result.data.messages) {
				if (!byId.has(message.id)) byId.set(message.id, message);
			}
			this.messages = [...byId.values()].sort((a, b) => a.insertedAt.localeCompare(b.insertedAt));
			this.hasMore = result.data.hasMore;
			writeHistory(this.conversationId, this.messages);
		}

		this.loadingOlder = false;
	}

	/**
	 * Settles snapshot-vs-server drift the delta fetch can't catch — rows
	 * deleted while this conversation wasn't joined. Replaces wholesale only
	 * when the turn is quiescent; mid-stream it merges instead (a replace
	 * would drop the provisional streaming message).
	 */
	async #trueUp(): Promise<void> {
		const result = await messageHistoryPage(this.conversationId, { limit: PAGE_SIZE });
		if (!result.success) return;

		const fresh = result.data.messages
			.slice()
			.sort((a, b) => a.insertedAt.localeCompare(b.insertedAt));
		const quiescent = !this.agentThinking && !this.sending && this.#chunkBuffer.length === 0;

		// Wholesale replace (catches rows deleted while away) is only safe when
		// the newest page IS the entire history; otherwise merge so older loaded
		// pages aren't dropped.
		if (quiescent && !result.data.hasMore) {
			this.messages = fresh;
		} else {
			let merged = this.messages;
			for (const message of fresh) {
				merged = upsertMessage(merged, message);
			}
			this.messages = merged;
		}
		this.hasMore = result.data.hasMore;
		writeHistory(this.conversationId, this.messages);
	}

	async #gapFill(): Promise<void> {
		const since = lastInsertedAt(this.messages);
		if (!since) return this.#loadHistory();

		const result = await messagesSince(this.conversationId, since);
		if (result.success) {
			for (const message of result.data) {
				this.messages = upsertMessage(this.messages, message);
			}
		}
	}

	/**
	 * Post-turn reconcile: merge fresh rows into local state (instead of
	 * replacing it, which would drop a still-streaming provisional message if
	 * PubSub delivery raced persistence) and only then retire the transient
	 * tool cards — their persisted tool-event messages are now present, so
	 * the cards don't flicker out before their replacements render.
	 *
	 * Fetches only messages since the turn baseline (messages_since is
	 * inclusive, duplicates merge away); full history only when no baseline
	 * exists (e.g. reconnect mid-turn).
	 */
	async #reconcileAfterResponse(): Promise<void> {
		this.#flushChunks();
		const since = this.#turnBaseline;
		this.#turnBaseline = null;

		let fresh: ChatMessage[];
		if (since) {
			const result = await messagesSince(this.conversationId, since);
			if (!result.success) return;
			fresh = result.data;
		} else {
			const result = await messageHistoryPage(this.conversationId, { limit: PAGE_SIZE });
			if (!result.success) return;
			fresh = result.data.messages;
		}

		let merged = this.messages;
		for (const message of fresh) {
			merged = upsertMessage(merged, message);
		}
		this.messages = merged;
		this.liveTools = [];
	}

	async #join(): Promise<void> {
		const socket = await getSocket();
		if (!socket) {
			this.connection = 'offline';
			return;
		}

		this.#channel = socket.channel(`conversation:${this.conversationId}`);
		this.#bindEvents(this.#channel);

		this.#channel
			.join()
			.receive('ok', () => {
				this.connection = 'live';
				if (this.#joinedOnce) void this.#gapFill();
				this.#joinedOnce = true;
				// Seed the context-window donut once per join; `context.updated`
				// keeps it fresh thereafter.
				void this.#refreshContextWindow();
			})
			.receive('error', () => {
				this.connection = 'offline';
			})
			.receive('timeout', () => {
				this.connection = 'offline';
			});

		this.#channel.onClose(() => {
			if (!this.accessRevoked) this.connection = 'connecting';
		});
	}

	#bindEvents(channel: Channel): void {
		channel.on('text.chunk', (payload: Record<string, unknown>) => {
			this.#queueChunk(payload, 'text');
		});

		channel.on('thinking.chunk', (payload: Record<string, unknown>) => {
			this.#queueChunk(payload, 'thinking');
		});

		channel.on('text.complete', (payload: Record<string, unknown>) => {
			this.#flushChunks();
			// The answer text is committed; the persisted message now carries the
			// reasoning summary, so retire the live reasoning indicator.
			this.streamingThinking = '';
			this.messages = completeStreamMessage(this.messages, payload);
		});

		channel.on('state.change', (payload: Record<string, unknown>) => {
			const state = typeof payload.state === 'string' ? payload.state : '';
			// `idle` is the only terminal state; everything else means the turn is
			// still active, so keep the stuck-turn watchdog armed (text/tool signals
			// re-arm it too). Whether the *thinking indicator* shows mirrors the
			// workbench derive_thinking_state `waiting` flag (streaming and
			// processing are active-but-not-waiting, the answer is arriving).
			// Crucially this never touches streamingThinking: the backend emits a
			// state.change(:reasoning) before every thinking.chunk, so clearing it
			// here would unmount/remount the reasoning box on each delta.
			// `busy` gates enqueue-vs-send for the whole turn (any non-idle state).
			if (state === 'idle') {
				this.agentThinking = false;
				this.busy = false;
				this.#clearWatchdog();
			} else {
				this.agentThinking = WAITING_STATES.has(state);
				this.busy = true;
				this.#turnBaseline ??= lastInsertedAt(this.messages);
				this.#armWatchdog();
			}
		});

		channel.on('response.complete', () => {
			this.agentThinking = false;
			this.busy = false;
			this.streamingThinking = '';
			this.#clearWatchdog();
			void this.#reconcileAfterResponse();
		});

		channel.on('error', (payload: Record<string, unknown>) => {
			this.agentThinking = false;
			this.busy = false;
			this.streamingThinking = '';
			this.#clearWatchdog();
			// Classic LimitExceededModal: plan-limit denials get a dialog, not
			// just an inline error event.
			if (payload.error_type === 'limit_exceeded') {
				this.limitExceeded =
					typeof payload.error_message === 'string' && payload.error_message !== ''
						? payload.error_message
						: 'Your plan limit was reached.';
			}
			// A failed turn never sends response.complete — reconcile here too,
			// so partially persisted output appears, the turn baseline resets,
			// and the transient tool cards don't linger forever.
			void this.#reconcileAfterResponse();
		});

		for (const event of [
			'tool.start',
			'tool.progress',
			'tool.complete',
			'tool.step.start',
			'tool.step.progress',
			'tool.step.complete'
		]) {
			channel.on(event, (payload: Record<string, unknown>) => {
				// A turn can open with a tool call before any text streams.
				this.#turnBaseline ??= lastInsertedAt(this.messages);
				this.liveTools = applyToolEvent(this.liveTools, event, payload);
				this.#armWatchdog();
				// start_service completion opens the service pane (classic parity).
				if (event === 'tool.complete' && payload.tool_name === 'start_service') {
					this.onCompanionRequest?.({ type: 'service', id: this.conversationId });
				}
			});
		}

		for (const event of [
			'message.create',
			'message.send_user_message',
			'message.upsert_response',
			'message.create_event',
			'message.upsert_event'
		]) {
			channel.on(event, (payload: Record<string, unknown>) => {
				const message = messageFromBroadcast(payload);
				if (!message) return;
				this.#flushChunks();
				this.messages = upsertMessage(this.messages, message);
				// A persisted tool event row replaces its in-flight live card, so
				// drop the matching live tool to avoid a double render.
				if (message.toolCallData) {
					this.liveTools = dropPersistedTools(this.liveTools, this.messages);
				}
			});
		}

		// Deletes by any participant drop the row live (id-only broadcast).
		channel.on('message.destroy', (payload: Record<string, unknown>) => {
			const id = String(payload.id ?? '');
			if (id) this.messages = this.messages.filter((message) => message.id !== id);
		});

		// Mid-turn queue lifecycle: enqueue adds, flush/remove drop. The payload
		// may arrive string-keyed/snake_case, so normalize id/text defensively
		// (matching how other handlers in this file read broadcasts).
		channel.on('queued.enqueue_message', (payload: Record<string, unknown>) => {
			const id = String(payload.id ?? '');
			if (!id) return;
			const text = typeof payload.text === 'string' ? payload.text : '';
			const insertedAt =
				typeof payload.inserted_at === 'string'
					? payload.inserted_at
					: typeof payload.insertedAt === 'string'
						? payload.insertedAt
						: undefined;
			const createdById =
				typeof payload.created_by_id === 'string'
					? payload.created_by_id
					: typeof payload.createdById === 'string'
						? payload.createdById
						: undefined;
			this.queued = applyQueuedEvent(this.queued, 'enqueue_message', {
				id,
				text,
				insertedAt,
				createdById
			});
		});

		for (const event of ['queued.flush_queued', 'queued.remove_queued'] as const) {
			channel.on(event, (payload: Record<string, unknown>) => {
				const id = String(payload.id ?? '');
				if (!id) return;
				const reducerEvent = event === 'queued.flush_queued' ? 'flush_queued' : 'remove_queued';
				this.queued = applyQueuedEvent(this.queued, reducerEvent, { id });
			});
		}

		channel.on('typing.user_typing', (payload: Record<string, unknown>) => {
			const userId = String(payload.user_id ?? '');
			const userName = String(payload.user_name ?? '');
			const isTyping = payload.is_typing === true;

			const without = this.typing.filter((entry) => entry.userId !== userId);
			this.typing = isTyping ? [...without, { userId, userName }] : without;
		});

		channel.on('access.revoked', () => {
			this.accessRevoked = true;
			this.connection = 'offline';
		});

		// Agent tools ask the workbench to open a brain page (after every
		// successful write_page). Same trigger the classic ConversationView
		// handles; the revision bump refreshes an already-open companion.
		channel.on('ui.open_brain_pane', (payload: Record<string, unknown>) => {
			const pageId = typeof payload.page_id === 'string' ? payload.page_id : '';
			this.brainRevision += 1;
			if (pageId) this.onCompanionRequest?.({ type: 'brain_page', id: pageId });
		});

		// Draft lifecycle: created auto-opens the companion (classic parity —
		// the agent's write_draft should surface its document); updates bump
		// the revision so an open companion refetches content.
		channel.on('draft.created', (payload: Record<string, unknown>) => {
			const draft = payload.draft as Record<string, unknown> | undefined;
			const draftId = typeof draft?.id === 'string' ? draft.id : '';
			this.draftRevision += 1;
			if (draftId) this.onCompanionRequest?.({ type: 'draft', id: draftId });
		});

		for (const event of ['draft.updated', 'draft.refined']) {
			channel.on(event, () => {
				this.draftRevision += 1;
			});
		}

		// Context-window changes (turn completion, clear, compact, strategy
		// change). Refetch rather than trusting the event payload shape: the
		// robust LiveView approach.
		channel.on('context.updated', () => {
			void this.#refreshContextWindow();
		});
	}

	/** Re-reads the persisted context-window snapshot into reactive state. */
	async #refreshContextWindow(): Promise<void> {
		const result = await getContextWindow(this.conversationId);
		if (result.success) this.contextWindow = result.data;
	}

	/**
	 * Clears the live context window (older messages stay in the transcript but
	 * are no longer sent to the model). The channel broadcast also refreshes the
	 * snapshot; updating from the result here is idempotent and avoids a flash.
	 */
	async clearContext(): Promise<void> {
		const result = await clearContextWindow(this.conversationId);
		if (result.success) this.contextWindow = result.data;
	}

	/** Requests compaction of older messages to free up the window. */
	async compactContext(): Promise<void> {
		const result = await compactContextWindow(this.conversationId);
		if (result.success) this.contextWindow = result.data;
	}

	/** Sets (or clears) the per-conversation strategy override. */
	async setContextStrategy(strategy: 'rolling' | 'compact' | null): Promise<void> {
		const result = await setContextStrategy(this.conversationId, strategy);
		if (result.success) this.contextWindow = result.data;
	}
}
