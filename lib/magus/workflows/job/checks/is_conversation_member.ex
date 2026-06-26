defmodule Magus.Workflows.Job.Checks.IsConversationMember do
  @moduledoc """
  Check that verifies the actor is a member of the conversation being referenced.

  For create actions, looks up the conversation_id argument and verifies the actor
  is an accepted member of that conversation.
  """

  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(_opts) do
    "actor is a member of the conversation"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    conversation_id = Ash.Changeset.get_argument(changeset, :conversation_id)
    is_member?(actor, conversation_id)
  end

  def match?(_actor, _context, _opts), do: false

  defp is_member?(_actor, nil), do: false

  defp is_member?(actor, conversation_id) do
    # Check if actor is a member of the conversation
    case Magus.Chat.ConversationMember
         |> Ash.Query.filter(
           conversation_id == ^conversation_id and
             user_id == ^actor.id and
             not is_nil(accepted_at)
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %Magus.Chat.ConversationMember{}} -> true
      _ -> false
    end
  end
end
