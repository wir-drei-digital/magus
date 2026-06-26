defmodule Magus.Chat.Checks.ConversationVisibleToActor do
  @moduledoc """
  FilterCheck that restricts per-user pane-state records to rows the actor can
  see: `user_id` matches the actor and the conversation is owned, joined, or
  shared into the actor's workspace.
  """

  use Ash.Policy.FilterCheck

  require Ash.Query

  @impl true
  def describe(_opts), do: "conversation is visible to actor"

  @impl true
  def filter(actor, _authorizer, _opts) do
    actor_id = actor && actor.id

    expr(
      not is_nil(^actor_id) and
        user_id == ^actor_id and
        (conversation.user_id == ^actor_id or
           exists(conversation.members, user_id == ^actor_id and not is_nil(accepted_at)) or
           (not is_nil(conversation.workspace_id) and
              conversation.is_shared_to_workspace == true and
              exists(conversation.workspace.members, is_active == true and user_id == ^actor_id)))
    )
  end
end
