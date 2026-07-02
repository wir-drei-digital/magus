/**
 * Pure logic for the "broken model selection" remediation flow (runes-free,
 * unit-tested in node).
 *
 * Task 1 (backend) persists an `:event` chat message whose `tool_call_data`
 * carries STRING keys, delivered verbatim over the ["messages", conversation_id]
 * PubSub topic and message fetches:
 *
 *   kind: always "broken_model_selection"
 *   requested_by: "id" | "key" (how the stale selection was expressed)
 *   requested_value: the stale ask
 *   fallback_key: the model actually resolved (may rarely be null)
 *   scope: "conversation" | "user" (which selection to reset)
 *
 * The blocked user message produced no agent response, so remediation clears the
 * scoped selection and re-sends the original text through the normal send path.
 */

export interface BrokenSelectionPayload {
	kind: string;
	requested_by: string;
	requested_value: string;
	/** May rarely be null when nothing usable resolved. */
	fallback_key: string | null;
	scope: string;
}

/** Type guard: is this `tool_call_data` the Task 1 broken-selection payload? */
export function isBrokenSelection(payload: unknown): payload is BrokenSelectionPayload {
	return (
		!!payload &&
		typeof payload === 'object' &&
		(payload as { kind?: unknown }).kind === 'broken_model_selection'
	);
}

/**
 * Which selection the reset clears: the USER default vs the CONVERSATION pin.
 * Anything other than "user" resets the conversation (the backend only ever
 * emits "conversation" | "user", so this is a safe, closed mapping).
 */
export function resetTarget(payload: BrokenSelectionPayload): 'conversation' | 'user' {
	return payload.scope === 'user' ? 'user' : 'conversation';
}

/** Minimal shape needed to locate the blocked user message in the thread. */
type ThreadRow = {
	id: string;
	source: 'user' | 'agent';
	messageType: 'message' | 'event' | 'job_trigger' | 'draft_event';
	text: string;
};

/**
 * The text to re-send: the nearest prior regular user message before the
 * broken-selection event. The payload carries no text, and the blocked message
 * is always the most recent user turn preceding the event (the agent never
 * replied), so we scan backwards from the event for the first user `:message`.
 * Returns null when the event id is unknown or no such user message exists.
 */
export function precedingUserText<Row extends ThreadRow>(
	messages: Row[],
	eventId: string
): string | null {
	const eventIndex = messages.findIndex((message) => message.id === eventId);
	if (eventIndex < 0) return null;

	for (let index = eventIndex - 1; index >= 0; index--) {
		const message = messages[index];
		if (message.source === 'user' && message.messageType === 'message') {
			return message.text;
		}
	}
	return null;
}
