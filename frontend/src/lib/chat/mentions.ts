/**
 * Pure @mention logic for the composer (runes-free, unit-tested in node).
 *
 * Mirrors the classic chat input's behavior
 * (chat_input_component.ex `mention_search`): suggestions match agents whose
 * handle starts with the query or whose name contains it, capped at 5.
 */
import type { AgentSummary } from '$lib/ash/api';

export type MentionContext = {
	/** Index of the `@` character in the text. */
	start: number;
	/** The partial handle typed after `@` (may be empty). */
	query: string;
};

const HANDLE_CHARS = /^[a-z0-9-]*$/;

/**
 * Detects an in-progress mention at the caret: an `@` at the start of the
 * text or preceded by whitespace, followed only by handle characters up to
 * the caret position.
 */
export function detectMention(text: string, caret: number): MentionContext | null {
	const upToCaret = text.slice(0, caret);
	const at = upToCaret.lastIndexOf('@');
	if (at === -1) return null;

	const before = at === 0 ? '' : upToCaret[at - 1];
	if (before !== '' && !/\s/.test(before)) return null;

	const query = upToCaret.slice(at + 1);
	if (!HANDLE_CHARS.test(query)) return null;

	return { start: at, query };
}

export function filterAgents(agents: AgentSummary[], query: string): AgentSummary[] {
	const q = query.toLowerCase();
	return agents
		.filter((agent) => agent.handle.startsWith(q) || agent.name.toLowerCase().includes(q))
		.slice(0, 5);
}

/** Replaces the in-progress mention with `@handle ` and returns the new caret. */
export function insertMention(
	text: string,
	caret: number,
	context: MentionContext,
	handle: string
): { text: string; caret: number } {
	const inserted = `@${handle} `;
	const next = text.slice(0, context.start) + inserted + text.slice(caret);
	return { text: next, caret: context.start + inserted.length };
}
