/**
 * Pure chat-event logic (runes-free, unit-tested in node).
 *
 * Two input planes with different casings, normalized here:
 *  - RPC reads (camelCase): ChatMessage from ash_rpc
 *  - Channel pushes (snake_case, frozen broadcast shapes): agent signals and
 *    `message.<action>` persistence events from ConversationChannel
 */
import type { ChatMessage } from '$lib/ash/api';

export type ToolStatus = 'running' | 'success' | 'error';

/** A sub-step within a tool call (tool.step.start/progress/complete), with
 *  streaming content. The hierarchy is tool → steps → streaming content. */
export type ToolStep = {
	stepId: string;
	index: number;
	label: string;
	content: string;
	status: ToolStatus;
	summary: string | null;
};

export type LiveToolEvent = {
	eventId: string;
	toolName: string;
	displayName: string;
	status: ToolStatus;
	progress: string | null;
	outputSummary: string | null;
	durationMs: number | null;
	inputs: Record<string, unknown> | null;
	steps: ToolStep[];
	/** When tool.start arrived (client clock); orders the tool in the stream. */
	startedAt: string;
};

/** Normalized shape the collapsible ToolCard renders, fed from either a live
 *  tool event (streaming) or a persisted tool_call_data row (reload). */
export type ToolView = {
	status: ToolStatus;
	toolName: string;
	displayName: string;
	summary: string | null;
	durationMs: number | null;
	inputs: Record<string, unknown> | null;
	steps: ToolStep[];
	output: unknown;
	/** Persisted rows default collapsed; a live running tool defaults open. */
	persisted: boolean;
};

type RawPayload = Record<string, unknown>;

const str = (value: unknown): string => (typeof value === 'string' ? value : '');
const strOrNull = (value: unknown): string | null => (typeof value === 'string' ? value : null);

/** Normalize a snake_case `message.<action>` channel payload into a ChatMessage. */
export function messageFromBroadcast(payload: RawPayload): ChatMessage | null {
	const id = str(payload.id);
	if (!id) return null;

	return {
		id,
		text: str(payload.text),
		source: payload.source === 'agent' ? 'agent' : 'user',
		role: payload.source === 'agent' ? 'agent' : 'user',
		messageType: (strOrNull(payload.message_type) as ChatMessage['messageType']) ?? 'message',
		status: payload.complete === false ? 'streaming' : 'complete',
		insertedAt: str(payload.inserted_at) || new Date().toISOString(),
		modelName: strOrNull(payload.model_name),
		toolCallData: (payload.tool_call_data as ChatMessage['toolCallData']) ?? null,
		citations: (payload.citations as ChatMessage['citations']) ?? null,
		reasoningSummary: (payload.reasoning_summary as ChatMessage['reasoningSummary']) ?? null,
		metadata: (payload.metadata as ChatMessage['metadata']) ?? {},
		attachments: Array.isArray(payload.attachments) ? payload.attachments.map(String) : [],
		disabled: payload.disabled === true
	};
}

/** Insert-or-update by id, keeping ascending insertedAt order. */
export function upsertMessage(messages: ChatMessage[], message: ChatMessage): ChatMessage[] {
	const index = messages.findIndex((existing) => existing.id === message.id);
	if (index >= 0) {
		const next = messages.slice();
		next[index] = {
			...next[index],
			...message,
			// A later broadcast without attachments must not clobber known ones.
			attachments: message.attachments?.length
				? message.attachments
				: (next[index].attachments ?? []),
			// Likewise for metadata (a tool/event upsert omits it → {}).
			metadata:
				message.metadata && Object.keys(message.metadata).length
					? message.metadata
					: (next[index].metadata ?? {})
		};
		return next;
	}
	return [...messages, message].sort((a, b) => a.insertedAt.localeCompare(b.insertedAt));
}

/** Apply a streaming text.chunk / thinking.chunk: payload.text is the full accumulated text. */
export function applyStreamChunk(
	messages: ChatMessage[],
	payload: RawPayload,
	kind: 'text' | 'thinking'
): ChatMessage[] {
	const messageId = str(payload.message_id);
	if (!messageId) return messages;

	const index = messages.findIndex((existing) => existing.id === messageId);
	const fullText = str(payload.text);

	if (index >= 0) {
		const next = messages.slice();
		const current = next[index];
		next[index] =
			kind === 'text'
				? { ...current, text: fullText, status: 'streaming' }
				: { ...current, status: 'streaming' };
		return next;
	}

	// Thinking chunks arriving before any text chunk have no bubble to attach
	// to and are dropped — the store still flips `agentThinking`, so the user
	// sees the generic indicator. Streaming a dedicated reasoning UI is
	// deferred (iteration 3+).
	if (kind !== 'text') return messages;

	return [
		...messages,
		{
			id: messageId,
			text: fullText,
			source: 'agent',
			role: 'agent',
			messageType: 'message',
			status: 'streaming',
			insertedAt: new Date().toISOString(),
			modelName: strOrNull(payload.custom_agent_name),
			toolCallData: null,
			citations: null,
			reasoningSummary: null,
			metadata: {},
			attachments: [],
			disabled: false
		}
	];
}

export function completeStreamMessage(messages: ChatMessage[], payload: RawPayload): ChatMessage[] {
	const messageId = str(payload.message_id);
	if (!messageId) return messages;

	return messages.map((existing) =>
		existing.id === messageId
			? { ...existing, text: str(payload.text) || existing.text, status: 'complete' }
			: existing
	);
}

export function applyToolEvent(
	tools: LiveToolEvent[],
	event: string,
	payload: RawPayload
): LiveToolEvent[] {
	const eventId = str(payload.event_id);
	if (!eventId) return tools;

	switch (event) {
		case 'tool.start': {
			const item: LiveToolEvent = {
				eventId,
				toolName: str(payload.tool_name),
				displayName: str(payload.display_name) || str(payload.tool_name),
				status: 'running',
				progress: null,
				outputSummary: null,
				durationMs: null,
				inputs:
					payload.inputs && typeof payload.inputs === 'object'
						? (payload.inputs as Record<string, unknown>)
						: null,
				steps: [],
				startedAt: new Date().toISOString()
			};
			if (tools.some((tool) => tool.eventId === eventId)) return tools;
			return [...tools, item];
		}
		case 'tool.progress': {
			const data = (payload.data ?? {}) as RawPayload;
			const progress = strOrNull(data.message) ?? strOrNull(payload.progress_type);
			return tools.map((tool) => (tool.eventId === eventId ? { ...tool, progress } : tool));
		}
		case 'tool.step.start': {
			const stepId = str(payload.step_id);
			if (!stepId) return tools;
			const step: ToolStep = {
				stepId,
				index: typeof payload.step_index === 'number' ? payload.step_index : 0,
				label: str(payload.label),
				content: '',
				status: 'running',
				summary: null
			};
			return tools.map((tool) =>
				tool.eventId === eventId && !tool.steps.some((existing) => existing.stepId === stepId)
					? { ...tool, steps: [...tool.steps, step] }
					: tool
			);
		}
		case 'tool.step.progress': {
			// `mode` is "append" (default) or "replace"; content streams in.
			const stepId = str(payload.step_id);
			const chunk = str(payload.content);
			const replace = payload.mode === 'replace';
			return tools.map((tool) =>
				tool.eventId === eventId
					? {
							...tool,
							steps: tool.steps.map((step) =>
								step.stepId === stepId
									? { ...step, content: replace ? chunk : step.content + chunk }
									: step
							)
						}
					: tool
			);
		}
		case 'tool.step.complete': {
			const stepId = str(payload.step_id);
			const failed = payload.status === 'error';
			return tools.map((tool) =>
				tool.eventId === eventId
					? {
							...tool,
							steps: tool.steps.map((step) =>
								step.stepId === stepId
									? {
											...step,
											status: failed ? 'error' : 'success',
											summary: strOrNull(payload.summary)
										}
									: step
							)
						}
					: tool
			);
		}
		case 'tool.complete': {
			// The server's `status` ("success" | "error") is authoritative;
			// `error` presence is only a fallback for payloads without one.
			const failed =
				payload.status === 'error' || (payload.status == null && Boolean(payload.error));
			return tools.map((tool) =>
				tool.eventId === eventId
					? {
							...tool,
							status: failed ? 'error' : 'success',
							outputSummary: strOrNull(payload.output_summary),
							durationMs: typeof payload.duration_ms === 'number' ? payload.duration_ms : null
						}
					: tool
			);
		}
		default:
			return tools;
	}
}

/** A live (streaming) tool event → the ToolCard view model. */
export function toolViewFromLive(tool: LiveToolEvent): ToolView {
	return {
		status: tool.status,
		toolName: tool.toolName,
		displayName: tool.displayName,
		summary: tool.status === 'running' ? (tool.progress ?? null) : tool.outputSummary,
		durationMs: tool.durationMs,
		inputs: tool.inputs,
		steps: tool.steps,
		output: undefined,
		persisted: false
	};
}

/**
 * A persisted tool_call_data row (snake_case, from the message bridge / RPC) →
 * the ToolCard view model. Persisted rows carry the full output and inputs but
 * not the ephemeral steps (those are live-only, matching the workbench).
 */
export function toolViewFromPersisted(data: Record<string, unknown>): ToolView {
	const rawStatus = str(data.status);
	const status: ToolStatus =
		rawStatus === 'error' || rawStatus === 'cancelled' ? 'error' : 'success';
	return {
		status,
		toolName: str(data.tool_name),
		displayName: str(data.display_name) || str(data.tool_name) || 'Tool',
		summary: strOrNull(data.output_summary),
		durationMs: null,
		inputs:
			data.inputs && typeof data.inputs === 'object'
				? (data.inputs as Record<string, unknown>)
				: null,
		steps: [],
		output: data.output ?? null,
		persisted: true
	};
}

/**
 * Latest insertedAt across regular messages — the gap-fill cursor for
 * reconnects. Restricted to `messageType === 'message'` because the server's
 * `messages_since` only returns regular messages: an event/tool message's
 * (possibly client-synthesized) timestamp would push the cursor past regular
 * messages the gap-fill still needs.
 */
export function lastInsertedAt(messages: ChatMessage[]): string | null {
	let max: string | null = null;
	for (const message of messages) {
		if (message.messageType !== 'message') continue;
		if (max === null || message.insertedAt > max) max = message.insertedAt;
	}
	return max;
}

/**
 * Whether a message earns a bubble. Agent turns that only ran tools persist
 * a text row with empty text — classic skips those, and an empty bubble
 * reads as a glitch. Streaming/pending rows always render (their content is
 * arriving), as do errors (the failure state is the content).
 */
export function isRenderableMessage(message: ChatMessage): boolean {
	if (message.messageType !== 'message') return true;
	if (message.status === 'streaming' || message.status === 'pending') return true;
	if (message.status === 'error') return true;
	return message.text.trim() !== '' || (message.attachments ?? []).length > 0;
}

/** The persisted-event id carried by a tool message (matches LiveToolEvent.eventId). */
function persistedToolId(message: ChatMessage): string | null {
	const id = message.toolCallData?.id;
	return typeof id === 'string' ? id : null;
}

/**
 * Drop any live tool whose persisted twin just landed in `messages`. A live
 * tool (tool.start) and its persisted event row (message.upsert_event) share an
 * id; without this the card renders twice until the post-turn reconcile clears
 * liveTools. Called right after a message upsert.
 */
export function dropPersistedTools(
	tools: LiveToolEvent[],
	messages: ChatMessage[]
): LiveToolEvent[] {
	if (tools.length === 0) return tools;
	const persisted = new Set<string>();
	for (const message of messages) {
		const id = persistedToolId(message);
		if (id) persisted.add(id);
	}
	const next = tools.filter((tool) => !persisted.has(tool.eventId));
	return next.length === tools.length ? tools : next;
}

export type ChatStreamItem =
	| { kind: 'message'; key: string; sortAt: string; message: ChatMessage }
	| { kind: 'tool'; key: string; sortAt: string; tool: LiveToolEvent };

/**
 * One time-ordered render stream of messages + in-flight tools, so a running
 * tool never renders above (or below) a message it didn't precede. Live tools
 * are positioned by their start time and de-duplicated against any persisted
 * twin already in `messages` (belt-and-suspenders alongside dropPersistedTools).
 */
export function buildChatStream(
	messages: ChatMessage[],
	liveTools: LiveToolEvent[]
): ChatStreamItem[] {
	const persisted = new Set<string>();
	for (const message of messages) {
		const id = persistedToolId(message);
		if (id) persisted.add(id);
	}

	const items: ChatStreamItem[] = [];
	for (const message of messages) {
		if (!isRenderableMessage(message)) continue;
		items.push({ kind: 'message', key: message.id, sortAt: message.insertedAt, message });
	}
	for (const tool of liveTools) {
		if (persisted.has(tool.eventId)) continue;
		items.push({ kind: 'tool', key: `tool:${tool.eventId}`, sortAt: tool.startedAt, tool });
	}

	// Array.sort is stable, so equal timestamps keep insertion order (messages
	// before tools), which is the sensible tie-break for a same-instant pair.
	return items.sort((a, b) => a.sortAt.localeCompare(b.sortAt));
}
