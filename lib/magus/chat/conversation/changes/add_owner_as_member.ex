defmodule Magus.Chat.Conversation.Changes.AddOwnerAsMember do
  @moduledoc """
  Adds the conversation owner as the first member with :owner role
  when multiplayer is enabled.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, conversation ->
      Magus.Chat.add_conversation_owner!(
        conversation.id,
        conversation.user_id,
        authorize?: false
      )

      {:ok, conversation}
    end)
  end
end
