import type { ConversationSummary } from '$lib/ash/api';

/**
 * Date grouping for the chat nav's unfiled conversations, mirroring the
 * classic `group_conversations_by_date/1` (UTC calendar-date boundaries,
 * sorted by last message timestamp, empty groups dropped).
 */

export type DateGroup = { label: string; conversations: ConversationSummary[] };

/** Last message wins; conversations without messages fall back to updated_at. */
export function navTimestamp(conversation: ConversationSummary): string {
	return conversation.lastMessageAt ?? conversation.updatedAt;
}

function utcDayNumber(date: Date): number {
	return Math.floor(
		Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()) / 86_400_000
	);
}

const GROUPS: { label: string; maxDaysAgo: number }[] = [
	{ label: 'Today', maxDaysAgo: 0 },
	{ label: 'Yesterday', maxDaysAgo: 1 },
	{ label: 'Last 3 Days', maxDaysAgo: 3 },
	{ label: 'Last 7 Days', maxDaysAgo: 7 },
	{ label: 'Last 30 Days', maxDaysAgo: 30 },
	{ label: 'Older', maxDaysAgo: Infinity }
];

export function groupConversationsByDate(
	conversations: ConversationSummary[],
	now: Date = new Date()
): DateGroup[] {
	const today = utcDayNumber(now);

	const groups = GROUPS.map((group) => ({
		label: group.label,
		conversations: [] as ConversationSummary[]
	}));

	for (const conversation of conversations) {
		const daysAgo = today - utcDayNumber(new Date(navTimestamp(conversation)));
		const index = GROUPS.findIndex((group) => daysAgo <= group.maxDaysAgo);
		groups[index >= 0 ? index : GROUPS.length - 1].conversations.push(conversation);
	}

	for (const group of groups) {
		group.conversations.sort((a, b) => navTimestamp(b).localeCompare(navTimestamp(a)));
	}

	return groups.filter((group) => group.conversations.length > 0);
}

/**
 * Caps the total number of conversations across groups (groups are assumed
 * newest-first, as groupConversationsByDate returns them). The nav shows
 * only the most recent unfiled conversations; older ones live in the
 * history view.
 */
export function capConversationGroups(groups: DateGroup[], max: number): DateGroup[] {
	const capped: DateGroup[] = [];
	let remaining = max;
	for (const group of groups) {
		if (remaining <= 0) break;
		const conversations = group.conversations.slice(0, remaining);
		remaining -= conversations.length;
		capped.push({ label: group.label, conversations });
	}
	return capped;
}
