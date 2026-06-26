defmodule Magus.Chat.ConversationInviteLink.Checks.IsConversationOwner do
  @moduledoc """
  Custom policy check for create actions on ConversationInviteLink.

  Verifies that the actor is an owner of the conversation specified by the
  `conversation_id` argument on the changeset. This is necessary because
  Ash cannot use relationship-traversal filters to authorize create actions
  (the record doesn't exist yet).
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is an owner of the target conversation"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)

    if is_nil(conversation_id) do
      false
    else
      require Ash.Query

      Magus.Chat.ConversationMember
      |> Ash.Query.filter(
        conversation_id == ^conversation_id and
          user_id == ^actor.id and
          role == :owner
      )
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, %Magus.Chat.ConversationMember{}} -> true
        _ -> false
      end
    end
  end

  def match?(_actor, _context, _opts), do: false
end
