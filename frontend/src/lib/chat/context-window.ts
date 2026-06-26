import type { ChatMessage } from '$lib/ash/api';

/**
 * The message BELOW which the context-floor divider should render (the divider
 * is placed just after this message), or null when there is no divider.
 *
 * This is the LAST out-of-window message — the newest message still older than
 * the floor. Anchoring to it (rather than the first in-window message) keeps the
 * divider visible the instant the floor advances past every message — e.g. right
 * after a Clear, when nothing is in-window yet — and pinned at the boundary as
 * the conversation continues, instead of riding the latest message.
 *
 * Returns null when there is no floor, no messages, or nothing is out-of-window.
 * insertedAt values are ISO-8601 UTC strings, which compare lexicographically.
 */
export function floorBoundaryMessageId(
	messages: ChatMessage[],
	windowStartAt: string | null
): string | null {
	if (!windowStartAt || messages.length === 0) return null;
	let boundary: ChatMessage | null = null;
	for (const m of messages) {
		if (m.insertedAt < windowStartAt && (!boundary || m.insertedAt > boundary.insertedAt)) {
			boundary = m;
		}
	}
	return boundary?.id ?? null;
}

/** Contextual divider label: summarized (compact strategy) vs cleared/rolling. */
export function floorDividerLabel(summaryMessageCount: number): string {
	return summaryMessageCount > 0
		? 'Older messages summarized'
		: 'Older messages are out of context';
}

/**
 * Donut denominator: the selected model's context window when a concrete model
 * is picked, else the persisted snapshot max (last-used model, or default).
 */
export function effectiveContextMax(
	selectedContextWindow: number | null,
	snapshotMax: number
): number {
	return selectedContextWindow && selectedContextWindow > 0 ? selectedContextWindow : snapshotMax;
}
