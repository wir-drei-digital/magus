defmodule Magus.Sandbox.Sandbox.Checks.OwnsConversation do
  @moduledoc """
  Policy check that verifies the actor owns the conversation they're creating a sandbox for.

  This prevents users from creating sandboxes for conversations they don't own.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor owns the conversation"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: changeset}, _opts) do
    conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)

    if is_nil(conversation_id) do
      false
    else
      # Verify the actor owns this conversation
      case Magus.Chat.get_conversation(conversation_id, actor: actor) do
        {:ok, conversation} ->
          # Check that the actor is the owner of the conversation
          conversation.user_id == actor.id

        {:error, _} ->
          false
      end
    end
  end

  def match?(_actor, _context, _opts), do: false
end
