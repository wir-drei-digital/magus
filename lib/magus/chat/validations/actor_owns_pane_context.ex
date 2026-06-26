defmodule Magus.Chat.Validations.ActorOwnsPaneContext do
  @moduledoc """
  Shared validation for per-user pane state resources (`Magus.Chat.PaneState`,
  `Magus.Plan.TaskPaneState`). Ensures the `user_id` argument matches the actor
  and that the actor can access the target conversation.
  """

  use Ash.Resource.Validation

  alias Magus.Chat.Checks.ActorCanAccessConversation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    case context.actor do
      %{id: actor_id} = actor ->
        argument_user_id = Ash.Changeset.get_argument(changeset, :user_id)
        conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)

        cond do
          argument_user_id != actor_id ->
            {:error, field: :user_id, message: "must match the actor"}

          is_nil(conversation_id) ->
            {:error, field: :conversation_id, message: "is required"}

          ActorCanAccessConversation.can_access?(actor, conversation_id) ->
            :ok

          true ->
            {:error, field: :conversation_id, message: "must be accessible to the actor"}
        end

      _ ->
        {:error, field: :user_id, message: "actor is required"}
    end
  end
end
