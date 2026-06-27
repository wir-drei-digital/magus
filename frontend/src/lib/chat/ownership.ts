/**
 * Owner-only conversation controls — the context-window donut's Clear / Compact /
 * strategy actions — are gated on this, mirroring the classic
 * `is_owner = conv.user_id == user.id` check (conversation_view.ex) and the
 * workbench's `:if={@is_owner}` control row (context_indicator_component.ex).
 *
 * The server still enforces ownership on the underlying actions; this only
 * decides what to render, so a non-owner member sees a read-only donut instead
 * of controls that would error on click. Unknown ownership (conversation not yet
 * loaded, or no signed-in user) is treated as not-owner: safer to hide a control
 * briefly than to show a mutating action to someone who can't use it.
 */
export function isConversationOwner(
	conversation: { userId: string } | null | undefined,
	currentUserId: string | null | undefined
): boolean {
	return !!conversation && !!currentUserId && conversation.userId === currentUserId;
}
