defmodule Magus.Chat.Message.Checks.WorkspaceConversationAccess do
  @moduledoc """
  Authorizes actors who have a workspace-grant on the message's parent
  conversation.

  Mirrors `Magus.Workspaces.AccessCheck` but resolves through `conversation_id`
  instead of the resource's own `id`. Lets workspace members read messages in
  conversations shared to their workspace, without requiring multiplayer
  membership.

  Inlined here (rather than parameterizing `AccessCheck`) because `parent/1`
  in `expr/1` doesn't accept a dynamic field reference at compile time. A
  follow-up will fold this into a generic check after `Magus.Workspaces.ResourceAccess`'s
  read policy is rewritten so inline `exists(ResourceAccess, ...)` is safe to
  use in any policy/filter context.
  """

  use Ash.Policy.FilterCheck

  alias Magus.Workspaces.AccessCheck

  @impl true
  def describe(_opts), do: "actor has workspace access to the parent conversation"

  @impl true
  def filter(actor, _authorizer, _opts) do
    actor_id = AccessCheck.actor_user_id(actor)
    workspace_ids = AccessCheck.active_workspace_ids(actor_id)

    build_filter(actor_id, workspace_ids)
  end

  defp build_filter(nil, _), do: expr(false)

  defp build_filter(_actor_id, []), do: expr(false)

  defp build_filter(_actor_id, workspace_ids) do
    # Traverse via the `conversation` belongs_to. Ash joins conversations and
    # evaluates the `is_shared_to_workspace` calc in the conversation's own
    # context, so the calc's `parent(id)`/`parent(workspace_id)` references
    # resolve correctly.
    #
    # Direct user-grants on conversations aren't covered here because
    # `share_to_team` only creates `:workspace` grants today. If we add
    # per-user conversation sharing, augment this check.
    expr(
      conversation.is_shared_to_workspace == true and
        conversation.workspace_id in ^workspace_ids
    )
  end
end
