defmodule Magus.Drafts.Draft.Checks.ActorCanAccessConversation do
  @moduledoc """
  Policy check that verifies the actor can access the target conversation.

  Delegates to `Magus.Chat.get_conversation/2` which applies its own
  read policies, so this check passes only when the actor owns the
  conversation or is an accepted member.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor can access the conversation"

  @impl true
  def match?(nil, _authorizer, _context), do: false

  def match?(actor, %{changeset: changeset}, _context) do
    conversation_id =
      Ash.Changeset.get_argument(changeset, :conversation_id) ||
        Ash.Changeset.get_attribute(changeset, :conversation_id)

    case Magus.Chat.get_conversation(conversation_id, actor: actor) do
      {:ok, _conversation} -> true
      _ -> false
    end
  end

  def match?(_actor, _authorizer, _context), do: false
end
