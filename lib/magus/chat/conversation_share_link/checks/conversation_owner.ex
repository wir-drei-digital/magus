defmodule Magus.Chat.ConversationShareLink.Checks.ConversationOwner do
  @moduledoc """
  Custom check to verify the actor owns the conversation.

  For create actions, checks the conversation_id argument.
  For other actions, checks the loaded conversation relationship.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor owns the conversation"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset} = _context, _opts) do
    # For create actions, check the argument
    conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)

    if conversation_id do
      case Magus.Chat.Conversation
           |> Ash.get(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          conversation.user_id == actor.id

        _ ->
          false
      end
    else
      false
    end
  end

  def match?(actor, %{query: _query, resource: resource} = context, _opts) do
    # For read/update/destroy on existing records
    # This is handled by the expression-based policy, so return true
    # to let the expression policy handle it
    record = Map.get(context, :subject)

    if record && record.__struct__ == resource do
      record = Ash.load!(record, [:conversation], authorize?: false)
      record.conversation.user_id == actor.id
    else
      # For queries, let the expression policy handle it
      true
    end
  end

  def match?(_actor, _context, _opts), do: false
end
