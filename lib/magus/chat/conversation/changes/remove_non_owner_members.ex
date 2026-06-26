defmodule Magus.Chat.Conversation.Changes.RemoveNonOwnerMembers do
  @moduledoc """
  Removes all non-owner members from a conversation when multiplayer is disabled.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, conversation ->
      require Ash.Query

      result =
        Magus.Chat.ConversationMember
        |> Ash.Query.filter(conversation_id == ^conversation.id and role != :owner)
        |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: true)

      if result.error_count > 0 do
        Logger.warning(
          "Failed to remove #{result.error_count} members when disabling multiplayer for conversation #{conversation.id}"
        )
      end

      {:ok, conversation}
    end)
  end
end
