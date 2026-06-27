/**
 * Conversation presence view-model. The backend `presence.state` channel push
 * carries the deduped viewer list from `Magus.Presence`; these helpers shape it
 * for the avatar UI (exclude self + hidden, cap with an overflow count).
 */

export type PresenceViewer = {
	userId: string;
	name: string;
	avatarPath: string | null;
	color: string;
	visible: boolean;
};

/** Raw viewer as pushed by the channel (snake_case, from Elixir). */
export type RawPresenceViewer = {
	user_id?: string;
	name?: string | null;
	avatar_path?: string | null;
	color?: string | null;
	visible?: boolean;
};

export function normalizeViewers(raw: RawPresenceViewer[] | undefined | null): PresenceViewer[] {
	if (!Array.isArray(raw)) return [];
	return raw
		.filter((v): v is RawPresenceViewer & { user_id: string } => typeof v.user_id === 'string')
		.map((v) => ({
			userId: v.user_id,
			name: v.name ?? '',
			avatarPath: v.avatar_path ?? null,
			color: v.color ?? '#888888',
			visible: v.visible ?? true
		}));
}

/** Viewers to display: drop self + hidden, ordered deterministically. */
export function visibleOthers(
	viewers: PresenceViewer[],
	selfUserId: string | null | undefined
): PresenceViewer[] {
	return viewers
		.filter((v) => v.visible && v.userId !== selfUserId)
		.sort((a, b) => a.userId.localeCompare(b.userId));
}

/** Up to `max` viewers to render, plus the count of the remainder. */
export function viewerOverflow(
	viewers: PresenceViewer[],
	max: number
): { shown: PresenceViewer[]; extra: number } {
	if (viewers.length <= max) return { shown: viewers, extra: 0 };
	return { shown: viewers.slice(0, max), extra: viewers.length - max };
}

/** 1-2 char fallback when a viewer has no avatar image. */
export function viewerInitials(viewer: { name: string }): string {
	const parts = viewer.name.trim().split(/\s+/).filter(Boolean);
	if (parts.length === 0) return '?';
	if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
	return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}
